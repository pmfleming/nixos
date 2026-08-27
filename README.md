# NixOS Config

This repository tracks the live NixOS flake configuration in `/etc/nixos`.

## Apply Changes

Daily ThinkPad rebuild:

```sh
rebuild
```

Equivalent explicit command:

```sh
sudo nixos-rebuild switch --flake /etc/nixos#thinkpad
```

Home Manager is integrated as a NixOS module, so home changes in `home.nix` are applied by the same rebuild.

`rebuild` first rejects untracked Nix files, discovers every root `git+file` input from `flake.lock`, verifies that the set exactly matches `machine.localProjects`, and advances all of them to their committed branch heads. It then runs the complete flake checks, switches the NixOS and integrated Home Manager generations, and force-restarts Shelllist plus `app-daemon`, `bar-daemon`, `bt-daemon`, `clip-daemon`, and `nm-daemon` when the graphical session is active. This explicit restart is intentional: Home Manager normally restarts only units whose unit files changed. Extra arguments are passed to `nixos-rebuild`.

## Validate Changes

Check the flake before applying it:

```sh
nix flake check /etc/nixos
```

## Automatic Updates

Updates are split by activation risk rather than by one shared system switch.

### AI coding tools

Claude Code, Codex, Pi, and T3 Code are checked against `nixpkgs-unstable` every 30 minutes. The updater keeps an independent lock under `/var/lib/nixos-ai-tools`, builds only the four-tool profile, runs the Pi extension compatibility check, and atomically moves `/var/lib/nixos-ai-tools/current` after everything succeeds. New processes immediately use that profile through `PATH`; running agent sessions are not interrupted. A failed build leaves the previous profile active and sends a rate-limited desktop notification. A separate stale check warns if no successful check completes for four hours.

The system and Home Manager packages remain bootstrap fallbacks. The independent profile shadows them after its first successful run and never modifies `/etc/nixos/flake.lock` or switches NixOS.

```sh
sudo systemctl start nixos-ai-tools-update.service
systemctl list-timers nixos-ai-tools-update.timer nixos-ai-tools-stale.timer
journalctl -u nixos-ai-tools-update.service -n 100 --no-pager
readlink -f /var/lib/nixos-ai-tools/current
```

### NixOS and other remote inputs

Machine-local `git+file` inputs remain local-first and are never advanced by the scheduled updater. `rebuild` advances them to their local committed branch heads, checks the complete flake, switches the machine, and then records the exact local configuration revision, lock hash, and active system path as the unattended-update baseline. Those commits do not need to be pushed to GitHub. Uncommitted `/etc/nixos` files other than `flake.lock` deliberately prevent approval, while unpushed commits in the local project repositories are supported.

Other remote inputs are checked daily on AC power. A discovered lock snapshot is frozen for three days, checked, and built against the approved local baseline. A successful candidate updates the live lock and system profile but uses `switch-to-configuration boot`, so Home Manager and the graphical session are not activated or restarted. The update takes effect on the next reboot. `nixpkgs-unstable` is refreshed when the matured system candidate is built, but the independently newer AI-tools profile continues to shadow its fallback packages.

One service performs discovery and conditional staging; skipped checks no longer trigger separate `OnSuccess` apply jobs.

```sh
# Discover or mature the quarantined candidate.
sudo systemctl start nixos-update-check-all.service

# Explicitly stage an already-built candidate for next boot.
sudo systemctl start nixos-update-apply-delayed.service

sudo diff -u /etc/nixos/flake.lock \
  /var/lib/nixos-delayed-updates-v2/delayed/ready-flake.lock
sudo cat /var/lib/nixos-delayed-updates-v2/delayed/first-seen

systemctl list-timers nixos-update-delayed.timer
journalctl -u nixos-update-delayed.service -n 100 --no-pager
```

Review and commit automatic `flake.lock` changes intentionally. After changing and committing NixOS configuration, run `rebuild` once to approve that local commit and exact resulting lock for future unattended staging.

## Generation Retention

`prune-nixos-generations.service` runs daily for both the system and Home Manager profiles. It retains the newest five generations, the newest generation from each of the current and previous seven ISO weeks, and the newest generation from each of the current and previous eleven calendar months. These sets may overlap, and active system/profile targets are always protected. `nix-store-gc.timer` separately removes unreferenced store paths once per week.

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

## Clipboard

Ringboard and `clip-daemon` are the only clipboard-history stack; `Super+V` opens its Shelllist frontend. Ringboard captures content before its source exits, although the live Wayland selection can remain empty until an item is copied again.

## Notes

- `hardware-configuration.nix` is machine-specific.
- Review `git diff` before committing or applying changes.
