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
