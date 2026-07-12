# Pre-Implementation Correctness and Testing Review — Round 2

## Scope

Reviewed the revised `sdk-public-connect` proposal, design, capability deltas, and tasks without modifying planning or production source. The review re-traced the six Round 1 findings and then followed preflight precedence, generation-tagged cancellation targets, task-cancellation versus shutdown winners, off-actor identity staleness, admission phase suspension, admission-to-activation ownership, active terminal handoff, state commit order, fail-closed lease release, real-encoding limit evidence, deterministic hooks, and retention coverage against the current lower-layer contracts.

## Round 1 Remediation Verification

| Round 1 finding | Round 2 status | Evidence |
| --- | --- | --- |
| 1. Attempt-time deinitialization was unimplementable | Resolved | The design now states that a live `connect` Task retains the actor and assigns attempt cleanup to Task cancellation or shutdown; only an active owner after return is subject to facade deinitialization cleanup (`design.md:104-106`; `specs/sdk-async-facade/spec.md:5-7`; `tasks.md:23`). |
| 2. No deterministic orchestration boundary | Resolved | One immutable internal dependency value and named barriers now cover lease, identity, admission, phase, activation, transfer, actor commit, terminal delivery, and cleanup (`design.md:108-118`; `tasks.md:17,22`). The terminal-observation boundary still needs the refinement in Finding 2 below. |
| 3. Cancellation, phase, and activation had no complete winner protocol | Partially resolved | The revision adds a lock-linearized latch, exact target generations, replacement rules, transfer commit, stale-result disposal, and pre/post phase checks (`design.md:74-104,169-183`; `specs/sdk-public-connect/spec.md:91-131`). Findings 1 and 2 identify the remaining cross-owner gaps. |
| 4. Preflight precedence and state semantics were undefined | Resolved | Shutdown, pre-latched Task cancellation, same-instance state, pairing, limit/version validation, reservation, and lease claim now have one exact order; failures before discovery preserve the prior stable state and later failures disconnect (`design.md:45-57`; `specs/sdk-public-connect/spec.md:3-23`). The state requirement correctly distinguishes actor commits from latest-value stream delivery (`specs/sdk-public-connect/spec.md:112-121`; `specs/sdk-async-facade/spec.md:34-41`). |
| 5. Keychain duplicate/error tests collapsed distinct branches | Resolved | The design and tasks enumerate initial read, random, add, duplicate reread, missing, malformed, noncanonical, unexpected-type, and access failures with exact call counts and zero update/delete behavior (`design.md:146-163,226-233`; `tasks.md:12-13`). |
| 6. Lease reuse overclaimed release success | Resolved | Proposal, design, lease delta, public-connect delta, and tasks now consistently make reacquisition conditional on successful runtime synchronization and preserve process-lifetime fail-closed unavailability (`proposal.md:12`; `design.md:120-131`; `specs/sdk-process-connection-lease/spec.md:7-29`; `tasks.md:24,29`). |

## Findings

### 1. HIGH — The admission post-observer check cannot reliably observe an outer shutdown winner

**Evidence**

- The revised contract requires admission to check its own state and pre-latched Task cancellation before and after the async observer (`specs/sdk-session-admission/spec.md:5-9`; `specs/sdk-public-connect/spec.md:112-131`). It does not require admission to synchronously read the public attempt's lock-linearized cancellation latch or receive a token-current result from the observer.
- The outer callback only suppresses a stale public state publication (`design.md:171-173`). Returning `Void` from that stale callback does not tell admission that the outer token was detached and therefore cannot authorize channel construction.
- Cancellation of the current admission actor is asynchronous. The current admission cancellation handler schedules `Task { await self.cancel() }`, and `cancel()` itself is actor-isolated (`SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:63-91`). A public target closure must likewise cross the admission actor unless the new design adds a shared synchronous gate.

The unresolved ordering is:

1. admission suspends in the phase observer;
2. shutdown detaches the exact public slot and latches shutdown in the attempt operation;
3. the stale phase callback returns without publishing;
4. admission resumes before its asynchronously forwarded `cancel()` message runs;
5. both admission-local checks still pass, allowing core and channel construction after shutdown already won.

Named barriers can reproduce this ordering, but barriers alone do not close it.

**Impact**

The implementation can satisfy the stated double-check and still violate the stronger requirement that shutdown during phase delivery constructs no channel. State remains safely stale, but internal transport work may start after the authoritative public cancellation point, and lease cleanup is delayed by a core that should never have been created.

**Required remediation**

Make the post-observer authorization include the same synchronous, lock-linearized cancellation source used by the public attempt. Two implementable choices are:

- pass admission a content-free shared cancellation gate whose `isCancelled` check is synchronous and is performed immediately before core construction; or
- make the observer return/throw a closed authorization result and require admission to reject a stale token, while still retaining an independent admission-local cancellation check.

Specify that shutdown latching happens-before this check even if actor-target cancellation delivery is delayed. Add a deterministic test that holds admission cancellation delivery, lets the stale observer return, and proves zero core constructions, channels, transport starts, and attachment values.

### 2. HIGH — Terminal observation has no unique handoff owner or terminal-versus-transfer winner table

