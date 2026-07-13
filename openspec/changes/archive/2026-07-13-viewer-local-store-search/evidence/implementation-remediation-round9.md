# Implementation Remediation — Round 9

Date: 2026-07-13 (Asia/Shanghai)

This remediation addresses all five actionable findings from the three Round 9 implementation reviews. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain deferred, by user direction, to the goal-level `release-hardening` change. They are neither changed nor represented as passing here.

## Maintenance shutdown ownership

Addresses `NW-LSS-IMPL-R9-ARCH-001`.

- `ViewerStoreMaintenanceOwner` now separates lifecycle invalidation from queue quiescence. Runtime end invalidates recovery publication, pending work, and dirty successors, while `waitForQuiescence()` establishes a serial-queue barrier before the coordinator begins its one terminal ingress flush.
- A queued campaign revalidates the lifecycle before crossing the execution seam. An already-running campaign may finish before shutdown progresses, but it cannot overlap or follow the terminal flush. A lifecycle-invalid dirty successor performs no maintenance work.
- `testRuntimeShutdownQuiescesMaintenanceBeforeOneTerminalFlush` blocks a maintenance campaign before execution, starts runtime shutdown, proves that no terminal Event-store writer turn occurs while maintenance owns the queue, releases the campaign, and then proves one terminal flush and zero dirty-successor executions.

## Writer-first schema acceptance

Addresses `NW-LSS-IMPL-R9-ARCH-002`.

- `ViewerSQLitePool` now has one construction path. It prepares the secure directory and reserve, opens only the writer, completes migration, probes the accepted schema and writer configuration, and only then opens the query and export readers.
- Construction failures unwind local connections without publishing a partially initialized pool. Unknown, incomplete, and invalid version-zero stores never open a read connection.
- `testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection` observes the exact successful construction order and proves migration rejection stops after the writer-open edge.

## Completion-owned runtime recovery

Addresses `NW-LSS-IMPL-R9-ARCH-003`.

- Runtime recovery now moves the current missed-observation aggregate into a generation-bound in-flight claim. The count is not discarded when work is merely admitted to the preparation queue.
- `recoverRuntimeAndSessions` reports completion only after the recording and required live device sessions have materialized and the corresponding bounded gap ownership has been established. Admission failure or materialization failure completes unsuccessfully.
- Failed completion merges the claimed count back with observations received during the attempt using saturating arithmetic. Successful completion discards only the completed claim; observations that arrived during recovery keep the runtime unavailable until a later recovery.
- Runtime replacement, runtime end, and storage close invalidate obsolete recovery generations so late callbacks cannot mutate replacement ownership.
- `testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes` and `testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork` cover fresh-coordinator and same-coordinator failure paths, exact missed counts, and live-device recovery.

## Settings-revision recovery authority

Addresses `NW-LSS-IMPL-R9-CT-001`.

- `ViewerStoreRuntime.saveConfiguration` serializes preference comparison, persistence, and a monotonically advancing settings revision.
- Every settings maintenance trigger carries that revision. A newer settings edit replaces the pending recovery decision even when the new decision has no recovery permit.
- Recovery publication verifies the captured settings revision both before and after the injected publication seam. A stale campaign may finish its bounded cleanup work, but it cannot reopen automatic ingress. Its newer dirty successor remains owned and executes normally.
- `testQueuedSettingsRecoveryIsRevokedByANewerNonrecoveringRevision` and `testRunningSettingsRecoveryIsRevokedBeforePublicationByNewerRevision` cover queued and already-running supersession, failed-state preservation, and a later current recovery.

## Closed callback diagnostics

Addresses `NW-ISPD9-001`.

- `ViewerStoreChangeSnapshot` retains its bounded internal recording IDs and Event upper row ID for trusted in-process refresh consumers, while its description, debug description, interpolation, reflected string, and mirror are content-free.
- The operator guide now distinguishes callback semantics from diagnostics and presentation. Internal row identities are never described as peer identity or redaction.
- `testLatestOnlyChangeSignalCarriesSafeRecordingAndUpperRowSnapshot` proves the callback still receives the exact refresh values while every generic diagnostic path omits the distinctive IDs and secret marker.

## Validation-discovered test synchronization defect

> Superseded by Round 10 remediation: the failure-consumption semaphore below proved execution only after admission, but did not prove that the saturated lifecycle queue could admit the retry. `NW-ISPD10-001` reproduced that remaining race. The exact current-prefix barrier and blocking admission proof are recorded in `implementation-remediation-round10.md`.

The first focused Round 10 combination exposed an intermittent test-only timeout in `testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork`. The test filled the preparation queue and then used a generic two-second poll that included the time required to drain the queued prefix. A later retry could therefore be correctly rejected while the first recovery remained in flight.

The one-shot fault helper emitted a semaphore signal when the intended failure was consumed. That initial correction removed one timing assumption and produced a passing local run, but fresh Round 10 review proved that a retry rejected before admission could never reach the signal. It is historical evidence only and is not the final synchronization design.

## Artifact synchronization

The active design and capability specification now state the implemented acceptance boundaries explicitly: writer migration/schema acceptance precedes reader construction; queue admission is not recovery completion; settings recovery is bound to the latest settings revision; trusted refresh identities remain absent from diagnostics; and maintenance reaches quiescence before the terminal flush. This is specification alignment for the reviewed implementation, not additional feature scope. Strict OpenSpec validation passes after the synchronization.

Complete current-tree validation is recorded in `implementation-validation-round10.md`.
