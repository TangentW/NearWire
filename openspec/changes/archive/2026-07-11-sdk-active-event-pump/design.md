## Context

The admitted SDK session already owns one mandatory-TLS `SecureByteChannel`, one permanent `SDKSessionTransportCore`, one continuous `WireFrameDecoder`, one negotiated V1 codec, one exact route, and one shared cancellation relay. It remains in `negotiatingPolicy`, rejects the Event lane before payload retention, and buffers only a bounded FIFO of policy Control messages until one pump attachment is created.

The `NearWire` instance already owns the bounded uplink queue and internal actor seams for route-aware candidate offering and incoming publication. Core already provides directional rate calculation, token buckets, wire Event records and batches, receiver-local TTL wrappers, and sequence counters/validators. The missing layer must compose these pieces without moving queue ownership out of `NearWire`, replacing the transport owner, or introducing public connection behavior.

The implementation must compile distributed source in Swift 5 language mode under Xcode 16 or later, remain compatible with iOS 16, add no third-party runtime dependency, and preserve the supported SwiftPM and CocoaPods API inventory.

## Goals / Non-Goals

**Goals:**

- Activate one attached admitted session through exact Viewer-requested/App-capped directional flow policy.
- Transfer App events from the existing queue with route affinity, TTL, sequence, wire-limit, and secure-mailbox guarantees.
- Validate, rate-limit, and publish Viewer events in exact route and sequence order.
- Preserve the permanent core, callback ingress, channel, decoder, codec, route, relay, and terminal authority.
- Keep all decoded work, timers, tasks, transport admission, and wakeups explicitly bounded and deterministic.
- Make an idle active connection event-driven rather than periodically polling the App queue.
- Return only closed, redacted internal errors and leave the queue intact when a candidate was not admitted by transport.

**Non-Goals:**

- No supported connect, disconnect, state-transition, effective-rate, or pump API.
- No process lease claim or release; the later public-connect owner supplies the already admitted attachment.
- No retry, reconnection, background/foreground observation, route replacement, persistence, Keychain access, UI, or performance collection.
- No remote delivery acknowledgement, replay, resend, or processing guarantee.
- No outbound Event batching in this change. A negotiated batching capability is honored for inbound batches; sending valid single Event frames remains protocol-compatible.
- No local Event-drop-summary emission. Negotiated inbound summaries are decoded as bounded diagnostics only.

## Decisions

### 1. One explicit internal pump consumes one attachment

`SDKActiveEventPump` will be an internal one-shot starter constructed from one `SDKSessionPumpAttachment`, one `NearWire` instance, validated active limits, and injected active-operation dependencies. Construction performs no Task, timer, queue mutation, callback registration, transport send, or publication.

`run()` installs a lock-protected cancellation gate with one reference-identity run token before entering task cancellation handling, asks the permanent core to claim runner ownership, and waits only through owner binding plus initial flow-policy activation. On activation it returns one `SDKActiveEventPumpHandle`; it does not remain pending for the connection lifetime. Pre-registration cancellation atomically causes a nonterminal core to store `cancelled` without installing a runner waiter or wake callback. A second run returns `alreadyStarted` and never replaces work.

Successful activation commit closes the run cancellation gate, invalidates the run token, clears the activation waiter, and only then resumes `run()`. The starter synchronously constructs the handle and transfers away its attachment ownership without another suspension. Cancellation-first returns no handle; activation-first makes every late run-task callback stale. A completed Task result owns the handle until observed or released, so an abandoned result still triggers handle deinitialization.

The returned handle owns the shared relay and provides explicit cancellation plus one separate redacted `SDKActiveEventPumpTermination` observer that may retain the core but never the handle or relay. Its `wait()` is one-shot: a second wait returns `terminationWaitAlreadyStarted`; per-call task cancellation returns `terminationWaitCancelled`, removes only that observer, and never terminates the session. Each wait uses a private lock-protected cancellation gate. Registration precedence is one-shot claim, pre-latched cancellation, stored terminal, then pending observation. After registration the core actor orders terminal and tokenized cancellation: terminal-first closes the gate and returns the stored code; cancellation-first removes the observer and returns only its local code. A terminal core stores its exact result for a later unused first wait. Handle deinitialization therefore requests cancellation once even when an unstructured Task awaits termination. Explicit cancellation, run-task cancellation before activation, final active-handle release, and terminal channel input converge on the core's exact-once cleanup.

