# Implementation validation

## Focused layout coverage

The focused workspace tests passed:

- delayed light/dark minimum, standard, and wide workspace rendering;
- stable default split through content updates;
- retained operator-adjusted divider position;
- locale propagation through the native split host;
- single-panel expansion.

The stable split regression also passed five repeated iterations.

During development, one compile run identified an access-level mismatch for the hosted environment
wrapper, and an initial locale assertion incorrectly searched for `NSTextField` even though SwiftUI
did not materialize one. The wrapper visibility was corrected, and the locale check now uses a
direct `NSViewRepresentable` environment probe. The final focused runs passed without source
warnings.

## ViewerFoundationTests

Command:

```text
xcodebuild test -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-stable-split-class-current CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual -only-testing:NearWireViewerTests/ViewerFoundationTests
```

Result: 99 passed, 0 failed, and 1 skipped test.

## Viewer build

Command:

```text
xcodebuild build -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-stable-split-build-ultimate CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual
```

Result: passed with exit code 0.

The signing override affected only temporary DerivedData and did not modify the repository.

## Specification and diff checks

Commands:

```text
openspec validate keep-viewer-default-split-stable --strict
git diff --check
```

Results:

- strict change validation passed;
- diff check passed with no output;
- unreachable OpenSpec telemetry did not affect validation.
