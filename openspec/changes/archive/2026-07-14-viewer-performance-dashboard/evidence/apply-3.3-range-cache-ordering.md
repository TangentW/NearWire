# Apply 3.3 Evidence: Range Geometry, Anchors, Ordering, and Cache

Date: 2026-07-14

## Implemented behavior

- Performance ranges use checked inclusive bounds. One, five, and fifteen minutes plus Current
  Session are closed values, and five minutes is the default. A zero duration means one tick; fixed
  range subtraction saturates before applying the device start lower bound.
- Inclusive span, ceiling-divided width, bucket count, index, and per-bucket bounds use `UInt64`
  arithmetic so the complete nonnegative `Int64` monotonic domain is representable. There are at
  most 512 buckets; an interior exact edge selects the later bucket and the final upper remains in
  the final bucket.
- Current anchors accept only a matching already-frozen live slice. Ended sessions use exact device
  end, interrupted sessions use frozen recording upper, and empty sessions use device start for
  both bounds.
- Viewer receive time orders Events. Equal receive times use runtime UUID bytes, connection UUID
  bytes, direction ordinal, and unsigned wire sequence. App sampled time is not part of ordering.
- The cache key contains the complete source/device, range, lower/upper, Store generation, Event/gap
  uppers, runtime, live generation, and slice revision tuple. Current live-only keys use explicit
  zero Store identity; historical keys reject live identity.
- Canonical cache comparison implements the approved source-kind, source identity, device identity,
  range, bounds, Store identity, runtime, live generation, and slice revision sequence using UUID
  bytes and unsigned integer order.
- One cache owns only charged immutable aggregation results for one active source/device. Exact hits
  and successful publication touch deterministic LRU state. A fifth insertion releases the oldest
  touch before reservation and insertion, using canonical key order for a tie. Source or device
  replacement releases every prior entry and shared-ledger reservation before successor use.
- No cache or geometry type retains a raw Event/sample array.

## Focused test command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-3-3-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceRangeAndCacheTests -only-testing:NearWireViewerTests/ViewerPerformanceAggregationTests -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests
```

Result:

```text
Executed 14 tests, with 0 failures (0 unexpected) in 0.015 (0.024) seconds
** TEST SUCCEEDED **
```

Coverage includes:

- default and exact one/five/fifteen/session ranges;
- zero duration, saturated subtraction, 513-tick geometry, exact interior/final edges, and the
  inclusive `0...Int64.max` span;
- current, ended, interrupted, and empty anchors plus mismatch rejection;
- Viewer receive ordering and every canonical journal tuple component;
- every canonical cache comparator component, including historical row and runtime identities;
- complete current, live-only, and historical keys built from frozen receipts;
- exact hit/publication touches, deterministic fifth insertion, ledger releases, and both device
  and source replacement clearing.

The unsigned test build intentionally does not claim signed embedded entitlement or stable-signer
validation. Those externally configured checks remain deferred to the Goal-level
`release-hardening` change.

## Static gates

```text
env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerPerformanceAggregation.swift Viewer/NearWireViewer/Application/ViewerPerformanceProjection.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK

git diff --check
exit 0

git diff --name-only -- Package.swift NearWire.podspec Viewer/NearWireViewer/Store/ViewerStoreSchema.swift
exit 0; no output
```