Alternative considered: keep `run()` pending for the complete connection lifetime. A Task awaiting an instance method would retain the pump and relay, making final-handle deinitialization unable to cancel deterministically. A returned lifetime handle plus non-owning termination waiter makes ownership explicit while the permanent core remains sole session authority.

### 2. The permanent core changes phase; callbacks are never retargeted

Pump start adds `bindingActiveOwner`, `negotiatingPolicy`, and `active` states to the existing core. The secure channel's immutable handler continues to submit only to `SDKSessionChannelIngress`, which weakly schedules the same core. The same decoder consumes every byte from admission through active Event transfer.

After cross-limit validation and runner claim, the core synchronously starts the initial policy deadline and enters `bindingActiveOwner` before any actor suspension. Pump attachment already cancelled the attachment deadline; this new reference-tokenized deadline continuously covers both owner binding and initial policy negotiation until activation.

The core then calls a lock-linearized `pauseNonterminalDrain()` on the existing ingress. Ingress mode is exactly `running`, `nonterminalPaused`, or `stopped`, orthogonal to the existing `drainScheduled` latch. A scheduled callback that arrives after pause calls a pause-aware take operation: it may take a latched terminal/overflow, but otherwise atomically clears `drainScheduled` and reports parked without consuming retained items or calling `finishDrainTurn`. Nonterminal submissions while parked remain under the existing count/byte bounds and create no callback. Terminal input or overflow replaces pending nonterminal work and authorizes exactly one drain even while paused. `finishDrainTurn` may schedule a successor only for a latched terminal while paused, or for any pending work while running, so no pause path spins.

During binding the core consumes neither nonterminal ingress nor the policy FIFO. Wake installation claims the shared active-operation gate around the actual NearWire actor assignment and returns an initial owner-availability plus queue selection/deadline snapshot. Terminal-first installs nothing; owner-shutdown-first returns unavailable without installing; install-first completes before terminal can close the gate, after which exact-token removal cannot overtake installation. Only a live matching available result stores all dependencies and consumes the earlier policy FIFO. It then calls lock-linearized `resumeNonterminalDrain()`, which changes paused to running and authorizes exactly one callback when retained work exists. Terminal racing resume is handled by the same latch: terminal-first already has or schedules its bypass drain, and resume-first permits that one normal scheduled drain to observe the terminal. Stop wins over pause/resume and schedules nothing. No ingress resumes after a policy deadline or other terminal result.

Before active state, Event-lane preflight continues to reject before payload buffering. After a valid initial policy offer is processed and the exact acceptance bytes are synchronously admitted to the secure mailbox, the core changes the decoder admission phase to `active`. Raw input retained during binding is then decoded in order, so an offer followed by an Event in one chunk activates before that Event's lane preflight; an Event before the offer remains terminal.

The existing policy FIFO is consumed in order at pump start. The core has one irreversible policy-consumer ownership state: `unclaimed`, `attachmentPull`, or `activeRunner`. The first non-pre-cancelled attachment pull claims pull ownership even if it completes immediately or is later task-cancelled; sequential pulls may then continue, but an active runner can never claim that attachment. A successful runner claim excludes all later pulls. Runner claim fails with `policyConsumerClaimed` when pull ownership exists; a non-pre-cancelled pull after runner ownership returns the same code, while existing pre-cancelled-pull precedence remains `pullCancelled`. A pending pull is never stolen or cancelled by runner claim. An accepted-policy message received from the Viewer is invalid because the Viewer is the requester and the App is the responder.

### 3. Viewer requests policy; App computes and acknowledges the conservative result

Active transfer requires negotiated `bidirectional-events` and `flow-policy` capabilities. The first policy message must be `WireFlowPolicyOffer`. The App converts the offer and its local `NearWireConfiguration` maxima to `DirectionalEventRates`, computes the minimum independently for uplink and downlink, and admits one exact `WireFlowPolicyAccepted` response.

Zero pauses only the corresponding business-Event direction. Control processing, terminal handling, and policy changes continue. Positive rates use the existing monotonic `EventTokenBucket` and its bounded two-second burst capacity.

