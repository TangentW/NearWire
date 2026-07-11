# Pre-Implementation Architecture/API Review — Round 2

## Scope

Re-read the current proposal, complete design, all six capability deltas, task plan, all three Round 1 reviews, and `pre-implementation-remediation-round-1.md`. Re-checked the canonical queue, rate-control, wire-event, secure-channel, offline-buffer, session-admission, async-facade, and public-boundary contracts against the current `BoundedEventQueue`, `NearWire`, stream hubs, `SecureByteChannel`, session ingress, cancellation relay, pump attachment, and permanent transport core. This was a fresh review of the remediated plan, not a resolution inferred from the remediation summary.

## Round 1 Closure Audit

- **Closed:** the indefinitely pending pump lifetime was replaced with an activation starter, explicit lifetime handle, and termination observer that does not retain the handle or relay.
- **Closed:** attachment-pull versus runner ownership now has one irreversible consumer state and exact errors for completed, pending, pre-cancelled, and post-runner pulls.
- **Closed:** uplink and downlink now have one-shot token-or-TTL decision wakes, including zero-rate expiry behavior.
- **Closed:** combined incoming FIFO plus in-flight accounting, bounded outbound count/byte turns, deterministic test dependencies, and known-size mailbox capacity observation address the related Round 1 correctness/security findings.
- **Partially closed:** complete dynamic policy transactions now defer both directions and their acceptance, but their recorded observation time conflicts with the declared acceptance commit boundary.
- **Partially closed:** the shared operation gate covers accepted outbound candidates and incoming publication, but not startup callback binding, route-affinity removal, queue expiration, or core-owned accepted-prefix accounting.

## Findings

### P1 — Startup callback binding is not terminal-linearized and has no ingress-safe binding phase

**Severity:** P1 (callback lifetime, activation ordering, and continuous-decoder correctness)

**Evidence:**

- `design.md:60-66` installs the NearWire wake callback during pump start and relies on later exact-token removal. `design.md:68-74` limits the shared operation gate to the drain/publication dependencies; wake installation is not one of its claimed side effects.
- `design.md:167` and `specs/sdk-active-event-pump/spec.md:243` require terminal cleanup to unregister the exact wake, but neither defines an order when terminal cleanup runs while the cross-actor install call is queued or suspended.
- Swift actor jobs from separate tasks do not provide the plan with a FIFO contract. A removal sent by terminal cleanup can run before a previously issued install job, after which the stale install leaves a callback registered on NearWire. Its weak core target avoids a retain cycle but does not remove the token, and a later session can fail its “exactly one registration” rule.
- `design.md:34-48` moves directly from runner claim to policy negotiation and active decoding. It defines no intermediate binding state that prevents the permanent ingress from draining while cross-limit validation, dependency storage, operation-gate binding, and NearWire wake installation are incomplete.
- `specs/sdk-active-event-pump/spec.md:60-64` requires an initial offer followed by an Event in the same receive chunk to admit the acceptance and then retain the Event. If that chunk is decoded during a suspended wake install, the core must either activate against incomplete dependencies or keep the Event pre-active and reject it. The current ingress continuously schedules the same core and has no planned pause/resume ownership (`SDK/Sources/NearWire/Session/SDKSessionChannelIngress.swift:48-59,129-139`; `SDKSessionTransportCore.swift:212-231,346-387`).

**Impact:** Terminal-first startup can leave a stale callback installed after cleanup. Separately, valid coalesced initial policy/Event input can fail depending on actor scheduling, or activation can begin before its wake, limits, gate, and dependencies are fully bound. Both outcomes contradict the permanent-owner and deterministic activation claims.

**Actionable remediation:**

