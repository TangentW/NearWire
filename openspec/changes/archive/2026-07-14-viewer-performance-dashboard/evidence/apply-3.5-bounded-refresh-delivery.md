# Apply 3.5 Evidence: Bounded Projection, Refresh, Delivery, and Freshness

Date: 2026-07-14

## Implemented behavior

- A frozen projection session owns one bounded Store Event page, one bounded live slice, aggregate
  state, and gap state. It merges Store/live Events in canonical Viewer receive order, reconciles
  duplicate journal identities, and decodes at most 64 Events per turn without retaining a complete
  raw-sample range.
- Publication is impossible until Event and gap traversal both report complete. Current Store
  unavailability resolves to a fresh live-only freeze, historical unavailability resolves to a
  storage-unavailable state, other failures discard the partial session, and recovery never merges
  predecessor reducer state.
- Live-only publication is labeled separately from complete range and marks the leading bucket
  discontinuous to preserve unknown history.
- Refresh admission retains exactly one running token and one latest dirty successor. A running
  result may publish before the successor starts. Pause retains one latest desired refresh, and
  source-generation replacement rejects predecessor completions while preserving paused state.
- The delivery pump retains one latest pending value, dispatches no faster than once every 100 ms,
  and does not create a task per submitted sample. Counter reads and retained-value inspection are
  lock-protected.
- Current freshness carries source generation, latest Event journal key, absolute Viewer-monotonic
  deadline, and deadline revision. Delivery validates the receipt and injected current uptime at
  claim and apply. Claim validation failure does not poison later delivery, and apply-time equality
  restates every card as No recent sample.
- The deadline owner keeps one replaceable active wake, schedules only a future current deadline,
  rejects predecessor callbacks by token and full receipt, and records one paused-expiry dirty bit.
  Historical receipts schedule no wake and never compare persisted monotonic values with current
  process uptime.
- Projection sessions, publications, claimed deliveries, and delivery pumps expose content-free
  reflection.

## Focused pipeline command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-3-5-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformancePipelineTests
```

Final result after redaction and claim-failure coverage:

```text
Executed 10 tests, with 0 failures (0 unexpected) in 0.145 (0.147) seconds
** TEST SUCCEEDED **
```

Coverage includes:

- one 129-Event Store page plus a live duplicate reduced in exact 64/64/1 decode turns;
- durable/live reconciliation, complete-range publication, and no publication before both Event and
  gap completion;
- live-only coverage with a leading unknown-history break and fresh recovery after a partial scan;
- historical frozen-upper evaluation with no current uptime;
- current, historical, unavailable, discard, and recovery resolutions;
- 100,000 refresh submissions retaining one running and one latest dirty successor;
- paused range replacement and source-generation invalidation;
- 100,000 delivery submissions retaining and delivering only the latest value at the 100-ms bound;
- claim/apply deadline crossing at equality, stale-receipt rejection, and recovery after a throwing
  claim validation;
- replaceable future-only current wakes, zero historical wakes, equality rejection, and one paused
  expiry dirty bit;
- content-free delivery claim and pump reflection.

## Typed projection regression command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-3-5-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests -only-testing:NearWireViewerTests/ViewerPerformanceAggregationTests -only-testing:NearWireViewerTests/ViewerPerformanceRangeAndCacheTests -only-testing:NearWireViewerTests/ViewerPerformanceSemanticsTests -only-testing:NearWireViewerTests/ViewerPerformancePipelineTests
```

Result:

```text
Executed 32 tests, with 0 failures (0 unexpected) in 0.167 (0.180) seconds
** TEST SUCCEEDED **
```

## Unsigned build

```text
xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-3-5-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
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

xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerPerformancePipeline.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK

git diff --check
exit 0

git diff --name-only -- Package.swift NearWire.podspec Viewer/NearWireViewer/Store/ViewerStoreSchema.swift
exit 0; no output
```