Later Viewer offers are supported as complete ordered policy transactions containing only validated effective values, receipt order, and an acceptance intent; encoded `Data` is not retained. Receipt of a dynamic offer immediately pauses selection of new outbound drains and incoming publications. If an old-policy drain or publication is suspended, both finish and consume tokens at their captured selection times before any transaction applies. The offer-receipt time is not the rate boundary.

At commit the core deterministically encodes the acceptance, samples one fresh policy-commit time from the bound session clock, and reconfigures copies of both buckets at that time. Every clock/arithmetic failure therefore occurs before peer-visible bytes. It then synchronously admits the acceptance and nonthrowingly installs the prepared bucket copies; that sampled instant is the local policy boundary immediately preceding mailbox admission, with no Event selection between. Mailbox failure terminates without changing either bucket. Multiple transactions apply in order, each with its own commit time and no Event selection between acceptance boundaries. Events decoded after an offer may enter the bounded incoming FIFO but cannot publish until the ordered transaction commits. Too many deferred transactions terminate safely.

Alternative considered: periodically sample Viewer configuration. The wire protocol already provides explicit offers, so push-based ordered changes are both cheaper and deterministic.

### 4. NearWire owns its queue and provides one tokenized outbound wake registration

The active core never takes the uplink queue out of the `NearWire` actor. The binding phase installs one internal wake registration identified by a reference token through the shared operation gate and receives one atomic initial owner-availability/fair-candidate/deadline snapshot. Shutdown-first returns `ownerUnavailable` without a registration. Work committed before registration appears in the snapshot; later work, including shutdown, signals the callback.

The callback targets a lock-protected `SDKOutboundSignalIngress`, not a new Task per notification. The ingress atomically transitions idle to scheduled before creating one weak-routed core Task; further signals set only one dirty bit. Completing a routing turn schedules at most one successor when dirty. A binding-tokenized signal that reaches the core before the assignment result merely latches outbound work; a live matching binding result immediately performs a level-triggered refresh when that bit is set. Stop makes late signals no-ops and releases its weak routing closure. `NearWire` invokes the signal after a successful buffered send/reply/platform-event mutation and after persisting shutdown owner-unavailable state.

Installing a second registration fails. Terminal cleanup stops signal ingress and removes only the matching token after the gate-ordered install outcome, so stale cleanup cannot remove a later session registration. The initial snapshot drives events buffered before registration. Every later schedule refresh and drain returns owner availability as level-triggered state; the callback is only a coalesced hint. Therefore an empty live owner is distinct from a shutdown owner even if the shutdown edge occurred before registration or coalesced with queue signals. No timer polls an empty queue, and a notification storm retains at most one routing Task plus one successor.

The ownership graph remains acyclic: the core may retain the `NearWire` instance while active; `NearWire` retains only a callback whose target is weak; external session handles retain the relay; the relay retains the core; and the core does not retain the relay.

### 5. One shared operation gate linearizes terminal state with cross-actor side effects

Pump start creates one reference-tokenized `SDKActiveOperationGate` shared by the permanent core and every session-owned NearWire dependency. The gate is lock protected and has only open or closed state. Core terminal transition closes it synchronously before invalidating Tasks, scheduling channel cancellation, unregistering wake callbacks, or releasing active data.

Wake installation, each due-expiration removal, each route-affinity removal, each accepted outbound candidate, and incoming publication claim the gate only around their small irreversible mutation. Expensive Event encoding and complete turns occur outside the gate. The Core queue active-offer seam plans selection without mutating fairness, then invokes one synchronous authorization/body closure around queue removal, fairness credit, live-ID/statistic updates, and—only for an accepted candidate—secure-mailbox admission. Scheduling observation services due expirations through the same per-item closure and a supplied quantum.

If terminal close wins first, those calls leave registration, mailbox, queue, telemetry, streams, and publication result unchanged. If an operation claim wins first, that small side effect is committed-before-terminal and may finish; a later stale actor result cannot undo it. Core result tokens still prevent ABA and post-terminal actor-state mutation but are not treated as side-effect cancellation.

