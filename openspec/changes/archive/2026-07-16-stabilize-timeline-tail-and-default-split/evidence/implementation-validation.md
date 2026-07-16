# Implementation validation

## Viewer build

Command:

```text
xcodebuild build -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-tail-split-build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual
```

Result: passed with exit code 0.

The command-line signing override was used only in temporary DerivedData. No repository signing
configuration was changed.

## ViewerFoundationTests

Command:

```text
xcodebuild test -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-tail-split-class CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual -only-testing:NearWireViewerTests/ViewerFoundationTests
```

Result: passed. The xcresult summary reported 98 passed, 0 failed, and 1 skipped test.

The covered scenarios include:

- the Timeline contains exactly one native row per Event and follows the last real Event;
- an operator reading away from the bottom remains at the same position when a new Event arrives;
- jump-to-latest restores following;
- the initial two-panel workspace renders at approximately 70% Timeline and 30% Inspector;
- either single visible Event panel expands across the workspace.

An earlier default-signing invocation could not load the test bundle because the host and test
bundle had different Team IDs. The successful run above used matching ad-hoc signatures without
changing the Xcode project. During focused test development, the real-row visibility assertion was
also corrected to convert the scroll document viewport into the native table coordinate space.

## OpenSpec and diff checks

Commands:

```text
openspec validate stabilize-timeline-tail-and-default-split --strict
git diff --check -- Documentation/Viewer-Event-Explorer.md Viewer/NearWireViewer/UI/ViewerEventExplorerView.swift Viewer/NearWireViewer/UI/ViewerRootView.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift openspec/changes/stabilize-timeline-tail-and-default-split
```

Results:

- strict OpenSpec validation passed;
- diff check passed with no output;
- OpenSpec telemetry could not reach `edge.openspec.dev`, which did not affect validation.
