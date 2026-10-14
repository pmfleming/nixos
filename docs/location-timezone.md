# Network-aware timezone updates

`services.location-timezone.enable` replaces `automatic-timezoned`. Do not enable
both: the module asserts mutual exclusion and orders the old writer's stop before
the new writer's start. It retains the existing reserved `automatic-timezoned`
account/UID rather than creating a conflicting replacement identity. Amsterdam's Home/weather entry in `home.nix` is
unchanged. This change implements automatic connection-triggered checks, not the
planned city-management/manual-location panel.

## Triggers and decision

NetworkManager connectivity must be FULL and state CONNECTED_GLOBAL. One initial
check observes the usable connection at service startup. Subsequently, only a new
active/default connection identity schedules a lookup (including reconnecting to
the same saved Wi-Fi with a new connection object). A 10-second debounce coalesces
connection setup. The five-second recovery tick reads local NetworkManager state
only; it does not periodically query a provider.

Repeated FULL notifications, DHCP renewals, AP roaming on the same connection,
GeoClue restarts and waking on the same connection do not rearm a completed check.
Suspending cancels in-flight work; a different connection after resume can start a
new check. NetworkManager's unique bus owner is part of the identity so connection
paths reused after its restart are not confused with the old connection. There is
no dependency on opening Shelllist.

The service owns its own GeoClue client and accepts only a fresh `WiFi` fix newer
than the check, with reported accuracy in (0, 25 km]. GeoClue can return an old fix
on Start: it is ignored while waiting up to 90 seconds for LocationUpdated. An
HTTPS `ipapi.co` lookup runs independently. No redirects/proxies are followed,
responses are bounded to 64 KiB, and a request times out after 15 seconds.

Both points must be within 50 km, less than five minutes old, at most two minutes
apart, and resolve to the same canonical IANA timezone using timezonefinder's
packaged land boundaries. The IP-reported timezone must match and its country
must belong to that timezone in tzdata's zone.tab. **This last check is country /
zone consistency, not a country-polygon comparison**; it must not be presented as
proof of identical countries near a border. GeoClue's WiFi attribution is the
installed provider's description, not cryptographic source provenance.

Re-read the active network immediately before SetTimezone. Reject obsolete
network generations, stale fixes, disagreement, missing data, failures and rate
limits. Never choose a single provider as fallback. Keep the current system zone
until agreement; successful changes are read back from timedated. System UTC/NTP
is never changed. There are **no hourly checks, automatic failure retries or local
daily quotas**. After either success or failure, wait for a new connection.
Provider-issued HTTP 429 / Retry-After cooldowns are persisted and honored even
across reconnects and restarts; a 429 with no usable header uses a conservative
one-hour cooldown, not a periodic check. Expiry alone never starts a lookup.
The old `ip_calls` / `budget_day` fields are removed on startup without clearing
provider cooldowns, accepted location or manual-pause state.

## Status and state

* `/var/lib/location-timezone/state.json`: private accepted coordinates/timezone,
  verification timestamp, provider cooldown and pause state; atomically replaced and fsynced.
* `/run/location-timezone/status.json`: public concise message only, atomically
  replaced. No raw IP address, BSSID or coordinates. bar-daemon reads this bounded
  file on a two-second recovery tick and exposes its message in `timezone.error`
  without invalidating an otherwise available system timezone.
* Time & Weather contributes that message through its shared FeedbackSource to
  the existing list status bar, including with details collapsed. No inline warning
  or tooltip is added. The top-bar clock uses the daemon's offset and UTC getters,
  so it does not depend on Qt refreshing its process-local timezone cache.

Provider failures are intentionally not logged with raw URLs/payloads. Automatic
checks send Wi-Fi data through GeoClue/BeaconDB and expose the outgoing public IP
to ipapi.co. Free-tier quotas and availability are not guaranteed. VPN/mobile IP
locations may disagree; that is a retained-timezone warning, not permission to
relax the gate.

## Deployment / manual recovery

Build and switch using the normal repository `rebuild` workflow; this requires
administrator authorization. Deployment must stop automatic-timezoned before the
new writer is started. Check:

```
systemctl status location-timezone automatic-timezoned
journalctl -u location-timezone -b
cat /run/location-timezone/status.json
timedatectl
```

A manual/external timezone change during the service lifetime pauses automatic
writes at the next attempted application. Pause persists across restarts. To
explicitly resume eligibility for the next new connection:
`sudo systemctl reload location-timezone`. This does not recheck an already
attempted connection. For a guaranteed
manual override, stop the service before `timedatectl set-timezone Europe/Dublin`.
Restarting a not-paused service establishes the then-current system timezone as
its baseline; it does not reinterpret Home as a verified location.

The service runs without root and with authorization only for timedated's
set-timezone operation. State/runtime directories are its only writable system
paths. No application or geocoding mutation API is introduced here.

## Validation

`checks.location-timezone` runs policy, generation/race, provider-cooldown persistence,
connection-only routing, no-hourly/no-retry behavior, stale GeoClue, manual-override
and apply/readback tests,
plus actual packaged timezone boundaries/aliases. A private D-Bus integration test
runs the real authority against fake NetworkManager, GeoClue and timedated:
Canadian Wi-Fi versus Dublin IP retains the timezone, then a network change with
a fresh Dublin fix applies Europe/Dublin exactly once. It also starts with an
exhausted legacy local counter and verifies it no longer blocks requests; repeated
notifications on the same connection do not issue another request. It performs no external
HTTP calls or host timezone changes. bar-daemon covers bounded status parsing and
zone projections. Shelllist Qt tests cover immediate offset/day rollover and
existing-footer warning placement/clearing.

Live provider agreement and privileged deployment must be verified separately;
unit tests do not establish the current network's geolocation.