Committed-before-terminal scope is deliberately split across actors. The gated NearWire transaction covers peer bytes, queue removal, local planned sequence progression in the returned prefix, fairness, live IDs, and telemetry. Only a still-live matching drain result installs that returned counter and consumes uplink tokens at its captured selection time. If terminal closes after an accepted prefix but before result delivery, terminal cleanup discards route-local bucket/counter state because that route can never send again, while the already committed mailbox/queue/telemetry prefix remains valid local acceptance. The gate therefore needs no shared growing ledger.

Live and test dependencies both receive this gate. Deterministic hooks surround claim and irreversible boundaries so tests can force both legal orderings without sleeps.

### 6. Wire encoding and synchronous transport admission occur inside the NearWire actor

A new internal drain operation accepts the exact route, session codec, current outbound sequence counter, a nonnegative maximum accepted-Event allowance captured from the refreshed uplink bucket, positive service/queue-accounted-byte turn bounds, the secure channel, the fixed Control reservation, and the shared operation gate. After entering the `NearWire` actor, it samples that instance's own injected origin clock exactly once for the turn. No core-supplied timestamp may drive origin-queue expiry or remaining-TTL encoding. For each fair queue candidate it:

1. removes a stale reply affinity before transport-byte accounting and without allocating a sequence;
2. copies the current sequence counter and allocates one candidate sequence;
3. constructs the exact App-to-Viewer `EventEnvelope` from the stable queued ID/draft/date/enqueue monotonic timestamp and active route;
4. computes positive remaining TTL at that actor-local origin-clock value;
5. encodes one V1 `WireEventPayload` in active phase;
6. synchronously asks the channel mailbox to own the bytes while preserving Control capacity; and
7. while holding one operation-gate claim, commits mailbox admission, queue removal, fairness, live-ID and telemetry changes, and returns the copied sequence in the committed prefix.

Encoding, limit, TTL arithmetic, or sequence failure leaves the candidate and counter unchanged and terminates the session with a closed local code. Mailbox backpressure leaves the candidate, TTL, queue ordinal, scheduler credit, and sequence unchanged. Route-affinity drops and queue expiration do not consume rate tokens or sequence values.

The operation commits no more live candidates than the captured allowance. Once the allowance is exhausted it may continue token-free expiry and route-drop maintenance within the service quantum, but offers no further live Event and reports eligible work remaining. It returns exact owner availability, accepted/rejected/not-attempted/routing-dropped/expired IDs, the planned counter for its committed accepted prefix, accepted encoded-byte totals, whether due maintenance remains, whether eligible work remains, the next origin-queue expiration deadline, and any transport block's candidate ID plus exact encoded byte requirement. Its positive service quantum counts every expiry, route drop, and candidate decision; its positive queue-offer byte limit counts only the existing deterministic queued-draft accounting. It creates no long-lived reservation outside the queue.

Alternative considered: dequeue into a pump-owned batch before sending. That violates the existing queue contract when mailbox admission rejects and would require a second reservation/rollback store.

### 7. Event sends reserve mailbox capacity for Control traffic and observe progress cheaply

`SecureByteChannel` gains a narrow internal synchronous admission form with nonnegative reserved pending-count and pending-byte values. Under the existing mailbox lock, an Event candidate is accepted only when the post-admission count and bytes plus the reservation fit the configured hard bounds. Ordinary Control admission uses zero reservation and retains existing behavior.

The same mailbox lock exposes a constant-size, non-retaining capacity snapshot containing accepting state, available count, available bytes, and a monotonic progress generation incremented when retained capacity is released or terminal cleanup closes admission. A cheap predicate reports whether a known encoded byte count could fit with the Control reservation; it is advisory and later admission still rechecks atomically.

The pump fixes the reservation at two sends and twice the maximum encoded Control-frame size. Active-limit validation requires the transport mailbox to fit the reservation plus one maximum Event send, and requires the transport single-send limit to fit the active Event frame. Reservation arithmetic is overflow checked.

This prevents a queue drain from consuming every mailbox slot or byte needed for a policy acceptance and a pong. A Control storm can still reach the global mailbox bound; that is a terminal transport failure rather than unbounded retention.

### 8. Outbound driving is tokenized, TTL-aware, bounded, and backpressure-aware

