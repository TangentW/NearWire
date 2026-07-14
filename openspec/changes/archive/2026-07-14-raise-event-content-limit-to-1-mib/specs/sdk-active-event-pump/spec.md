## MODIFIED Requirements

### Requirement: Uplink scheduling is event-driven and bounded

The active core SHALL install one tokenized internal outbound-work callback in the exact NearWire
instance. Registration and every schedule-refresh/drain result SHALL distinguish level-triggered
owner availability from an empty live queue. Shutdown-first SHALL return `ownerUnavailable`
without callback assignment; assignment-first SHALL later signal after persistent shutdown state
is stored. A successfully buffered send, reply, or platform event and owner shutdown SHALL signal
that callback. The callback SHALL weakly target the core and coalesce work, and every generic
signal SHALL be followed by a level-triggered availability read so coalescing cannot lose
shutdown. Terminal cleanup SHALL remove only the matching registration token. Pump start SHALL
drive work already buffered before registration.

The callback SHALL enter a lock-protected signal ingress that changes idle to scheduled before
creating a weak-routing Task. Repeated signals SHALL set only one dirty bit, and completing a
routing turn SHALL authorize at most one successor. A matching binding-token signal delivered
before the owner-assignment result SHALL latch work without requiring bound dependencies; a later
live binding result SHALL immediately perform one level-triggered refresh when that work bit
remains set. Thus a signal storm SHALL retain at most one routing Task plus one already-authorized
successor.

The core SHALL own at most one outbound drain Task, one drain token, one finite decision-wakeup
Task, and one coalesced continuation turn. One turn SHALL service at most 64 queue
mutations/candidate decisions and 4,259,840 bytes of queue-accounted offered draft bytes by
default, with hard maxima of 256 service units and 64 MiB. Each expiry, route drop, accepted
candidate, or rejected candidate SHALL consume one service unit; only an offered live candidate
SHALL consume byte budget. The byte limit SHALL fit the configured NearWire single queued Event.
If due maintenance remains, the core SHALL schedule one immediate coalesced continuation before
token scheduling. Otherwise, if whole tokens and eligible work remain, it SHALL schedule one
later turn rather than recurse.

The single outbound decision wake SHALL target the earlier of positive-rate token availability and
the queue's next origin-local expiration deadline. At zero rate it SHALL target expiration only; an
empty queue SHALL schedule no wake. Scheduling observation SHALL remove at most the same positive
service quantum of due work, gate each expiry separately against terminal close, report whether
due work remains, and otherwise expose the next deadline without consuming a business token or
using recurring polling.

When reserved-capacity mailbox admission rejects a candidate, the result SHALL identify that
candidate and exact encoded byte requirement without retaining encoded `Data` outside the queue.
The core SHALL retain that constant-size block plus a mailbox progress generation. Send completion
SHALL first use a constant-time capacity predicate and SHALL NOT re-encode while candidate bytes
plus Control reservation cannot fit. Immediately after installing a blocked result, the core SHALL
re-snapshot capacity; a freeing completion observed before result return SHALL cause exactly one
retry rather than a lost wake. Queue mutation SHALL first use a cheap NearWire observation to test
whether the same candidate remains the next fair selection; only a changed selection SHALL
invalidate the block and permit new encoding. Policy, route, terminal, or channel generation SHALL
invalidate it directly. Only one drain may be suspended; stale drain and wake tokens SHALL be
ignored.

While transport-blocked, whole-token availability SHALL NOT schedule an immediate retry loop. The
one outbound decision wake SHALL continue to target the blocked candidate's queue TTL deadline,
while send-completion capacity progress remains event driven.

#### Scenario: Empty active queue remains idle

- **WHEN** the session is active, the queue is empty, and no policy changes
- **THEN** no recurring queue poll or token timer runs

#### Scenario: Owner shuts down while all Event work is idle

- **WHEN** the bound NearWire instance shuts down during policy negotiation or active
  zero/positive-rate idle
- **THEN** registration or the next coalesced level-triggered refresh terminates once with
  `ownerUnavailable`
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

- **WHEN** capacity is released after candidate rejection but before the blocked drain result
  reaches the core
- **THEN** the post-result capacity snapshot schedules exactly one retry
- **AND** no polling or additional producer signal is required

#### Scenario: Uplink is paused past TTL

- **WHEN** rate is zero and the earliest queued Event reaches its origin-local deadline without
  other input
- **THEN** one expiry wake removes no more than one service quantum and schedules an immediate
  continuation while due work remains, otherwise only the next deadline
