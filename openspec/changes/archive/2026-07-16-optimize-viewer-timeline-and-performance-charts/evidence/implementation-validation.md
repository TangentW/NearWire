# Implementation Validation

## Focused regression tests

- Command: `xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-chart-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test ...`
- Result: 13 tests passed, 0 failed. This covered Timeline disposition classification, Performance chart presentation, aggregation bounds, and publication behavior.
- Result: the chart projection accounting boundary test passed separately, 1 passed and 0 failed.
- Result: the populated Performance controller/render test passed separately, 1 passed and 0 failed.

## Viewer test classes

The suite was split by test class because the macOS app test host consistently stalls while the pre-existing localization source-boundary test enumerates repository source outside its sandbox. No assertion failed before the stall. The equivalent regex and file scan completed over all 42 Viewer Swift files in 0.001 seconds or less per file from a temporary command-line process.

- `ViewerWorkspacePresentationTests`: 8 passed, 0 failed.
- `ViewerPerformanceInventoryTests`: 4 passed, 0 failed.
- `ViewerPerformancePresentationTests`: 11 passed, 0 failed.
- `ViewerPerformanceAggregationTests`: 8 passed, 0 failed.
- `ViewerFoundationTests`: 94 passed, 1 skipped by its existing stable-signer environment gate, 0 failed.
- `ViewerFlowControlTests`: 40 passed, 0 failed.
- `ViewerLocalizationTests`: 8 passed before the sandboxed test host stalled at `testViewerSourceBoundaryCoversFixedLocalizationCallsAndAppKitPanels`; the equivalent complete source scan passed outside that host.

Total executed assertions: 173 passed, 1 expected environment skip, 0 assertion failures.

## Build and concurrency

- Command: `xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/nearwire-viewer-final-build-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build`
- Result: `** BUILD SUCCEEDED **`.
- The project compiles with its existing strict-concurrency compiler setting; the build and all selected tests completed without Swift concurrency diagnostics.
