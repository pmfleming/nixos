# Storage and update implementation

Implement in independently validated commits; preserve unrelated worktree edits.

1. Qualify the pending public observation reader and version provenance changes.
   Root-owned update observations must reach unprivileged consumers without
   granting write access to the database or silently accepting stale legacy data.
2. Extend the application catalog with explicit update ownership and release
   coverage; repair Applications/System presentation and distinguish observation
   failures, unsupported products, local builds and upstream/channel versions.
3. Introduce a Rust storage domain using the shared current daemon framework.
   Inventory allocated bytes, deduplicate hard links, identify generated Cargo
   profiles in custom build trees and supported shared caches, and plan cleanup
   against aggregate budgets and age. Protect source, worktrees and active builds.
4. Expose session inventory, explicit scans, cleanup, cancellation, policy and
   history to a dedicated QML Storage panel reachable from Updates. Use the same
   native engine for a bounded unprivileged shutdown worker; shutdown is the
   default automatic deletion trigger and needs no desktop session.
5. Migrate host wiring and remove the old Python cleanup implementation, tests,
   packaging and duplicated project callers. Qualify the integrated source graph.

Initial storage policy: 64 GiB project generated-cache budget, 8 GiB shared-cache
budget, 24-hour warm-artifact protection, 14-day inactive artifact expiry and
30-day completed-run log retention. Budgets are soft when content is protected.
Unknown ownership/activity is preserved and explained. User source and Git
worktrees are never deleted merely because their parent is called target.

The updater retains ownership of vendor generations, rollback roots and locks.
Nix garbage collection and system temporary-file cleanup keep their owners.
Storage reports those areas without claiming every allocated byte is reclaimable.
New domain policy and tests are Rust; UI is QML; deployment remains declarative
Nix. Existing generated protocol bindings remain framework-owned.

Acceptance includes native filesystem race/lock tests, the real unprivileged
observation boundary, actual Qt interaction tests, bounded rendering, explicit
unknown/stale states and coordinated Nix module/package validation. No test may
delete actual project artifacts. Deployment and first live cleanup are separate
from source validation and their outcomes must be reported explicitly.

## Implementation record

The existing observation-reader and version-provenance work was reviewed and
incorporated in update-daemon `227d364` and Shelllist `11c804a5`. The requested
Hyprland placement change is committed here as `51a3436`.

Update ownership/release states are implemented in app-daemon `a225066`, with
additional Android Studio/Electrum release readers and reviewed desktop identities
in update-daemon `07c945d`. Shelllist `a6a4c42e` adds route/status filters, explicit
missing-release states and wider system-version presentation. These observations
describe upstream releases; they do not promise that the configured Nix inputs
already contain them. Vendor profile and generation versions remain distinct.

The new sibling storage-daemon starts at `c43cb87`; `74c7823` adds Nix packaging,
the session service, periodic measurement and bounded shutdown worker. Follow-up
commits qualify the real JSONL bridge, handle Cargo hard links correctly, bound
cleanup bookkeeping and reject ambiguous pin paths. Shelllist `2c9b5f70` supplies
the dedicated Storage surface and an Updates entry point. `shelllist storage`
opens it directly. No new cleanup domain code or tests depend on Python.

Legacy Python cleanup modules/tests and active per-project copies/callers are
removed, including the duplicate Shelllist xtask policy (`294f73d2`).
The old persistent shutdown unit has an inert replacement without ExecStop,
preventing the first reboot from invoking the previously armed Python cleaner.
Historical review checkouts remain intact. The new cleanup engine protects their
source and Git worktrees while recognizing generated Cargo profiles beneath them.

Operational limits: shutdown consumes the most recent measured candidates and
revalidates each one; it does not rescan the disk during shutdown. The read-only
inventory timer runs after boot and every twelve hours. No inventory means no
automatic deletion yet. Budgets remain soft for protected data. Unmarked logs and
reports are measurement-only; completed log batches require the producer protocol
documented in storage-daemon/contracts/storage.md. Nix GC, system temporary-file
retention, journals and updater rollback generations keep their existing owners.

Validation recorded during implementation: the unprivileged observation boundary,
application release/catalog Rust tests and strict Clippy passed. Storage filesystem
fixtures and a private real D-Bus/JSONL session passed; all filesystem effects used
temporary test directories. Strict QML lint and the full native QML suite passed
with 762 passes, zero failures and one existing renderer skip. The native build
input audit includes storage-daemon and passes with the shared Rust 1.95.0/dependency
policy. Storage's Nix package and host evaluation passed. The final integrated
`rebuildChecks` build passed against the frozen current-source graph prepared by
daemon-framework's `tools/local-build`:

