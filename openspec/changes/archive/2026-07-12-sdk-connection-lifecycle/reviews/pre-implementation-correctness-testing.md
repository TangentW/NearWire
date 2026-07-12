# Pre-Implementation Correctness and Testing Review

## Scope

Reviewed the complete `sdk-connection-lifecycle` proposal, design, all five delta specifications, and task plan against the current public-connect actor slot, transition gate, terminal coordinator, process lease, and state hub. The review is limited to correctness and deterministic testability: lifecycle races, cancellation precedence, cleanup completion, retry budgets and delay, stale generations, and state/status coherence. No production or test source was modified.

## Findings

### 1. HIGH — The pairing-code ownership model cannot create the promised post-commit intent

**Evidence**

- The design says lifecycle intent exists only after explicit connect becomes active and is the only actor owner of the normalized code (`design.md:44-50,139-142`).
- The public-connect delta requires the public attempt to release its normalized code immediately after transfer into admission, but says the actor installs a separate intent copy only after connected commit (`specs/sdk-public-connect/spec.md:32-44`).
- The recovery design separately says the delay Task contains another copied normalized code (`design.md:127-131`), contradicting the “only inside actor intent” retention rule and the single-intent resource model (`specs/sdk-connection-lifecycle/spec.md:24-38,137-144`).
- In the current pipeline, `SDKPairingCodeTransfer.take()` moves the only normalized value into admission (`SDK/Sources/NearWire/NearWire.swift:300-320,682-699`). There is no later normalized value from which connected commit can create intent without retaining an undocumented attempt copy or reparsing the raw method argument.

**Required resolution**

Define one exact pending-intent candidate before the first suspension. It must have a stated owner, be separate from route/admission ownership, move atomically into lifecycle intent at connected commit, and be cleared on every pre-commit failure, Task cancellation, disconnect, suspension, shutdown, stale completion, and deinitialization. The recovery delay Task should carry only generation/attempt/clock data; it should fetch or receive the code only when a generation-current actor turn starts the next route, rather than retaining a second code through sleep.

**Required deterministic scenarios**

- Success transfers one candidate into one intent with no second surviving reference.
- Failure/cancellation at identity, discovery, admission result, activation result, transfer, and connected commit clears the candidate.
- Disconnect/shutdown during every suspension clears candidate and stale Tasks cannot recreate it.
- A cancelled recovery delay releases its Task without retaining the code; diagnostics and reflection remain redacted.

### 2. HIGH — Generation invalidation is conflated with the old route's required cleanup acknowledgement

**Evidence**

- Every callback is required to match the current lifecycle generation and route token before mutation (`design.md:70-81`).
- Disconnect first invalidates intent/generation and makes stale terminal callbacks unable to act, yet must wait for the old attempt's direct release or the old coordinator's post-release callback (`specs/sdk-connection-lifecycle/spec.md:40-59`; `specs/sdk-process-connection-lease/spec.md:3-22`).
- The current coordinator's only success notification occurs after release (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:181-200`), while the current actor callback discards delivery when the active token no longer occupies the slot (`SDK/Sources/NearWire/NearWire.swift:807-813`). A lifecycle implementation that detaches/increments generation first and then applies the same stale guard would strand disconnect/suspend waiters forever.

**Required resolution**

Specify two independent authorities:

1. a lifecycle generation that authorizes state, intent, status, and successor-route mutation; and
2. an exact route-cleanup receipt that may complete waiters for that old route after release even when its lifecycle generation is stale.

Register or obtain the cleanup receipt before invalidation/detachment. Delivery must always settle the matching old cleanup receipt exactly once, then separately gate state/recovery mutation by the current generation. While a receipt is unresolved, the controller must represent cleanup-in-flight so resume or a new explicit route cannot claim early.

**Required deterministic scenarios**

- Disconnect/suspend wins immediately before and after terminal mark, direct release, coordinator release, and callback enqueue.
- Generation changes before old delivery: old waiters finish, but intent/status/state and a newer route remain untouched.
- Old delivery occurs after a new route exists: it cannot release the new handle or clear its slot.
- Multiple waiters join one receipt and all finish exactly once after the same release invocation.

