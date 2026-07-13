# Implementation Remediation — Round 11

Date: 2026-07-13 (Asia/Shanghai)

This remediation addresses the one Medium finding `NW-LSS-IMPL-R11-ARCH-001` from the Round 11 architecture/API review. The Round 11 correctness/testing and security/performance/documentation reviews reported zero findings. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain deferred, by user direction, to the goal-level `release-hardening` change and are not represented as passing here.

## Generation-bound initial outage marker

- `ViewerStoreRuntime.runtimeStarted` now distinguishes a new logical runtime generation from a repeated callback for the same logical ID.
- A new generation that has no attachable coordinator receives one saturating runtime-level missed observation. This covers both bootstrap/path/schema failure and a replacement runtime waiting for the prior runtime's coordinator to close.
- An attachable coordinator does not receive this runtime-level marker. Its accepted asynchronous start failure retains the coordinator-local marker added in Round 10, so the two ownership paths cannot duplicate the same unavailable interval.
- Repeated start callbacks for the same generation no longer clear the existing missed aggregate or add another initial marker.
- Recovery still claims the exact aggregate, resets the live counter while work is in flight, restores the claim on failure, and clears it only after the replacement coordinator successfully owns the partial recording and its recording-level `storageUnavailable` gap.

## Deterministic zero-observation recovery regressions

- `testUnavailableRuntimeReopensAfterExplicitRetry` starts against a rejected schema and emits no device, Event, policy, or drop callback. After schema repair, one injected recovery write failure leaves zero recordings and unavailable status. The next retry creates the original logical recording with `midRuntimeRetry`, exactly one recording-level unavailable gap, and no device. A later retry crosses the preparation prefix and proves the gap is not duplicated.
- `testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime` starts a replacement logical runtime while the coordinator still belongs to its predecessor and emits no replacement callback. A Viewer-internal no-op-by-default reopen execution gate deterministically pauses the replacement after old-runtime cleanup; the test arms one recovery write failure before releasing it. The failed attempt leaves no replacement recording. The next retry creates exactly one partial replacement recording, one recording-level unavailable gap, and no device; a later retry does not duplicate it.
- The same two tests passed 100 iterations each in one 200-test stress run. The reopen gate is module-internal, has no public/API/protocol surface, and is a no-op in production composition.
- `testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes` now expects three missed observations: one generation-start marker plus its two deliberate nondurable policy callbacks.

Complete current-tree validation is recorded in `implementation-validation-round12.md`.
