# ThinkPad NixOS configuration

The live flake in `/etc/nixos` targets `thinkpad` (`x86_64-linux`), user `laufan`, with NixOS/Home Manager 26.05 inputs. Home Manager is integrated into the system rebuild.

## Layout

| Path | Purpose |
| --- | --- |
| `flake.nix`, `checks.nix` | Inputs, machine identity, outputs and deployment gates |
| `configuration.nix`, `home.nix` | System and desktop-session policy |
| `hardware-configuration.nix` | Machine-specific hardware settings |
| `modules/`, `lib/` | Update, retention, printer, display and shared integration |
| `config/`, `theme.nix` | Application configuration, scripts and theme substitutions |
| `update-daemon` local input | Native rebuild manifests, system updates and independent vendor-tool packaging/updates |

## Build and deploy

```sh
rebuild
```

For validation without activation, use `local-build check /etc/nixos`. To switch to the previous system generation, use `rollback`.

Use `rebuild`, not direct `nixos-rebuild --flake`: the wrapper owns source selection, checks, deployment locking, session recovery and unattended-update approval.

Local inputs are current Git worktrees under `/home/laufan/Projects`, including tracked uncommitted edits. Register new files with `git add` or `git add -N`; rebuild reports untracked files before sudo and never stages them itself. The native framework helper snapshots each worktree once and revalidates after authentication. Checks and deployment reuse that frozen graph even if editing continues. It does not fetch, push, change branches or update live local-project pins.

**All five domain daemons share one current `daemon-framework` snapshot.** Vendored frameworks and per-daemon revision pins are rejected. Persistent locks retain remote dependencies; ordinary Nix flake commands can recreate unwanted local pins.

If the installed wrapper predates the current integration, bootstrap from source:

```sh
/home/laufan/Projects/daemon-framework/tools/local-build run --attr rebuild /etc/nixos
```

The checkout launcher requires Cargo/Rust, Git and Nix. The installed native `local-build` needs neither Cargo nor Python and also supports `build` and `develop` for individual projects.

### Checks, caching and recovery

Rebuild evaluates the frozen flake without building, runs cheap configuration/TypeScript checks, then builds `rebuildChecks`: every host check, the full Shelllist contract matrix, framework/daemon tests and reusable Rust dependencies. Successful checks precede the system switch. With a graphical session active, it restarts Shelllist and all five daemons even when their unit files are unchanged.

Interactive rebuild and Nix daemon defaults are **two jobs, eight cores**. Updater services explicitly use **one job, two cores**. Rebuild accepts `-j`/`--max-jobs N|auto`, `--cores N`, verbosity/logging flags, `--show-trace`, `--keep-going`, `--keep-failed`, `--fallback`, `--repair` and `--offline`. Keep-going is opt-in. Source overrides, arbitrary `--option`, remote deployment and rollback arguments are rejected; use the separate rollback command.

Crane caches compiled dependencies for the daemons, framework tools/tests and Scratchpad. Filtered sources avoid rebuilding them for unrelated documentation changes. The last two **distinct successful** check aggregates and dependency outputs remain GC-rooted in `$XDG_STATE_HOME/nixos-rebuild/check-cache` (default `~/.local/state/nixos-rebuild/check-cache`). Failed checks preserve previous entries. Remove that directory only while no rebuild is running to release its roots; changed derivations still require checks.

Rebuild, rollback, unattended system staging and generation pruning share `/run/lock/nixos-deployment/lock`. Interactive contention exits 75; timer jobs skip. Direct `nixos-rebuild` bypasses this coordination. Host scripts bind helper paths and the deployment-lock path at build time; environment variables cannot substitute them. Tests render private script fixtures instead (`config/scripts/tests/render-deployment.sh`).

Logs live in `~/.local/state/nixos-rebuild/` (or `$XDG_STATE_HOME/nixos-rebuild/`). `latest.log` identifies the newest attempt, not necessarily the running one; `latest-failed.log` identifies the latest failure. Completed logs end in `.success.log` or `.failed.log`; logs older than 30 days are pruned on subsequent runs. Skipped baseline approval after a successful deployment exits zero and reports **SUCCESS WITH WARNINGS**, with the reason in the log.

## Automatic updates

Two independent lanes separate tool activation from system deployment. Finite systemd jobs publish status under `/var/lib/nixos-delayed-updates-v2/jobs/`; Shelllist displays progress/failures and links journals. A completed release check is not proof of installation.

### AI tools: independent vendor releases

