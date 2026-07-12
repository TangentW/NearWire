# Pre-Implementation Architecture and API Review — Round 2

## Scope

Re-reviewed the revised proposal, design, all delta specifications, tasks, prior review reports, current lifecycle-related specifications, and current public-connect/lease ownership implementation. This is report-only; no production or test source was modified.

## Prior-Finding Disposition

All five Round 1 findings are resolved:

1. **Pairing-code ownership:** one actor-owned pending capsule now exists before suspension, is promoted rather than copied at connected commit, and delay Tasks carry no code (`design.md:64-70`; `specs/sdk-public-connect/spec.md:32-44`).
2. **Disconnected intent and disconnect:** the canonical matrix distinguishes disconnected-with-intent, and disconnect is a work no-op only when intent, route/attempt, recovery Task, and receipt are absent (`design.md:82-86,122-140`; `specs/sdk-connection-lifecycle/spec.md:54-60,116-137`).
3. **Explicit connect during lifecycle ownership:** fixed preflight errors reject suspension, recovery/cleanup, active route, and retained intent; changing code requires awaited disconnect (`design.md:84-86`; `specs/sdk-connection-lifecycle/spec.md:40-52`).
4. **Supported recovery-policy API:** the exact public type, initializer, Duration units, disabled representation, configuration parameter, validation fields, and consumer form are specified (`design.md:26-60,150-165`; `specs/sdk-connection-lifecycle/spec.md:3-22`).
5. **Cleanup waiter bound:** one exact-route receipt owns one shared completion Task, with no actor-owned caller continuation list and explicit caller-cancellation/fail-closed behavior (`design.md:88-96`; `specs/sdk-connection-lifecycle/spec.md:54-75,155-162`).

## Remaining Finding

### 1. P1 / High — `resumeConnection()` is not inert while an active route is already connected

**Evidence**

- The design says that when active intent exists, resume resets the recovery campaign and schedules recovery; if cleanup remains in flight, it records a Boolean request for after receipt completion (`design.md:82-84`).
- The normative requirement repeats that any active intent causes campaign reset and attempt-one scheduling, and declares only no-intent or already-current campaign cases inert (`specs/sdk-connection-lifecycle/spec.md:77-83`).
- A connected route necessarily has active intent and an unsettled route cleanup receipt. The text therefore permits either an immediate overlapping recovery request or a deferred resume request that unexpectedly starts when the healthy route later terminates.
- The canonical status table has no resume-while-connected row, and task 5.1 does not explicitly require it (`design.md:122-140`; `tasks.md:27-30`).

**Impact**

A repeated foreground/scene callback can reset the intent-wide attempt budget while already connected and can opt a default-disabled connection into a future recovery attempt without a preceding suspension or explicit disconnected retry. That breaks idempotent resume semantics and the bounded automatic-work model.

**Required remediation**

Define resume eligibility as active intent with no current route/attempt/delay and either a previously suspended cleanup flow or a disabled-policy transient-disconnected status. `resumeConnection()` while connected, while an initial connect is pending, or while an automatic/explicit recovery campaign is current must be inert and must not reset budget or store the Boolean deferred request. Reserve the Boolean only for resume that follows a suspension and arrives before that suspended route's receipt settles. Add canonical matrix rows and deterministic tests for resume while connected, during initial connect, during automatic delay/attempt, after disabled transient disconnection, and during suspended cleanup.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: passed.
- `git diff --check -- openspec/changes/sdk-connection-lifecycle`: passed.

## Verdict

**Unresolved actionable findings: 1 (High). Not ready for implementation until resume eligibility is closed.**

Aside from this command-eligibility gap, the revised lifecycle ownership, public API, lease/receipt, route replacement, data-retention, status, resource, and scope boundaries are coherent and implementation-ready.
