## ADDED Requirements

### Requirement: Session admission is one explicit internal operation

The SDK SHALL provide one internal App-side session-admission actor constructed from a validated pairing code, a validated local App hello, immutable validated limits, and fixed production dependencies. Construction SHALL start no browser, permission request, connection, channel, Task, timer, process-lease claim, persistence, Keychain access, state publication, or Event transfer. One explicit `run()` SHALL perform at most one discovery and one secure admission attempt. A second run or cancel-before-run SHALL be deterministic and SHALL NOT start or replace work.

Before discovery, `run()` SHALL require the App role and revalidate the complete local hello by encoding it through `WirePreHandshakeCodec` with the admission's exact `WireProtocolLimits`. The same limits SHALL construct pre-handshake, framing, and negotiated-session codecs. Admission SHALL also encode the maximum-nonce V1 pong and require both cached hello and pong to fit `SecureTransportLimits.maximumSingleSendBytes`, require at least two pending-send slots, and require their overflow-checked sum to fit pending-send bytes. Revalidation, encoding, or cross-limit failure SHALL start no dependency.

Production admission SHALL compose exact pairing discovery with `SecureAppTransport` and therefore SHALL use only `_nearwire._tcp` in the local domain, peer-to-peer-enabled Network.framework routing, ordered TCP, TLS 1.3, and `nearwire/1` ALPN. It SHALL expose no plaintext, arbitrary endpoint, service type, TLS, or certificate override.

#### Scenario: Internal run begins

- **WHEN** a valid internal admission is explicitly run once
- **THEN** discovery begins before any connection is constructed
- **AND** exactly one secure App channel is constructed only from the matched interface-neutral endpoint

#### Scenario: Construction remains idle

- **WHEN** an admission value is constructed but not run
- **THEN** it starts no discovery, permission, network, Task, timer, lease, persistence, or SDK state work

#### Scenario: Local hello was validated under broader limits

- **WHEN** the supplied hello violates the exact admission wire limits
- **THEN** admission fails before discovery, deadline, endpoint, or channel creation

### Requirement: Admission follows one bounded fail-closed state machine

Admission SHALL transition only through idle, discovering, connecting, exchanging hello, awaiting approval, and admitted, or to failed/cancelled. `SDKSessionAdmission` SHALL be sole authority only through validation and discovery. On exact match it SHALL cancel the discovery deadline and transfer one opaque attempt token and result waiter exactly once to `SDKSessionTransportCore`. From connecting onward, only the core SHALL own secure/attachment deadlines, protocol and terminal state, waiter completion, ingress, and channel cancellation.

Cancellation after transfer SHALL be a tokenized request forwarded to the core and ordered there with channel input. A successful acknowledgement commit SHALL invalidate that token before waiter resumption, so late task cancellation SHALL NOT cancel an admitted session. Only the shared admitted-handle cancellation relay may cancel after commit.

TLS readiness SHALL precede exactly one App hello send. The first successfully decoded remote pre-handshake message SHALL be exactly one Viewer hello. The SDK SHALL then bind discovery identity, negotiate a registered V1 session codec, enter awaiting approval, and accept only an exact hello acknowledgement, bounded ping/pong, safe error, disconnect, or connection rejection according to the registered phase rules.

An exact acknowledgement SHALL match the negotiated version, codec, maximum event bytes, capabilities, policies, Viewer installation ID, and a syntactically valid peer-supplied session epoch. V1 admission SHALL NOT claim epoch freshness or replay prevention because it has no nonce, persistence, or prior-epoch state. Rejection, remote error, disconnect, duplicate or out-of-order hello, policy before acknowledgement, unknown type, Event before active, malformed frame or payload, incompatible negotiation, unregistered selected codec, or acknowledgement substitution/escalation SHALL fail terminally without returning an admitted route. Admission SHALL NOT retry, reconnect, resend ambiguous bytes, or emit a best-effort protocol error during terminal teardown.

#### Scenario: Exact admission succeeds

- **WHEN** TLS becomes ready, App and Viewer exchange valid V1 bootstrap hellos, identity binding succeeds, and Viewer sends the exact acknowledgement
- **THEN** admission returns one internal admitted session with the exact negotiated route and values

#### Scenario: Viewer rejects the App

- **WHEN** Viewer sends a valid connection rejection while approval is pending
- **THEN** admission fails with the fixed safe Viewer-rejected category
- **AND** untrusted rejection code and message are not propagated

#### Scenario: Ping arrives while approval is pending

- **WHEN** Viewer sends a bounded valid ping before acknowledgement
- **THEN** App admits one matching pong and continues awaiting the same acknowledgement

