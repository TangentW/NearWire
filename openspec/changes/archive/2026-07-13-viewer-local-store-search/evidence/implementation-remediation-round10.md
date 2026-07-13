# Implementation Remediation — Round 10

Date: 2026-07-13 (Asia/Shanghai)

This remediation addresses both actionable Medium findings from the Round 10 correctness/testing and security/performance/documentation reviews. The Round 10 architecture/API review reported zero findings. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain deferred, by user direction, to the goal-level `release-hardening` change and are not represented as passing here.

## Initial runtime outage ownership

Addresses `NW-LSS-IMPL-R10-CT-001`.

- `ViewerStoreCoordinator.runtimeStarted` no longer discards an asynchronously failed initial recording materialization. It records one bounded coordinator-local unavailable observation at the original runtime start time.
- The existing saturating unavailable aggregate survives failed explicit retries. The first successful same-runtime retry creates the original logical recording with `midRuntimeRetry`, converts the aggregate into one coalesced recording-level `storageUnavailable` gap, and owns no device row unless a live device actually exists.
- `testDirectMaterializationFailureAndFailedRetryCannotReopenIngress` already contained the exact initial-failure, failed-retry, and later-success sequence without intervening device/Event callbacks. It now asserts zero recording after the failed retry, one partial recording, exactly one gap/version with total count one, zero device sessions, and available status after the successful retry.

## Exact lifecycle-prefix and recovery-admission proof

Addresses `NW-ISPD10-001`.

- `ViewerJournalPreparationQueue.afterCurrentPrefix` enqueues one content-free callback directly on the serial preparation queue. It does not consume or widen Event/structural capacity and establishes that every operation already accepted before the callback has completed and released its reservation.
- Viewer-internal coordinator/runtime forwarding exposes that bounded barrier only inside the Viewer module; no SDK or public API changes.
- `testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork` installs the barrier after all 40 lifecycle offers and before releasing the blocked initial write. The test waits for the exact accepted prefix rather than treating store status as quiescence.
- A second blocking fault then proves the retry reached the writer after admission while `isRecoveryInFlight` is true. Releasing that fault proves failed completion retains the runtime's five rejected-session observations; the coordinator-local failed-start marker adds one, so the final successful retry owns an exact aggregate count of six and one live device.
- The incomplete failure-consumption semaphore was removed. Historical Round 9 remediation and Round 10 validation now explicitly identify the superseded claim rather than presenting it as deterministic evidence.

Complete current-tree validation is recorded in `implementation-validation-round11.md`.
