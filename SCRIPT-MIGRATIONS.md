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
- **Updates:** `/home/laufan/Projects/update-daemon` owns the privileged finite
  worker and private transaction helpers. Existing service/timer names remain;
  Shelllist reads structured progress, failures and AI-tool freshness. Quarantine,
  approval, deployment locks and next-boot-only system staging remain intact.
  AI-profile updates and freshness checks are now native Python, not a private
  Bash helper. The system quarantine/approval/rollback transaction is the remaining
  updater Bash implementation; it is deliberately unchanged in this step.
- **Cleanup:** update jobs no longer signal Waybar or require `procps`.

**Keep `config/hypr/monitors.lua`, its Home Manager link and its Lua import.**
Activated generations can reference the source through an out-of-store symlink;
deleting it breaks the live configuration before any new activation. A regression
check now protects this compatibility boundary.

## Validation and activation

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
