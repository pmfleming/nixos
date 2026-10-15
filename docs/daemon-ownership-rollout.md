# Daemon ownership and D-Bus deduplication rollout

## Scope and gates

Shelllist owns presentation and explicit UI effects. Domain daemons own policy,
validation, persistence, effects and operation recovery. The framework owns
transport; deployment composes independently enabled components.

Stages:
1. Introduce daemon-owned session/system integration modules and isolated policy packages.
2. Switch host composition to those modules; preserve machine policy.
3. Make Shelllist UI-only and remove superseded module/packaging ownership.
4. Deduplicate D-Bus discovery without dropping activation definitions or policy.
5. Reconcile domain migration candidates against current code, migrate remaining
   authoritative decisions with contract and interaction tests.
6. Run the full frozen-graph deployment gate, switch, then live and fresh-boot checks.

Each implementation stage is committed after its relevant checks. The final gate
must include all consumer/daemon checks, not just compilation. Changes to display,
sleep, credentials and clipboard must preserve authorization and no-replay guards.

## Baseline

All seven participating repositories and /etc/nixos were clean at start.
The initial system and session duplicate service definitions compared identically.
Some historical migration proposals are already implemented (e.g. Bluetooth
apply-and-remember); do not recreate their older frontend implementations.

Deployment authorization probe: `sudo -n true` requires a password. No system
switch, live bus restart, suspend, reboot or disruptive hardware test is authorized
by an available privilege credential yet. Do not label rollout complete without
those gates. Preserve the existing system generation for rollback.

## Stage 1

Introduced bar-daemon session options, shared service definition, Home Manager and
NixOS modules, separate battery integration and location-only D-Bus policy packages.
Location integration no longer registers the entire bar package. Added app-daemon
RAPL permissions (video group, 0440, no unsupported enabled write), and nm-daemon
resolver/discovery integration with explicit host policy options.

Validation: bar-daemon standalone module contract builds successfully, including
session independence, enabled feature environment, helper-only configuration and
absence of unrelated activation files in location/battery integration packages.
Standalone app-daemon permission and nm-daemon discovery module contracts also
pass (enabled/disabled/custom policy). Host-composed Home Manager checks are
required in stage 2.

## Stage 2

Host configuration now explicitly enables bar-daemon's Home Manager session,
managed idle/display/media policy and the NixOS battery helper. Network discovery
and resource access use their daemon-owned modules. Existing host resolver mode
and inherited mDNS profile policy are preserved. Shelllist's old daemon startup is
disabled temporarily, pending removal of those options in stage 3.

Validation: the composed host ownership check passes, including evaluation with
Shelllist disabled while daemon settings remain identical and hypridle stays
notify-ready. This caught and fixed an unconditional host override that otherwise
left a stub shelllist unit behind. Resource/network and helper module checks remain
mandatory members of the deployment matrix. No live services have been changed.

## Stage 3

Shelllist now exports only the UI application; its NixOS/Home Manager modules no
longer configure daemons, discovery, RAPL, privileged helpers or idle policy. Old
options fail with migration instructions. Client binaries remain runtime adapters
in its PATH, not exported service metadata (their shared server/client packages
remain transitive dependencies). Bar runtime packaging no longer exports system
activation/Polkit/location policy; those are separate integration packages.

Validation: UI-only module/package checks, bar system/session/idle module checks,
and the host UI-disabled independence check pass. Rebuilding bar-daemon also ran
144 library tests, 11 battery helper tests and two integration test cases without
failures. NixOS-managed sessions also get notify-ready idle integration when
explicitly enabled. No deployed service has changed yet.

## Stage 4

Added a canonical system activation directory and a supplemental session directory
that excludes services already available through the system profile's standard
XDG path. Standard session discovery and user override ordering remain intact.
Authorization policies/includes are retained unchanged. Repeated package inputs
are deduplicated; conflicting service contents fail the build. An obex package
fix corrects its activation filename. Tests exposed a pre-existing nonportable
battery activation file lacking Exec; it now has an explicit false fallback so
only systemd can launch the sandboxed privileged helper.

Validation: six generator tests pass, including conflicts, policy preservation,
missing paths, duplicate symlinks and profile overlap. Built host inventory has
32 unique system and 27 unique session activation definitions with no missing
names or misnamed files. Both inventories pass private reference-daemon tests in
the Nix sandbox. Private socket-activated production dbus-broker instances on the
host also pass both inventories without duplicate/name warnings. Broker testing
is separate because the ordinary build sandbox has no journald. No real service
was activated by these tests and neither live bus was restarted. Nix formatting,
deadnix and statix gate passes. Future user-installed overrides remain supported;
this does not suppress warnings for arbitrary duplicate user definitions.

## Stage 5

