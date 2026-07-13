# Implementation Remediation — Round 5

Date: 2026-07-13 (Asia/Shanghai)

This remediation addresses every actionable finding from the three Round 5 implementation reviews. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain deferred, by user direction, to goal-level `release-hardening`; no result below represents those gates as passing.

## Maintenance progress below an expensive action plan

Addresses `NW-LSS-IMPL-R5-ARCH-001`.

- `ViewerStoreMaintenance.run` now classifies capacity failures at tombstone-selection and reclaim boundaries instead of aborting the campaign immediately.
- A blocked expensive action may yield to exactly one eligible floor-only recovery action: passive checkpoint first, then incremental vacuum. The eight-turn campaign bound remains unchanged and no logical selection state is skipped or mutated by the fallback.
- `testMaintenanceRunBypassesBlockedReclaimForOneFloorOnlyAction` drives the production `run` path with a blocked Event reclaim and free pages. It proves physical page progress while the Event row and tombstone remain intact.

## One-attempt shutdown and next-open repair

Addresses `NW-LSS-IMPL-R5-ARCH-002`, `NW-LSS-IMPL-R5-CT-001`, and `NW-ISPD5-003`.

- `ViewerStoreCoordinator.runtimeEnded` performs exactly one ingress flush. It no longer invokes `eventStore.retry`, clears ingress failure state, or performs a second automatic flush.
- Failure closes resources and leaves orphan repair to the next coordinator open, preserving explicit retry ownership.
- `testShutdownUsesOneFailedFlushAndNextOpenReconcilesOrphan`, `testShutdownDoesNotRetryPreexistingFailedPrefix`, and `testShutdownCapacityFailureIsFiniteAndReconcilesOnNextOpen` cover a failure created by shutdown, a pre-existing failed prefix, and capacity failure. They assert finite completion, no implicit retry, and next-open reconciliation.

## Shared authoritative write-failure classification

Addresses `NW-LSS-IMPL-R5-ARCH-003`.

- `ViewerStoreWriteFailureDisposition` centralizes the classification shared by Event and maintenance writes.
- Capacity exhaustion reports `capacityPaused`; storage, I/O, corruption, and unavailable-store failures report `writeFailed`; stale revision, lease contention, cancellation, work limits, and invalid caller values remain operation-local.
- `ViewerStoreMaintenance` exposes an internal mutation-phase fault seam solely for deterministic tests. The gate covers pre-BEGIN, mutation-body, and pre-COMMIT failures without changing production behavior.
- `testMaintenanceMutationFailuresReportAuthoritativeStateAndRollback` verifies all three injected storage phases roll back and report `writeFailed`, while stale revision remains operation-local.

## Late-runtime regression root cause

Addresses `NW-LSS-IMPL-R5-CT-002`.

The repeated failure was caused by the test fixture, not by a replacement-runtime ownership race. The test used wall-clock values around `1000` milliseconds while dirty-successor/startup maintenance uses the real current date. Once the replacement recording became closed and therefore unprotected, the valid seven-day retention policy could delete it before the assertion observed it.

- The fixture now derives all lifecycle wall times from the current wall clock while retaining deterministic relative offsets.
- The wait timeout was not increased.
- The isolated regression passed 100 consecutive iterations. Its result bundle is `/tmp/NearWireViewerRound5FixDerived/Logs/Test/Test-NearWireViewer-2026.07.13_09-20-58-+0800.xcresult`.
- The test also passed inside the 56-test ViewerStore suite and the complete 133-test Viewer suite.

## Writer-serialized physical reserve checks

Addresses `NW-ISPD5-001`.

- Manual-delete reserve admission now occurs inside the writer executor immediately before `BEGIN IMMEDIATE`.
- Orphan reconciliation computes the exact bounded child-plus-parent version plan on the writer executor, checks that exact plan, and begins the transaction on the same writer turn. The former outside-writer maximum-plan check was removed.
- `testManualDeleteReserveSharesWriterOrderingWithMetadataWrite` proves two mutations cannot concurrently spend one apparent reserve.
- `testOrphanRecoveryChecksExactPhysicalPlanOnWriter` proves the exact two-child plus one-parent plan is checked after bootstrap and before mutation.

## Closed reflection for active Event carriers

Addresses `NW-ISPD5-002`.

- `EventEnvelope`, `EventEnvelopeContext`, `WireEventRecord`, `WireEventPayload`, `WireEventBatchPayload`, `WireFrame`, `WireFrameDecoder`, `WireMessage`, and `WireAdmittedMessage` now expose bounded, content-free descriptions and mirrors.
- Batch and frame diagnostics expose only bounded count information. They do not expose Event type, JSON content, endpoints, epoch, IDs, causality, or payload bytes.
- `testEnvelopeAndContextReflectionAreContentFree` and `testEventWireCarrierReflectionIsContentFree` extend the secret-marker matrix across these direct carriers.
- `WireFrameTests.testLanePreflightFailureIsTerminalAndRetainsNoPayload` now uses the supported retained-byte accounting seam rather than private-layout reflection and verifies that only the four-byte length prefix remains after preflight rejection.

## Live-resource evidence and encryption disclosure

Addresses `NW-ISPD5-004`.

- The residual `/tmp/NearWire-audit-created-20260713` store was removed.
- `resource-filesystem-audit-round6.md` records the exact move, marker, test, launch, `lsof`, quit, stat, restore, cleanup, and residue-check commands with exit results.
- The audit records non-content device/inode/mode/size/time metadata before and after restoration and verifies exact equality. The audit-created database is deleted after metadata capture.
- WAL measurements are labeled as allocated bytes where that is what `fileAllocatedSizeKey` measured.
- `Documentation/Viewer-Local-Store.md` now states directly that the local SQLite database and JSON exports do not receive NearWire application-layer at-rest encryption. FileVault or filesystem protection is optional platform protection outside NearWire's guarantee.

## Focused verification

- New Viewer storage regressions: five tests passed, zero failures.
- New shutdown regressions added later in remediation: two tests passed, zero failures.
- `ViewerStoreTests`: 56 tests, one explicit opt-in audit skip, zero failures.
- Late-runtime replacement regression: 100 iterations, zero failures.
- Core reflection regressions: two tests passed, zero failures.
- `WireFrameTests`: 15 tests, zero failures after replacing the private-reflection assertion.

Complete validation is recorded in `implementation-validation-round6.md`.