### Requirement: Discovery and hello identity must agree

After a fully validated remote hello claims the Viewer role, admission SHALL derive `ViewerDiscoveryDiscriminator` from its exact Viewer installation ID and require equality with the exact discovered `vid` before negotiation. Mismatch SHALL fail terminally and release the discovery result and hello metadata.

This consistency check SHALL NOT claim Viewer authentication, certificate binding, publisher uniqueness, spoofing resistance, or cross-connection continuity. Pairing code, `vid`, and connection-local self-signed TLS identity SHALL remain distinct concepts.

#### Scenario: Advertisement and hello disagree

- **WHEN** the discovered `vid` differs from the value derived from the Viewer hello installation ID
- **THEN** admission fails before negotiation or acknowledgement

#### Scenario: Values agree

- **WHEN** advertisement and Viewer hello derive the same discriminator
- **THEN** negotiation may continue
- **AND** the SDK still makes no authentication or certificate-continuity claim

### Requirement: Admission input and streaming state are strictly bounded

The SDK SHALL use one lock-protected channel ingress with at most one scheduled drain, a bounded event count, and a bounded cumulative receive-byte count. Ingress SHALL never silently drop or reorder stream bytes. Overflow SHALL latch one terminal safe error, discard pending nonterminal work, reject later input, and cause channel cancellation. Terminal channel input SHALL take priority over queued nonterminal state or bytes.

One long-lived transport-core actor SHALL be created before channel construction and SHALL remain the channel ingress's permanent weak-routed callback owner through admission and event-pump attachment. It SHALL exclusively own one continuous frame decoder across TLS readiness, hello, acknowledgement, and admitted-session handoff. No callback SHALL be retargeted to the admission actor, admitted handle, or event pump. Pre-acknowledgement complete frame/generated-response work count and cumulative complete encoded bytes SHALL be bounded independently of individual frame limits. Event lane SHALL be rejected by streaming lane preflight before payload buffering while the session is pre-active. Limit or arithmetic failure SHALL return no partial admission result.

#### Scenario: Fragmented hello and coalesced acknowledgement

- **WHEN** Viewer hello is fragmented across chunks and acknowledgement plus later Control data are coalesced
- **THEN** frames are decoded once in byte order through one decoder
- **AND** later Control data enter the admitted owner's bounded handoff without a receive gap

#### Scenario: Early Event frame declares a large payload

- **WHEN** an Event lane byte is received before active state
- **THEN** lane preflight fails before any Event payload byte is retained

#### Scenario: Callback storm exceeds ingress

- **WHEN** channel callbacks exceed event or byte bounds before the actor drains them
- **THEN** one overflow terminal wins and no valid later acknowledgement can revive admission

### Requirement: Stage deadlines and cancellation clean up exactly once

Validated internal limits SHALL use defaults and hard maxima of: discovery timeout 30/120 seconds, secure-admission timeout 15/120 seconds, pump-attachment timeout 5/30 seconds, ingress events 64/256, ingress bytes 256 KiB/1 MiB, pre-ack work items 32/128, pre-ack encoded work bytes 256 KiB/1 MiB, pre-active handoff work items 64/256, pre-active handoff work bytes 512 KiB/1 MiB, retained handoff messages 32/128, and retained handoff bytes 256 KiB/1 MiB.

Every value SHALL be positive and every addition overflow-checked. Secure-admission timeout SHALL be at least the transport connection timeout; ingress bytes SHALL fit one receive chunk; each work-byte budget SHALL fit one active maximum Control frame; retained limits SHALL not exceed cumulative handoff limits; the cached hello and maximum V1 pong SHALL each fit maximum single-send bytes; pending-send count SHALL be at least two; their sum SHALL fit pending-send bytes; and no value SHALL widen Core wire, frame, or transport hard limits. At most one deadline Task SHALL exist for discovery, secure admission, or unattached handoff. Stage transition SHALL cancel and release the old deadline before creating the next; acknowledgement commit SHALL replace secure admission with attachment deadline; and pump attachment SHALL cancel that deadline.

Explicit cancellation, task cancellation, last-handle release, timeout, discovery failure, transport terminal, protocol failure, and ingress failure SHALL converge on one terminal cleanup. Cleanup SHALL resume the waiter at most once, cancel the started discovery or channel at most once as applicable, stop ingress, discard partial frame bytes and bounded messages, release local and remote hello metadata and duplicate endpoint/service identity values, and ignore every late callback. Cancellation, timeout, and success races SHALL be resolved by the sole current authority, with the transfer token and stale deadline tokens ignored after invalidation.

#### Scenario: Discovery timeout races with match

