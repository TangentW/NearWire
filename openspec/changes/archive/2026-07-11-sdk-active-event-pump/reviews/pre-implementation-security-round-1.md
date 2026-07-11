# Pre-Implementation Security, Performance, Power, and Documentation Review — Round 1

## Findings

### HIGH — Core-side stale tokens cannot prevent irreversible NearWire side effects after terminal state

Evidence:

- `openspec/changes/sdk-active-event-pump/design.md:68-82,112-118,138-144`
- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:60-68,94-100,157-163,189-204`
- `SDK/Sources/NearWire/NearWire.swift:436-468,471-560`
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:641-676`
- `openspec/changes/sdk-active-event-pump/tasks.md:13-15,26-28,34-35`

The plan invalidates drain and publication tokens in the core and ignores stale results, but both planned operations cross to the independent `NearWire` actor before performing irreversible work. The existing publication seam immediately publishes to every event-stream hub, and the existing drain seam can admit bytes, remove queue entries, and update transport telemetry entirely inside the NearWire actor. Cancelling the task or rejecting its eventual result in the core cannot undo either side effect. Existing channel cancellation is itself scheduled asynchronously after core terminal state, so it is not a terminal linearization gate for a drain already executing on NearWire.

As written, terminal cleanup may win in the core while an already queued publication subsequently reaches subscribers, or while a drain subsequently admits bytes and removes an App event. This contradicts the planned cleanup claim and makes cancellation outcome depend on cross-actor scheduling rather than one explicit order.

Remediation:

- Add one lock-protected, reference-identity active-operation gate shared by the core and the exact NearWire drain/publication seams. Terminal transition must synchronously close it before any actor suspension or channel-cancellation task.
- Require every irreversible candidate commit and incoming publication to claim/check that gate immediately around its synchronous side effect. An operation linearized before close may complete as pre-terminal work; an operation after close must leave the queue, mailbox, telemetry, public streams, and publication result unchanged.
- Keep result tokens as ABA/stale-result protection, but do not treat them as side-effect cancellation.
- Add deterministic actor barriers for terminal-before-drain-commit, terminal-after-drain-commit, terminal-before-publication, terminal-after-publication, shutdown, and late callback cases. Assert exact queue IDs, mailbox bytes, stream output, telemetry, sequence/token accounting, and at-most-once channel cancellation.

### HIGH — A dynamic policy acceptance can overtake an old-policy drain and make later Events violate the accepted rate or pause

Evidence:

- `openspec/changes/sdk-active-event-pump/design.md:50-58,68-82,94-100`
- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:28-34,42-58,60-80`
- `openspec/changes/sdk-active-event-pump/tasks.md:19-22,26-28`
- `Core/Sources/NearWireTransport/SecureByteChannel.swift:302-379`

The design defers uplink bucket reconfiguration while a drain is suspended, but it does not explicitly defer the complete policy operation: both directional application and admission of the single `flow.policy.accepted` response. The old drain and the core can concurrently admit bytes through the same lock-linearized mailbox. If the acceptance wins that lock first and the old drain later admits Event bytes, the wire can contain an acceptance that lowers or pauses uplink followed by Events still charged under the old policy. Applying downlink immediately is also unsafe because increasing it before acceptance publishes faster than the previously accepted value, while lowering it creates semantics different from the single bidirectional acceptance.

Remediation:

- When any outbound drain is outstanding, retain the complete dynamic offer operation in the bounded FIFO: both directional effective rates, observation time, and pending acceptance intent. Do not apply either bucket and do not admit its acceptance yet.
- After the old drain result and old-policy token/sequence accounting commit, admit old Event bytes before the acceptance, then apply the full effective policy in offer order and only then permit another drain or later-policy Event work. Define exact failure behavior if acceptance admission backpressures or becomes terminal.
- Clarify how Events and additional offers later in the same receive chunk are governed while the policy operation is deferred.
- Add a mailbox-order test with a suspended drain and an offer that changes uplink to zero. Prove every old-policy Event precedes the acceptance bytes, no Event follows a zero acceptance until resume, both directions change at one defined commit point, and multiple offers preserve exact order.

### MEDIUM — Zero-rate downlink has no wake that enforces receiver-local TTL without later traffic

Evidence:

- `openspec/changes/sdk-active-event-pump/design.md:112-118,120-136`
- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:157-175,183-193`
- `openspec/changes/sdk-active-event-pump/tasks.md:32-35`
- `Core/Sources/NearWireTransport/WireEventPayloads.swift:275-289`
- `Core/Sources/NearWireFlowControl/EventRateControl.swift:148-176`

The plan promises that zero pauses publication, schedules no token timer, and retains Events only within TTL bounds. It also specifies only a token wake. If the head is queued while downlink is zero and no later Event or policy arrives, nothing re-enters the core when its receiver-local deadline passes. Expired hostile payloads can therefore remain retained indefinitely, up to the full configured count/byte limits, despite no longer being live.

Remediation:

- Make the single downlink wake represent the earliest reason to run: the minimum of next-token availability and the FIFO head's receiver-local deadline. At zero rate it must become a one-shot TTL wake, not a recurring poll.
- Reschedule only when the head, rate, or terminal token changes; use a reference token and the injected monotonic sleep, and release it at cleanup.
- Remove all contiguous expired heads in a bounded turn and saturating-account the expiry so this intentional loss is observable in internal diagnostics and documentation.
- Add no-further-input tests for zero rate, positive-rate token delay later than TTL, dynamic pause/resume, stale TTL wake, clock failure, and terminal cleanup. Prove memory is released at the deadline without periodic polling.

