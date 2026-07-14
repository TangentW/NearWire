# Validation 6.2 Evidence: Shared Inventory and Typed Decode

Date: 2026-07-14

## Coverage

- Core proves the exact ordered 16 raw keys, group membership, and the 10 numeric/3 categorical/3
  unavailable-only kinds. SDK and Viewer independently project that same Core SPI order, groups, and
  kinds without a local raw-string metric enum.
- Viewer decode tests preserve real numeric and unsigned zero, categorical unknown, all four closed
  unavailable reasons, absent as Not collected, and repeated unknown raw-only keys.
- Both identical and conflicting duplicate known unavailable entries invalidate the whole snapshot.
  A known present-plus-unavailable metric also invalidates the whole snapshot.
- Malformed JSON, unsupported schema, missing/invalid Core headers, exact 65,536-byte input,
  65,537-byte canonical input, and metadata-only oversized content are covered. Oversized Store
  content has no copied body for the decoder to inspect.
- Latest-Event semantics prove a newer missing metric does not fall back to an older measurement, a
  fresh invalid Event reports Invalid snapshot, and an invalid Event at deadline equality reports No
  recent sample before typed state.

## Root package result

```text
swift test --filter MetricInventory

Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.003) seconds
```

The initial restricted-sandbox attempt could not write Swift's user module cache. The identical
command was rerun with the permitted local compiler cache and passed; no test or gate was weakened.

## Viewer result

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-6-2-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests -only-testing:NearWireViewerTests/ViewerPerformanceSemanticsTests/testLatestEventCardsApplyFreshnessBeforeTypedStateWithoutFallback

Executed 6 tests, with 0 failures (0 unexpected) in 0.010 (0.012) seconds
** TEST SUCCEEDED **
```

## Source and static gates

```text
rg -n "enum PerformanceMetric(Key|Group|Kind)" Core SDK Viewer --glob '*.swift'
Core/Sources/NearWireCore/Builtins/Performance/PerformanceSnapshot.swift:13: PerformanceMetricGroup
Core/Sources/NearWireCore/Builtins/Performance/PerformanceSnapshot.swift:42: PerformanceMetricKind
Core/Sources/NearWireCore/Builtins/Performance/PerformanceSnapshot.swift:49: PerformanceMetricKey
```

There are no SDK or Viewer matches.

```text
xcrun swift-format lint --strict SDK/Tests/NearWirePerformanceTests/PerformanceSamplerProjectionTests.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

Testing is unsigned and does not claim the deferred Goal-level signed entitlement or stable-signer
validation.