- **WHEN** the active discovery deadline and exact match race
- **THEN** exactly one advances or terminates the attempt
- **AND** the stale discovery deadline cannot later terminate the secure stage

#### Scenario: Task cancellation races with acknowledgement

- **WHEN** task cancellation and exact acknowledgement race
- **THEN** the waiter completes once and channel ownership is either transferred once or cancelled once

### Requirement: Admitted session preserves one continuous route owner

Success SHALL return one internal, Sendable, non-Codable, redacted `SDKAdmittedSession` handle that retains the same permanent transport-core actor through one shared cancellation relay. Only admitted and pump-attachment handles SHALL retain that relay; the relay SHALL strongly retain the core, and the core SHALL NOT retain the relay. The core SHALL exclusively own the live secure channel, ingress, continuous frame decoder, negotiated session codec, exact route, capabilities, policies, and maximum event bytes. Its initial protocol phase SHALL be policy negotiation rather than active Event transfer.

Acknowledgement SHALL remain provisional until the entire receive chunk that completed it has been processed. Valid later policy Control frames in that chunk SHALL enter the handoff; a later terminal or invalid frame in the same chunk SHALL fail admission and return no handle. The owner SHALL retain one bounded FIFO of already admitted post-acknowledgement flow-policy Control messages. During this handoff it SHALL answer bounded ping, ignore valid pong, terminate on safe error/disconnect, reject Event lane before payload buffering, and cancel on retained or cumulative work overflow. Every post-ack Control frame and generated pong SHALL consume cumulative work-item and encoded-byte budgets even when not retained.

`SDKAdmittedSession` SHALL attach a later event pump exactly once through the core actor. Attachment SHALL retarget no callback. Only admitted flow-policy offer/acceptance messages SHALL enter one FIFO, preserving buffered-before-later flow-policy order across attachment races. Ping SHALL be answered, pong discarded, and error/disconnect terminated outside that FIFO. A terminal core SHALL reject attachment; a second attachment SHALL fail. The later active event pump SHALL consume this same core and SHALL NOT replace the channel or decoder.

The attachment SHALL provide one asynchronous `nextPolicyMessage()`. Each call SHALL create a private lock-protected cancellation gate before entering its task-cancellation handler. `onCancel` SHALL synchronously latch cancellation. Core registration SHALL atomically claim the gate before storing a waiter; a pre-cancelled gate SHALL return `pullCancelled` without installing one. The core SHALL retain a claimed gate only with the one pending pull.

Registration precedence SHALL be: pre-latched per-call cancellation returns `pullCancelled` before all core-state inspection; otherwise stored terminal code; otherwise `pullAlreadyPending` when one waiter exists; otherwise immediate FIFO head; otherwise installation of the one waiter. Every immediate outcome SHALL close its gate before returning.

Pull-task cancellation after registration SHALL remove the still-pending token, close its gate, and resume with `pullCancelled` without terminating the session. A later policy message SHALL close the gate and either resume the pending pull directly or enter the FIFO, never both. Terminal state SHALL close the gate before resuming a pending pull once with the exact stored terminal code. The core SHALL order message, cancellation, and terminal races and retain no completed gate or continuation.

Acknowledgement commit SHALL start the bounded pump-attachment deadline; absence of attachment SHALL terminate the channel. Cumulative handoff budgets SHALL remain active until later policy activation. Explicit cancellation and cancellation-relay deinitialization SHALL use one exact-once gate and schedule at most one bounded core-cancellation Task. Dropping the admission handle after attachment SHALL leave the session alive through the pump handle. Dropping the final external handle SHALL deinitialize the relay and request cancellation once; an already-terminal core SHALL ignore that final request. Releasing the admission actor after success SHALL not affect callback delivery.

#### Scenario: Policy offer follows acknowledgement in one chunk

- **WHEN** exact acknowledgement and a valid flow-policy offer are coalesced
- **THEN** admission returns the route once
- **AND** the policy offer remains in order in the bounded handoff for the later pump

#### Scenario: Terminal frame follows acknowledgement in one chunk

- **WHEN** a valid acknowledgement is followed by disconnect, malformed, duplicate, or otherwise invalid Control data in the same receive chunk
- **THEN** admission fails without returning a handle

#### Scenario: Pump attachment races with callbacks

- **WHEN** Control frames arrive while the event pump attaches
- **THEN** one permanent core orders every handoff-eligible flow-policy message exactly once in one FIFO
- **AND** no eligible callback is lost, duplicated, or delivered to an old owner

#### Scenario: Unattached owner is abandoned

- **WHEN** the last admitted handle is released before pump attachment
- **THEN** defensive cancellation is requested once and releases channel, ingress, decoder, backlog, and deadline

