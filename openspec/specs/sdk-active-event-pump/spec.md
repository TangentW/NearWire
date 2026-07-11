# sdk-active-event-pump Specification

## Purpose
TBD - created by archiving change sdk-active-event-pump. Update Purpose after archive.
## Requirements
### Requirement: Active Event pumping is one explicit internal operation

The SDK SHALL provide one internal active-event-pump starter constructed from exactly one `SDKSessionPumpAttachment`, one `NearWire` instance, immutable validated active limits, and fixed injected operation dependencies. Construction SHALL start no Task, timer, wake registration, queue drain, transport send, Event publication, process lease, state publication, persistence, Keychain access, lifecycle observation, or UI work.

One explicit `run()` SHALL start at most one activation attempt. Before core registration it SHALL install a private lock-protected cancellation gate and reference-identity token. Pre-latched task cancellation SHALL atomically terminate the attached core with `cancelled` without installing an activation waiter or wake callback. A second run on the same starter SHALL fail with `alreadyStarted` and SHALL NOT replace work. Initial-policy activation SHALL atomically close the run cancellation gate, invalidate its token, clear its activation waiter, and only then resume `run()`. The starter SHALL construct one redacted `SDKActiveEventPumpHandle` synchronously without suspension and transfer attachment ownership to it. Cancellation-first SHALL return no handle; activation-first SHALL make every later run-task cancellation callback stale.

The active handle SHALL retain the same shared cancellation relay and SHALL provide explicit cancellation plus one separate redacted termination observer that retains neither handle nor relay. Its `wait()` SHALL be one-shot. Registration precedence SHALL be: claim the one-shot observer, observe pre-latched per-call cancellation, return stored core terminal state, or install one pending observer. A second wait SHALL return `terminationWaitAlreadyStarted`; pre-latched or cancellation-first pending observation SHALL return `terminationWaitCancelled`, release only that observer, and SHALL NOT terminate the session. Stored-terminal-first SHALL close the observer cancellation gate and return that exact terminal code. A terminal core SHALL retain its exact result for a later unused first wait. Handle deinitialization SHALL request cancellation once even while an unstructured Task awaits that observer. The relay SHALL retain the same permanent `SDKSessionTransportCore`; the core SHALL NOT retain the relay. Pump activation SHALL NOT replace or retarget the secure channel, callback ingress, frame decoder, negotiated session codec, route, or terminal authority.

#### Scenario: Idle pump is constructed

- **WHEN** an active-pump value is initialized but not run
- **THEN** no queue, callback, Task, timer, transport, state, lease, persistence, or Event work begins

#### Scenario: Run is cancelled before registration

- **WHEN** task cancellation latches before the core claims the pump gate
- **THEN** run fails once with `cancelled`
- **AND** the attached session terminates without an activation waiter or outbound wake registration

#### Scenario: Existing permanent owner becomes active

- **WHEN** one attached admitted session successfully starts its pump
- **THEN** the original channel, ingress, decoder, codec, route, core, and cancellation relay remain the active owners
- **AND** no callback target changes

#### Scenario: Active handle is abandoned while termination is observed

- **WHEN** the active handle is released while another Task awaits its separate termination waiter
- **THEN** handle deinitialization requests core cancellation once
- **AND** the waiter completes without retaining the handle or relay

#### Scenario: Termination observation is cancelled

- **WHEN** the observer's first wait is task-cancelled while the active handle remains live
- **THEN** only that wait returns `terminationWaitCancelled`
- **AND** the session remains active until its handle or another terminal cause cancels it

#### Scenario: Activation races late run cancellation

- **WHEN** initial policy activation commits before the run-task cancellation callback claims its token
- **THEN** run returns exactly one active handle and the late callback is ignored
- **AND** no cancellation can overtake handle ownership transfer

#### Scenario: Terminal races observer cancellation

- **WHEN** a pending first termination wait races core terminal state with per-call cancellation
- **THEN** the core orders exactly one winner through the observer's private cancellation gate
- **AND** terminal-first returns the stored terminal code while cancellation-first returns only `terminationWaitCancelled`

