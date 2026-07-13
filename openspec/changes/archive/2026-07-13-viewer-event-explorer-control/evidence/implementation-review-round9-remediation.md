# Implementation Review Round 9 Remediation

Date: 2026-07-14

## Result

All three round-9 reports reduce to two unique P1 findings, and both are remediated. The expanded
traversal/export regression set passes 13 tests, the final SQLite fixture-ownership set passes 30
executions without a libsqlite API-violation diagnostic, and the complete Viewer/package/build/static
validation gate passes. A fresh independent three-discipline review remains required before this
change can close.

Configured distribution signing and validation of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change by product-owner decision. This
remediation does not claim that deferred gate passed.

## ARCH-R9-001 — exact Store identity across traversal stages

- `ViewerExplorerStoreDriver` now returns an immutable Store-operation token for release, query,
  page, and gap work. Query/page/gap successor APIs require the exact predecessor token.
- The gateway selects a successor only when that predecessor still belongs to the current
  coordinator generation. A retired predecessor returns `storeReplaced` synchronously and cannot
  retarget work to the replacement generation.
- A synchronous-completion-safe delivery box attaches each returned token exactly once. Every
  callback retires its own coordinator work identity, but it applies presentation or starts a
  successor only while that exact Store token remains valid.
- The stage regression invalidates release, query, page, and gap deliveries independently. None
  publishes stale state or issues implicit replacement-generation work. An explicit fresh traversal
  then succeeds and all coordinator/gateway work reaches zero.

## ARCH-R9-002 / CT-R9-001 / SPD-R9-001 — commit-aware export completion

- Export execution has a distinct `cancelling` presentation state. User cancellation requests exact
  gateway cancellation without deleting the controller's operation/delivery identity.
- Pre-commit cancellation remains `cancelled` and preserves the prior destination. After the atomic
  destination replacement, the gateway's exact terminal receipt is authoritative: both user
  cancellation and Store replacement publish `completed`.
- The narrow exception accepts only the terminal receipt for the existing export operation. It
  cannot query, mutate, or retarget a successor Store generation. Runtime sealing still clears
  presentation and joins the callback without repopulating a sealed controller.
- Controller regressions cover cancellation before commit, cancellation after commit, and Store
  replacement after commit. They assert the destination bytes, truthful terminal presentation,
  exact callback retirement, and zero remaining gateway/controller work.

## Focused traversal and export validation

The expanded set includes the new traversal-stage and export-boundary tests together with adjacent
pause/reconciliation, generation-replacement, save-panel, gateway-linearization, and committed-export
regressions:

```text
testExplorerCoordinatorPauseBeforeCompletionAndRapidGenerationsPublishOnlyLatest
testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity
testExplorerCoordinatorRejectsInvalidStoreTokenAtEveryTraversalStage
testControllerCancellationAfterExportCommitPublishesAuthoritativeSuccess
testControllerCancellationBeforeExportCommitPreservesPriorDestination
testControllerRejectsClaimedCatalogFromReplacedGatewayGeneration
testControllerStoreReplacementAfterExportCommitPublishesAuthoritativeSuccess
testDelayedExportDestinationCannotMutateOrRetainSealedExplorer
testExplorerGatewayActiveCompletionCanInstallReplacementReentrantly
testExplorerGatewayFollowingOperationsRejectRetiredPredecessorWithoutRetargeting
testExplorerGatewayLinearizesExternalAndCallbackReplacementWithoutOrphanGeneration
testExplorerGatewayReplacementRetiresOperationBeforeArbitraryCompletion
testGatewayCancellationAfterCommittedExportPreservesSuccessAndClearsState

Executed 13 tests, with 0 failures
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_03-07-57-+0800.xcresult
```

## SQLite fixture ownership found during final validation

The first complete rerun exposed three passing tests whose temporary-directory cleanup could precede
full pool ownership release. Two now close their pools with scope-bound cleanup. The capacity
recovery fixture additionally clears its store-to-maintenance callback cycle before closing the
pool. The final combined repetition passes without a SQLite API-violation diagnostic:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testMissingInitialTransitionBecomesIdempotentGapWithoutPoisoningWriter \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testNearMaximumPayloadUsesBoundedOversizeTransaction \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testProjectedReservationCrossingCapacityReclaimsEligibleHistoryThenAdmits \
  -test-iterations 10
Executed 30 tests, with 0 failures
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_03-14-19-+0800.xcresult
```

## Complete validation after remediation

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
totalTestCount: 275
passedTests: 273
skippedTests: 2
failedTests: 0
expectedFailures: 0
** TEST SUCCEEDED **
```

The complete run passed by XCTest result count. Subsequent round-10 independent log review found one
additional recording-catalog fixture that could still unlink an open SQLite file; that ownership
issue and its fresh clean complete rerun are recorded in
`implementation-review-round10-remediation.md`. Result bundle for this historical run:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_03-12-47-+0800.xcresult
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

`swift package dump-package`, source/built plist validation, and project/package-boundary
inspection pass. The root package still has no dependencies, keeps iOS 16/macOS 13 and Swift 5, and
contains no Viewer target or source. The Viewer project retains macOS 13, Swift 5, complete strict
concurrency, one local root-package reference, no remote package, and no shell-script build phase.
