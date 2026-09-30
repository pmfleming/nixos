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
- **AI updates:** `packages/vendor-ai-tools` now owns vendor release discovery,
  independent checked Nix profiles, rollback holds and freshness checks. It does
  not use the system worker's host-flake/local-worktree preparation. Existing
  service/timer names and Shelllist's aggregate job record format are preserved;
  `ai-tools status` adds per-tool versions, check/activation times and failures.
  The legacy shared profile remains a bootstrap fallback, not an update target.
- **Cleanup:** update jobs no longer signal Waybar or require `procps`.

**Keep `config/hypr/monitors.lua`, its Home Manager link and its Lua import.**
Activated generations can reference the source through an out-of-store symlink;
deleting it breaks the live configuration before any new activation. A regression
check now protects this compatibility boundary.

## Validation and activation

For vendor AI packaging and real isolated update tests, see
[its validation record](packages/vendor-ai-tools/README.md#implementation-validation-2026-09-30).
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
