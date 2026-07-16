# Validation Evidence

## Focused regression

Command:

```sh
xcodebuild test -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-inspector-pretty-default-test \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  -parallel-testing-enabled NO \
  -only-testing:NearWireViewerTests/ViewerWorkspacePresentationTests/testInspectorOrdersPrettyRawPreviewAndMetadata
```

Result: passed.

Result bundle:

```text
/tmp/nearwire-inspector-pretty-default-test/Logs/Test/Test-NearWireViewer-2026.07.17_03-33-36-+0800.xcresult
```

## Viewer build

Command:

```sh
xcodebuild build -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/nearwire-inspector-pretty-default-build \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual
```

Result: passed.

## Review

The source diff introduces one Inspector default-selection constant, uses it for the workspace
state initializer, and asserts that it remains Pretty. Operator-driven tab selection and all
Inspector content paths are unchanged. `git diff --check` passed.
