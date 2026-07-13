# Implementation Remediation — Round 14

Date: 2026-07-13 (Asia/Shanghai)

This remediation resolves architecture/API finding `NW-LSS-IMPL-R14-ARCH-001`,
correctness/testing finding `NW-LSS-IMPL-R14-CT-001`, and
security/performance/documentation finding `NW-ISPD14-001`.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain
deferred, by user direction, to goal-level `release-hardening`. They are not represented as
passing evidence here.

## Explicit retry does not create automatic authority

- `needsRuntimeReopen` is now written only when a coordinator that owned a logical runtime is
  intentionally detached. No-coordinator `retryStorage()` creates only a typed explicit request;
  it does not mutate the process-lifetime automatic reason.
- A failed explicit constructor or an explicit request cancelled with runtime A therefore clears
  only its request generation. Starting runtime B cannot probe the store automatically. B remains
  unavailable until its own explicit retry succeeds.
- Intentional clean detach still retains the existing one next-runtime automatic reason. A failed
  automatic or explicit attempt made while that independent reason exists does not erase it. A
  successful replacement consumes it, and terminal close clears it.
- `testFailedInitialExplicitRetryDoesNotAuthorizeLaterRuntime` and
  `testCancelledInitialExplicitRetryDoesNotAuthorizeLaterRuntime` start from an unsupported schema,
  exercise both escape paths, repair the schema, and prove the later runtime creates no recording
  until its own explicit retry. The later successful retry owns exactly one unavailable gap.

## Authorized construction is part of shutdown completion

- A reopen turn that passes its first authority check creates a generation- and request-bound
  completion lease before releasing the runtime lock. Filesystem, SQLite, maintenance, recovery,
  close, gate, and wait work remain outside that lock.
- A runtime end waits only for a construction lease whose typed request belongs to that exact
  logical runtime, even if a newer runtime context has already superseded it. Terminal
  `closeStorage` waits for any current construction lease. Unrelated newer-runtime ownership is
  not globally drained.
- The lease completes only after constructor failure, valid publication/admission, or explicit
  close of a successfully constructed replacement that lost authority. Shutdown cannot return
  while three stale SQLite connections or startup maintenance can still open or remain owned.
- The execution gate now pauses after the first authority check and lease reservation. Internal
  content-free resource events deterministically prove runtime-end and terminal-close wait, a
  stale coordinator is constructed, it is explicitly closed, and only then shutdown completes.
- `testEndedRuntimeCancelsPausedAutomaticReopenAndPreservesNextAttempt`,
  `testTerminalCloseCancelsPausedAutomaticReopen`, and
  `testNewerRuntimeSupersedesPausedAutomaticReopen` cover matching end, terminal close, and a late
  superseded-runtime end while a newer context remains valid. The real application rapid-stop
  regression now also proves the application remains in `stopping` until the authorized turn is
  released and quiesced.

## One physical worker with one coalesced latest successor

- Logical request presence and physical worker occupancy are now separate state. At most one
  `reopenQueue` closure is queued or running. While it executes, any number of distinct runtime
  generations replace one bounded latest request instead of enqueuing additional closures.
- When the current worker returns, it schedules at most one successor turn if one latest request
  still has authority. Constructor/recovery failure clears the current request and creates no
  automatic successor. Terminal close clears the latest request, so the worker schedules none.
- No timer, polling loop, recursion, unbounded task/value allocation, or third executor was added.
  Request identity, generation checks, pre-publication validation, and explicit stale close remain
  intact.
- `testRepeatedRuntimeSupersessionCoalescesOneReopenSuccessor` blocks one turn, applies 64 distinct
  superseding generations, and proves only two physical gate turns occur, only the latest runtime
  materializes, and it owns one unavailable gap. `testTerminalCloseDiscardsCoalescedReopenSuccessor`
  applies the same 64 generations and proves terminal close leaves one physical turn, no successor,
  no new recording, and no available coordinator.

All eight direct remediation scenarios passed 20 iterations each in the final 160-test stress
run. Complete current-tree evidence is recorded in `implementation-validation-round15.md`.
