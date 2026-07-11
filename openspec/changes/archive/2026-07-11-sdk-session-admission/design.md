# SDK Session Admission Design

## Context

The current repository intentionally separates discovery, transport, wire validation, SDK buffering, and process ownership:

- `ViewerDiscoveryCoordinator` returns one bounded `DiscoveredViewer` but establishes no trust or connection.
- `SecureAppTransport` creates a peer-to-peer-enabled TLS 1.3 channel with connection-local self-signed certificate validation and no plaintext fallback.
- `WirePreHandshakeCodec` exchanges only hello, safe error, and disconnect before a negotiation result exists.
- `WireSessionCodec` admits only messages valid for the negotiated version, capabilities, and current phase.
- `ProcessConnectionLeaseRegistry` exists, but the roadmap assigns its claim to the later supported public-connect orchestrator.
- `NearWire` already has internal incoming-publication and outbound-drain seams, but the roadmap assigns their use to the later active event pump.

This change composes only App-side session admission. The Viewer application does not exist yet; tests use deterministic discovery and secure-channel seams plus the already validated real TLS transport integration.

## Goals and Non-Goals

Goals:

- Produce one live, validated, internally owned App-to-Viewer session from one explicit run.
- Make discovery, TLS readiness, hello exchange, identity consistency, negotiation, and Viewer acknowledgement one fail-closed state machine.
- Reject Event lane at the streaming lane boundary before retaining its payload while the session is pre-active.
- Bound callback ingress, partial framing, complete handshake frames, cumulative handshake bytes, post-acknowledgement Control backlog, timers, and retained identities.
- Preserve exact cancellation, timeout, terminal-error, and late-callback behavior under synchronous and concurrent races.
- Keep the admitted route and channel available to the next event-pump change without a receive gap.

Non-goals:

- Supported `connect`, `disconnect`, or new public errors and state transitions.
- Process lease claim or release.
- Flow-policy offer/acceptance completion, token buckets, batching, sequence allocation, Event encode/decode, queue drain, or incoming event publication.
- Retry, reconnection, background lifecycle, persistence, certificate pinning, mutual TLS, Keychain access, Viewer implementation, UI, logging, or telemetry.

## Decisions

### 1. Use one explicit internal one-shot admission object

`SDKSessionAdmission` is an internal actor constructed from a validated `PairingCode`, a validated local `WireHello`, immutable internal limits, and production dependencies. Construction creates no Task, timer, browser start, permission request, connection, lease claim, or channel.

Before discovery, the first `run()` requires the local hello to have the App role and revalidates its complete model by encoding it once through `WirePreHandshakeCodec` using the admission's exact `WireProtocolLimits`. This rechecks its advertised event limit, collections, text, role, and fixed bootstrap representation even if the value was originally constructed under broader limits. The same limits construct the pre-handshake decoder, frame decoder, and negotiated `WireSessionCodec`.

Admission also encodes the largest V1 pong (`UInt64.max`) with those limits and validates the exact `SecureTransportLimits` before discovery. Maximum single-send bytes must fit both the cached hello and maximum pong; pending-send count must be at least two; and pending-send bytes must fit their overflow-checked sum. Two slots are required because a peer may receive hello and send ping before the local send-completion callback retires hello. Any model, encoding, or cross-limit failure occurs before a browser, deadline, endpoint, or channel exists. Validated hello bytes are cached only until secure-channel admission takes ownership; the maximum pong bytes are used only for validation and then released.

One explicit `run()` performs the operation once. A second run fails without replacing the first waiter. Cancel before run becomes terminal without starting a dependency. Task cancellation and explicit internal cancellation use the same terminal path.

The production dependency path creates `NWBrowserDiscoveryDriver`, `ViewerDiscoveryCoordinator`, `SecureAppTransport`, and a `ContinuousClock` deadline only when their stage begins. Test dependencies remain internal, bounded, Sendable, and absent from supported or SPI API.

### 2. Keep a closed monotonic state machine

Terminal authority is never shared. `SDKSessionAdmission` owns local validation, `idle`, `discovering`, the discovery deadline, and discovery cancellation only. On one exact match it cancels the discovery deadline, creates one opaque attempt token and transport core, records a transferred state, and transfers attempt authority exactly once. From `connecting` onward, only `SDKSessionTransportCore` owns the result waiter, secure and attachment deadlines, protocol phase, terminal state, ingress, and channel cancellation.

