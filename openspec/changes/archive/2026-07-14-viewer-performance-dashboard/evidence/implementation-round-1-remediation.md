# Implementation Round 1 Remediation Evidence

Date: 2026-07-14

## Result

All eight unique actionable findings from the first independent implementation review round were
remediated. Fresh focused and complete unsigned validation passes. Configured distribution signing,
the running signed-product entitlement assertion, and stable-signer cross-update validation remain
deferred to the Goal-level `release-hardening` change and are not claimed here.

## Finding closure

1. **Store replacement versus ordinary refresh**: `ViewerStoreStatus` now carries the installed
   explorer-coordinator generation. Application coordination uses ordinary refresh only while that
   generation is unchanged. A changed generation immediately advances performance source authority,
   invalidates delivery and raw resolution, cancels and joins run/delivery/deadline work, clears the
   model and entire result cache, releases source ownership, and only then admits one successor.
   Ready, paused, blocked-scan, claimed-delivery, coordinator-routing, and actual sequential Store
   installation tests cover the distinction.
2. **Current live-only fallback**: Store-unavailable recovery now clears the predecessor publication,
   cache, deadline, crosshair, tooltip, and raw action before a fresh live-only freeze starts. A
   blocked-preparation test proves no old presentation remains while recovery waits.
3. **Representative provenance**: every numeric representative now carries its reduction source
   generation. Finalization validates that generation, and raw requests are created from and checked
   against the representative's bound generation/key pair.
4. **Traversal release failure**: a failed `endTraversal` result now replaces a completed projection
   with the exact Store failure. Tests cover Store replacement, unavailable, and cancellation with no
   publication or retained ledger reservation.
5. **Freshness task ownership**: scheduling returns cancellable owned work. Replacement cancels the
   prior task, cleanup invalidates and waits, and a 1,800-arm test retains exactly one physical
   scheduled job before reducing to zero.
6. **Unsealed deinitialization**: the isolated controller deinitializer synchronously seals an
   externally retained model. A detached cleanup registry retains only the run, delivery, deadline,
   and ledger owners until their waits complete. A ready-model plus blocked-scan test proves immediate
   content removal and eventual zero work and bytes without an explicit `sealAndWait()` call.
7. **Duplicate live carrier array**: `ViewerPerformanceLiveSlice` validates canonical construction and
   the projection session reuses the slice's event buffer instead of allocating a second sorted array.
   A 512-carrier, 4-MiB session test completes in exactly eight 64-event decode turns.
8. **Repeated gap classification**: one immutable classification receipt is computed on the first gap
   page and carried by every successor traversal. A 129-row, five-page SQLite traversal records exactly
   one classification invocation; a fresh traversal records one new invocation.

Projection-session construction now requires an explicit source generation, preventing tests or new
callers from accidentally reducing under an implicit generation and finalizing under another.
Pure pagination boundary tests use a fixed injected clock; the separate 49/50/exceeded-ms tests retain
the complete time-budget gate without depending on host scheduling load.

## Focused validation

The following unsigned selection passed after remediation:

```text
xcodebuild -quiet \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-remediation-active \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  test-without-building \
  -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests \
  -only-testing:NearWireViewerTests/ViewerAnalysisModeCoordinatorTests \
  -only-testing:NearWireViewerTests/ViewerPerformancePipelineTests \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testSequentialRuntimeAutomaticallyReopensAfterCompletedShutdown \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceGapClassificationSeparatesGenericAndApplicableOverflow \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceGapPageAndLiveSliceReachExactCaps

exit 0
```

## Complete Viewer validation

```text
xcodebuild -quiet \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-remediation-active \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-remediation-round1b.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  test-without-building \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement

exit 0
```

`xcresulttool get test-results summary` reported:

```text
result: Passed
totalTestCount: 376
passedTests: 374
skippedTests: 2
failedTests: 0
expectedFailures: 0
```

The two self-skips retain their prior meaning: the stable-signer phase lacks explicit signed-phase
configuration, and the live Application Support artifact audit lacks its machine-local opt-in
marker. The running-product entitlement test is command-excluded because this is an unsigned host
validation. None is counted as signed-product evidence.

The first complete rerun exposed `testPerformanceContinuationOrdersEqualMonotonicTiesByRowID`
depending on the live 50-ms clock while asserting only pagination order. The test was corrected to
use its existing injected-clock seam; the dedicated equality and exceeded-time tests were unchanged.
The failed run is not completion evidence. The fresh complete rerun above passed.

## Package, build, and static validation

```text
xcodebuild -quiet \
  -workspace NearWire.xcworkspace \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-remediation-build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build

exit 0
```

```text
swift test

NearWirePackageTests.xctest: Executed 539 tests, with 0 failures (0 unexpected).
All tests: Executed 539 tests, with 0 failures (0 unexpected).
exit 0
```

The first sandboxed SwiftPM invocation could not write the compiler module cache. The unchanged
command passed with standard compiler-cache access; no option or assertion was changed.

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

plutil -lint \
  Viewer/NearWireViewer.xcodeproj/project.pbxproj \
  Viewer/NearWireViewer/Resources/Info.plist \
  Viewer/NearWireViewer/Resources/NearWireViewer.entitlements \
  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
all four files: OK

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

swift package dump-package
exit 0

rg --files Core SDK Viewer Demo -g 'Package.swift' -g '*.podspec'
no matches (expected exit 1)
```

The dumped root manifest still has no dependencies, retains iOS 16/macOS 13 and Swift 5, and keeps
Core, SDK, and Viewer within their established boundaries. No nested package manifest, podspec,
third-party Core/SDK dependency, service, background mode, privacy declaration, or entitlement was
added.
