# Implementation Validation

## Planning validation

Command:

```sh
openspec validate fix-timeline-follow-and-performance-trends --strict
```

Result: `Change 'fix-timeline-follow-and-performance-trends' is valid`. The PostHog DNS warning was telemetry-only.

## Focused regressions

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-trends-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests/testChartSegmentsDisconnectExplicitBreaksButBridgeEmptyDisplayBuckets -only-testing:NearWireViewerTests/ViewerFoundationTests/testTimelineTailFollowingPreservesManualReadingAndJumpRestoresFollow -only-testing:NearWireViewerTests/ViewerFoundationTests/testPerformanceDashboardControllerPublishesCurrentMemoryProjectionAndRawLocator
```

Result: 3 passed, 0 failed. This covers scroll-geometry state transitions, sparse measured buckets sharing a trend segment, and the initial rendered multi-sample Performance publication.

Hosted List command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-trends-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerFoundationTests/testHostedTimelineDoesNotJumpAfterOperatorScrollsAwayFromBottom
```

Result: 1 passed, 0 failed. The test hosts the real SwiftUI Timeline, locates its `NSScrollView`, scrolls 220 points away from the bottom, publishes another Event, and verifies both `autoFollow == false` and a stable non-bottom viewport.

The first projection-focused run retained the predecessor expectation that an empty display bucket must start a new segment. It failed exactly that assertion after the intended semantic change. The expectation was updated to require a shared segment, and the clean focused rerun passed.

## Review-finding regressions

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-trends-review-dd -resultBundlePath /private/tmp/nearwire-viewer-trends-review2.xcresult CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests/testChartSegmentsDisconnectExplicitBreaksButBridgeEmptyDisplayBuckets -only-testing:NearWireViewerTests/ViewerFoundationTests/testTimelineTailFollowingPreservesManualReadingAndJumpRestoresFollow -only-testing:NearWireViewerTests/ViewerFoundationTests/testHostedTimelineDoesNotJumpAfterOperatorScrollsAwayFromBottom -only-testing:NearWireViewerTests/ViewerFoundationTests/testPerformanceDashboardControllerPublishesCurrentMemoryProjectionAndRawLocator
```

Result: 4 passed, 0 failed. The projection regression now separately proves that an ordinary empty display bucket preserves the segment while an empty bucket carrying an explicit discontinuity starts the next measurement in a new segment. The render fixture aggregates paired differing samples into measured buckets and asserts a nonzero min/average/max envelope.

The first post-review fixture run passed the three Timeline/projection regressions and failed only an over-specific expectation that paired samples must occupy exactly ten display buckets; the actual aligned range produced eleven measured buckets while still aggregating multiple pairs. The assertion was replaced with the intended contract: fewer points than input observations and at least one measured bucket with a strict nonzero envelope. The clean rerun above passed.

After the compatibility fallback latch was added, the same four focused regressions were run again with `/private/tmp/nearwire-viewer-trends-final2-dd`: 4 passed, 0 failed.

## Class-level regression

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-trends-final2-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests -only-testing:NearWireViewerTests/ViewerFoundationTests
```

Result: 109 executed, 108 passed, 1 existing stable-signer environment skip, 0 failed.

## Build

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-trends-final2-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

Result: `** BUILD SUCCEEDED **` in Swift 5 language mode with strict concurrency enabled.
