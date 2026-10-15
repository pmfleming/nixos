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