Claude Code, Codex, Pi and T3 Code check official non-prerelease releases every **15 minutes**, including on battery, with boot/resume catch-up. Claude uses its latest public release channel, not its deliberately delayed `stable` channel. Availability within roughly an hour awake/online is a target, not a guarantee.

Each tool has separate checked packages, current/previous profiles and GC roots under `/var/lib/nixos-ai-tools/vendor/<tool>/`. Downloads require vendor hashes; sandboxed smoke checks precede activation. Pi extension tests gate only Pi; T3 includes CLI and desktop. Failures are isolated and existing sessions are untouched. Hashes trust vendor accounts, not independent publisher signatures.

The updater imports deployment-pinned packaging inputs directly: no host flake evaluation, Git inspection, OS approval, host-lock mutation or NixOS switch. PATH launchers prefer the independent profile, then the retained legacy shared profile, then immutable bootstrap packages. Vendor releases need no rebuild; recipe/support-input or deployed Pi-extension changes do. After initially deploying launcher PATH changes, start a fresh login session.

```sh
ai-tools status --json
sudo ai-tools check                 # Discover only
sudo ai-tools update claude          # Update one tool
sudo systemctl start nixos-ai-tools-update.service  # Update all tools
sudo ai-tools rollback pi            # Restore previous profile and hold updates
sudo ai-tools resume pi              # Release that hold
journalctl -u nixos-ai-tools-update.service -n 100 --no-pager
```

Hourly stale checks retry/wait before warning about checks older than four hours; notifications are limited to once per six hours. The native `ai-tools` command and recipes are owned by `/home/laufan/Projects/update-daemon`; its `nix/VENDOR.md` runbook covers trust boundaries, isolated validation and recovery. There is no production configuration-file override or Python updater.

### NixOS: quarantined remote inputs, next-boot activation

The Rust `update-worker` from `update-daemon` handles this lane. Automatic discovery runs daily on AC, with a 30-minute overdue-check catch-up timer. Remote lock candidates wait **three days** before checked builds against the approved configuration baseline. `nixpkgs-unstable` refreshes at candidate build time; vendor launchers still shadow its fallback tools.

Local projects are snapshotted afresh, never deployed from persistent revision pins. Before applying, the worker re-evaluates current local sources; a changed resulting system invalidates the candidate. Successful staging updates the live lock/system profile and runs `switch-to-configuration boot`, not `switch`: the graphical session remains untouched until reboot.

The unprivileged `update-worker source` commands capture and verify rebuild manifests; privileged approval invokes verification as the source owner. Manifest v1 remains compatible with the former Python helper. Rebuild approval binds the captured configuration revision, source identity, original lock and active system. `/etc/nixos` must be clean except for `flake.lock`; dirty or unpushed sibling projects are supported. Configuration/lock changes during the build, or remote-pin changes during disposable resolution, prevent new approval without undoing a successful deployment. Refusal preserves existing approval and pending transactions. After committing configuration changes, rebuild again to establish the matching baseline; review and commit automatic lock changes intentionally.

```sh
# Discover/build a matured candidate without applying it.
sudo systemctl start nixos-update-check-all.service
# Stage an already-built candidate for next boot.
sudo systemctl start nixos-update-apply-delayed.service
systemctl list-timers nixos-update-delayed.timer nixos-update-delayed-catchup.timer
journalctl -u nixos-update-delayed.service \
  -u nixos-update-delayed-catchup.service -n 100 --no-pager
sudo diff -u /etc/nixos/flake.lock \
  /var/lib/nixos-delayed-updates-v2/delayed/ready-flake.lock
```

The automatic job combines discovery and conditional staging; there is no separate OnSuccess apply chain. Native approval and recovery use `approval.json` and `transaction.json` in the state directory. Do not mix worker generations during a pending transaction; legacy `apply-transaction/` state must be recovered with the previous worker before migration. Update jobs perform real operations, not smoke tests.

## Desktop and hardware

