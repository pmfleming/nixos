import concurrent.futures
from dataclasses import replace
import json
import math
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from policy import Fix, Schedule, agreement, atomic_json, ip_fix, provider_wait
import daemon


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.wifi = Fix(53.3498, -6.2603, 1001, "WiFi", 3102)
        self.ip = Fix(53.34, -6.27, 1002, "IP", zone="Europe/Dublin", country="IE")

    def decide(self, wifi=None, ip=None, **kwargs):
        values = dict(started=1000, now=1010, zone_at=lambda lat, lon: "Europe/Dublin",
                      canonical=lambda zone: zone, countries=lambda zone: {"IE"})
        values.update(kwargs)
        return agreement(wifi or self.wifi, ip or self.ip, **values)

    def test_matching_dublin(self):
        self.assertEqual(self.decide(), "Europe/Dublin")

    def test_actual_alberta_observation_is_rejected(self):
        alberta = replace(self.wifi, latitude=54.605633587076056, longitude=-112.803852)
        with self.assertRaisesRegex(ValueError, "Sources disagree"):
            self.decide(wifi=alberta)

    def test_rejects_stale_future_broad_nonwifi_or_nonoverlapping_observations(self):
        for change in [dict(timestamp=999), dict(timestamp=1020), dict(accuracy=0),
                       dict(accuracy=30000), dict(accuracy=math.nan), dict(source="GeoIP")]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.decide(wifi=replace(self.wifi, **change))
        with self.assertRaises(ValueError):
            self.decide(now=1400)
        with self.assertRaises(ValueError):
            self.decide(ip=replace(self.ip, timestamp=1150), now=1155)

    def test_country_timezone_and_boundary_disagreement(self):
        for ip in [replace(self.ip, zone="Europe/London"), replace(self.ip, country="CA")]:
            with self.subTest(ip=ip), self.assertRaises(ValueError):
                self.decide(ip=ip)
        with self.assertRaises(ValueError):
            self.decide(zone_at=lambda lat, lon: "Europe/Dublin" if lat > 53.345 else "Europe/London")
        with self.assertRaises(ValueError):
            self.decide(zone_at=lambda lat, lon: None)

    def test_missing_invalid_and_nonfinite_payloads(self):
        good = dict(latitude=53.3, longitude=-6.2, timezone="Europe/Dublin", country_code="IE")
        for bad in [{}, {**good, "error": True}, {**good, "latitude": True},
                    {**good, "latitude": 91}, {**good, "longitude": math.inf},
                    {**good, "timezone": None}, {**good, "country_code": ""}]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                ip_fix(bad, 1000)
        self.assertEqual(ip_fix(good, 1000).country, "IE")


