# Implementation Round 5 Remediation Evidence

Date: 2026-07-14

> Superseded by `implementation-round-6-remediation.md`, which closes the authority-recreation and
> partial-catalog findings discovered by the fresh round-6 reviews and records validation of the
> resulting implementation.

## Result

All three actionable round-5 findings are implemented, specified, and covered by deterministic
regression tests. The complete applicable Viewer suite, complete root package suite, unsigned
workspace build, formatting, plist, diff, package-boundary, and strict OpenSpec gates pass. A fresh
independent three-dimensional review remains required before task 7.2 can complete.

Configured distribution signing, the running signed-product entitlement assertion, and stable-signer
cross-update validation remain deferred to the Goal-level `release-hardening` change and are not
claimed here.

## Finding closure

1. **One frozen catalog phase:** the first device-page read now receives the recording snapshot and,
   in the same read transaction that mints device-scoped bounds, compares the current global bounds
   and change fingerprint with that recording snapshot. Any mismatch reports `catalogChanged`.
   During rematerialization, that failure clears partial rows and restarts the entire recording plus
   device phase rather than accepting a fresh device-only snapshot.
2. **Generation-invalidated committed export:** the controller preserves a Store-committed export
   slot and requests cancellation while a concurrent gateway install invalidates its generation and
   defers completion. The authoritative committed success is delivered after replacement, accepted
   exactly once, and both gateway and controller work counts retire to zero.
3. **Terminal failure is fail-closed:** rematerialization records `unresolved`, `resolved`, or
   `recordingAbsent`. Only successful exact identity lookup returning no row authorizes historical-
   to-Live reconciliation. Snapshot/catalog failure retains the historical logical source and
   explicit device selection, clears every Store-derived row/mapping, and compiles no durable query
   or performance target.
4. **Full-phase dirty coalescing:** the latest controller already deferred Store notifications for
   the complete active rematerialization receipt. The refreshed correctness review withdrew its
   initial concern. A recording-catalog-phase gate proves exactly one successor snapshot begins only
   after the receipt.

## Focused validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round5-focused \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-round5-focused-6.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationUsesExactLogicalIdentityWithoutBroadeningMissingDevice \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationPreservesAuthoritativeCommittedExportCompletion \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationFailurePublishesTerminalStateAndPreservesExplicitScope \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationRetainsDirtyChangeUntilOneSuccessorSnapshotCompletes

exit 0
four tests passed
```

The first restricted Xcode attempt could not write the standard compiler and SwiftPM caches. The
unchanged focused command passed with normal cache access. Test-only timing fixes use asynchronous
MainActor-compatible waiting and current wall time; no production or retention limit was weakened.

## Complete Viewer validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round5-full \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-round5-full.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement

exit 0
```

Result-bundle extraction reported:

```text
result: Passed
total tests: 390
passed tests: 388
skipped tests: 2
failed tests: 0
test operation: 46.665 seconds
```

Xcode emitted only the established signed-XCTest stripping and macOS 13 target / XCTest 14 linker
warnings. The two self-skips and command-excluded entitlement assertion retain their documented
environment/signing meanings and are not signed-product evidence.

## Root package and unsigned workspace

```text
swift test

NearWirePackageTests.xctest: Executed 539 tests, with 0 failures (0 unexpected)
All tests: Executed 539 tests, with 0 failures (0 unexpected) in 2.374 seconds
exit 0

xcodebuild -quiet build \
  -workspace NearWire.xcworkspace \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round5-workspace \
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

The manifest reports no dependencies, iOS 16/macOS 13 platforms, Swift 5 language mode, and the
existing root-owned products and targets. Viewer-only implementation remains outside the package
manifest.