### 3. HIGH — Lifecycle command precedence and explicit-connect supersession are not defined

**Evidence**

- The design says a “superseding explicit connection” clears prior intent (`design.md:44-47`), but the public-connect preflight order checks only shutdown, Task cancellation, current attempt/active slot, input, configuration, and lease (`specs/sdk-public-connect/spec.md:3-9`). It does not say what `connect(code:)` does while a recovery delay, recovery attempt, retained suspended intent, or cleanup receipt exists.
- Resume may start when no route or recovery operation is current (`specs/sdk-connection-lifecycle/spec.md:61-80`), but suspension may already have detached the public slot while old cleanup is still running. Without an explicit cleanup-in-flight condition, resume can start a claim before the old lease boundary.
- Shutdown is declared highest priority, but disconnect versus suspension, disconnect versus resume, explicit connect versus resume/recovery, and caller Task cancellation versus lifecycle cancellation have no complete winner table (`design.md:64-81`; `tasks.md:14-17,22-29`).

**Required resolution**

Add a total actor-level precedence and transition table. At minimum, decide:

- whether explicit connect rejects or supersedes retained intent/recovery, and if superseding, how it cancels and awaits old cleanup before claim;
- whether explicit connect is allowed while suspended and whether it clears suspension;
- disconnect versus suspend/resume and resume versus a still-pending suspend cleanup;
- shutdown > disconnect > suspension > caller Task cancellation (or another explicit order), including the exact connect result and final status;
- which operations increment generation and which merely join current work.

**Required deterministic scenarios**

Barrier-test both actor orderings for every pair above at delay, discovery, admission, activation, transfer, connected commit, and cleanup delivery. Assert one route, one lease, one target cancellation, exact thrown result, final intent/suspension, and coherent state/status.

### 4. MEDIUM — Explicit-resume delay and attempt-budget semantics are incomplete

**Evidence**

- Every recovery attempt `n` is specified to wait the exponential delay (`specs/sdk-connection-lifecycle/spec.md:3-17`).
- Disabled policy has no usable bounded delay values but still permits one explicit resume attempt; a configured policy may continue after that attempt (`design.md:26-36`; `specs/sdk-connection-lifecycle/spec.md:63-80`). The artifacts do not say whether the explicit attempt is immediate, uses `initialDelay`, or consumes attempt 1 before subsequent automatic retries.
- The budget is said to apply “for one interruption,” but reset points after successful recovery and a later terminal, repeated resume calls, and resume after an automatic-recovery terminal are not fully stated.

**Required resolution**

Define one attempt-number algorithm for active-terminal recovery and explicit resume. State the delay before the explicit resume attempt under disabled and bounded policies, whether that attempt consumes the bounded budget, the numbering of any following delay, when the budget resets, and whether a transient terminal with automatic recovery disabled preserves intent for later manual resume. Define exactly when `reconnectAttempt` becomes 1 and when it returns to nil.

**Required deterministic scenarios**

- Disabled policy: one resume attempt, its exact delay (including immediate if selected), transient failure, no second attempt.
- Bounded policies with maximumAttempts 1, 2, and 20; exact sequence before cap, at cap, and after cap.
- Success resets the budget; a later interruption starts again at attempt 1.
- Repeated resume during delay/attempt does not consume budget or create another Task.
- Disconnect/suspend at delay deadline and attempt-start boundary prevents the next claim.

### 5. MEDIUM — Cleanup API completion, caller cancellation, and waiter bounds are not closed

**Evidence**

