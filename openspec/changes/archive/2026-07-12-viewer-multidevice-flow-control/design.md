## Context

`viewer-application-foundation` established the native application, mandatory-TLS listener, bounded admission manager, and one immutable `ViewerAdmissionConnectionCore` per accepted connection. That core currently sends the Viewer Hello, decodes the App Hello, retains the negotiation result, and hands an opaque right to a placeholder owner that closes the same core. The SDK already implements the opposite side of hello acknowledgement, flow-policy acceptance, active Event validation, bounded queues, and dynamic policy updates.

This change must complete the Viewer side without creating a second byte callback, decoder, terminal gate, or transport owner. It must also distinguish three different limits: 32 admission connection owners protect listener ingress, 16 Viewer sessions protect product resources, and each session's queues and secure mailbox have their own count and byte limits.

The root package product `NearWireCore` already exposes the repository's `NearWireCore`, `NearWireTransport`, and `NearWireFlowControl` modules to the Viewer project. Existing shared types cover wire messages, negotiation, session codecs, Event records, bounded queues, token buckets, batching, and secure-channel admission. Viewer-specific policy, persistence, UI, and lifecycle remain in `Viewer`.

## Goals / Non-Goals

**Goals:**

- Retain at most 16 independent App owners across provisional attachment, policy negotiation, active transfer, and disconnecting cleanup, and close them deterministically.
- Complete the existing V1 handshake and exchange Events in both directions using bounded memory and negotiated rates.
- Make requested versus effective rates understandable and dynamically configurable per device.
- Preserve bounded logical-device correlation and local nicknames without treating peer-declared values as authenticated identity or persisting Event data.
- Surface enough session and queue telemetry for operators to understand rate limiting and drops.
- Demonstrate isolation: a silent, full, slow, invalid, or disconnecting device cannot stall another device.

**Non-Goals:**

- Event history, SQLite storage, search, filters, JSON export, timelines, renderer plugins, or performance charts.
- A general Viewer control composer, command history, templates, or arbitrary replay. This change exposes only an internal downlink Event seam for later UI work and tests.
- Reconnection replay, delivery acknowledgement, guaranteed delivery, App authentication, certificate pinning, or pairing-code secrecy.
- Background operation, multiple Viewer windows, a daemon, a cloud service, internet rendezvous, or a new transport.
- New Core or SDK public API, a wire-version change, or a second test script.

## Decisions

### 1. A Viewer session manager consumes the existing opaque handoff

`ViewerMultiDeviceSessionManager` conforms to `ViewerAdmissionHandoffOwning` and replaces `ViewerPlaceholderHandoffOwner` in live dependencies. The manager owns at most 16 entries across provisional attachment, policy negotiation, active operation, and disconnecting cleanup. Capacity is claimed synchronously during transfer and retained through exact handle cleanup, so the 17th handoff is rejected without creating a session task. Rejection returns `false`, allowing the admission owner to cancel the same handle and retain its admission slot through cleanup.

Every accepted handle still contains the original `ViewerAdmissionConnectionCore`. The core gains a one-time session attachment whose callbacks execute on that core's existing serial queue. Attachment exposes only immutable peer metadata, the App Hello, the prior negotiation result, validated frame input, bounded channel send admission, and terminal notification through Viewer-internal types. It does not expose `NWConnection`, `NWListener`, endpoint text, mutable decoder state, or a way to replace the callback. The core queue remains the sole executor for decoder, wire phase, policy transaction, sequence, and terminal state. Per-session business scheduling may prepare queue work independently, but it cannot become a second frame/protocol executor or receive an unbounded asynchronous frame stream.

Transfer is one synchronous, reentrant transaction. The session manager installs a provisional registry entry and retains the handle under its lock, releases that lock, and invokes the core attachment API. Because transfer begins inside the core's Hello callback, the API detects the core queue and attaches inline rather than calling `sync` recursively. It returns success only after the handler is installed, allowing a second frame coalesced after App Hello to continue through the same decoder. The manager then commits the provisional entry under its lock. If capacity, duplicate-route policy, attachment, terminal state, or shutdown prevents commit, it removes the provisional entry and returns `false`; admission retains cancellation and cleanup ownership. A provisional entry counts against the 16-slot bound.