- **AND** no sequence or rate token is consumed

### Requirement: Active limits, timers, cancellation, and errors fail closed

Validated active limits SHALL use defaults and hard maxima of: initial policy timeout 10/120
seconds, incoming retained Events including in-flight publication 1,024/10,000, incoming retained
encoded bytes including in-flight publication 8 MiB/64 MiB, completed frames per receive callback
256/1,024, outbound queue service units per turn 64/256, outbound queue-accounted bytes per turn
4,259,840 bytes/64 MiB, incoming publications/expiries per turn 32/256, and deferred complete policy
transactions 32/128.

Every value SHALL be positive and every addition/multiplication overflow checked. Before wake
registration or active mutation, the incoming byte limit SHALL fit one negotiated maximum Event,
the outbound queue-byte turn SHALL fit the configured NearWire single Event, the transport
single-send limit SHALL fit the active maximum encoded Event and Control frames, and the transport
pending count/bytes SHALL fit the fixed two-Control reservation plus one maximum Event send.

The core SHALL own at most one policy deadline, uplink token-or-TTL decision wake, downlink
token-or-TTL decision wake, outbound drain, and incoming publication Task. The outbound signal
ingress SHALL create no Task before its lock changes idle to scheduled and SHALL retain at most one
weak-routing Task plus one already-authorized dirty successor. Owner binding MAY suspend one
bounded actor operation but SHALL create no unbounded task family. Every core-owned Task SHALL
carry a reference-identity token and SHALL be cancelled and released at terminal cleanup. Pump
attachment SHALL already have cancelled the pump-attachment deadline. Successful runner claim
SHALL start the initial-policy deadline before owner binding, and that same deadline SHALL remain
live through binding and negotiation until activation cancels it.

Internal active dependencies SHALL expose the exact bound `NearWire` session clock, fixed live
closures, and barrier-capable test seams for wake registration/assignment/removal, activation
acceptance/gate-close/waiter-resume, drain actor entry and return, candidate/expiry/route-drop gate
claim, mailbox admission/capacity/completion, publication entry/claim, observer cancellation,
terminal close, and one-shot sleeping. Tests SHALL be able to order actor reentrancy and both
operation-gate winners without wall-clock sleeps, live Bonjour, or probabilistic scheduling. Test
seams SHALL NOT bypass production validation, clock identity, or the shared gate.

The existing closed internal session error SHALL add exact codes `policyConsumerClaimed`,
`terminationWaitAlreadyStarted`, `terminationWaitCancelled`, `policyNegotiationTimedOut`,
`activeIngressOverflow`, `activeWorkLimitExceeded`, `routeMismatch`, `sequenceViolation`,
`outboundEncodingFailed`, `ownerUnavailable`, and `clockFailed`; existing applicable codes SHALL
remain exact. Observer-local termination-wait cancellation SHALL NOT replace stored core terminal
state. Error description, debug description, interpolation, and reflection SHALL derive only from
the code and SHALL contain no route, endpoint, ID, rate, queue value, Event content, wire bytes,
certificate data, underlying error, or peer text.

Terminal cleanup SHALL first synchronously close one shared active-operation gate. It SHALL then
close the run cancellation token before waiter resumption, resume activation and termination
waiters at most once, cancel the channel at most once, stop signal ingress, unregister only the
exact NearWire wake token, invalidate and release every active Task/token, clear
incoming/complete-policy/in-flight active work, exact deadline-index nodes, and combined
accounting, release active dependency closures, and ignore late callbacks. It SHALL NOT clear the
NearWire uplink queue or reset retained App Event TTL/identity. Wake assignment, every expiry,
every route drop, every accepted candidate, and publication claimed before gate close SHALL be
recorded as committed-before-terminal; operations losing the gate SHALL mutate nothing.

#### Scenario: Viewer never offers policy

- **WHEN** the initial policy deadline expires before a valid offer activates the session
- **THEN** the session fails once with `policyNegotiationTimedOut`
- **AND** all active-pump registration and retained work are released

#### Scenario: Cancellation races with drain and publication

- **WHEN** cancellation races with a suspended queue drain and an incoming publication
- **THEN** the shared gate gives each irreversible side effect an exact before-terminal or
  terminal-first outcome
- **AND** stale results cannot mutate core state, and channel cancellation occurs at most once

#### Scenario: Diagnostics render hostile context

- **WHEN** an active error originates from hostile peer text, route values, wire bytes, or an
  underlying system error
- **THEN** every diagnostic surface contains only the fixed local code and message
