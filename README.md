# NixOS Config

This repository tracks the live NixOS flake configuration in `/etc/nixos`.

## Apply Changes

Daily ThinkPad rebuild:

```sh
rebuild
```

Use `rebuild`, not a direct `nixos-rebuild --flake` invocation: the wrapper
owns current-worktree selection, compatibility checks, service recovery, and
baseline approval. Direct Nix commands can recreate stale local-project pins.

For the first deployment of this policy, the installed `rebuild` still has the
old behavior. Bootstrap the new wrapper without using old project pins:

```sh
python3 /home/laufan/Projects/daemon-framework/tools/local-build.py run --attr rebuild /etc/nixos
```

After that successful switch, use `rebuild` normally. No source commits are
required, but new files must be registered with Git (`git add` or `git add -N`).

Home Manager is integrated as a NixOS module, so home changes in `home.nix` are applied by the same rebuild.

`rebuild` snapshots the current Git worktrees of the configuration and every local input, including tracked uncommitted edits. Before requesting sudo, a preflight lists untracked files across all discoverable local repositories together. Add or ignore them explicitly; rebuild never changes Git tracking. Snapshotting repeats validation to catch changes after preflight. Ignored build artifacts are excluded. It does not fetch, push, change branches, or write local-project deployment pins. Nix resolves a disposable build graph once; checks and deployment reuse it even if editing continues during the build. Persistent locks retain third-party inputs only.

**Co-development invariant:** all five daemons, including `app-daemon`, consume exactly one current local `daemon-framework` snapshot. No vendored framework or per-daemon revision pin is allowed. The source helper validates this before building, and regression tests protect the policy.

The mandatory checks include framework workspace tests, all five daemon packages/tests, and Shelllist contracts. After success, `rebuild` switches NixOS/Home Manager and restarts Shelllist and all five daemons when the graphical session is active. Restarting is intentional even when unit files have not changed. Build tuning is allowlisted and applied to both checks and the system build: `-v`/`--verbose`, `--quiet`, `-L`/`--print-build-logs`, `--show-trace`, `-k`/`--keep-going`, `-K`/`--keep-failed`, `--fallback`, `--repair`, `--offline`, `-j`/`--max-jobs N|auto`, and `--cores N`. Numeric options accept separate or `=value` arguments, and `-j4` is supported. Source overrides (including `-F`), arbitrary `--option` settings, rollback, and remote deployment modes are rejected before authentication.

Standalone development uses `local-build check /path/to/project`, `local-build build /path/to/project`, or `local-build develop /path/to/project`. Before installing that command, invoke `python3 /home/laufan/Projects/daemon-framework/tools/local-build.py` with the same arguments. This is the supported Nix development path; ordinary `nix build`/`flake check` can create and reuse local lock entries.

`rebuild`, `rollback`, unattended NixOS staging, and generation pruning share the root-owned
`/run/lock/nixos-deployment/lock` inode. Contention makes interactive rebuilds fail
with exit 75 and timer jobs skip, rather than racing the live lock file, profile,
or boot entries. The lock is held through rebuild's baseline approval; the
privileged updater command skips reacquiring the deployment lock during approval.
Its worker-family and updater-state locks are nonblocking, avoiding nested-lock deadlocks.
Rebuild passes a private source-identity manifest directly to that command; approval
without a manifest is refused.
Direct `nixos-rebuild` calls do not participate: run them only when
no deployment/pruning job is active. On the first upgrade introducing this lock,
let existing jobs finish and pause the update/pruning timers before the rebuild;
the new tmpfiles rule provisions the lock at activation. Re-enable the timers
afterwards. Older running scripts cannot participate in the new protocol.

Every invocation records its command output under `~/.local/state/nixos-rebuild/`, including argument rejection and lock contention. `latest.log` points to the most recent attempt (not necessarily the running build) and `latest-failed.log` to the most recent failure; completed files are marked `.success.log` or `.failed.log`. A successful deployment with skipped baseline approval exits zero, keeps a `.success.log`, and reports `SUCCESS WITH WARNINGS` with the approval reason above the summary. Logs older than 30 days are removed when the next rebuild starts. A concise completion overview reports the outcome, elapsed time, derivations built, store paths and data copied, closure and store-size changes, active system, graphical-session recovery, baseline approval, log path, and package changes.

## Validate Changes

Check the flake before applying it:

```sh
local-build check /etc/nixos
```

## HDMI Suspend Recovery