**Evidence**

- The connected owner is described as retaining the active handle, termination observer, and lease, while also starting a terminal-observation Task that retains the observer and cleanup capability (`design.md:120-129,175-183`). Shutdown or deinitialization is then described as transferring those same values to `SDKPublicConnectionCleanupOwner`.
- The current termination object permits exactly one `wait()` call and throws `terminationWaitAlreadyStarted` on a second call (`SDK/Sources/NearWire/Session/SDKActiveEventPump.swift:285-339`). Therefore cleanup cannot safely start a new wait after the connected owner's Task has claimed the observer.
- The revised artifacts do not select a public outcome when the core becomes terminal after activation returns a handle but before transfer commit, between transfer commit and actor owner commit, or between connected publication and termination-wait registration. Task 3.6 names “terminal activation” but does not state both winner outcomes or exact observer/wait/release counts (`tasks.md:22`).

**Impact**

One implementation may treat pre-commit terminal as a thrown connect failure while another may commit connected and return success before publishing disconnected. During shutdown or deinitialization, a literal implementation of the documented transfer can start the one-shot wait twice. Treating the second-wait error as terminal could release the lease while the core is still live; retaining it as an error could strand the lease indefinitely. The ambiguity also prevents a deterministic retention test from identifying which Task is supposed to keep the lease alive.

**Required remediation**

Define one terminal-observation ownership object before any wait starts. It should own the one-shot termination object, exact lease handle, one wait Task, and exact release-on-terminal gate. The connected owner may request cancellation and hold a reference to that observation owner, but shutdown/deinitialization must transfer or detach the already-running owner/Task rather than start a second wait.

Add a normative winner table for:

- terminal before active-handle transfer commit;
- transfer commit before terminal;
- shutdown after transfer but before actor commit;
- terminal after actor commit but before wait registration;
- shutdown/deinitialization while the wait is pending; and
- stale terminal delivery after a newer attempt token exists.

For every row, specify the `connect` result, actor state commits, handle cancellation count, termination `wait()` count, lease release count/timing, and whether a later claim is permitted. Add barriers immediately before and after termination-wait claim/registration, not only terminal delivery, and add weak-retention assertions for the connected owner, observation owner, wait Task, handle, termination object, and lease after both normal terminal and shutdown cleanup.

### 3. MEDIUM — A single maximum fixture does not prove the queue-to-wire expansion bound for every admitted draft

**Evidence**

- The design requires a worst-case calculation that proves every admitted queued draft fits the Event record and all downstream domains, but describes the calculation only as preserving the “exact queued content bytes” (`design.md:59-72`; `specs/sdk-public-connect/spec.md:25-39`).
- Queue accounting currently uses Foundation `JSONEncoder` over the complete tagged `EventDraft` representation (`SDK/Sources/NearWire/NearWire.swift:382-393`; `Core/Sources/NearWireCore/Event/JSONValue.swift:14-67`). Wire sizing uses a different deterministic JSON representation of `WireEventRecord` and adds route, timestamp, sequence, TTL, causality, and session fields (`Core/Sources/NearWireTransport/WireEventPayloads.swift:96-129`). A constant wrapper proof therefore needs an explicit conservative relationship between two different encodings, including string escaping and all valid JSON shapes.
- Task 2.4 requires one maximum admitted queued draft and one maximum incoming Event to traverse the real encoders (`tasks.md:10-11`). That is necessary boundary evidence, but one chosen draft does not establish that no other valid draft with the same queue-accounted size has a larger wire representation. Task 4.5 names a limit-domain proof without defining the required adversarial/property evidence (`tasks.md:32`).

**Impact**

A planner can pass the exact fixture while underestimating another valid content shape, such as heavily escaped text, Unicode, maximum-depth arrays/objects, maximum keys, or different optional Event fields. Such an Event is accepted offline and later fails production encoding or a downstream mailbox/turn bound, contradicting the “every maximum admitted queued draft” guarantee.

**Required remediation**

Document the exact conservative transformation from queue-accounted `EventDraft` bytes to maximum deterministic `WireEventRecord` bytes, including why every valid JSON value and optional field is covered. Validate it with the production encoders, not a parallel estimator. In addition to exact and one-over downstream fixtures, require adversarial or property-based coverage for every JSON value kind, escaping/control boundaries, Unicode, depth and collection maxima, numeric extrema, maximum route and keep-latest identifiers, optional causality fields, timestamps, sequence, TTL, and schema. The evidence must assert that actual encoded record/frame/mailbox/turn counts never exceed the planner's bound.

## Review Status

**Unresolved finding count: 3 — 2 High, 1 Medium. Correctness/testing approval is not granted.**

Five of the six Round 1 findings are fully resolved. Round 1 Finding 3 is materially improved but remains partially unresolved by Findings 1 and 2 above. Finding 3 is a new evidence-completeness issue discovered in this round.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- Static cross-check against the current `NearWire` queue accounting, `SDKSessionAdmission` cancellation path, admitted session/attachment ownership, active-pump transfer gate, one-shot termination observer, state hub semantics, and exact fail-closed process lease.
