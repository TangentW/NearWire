# Task 6.1 Migration and Query-Race Evidence

Date: 2026-07-13

## Migration contract coverage

The Viewer migration tests exercise the complete schema-1-to-2 boundary without a shell harness:

- `testStoreCreatesFreshNormalPoolAndVersionTwoSchemaWithOwnerOnlyPermissions` proves a fresh
  store starts at schema 2 with the three explorer indexes and owner-only artifacts.
- `testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection` and
  `testVersionOneMigrationPreservesContentAndPublishesOnlyFreshNormalConnections` prove the
  migration writer closes before a fresh normal writer and both readers publish. The published
  connections use `temp_store=MEMORY` and an 8-MiB cache.
- The schema probe now rejects a migration connection unless it uses `temp_store=FILE` and the
  migration-only 32-MiB cache. The three index statements contain only lookup/order keys and no
  Event type or content column.
- `testVersionOneMigrationRollsBackEveryInjectedIndexAndValidationFailure` injects failure at each
  of the three index phases and final validation. Every case preserves schema 1, all original
  content, and zero explorer indexes.
- `testVersionOneMigrationRejectsUnsafeTemporaryDirectoriesAndBothVolumeShortfalls` covers wrong
  mode, symlink, distinct database-volume shortage, distinct temporary-volume shortage,
  same-volume single accounting, live-floor failure, and checked footprint overflow.
- `testRuntimeCloseCancelsAndJoinsVersionOneMigrationRollback`,
  `testAsynchronousRuntimeMigrationPublishesSafePhaseWithoutBlockingRuntimeStart`, and
  `testAutomaticMigrationIsAuthorizedOnceAndExplicitRetryBypassesAutomaticGate` cover terminal
  cancellation/join, safe progress phases, rollback, once-per-process automatic authorization,
  and explicit retry.
- `testLargeVersionOneMigrationBoundsResourcesAndLeavesOnlyKeySorters` migrates exactly 100,000
  Events and 10,000 gap versions. It proves schema 2, exact row preservation, key-only index SQL,
  unchanged default VFS and global SQLite temporary-directory value, normal connection settings,
  no open descriptor under the private sorter directory, and no remaining sorter file.
- `testLargeVersionOneMigrationCancelsWithinInjectedProgressDeadline` uses the same populated
  fixture, cancels inside the SQLite progress callback, and proves a cancelled result, schema-1
  rollback, zero explorer indexes, exact row preservation, unchanged VFS/temp routing, bounded
  physical footprint, and zero descriptor/file residue.

The latest focused large-fixture diagnostics were:

```text
success: heap-growth=23740416, database-high-water=26894336, wal-high-water=0,
         temp-high-water=0, samples=6
cancellation: acknowledgement-ns=5999667, heap-growth=262144,
              database-high-water=26894336, wal-high-water=0,
              temp-high-water=0, samples=2
```

The structural limits therefore passed with 22.64 MiB maximum observed success growth, 0.25 MiB
maximum observed cancellation growth, and 5.999667 ms cancellation acknowledgement, below the
128-MiB and 250-ms gates. Wall time and process footprint are diagnostic machine context only.

## Coordinator-generation and query-arbiter coverage

The `ViewerStoreTests` class also covers the required operation races:

- `testExplorerGatewaySealsOriginatingGenerationBeforePublishingReplacement` and
  `testRuntimeSealsExplorerOperationsBeforeClosingOriginatingStore` prove originating work is
  cancelled, joined, and released before replacement/close.
- `testExplorerGatewaySerializesQueryPageDetailAndFilteredScope` covers page, detail, gap,
  causality, and immutable filtered-export scope on the sole query arbiter.
- `testExplorerGatewayCancellationIsQueuedCompletedAndActiveSuccessorSafe` proves cancellation of
  queued, completed, and active operations cannot cancel a successor.
- `testExplorerGatewayReplacementRetiresOperationBeforeArbitraryCompletion`,
  `testExplorerGatewayLinearizesExternalAndCallbackReplacementWithoutOrphanGeneration`, and
  `testExplorerGatewayCatalogRejectsOldStoreGenerationWithoutRetargeting` cover operation
  retirement before arbitrary completion, serialized replacement, catalog/source replacement,
  stale generation rejection, and no retargeting or orphan generation.
- `testExplorerQueryArbiterOwnsOneTraversalAndFilteredExportUsesIndependentLease`,
  `testQueryLeaseExpiresAndCannotBeRefreshed`, and
  `testExportLeaseExpiresAtExactAbsoluteBoundary` cover sole traversal ownership, exact release,
  refresh/expiry behavior, and independent export leases.

Focused store-class command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests
```

Result: `TEST SUCCEEDED`; 118 tests executed, 1 machine-local audit test skipped, 0 failures.

## Deterministic backpressure-test remediation

The first complete run exposed that two existing manual-clock backpressure tests observed the
queued-event count before the resumed service task had actually reached its intended rejection.
An early synthetic send-completion could therefore replace the pending wake. No production send,
mailbox, or sequence logic changed. The test channel now counts ordinary preflight denial and
authoritative admission rejection separately, and each test waits for its exact rejection before
publishing mailbox progress.

The two tests were then run for 10 iterations each:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests/testDownlinkMailboxBackpressureRetriesWithoutSequenceGapOrDisconnect -only-testing:NearWireViewerTests/ViewerFlowControlTests/testAuthoritativeMailboxBackpressureAlsoRetriesWithoutCommittingSequence -test-iterations 10
```

Result: `TEST SUCCEEDED`; 20 executions, 0 failures.

## Final Viewer and static validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 226 tests executed, 2 skipped, 0 failures.

One skip is the explicit machine-local Application Support audit marker gate. The configured
signing entitlement assertion is the other skip and remains deferred to the user-approved
Goal-level release-hardening verification. This unsigned run makes no release-signing claim.

Static/specification commands and exact results:

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid
```

No shell validation harness was added.