Admission/task cancellation after transfer is only a tokenized request forwarded to the core. The core linearizes it with channel input. On successful acknowledgement commit, the core invalidates the attempt token before resuming the result waiter; a late forwarded task-cancellation request bearing that token is ignored and cannot cancel an admitted session. After commit, only the shared admitted-handle cancellation relay may cancel the core. The admission actor may record that `run()` returned, but it performs no channel or terminal work.

The states and their single authority are:

| State | Authority | Owned work | Accepted progress |
| --- | --- | --- | --- |
| `idle` | Admission actor. | Immutable input only. | First `run()` or cancel. |
| `discovering` | Admission actor. | One discovery operation and one discovery deadline. | Exact match, discovery failure, timeout, or cancellation. |
| `transferred/connecting` | Transport core. | Attempt token, result waiter, channel, ingress, secure deadline. | TLS preparing/ready, terminal transport, timeout, or tokenized cancellation. |
| `exchangingHello` | Transport core. | Ready channel, one frame decoder, local hello bytes sent once. | One Viewer hello, safe terminal control, timeout, or cancellation. |
| `awaitingApproval` | Transport core. | Negotiation result and negotiated session codec. | Exact acknowledgement, rejection, bounded ping/pong, safe terminal control, timeout, or cancellation. |
| `admitted` | Transport core. | Channel, codec, route, bounded flow-policy backlog, cumulative handoff budget, attachment deadline, and at most one pull waiter. External handles alone share the cancellation relay. | Exactly one pump attachment, policy pull, terminal input, attachment timeout, or handle cancellation. |
| `failed` | Current stage authority. | No live discovery, timeout, ingress, frame, or channel work. | Late input ignored. |
| `cancelled` | Current stage authority. | Same cleanup as failed. | Late input ignored. |

Every transition is isolated by its sole authority. Transfer occurs once before the channel exists. Before transfer the admission actor orders outcomes; after transfer the core actor orders outcomes. No callback, timeout, cancellation, or second run may revive a terminal attempt or complete a waiter twice.

### 3. Bind discovery metadata to the Viewer hello without overstating trust

Discovery returns an exact pairing-code instance name and public 64-bit `vid` discriminator. After the Viewer hello is fully decoded, admission requires its role to be Viewer and derives `ViewerDiscoveryDiscriminator` from the exact hello installation ID. That value must equal the discovered value before `WireNegotiator` runs.

Mismatch is a terminal `viewerIdentityMismatch` admission error. The discovered service identity and remote hello metadata are then released; the admitted result retains only the negotiated Viewer ID and route values needed by the session.

This check detects accidental advertisement/hello disagreement. It does not authenticate the Viewer, bind the TLS certificate, prove one physical publisher, prevent spoofing, or provide continuity across connections. The V1 TLS model remains encrypted but connection-local and non-pinned.

### 4. Add early lane preflight to the incremental frame decoder

`WireFrameDecoder.consume` gains a synchronous, non-retained lane-preflight closure. For each frame it runs exactly once after the prefix, known lane byte, and lane-specific declared-size check, but before payload storage reservation or payload-byte copy. A thrown `WireProtocolError` becomes the decoder's terminal connection error; another thrown error becomes a safe terminal decoder error. Existing callers receive an allow-all default and preserve behavior.

Session transport supplies phase-aware preflight. Event lane is rejected while phase is `preHandshake`, `awaitingApproval`, or `negotiatingPolicy`, so a hostile Event frame cannot make the admission layer retain its declared payload. A later active event pump may allow Event lane only after it owns the same transport and has completed policy activation.

The closure executes synchronously inside the owning session actor, is never stored, and cannot schedule work or receive payload bytes.

### 5. Use one permanent transport core and bounded callback edge

After discovery and before channel construction, admission creates one long-lived `SDKSessionTransportCore` actor and one private lock-protected `SDKSessionChannelIngress`. The secure channel's immutable event handler permanently targets the ingress; it is never redirected to the admission actor, admitted handle, or event pump. The core exclusively owns phase, terminal state, frame decoder, channel, budgets, backlog, and pump-attachment state from TLS setup through later active-pump ownership.

The core strongly owns channel and ingress. The ingress drain callback refers weakly to the core, while each scheduled drain temporarily retains it only for that one bounded drain. Channel handler strongly retains only ingress. This prevents `core -> channel -> handler -> core` and `core -> ingress -> core` cycles. Releasing the admission actor after success cannot stop callbacks because `SDKAdmittedSession` retains the core.

