# Pre-Implementation Correctness and Testing Review — Round 1

## Scope

Reviewed the complete `sdk-public-connect` proposal, design, capability deltas, and task plan against the current `NearWire` actor, latest-value state hub, exact process lease, `SDKSessionAdmission`, admitted-session handoff, active-pump activation/termination ownership, shutdown, and stream behavior. The review traced same-instance actor reentrancy, task cancellation, shutdown and deinitialization, discovery phase delivery, lease claim/release, admission-to-activation transfer, terminal races, stale callbacks, retry, state order, Keychain outcomes, error mapping, and deterministic evidence requirements. No planning or production source was modified.

The existing lower layers provide strong building blocks: actor-isolated facade state, bounded latest-value streams, exact-token lease release, one-shot admission, active activation cancellation gates, and a non-owning one-shot termination observer. The findings below concern the public composition contract and the evidence needed before implementation.

## Findings

### 1. HIGH — Attempt-time deinitialization is required and tested even though the async instance call retains the actor

**Evidence**

- The public API is an instance actor method that remains pending through discovery, admission, attachment, and active-pump activation (`design.md:13-21,34-42`; `specs/sdk-public-connect/spec.md:3-8`). An executing async instance method normally retains its `self` for the lifetime of that invocation.
- The plan nevertheless requires owner destruction to release every attempt and active session, and Task 3.5 requires deinitialization at every suspension (`proposal.md:9-12`; `design.md:90-97,161-168,176-181`; `specs/sdk-async-facade/spec.md:3-5`; `tasks.md:18-19`).
- Current `NearWire` deinitialization can finish nonisolated stream hubs only after the actor is actually released (`SDK/Sources/NearWire/NearWire.swift:64-119`). The proposed weak terminal Task makes active-session deinitialization feasible after `connect` returns, but it does not make the actor releasable while the still-running `connect` invocation owns it.

**Impact**

An abandoned connection Task can keep the facade, attempt owner, lease, pairing code, and internal admission alive until cancellation or an internal deadline. A test that merely drops the caller's separate reference while `connect` is suspended cannot prove deinitialization cleanup because deinit should not run. The task plan currently demands evidence for an unreachable ordering.

**Required remediation**

Choose and specify one implementable ownership model. Either narrow deinitialization guarantees and Task 3.5 to active sessions after `connect` returns, with task cancellation as the attempt cleanup mechanism, or define a public orchestration object/task structure that provably does not retain the facade across suspension. Add a retention test that holds weak references to the facade, attempt owner, admission, lease, and terminal observer and distinguishes task cancellation from actual actor deinitialization.

### 2. HIGH — The plan requires deterministic whole-orchestrator races but defines no injectable public orchestration boundary

**Evidence**

- Task 3.5 requires barrier-controlled tests for same-instance reentrancy, contention, retry, cancellation, shutdown/deinit at each suspension, activation/terminal races, stale callbacks, and lease reuse without sleeps; Task 4.2 additionally requires a supported-connect integration without live Bonjour (`tasks.md:19,24`).
- The design names an injected Keychain adapter but defines no fixed `SDKPublicConnectionDependencies`-style boundary for lease claim, identity load, hello construction, admission construction/run, phase delivery, attachment, pump construction/run, connected-owner commit, terminal delivery, and cleanup (`design.md:78-168,176-183`).
- Existing lower-layer seams are not sufficient by themselves. `SDKRuntimeDependencies` currently contains only clocks and UUID generation (`SDK/Sources/NearWire/NearWire.swift:46-58`); admission and active pump each have their own internal dependencies, but the planned facade has no specified way to supply or barrier their construction and handoff as one attempt (`SDK/Sources/NearWire/Session/SDKSessionAdmissionModels.swift:373-425`; `SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:9-224`).

**Impact**

Implementation can satisfy the API while leaving tests coupled to live process globals, actual Keychain, actor scheduling, or incidental callbacks. The most important negative assertions—no second lease claim, no channel after shutdown, no stale owner install, no reconnect, and no lease gap—would then be probabilistic or impossible to place at the required boundary.

