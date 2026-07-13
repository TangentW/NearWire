# viewer-multidevice-flow-control Specification

## Purpose
TBD - created by archiving change viewer-multidevice-flow-control. Update Purpose after archive.
## Requirements
### Requirement: Viewer owns a finite set of independent App sessions

Viewer SHALL replace the foundation placeholder with one `ViewerAdmissionHandoffOwning` multi-device manager. The manager SHALL synchronously bound all provisional, negotiating, active, and disconnecting session owners to 16, independently from the foundation's 32 connection-owner bound. A rejected 17th handoff SHALL create no session task or UI row and SHALL be cancelled through the original admission cleanup ownership.

Each accepted session SHALL extend the same immutable admission connection core, secure-channel callback, continuous frame decoder, and terminal gate that decoded the App Hello. The core serial queue SHALL remain the sole decoder, wire-phase, policy-transaction, sequence, and terminal executor. Session attachment SHALL occur synchronously and reentrantly before handoff transfer returns success, SHALL preserve another frame coalesced after App Hello, and SHALL occur at most once. It SHALL NOT expose or replace raw Network.framework objects, endpoint descriptions, decoder ownership, or transport callbacks. A provisional reservation SHALL count toward 16 and SHALL roll back if duplicate-route policy, attachment, terminal state, or shutdown prevents commit. No manager lock SHALL be held across a core operation or callback that can re-enter the manager. Per-session work SHALL be isolated so one device's wait, full queue, malformed input, or cleanup cannot serialize another device.

#### Scenario: Sixteen Apps are connected

- **WHEN** 16 distinct slots are occupied by any mixture of provisional, negotiating, active, or disconnecting owners
- **THEN** each has independent session and queue ownership
- **AND** a valid 17th handoff is rejected without disturbing the first 16

#### Scenario: One device blocks

- **WHEN** one active device stops reading, fills its queue, or delays cleanup
- **THEN** another device can negotiate, exchange Events, publish telemetry, and disconnect
- **AND** no shared wait or business queue couples their progress

#### Scenario: Session attaches after admission

- **WHEN** the multi-device owner accepts an opaque admission handle
- **THEN** active protocol handling continues through the same connection core and decoder
- **AND** no unread bytes or terminal event can be stranded between owners

#### Scenario: App coalesces input after Hello

- **WHEN** App Hello and the next valid session frame arrive in one receive chunk
- **THEN** transfer installs the session handler inline before the decoder advances
- **AND** the next frame reaches the sole core protocol executor without an asynchronous holding queue

#### Scenario: Attachment cannot commit

- **WHEN** terminal state or shutdown wins after provisional reservation but before attachment commit
- **THEN** Viewer rolls back the session entry and returns handoff failure
- **AND** admission retains exact cancellation and cleanup ownership

### Requirement: Logical device correlation is bounded and never authenticates a peer

Viewer SHALL derive a logical correlation key from the peer-declared App installation ID plus optional Bundle ID in the validated App Hello. That key, display name, version, generated alias, and nickname SHALL be unauthenticated correlation/presentation hints only. They SHALL NOT prove App identity, authorize replacement, or retarget Event delivery. Viewer SHALL present at most one owned connection per correlation key.

While a key is provisional, negotiating, active, or disconnecting, a second live claim SHALL be rejected under both automatic and approval admission without disturbing the healthy connection. Reconnection SHALL start only after the old handle is terminal and its 16-slot ownership is released. Downlink work SHALL belong to the exact internal connection ID and epoch, SHALL be cleared or terminally dropped when it closes, and SHALL never transfer to a later connection declaring the same key. A later send SHALL be a new local submission to the newly selected live session.

A disconnected key MAY remain as a safe memory-only recent row for at most 30 seconds and SHALL retain no Event content, queue key, session epoch, pairing code, endpoint, certificate, or wire bytes. Recent rows SHALL be globally bounded to 64, deterministically evict the oldest disconnect time with correlation-key tie-breaking, and never evict an owned/disconnecting connection. Exactly one manager-owned replaceable wake SHALL target the earliest expiry and service at most 64 due rows per turn. A successful handoff commit before the deadline SHALL replace the exact row, while failed attachment SHALL preserve it until its original deadline; at a sampled time equal to or later than the deadline, expiry SHALL win. Late callbacks SHALL match immutable connection and disconnect generations. A live slot SHALL remain occupied through disconnecting state and release only after exact handle cleanup. Shutdown SHALL leave zero live slots, recent rows, and expiry-wake ownership after cleanup.

