# Validation Evidence

## OpenSpec

Command:

```sh
openspec validate simplify-viewer-header-and-composer-layout --strict
```

Result: passed. OpenSpec's optional PostHog flush could not resolve `edge.openspec.dev` in the
restricted environment after validation completed; it did not affect the validation result.

## Build

Command:

```sh
xcodebuild build -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-header-composer-build-final \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual
```

Result: passed with the expected multiple-destination warning.

## Focused UI and Localization Tests

Command:

```sh
xcodebuild test -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-header-composer-review-fixes \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  -parallel-testing-enabled NO \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testRootViewComposesWithoutStartingRuntime \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningWorkspaceRendersAtSupportedSizesAndAppearances \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testCompactHeaderFitsSupportedLocalesAndIdentityFailureAtMinimumWidth \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testFixedHeightComposerContainsValidationAndFailureStateWithInternalScrolling \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testViewerSourceBoundaryCoversFixedLocalizationCallsAndAppKitPanels
```

Result: passed.

The first layout iteration exposed a real three-point overflow at the maintained 1,000 by 720
window. The header vertical padding was compacted from 20 to 16 points and the focused tests then
passed. A later regression assertion synchronously opened a source file from a `MainActor` UI test
and blocked the test host. A one-second process sample identified that exact `open` call. The
assertion was moved into the existing non-UI source-boundary scan, after which the focused run
completed normally.

## Viewer Foundation Regression

Command:

```sh
xcodebuild test -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-header-composer-class-final \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  -parallel-testing-enabled NO \
  -only-testing:NearWireViewerTests/ViewerFoundationTests
```

Result bundle:

```text
/tmp/nearwire-header-composer-class-final/Logs/Test/Test-NearWireViewer-2026.07.17_02-30-48-+0800.xcresult
```

Result: 102 total, 101 passed, 0 failed, 1 skipped. The skipped stable-signer packaging test requires
two configured signing identities and is expected in an ad-hoc local test run.
