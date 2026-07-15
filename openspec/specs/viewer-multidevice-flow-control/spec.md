# viewer-multidevice-flow-control Specification

## Purpose
TBD - created by archiving change viewer-multidevice-flow-control. Update Purpose after archive.
## Requirements
### Requirement: Viewer owns a finite set of independent App sessions

Viewer SHALL replace the foundation placeholder with one `ViewerAdmissionHandoffOwning` multi-device manager. The manager SHALL synchronously bound current provisional, negotiating, active, and disconnecting route owners to 16, independently from the foundation's 32 connection-owner bound, and SHALL separately bound displaced reconnect cleanup owners to 16. A rejected 17th current-owner handoff SHALL create no session task or UI row and SHALL be cancelled through the original admission cleanup ownership.

Each accepted session SHALL extend the same immutable admission connection core, secure-channel callback, continuous frame decoder, and terminal gate that decoded the App Hello. The core serial queue SHALL remain the sole decoder, wire-phase, policy-transaction, sequence, and terminal executor. Session attachment SHALL occur synchronously and reentrantly before ownership replacement commits or handoff transfer returns success, SHALL preserve another frame coalesced after App Hello, and SHALL occur at most once. It SHALL NOT expose or replace raw Network.framework objects, endpoint descriptions, decoder ownership, or transport callbacks. A failed attachment SHALL change no current or displaced route ownership. A committed replacement SHALL move the exact predecessor to bounded displaced cleanup ownership. No manager lock SHALL be held across a core operation or callback that can re-enter the manager. Per-session work SHALL be isolated so one device's wait, full queue, malformed input, or cleanup cannot serialize another device.

#### Scenario: Sixteen Apps are connected

- **WHEN** 16 current slots are occupied by any mixture of provisional, negotiating, active, or disconnecting owners
- **THEN** each has independent session and queue ownership
- **AND** a valid 17th distinct-route handoff is rejected without disturbing the first 16

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

- **WHEN** terminal state, shutdown, or an injected attachment failure wins before ownership commit
- **THEN** Viewer returns handoff failure without changing the current route owner or creating displaced cleanup ownership
- **AND** admission retains exact cancellation and cleanup ownership for the failed candidate

### Requirement: Logical device correlation is bounded and never authenticates a peer

Viewer SHALL derive a logical correlation key from the peer-declared App installation ID plus optional Bundle ID in the validated App Hello. That key, display name, version, generated alias, and nickname SHALL be unauthenticated correlation/presentation hints only. They SHALL NOT prove App identity, authorize Event delivery, or transfer connection-owned state. Viewer SHALL present at most one current connection per correlation key.

When a second admitted connection claims an exact currently owned key, Viewer SHALL make the newest session the current route owner and cancel the displaced session outside manager locks. Replacement SHALL issue a new opaque control capability and SHALL NOT transfer pending downlink work, queue keys, sequence state, session epoch, terminal state, or a delivery claim. The displaced owner SHALL remain separately owned until exact cleanup completes. Viewer SHALL retain at most 16 current owners and 16 displaced cleanup owners, SHALL allow at most one outstanding displacement per correlation key, and SHALL reject additional replacement or capacity handoffs without disturbing the current owner. Shutdown SHALL join both ownership sets.

A disconnected key MAY remain as a safe memory-only recent row for at most 30 seconds and SHALL retain no Event content, queue key, session epoch, pairing code, endpoint, certificate, or wire bytes. Recent rows SHALL be globally bounded to 64, deterministically evict the oldest disconnect time with correlation-key tie-breaking, and never evict a current/displaced connection. Exactly one manager-owned replaceable wake SHALL target the earliest expiry and service at most 64 due rows per turn. A successful handoff commit before the deadline SHALL replace the exact row, while failed attachment SHALL preserve it until its original deadline; at a sampled time equal to or later than the deadline, expiry SHALL win. Late callbacks SHALL match immutable connection and disconnect generations. Shutdown SHALL leave zero current owners, displaced owners, recent rows, and expiry-wake ownership after cleanup.

