# Personal Pi extensions: quality review and refactor

Measured 2026-10-27 with the local `/home/laufan/Projects/ts-react-quality-lens`.
Scope: all production TypeScript under `config/pi/`, including the new shared
helpers, plus the existing tests for verification. Bash/Nix/Python are not
TypeScript-lens analysis targets; the launcher and deployment configuration were
checked separately. No Pi core modifications.

Baseline: `a090ba7` **plus the pre-existing working-tree worker-dashboard changes**.
Those changes were preserved, not reset. Measurements used a disposable shared
Git clone with the working sources copied in and the installed Pi dependencies
linked at its root. Git history and compiler resolution were available. No npm
manifest was fabricated to make the package checks look successful.

## Measured results

| Production-source measurement | Before | After |
| --- | ---: | ---: |
| Source files, including shared helpers | 22 | 24 |
| Source lines (lens convention) | 3,081 | 2,983 |
| Collected functions | 120 | 136 |
| Cyclomatic complexity: total / maximum | 546 / 46 | 541 / 18 |
| Cognitive complexity: total / maximum | 555 / 49 | 478 / 20 |
| Halstead effort: total | 1,933,798.25 | 1,449,507.15 |
| Halstead effort: maximum | 288,387.01 | 132,061.95 |
| Clone groups (jscpd + AST) | 4 | 0 |
| Escape-hatch findings | 35 | 0 |
| Typed-lint warnings / blockers | 25 / 0 | 0 / 0 |
| Unused-export candidates | 4 | 0 |
| Compiler diagnostics | 0 | 0 |
| Type coverage | 99.41% | 99.70% |
| Untyped symbols | 30 | 15 |
| Dependency cycles / distant imports | 0 / 0 | 0 / 0 |
| High-risk hotspot records, including files | 30 | 30 |

Production lines fell by 98; maximum function complexity fell substantially and
aggregate effort fell about 25%. This is not a claim that all hotspots disappeared.

Including **all TypeScript and Python test code** under `config/pi/`, physical
lines went from **4,378 to 4,374**. That much smaller net reduction includes new
regression coverage; it does not exclude added helpers or tests. These physical
counts use `splitlines()`; the lens's production count includes the final empty
line of each file. Documentation and JSON/Nix configuration are not in that code
count. The Bash launcher is unchanged.

No thresholds, weights, suppressions or source exclusions were relaxed. Class
methods are not emitted as individual function hotspot records by this version
of the lens (for example, most sidebar/view methods); the function totals are
therefore not a complete complexity census. Halstead effort is a token-derived
estimate, not developer hours, and enclosing/nested functions can overlap.

## Changes selected from the findings

- **Worker attachment:** separate saved-session validation, continuation-option
  parsing and exclusive leasing. `prepareAttachment` drops from 46/49 to 17/16
  cyclomatic/cognitive complexity. Keep PID/process-group checks, model/session
  identity, isolated cwd checks, regular-file/read limits, no assignment replay,
  no second writer, and ownership-token-safe lease release.
- **Instance discovery:** separate process inspection, log-event interpretation
  and registry verification. `parseLog` cognitive complexity drops from 47 to 13;
  `scan` drops from 23 to 11. Bounded nonblocking reads, descriptor identity and
  post-read PID-start checks remain. Unknown/stale/log-only are still distinct.
- **Shared input validation:** replace unchecked casts/non-null assertions with
  small runtime guards for objects, arrays, strings and OS error codes. Required
  objects still fail closed; optional message content still has an empty fallback.
  RPC response data now uses the same non-array object guard as other record inputs.
- **Worker UI:** share theme, shortcut and clipping helpers; consolidate teardown
  without changing its clear-before-close ordering. Extract label packing and
  remove the unreachable unavailable-state branch behind the active-worker guard.
  `renderWorkerBox` falls from 19/34 to 5/4 cyclomatic/cognitive complexity.
- **Recent sessions:** remove unnecessary exports and duplicate sorting/group
  updates; validate stored metadata rather than asserting its shape. Centralize
  row selection and color fallback, and remove the redundant sidebar component
  wrapper. Retention accounting is separated from candidate selection, retaining
  protected sessions and retry/error accounting. `archiveExcess` falls from
  12/19 to 8/13 cyclomatic/cognitive complexity.
