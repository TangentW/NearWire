## MODIFIED Requirements

### Requirement: Requested device preferences are bounded and safe

The Viewer global requested defaults SHALL be 4,096 App-to-Viewer and 10 Viewer-to-App Events per second. A new session SHALL resolve requested values from an in-memory session override, then the most recent preference for its Bundle ID, then global defaults. Changing a connected device SHALL update its session override and its Bundle-ID preference when a Bundle ID exists. Effective accepted policy SHALL NOT be persisted.

Viewer SHALL persist at most 256 versioned Bundle-ID policy records and 256 logical-route nicknames through an injected `UserDefaults` boundary. It SHALL deterministically evict least-recently-used records on overflow. Missing Bundle ID SHALL NOT inherit another Bundle-ID preference. Invalid identifiers, unknown versions, corrupt data, invalid/nonfinite rates, invalid timestamps, or invalid nicknames SHALL fall back safely without transport failure or raw stored-value presentation. Nicknames SHALL exclude control characters and contain no more than 80 Unicode scalar values.

The current preference schema SHALL be version 2. When loading schema version 1, Viewer SHALL migrate an exact global `20/10` pair to the new `4,096/10` default and preserve every other valid global pair as an explicit user customization. Valid Bundle-ID policies and route nicknames SHALL be preserved during migration. Unknown future versions and invalid records SHALL continue to fail closed to bounded defaults.

#### Scenario: Known Bundle ID reconnects

- **WHEN** an App with a stored valid Bundle-ID preference reconnects without a session override
- **THEN** the stored requested pair is used for its initial offer

#### Scenario: App has no Bundle ID

- **WHEN** an App Hello omits its application identifier
- **THEN** Viewer uses its route-specific session override or global defaults
- **AND** it does not read or write a fabricated Bundle-ID preference

#### Scenario: Preference storage is corrupt

- **WHEN** persisted preference data cannot be decoded or violates bounds
- **THEN** Viewer falls back to valid defaults and may repair the bounded store
- **AND** session admission remains available

#### Scenario: Legacy defaults migrate without overwriting custom policy

- **WHEN** Viewer loads a valid schema-version-1 store
- **THEN** an exact global `20/10` pair becomes `4,096/10`, while any other valid global pair is preserved
- **AND** valid Bundle-ID policies and route nicknames survive the schema-version-2 rewrite

### Requirement: Bidirectional Event transfer is bounded and protocol-correct

Each active session SHALL own one downlink-send queue and one uplink-delivery queue using the shared bounded queue implementation. The App-to-Viewer uplink-delivery queue SHALL permit at most 10,000 Events and 64 MiB of accounted data. The Viewer-to-App downlink-send queue SHALL permit at most 5,000 Events and 16 MiB of accounted data. Each queue's single-Event limit SHALL be no greater than the negotiated maximum. Viewer downlink SHALL support normal and caller-keyed keep-latest semantics. Incoming wire Events SHALL remain distinct because the wire schema carries no sender queue key.

Outbound Events SHALL receive route, session epoch, sequence, and wire encoding only for the exact active target connection. Inbound Events SHALL validate lane, source, target, session epoch, strict contiguous sequence, negotiated codec and schema, payload bounds, and receiver-local TTL before delivery. After every record in one frame is structurally/route valid and has a safe receiver-local deadline, Viewer SHALL atomically advance the expected sequence for the whole contiguous frame before local expiry and queue overflow. Thus an already-expired or locally dropped valid record consumes its wire sequence; invalid input advances none and closes only that session. Expired input SHALL not reach the sink. Local queue acceptance SHALL NOT claim remote delivery, processing, persistence, or acknowledgement.

Downlink preparation SHALL use tentative contiguous sequences. Exactly one encoded Event or batch frame SHALL enter the secure mailbox atomically. Success SHALL consume the whole frame's sequence range and commit exact queue removals, fairness, tokens, and telemetry. Failure SHALL commit none and retry SHALL use the same sequence and queue ownership. Earlier whole frames in one drain MAY remain committed when a later frame fails, but a frame SHALL have no partial admitted prefix. Keep-latest replacement, local expiry, route drop, and overflow before mailbox admission SHALL consume no downlink sequence. Terminal cleanup SHALL drop all connection-owned pending values rather than migrate them to a later correlation match.

#### Scenario: Viewer sends normal Events

- **WHEN** two valid normal Events are enqueued for one active App
- **THEN** both retain independent queue entries and are assigned contiguous wire sequences only when admitted for sending

