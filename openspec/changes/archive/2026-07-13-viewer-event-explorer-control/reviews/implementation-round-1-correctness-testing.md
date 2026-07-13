# Correctness/Test Review — DONE_WITH_CONCERNS

No files were modified. The reviewer inspected the active OpenSpec artifacts, SQLite/catalog
boundaries, operation cancellation, live evaluation cleanup, and associated tests.

## Findings

### CT-001 — High: Recording catalog applies the wrong tombstone bound

`ViewerStoreCatalog.swift:328` compares `Tombstones.rowID` against SQL parameter `?3`, but the binding
at line 337 supplies `installationAliasUpperRowID`. `snapshot.tombstoneUpperRowID` is never bound.

Consequently, deleted recordings can reappear whenever a tombstone row ID exceeds the unrelated
installation-alias high-water mark. This violates frozen-catalog deletion semantics.

The existing test at `ViewerStoreTests.swift:1645` accidentally masks the defect: it creates one alias
and the first tombstone, so both row IDs are `1`.

Required fix:

- Bind `snapshot.tombstoneUpperRowID` through a distinct placeholder and renumber subsequent
  parameters.
- Add a regression with fewer alias rows than tombstones, proving every deleted recording remains
  excluded across fresh pages and cursor restart.

### CT-002 — High: Late cancellation can interrupt the succeeding SQLite operation

`ViewerStoreExplorerGateway.swift:708` verifies that token A is active while holding its lock, then
releases the lock before invoking `cancelCurrentOperation()` at line 732.

During that gap, A may finish and operation B may become active. `ViewerSQLite.cancelCurrentOperation()`
at line 578 has no originating operation token; it cancels whichever SQLite generation is currently
active. A late cancellation can therefore interrupt B, directly violating the exact-token requirement.

The test at `ViewerStoreTests.swift:1357` does not force this window.

Required fix:

- Carry the exact SQLite operation generation/token into cancellation, or otherwise make cancellation
  atomic with successor activation.
- Add a deterministic race test that pauses after A is marked cancelled but before the interrupt, lets
  A finish and B start, then releases A's cancellation and proves B succeeds.

### CT-003 — Medium: Production live-match work is generation-gated but not cancellable

`ViewerLiveEventEvaluator.swift:282` supports an `isCancelled` callback, but
`ViewerEventExplorerCoordinator.swift:329` invokes it with the default always-false closure.

Shutdown at `ViewerEventExplorerController.swift:1119` prevents stale publication and waits for
completion, but it does not cancel active live matching. It therefore waits for the evaluator's own
deadline instead of satisfying the explicit cancel-and-join requirement.

The blocked cleanup test at `ViewerFoundationTests.swift:4534` manually releases the evaluation queue.
It proves joining and stale-publication suppression, not cancellation.

Required fix:

- Give each live evaluation a cancellation token/flag and pass it to the evaluator.
- Cancel it on pause, traversal replacement, and sealing.
- Add a deterministic test where the evaluator has entered checkpointed work and cleanup completes
  because cancellation is observed, without manually allowing normal completion.

Validation evidence reports Viewer 236 passed / 2 skipped / 0 failed and root package 536 / 0, but
those tests do not exercise the three cases above.

**Unresolved findings: 3**
