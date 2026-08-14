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

The updater has two independent lanes:

- `nixpkgs-unstable`, which supplies Codex, Pi, and Claude, is checked every six hours and has no quarantine.
- Every other root flake input is checked daily. The first discovered lock snapshot is frozen for three days before it may be built and applied. New upstream changes do not restart that clock.

Both scheduled lanes run only on AC power. Persistent timers cover missed calendar runs, and a lightweight 15-minute catch-up timer retries overdue checks after AC power becomes available. Candidate discovery, `nix flake check`, and the complete system build run as `laufan`, allowing the updater to read the user-owned `git+file` development inputs. Only installation of the checked lock and prebuilt system runs as root.

Successful scheduled candidates are applied automatically when `/etc/nixos` is safe. A clean checkout is safe; a checkout whose only change is a `flake.lock` written by the updater is also safe. Any user-authored or unrelated change leaves the candidate pending. Fast and delayed candidates have separate slots, and applying either lane invalidates a stale build from the other lane. A matured delayed candidate refreshes `nixpkgs-unstable` before building, so it cannot downgrade the AI tools.

The updater stages committed `HEAD` outside `/etc/nixos`, records the exact revision and baseline lock hash, runs all flake checks, and builds with limited Nix parallelism and low CPU/I/O priority. Switching uses that exact prebuilt system. A failed switch restores the prior lock and system profile.

### Manual command reference

Stage either update scope immediately:

```sh
# Discover or build the quarantined lane without applying it automatically.
sudo systemctl start nixos-update-check-all.service

# Build the immediate AI-tools lane without applying it automatically.
sudo systemctl start nixos-update-check-apps.service
```

Inspect pending state independently for each lane:

```console
sudo diff -u /etc/nixos/flake.lock /var/lib/nixos-delayed-updates/fast/ready-flake.lock
sudo diff -u /etc/nixos/flake.lock /var/lib/nixos-delayed-updates/delayed/ready-flake.lock
sudo cat /var/lib/nixos-delayed-updates/delayed/first-seen
```

Apply one lane or every ready candidate explicitly:

```sh
sudo systemctl start nixos-update-apply-fast.service
sudo systemctl start nixos-update-apply-delayed.service
sudo systemctl start nixos-update-approve.service
```

Inspect the timer and recent updater output when troubleshooting:

```sh
systemctl list-timers nixos-update-fast.timer nixos-update-delayed.timer
systemctl list-timers nixos-update-catchup.timer
journalctl -u nixos-update-fast.service -u nixos-update-delayed.service -n 100 --no-pager
journalctl -u delayed-nixos-update.service -n 100 --no-pager
journalctl -u nixos-update-check-all.service -u nixos-update-check-apps.service -n 100 --no-pager
journalctl -u nixos-update-apply-fast.service -u nixos-update-apply-delayed.service -n 100 --no-pager
```

Review and commit successful automatic `flake.lock` changes intentionally. Until the first clean automatic application, pre-existing uncommitted lock changes are treated as user-authored and block application.

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

Ringboard and `clip-daemon` are the only clipboard-history capture stack. `Super+V` opens Shelllist; `Super+Shift+V` retains the previous `cliphist` picker as a one-release rollback shortcut. Existing `cliphist` history was intentionally not imported.

`wl-clip-persist` is intentionally disabled. Ringboard captures clipboard content before a source exits, so it remains selectable from Shelllist, but the live Wayland selection can be empty until that item is copied again.

To roll back the complete cutover, revert the clipboard-cutover commit and rebuild. This restores the `cliphist` watchers, `wl-clip-persist`, and the former shortcut assignment. Do not run the Ringboard and `cliphist` writers together beyond rollback diagnosis.

## Notes

- `hardware-configuration.nix` is machine-specific.
- Review `git diff` before committing or applying changes.
