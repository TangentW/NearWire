# Implementation Round 4 Remediation Evidence

> Superseded by `implementation-round-5-remediation.md` after the next independent review found
> cross-catalog snapshot, committed-export race-coverage, and terminal fail-closed gaps.

Date: 2026-07-14

## Result

Every actionable round-4 finding has an implementation, specification, and regression-test closure.
Focused replacement tests, the complete applicable Viewer suite, the complete root package suite,
the unsigned workspace build, formatting, plist, diff, package-boundary, and strict OpenSpec gates
pass. A fresh independent review round remains required before task 7.2 can complete.

Configured distribution signing, the running signed-product entitlement assertion, and stable-signer
cross-update validation remain deferred to the Goal-level `release-hardening` change and are not
claimed here.

## Finding closure

1. **Combined replacement barrier:** Explorer now deactivates and releases Event traversal before
   Store rematerialization. Applying the rebuilt scope while inactive cannot start Event work; the
   analysis coordinator alone reactivates Events after joining Event deactivation, catalog
   rematerialization, Performance cleanup, raw resolution, and the prior mode transition.
2. **Exact logical identity:** first pages remain presentation windows, not identity authority.
   Frozen-snapshot, indexed exact lookup resolves one selected recording logical ID and at most 16
   selected device logical IDs. Catalog-generation changes restart the bounded catalog phase.
3. **No scope broadening:** a historical recording absent by exact logical ID resets to Live. A
   missing selected device remains explicitly selected but has no materialized row, durable Event
   query, or performance target; it never becomes the empty-selection meaning of all devices.
4. **Terminal and dirty state:** change-snapshot failure commits empty or failed recording state and
   empty device state before completing the receipt. A Store-change signal received during the
   catalog phase remains one dirty bit and starts exactly one successor snapshot afterward.
5. **Operation authority:** replacement cancels predecessor operations, destination selection, and
   prepared delete/export tickets synchronously. A Store-committed export keeps its active execution
   slot, receives a cancellation request, and publishes only its existing authoritative completion.
6. **Integrated race coverage:** real two-Store coverage places a surviving selected recording
   outside the first 50 rows, reuses its predecessor device row for another logical device, places
   101 replacement devices behind a 100-row window, and proves exact missing-device lookup is part of
   the receipt. Separate tests cover terminal failure, prepared delete, prepared export/destination,
   committed export, one dirty successor, and the prior mismatched-recording row-reuse case.

## Focused validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-viewer-performance-round4-focused \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationClearsReusedRowIDsUntilReplacementCatalogsCommit \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationUsesExactLogicalIdentityWithoutBroadeningMissingDevice \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationFailurePublishesTerminalCatalogStateAndClearsIdentity \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationRevokesPreparedExportAndDestinationAuthority \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationRevokesPreparedDeleteAuthority \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationPreservesAuthoritativeCommittedExportCompletion \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationRetainsDirtyChangeUntilOneSuccessorSnapshotCompletes

exit 0
```

The first exact-identity test version synchronously waited for a sixth request on MainActor and
therefore prevented the intervening callbacks from starting it. The waiter was made asynchronous.
The first prepared-delete fixture used retention-expired wall time; it was corrected to current wall
time without weakening retention or production behavior.

## Complete Viewer validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-remediation-round6 \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-remediation-round6-final.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement

exit 0
```

Result-bundle extraction reported:

```text
action status: succeeded
total tests: 390
successful tests: 388
skipped tests: 2
failed tests: 0
test operation: 45.554 seconds
```

Xcode emitted only the established macOS 13 target / XCTest 14 linker and signed XCTest stripping
warnings. The two self-skips and command-excluded entitlement assertion keep their documented
environment/signing meanings and are not signed-product evidence.

## Root, build, and static validation

```text
swift test

NearWirePackageTests.xctest: Executed 539 tests, with 0 failures (0 unexpected).
All tests: Executed 539 tests, with 0 failures (0 unexpected) in 1.997 seconds.
exit 0

xcodebuild -quiet build \
  -workspace NearWire.xcworkspace \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-remediation-workspace-round6 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64

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

The restricted SwiftPM attempts could not write the standard compiler module cache. The unchanged
`swift test` and `swift package dump-package` commands passed with normal cache access. The manifest
still reports no dependencies, iOS 16/macOS 13 platforms, Swift 5 language mode, and the existing
root-owned products and targets.
