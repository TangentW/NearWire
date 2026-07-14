# Validation 6.3 Evidence: Bounded Aggregation

Date: 2026-07-14

## Coverage

- Numeric accumulator tests cover exactly 0, 1, 512, 513, and 100,000 measurements while checking
  minimum, maximum, incremental average, finite sum, count, endpoints, and representative selection.
- Ten disjoint snapshots prove that each numeric metric keeps its own contributor, representative,
  nonmeasurement counts, and availability counts. Equal-distance and equal-time representatives use
  the complete canonical journal-key comparator.
- Existing mixed-state tests cover invalid, unsupported, disabled, permission-denied, temporarily
  unavailable, and not-collected input. Finite-sum overflow saturates without producing infinity.
- A deterministic 100,000-entry categorical storm verifies bounded first/latest/last state and an
  exact 99,999 change count. Separate 100,000-entry gap and invalid storms retain exactly 128 details
  of each kind and report the exact 199,744-detail loss count.
- Range/cache tests cover inclusive edges, the complete Event and cache comparators, exact-hit LRU
  touch, deterministic fifth insertion, current/ended/interrupted/empty anchors, and source clearing.
- Inventory tests cover metric-specific representative reconciliation from a live locator to its
  durable locator without changing Event identity.
- Accounting tests check every declared per-object charge, empty and fully populated result/reducer
  formulas, the 8,388,608-byte result cap, 16,777,216-byte shared-ledger cap, exact
  25,805,312-byte deterministic peak, 512-bucket acceptance, and 513-bucket rejection.
- The reducer retains fixed accumulators plus only bounded result/detail arrays. It contains no
  `rawSamples`, `rawSampleArray`, or `samples:` storage.

## Viewer result

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-performance-6-3-tests \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerPerformanceAggregationTests \
  -only-testing:NearWireViewerTests/ViewerPerformanceRangeAndCacheTests \
  -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests

ViewerPerformanceAggregationTests: Executed 7 tests, with 0 failures.
ViewerPerformanceInventoryTests: Executed 5 tests, with 0 failures.
ViewerPerformanceRangeAndCacheTests: Executed 7 tests, with 0 failures.
Selected tests: Executed 19 tests, with 0 failures (0 unexpected) in 0.164 seconds.
** TEST SUCCEEDED **
```

## Static gates

```text
xcrun swift-format lint --strict \
  Viewer/NearWireViewer/Application/ViewerPerformanceAggregation.swift \
  Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

rg -n "(rawSamples|rawSampleArray|samples[[:space:]]*:)" \
  Viewer/NearWireViewer/Application/ViewerPerformanceAggregation.swift \
  Viewer/NearWireViewer/Application/ViewerPerformancePipeline.swift \
  Viewer/NearWireViewer/Application/ViewerPerformanceDashboardModel.swift
no matches (expected rg exit 1)
```

Testing is unsigned and does not claim the deferred Goal-level signed entitlement or stable-signer
validation.
