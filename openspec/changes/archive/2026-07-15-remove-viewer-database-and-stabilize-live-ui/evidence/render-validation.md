## Focused SwiftUI and AppKit rendering

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-memory-ui-build CODE_SIGNING_ALLOWED=NO test-without-building \
  -only-testing:NearWireViewerTests/ViewerLocalizationTests/testStringCatalogHasCompleteEnglishAndSimplifiedChineseCoverage \
  -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests/testPerformanceSummaryComposesAtCompactAndWideWidthsWithoutRuntime \
  -only-testing:NearWireViewerTests/ViewerPerformanceDashboardModelTests/testCurrentProjectionComposesSystemChartsWithoutStartingAnotherRuntime \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testRootViewComposesWithoutStartingRuntime
```

Result: exit 0, 4 tests executed with 0 failures.

The root Event workspace rendered at the supported minimum size. Empty and populated Performance presentations rendered at compact and wide sizes. The separate composer test rendered the control surface, found all three native editors, verified nonzero interactive frames, hit-tested the Event type editor, made it first responder, inserted `app.debug.command`, and observed the controller update.

The Event and Performance data containers both disable implicit refresh animation. The publication tests verify that retained rows/cards stay presented while internal refresh work runs, so ordinary Event arrival does not switch through visible loading branches.