#### Scenario: Viewer keeps only the latest value

- **WHEN** several pending downlink Events use the same valid keep-latest key
- **THEN** only the latest value remains pending at that logical insertion position
- **AND** coalescing telemetry identifies the replacements

#### Scenario: App Event has the wrong route

- **WHEN** an inbound Event has a mismatched source, target, epoch, or sequence
- **THEN** it is not delivered and that session closes
- **AND** other sessions remain active

#### Scenario: Uplink queue reaches a byte bound

- **WHEN** another App Event would exceed a session uplink-delivery queue's 64 MiB limit
- **THEN** existing priority-aware overflow policy restores the bound
- **AND** queue count and accounted bytes never exceed 10,000 Events or 64 MiB

#### Scenario: Downlink queue reaches a byte bound

- **WHEN** another Viewer Event would exceed a session downlink-send queue's 16 MiB limit
- **THEN** existing priority-aware overflow policy restores the bound
- **AND** queue count and accounted bytes never exceed 5,000 Events or 16 MiB

#### Scenario: Valid inbound Event expires locally

- **WHEN** the next route-valid wire Event is already expired on the receiver clock
- **THEN** Viewer advances the expected sequence and records local expiry without delivery
- **AND** the following contiguous Event remains valid

#### Scenario: Downlink mailbox rejects a frame

- **WHEN** an encoded batch cannot enter the secure mailbox atomically
- **THEN** no sequence, queue entry, fairness credit, or rate token is consumed
- **AND** retry emits the same contiguous sequence range exactly once

### Requirement: Session pumping preserves rate and Control progress

Viewer SHALL enforce effective uplink delivery and downlink send rates with independent shared token buckets using a 0.25-second bounded burst duration. The accepted App-uplink rate SHALL also be a cooperative sender contract enforced by a 0.25-second ingress token bucket. A business Event frame whose whole record count exceeds available ingress tokens, including any Event at zero rate, SHALL close with `activeWorkLimitExceeded` before that frame commits sequence or queue state. Downlink SHALL use 500 ms batching. Business Event mailbox admission SHALL reserve one bounded Control slot and bounded Control bytes through the secure-channel reservation seam. Control frames SHALL bypass business Event rates and queues but SHALL remain schema- and mailbox-bounded. The protocol-defined Event-lane drop summary SHALL also bypass business rate tokens and queues while remaining mailbox- and coalescing-bounded.

Active ingress SHALL separate hard retention/protocol bounds from scheduling quanta. Total connection-owned input SHALL include decoder partial/pending bytes plus the current synchronously delivered callback `Data` until its handler returns. While paused, no driver receive or second callback `Data` SHALL be active. The live total-input default SHALL be 2 MiB and the hard maximum 19 MiB. Before active mutation, overflow-safe configuration SHALL prove that this budget is at least one maximum legal encoded active frame plus twice the configured secure-channel receive-chunk size, remains within Core framing hard bounds, and is coherent with negotiated Event size. Exceeding the total budget, one legal frame/batch bound, the sender-contract bucket, or the system-message bucket SHALL close before the offending whole frame commits.

Service-turn defaults SHALL be 64 completed frames, 512 Event records, and 32 system messages, with hard configurable maxima of 256, 2,048, and 128. One maximum legal Event batch SHALL fit atomically within the configured record quantum. A separate system-message bucket SHALL allow 64 per second with a burst of 128. Uplink publication, expiry, and scheduled queue service SHALL process at most 128 records per turn, with a hard maximum of 512.

When valid coalesced input exceeds a service quantum, the same Core decoder SHALL pause before the next whole frame and retain only the bounded ordered frame/suffix. During that synchronous `.received` handler, the core SHALL claim exactly one generation-bound internal secure-channel receive-pause token. A claimed token SHALL prevent driver receive rearm. The core SHALL retain exactly that token and one continuation on its same executor while a complete unprocessed frame remains. Failure to claim SHALL close rather than accept unowned input. No later receive callback, callback-ingress `Data`, or byte SHALL exist or overtake while paused. Earlier whole frames MAY remain committed; the paused frame and suffix SHALL remain uncommitted and charged; one Event batch SHALL never split.

