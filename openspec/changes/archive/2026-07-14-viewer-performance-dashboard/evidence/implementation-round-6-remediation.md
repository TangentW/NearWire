# Implementation Round 6 Remediation Evidence

Date: 2026-07-14

> Superseded by `implementation-round-7-remediation.md`, which closes the active-source-switch
> receipt race and the direct exact-device/post-failure evidence gaps found by the fresh round-7
> reviews.

## Result

All three actionable round-6 findings are implemented, specified, and covered by deterministic
regression tests. The complete applicable Viewer suite, complete root package suite, unsigned
workspace build, formatting, plist/privacy, diff, package-boundary, and strict OpenSpec gates pass.
A fresh independent three-dimensional review remains required before task 7.2 can complete.

Configured distribution signing, the running signed-product entitlement assertion, and stable-signer
cross-update validation remain deferred to the Goal-level `release-hardening` change and are not
claimed here.

## Finding closure

1. **Unresolved authority cannot be recreated:** Store rematerialization enters an explicit
   unresolved state before any catalog read. A terminal failure clears every partially committed
   recording row, device row, recording operation target, and device mapping while retaining only
   the logical user selection and terminal failure. Filter changes, all-device selection, paging,
   and ordinary catalog refresh cannot compile a durable query from that state.
2. **Later-phase failure is fail-closed:** a deterministic internal device-catalog loader seam drives
   failure after the recording catalog has committed. The regression proves that terminal cleanup
   removes partial presentation and authority, leaves zero background work, and remains inert after
   a later filter mutation. The seam is internal to the Viewer implementation and does not change
   SDK or public API.
3. **Numeric row reuse cannot regain authority:** historical selection, operation target lookup, and
   management eligibility require the resident row ID and logical recording ID to match while the
   rematerialization state is resolved. A replacement row reusing the same numeric ID cannot be
   exported, deleted, or used to compile the prior logical scope.
4. **Explicit Live recovery is bounded:** an explicit switch from unresolved historical state to
   Live may build a live-only scope, but it carries no durable Store recording ID or device mapping.
   Successful exact historical absence remains the only automatic historical-to-Live transition.

## Focused validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round6-remediation-rerun \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-round6-remediation-rerun.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationUsesExactLogicalIdentityWithoutBroadeningMissingDevice \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationPreservesAuthoritativeCommittedExportCompletion \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationFailurePublishesTerminalStateAndPreservesExplicitScope \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationClearsPartialCatalogAuthorityAfterDevicePhaseFailure \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationRetainsDirtyChangeUntilOneSuccessorSnapshotCompletes \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationClearsReusedRowIDsUntilReplacementCatalogsCommit

exit 0
result: Passed
total tests: 6
passed tests: 6
skipped tests: 0
failed tests: 0
test operation: 2.312 seconds
```

An initial version of the new later-phase test used an unnecessary background gateway-install race
and was stopped before it produced evidence. It was replaced with deterministic content-driver
failure injection; no production gate, limit, or failure behavior was weakened.

## Complete Viewer validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round6-full \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-round6-full.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement

exit 0
result: Passed
total tests: 391
passed tests: 389
skipped tests: 2
failed tests: 0
test operation: 46.942 seconds
```

Xcode emitted only the established signed-XCTest stripping and macOS 13 target / XCTest 14 linker
warnings. The two self-skips and command-excluded entitlement assertion retain their documented
environment/signing meanings and are not signed-product evidence.

## Root package and unsigned workspace

```text
swift test

NearWirePackageTests.xctest: Executed 539 tests, with 0 failures (0 unexpected)
All tests: Executed 539 tests, with 0 failures (0 unexpected) in 2.034 seconds
exit 0

xcodebuild -quiet build \
  -workspace NearWire.xcworkspace \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round6-workspace \
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
manifest. An initial operator invocation of `plutil` referenced an obsolete SDK privacy-manifest
path and exited 1 without inspecting that file; the corrected complete six-file inventory above
passed and is the recorded gate.
