# Validation Evidence

## Focused regression

Command:

```sh
xcodebuild test -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-inspector-tab-order-test \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  -parallel-testing-enabled NO \
  -only-testing:NearWireViewerTests/ViewerWorkspacePresentationTests/testInspectorOrdersPrettyRawPreviewAndMetadata
```

Result: passed.

Result bundle:

```text
/tmp/nearwire-inspector-tab-order-test/Logs/Test/Test-NearWireViewer-2026.07.17_03-26-22-+0800.xcresult
```

## Viewer build

Command:

```sh
xcodebuild build -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-inspector-tab-order-build \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual
```

Result: passed.

## Review

The final source diff only reorders the four existing inspector cases and updates the exact-order
regression. Content preparation, bindings, localization keys, and the selected-tab state are
unchanged. `git diff --check` passed.