No manager registry lock is held while invoking a core operation or callback that can re-enter the manager. Core-to-manager notifications capture immutable IDs, leave core mutation, and then enter the manager. Manager-to-core operations snapshot ownership under the manager lock, release it, and then enqueue on the core. A terminal event during transfer makes attachment or commit fail; attachment twice is invalid. No shared executor performs network waits or Event consumption for every device. Manager snapshots cross to `@MainActor` through a latest-only coalescer so bursts cannot create unbounded UI tasks.

### 2. Session identity separates a connection from a logical device

A connection receives an internal random connection ID and is the only authority for sending during its lifetime. A logical correlation key combines the peer-declared App installation ID and optional Bundle ID from `WireHello`. Those values, display name, version, alias, and nickname are unauthenticated correlation/presentation hints, never proof of App identity or authorization. A missing Bundle ID remains a valid distinct correlation key and does not inherit another application's Bundle-ID preference.

Only one negotiating, active, or disconnecting connection may claim a correlation key. A second live claim is rejected even under default automatic admission or optional approval; V1 has no authenticated continuity proof that could safely replace the healthy connection. Reconnection starts only after the old handle is terminal and its session slot is released. Downlink work is owned by the exact internal connection ID and epoch, is cleared or terminally dropped when that connection closes, and is never reassigned to a later connection that declares the same key. A later downlink send must be a new local submission against the newly selected live session.

After disconnection, the manager may retain a safe, in-memory recent row for 30 seconds: correlation key, nickname-derived presentation, last state, disconnect generation, and timestamp. It contains no Event payload, queue key, session epoch, pairing code, endpoint, certificate, or wire bytes and does not authenticate a reconnect. Recent rows are globally bounded to 64, do not consume the separate 16 live-session slots, and evict by oldest disconnect time with correlation-key tie-breaking. An owned or disconnecting connection is never eligible for recent-row eviction. A reconnect replaces its exact row.

One manager-owned replaceable wake targets the earliest recent-row deadline; there is never one task per row. A wake services at most 64 due rows and then schedules the next exact deadline. Reconnect and expiry are serialized: a successful handoff commit before the deadline removes the row, while failed attachment leaves it until its original deadline; at a sampled time equal to or later than the deadline, expiry wins and a later handoff starts from absent state. Late callbacks whose connection or disconnect generation no longer matches are ignored. A 16-session slot remains occupied through disconnecting state and is released only after exact handle cleanup.

| Current correlation state | Event | Result |
| --- | --- | --- |
| Absent or recent | First handoff | Reserve one provisional slot; successful attachment commit removes the exact recent row and enters negotiating. |
| Provisional | Attachment failure, terminal, or shutdown | Roll back the provisional registry entry; admission owns cancellation; preserve any unexpired recent row. |
| Provisional, negotiating, active, or disconnecting | Same-key handoff | Reject the new handle without changing the owned connection or its downlink queue. |
| Negotiating | Conservative initial acceptance before deadline | Enter active if the manager is live; otherwise terminal cleanup wins. |
| Negotiating or active | Terminal or User Disconnect | Enter disconnecting, clear connection-owned queues, close the handle, and create at most one recent row only after cleanup. |
| Recent | Wake at or after exact deadline | Remove only a row whose disconnect generation and deadline still match. |
| Any state | Manager shutdown | Close transfer, remove all recent rows, mark all owned entries disconnecting, prevent new rows, and retain slots until cleanup. |

Shutdown completion requires zero provisional/live/disconnecting owners, recent rows, and expiry-wake ownership.

### 3. Viewer completes the protocol handshake before declaring a session active

For each accepted handoff, Viewer creates a fresh random `SessionEpoch`. One non-resetting 10-second monotonic initial deadline starts immediately before Viewer attempts to encode and admit the `WireHelloAcknowledgement` and initial `WireFlowPolicyOffer`. It includes local atomic mailbox admission and peer response time, does not wait for send completion, and is never reset by progress. Encoding or mailbox admission failure closes immediately. The App must respond before the deadline with one compatible `WireFlowPolicyAccepted`. Each accepted direction must be finite, protocol-valid, and no greater than the corresponding Viewer offer. The possibly lower accepted pair becomes effective; Viewer never displays its request as effective before acceptance.