The bounded decoder SHALL return distinct paused-on-complete-frame, needs-more-bytes, and drained progress. Only paused-on-complete-frame SHALL retain the token and another continuation. In the ordinary path with no recorded policy timeout, needs-more-bytes SHALL preserve and charge the partial frame, discard its old sample for completion decisions, and resume one receive; the later callback that completes it supplies the frame sample. Ordinary drained input SHALL also resume. The recorded-policy-timeout rule is the explicit exception: partial-only or drained input without acceptance SHALL close and SHALL NOT resume. Before any permitted resume, the core SHALL atomically clear continuation state and detach the token so an immediate callback cannot observe/reuse it and may claim only one fresh token. If resume wins before terminal, at most one new generation-matched receive starts and terminal cancels it. Terminal-first SHALL make resume a no-op.

Terminal, decoder failure, attachment rollback, channel cancellation, or shutdown SHALL invalidate the continuation, release decoder bytes, and resolve the token exactly once without rearming. Resume from a stale channel generation SHALL do nothing. Consumers that never claim a token SHALL preserve the existing eager receive loop.

Each receive callback SHALL capture one injected monotonic receipt sample. A frame SHALL use the sample of the callback whose bytes complete it. A frame completed in a retained suffix SHALL preserve that original sample across continuation turns; a frame fragmented across callbacks SHALL use the later completing callback's sample. That one frame sample SHALL govern sender/system token charging, receiver-local TTL origin, policy-deadline arbitration, throughput, and every other receive-time decision. Continuation scheduling delay SHALL NOT change it. Split and coalesced delivery SHALL produce identical protocol, sequence, queue, token, timeout, and terminal outcomes when the same completed frames receive the same samples. Later split-callback samples MAY produce only the corresponding defined later time-based outcome.

Session work SHALL be event-driven. A session MAY schedule one replaceable one-shot wake for the earliest token, batch, policy, TTL, or cleanup deadline. Receive/service work SHALL retain at most one scheduled continuation plus one coalesced successor bit. It SHALL NOT own a recurring idle timer, poll an empty queue, replay missed batch intervals, immediately retry a blocked queue/mailbox, or drain beyond its finite service quantum without yielding.

#### Scenario: Business mailbox is nearly full

- **WHEN** an Event batch would consume the secure mailbox's reserved Control capacity
- **THEN** Event admission stops before consuming that capacity
- **AND** a policy or close Control frame can still be admitted

#### Scenario: Session is idle

- **WHEN** a session has no queued, policy, TTL, reconnect, or terminal work
- **THEN** it owns no scheduled polling task or repeating timer

#### Scenario: Several batches were missed

- **WHEN** a downlink flush runs long after its expected deadline
- **THEN** it emits at most one bounded due batch in that service call
- **AND** it schedules from the supplied current time instead of replaying missed intervals

#### Scenario: Peer exceeds accepted uplink contract

- **WHEN** a business frame exceeds available sender-contract tokens or hard retained/protocol bounds
- **THEN** Viewer closes that session with the closed local active-work-limit category
- **AND** the offending whole frame commits no sequence, queue, or telemetry delivery state

#### Scenario: Valid frames exceed one service turn

- **WHEN** one callback contains more valid frames or records than one configured quantum but remains inside hard and token bounds
- **THEN** Viewer commits only earlier whole frames, retains the ordered suffix, and schedules one same-core continuation
- **AND** the receive-pause token prevents rearm until that suffix drains

#### Scenario: Driver can complete another receive immediately

- **WHEN** valid input pauses and the controllable driver would synchronously complete its next receive
- **THEN** the channel has not rearmed and no second callback or `Data` exists
- **AND** resuming after the suffix drains starts exactly one next receive

#### Scenario: Paused suffix ends with a partial frame

- **WHEN** continuation consumes all complete retained frames, no policy timeout is recorded, and the decoder still owns a partial next frame
- **THEN** Viewer preserves and charges the partial bytes, detaches the old token/continuation, and resumes one receive
- **AND** the later completing callback supplies the frame receipt sample and may claim only one fresh pause token

#### Scenario: Frame spans two receipt samples

- **WHEN** a frame prefix arrives at one monotonic sample and its final bytes arrive at a later sample
- **THEN** the complete frame uses the later sample for TTL, token, deadline, and throughput decisions
- **AND** any continuation delay after completion cannot change that sample

#### Scenario: Terminal races a paused suffix

- **WHEN** terminal close wins while one decoder suffix and receive-pause token are owned
- **THEN** Viewer releases all retained bytes and invalidates the one continuation
- **AND** the token resolves once without receive rearm or stale-generation revival

#### Scenario: Resume races terminal with partial input

