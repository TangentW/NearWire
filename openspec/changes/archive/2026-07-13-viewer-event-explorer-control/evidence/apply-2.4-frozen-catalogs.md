# Task 2.4 Frozen Catalog Evidence

Date: 2026-07-13

## Implemented contract

- The runtime gateway exposes tokenized recording and device catalog requests without exposing
  coordinator services, SQLite, SQL, paths, or raw errors to application code.
- Recording pages use immutable descending recording row IDs. Device pages use immutable
  descending connection ordinal plus row ID. Neither path uses `OFFSET`, activity ordering, a long
  transaction, or Event content.
- Recording snapshots bind coordinator/store generation and the frozen upper row IDs for
  recordings, recording versions, installation aliases, device sessions, device versions,
  tombstones, gaps, and drops. Device snapshots bind the same exact values within one recording.
  Their SHA-256 change-generation fingerprint and the source query fingerprint travel with every
  cursor.
- A relevant catalog mutation returns the closed `catalogChanged` restart category. Event-only
  writes do not invalidate recording pagination, and changes to another recording do not invalidate
  the selected device catalog. A cursor from a replaced coordinator returns `storeReplaced` and is
  never retargeted.
- Recording rows expose bounded lifecycle/name/note/pin/revision values, device count, latest safe
  `device-N`/`connection-N` hint, App/Bundle hints, and gap/drop flags. Device rows expose the exact
  internal logical UUID plus safe aliases and bounded lifecycle/App/Bundle/gap/drop metadata. They
  contain no installation identifier, endpoint, SQL/path/error, or Event type/content.
- Defaults are 50 recording rows and 100 device rows. Accepted ranges are 1 through 100 and 1
  through 200 respectively. All requests use the existing 2,000,000-VM-step/250-ms query budget.
- Each page runs `EXPLAIN QUERY PLAN` before execution. The accepted recording plan uses the integer
  recording and recording-version primary keys; the accepted device plan uses the existing
  `(recordingID, connectionOrdinal)` unique index plus integer primary-key lookups. Any scan or temp
  B-tree returns the fixed `refineQuery` category rather than running a fallback.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testRecordingCatalogUsesFrozenDescendingKeysetsAndRelevantChangeRestart -only-testing:NearWireViewerTests/ViewerStoreTests/testDeviceCatalogUsesConnectionKeysetsAndOnlyRelevantMutationRestarts -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayCatalogRejectsOldStoreGenerationWithoutRetargeting
```

Result: `TEST SUCCEEDED`; 3 tests executed, 0 failures.

The tests cover bidirectional keyset continuity, relevant versus irrelevant mutation invalidation,
Event-only stability, gap/drop hints, aliases/App hints, cursor/store-generation binding, closed
reflection, and gateway retarget rejection. Captured plans assert `SEARCH R USING INTEGER PRIMARY
KEY`, `SEARCH V USING INTEGER PRIMARY KEY`, and `USING INDEX
SQLITE_AUTOINDEX_DEVICESESSIONS_2`; all reject `SCAN` and `USE TEMP B-TREE`.

Boundary command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testCatalogDefaultAndMaximumPageBounds
```

Result: `TEST SUCCEEDED`; 1 test executed, 0 failures. The fixture proves recording 50/100 and device
100/200 default/maximum page sizes.

## Store regression suite

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests
```

Result: `TEST SUCCEEDED`; 108 tests executed, 1 test skipped, 0 failures. The skipped test is the
existing opt-in Application Support artifact audit, which requires the explicit machine-local
`/tmp/nearwire-live-container-audit.enabled` marker.

## Static and specification validation

- `xcrun swift-format lint` passed for the catalog and affected production files.
- `rg` found no `OFFSET`, Event FTS, or Event-content selection in `ViewerStoreCatalog.swift`.
- `git diff --check` passed.
- `openspec validate viewer-event-explorer-control --strict` reported
  `Change 'viewer-event-explorer-control' is valid`.

## Environment boundary

Configured signing and entitlement validation remains deferred to final `release-hardening` by the
user-approved Goal policy. Compilation and tests use `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64` on this Apple-silicon host; this does not claim that
signing validation passed.