The session becomes active only after both initial frames have entered the bounded mailbox and a conservative acceptance has been validated. V1 has no policy generation or nonce, so correlation relies on one pending offer plus ordered stream phase. Acceptance without an offer is an observable repeat and closes. While an offer is pending, any protocol-valid pair no greater than that offer is attributed to the current transaction and becomes effective, even if a malicious peer semantically intended it as a duplicate of an earlier lower acceptance; V1 cannot distinguish those meanings. Escalation, unexpected lane/message/phase input, timeout, encoding failure, or terminal transport state closes only that session.

Dynamic changes are ordered. Immediately before encoding and admitting each offer, Viewer starts a new non-resetting 10-second monotonic deadline. At most one offer is in flight. User edits during a pending offer retain only the latest validated desired pair. A valid conservative acceptance changes effective values for exactly the current offer, then sends the latest desired pair only if it still differs; the acceptance cannot directly activate the later edit. Atomic offer admission failure or timeout closes the session. A zero effective direction pauses business Event movement but not Control messages, terminal cleanup, expiry service, or telemetry observation.

The core serial queue and the frame-completion receipt sample define the winner. Acceptance is valid only when its frame sample is earlier than the deadline; equality is timeout. Acceptance-first commits once and makes a later timeout callback stale. A timeout callback normally selects terminal once, but it SHALL NOT invalidate an already-owned decoder suffix whose completion sample is earlier than that policy deadline. Instead it records `deadlineElapsed`, keeps receive paused, and lets the finite same-core continuation classify already-complete frames in that suffix without resetting or extending the deadline. A matching pre-deadline acceptance may then commit. If no complete frame remains—whether the decoder is drained or holds only a partial tail—or if a policy/protocol violation appears first, the recorded timeout closes exactly once, clears any partial bytes, and never resumes receive. A suffix sampled at or after the deadline receives no deferral. Physical transport terminal, explicit cancellation, and shutdown still win immediately and release the suffix because no live session can continue. A user edit only replaces desired state and cannot win a protocol terminal gate.

| Protocol state | Input | Result |
| --- | --- | --- |
| Attached | Initial frame preparation/admission succeeds | Enter initial-offer-pending with the already-started deadline. |
| Attached | Initial preparation/admission fails or deadline is reached | Close once and never become active. |
| Initial-offer-pending | Conservative acceptance before deadline | Commit accepted effective values and enter active. |
| Active | Desired pair differs and no offer is pending | Start a deadline, admit one offer, and enter update-pending. |
| Update-pending | User edit | Replace only latest desired state. |
| Update-pending | Conservative acceptance before deadline | Commit only the offered effective pair, then offer latest desired state if still different. |
| No pending policy | Acceptance | Treat as an observable repeat and close once. |
| Any pending policy | Timeout with an owned pre-deadline suffix | Record elapsed, keep receive paused, and classify the finite suffix before timeout commit. |
| Any pending policy | Acceptance sampled at/after deadline, escalation, physical terminal, or shutdown | Select one terminal result and emit no later offer. |

### 4. Requested policy is persisted; effective policy is session state

The global defaults are 20 App-to-Viewer Events per second and 10 Viewer-to-App Events per second. Each direction accepts zero or the existing protocol-valid positive range. The requested pair for a route resolves in this order:

1. an in-memory session override selected for the current connection;
2. the most recent bounded preference for the App Bundle ID;
3. the global default.

Changing a connected device updates its session override and, when it has a Bundle ID, updates that Bundle-ID preference for later sessions. It does not modify the global default. Viewer-requested values are persisted; App-accepted effective values are not.

`ViewerDevicePreferences` uses an injected `UserDefaults`, wall-clock provider, and bounded versioned Codable records. It stores at most 256 Bundle-ID policies and 256 logical-route nicknames. On overflow it evicts the least-recently-used record with deterministic key tie-breaking. Invalid keys, nonfinite/invalid rates, oversized nicknames, decode failures, unknown schema versions, or impossible timestamps are ignored or repaired to safe defaults without rendering raw stored text as an error. A nickname is trimmed, limited to 80 Unicode scalar values, and excludes control characters. Preference mutation is serialized and never performed on a transport callback queue.

### 5. Each session has two bounded business Event queues

Viewer owns one downlink-send queue and one uplink-delivery queue per session. Each uses existing `BoundedEventQueue` with limits of 5,000 Events, 16 MiB accounted bytes, and the negotiated maximum single-Event size. Limits are validated against Core hard bounds and the negotiation result before active state. The downlink API supports normal delivery and keep-latest coalescing with a caller-supplied local key. Incoming wire Events have no remote queue key and enter the uplink queue as distinct priority-aware values.