#### Scenario: Exact tuple reconnects while the predecessor is owned

- **WHEN** a second paired and TLS-admitted peer declares the same installation ID and optional Bundle ID while the original connection is owned
- **THEN** Viewer presents the new session as the current route and cancels the displaced session
- **AND** the new session inherits no queue, capability, sequence, epoch, terminal, or delivery state from the predecessor

#### Scenario: Replacement cleanup is still pending

- **WHEN** another exact-route connection arrives before the displaced predecessor finishes cleanup
- **THEN** Viewer rejects that additional handoff without disturbing the current route owner
- **AND** current plus displaced ownership remains within its fixed bounds

#### Scenario: Bundle variant creates a distinct key

- **WHEN** a peer declares the same installation ID but a different or missing Bundle ID from the original key
- **THEN** Viewer treats it as a separate unauthenticated correlation row subject to ordinary capacity and admission
- **AND** it neither disturbs nor inherits the original nickname, selection, session, or downlink queue

#### Scenario: Recent-route churn exceeds its bound

- **WHEN** more than 64 distinct keys disconnect within 30 seconds
- **THEN** Viewer retains at most 64 recent rows using deterministic oldest-first eviction without evicting current or displaced ownership
- **AND** one manager expiry owner services all remaining rows

#### Scenario: Reconnect reaches the expiry boundary

- **WHEN** a handoff for a recent key is processed before its deadline
- **THEN** a successful ownership commit removes the exact old row and starts a fresh unauthenticated connection
- **AND** failed attachment preserves the row, while at or after the deadline expiry wins before any later handoff

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

### Requirement: Device workspace exposes session control and composes with the Event Explorer

The Viewer Devices strip SHALL list negotiating, active, disconnecting, and recently disconnected correlation rows with safe identity hints, nickname, state, and bounded warning indicators. A returning connection SHALL use the ordinary negotiating state; there SHALL be no separate reconnecting state. The workspace SHALL explicitly label App identity, installation alias, Bundle ID, nickname continuity, and recent-row presentation as unauthenticated and SHALL NOT imply that any one proves the returning App. A selected connected Device SHALL expose the existing bounded settings and telemetry without Event or decoded Performance content in the row. Invalid rate or nickname input SHALL be rejected locally with fixed safe guidance. Disconnected rows SHALL not permit rate mutation.

The workspace SHALL preserve pairing, approval, pause, and recovery controls and SHALL compose one main Event window with one singleton Performance window without creating a second session manager, Store owner, listener, or protocol owner. Event content and decoded Performance values SHALL appear only in Timeline/Inspector/composer or Performance dashboard surfaces. Events MAY scope up to 16 current-Session Devices; Performance SHALL own one independent exact Device choice. V1 multi-Device Performance overlays remain deferred.

Controls and state SHALL have accessibility labels and deterministic presentation-model coverage.

#### Scenario: User selects an active Event Device

- **WHEN** an active logical route is selected in the main Device strip
- **THEN** its settings and telemetry target are explicit and it may scope the Event Timeline
- **AND** a valid existing Performance Device choice is not silently retargeted

#### Scenario: User selects a Performance Device

- **WHEN** the Performance window chooses one exact available Device
- **THEN** only the bounded Performance projection target changes
- **AND** main Event Device scope, selected Event, Inspector, and Device-details target remain unchanged

#### Scenario: Device disconnects while selected

- **WHEN** a selected session terminates
- **THEN** its row enters bounded recent-disconnect presentation or is removed after expiry
- **AND** invalid Performance selection uses only the documented exact fallback or is cleared without selecting an unrelated Device

### Requirement: Multi-device owner exposes bounded live presentation and typed control admission without transferring protocol ownership

One runtime-components factory SHALL create the exact session manager, typed control facade, manager generation, live projection, and composite store/live journal for one explicit runtime logical ID. The manager SHALL NOT generate a different hidden runtime ID and application code SHALL NOT recover control by downcasting the handoff owner.