The ingress retains at most one scheduled drain, a fixed number of events, and a fixed cumulative number of receive bytes. State changes may be coalesced only when doing so preserves terminal and ready ordering. A terminal channel event latches, discards pending nonterminal work, and prevents later admission. Byte or event overflow latches one safe overflow terminal instead of dropping stream bytes.

The transport core owns one `WireFrameDecoder` continuously from TLS readiness through acknowledgement and later handoff. It does not decode each receive chunk independently. Fragmented and coalesced frames therefore preserve order, and an acknowledgement followed by policy Control data in the same chunk is handled without a receive gap.

Before acknowledgement, cumulative frame/work count and encoded bytes have independent hard bounds in addition to wire frame limits. Incoming complete frames and generated pong responses both consume these budgets. Limit exhaustion is terminal even when every individual frame is valid.

### 6. Enforce one exact wire sequence

After TLS reports ready, App hello is encoded through `WirePreHandshakeCodec` and admitted to the channel exactly once. Incoming messages follow this table:

| Phase | Message | Behavior |
| --- | --- | --- |
| `preHandshake` | Viewer hello | Validate model and Viewer role, bind `vid`, negotiate, create `WireSessionCodec`, move to awaiting approval. |
| `preHandshake` | error or disconnect | Fail with a fixed safe terminal category; discard remote text. |
| `preHandshake` | anything else | Terminal protocol violation from the sealed codec. |
| `awaitingApproval` | exact hello acknowledgement | Validate against the negotiation result, create route, and admit. |
| `awaitingApproval` | connection rejected | Fail as `viewerRejected`; discard untrusted code and message from diagnostics. |
| `awaitingApproval` | ping | Encode and admit one matching pong, count the frame against the handshake budget, and continue. |
| `awaitingApproval` | pong | Ignore after validation, count it, and continue. |
| `awaitingApproval` | error or disconnect | Fail with a fixed safe terminal category. |
| `awaitingApproval` | duplicate hello, policy, Event, unknown, or invalid payload | Terminal protocol violation. |

`WireNegotiator` must select a registered V1 session codec. Future-version selection fails before acknowledgement. Acknowledgement must exactly match version, codec, event limit, capabilities, policies, Viewer installation ID, and a syntactically valid peer-supplied session epoch. No acknowledgement field may escalate or substitute the negotiated result. V1 has no nonce, persistence, or prior-epoch store, so admission does not prove epoch freshness or prevent a malicious peer from replaying a previously observed syntactically valid epoch.

The admission layer emits no best-effort protocol error after a terminal decode because immediate cancellation could discard or ambiguously transmit it. It closes the channel and returns only a local safe error.

### 7. Return one handle to the permanent owner at policy-negotiation phase

Success returns internal `SDKAdmittedSession`, a redacted final handle retaining the same `SDKSessionTransportCore`, with access to:

- the exact `SDKSessionRoute` derived from acknowledgement epoch, negotiated Viewer ID, and local App ID;
- the negotiated `WireSessionCodec`, capabilities, policies, and event limit;
- exclusive core ownership of the live `SecureByteChannel`, ingress, and continuous frame decoder without callback retargeting;
- protocol phase `negotiatingPolicy`;
- a bounded FIFO of already admitted post-acknowledgement flow-policy Control messages received in the same or later callback before the event pump attaches.

At `negotiatingPolicy`, flow-policy offer/acceptance may enter the bounded handoff, ping receives pong, pong is ignored, and error/disconnect terminates the owner. Event lane remains rejected before payload buffering. Every decoded Control frame and generated pong consumes a cumulative pre-active handoff work count and encoded-byte budget, including messages that are answered or discarded rather than retained. Backlog count/bytes and cumulative work count/bytes are independently bounded; any overflow cancels the session.

Acknowledgement is provisional until the core finishes the entire receive chunk that completed it. Valid later policy Control frames from that same chunk enter the handoff. A later disconnect, error, malformed frame, duplicate acknowledgement, or other terminal/invalid frame in that same chunk fails admission and returns no handle. Only after the whole acknowledgement-containing chunk completes without terminal input does the core atomically commit admitted state and resume `run()`. A separately delivered later terminal event may, as with any live connection, terminate the already returned owner.

