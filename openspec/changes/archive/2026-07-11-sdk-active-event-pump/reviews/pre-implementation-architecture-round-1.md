# Pre-Implementation Architecture/API Review — Round 1

## Scope

Reviewed the complete `sdk-active-event-pump` proposal, design, capability deltas, and task plan; the canonical queue, rate-control, wire-event, secure-channel, SDK admission, offline-buffer, async-facade, and public-boundary specifications; and the current `NearWire`, `SDKSessionTransportCore`, ingress, token-bucket, queue, sequence, wire-codec, and secure-mailbox implementations. The review focused on authority and lifetime, actor reentrancy, permanent transport continuity, queue and sequence commit atomicity, policy roles and ordering, terminal races, bounded scheduling, Swift 5 strict-concurrency compatibility, and supported API boundaries.

## Findings

### P1 — Terminal cleanup has no shared linearization point with NearWire-side queue commits or publication

**Severity:** P1 (event loss, post-terminal publication, and terminal-authority correctness)

**Evidence:**

- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:201-204` requires terminal cleanup to win once when cancellation races suspended drain/publication work and says stale results cannot commit sequence or resume work.
- `openspec/changes/sdk-active-event-pump/design.md:70-82` places synchronous mailbox admission, queue removal, telemetry mutation, and candidate-local sequence commitment inside the `NearWire` actor before the core receives the drain result. `design.md:98` lets the core reject the result only after the suspension returns.
- `openspec/changes/sdk-active-event-pump/design.md:114-118` likewise invokes `NearWire.publishIncoming` across an actor suspension and checks only its eventual result. A core-owned reference token cannot prevent the already-enqueued actor call from publishing.
- `SDK/Sources/NearWire/NearWire.swift:511-529` demonstrates the existing commit boundary: successful admission removes the queue item and changes telemetry synchronously inside `NearWire`. `NearWire.swift:437-468` publishes synchronously once the actor call executes.
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:641-676` currently records terminal state on the core actor and schedules channel cancellation asynchronously. Invalidating a core token cannot close the channel mailbox or stop a separately executing `NearWire` actor before that asynchronous cancellation runs.

**Impact:** If terminal cleanup runs while the drain is queued or executing, the drain can still admit bytes and irreversibly remove an App event after the core has invalidated its result token. The core then ignores the returned counter/result, so the queued event is lost from offline state without a terminal ordering that authorized the commit. Similarly, an already-enqueued publication can publish to App observers after terminal cleanup has declared itself the winner. Core-only stale-result checks do not satisfy the stated terminal invariant because the irreversible side effects occur before the result returns.

**Actionable remediation:**

1. Add one lock-protected, reference-tokenized active-operation gate shared by the core and the exact `NearWire` drain/publication calls. Core terminal cleanup must close that gate synchronously before scheduling channel cancellation or releasing active state.
2. For each outbound candidate, hold or atomically claim the gate across the final synchronous mailbox-admission plus queue/telemetry/sequence commit boundary. If terminal won first, do not admit bytes or mutate the queue. If the candidate won first, define it as committed before terminal and return that fact even if the outer drain result later becomes stale.
3. Check the same gate at the actual `NearWire` publication linearization point, immediately before `eventHub.publish`, so cancellation that wins first prevents publication rather than merely ignoring its return value.
4. Specify the two race outcomes explicitly and add deterministic barriers for terminal-before-commit, commit-before-terminal, terminal-before-publication, and publication-before-terminal. The tests must prove no event is removed/published in the terminal-first outcome and no committed result is ambiguously discarded in the operation-first outcome.

### P1 — Dynamic policy is not one atomic transition across suspended uplink and downlink work

**Severity:** P1 (wire ordering, rate-accounting, and actor-reentrancy correctness)

**Evidence:**