Downlink Event creation uses a fresh Event ID, source Viewer installation ID, target App installation ID, current session epoch, next sequence, negotiated codec, and receiver-valid wire envelope only at transport admission time. Pending values belong to the exact internal connection and are never migrated by a correlation key. Viewer validates outbound type, Codable content, metadata, priority, TTL, and byte budgets before enqueue. It makes no delivery guarantee and reports only local acceptance.

Inbound Event handling validates the Event lane, source, target, session epoch, strict contiguous sequence, negotiated codec/schema, payload bounds, and receiver-local TTL before queue mutation. A frame's structurally and route-valid contiguous sequence range commits atomically after every record has a safe receiver-local deadline and before local expiry/queue policy. Every such received record consumes its sequence even if already expired, selected as the incoming overflow victim, or responsible for evicting another queued value. A malformed, wrong-route, noncontiguous, or deadline-overflowing frame closes without advancing any sequence. Expired input is summarized and never delivered to the UI/store sink. Uplink delivery uses a nonblocking session sink boundary that later persistence work can replace.

For downlink, preparation uses value copies and tentative contiguous sequences. One encoded Event or Event-batch frame is admitted atomically by one secure-mailbox call. Only successful mailbox ownership commits that frame's entire sequence range, exact queue removals, fairness credit, rate tokens, and dequeue telemetry. Admission failure commits none, so retry uses the same next sequence and queue entries. A drain may commit earlier whole frames before a later frame fails, but no frame has a partial admitted prefix. Keep-latest replacement, local expiry, route drop, or overflow before mailbox admission consumes no sequence. A successfully admitted frame consumes its sequences permanently even if later transport termination prevents peer receipt.

### 6. Rate pumps are event-driven and preserve Control capacity

Each session owns independent `EventTokenBucket` values for effective uplink delivery and downlink sending. The accepted App-uplink rate is also a cooperative sender contract enforced by a two-second ingress token bucket; an Event frame whose whole record count exceeds available tokens closes with `activeWorkLimitExceeded` before that frame commits sequence or queue state. At zero rate any business Event violates the contract. Downlink uses the existing 500 ms `EventBatchScheduler`; a due flush admits one bounded Event prefix to the secure mailbox. Uplink may deliver as tokens permit without network batching. Missed intervals are not replayed and no pump catches up in an unbounded loop.

Control frames, including policy and close messages, bypass business Event rates and business queues. The existing drop-summary message remains on its protocol-defined Event lane but is system telemetry that also bypasses business rate tokens and queues. Business Event mailbox admission reserves one Control message slot and a bounded Control byte allowance through the existing secure-channel reservation API. A full business mailbox therefore cannot prevent terminal or policy progress. System traffic remains bounded and may be coalesced: only one unsent local drop summary and one policy update are retained per session.

Active ingress separates hard retention/protocol limits from scheduling quanta. The total connection-owned input budget covers decoder partial/pending bytes plus the current synchronously delivered callback `Data` until that handler returns. With receive paused there is no active driver receive or second callback `Data`. The live default is 2 MiB and the hard maximum is 19 MiB. Overflow-safe configuration proves that the budget is at least one maximum legal encoded active frame plus twice the configured receive-chunk size, and remains coherent with negotiated Event size and the Core decoder hard limit before active mutation. Exceeding the total retained budget, one legal-frame/batch bound, the sender-contract bucket, or the system-message bucket closes with a closed local ingress/`activeWorkLimitExceeded` category before that offending whole frame commits.

Defaults per service turn are 64 completed frames, 512 Event records, and 32 system messages, with hard configurable maxima of 256, 2,048, and 128. One maximum legal Event batch must fit atomically within the configured record quantum; otherwise configuration fails before active state. Uplink publication, expiry, and scheduled queue service process at most 128 records per turn, with a hard maximum of 512. A separate system-message bucket permits 64 per second with a burst of 128, so one valid burst may take four default turns.

