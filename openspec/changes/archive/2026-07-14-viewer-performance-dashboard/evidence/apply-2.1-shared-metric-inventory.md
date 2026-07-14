# Apply 2.1 — Shared Performance Metric Inventory

## Implementation

- Added the exact ordered 16-key `PerformanceMetricKey`, `PerformanceMetricGroup`, and
  `PerformanceMetricKind` vocabulary to NearWireCore's `NearWireInternal` SPI.
- Moved group membership and numeric/categorical/unavailable-only classification into Core.
- Removed the SDK-internal duplicate key/group enums. `NearWirePerformance` now consumes Core SPI
  while retaining identical snapshot JSON, validation, collection, and public API behavior.
- Added a Viewer-internal descriptor projection built directly from `PerformanceMetricKey.allCases`.
- Added Core, SDK, and Viewer regression tests for order, grouping, kind, and shared consumption.

## Validation

```text
swift test --filter MetricInventory
```

Exit 0 after allowing SwiftPM to use the local compiler cache:

```text
Executed 2 tests, with 0 failures (0 unexpected)
```

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Task21-arm64 \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests
```

Exit 0:

```text
Executed 1 test, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

An initial command used the ambiguous `platform=macOS` destination, which also attempted x86_64 and
failed to resolve local package modules for that architecture. The maintained arm64 command above
matches the repository's existing Viewer test gate and passed.

```text
xcrun swift-format lint --strict <six changed Swift files>
```

Exit 0 with no output.

```text
plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
```

Exit 0: `Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK`.

```text
rg -n "enum PerformanceMetricKey|enum PerformanceMetricGroup" Core SDK Viewer
```

Exit 0 with matches only in Core's `PerformanceSnapshot.swift`; SDK and Viewer declare no duplicate
metric-key or group enum.

```text
git diff --check
```

Exit 0 with no output.