The default configuration corrects Hyprland's Lua DPMS wake/idle commands and
logs compositor output to the journal. Separate `hdmi-display`, `hdmi-kernel`,
and `hdmi-combined` boot specialisations test updated display packages and the
6.18 LTS kernel without changing the default stack or updating the whole OS.
See [HDMI-RECOVERY-ROLLOUT.md](HDMI-RECOVERY-ROLLOUT.md) for deployment, test order,
and rollback. Use `rebuild` so current local project snapshots are selected.

## Automatic Updates

Updates are split by activation risk rather than by one shared system switch.
The `update-daemon` local project packages the privileged NixOS `update-worker`.
AI-tool updates instead use the isolated `packages/vendor-ai-tools` package in
this repository. Existing systemd services/timers invoke finite jobs; no
additional resident process or privileged API is added to bar-daemon.

Structured progress and outcomes are written atomically under
`/var/lib/nixos-delayed-updates-v2/jobs/`. Shelllist shows running, failed,
interrupted and stale-AI-tool jobs, and its update indicator opens the relevant
journals. A completed/skipped check is not presented as an installed update.
The reader verifies boot/PID/start identity before calling a job running.

Activate worker, daemon and UI changes together after checks. Existing quarantine,
approval, dirty-lock protection, profile roots and next-boot staging remain in
force. `monitors.lua` and its compatibility link remain present; do not remove
out-of-store linked configuration merely because a future activation replaces it.

### AI coding tools

Claude Code, Codex, Pi, and T3 Code track **official stable vendor releases**,
not their versions in `nixpkgs-unstable`. Checks run every **15 minutes**, including
on battery, with persistent catch-up after boot/resume. The target is availability
within about one hour while awake and online; network, packaging or compatibility
failures can exceed that target and are reported, not silently treated as current.

Each tool has its own checked Nix package, activation pointer, previous version
and GC roots under `/var/lib/nixos-ai-tools/vendor/<tool>/`. Tools update
concurrently and independently. Pi's extension typecheck/tests gate **only Pi**.
T3 includes both CLI and desktop; its launchers do not prepend a pinned Codex.
Vendor checksums are required, runtime libraries are adapted for NixOS, and
launch/version smoke tests run inside the Nix build sandbox before activation.
Vendor self-updates are disabled where provided. Running sessions are untouched.

The updater directly imports a deployment-pinned nixpkgs for packaging support.
It never evaluates the host flake, inspects Git worktrees, updates the host lock,
requires OS approval, or switches NixOS. Local daemon projects are not dependencies.
Stable PATH launchers prefer the independent tool, then the old shared profile,
then immutable system/Home Manager bootstrap packages.

`ai-tools status` reports each tool's installed and detected vendor versions,
last successful release check, last activation, phase and actionable error.
A recent check does **not** mean the latest release was installed. Shelllist keeps
its aggregate progress/failure indicator and journal link. Hourly stale checks
retry/wait for updates before warning about checks older than four hours;
notifications are rate-limited to six hours.

```sh
ai-tools status
ai-tools status --json
sudo ai-tools check                 # Discover only; do not install
sudo ai-tools update claude         # One tool; unrelated failures do not block it
sudo systemctl start nixos-ai-tools-update.service  # All tools
sudo ai-tools rollback pi           # Restore previous checked profile AND pause Pi updates
sudo ai-tools resume pi             # Explicitly release that hold
systemctl list-timers nixos-ai-tools-update.timer nixos-ai-tools-stale.timer
journalctl -u nixos-ai-tools-update.service -n 100 --no-pager
```

**Deployment:** use `rebuild` once to install the worker, timer and PATH changes,
then start a fresh login session so graphical launches inherit the new PATH.
Thereafter no rebuild is needed for vendor releases. The old shared profile is
left intact as a migration fallback; neither old sessions nor old roots are
removed during migration. See [the packaging/runbook](packages/vendor-ai-tools/README.md)
for sources, trust boundaries, isolated tests and recovery.

### NixOS and other remote inputs

Machine-local `git+file` inputs always come from current tracked worktrees, never persistent revision pins. Manual rebuilds and unattended builds both snapshot them afresh. The updater persists only remote dependency locks and re-evaluates local sources before applying a candidate; a changed resulting system invalidates that candidate. `rebuild` records the captured configuration revision, input lock hash, and active system as the unattended-update baseline. Approval verifies that the live configuration still matches the actual snapshot (before disposable lock resolution). A commit or lock change during the build skips approval without failing the successful deployment. Approval also requires disposable resolution to preserve the captured remote pins; adding or changing remote inputs requires an updated remote lock before approval. A refused approval preserves existing approval metadata and pending updater transactions. Uncommitted `/etc/nixos` files other than `flake.lock` still prevent automatic approval; dirty or unpushed local project worktrees are supported. Nothing is pushed to GitHub.