### Requirement: Active owner binding closes wake-registration races

After runner claim and cross-limit validation, the permanent core SHALL synchronously start one reference-tokenized initial-policy deadline and enter `bindingActiveOwner` before any actor suspension. Pump attachment already cancelled the attachment deadline; this new deadline SHALL continuously cover owner binding plus initial policy negotiation until activation. Deadline-first SHALL terminate with `policyNegotiationTimedOut`; successful registration SHALL retain the same live deadline token; only activation or another terminal transition SHALL invalidate it, and stale deadline delivery SHALL do nothing.

Before starting the owner actor operation, the core SHALL atomically change the existing callback ingress from `running` to `nonterminalPaused` under its lock. A callback scheduled before pause but delivered afterward SHALL take a latched terminal/overflow if present; otherwise it SHALL clear the scheduled latch and report parked without consuming retained input or requesting a successor. Nonterminal submissions while parked SHALL remain under existing count/byte bounds and SHALL create no routing Task. Terminal input or overflow SHALL replace retained nonterminal work and authorize exactly one drain despite the pause. A drain-turn completion SHALL schedule a successor while paused only for a latched terminal, never merely for parked nonterminal work.

Wake installation SHALL claim the shared active-operation gate around the actual tokenized assignment inside the `NearWire` actor and SHALL atomically return an initial owner-availability/fair-candidate/deadline snapshot from that same actor turn. Owner-shutdown-first SHALL return `ownerUnavailable` without installation. Terminal-first SHALL install nothing. Install-first SHALL complete assignment and snapshot before terminal close can proceed. Only a live matching available result SHALL store the bound session clock and active dependencies and consume the earlier policy FIFO. It SHALL then atomically resume ingress from `nonterminalPaused` to `running`, authorizing exactly one drain when retained work exists. Terminal racing resume SHALL share the same scheduled latch and produce one terminal-capable drain; stop racing pause or resume SHALL suppress all successors. Cleanup SHALL remove only the exact installed token, and no ingress SHALL resume after deadline or terminal state.

#### Scenario: Queue mutation precedes wake installation

- **WHEN** App work commits before the active wake callback is assigned
- **THEN** the atomic installation result reports the resulting candidate/deadline state
- **AND** activation does not require a historical notification or periodic poll

#### Scenario: Terminal races wake installation

- **WHEN** terminal close races the NearWire actor operation that assigns the callback
- **THEN** either terminal-first installs nothing or install-first returns one exact token and initial snapshot
- **AND** cleanup cannot miss or remove a different registration

#### Scenario: Input arrives during binding

- **WHEN** policy and Event bytes arrive while owner binding is suspended
- **THEN** raw callback ingress retains their bounded byte order without decoding nonterminal input
- **AND** after successful binding, the existing decoder resumes that order under the correct policy phase

#### Scenario: Scheduled drain arrives after binding pause

- **WHEN** a nonterminal callback scheduled a drain before pause but that drain reaches the core after pause
- **THEN** it parks without consuming input, clears the unusable scheduled latch, and schedules no successor
- **AND** later terminal/overflow or successful resume can authorize exactly one drain

#### Scenario: Policy deadline fires during owner binding

- **WHEN** wake registration remains suspended until the initial-policy deadline wins
- **THEN** the core terminates once with `policyNegotiationTimedOut`, stops paused ingress, and installs no later binding result
- **AND** a late registration token is removed through the exact gate-ordered cleanup outcome

### Requirement: Viewer policy activates conservative directional rates

Active pumping SHALL require negotiated `bidirectional-events` and `flow-policy` capabilities. The first buffered or newly received policy message SHALL be one Viewer `flow.policy.offer`. The App SHALL convert the offer and `NearWireConfiguration` maxima to validated directional rates, compute each effective direction as the minimum of Viewer request and App maximum, and synchronously admit one exact `flow.policy.accepted` response before entering active phase. Missing capabilities, an accepted-policy message from Viewer, Event input before the initial offer, or invalid phase/order SHALL fail terminally.