A platform-neutral internal Core decoder operation appends one bounded chunk, processes whole frames until the caller's turn decision says pause, and retains the ordered unconsumed frame/suffix inside the existing bounded decoder. Pause is a scheduling result, not a protocol error. `SecureByteChannel` also gains one internal generation-bound receive-pause token. The token may be claimed synchronously only while the current `.received` event handler is executing. If claimed, the channel does not rearm its driver receive after that handler returns. The connection core retains exactly one token with its decoder suffix and one continuation; it resumes the token exactly once only after the suffix drains. Failure to claim the token when pausing is terminal because receive ownership cannot be proven.

The connection core schedules at most one continuation on its same serial executor. Because the channel is not rearmed, no later receive callback or callback-ingress `Data` can exist or overtake. Earlier whole frames may remain committed, the paused frame and suffix remain uncommitted and charged, and a single Event batch is never split.

The bounded decoder result distinguishes `pausedOnCompleteFrame`, `needsMoreBytes`, and `drained`. Only `pausedOnCompleteFrame` keeps the token and schedules another turn. In the ordinary no-timeout path, if a continuation consumes every complete retained frame but leaves a partial next frame, `needsMoreBytes` preserves and charges those partial bytes, discards their old callback sample for frame-completion decisions, and resumes receive so a later callback can complete the frame with its later sample. The recorded-policy-timeout arbitration above is the explicit exception: partial-only or drained input without acceptance closes and never resumes. Before any permitted token resume, the core atomically clears its continuation flag and detaches the token from session state; an immediately completing driver callback therefore observes no stale token and may claim one fresh token if it pauses again. Ordinary drained input follows the same detach-before-resume rule.

Terminal, decoder failure, attachment rollback, channel cancellation, or shutdown invalidates the continuation, releases decoder bytes, and resolves an attached token exactly once without rearming. If resume wins first, it starts at most one new generation-matched receive and a later terminal cancels it; if terminal wins first, resume is a no-op. A stale resume from an older channel generation is always a no-op. Other channel consumers that never claim the token retain the existing eager-receive behavior.

Every received callback captures one injected monotonic receipt sample. A frame uses the sample of the callback whose bytes complete that frame; a frame completed within a retained suffix keeps that original sample across every continuation turn, while a frame fragmented across callbacks uses the later callback that completes it. That one frame-receipt sample governs sender/system token charging, receiver-local TTL origin, policy-deadline comparison, throughput buckets, and any other receive-time decision. Scheduling delay never changes it. Terminal and timeout callbacks remain ordered on the same core executor. Split-versus-coalesced equivalence is required only when tests assign the same receipt sample to the same completed frames; deliberately later split-callback samples may produce the defined later TTL/token/deadline outcome. Tiny-frame, drop-summary, or signal storms therefore yield fairly without making byte grouping at an equal receipt time observable.

There is no repeating timer. Queue mutation, token availability, batch deadline, policy deadline, Event TTL, recent-row expiry, or send completion computes the next relevant monotonic deadline. The owner schedules at most one replaceable one-shot wake per session, plus the manager's single recent-row wake. Receive/service work retains at most one scheduled continuation plus one coalesced need-to-continue bit. Each boundary services only the finite quantum, yields before continuation, and never immediately retries while a queue or mailbox remains blocked. An idle session owns no timer or polling task.

### 7. Drops and telemetry are explicit but bounded

Local queue expiry, overflow, route invalidation, and keep-latest replacement update cumulative saturating counters. Dropped/expired Events are aggregated into the existing bounded `WireDropSummaryPayload`; one coalesced pending summary is sent on its protocol-defined Event lane without consuming business rate tokens when mailbox capacity permits. Remote summaries update remote-drop telemetry and are never reflected back, persisted as Event history, or treated as acknowledgement.

`ViewerSessionSnapshot` contains only safe bounded presentation state: connection/session IDs, route alias, optional validated App metadata, state, requested/effective rates, queue count/bytes/oldest wait, cumulative enqueue/dequeue/drop/expire/coalesce values, remote drop totals, last terminal category, and approximate ingress/egress Events-per-second. Throughput uses fixed one-second monotonic buckets and bounded counters updated during real activity; it does not require a permanent timer. Snapshot publication is latest-only and rate-coalesced to UI turns.

Telemetry must never expose Event content, metadata values, pairing code, endpoints, TLS material, raw peer bytes, or arbitrary transport errors. Every new error, terminal category, description, debug description, reflection helper, interpolation, and log derives only from a closed local code and excludes Event type/content, metadata values, queue keys, installation/correlation/Bundle identifiers, nicknames, rates, queue values, session epochs, endpoint/certificate data, peer text, raw bytes, and underlying errors. Counter overflow saturates. Telemetry failure cannot terminate or block a session.