The core owns one uplink bucket, one outbound drain token, at most one drain Task, at most one one-shot decision-wakeup Task, and one coalesced work flag. A turn services at most 64 queue mutations/candidate decisions and 2 MiB of queue-accounted offered bytes by default, with hard maxima of 256 service units and 64 MiB. Each expiry, route drop, accepted candidate, or rejected candidate consumes one service unit; only offered live candidates consume the byte budget. Route drops and expiry consume neither transport rate nor sequence. The byte limit must fit the configured NearWire single queued Event.

Before launching a drain, the core samples its session-token selection time, refreshes a copy of the uplink bucket at that time, and captures its exact available-whole-token allowance. That time never enters queue TTL logic. The refreshed bucket copy and allowance remain constant-size drain context. The actor cannot accept more Events than the allowance. After a drain returns, a live matching token uses the proven `accepted <= allowance` invariant to perform a nonthrowing prevalidated consumption on the refreshed bucket copy, then atomically installs that bucket plus the returned planned sequence counter. A stale or terminal result installs neither route-local counter nor bucket state, even though a gate-committed mailbox/queue/telemetry prefix remains committed. If the result reports owner unavailable, a live core terminates with `ownerUnavailable` before scheduling work. If due maintenance remains, one immediate coalesced continuation is scheduled regardless of Event rate. Otherwise, if eligible work and whole tokens remain, one continuation turn is scheduled rather than recursively draining. The single decision wake targets the earlier of next-token availability and the next origin-queue TTL deadline. At zero rate it targets TTL only; this is one-shot expiration work, not polling.

Core exposes its existing prevalidated bucket subtraction as an internal SPI-only nonthrowing operation. It is valid only on the exact refreshed bucket copy, with a nonnegative accepted count no greater than the whole-token allowance returned by that same copy and with no intervening mutation. This adds no supported SDK surface; it removes any throwing arithmetic or rate decision after peer-visible acceptance.

Core queue scheduling observation uses the same positive service quantum and shared gate as drain work. It first reports level-triggered owner availability. For a live owner it performs at most that many due-expiration mutations, reports whether due work remains, and otherwise exposes the earliest remaining origin-local deadline from the queue's bounded deadline index. Each removal has its own gate claim; terminal-first leaves the item and its accounting unchanged. Observation changes neither live fairness credits nor live candidate selection and starts no timer itself.

If mailbox backpressure stopped the turn, the core stores only the blocked candidate identity, exact encoded byte requirement, reservation, and observed mailbox progress generation. New unrelated send completions first use the cheap capacity predicate and do not re-encode while required count/bytes still cannot fit. Immediately after a blocked result arrives, the core re-snapshots capacity; if a freeing completion raced ahead of the result and capacity now fits, exactly one retry is scheduled, eliminating the lost-wake window. A queue mutation first performs a cheap NearWire fair-candidate identity probe; only removal/replacement or a changed next selection invalidates blocked state and permits new encoding. Policy transaction, route change, terminal state, or channel generation invalidates it directly. Admission always rechecks atomically.

While transport-blocked, token availability is not a wake reason because tokens are already available for the blocked candidate; the one-shot outbound wake still targets its queue TTL deadline. Capacity progress is event-driven through send completion and the cheap predicate.

This design sends one Event frame per queue item. It preserves secure-mailbox FIFO, so allocated sequence order is wire-send order.

### 9. Incoming single Events and batches are validated atomically before retention

In active phase the same codec accepts Event, Event batch, bounded drop summary, flow-policy offer, ping, pong, safe error, and disconnect according to negotiated capabilities. One receive callback may complete at most 256 frames by default and 1,024 at the hard maximum; exceeding the per-callback work bound terminates instead of monopolizing the core actor.

For one Event or a complete batch, the core plans validation on a copy of the Viewer-to-App `WireSequenceValidator`. Every record must match the exact session epoch, Viewer source endpoint, App target endpoint, direction, and next sequence. Each record establishes a receiver-local deadline using one monotonic observation value for that decoded payload. Batch records and the planned sequence are committed only if the entire batch fits route, sequence, TTL, count, byte, and arithmetic bounds.

