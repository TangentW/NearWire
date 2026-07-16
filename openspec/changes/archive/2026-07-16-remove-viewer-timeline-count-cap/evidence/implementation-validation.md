# Implementation Validation

## Focused count-cap regressions

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerFoundationTests/testTimelinePublishesEveryByteValidRowBeyondLegacyCountCap -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState -only-testing:NearWireViewerTests/ViewerFoundationTests/testHundredThousandLiveOffersUseOneBoundedDrainAndRefreshWake -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveEvaluatorReturnsNoPartialCompletionOnCancellationDeadlineOrShapeOverflow
```

Clean result: 4 passed, 0 failed. The selected tests covered 600-row Timeline publication, byte-budget eviction, the 100,000-offer bounded drain path, and evaluator carrier limits. The 100,000-offer diagnostic measured about 51.5 ms total callback time and 32,768 bytes of process-footprint growth in that run.

An earlier fixture attempt used one Event accounting for the full 32 MiB retention window. It correctly failed ingress admission because the independent callback ingress is 20 MiB. The fixture was corrected to two 16 MiB accounted Events; the production implementation was unchanged, and the clean four-test rerun passed.

Focused JSON import command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-final-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerFoundationTests/testMemorySessionImportAcceptsMoreThanLegacyCountWithinByteBudget
```

Result: 1 passed, 0 failed, proving a 600-Event complete-Session file is accepted when its accounted bytes fit.

Review-driven saturated pending-metadata command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-final-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerFoundationTests/testPendingMetadataCoversRetainedWindowPlusBlockedIngress
```

Result: 1 passed, 0 failed. It covers 1,024 retained authority keys plus 64 ingress keys with dispositions and conflicts while the projection executor is blocked.

## Viewer test classes

- `ViewerWorkspacePresentationTests`: 8 passed, 0 failed.
- `ViewerFoundationTests`: 97 executed, 96 passed, 1 skipped by the existing stable-signer environment gate, 0 failed.
- `ViewerFlowControlTests`: 40 passed, 0 failed.
- `ViewerPerformanceInventoryTests`: 4 passed, 0 failed.
- `ViewerPerformancePresentationTests`: 11 passed, 0 failed.
- `ViewerPerformanceAggregationTests`: 8 passed, 0 failed.
- `ViewerLocalizationTests`: 8 passed, 0 failed, with the known sandboxed source-enumerator test excluded from the app test host.

Combined class result: 175 passed, 1 expected environment skip, 0 assertion failures.

Exact class commands:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-final-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerWorkspacePresentationTests
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-final-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerFoundationTests
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-final-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerFlowControlTests
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-final-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-final-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-final-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerPerformanceAggregationTests
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-final-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test -only-testing:NearWireViewerTests/ViewerLocalizationTests -skip-testing:NearWireViewerTests/ViewerLocalizationTests/testViewerSourceBoundaryCoversFixedLocalizationCallsAndAppKitPanels
```

The excluded localization source-boundary logic was rerun with `xcrun swift /private/tmp/nearwire_localization_scan.swift` from a temporary command-line Swift process after the final source edits. It scanned all 42 Viewer Swift files with all three production regular expressions; every file completed in 0.001 seconds or less. The app-host-only enumerator stall is documented in the preceding archived change and is not caused by this change.

## Build and concurrency

Command: `xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-count-cap-final-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build`.

Result: `** BUILD SUCCEEDED **`. The target compiled with its existing strict-concurrency setting and produced no Swift concurrency diagnostic.

## OpenSpec

Planning and final validation command: `openspec validate remove-viewer-timeline-count-cap --strict`.

Both runs reported `Change 'remove-viewer-timeline-count-cap' is valid`. The following PostHog DNS warning was telemetry-only and did not affect either validation result.
