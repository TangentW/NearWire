# Implementation Remediation — Round 13

Date: 2026-07-13 (Asia/Shanghai)

> Supersession note: Round 14 showed that logical request invalidation did not by itself bound the
> number of closures physically retained by `reopenQueue`. The one-worker/latest-successor bound
> is implemented and evidenced in `implementation-remediation-round14.md`. The request identity
> and stale-publication correction below remains valid, but `reopenScheduled` alone is not used as
> physical queue-bound evidence.

This remediation resolves architecture/API finding `NW-LSS-IMPL-R13-ARCH-001` and the matching
security/performance/documentation finding `NW-ISPD13-001`. Both reports described the same Low
severity edge: queued automatic reopen work could outlive the runtime that authorized it, then
install an idle SQLite coordinator after runtime shutdown or terminal storage close.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain
deferred, by user direction, to goal-level `release-hardening`. They are not represented as
passing evidence here.

## Runtime-bound reopen authority

- Every admitted reopen is now a typed request. An automatic request captures the exact runtime
  logical ID that authorized it; an explicit operator request captures either the current runtime
  ID or the deliberate no-runtime state. Automatic and explicit authority are no longer
  conflated in one Boolean queue flag.
- Each admitted request also receives a monotonic reopen-attempt generation. The stored request,
  generation, coordinator absence, and current runtime identity must all still match before work
  is allowed to construct or publish a replacement.
- A distinct runtime start invalidates obsolete reopen authority before installing the new
  context. Ending the matching runtime invalidates its queued request. Terminal `closeStorage`
  invalidates all queued reopen and recovery work while clearing runtime/session state.
- The reopen queue rechecks authority after the execution gate and before coordinator
  construction. It checks again before publication. If authority changes after construction, the
  replacement is explicitly closed, releasing its writer, query, export, maintenance, signal,
  and executor ownership rather than publishing or abandoning it.
- Cancelling a stale automatic request does not consume the process-lifetime
  reopen-on-next-runtime reason. A later distinct runtime can therefore receive one bounded
  automatic attempt. A newer runtime that supersedes paused work owns only its own request and
  recovery marker. No timer, polling loop, recursive dispatch, or automatic successor was added.

## Deterministic regression matrix

- `testEndedRuntimeCancelsPausedAutomaticReopenAndPreservesNextAttempt` pauses runtime B's
  automatic reopen, fully ends B, releases the queue, proves no B recording or idle available
  coordinator appears, and then proves runtime C receives one automatic recovery with one gap.
- `testTerminalCloseCancelsPausedAutomaticReopen` pauses automatic reopen, calls terminal
  `closeStorage`, releases the queue, and proves the closed runtime cannot recreate storage.
- `testNewerRuntimeSupersedesPausedAutomaticReopen` installs runtime C while B's queued request is
  paused, proves the B request cannot publish or consume C's claim, and proves late B cleanup
  cannot affect C.
- `testApplicationRapidStopCancelsPausedAutomaticReopen` composes the real
  `ViewerApplicationModel`, `ViewerMultiDeviceSessionManager`, and shared `ViewerStoreRuntime`.
  Application Retry creates B, the test pauses B's automatic reopen, termination fully ends B,
  and queue release proves no idle coordinator or second recording survives shutdown.

The first application-test attempt synchronously waited on a semaphore while executing on
`MainActor`. That test-only wait prevented `retry()` from creating runtime B and timed out before
the intended race existed. The wait now runs in a detached task so `MainActor` can advance. No
production behavior was changed for that test correction. The failed assertion result and the
successful rerun are both disclosed in `implementation-validation-round14.md`.

The incomplete Round 12 evidence statement is explicitly superseded in
`implementation-remediation-round12.md`. Complete current-tree validation is recorded in
`implementation-validation-round14.md`.