Zero SHALL pause only the corresponding business-Event direction. Control traffic, policy changes, terminal handling, queue retention, and TTL processing SHALL continue. Positive effective rates SHALL use one monotonic token bucket per direction with the Core default bounded burst duration.

Later Viewer offers SHALL become complete ordered transactions containing both validated effective directions, receipt order, and an acceptance intent without retained encoded `Data` or a preselected rate boundary. Receipt SHALL pause selection of new outbound drains and incoming publications. Any old-policy drain or publication already in flight SHALL finish and consume its token at its captured selection time before the acceptance or either bucket changes. At commit the core SHALL deterministically encode the acceptance, sample one fresh policy-commit time from the exact bound session clock, and prepare nonthrowing replacement copies of both buckets before peer-visible mutation. Any encoding, clock, or arithmetic failure SHALL terminate before mailbox admission. The core SHALL then synchronously admit the acceptance and immediately install both prepared bucket copies without suspension or Event selection between those operations. The sampled commit time SHALL be the local policy boundary; mailbox failure SHALL leave both old buckets unchanged. Multiple transactions SHALL apply in offer order, each with a fresh commit time and no Event selection between acceptance boundaries. Events decoded after an offer MAY enter the bounded incoming FIFO but SHALL NOT publish before that transaction commits. Exceeding the complete-transaction bound SHALL fail terminally.

#### Scenario: Viewer requests above App maxima

- **WHEN** Viewer offers 1,000 uplink and 500 downlink events per second while App maxima are 100 and 50
- **THEN** App admits an acceptance containing 100 uplink and 50 downlink
- **AND** only those effective values configure the active buckets

#### Scenario: Direction is paused

- **WHEN** either side contributes zero for one direction
- **THEN** no business Event is sent or published in that direction
- **AND** Control processing and later policy offers remain live

#### Scenario: Initial offer and Event are coalesced

- **WHEN** a valid initial offer is followed by a valid Event in the same receive chunk
- **THEN** the acceptance bytes enter the secure mailbox before the Event is admitted to active buffering
- **AND** the Event is governed by the effective downlink policy

#### Scenario: Policy changes during Event work

- **WHEN** one or more Viewer offers arrive while a queue drain or incoming publication is suspended
- **THEN** selected Events consume only old-policy tokens at their captured times
- **AND** complete bidirectional acceptances and reconfigurations apply exactly once in offer order before any new Event selection

### Requirement: Uplink drain commits route, TTL, sequence, and queue removal only after transport admission

For each active turn, the SDK SHALL refresh a copy of the uplink token bucket at one captured core selection time and pass its exact available-whole-token count as a maximum accepted-Event allowance distinct from service and byte limits. It SHALL synchronously offer fair candidates from the existing NearWire-owned queue without moving queue ownership or creating an external reservation. A stale reply affinity SHALL be removed before transport-byte accounting and SHALL consume neither sequence nor rate token.

For each eligible candidate, the SDK SHALL plan on a copy of the App-to-Viewer sequence counter, construct an exact active-route `EventEnvelope` using the queued stable ID, draft, wall creation date, origin enqueue monotonic timestamp, App source, Viewer target, session epoch, App-to-Viewer direction, and planned sequence, establish positive remaining TTL using one origin-clock value sampled by the exact `NearWire` actor after actor entry, encode one active V1 Event frame under the negotiated codec/limits, and synchronously admit those bytes with the fixed Control reservation. A core-supplied or separately injected timestamp SHALL NOT drive origin-queue expiry or wire remaining TTL.

