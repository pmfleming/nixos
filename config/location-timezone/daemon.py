#!/usr/bin/env python3
"""Network-aware GeoClue + HTTPS-IP timezone authority. No UI or Home writes."""
import concurrent.futures
from email.utils import parsedate_to_datetime
import json
import logging
import os
from pathlib import Path
import signal
import time
import urllib.error
import urllib.request
from zoneinfo import ZoneInfo

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib
from timezonefinder import TimezoneFinder

from policy import Fix, Schedule, agreement, atomic_json, coordinate, ip_fix, provider_wait

PROPERTIES = "org.freedesktop.DBus.Properties"
NM = "org.freedesktop.NetworkManager"
GEO = "org.freedesktop.GeoClue2"
TIME = "org.freedesktop.timedate1"
LOG = logging.getLogger("location-timezone")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("IP provider redirect rejected")


def lookup_ip():
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.ProxyHandler({}))
    request = urllib.request.Request("https://ipapi.co/json/", headers={
        "User-Agent": "Shelllist-location-timezone/1", "Accept": "application/json"})
    try:
        with opener.open(request, timeout=15) as response:
            data = response.read(65537)
            if len(data) > 65536:
                raise ValueError("IP response too large")
            return ip_fix(json.loads(data), time.time()), 0, ""
    except urllib.error.HTTPError as error:
        if error.code == 429:
            retry = error.headers.get("Retry-After", "3600")
            try:
                delay = max(60, int(retry))
            except ValueError:
                try:
                    delay = max(60, parsedate_to_datetime(retry).timestamp() - time.time())
                except (TypeError, ValueError, OverflowError):
                    delay = 3600
            return None, delay, "Location provider rate limited · timezone unchanged"
        return None, 0, "IP location unavailable · timezone unchanged"
    except (OSError, ValueError):
        return None, 0, "IP location unavailable · timezone unchanged"


class Zones:
    def __init__(self, directory):
        self.finder = TimezoneFinder(in_memory=True)
        self.links = {}
        for line in (directory / "tzdata.zi").read_text().splitlines():
            fields = line.split()
            if fields and fields[0] in ("L", "Link"):
                self.links[fields[2]] = fields[1]
        self.country_map = {}
        for line in (directory / "zone.tab").read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            country, _, zone, *_ = line.split()
            self.country_map.setdefault(self.canonical(zone), set()).add(country)

    def canonical(self, zone):
        for _ in range(20):
            target = self.links.get(zone)
            if target is None:
                try:
                    ZoneInfo(zone)
                    return zone
                except (ValueError, KeyError):
                    return ""
            zone = target
        return ""

    def at(self, lat, lon):
        return self.finder.timezone_at_land(lat=lat, lng=lon)