At each committed uplink or secure-mailbox-admitted downlink boundary, the manager SHALL create one immutable normalized observation shared by store and live paths. It SHALL contain one Viewer wall/monotonic receive time, runtime/connection identity, bounded frozen App/Bundle/display aliases, Event value, deterministic byte count, direction/sequence, and initial disposition. The store SHALL use those exact receive times rather than resampling later.

The protocol callback SHALL offer observations to a 64-record/20-MiB fixed ingress using precomputed deterministic Event bytes plus fixed maximum metadata/entry overhead and a constant number of lock/index/ring operations. The ingress byte bound SHALL admit one maximum legal encoded journal Event plus that fixed maximum overhead. It SHALL perform no eviction, large-value release, JSON encoding, content traversal, SQLite, MainActor wait, task per Event, or network mutation. At most one serial projection drain plus one dirty successor SHALL maintain an O(1) deque/exact-key index retaining at most 512 Events and 32 MiB, which can retain one maximum legal journal Event. Displaced values SHALL release outside the state lock. Deterministic bytes SHALL be documented as accounting, not actual Swift heap; callback latency and heap high-water SHALL be measured.

The projection SHALL also retain at most 16 frozen session metadata rows, exact later terminal disposition per retained Event, one positive-drop/cumulative sample per device, session end, live overflow/conflict gap, and store unavailable/recovery gap state. The process store SHALL publish content-free accepted/identical/journal-conflict/unavailable/recovered transitions to the projection executor without calling into protocol state or changing committed observations. Accepted SHALL wait for exact durable-row visibility before reconciliation; identical SHALL remove only the later exact transient candidate; journal-conflict SHALL remove that candidate and add its bounded marker so neither obscures the first durable row. Its latest-only UI wake SHALL run no more than once per main run-loop turn and 10 times per second, with at most one refresh query per cadence and none while presentation is paused. Runtime shutdown SHALL join ingress/drain work and clear every Event/session projection value before the existing cleanup receipt completes.

Its identity SHALL be `(runtime logical ID, connection ID, direction, wire sequence)`. Peer Event UUID SHALL remain content. Duplicate equivalence SHALL use the same durable projection in live and store: Event ID/type, canonical content JSON bytes, App-created time normalized once to nearest integer milliseconds since 1970, App monotonic time, priority, TTL, schema version, correlation/reply IDs, and initial disposition. Source/target/session epoch SHALL be validated against the exact session before commit, so a mismatch cannot reach a journal comparator. Frozen session metadata, deterministic byte accounting, and newly sampled Viewer receive times SHALL be excluded; the first accounting/receive values remain authoritative, and no hash alone decides equality. The composite journal SHALL linearize classification at live ingress before fan-out. While the key remains pending or retained, an identical duplicate SHALL be idempotent and conflicting content SHALL preserve the first observation, add one exact-key `presentationConflict` marker, and bypass store fan-out. Ingress rejection of a new key SHALL record the saturating gap and return `untracked`, after which the serial writer remains the only durable duplicate authority; if storage is unavailable too, no content or duplicate guarantee is retained. Eviction SHALL end that live duplicate horizon and SHALL already produce an overflow marker; no unbounded key tombstone SHALL be retained. A later candidate MAY become the new transient first after eviction. If an immutable durable row exists, the writer SHALL be the second authority: identical SHALL be a no-op and conflicting content SHALL preserve the row and return content-free `journalConflict` without making storage unavailable. If neither bounded live nor durable state retains the first observation, no post-eviction first-wins claim SHALL be made. Conflict markers SHALL coalesce only while resident and otherwise increment the saturating diagnostic-loss counter. Presentation may reconcile an exact key with a durable row but SHALL NOT backfill SQLite, infer acknowledgement, alter sequence/queue/token/terminal state, or keep transient content after runtime end.