`SDKAdmittedSession.attachEventPump()` is actor-linearized and succeeds exactly once. It returns a redacted attachment handle to the same core rather than moving state or installing a callback. Only admitted flow-policy offer/acceptance messages enter the core FIFO. Ping is answered, pong is discarded, and error/disconnect terminate outside the FIFO. Already buffered flow-policy messages remain ahead of every later flow-policy message. A call after terminal state reports the fixed terminal category, a second attachment fails, and callbacks racing attachment are ordered by the core actor with no gap, duplicate flow-policy delivery, or old owner.

The attachment exposes one actor-isolated asynchronous `nextPolicyMessage()`. Before entering its task-cancellation handler, each call creates one private lock-protected `SDKSessionPullCancellationGate`. The handler's `onCancel` synchronously latches cancellation in that gate, including for an already-cancelled task. Core registration atomically claims the gate before storing any continuation: a previously latched cancellation makes registration fail immediately with `pullCancelled`; otherwise the gate installs one tokenized cancellation notification to the core.

Registration uses exact precedence: a pre-latched per-call cancellation returns `pullCancelled` before inspecting terminal state, FIFO contents, or another pending pull. Otherwise a stored terminal code wins, then a second pending pull returns `pullAlreadyPending`, then a nonempty FIFO returns immediately, and only then may an empty FIFO install the waiter.

An immediate outcome closes the gate before returning. An empty FIFO stores exactly one tokenized checked continuation plus its claimed gate. A future flow-policy message closes the pending gate before resuming the waiter directly instead of also enqueuing it. Cancellation after registration latches synchronously and submits its token to the core; if still pending, the core removes the waiter, closes the gate, and resumes with `pullCancelled` without terminating the session. Terminal state closes the gate before resuming a pending pull once with the exact stored terminal code. The core retains a gate only while that pull is pending. Message, cancellation-before-registration, cancellation-after-registration, immediate return, terminal, and final-handle races produce one outcome and retain no completed gate or continuation.

When acknowledgement commits, the core cancels the secure-admission deadline and starts one bounded pump-attachment deadline. Failure to attach terminates the channel. Cumulative handoff budgets remain active until the later event-pump change completes policy activation, even after attachment, so a delayed or stalled consumer cannot sustain unbounded ping/pong work.

No raw frame, pairing code, discovered service identity, remote display metadata, endpoint description, certificate object, or application event is exposed by the result. The result has fixed redacted description, debug description, reflection, and interpolation. It is internal and non-Codable.

The admitted handle and pump attachment share one lock-protected nonisolated `SDKSessionCancellationRelay`. Only these external handles retain the relay; the relay strongly retains the core, and the core explicitly does not retain the relay. Explicit cancellation and relay deinitialization request cancellation through the same exact-once gate. The first request schedules at most one bounded Task to the core; the core closes ingress, resumes any pending pull with `cancelled`, clears decoder/backlog, and cancels the channel once. Dropping the admission handle after successful attachment leaves the relay and core alive through the pump handle. Dropping the final external handle deinitializes the relay and requests cancellation once. An already-terminal core treats that final request as a no-op. The future public connection lifecycle remains responsible for coupling this cancellation with exact process-lease release.

### 8. Use concrete validated resource limits

Internal `SDKSessionAdmissionLimits` uses this table:

| Limit | Default | Hard maximum | Required relationships |
| --- | ---: | ---: | --- |
| discovery timeout | 30 s | 120 s | Positive. |
| secure-admission timeout | 15 s | 120 s | Positive and no shorter than the configured transport connection timeout. |
| pump-attachment timeout | 5 s | 30 s | Positive. |
| ingress retained events | 64 | 256 | Positive. |
| ingress retained receive bytes | 256 KiB | 1 MiB | At least one configured transport receive chunk. |
| pre-ack work items | 32 | 128 | Counts every incoming complete frame and generated pong. |
| pre-ack encoded work bytes | 256 KiB | 1 MiB | At least one maximum Control frame under the active wire limits. |
| pre-active handoff work items | 64 | 256 | Counts every post-ack Control frame and generated pong, retained or not. |
| pre-active handoff work bytes | 512 KiB | 1 MiB | At least one maximum Control frame under the active wire limits. |
| retained handoff messages | 32 | 128 | No greater than handoff work items. |
| retained handoff encoded bytes | 256 KiB | 1 MiB | No greater than handoff work bytes. |

