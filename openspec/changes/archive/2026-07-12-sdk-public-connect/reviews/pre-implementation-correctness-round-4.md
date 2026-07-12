# Pre-Implementation Correctness and Testing Review — Round 4

## Scope

Reviewed the latest `sdk-public-connect` proposal, design, capability deltas, and task plan without modifying planning or production source. The review re-verified both Round 3 High findings and traced the shared session transition gate from the core's synchronous terminal mark through task cancellation, shutdown, active transfer, connected commit, waiter delivery, weak callback, and exact release. It also followed every no-lifetime failure through attempt cleanup and atomic coordinator handoff, then rechecked state/result order, weak-owner deinitialization, Keychain transcripts, constant-space limit evidence, and deterministic test hooks.

## Round 3 Remediation Verification

| Round 3 finding | Round 4 status | Evidence |
| --- | --- | --- |
| 1. Terminal, transfer, and actor commit lacked one shared linearization gate | Resolved | One `SDKSessionTransitionGate` is now part of the lifetime shared by the core, admitted session, attachment, active handle, post-admission attempt, coordinator, and actor commit. The core synchronously calls `markTerminal(code:)` at its exact first terminal transition before waiter resumption or async cleanup. `claimActiveTransfer()` and `claimConnectedCommit()` use the same lock, the connected claim occurs inside the no-suspension actor turn before owner/state mutation, and hooks run inside each critical section before mutation (`design.md:119-145`; `specs/sdk-session-admission/spec.md:9-31`; `specs/sdk-public-connect/spec.md:86-114`; `tasks.md:18,21,23`). This closes both prior check-then-commit windows and makes delayed waiter/callback scheduling irrelevant to the winner. |
| 2. No-lifetime failures lacked an explicit lease-release owner | Resolved for ownership and handoff | Before a lifetime returns, the attempt or its cleanup owner retains the lease through operation completion and explicitly invokes exact release once. Successful admission performs an acknowledged attempt-gate-to-session-gate handoff under a fixed attempt-then-session lock order, redirects later cancellation, and clears attempt ownership only after the coordinator owns the handle. Every named identity, discovery, phase, and admission failure is assigned no coordinator/wait and explicit branch coverage (`design.md:127-131,147-153`; `specs/sdk-process-connection-lease/spec.md:3-34`; `specs/sdk-public-connect/spec.md:149-166`; `tasks.md:18,21,23,26`). Finding 1 below concerns two remaining universal ordering sentences, not missing ownership. |

## Finding

### 1. MEDIUM — No-lifetime release ordering contradicts synchronous shutdown detachment and the terminal-only release sentence

**Evidence**

- Shutdown is required to synchronously detach the exact public attempt slot, publish final shutdown, and allow non-cancellable identity or pre-admission work to continue in a cleanup owner (`specs/sdk-async-facade/spec.md:3-27`).
- The revised no-lifetime rule requires stale identity completion after shutdown to remain owned until the worker finishes, then release. The same rule universally says release occurs “before clearing the attempt slot or completing the pending public call” (`design.md:147-149`; `specs/sdk-public-connect/spec.md:149-151`). On the shutdown ordering, the public slot was necessarily cleared before worker completion and release, so both requirements cannot be satisfied literally.
- Immediately afterward, the design and public-connect requirement still say, “Every path” invokes release after terminal state (`design.md:151-153`; `specs/sdk-public-connect/spec.md:153-155`). Identity failure, stale identity completion, discovery failure before core construction, and phase rejection before core construction intentionally have no lifetime, coordinator, wait, or session terminal (`specs/sdk-public-connect/spec.md:151,162-166`; `specs/sdk-process-connection-lease/spec.md:21-24`). Their required release occurs after operation completion, not after a nonexistent terminal state.
- Task 3.10 explicitly includes stale identity after shutdown and exact state order, so this is an observable evidence conflict rather than editorial wording with no test effect (`tasks.md:26`).

**Impact**

An implementation and its tests must choose which normative sentence to violate. Delaying public slot detachment until Keychain IPC returns breaks responsive, final shutdown. Detaching immediately breaks the “release before slot clearing” rule. Treating operation completion as an invented terminal blurs the new and intentionally separate pre-admission release regime and can accidentally create coordinator/wait expectations on branches that forbid them.