One immutable projection snapshot SHALL drive live filtering/detail without consulting mutable session state. Runtime gaps apply to every retained Event; device gaps and positive drops apply to the exact device; terminal disposition applies to the exact Event; unavailable projection data does not match. Evaluation SHALL scan at most 512 entries/32 MiB, perform at most 16,384 predicate checks and 1,000,000 JSON-node visits, run at most 100 ms, check cancellation between entries/predicates/path components, and publish no partial result as complete. FTS5 full-text SHALL exclude transient rows with fixed recorded-data guidance rather than guessed tokenizer semantics.

The session manager SHALL accept one immutable prepared Event plus 1 through 16 manager-issued opaque target capabilities carrying random token UUID, exact runtime logical ID, manager generation, and connection ID. Capabilities SHALL be memory-only, non-reconstructible by UI, and limited to the exact active/terminal-cache lifetime below. The prepared value SHALL contain the one validated/encoded draft, checked accounted bytes, and normal or event-type-keyed keep-latest policy; no target admission may re-encode, deep-traverse, or deep-copy content. Duplicate token UUID occurrences SHALL all be invalid before admission and unique results SHALL preserve input order.

Classification SHALL be authoritative inside manager/session ownership. At most 16 active capabilities exist. Terminal moves the exact capability into a separate connection-keyed cache capped at 64 entries and retained while elapsed monotonic time is less than 30 seconds; equality expires, and capacity eviction uses oldest terminal time then token UUID lexical order. Same-route reconnect issues a new capability and never removes or satisfies the old entry. Shutdown/full identity reset clears the cache; it is not the route-keyed recent-device presentation. Malformed, duplicate, wrong-runtime, wrong-generation, never-issued, expired, capacity-evicted, or reset-cleared capabilities are `invalidTarget`. On the manager's serial executor, terminal-before-capability-lookup finds the exact terminal entry and is `noLongerConnected`; lookup-before-terminal followed by negotiating/disconnecting state or terminal-before-session-active-check is `notActive`; `queueRejected` requires exact active ownership with negotiated-size or bounded-queue rejection; and `queued` requires that exact session to buffer the prepared draft. Terminal after buffering does not rewrite `queued`. There SHALL be no retry, route retarget, cross-device rollback, secure-mailbox/peer claim, or independent send history.

#### Scenario: Storage is unavailable while uplink Events commit

- **WHEN** valid contiguous Events commit protocol sequence but cannot become durable rows
- **THEN** the bounded current-runtime window may present them as transient `Not recorded` rows
- **AND** store failure changes no connection, sequence, queue, token, timeout, or terminal decision

#### Scenario: Live callback ingress or window reaches a bound

- **WHEN** callback ingress would exceed 64 entries/20 MiB or projection would exceed 512 entries/32 MiB
- **THEN** callback admission remains constant-work, one saturating gap records rejected/displaced presentation values, and projection eviction occurs only on its executor
- **AND** no producer blocks, no Event is released under the callback lock, and no task/value accumulates per loss

#### Scenario: One selected target is no longer active

- **WHEN** a validated multi-target control draft reaches a target whose exact connection lost active ownership
- **THEN** that target receives `noLongerConnected` or `notActive` while other targets decide independently
- **AND** no new session is selected by route similarity and no delivery claim is made

#### Scenario: Same live key arrives with conflicting content

- **WHEN** a second observation reuses runtime/connection/direction/sequence with different Event content while the first key remains live or durable
- **THEN** the retained first Event remains, one bounded presentation-conflict marker is coalesced, and the duplicate does not replace it or make storage unavailable
- **AND** no durable or protocol outcome is changed

#### Scenario: Conflicting key returns after transient eviction during storage outage

- **WHEN** the first key was evicted, no durable row exists, and a later candidate reuses that key
- **THEN** the existing overflow diagnostic discloses the lost horizon and the later candidate may become the new bounded transient first
- **AND** no unbounded tombstone, global first-wins claim, or protocol mutation is introduced