1. Add an explicit core `bindingActivePump` phase entered only after all cross-limit validation succeeds. During this phase, pause nonterminal ingress decoding while still allowing a latched transport terminal or ingress overflow to preempt startup.
2. Make wake installation an operation-gate-claimed synchronous NearWire side effect. If terminal close wins first, install nothing. If install wins first, complete actor-local assignment before releasing the gate; terminal can then close the gate and issue exact-token removal without removal-before-install inversion.
3. Record the registration token and all active dependencies before leaving the binding phase. Only then replace the attachment deadline, start the policy deadline, resume ingress, consume the buffered policy FIFO, and allow initial activation.
4. Add barrier tests for terminal-before-install, install-before-terminal, terminal while install return is delayed, raw ingress while binding, and buffered/coalesced initial offer plus Event. Prove no stale registration, busy rescheduling, callback gap, or premature Event preflight.

### P1 — Terminal-first drain semantics still permit ungated expiration and route-drop mutation

**Severity:** P1 (queue identity and telemetry after terminal authority wins)

**Evidence:**

- `design.md:70-72`, `design.md:78-90`, and `specs/sdk-active-event-pump/spec.md:78-80` place only mailbox-accepted candidate commit under the operation gate. Expiration and stale route-affinity removal are still described as ordinary drain effects outside that claim.
- `specs/sdk-offline-buffer/spec.md:7,23-31` and `specs/sdk-active-event-pump/spec.md:108-112,243-255` promise that terminal-first leaves queue identity, fairness credit, telemetry, and active-operation effects unchanged.
- The current queue implementation removes all due entries before invoking any candidate decision (`Core/Sources/NearWireFlowControl/BoundedEventQueue.swift:384-388`) and removes route-preflight entries before the admission decision (`BoundedEventQueue.swift:392-408`). The current NearWire drain updates route-drop identity and telemetry in that preflight (`SDK/Sources/NearWire/NearWire.swift:491-507`). A candidate-only gate cannot stop either mutation.
- `pre-implementation-remediation-round-1.md:7-10` claims the gate covers actual queue and telemetry boundaries, but the current normative artifacts do not extend it to these two queue mutations.

**Impact:** A drain that loses the terminal race can still remove expired events or route-affinity replies, advance fairness service, and change public expiration/route-drop telemetry after cleanup declared terminal-first. The plan therefore still permits a third outcome beyond its stated “complete operation-first” or “terminal-first no mutation” model.

**Actionable remediation:**

Choose one contract explicitly:

1. Prefer gate-linearizing every active-drain mutation, including due expiration and each route-affinity removal. Do not hold the gate across encoding; claim it only around bounded queue mutation units. Extend the queue seam if necessary so automatic pre-offer expiration cannot run before authorization.
2. Alternatively, classify expiration and route drops as intentionally session-independent maintenance allowed after terminal, and narrow every terminal-first/no-mutation requirement and test accordingly. This weakens the current exact cleanup claim and must state which route is allowed to discard replies after its session ended.
3. Add terminal barriers before expiration, between expiration and route preflight, before route removal, and between accepted-prefix candidates. Assert exact IDs, fairness credits, telemetry, mailbox bytes, and counter state.

### P1 — Dynamic policy records the offer time but declares the later acceptance time as the policy boundary

**Severity:** P1 (rate semantics and atomic policy acknowledgement)

**Evidence:**

- `design.md:56` and `specs/sdk-active-event-pump/spec.md:46` retain each offer's monotonic observation value, wait for old-policy work, synchronously admit the acceptance, declare the old policy effective until those bytes enter the mailbox, and only then reconfigure both buckets **at the earlier recorded observation value**.
- The canonical token-bucket contract refills under the old rate through the supplied reconfiguration instant and applies the new rate afterward (`openspec/specs/event-rate-control/spec.md:44-63`; `Core/Sources/NearWireFlowControl/EventRateControl.swift:128-145,178-196`).
- For `selection t0 < offer t1 < acceptance t2`, reconfiguring at `t1` means the new policy accrues or clears tokens during `t1...t2`, even though the active-pump specification says the old policy remains effective until `t2`. A rate increase can begin activation with tokens earned before acknowledgement; a decrease or pause discards old-rate accrual from an interval the plan calls old-policy time.
- The plan also admits acceptance before calling the fallible bucket reconfiguration. A clock/arithmetic failure can therefore put acceptance bytes in the mailbox and then terminate without installing the accepted policy, contrary to one atomic transition.

