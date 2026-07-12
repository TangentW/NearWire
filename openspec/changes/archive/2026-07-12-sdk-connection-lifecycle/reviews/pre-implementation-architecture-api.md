# Pre-Implementation Architecture and API Review

## Scope

Reviewed `proposal.md`, `design.md`, all five delta specifications, `tasks.md`, the pre-implementation validation evidence, the current public-connect/session/lease implementation, current capability specifications, and `NearWire-Platform-Architecture.md`. This is a report-only review; no production or test source was modified.

## Findings

### 1. P1 / High — The normalized pairing code has no legal owner between admission handoff and connected intent commit

**Evidence**

- The design says lifecycle intent exists only after an explicit connection becomes active and route owners retain no code (`design.md:44-50`).
- The public-connect delta requires the public attempt to release its normalized code immediately after transferring it into admission, while the separate intent copy may be installed only at connected commit (`specs/sdk-public-connect/spec.md:32-44`). Connected commit and intent installation must be indivisible (`specs/sdk-public-connect/spec.md:9-15`).
- Once admission consumes the current one-shot transfer, no normalized value remains from which the actor can create that post-commit intent. Retaining another local copy through discovery/admission would directly violate the stated immediate-release rule.
- The same ownership model is weakened again by the recovery design, which copies the code into the delay Task even though the actor is supposed to own the single intent (`design.md:127-133`; `specs/sdk-connection-lifecycle/spec.md:24-28`).

**Impact**

The central lifecycle state cannot be implemented while satisfying its own retention contract. A workaround risks either losing recovery ability at commit or silently introducing second, long-lived code owners.

**Required remediation**

Define one explicit actor-owned provisional intent/candidate created after validation and before admission. It may hold the sole lifecycle copy through the initial attempt, must not authorize recovery before connected commit, is promoted atomically at commit, and is cleared on every initial failure, cancellation, disconnect, suspension decision, or shutdown. Update the minimal-retention requirement to distinguish this actor-owned candidate from route/admission ownership. Recovery delay Tasks should carry generation and attempt metadata only and fetch the code from the actor after wake and reauthorization; they should not copy it across sleep.

### 2. P1 / High — `disconnect()` is specified as a no-op in a state that can still own intent

**Evidence**

- Suspension preserves intent but publishes `disconnected` with `isSuspended == true` (`design.md:64-68,113-125`; `specs/sdk-connection-lifecycle/spec.md:61-75,98-104`).
- Manual disconnect must clear intent first (`design.md:66`; `specs/sdk-connection-lifecycle/spec.md:40-44`).
- The same normative paragraph says disconnect from `disconnected` is a no-op (`specs/sdk-connection-lifecycle/spec.md:44`). Thus `disconnect()` while suspended can either violate the no-op rule or fail its primary promise to clear the retained code and connection intent.
- Disabled recovery also leaves the post-transient intent lifetime unclear: explicit resume is promised even when automatic recovery is disabled, but a failed one-shot resume does not say whether intent is retained for another explicit resume or cleared as exhausted (`design.md:34-36`; `specs/sdk-connection-lifecycle/spec.md:77-80`).

**Impact**

Public lifecycle behavior depends on state labels that do not uniquely describe ownership. Apps cannot reliably use disconnect to forget a suspended Viewer, and implementations can diverge on whether explicit resume remains usable after a disabled-policy failure.

**Required remediation**

Specify an intent/route/recovery state matrix. Disconnect is a no-op only when intent, current route/attempt, recovery Task, and cleanup boundary are all absent; it must clear a suspended intent even though public state is already disconnected. Define whether transient termination under disabled policy preserves intent, and whether each failed explicit resume preserves it for another host request or consumes/clears it. Include status fields and pairing-reference clearing for every row.

### 3. P1 / High — Explicit `connect(code:)` has no deterministic rule while lifecycle intent or recovery exists

**Evidence**