The core and every exact session-owned NearWire operation SHALL share one lock-protected active-operation gate. Core terminal transition SHALL close it synchronously. Wake registration, each expiration, each route drop, each accepted outbound candidate, and each incoming publication SHALL claim the gate separately around only its small irreversible mutation. For an accepted candidate, one claim SHALL cover mailbox admission plus queue removal, fairness, live-ID, telemetry, and returned planned-sequence-prefix commit. The drain SHALL accept no more Events than the captured whole-token allowance; after allowance exhaustion it MAY service token-free expiry/route drops within the quantum but SHALL offer no later live candidate. If terminal close wins first, those values SHALL remain unchanged. A candidate that claims first SHALL be committed-before-terminal even if its outer actor result later becomes stale. Only a live matching drain result SHALL nonthrowingly prevalidated-consume its accepted count from the exact refreshed bucket copy and atomically install that bucket plus the returned route-local sequence counter; terminal or stale delivery SHALL discard those route-local changes without undoing already committed mailbox, queue, or telemetry state.

Encoding, arithmetic, expiry, active-limit, or sequence failure SHALL retain the candidate and old counter and terminate with a closed local error. Mailbox backpressure SHALL retain the candidate, TTL, insertion ordinal, fairness credit, and old counter for a later attempt and SHALL increment only actual transport-rejection telemetry. Expiration and route drops SHALL not consume sequence or rate tokens.

The SDK SHALL send single Event frames in this change even when batching is negotiated. It SHALL NOT infer peer receipt, acknowledgement, processing, retry, or delivery from mailbox admission.

#### Scenario: Two Events are admitted

- **WHEN** two queue candidates encode and the secure mailbox accepts them in one turn
- **THEN** their wire sequences are contiguous in fair-selection and mailbox FIFO order
- **AND** both leave the queue and consume exactly two tokens

#### Scenario: One whole token bounds a larger turn

- **WHEN** one whole token is available while service, byte, mailbox, and queue limits could otherwise admit many Events
- **THEN** the drain admits at most one live Event and reports later eligible work
- **AND** route drops or expiries may still use remaining service units without consuming another token

#### Scenario: Mailbox rejects the next candidate

- **WHEN** one candidate is accepted and the next reaches reserved-capacity backpressure
- **THEN** only the accepted candidate's mailbox, queue, telemetry, and returned planned-sequence prefix commit
- **AND** the rejected candidate remains unchanged for a send-completion or policy wake

#### Scenario: Stale reply precedes a large valid Event

- **WHEN** a route-mismatched reply is selected before an eligible Event
- **THEN** the reply is routing-dropped without consuming sequence, token, or transport bytes
- **AND** the later Event may use the same turn's remaining capacity

#### Scenario: Event cannot encode for the active route

- **WHEN** a pending candidate cannot fit or encode under the negotiated Event limits
- **THEN** it remains in the NearWire queue with its original identity and TTL
- **AND** the session terminates without advancing the sequence or admitting later work

#### Scenario: Terminal races candidate commit

- **WHEN** terminal close and one encoded candidate race at the shared operation gate
- **THEN** either the complete mailbox-plus-queue-plus-returned-planned-prefix transaction commits before terminal or none of it occurs
- **AND** a stale drain-result token cannot create a third outcome

### Requirement: Uplink scheduling is event-driven and bounded

The active core SHALL install one tokenized internal outbound-work callback in the exact NearWire instance. Registration and every schedule-refresh/drain result SHALL distinguish level-triggered owner availability from an empty live queue. Shutdown-first SHALL return `ownerUnavailable` without callback assignment; assignment-first SHALL later signal after persistent shutdown state is stored. A successfully buffered send, reply, or platform event and owner shutdown SHALL signal that callback. The callback SHALL weakly target the core and coalesce work, and every generic signal SHALL be followed by a level-triggered availability read so coalescing cannot lose shutdown. Terminal cleanup SHALL remove only the matching registration token. Pump start SHALL drive work already buffered before registration.

The callback SHALL enter a lock-protected signal ingress that changes idle to scheduled before creating a weak-routing Task. Repeated signals SHALL set only one dirty bit, and completing a routing turn SHALL authorize at most one successor. A matching binding-token signal delivered before the owner-assignment result SHALL latch work without requiring bound dependencies; a later live binding result SHALL immediately perform one level-triggered refresh when that work bit remains set. Thus a signal storm SHALL retain at most one routing Task plus one already-authorized successor.