**Impact:** The wire-visible policy boundary and local rate-accounting boundary disagree. Delayed old-policy drains/publications and multiple queued offers can produce incorrect bursts or pauses immediately after each acceptance, and a local clock failure can acknowledge a policy that never becomes active.

**Actionable remediation:**

1. After all old-policy operations commit at their captured selection times, obtain a fresh policy-commit time immediately before acceptance admission.
2. On copies of both buckets, refill/reconfigure at that commit time so all failure occurs before bytes are admitted. Then synchronously admit the acceptance and commit the already validated bucket copies without a throwing step.
3. Apply each queued transaction at its own actual acceptance-admission time. Keep the original offer observation only for ordering or diagnostics, not as the effective bucket boundary, unless the specification instead intentionally changes to make receipt the boundary.
4. Add deterministic `t0 < offer < old-work-return < acceptance` tests for increase, decrease, pause, resume, multiple queued offers, mailbox failure, and clock failure. Assert token fractions/capacities immediately before and after every acceptance.

### P1 — Activation commit does not invalidate run cancellation before transferring the lifetime handle

**Severity:** P1 (single-owner handoff and late-cancellation correctness)

**Evidence:**

- `design.md:36-38` and `specs/sdk-active-event-pump/spec.md:7-9` define a cancellable activation wait followed by a returned handle, but they do not define one atomic winner when initial acceptance/active commit races the run Task's cancellation handler.
- The plan says run-task cancellation before activation terminates the attached core and handle deinitialization owns cancellation after activation, but it never requires activation to close the run gate and invalidate its core cancellation token before resuming the waiter or transferring the relay.
- The existing admission design already needed this exact boundary: successful acknowledgement invalidates its attempt-cancellation token before waiter resumption (`openspec/specs/sdk-session-admission/spec.md:29-31`). The active-pump delta has no equivalent requirement or race scenario.
- `tasks.md:19-22` requests run cancellation and ownership tests, but does not require the critical activation-wins/late-onCancel ordering.

**Impact:** Cancellation that was scheduled before, during, or just after activation can return a live handle and then cancel its session, or terminally cancel the core while the starter still returns a handle. The public-connect layer cannot tell whether handle ownership transferred, and the claimed separation between activation cancellation and handle cancellation is not deterministic.

**Actionable remediation:**

1. Make initial activation commit atomically close the run cancellation gate, invalidate the active-run token, transfer relay ownership to the new handle, and remove the activation waiter before resuming it.
2. Define exactly two outcomes: cancellation wins and no handle is created/returned, or activation wins and every later run-task cancellation callback is stale and cannot cancel the returned handle.
3. Ensure an activation result retained by a completed but abandoned Task still owns the handle so releasing the Task result triggers handle deinitialization cancellation.
4. Add barrier tests before acceptance admission, between acceptance and gate close, after gate close but before waiter resume, and after waiter resume but before caller observation.

### P2 — The open/closed operation gate cannot record core-owned sequence and token commits before a stale result is discarded

**Severity:** P2 (spec implementability and exact accounting evidence)

**Evidence:**

- `design.md:70` defines `SDKActiveOperationGate` as having only open or closed state. Accepted candidates advance a counter copy inside NearWire (`design.md:78-90`), while the core consumes accepted tokens and installs the returned counter only after the cross-actor result returns (`design.md:108`).
- `specs/sdk-active-event-pump/spec.md:78` nevertheless places sequence and token commitment in the pre-terminal candidate transaction. `spec.md:243-255` then says terminal cleanup releases active work and stale results cannot mutate core state.
- If a candidate wins the gate, removes its queue item, and admits bytes, but terminal closes before the outer drain result returns, the core cannot later install the returned counter or consume the token without violating stale-result/no-post-terminal-mutation. The gate contains no commit ledger from which terminal cleanup can observe the accepted prefix.
- The issue does not affect a later sequence on the already-terminal route, but it prevents literal satisfaction and evidence of the promised complete committed-before-terminal transaction.

