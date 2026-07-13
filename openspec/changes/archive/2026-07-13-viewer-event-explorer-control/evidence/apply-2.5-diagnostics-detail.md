# Task 2.5 Diagnostics and Detail Evidence

Date: 2026-07-13

## Implemented contract

- Newly materialized durable device sessions store the exact admission `connectionID` in the
  existing `DeviceSessions.logicalID` column. The schema-1 migration still adds indexes only; a
  closed legacy device row retains its original logical ID and closed version without rewriting.
- Event detail extends the frozen point lookup with exact device logical identity, safe
  installation/connection aliases, App-origin monotonic time, TTL, schema version,
  correlation/reply UUIDs, Viewer receive times, and the already resolved local disposition. The
  detail, gap, causality, services, and gateway roots keep closed reflection.
- Gap diagnostics bind the current traversal's recording, refreshed originating lease, device
  filter, and a frozen gap upper row ID. Pages contain 1 through 32 rows, select the latest revision
  at or below that bound, traverse `(lastViewerWallMilliseconds, gapRowID)` in either direction,
  and use stable recording/device/namespace/sequence identity.
- All-device gap requests use `GapTimelineAllDevices`. A selected-device request accepts 1 through
  16 exact device rows, executes one bounded range for each selected device plus the nil-device
  recording lane through `GapTimelineByDevice`, and merges at most 17 lanes into 32 results.
- Causality lookup binds the traversal's recording, exact root device, refreshed lease, and frozen
  Event upper row ID. Each UUID lookup uses `EventCausalityLookup`, reads `LIMIT 9`, exposes at most
  eight row-ID-ordered candidates plus `hasMore`, visits reply-to before correlation breadth-first,
  and uses durable row ID for the 32-node visited/cycle identity. Duplicate peer UUIDs remain
  explicit ambiguous candidates instead of becoming a parent key or false cycle.
- Gap and causality work serialize through the generation-owned query arbiter and runtime gateway.
  Both use the existing 2,000,000-VM-step/250-ms budget and return the fixed `refineQuery` category
  when their accepted index-only/no-temp plan gate fails.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testDurableMaterializationUsesExactAdmissionConnectionID -only-testing:NearWireViewerTests/ViewerStoreTests/testEventDetailIncludesExactIdentityAliasesAndCompleteMetadata -only-testing:NearWireViewerTests/ViewerStoreTests/testGapTraversalFreezesLatestRevisionsAndUsesBoundedBidirectionalLanes -only-testing:NearWireViewerTests/ViewerStoreTests/testCausalityUsesExactDeviceNineRowCandidatesReplyFirstAndRowIDCycles
```

Result: `TEST SUCCEEDED`; 4 tests executed, 0 failures.

The tests prove exact admission identity persistence, complete frozen detail metadata, revision-safe
gap bounds, forward/backward 32-row keysets, all-device and selected-device lane plans, eight-plus-
`hasMore` ambiguity, exact-device isolation, reply-first breadth-first traversal, real row-ID cycles,
non-cycles from repeated UUIDs, and the 32-node limit. Captured plans require
`GapTimelineAllDevices`, `GapTimelineByDevice`, and `EventCausalityLookup` and reject `SCAN` and
`USE TEMP B-TREE`.

Gateway command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewaySerializesQueryPageDetailAndFilteredScope
```

Result: `TEST SUCCEEDED`; 1 test executed, 0 failures. The tokenized generation path serializes
query, page, detail, gap, causality, filtered-export scope, and exact traversal release.

Legacy-preservation command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testVersionOneMigrationPreservesContentAndPublishesOnlyFreshNormalConnections
```

Result: `TEST SUCCEEDED`; 1 test executed, 0 failures. The schema-1 fixture contains a closed legacy
device row whose original `logicalID` and closed version remain present after the index-only
migration.

## Viewer regression suite

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 194 tests executed, 2 tests skipped, 0 failures. One skip is the explicitly
deferred configured-signing entitlement gate. The other is the existing opt-in Application Support
artifact audit, which requires `/tmp/nearwire-live-container-audit.enabled`.

The same command without the approved signing skip executed 195 tests; the 112-test Store suite
passed, and its only two reported failures were duplicate execution reports for the configured
signing entitlement test. No product test failed.

## Static and specification validation

- `xcrun swift-format lint` passed for affected production files. It reported only the unchanged
  pre-existing `ReplaceForEachWithForLoop` warning in `ViewerStoreTests.swift`.
- `rg` found no `OFFSET`, `SELECT *`, JSON traversal, or FTS selection in
  `ViewerStoreDiagnostics.swift`.
- `git diff --check` passed.
- `openspec validate viewer-event-explorer-control --strict` reported
  `Change 'viewer-event-explorer-control' is valid`. The CLI's optional PostHog flush could not
  resolve its analytics host in the restricted environment after validation; this did not affect
  the local validation result.

## Environment boundary

Configured signing and entitlement validation remains deferred to final `release-hardening` by the
user-approved Goal policy. Compilation and tests use `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64` on this Apple-silicon host; this does not claim that
signing validation passed.
