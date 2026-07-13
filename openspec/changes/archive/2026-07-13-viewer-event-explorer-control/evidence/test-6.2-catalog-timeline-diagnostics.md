# Task 6.2 Catalog, Timeline, Gap, and Causality Evidence

Date: 2026-07-13

## Frozen catalog and timeline coverage

- `testRecordingCatalogUsesFrozenDescendingKeysetsAndRelevantChangeRestart` covers descending
  recording row-ID keysets, older/newer paging, an irrelevant Event commit between pages, relevant
  lifecycle mutation, explicit `catalogChanged`, store-generation rejection, bounded page sizes,
  accepted query plans, and content-free rows/cursors.
- `testRecordingCatalogIgnoresEventCommitsAndRestartsForRenamePinAndTombstone` creates six
  recordings with equal wall and monotonic start times. It proves row-ID tie-breaking without
  overlap, Event commit continuity, and separate rename, pin, and tombstone invalidation. Each
  invalidation is followed by an explicit cursor-free restart that exposes the new authoritative
  state.
- `testDeviceCatalogUsesConnectionKeysetsAndOnlyRelevantMutationRestarts` covers stable connection
  ordinals, older/newer paging, unrelated-recording commits, relevant gap mutation, explicit
  restart, accepted plans, bounds, and no content in catalog values.
- `testCatalogDefaultAndMaximumPageBounds` proves recording 50/100 and device 100/200
  default/maximum page sizes.
- `testQueryUsesDimensionAndValueOrWithStableBidirectionalKeysets` stores three Events at the exact
  same Viewer monotonic time and proves row-ID-stable forward paging plus exact backward reload.
- `testExplorerModelCapsEveryResidentListAndReloadsOnlyExactSelection` fills recording/device/Event
  and gap resident windows through and beyond their caps. It proves deterministic leading/trailing
  eviction, 600-Event long scrolling, exact selected-row/detail preservation, reload anchors,
  leading reload, and no stale-token/invalid-order publication.
- `testExplorerScopePreservesLogicalSelectionAcrossPartialMaterialization` covers all devices,
  one-through-three selected logical devices with partial durable materialization, the 16-device
  maximum, historical durable-only scope, and stable logical selection across materialization.
- `testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity` covers one selected
  device and the atomic current transient-to-durable identity transition without duplicate rows or
  lost selection.

## Gap and causality coverage

- `testGapTraversalFreezesLatestRevisionsAndUsesBoundedBidirectionalLanes` creates 34 gaps across
  recording-wide and two device lanes, starts a frozen traversal, then appends a newer revision of
  the first gap. The traversal keeps the captured revision, pages 32 plus 2 rows without overlap,
  supports forward and backward directions, filters one selected device plus recording-wide gaps,
  and uses both schema-2 gap indexes without scan/temp-sort plans.
- `testCausalityUsesExactDeviceNineRowCandidatesReplyFirstAndRowIDCycles` now covers exact-device
  candidate cardinalities 0, 1, 2, 8, and 9+. Zero through eight return complete lists with
  `hasMore=false`; nine returns the first eight with `hasMore=true`. Reply-to remains ordered before
  correlation, a duplicate UUID across another device is excluded, duplicate UUID candidates do
  not become false cycles, a genuine two-row reply cycle is marked by row ID, and a 33-row chain is
  capped at 32 nodes. The accepted causality plan uses the schema-2 lookup index without a scan or
  temporary B-tree.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testRecordingCatalogUsesFrozenDescendingKeysetsAndRelevantChangeRestart -only-testing:NearWireViewerTests/ViewerStoreTests/testRecordingCatalogIgnoresEventCommitsAndRestartsForRenamePinAndTombstone -only-testing:NearWireViewerTests/ViewerStoreTests/testDeviceCatalogUsesConnectionKeysetsAndOnlyRelevantMutationRestarts -only-testing:NearWireViewerTests/ViewerStoreTests/testCatalogDefaultAndMaximumPageBounds -only-testing:NearWireViewerTests/ViewerStoreTests/testQueryUsesDimensionAndValueOrWithStableBidirectionalKeysets -only-testing:NearWireViewerTests/ViewerStoreTests/testGapTraversalFreezesLatestRevisionsAndUsesBoundedBidirectionalLanes -only-testing:NearWireViewerTests/ViewerStoreTests/testCausalityUsesExactDeviceNineRowCandidatesReplyFirstAndRowIDCycles -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerModelCapsEveryResidentListAndReloadsOnlyExactSelection -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerScopePreservesLogicalSelectionAcrossPartialMaterialization -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity
```

Result: `TEST SUCCEEDED`; 10 tests executed, 0 failures.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 227 tests executed, 2 skipped, 0 failures.

One skip is the explicit machine-local Application Support audit marker gate. The configured
signing entitlement assertion remains deferred to Goal-level release hardening as approved by the
user. This unsigned run makes no release-signing claim.

## Static and specification validation

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid
```