Other remote inputs are checked daily on AC power. A lightweight 30-minute catch-up timer retries an overdue check after AC power becomes available. A discovered lock snapshot is frozen for three days, checked, and built against the approved local baseline. A successful candidate updates the live lock and system profile but uses `switch-to-configuration boot`, so Home Manager and the graphical session are not activated or restarted. The update takes effect on the next reboot. `nixpkgs-unstable` is refreshed when the matured system candidate is built, but the independent vendor-tool launchers continue to shadow its fallback packages.

A single updater invocation performs discovery and conditional staging; skipped checks do not trigger separate `OnSuccess` apply jobs.

```sh
# Discover or mature the quarantined candidate.
sudo systemctl start nixos-update-check-all.service

# Explicitly stage an already-built candidate for next boot.
sudo systemctl start nixos-update-apply-delayed.service

sudo diff -u /etc/nixos/flake.lock \
  /var/lib/nixos-delayed-updates-v2/delayed/ready-flake.lock
sudo cat /var/lib/nixos-delayed-updates-v2/delayed/first-seen

systemctl list-timers nixos-update-delayed.timer nixos-update-delayed-catchup.timer
journalctl -u nixos-update-delayed.service \
  -u nixos-update-delayed-catchup.service -n 100 --no-pager
```

Review and commit automatic `flake.lock` changes intentionally. After changing and committing NixOS configuration, run `rebuild` once to approve that local commit and exact resulting lock for future unattended staging.

## Generation Retention

`prune-nixos-generations.service` runs daily for both the system and Home Manager profiles. It retains the newest five generations, the newest generation from each of the current and previous seven ISO weeks, and the newest generation from each of the current and previous eleven calendar months. These sets may overlap, and active system/profile targets are always protected. Boot entries are refreshed from the system profile target, preserving any update staged for the next boot rather than reselecting the older running system. `nix-store-gc.timer` separately removes unreferenced store paths once per week.

## Secrets and Login Recovery

`sops-nix` decrypts the login password hash from `secrets.yaml`. The root-owned Age identity is intentionally kept outside Git at:

```text
/var/lib/sops-nix/key.txt
```

Back up that identity in a password manager or other secure offline location. On a fresh installation, restore it as `root:root` with mode `0600` before the first rebuild. To migrate an existing user-owned identity:

```sh
sudo install -d -m 0700 -o root -g root /var/lib/sops-nix
sudo install -m 0600 -o root -g root \
  "$HOME/.config/sops/age/keys.txt" /var/lib/sops-nix/key.txt
```

After a successful rebuild and decryption test, remove the old user-owned copy. Fingerprint enrollment remains machine-local and can be restored by enrolling again after password login works.

To edit encrypted secrets:

```sh
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  nix shell nixpkgs#sops -c sops secrets.yaml
```

## Desktop Input Access

The desktop user intentionally does not belong to `input`. Hyprland obtains
session-scoped device access through logind; ordinary applications must not get
permanent access to raw keyboard events. If a specific device needs extra
permissions, use a narrowly scoped device rule rather than restoring this group.

After deploying the removal of `input` membership, reboot to discard the old
supplementary groups in all existing user processes. Changing `/etc/group`
alone does not revoke access from already-running processes.

## Notifications

Shelllist's bar-daemon is the sole notification server and owns
`org.freedesktop.Notifications`. Notification presentation and history belong
to Shelllist; no separate notification daemon or legacy Waybar client is needed.

## Clipboard

Ringboard and `clip-daemon` are the only clipboard-history stack; `Super+V` opens its Shelllist frontend. Ringboard captures content before its source exits, although the live Wayland selection can remain empty until an item is copied again.

All three clipboard services use the unit files shipped by `clip-daemon`. These select its policy-enabled Ringboard package and retain the startup readiness, retention initialization, and privacy checks. Do not substitute `pkgs.ringboard-wayland`: the stock server cannot perform safe edits, deletes, or favorite changes. Before activating an engine change, back up history and review retention settings; startup applies those limits.

## Notes

- `hardware-configuration.nix` is machine-specific.
- Review `git diff` before committing or applying changes.
