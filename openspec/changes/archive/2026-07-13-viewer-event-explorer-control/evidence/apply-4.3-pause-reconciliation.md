# Task 4.3 Pause and Timeline Reconciliation Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerEventExplorerCoordinator` is the MainActor presentation orchestrator over the existing
  runtime-owned store gateway and live-observation facade. Pause first changes the model's exact
  presentation generation and only then pauses live refresh delivery. It does not own or call
  network receive, directional flow control, queue expiration, store ingress, maintenance, cleanup,
  session shutdown, or downlink sending.
- Pause leaves timeline rows, selection, and scroll position unchanged. The model continues to
  coalesce only one latest change token, the greatest durable row bound, and saturating transient
  change and gap counts without accepting stale page/detail/live completions or scheduling a paused
  refresh wake.
- Resume, Jump to Latest, scope replacement, materialization replacement, and bounded refresh use
  the same runtime/presentation token. Each fresh traversal request submits exactly one
  `endTraversal` operation before starting a replacement query. Rapid successor actions receive a
  new generation, so a completed predecessor release cannot start a stale query. Resume starts one
  fresh current-scope traversal; repeated Pause/Resume calls are no-ops.
- Manual scrolling disables auto-follow without entering Pause. Jump to Latest re-enables
  auto-follow, invalidates older presentation work, releases the prior traversal once, loads one
  bounded 100-row tail page and one bounded 32-row gap page, evaluates one immutable live snapshot,
  and anchors only to the latest retained row.
- `ViewerExplorerTimelineWindow` retains at most 600 combined durable and transient summaries. A
  transient summary contains bounded presentation metadata rather than Event content. Durable and
  transient rows reconcile only through exact runtime logical ID, connection logical ID, direction,
  and wire sequence. Peer Event UUID is never the reconciliation key.
- When an exact durable row becomes visible, the transient row is removed, a transient selection or
  scroll anchor moves only to that exact durable row, and the live projection receives one exact
  visibility notification for the matching observation ID. Unmatched transient rows remain. A
  transient-only row preserves its pending/awaiting-visibility/not-recorded state for truthful UI.
- Durable gaps remain a separate 128-row paged diagnostic lane and live overflow/conflict/store
  state remains a separate content-free live gap lane. Neither is inserted into Viewer monotonic
  Event order. Refine-required and durable-only full-text exclusion states remain explicit.
- Coordinator, timeline rows, transient summaries, and gap-lane reflection is redacted; the focused
  test includes secret values and proves they do not appear in generic diagnostics.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity
```

Result: `TEST SUCCEEDED`; 1 test executed, 0 failures.

The test presents two transient rows, then makes one exact durable row visible. It proves one merged
durable row plus the unrelated transient row remain, the exact transient selection becomes the
durable selection, one visibility notification is issued, durable and live gaps stay outside the
timeline, manual scroll disables auto-follow, Pause freezes rows and saturates change/gap counts,
stale Resume work cannot start a query after Jump to Latest supersedes it, and three fresh traversal
requests produce exactly three release requests and three completions.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 214 tests executed, 2 skipped, 0 failures.

The configured-signing application entitlement assertion remains intentionally deferred to the
Goal-level release-hardening verification. This unsigned validation does not claim release-signing
evidence.

## Static and specification validation

Commands and results:

```text
xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerEventExplorerModel.swift Viewer/NearWireViewer/Application/ViewerExplorerScope.swift Viewer/NearWireViewer/Application/ViewerExplorerTimeline.swift Viewer/NearWireViewer/Application/ViewerEventExplorerCoordinator.swift Viewer/NearWireViewer/Application/ViewerRuntimeComponents.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid
```
