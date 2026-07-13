# Implementation Review Round 10 Remediation

Date: 2026-07-14

## Result

All three unique round-10 findings are remediated. The four affected regressions pass 40 repeated
executions with no SQLite API-violation diagnostic, and the complete Viewer/package/build/static
validation gate passes. A fresh independent three-discipline review remains required before this
change can close.

Configured distribution signing and validation of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change by product-owner decision. This
remediation does not claim that deferred gate passed.

## ARCH-R10-001 — rejected successors carry invalid delivery identity

- Direct requests made while no Store is available retain the existing generation-zero,
  delivery-valid token so their closed `unavailable` presentation can be shown.
- A `following:` request whose predecessor is retired now returns a distinct generation-zero token
  backed by an already-invalid delivery cell. Its synchronous `storeReplaced` completion retires
  coordinator work but cannot publish an error or any other presentation state.
- Gateway tests assert that rejected query, page, and gap successor tokens are each delivery-invalid
  and that no replacement-generation operation is created.
- Coordinator coverage deterministically rejects query submission after release validation and
  rejects page/gap submission after query validation. Both chains remain in their prior loading
  presentation, publish no stale rows/gaps/error, retire all work, and recover only through an
  explicit fresh traversal.

## CT-R10-001 — independent page and gap guard sensitivity

- The traversal-stage regression now invalidates page and gap tokens in separate refresh phases.
- The invalid page returns a nonempty Event sentinel while the gap completes validly; the Event is
  not applied and the page stage is not marked finished.
- The invalid gap returns a nonempty gap sentinel while the page completes validly; the gap is not
  applied and the gap stage is not marked finished.
- Each invalid phase reaches zero tracked work without becoming ready. A later explicit refresh
  completes both stages and reaches `ready`.

## CT-R10-002 — recording-catalog fixture ownership

- `testRecordingCatalogUsesFrozenDescendingKeysetsAndRelevantChangeRestart` now closes its
  `ViewerSQLitePool` with scope-bound cleanup before XCTest removes the temporary directory.
- Ten isolated iterations and the fresh complete Viewer suite contain no libsqlite API-violation
  diagnostic.

## Focused validation

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCoordinatorRejectsInvalidStoreTokenAtEveryTraversalStage \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCoordinatorDiscardsSynchronouslyRejectedTraversalSuccessors \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayFollowingOperationsRejectRetiredPredecessorWithoutRetargeting \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRecordingCatalogUsesFrozenDescendingKeysetsAndRelevantChangeRestart \
  -test-iterations 10
Executed 40 tests, with 0 failures
** TEST SUCCEEDED **
```

No libsqlite API-violation diagnostic appeared. Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_03-26-59-+0800.xcresult
```

## Complete validation after remediation

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
totalTestCount: 276
passedTests: 274
skippedTests: 2
failedTests: 0
expectedFailures: 0
** TEST SUCCEEDED **
```

The complete run passed by XCTest result count. Subsequent round-11 raw-diagnostic export found
additional temporary-pool teardown incidents that were invisible in the summary. The systematic
fixture remediation and a fresh zero-match complete diagnostic scan are recorded in
`implementation-review-round11-remediation.md`. Historical result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_03-27-21-+0800.xcresult
```

```text
swift test
Executed 537 tests, with 0 failures

xcodebuild build -workspace NearWire.xcworkspace -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
** BUILD SUCCEEDED **

xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid
```
