"""Private-bus smoke: real authority, fake NM/GeoClue/timedated, no host writes/HTTP."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

PROPS = "org.freedesktop.DBus.Properties"
NM = "org.freedesktop.NetworkManager"
GEO = "org.freedesktop.GeoClue2"
TIME = "org.freedesktop.timedate1"


def services():
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    names = [dbus.service.BusName(name, bus) for name in (NM, GEO, TIME)]
    objects = []
    scenario = {"network": 1, "zone": "America/Edmonton", "writes": [], "clients": 0}

    class Object(dbus.service.Object):
        def __init__(self, path, values):
            super().__init__(bus, path)
            self.values = values
            objects.append(self)

        @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
        def GetAll(self, interface):
            return self.values(interface)

        @dbus.service.method(PROPS, in_signature="ss", out_signature="v")
        def Get(self, interface, name):
            return self.values(interface)[name]

        @dbus.service.method(PROPS, in_signature="ssv", out_signature="", message_keyword="message")
        def Set(self, interface, name, value, message=None):
            # dbus-python dispatch otherwise accepts wrong wire signatures,
            # unlike GeoClue's GDBus implementation.
            if message.get_signature() != "ssv":
                raise dbus.DBusException("Expected Properties.Set(ssv)",
                                         name="org.freedesktop.DBus.Error.UnknownMethod")

        @dbus.service.signal(PROPS, signature="sa{sv}as")
        def PropertiesChanged(self, interface, changed, invalidated):
            pass

    class Network(Object):
        @dbus.service.method("test.Control", in_signature="u", out_signature="")
        def Move(self, number):
            scenario["network"] = int(number)
            self.PropertiesChanged(NM, {"Connectivity": dbus.UInt32(4)}, [])

        @dbus.service.method("test.Control", out_signature="as")
        def Writes(self):
            return scenario["writes"]

    network = Network("/org/freedesktop/NetworkManager", lambda _: {
        "Connectivity": dbus.UInt32(4), "State": dbus.UInt32(70),
        "ActiveConnections": dbus.Array([dbus.ObjectPath(f'/connection/{scenario["network"]}')], signature="o"),
        "PrimaryConnection": dbus.ObjectPath(f'/connection/{scenario["network"]}'),
        "Devices": dbus.Array([dbus.ObjectPath("/device/wifi")], signature="o"),
    })
    Object("/device/wifi", lambda interface: {"DeviceType": dbus.UInt32(2), "State": dbus.UInt32(100)}
           if interface == NM + ".Device" else {"ActiveAccessPoint": dbus.ObjectPath(f'/ap/{scenario["network"]}')})

    class Timedated(Object):
        @dbus.service.method(TIME, in_signature="sb", out_signature="")
        def SetTimezone(self, zone, interactive):
            assert not interactive
            scenario["zone"] = str(zone)
            scenario["writes"].append(str(zone))
            self.PropertiesChanged(TIME, {"Timezone": zone}, [])

    Timedated("/org/freedesktop/timedate1", lambda _: {"Timezone": scenario["zone"]})

    class Client(Object):
        def __init__(self, number):
            self.number, self.active = number, False
            self.location = "/"
            super().__init__(f"/client/{number}", lambda _: {"Location": dbus.ObjectPath(self.location)})

        def fix(self, fresh):
            stamp = time.time() if fresh else time.time() - 60
            seconds = int(stamp)
            # Cached result is always the old Canadian fix; fresh network 2 is Dublin.
            lat, lon = (53.3498, -6.2603) if fresh and scenario["network"] == 2 else (54.605633587076056, -112.803852)
            path = f'/location/{self.number}/{"fresh" if fresh else "cached"}'
            Object(path, lambda _: {
                "Latitude": dbus.Double(lat), "Longitude": dbus.Double(lon),
                "Accuracy": dbus.Double(3102), "Description": "WiFi",
                "Timestamp": dbus.Struct((dbus.UInt64(seconds), dbus.UInt64((stamp - seconds) * 1e6)), signature="tt"),
            })
            old, self.location = self.location, path
            if fresh:
                self.LocationUpdated(old, path)
            return False

        @dbus.service.method(GEO + ".Client", out_signature="")
        def Start(self):
            self.active = True
            self.fix(False)
            GLib.timeout_add(200, lambda: self.fix(True) if self.active else False)

        @dbus.service.method(GEO + ".Client", out_signature="")
        def Stop(self):
            self.active = False

        @dbus.service.signal(GEO + ".Client", signature="oo")
        def LocationUpdated(self, old, new):
            pass

    class Manager(Object):
        @dbus.service.method(GEO + ".Manager", out_signature="o")
        def GetClient(self):
            scenario["clients"] += 1
            client = Client(scenario["clients"])
            return client.__dbus_object_path__

        @dbus.service.method(GEO + ".Manager", in_signature="o", out_signature="")
        def DeleteClient(self, path):
            pass

    Manager("/org/freedesktop/GeoClue2/Manager", lambda _: {})
    assert network and names  # retain bus names and objects for the loop lifetime
    GLib.MainLoop().run()


def authority():
    import daemon
    from policy import Fix
    # Only the remote IP adapter is replaced; real production scheduling,
    # GeoClue subscription, network fencing, status and timezone write run.
    def lookup():
        with open(os.environ["TEST_IP_LOG"], "a") as log:
            log.write("request\n")
        return Fix(53.34, -6.27, time.time(), "IP", zone="Europe/Dublin", country="IE"), 0, ""
    daemon.lookup_ip = lookup
    daemon.main()


def smoke():
    os.environ["DBUS_SYSTEM_BUS_ADDRESS"] = os.environ["DBUS_SESSION_BUS_ADDRESS"]
    with tempfile.TemporaryDirectory() as directory:
        os.environ["STATE_DIRECTORY"] = directory + "/state"
        os.environ["RUNTIME_DIRECTORY"] = directory + "/run"
        os.environ["TEST_IP_LOG"] = directory + "/requests"
        state_dir = Path(directory) / "state"
        state_dir.mkdir()
        (state_dir / "state.json").write_text(json.dumps({"ip_calls": 40, "budget_day": "2026-10-14"}))
        status = Path(directory) / "run/status.json"
        bus = dbus.SessionBus()
        server = subprocess.Popen([sys.executable, __file__, "services"])
        worker = None
        try:
            until = time.monotonic() + 5
            while not bus.name_has_owner(GEO):
                if server.poll() is not None or time.monotonic() > until:
                    raise AssertionError("fake services did not start")
                time.sleep(.05)
            control = dbus.Interface(bus.get_object(NM, "/org/freedesktop/NetworkManager"), "test.Control")
            worker = subprocess.Popen([sys.executable, __file__, "authority"])
            def wait_message(expected):
                until = time.monotonic() + 30
                while time.monotonic() < until:
                    if worker.poll() is not None:
                        raise AssertionError("authority exited")
                    if status.exists() and json.loads(status.read_text())["message"] == expected:
                        return
                    time.sleep(.1)
                raise AssertionError(f"missing status: {expected}")
            wait_message("Sources disagree · no automatic change")
            assert list(control.Writes()) == [], "disagreement must not change timezone"
            control.Move(2)
            wait_message("Checking current location…")
            wait_message("")
            assert list(control.Writes()) == ["Europe/Dublin"]
            saved = json.loads((Path(directory) / "state/state.json").read_text())
            assert saved["accepted"]["timezone"] == "Europe/Dublin"
            assert "ip_calls" not in saved and "budget_day" not in saved
            control.Move(2)  # repeated FULL notification on the same connection
            time.sleep(12)  # longer than debounce; must not cause another lookup
            assert Path(os.environ["TEST_IP_LOG"]).read_text().splitlines() == ["request", "request"]
            assert list(control.Writes()) == ["Europe/Dublin"]
            print("PASS: real D-Bus connection-only lookup, legacy-cap migration, stale-fix rejection and timezone application")
        finally:
            for process in (worker, server):
                if process is not None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    if len(sys.argv) > 1:
        {"services": services, "authority": authority}[sys.argv[1]]()
    else:
        smoke()
