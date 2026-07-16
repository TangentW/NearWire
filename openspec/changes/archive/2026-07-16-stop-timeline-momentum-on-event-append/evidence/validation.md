# Validation Evidence

## Focused tests

Command:

```sh
xcodebuild test -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-timeline-momentum-final \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  -parallel-testing-enabled NO \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testTimelineMomentumStopsOnlyTheActiveDecelerationSequence \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testHostedTimelineDoesNotJumpAfterOperatorScrollsAwayFromBottom
```

Result: passed.

The state-machine test covers momentum start, append-time stop, suppressed movement, terminal phase
reset, and a later ordinary gesture. The hosted regression confirms the bridge resolves the exact
Timeline `NSScrollView` and preserves an above-tail reading origin when another Event appends.

## Viewer foundation tests

Command:

```sh
xcodebuild test -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-timeline-momentum-class \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  -parallel-testing-enabled NO \
  -only-testing:NearWireViewerTests/ViewerFoundationTests
```

Result bundle:

```text
/tmp/nearwire-timeline-momentum-class/Logs/Test/Test-NearWireViewer-2026.07.17_02-43-33-+0800.xcresult
```

Result: 103 total, 102 passed, 0 failed, 1 skipped. The stable-signer packaging test is expected to
skip without two configured signing identities.

## Build and specification

The Viewer build passed with ad-hoc signing in
`/tmp/nearwire-timeline-momentum-build`. Strict OpenSpec validation and `git diff --check` passed.
OpenSpec's optional PostHog flush could not resolve `edge.openspec.dev` after successful validation.