- **WHEN** needs-more-bytes detaches its token while terminal is racing
- **THEN** resume-first starts at most one cancellable generation-matched receive while terminal-first starts none
- **AND** both orders leave zero token, continuation, callback `Data`, and decoder residue after terminal cleanup

#### Scenario: System-message storm arrives

- **WHEN** drop-summary or other allowed system messages exceed the time-based system bucket
- **THEN** Viewer closes only that session without scheduling an unbounded successor
- **AND** another session can negotiate, transfer, and disconnect within its own work bounds

#### Scenario: Valid system burst is coalesced

- **WHEN** 33 through 128 valid system messages inside the permitted burst arrive together
- **THEN** Viewer services them across bounded continuation turns without closing solely for callback grouping

### Requirement: Multi-device owner exposes bounded live presentation and typed control admission without transferring protocol ownership

One runtime-components factory SHALL create the exact session manager, typed control facade, manager
generation, memory projection, and bounded journal for one explicit runtime logical ID. The manager
SHALL NOT generate a different hidden runtime ID and application code SHALL NOT recover control by
downcasting the handoff owner.

At each committed uplink or secure-mailbox-admitted downlink boundary, the manager SHALL create one
immutable normalized observation shared by protocol diagnostics and the memory projection. It SHALL
contain one Viewer wall/monotonic receive time, runtime/connection identity, bounded frozen
App/Bundle/display aliases, Event value, deterministic byte count, direction/sequence, and initial
disposition. Every current-Session consumer SHALL use those exact receive times rather than
resampling later.

The protocol callback SHALL offer observations to a 2,048-record/64-MiB fixed ingress using
precomputed deterministic Event bytes plus fixed maximum metadata/entry overhead and a constant
number of lock/index/ring operations. The ingress byte bound SHALL admit one maximum legal encoded
journal Event plus that fixed maximum overhead. It SHALL perform no eviction, large-value release,
JSON encoding, content traversal, MainActor wait, task per Event, or network mutation. At most one
serial projection drain plus one dirty successor SHALL maintain an O(1) deque/exact-key index
retaining at most 256 MiB of accounted Event data. It SHALL NOT evict because of an independent
fixed Event count. Finite deque and marker storage SHALL be derived from the byte budget divided by
minimum fixed per-Event accounting overhead and SHALL represent every byte-valid snapshot. Displaced
values SHALL release outside the state lock. Deterministic bytes SHALL be documented as accounting,
not actual Swift heap; callback latency and heap high-water SHALL be measured.

The projection SHALL also retain at most 16 frozen Session metadata rows, exact later terminal
disposition per retained Event, one positive-drop/cumulative sample per Device, Session end, and
bounded overflow/conflict gap state. Lock-side authority and pending per-key disposition/conflict
state SHALL cover the byte-derived retained-slot capacity plus the 2,048 fixed ingress slots so every
accepted pending Event can preserve its metadata while the projection executor is blocked. Normal
accepted disposition SHALL update the exact retained Event without creating a separate badge;
identical duplicate input SHALL remain idempotent; conflicting content for a retained journal key
SHALL preserve the first Event and add one bounded marker. Its latest-only UI wake SHALL run no more
than once per main run-loop turn and ten times per second, with at most one evaluation per cadence
and none while presentation is paused. Runtime shutdown SHALL join ingress/drain work and clear every
Event/Session projection value before the existing cleanup receipt completes.

Its identity SHALL be `(runtime logical ID, connection ID, direction, wire sequence)`. Peer Event UUID
SHALL remain content. Duplicate equivalence SHALL compare Event ID/type, canonical content JSON bytes,
App-created time normalized once to nearest integer milliseconds since 1970, App monotonic time,
priority, TTL, schema version, correlation/reply IDs, and initial disposition. Source, target, and
Session epoch SHALL be validated against the exact Session before commit. Frozen Session metadata,
deterministic byte accounting, and newly sampled Viewer receive times SHALL be excluded; the first
accounting and receive values remain authoritative, and no hash alone decides equality. While the
key remains pending or retained, an identical duplicate SHALL be idempotent and conflicting content
SHALL preserve the first observation plus one exact-key `presentationConflict` marker. Ingress
rejection SHALL record a saturating Session-wide gap and return `untracked`. Eviction SHALL end the
bounded duplicate horizon and SHALL already produce an overflow marker; no unbounded key tombstone
SHALL be retained, and a later candidate MAY become the new first observation. Presentation SHALL
NOT infer acknowledgement, alter sequence/queue/token/terminal state, or keep Event content after
runtime end.

