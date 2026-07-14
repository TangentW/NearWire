# Implementation Round 9 Remediation Evidence

Date: 2026-07-14

## Result

The round-9 architecture finding is closed. A user-owned post-Live historical rematerialization
receipt is now routed to the analysis coordinator instead of being discarded by the Explorer
controller. Events traversal resumes only after that receipt completes, and Performance clears the
old target before the receipt and rebuilds exactly one target after the same barrier. Eleven focused
scenarios passed once and then passed five repeated iterations. The complete applicable Viewer and
root package suites, unsigned workspace build, formatting, plist/privacy, diff, package-boundary,
and strict OpenSpec gates pass. A fresh independent three-dimensional review remains required before
task 7.2 can complete.

Configured distribution signing, the running signed-product entitlement assertion, and stable-signer
cross-update validation remain deferred to the Goal-level `release-hardening` change and are not
claimed here.

## Finding closure

1. **The analysis coordinator owns the user receipt:** the Controller starts the fresh logical-ID
   rematerialization after explicit Live recovery, forwards its joined task exactly once through a
   lifecycle-cleared internal handler, and does not emit a premature ordinary selection callback.
2. **Events resumes after authority is materialized:** the coordinator invalidates predecessor
   transitions and raw resolution, waits for the user receipt, and only then reactivates Event
   traversal. A barrier-controlled integration test observes zero activation while the receipt is
   blocked and exactly one activation after completion.
3. **Performance rebuilds across the same barrier:** the coordinator deactivates and clears the old
   target before waiting, then recompiles selection and activates exactly one new target after the
   receipt. A second barrier-controlled integration test proves no preparation occurs while blocked.
4. **Store replacement remains a distinct route:** coordinator-owned Store replacement continues to
   call its explicit rematerialization driver. The user route is only used by a fresh post-Live
   historical selection, so it does not duplicate the Store-replacement successor or perturb active
   historical A-to-B restart handling.

## Focused validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-viewer-r9-focused \
  -resultBundlePath /tmp/nearwire-viewer-r9-focused-final.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerAnalysisModeCoordinatorTests/testUserSelectionRematerializationReactivatesEventsOnlyAfterReceipt \
  -only-testing:NearWireViewerTests/ViewerAnalysisModeCoordinatorTests/testUserSelectionRematerializationRebuildsPerformanceOnlyAfterReceipt \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationClearsReusedRowIDsUntilReplacementCatalogsCommit \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationUsesExactLogicalIdentityWithoutBroadeningMissingDevice \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationFailurePublishesTerminalStateAndPreservesExplicitScope \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationClearsPartialCatalogAuthorityAfterDevicePhaseFailure \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationClearsCommittedDevicePageAfterExactIdentityFailure \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationDevicePhaseSwitchToLiveCompletesReceiptAndSuccessor \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationActiveHistoricalSwitchRestartsOneReceiptForNewIdentity \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationPreservesAuthoritativeCommittedExportCompletion \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationRetainsDirtyChangeUntilOneSuccessorSnapshotCompletes

exit 0
result: Passed
total tests: 11
passed tests: 11
skipped tests: 0
failed tests: 0
test operation: 1.389 seconds
```

The same eleven tests then ran with `-test-iterations 5` and a separate result bundle:

```text
exit 0
result: Passed
test repetitions: 55
passed repetitions: 55
failed repetitions: 0
test operation: 2.992 seconds
```

Before the successful four-test precursor, one chained in-sandbox invocation exited 74 before tests
could build because Xcode could not write the user Clang and SwiftPM caches. The required standalone
Xcode invocation was rerun with the established Xcode cache permission. Its first requested result
bundle path already existed from the failed attempt, so Xcode rejected that path with exit 64; a new
result bundle path was used without deleting evidence. The unchanged four-test command then passed
4/4, followed by the 11/11 and 55/55 gates above. These were environment/path failures, not test
failures, and no production behavior or validation gate was weakened.

## Complete Viewer validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-viewer-r9-full \
  -resultBundlePath /tmp/nearwire-viewer-r9-full.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement

exit 0
result: Passed
total tests: 396
passed tests: 394
skipped tests: 2
failed tests: 0
test operation: 49.686 seconds
```

The two self-skips and command-excluded entitlement assertion retain their documented
environment/signing meanings and are not signed-product evidence.

## Root package and unsigned workspace

```text
swift test

NearWirePackageTests.xctest: Executed 539 tests, with 0 failures (0 unexpected)
All tests: Executed 539 tests, with 0 failures (0 unexpected) in 2.338 seconds
exit 0

xcodebuild -quiet build \
  -workspace NearWire.xcworkspace \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-viewer-r9-workspace \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64

exit 0
```

## Static and boundary validation

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

plutil -lint \
  Viewer/NearWireViewer.xcodeproj/project.pbxproj \
  Viewer/NearWireViewer/Resources/Info.plist \
  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy \
  Viewer/NearWireViewer/Resources/NearWireViewer.entitlements \
  SDK/Sources/NearWire/PrivacyInfo.xcprivacy \
  SDK/Sources/NearWirePerformance/PrivacyInfo.xcprivacy

all six files: OK

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

swift package dump-package
exit 0
```

The manifest reports no dependencies, iOS 16/macOS 13 platforms, Swift 5 language mode, and the
existing root-owned products and targets. Viewer-only implementation remains outside the package
manifest.
