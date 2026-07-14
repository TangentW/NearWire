# Apply 3.2 Evidence: Bounded Performance Aggregation

Date: 2026-07-14

## Implemented behavior

- The Viewer owns ten closed, metric-specific numeric accumulators. Each accumulator preserves
  minimum, maximum, a stable finite average, saturating measurement and availability counts, and a
  deterministic representative selected nearest the bucket center with canonical journal-tuple
  tie-breaking.
- Battery state, thermal state, and low-power mode use bounded categorical accumulators that retain
  first, latest, previous, and a saturating change count without retaining raw samples.
- Buckets carry fixed numeric and categorical state plus an explicit discontinuity flag. A complete
  result is capped at 512 buckets, 128 normalized gap details, and 128 invalid details; further
  details contribute only to a saturating loss count.
- Presentation derivation is bounded to six charts, four marks per bucket, 12,288 total marks, and
  at most 64 deterministic accessibility buckets per chart.
- Every retained aggregation object has a deterministic byte charge. Result accounting includes
  its cache key, fixed buckets, gaps, invalid details, and the exact 16-entry availability inventory.
  The shared thread-safe ledger rejects reservations above 16 MiB and releases reservations
  explicitly. The documented worst-case concurrent ownership is exactly 25,805,312 bytes.
- Numeric finite-sum overflow saturates instead of producing infinity. No raw-sample array or raw
  event content is retained, and result and ledger reflection are content-free.

## Focused test command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-3-2-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceAggregationTests -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests
```

Result:

```text
Executed 8 tests, with 0 failures (0 unexpected) in 0.011 (0.018) seconds
** TEST SUCCEEDED **
```

Coverage includes:

- all ten numeric metrics with disjoint contributors;
- minimum, maximum, stable average, finite-sum saturation, measurement counts, and every
  nonmeasurement state;
- center-nearest representatives and canonical equal-distance ties;
- categorical first/latest/previous values and change counts;
- bucket discontinuity;
- 128 retained plus one lost gap and invalid detail;
- exact 512-bucket result charge, 16-MiB ledger admission/rejection/release, and exact
  25,805,312-byte peak ownership;
- exact 12,288-mark and 64-accessibility derivation.

## Unsigned build

```text
xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-3-2-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
```

Result:

```text
** BUILD SUCCEEDED **
```

This build intentionally does not claim signed embedded entitlement or stable-signer validation.
Those externally configured checks remain deferred to the Goal-level `release-hardening` change.

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