The ownership safety itself is now sound: the cleanup owner can retain the exact handle after public detachment and release once the operation finishes. The unresolved issue is the exact public-slot, pending-call, and release ordering that evidence must assert.

**Required remediation**

Split the no-lifetime rule by whether public ownership is still attached:

- For a token-current ordinary failure, complete the identity/admission operation, invoke exact release, then clear the exact slot, publish disconnected when discovery began, and complete `connect`.
- If shutdown already detached the public slot, the non-public attempt-cleanup owner completes the operation and invokes exact release without any later state/slot mutation; final shutdown remains immediate and the pending call returns shutdown according to the existing precedence rule.
- If Task cancellation detaches the slot before operation completion, define the same cleanup ordering and the exact point at which the pending call may return `connectionCancelled`.

Replace “Every path releases after terminal” with two explicit exhaustive regimes: no-lifetime branches release after operation completion, while lifetime branches release only through the coordinator after the sole wait observes the core's terminal mark. Preserve the existing fail-closed synchronization qualification for both regimes.

Update the branch tests to assert public slot/state timing separately from cleanup-owner/lease timing for ordinary failure, Task cancellation, and shutdown during identity, discovery, and phase authorization. Continue to assert one release invocation, zero coordinator/wait for no-lifetime branches, no stale newer-token mutation, and reacquisition only after successful release synchronization.

## Re-Traced Areas With No Additional Finding

- **Task, terminal, and shutdown precedence:** before transfer, Task cancellation and terminal use their order in the shared gate; successful transfer makes later Task cancellation stale; shutdown overrides both until connected claim; the no-suspension actor turn makes later shutdown a lifecycle event rather than a retroactive connect failure (`design.md:121-145`; `specs/sdk-public-connect/spec.md:108-114`).
- **One lifetime, wait, and release:** admission creates one termination value and transition gate; the coordinator starts one wait before attachment; duplicate waits are rejected and cannot trigger release; terminal-before-registration remains stored for the first waiter (`specs/sdk-session-admission/spec.md:9-31`; `specs/sdk-public-connect/spec.md:106-124`).
- **Weak owner and deinitialization:** active rates are captured by value, permanent core and live-operation closures have no strong path to NearWire, hidden-handle destruction requests cancellation, and the coordinator remains independent until terminal release (`specs/sdk-active-event-pump/spec.md:3-25`; `specs/sdk-public-connect/spec.md:126-134`; `tasks.md:22,24`).
- **Preflight and state/result order:** synchronous precedence and pre-discovery preservation remain exact; connected claim, owner installation, connected publication, and success return form one actor turn; stale callbacks cannot mutate a newer token.
- **Phase authorization:** the synchronous attempt gate and closed observer result still prevent channel construction when outer cancellation wins despite delayed admission-actor cancellation delivery.
- **Keychain:** exact modern dictionaries, bounded hit/miss/random/add/duplicate-reread transcripts, protected-item skip behavior, and zero update/delete operations remain fully enumerated (`design.md:86-103`; `tasks.md:12-13`).
- **Constant-space limits:** the fixed deterministic-content plus exact non-content formula, structural proof, production-encoder generated/adversarial properties, exact/one-over capacities, hostile inbound coverage, and peak-retention audit remain testable and unchanged (`design.md:35-54`; `tasks.md:10-11,34`).
- **Deterministic hooks:** critical-section hooks now cover lifetime handoff, terminal mark, active transfer, connected commit, wait registration, delayed delivery, and exact release without relying on sleeps (`design.md:69-84,145,171-178`; `tasks.md:17,23`).

## Review Status

**Unresolved finding count: 1 — 1 Medium. Correctness/testing approval is not granted.**

Both Round 3 High findings are resolved. The remaining finding is a narrower normative ordering conflict in the newly added no-lifetime cleanup regime.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- Static cross-check against the current facade actor and shutdown behavior, admission/core terminal path, cancellation relay, one-shot termination observer, active-operation gate, exact process lease, Keychain ordering, queue/content validation, wire Event encoding, state hubs, and active-pump owner references.
