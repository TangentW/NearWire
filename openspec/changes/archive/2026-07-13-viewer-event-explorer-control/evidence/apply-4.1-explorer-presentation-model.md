# Task 4.1 Explorer Presentation Model Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerEventExplorerModel` is one `@MainActor` owner for the active runtime logical ID,
  presentation generation, pause/auto-follow state, catalog/timeline/gap windows, selections, one
  selected detail, one scroll anchor, and latest refresh state. Runtime/source/presentation changes,
  Pause, and Resume issue a new exact `(runtimeLogicalID, generation)` token; stale or paused
  completions cannot mutate resident state.
- The four typed resident windows enforce independent hard caps of 200 recordings, 200 devices, 600
  Events, and 128 gaps. Page admission is separately bounded at 200 catalog rows, 200 Event rows, and
  32 gap rows, rejects duplicate or incorrectly ordered rows, and never constructs a complete result
  set.
- Every window owns exactly two typed boundary cursors and one content-free exact reload anchor.
  Trailing loads evict the leading edge; leading loads evict the trailing edge. The opposite boundary
  cursor remains intact, the closest evicted identity becomes the one reload anchor, and an exact
  reloaded identity clears that marker before any deterministic opposite-edge eviction.
- Event rows retain Viewer monotonic receive order with row-ID ties. Recording and device catalogs
  retain their store-defined descending order, while gaps retain their diagnostic wall-time/row-ID
  lane order. Malformed page order fails closed without mutating the previous window.
- One recording identity, at most 16 unique device logical IDs, and one Event identity/detail are
  retained. Eviction never selects a neighbor. An evicted selection remains the same content-free
  identity with an explicit reload-needed state; the one selected detail may remain attached only to
  that exact Event. An evicted scroll anchor moves only to the retained boundary corresponding to the
  unloaded edge.
- The model's latest-only refresh coalescer retains one latest change token, monotonic durable upper
  row ID, and saturating transient-change count. It owns at most one scheduled wake, delivers at most
  once per 100 ms and once per scheduled main turn, invokes at most one refresh callback per cadence,
  and schedules nothing new while paused. A pending wake becomes a no-op after Pause or sealing;
  Resume performs one coalesced delivery under the new generation.
- Sealing invalidates the generation, disables refresh/control state, and clears every resident row,
  cursor, reload anchor, selection, detail, scroll anchor, and pending refresh value. The model,
  resident windows, tokens, and refresh signals expose redacted/content-free diagnostics.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerModelCapsEveryResidentListAndReloadsOnlyExactSelection -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerModelCoalescesOneLatestRefreshAtTenHertzAndFreezesOnPause
```

Result: `TEST SUCCEEDED`; 2 tests executed, 0 failures.

The resident test fills every exact cap, crosses each cap, exercises both Event eviction directions,
keeps one selected detail through eviction and exact reload, moves only the exact scroll boundary,
tracks recording/device reload needs, rejects 17 devices, stale generations, 201-row pages, duplicate
or reversed rows, and proves sealing clears all content. The cadence test submits two 100,000-change
bursts, proves one pending wake per burst, exact latest values and saturating count delivery, 100-ms
successor delay, Pause/Resume generation changes, no paused delivery, input bounds, and sealed-wake
suppression.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 212 tests executed, 2 tests skipped, 0 failures. One skip is the explicitly
deferred configured-signing entitlement gate. The other is the opt-in Application Support artifact
audit that requires its machine-local marker.

## Static and specification validation

- `xcrun swift-format lint --strict` passed for the new model and affected Viewer test file.
- The Viewer Xcode project includes the new Application source and completed `build-for-testing`.
- `git diff --check` passed.
- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  reported `Change 'viewer-event-explorer-control' is valid`.

## Environment boundary

Configured signing and entitlement validation remains deferred to final `release-hardening` by the
user-approved Goal policy. Compilation and tests use `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64`; this evidence does not claim configured signing passed.
