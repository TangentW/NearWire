# Implementation Remediation — Round 12

Date: 2026-07-13 (Asia/Shanghai)

> Supersession note: Round 13 found that the statement below about never reopening an idle store
> was incomplete for a queued automatic reopen whose triggering runtime ended before the queued
> work resumed. That edge is corrected by the runtime-bound request and generation invalidation
> recorded in `implementation-remediation-round13.md`. The steady-state Round 12 behavior remains
> valid, but this document must not be read as evidence for the later cancellation edge.

This remediation addresses the Medium finding `NW-LSS-IMPL-R12-ARCH-001` and Low finding `NW-LSS-IMPL-R12-ARCH-002` from the Round 12 architecture/API review. The Round 12 correctness/testing and security/performance/documentation reviews reported zero findings before these adjacent lifecycle issues were identified. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain deferred, by user direction, to the goal-level `release-hardening` change and are not represented as passing here.

## Sequential runtime reopen ownership

- Detaching a coordinator after a runtime shutdown now preserves one bounded reopen-on-next-runtime reason even when no successor context already exists. It does not immediately reopen an idle store and does not change initial bootstrap/path/schema failure, which remains explicit-retry-only.
- The next distinct logical runtime adds its one initial nondurable marker and schedules at most one fresh coordinator/reconciliation attempt through the existing `reopenScheduled` gate. There is no polling or recurring retry.
- If that automatic attempt fails, the generation-bound recovery completion restores the exact marker and remains unavailable. A later explicit retry can consume it only after the new partial recording and recording-level gap exist.
- `testSequentialRuntimeAutomaticallyReopensAfterCompletedShutdown` starts and fully ends runtime A before starting runtime B on the same `ViewerStoreRuntime`. Without any explicit retry, B receives a distinct active recording while A remains closed.
- `testFailedAutomaticSequentialReopenRetainsMarkerForExplicitRetry` deterministically pauses that automatic attempt, injects one write failure, proves no false B recording, and verifies one later explicit retry creates B with exactly one recording-level unavailable gap and no device.
- `testApplicationRetryAndIdentityResetReuseOneStoreRuntimeAutomatically` composes the real `ViewerMultiDeviceSessionManager` with one shared store runtime. Viewer application Retry and TLS identity reset create three sequential recording generations; each predecessor closes and each successor starts without a storage retry call.

## Same-generation start idempotence

- `ViewerStoreRuntime.runtimeStarted` now returns immediately when the logical ID already matches the retained runtime context. The first wall and monotonic start times remain authoritative.
- A duplicate callback cannot forward another coordinator start, mutate active sessions, clear `coordinatorNeedsRecovery`, alter an in-flight claim, or create overlapping coordinator-local and runtime-level markers.
- Recovery authority is therefore cleared only through the existing generation/coordinator-matching successful materialization completion, never through duplicate start queue admission.
- `testRepeatedRuntimeStartPreservesOriginalContextAndRecoveryOwnership` repeats the same logical start before first reopen, while reopen is paused, and after a failed claim is restored. The later successful retry persists the original time, one `midRuntimeRetry` recording, one recording-level unavailable gap, no device, and no duplicate on another retry.

All four new regressions passed 20 iterations each in one 80-test run. Complete current-tree validation is recorded in `implementation-validation-round13.md`.
