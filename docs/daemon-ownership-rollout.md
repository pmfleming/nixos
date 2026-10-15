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
