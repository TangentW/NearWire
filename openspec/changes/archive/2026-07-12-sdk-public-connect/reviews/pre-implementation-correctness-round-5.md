# Pre-Implementation Correctness and Testing Review — Round 5

## Scope

Performed a final concise pre-implementation review of the revised `sdk-public-connect` planning artifacts. This round reports only correctness or test-plan issues that would block implementation. It verified chronology across delayed admission-result delivery and the exhaustive no-lifetime cleanup regimes, then sanity-checked their interaction with shutdown precedence, state publication, one-wait/one-release ownership, weak-owner cleanup, Keychain transcripts, and limit evidence. No planning or production source was modified.

## Round 4 Remediation Confirmation

### One pre-created transition gate preserves chronology

Confirmed.

- The attempt creates one `SDKSessionTransitionGate` before any suspension and uses it for cancellation reason, target generation, authorization, terminal mark, active-transfer claim, and connected-commit claim (`design.md:56-69`; `specs/sdk-public-connect/spec.md:86-90`; `tasks.md:18`).
- Admission receives that exact object before `run`, and a successful `SDKSessionLifetime` adopts it by reference identity rather than copying state into a second gate (`design.md:67,117-129`; `specs/sdk-session-admission/spec.md:3-9`; `specs/sdk-public-connect/spec.md:88-108`).
- Task cancellation recorded before admission returns and a core terminal mark occurring while result delivery is delayed therefore retain their real lock order. Core terminal marking, active transfer, and connected commit use the same gate; waiter or callback scheduling cannot redefine the winner (`specs/sdk-session-admission/spec.md:9-35`; `specs/sdk-public-connect/spec.md:108-114`).
- Same-gate lease handoff acknowledges coordinator ownership before clearing the attempt handle, so cancellation/terminal chronology and lease ownership do not cross separate locks or copied state (`design.md:129-133`; `specs/sdk-public-connect/spec.md:90,108`).
- Critical-section hooks and explicit task-versus-terminal delayed-result tests make both winners deterministic without sleeps (`tasks.md:23`).

### No-lifetime release regimes are exhaustive and testable

Confirmed.

- Ordinary token-current failure and Task cancellation keep the attempt slot attached until the current identity/admission operation completes, invoke exact release once, then clear the slot, publish disconnected only if discovery began, and complete the pending call. A same-instance overlap remains `connectionInProgress` until cleanup finishes (`design.md:151-153`; `specs/sdk-public-connect/spec.md:151-153`; `specs/sdk-process-connection-lease/spec.md:7`).
- Shutdown is the only pre-admission reason that detaches the slot immediately. Its non-public cleanup owner completes the operation, invokes exact release once, performs no later actor mutation, and only then lets the pending connect call return shutdown; shutdown state itself remains immediate and final (`design.md:155`; `specs/sdk-public-connect/spec.md:153`; `specs/sdk-async-facade/spec.md:7-22`).
- Task cancellation followed by shutdown transitions to the shutdown result through the same gate and existing pending-call precedence; it cannot create a third release regime or a second owner (`design.md:33,65-69,155-159`; `specs/sdk-public-connect/spec.md:9,90,153-157`).
- Successful admission atomically hands the lease to the sole coordinator. Thus every path is exactly one of two ownership classes: no lifetime releases after operation completion; lifetime releases only after the sole wait observes synchronous core terminal (`design.md:157-159`; `specs/sdk-public-connect/spec.md:155-157`).
- Task 3.10 requires the identity, discovery, phase, and admission matrix under ordinary failure, Task cancellation, and shutdown, with separate attached-slot and immediate-detachment assertions, result-after-release, zero coordinator/wait, and retry only after successful synchronization (`tasks.md:26`).

## Blocking Findings

None.

The revised plan provides a single implementable chronology, an exact lease owner at every boundary, deterministic both-winner hooks, and mutually exclusive cleanup expectations. Remaining implementation details can be evaluated by the required post-implementation correctness review.

## Review Status

**Unresolved finding count: 0. Correctness/testing pre-implementation approval is granted.**

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- Static trace of pre-created gate identity, admission-result delay, task/terminal/shutdown ordering, no-lifetime cleanup, atomic coordinator handoff, state/result order, exact release, weak-owner cleanup, Keychain transcript coverage, constant-space limit proof, and deterministic hooks.