**Impact:** Implementers must either mutate terminal core state from a stale result, silently omit required token/counter accounting, or add an unplanned shared ledger. Tests cannot prove the current stated transaction because its owners are split across actors and its result can be invalidated between those halves.

**Actionable remediation:**

1. Either extend the gate with a constant-size accepted-prefix ledger (accepted count and latest committed counter) updated under each candidate claim, and let terminal close return a snapshot that the core accounts before releasing the bucket/drain context;
2. Or narrow committed-before-terminal semantics to mailbox, queue, and telemetry only, explicitly allowing terminal cleanup to discard route-local counter/bucket state because no later Event can use it. Keep exact sequence/token installation mandatory only for a live drain result.
3. Add a barrier after the last candidate commit but before drain return and assert whichever accounting contract is selected.

### P2 — Uplink TTL evaluation is not structurally bound to the NearWire instance's enqueue clock

**Severity:** P2 (clock-domain and delayed-actor correctness)

**Evidence:**

- The canonical offline-buffer contract uses one instance-local injected monotonic clock (`openspec/specs/sdk-offline-buffer/spec.md:22-34`). Current enqueue timestamps come from `NearWire`'s private runtime dependency (`SDK/Sources/NearWire/NearWire.swift:302-324`).
- The canonical wire contract requires current time from that same clock when constructing remaining lifetime (`openspec/specs/wire-event-transfer/spec.md:20-32`).
- The remediated drain instead accepts an externally supplied “active time” (`design.md:78-83`; `specs/sdk-offline-buffer/spec.md:5`; `specs/sdk-active-event-pump/spec.md:76`). `SDKActiveEventPumpDependencies` has a separate monotonic closure (`design.md:136-140`) but the plan does not require identity with the bound NearWire instance's enqueue clock or require the drain to sample after it actually reaches the NearWire actor.
- A time captured before a delayed actor hop can precede the real encoding point; an event that expires while waiting can therefore encode with overstated positive remaining TTL. A different test clock domain can also cause false clock reversal or invalid lifetime.

**Impact:** Actor contention can transmit work that was already expired when encoding began, and custom/test wiring can violate the one-clock-domain invariant without any configuration validation capable of detecting it.

**Actionable remediation:**

1. Do not supply the origin-TTL observation from the core. The NearWire actor should sample its own instance-local monotonic dependency when the drain actually starts candidate evaluation and use that value for queue expiration and wire remaining lifetime.
2. Keep the core's captured selection time separate and use it only for token-bucket accounting/policy ordering.
3. If one shared injected clock object is desired, make that identity part of the live dependency construction rather than relying on two numerically compatible closures.
4. Add a barrier that delays NearWire entry past the queued event's deadline and prove it expires without encoding, mailbox admission, sequence allocation, or transport-rejection telemetry.

## Verified Architecture Areas

- The shared gate's proposed lock order is implementable for accepted candidate commits: gate then mailbox, with current mailbox completion/terminal callbacks releasing the mailbox lock before entering the core. No reverse mailbox-to-gate lock path is required. Publication similarly has no required reverse EventStreamHub-to-gate path, although its claim duration scales with bounded stream publication work.
- Permanent channel, ingress, decoder, codec, route, and core ownership remains intact; no callback retargeting or second transport is introduced.
- The activation starter, explicit handle, non-owning termination observer, and irreversible policy-consumer modes resolve the prior direct relay-retention and completed-pull ambiguity.
- All added APIs remain repository-internal or Core SPI. The plan adds no supported SDK signature, package product, target, pod subspec, runtime dependency, entitlement, privacy declaration, process lease, state publication, reconnection, lifecycle observer, persistence, Keychain, UI, or performance collection.
- The proposed dependency closures, tokens, gates, handles, and result models can be made `Sendable` in Swift 5 strict-concurrency mode with lock-backed `@unchecked Sendable` reference types and Sendable value results; no public Swift concurrency compatibility issue was found.

## Review Result

Six actionable findings remain: four P1 and two P2. Round 1 is not fully remediated, and source apply should remain blocked until the proposal/design/specs/tasks resolve these findings and a fresh architecture/API review reports zero unresolved findings.