- **Session:** Hyprland runs through UWSM. Keep package-owned daemon units and their shared graphical-session drop-in; do not duplicate lifecycle commands in Home Manager.
- **Shelllist:** the only bar/frontend. `Super+M` toggles Media via the binding in `config/hypr/hyprland.lua`. `bar-daemon` owns `org.freedesktop.Notifications` and persistent notification history; no separate notification server or Waybar is deployed. Captive-portal desktop entry opens Wi-Fi controls; browser launch requires a daemon-approved intent.
- **YouTube media:** `programs.shelllist.media.youtubeMetadata.enable = true` opts the managed `bar-daemon` into oEmbed lookups for missing title, channel and artwork. Requests disclose recognized video IDs to YouTube, without browser cookies or extensions. Existing browser metadata and playback controls remain authoritative; unavailable/restricted videos keep their fallback. Rebuild deploys both the daemon and Shelllist UI; no persistent local-input pins are needed.
- **Chrome audio apps:** `modules/home/desktop-entries.nix` provides Audible UK and Pocket Casts launcher entries. Audible uses forced dark rendering; Pocket Casts uses its own theme setting without Chrome dark-mode overrides. Each uses Chrome app-window mode and a separate data directory under `$XDG_DATA_HOME/chrome-web-apps/` (default `~/.local/share/chrome-web-apps/`). Sign in separately on first launch; regular Chrome logins are not copied. Separate browser processes expose independent MPRIS players after playback starts. Official app icons are installed locally in the hicolor theme for both the launcher and media chooser (sources in `assets/audio-icons.md`). Launcher environment hints let `bar-daemon` label them Audible/Pocket Casts; title, author/host, artwork and controls still come from each site's Media Session support. Forced dark rendering can alter site colours. This does not add offline playback or bypass subscriptions. The earlier shared-profile force-install policy is removed; if it was deployed, reload Chrome policies and remove any old Chrome-created app shortcuts to avoid duplicate launchers.
- **Clipboard:** `Super+V` opens Shelllist over `clip-daemon` and its policy-enabled Ringboard. Use package-owned units, not stock `pkgs.ringboard-wayland`, which lacks safe mutation support. Back up history before engine changes; startup applies retention limits.
- **Display recovery:** the 6.18 LTS kernel, Hyprland/Aquamarine, matching portal and both Mesa architectures come from `nixpkgs-display`, independently of the base OS pin. Experimental specialisations are retired. See [HDMI rollout/recovery](HDMI-RECOVERY-ROLLOUT.md).
- **Hibernate:** a 64 GiB `/swapfile` supplements zram; systemd initrd uses the UEFI HibernateLocation mechanism. The root filesystem and hibernated memory are unencrypted.
- **Input access:** the user is deliberately outside `input`; logind provides session-scoped access. Use narrow device rules for exceptions. Reboot after removing group membership to revoke existing processes' supplementary groups.

Some Hyprland files, including `config/hypr/monitors.lua`, are writable out-of-store links. Preserve their targets and compatibility links during migrations; see [sleep recovery](SLEEP-RECOVERY.md) for troubleshooting.

## Epson network printer

`modules/printers.nix` declares `Epson_ET_2950`: driverless IPP Everywhere at `ipps://EPSON4C18B4.local:631/ipp/print`, A4, unshared, retrying failed jobs. No fixed IP or printer password is stored. Existing queues/default selection are unchanged. Setup runs asynchronously with a 45-second timeout and two-minute retries, so an offline printer does not block activation.

The trusted `rembrandtweg` NetworkManager profile needs resolve-only mDNS. This is machine-local state, not a flake-managed credential/profile. If recreating it:

```sh
nmcli connection modify rembrandtweg connection.mdns 1
nmcli device reapply wlp2s0
resolvectl query EPSON4C18B4.local
systemctl status ensure-printers.service ensure-printers.timer
lpstat -p Epson_ET_2950 -v
lpoptions -d Epson_ET_2950          # Optional personal default
```

Do not enable discovery on unrelated networks. Existing systemd-resolved handles it; Avahi and incoming CUPS firewall ports are unnecessary.

## Retention and secrets

Daily generation pruning covers the system, Home Manager and user `profile`. It retains the newest five generations plus the newest in each of eight ISO-week and twelve calendar-month buckets, including current periods. Active/profile targets remain protected. Boot entries refresh from the system profile, preserving next-boot staging. Weekly Nix GC removes unreferenced paths separately.

`sops-nix` decrypts the login password hash from `secrets.yaml`; users are declaratively managed. Back up the Age identity securely outside Git and restore it before a fresh installation's first rebuild. Its required location is `/var/lib/sops-nix/key.txt`, owned by `root:root`, mode `0600`:

```sh
sudo install -d -m 0700 -o root -g root /var/lib/sops-nix
sudo install -m 0600 -o root -g root \
  "$HOME/.config/sops/age/keys.txt" /var/lib/sops-nix/key.txt
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  nix shell nixpkgs#sops -c sops secrets.yaml
```

The copy command migrates an existing user-owned identity. Remove that old copy only after successful rebuild/decryption. Fingerprint enrollment is machine-local; re-enroll after password login works.