#### Scenario: Admission handle is dropped after attachment

- **WHEN** the pump attachment remains live and the original admitted handle is released
- **THEN** the shared relay remains live and the session is not cancelled

#### Scenario: Empty policy pull races with input

- **WHEN** one empty-FIFO pull races with a policy frame, task cancellation, or terminal state
- **THEN** the core resumes the waiter exactly once with the one winning outcome
- **AND** a concurrent second pull fails without replacing the first

#### Scenario: Pull is cancelled before registration

- **WHEN** the task is already cancelled or cancellation latches before the core claims its gate
- **THEN** pull fails with `pullCancelled` without installing a continuation
- **AND** releasing the final handle can still tear down the session

#### Scenario: Pre-cancelled pull has multiple immediate outcomes

- **WHEN** a pre-cancelled pull reaches a terminal core, nonempty FIFO, or existing waiter
- **THEN** its own `pullCancelled` outcome takes precedence
- **AND** core terminal state, FIFO, and existing waiter remain unchanged

#### Scenario: Ping storm never fills retained backlog

- **WHEN** valid ping and pong traffic continues while retained policy backlog stays below its instantaneous bound
- **THEN** cumulative handoff work reaches its bound and terminates the session

#### Scenario: Result is rendered

- **WHEN** admitted session description, debug description, interpolation, or reflection is requested
- **THEN** output contains no route ID, installation ID, endpoint, pairing code, `vid`, certificate, metadata, bytes, or application content

### Requirement: Admission errors are closed and safe

Admission, pump attachment, attachment pulls, and stored core terminal state SHALL use one internal closed `SDKSessionAdmissionError`. Exact codes SHALL be: `invalidLocalConfiguration` for local model/encoding/limit/send-capacity failure; `alreadyStarted` for a second run; `cancelled` for expected pre-commit or handle-relay cancellation; `discoveryTimedOut`, `discoveryDenied`, `discoveryUnavailable`, `discoveryAmbiguous`, or `discoveryFailed` for their exact discovery categories; `secureAdmissionTimedOut` or `pumpAttachmentTimedOut` for their deadlines; `transportFailed` for unexpected transport/EOF/send failure; `ingressOverflow` for callback bounds; `protocolViolation` for malformed, phase, lane, type, ordering, or acknowledgement-escalation failures; `incompatiblePeer` for role/version/codec/policy or codec-registration incompatibility; `viewerIdentityMismatch`; `viewerRejected`; `remoteClosed` for valid remote error/disconnect; `handshakeWorkLimitExceeded`; `handoffWorkLimitExceeded`; `handoffBufferOverflow`; `alreadyAttached` for a second pump attachment; `pullAlreadyPending` for a second concurrent pull; and `pullCancelled` for cancellation of the one pending pull without session termination.

Attachment or a non-pre-cancelled pull after terminal state SHALL return the exact stored terminal code. A pre-cancelled pull SHALL return `pullCancelled` first. Last-handle cancellation SHALL store `cancelled` without requiring a waiter. A stale attempt-cancellation token after successful acknowledgement commit SHALL be ignored. Error description and reflection SHALL be derived only from the code for every API and terminal use. They SHALL NOT include pairing code, advertised name, `vid`, endpoint/interface description, Viewer or App ID, Bundle ID, product/display metadata, certificate/fingerprint, raw Network error, remote rejection/error/disconnect text, wire bytes, or application content.

#### Scenario: Private underlying failures are mapped

- **WHEN** discovery, Network.framework, or a remote control payload contains private or hostile text
- **THEN** the returned admission error contains only its fixed local code and message

#### Scenario: Attachment observes a terminal owner

- **WHEN** attachment is attempted after pump-attachment timeout or handoff overflow
- **THEN** it returns that exact stored code without underlying content

#### Scenario: Second attachment

- **WHEN** one pump attachment already succeeded
- **THEN** a second attempt fails with `alreadyAttached`

### Requirement: Admission does not start later ownership or event features

Session admission SHALL NOT call `ProcessConnectionLeaseRegistry`, claim or release process ownership, add supported connect/disconnect API, publish supported `NearWireState`, drain buffered events, publish incoming events, negotiate effective flow rates, admit Event messages, allocate event sequences, reconnect, observe App lifecycle, persist data, access Keychain, collect performance, or create UI. The later public-connect owner SHALL claim the lease before admission and retain its exact handle alongside the admitted session; later lifecycle code SHALL release both.

#### Scenario: Admission succeeds internally

- **WHEN** an internal admitted session is returned
- **THEN** no process lease or supported SDK state has changed
- **AND** no App or Viewer Event has been transferred