Every addition is overflow-checked. Byte ceilings include the complete four-byte prefix, lane byte, and payload for incoming or generated frames. Limits cannot exceed Core frame hard maxima, widen the supplied `WireProtocolLimits` or `SecureTransportLimits`, or admit a configuration in which one valid configured Control frame or receive callback cannot fit its corresponding budget.

Before dependency start, the cached local hello and maximum V1 pong must each fit `maximumSingleSendBytes`; `maximumPendingSendCount` must be at least two; and their sum must fit `maximumPendingSendBytes`. Runtime backpressure after these checks is a terminal transport failure rather than a configuration fallback.

### 9. Bound stage deadlines and cleanup

At most one deadline Task exists for discovery, secure admission, or unattached admitted handoff. Moving stages cancels and releases the old deadline before starting the next. Pump attachment cancels the attachment deadline. Failure or cancellation clears the waiter, timeout, ingress, decoder partial bytes, handshake/backlog messages, local/remote hello metadata, discovery result, and duplicate endpoint references, then cancels discovery or channel at most once as applicable.

The permanent core deliberately retains the live channel and decoder for the next change. Explicit cancellation and last-handle defensive cancellation release the bounded handoff. The future public connection lifecycle remains responsible for coupling this cancellation with exact process-lease release.

### 10. Keep errors closed and content-safe

`SDKSessionAdmissionError` is the single internal, Equatable, Sendable, code-only error used by `run()`, `attachEventPump()`, attachment pulls, and stored core terminal state. Its exhaustive mapping is:

| Source | Exact code |
| --- | --- |
| invalid local role, hello revalidation/encoding, admission-limit relation, or outbound hello/pong capacity | `invalidLocalConfiguration` |
| second admission run | `alreadyStarted` |
| explicit/task cancellation before commit, last-handle relay cancellation, or expected channel cancellation | `cancelled` |
| discovery deadline | `discoveryTimedOut` |
| discovery policy denial | `discoveryDenied` |
| discovery unavailable terminal | `discoveryUnavailable` |
| multiple exact Viewer registrations | `discoveryAmbiguous` |
| result limit, browser start/failure, or other discovery failure | `discoveryFailed` |
| secure-admission deadline | `secureAdmissionTimedOut` |
| pump-attachment deadline | `pumpAttachmentTimedOut` |
| unexpected channel failure, EOF before a remote close message, or send/backpressure failure | `transportFailed` |
| callback event/byte bound | `ingressOverflow` |
| malformed frame/JSON/payload, wrong phase/lane/type, acknowledgement escalation, or invalid ordering | `protocolViolation` |
| role/version/codec/policy incompatibility or unregistered selected codec | `incompatiblePeer` |
| advertisement/hello discriminator mismatch | `viewerIdentityMismatch` |
| valid connection rejection | `viewerRejected` |
| valid remote error or disconnect | `remoteClosed` |
| pre-ack cumulative work count/bytes | `handshakeWorkLimitExceeded` |
| post-ack cumulative work count/bytes | `handoffWorkLimitExceeded` |
| retained handoff count/bytes | `handoffBufferOverflow` |
| second pump attachment | `alreadyAttached` |
| second concurrent empty-FIFO pull | `pullAlreadyPending` |
| cancellation of the one pending pull | `pullCancelled` without terminating the session |
| attachment or a non-pre-cancelled pull after any stored terminal outcome | the exact stored terminal code above |

Last-handle deinitialization has no waiter to throw into; it stores `cancelled` in the core and uses the same cancellation relay. A stale admission-attempt cancellation token after successful commit is ignored and produces no error or session transition.

Descriptions and reflection are computed from the code only for admission, attachment, and terminal-owner use. They contain no pairing code, instance name, `vid`, endpoint, interface, Viewer/App installation ID, Bundle ID, product/display metadata, certificate, fingerprint, raw Network error, remote rejection/error/disconnect text, wire bytes, or application content. Mapping from discovery, transport, and wire errors is exhaustive and discards underlying descriptions.

### 11. Preserve the supported SDK and ownership boundaries

This change adds no supported or SPI SDK declaration. Normal SwiftPM and CocoaPods consumers cannot name admission, admitted-session, ingress, timeout, error, route-owner, or dependency-seam types. CocoaPods same-module compilation must preserve the same non-SPI supported inventory as SwiftPM.