The core SHALL own at most one outbound drain Task, one drain token, one finite decision-wakeup Task, and one coalesced continuation turn. One turn SHALL service at most 64 queue mutations/candidate decisions and 2 MiB of queue-accounted offered draft bytes by default, with hard maxima of 256 service units and 64 MiB. Each expiry, route drop, accepted candidate, or rejected candidate SHALL consume one service unit; only an offered live candidate SHALL consume byte budget. The byte limit SHALL fit the configured NearWire single queued Event. If due maintenance remains, the core SHALL schedule one immediate coalesced continuation before token scheduling. Otherwise, if whole tokens and eligible work remain, it SHALL schedule one later turn rather than recurse.

The single outbound decision wake SHALL target the earlier of positive-rate token availability and the queue's next origin-local expiration deadline. At zero rate it SHALL target expiration only; an empty queue SHALL schedule no wake. Scheduling observation SHALL remove at most the same positive service quantum of due work, gate each expiry separately against terminal close, report whether due work remains, and otherwise expose the next deadline without consuming a business token or using recurring polling.

When reserved-capacity mailbox admission rejects a candidate, the result SHALL identify that candidate and exact encoded byte requirement without retaining encoded `Data` outside the queue. The core SHALL retain that constant-size block plus a mailbox progress generation. Send completion SHALL first use a constant-time capacity predicate and SHALL NOT re-encode while candidate bytes plus Control reservation cannot fit. Immediately after installing a blocked result, the core SHALL re-snapshot capacity; a freeing completion observed before result return SHALL cause exactly one retry rather than a lost wake. Queue mutation SHALL first use a cheap NearWire observation to test whether the same candidate remains the next fair selection; only a changed selection SHALL invalidate the block and permit new encoding. Policy, route, terminal, or channel generation SHALL invalidate it directly. Only one drain may be suspended; stale drain and wake tokens SHALL be ignored.

While transport-blocked, whole-token availability SHALL NOT schedule an immediate retry loop. The one outbound decision wake SHALL continue to target the blocked candidate's queue TTL deadline, while send-completion capacity progress remains event driven.

#### Scenario: Empty active queue remains idle

- **WHEN** the session is active, the queue is empty, and no policy changes
- **THEN** no recurring queue poll or token timer runs

#### Scenario: Owner shuts down while all Event work is idle

- **WHEN** the bound NearWire instance shuts down during policy negotiation or active zero/positive-rate idle
- **THEN** registration or the next coalesced level-triggered refresh terminates once with `ownerUnavailable`
- **AND** no policy timeout, empty-queue interpretation, or unrelated producer signal is required

#### Scenario: App sends after an idle period

- **WHEN** a public send buffers one Event after the active queue became idle
- **THEN** the tokenized callback schedules one bounded drain without waiting for periodic polling

#### Scenario: High-rate queue exceeds one turn

- **WHEN** whole tokens or due maintenance expose more queue work than the service-unit limit
- **THEN** one turn performs no more than its service-unit limit
- **AND** at most one continuation turn is scheduled

#### Scenario: Backpressure receives more producer signals

- **WHEN** mailbox backpressure blocks the head candidate and App code buffers more Events
- **THEN** repeated producer signals do not repeatedly offer the blocked candidate
- **AND** only capacity sufficient for its known encoded size permits one later retry

#### Scenario: Completion precedes blocked result

- **WHEN** capacity is released after candidate rejection but before the blocked drain result reaches the core
- **THEN** the post-result capacity snapshot schedules exactly one retry
- **AND** no polling or additional producer signal is required

#### Scenario: Uplink is paused past TTL

- **WHEN** rate is zero and the earliest queued Event reaches its origin-local deadline without other input
- **THEN** one expiry wake removes no more than one service quantum and schedules an immediate continuation while due work remains, otherwise only the next deadline
- **AND** no sequence or rate token is consumed

