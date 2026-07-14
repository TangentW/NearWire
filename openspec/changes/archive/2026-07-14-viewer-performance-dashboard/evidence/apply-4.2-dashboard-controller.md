# Apply 4.2 Evidence: Dashboard Driver, Runner, Controller, and Joined Lifecycle

Date: 2026-07-14

## Implemented behavior

- One validated dashboard target represents either an exact current runtime/connection plus its
  Store recording/device identity, or one exact historical recording/device session plus its frozen
  ended, interrupted, or empty anchor.
- The concrete projection driver freezes current live observations before deriving the chart and
  180-second card-scan lower bounds, then freezes Store Event/gap uppers. Historical preparation uses
  only the supplied same-recording frozen anchor. A fresh-live-only retry does not start a Store
  traversal.
- One self-retained serial projection run performs preparation, Event pages, 64-Event decode turns,
  gap pages, finalization, and exact traversal release off MainActor. Progress crosses a bounded
  latest-only MainActor pump; no task is created per Event.
- Cancellation invalidates the active operation, waits for its callback, releases the exact
  traversal, discards partial reducer state, delivers a content-free cancellation outcome, and only
  then completes the joined cleanup task. A run cannot disappear while its operation or release is
  still outstanding.
- Active reducer accounting resizes as invalid and gap details are retained. Finalization resizes to
  the immutable result's exact bytes and transfers the same reservation from `activeReducer` to
  `completedResult`; failure and cancellation release it.
- The MainActor controller owns one source generation, one running run plus one dirty successor, one
  four-entry exact-key LRU cache, one 10-Hz latest-only delivery pump, one freshness deadline, and
  controller/model/delivery/crosshair ledger reservations under the shared 16-MiB cap.
- A completed result remains independently charged while pending delivery. At successful apply it
  transfers into the cache without double charging; exact cache hits replace the incoming result
  value with the already charged cached value. The current presentation is touched before insertion
  so LRU eviction cannot leave the model referencing an uncharged result.
- Delivery validates generation/Event/deadline/revision and injected uptime at claim and apply. A
  cleanup that begins after claim invalidates the gate, clears old presentation immediately, waits
  for the processing delivery to release its result and wrapper, and admits no successor first.
- Pause cancels pending delivery while retaining unchanged presentation and one bounded dirty token.
  A paused range change clears presentation, records the desired range, and performs no traversal;
  Resume creates one new-sequence fresh projection. Source/device replacement clears model, cache,
  deadline, delivery, identities, and accounting before joined successor admission even while
  paused.
- Mid-scan current Store unavailability releases the traversal and starts one newly frozen live-only
  projection. Historical Store unavailability publishes only Storage unavailable. Cached
  presentation never owns a traversal lease.
- Explicit `sealAndWait()` returns the combined run-and-delivery cleanup task after synchronously
  clearing every owned value. Deinitialization also invalidates delivery/deadline state, initiates
  run cancellation, and releases controller/cache/presentation reservations as a fallback.
- Target, driver, operation, preparation, owned publication, run outcome/output, run, controller,
  and diagnostics reflection is content-free.

## Focused controller command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-4-2-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests
```

Final focused result:

```text
Executed 5 tests, with 0 failures (0 unexpected) in 0.024 (0.026) seconds
** TEST SUCCEEDED **
```

Coverage includes off-MainActor Store Event/gap traversal, exact completed-result ownership,
blocked-page cancellation and joined traversal release, current mid-scan Store failure followed by a
fresh live-only freeze, claim/apply deadline crossing, crosshair accounting, paused range behavior,
paused source replacement, historical Storage unavailable, claimed-delivery cleanup, cache clearing,
and zero-byte/zero-reservation teardown.

## Controller and projection regression command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-4-2-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceAggregationTests -only-testing:NearWireViewerTests/ViewerPerformanceRangeAndCacheTests -only-testing:NearWireViewerTests/ViewerPerformancePipelineTests -only-testing:NearWireViewerTests/ViewerPerformanceDashboardModelTests -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests
```

Result:

```text
Executed 30 tests, with 0 failures (0 unexpected) in 0.171 (0.178) seconds
** TEST SUCCEEDED **
```

This regression includes exact ledger resize/transfer/release, transferred cache ownership without
double charging, deterministic LRU behavior, bounded projection turns, 100,000 refresh and delivery
submissions, current/historical freshness, model source validation, and controller lifecycle tests.

## Unsigned build

```text
xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-4-2-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
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

xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift Viewer/NearWireViewer/Application/ViewerPerformancePipeline.swift Viewer/NearWireViewer/Application/ViewerPerformanceAggregation.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK

git diff --check
exit 0

git diff --name-only -- Package.swift NearWire.podspec Viewer/NearWireViewer/Store/ViewerStoreSchema.swift
exit 0; no output
```
