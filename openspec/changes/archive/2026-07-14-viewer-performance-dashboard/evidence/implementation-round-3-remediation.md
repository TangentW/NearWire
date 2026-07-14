# Implementation Round 3 Remediation Evidence

Date: 2026-07-14

## Result

Every actionable implementation-review round-3 finding is remediated. The focused regression set,
complete applicable Viewer suite, complete root package suite, unsigned workspace production build,
formatting, plist, diff, package-boundary, and strict OpenSpec gates pass.

Configured distribution signing, the running signed-product entitlement assertion, and stable-signer
cross-update validation remain deferred to the Goal-level `release-hardening` change and are not
claimed here.

Round-4 review later superseded the round-3 catalog-page sufficiency assumption. The final design
uses bounded exact logical-ID lookups beyond first pages and retains a missing selected device as an
explicit no-match scope instead of removing it. Round-4 evidence is authoritative for that behavior.

## Finding closure

1. **Constant-space deadline ownership:** one deadline owner now creates at most one reschedulable
   physical worker. Re-arming replaces the logical receipt and reschedules that worker; invalidation
   disarms it; cleanup cancels and joins it. Physical commands are linearized by the owner lock, so an
   older arm cannot land after a newer arm or invalidation. The cooperative scheduler test performs
   1,800 arms and proves one logical wake, one pending schedule, one created/physical worker, cleanup
   pending until that worker exits, and zero physical work afterward. A separate test drops the owner
   while cleanup still independently joins the worker.
2. **Explorer Store-rematerialization barrier:** replacement now clears predecessor Store-derived
   rows, operation targets, and device-catalog authority synchronously. Explorer returns one receipt
   covering the replacement change snapshot, recording catalog, and exact logical recording/device
   catalog when the selected source survives. The analysis coordinator joins that receipt with the
   prior transition, Performance cleanup, and raw resolver before recompiling target/guidance and
   admitting exactly one successor. If an exact historical recording is absent, Explorer resets to
   Live and removes device selections absent from the replacement catalog before compiling any Event
   scope.
3. **Reused-row integration coverage:** a real two-database test gives the old and replacement Stores
   identical numeric recording/device row IDs but different logical identities. A blocked change
   snapshot proves predecessor target authority clears before I/O completes; after release, only the
   replacement recording catalog is resident, the mismatched device row is not loaded, the stale
   historical selection has reset to Live, and no stale target can compile. A coordinator barrier
   test separately proves exactly one successor after the
   rematerialization receipt completes.

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
  -only-testing:NearWireViewerTests/ViewerAnalysisModeCoordinatorTests \
  -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationClearsReusedRowIDsUntilReplacementCatalogsCommit

exit 0
```

The first integration-test fixture used epoch-adjacent wall timestamps. The real retention policy
correctly removed those closed recordings before catalog loading. The fixture was corrected to use
current wall time; no production behavior or retention gate changed.

## Complete Viewer validation

```text
xcodebuild -quiet \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-remediation-active \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-remediation-round4-final.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  test-without-building \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement

exit 0
```

`xcrun xcresulttool get test-results summary` reported:

```text
result: Passed
totalTestCount: 384
passedTests: 382
skippedTests: 2
failedTests: 0
expectedFailures: 0
```

The test operation completed in 41.029 seconds. Xcode emitted only the established macOS 13 target /
XCTest 14 linker warnings. The two self-skips and command-excluded entitlement assertion keep their
documented environment/signing meanings and are not signed-product evidence.

## Root, build, and static validation

```text
xcodebuild -quiet \
  -workspace NearWire.xcworkspace \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-remediation-workspace-final \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build

exit 0

swift test

NearWirePackageTests.xctest: Executed 539 tests, with 0 failures (0 unexpected).
All tests: Executed 539 tests, with 0 failures (0 unexpected) in 2.041 seconds.
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

swift package dump-package
exit 0
```

The first restricted `swift package dump-package` attempt could not write the compiler module cache.
The unchanged command passed with standard cache access. The manifest still reports no dependencies,
iOS 16/macOS 13 platforms, Swift 5 language mode, and the existing root-owned products and targets.
