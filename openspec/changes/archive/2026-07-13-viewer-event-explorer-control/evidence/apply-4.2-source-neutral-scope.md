# Task 4.2 Source-Neutral Explorer Scope Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerExplorerScope` is the authoritative source-neutral value. It identifies either one exact
  current runtime logical ID or one historical recording, combines that source with all devices or
  1 through 16 unique logical device IDs, and carries the complete validated V1 filter expression.
- `ViewerExplorerScopeCompiler` produces both sides of the current-runtime query from one immutable
  scope and one immutable materialization snapshot. The live request retains the complete logical
  device selection. The durable query contains only exact materialized store device-session row IDs;
  it is absent when the current recording or every selected device is still unavailable. No synthetic
  ID, omitted logical selection, guessed mapping, replay, or widened fallback is produced.
- Historical scopes compile to durable input only. All-device scopes use the materialized recording
  without inventing a device predicate. Selected-device scopes preserve their exact logical identity
  while the durable subset grows from zero through partial to complete materialization.
- Filter validation reuses the durable query compiler and bounded live request validation. Direct
  durable device-session predicates are rejected because the source-neutral device scope owns that
  dimension. Metadata, JSON, presence, direction, priority, disposition, time, size, type, text, and
  boolean composition retain the existing exact AND/OR semantics and bounds.
- Full-text search remains durable-only. The live evaluator consumes one immutable snapshot and
  returns the existing explicit transient exclusion instead of guessing, partially publishing, or
  widening the filter. Existing live work and refine guidance bounds remain authoritative.
- `ViewerEventExplorerModel` compiles replacements before mutation, then changes presentation
  generation and atomically installs the exact scope, materialization, compiled durable/live inputs,
  logical device selection, and source selection. A materialization change starts a fresh exact
  traversal presentation and clears resident timeline/gap/detail state; unchanged snapshots are
  no-ops, and stale source mappings fail without changing the model. Pause/release and cross-store
  transient/durable row reconciliation remain the separately scoped task 4.3 behavior.
- Scope, source, filter, materialization, and compiled-input reflection is content-free and redacted.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerScopePreservesLogicalSelectionAcrossPartialMaterialization
```

Result: `TEST SUCCEEDED`; 1 test executed, 0 failures.

The test covers unavailable, partial, unchanged, stale, all-device, and historical materialization;
preserves the full logical live selection while compiling only exact durable IDs; validates the
1-through-16 boundary and duplicate rejection; exercises the broad filter shape including FTS,
metadata, JSON, and presence; proves immutable live-snapshot FTS exclusion; verifies atomic model
generation replacement; rejects direct durable device-session predicates; and checks redacted
diagnostics.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 213 tests executed, 2 skipped, 0 failures.

The configured-signing application entitlement assertion remains intentionally deferred to the
Goal-level release-hardening verification, where an appropriately signed Viewer can be inspected.
The current unsigned build does not claim that release-signing evidence.

## Static and specification validation

Commands and results:

```text
xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerEventExplorerModel.swift Viewer/NearWireViewer/Application/ViewerExplorerScope.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid
```
