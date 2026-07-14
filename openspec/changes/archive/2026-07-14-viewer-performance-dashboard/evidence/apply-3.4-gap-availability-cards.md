# Apply 3.4 Evidence: Gap, Availability, Continuity, and Card Semantics

Date: 2026-07-14

## Implemented behavior

- Every bucket owns fixed counts for all 16 Core performance keys. Counts distinguish measurements,
  Invalid, all four explicit unavailable reasons, and Not collected. Cross-bucket merge saturates,
  and presentation uses the closed measured-then-Invalid-then-Permission denied-then-Temporarily
  unavailable-then-Disabled-then-Unsupported-then-Not collected precedence.
- Numeric holes mark only their metric discontinuous and remain pending through the next measured
  contributor. Invalid snapshots count Invalid for all 16 keys and break all ten numeric metrics.
  Adjacent Event distance at or beyond the checked interval horizon also breaks all metrics.
- Store and live projection consume only the existing fixed normalized gap carriers. Irrelevant gaps
  are counted without breaking App-to-Viewer series, and generic Store pagination is retained
  separately from applicable overflow.
- Ordered performance Events build bounded per-bucket Viewer-wall envelopes without retaining a raw
  sample array. An applicable or uncertain Store gap is placed only when its valid interval overlaps
  exactly one envelope. Interval-less, unknown-kind, invalid-interval, regressing, ambiguous,
  nonoverlapping, inconsistent, applicable-overflow, and combined-overflow evidence is Unplaced and
  suppresses every inter-bucket connection.
- A placed gap marks its bucket discontinuous before bounded detail retention. Therefore a detail
  dropped after 128 retained irrelevant gaps cannot reconnect a line. Combined Store/live applicable
  counts saturate, 128 remains placeable, and 129 is conservatively Unplaced.
- Card selection retains only the latest raw performance Event at/before the anchor within a checked
  inclusive 180-second lookback. Selection is independent of chart lower bound and uses Viewer
  receive/canonical journal ordering.
- Card evaluation decides freshness before typed state. A valid header uses the checked capped
  three-interval horizon, invalid/unreadable content uses exactly three seconds, equality is stale,
  and No recent sample wins over Invalid, unavailable, and Not collected. A fresh missing or
  unavailable latest Event never falls back to an older metric value.
- Content-bearing latest-Event and wall-envelope builders plus card/gap results have content-free
  reflection.

## Focused semantic test command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-3-4-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceSemanticsTests -only-testing:NearWireViewerTests/ViewerPerformanceRangeAndCacheTests -only-testing:NearWireViewerTests/ViewerPerformanceAggregationTests -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests
```

Result:

```text
Executed 22 tests, with 0 failures (0 unexpected) in 0.020 (0.030) seconds
** TEST SUCCEEDED **
```

Coverage includes:

- mixed-state and cross-bucket fixed-inventory counts plus complete presentation precedence;
- metric-only missing breaks, all-metric Invalid breaks, and interval equality breaks;
- unique wall-envelope placement and per-bucket application;
- irrelevant-only generic pagination without suppression;
- unknown kind, invalid interval, ambiguity, nonoverlap, wall regression, applicable overflow, and
  interval-less live evidence;
- exact 128 and combined 129 applicable boundaries;
- 128 retained irrelevant details followed by a dropped but still effective placed gap;
- latest-only card state without fallback, invalid three-second horizon, equality staleness, checked
  180-second lookback, and `UInt64.max` interval capping.

## Store/live normalization integration command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-3-4-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceGapClassificationSeparatesGenericAndApplicableOverflow -only-testing:NearWireViewerTests/ViewerFoundationTests/testPerformanceFreezeDrainsIngressAndReportsBoundedApplicableLoss
```

Result:

```text
Executed 2 tests, with 0 failures (0 unexpected) in 0.033 (0.035) seconds
** TEST SUCCEEDED **
```

This proves that the already-closed Store reason/direction mapper separates irrelevant-only generic
pagination from hidden applicable evidence, while live freeze retains bounded uncertain loss and
its applicable-overflow receipt.

## Unsigned build

```text
xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-3-4-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
```

Result:

```text
** BUILD SUCCEEDED **
```

This unsigned build intentionally does not claim signed embedded entitlement or stable-signer
validation. Those externally configured checks remain deferred to the Goal-level
`release-hardening` change.

## Static gates

```text
env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerPerformanceAggregation.swift Viewer/NearWireViewer/Application/ViewerPerformanceProjection.swift Viewer/NearWireViewer/Application/ViewerPerformanceSemantics.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK

git diff --check
exit 0

git diff --name-only -- Package.swift NearWire.podspec Viewer/NearWireViewer/Store/ViewerStoreSchema.swift
exit 0; no output
```
