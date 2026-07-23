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

After the preflight checks, `rebuild` prints a resource summary even if the flake check or rebuild fails. It reports Nix builds, copied and newly added store data, the largest new store paths, closure and disk-space changes, elapsed time, and system-wide CPU, peak RAM, network, and disk I/O. Resource warnings call out additions of at least 10 GiB, copied data or network receives of at least 5 GiB, disk writes of at least 20 GiB, RAM pressure of at least 90%, less than 20 GiB free, or a run lasting at least 30 minutes. System-wide figures can include unrelated work performed at the same time.

Preview the visual summary without rebuilding:

```sh
rebuild --summary-preview
```

The `update` command is an intentional escape hatch that runs `nix flake update` and switches immediately, bypassing staged approval. It leaves `flake.lock` modified; review and commit or revert that change before approving any staged update.

## Validate Changes

Check the flake before applying it:

```sh
nix flake check /etc/nixos
```

## Automatic Updates

`delayed-nixos-update.service` runs overnight at approximately 03:00, only on AC power. The timer is persistent, so a missed run is attempted after the next boot. An AC-only catch-up timer also checks every 15 minutes whether the latest overnight run was missed, covering a laptop that booted on battery and was plugged in later. Successful full-input checks are recorded; expensive catch-up retries after failures are limited to once per hour.

The updater stages the committed `HEAD` outside `/etc/nixos`, ignoring but never modifying uncommitted work, updates the candidate lock, runs `nix flake check` (including formatter checks), and builds the candidate with limited Nix parallelism and low CPU/I/O priority. It never changes the live lock file or switches generations. Approval still requires a clean worktree at the same Git revision used to build the candidate.

### Manual command reference

Stage either update scope immediately:

```sh
# Update every flake input.
sudo systemctl start nixos-update-check-all.service

# Update only nixpkgs-unstable, which supplies Codex, Pi, and Claude.
sudo systemctl start nixos-update-check-apps.service
```

Both commands only check and build a candidate; neither switches the running system. There is one candidate slot, so a successful later staging command replaces the earlier candidate.

When the Waybar update indicator appears, review the persistent candidate state:

```sh
sudo cat /var/lib/nixos-delayed-updates/ready-scope
sudo diff -u /etc/nixos/flake.lock /var/lib/nixos-delayed-updates/ready-flake.lock
```

Apply it explicitly after review:

```sh
sudo systemctl start nixos-update-approve.service
```

Inspect the timer and recent updater output when troubleshooting:

```sh
systemctl list-timers delayed-nixos-update.timer
systemctl list-timers nixos-update-catchup.timer
# Both timers invoke the same catch-up service.
journalctl -u delayed-nixos-update.service -n 100 --no-pager
journalctl -u nixos-update-check-all.service -u nixos-update-check-apps.service -n 100 --no-pager
journalctl -u nixos-update-approve.service -n 100 --no-pager
```

The approval service requires a clean worktree at the same Git revision used for the candidate build, checks the flake again without allowing implicit lock updates, updates `/etc/nixos/flake.lock`, and only then switches. If checking or switching fails, it restores the original lock file. Review and commit the successful lock-file change intentionally.

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

## Clipboard cutover

Ringboard and `clip-daemon` are the only clipboard-history capture stack. `Super+V` opens Shelllist; `Super+Shift+V` retains the old read-only `cliphist` picker as a one-release rollback shortcut. Existing `cliphist` history was intentionally not imported.

`wl-clip-persist` is intentionally disabled. Ringboard captures clipboard content before a source exits, so it remains selectable from Shelllist, but the live Wayland selection can be empty until that item is copied again.

To roll back the complete cutover, revert the clipboard-cutover commit and rebuild. This restores the `cliphist` watchers, `wl-clip-persist`, and the former shortcut assignment. Do not run the Ringboard and `cliphist` writers together beyond rollback diagnosis.

## Notes

- `hardware-configuration.nix` is machine-specific.
- Review `git diff` before committing or applying changes.