class SchedulingTests(unittest.TestCase):
    def test_offline_to_online_debounce_and_stale_reply_fence(self):
        s = Schedule()
        self.assertIsNone(s.begin(0))
        s.invalidate(("connection-a", "ap-a"), 0)
        self.assertIsNone(s.begin(9))
        generation = s.begin(10)
        self.assertTrue(s.current(generation))
        self.assertIsNone(s.begin(20))
        s.invalidate(("connection-b", "ap-b"), 21)
        self.assertFalse(s.current(generation))
        self.assertFalse(s.finish(generation))
        self.assertIsNone(s.begin(30))
        self.assertTrue(s.current(s.begin(31)))

    def test_new_connection_object_after_disconnect_rearms(self):
        s = Schedule()
        s.invalidate(("same-wifi", "/connection/1"), 0)
        old = s.begin(10)
        s.invalidate(None, 12)
        self.assertFalse(s.current(old))
        s.invalidate(("same-wifi", "/connection/2"), 20)
        new = s.begin(30)
        self.assertIsNotNone(new)
        self.assertNotEqual(old, new)

    def test_new_connections_have_no_daily_cap(self):
        s = Schedule()
        for connection in range(100):
            s.invalidate(connection + 1, connection * 20)
            generation = s.begin(connection * 20 + 10)
            self.assertIsNotNone(generation)
            self.assertTrue(s.finish(generation))

    def test_completion_never_schedules_hourly_or_failure_retries(self):
        s = Schedule()
        s.invalidate("online", 0)
        generation = s.begin(10)
        self.assertTrue(s.finish(generation))
        for now in (60, 3600, 86400, 365 * 86400):
            self.assertIsNone(s.begin(now))
        s.invalidate(None, 100)
        s.invalidate("online", 200)
        self.assertIsNone(s.begin(220), "Connectivity flicker is not a new connection")
        s.invalidate("new-connection-object", 300)
        self.assertIsNotNone(s.begin(310))

    def test_only_provider_cooldown_limits_requests(self):
        state = {"budget_day": "2026-10-14", "ip_calls": 100000}
        for now in (0, 1000, 1791990000):
            self.assertEqual(provider_wait(state, now), 0)
        state["ip_not_before"] = 2000
        self.assertEqual(provider_wait(state, 1000), 1000)
        self.assertEqual(provider_wait(json.loads(json.dumps(state)), 1500), 500)
        self.assertEqual(provider_wait(state, 2000), 0)

    def test_atomic_private_state_and_public_status(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / "state.json"
            atomic_json(p, {"accepted": "Dublin"})
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            atomic_json(p, {"message": "Sources disagree"}, mode=0o644)
            self.assertEqual(json.loads(p.read_text()), {"message": "Sources disagree"})
            self.assertEqual(p.stat().st_mode & 0o777, 0o644)
            with self.assertRaises(ValueError):
                atomic_json(p, {"x": math.nan})
            self.assertEqual(json.loads(p.read_text()), {"message": "Sources disagree"})
            self.assertEqual(len(list(Path(directory).iterdir())), 1)


class AuthorityTests(unittest.TestCase):
    def make_authority(self):
        a = daemon.Authority.__new__(daemon.Authority)
        a.schedule = Schedule()
        a.schedule.invalidate("wifi-a", 0)
        a.schedule.begin(10)
        a.state = {}
        a.ip_future = None
        a.suspended = False
        a.started_wall = 1000
        a.wifi = Fix(53.3498, -6.2603, 1001, "WiFi", 1000)
        a.ip = Fix(53.34, -6.27, 1002, "IP", zone="Europe/Dublin", country="IE")
        a.baseline = "America/Edmonton"
        a.zones = MagicMock()
        a.zones.at.return_value = "Europe/Dublin"
        a.zones.canonical.side_effect = lambda name: name
        a.zones.country_map = {"Europe/Dublin": {"IE"}}
        a.network = MagicMock(return_value="wifi-a")
        a.timezone = MagicMock(side_effect=["America/Edmonton", "Europe/Dublin"])
        a.bus = MagicMock()
        a.save = MagicMock()
        a.status = MagicMock()
        a.close_geo = MagicMock()
        return a

    @patch("daemon.time.time", return_value=1010)
    @patch("daemon.dbus.Interface")
    def test_agreement_writes_once_and_reads_back(self, interface, clock):
        a = self.make_authority()
        a.consider(a.schedule.generation)
        interface.return_value.SetTimezone.assert_called_once_with("Europe/Dublin", False, timeout=10)
        self.assertEqual(a.timezone.call_count, 2)
        self.assertEqual(a.state["accepted"]["timezone"], "Europe/Dublin")
        a.status.assert_called_with("")

    @patch("daemon.time.time", return_value=1010)
    @patch("daemon.dbus.Interface")
    def test_disagreement_does_not_write(self, interface, clock):
        a = self.make_authority()
        a.wifi = replace(a.wifi, latitude=54.6056, longitude=-112.803852)
        a.consider(a.schedule.generation)
        interface.assert_not_called()
        a.timezone.assert_not_called()
        self.assertNotIn("accepted", a.state)
        a.status.assert_called_with("Sources disagree · no automatic change")

    @patch("daemon.time.time", return_value=1010)
    @patch("daemon.dbus.Interface")
    def test_old_generation_and_changed_actual_network_cannot_write(self, interface, clock):
        a = self.make_authority()
        a.consider(a.schedule.generation - 1)
        interface.assert_not_called()
        a.network.return_value = "wifi-b"
        a.invalidate = MagicMock()
        a.consider(a.schedule.generation)
        a.invalidate.assert_called_once_with(force=True)
        interface.assert_not_called()

    @patch("daemon.time.time", return_value=1010)
    @patch("daemon.dbus.Interface")
    def test_manual_change_pauses_and_apply_failure_is_not_success(self, interface, clock):
        a = self.make_authority()
        a.timezone.side_effect = ["Europe/Amsterdam"]
        a.consider(a.schedule.generation)
        self.assertTrue(a.state["paused"])
        interface.assert_not_called()
        a = self.make_authority()
        interface.return_value.SetTimezone.side_effect = daemon.dbus.DBusException("Denied")
        a.consider(a.schedule.generation)
        self.assertNotIn("accepted", a.state)
        a.status.assert_called_with("Timezone not applied · waiting for a new connection")

    def test_cached_geoclue_result_waits_instead_of_accepting(self):
        a = self.make_authority()
        a.wifi = None
        a.props = MagicMock(return_value={"Timestamp": (999, 0)})
        a.consider = MagicMock()
        a.geo_update(a.schedule.generation, "/location/old")
        self.assertIsNone(a.wifi)
        a.consider.assert_not_called()
        self.assertIsNotNone(a.schedule.started)

    def test_late_ip_rate_limit_retained_without_applying_old_result(self):
        a = self.make_authority()
        a.consider = MagicMock()
        future = concurrent.futures.Future()
        future.set_result((None, 7200, "rate limited"))
        a.ip_update(a.schedule.generation - 1, future)
        self.assertGreater(a.state["ip_not_before"], 0)
        a.save.assert_called_once()
        a.consider.assert_not_called()

    @patch("daemon.GLib.idle_add")
    def test_signals_recheck_identity_not_force_a_lookup(self, idle):
        a = self.make_authority()
        a.invalidate = MagicMock()
        a.network_signal(daemon.NM, {"Connectivity": 4}, [])
        idle.assert_called_once_with(a.refresh_network)
        a.invalidate.assert_not_called()
        a.refresh_network()
        a.invalidate.assert_called_once_with()
        idle.reset_mock()
        a.network_signal(daemon.NM + ".Device.Wireless", {"LastScan": 123}, [])
        a.owner_signal(daemon.GEO, ":1.3", "")
        a.owner_signal(daemon.GEO, "", ":1.4")
        idle.assert_not_called()
        a.resume_signal(True)
        self.assertTrue(a.suspended)
        self.assertIsNone(a.schedule.started)
        a.resume_signal(False)
        idle.assert_called_once_with(a.refresh_network)
        self.assertFalse(a.suspended)
        self.assertIsNone(a.schedule.begin(10000))

    def test_repeated_network_notifications_do_not_rearm_or_replace_status(self):
        a = self.make_authority()
        a.fail(a.schedule.generation, "Sources disagree")
        a.status.reset_mock()
        generation = a.schedule.generation
        for _ in range(10):
            a.invalidate()
        self.assertEqual(a.schedule.generation, generation)
        self.assertIsNone(a.schedule.begin(1000000))
        a.status.assert_not_called()
        a.network.return_value = None
        a.invalidate()
        a.network.return_value = "wifi-a"
        a.invalidate()
        self.assertIsNone(a.schedule.begin(1000000))
        a.status.assert_called_with("Sources disagree")

    @patch("daemon.dbus.Interface")
    def test_cooldown_blocks_connection_attempt_without_a_fake_budget(self, interface):
        a = self.make_authority()
        a.state = {"ip_not_before": 2000, "ip_calls": 40}
        with patch("daemon.time.time", return_value=1000):
            a.start(a.schedule.generation)
        interface.assert_not_called()
        a.status.assert_called_with("Location provider rate limited · timezone unchanged")
        self.assertIsNone(a.schedule.begin(5000))

    @patch("daemon.dbus.Interface")
    def test_no_request_counter_before_geo_or_ip_setup(self, interface):
        a = self.make_authority()
        a.state = {"ip_calls": 40, "budget_day": "2026-10-14"}
        interface.return_value.GetClient.side_effect = daemon.dbus.DBusException("unavailable")
        with self.assertRaises(daemon.dbus.DBusException):
            a.start(a.schedule.generation)
        self.assertEqual(a.state["ip_calls"], 40)
        a.save.assert_not_called()

    def test_real_offline_zone_dataset_and_aliases(self):
        zones = daemon.Zones(Path(os.environ["TZDIR"]))
        self.assertEqual(zones.at(53.3498, -6.2603), "Europe/Dublin")
        self.assertEqual(zones.canonical("Eire"), "Europe/Dublin")
        self.assertIn("IE", zones.country_map["Europe/Dublin"])
        self.assertNotEqual(zones.at(54.605633587076056, -112.803852), "Europe/Dublin")


if __name__ == "__main__":
    unittest.main()