- The design says intent may be cleared by a “superseding explicit connection” and every explicit connect advances/checks lifecycle generation (`design.md:44-47,70-74`).
- The public-connect delta preserves the old preflight rule that rejects only a current attempt or active slot; it does not classify a suspended intent or recovery delay, where the slot may be empty (`specs/sdk-public-connect/spec.md:3-9`). During a recovery attempt the slot is expected to be occupied, so the same call can be accepted during delay but rejected moments later during attempt execution.
- The platform architecture explicitly requires callers to disconnect before entering a new code and forbids implicit target replacement (`NearWire-Platform-Architecture.md:353-364`).
- No scenario or task defines cancellation, cleanup waiting, error precedence, or lease ordering for a new explicit connect racing a recovery delay or replacement route.

**Impact**

Viewer replacement can become timing-dependent and may either overlap lifecycle work or unexpectedly supersede retained intent, contrary to the product's explicit-disconnect rule.

**Required remediation**

Choose and specify one policy. The architecture-consistent recommendation is to reject explicit connect whenever any lifecycle intent, recovery delay/attempt, active route, or cleanup boundary exists, requiring `await disconnect()` before a new code. Define the fixed public error and its precedence. If supersession is intentionally desired instead, specify generation invalidation, old cleanup completion, release-before-new-claim, suspension reset, status changes, and pairing clearing as a complete async connect path with both-winner tests.

### 4. P2 / Medium — The supported reconnection-policy API is not defined enough to implement or compile a consumer

**Evidence**

- The design and specification name `NearWireReconnectionPolicy` and validation ranges but provide no public declaration, disabled representation, initializer/factory, property visibility, or delay value type (`design.md:26-36`; `specs/sdk-connection-lifecycle/spec.md:3-22`).
- `NearWireConfiguration` is said to gain a `reconnection` value, but its revised supported initializer signature and default are not specified. Task 2.3 requires representative consumer compilation without defining what that consumer should write (`tasks.md:6-10`).

**Impact**

Different implementations can expose incompatible enum/struct shapes or `Duration`/floating-point APIs while all appearing to satisfy the prose. Checked nanosecond conversion and stable validation fields also depend on this choice.

**Required remediation**

Add the exact supported declarations to the design/spec: disabled and bounded construction, throwing validation surface, public read-only fields, delay type and units, `NearWireConfiguration` initializer integration with a source-compatible default, and fixed validation field names. Add the intended SwiftPM/CocoaPods consumer snippet to the plan.

### 5. P2 / Medium — The promised bounded cleanup-waiter list has no enforceable bound

**Evidence**

- The actor is designed to store cleanup waiters, and the normative resource requirement promises a bounded list (`design.md:70-81`; `specs/sdk-connection-lifecycle/spec.md:137-144`; `tasks.md:14,29-30`).
- Public code may create an arbitrary number of concurrent `disconnect()` or `suspendConnection()` calls. No maximum, overflow behavior, cancellation removal rule, or alternative shared completion owner is defined.

**Impact**

An implementation that appends one continuation per caller cannot meet the resource claim, while an arbitrary silent cap would strand or prematurely resume public calls.

**Required remediation**

Replace the actor-owned waiter list with one tokenized shared cleanup boundary/Task per generation that all callers await, and specify cancellation semantics for each caller; or define a concrete capacity and a supported overflow outcome. Update tasks and retention tests to assert the chosen constant-size actor ownership model.

## Verdict

**Not ready for implementation. Unresolved actionable findings: 5 (3 High, 2 Medium).**

The overall separation of lifecycle intent from fresh route ownership, release-before-replacement rule, host-controlled suspension, bounded recovery, weak actor recovery Task, and latest-value status direction are sound. The five contracts above must be resolved before source changes because they determine whether the core ownership model is implementable and whether public calls have deterministic semantics.

Pre-implementation gates currently pass: strict OpenSpec validation and `git diff --check`.
