# Location/timezone daemon

`services.location-timezone.enable` now imports the **Rust implementation and
NixOS service module from the bar-daemon repository**:

- binary: `bar-location-daemon`
- source: `/home/laufan/Projects/bar-daemon/src/bin/bar-location-daemon/`
- module: `bar-daemon.nixosModules.location-timezone`
- full policy, migration and validation documentation:
  `/home/laufan/Projects/bar-daemon/docs/location-timezone.md`

The previous `config/location-timezone/*.py` implementation is retired. No Python
runtime or Python timezonefinder is needed. `checks.location-timezone` points to
the bar-daemon package's Rust checks, including private D-Bus fixtures.

The same `location-timezone.service` and `automatic-timezoned` service account
are retained. A rebuild/switch replaces the Python process rather than starting a
second timezone writer. Existing private JSON state is migrated without losing
provider cooldowns, pause state or accepted location. Home/weather settings are
unchanged; the graphical session's bar-daemon remains a read-only consumer.

Temporary location failures now retry on the same connection, backing off from
30 seconds to five minutes. Wi-Fi fallback results wait for a fresh precise Wi-Fi
fix; internet connectivity alone is not sufficient location evidence. No IP-only
fallback or blind retry after an uncertain timezone write is permitted.

## Deployment

Use the repository's normal `rebuild` workflow (or `local-build check /etc/nixos`
for validation without activation). Administrator authorization is required for
the switch. Afterwards verify:

```sh
systemctl show location-timezone -p ExecStart
systemctl status location-timezone automatic-timezoned
journalctl -u location-timezone -b
cat /run/location-timezone/status.json
timedatectl
```

ExecStart must refer to `bar-location-daemon`, not Python. The retired updater must
remain inactive. `sudo systemctl reload location-timezone` explicitly resumes
paused automation and requests a fresh debounced check, honoring provider
cooldowns. For a guaranteed manual override, stop the service before running
`timedatectl set-timezone Europe/Dublin`.

Build/test success is not proof that the updated service is active or that live
location sources currently agree.
