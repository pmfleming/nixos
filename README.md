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

## Validate Changes

Check the flake before applying it:

```sh
nix flake check /etc/nixos --no-build
```

## Automatic Updates

`delayed-nixos-update.service` runs overnight at approximately 03:00, only on AC power. The timer is persistent, so a missed run is attempted after the next boot. An AC-only catch-up timer also checks every 15 minutes whether the latest overnight run was missed, covering a laptop that booted on battery and was plugged in later. Successful full-input checks are recorded; expensive catch-up retries after failures or a dirty worktree are limited to once per hour.

The updater skips dirty worktrees, stages the committed checkout outside `/etc/nixos`, updates the candidate lock, runs `nix flake check --no-build`, and builds the candidate with limited Nix parallelism and low CPU/I/O priority. It never changes the live lock file or switches generations.

### Manual command reference

Stage either update scope immediately:

```sh
# Update every flake input.
sudo systemctl start nixos-update-check-all.service

# Update only nixpkgs-unstable, which supplies Codex, Pi, and Claude.
sudo systemctl start nixos-update-check-apps.service
```

Both commands only check and build a candidate; neither switches the running system. There is one candidate slot, so a successful later staging command replaces the earlier candidate.

When `/run/nixos-updates-available` exists, review the candidate:

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
journalctl -u delayed-nixos-update.service -n 100 --no-pager
journalctl -u nixos-update-catchup.service -n 100 --no-pager
journalctl -u nixos-update-check-all.service -u nixos-update-check-apps.service -n 100 --no-pager
journalctl -u nixos-update-approve.service -n 100 --no-pager
```

The approval service requires a clean worktree at the same Git revision used for the candidate build, checks the flake again without allowing implicit lock updates, updates `/etc/nixos/flake.lock`, and only then switches. If checking or switching fails, it restores the original lock file. Review and commit the successful lock-file change intentionally.

## Generation Retention

`prune-nixos-generations.service` runs daily and retains the newest five generations, the newest generation from each of the current and previous seven ISO weeks, and the newest generation from each of the current and previous eleven calendar months. These sets may overlap. The current, running, and booted systems are always protected. Older generation links are deleted before `nix-store --gc` runs.

## Notes

- `hardware-configuration.nix` is machine-specific.
- Review `git diff` before committing or applying changes.