### Requirement: Downlink validates complete route and sequence before bounded retention

In active phase the permanent decoder SHALL admit Event-lane payload only when negotiated capabilities permit the exact type. It SHALL decode one Event or a batch, plus negotiated drop summaries, and SHALL continue to process valid flow-policy offers, ping, pong, safe error, and disconnect. Viewer policy acceptance, unknown/disallowed type, malformed payload, invalid lane, or phase violation SHALL terminate safely.

For one Event or an entire batch, the SDK SHALL use one monotonic receipt value and a copy of the Viewer-to-App sequence validator. Every record SHALL match the exact session epoch, Viewer source endpoint, App target endpoint, Viewer-to-App direction, and exact next sequence, and SHALL establish an overflow-safe receiver-local TTL deadline. A batch SHALL commit no sequence or retained Event unless every record validates and the entire batch fits the remaining incoming count and byte bounds.

The incoming bound SHALL account FIFO plus separately retained in-flight publication together by Event count and deterministic encoded record bytes. The selected item SHALL remain charged until publication commits or terminal cleanup releases it. Defaults SHALL be 1,024 Events and 8 MiB; hard maxima SHALL be 10,000 Events and 64 MiB. The byte limit SHALL fit one negotiated maximum Event. Overflow SHALL terminate with `activeIngressOverflow` and SHALL publish none of the failing frame or batch. The SDK SHALL NOT reorder or silently drop a live Event to recover capacity. Decoder partial bytes, callback ingress, and public subscriber buffers SHALL remain under their separate documented hard bounds.

One receive callback SHALL complete at most 256 frames by default and 1,024 at the hard maximum. Exceeding that work quantum SHALL terminate with `activeWorkLimitExceeded`. Inbound drop summaries SHALL update only saturating internal diagnostics and SHALL create no public Event, sequence change, acknowledgement, or retry state.

#### Scenario: Contiguous single Events arrive

- **WHEN** Viewer Events 0, 1, and 2 match the active route and limits
- **THEN** they enter the incoming FIFO once in sequence order with receiver-local deadlines

#### Scenario: Batch contains one invalid record

- **WHEN** any record in a batch has a gap, duplicate, wrong endpoint, direction, epoch, TTL, or bound
- **THEN** no record from that batch is retained or published
- **AND** the planned validator state does not partially commit

#### Scenario: Incoming FIFO cannot fit a batch

- **WHEN** a valid batch would exceed the remaining count or encoded-byte capacity
- **THEN** the session terminates with `activeIngressOverflow`
- **AND** no earlier Event is evicted to make room

#### Scenario: Negotiated drop summary arrives

- **WHEN** Viewer sends a valid drop summary under the required capabilities
- **THEN** its counters saturating-add to internal diagnostics
- **AND** App observers receive no synthetic Event or delivery claim

### Requirement: Downlink publication is ordered, TTL-aware, and rate limited

The active core SHALL own one downlink token bucket, one charged in-flight publication, one finite decision-wakeup Task, one bounded continuation turn, and an exact indexed min-heap covering the complete FIFO. The heap SHALL contain at most one node for each FIFO item. Selecting the FIFO head as in-flight SHALL remove its heap node immediately and retain the direct deadline in the charged in-flight value; expiry and terminal cleanup SHALL remove exact matching nodes. Tombstones, stale nodes, and periodic heap rebuilds SHALL NOT be used. Heap node count SHALL never exceed FIFO count or the validated incoming Event limit, and insertion/removal SHALL be bounded `O(log n)` work.

An expiry turn SHALL remove at most the remaining publication quantum of due queued Events without token consumption, preserve remaining live order, and saturating-add internal expiry diagnostics. If more due work remains, it SHALL schedule one immediate coalesced continuation before token scheduling. A later live Event SHALL not publish ahead of an earlier live Event.

