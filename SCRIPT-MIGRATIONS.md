# Script-to-daemon migrations

## Implemented

- **Screenshots:** `clip-daemon screenshot`, `--annotate`, and `--screen` replace
  the helper and Grim/wl-copy keybinding pipelines. The daemon owns publication,
  validation and operation cleanup; Slurp/Satty remain on-demand tools.
- **Display layouts:** `SUPER+P` or `shelllist open displays` opens the native
  editor. The daemon saves mode, scale, position and rotation settings, with a
  20-second confirmation deadline and durable rollback. External-only policy
  retains laptop fallback. The nwg-displays converter is removed; advanced
  mirroring/bit-depth controls are not provided by this editor and workspace
  rules remain declarative.
- **NixOS updates:** `/home/laufan/Projects/update-daemon` owns system quarantine,
  approval, deployment locks and next-boot staging. Those semantics are unchanged.
- **Rebuild manifests:** native unprivileged `update-worker source` operations
  replace the host Python helper. Existing manifest hashes and approval formats
  are preserved; the framework still owns source graph discovery/snapshotting.
- **AI updates:** `update-daemon` now owns native vendor release discovery,
  Nix packaging, independent checked profiles, rollback holds and freshness checks.
  Its vendor engine does not use the system lane's host-flake/worktree preparation. Existing
  service/timer names and Shelllist's aggregate job record format are preserved;
  `ai-tools status` adds per-tool versions, check/activation times and failures.
  The legacy shared profile remains a bootstrap fallback, not an update target.
- **Cleanup:** update jobs no longer signal Waybar or require `procps`.

**Keep `config/hypr/monitors.lua`, its Home Manager link and its Lua import.**
Activated generations can reference the source through an out-of-store symlink;
deleting it breaks the live configuration before any new activation. A regression
check now protects this compatibility boundary.

## Validation and activation

For vendor AI packaging and real isolated update tests, see `nix/VENDOR.md` and
`HOST-HELPERS.md` in `/home/laufan/Projects/update-daemon`. Host rebuild/locking tests
now invoke an explicitly configured native test driver, not the historical shell
updater oracle. The worker and manifest operations no longer require Python.
The following records the earlier desktop/daemon migration validation:

Rust tests/Clippy, QML tests/lint, protocol contracts, worker fake-process tests,
transaction/approval/deployment-lock regression tests, targeted Nix checks and
current-worktree host service evaluation passed. Tests did not run real updates,
change outputs, suspend, or activate a generation. Hardware docking/resume still
requires separate verification.

Use the documented `local-build check /etc/nixos` and `rebuild` workflow for a
coherent activation of the current worker/daemon/UI sources. Ordinary Nix
commands can resolve stale local locks; no new persistent local-project revision
pin was committed. Existing unrelated `flake.lock` edits were preserved exactly.
All migration changes were committed locally; nothing was pushed remotely.