One immutable projection snapshot SHALL drive filtering and detail without consulting mutable
Session state. Session-wide gaps SHALL remain in the global diagnostic snapshot and SHALL NOT be
attributed to every retained Event. Device gaps and positive drops apply to the exact Device;
terminal disposition and presentation conflict apply to the exact Event; unavailable projection
data does not match. Evaluation SHALL scan the complete byte-valid snapshot, bounded by 256 MiB and
the derived finite carrier capacity, perform at most 16,384 predicate checks and 1,000,000 JSON-node
visits, run at most 100 ms, check cancellation between entries/predicates/path components, and
publish no partial result as complete. Literal and typed JSON matching SHALL use the closed
current-Session evaluator rather than an external query engine.

The session manager SHALL accept one immutable prepared Event plus 1 through 16 manager-issued opaque
target capabilities carrying random token UUID, exact runtime logical ID, manager generation, and
connection ID. Capabilities SHALL be memory-only, non-reconstructible by UI, and limited to the exact
active/terminal-cache lifetime below. The prepared value SHALL contain the one validated/encoded
draft, checked accounted bytes, and normal or event-type-keyed keep-latest policy; no target
admission may re-encode, deep-traverse, or deep-copy content. Duplicate token UUID occurrences SHALL
all be invalid before admission and unique results SHALL preserve input order.

Classification SHALL be authoritative inside manager/session ownership. At most 16 active
capabilities exist. Terminal moves the exact capability into a separate connection-keyed cache
capped at 64 entries and retained while elapsed monotonic time is less than 30 seconds; equality
expires, and capacity eviction uses oldest terminal time then token UUID lexical order. Same-route
reconnect issues a new capability and never removes or satisfies the old entry. Shutdown/full
identity reset clears the cache; it is not the route-keyed recent-device presentation. Malformed,
duplicate, wrong-runtime, wrong-generation, never-issued, expired, capacity-evicted, or reset-cleared
capabilities are `invalidTarget`. On the manager's serial executor,
terminal-before-capability-lookup finds the exact terminal entry and is `noLongerConnected`;
lookup-before-terminal followed by negotiating/disconnecting state or terminal-before-session-active
check is `notActive`; `queueRejected` requires exact active ownership with negotiated-size or
bounded-queue rejection; and `queued` requires that exact session to buffer the prepared draft.
Terminal after buffering does not rewrite `queued`. There SHALL be no retry, route retarget,
cross-device rollback, secure-mailbox/peer claim, or independent send history.

#### Scenario: Presentation ingress is unavailable while uplink Events commit

- **WHEN** valid contiguous Events commit protocol sequence but bounded presentation ingress cannot
  accept another observation
- **THEN** one saturating Session-wide memory gap records the unavailable presentation horizon
- **AND** presentation loss changes no connection, sequence, queue, token, timeout, or terminal
  decision

#### Scenario: More than 512 small Events remain within the byte budget

- **WHEN** projection contains more than 512 Events but remains within 256 MiB of accounted data
- **THEN** it retains those Events without count-triggered displacement
- **AND** exact-key authority, diagnostics, evaluation, and Timeline publication remain bounded by
  the same byte-derived carrier capacity

#### Scenario: Live callback ingress or window reaches a bound

- **WHEN** callback ingress would exceed 2,048 entries/64 MiB or projection would exceed 256 MiB of
  accounted Event data
- **THEN** callback admission remains constant-work, one saturating global gap records
  rejected/displaced presentation values, and projection eviction occurs only on its executor
- **AND** no producer blocks, no Event is released under the callback lock, and no task/value
  accumulates per loss

#### Scenario: One selected target is no longer active

- **WHEN** a validated multi-target control draft reaches a target whose exact connection lost active
  ownership
- **THEN** that target receives `noLongerConnected` or `notActive` while other targets decide
  independently
- **AND** no new session is selected by route similarity and no delivery claim is made

#### Scenario: Same live key arrives with conflicting content

- **WHEN** a second observation reuses runtime/connection/direction/sequence with different Event
  content while the first key remains retained
- **THEN** the retained first Event remains, one bounded presentation-conflict marker is coalesced,
  and the duplicate does not replace it
- **AND** no protocol outcome is changed

#### Scenario: Conflicting key returns after memory eviction

- **WHEN** the first key was evicted and a later candidate reuses that key
- **THEN** the existing overflow diagnostic discloses the lost horizon and the later candidate may
  become the new bounded first