**Required remediation**

Add one immutable internal public-connect dependency value bound at `NearWire` initialization. It should expose concrete production closures/factories plus named barrier hooks immediately before and after lease claim, identity load, admission phase delivery, admission result, attachment, activation result, owner commit, terminal callback, and exact cleanup. Test hooks must not replace token checks or lower-layer validation. Update Tasks 3.1–3.5 and 4.2 to require both-winner tests at those named boundaries and exact retained-resource snapshots.

### 3. HIGH — Cancellation, phase observation, and activation transfer do not yet form one complete winner protocol

**Evidence**

- The attempt relay is described as forwarding cancellation once to an admission or active-pump target, but the attempt crosses several ownership states: admission actor, admitted session, pump attachment, activation run, returned handle, and connected owner (`design.md:78-97,161-168`). The plan does not define target replacement, stale-target completion, or the cleanup obligation for every value returned after the slot token was detached.
- The new admission phase observer is async and must run after discovery selection but before channel construction/startup. The specification says its suspension remains covered by cancellation, but it does not require an immediate post-observer cancellation/token check or define which admission state owns cancellation while the observer is suspended (`specs/sdk-session-admission/spec.md:3-25`; `tasks.md:17,19`). Current admission transitions directly from discovery success into core/channel construction, so this is a new cancellation window (`SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:129-178`).
- Task cancellation and shutdown have deliberately different winner rules: activation-first must ignore late task cancellation, while shutdown must remain final even if activation committed (`design.md:161-168`). No shared handshake explains how the outer relay distinguishes these outcomes while the active pump's existing cancellation gate independently decides whether `run()` returns a handle (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:247-265`).

**Impact**

A cancellation delivered to an already inert admission target can be lost during handoff; discovery can resume from a suspended phase callback and construct a channel after shutdown; or a returned admitted session/attachment/active handle can arrive after slot detachment without being cancelled. Conversely, treating every latched task cancellation as authoritative can tear down an activation that the specification says already won.

**Required remediation**

Specify an exact attempt state machine and winner table. Every suspension must resume by checking the same token and disposing any returned internal owner before further work. Define cancellation-target installation/removal as a lock-linearized handshake, including cancellation-before-target, cancellation-during-target-replacement, stale target completion, and target-first completion. For the phase observer, require cancellation checks before invocation and immediately after return, and prohibit channel construction when cancellation/shutdown won. Add barrier tests for task-cancel-first, activation-first, shutdown-first, phase-first, terminal-before-handle-transfer, and handle-transfer-before-terminal, with exact state, lease, handle, callback, and channel counts.

### 4. MEDIUM — Preflight error precedence and pre-discovery state semantics are not deterministic

**Evidence**

- Pairing validation is required before attempt/lease ownership, same-instance overlap must return `connectionInProgress` or `alreadyConnected`, pre-cancelled calls must be rejected deterministically, and connect after shutdown must return the existing shutdown error (`design.md:44-76,78-90,161-166`; `tasks.md:15-16`; `specs/sdk-async-facade/spec.md:3-5`; `specs/sdk-process-connection-lease/spec.md:3-7`).
- These rules do not define the result when conditions overlap: invalid code plus shutdown, invalid code plus an existing attempt/session, or a pre-cancelled Task plus any of those states.
- Identity, metadata, and hello failures occur after slot and lease claim but before `discovering`. The state contract says only failures after `discovering` publish `disconnected`, but the retry and error sections do not explicitly say whether an identity failure leaves `idle`/the prior `disconnected` state unchanged (`design.md:117-151`; `specs/sdk-public-connect/spec.md:28-45,69-89`).
- The proposal says terminal failures map to public errors, while active terminal completion after successful return only publishes `disconnected` and has no public error delivery surface (`proposal.md:8-12`; `design.md:129-159`).

**Impact**

