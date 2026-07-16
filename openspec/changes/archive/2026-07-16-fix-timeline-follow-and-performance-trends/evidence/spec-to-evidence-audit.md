# Spec-to-Evidence Audit

## Viewer Event Explorer control

| Requirement or scenario | Implementation evidence | Verification evidence |
| --- | --- | --- |
| Derive follow state from the actual viewport | `ViewerTimelineScrollGeometryModifier`, `ViewerTimelineScrollGeometry`, and `ViewerTimelineTailViewportState.observe(previous:current:)` | `testTimelineTailFollowingPreservesManualReadingAndJumpRestoresFollow` |
| Keep a manually scrolled reading position when a new Event arrives | Local follow intent becomes false before the successor-row handler; content growth cannot restore it | `testHostedTimelineDoesNotJumpAfterOperatorScrollsAwayFromBottom` verifies the real `NSScrollView` origin remains stable |
| Preserve tail following when content grows while already at the bottom | Scroll-geometry content-growth latch on macOS 15+; settled-row fallback latch on macOS 13/14 | Timeline state test covers geometry growth and fallback stable/pending/false/settled transitions |
| Restore following only at the bottom or through Jump to Latest | Bottom geometry and explicit controller action are the only positive paths; lazy `onAppear` is not | Timeline state test and the complete Viewer foundation suite |
| Publish every retained row beyond the old count cap | Existing byte-bounded Timeline evaluation remains unchanged | `testTimelinePublishesEveryByteValidRowBeyondLegacyCountCap` publishes 600 rows |
| Hide normal progress dispositions but retain exceptional status | Existing `ViewerExplorerTimelineDispositionPresentation` remains unchanged | `testTimelineHidesNormalAdmissionProgressAndKeepsExceptionalDisposition` |
| Preserve stable row identity and clear unavailable selected detail | No row identity or Inspector resolution path changed | Complete `ViewerFoundationTests`, including Timeline/Inspector rendering and replacement cleanup coverage |

## Viewer Performance dashboard

| Requirement or scenario | Implementation evidence | Verification evidence |
| --- | --- | --- |
| Ordinary empty display buckets do not split a valid trend | Chart preparation carries `segmentStartBucketIndex` across empty buckets | `testChartSegmentsDisconnectExplicitBreaksButBridgeEmptyDisplayBuckets` |
| Explicit gap/availability discontinuity still breaks a trend, including an empty bucket | `pendingBreak` latches an empty discontinuous bucket until the next measurement | The same projection regression verifies measured → empty/discontinuous → measured starts a new segment |
| Average is primary; min/max is a continuous translucent band; points are subordinate | Monotone `LineMark`, segmented monotone `AreaMark`, and size-dependent `PointMark` | `continuous-performance-trends.png`, `render-validation.md`, and strict envelope assertions in `testPerformanceDashboardControllerPublishesCurrentMemoryProjectionAndRawLocator` |
| A one-bucket metric remains visible | Single-series point size is promoted | `testSingleMeasuredBucketPreparesAnExplicitVisiblePoint` |
| Projection work stays linear, bounded, immutable, and off-main | Existing bounded aggregation/projection architecture remains; mark count stays three per measured point | `ViewerPerformancePresentationTests`, `ViewerFoundationTests`, build, and clean architecture/performance reviews |
| Ordinary refresh keeps stable SwiftUI containers | Chart identity, prepared series identity, and nonanimated Timeline container remain stable | Existing publication/render tests plus final clean reviews found no SwiftUI replacement or MainActor aggregation regression |

## Final gates

- Focused regressions: 4 passed, 0 failed.
- Class-level Viewer tests: 109 executed, 108 passed, 1 existing stable-signer environment skip, 0 failed.
- Viewer build: succeeded in Swift 5 language mode with strict concurrency enabled.
- Strict OpenSpec validation: passed; PostHog DNS output was telemetry-only.
- Independent final review round: no actionable findings.
