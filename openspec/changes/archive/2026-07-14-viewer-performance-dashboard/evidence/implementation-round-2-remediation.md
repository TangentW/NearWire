# Implementation Round 2 Remediation Evidence

Date: 2026-07-14

## Result

All three actionable findings from implementation review round 2 were remediated. Round 3 then found
that the first Store barrier did not include Explorer catalog rematerialization and that the first
cooperative deadline design retained unbounded retired handles. Those later findings supersede the
affected implementation details below and are closed by `implementation-round-3-remediation.md`.
Configured distribution signing and stable-signer cross-update validation remain deferred to the
Goal-level `release-hardening` change and are not claimed here.

## Finding closure

1. **Coordinator-owned Store replacement:** the Performance controller exposes an invalidation-only
   Store replacement barrier. The final round-3 refinement also clears Explorer Store-derived rows
   immediately and joins its change-snapshot and exact logical catalog rematerialization receipt
   before recompiling target/guidance and admitting exactly one successor.
2. **Generation-safe exact cache hits:** every retained numeric representative is checked against
   active source generation before exact-key reuse. A mismatch atomically replaces the old entry
   with the incoming already-owned result and releases predecessor ownership. A historical
   Current Session-to-one-minute-to-Current Session test proves raw reveal remains bound to the new
   generation while the two range entries remain cached.
3. **Joined cooperative deadline cancellation:** the final round-3 refinement uses one reschedulable
   physical worker for the deadline owner's lifetime. Arbitrary re-arming updates one logical receipt
   without retaining per-arm handles. Cleanup cancels and joins that same worker; the cooperative
   1,800-arm test proves one worker and one pending physical schedule before cleanup, then zero after
   release.

The validation below records the round-2 checkpoint. Fresh validation of the refined implementation
is recorded in `implementation-round-3-remediation.md`.

## Focused validation

```text
xcodebuild -quiet \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-remediation-active \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  test-without-building \
  -only-testing:NearWireViewerTests/ViewerPerformancePipelineTests \
  -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests \
  -only-testing:NearWireViewerTests/ViewerAnalysisModeCoordinatorTests

exit 0
```

An initial raw-reveal regression used a blocking semaphore from MainActor and consequently prevented
the MainActor transition it was waiting for. The test synchronization was corrected to use its
bounded asynchronous condition seam. The unchanged production implementation and fresh command
above passed; the blocked attempt is not completion evidence.

## Complete Viewer validation

```text
xcodebuild -quiet \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-remediation-active \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-remediation-round3.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  test-without-building \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement

exit 0
```

`xcresulttool get test-results summary` reported:

```text
result: Passed
totalTestCount: 381
passedTests: 379
skippedTests: 2
failedTests: 0
expectedFailures: 0
```

The test operation completed in 40.040 seconds. The two self-skips and the command-excluded running
entitlement assertion retain their documented environment/signing meanings and do not count as
signed-product evidence.

## Root and static validation

```text
swift test

NearWirePackageTests.xctest: Executed 539 tests, with 0 failures (0 unexpected).
All tests: Executed 539 tests, with 0 failures (0 unexpected) in 2.004 seconds.
exit 0

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
```

The first restricted build attempt could not access Xcode/Swift compiler caches and did not reach
compilation. The identical build command passed with standard cache access; no source, assertion, or
gate was weakened.
