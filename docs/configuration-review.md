# Configuration refactor — 2026-10-30

Scope: `/etc/nixos`, including its deployment scripts/tests. The baseline was the
working tree at review start, including the pending Ringboard-removal fixes.
Sibling application implementations and personal extension implementations were
not refactored. No activation or automatic commit is part of this review.

## Findings and changes

- **Mixed exit-handler responsibilities:** `rebuild.sh` parsed build events already
  parsed by `rebuild-report.py`, then rendered a second representation of the same
  run. The shell now owns cleanup, locks, logger drainage, final log naming and
  exit status; the report helper owns event parsing, final telemetry, presentation and
  history publication. One event list drives both human counts and JSON history.
- **Scattered desktop ownership:** `modules/home/session.nix` owns daemon units,
  session services and idle policy. `modules/home/file-associations.nix` owns both
  MIME defaults and ordered Yazi routing. `yazi.nix` retains openers and styling.
  Package-owned service definitions remain authoritative, not copied into Nix.
- **Repeated test data:** independent application-inventory fixtures now live
  beside other tests, using small record constructors. The exact-output,
  deduplication, override-priority and host assertions are retained.
- **Unconditional overwrite:** five immutable Home Manager registrations no longer
  set `force = true`; a check guards this. Explicit writable monitor/workspace and
  VS Code settings retain their existing migration behaviour. Standalone launcher
  and icon sources are copied independently of the entire flake source hash.
- **Dead validation path:** removed the unreferenced `rust-cache-identity.py`.
  Its hand-built input graph omitted bar-daemon's required `updateWorker` input;
  it was not an active deployment gate. No active check or opt-in VM test was
  removed. Current documentation no longer advertises Ringboard, an obsolete
  Shelllist option, or the deleted HDMI runbook.

## Measurements

| Measure | Before | After |
| --- | ---: | ---: |
| Lines in affected code and tests, including added/deleted files | 2,147 | 2,043 |
| `home.nix` / `checks.nix` lines | 511 / 551 | 307 / 395 |
| Rebuild exit-handler lines | 124 | 53 |
| Exit-handler cyclomatic proxy / nesting-weighted branch score | 35 / 40 | 10 / 9 |
| Maximum Bash function cyclomatic proxy | 35 | 19 |
| Exit-handler lexical Halstead effort estimate | 315,101 | 39,500 |
| Maximum reporting Python function cyclomatic complexity (Radon) | 12 | 12 |
| Explicit `force = true` declarations in `home.nix` | 6 | 1 |

The shell proxies count tree-sitter Bash if/elif/loop/case-arm and `&&`/`||`
branches, with nesting penalties for the weighted score. Effort uses Pygments
operator/operand tokens and Halstead's D×V formula. These are reproducible
structural estimates, **not** Sonar scores or measured engineering hours. The
reporting code grew; the aggregate reduction includes tests and the removed stale
harness, rather than hiding moved code. Documentation is excluded from code LOC.

## Validation boundaries

Compare evaluated packages, user services/timers, idle policy, MIME associations
and Yazi settings before/after using the same frozen inputs. Source-path hash
changes alone are not behavioural differences. Rebuild tests exercise failures,
argument rejection, source freezing, lock contention, recovery, signals and logger
cleanup. Report tests cover concurrent publication, partial history, unavailable
telemetry, warnings, copied paths, negative deltas and byte-format boundaries.
Run `local-build build --attr rebuildDeployment /etc/nixos` plus `rebuildPreflight`
for the complete build-only validation; `rebuild` is still required to activate.

Validation completed: the refactored configuration's full deployment/preflight
build passes with the known-good frozen sibling graph, and current-graph flake
evaluation passes. A full build against current siblings is blocked independently
by `bar-daemon`'s `agenda-turso-contract`: `src/activity/agenda_store/migration.rs:2`
cannot resolve `super::super::model::TodoItem`. Remaining compilation was stopped
after that error; no claim is made that the current full graph passes.

The remaining largest Bash function is the strict argument parser (proxy 19).
Its allowlist, deployment locks, privilege boundaries and recovery precedence were
not traded for generic command passthrough. Deliberate D-Bus/printer `mkForce`
overrides and writable editor/layout files remain explicit integration policy.