The active incoming bound accounts the combined FIFO plus separately retained in-flight publication by deterministic encoded record bytes. An item remains charged until publication commits or terminal cleanup releases it. Defaults are 1,024 events and 8 MiB; hard maxima are 10,000 events and 64 MiB. The byte bound must fit one negotiated maximum Event. Overflow is terminal and publishes none of the failing frame or batch. No Event is silently dropped to recover capacity. The decoder's bounded partial frame, callback ingress, and each public subscriber buffer remain outside this accounting under their own independent hard bounds and are listed in the retention audit.

Drop summaries are decoded and accumulated into saturating internal diagnostics; they do not create App events, acknowledgements, retry state, or sequence changes.

### 10. Incoming publication is FIFO, TTL-aware, and rate limited

The core owns one downlink bucket, one in-flight publication that remains charged to the combined bound, one one-shot decision-wakeup Task, and a bounded per-turn publication/expiry quantum of 32 by default and 256 at the hard maximum. The FIFO has an exact indexed min-heap containing at most one deadline node per queued item. Removing the FIFO head for in-flight publication removes its heap node immediately; the in-flight value retains its direct deadline for the actor-side recheck. Expiry or terminal cleanup removes the exact matching node without tombstones, and no stale-node or periodic-rebuild strategy is permitted. Heap node count therefore never exceeds FIFO count or the incoming Event limit, and every insert/removal costs bounded `O(log n)` work.

An expiry turn removes at most the remaining publication quantum of due queued items without consuming tokens, preserves the order of remaining live items, and saturating-adds internal expiry diagnostics. If more due items remain, it schedules one immediate coalesced continuation before considering token time. Live events remain in exact sequence order; a later live Event never publishes ahead of an earlier live Event.

When one token is available and no policy transaction is pending, the core retains the selected head as in-flight and records its selection time before scheduling exactly one gated `NearWire.publishIncoming` call. The live publication dependency rechecks the receiver-local deadline immediately before gate claim and event-hub publication. An item that expires while waiting on the NearWire actor publishes nothing, releases its charge, and consumes no token. Successful publication consumes one token against the old-policy bucket at that captured time and advances. A false result means the operation gate or owner prevented publication; a terminal gate result is ignored as already ordered, while a live unavailable owner terminates with `ownerUnavailable`. Slow public subscribers retain their existing independent bounded-stream overflow behavior.

The single downlink decision wake targets the earlier of next-token availability and the earliest queued receiver-local TTL deadline. At zero downlink rate it targets TTL only and schedules no token wake or polling. The wake is replaced or cancelled whenever FIFO deadlines, policy, terminal state, or token state change.

### 11. Active dependencies expose deterministic reentrancy seams

`SDKActiveEventPumpDependencies` supplies Sendable closures for the bound session clock, one-shot sleeping, gate-authorized wake install/removal, outbound schedule refresh/drain, incoming publication, and secure-mailbox capacity observation. Live construction binds them to the exact NearWire and channel operations described above. The bound session clock is the exact instance-local clock already used by that `NearWire` queue; separate arbitrary clock closures are not accepted. Test construction may insert lock-controlled barriers before operation-gate claim, candidate admission, publication, drain return, mailbox completion, and terminal close without changing production ordering or bypassing the shared gate.

These seams make terminal-before/after-commit, policy-during-drain/publication, completion-before-block-result, and stale-wake races deterministic. No conformance test relies on `Task.yield`, wall-clock sleep, live Bonjour, or probabilistic actor scheduling.

### 12. Active limits and work ownership are explicit

`SDKActiveEventPumpLimits` uses these defaults and hard maxima:

| Limit | Default | Hard maximum |
| --- | ---: | ---: |
| Initial policy timeout | 10 seconds | 120 seconds |
| Incoming retained events | 1,024 | 10,000 |
| Incoming retained encoded bytes | 8 MiB | 64 MiB |
| Completed frames per receive callback | 256 | 1,024 |
| Outbound queue service units per turn | 64 | 256 |
| Outbound queue-accounted bytes per turn | 2 MiB | 64 MiB |
| Incoming publications per turn | 32 | 256 |
| Deferred complete policy transactions | 32 | 128 |

All values are positive. Cross-limit validation occurs before wake registration or active mutation. The incoming byte limit fits one negotiated Event; the outbound queue-byte turn fits the configured NearWire single Event; the Control reservation and one maximum Event fit transport count/bytes; and maximum encoded Event and Control frames fit the transport single-send limit as applicable.