Reconciled all eight historical domain migration candidates against current native
implementations and UI consumers. Calendar day projections, Bluetooth coordinated
apply/persist, epoch-fenced display baselines, native resource totals/confidence,
application close observation, session-bound edit-and-prepare-paste, network form
descriptors and canonical time/weather locations are already implemented. No
redundant reimplementation or migration of legitimate UI drafts/focus was needed.
The Shelllist review documents the concrete owners. Updated stale option names in
installation/media/display guidance and the unavailable-display hint; added a Qt
regression proving the hint does not enable or dispatch a mutation.

Validation: the complete host `packages.x86_64-linux.rebuildChecks` gate passed
against one captured graph. The Qt suite reported 316 passed, zero failed, one
existing renderer skip; the new display-owner hint test passed. Consumer protocol
fixtures, generated bindings/contracts, transport no-replay checks, Nix quality,
TypeScript, lint, daemon package checks and deployment tests all remain in the
matrix (unchanged cached checks were reused). Log: `/tmp/ownership-full-checks.log`.
A final retained snapshot and system build are still required before activation.

## Stage 6 — activated and live-validated; fresh-boot/hardware acceptance pending

The retained final graph passed `nix flake check --no-build`, the complete
`rebuildChecks` aggregate, and the NixOS toplevel build. All 47 generated udev rule
files passed the system build's verifier. Both final system/session inventories
also passed private reference-daemon and production-broker checks on the host.

Artifacts and logs are rooted under:
`/home/laufan/.local/state/daemon-ownership-rollout/`

- `snapshot/`, `snapshot.json`: the exact graph used for checks and system build.
- `checks`: `/nix/store/hmgi0rf4k6a39q7dz192c7zhhbpb81i6-rebuild-checks`.
- `system`: `/nix/store/dcl8hlhrkm59nf8qxkj4m6qxwjz5xa1a-nixos-system-thinkpad-26.05.20260719.fd14620`.
- `previous-system`: GC-rooted known-running generation for rollback.
- `evaluation.log`, `checks.log`, `system.log`, `private-bus-validation.log`.
- `build.status`: zero.

### Activation and live acceptance — 2026-10-15 17:48–17:51 MDT

The initial sudo blocker was resolved by the user running `rebuild` interactively.
The rebuild completed successfully in 1m 5s, ran all mandatory gates, switched to
the exact checked dcl8hlhrkm59nf8qxkj4m6qxwjz5xa1a generation, refreshed the stack
and recorded the update baseline. Log:
`~/.local/state/nixos-rebuild/rebuild-20261015T234744Z-50938.success.log`.

Verified after activation:

- Both brokers reloaded at 17:48:37 without restarting (system PID 825, user PID
  1542). No duplicate-name or misnamed-service messages since activation. The
  earlier boot warnings remain historical entries, not new failures.
- Live activation inventories contain every expected service: 32 managed system
  definitions and 27 managed session definitions, no duplicates or missing names.
  ListActivatableNames additionally includes org.freedesktop.DBus on each bus.
- All five daemon units, Shelllist, notify-ready hypridle and location-timezone
  are active. Notification name ownership belongs to bar-daemon.
- Stopped only Shelllist at 17:50:52, verified backend/idle PIDs unchanged and
  bar.snapshot plus notification-server reads still available, then restarted
  Shelllist at 17:50:54. The UI subsequently reported its loaded surfaces and
  logged successful bar/network/Bluetooth snapshot reconstruction. No test
  requested a hardware mutation or replayed an uncertain operation.
- Battery helper activated on demand and GetThresholds(BAT0) returned 0/100.
  Generic introspection is denied by the unchanged narrow interface policy;
  calling the allowed read interface succeeds. No thresholds were changed.
- A short test notification was accepted (ID 306). Wi-Fi is connected; speakers,
  microphones and Bluetooth earbuds are present. This is not a hearing/visual
  confirmation or a test of network/audio setting mutations.
- No failed user units. The pre-existing printer issue recurred:
  ensure-printers failed resolving EPSON4C18B4.local at 17:50:32. It is not a
  missing D-Bus activation. Other observed diagnostics include ignored deprecated
  eavesdropping policy, a Qt portal app-ID registration warning and a QML IPC
  signal warning; this is not a claim of a globally warning-free desktop.

Live evidence: `live-independence.json` and `live-activation-inventory.json` in the
artifact directory above. The independence log records both the initial not-yet-
ready UI response and the subsequent successful readiness confirmation.

### Remaining acceptance

The active system is new, but `/run/booted-system` still points to the old q0ibr4c
closure: no reboot has occurred. Reboot when convenient and review the new boot's
bus logs and unit health. Display Preview/Revert, lock/suspend/resume, and visual/
audible notification/audio acceptance need user-present testing. They were not
silently exercised during an active session. Commit fresh-boot/hardware evidence
only after those checks pass; do not label the full hardware plan complete yet.
Roll back with normal NixOS generation selection if needed; the previous closure
remains rooted.
