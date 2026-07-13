# Task 5.3 Recording Operations and Export Evidence

Date: 2026-07-13

## Implemented contract

- The Explorer retains opaque `ViewerStoreRecordingTarget` values only for rows in the bounded
  resident recording catalog. Targets originate from the catalog snapshot and carry the exact store
  generation, recording row ID, and recording revision; SwiftUI cannot construct or revise them.
- Rename, note, pin/unpin, and append-only annotation actions route through the runtime gateway and
  existing store validators/writer ordering. `ViewerRecordingEditorModel` owns the operator's
  memory-only name, note, and annotation buffers with the authoritative 80-scalar/120-byte and
  4,096-scalar/16-KiB caps, rejects over-cap replacement before storage, and exposes content-free
  reflection. A mutation disables new actions until a fresh authoritative catalog target arrives,
  preventing a stale pin action from overwriting a just-saved name or note.
- Manual delete is disabled for a catalog row presented as active and remains authoritatively
  rejected by the store for active or leased recordings. The first action requests one opaque
  delete confirmation bound to exact recording and annotation revisions. Only the subsequent
  destructive confirmation can consume it. Dismissal clears it; stale, expired, replaced-store, or
  already-consumed confirmation failures delete nothing and trigger a fresh catalog.
- Successful deletion removes the exact target, replaces a deleted historical selection with the
  current runtime source, clears the selected detail/device materialization, and begins a fresh
  bounded traversal. It never guesses a replacement historical source.
- Export offers only `Complete Recording` and `Current Filtered Result`. Filtered export is
  available only while an exact durable query traversal exists and is not presentation-paused.
  Preflight freezes the immutable scope and returns the bounded Event count plus the store-owned
  disclosure; no destination exists in controller state at that point.
- The disclosure explicitly states that JSON is unencrypted, aliases are pseudonyms rather than
  redaction, Event/App content may identify people or secrets, output is outside Viewer
  quota/retention/cleanup, a provider may sync or back up it, and transient `Not recorded` rows are
  excluded. Only the explicit `I Understand — Choose Destination` action creates `NSSavePanel`.
- The save panel is a local function value with a fixed generic filename. Its selected file URL is
  passed directly to one prepared export execution and is not retained in the application model,
  preferences, recent rows, restoration state, or another history. No panel opens before
  disclosure acknowledgement.
- Export execution exposes indeterminate progress, exact prepared Event count, and Cancel. The
  runtime gateway retains its finite export lease, bounded streaming pages, exact cancellation,
  owner-only temporary sibling, and atomic destination replacement. The UI reports `Export
  Complete` only after gateway success; cancellation explicitly states that no partial file
  replaced a prior destination.
- Source replacement, runtime seal, or explicit dismissal cancels and clears pending confirmation,
  preflight, ticket, and execution tokens without exposing a database path, temporary path, SQL,
  filesystem phase, or raw error.

No import, CSV, `.nearwire`, automatic export, export destination persistence, or clipboard export
was added.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testRecordingEditorEnforcesMetadataCapsBeforeStorageAndRedactsContent -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayRoutesRevisionBoundHistoryMutationsAndRejectsOldGeneration -only-testing:NearWireViewerTests/ViewerStoreTests/testDeleteConfirmationIsSingleUseAndInvalidatedByAnnotation -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayFreezesPreflightedExportsAndCancellationPreservesDestination
```

Result: `TEST SUCCEEDED`; 5 tests executed, 0 failures.

The focused tests prove pre-storage editor caps and redaction, safe unavailable UI states, exact
revision-bound mutation routing and old-generation rejection, one-use delete confirmation invalidated
by annotation changes, immutable complete/filtered export tickets, exact cancellation, and
preservation of a prior destination across cancelled export work.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 221 tests executed, 2 skipped, 0 failures.

One skip is the explicit machine-local Application Support audit marker gate. The
configured-signing application entitlement assertion is the other skip and remains intentionally
deferred to the user-approved Goal-level release-hardening verification. This unsigned validation
does not claim release-signing evidence.

## Static and specification validation

Commands and results:

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid

rg -n "NSSavePanel|UserDefaults|destination" Viewer/NearWireViewer/UI/ViewerEventExplorerView.swift Viewer/NearWireViewer/Application/ViewerEventExplorerController.swift Viewer/NearWireViewer/Application/ViewerRecordingEditorModel.swift
# NSSavePanel and destination occur only in the disclosure/save-panel/direct execution path;
# no UserDefaults match exists.
```
