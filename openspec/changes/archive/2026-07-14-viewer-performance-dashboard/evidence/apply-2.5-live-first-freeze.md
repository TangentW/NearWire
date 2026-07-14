# Apply 2.5 Evidence: Live-First Freeze and Reconciliation

Date: 2026-07-14

## Implemented behavior

- `ViewerLiveObservationProviding` now exposes one exact-connection performance freeze.
- `ViewerLiveEventWindow` performs the freeze on its serial projection queue. While that queue is
  exclusively owned, it locks ingress, captures the current uptime anchor, detaches all bounded
  work accepted at that boundary, then unlocks ingress and projects only that detached work before
  building the slice. Work accepted after the boundary cannot run until the slice is complete.
- Runtime manager generation is the live generation. Every successful slice advances one nonzero
  revision and contains no more than 512 Events, 4,194,304 copied content bytes, 128 normalized
  gaps, or 4,493,312 accounted bytes.
- Exact `nearwire.performance.snapshot` candidates are ordered by Viewer monotonic receive time and
  the canonical runtime UUID bytes, connection UUID bytes, direction ordinal, and unsigned wire
  sequence tuple. Oversized content crosses the boundary as length-only metadata.
- Live ingress/window loss, Store unavailability/recovery, resident conflict, and diagnostic loss
  become closed, interval-less, uncertain gap carriers. Counts saturate, and 129 applicable loss
  occurrences set `hasMoreApplicableGaps` while retaining bounded detail.
- `ViewerPerformanceFreezeCoordinator` obtains the live slice first and only then submits Store
  Event/gap upper freezing using the slice anchor as the exact upper monotonic bound. Store
  unavailability returns a separately identifiable live-only receipt; cancellation, replacement,
  busy, and invalid requests remain failures.
- `ViewerPerformanceEventReconciler` validates identical journal key, receive times, and content,
  then prefers a durable locator in either arrival order. A mismatch fails closed instead of moving
  a contribution.
- No table, index, database, migration, package manifest, or podspec changed.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-2-5-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testPerformanceFreezeDrainsIngressAndReportsBoundedApplicableLoss -only-testing:NearWireViewerTests/ViewerFoundationTests/testPerformanceFreezeClassifiesOversizedContentWithoutCopyingIt -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests/testPerformanceReconciliationPrefersDurableLocatorWithoutChangingIdentity -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCurrentFreezeUsesLiveAnchorBeforeStoreUppers
```

Result:

```text
Executed 4 tests, with 0 failures (0 unexpected) in 0.017 (0.019) seconds
** TEST SUCCEEDED **
```

The Store integration test froze a live anchor of 5,000, then appended a second durable row whose
Viewer monotonic time was 4,500. The frozen traversal returned only the first row, proving that the
later Store row upper—not timestamp alone—closes the capture/commit race.

## Live projection regression

The first complete class run intentionally retained the embedded-entitlement test and produced the
already approved release-signing limitation:

```text
Executed 106 tests, with 1 test skipped and 2 failures (0 unexpected)
Failing tests:
ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement()
```

Both failures were `nil` embedded entitlement values under `CODE_SIGNING_ALLOWED=NO`. Per the Goal
decision, signed-product and embedded-entitlement verification remains deferred to the final
Goal-level `release-hardening` pass and is not weakened or reported as passing here.

The current-stage regression command excluded only that named signed-product test:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-2-5-regression CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformanceInventoryTests -only-testing:NearWireViewerTests/ViewerFoundationTests -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result:

```text
Executed 105 tests, with 1 test skipped and 0 failures (0 unexpected) in 3.062 (3.084) seconds
** TEST SUCCEEDED **
```

The one skipped stable-signer probe explicitly requires external stable-signer build settings and
remains part of the same final Goal-level verification.

## Build and static gates

Command:

```text
xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-2-5-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
```

Result: `** BUILD SUCCEEDED **`.

Commands and results:

```text
env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerLiveEventProjection.swift Viewer/NearWireViewer/Application/ViewerPerformanceProjection.swift Viewer/NearWireViewer/Application/ViewerRuntimeComponents.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift Viewer/NearWireViewerTests/ViewerStoreTests.swift
exit 0

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK

git diff --check
exit 0

git diff --name-only -- Viewer/NearWireViewer/Store/ViewerStoreSchema.swift Package.swift NearWire.podspec
exit 0; no output
```

## Corrected intermediate failures

- The first focused compile found one existing active-session call site that needed the captured
  ingress-boundary active set. It was corrected before evidence was claimed.
- The first oversized test attempted to construct a 70,000-byte Core `JSONValue` string and was
  correctly rejected by Core's 65,536-byte structural validation. The test was corrected to inject
  an internal committed observation with length-only oversized canonical metadata, which exercises
  the Viewer boundary without weakening Core validation.
