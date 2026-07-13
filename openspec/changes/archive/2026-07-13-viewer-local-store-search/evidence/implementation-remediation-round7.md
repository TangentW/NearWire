# Implementation Remediation — Round 7

Date: 2026-07-13 (Asia/Shanghai)

This remediation addresses every actionable finding from the three Round 7 implementation reviews. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain deferred, by user direction, to goal-level `release-hardening`; no result below represents those gates as passing.

## One authoritative writer state and generation

Addresses `NW-LSS-IMPL-R7-ARCH-001` and `NW-LSS-IMPL-R7-CT-001`.

- `ViewerStoreStateRelay` is now the single owner of write state and an opaque UUID generation. Event-store presentation and ingress scheduling are observers of that owner rather than independent writable states.
- Every automatic Event-store write obtains an authorization ticket before queueing and revalidates that exact generation on the serial SQLite writer immediately before the injected write seam, planning, reserve admission, and `BEGIN IMMEDIATE`.
- A failure advances the generation before releasing the writer. Therefore a prefix selected before a maintenance/direct-write failure cannot begin SQLite work afterward. A stale ticket is retained within the existing bounded ingress and cannot change public state.
- Direct recording/device materialization uses the same automatic ticket and failure publication as ingress writes.
- Explicit retry is two phase: reserve/schema/integrity probes create a generation-bound recovery permit; recording and every live device materialize with that permit while ingress remains stopped; only complete success publishes `available`. A later materialization failure advances the generation and invalidates the permit.
- `ViewerStoreIngress` derives admission/flush/drain decisions from the authoritative owner. One recovery transition schedules at most one finite successor. Operation-local stale drop observations are removed from the structural head and converted through a bounded coordinator rejection seam rather than poisoning or retrying the head forever.
- `testWriterGenerationRejectsAPreselectedIngressPrefixAfterMaintenanceFailure` deterministically holds a maintenance transaction, proves the Event prefix already obtained a ticket and queued behind it, then proves zero unauthorized Event writes before explicit recovery and exactly one retained-prefix commit afterward.
- `testDirectMaterializationFailureAndFailedRetryCannotReopenIngress` covers a direct recording failure with an existing durable device and a successful retry probe followed by materialization failure.

## Typed recovery authorization

Addresses `NW-LSS-IMPL-R7-ARCH-002` and the recovery half of `NW-LSS-IMPL-R7-CT-001`.

- Recovery reasons are closed `ViewerStoreRecoveryAction` values. Production call sites authorize only explicit retry, a storage setting that can improve safety, unpin, and confirmed manual deletion. A successful reopen constructs a fresh validated coordinator/state owner rather than mutating the failed generation.
- Rename, annotation, and pin success no longer publish `available` or schedule ingress.
- `updateRecording` detects an actual pinned-to-unpinned transition on the serialized writer result. Manual deletion reports recovery only after commit.
- A settings change carries recovery authority only when capacity increases or `historyRetention` decreases. `ViewerStoreMaintenanceOwner` preserves that typed action through dirty-successor coalescing and publishes recovery only after the bounded campaign succeeds. Capacity reduction, longer retention, ordinary cleanup, and unrelated metadata have no recovery authority.
- `testRecoveryMatrixAllowsOnlyApprovedSuccessfulActions` covers rename, annotation, unpin, manual deletion, ordinary cleanup, and settings recovery from both `writeFailed` and `capacityPaused`.
- Manual-delete fault coverage now exercises `beforeBegin`, `beforeBody`, and `beforeCommit` for storage, corruption, and capacity failures, proving tombstone and quota rollback for all nine combinations.

## Strict cumulative drop validation before cleanup

Addresses `NW-LSS-IMPL-R7-CT-002`.

- The writer planning phase compares a new drop sequence with the latest persisted count for that device/reason before quota projection, disk admission, or capacity recovery.
- A lower count throws the operation-local `staleObservation` category without changing global write state. An equal projected count is an idempotent zero-reservation/no-row result. The transaction body repeats the comparison for defense in depth, and only a greater count reserves quota.
- The coordinator retains bounded per-device/reason projected `Int64` counts. Values at or above `Int64.max` saturate to one durable value; later equal projections produce no row. A real decrease creates one bounded `dropJournalNonIncreasing` gap before store admission.
- `testDropPlanningRejectsNonIncreasingCountsBeforeCapacityRecovery` places the store at capacity with eligible history and proves equal/lower samples trigger no recovery campaign, tombstone, quota change, row, or global failure.
- `testCoordinatorSaturatesDropProjectionAndGapsARealDecrease` covers `Int64.max`, `Int64.max + 1`, `UInt64.max`, and a later lower count through the production coordinator.

## Closed active handoff and secure-transport reflection

Addresses `NW-ISPD7-001`.

- `ViewerUplinkHandoff.Item`, `ViewerUplinkPayload`, and `ViewerUplinkHandoff` now expose closed descriptions and empty mirrors. Queue IDs and received Events cannot be reached through generic diagnostics.
- `SecureByteChannelEvent` and `SecureViewerListenerEvent` expose only closed event categories and bounded byte counts. `SecureByteChannel`, its receive-pause/send-mailbox/callback ownership chain, `SecureViewerListener`, `SecureViewerIncomingConnection`, and the admission gate expose closed content-free reflection.
- `ViewerStoreIngress` and the new authoritative state relay also close reflection so retained Event values cannot be reached through the new ownership graph.
- The Core queue matrix now uses a real `EventDraft`. `testActiveTransportOwnersHaveContentFreeReflection` covers received bytes, a channel retaining queued send bytes, an incoming connection, and its listener event. `testActiveViewerEventOwnersHaveContentFreeReflection` covers populated `EventDraft` and `WireReceivedEvent` queues plus uplink item/payload/owner. The stale-generation test reflects an ingress while it retains a secret Event.

## Previously unidentified SwiftPM failures

Addresses `NW-ISPD7-002` and `NW-LSS-IMPL-R7-CT-003`.

Durable logging reproduced and identified two independent test-observation races. Neither was hidden, converted to a skip, or fixed by increasing a timeout.

1. `PerformanceMonitorTests.testStateStreamsYieldCurrentAndCancelIndependently` manually broke its `for await` loop when cancellation arrived between the first body and the next `AsyncStream.next()`. The stream itself remained retained by the outer test value, so the hub's termination callback was not guaranteed to run. Removing the manual break lets the next cancellation-aware `next()` terminate the iterator. The corrected test passed 100 independent SwiftPM processes.
2. `SDKSessionAdmissionTests.testTransportBlockWithWholeTokensDoesNotPollUntilCapacityProgress` treated `outboundTurnStarts` as turn completion even though it increments before the asynchronous schedule-observation hook. The test now waits for the progress-driven turn to finish, restore the transport block, and clear its drain before taking the no-polling baseline. The corrected test passed 100 independent SwiftPM processes.

After both root causes were fixed, the complete 535-test package suite passed in 20 consecutive independent SwiftPM processes. Per-run logs are retained under `/tmp/NearWireSwiftPMRound8-stability-*.log` for this validation session.

Complete current-tree validation is recorded in `implementation-validation-round8.md`.