#### Scenario: Exact tuple duplicates a healthy key

- **WHEN** a second peer declares the same installation ID and the same optional Bundle ID while the original connection is owned
- **THEN** Viewer rejects the new handoff under automatic or approval admission
- **AND** the original session, nickname presentation, and queued downlink ownership remain unchanged

#### Scenario: Bundle variant creates a distinct key

- **WHEN** a peer declares the same installation ID but a different or missing Bundle ID from the original key
- **THEN** Viewer treats it as a separate unauthenticated correlation row subject to ordinary capacity and admission
- **AND** it neither disturbs nor inherits the original nickname, selection, session, or downlink queue

#### Scenario: Recent-route churn exceeds its bound

- **WHEN** more than 64 distinct keys disconnect within 30 seconds
- **THEN** Viewer retains at most 64 recent rows using deterministic oldest-first eviction
- **AND** one manager expiry owner services all remaining rows

#### Scenario: Reconnect reaches the expiry boundary

- **WHEN** a handoff for a recent key is processed before its deadline
- **THEN** it removes the exact old row and starts a fresh unauthenticated connection
- **AND** at or after the deadline expiry wins before any later handoff

### Requirement: Viewer completes and maintains directional flow policy

For every accepted handoff, Viewer SHALL allocate a fresh `SessionEpoch`. One non-resetting 10-second monotonic initial deadline SHALL start immediately before acknowledgement and initial-offer encoding/mailbox admission, include local admission and peer response time, and not wait for send completion. Encoding or atomic mailbox admission failure SHALL close immediately. The App acceptance frame's completion receipt sample SHALL be earlier than the deadline; equality SHALL be timeout. Each accepted App uplink and App downlink value SHALL be protocol-valid and no greater than the current offered value. Only then SHALL the session become active and expose the possibly lower accepted values as effective.

Viewer SHALL serialize dynamic policy updates with at most one offer in flight. Each dynamic non-resetting 10-second deadline SHALL start immediately before that offer's encoding/mailbox admission. Changes during an in-flight offer SHALL retain only the latest validated requested pair for the next offer. Because V1 has no policy generation field, correlation SHALL use exactly one pending offer plus ordered stream phase. A valid conservative acceptance SHALL change only the current offer's effective values, then send the latest desired pair if still different. Acceptance without a pending offer SHALL be an observable repeat and close the session. While an offer is pending, any protocol-valid pair no greater than it SHALL be attributed to that current transaction even if its values equal an earlier lower acceptance, because V1 cannot observe semantic staleness. Escalation, unexpected message, admission failure, or timeout SHALL close only that session under the suffix-arbitration rule below. Zero SHALL pause the corresponding business Event direction without blocking Control traffic, system drop summaries, or local expiry service.

The core serial queue and frame-completion receipt sample SHALL choose exactly one policy winner. A timeout callback SHALL normally close, but SHALL first defer terminal commit when one already-owned paused decoder suffix has a completion sample earlier than that deadline. It SHALL record elapsed state without resetting/extending the deadline or rearming receive, and the bounded continuation SHALL classify already-complete frames in that suffix. A matching pre-deadline acceptance MAY commit. When no complete frame remains, including needs-more-bytes with only a partial tail, or when a violation appears first, the recorded timeout SHALL close once, clear partial bytes, and SHALL NOT resume receive. A suffix sampled at or after the deadline SHALL not defer timeout. Physical transport terminal, explicit cancellation, and shutdown SHALL still invalidate any suffix immediately. No continuation scheduling delay SHALL turn a pre-deadline completed acceptance into timeout.

#### Scenario: Initial policy is accepted conservatively

- **WHEN** Viewer requests 20 uplink and 10 downlink Events per second and App accepts 12 and 8
- **THEN** the session becomes active with effective rates 12 and 8
- **AND** requested rates remain visible as 20 and 10

#### Scenario: App escalates a rate

- **WHEN** App accepts any direction above the matching Viewer request
- **THEN** Viewer rejects the policy and closes that session