When one whole token is available and no complete policy transaction is pending, the core SHALL retain the live FIFO head as in-flight, record its selection time, and schedule exactly one actor-isolated gated `NearWire.publishIncoming` call. The live dependency SHALL recheck receiver-local TTL immediately before gate claim and event-hub publication; an item expiring on the NearWire actor SHALL publish nothing, consume no token, and release its charge. The shared operation gate SHALL linearize event-hub publication against terminal close: publication-first is committed-before-terminal, while terminal-first publishes nothing. Successful live publication SHALL consume exactly one old-policy token at its captured selection time and permit later work. A live owner failure SHALL terminate with `ownerUnavailable`; a terminal gate loss SHALL make no second terminal claim. Public event-stream subscribers SHALL retain their existing independent bounded overflow semantics; one slow subscriber SHALL NOT block the active core or another subscriber.

Each continuation turn SHALL publish or expire at most 32 Events by default and 256 at the hard maximum. The single downlink decision wake SHALL target the earlier of positive-rate token availability and the earliest queued receiver-local deadline. At zero rate it SHALL target TTL only and schedule no token wake or polling. FIFO deadline, policy, terminal, and token changes SHALL replace or cancel the same reference-tokenized wake.

#### Scenario: Downlink rate queues Events

- **WHEN** valid Viewer Events arrive faster than the effective downlink rate
- **THEN** they wait in exact sequence order within count, byte, and TTL bounds
- **AND** publication never exceeds available whole tokens

#### Scenario: Event expires while waiting

- **WHEN** any queued Event reaches its receiver-local deadline before publication
- **THEN** it is removed without publication or token consumption
- **AND** remaining live publication order is unchanged

#### Scenario: Paused head expires without input

- **WHEN** downlink rate is zero and no later network or policy callback occurs before the earliest queued deadline
- **THEN** one TTL decision wake removes no more than one publication quantum, releases those combined count/byte charges, and schedules an immediate continuation while due work remains
- **AND** no recurring timer runs

#### Scenario: Terminal races publication

- **WHEN** terminal close and an in-flight NearWire publication race at the shared gate
- **THEN** publication either completes entirely before terminal or produces no stream output
- **AND** the Event remains charged until that ordering is resolved

#### Scenario: NearWire owner shuts down

- **WHEN** an in-flight or pending publication reaches a shutdown NearWire instance
- **THEN** the active session terminates with `ownerUnavailable`
- **AND** the pump does not claim that Event was delivered

### Requirement: Active limits, timers, cancellation, and errors fail closed

Validated active limits SHALL use defaults and hard maxima of: initial policy timeout 10/120 seconds, incoming retained Events including in-flight publication 1,024/10,000, incoming retained encoded bytes including in-flight publication 8 MiB/64 MiB, completed frames per receive callback 256/1,024, outbound queue service units per turn 64/256, outbound queue-accounted bytes per turn 2 MiB/64 MiB, incoming publications/expiries per turn 32/256, and deferred complete policy transactions 32/128.

Every value SHALL be positive and every addition/multiplication overflow checked. Before wake registration or active mutation, the incoming byte limit SHALL fit one negotiated maximum Event, the outbound queue-byte turn SHALL fit the configured NearWire single Event, the transport single-send limit SHALL fit the active maximum encoded Event and Control frames, and the transport pending count/bytes SHALL fit the fixed two-Control reservation plus one maximum Event send.

The core SHALL own at most one policy deadline, uplink token-or-TTL decision wake, downlink token-or-TTL decision wake, outbound drain, and incoming publication Task. The outbound signal ingress SHALL create no Task before its lock changes idle to scheduled and SHALL retain at most one weak-routing Task plus one already-authorized dirty successor. Owner binding MAY suspend one bounded actor operation but SHALL create no unbounded task family. Every core-owned Task SHALL carry a reference-identity token and SHALL be cancelled and released at terminal cleanup. Pump attachment SHALL already have cancelled the pump-attachment deadline. Successful runner claim SHALL start the initial-policy deadline before owner binding, and that same deadline SHALL remain live through binding and negotiation until activation cancels it.