The core owns no recurring timer. It owns at most the policy deadline, one uplink decision wake, one downlink decision wake, one outbound drain, and one incoming publication Task. `SDKOutboundSignalIngress` owns at most one weak-routing Task plus one already-authorized dirty successor and creates no Task until its lock changes idle to scheduled. Owner binding may suspend one actor operation but creates no extra unbounded task family. Decision wakes cover token and TTL deadlines. All carry reference-identity tokens, capture the core weakly where appropriate, and are cancelled/released on terminal cleanup.

### 13. Closed error mapping and cleanup extend across active state

The existing internal `SDKSessionAdmissionError` remains the sole core terminal and active-observer error type and gains: `policyConsumerClaimed`, `terminationWaitAlreadyStarted`, `terminationWaitCancelled`, `policyNegotiationTimedOut`, `activeIngressOverflow`, `activeWorkLimitExceeded`, `routeMismatch`, `sequenceViolation`, `outboundEncodingFailed`, `ownerUnavailable`, and `clockFailed`. Existing `alreadyStarted`, `cancelled`, `transportFailed`, `protocolViolation`, `incompatiblePeer`, and handoff errors continue where applicable. Observer-local wait cancellation is returned to that call only and is never stored as core terminal state.

Descriptions and reflection remain code-only and omit route, IDs, pairing data, endpoint, policy values, queue content, event content, wire bytes, certificate data, underlying errors, and peer text.

Terminal cleanup first closes the shared operation gate synchronously. It then resumes admission/pull/activation/termination waiters at most once, cancels the channel at most once, unregisters the exact outbound wake, invalidates every drain/publication/deadline/wake token, clears active incoming and complete-policy FIFOs, releases charged in-flight envelopes and all active dependency closures, resets decoder state, and ignores late callbacks. The App uplink queue remains owned by `NearWire` and is not cleared when a session ends. An operation that claimed the gate before terminal is recorded as committed-before-terminal; an operation that loses the gate mutates nothing.

### 14. Public behavior remains deferred to later changes

The active pump does not call `updateSessionState`, claim the process lease, add supported connection methods, reconnect, observe App lifecycle, or expose effective rates. Tests construct admitted attachments and pumps through internal seams. `sdk-public-connect` will later claim the lease, perform admission, attach and run this pump, map internal errors, and publish safe public state.

## Risks / Trade-offs

- **A Viewer can outpace the negotiated downlink rate until the bounded FIFO fills.** → TCP receive remains continuous to avoid callback retargeting; exact count/byte bounds terminate the session instead of silently dropping.
- **Single-frame uplink does not exploit negotiated batching.** → It preserves queue atomicity and accepted-only sequence commitment; batching remains an optimization rather than a compatibility requirement.
- **Two reserved Control slots cannot absorb an unlimited Control storm.** → Control traffic is still globally bounded; exhaustion terminates rather than starving policy or retaining unbounded bytes.
- **The core retains the `NearWire` actor while active.** → The reverse wake edge is weak and tokenized, and terminal cleanup releases both the registration and actor reference.
- **Dynamic policy can arrive while Event work is suspended.** → The complete bidirectional transaction and response wait in one bounded FIFO until all old-policy selections commit.
- **No remote Event acknowledgement exists.** → Sequence and mailbox acceptance prove only local ordered transmission admission; documentation preserves non-delivery semantics.

## Migration Plan

1. Add and validate OpenSpec deltas before source changes.
2. Extend the secure mailbox with reserved-capacity admission and exhaustive lock/terminal tests.
3. Add internal NearWire wake and wire-drain seams with deterministic queue/sequence/backpressure tests.
4. Extend the permanent core and add the active pump operation, policy, inbound, outbound, timer, cancellation, and cleanup tests.
5. Add production-channel integration coverage without Bonjour dependence, run all distribution gates, review to zero findings, archive, and commit.

Rollback is one commit because the change adds no supported API or persistent state.

## Open Questions

None. Outbound batching, public effective-rate observability, local drop-summary emission, lease/state orchestration, reconnection, and App lifecycle integration remain explicitly assigned to later changes.