### MEDIUM — The incoming byte/count limit does not explicitly include the separately retained in-flight publication

Evidence:

- `openspec/changes/sdk-active-event-pump/design.md:102-118,122-136`
- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:124-130,157-163,183-193`
- `openspec/changes/sdk-active-event-pump/tasks.md:32-35,43`
- `SDK/Sources/NearWire/NearWire.swift:436-468`

The FIFO is count/byte accounted, but publication moves one item into a separately retained in-flight slot while awaiting the NearWire actor. The plan does not say that this item remains charged to the same counters. If dequeue releases its accounting before publication completes, another batch can fill the FIFO to its limit while one maximum Event remains in flight. The advertised retained maximum can then be exceeded by one Event and as much as one negotiated maximum Event's deterministic bytes; when the configured byte bound is only large enough for one maximum Event, this approaches a two-times accounting breach. NearWire actor contention can make that overlap long-lived.

Remediation:

- Define the active incoming count and byte limits as combined FIFO-plus-in-flight limits. Keep the selected head charged until publication succeeds or terminal cleanup releases it; batch admission must use the combined counters.
- State which transient decoded frame/batch and public subscriber buffers are outside this accounting, and include their independent hard bounds in the required retention audit and documentation.
- Add a deterministic blocked-publication test at exact count and byte boundaries, then receive another single Event and a batch. Prove total charged retention never exceeds either configured value and terminal cleanup returns both counters to zero.

### MEDIUM — Any send completion can trigger repeated maximum-Event encoding while mailbox capacity is still insufficient

Evidence:

- `openspec/changes/sdk-active-event-pump/design.md:86-100`
- `openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:76-80,94-122`
- `openspec/changes/sdk-active-event-pump/specs/secure-byte-channel/spec.md:3-45`
- `Core/Sources/NearWireTransport/SecureByteChannel.swift:4-8,241-265,302-379`
- `openspec/changes/sdk-active-event-pump/tasks.md:26-28`

The transport-block latch is cleared by the next send-completion callback, but that callback reports only a byte count and may represent a small Control frame. The planned drain must encode the blocked queue head before mailbox admission can reject it again. With a large Event and a mailbox that frees capacity gradually, a stream of small Control completions can therefore force repeated full Event-envelope construction and encoding even though the Event still cannot fit. This is bounded in retained memory but can amplify CPU, allocations, and phone power far beyond the peer's Control bytes.

Remediation:

- Return the blocked candidate's exact encoded byte count and required reserved count/bytes without retaining its Data outside the queue.
- Add a cheap synchronous mailbox-capacity predicate or one tokenized threshold notification. A send completion may coalesce a wake, but another expensive drain/encode must not start until count and byte capacity could admit that blocked size plus the Control reservation. Recheck atomically at admission because the predicate is not a reservation.
- Bound and invalidate the blocked-size state at policy, route, queue-head, terminal, and channel-generation changes.
- Add a test that fills the mailbox, blocks one maximum-size Event, completes many smaller Control sends, and proves encoding/admission is not retried until sufficient capacity exists. Include a sustained ping/pong plus blocked-uplink power test and exact cleanup assertions.

## Verified Strengths

- Event-lane admission remains capability and phase gated through the existing continuous decoder and negotiated codec. Batch, drop-summary, flow-policy, route, direction, epoch, and contiguous sequence checks are explicitly fail closed.
- Secure mailbox count, byte, single-send, FIFO, terminal, and reservation arithmetic are designed as lock-linearized hard bounds. The fixed Control reservation prevents Event traffic from consuming all planned policy/pong capacity; unlimited Control traffic terminates rather than growing memory without bound.
- Queue ownership, route-affinity removal, accepted-only sequence allocation, mailbox FIFO order, retry identity, and no remote-delivery inference are stated clearly. TLS is inherited from the admitted channel without a plaintext or replacement-channel path.
- Callback ingress, frame quantum, incoming FIFO, deferred policies, queue turns, publication turns, task inventory, one-shot wakes, and hard maxima are enumerated. Idle queue operation is event-driven and introduces no periodic polling.
- Closed active errors and every diagnostic surface exclude hostile route, policy, Event, wire, peer, certificate, endpoint, queue, and underlying-system text.
- The proposed internal operation adds no supported API, product, target, runtime dependency, CocoaPods subspec, entitlement, privacy declaration, process lease, public state mutation, reconnect, persistence, Keychain, lifecycle, UI, or performance collection.
- Tasks 7.1 through 7.7 require production TLS integration, SwiftPM/CocoaPods and API-boundary evidence, English security/non-delivery documentation, full validation, requirement-to-evidence mapping, retention/task/timer audits, independent post-implementation review, and archive discipline.

## Validation Performed

- `openspec validate sdk-active-event-pump --strict`: passed. Optional PostHog telemetry flush failed because network access was unavailable and did not affect validation.
- Static review of the complete proposal, design, task plan, five capability deltas, relevant canonical specifications, current secure mailbox, permanent session core and ingress, wire framing/message/event/sequence/rate primitives, bounded queue, NearWire queue/drain/publication seams, public stream hubs, diagnostics, package/CocoaPods boundaries, and existing cleanup ownership graph.
