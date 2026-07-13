# Implementation Review Round 8 Remediation

Date: 2026-07-14

## Result

All four round-8 findings are remediated. The combined focused set passes nine tests, the isolated
SQLite ownership regression passes ten consecutive iterations without a libsqlite API-violation
diagnostic, and the complete Viewer/package/build/static validation gate passes. A fresh independent
three-discipline review remains required before this change can close.

Configured signing and validation of entitlements embedded in a signed product remain explicitly
deferred to Goal-level `release-hardening` by product-owner decision. This remediation does not claim
that deferred gate passed.

## SPD-R8-001 — hard-bounded claimed-result delivery

- Renderer and composer callbacks retain their exact per-request cancellation/delivery gate, but a
  successful claim now submits into one owner-level `ViewerLatestMainActorDeliveryPump` instead of
  creating a task per result.
- Each pump schedules at most one MainActor drain chain and retains at most one processing plus one
  replaceable pending value. A displaced content-bearing value is moved out and released after the
  pump lock is released.
- Supersession cancels the current per-request gate and clears the one pending pump value. Cleanup
  cancels/joins the preparation service and seals/joins the pump before reporting zero work.
- Deterministic regressions keep the MainActor in one synchronous call stack, wait for each of 256
  background delivery claims, supersede without yielding, and assert the declared two-value bound
  for both renderer and composer. Their final values are respectively one maximum 16-MiB canonical
  Event and one JSON document at the active maximum encoded-content byte limit. Cleanup releases all
  retained content and reaches zero work.

## SPD-R8-002 — lifecycle-owned native export destination

- Native destination selection now starts through an injectable controller seam with one exact
  gate, tracker identity, and cancellation closure. The AppKit callback weakly captures the
  controller.
- Closing the export flow or sealing the runtime cancels/dismisses the active panel. A response that
  already claimed delivery remains joined; a later response after cancellation performs no state
  mutation or export request.
- `executePreparedExport` returns immediately when sealed rather than publishing an invalid-request
  state.
- The delayed-response regression acknowledges disclosure, starts selection, seals and joins the
  controller, then returns an approved file URL. It proves no revision, export state, request, or
  file mutation and proves the panel callback does not retain the old controller.

## ARCH-R8-001 — predecessor-generation delivery invalidation

- Each gateway generation owns one shared validity cell carried by its immutable operation tokens.
  Replacement invalidates the predecessor before successor publication and before deferred client
  callbacks run.
- Controller completion still retires its exact local operation/tracker identity, but it applies a
  result only while the attached Store token remains valid. This preserves the gateway's
  resource-retirement-before-arbitrary-callback ordering without allowing an old catalog, detail,
  mutation, or export result to update presentation.
- The controller regression blocks the first catalog result immediately after delivery claim,
  installs a replacement, then releases the callback. The old catalog is discarded; a fresh
  replacement change/catalog request and recording update succeed; controller and gateway work
  counts finish at zero.

## CT-R8-001 — deterministic SQLite test ownership

- `testWholeTransactionPlanIncludesInitialDispositionAndDuplicateIsZeroQuota` now closes its
  `ViewerSQLitePool` with a scope-bound `defer` before XCTest removes the temporary directory.
- Ten isolated iterations pass with zero failures and no `vnode unlinked while in use`, invalidated
  descriptor, or libsqlite client API-violation diagnostic.

## Focused validation

Combined remediation command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerHundredThousandRendererReplacementsCancelBeforeDeliveryClaim \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerBlockedMainActorRetainsBoundedClaimedRendererResults \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCleanupJoinsClaimedContentBearingRendererDelivery \
  -only-testing:NearWireViewerTests/ViewerFlowControlTests/testControlComposerHundredThousandReplacementsCancelBeforeDeliveryClaim \
  -only-testing:NearWireViewerTests/ViewerFlowControlTests/testControlComposerBlockedMainActorRetainsBoundedClaimedResults \
  -only-testing:NearWireViewerTests/ViewerFlowControlTests/testControlComposerCleanupJoinsClaimedContentBearingDelivery \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testControllerRejectsClaimedCatalogFromReplacedGatewayGeneration \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testDelayedExportDestinationCannotMutateOrRetainSealedExplorer \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testWholeTransactionPlanIncludesInitialDispositionAndDuplicateIsZeroQuota
```

Exact result:

```text
Executed 9 tests, with 0 failures
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_02-41-09-+0800.xcresult
```

SQLite repetition:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testWholeTransactionPlanIncludesInitialDispositionAndDuplicateIsZeroQuota \
  -test-iterations 10
Executed 10 tests, with 0 failures
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_02-41-26-+0800.xcresult
```

## Complete validation after remediation

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
totalTestCount: 270
passedTests: 268
skippedTests: 2
failedTests: 0
expectedFailures: 0
** TEST SUCCEEDED **
```

No libsqlite API-violation diagnostic appeared in the complete run. Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_02-44-01-+0800.xcresult
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

`swift package dump-package` and source plist/project validation pass. The package still has no
dependencies, keeps iOS 16/macOS 13 and Swift 5, and exposes only the four expected products. The
Viewer project retains macOS 13, Swift 5, complete strict concurrency, one local root-package
reference, no remote package, and no shell-script build phase.
