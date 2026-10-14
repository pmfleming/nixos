"""Pure policy for network-scoped, fail-closed timezone updates."""
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import tempfile


@dataclass(frozen=True)
class Fix:
    latitude: float
    longitude: float
    timestamp: float
    source: str
    accuracy: float = 0
    zone: str = ""
    country: str = ""


def coordinate(value, bound):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("Invalid location coordinates")
    if not math.isfinite(value) or abs(value) > bound:
        raise ValueError("Invalid location coordinates")
    return float(value)


def ip_fix(payload, now):
    if not isinstance(payload, dict) or payload.get("error"):
        raise ValueError("IP location unavailable")
    zone, country = payload.get("timezone"), payload.get("country_code")
    if not isinstance(zone, str) or len(zone) > 100 or not zone:
        raise ValueError("IP timezone unavailable")
    if not isinstance(country, str) or len(country) != 2 or not country.isalpha():
        raise ValueError("IP country unavailable")
    return Fix(coordinate(payload.get("latitude"), 90),
               coordinate(payload.get("longitude"), 180), now, "IP",
               zone=zone, country=country.upper())


def distance_km(a, b):
    lat1, lat2 = map(math.radians, (a.latitude, b.latitude))
    dlat = lat2 - lat1
    dlon = math.radians(b.longitude - a.longitude)
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(min(1, max(0, h))))


def agreement(wifi, ip, *, started, now, zone_at, canonical, countries):
    """No cached pre-network fix, IP fallback, broad fix, or single-source writes."""
    for fix in (wifi, ip):
        coordinate(fix.latitude, 90)
        coordinate(fix.longitude, 180)
        if not math.isfinite(fix.timestamp) or not started <= fix.timestamp <= now + 5:
            raise ValueError("Waiting for a fresh location · timezone unchanged")
        if now - fix.timestamp > 300:
            raise ValueError("Location expired · timezone unchanged")
    if wifi.source != "WiFi" or ip.source != "IP":
        raise ValueError("Wi-Fi location unavailable · timezone unchanged")
    if not math.isfinite(wifi.accuracy) or not 0 < wifi.accuracy <= 25000:
        raise ValueError("Wi-Fi location too imprecise · timezone unchanged")
    if abs(wifi.timestamp - ip.timestamp) > 120:
        raise ValueError("Location observations do not overlap · timezone unchanged")
    if distance_km(wifi, ip) > 50:
        raise ValueError("Sources disagree · no automatic change")
    zones = [canonical(zone_at(fix.latitude, fix.longitude) or "") for fix in (wifi, ip)]
    if not zones[0] or zones[0] != zones[1] or canonical(ip.zone) != zones[0]:
        raise ValueError("Sources disagree · no automatic change")
    # zone.tab is a conservative country/zone consistency check, not a country
    # polygon lookup. Border ambiguity never changes the agreed timezone.
    if ip.country not in countries(zones[0]):
        raise ValueError("IP country and timezone disagree · no automatic change")
    return zones[0]


class Schedule:
    """One attempt per usable connection; timers never schedule another lookup."""
    def __init__(self):
        self.network = None
        self.generation = 0
        self.due = float("inf")
        self.attempted_network = None
        self.started = None

    def invalidate(self, network, now):
        self.network = network
        self.generation += 1
        self.started = None
        self.due = now + 10 if network and network != self.attempted_network else float("inf")

    def begin(self, now):
        if not self.network or self.started is not None or now < self.due:
            return None
        self.started = now
        self.attempted_network = self.network
        self.due = float("inf")
        return self.generation

    def current(self, generation):
        return self.network is not None and self.started is not None and generation == self.generation

    def finish(self, generation):
        if not self.current(generation):
            return False
        self.started = None
        self.due = float("inf")
        return True


def atomic_json(path, value, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".location-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            os.fchmod(output.fileno(), mode)
            json.dump(value, output, allow_nan=False)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def provider_wait(state, now):
    """Honor a provider-issued cooldown only; there is no local request quota."""
    return max(0, state.get("ip_not_before", 0) - now)
