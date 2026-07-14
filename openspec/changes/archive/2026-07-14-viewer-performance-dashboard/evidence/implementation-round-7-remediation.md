# Implementation Round 7 Remediation Evidence

Date: 2026-07-14

> Superseded by `implementation-round-8-remediation.md`, which closes the post-Live historical
> source mismatch, active historical restart coverage, and Store-unavailable documentation findings
> from the fresh round-8 reviews.

## Result

Both production findings and both direct-evidence gaps from the round-7 independent reviews are
closed. Eight focused scenarios passed once and then passed five repeated iterations. The complete
applicable Viewer suite, complete root package suite, unsigned workspace build, formatting,
plist/privacy, diff, package-boundary, and strict OpenSpec gates pass. A fresh independent
three-dimensional review remains required before task 7.2 can complete.

Configured distribution signing, the running signed-product entitlement assertion, and stable-signer
cross-update validation remain deferred to the Goal-level `release-hardening` change and are not
claimed here.

## Finding closure

1. **Source selection retires or restarts active rematerialization:** selecting Live while the
   change-snapshot, recording, first-device, or exact-device phase is active cancels every catalog
   slot, clears partial Store identity, completes the receipt exactly once, consumes one dirty
   successor, and installs a live-only materialization. Selecting another resident historical source
   restarts the whole bounded catalog phase for its logical identity instead of cancelling its only
   completion path.
2. **Unresolved presentation is fail-closed:** `selectedRecordingRow`, operation targets, management
   eligibility, performance targets, device mapping, and historical materialization all require
   resolved Store authority. Ordinary refresh may retain bounded catalog presentation internally,
   but it cannot expose the selected recording or restore executable authority.
3. **Exact-device failure has direct evidence:** a deterministic internal identity-loader seam lets
   the first 100-device page commit before the selected 101st device's exact lookup fails terminally.
   The test proves the committed recording/device rows, mapping, targets, and compiled inputs are all
   cleared while the logical selection remains.
4. **Post-failure actions have direct evidence:** after terminal failure, the regression executes
   filter clearing, all-device selection, ordinary refresh, recording paging that reintroduces the
   matching logical row, blocked device paging, a recording-management attempt, and refresh against
   a different logical recording that reuses the same numeric row ID. None restores selected-row
   presentation, a Store query, performance target, or management authority. A final explicit Live
   switch contains a live request and no durable recording ID or device mapping.

## Focused validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round7-remediation-focused \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-round7-remediation-focused.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  [eight rematerialization, export, terminal-failure, exact-device, Live-switch, dirty-successor, and row-reuse tests]

exit 0
result: Passed
total tests: 8
passed tests: 8
skipped tests: 0
failed tests: 0
test operation: 2.534 seconds
```

The same eight tests then ran with `-test-iterations 5`:

```text
exit 0
result: Passed
test repetitions: 40
passed repetitions: 40
failed repetitions: 0
test operation: 5.881 seconds
```

The first repetition attempt exited 65 before executing tests because `/tmp` had only 110 MiB free
and Clang could not write the `simd` module cache. Only obsolete NearWire validation DerivedData
directories under `/tmp` were removed. With 6.6 GiB free, the unchanged repetition command produced
the 40/40 result above. This was an environment-capacity failure, not a test failure or weakened
gate.

## Complete Viewer validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round7-full \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-round7-full.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement

exit 0
result: Passed
total tests: 393
passed tests: 391
skipped tests: 2
failed tests: 0
test operation: 46.349 seconds
```

Xcode emitted only the established signed-XCTest stripping and macOS 13 target / XCTest 14 linker
warnings. The two self-skips and command-excluded entitlement assertion retain their documented
environment/signing meanings and are not signed-product evidence.

## Root package and unsigned workspace

```text
swift test

NearWirePackageTests.xctest: Executed 539 tests, with 0 failures (0 unexpected)
All tests: Executed 539 tests, with 0 failures (0 unexpected) in 1.972 seconds
exit 0

xcodebuild -quiet build \
  -workspace NearWire.xcworkspace \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round7-workspace \
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
