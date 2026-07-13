# Implementation Remediation — Round 8

Date: 2026-07-13 (Asia/Shanghai)

This remediation addresses every actionable finding from the three Round 8 implementation reviews. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain deferred, by user direction, to the goal-level `release-hardening` change. They are neither changed nor represented as passing here.

## Failure publication before writer release

Addresses `NW-LSS-IMPL-R8-ARCH-001`.

- `ViewerSQLiteConnection.run` accepts an internal failure observer that executes on the serialized connection queue before that writer turn is released. The Event store uses this edge to classify storage/capacity failures and advance `ViewerStoreStateRelay` before a queued writer can validate its ticket.
- Operation-local `writeNotAuthorized` and `staleObservation` outcomes remain nonpoisoning. An eligible capacity failure still receives exactly one generation-bound recovery campaign, and any terminal recovery failure closes the generation before the writer is released.
- `testDirectWriterFailurePublishesBeforeQueuedAutomaticWriterValidates` deterministically queues a second automatic writer behind a failing direct writer and proves that the queued ticket performs no planning or mutation under the failed generation.

## Ordered relay transitions

Addresses `NW-LSS-IMPL-R8-ARCH-002`.

- Every relay mutation now creates a monotonic `ViewerStoreStateRelay.Transition` containing a sequence and safe state category.
- Event-store presentation and ingress each remember the latest applied transition sequence and reject delayed callbacks. A stale recovery notification therefore cannot overwrite a newer failure, and a stale failure cannot overwrite a newer approved recovery.
- `testRelayObserversRejectReorderedTransitions` suspends and reverses callback delivery in both directions, then verifies authoritative state, presentation, admission, flush behavior, and drain ownership converge on the newest transition.

## Lifecycle-owned maintenance and shutdown

Addresses `NW-LSS-IMPL-R8-ARCH-003`.

- Scheduled maintenance obtains one generation-bound authorization before it queues. All writer turns in that campaign revalidate the same authorization, and a genuine scheduled storage/capacity failure is published from the serialized writer edge before another automatic writer can proceed.
- `ViewerStoreMaintenanceOwner` now owns a lifecycle generation. `runtimeEnded()` invalidates pending recovery authority and dirty successors before the coordinator's one terminal ingress flush. `close()` waits for maintenance queue ownership to finish before the SQLite pool closes.
- Recovery publication rechecks the exact lifecycle generation both before and after the injected publication seam. No campaign released after runtime shutdown begins can publish `available` or schedule post-flush work.
- A dirty settings successor retains the permit captured for that exact failed generation instead of requesting a permit later.
- `testScheduledMaintenanceStorageFailureClosesAutomaticWrites`, `testDirtySettingsRecoverySuccessorRetainsItsOriginalPermit`, and `testRuntimeEndInvalidatesInFlightMaintenanceRecoveryBeforePublication` cover scheduled failure classification, dirty-successor ownership, shutdown invalidation, the single terminal flush, and bounded pool closure.

## Recovery permits bound before approved actions

Addresses `NW-LSS-IMPL-R8-CT-001`.

- Unpin, confirmed manual deletion, and settings recovery capture a permit for the current failed generation before work begins, validate it on every serialized writer turn, and complete only that same permit after success.
- The old callback path that created a fresh permit after an operation succeeded has been removed. If an intervening failure advances the generation, completion of the older action is rejected and the newer failure remains authoritative.
- Ordinary metadata and maintenance mutations use a generation-bound `nonRecoveringMutation` authorization. This permits bounded rename, annotation, pin, and cleanup work while failed without reopening automatic ingress.
- `testApprovedRecoveryActionsCannotReopenANewerFailureGeneration` deterministically covers unpin, manual deletion, and settings maintenance across a newer intervening failure. `testRecoveryMatrixAllowsOnlyApprovedSuccessfulActions` confirms the complete recovery policy still permits ordinary nonrecovering mutations and only reopens for approved actions.

## Closed admission, session, and store reflection

Addresses `NW-ISPD8-001`.

- `WireHello` and `ViewerAdmissionSessionContext` now expose closed content-free descriptions and mirrors. Peer installation identity, display/application text, versions, capabilities, and correlation identifiers cannot be reached through generic diagnostics.
- The active admission ownership chain now closes reflection for the budget/reservation, cleanup receipt/registry, connection core, handle, weak ingress, placeholder owner, attempt, and manager roots. Raw Hello frames, callbacks, waiters, UUIDs, channels, and session receivers are not reflected.
- The post-admission chain now closes reflection for `ViewerDeviceSession`, `ViewerMultiDeviceSessionManager`, `ViewerStoreCoordinator`, `ViewerStoreRuntime`, and their operational SQLite, maintenance, query, export, status, lease, preference, and service roots. Mirrors expose no retained Event value, queue key, path, SQL, raw bytes, session epoch, peer identity, or implementation owner.
- `testHelloDiagnosticsDoNotExposePeerIdentityOrText`, `testAdmissionAndActiveSessionRootsHaveClosedReflection`, and `testStoreCoordinatorAndRuntimeRootsHaveClosedReflection` drive distinctive secret markers through real Hello/admission/session/store ownership and verify descriptions, interpolation, `String(reflecting:)`, and recursive mirrors remain closed.

Complete current-tree validation is recorded in `implementation-validation-round9.md`.
