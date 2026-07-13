# Task 5.1 Native Workspace Shell Evidence

Date: 2026-07-13

## Implemented contract

- The Viewer remains one native SwiftUI `Window` and now uses a stable nested split hierarchy:
  source/devices on the left; Event timeline and Event inspector in the upper right; and one
  Viewer-to-App control composer region spanning the lower right. No second window, session manager,
  protocol owner, or store owner was introduced.
- `ViewerWorkspaceLayout` is the single layout contract for the four ordered regions, 1,000-by-640
  minimum window, bounded source/timeline/inspector widths, and bounded composer height. The App
  scene and root view consume the same values instead of duplicating frame constants.
- All four workspace regions have stable accessibility identifiers. The source column explicitly
  separates current source, future historical recordings, connected/recent device rows, and pending
  approval rows. The live source uses fixed state text, including `Live — not recording` when the
  current listener is active but storage is unavailable.
- Pairing code/status, Copy, Refresh, Pause New Devices, approval policy, TLS/pairing disclosure,
  storage settings/status/cleanup/retry, listener recovery, and identity reset controls remain in
  the compact header area.
- Existing device nickname, requested/effective rates, queue count/bytes/oldest wait, throughput,
  Event/drop counters, and disconnect controls remain reachable through one native
  `Device Settings & Telemetry` sheet opened from the selected device row. Disconnected/recent
  snapshots continue to use the existing capability checks; the layout adds no independent
  mutation path.
- Timeline, inspector, and composer are deliberately structural states in task 5.1. Their data,
  filtering, selection, renderer, and control-send behavior remain owned by tasks 5.2 through 5.4,
  so this task does not widen scope with placeholder query or protocol logic.
- The composer shell states that local queue admission is not delivery or processing
  acknowledgement, preserving the existing truthfulness boundary before the full form is wired.

The implementation follows native SwiftUI split/list/sheet patterns, semantic system styles, and
SF Symbol names. No Figma artifact or third-party UI dependency was introduced.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testRootViewComposesWithoutStartingRuntime
```

Result: `TEST SUCCEEDED`; 1 test executed, 0 failures.

The test hosts and lays out `ViewerRootView` at the authoritative minimum window size without
starting a runtime, asserts the exact four-region order, proves the minimum width covers all three
column minima, checks the bounded composer contract, and confirms the root has a nonzero fitting
size while the application model remains stopped.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 219 tests executed, 2 skipped, 0 failures.

One skip is the explicit machine-local Application Support audit marker gate. The
configured-signing application entitlement assertion is the other skip and remains intentionally
deferred to the Goal-level release-hardening verification. This unsigned validation does not claim
release-signing evidence.

## Static and specification validation

Commands and results:

```text
xcrun swift-format lint --strict Viewer/NearWireViewer/App/NearWireViewerApp.swift Viewer/NearWireViewer/UI/ViewerRootView.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid
```