- `disconnect()` and `suspendConnection()` are nonthrowing async methods that promise to return after exact cleanup (`design.md:52-68`; `specs/sdk-connection-lifecycle/spec.md:40-65`). Caller Task cancellation is not assigned a result or waiter-removal rule.
- The current terminal coordinator intentionally vaults the lease and sends no actor delivery if its registered wait fails (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:181-210`). The lifecycle artifacts do not say whether an awaiting disconnect remains pending forever, returns after public detachment, or gains a failure surface in this fail-closed branch.
- The resource requirement promises a bounded list of cleanup waiters, but gives no bound, overflow behavior, or shared completion representation, while concurrent disconnect callers are unrestricted (`specs/sdk-connection-lifecycle/spec.md:40-59,137-144`; `tasks.md:14,16,29-30`).

**Required resolution**

Define whether caller cancellation is deliberately ignored until the cleanup boundary or removes only that caller while the lifecycle request continues. Define the public outcome for terminal-wait registration/execution failure; if safe cleanup cannot be proven, document deliberate noncompletion or change the API to expose failure rather than silently violating the boundary. Replace the unspecified bounded waiter list with one shared per-route cleanup completion primitive, or specify a real maximum and overflow result.

**Required deterministic scenarios**

- Cancel one of several disconnect/suspend caller Tasks before and after release; remaining callers and lifecycle intent behave exactly as specified.
- Inject terminal-wait registration and execution failure and prove the selected fail-closed API outcome without lease reacquisition.
- Stress repeated concurrent callers and prove one cancellation, one release invocation, one receipt, and bounded controller retention.
- Release-enter/exit runtime failure still settles callers only at the documented invocation boundary.

### 6. MEDIUM — The state/status table is not complete enough to prove coherence

**Evidence**

- The design says manual disconnect from any non-shutdown state publishes disconnected (`design.md:113-123`), while the normative disconnect requirement says idle and disconnected are no-ops (`specs/sdk-connection-lifecycle/spec.md:40-45`).
- Suspension must expose `isSuspended`, but behavior for suspension with no intent, explicit connect while suspended, and resume with no intent is not assigned a complete snapshot (`specs/sdk-connection-lifecycle/spec.md:61-80,98-119`).
- `lastError` and `reconnectAttempt` rules do not fully specify suspend during recovery, transient terminal with recovery disabled, caller-driven supersession, cancelled recovery, or cleanup-in-flight. Updating two hubs in one actor turn guarantees internal ordering, not atomic cross-stream observation, so the invariant to test must be current-value coherence rather than simultaneous delivery (`design.md:93-125`).

**Required resolution**

Add a canonical transition table containing prior lifecycle mode, winning operation/result, `NearWireState`, `lastError`, `reconnectAttempt`, `isSuspended`, intent presence, route/cleanup presence, and whether each hub publishes or suppresses a duplicate. Resolve the idle-disconnect contradiction and state explicitly that independently buffered state and status streams may coalesce differently while every published status satisfies `status.state ==` the actor's corresponding current state.

**Required deterministic scenarios**

- Idle/disconnected disconnect, suspend, resume, and explicit connect.
- Suspend during delay and active attempt; resume before and after cleanup completion.
- Disabled-recovery terminal, permanent failure, exhaustion, successful retry, manual supersession, and shutdown.
- Late subscribers and slow independent state/status subscribers, proving latest-value bounds, duplicate suppression, final shutdown delivery, and current snapshot coherence without promising cross-stream event pairing.

## Task-Plan Adequacy

Tasks 2.1-6.4 name the major implementation areas, but Tasks 3.1-3.4, 4.2, 5.1, and 5.2 cannot prove the current requirements until the ownership candidate, cleanup receipt, command precedence, resume budget, waiter completion, and canonical status table above are specified. After remediation, expand Task 5.1 into named winner rows and require the final requirement-to-test matrix to map each transition-table row rather than merely each top-level requirement.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: PASS — the change is structurally valid.
- `git diff --check -- openspec/changes/sdk-connection-lifecycle`: PASS.

These gates validate structure and formatting; they do not resolve the semantic ambiguities above.

## Verdict

**Unresolved actionable finding count: 6 — 3 High, 3 Medium. Pre-implementation correctness/testing approval is not granted.**

The lifecycle direction is viable, but implementation should not begin until the exact code owner, cleanup acknowledgement model, lifecycle command precedence, recovery budget, async waiter behavior, and state/status transition table are closed and deterministically testable.