#### Scenario: Rate changes overlap

- **WHEN** two requested policy edits occur before the current offer is accepted
- **THEN** Viewer completes the current in-flight offer and retains only the latest later pair
- **AND** the latest later pair becomes effective only after its own attributed acceptance

#### Scenario: Acceptance races its deadline

- **WHEN** a conservative acceptance frame completes with a receipt sample before its deadline
- **THEN** it commits once and a later timeout callback is stale
- **AND** a frame sampled at or after the deadline cannot mutate effective state

#### Scenario: Timeout overtakes a retained pre-deadline acceptance

- **WHEN** a callback sampled just before the deadline pauses with its acceptance beyond the first service quantum and timeout is queued before continuation
- **THEN** timeout records elapsed but keeps receive paused until the finite suffix is classified
- **AND** the matching pre-deadline acceptance commits regardless of timeout/continuation queue order

#### Scenario: Retained acceptance is not pre-deadline

- **WHEN** the otherwise identical suffix is sampled at or after the exact deadline
- **THEN** timeout closes once without allowing that acceptance to mutate effective state

#### Scenario: Pre-deadline suffix ends partial without acceptance

- **WHEN** timeout is deferred for pre-deadline complete frames but classification reaches only a partial tail without acceptance
- **THEN** the recorded timeout closes, clears the partial bytes, and resolves the pause token
- **AND** Viewer does not resume receive to wait for post-deadline completion

#### Scenario: Acceptance has no pending offer

- **WHEN** App repeats a prior acceptance while Viewer has no offer in flight
- **THEN** Viewer closes that session exactly once and emits no later policy offer

#### Scenario: Lower pair is indistinguishable from an earlier acceptance

- **WHEN** a later offer is pending and App sends a valid lower pair that also matched an earlier offer
- **THEN** V1 attributes that pair to the one current transaction and makes it effective
- **AND** a further acceptance with no next pending offer is detectable and closes the session

#### Scenario: Direction is paused

- **WHEN** one effective direction is zero
- **THEN** no business Event moves in that direction
- **AND** policy, close, system drop-summary, terminal, and expiry work can still progress

### Requirement: Requested device preferences are bounded and safe

The Viewer global requested defaults SHALL be 20 App-to-Viewer and 10 Viewer-to-App Events per second. A new session SHALL resolve requested values from an in-memory session override, then the most recent preference for its Bundle ID, then global defaults. Changing a connected device SHALL update its session override and its Bundle-ID preference when a Bundle ID exists. Effective accepted policy SHALL NOT be persisted.

Viewer SHALL persist at most 256 versioned Bundle-ID policy records and 256 logical-route nicknames through an injected `UserDefaults` boundary. It SHALL deterministically evict least-recently-used records on overflow. Missing Bundle ID SHALL NOT inherit another Bundle-ID preference. Invalid identifiers, unknown versions, corrupt data, invalid/nonfinite rates, invalid timestamps, or invalid nicknames SHALL fall back safely without transport failure or raw stored-value presentation. Nicknames SHALL exclude control characters and contain no more than 80 Unicode scalar values.

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

### Requirement: Bidirectional Event transfer is bounded and protocol-correct

Each active session SHALL own one downlink-send queue and one uplink-delivery queue using the shared bounded queue implementation. Each queue SHALL permit at most 5,000 Events and 16 MiB of accounted data, with its single-Event limit no greater than the negotiated maximum. Viewer downlink SHALL support normal and caller-keyed keep-latest semantics. Incoming wire Events SHALL remain distinct because the wire schema carries no sender queue key.

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

#### Scenario: Queue reaches a byte bound

- **WHEN** another Event would exceed a session queue's 16 MiB limit
- **THEN** existing priority-aware overflow policy restores the bound
- **AND** queue count and accounted bytes never exceed their configured limits

#### Scenario: Valid inbound Event expires locally

- **WHEN** the next route-valid wire Event is already expired on the receiver clock
- **THEN** Viewer advances the expected sequence and records local expiry without delivery
- **AND** the following contiguous Event remains valid

#### Scenario: Downlink mailbox rejects a frame

- **WHEN** an encoded batch cannot enter the secure mailbox atomically
- **THEN** no sequence, queue entry, fairness credit, or rate token is consumed
- **AND** retry emits the same contiguous sequence range exactly once

