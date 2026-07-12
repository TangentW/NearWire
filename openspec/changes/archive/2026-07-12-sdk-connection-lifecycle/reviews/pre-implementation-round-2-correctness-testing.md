# Pre-Implementation Correctness and Testing Review — Round 2

## Scope

Re-reviewed the revised `sdk-connection-lifecycle` proposal, design, all delta specs, and tasks against the current public-connect orchestration. This round focused on the six prior findings and new material correctness/testability gaps only. No production or test source was modified.

## Prior Findings

| Round 1 finding | Resolution |
| --- | --- |
| No legal pairing-code owner at connected commit | Resolved. One actor-owned pending capsule is installed before suspension, promoted without another lifecycle copy, and cleared on every pre-commit losing path. Admission owns only its separate one-shot discovery transfer; delay Tasks are code-free (`design.md:64-70`; `specs/sdk-connection-lifecycle/spec.md:24-38`; `specs/sdk-public-connect/spec.md:32-44`). |
| Generation invalidation could strand cleanup waiters | Resolved. Lifecycle mutation generation and exact-route receipt settlement are independent; old release delivery settles its receipt before freshness checks, while stale state/intent/recovery mutation remains forbidden (`design.md:88-96`; `specs/sdk-connection-lifecycle/spec.md:54-75`; `specs/sdk-process-connection-lease/spec.md:3-22`). |
| Lifecycle command precedence and connect supersession undefined | Resolved. Disconnect is monotonic, shutdown is highest, suspend/resume behavior is explicit, and connect rejects suspension, recovery/cleanup, active route, or retained intent in a fixed preflight order (`design.md:72-86`; `specs/sdk-connection-lifecycle/spec.md:40-52,77-98`; `specs/sdk-public-connect/spec.md:3-20`). |
| Resume delay and budget ambiguous | Resolved. The enabled policy has an intent-wide budget that survives brief success; enabled resume uses configured attempt-one delay; disabled resume authorizes one immediate attempt and preserves transient intent (`design.md:26-62,142-148`; `specs/sdk-connection-lifecycle/spec.md:3-17,77-98`). |
| Cleanup completion, caller cancellation, and waiter bound open | Resolved. Callers await one shared constant-space Task, intentionally ignore caller cancellation, settle after exact release invocation, and deliberately remain incomplete on terminal-wait failure (`design.md:88-96`; `specs/sdk-connection-lifecycle/spec.md:54-75,155-162`). |
| State/status matrix incomplete | Resolved. The canonical matrix now covers idle suspension, initial phases, disabled/enabled recovery, success, exhaustion, suspension, disconnect, and shutdown; it also defines independent stream coalescing and current-value coherence (`design.md:104-140`; `specs/sdk-connection-lifecycle/spec.md:116-137`). |

## Remaining Findings

### 1. MEDIUM — `resumeConnection()` is not explicitly inert while a route is already connected

**Evidence**

- Resume is idempotent, but the normative text says that whenever active intent exists it resets the campaign and schedules attempt one; it only excludes no-intent and already-current campaigns (`specs/sdk-connection-lifecycle/spec.md:77-83`; `design.md:82`).
- A normally connected route has active intent but no recovery campaign. Literal implementation would therefore schedule recovery while the old route is still active, conflicting with the fresh-route no-overlap rule (`specs/sdk-connection-lifecycle/spec.md:139-148`) and one-current-route boundary.
- The intended useful resume states are suspended cleanup/completion and disabled-policy transient-disconnected intent; the connected/no-suspension row is absent from the canonical matrix.

**Required remediation**

State that resume is inert while an active route or any attempt/campaign is current. It may start attempt one only when active intent exists, no route/attempt/campaign is current, cleanup is settled (or deferred by the one Boolean request), and suspension has just been cleared or the instance is transient-disconnected with retained intent.

**Required deterministic scenarios**

- Resume once and repeatedly while connected: zero generation/budget change, zero Task, zero claim, no publication.
- Resume during active recovery: no reset or second Task.
- Resume during suspended cleanup: one Boolean request and one post-receipt attempt.
- Resume after disabled transient disconnection: exactly one immediate attempt.

### 2. MEDIUM — Pre-active `remoteClosed` still lacks a recovery disposition

**Evidence**

- The phase-aware mapping explicitly makes active-route `remoteClosed` transient and pre-active `transportFailed` permanent, but does not classify pre-active `remoteClosed` (`design.md:98-102`; `specs/sdk-connection-lifecycle/spec.md:100-114`).
- `remoteClosed` is reachable before active commit during hello/approval and handoff, not only after connection (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:895-965,971-1013`).
- Task 4.1 requests exhaustive phase-aware mapping, so the missing row prevents a complete code-by-reachable-phase oracle (`tasks.md:21`).

**Required remediation**

Assign pre-active `remoteClosed` explicitly to transient or permanent and explain the choice. Then require a table test over every `SDKSessionAdmissionError.Code` and every reachable origin phase, with impossible pairs documented, so no switch default can hide an unclassified future row.

**Required deterministic scenarios**

- Viewer disconnect/error during hello, approval, policy handoff, and active state.
- Assert exact safe error, disposition, intent retention/clearing, budget consumption, next-delay decision, and no plaintext fallback for each reachable phase.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: PASS — `Change 'sdk-connection-lifecycle' is valid`.
- `git diff --check -- openspec/changes/sdk-connection-lifecycle`: PASS.

## Verdict

**Unresolved actionable finding count: 2 — 0 High, 2 Medium. Pre-implementation correctness/testing approval is not yet granted.**

The six Round 1 ownership, cleanup, precedence, budget, waiter, and status issues are resolved. Implementation can proceed after the connected-resume no-op row and pre-active `remoteClosed` disposition are made explicit and added to the deterministic matrices.
