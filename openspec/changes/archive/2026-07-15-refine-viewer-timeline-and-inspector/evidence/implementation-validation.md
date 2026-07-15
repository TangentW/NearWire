# Implementation Validation

## Focused Behavior Tests

Commands:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:NearWireViewerTests/ViewerLocalizationTests/testSupportedLocaleResolutionUsesSimplifiedChineseForEveryChineseLocale \
  -only-testing:NearWireViewerTests/ViewerWorkspacePresentationTests/testInspectorOffersOnlyMetadataRawPrettyAndPreview \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testNativeTextControlsBoundExactEditsAndExposeOnlyExplicitInspectorCopy \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testTimelineTailFollowingPreservesManualReadingAndJumpRestoresFollow \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testRendererRegistryPreparesBoundedRawPrettyLogTableAndNumericFallbacks \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testRendererExtremeValidatedShapesRemainBounded
```

Result: exit 0, 6 tests passed.

These tests cover the four-tab Inspector contract, simplified-Chinese locale mapping, read-only selectable and wrapping text controls, frame-against-viewport tail-follow decisions with stale-report rejection, Generic JSON Preview that remains on Raw chunk zero after Raw navigation, and retained specialized renderer bounds.

## Full Viewer Test Coverage

The final whole-suite command excluded two environment-specific packaging/source-access probes and ran every other test:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasRequiredFoundationNetworkEntitlements \
  -skip-testing:NearWireViewerTests/ViewerLocalizationTests/testViewerSourceBoundaryCoversFixedLocalizationCallsAndAppKitPanels
```

Final result after all review fixes: exit 0, 169 tests executed with zero failures; one stable-signer probe was skipped by its existing opt-in contract. The result bundle is `Test-NearWireViewer-2026.07.16_02-24-56-+0800.xcresult`.

The packaging test was then run with one consistent temporary ad-hoc identity, without changing repository signing configuration:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasRequiredFoundationNetworkEntitlements
```

Result: exit 0, 1 packaging test passed.

The source-boundary localization test was invoked alone, including once with `ENABLE_APP_SANDBOX=NO`. In both invocations the macOS test host exited after the test started and Xcode waited indefinitely for `runningDidFinish`; neither invocation produced a test result. The exact source enumeration and three regular-expression checks were therefore reproduced outside the application test host against the same `Viewer/NearWireViewer` directory and `Localizable.xcstrings` catalog. Result: exit 0, `MISSING []`, `PANELS []`. This verifies the test's localization-key and AppKit-panel assertions while recording the host limitation instead of treating a missing result as a pass.

Together, the 169-test run, focused source-boundary reproduction, and signed entitlement test cover every non-opt-in Viewer test contract.

## Build and Concurrency

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Result: exit 0, `** BUILD SUCCEEDED **`.

The compile command used Swift 5 language mode with `-enable-upcoming-feature StrictConcurrency` for the Viewer and test targets. No new concurrency diagnostic was emitted.

## Source Hygiene

Command:

```text
git diff --check
```

Result: exit 0.
