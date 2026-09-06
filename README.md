# NixOS Config

This repository tracks the live NixOS flake configuration in `/etc/nixos`.

## Apply Changes

Daily ThinkPad rebuild:

```sh
rebuild
```

Low-level command (bypasses the `rebuild` wrapper's deployment lock, checks,
local-input updates, service recovery, and baseline approval):

```sh
sudo nixos-rebuild switch --flake /etc/nixos#thinkpad
```

Home Manager is integrated as a NixOS module, so home changes in `home.nix` are applied by the same rebuild.

`rebuild` rejects every untracked file, advances the `machine.localProjects` inputs to their committed branch heads in one lock operation, and verifies that they exactly match the root `git+file` inputs. It then runs the complete flake checks, switches the NixOS and integrated Home Manager generations, and restarts Shelllist plus `app-daemon`, `bar-daemon`, `bt-daemon`, `clip-daemon`, and `nm-daemon` when the graphical session is active. This explicit restart is intentional: Home Manager normally restarts only units whose unit files changed. Extra arguments are passed to `nixos-rebuild`.

`rebuild`, `rollback`, unattended NixOS staging, and generation pruning share the root-owned
`/run/lock/nixos-deployment/lock` inode. Contention makes interactive rebuilds fail
with exit 75 and timer jobs skip, rather than racing the live lock file, profile,
or boot entries. The lock is held through rebuild's baseline approval; that
service takes only the updater-state lock to avoid a nested-lock deadlock.
Direct `nixos-rebuild` calls do not participate: run them only when
no deployment/pruning job is active. On the first upgrade introducing this lock,
let existing jobs finish and pause the update/pruning timers before the rebuild;
the new tmpfiles rule provisions the lock at activation. Re-enable the timers
afterwards. Older running scripts cannot participate in the new protocol.

Every invocation records its command output under `~/.local/state/nixos-rebuild/`. `latest.log` points to the most recent run and `latest-failed.log` to the most recent failure; completed files are marked `.success.log` or `.failed.log`. Logs older than 30 days are removed when the next rebuild starts. A concise completion overview reports the outcome, elapsed time, derivations built, store paths and data copied, closure and store-size changes, active system, graphical-session recovery, baseline approval, log path, and package changes.

## Validate Changes

Check the flake before applying it:

```sh
nix flake check /etc/nixos
```

## Automatic Updates

Updates are split by activation risk rather than by one shared system switch.

### AI coding tools

Claude Code, Codex, Pi, and T3 Code are checked against `nixpkgs-unstable` every 30 minutes. The updater keeps an independent lock under `/var/lib/nixos-ai-tools`, builds only the four-tool profile, runs the Pi extension compatibility check, and atomically moves `/var/lib/nixos-ai-tools/current` after everything succeeds. New processes immediately use that profile through `PATH`; running agent sessions are not interrupted. A failed build leaves the previous profile active and sends a rate-limited desktop notification. A separate stale check first retries and waits for the updater, then warns if no successful check completes for four hours.

The system and Home Manager packages remain bootstrap fallbacks. The independent profile shadows them after its first successful run and never modifies `/etc/nixos/flake.lock` or switches NixOS.

```sh
sudo systemctl start nixos-ai-tools-update.service
systemctl list-timers nixos-ai-tools-update.timer nixos-ai-tools-stale.timer
journalctl -u nixos-ai-tools-update.service -n 100 --no-pager
readlink -f /var/lib/nixos-ai-tools/current
```

### NixOS and other remote inputs

Machine-local `git+file` inputs remain local-first and are never advanced by the scheduled updater. `rebuild` advances them to their local committed branch heads, checks the complete flake, switches the machine, and then records the exact local configuration revision, lock hash, and active system path as the unattended-update baseline. Those commits do not need to be pushed to GitHub. Uncommitted `/etc/nixos` files other than `flake.lock` deliberately prevent approval, while unpushed commits in the local project repositories are supported.

Other remote inputs are checked daily on AC power. A lightweight 30-minute catch-up timer retries an overdue check after AC power becomes available. A discovered lock snapshot is frozen for three days, checked, and built against the approved local baseline. A successful candidate updates the live lock and system profile but uses `switch-to-configuration boot`, so Home Manager and the graphical session are not activated or restarted. The update takes effect on the next reboot. `nixpkgs-unstable` is refreshed when the matured system candidate is built, but the independently newer AI-tools profile continues to shadow its fallback packages.

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

## Clipboard

Ringboard and `clip-daemon` are the only clipboard-history stack; `Super+V` opens its Shelllist frontend. Ringboard captures content before its source exits, although the live Wayland selection can remain empty until an item is copied again.

## Notes

- `hardware-configuration.nix` is machine-specific.
- Review `git diff` before committing or applying changes.
