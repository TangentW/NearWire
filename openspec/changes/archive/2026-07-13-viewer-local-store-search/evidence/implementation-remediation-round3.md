# Implementation Remediation — Round 3

Date: 2026-07-13 (Asia/Shanghai)

This record maps every actionable Round 3 finding to the current implementation and regression evidence. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## Architecture/API findings

### Complete transaction quota planning

Resolved. Every write transaction now computes its exact net-new logical reservation on the writer executor before `BEGIN`. The same complete plan is used for admission, filesystem reserve, and the single cleanup retry. Event insertion includes both the Event/FTS reservation and the optional initial disposition; duplicates and no-op structural offers plan zero. Lifecycle, alias, gap, policy, drop, disposition, close, annotation, and metadata paths have explicit plans.

Evidence:

- `ViewerEventStore.writeTransaction` and `plannedStructuralReservation`.
- `ViewerStoreTests.testWholeTransactionPlanIncludesInitialDispositionAndDuplicateIsZeroQuota`.
- `ViewerStoreTests.testProjectedReservationCrossingCapacityReclaimsEligibleHistoryThenAdmits`.

### Missing-initial transition identity

Resolved. A missing initial disposition is represented by a versioned gap whose reason includes the terminal disposition. An identical `(recording, device, direction, sequence, disposition, count)` observation is idempotent even if its later wall time differs; another disposition for the same transition identity conflicts.

Evidence:

- `ViewerEventStore.appendMissingTransitionGap`.
- `ViewerStoreTests.testMissingInitialTransitionBecomesIdempotentGapWithoutPoisoningWriter`.

### Event-type query grammar

Resolved. Exact Event types and prefixes use a closed ASCII dot-segment grammar consistent with the shared Event model. JSON array indexes accept ASCII decimal digits only, so malformed values fail in the compiler before SQLite execution.

Evidence:

- `ViewerStoreQueryValidator`.
- `ViewerStoreTests.testQueryCompilerRejectsImpossibleEventTypesAndNonASCIIJSONIndexes`.

### Safe latest-only notification payload

Resolved. Notifications coalesce into `ViewerStoreChangeSnapshot`, which carries at most 32 changed recording IDs, the frozen upper Event row, and the latest closed `ViewerStoreStatus`. The runtime adapter preserves that bounded snapshot and never publishes Event, query, path, or SQL values.

Evidence:

- `ViewerStoreChangeSnapshot` and `ViewerStoreStatusSignal`.
- `ViewerStoreTests.testLatestOnlyChangeSignalCarriesSafeRecordingAndUpperRowSnapshot`.

## Correctness/testing findings

`NW-LSS-IMPL-R3-CT-001` is resolved by the complete transaction quota planning described above. `NW-LSS-IMPL-R3-CT-002` is resolved by the closed Event-type and ASCII JSON-index validators. Both named regressions execute in the final 44-test store suite.

## Security/performance/documentation findings

### `NW-ISPD3-001`: physical reserve includes planned work

Resolved. The volume guard requires `available capacity >= 64 MiB floor + planned bytes`, uses checked arithmetic, rejects negative plans, and is called before bootstrap and each mutating category. Boundary tests cover equality, one byte below, overflow, normal writes, oversize Event writes, and reclaim plans.

### `NW-ISPD3-002`: export file identity and parent-directory races

Resolved. Export opens the parent directory once, creates the temporary leaf with `openat(O_EXCL | O_NOFOLLOW)`, retains its file descriptor, verifies `fstat`/`fstatat` device and inode identity, validates owner/mode/link count and the retained parent identity, commits with descriptor-relative `renameat`, and synchronizes that same directory. Substituted regular files, hard links, symlinks, and parent replacement fail without changing the destination or unrelated content.

Evidence: `ViewerStoreTests.testExportRejectsTemporaryLeafHardLinkAndParentSubstitution` and `testExportCommitBoundaryPreservesDestinationAcrossInjectedFailuresAndCancellation`.

### `NW-ISPD3-003`: sensitive reflection

Resolved. Query scalars, predicates, bindings, compiled plans, cursors, traversal state, stored rows, pages, and summaries implement closed redacted descriptions/reflection. Tests assert that secrets, paths, SQL fragments, and Event content do not appear.

Evidence: `ViewerStoreTests.testSensitiveQueryAndSummaryModelsHaveClosedRedactedReflection` and `testDurableMetadataAndSensitiveReflectionAreBoundedAndRedacted`.

### `NW-ISPD3-004`: resource, filesystem, distribution, and documentation evidence

Resolved for this change. `resource-filesystem-audit-round4.md` records the sustained-write WAL measurement, near-maximum payload measurement, process peak-memory measurement, active and closed artifact permissions/types, export substitution attacks, SQLite linkage, privacy manifest, root manifest boundaries, SwiftPM regression, and CocoaPods validation. `Documentation/Viewer-Local-Store.md` documents the resulting operational and privacy contract.
