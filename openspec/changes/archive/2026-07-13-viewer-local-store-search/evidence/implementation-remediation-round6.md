# Implementation Remediation — Round 6

Date: 2026-07-13 (Asia/Shanghai)

This remediation addresses every actionable finding from the three Round 6 implementation reviews. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain deferred, by user direction, to goal-level `release-hardening`; no result below represents those gates as passing.

## Shared maintenance and ingress write gate

Addresses `NW-LSS-IMPL-R6-ARCH-001`.

- `ViewerStoreStateRelay` now connects authoritative maintenance state transitions to both the public Event-store status and the bounded ingress owner.
- A maintenance `writeFailed`, `capacityPaused`, or `unavailable` transition stops new Event admission and automatic drains. The ingress retains only its bounded queued/structural ownership and coalesces rejected Event ownership into the existing bounded gap path.
- A successful explicit retry or another already-approved relevant recovery action may publish `available` and schedule one finite successor drain. An unrelated automatic Event write cannot reopen a gate that it was not allowed to enter.
- `testMaintenanceWriteFailureStopsIngressUntilExplicitRecovery` proves that a maintenance storage failure prevents subsequent Event and structural offers from reaching SQLite, preserves bounded ownership, emits the expected gap, and resumes one finite attempt only after explicit recovery.

## Writer-serialized checkpoint admission

Addresses `NW-LSS-IMPL-R6-ARCH-002`.

- `checkpointOneStep` now re-reads the actionable WAL size and checks the floor-only filesystem reserve inside `pool.writer.run`, immediately before `sqlite3_wal_checkpoint_v2`.
- Any earlier WAL observation is only a hint; it cannot authorize the mutation across another writer turn.
- `testCheckpointReserveSharesWriterOrderingWithEventWrite` deterministically interleaves a queued Event writer with checkpoint admission and proves that the checkpoint uses the current serialized reserve decision rather than stale apparent capacity.

## SQLite lock origin and authoritative manual-delete failures

Addresses `NW-LSS-IMPL-R6-CT-001`.

- `ViewerStoreError.sqliteBusy` now represents actual SQLite `BUSY` and `LOCKED` results. The existing `busy` case remains reserved for expected revision, active-session, and lease contention.
- The shared write-failure classifier treats `sqliteBusy` as `writeFailed` for interactive storage mutation while keeping caller conflicts, cancellation, work limits, and invalid values operation-local.
- Manual deletion now uses the same mutation phases, rollback discipline, capacity classification, and authoritative state reporting as other interactive maintenance writes. The classification is published while the writer turn is still owned, so automatic ingress cannot race past the failed boundary.
- `testSQLiteWriterLockReportsWriteFailedWhileStaleRevisionRemainsLocal` obtains a real external `BEGIN IMMEDIATE` lock and proves the distinction between SQLite lock failure and stale revision.
- `testManualDeleteClassifiesStorageAndCapacityFailuresWithoutMutation` covers injected storage and capacity failures and proves rollback, exact state, and unchanged durable data.

## Monotonic cumulative drop journaling

Addresses `NW-LSS-IMPL-R6-CT-002`.

- Local drop callbacks now publish the post-merge saturating cumulative value for the changed reason, not the callback delta.
- `ViewerRemoteDropCounts` keeps a bounded saturating cumulative counter per persisted remote reason and emits only changed cumulative values.
- The store rejects a drop-version count that decreases for the same device and reason, protecting the durable analysis contract at its final boundary.
- `testDropJournalPublishesMonotonicCumulativeLocalAndRemoteSamples` covers repeated local and remote drops, zero/no-change callbacks, and saturation.
- `testRejectedCumulativeDropSampleCreatesGapBeforeLaterSample` rejects one cumulative observation on the production coordinator path, proves the transition-loss gap, explicitly recovers, and then persists a later higher cumulative sample without changing protocol ownership.

## Closed reflection for active queue ownership

Addresses `NW-ISPD6-001`.

- `EventDraft` now has content-free descriptions and reflection.
- `KeepLatestKey`, `EventQueuePolicy`, `PendingEvent`, `BoundedEventQueue`, queue snapshots, enqueue/dequeue/offer/clear/scheduling results, `EventBatch`, and `EventBatchAttempt` expose only bounded count or policy-kind diagnostics. They never expose Event values, Event IDs, timestamps, queue keys, or policy payloads.
- `ViewerDownlinkPolicy` also redacts its keep-latest key independently of the Core queue implementation.
- `testActiveQueueOwnersAndResultsHaveContentFreeReflection` drives populated `EventDraft` and received-Event queues through all active ownership/result shapes with a secret marker.
- `testViewerDownlinkPolicyReflectionRedactsKeepLatestKey` closes the Viewer policy representation. The existing envelope, wire, frame, decoder, and message matrices remain in place.

## Focused verification

- Core queue/reflection suites: 49 tests, zero failures.
- New Viewer flow-control regressions: 2 tests, zero failures.
- New storage write-gate, classification, checkpoint, and manual-delete regressions: 4 tests, zero failures.
- Rejected cumulative drop/gap production-path regression: 1 test, zero failures.
- Complete Viewer suite: 140 tests, one explicit live-resource-audit skip, zero failures.
- Complete root Swift package suite: 534 tests, zero failures.

Complete current-tree validation is recorded in `implementation-validation-round7.md`.