```sh
nix build path:/tmp/storage-retirement/root#rebuildChecks \
  --no-update-lock-file --no-link --keep-going
```

The resulting check closure is
`/nix/store/yfwxv6yj54m7ll17zxf0v5ghnlnbcmgm-rebuild-checks`.
It includes packaged daemon tests, the full QML suite (762 passed, zero failed,
one existing skip), native application/CLI tests, generated protocol contracts,
D-Bus discovery, Nix formatting and host/module evaluation. The transient build
log is `/tmp/storage-retirement-build.log`; Nix retains individual derivation logs.

No system switch or live cleanup was performed as part of source qualification.

## Review follow-up

The eleven findings from the subsequent review were addressed in isolated commits:

| Finding | Solution and commits |
| --- | --- |
| 1. Tool-name false positives | Exact executable/script/module identities and Gradle JVM arguments; Nix wrapper names supported. storage-daemon `f6dc4ca`, `d8b5f4c`. |
| 2. Activity protection persisted into shutdown | Separate temporary activity from structural/source protection; shutdown retries native locks and activity checks. Manual cleanup still intersects the displayed selection. `f6dbe9f`. |
| 3. Policy changes erased inventory | Retain measured identities, replan and change the preview revision; unchanged policies are no-ops. `e52ed37`. Shelllist avoids unchanged pin writes: `ce5ca0fc`. |
| 4. Operation-lock contention | Start/read during external work, defer interrupted-run recovery, yield scheduled inventory and hold one lock across cleanup plus refresh. `bdec940`. |
| 5. System observations masked inventory health | Separate measurement budgets (100,000 entries/five seconds per root, thirty seconds total), partial coverage and private-path counts. `f475b28`; Shelllist `5ba9b2e5`. |
| 6. Repeated directory resolution | Reuse one measured parent descriptor per file group; bound descriptor use and retain no-follow opening and per-file identity checks. `2b5157c`. |
| 7. Unstable fingerprints | Fixed FNV-1a/64 and explicit byte encoding, with fixed vectors. `1588e95`. |
| 8. Read-only lock data | Preserve Cargo output lock data and known language lock manifests inside shared caches without requiring write access; retain real native locks. `565a79b`, `6583abb`. |
| 9. Missing cache coverage | Recognize arbitrary Cargo profile names, doc/criterion outputs, registry archives/extracted crates, locked-project node_modules and versioned Playwright downloads. Native Cargo locks and explicit layouts gate deletion; dependency/browser symlinks are unlinked without traversal. `b79e966`. Quality-run evidence is measured separately and preserved: `7ff4583`. |
| 10. Version/status/history presentation | All release states can be filtered, combined filters match the same installation, and history exposes visible skip reasons: Shelllist `217b90f9`. Numeric trailing zeros compare equally: app-daemon `f551d36`. |
| 11. Missing regression coverage | Full temporary-directory scan/plan/delete fixtures for npm/Gradle/pip/bun and the added dependency/browser caches, controlled and real process observations, native lock contention and shutdown after tools exit. `7103f49`, plus regressions alongside the individual fixes. |

Coverage is deliberately explicit: Cargo registry indexes/Git checkouts and
Playwright's .links metadata retain their owners. Existing quality-run summaries,
source patches and frozen review reports are evidence, not an inferred completion
signal. Their usage is shown separately; generated Cargo profiles inside those
trees remain eligible independently. No real project artifacts were removed.

Review validation: strict Clippy and storage Rust tests passed. Strict QML lint
passed, the UI composition review reported no new numeric overrides or wrappers,
and the complete native QML suite passed with 765 passes, zero failures and one
existing renderer skip. The integrated Nix follow-up build passed, including the
packaged QML suite with the same result. After the shared-cache lock-manifest
follow-up, final qualification also passed:

```sh
nix build path:/tmp/storage-review-final/root#rebuildChecks \
  --no-update-lock-file --no-link --keep-going
```

Final check closure: `/nix/store/n5rq8f41fa1zkz6lj2wn5h4dq6axz6bd-rebuild-checks`.
Storage's packaged tests passed (7 unit, 15 filesystem, 2 service and 1 private
session-bus tests; the two helper child cases are explicitly invoked by their
parent tests). App-daemon's package, generated protocol/frontend contracts,
native application/CLI, module/host and D-Bus discovery checks passed too.
Transient logs are `/tmp/storage-review-final-build.log` and
`/tmp/storage-review-full-qml.log`; Nix retains individual derivation logs.

Unrelated in-progress Scratchpad edits were left untouched. Source fixes are
committed independently of deployment. No system switch or live cleanup was
performed during this review follow-up.
