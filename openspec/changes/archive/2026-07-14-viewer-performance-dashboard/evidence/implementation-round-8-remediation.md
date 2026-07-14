# Implementation Round 8 Remediation Evidence

Date: 2026-07-14

> Superseded by `implementation-round-9-remediation.md`, which closes the analysis-coordinator
> ownership and post-Live Events/Performance reactivation finding from the fresh round-9 review.

## Result

The production finding, direct historical-restart evidence gap, and documentation finding from the
round-8 reviews are closed. Nine focused scenarios passed once and then passed five repeated
iterations. The complete applicable Viewer suite, root package repeat audit, unsigned workspace
build, formatting, plist/privacy, diff, package-boundary, and strict OpenSpec gates pass. A fresh
independent three-dimensional review remains required before task 7.2 can complete.

Configured distribution signing, the running signed-product entitlement assertion, and stable-signer
cross-update validation remain deferred to the Goal-level `release-hardening` change and are not
claimed here.

## Finding closure

1. **Post-Live historical selection starts fresh authority:** if a dirty successor repopulates
   historical source rows after unresolved-to-Live recovery, selecting one immediately deactivates
   and clears the live scope, opens a new rematerialization receipt for the selected logical ID, and
   exposes no live request under the historical label. A completion-only selection notification lets
   Performance re-evaluate only after that user-initiated receipt resolves without perturbing the
   coordinator-owned Store-replacement receipt.
2. **Active historical-to-historical restart has direct evidence:** a device-completion gate holds
   the first historical source's device page after recording rows commit. Selecting a second
   historical source cancels predecessor delivery, retains one receipt, restarts frozen catalogs for
   the second logical identity, consumes one dirty successor, installs only the second recording and
   device identities, and reaches zero controller/gateway work.
3. **Store-unavailable states are documented:** the operator guide now distinguishes historical
   `Storage unavailable` from current `Live window only`, including the leading unknown-history
   discontinuity, overflow disclosure, no `Complete Range` claim, discarded partial reducer state,
   and one fresh recovery scope or paused dirty successor.

## Focused validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round8-remediation-focused2 \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-round8-remediation-focused2.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  [nine rematerialization, source-switch, export, terminal-failure, exact-device, dirty-successor, and row-reuse tests]

exit 0
result: Passed
total tests: 9
passed tests: 9
skipped tests: 0
failed tests: 0
test operation: 2.485 seconds
```

The same nine tests then ran with `-test-iterations 5`:

```text
exit 0
result: Passed
test repetitions: 45
passed repetitions: 45
failed repetitions: 0
test operation: 2.620 seconds
```

An earlier version of the new historical-to-historical test assumed that the gateway's third global
operation was the first device page. Event traversal release also consumes that sequence, so the
test gated the recording catalog and failed six downstream assertions before reaching the intended
branch. The test was corrected to gate the device-catalog completion callback directly. Both source
switch tests then passed alone, the nine-test set passed, and all 45 repetitions passed. No
production behavior or gate was weakened.

## Complete Viewer validation

```text
xcodebuild -quiet test \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round8-remediation-focused2 \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-round8-full.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement

exit 0
result: Passed
total tests: 394
passed tests: 392
skipped tests: 2
failed tests: 0
test operation: 48.064 seconds
```

The two self-skips and command-excluded entitlement assertion retain their documented
environment/signing meanings and are not signed-product evidence.

## Root package repeat audit

The first current-tree `swift test` execution reported one failure among 539 tests, but output
truncation did not retain the case name. Viewer source is outside the root Swift Package manifest,
yet the failure was not dismissed on that basis. The same built test product was rerun repeatedly:

```text
swift test --skip-build

confirmed pass 1: 539 tests, 0 failures, exit 0, 2.186 seconds
confirmed pass 2: 539 tests, 0 failures, exit 0, 2.269 seconds
additional filtered summary: 539 tests, 0 failures, 2.066 seconds
```

The failure did not reproduce in any of the three subsequent executions. No root package source or
test changed in this remediation, and no validation was weakened. The two direct exit-0 repeats are
the completion gate; the isolated initial result remains recorded rather than hidden.

## Unsigned workspace

```text
xcodebuild -quiet build \
  -workspace NearWire.xcworkspace \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Viewer-Performance-round8-workspace \
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