### Requirement: Session pumping preserves rate and Control progress

Viewer SHALL enforce effective uplink delivery and downlink send rates with independent shared token buckets. The accepted App-uplink rate SHALL also be a cooperative sender contract enforced by a two-second ingress token bucket. A business Event frame whose whole record count exceeds available ingress tokens, including any Event at zero rate, SHALL close with `activeWorkLimitExceeded` before that frame commits sequence or queue state. Downlink SHALL use 500 ms batching. Business Event mailbox admission SHALL reserve one bounded Control slot and bounded Control bytes through the secure-channel reservation seam. Control frames SHALL bypass business Event rates and queues but SHALL remain schema- and mailbox-bounded. The protocol-defined Event-lane drop summary SHALL also bypass business rate tokens and queues while remaining mailbox- and coalescing-bounded.

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

### Requirement: Drop reporting and telemetry are bounded and content-free

Viewer SHALL maintain saturating per-session counters for local enqueue, dequeue, overflow drop, expiry, route drop, keep-latest coalescing, and remote drop summaries. It SHALL coalesce unsent local loss into at most one bounded wire drop summary on the protocol-defined Event lane without consuming business rate tokens. Remote summaries SHALL update telemetry only and SHALL NOT be reflected or treated as acknowledgement. Remote summaries MAY be persisted only as bounded drop samples and SHALL NOT become Event history.

Session snapshots SHALL include safe identity presentation, state, requested/effective rates, current queue counts/bytes/oldest wait, cumulative counters, approximate bounded one-second ingress/egress rates, and a closed terminal category. They SHALL NOT include Event content or metadata values, pairing code, endpoints, certificate/TLS material, wire bytes, or arbitrary transport errors. The full manager snapshot SHALL contain no more than 16 owned-session rows plus 64 recent rows and SHALL reach the main model through latest-only bounded delivery.

Every error, terminal category, description, debug description, reflection helper, interpolation, log, analytics value, clipboard value, and safe session/recent-row presentation SHALL derive only from a closed local code or explicitly bounded presentation model. These surfaces SHALL exclude Event type/content, Event metadata values, queue keys and contents, installation/correlation identifiers except the already bounded user-facing App/Bundle fields, session epochs, endpoints, certificate data, peer text, raw bytes, database paths, query text, SQL text/errors, and underlying errors.

The dedicated Viewer local-store boundary MAY persist validated logical Event content and metadata, bounded App/device correlation, requested/effective policy samples, drop samples, annotations, and safe lifecycle state exactly as specified by `viewer-local-store-search`. Those values SHALL remain absent from `UserDefaults`, logs, analytics, clipboard, safe status snapshots, and recent in-memory rows. Raw wire frames, queue keys, queue contents, pairing codes, endpoint/certificate/Keychain material, and exact session epochs SHALL remain absent from persistence and export. JSON export MAY contain validated Event content and safe analysis metadata only after applying the aliasing and omission rules of `viewer-local-store-search`. Effective policy MAY be persisted locally for analysis but SHALL remain absent from export and safe status. Packaging evidence SHALL reassess the Viewer privacy manifest against the new local Event store and bounded storage preferences and SHALL inspect the built privacy manifest.

Counter overflow SHALL saturate. Telemetry, journal, query, or persistence failure SHALL NOT terminate, block, or alter a device protocol session.

#### Scenario: Several local losses occur before mailbox capacity exists

- **WHEN** overflow and expiry occur while the bounded mailbox cannot admit the drop summary
- **THEN** Viewer retains one coalesced bounded drop summary
- **AND** later mailbox capacity sends the aggregate without blocking Event producers

#### Scenario: Remote reports dropped Events

- **WHEN** a valid remote drop summary arrives
- **THEN** remote-loss telemetry increases with saturation and may produce one bounded local drop sample
- **AND** Viewer emits no mirrored summary and infers no delivery acknowledgement

#### Scenario: UI telemetry is busy

- **WHEN** many session counters change in one main-run-loop interval
- **THEN** Viewer retains only the latest safe snapshot for UI delivery
- **AND** it creates no unbounded `MainActor` task backlog

#### Scenario: Event is committed for local journaling