Event drafts, encoded payloads, queue keys, session epochs, and queue contents are absent from `UserDefaults`, logs, analytics, clipboard, exported data, UI state, and recent rows. Effective policy is absent from persistence, logs, analytics, clipboard, exported data, and recent rows but may appear in the bounded safe session snapshot. The final packaging evidence reassesses the Viewer privacy manifest: bounded preferences use the existing UserDefaults required-reason declaration, and the stable peer-declared identifier/nickname correlation is documented against the existing linked Device ID collection decision without adding a claim unless the built behavior requires it.

### 8. The first device workspace is operational but intentionally not an explorer

The main window retains the pairing and admission header. Its sidebar lists negotiating, active, disconnecting, and recently disconnected correlation rows with safe name, nickname, state, and rate/queue warning badges. A returning connection enters the ordinary negotiating state; there is no separate reconnecting state. The workspace explicitly labels App identity, installation alias, Bundle ID, nickname continuity, and recent-row presentation as unauthenticated hints. Selection is stable by correlation key only for presentation; it never authorizes or retargets Event delivery. The detail pane supports nickname editing and two Viewer-requested rate fields, shows effective rates separately, and presents queue depth/bytes/oldest wait, throughput, Event counts, and drop totals.

Rate editing validates locally, communicates whether a value is requested or effective, and disables mutation for a disconnected row. Accessibility labels and keyboard selection are covered. The view does not display an Event timeline, payload detail, search field, filter builder, persistence controls, JSON export, control composer, or performance chart; those remain later roadmap changes.

### 9. Lifecycle operations close only their intended ownership

Pause New Devices and ordinary pairing refresh continue to preserve handed-off sessions exactly as defined by the foundation. A per-device Disconnect action closes only the selected session. Window close, application termination, identity reset, or future explicit Disconnect All closes session transfer first, cancels all owned cores independently, and waits for their cleanup through the existing application cleanup receipt. The manager never releases a handle early merely to satisfy the one-second UI wait.

One blocked device cannot delay another device's protocol, queue, telemetry, or cancellation work. Manager shutdown may await all independent cleanup tasks, but each session keeps its own transport cancellation and terminal gate. Late callbacks after rejection, disconnection, recent-row replacement, or runtime generation change are ignored by connection/session/disconnect generation.

## Risks / Trade-offs

- **Extending the admission core could accidentally create two protocol owners.** The attachment is one-time and runs through the same serial queue, decoder, channel, and terminal gate; tests reject callback or decoder replacement.
- **Sixteen sessions can multiply queue memory.** Count and byte limits are per session, session count is finite, queue contents are value-owned, and tests measure the exact aggregate bound rather than assuming typical traffic.
- **Dynamic rates can race active pumping.** One offer is in flight, desired policy is latest-only, and effective buckets change only after matching acceptance.
- **V1 has no policy transaction identifier.** Viewer detects an acceptance only by whether one offer is pending and whether values are conservative; semantic duplicates that satisfy a later offer are intentionally attributed to that later transaction until a future wire version adds a nonce.
- **Peer-declared identity can spoof continuity.** A live duplicate is rejected, every identity hint is labeled unauthenticated, and old downlink work is never reassigned to a later connection.
- **Control bypass can become an unbounded side channel.** Control values remain schema-bounded, mailbox-bounded, and coalesced; Event sends always reserve Control capacity.
- **TCP callback grouping is nondeterministic.** Hard byte/protocol/token bounds still close abusive input, while valid extra frames pause in the bounded decoder and resume on one ordered same-core continuation so split and coalesced delivery are equivalent.
- **UserDefaults is not a database.** Only small bounded preferences and nicknames are stored. Event data and effective session state await the dedicated local-store change.

## Migration Plan

This is the first active Viewer session implementation. Existing approval preferences and Keychain identities remain unchanged. New preference data uses separate versioned keys and safe defaults, so rollback can ignore it. Rolling back restores the placeholder handoff owner and empty workspace without changing wire compatibility or deleting identity data.

## Open Questions

None for this change. Event persistence/exploration, Viewer control composition, and performance dashboards remain explicitly assigned to later roadmap changes.
