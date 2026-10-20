# Update/rebuild improvements: validation and rollout

Implemented in staged commits across `/etc/nixos`, `update-daemon`, and Shelllist:
failed-input suppression; stage telemetry/error summaries; baseline/source
explanations; batched source-owner inspection; combined checks/system builds;
read-only status, quiet output, incident notifications and a persistent bar indicator.

## Safety boundaries

- All checks and the system use the same frozen source graph.
- Cheap checks remain early; either aggregate build failure prevents switching.
- Activation uses the exact checked closure with `--store-path --no-reexec`.
  The VM test demonstrated that **without `--no-reexec`, nixos-rebuild still
  evaluates configuration to rebuild itself**, despite `--store-path`.
- Source overrides remain rejected. Deployment locks, successful-check GC roots,
  graphical recovery and final approval verification remain in place.
- Dirty sibling worktrees remain supported. Baseline prediction does not approve
  anything, and `--skip-baseline` cannot bypass a build/check gate.
- Rebuild outcomes and updater public status are display data, never deployment
  authorization. Unknown successful-build counts/legacy baseline age stay unknown.

## Evidence

- Rust workspace/all-target tests and Clippy with warnings denied passed.
- The opt-in real-Nix changed-source-graph regression passed.
- Rebuild fixture tests cover argument rejection, early gates, failed system and
  check builds, activation path/arguments, locks, recovery, cache retention,
  baseline flags, quiet/monitor output, timing/history and actionable errors.
- Telemetry tests cover concurrent writers and crash recovery without duplicate
  history. Source-command cancellation tests cover nested process groups.
- Nix-packaged worker, rebuild wrapper, `nix`, `shellcheck` and `rebuild-sources`
  checks were built and tested against disposable snapshots.
- The selected Shelllist MaterialBar Qt test passed, including persistent failure,
  interrupted/invalid status, recovery and checked-update presentation.
- The installed-style status command was exercised read-only against live state:
  five tools and four timers, with configuration drift correctly reported.
- The isolated bootloader-enabled VM tests real root approval of a 100-file repo,
  a bounded number of PAM sessions (three observed; maximum five asserted),
  approval refusal/preservation after an edit, and store-path switching to a
  distinct specialisation and back. Profile and active-system pointers must
  change, and an `/etc` marker must appear/disappear with activation. Switches
  run with a real bootloader enabled; rebooting into the generated entries is
  not tested.

Reproduce the optional VM test (not part of every rebuild's checks):

```sh
local-build build --attr lib.updateWorkflowVmTest /etc/nixos
```

A frozen-graph standalone `flake check --no-build` took **17 seconds** in the
initial measurement; source snapshotting by local-build took **1 second**. These
are individual observations, not a speedup claim. The standalone evaluation gate
remains: collect representative stage histories before removing validation.

No live host switch, boot staging, vendor update or approval was performed by this
implementation work. Tests activated only an isolated VM. A normal user-run
`rebuild` deploys the new commands, timers' worker binaries and Shelllist indicator.
The first update attempt under the new worker captures suppression metadata for
an existing failed tool; old status files cannot retrospectively prove the cause.