`SDKSessionAdmission` does not call `ProcessConnectionLeaseRegistry`. The later public-connect orchestrator must claim first, retain its exact handle alongside the admitted owner, and release on every terminal lifecycle path. This change also does not mutate `NearWire` state, drain its queue, publish incoming events, negotiate rates, or transfer Event messages.

## Race and Failure Precedence

| Race | Required outcome |
| --- | --- |
| cancel vs discovery match | First actor-processed terminal/progress outcome wins; no second completion; matched endpoint is released on cancel. |
| discovery timeout vs match | First actor-processed outcome wins; old deadline token cannot affect the secure stage. |
| cancellation at discovery-to-core transfer | Admission either cancels discovery before transfer or forwards the one attempt token; only the core can terminate after transfer. |
| TLS ready vs terminal transport | Latched terminal ingress clears pending nonterminal ready work and admission fails. |
| acknowledgement bytes vs terminal transport | A terminal event already latched at ingress wins over queued bytes; otherwise actor order decides and any later terminal owns the admitted session state. |
| acknowledgement plus later frame in one chunk | Acknowledgement remains provisional; valid policy data is buffered, but terminal or invalid later data fails admission before any handle is returned. |
| explicit cancel vs stage timeout | First terminal state wins; discovery/channel cancel occurs at most once. |
| ingress overflow vs later valid acknowledgement | Overflow wins and no acknowledgement result is returned. |
| callback vs pump attachment | The permanent core actor orders both; attachment installs no callback and every handoff-eligible flow-policy message stays in the same FIFO exactly once. |
| last admitted handle release vs explicit cancel | One cancellation relay request wins and schedules at most one core cancellation Task. |
| policy frame vs empty-FIFO pull | The core either installs the waiter first and resumes it directly or enqueues the frame first for immediate pull; never both. |
| pull cancellation before registration | The synchronous gate remains latched; core registration returns `pullCancelled` without installing a waiter. |
| pull cancellation vs policy frame/terminal | The gate and core close once; the core resumes one winning outcome and ignores every stale pull token. |
| late task cancellation after handle commit | The invalidated attempt token is ignored; only the admitted cancellation relay can terminate the session. |
| late callback after failure/admission cancellation | Ignored and retains no bytes, endpoint, or identity. |

## Test Strategy

- Pure frame tests prove lane preflight happens after the lane bound but before payload reservation/copy, once per fragmented/coalesced frame, and becomes terminal on failure.
- Admission happy paths cover local hello revalidation before dependency start, fragmented/coalesced hello and acknowledgement, App hello exactly once, exact `vid` binding, V1 negotiation, route construction, capabilities/policies, and continuous post-acknowledgement Control handoff.
- Protocol tests cover wrong role, discriminator mismatch, incompatible versions/codecs/policies, future codec selection, acknowledgement escalation/substitution, rejection, safe error, disconnect, ping/pong, duplicate/out-of-order messages, early Event header, malformed JSON, oversized frame, partial EOF, frame/byte budgets, and backlog overflow.
- Lifecycle tests cover construction side effects, second run, cancel before each stage, exact discovery-to-core authority transfer, task cancellation before/during/after transfer and after handle commit, all three deadlines, synchronous/reentrant callbacks, provisional acknowledgement with valid and invalid coalesced suffixes, terminal priority, callback/attachment races, empty/immediate/concurrent/terminal pull behavior, pre-cancelled pull combined with terminal/FIFO/existing waiter, cancellation before registration, cancellation after immediate return, final-handle teardown with a pre-cancelled pull, admission-handle release after attachment, final pump-handle release, late callbacks, explicit and already-terminal final cancellation, deinitialization/retention shape, and exact one-shot discovery/channel cancellation.
- Budget tests cover each default, hard ceiling, cross-limit relationship, undersized single-send/count/byte capacity before dependency start, overflow, ping/pong storms before and after acknowledgement, delayed or absent pump attachment, and draining sends that never let instantaneous ingress/backlog bounds fill.
- Error tests cover every source-to-code row, stored-terminal attachment result, second attachment, last-handle cancellation, code-only rendering, and stale cancellation-token silence.
- Security tests prove diagnostics and reflection omit every sensitive or untrusted input and that the admitted result retains no duplicate discovery metadata.
- Packaging tests prove iOS 16 Swift 5 mode, macOS Core compatibility, SwiftPM/CocoaPods parity, unchanged supported API, no new dependency/product/subspec, and no process-lease call or Event transfer.
