# Implementation Remediation — Round 15

Date: 2026-07-13 (Asia/Shanghai)

This remediation resolves correctness/testing finding `NW-LSS-IMPL-R15-CT-001`.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain
deferred, by user direction, to goal-level `release-hardening`. They are not represented as
passing evidence here.

## Final current-runtime shutdown owns a stale predecessor construction

- `detachRuntime(logicalID:)` now distinguishes two cleanup authorities. A noncurrent late cleanup
  still captures only the construction lease whose typed request belongs to that exact logical
  runtime. Ending the current runtime, which removes the last current context and makes every
  predecessor construction stale, captures the one active construction lease regardless of the
  predecessor request ID.
- The lease is captured while the runtime lock still defines that ownership transition, but the
  wait remains outside `NSLock`. Existing request/generation checks, one-shot lease completion,
  stale coordinator close, and valid newer-runtime overlap remain unchanged.
- Multiple cleanup calls may safely wait on the same `DispatchGroup`-backed lease. A late cleanup
  for predecessor B therefore remains harmless after current runtime C has already waited for and
  completed the stale B construction cleanup.
- `testFinalCurrentRuntimeWaitsForSupersededReopenConstruction` deterministically starts a paused
  B-owned construction, supersedes it with current runtime C, and ends C before late B cleanup.
  The test proves C remains in `runtimeEndWaiting`, releasing B constructs and explicitly closes
  the stale coordinator before C completes, neither B nor C records, late B cleanup is harmless,
  and a later D receives the retained single automatic recovery attempt and outage gap.

The direct regression passed on the final code path. The complete nine-scenario stress matrix then
passed 20 iterations per scenario (180 tests total), followed by complete Store and Viewer
regressions. Exact final-tree evidence is recorded in `implementation-validation-round16.md`.

## Review-threshold observation

The bounded terminal-close worker-tail observation from Round 15 remains non-actionable under the
goal threshold. At most one already-sampled successor closure can reach the first locked guard
after terminal close. It performs no execution-gate, filesystem, SQLite, maintenance, status, or
recording work, cannot accumulate, and has no normal-work or architecture effect. No additional
worker-completion mechanism was introduced for that guard-only tail.
