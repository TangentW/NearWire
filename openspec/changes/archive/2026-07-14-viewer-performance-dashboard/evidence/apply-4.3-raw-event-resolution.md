# Apply 4.3 Evidence: Metric-Specific Raw Event Resolution

Date: 2026-07-14

## Implemented behavior

- `ViewerPerformanceDashboardController` creates a raw Event request only from the selected numeric
  metric accumulator's representative journal key and current source generation. The request carries
  no Event JSON, decoded snapshot, bucket, tooltip, availability state, or renderer object.
- Store resolution is an exact point query over recording row, device-session row, recording logical
  ID, device logical ID, direction, wire sequence, and the built-in performance Event type. It returns
  only a durable row locator, excludes tombstoned recordings, copies no content, and runs under the
  existing bounded query reader.
- The query arbiter rejects point lookup while either an ordinary Explorer traversal or a Performance
  traversal is active. The gateway preserves generation, cancellation, Store-replacement, and joined
  operation semantics; task 4.4 owns the required release-before-lookup sequencing.
- Current live lookup validates the exact runtime journal key, retained observation, and performance
  Event type on the live projection queue. A durable visibility update removes the transient locator.
- `ViewerPerformanceRawEventResolver` validates source generation and exact current or historical
  logical source before Store access. It prefers Store durable identity. On a current Store miss it
  captures the exact live locator and performs a second Store confirmation so a concurrent
  live-to-durable commit resolves to the durable row.
- If the second Store confirmation still misses, the resolver accepts only the same exact still-live
  observation. Eviction, deletion, observation replacement, historical misses, Store replacement,
  and stale source identity return fixed bounded guidance; no adjacent or bucket-wide Event is ever
  selected.
- Store-unavailable current resolution may use the exact still-live identity. Without that identity
  it returns fixed Storage-unavailable guidance. Historical resolution never falls back to another
  runtime's live window.
- Before Explorer use, revalidation checks request/source equality and durable device identity. A
  transient observation that disappeared requires a fresh exact resolution instead of retaining or
  substituting a stale identity.
- One active resolver operation is tracked at a time. Cancellation and sealing invalidate the Store
  operation and expose a joined task that completes only after its callback releases tracked work.
- Request, result, outcome, Store driver, and resolver reflection is content-free.

## Focused regression command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-4-3-regression CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceRawEventResolverTests -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests -only-testing:NearWireViewerTests/ViewerFoundationTests/testPerformanceFreezeDrainsIngressAndReportsBoundedApplicableLoss -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceRawEventLocatorRequiresExactSourceKeyAndReleasedTraversal
```

Result:

```text
Executed 11 tests, with 0 failures (0 unexpected) in 0.055 (0.059) seconds
** TEST SUCCEEDED **
```

Coverage includes metric-specific CPU request construction, absence of an FPS request without an FPS
contributor, stale source rejection before Store access, exact durable resolution, live-to-durable
confirmation, exact still-live fallback, live eviction, historical deletion, current Store
unavailability, transient revalidation, cancellation join, live visibility removal, exact Store
source/type matching, tombstone exclusion, traversal-busy rejection, and success after exact traversal
release.

## Unsigned build

```text
xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-4-3-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
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

xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerPerformanceRawEventResolution.swift Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift Viewer/NearWireViewer/Application/ViewerLiveEventProjection.swift Viewer/NearWireViewer/Application/ViewerRuntimeComponents.swift Viewer/NearWireViewer/Store/ViewerPerformanceStore.swift Viewer/NearWireViewer/Store/ViewerExplorerQueryArbiter.swift Viewer/NearWireViewer/Store/ViewerStoreExplorerGateway.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift Viewer/NearWireViewerTests/ViewerStoreTests.swift
exit 0

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK

git diff --check
exit 0

git diff --name-only -- Package.swift NearWire.podspec Viewer/NearWireViewer/Store/ViewerStoreSchema.swift
exit 0; no output
```
