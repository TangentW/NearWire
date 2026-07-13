# Correctness and Testing Implementation Review — Round 10

Date: 2026-07-14

## CT-R10-001 — P2 Medium: the traversal regression does not independently prove page and gap token rejection

**Confidence:** 10/10

The production coordinator now checks the exact Store-operation token before applying a tail Event
page or gap page (`ViewerEventExplorerCoordinator.swift:548-580`). Release and query invalidation are
also exercised in ways that would fail if their guards were removed. The new page/gap regression is
not equally discriminating.

`testExplorerCoordinatorRejectsInvalidStoreTokenAtEveryTraversalStage` invalidates both the page and
gap tokens together, completes both with empty successful pages, and then asserts only that both
models remain empty and the coordinator remains loading
(`ViewerFoundationTests.swift:5617-5629`). Removing either the page guard or the gap guard alone would
still let this test pass: the empty result makes the unintended presentation mutation invisible, and
the other still-invalid stage keeps the shared traversal from reaching `ready`. The test therefore
does not substantiate the remediation evidence's claim that page and gap delivery are rejected
independently, nor the Store-generation requirement that every traversal stage be protected.

Split this portion into two deterministic cases, or two distinct phases. In one, invalidate only the
page token while the gap completion remains valid; in the other, invalidate only the gap token while
the page completion remains valid. Give the invalid completion a nonempty sentinel payload and prove
that payload is not applied, the invalid stage is not marked finished, no implicit successor request
is issued, and the exact work retires. Each case should then issue an explicit fresh traversal, reach
`ready`, and assert zero coordinator/gateway work. This will make removal of either production guard
fail independently.

## CT-R10-002 — P2 Medium: a catalog fixture unlinks an open SQLite database during teardown

**Confidence:** 10/10

`testRecordingCatalogUsesFrozenDescendingKeysetsAndRelevantChangeRestart` creates a
`ViewerSQLitePool` at `ViewerStoreTests.swift:2421` but never closes it before the temporary-directory
teardown registered by `makePaths()` (`ViewerStoreTests.swift:9765-9771`). The complete Viewer run
reported:

```text
BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation:
vnode unlinked while in use: .../NearWire.sqlite-shm
```

An isolated ten-iteration run reproduced the diagnostic on nine iteration transitions, sometimes
for the database and WAL descriptors as well as the shared-memory descriptor. XCTest still reports
the test as passing, so this lifecycle defect can be missed by result-count-only validation and
contradicts the round-9 evidence claim that the final complete run is free of SQLite API violations.

Close this pool with scope-bound cleanup immediately after construction, then rerun the isolated
catalog test repeatedly and the complete Viewer suite while checking the raw process log for SQLite
API-violation diagnostics. Keep the three round-9 fixture fixes unchanged; their combined
thirty-execution repetition remained clean in this review.

## Verified Round-9 remediation

The requested export-boundary behavior is otherwise coherent across implementation, tests, and UI:

- pre-commit user cancellation enters `cancelling`, preserves the prior destination, resolves to
  `cancelled`, and retires gateway/controller work;
- post-commit user cancellation retains the exact operation until the authoritative success receipt,
  resolves to `completed`, and leaves valid committed JSON;
- post-commit Store replacement joins the predecessor operation, accepts only the existing
  controller operation's terminal handoff, resolves to `completed`, and permits fresh successor
  Store work;
- runtime sealing still clears export presentation and joins claimed delivery without repopulating
  the sealed controller; and
- the `Exporting`, `Cancelling`, `Export Complete`, and `Export Cancelled` messages accurately state
  the commit-boundary behavior.

The Store driver also preserves predecessor tokens across release, query, page, and gap calls, and
the final explicit fresh traversal in the new regression reaches `ready` with zero coordinator work.
The unresolved issue is the independent sensitivity of the page/gap test, not a production failure
observed in those guards.

## Fresh validation

- Thirteen traversal/export/gateway/lifecycle tests, five iterations each: 65 executions, 0 failures.
- Three remediated SQLite ownership tests, ten iterations each: 30 executions, 0 failures, no SQLite
  API-violation diagnostic.
- Problematic recording-catalog fixture, ten iterations: 10 executions, 0 test failures, repeated
  SQLite API-violation diagnostics.
- Complete Viewer suite with the explicitly deferred embedded-entitlement test skipped: 275 tests,
  2 skipped, 0 failures; one SQLite API-violation diagnostic from the catalog fixture above.
- Swift Package suite: 537 tests, 0 failures.
- Strict OpenSpec validation: passed.
- `git diff --check`: passed.

Configured distribution signing and validation of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change by product-owner decision and are
not findings in this review.

**Unresolved findings: 2**