- **WHEN** an uplink frame commits validation/sequence or a downlink frame commits secure-mailbox admission
- **THEN** the dedicated bounded store sink may receive the validated logical record and exact local disposition
- **AND** no log, `UserDefaults`, recent row, safe snapshot, or clipboard value receives its type, content, metadata, session epoch, or queue key

#### Scenario: Storage or query operation fails

- **WHEN** SQLite, indexing, cleanup, search, or export reports a failure
- **THEN** user-visible and diagnostic surfaces contain only a closed safe category
- **AND** no SQL, path, Event, identity, or underlying error value appears or changes the network session

### Requirement: Device workspace exposes session control without Event history

The Viewer sidebar SHALL list negotiating, active, disconnecting, and recently disconnected correlation rows with safe identity hints, nickname, state, and bounded warning indicators. A returning connection SHALL use the ordinary negotiating state; there SHALL be no separate reconnecting state. The workspace SHALL explicitly label App identity, installation alias, Bundle ID, nickname continuity, and recent-row presentation as unauthenticated and SHALL NOT imply that any one proves the returning App. A selected connected device SHALL show editable nickname, requested App uplink/downlink rates, separately labeled effective rates, queue count/bytes/oldest wait, throughput, Event counts, and drop totals. Invalid rate or nickname input SHALL be rejected locally with fixed safe guidance. Disconnected rows SHALL not permit rate mutation.

The workspace SHALL preserve the foundation pairing, approval, pause, and recovery controls. It SHALL NOT implement Event history, timeline/detail rendering, search, filters, local-store settings, export, control composition, or performance charts in this change. Controls and state SHALL have accessibility labels and deterministic presentation-model coverage.

#### Scenario: User selects an active device

- **WHEN** an active logical route is selected
- **THEN** its requested and effective rates are clearly distinguished
- **AND** its current queue and transfer telemetry are available without exposing Event content

#### Scenario: Device disconnects while selected

- **WHEN** the selected session terminates
- **THEN** the row enters bounded recent-disconnect presentation or is removed after expiry
- **AND** rate mutation is disabled without selecting an unrelated device

### Requirement: Session lifecycle composes with the foundation runtime

Pause New Devices and ordinary pairing refresh SHALL leave handed-off sessions active. Per-device disconnect SHALL close only that session. Window close, application termination, TLS reset, and full identity reset SHALL atomically prevent new session transfer, cancel all owned sessions, and join their cleanup through the existing runtime receipt. A one-second UI wait expiry SHALL NOT abandon handle cleanup or release an admission slot early.

Late callbacks SHALL be ignored by connection ID, session epoch, disconnect generation, and runtime generation. Disconnected-session presentation SHALL not authenticate or revive a closed transport. Session queues and effective policy SHALL remain memory-only, SHALL be discarded at terminal cleanup, and SHALL never migrate to a later connection declaring the same correlation values.

#### Scenario: Pairing code refreshes

- **WHEN** Viewer successfully replaces its Bonjour listener and pairing code
- **THEN** all active device sessions remain connected

#### Scenario: Window closes with several devices

- **WHEN** the last window closes while several sessions are negotiating, active, or cleaning up
- **THEN** session transfer closes first and each core is cancelled independently
- **AND** cleanup ownership persists even if the bounded application wait expires

### Requirement: The multi-device owner exposes bounded journal observations without transferring protocol ownership

The session manager SHALL expose immutable Viewer-internal journal observations for logical/durable recording-device lifecycle, committed uplink Events, append-only uplink terminal-disposition transitions, committed downlink mailbox admission, changed policy samples, and changed drop samples. Journal delivery SHALL be nonthrowing and constant-bounded per already-validated record on the connection core executor. Admission SHALL use the record's precomputed deterministic byte count plus fixed metadata reservation and copy-on-write value ownership; it SHALL perform no JSON encoding, content traversal, deep copy, or SQLite work. It SHALL NOT expose a network connection, decoder, mailbox mutation method, sequence counter, token bucket, queue, or terminal gate to storage.

#### Scenario: Store consumer is blocked or unavailable

- **WHEN** the journal sink cannot accept or persist an observation
- **THEN** the exact device session continues using its prior protocol, queue, token, timeout, and terminal state
- **AND** only bounded persistence-gap/status accounting changes
