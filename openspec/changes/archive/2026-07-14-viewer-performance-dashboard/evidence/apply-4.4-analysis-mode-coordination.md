# Apply 4.4 Evidence: Analysis-Mode Coordination

Date: 2026-07-14

## Implemented behavior

- `ViewerAnalysisModeCoordinator` is the single MainActor owner of Events/Performance mode changes.
  It serializes transitions with a monotonic revision and tracked predecessor task so a superseded
  transition cannot retarget the shared query arbiter.
- Events-to-Performance first invalidates Event query, gap, detail, renderer, delivery, and live
  evaluation work, then joins the Event traversal release. Only the accepted successor revision may
  compile a Performance target, replace the Performance scope, activate the controller, and submit a
  projection.
- Performance-to-Events first deactivates the dashboard, invalidates deadline, crosshair, delivery,
  and projection state, then cancels and joins the active projection and traversal release. Event
  traversal activation begins only after that joined receipt completes.
- An inactive Event or Performance presentation may retain immutable rows, model values, and bounded
  same-source cache entries, but owns no traversal lease and accepts no late callback. Mode switch
  clears active work and Performance crosshair ownership.
- Performance target compilation uses the existing Event Explorer source and device selection. It
  requires exactly one selected logical device and exact catalog materialization. Current targets
  additionally require the exact active connection. Historical targets derive closed, interrupted,
  or empty anchors from the selected recording and device rows. Invalid selection publishes the
  fixed `Select one device to view performance` guidance and starts no Performance traversal.
- Source, device, catalog, and current-session updates notify the same coordinator. A Performance
  selection replacement clears predecessor scope, model, cache, raw identity, delivery, and active
  work before compiling or admitting its successor.
- Pause remains presentation-local. An unchanged paused scope retains at most one dirty refresh. A
  paused range, source, or device replacement now records one desired successor without starting a
  traversal; Resume starts the fresh projection.
- Metric-specific raw reveal captures only the source generation and contributing journal key,
  validates the authoritative source, releases Performance traversal ownership, switches to Events,
  resolves and revalidates the exact identity, activates ordinary Event traversal, and then reveals
  that exact Event. Guidance paths never choose a neighboring Event.
- `ViewerApplicationModel` creates the Performance driver and raw resolver from the existing runtime
  live projection and Store explorer gateway, then installs one coordinator beside the existing
  Event Explorer and composer. It creates no second session manager, protocol owner, Store gateway,
  live projection, Event cache, or composer.
- Window shutdown seals and joins the analysis coordinator, raw resolver, Performance controller,
  Event Explorer, renderer delivery, composer, and runtime cleanup before the presentation cleanup
  receipt completes. Diagnostics and reflection remain content-free.

## Focused regression command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-4-4-regression CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerAnalysisModeCoordinatorTests -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests -only-testing:NearWireViewerTests/ViewerPerformanceRawEventResolverTests -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerAnalysisDeactivationJoinsTraversalBeforeReactivation -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCoordinatorPauseBeforeCompletionAndRapidGenerationsPublishOnlyLatest -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt
```

Result:

```text
Executed 18 tests, with 0 failures (0 unexpected) in 0.266 (0.270) seconds
** TEST SUCCEEDED **
```

Coverage includes exact historical target anchors, zero/multiple-device guidance, Event release before
Performance admission, Performance traversal release before Event activation, rapid superseding mode
changes, fixed guidance without traversal, real Explorer cancellation/join/release/reactivation,
paused range and source replacement, current Store fallback, delivery claim/apply revalidation,
projection cancellation and lease release, raw resolution cancellation and exact durable/live
identity, one runtime bundle, and joined window cleanup.

## Unsigned build

```text
xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-4-4-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
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

xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerAnalysisModeCoordinator.swift Viewer/NearWireViewer/Application/ViewerApplicationModel.swift Viewer/NearWireViewer/Application/ViewerEventExplorerController.swift Viewer/NearWireViewer/Application/ViewerEventExplorerCoordinator.swift Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift Viewer/NearWireViewer/Application/ViewerRuntimeComponents.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK

git diff --check
exit 0

git diff --name-only -- Package.swift NearWire.podspec Viewer/NearWireViewer/Store/ViewerStoreSchema.swift
exit 0; no output
```
