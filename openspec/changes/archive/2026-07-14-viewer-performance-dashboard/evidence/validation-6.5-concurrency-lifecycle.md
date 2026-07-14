# Validation 6.5 Evidence: Concurrency and Lifecycle

Date: 2026-07-14

## Coverage

- The current-source freeze tests pin live capture before Store uppers and execute a commit hook
  between live freeze and Store-upper publication. Events committed before and during that hook are
  reconciled exactly once, an Event committed after the Store upper remains outside the receipt,
  and an Event beyond the live anchor is excluded even when it becomes durable.
- Store-unavailable recovery is exercised independently during frozen-receipt preparation, after an
  incomplete Event page, and while loading the final gap page. Each failed Store-backed run is
  discarded completely before one fresh live-only successor publishes; no partial Store page can
  survive into the recovered result.
- Current scans cross the absolute freshness deadline both between delivery claim and MainActor
  apply and while an Event page is barrier-blocked. Equality and past-deadline publication restate
  cards as `No recent sample`, schedule no past wake, and cannot reverse stale state to fresh when a
  receipt is delivered again.
- The deadline scheduler proves one future wake for current sources, zero for historical sources,
  no wake at equality, and one bounded dirty expiry while paused. Historical receipts retain their
  frozen uptime semantics across current-clock reset and do not acquire current-source wakeups.
- Refresh admission coalesces 100,000 running-plus-dirty submissions to one running scan and one
  latest successor. The live window accepts 100,000 offers through one bounded drain and one
  refresh wake with zero measured process-footprint growth in this diagnostic run.
- Pause/Resume, range, source, device, current/historical mode, and Events/Performance mode
  transitions clear or join the originating generation before admitting a successor. A claimed
  delivery is discarded before replacement completes, and cancelling a blocked projection joins
  its page operation and traversal release.
- Store generation replacement waits for originating operations to seal, rejects following
  operations from a retired predecessor instead of retargeting them, and prevents late runtime
  cleanup from closing or attaching the replacement runtime.
- Every focused controller case finishes with no running scan, dirty successor, pending delivery,
  deadline wake, charged cache reservation, or retained projection bytes. Cache and ledger bounds
  remain constant rather than scaling with refresh count.

## Main concurrency matrix

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-performance-6-5-tests \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerPerformancePipelineTests \
  -only-testing:NearWireViewerTests/ViewerPerformanceDashboardModelTests \
  -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests \
  -only-testing:NearWireViewerTests/ViewerAnalysisModeCoordinatorTests \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceFreezeReconcilesBeforeDuringAndAfterStoreUpperCommitsExactlyOnce

ViewerAnalysisModeCoordinatorTests: Executed 6 tests, with 0 failures.
ViewerPerformanceDashboardControllerTests: Executed 7 tests, with 0 failures.
ViewerPerformanceDashboardModelTests: Executed 6 tests, with 0 failures.
ViewerPerformancePipelineTests: Executed 10 tests, with 0 failures.
ViewerStoreTests: Executed 1 test, with 0 failures.
Selected tests: Executed 30 tests, with 0 failures (0 unexpected) in 0.293 seconds.
** TEST SUCCEEDED **
```

The original command also named the 100,000-live-offer test under the wrong XCTest class. Xcode did
not execute that selector, so it is not counted as evidence above. The test was rerun below with its
actual `ViewerFoundationTests` class rather than treating a silently skipped selector as coverage.

## Stress and replacement matrix

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-performance-6-5-tests \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testHundredThousandLiveOffersUseOneBoundedDrainAndRefreshWake \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCurrentFreezeUsesLiveAnchorBeforeStoreUppers \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewaySealsOriginatingGenerationBeforePublishingReplacement \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayFollowingOperationsRejectRetiredPredecessorWithoutRetargeting \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime

NearWire 100,000 live-offer diagnostics:
  callback-total-ns=62928291
  process-footprint-growth=0
ViewerFoundationTests: Executed 1 test, with 0 failures.
ViewerStoreTests: Executed 4 tests, with 0 failures.
Selected tests: Executed 5 tests, with 0 failures (0 unexpected) in 0.294 seconds.
** TEST SUCCEEDED **
```

## Static gates

```text
xcrun swift-format lint --strict \
  Viewer/NearWireViewerTests/ViewerFoundationTests.swift \
  Viewer/NearWireViewerTests/ViewerStoreTests.swift
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

The first attempt to execute the newly added tests did not reach XCTest because the restricted
process could not write Xcode/SwiftPM caches. The identical unsigned commands were rerun with the
permitted local compiler-cache access and passed. No assertion or validation gate was changed.

Testing is unsigned and does not claim the deferred Goal-level signed entitlement or stable-signer
validation.
