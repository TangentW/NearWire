# Correctness and Testing Implementation Review — Round 11

Date: 2026-07-14

## Decision

Remediation is required. Round 10's traversal-delivery fixes, mutation-sensitive guard coverage,
explicit fresh-traversal recovery, zero-work retirement, and export commit-boundary behavior are
correctly represented and passed fresh focused validation. One P2 test-lifecycle finding remains:
the complete Viewer suite still removes temporary SQLite storage while connections are open, even
though every XCTest assertion passes.

Configured distribution signing and inspection of entitlements embedded in a signed product are
explicitly deferred to the Goal-level final validation by product-owner decision. That deferred gate
is not a finding in this review.

## Finding

### CT-R11-001 — P2: the green Viewer suite still reports SQLite API violations

`ViewerStoreTests.tearDownWithError` unconditionally removes every tracked temporary directory
(`Viewer/NearWireViewerTests/ViewerStoreTests.swift:107-111`). Several tests create a
`ViewerSQLitePool` over one of those directories without scope-bound cleanup. Two directly
reproducible examples are:

- `testAppendOnlyDispositionPolicyAndDropSamplesAreIdempotentAndDetectConflicts`, which opens the
  pool at `Viewer/NearWireViewerTests/ViewerStoreTests.swift:3780-3782` and exits at line 3978 without
  closing it.
- `testCapacityPauseRunsOneRecoveryAndExplicitProbeResumesAfterCapacityIncrease`, which opens the
  pool at `Viewer/NearWireViewerTests/ViewerStoreTests.swift:6728-6734` and exits at line 6778 without
  closing it.

The fresh complete Viewer run reports 276 total tests, 274 passed, 2 skipped, and 0 failed, but its
raw `StandardOutputAndStandardError.txt` contains three distinct pairs of:

```text
BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation:
vnode unlinked while in use: .../NearWire.sqlite-shm
invalidated open fd: 10 (0x11)
```

Those incidents were logged while the append-only disposition test, capacity-pause test, and
viewer-time query test were running. The result bundle is:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_03-34-27-+0800.xcresult
```

A focused 10-iteration run of the two reproducible tests plus the viewer-time query test executed 30
tests with 0 failures but emitted 19 `BUG IN CLIENT OF libsqlite3` diagnostics. The first two tests
account for all 19 focused-run incidents; the viewer-time query test did not reproduce one in that
isolated sequence. Its result bundle is:

```text
/tmp/NearWire-Round11-SQLite-Lifecycle.xcresult
```

A static fixture audit also finds 19 test methods that directly construct
`ViewerSQLitePool(migrating: makePaths())` without an explicit `pool.close()`. Relying on ARC to
choose a deinitialization point before XCTest removes the backing directory is nondeterministic and
has already produced observable SQLite API misuse. This invalidates the Round 10 remediation
evidence's claim that the complete run contained no SQLite API-violation diagnostic.

Required remediation:

1. Give every temporary-directory-backed pool deterministic ownership, preferably by placing
   `defer { pool.close() }` immediately after successful construction. Where a test owns higher-level
   services, seal/join those owners before closing the pool.
2. Repeat the complete Viewer suite and export the new `.xcresult` diagnostics. Treat any match for
   `BUG IN CLIENT OF libsqlite3`, `API violation`, `vnode unlinked`, or `invalidated open fd` as a gate
   failure even when XCTest reports zero failures.
3. Save the exact zero-match diagnostic scan with the remediation evidence so this failure mode
   cannot be hidden by the XCTest summary.

## Round 10 remediation verification

### Traversal delivery and mutation sensitivity

- `ViewerStoreExplorerOperationToken.invalidDeliveryToken()` returns an already-invalid delivery
  identity, and rejected `following:` submissions return it synchronously without creating work in a
  replacement generation (`Viewer/NearWireViewer/Store/ViewerStoreExplorerGateway.swift:51-58` and
  `519-533`).
- The release and query guards are independently sensitive: removing the release guard changes the
  asserted query count, while removing the query guard changes the asserted page/gap counts
  (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:5615-5630`).
- Page and gap delivery guards now have separate phases with nonempty sentinels. Removing either
  guard independently changes the corresponding rows and completion state
  (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:5632-5668`).
- Each rejected phase reaches exactly zero pending work, and an explicit fresh traversal is required
  to reach `ready` (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:5647-5683`).
- Synchronously rejected query and page/gap successors cannot publish stale rows, gaps, or error
  state; all work retires, and the explicit fresh traversal recovers
  (`Viewer/NearWireViewerTests/ViewerFoundationTests.swift:5737-5775`). Removing either page or gap
  delivery guard changes the expected loading state to failure, so the combined synchronous phase
  remains independently mutation-sensitive.
- The real gateway regression asserts `.storeReplaced`, delivery-invalid query/page/gap tokens,
  exactly zero gateway operations, and a successful fresh replacement request
  (`Viewer/NearWireViewerTests/ViewerStoreTests.swift:2048-2124`).

### Export commit boundaries

Fresh repeated coverage passed cancellation before and after commit, Store replacement after commit,
sealed-explorer cleanup, gateway cancellation after committed export, and injected failure/cancel
boundaries. The authoritative committed result is retained while pre-commit cancellation preserves
the prior destination. No actionable export correctness or lifecycle issue was found.

## Fresh validation

```text
Round 10 focused remediation tests, 10 iterations each
Executed 40 tests, with 0 failures
No SQLite API-violation diagnostic

Export boundary/lifecycle tests, 10 iterations each
Executed 60 tests, with 0 failures
No SQLite API-violation diagnostic

Complete Viewer suite
totalTestCount: 276
passedTests: 274
skippedTests: 2
failedTests: 0
Three distinct SQLite API-violation incidents in raw diagnostics

Focused SQLite-lifecycle reproduction
Executed 30 tests, with 0 failures
Nineteen SQLite API-violation incidents in raw diagnostics

swift test
Executed 537 tests, with 0 failures

xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid
```

## Unresolved finding count

1 actionable finding: CT-R11-001 (P2).