Internal active dependencies SHALL expose the exact bound `NearWire` session clock, fixed live closures, and barrier-capable test seams for wake registration/assignment/removal, activation acceptance/gate-close/waiter-resume, drain actor entry and return, candidate/expiry/route-drop gate claim, mailbox admission/capacity/completion, publication entry/claim, observer cancellation, terminal close, and one-shot sleeping. Tests SHALL be able to order actor reentrancy and both operation-gate winners without wall-clock sleeps, live Bonjour, or probabilistic scheduling. Test seams SHALL NOT bypass production validation, clock identity, or the shared gate.

The existing closed internal session error SHALL add exact codes `policyConsumerClaimed`, `terminationWaitAlreadyStarted`, `terminationWaitCancelled`, `policyNegotiationTimedOut`, `activeIngressOverflow`, `activeWorkLimitExceeded`, `routeMismatch`, `sequenceViolation`, `outboundEncodingFailed`, `ownerUnavailable`, and `clockFailed`; existing applicable codes SHALL remain exact. Observer-local termination-wait cancellation SHALL NOT replace stored core terminal state. Error description, debug description, interpolation, and reflection SHALL derive only from the code and SHALL contain no route, endpoint, ID, rate, queue value, Event content, wire bytes, certificate data, underlying error, or peer text.

Terminal cleanup SHALL first synchronously close one shared active-operation gate. It SHALL then close the run cancellation token before waiter resumption, resume activation and termination waiters at most once, cancel the channel at most once, stop signal ingress, unregister only the exact NearWire wake token, invalidate and release every active Task/token, clear incoming/complete-policy/in-flight active work, exact deadline-index nodes, and combined accounting, release active dependency closures, and ignore late callbacks. It SHALL NOT clear the NearWire uplink queue or reset retained App Event TTL/identity. Wake assignment, every expiry, every route drop, every accepted candidate, and publication claimed before gate close SHALL be recorded as committed-before-terminal; operations losing the gate SHALL mutate nothing.

#### Scenario: Viewer never offers policy

- **WHEN** the initial policy deadline expires before a valid offer activates the session
- **THEN** the session fails once with `policyNegotiationTimedOut`
- **AND** all active-pump registration and retained work are released

#### Scenario: Cancellation races with drain and publication

- **WHEN** cancellation races with a suspended queue drain and an incoming publication
- **THEN** the shared gate gives each irreversible side effect an exact before-terminal or terminal-first outcome
- **AND** stale results cannot mutate core state, and channel cancellation occurs at most once

#### Scenario: Diagnostics render hostile context

- **WHEN** an active error originates from hostile peer text, route values, wire bytes, or an underlying system error
- **THEN** every diagnostic surface contains only the fixed local code and message

### Requirement: Active pumping does not start public connection or lifecycle features

The active pump SHALL NOT claim or release `ProcessConnectionLeaseRegistry`, publish supported `NearWireState`, add supported connect/disconnect/effective-rate API, perform discovery or hello admission, reconnect, replace a route, observe App lifecycle, persist data, access Keychain, collect performance, create UI, or create a second secure channel. It SHALL add no supported SDK type or signature and no package product, target, runtime dependency, pod subspec, entitlement, or privacy declaration.

The later public-connect owner SHALL claim the lease before admission, create and retain this internal pump after attachment, map its closed errors to supported errors, and publish safe state. The later lifecycle change SHALL own disconnect/reconnect/background behavior.

#### Scenario: Internal pump transfers Events

- **WHEN** repository-owned test or later orchestration code explicitly runs the active pump
- **THEN** only the admitted route's existing TLS session may transfer Events
- **AND** process lease and supported state remain unchanged

#### Scenario: Ordinary public queue use remains offline

- **WHEN** App code sends, replies, inspects diagnostics, subscribes, or clears without internal pump orchestration
- **THEN** those operations start no discovery, connection, pump, timer, lease, persistence, or lifecycle work
