# Apply 3.1 Evidence: Core V1 Typed Decoder

Date: 2026-07-14

## Implemented behavior

- Viewer decodes only bounded `ViewerPerformanceEventContent` through Core `JSONValue`,
  `EventContentCodec`, and `PerformanceSnapshot` using an exact 65,536-byte decoder input limit.
- Oversized metadata and canonical data above the limit fail before JSON parsing or copying into a
  typed result.
- The result retains only sampled time, positive sample interval, and one fixed state for every key
  in `PerformanceMetricKey.allCases`. It does not retain raw JSON, unknown fields, unknown groups, or
  unknown unavailable keys.
- Numeric `Double`, exact `UInt64`, battery state, thermal state, and Boolean measurements remain
  distinct. Numeric and integer zero, categorical `.unknown`, all four unavailable reasons,
  Not collected, and unknown raw-only values therefore cannot collapse into one another.
- A duplicate known unavailable key or a known key that is both measured and unavailable invalidates
  the complete snapshot. Unknown unavailable keys may repeat without changing typed V1 state.
- Malformed JSON, unsupported schema, Core-invalid content, duplicate-known-unavailable,
  present-plus-unavailable, and oversized input use a closed reason set. Typed state and decode
  outcome reflection are redacted.

## Focused test command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-3-1-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests
```

Result:

```text
Executed 5 tests, with 0 failures (0 unexpected) in 0.007 (0.012) seconds
** TEST SUCCEEDED **
```

Coverage includes:

- measured `Double` and `UInt64` zero;
- future battery/thermal raw values decoded by Core as measured `.unknown`;
- Unsupported, Disabled, Permission denied, and Temporarily unavailable;
- Not collected and repeated unknown unavailable keys;
- duplicate known unavailable and present-plus-unavailable whole-snapshot invalidation;
- malformed JSON, schema 2, missing required Core header, metadata-only oversized input;
- canonical 65,537-byte rejection and exact 65,536-byte acceptance.

## Static gates

```text
env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerPerformanceProjection.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

git diff --check
exit 0

git diff --name-only -- Viewer/NearWireViewer/Store/ViewerStoreSchema.swift Package.swift NearWire.podspec
exit 0; no output
```