- **Terminal launching:** use the existing public error-or-undefined contract
  internally instead of converting it to/from an unused discriminated wrapper.
  No launch command, cwd fallback or success/error event was changed.

## Leverage and locality

The common `lib/data.ts` is used by **nine production modules**; `lib/tui.ts` by
two. Input guard fixes and worker rendering rules now have single implementations.
The observed-reuse leverage total rises **420 → 530**; shared hubs **3 → 4**.
The lens's leverage-risk sum falls **416 → 0**, driven by removal of escape
hatches, not proof that architectural risk is zero.

Locality-risk sum falls **446 → 392**. Direct source-to-test import associations
rise **16/22 → 21/24**. This reflects real tests for helpers, session metadata,
retention, navigation and launch-error handling, not measured execution coverage.
No distant imports or cycles were introduced. Historical churn was not changed.

The tradeoff is explicit: shared helpers add two modules, internal import edges
rise **42 → 53**, and public names **106 → 110** despite removing four unnecessary
exports. The added names are consumed; they replace repeated implementations.

## Verification and outstanding limits

Passed:

- TypeScript checking against the installed Pi 1.4.0 dependencies.
- All **37 Node tests**, including an isolated-HOME retention test. It verifies
  current/named/pinned/recent protection, per-project/global limits, byte counts,
  soft limits when protected sessions exceed policy, metadata and navigation.
- `instances-tui.py`, `worker-dashboard-tui.py`, and `multi-session-tui.py`:
  separate real Pi instances, report/chat navigation, Unicode/narrow resizing,
  session ownership, drafts, background work, reload and shutdown. Streaming uses
  deterministic local fixtures, not external model APIs.
- Nix syntax and an actual Nix-store copy loaded all three extensions via offline
  RPC in an isolated HOME; all three commands registered with sibling lib imports.
- `git diff --check`.

The old multi-session TUI test initially failed **on the untouched baseline**:
its startup assertion expected `2 review` in the automatically hidden idle box.
It now opens `/workers` to check that state before testing worker chat behavior.
This aligns the test with the user's existing visibility change rather than
reverting that change or dropping the state assertion.

Knip is installed but **cannot run without package.json**. Three unlisted-package
findings remain (`pi-coding-agent`, `pi-tui`, `@types/node`), supplied by the Nix
runtime rather than an npm manifest. The cleanup result is heuristic, not a
complete external dead-code certification. No execution-coverage, security-scan,
remote-instance or performance evidence was collected. High-risk hotspot count
remains 30; further refactoring should be evidence-led rather than score chasing.

Home Manager now takes all extension directories from the same `config/pi`
source tree and installs `lib/`, so relative sibling imports survive Nix-store
packaging. Keep that sibling directory if copying extensions manually. No rebuild
was activated, and no live session/worker was restarted or interrupted.

## Reproduction and artifacts

Persistent configuration: `config/pi/quality-lens.config.json`. It disables
implicit test execution (`test_command: null`); the tests above were run separately.
Generated output goes to the ignored `config/pi/target/quality/` directory.

For compiler-resolved analysis without installing npm dependencies into Nix config:

```sh
# Set PI_NODE_MODULES to the node_modules directory of the installed Pi package.
work=$(mktemp -d /tmp/pi-quality.XXXXXX)
git clone --shared /etc/nixos "$work/project"
cp -a /etc/nixos/config/pi/. "$work/project/config/pi/"
ln -s "$PI_NODE_MODULES" "$work/project/node_modules"
node /home/laufan/Projects/ts-react-quality-lens/dist/bin/ts-react-quality-lens.js \
  measure all --config "$work/project/config/pi/quality-lens.config.json"
```

The installed dependency directory used for this run was:
`/nix/store/k0m86xhl3i1slynvafwir7rqfcp86fs0-vendor-pi-coding-agent-1.4.0/lib/node_modules`.
Build the local lens with `npm run build` in its repository if `dist/` is absent.
Do not substitute a different Pi/npm dependency version when comparing results.

Full before/after JSON artifacts, source snapshots, original dirty diff, configs
and verification logs from this review are in:
`/tmp/pi-quality-review.MEf7Xy/` (temporary; this report retains the comparison).