- `openspec/changes/sdk-active-event-pump/design.md:56` applies downlink reconfiguration immediately and defers only uplink reconfiguration while an outbound drain is suspended. `specs/sdk-active-event-pump/spec.md:34` has the same split and requires every offer to receive the exact newly effective acceptance.
- The outbound operation may not yet have executed when the core receives a later offer: `design.md:70-78` performs mailbox admission only after the cross-actor drain reaches `NearWire`, while `design.md:98` consumes old-policy tokens only after that drain returns.
- The plan does not say that the dynamic `flow.policy.accepted` response is deferred with the uplink change. If the core admits the acceptance while the older drain is suspended, mailbox FIFO can contain the policy acceptance before Event bytes that are subsequently admitted under the old policy.
- Downlink has the symmetric reentrancy gap. `design.md:114-116` selects an item and consumes its token only after `NearWire.publishIncoming` returns, but `design.md:56` allows a policy offer to reconfigure the downlink bucket while that actor call is suspended. The completed publication can therefore be charged to the new bucket despite being selected under the old one.
- `Core/Sources/NearWireFlowControl/EventRateControl.swift:102-145,178-196` makes observation time part of token-bucket correctness and rejects backward time. The design records deferred offer times but does not require accepted-event token accounting to use the drain/publication selection time. Sampling return time before applying an earlier recorded offer will deterministically produce a clock reversal; sampling the offer time against old work charges elapsed time to the wrong policy.

**Impact:** A Viewer can observe an accepted policy and then receive an Event admitted under the preceding policy, or an App publication selected under the preceding downlink policy can consume tokens from the new policy. A decrease to zero is the clearest failure: an old in-flight publication may fail token accounting after it has already been published. The unspecified accounting timestamp can also turn every offer-during-drain race into `clockFailed` under an otherwise monotonic clock.

**Actionable remediation:**

1. Treat each later offer as one ordered transition containing both directional rates, its monotonic observation, and its not-yet-admitted acceptance response. Do not admit that response or apply either direction while any operation selected under the old policy is suspended.
2. Capture the token-bucket accounting time in the outbound-drain and incoming-publication context. On return, commit successful old-policy token consumption at exactly that captured time, then apply queued offers at their recorded observations in wire order.
3. Admit each acceptance before starting any new-policy outbound drain. Keep later decoded Events in FIFO while an older publication settles; after the policy transition, publish them under the new downlink rate.
4. Bound the whole deferred transition FIFO, not only an uplink-rate fragment, and update the active-limit name/specification accordingly. Add deterministic tests with `selectionTime < offerTime < actorReturnTime`, including positive-to-zero and zero-to-positive changes, and assert exact mailbox ordering and no clock reversal.

### P1 — Paused downlink Events have no scheduled path to reach TTL expiration

**Severity:** P1 (TTL semantics and retained-work liveness)

**Evidence:**

- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:159-175` requires the FIFO head to be removed when its receiver-local deadline arrives, including when it expires before a token becomes available.
- `spec.md:163` says a zero rate schedules no token timer and retains Events only within count, byte, and TTL bounds. `design.md:118` says paused Events remain until a later policy change or TTL expiration.
- `design.md:114-118,136` and `spec.md:185-189` enumerate only a downlink token wake and an incoming-publication Task. They define no deadline wake for a paused FIFO head, and zero rate explicitly creates no token wake.
- `tasks.md:34-35` asks for a token wake and TTL tests but does not add a head-deadline scheduling owner or a zero-rate expiry-wake test.

**Impact:** With downlink rate zero and no later input or policy change, an expired head remains retained indefinitely. At a low positive rate, a head can also remain until the later token deadline instead of its earlier TTL deadline. The FIFO is count/byte bounded, but it is not TTL bounded as specified, and the “head expires while waiting” scenario has no event that drives it.

**Actionable remediation:**

1. Generalize the single downlink wake into a tokenized one-shot “next publication decision” wake scheduled for the earlier of the head TTL deadline and next-token availability.
2. At zero rate, schedule only the finite head-deadline wake; this is not polling and does not contradict the prohibition on a token timer or recurring timer.
3. Reschedule or cancel the same wake whenever the head, policy, terminal state, or token state changes, with one task/token maximum preserved.
4. Add deterministic tests proving expiration progresses with no network, producer, publication, or policy callback at zero rate and when TTL precedes a positive-rate token deadline.

### P1 — The pending `run()` lifetime conflicts with final-handle cancellation

**Severity:** P1 (session abandonment and ownership lifecycle)

**Evidence:**

- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:7-9` requires `run()` to remain pending until terminal state, requires the active pump to retain the shared cancellation relay, and also requires final-handle release to enter terminal cleanup.
- `openspec/changes/sdk-active-event-pump/design.md:34-38,66` repeats that lifetime and ownership graph.
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:8-31` shows that final-handle cancellation depends on `SDKSessionCancellationRelay.deinit`.
- A Swift unstructured Task is not cancelled when its Task handle is released. The normal orchestration shape `Task { try await pump.run() }` retains its captured pump until the pending call finishes; the pump retains the relay; and the relay therefore cannot deinitialize to cancel the operation it is waiting for. Relying on compiler shortening of `self` or closure capture lifetime is not a deterministic ownership contract, especially under the required Swift 5 mode.

**Impact:** Dropping the later public-connect owner, its Task handle, and its explicit pump property can leave the active task, pump, relay, core, channel, and NearWire actor live indefinitely. The claimed defensive final-handle path cannot be demonstrated for the most direct caller pattern.

**Actionable remediation:**

Choose and specify one implementable ownership model before apply:

1. Prefer a distinct explicit run/connection handle whose deinitializer requests relay cancellation and which is not retained by the waiter Task; make the indefinitely pending wait operation depend only on a cancellation gate/core terminal signal that does not retain that handle. The later orchestrator must retain and release this handle explicitly.
2. Alternatively, declare the running Task itself to be a live owner, require explicit Task cancellation, and remove the final-handle/deinitialization guarantee for an abandoned unstructured Task. This is weaker and should be reflected in the later public-connect contract.
3. Add a deterministic weak-reference lifetime test using the exact intended orchestration pattern: start, release every external owner without calling cancel, and prove relay deinitialization, one core cancellation request, waiter completion, and release of core/channel/NearWire ownership.

### P2 — Runner claim and attachment-pull behavior is contradictory and lacks exact error outcomes

**Severity:** P2 (internal API determinism)

**Evidence:**

- `openspec/changes/sdk-active-event-pump/specs/sdk-session-admission/spec.md:5` says runner claim will “reject or cancel any concurrent policy pull.”
- The normative scenario at `spec.md:15-19` instead says a pending pull makes runner start fail without stealing the waiter. Those alternatives produce different continuation and ownership outcomes.
- After a runner succeeds, `spec.md:7` prohibits attachment pulls from racing or retaining a continuation, but neither this delta nor the closed error list at `spec.md:23-27` identifies the exact result of a later `SDKSessionPumpAttachment.nextPolicyMessage()` call.
- The current attachment remains independently callable (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:73-94`), and current pull registration (`SDKSessionTransportCore.swift:249-305`) has no runner-claimed state or corresponding result. Apply therefore needs an unambiguous gate rather than an implementation-specific choice.

**Impact:** Two conforming implementations could either cancel the existing pull or reject the runner, and could return different errors or accidentally install a continuation for a post-claim pull. That undermines the promised exact-one policy consumer and makes deterministic race tests impossible to specify.

**Actionable remediation:**

1. Make the scenario's behavior normative: if a pull is pending, runner claim fails with one named existing or new exact code, and the pull remains unchanged. Remove the “or cancel” alternative.
2. Specify that, after a successful runner claim, every non-pre-cancelled attachment pull fails immediately with one exact code and never installs a gate/continuation; retain pre-cancelled-call precedence if that remains part of the attachment contract.
3. Add tests for pending-pull-versus-runner, post-claim pull, pre-cancelled post-claim pull, terminal-versus-runner, and second-run precedence.

## Positive Architecture Notes

- Queue ownership remains correctly assigned to the `NearWire` actor, and the proposed weak callback edge avoids a direct core-to-NearWire-to-core retain cycle.
- Permanent channel, ingress, decoder, codec, route, and callback ownership are consistently preserved across the proposal, design, and deltas.
- Reserved synchronous mailbox admission is a narrow Core transport extension and does not leak into the supported SDK API.
- The change remains scoped to internal SDK behavior, adds no supported connection API or third-party runtime dependency, and preserves SwiftPM/CocoaPods boundary intent.

## Review Result

Five actionable findings remain: four P1 and one P2. This planning round is not ready for implementation until the specifications, design, and tasks resolve them and a fresh architecture/API review reports zero unresolved findings.
