# Pre-Implementation Architecture and API Review — Round 3

Re-read the complete current proposal, design, task plan, six capability deltas, all Round 2 review reports, and the Round 2 remediation note against the existing permanent session core, callback ingress, queue, transport, packaging, and public-boundary contracts. Round 2 remediation closes the previously reported dynamic-policy boundary, late run-cancellation, committed-prefix ownership, origin-clock identity, per-mutation terminal gating, and unbounded-expiration issues. Two binding-phase architecture gaps remain.

## Findings

### HIGH — Owner binding has no live deadline despite claiming to replace the attachment deadline

**Confidence:** 0.99

**Evidence**

- The canonical admission contract says pump attachment cancels and releases the pump-attachment deadline, and the current core does exactly that when `attachEventPump` succeeds (`openspec/specs/sdk-session-admission/spec.md:95-101,128`; `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:234-246`).
- The new starter is intentionally side-effect-free until `run()`, then runner claim enters `bindingActiveOwner` and suspends on NearWire wake registration (`design.md:34-38,44-50`; `specs/sdk-active-event-pump/spec.md:3-12,52-56`).
- The revised artifacts start the initial policy deadline only after a live matching binding result and describe that action as replacing the attachment deadline (`design.md:48`; `specs/sdk-active-event-pump/spec.md:56,271-277`; `specs/sdk-session-admission/spec.md:7`). At that point no attachment deadline exists to replace. This is a direct cross-spec contradiction, not merely missing implementation detail.
- Consequently, after a runner successfully claims irreversible policy ownership, a delayed or suspended wake-registration actor operation has no attachment or policy timeout. Task cancellation and terminal ingress can still end the session when their callbacks run, but neither establishes the promised bounded binding lifetime. This also leaves the Round 2 security requirement to keep a deadline bounded throughout binding unresolved (`reviews/pre-implementation-security-round-2.md:39-46`).
- Task 4.4 mentions deadline races generally but does not require a deadline that is actually active across runner claim and binding (`tasks.md:19-22`).

**Required remediation**

Choose and specify one continuous deadline ownership model. The simplest is to replace the attachment deadline with the initial policy deadline synchronously at successful runner claim, before any suspension on NearWire binding, and keep the same tokenized deadline live through binding and policy negotiation until activation. A separate bounded binding deadline is also viable, but it must have explicit stage replacement, cancellation, stale-token, and error-code semantics.

Update the canonical/delta wording so attachment cancellation, runner claim, binding, and policy negotiation describe one consistent transition. Add deterministic barriers for deadline-before-registration, registration-before-deadline, terminal versus deadline during binding, stale attachment-deadline delivery, and activation versus policy-deadline delivery. Assert one terminal result, exact wake-token cleanup, no ingress resume after timeout, and no live deadline Task after cleanup.

### HIGH — `bindingActiveOwner` cannot pause the existing ingress while preserving terminal preemption

**Confidence:** 0.99

**Evidence**

- The revised contract requires binding to retain nonterminal callback input in raw order without taking ingress batches, while a later channel terminal or ingress overflow must still preempt binding; a successful live bind must then resume the retained input (`design.md:44-50`; `specs/sdk-active-event-pump/spec.md:52-74`).
- The existing ingress sets `drainScheduled` before invoking the core callback. While that latch is true, later submissions—including the terminal item that replaces pending nonterminal work—do not authorize another callback. The latch is cleared only when `takeBatch` observes no work, or by `finishDrainTurn`, which immediately schedules another callback whenever pending work remains (`SDK/Sources/NearWire/Session/SDKSessionChannelIngress.swift:48-59,62-139`).
- The current core drain always takes a batch and then calls `finishDrainTurn` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:212-232`). During binding, taking the batch violates raw retention. Returning without taking leaves `drainScheduled` latched and can strand terminal, overflow, and post-bind retained work. Calling `finishDrainTurn` while deliberately retaining pending input immediately reschedules the same callback and can create an actor-task spin loop.
- A concrete failing ordering is: nonterminal bytes schedule a drain; the core enters binding before that drain executes; the drain parks without taking input; then terminal input replaces the pending bytes. Because `drainScheduled` remains true, no terminal-capable callback is scheduled. The suspended binding operation can therefore outlive the terminal signal, and a later successful bind can also miss the retained-input wake.
- Tasks 4.2 and 4.4 name pause and binding races but do not define or test the scheduler-latch transition that makes those requirements implementable (`tasks.md:19-22`).

**Required remediation**

Specify a pause-aware ingress state machine under the existing ingress lock, or an equivalent exact handshake. Entering binding must atomically park nonterminal draining without consuming input or retaining an unusable scheduled latch. Nonterminal submissions while parked must remain bounded and create no routing Task. Terminal or overflow latching must authorize exactly one terminal-capable drain even while nonterminal work is parked. A live successful bind must atomically unpark and authorize exactly one drain if retained work exists; terminal cleanup must suppress every successor. No path may use `finishDrainTurn` to self-reschedule retained paused work.

Add deterministic barriers for a callback scheduled before pause but delivered after pause; terminal and overflow after that callback parks; successful bind with retained policy/Event bytes; terminal racing unpark; stop racing pause/unpark; and repeated nonterminal submissions while parked. Assert raw order, exact retained accounting, one terminal result, no lost wake, no post-terminal callback, and constant routing-task bounds.

## Round 2 Findings Verified Closed

- Wake installation and every expiry, route-affinity drop, accepted candidate, and incoming publication now use explicit small shared-gate transactions with terminal-first no-mutation semantics.
- Dynamic policy now encodes and samples a fresh bound-clock commit time before preparing both bucket copies, then admits the acceptance and installs those copies without an intervening suspension or Event selection.
- Activation invalidates the run cancellation gate/token and clears its waiter before resumption, so activation-first makes every late cancellation callback stale and handle transfer has no suspension window.
- Gate-committed mailbox/queue/fairness/live-ID/telemetry state is separated consistently from route-local counter and token state installed only by a live matching result.
- Uplink queue expiry and remaining TTL use the exact NearWire instance clock after actor entry; core selection time is restricted to rate accounting.
- Uplink service work is quantum-bounded, due work has explicit immediate continuation, and the downlink deadline index is an exact one-node-per-FIFO-item indexed heap.
- The active starter, lifetime handle, termination observer, error type, products, package manifests, platform limits, and Swift language-mode boundaries introduce no unintended public API or package dependency.

## Review Status

Two unresolved actionable findings remain. Pre-implementation architecture/API review closure is not granted until the binding deadline and ingress pause/resume contracts are remediated and a fresh independent round reports zero unresolved findings.

## Validation

`DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive` passed with `Change 'sdk-active-event-pump' is valid` (exit 0).

`git diff --check -- openspec/changes/sdk-active-event-pump/reviews/pre-implementation-architecture-round-3.md` passed with no output (exit 0). The active OpenSpec change is untracked as a whole; this review modified no production or test source.
