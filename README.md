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

`rebuild` first rejects untracked Nix files, advances every machine-local `git+file` input to its committed branch head, then runs the complete flake checks before switching. Extra arguments are passed to `nixos-rebuild`.

## Validate Changes

Check the flake before applying it:

```sh
nix flake check /etc/nixos
```

## Automatic Updates

The updater has two independent lanes:

- `nixpkgs-unstable`, which supplies Codex, Pi, Claude, and T3 Code, is checked every six hours and has no quarantine.
- Remote root inputs other than `nixpkgs-unstable` are checked daily. The first discovered lock snapshot is frozen for three days before it may be built and applied. New upstream changes do not restart that clock.
- Scheduled update lanes never advance machine-local `git+file` development inputs. Every manual `rebuild` advances all of them together before validation; use `nix flake update <input>` only when intentionally staging one input without rebuilding yet.

Both scheduled lanes run only on AC power. Persistent timers cover missed calendar runs, and a lightweight 15-minute catch-up timer retries overdue or previously blocked checks after AC power becomes available. Candidate discovery, `nix flake check`, the complete system build, and application all run as root so the trusted updater state remains root-owned. `/etc/gitconfig` trusts only the exact deployment and machine-local repositories needed to evaluate their pinned revisions.

Successful scheduled candidates are applied automatically when `/etc/nixos` is safe and its committed revision was approved by a successful manual `rebuild`. A clean checkout is safe; a checkout whose only change is a `flake.lock` written by the updater is also safe. Any user-authored or unrelated change leaves the candidate pending. A lock-only commit matching the root-recorded result of an automatic application advances approval automatically; every other committed configuration change requires another manual rebuild. Fast and delayed candidates have separate slots, and applying either lane invalidates a stale build from the other lane. A matured delayed candidate refreshes `nixpkgs-unstable` before building, so it cannot downgrade the AI tools.

The updater stages the root-approved committed `HEAD` outside `/etc/nixos`, records the exact revision and baseline lock hash, runs all flake checks, and builds with limited Nix parallelism and low CPU/I/O priority. Before switching, the root apply service independently evaluates the candidate lock and requires its result to match the saved prebuilt system. Application uses a persistent transaction; interrupted operations are finalized or rolled back on the next updater run.

### Manual command reference

Stage either update scope immediately:

```sh
# Discover or build the quarantined remote-input lane for manual approval.
sudo systemctl start nixos-update-check-all.service

# Build the immediate AI-tools lane for manual approval.
sudo systemctl start nixos-update-check-apps.service
```

Inspect pending state independently for each lane:

```console
sudo diff -u /etc/nixos/flake.lock /var/lib/nixos-delayed-updates-v2/fast/ready-flake.lock
sudo diff -u /etc/nixos/flake.lock /var/lib/nixos-delayed-updates-v2/delayed/ready-flake.lock
sudo cat /var/lib/nixos-delayed-updates-v2/delayed/first-seen
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

Review and commit successful automatic `flake.lock` changes intentionally. Lock-only commits that exactly match the root-recorded automatic result retain approval. After any other commit, run `rebuild` once to approve that exact revision for future automatic lock updates. Pre-existing uncommitted lock changes are treated as user-authored and block application.

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
