# Task 5.2 Event Explorer UI Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerEventExplorerController` is one MainActor presentation owner for the active runtime. It
  composes the bounded explorer model, traversal coordinator, live observation facade, store
  gateway facade, source-neutral inspector, renderer preparation service, and replaceable
  operation slots without exposing SQLite, transport, or session-manager ownership to SwiftUI.
- `ViewerApplicationModel` creates exactly one controller from the typed runtime component bundle,
  forwards coalesced session snapshots and store changes, and seals the controller before beginning
  runtime-component cleanup. A stopped or failed runtime cannot retain prior source, timeline,
  detail, renderer, session, or filter presentation state.
- The source sidebar presents the current runtime and frozen historical recording catalog, with
  pin/gap/drop state, bounded incremental catalog paging, all-device selection, or one through 16
  exact logical devices. Live sessions can appear before durable materialization; durable aliases
  replace them without inventing identity or widening a selected scope.
- The timeline is a native virtualized `List` over the model's 600-row resident window. It supports
  bounded bidirectional paging, merged device lanes, literal or durable full-text search, all V1
  metadata/receive-time/JSON/presence/diagnostic filters, Pause/Resume presentation, and Jump to
  Latest. Scrolling toward older data disables auto-follow; no control pauses networking,
  persistence, cleanup, admission, or downlink sending.
- Transient rows are explicitly labeled `Not recorded`. Direction, priority, byte count, resolved
  disposition, gap, drop, presentation conflict, and session-ended state use text plus system
  symbols rather than color alone. Full-text transient exclusion and bounded-live refine guidance
  remain visible instead of silently widening or publishing a partial match.
- The separate diagnostic gap lane presents both bounded durable gap rows and live ingress/window,
  conflict, diagnostic-loss, storage-outage, and recovery counters. Its 128-row model cap and lazy
  presentation remain independent of the Event timeline.
- Event selection creates one source-neutral canonical detail buffer. Recorded and transient Events
  share metadata, 64-KiB raw chunks, bounded pretty JSON, a 4,096-node incrementally expanded tree,
  and registered log/table/numeric/timeline renderers. Only recorded Events request the bounded
  nine-candidate causality graph; transient Events show the fixed `Recorded Data Required` state.
- Loading, empty, paused, unavailable, busy, cancelled, catalog-changed, invalid-request, and
  refine-required states use fixed English operator messages. Store failures and raw errors cannot
  enter the UI.
- Pause invalidates prior timeline/detail generations before freezing. A user may select and inspect
  a row already visible in the frozen window, but a detail request issued before Pause cannot apply
  afterward. Recording and device catalogs remain operable because Pause is a timeline-presentation
  control, not a global UI or store freeze.
- Filter and presentation values, timeline/source/device rows, controller reflection, canonical
  content buffers, and renderer values preserve content-free descriptions and reflection. Received
  or stored Event content is not made text-selectable. The stronger command, drag, clipboard, focus,
  and restoration suppression remains scoped to task 5.5.

The implementation uses native SwiftUI split, `List`, `Form`, `Grid`, `DisclosureGroup`, sheet,
semantic style, and SF Symbol APIs compatible with macOS 13. It adds no Viewer dependency and no
Figma or generated UI artifact.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity -only-testing:NearWireViewerTests/ViewerFoundationTests/testRootViewComposesWithoutStartingRuntime
```

Result: `TEST SUCCEEDED`; 3 tests executed, 0 failures.

The focused tests host both stopped and running root views at the authoritative minimum size;
verify runtime controller creation, source/device/filter presentation, and joined seal/clear;
exercise transient-to-durable reconciliation, gap presentation, Pause generation invalidation,
frozen-row detail inspection, stale page rejection, Resume/Jump release ordering, and redacted
diagnostics; and prepare a transient Event through the same canonical inspector while proving it is
marked unrecorded and cannot claim durable causality.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 220 tests executed, 2 skipped, 0 failures.

One skip is the explicit machine-local packaging probe gate. The configured-signing application
entitlement assertion is the other skip and remains intentionally deferred to the user-approved
Goal-level release-hardening verification. This unsigned validation does not claim release-signing
evidence.

## Static and specification validation

Commands and results:

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid
```