class Authority:
    def __init__(self):
        self.bus = dbus.SystemBus()
        self.schedule = Schedule()
        self.state_path = Path(os.environ.get("STATE_DIRECTORY", "/var/lib/location-timezone")) / "state.json"
        self.status_path = Path(os.environ.get("RUNTIME_DIRECTORY", "/run/location-timezone")) / "status.json"
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}
        if not isinstance(self.state, dict):
            raise ValueError("Invalid persistent location state")
        # Migrate the obsolete local cap without discarding provider cooldowns,
        # accepted location or the manual-pause state.
        if any(key in self.state for key in ("budget_day", "ip_calls")):
            self.state.pop("budget_day", None)
            self.state.pop("ip_calls", None)
            self.save()
        self.last_result = "Waiting for a new network connection"
        self.zones = Zones(Path(os.environ["TZDIR"]))
        self.message = None
        self.client = None
        self.location_signal = None
        self.wifi = None
        self.ip = None
        self.started_wall = 0
        self.suspended = False
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.ip_future = None
        self.baseline = self.timezone()
        self.bus.add_signal_receiver(self.network_signal, signal_name="PropertiesChanged",
                                     dbus_interface=PROPERTIES, bus_name=NM)
        self.bus.add_signal_receiver(self.resume_signal, signal_name="PrepareForSleep",
                                     dbus_interface="org.freedesktop.login1.Manager",
                                     bus_name="org.freedesktop.login1")
        self.bus.add_signal_receiver(self.owner_signal, signal_name="NameOwnerChanged",
                                     dbus_interface="org.freedesktop.DBus",
                                     bus_name="org.freedesktop.DBus")
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGHUP, self.resume_automatic)
        GLib.timeout_add_seconds(5, self.tick)
        self.invalidate(force=True)

    def props(self, name, path, interface):
        obj = self.bus.get_object(name, path, introspect=False)
        return dbus.Interface(obj, PROPERTIES).GetAll(interface, timeout=5)

    def timezone(self):
        return str(self.props(TIME, "/org/freedesktop/timedate1", TIME)["Timezone"])

    def network(self):
        if self.suspended:
            return None
        try:
            props = self.props(NM, "/org/freedesktop/NetworkManager", NM)
            if int(props.get("Connectivity", 0)) != 4 or int(props.get("State", 0)) != 70:
                return None
            # Connection object paths change on reconnect, even for the same
            # saved network. DHCP renewals, scans and AP roaming on an existing
            # connection must not spend another provider request. Include NM's
            # unique owner because paths can be reused after an NM restart.
            active = tuple(sorted(map(str, props.get("ActiveConnections", []))))
            return (str(self.bus.get_name_owner(NM)), active, str(props.get("PrimaryConnection", "/")))
        except dbus.DBusException:
            return None

    def network_signal(self, interface, changed, invalidated):
        watched = {"Connectivity", "State", "ActiveConnections", "PrimaryConnection",
                   "ActiveAccessPoint", "Ip4Config", "Ip6Config"}
        if str(interface).startswith(NM) and watched.intersection(set(changed) | set(invalidated)):
            GLib.idle_add(self.refresh_network)

    def refresh_network(self):
        # Do not make nested synchronous D-Bus calls from a bus signal handler.
        if not self.suspended:
            self.invalidate()
        return False

    def owner_signal(self, name, old, new):
        if str(name) == NM:
            GLib.idle_add(self.refresh_network)
        # GeoClue stopping/starting is not a network connection event.

    def resume_signal(self, sleeping):
        self.suspended = bool(sleeping)
        if self.suspended:
            self.fail(self.schedule.generation, "Location check interrupted · waiting for a new connection")
        else:
            GLib.idle_add(self.refresh_network)

    def resume_automatic(self):
        # Explicit administrator action: systemctl reload location-timezone.
        self.state["paused"] = False
        self.save()
        self.baseline = self.timezone()
        self.invalidate(force=True)
        return True

    def status(self, text):
        if self.message == text:
            return
        atomic_json(self.status_path, {"message": text}, mode=0o644)
        self.message = text
        LOG.info("%s", text or "Location sources agree; system timezone verified")

    def save(self):
        atomic_json(self.state_path, self.state)

    def invalidate(self, force=False):
        network = self.network()
        if force or network != self.schedule.network:
            self.schedule.invalidate(network, time.monotonic())
            self.close_geo()
            self.wifi = self.ip = None
            if not network:
                self.status("Waiting for internet · timezone unchanged")
            elif self.schedule.due != float("inf"):
                self.status("Checking current location…")
            else:
                self.status(self.last_result)

    def close_geo(self):
        if self.location_signal:
            self.location_signal.remove()
            self.location_signal = None
        if self.client:
            path, self.client = self.client, None
            try:
                dbus.Interface(self.bus.get_object(GEO, path, introspect=False), GEO + ".Client").Stop(timeout=5)
                manager = dbus.Interface(self.bus.get_object(GEO, "/org/freedesktop/GeoClue2/Manager", introspect=False), GEO + ".Manager")
                manager.DeleteClient(path, timeout=5)
            except dbus.DBusException:
                pass

    def tick(self):
        try:
            if self.suspended:
                return True
            # This polls local connection state only, never periodically starts
            # a remote lookup on an already-attempted connection.
            self.invalidate()
            if self.state.get("paused"):
                self.status("Timezone changed manually · automatic location paused")
                return True
            now = time.monotonic()
            if self.schedule.started is not None and now - self.schedule.started > 90:
                self.fail(self.schedule.generation, "Fresh location unavailable · timezone unchanged")
            if self.ip_future is not None:
                return True
            generation = self.schedule.begin(now)
            if generation is not None:
                self.start(generation)
        except (dbus.DBusException, OSError, ValueError, KeyError) as error:
            # Avoid logging raw provider payloads/coordinates or request URLs.
            name = error.get_dbus_name() if isinstance(error, dbus.DBusException) else type(error).__name__
            LOG.warning("Location check failed (%s)", name)
            self.fail(self.schedule.generation, "Location service unavailable · timezone unchanged")
        return True

    def start(self, generation):
        if provider_wait(self.state, time.time()) > 0:
            self.fail(generation, "Location provider rate limited · timezone unchanged")
            return
        self.started_wall = time.time()
        self.wifi = self.ip = None
        self.status("Checking current location…")
        manager = dbus.Interface(self.bus.get_object(GEO, "/org/freedesktop/GeoClue2/Manager", introspect=False), GEO + ".Manager")
        self.client = manager.GetClient(timeout=5)
        client = self.bus.get_object(GEO, self.client, introspect=False)
        props = dbus.Interface(client, PROPERTIES)
        # With introspection disabled, specify the variant-bearing wire
        # signature; inference would send sss/ssu instead of Properties.Set(ssv).
        props.Set(GEO + ".Client", "DesktopId", dbus.String("location-timezone"), signature="ssv", timeout=5)
        props.Set(GEO + ".Client", "RequestedAccuracyLevel", dbus.UInt32(4), signature="ssv", timeout=5)
        self.location_signal = client.connect_to_signal("LocationUpdated", lambda old, new: self.geo_update(generation, new), dbus_interface=GEO + ".Client")
        dbus.Interface(client, GEO + ".Client").Start(timeout=5)
        self.geo_update(generation, props.Get(GEO + ".Client", "Location", timeout=5))
        if not self.schedule.current(generation):
            return
        self.ip_future = self.executor.submit(lookup_ip)
        self.ip_future.add_done_callback(lambda future: GLib.idle_add(self.ip_update, generation, future))

    def geo_update(self, generation, path):
        if not self.schedule.current(generation) or str(path) == "/":
            return
        try:
            value = self.props(GEO, path, GEO + ".Location")
            seconds, micros = value["Timestamp"]
            stamp = float(seconds) + float(micros) / 1e6
            # A new client may receive GeoClue's cached old-network fix. Wait
            # for LocationUpdated with a genuinely fresh observation instead.
            if stamp < self.started_wall:
                return
            self.wifi = Fix(coordinate(float(value["Latitude"]), 90),
                            coordinate(float(value["Longitude"]), 180), stamp,
                            str(value.get("Description", "")), float(value["Accuracy"]))
            self.consider(generation)
        except (dbus.DBusException, ValueError, KeyError, TypeError):
            self.fail(generation, "Wi-Fi location unavailable · timezone unchanged")

    def ip_update(self, generation, future):
        if self.ip_future is future:
            self.ip_future = None
        try:
            fix, retry, error = future.result()
            if retry:
                self.state["ip_not_before"] = time.time() + retry
                self.save()  # retain rate limit even for an invalidated generation
            if self.schedule.current(generation):
                if error:
                    self.fail(generation, error)
                else:
                    self.ip = fix
                    self.consider(generation)
        except (OSError, ValueError, dbus.DBusException):
            self.fail(generation, "Location service unavailable · timezone unchanged")
        return False

    def consider(self, generation):
        if not self.schedule.current(generation) or self.wifi is None or self.ip is None:
            return
        try:
            zone = agreement(self.wifi, self.ip, started=self.started_wall, now=time.time(),
                             zone_at=self.zones.at, canonical=self.zones.canonical,
                             countries=lambda name: self.zones.country_map.get(name, set()))
            # Re-read the real network before the privileged side effect, not
            # only the generation updated by queued D-Bus signals.
            if self.network() != self.schedule.network:
                self.invalidate(force=True)
                return
            current = self.timezone()
            if current != self.baseline:
                self.state["paused"] = True
                self.save()
                self.fail(generation, "Timezone changed manually · automatic location paused")
                return
            if current != zone:
                timedated = dbus.Interface(self.bus.get_object(TIME, "/org/freedesktop/timedate1", introspect=False), TIME)
                timedated.SetTimezone(zone, False, timeout=10)
            effective = self.timezone()
            if self.zones.canonical(effective) != zone:
                raise ValueError("Timezone change not acknowledged")
            self.baseline = effective
            self.state["accepted"] = {"timezone": zone, "latitude": self.wifi.latitude,
                                      "longitude": self.wifi.longitude, "verified_at": time.time()}
            self.save()
            self.schedule.finish(generation)
            self.close_geo()
            self.last_result = ""
            self.status("")
        except ValueError as error:
            self.fail(generation, str(error))
        except (dbus.DBusException, OSError):
            self.fail(generation, "Timezone not applied · waiting for a new connection")

    def fail(self, generation, message):
        if self.schedule.finish(generation):
            self.close_geo()
            self.last_result = message
            self.status(message)


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    DBusGMainLoop(set_as_default=True)
    authority = Authority()
    loop = GLib.MainLoop()
    def stop():
        authority.close_geo()
        loop.quit()
        return False
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, stop)
    try:
        loop.run()
    finally:
        authority.executor.shutdown(wait=True, cancel_futures=True)


if __name__ == "__main__":
    main()