Equivalent calls can return different public codes depending on implementation order, and state/error tests cannot define one expected result. Error-map evidence may also claim active terminal codes are publicly delivered when the supported API only exposes state after return.

**Required remediation**

Add a normative precedence table covering shutdown, pre-cancelled Task, pairing validation, attempting, active, lease contention, and lease-runtime failure. Define state behavior for every failure before and after `discovering`. Narrow public error mapping to errors observable from the pending `connect` call, explicitly stating that post-return active terminal causes are not exposed in this change, or add a separately reviewed terminal-error surface. Require table-driven tests for every overlapping preflight condition and state/error pair.

### 5. MEDIUM — The Keychain test task collapses distinct duplicate and error branches

**Evidence**

- The identity contract distinguishes initial hit, missing item, generation, add, duplicate-add reread, malformed or unexpectedly typed data, access failure, randomness failure, and unresolved duplicate, with no overwrite/delete (`design.md:99-115`; `specs/sdk-public-connect/spec.md:47-67`).
- Task 2.4 lists hit/miss/add/duplicate/malformed/access/random failure generically, but does not require separate outcomes for initial-read failure, add failure, duplicate followed by missing, duplicate followed by malformed data, duplicate reread access failure, or exact bounded call counts (`tasks.md:8-11`).

**Impact**

A nominal duplicate-success test can pass while an implementation retries indefinitely, generates twice, accepts noncanonical data, overwrites an item, or treats a failed duplicate reread as a new missing item. These are the failure branches most likely to differ between simulator, device, extension, and concurrent process behavior.

**Required remediation**

Make Task 2.4 require a table-driven operation transcript: exact Security status/result, returned object type/data, expected read/generate/add counts, accepted UUID or public error, and proof of zero update/delete calls. Cover hit; miss/add success; miss/add ordinary failure; duplicate/reread valid; duplicate/reread missing; duplicate/reread malformed, noncanonical, or unexpected type; duplicate/reread access failure; initial access failure; and random-generation failure. Also assert exact query attributes and that no Keychain operation occurs before successful lease ownership.

### 6. MEDIUM — Lease-release failure is silently possible but the public retry guarantees overstate exact reuse

**Evidence**

- The modified lease capability promises exact idempotent release on failure, terminal completion, cancellation, shutdown, and deinitialization, and Tasks 3.5/4.2 require exact lease reuse/reacquisition (`specs/sdk-process-connection-lease/spec.md:3-27`; `tasks.md:19,24`).
- The same capability partially qualifies this by saying later claim is guaranteed only when synchronization succeeds. Current `ProcessConnectionLeaseHandle.release()` is nonthrowing; a failed runtime enter/exit is silently fail-closed and may leave the exact owner installed (`SDK/Sources/NearWire/Session/ProcessConnectionLease.swift:96-121,219-246`).
- The public plan does not state what state/error or retry behavior applies when cleanup cannot synchronize, and the test plan names no release-failure branch.

**Impact**

Evidence can incorrectly claim that `disconnected` or `shutdown` always means another instance can immediately claim. Under the existing fail-closed lease contract, runtime failure can intentionally strand ownership for process lifetime, and there may be no pending public call through which to report `connectionOwnershipUnavailable`.

**Required remediation**

Preserve the existing fail-closed limitation explicitly. State that disconnected/shutdown cleanup makes a best exact-token release attempt, but reacquisition is guaranteed only after successful synchronization. Define whether release status becomes internally observable for evidence without expanding public API. Add injected-runtime tests for enter failure, exit failure before/after clearing, repeated release, stale release after a newer token, and attempted retry; assert that no wrong owner is removed and do not claim successful reuse when synchronization failed.

## Review Status

**Unresolved finding count: 6 — 3 High, 3 Medium. Correctness/testing approval is not granted.**

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- Cross-checked the planning artifacts against the current facade/state hubs, pairing model, process lease, session admission cancellation path, admitted-session relay, active-pump activation gate, and one-shot terminal observer.
