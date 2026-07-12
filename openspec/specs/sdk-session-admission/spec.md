# sdk-session-admission Specification

## Purpose
TBD - created by archiving change sdk-session-admission. Update Purpose after archive.
## Requirements
### Requirement: Session admission is one explicit internal operation

The SDK SHALL provide one internal App admission actor constructed from validated pairing, validated hello, immutable limits, fixed dependencies, one `SDKSessionTransitionGate` created before run, and an optional content-free async phase observer returning a closed authorization result. Construction SHALL start no work. Public orchestration SHALL pass its attempt gate; an internal caller MAY create one private default gate. One run SHALL perform at most one discovery and secure admission attempt; second run and cancel-before-run SHALL remain deterministic. Existing exact `_nearwire._tcp` local-domain peer-to-peer-enabled discovery, ordered TCP, TLS 1.3, `nearwire/1`, hello, pong, wire, transport, reservation, deadline, and resource validation SHALL remain unchanged.

After exact discovery selection and before core or channel construction, admission SHALL require its current state, absence of Task cancellation, and gate authorization; invoke the observer at most once; then require observer authorization and immediately recheck all three sources. Cancellation latched in the shared gate SHALL prevent core/channel construction even when admission-actor cancellation delivery is delayed. Existing internal callers MAY omit the observer and use an always-authorized gate.

One successful admission SHALL return an admitted owner backed by one `SDKSessionLifetime` containing the existing permanent cancellation relay, exactly one one-shot termination value, and the exact gate supplied before run. The admitted session, any pump attachment, and any active handle SHALL share the same lifetime and SHALL NOT construct another termination or gate. A first terminal wait MAY begin while admitted and remain authoritative through attachment and activation. Task cancellation recorded before admission return and terminal marked before result delivery SHALL therefore retain their true order in one gate.

At the permanent core's exact first terminal transition, before resuming the termination waiter, scheduling channel cleanup, or delivering callbacks, the core SHALL synchronously mark the terminal code in the lifetime gate. The gate SHALL store a pre-registration terminal for a later first wait and SHALL expose the same terminal mark to public active-transfer and connected-commit claims. Async waiter scheduling SHALL NOT define terminal ordering.

#### Scenario: Discovery selects the exact Viewer

- **WHEN** selection wins and observer plus shared gate remain authorized
- **THEN** one connecting phase completes before core and channel construction

#### Scenario: Outer cancellation wins during phase delivery

- **WHEN** shared authorization is revoked while the observer suspends
- **THEN** post-observer validation starts no core, channel, transport, or attachment

#### Scenario: Terminal wait starts before attachment

- **WHEN** public orchestration begins the lifetime's one terminal wait after admission
- **THEN** that same wait observes terminal through later attachment and activation without replacement

#### Scenario: Core terminates before waiter Task resumes

- **WHEN** the core marks terminal and waiter scheduling is delayed
- **THEN** the lifetime gate already rejects later transfer or connected-commit claims with that exact code

#### Scenario: Task cancellation crosses admission result delivery

- **WHEN** Task cancellation and core terminal marking occur on opposite sides of delayed admission-result delivery
- **THEN** their order is the order recorded by the one gate created before admission run

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

Admission, pump attachment, attachment pulls, active pumping, and stored core terminal state SHALL use one internal closed `SDKSessionAdmissionError`. Exact codes SHALL be: `invalidLocalConfiguration` for local model/encoding/limit/send-capacity failure; `alreadyStarted` for a second admission or active-pump run; `cancelled` for expected pre-commit, active-run, or handle-relay cancellation; `discoveryTimedOut`, `discoveryDenied`, `discoveryUnavailable`, `discoveryAmbiguous`, or `discoveryFailed` for their exact discovery categories; `secureAdmissionTimedOut`, `pumpAttachmentTimedOut`, or `policyNegotiationTimedOut` for their exact deadlines; `transportFailed` for unexpected transport/EOF/send failure; `ingressOverflow` for callback bounds; `activeIngressOverflow` for decoded active Event retention bounds; `activeWorkLimitExceeded` for per-callback or complete-policy active work bounds; `protocolViolation` for malformed, phase, lane, type, ordering, acknowledgement-escalation, or invalid active Control failures; `incompatiblePeer` for role/version/codec/policy/capability or codec-registration incompatibility; `viewerIdentityMismatch`; `viewerRejected`; `remoteClosed` for valid remote error/disconnect; `handshakeWorkLimitExceeded`; `handoffWorkLimitExceeded`; `handoffBufferOverflow`; `alreadyAttached` for a second pump attachment; `policyConsumerClaimed` for runner-versus-pull policy ownership conflict; `pullAlreadyPending` for a second concurrent pull under pull ownership; `pullCancelled` for per-call pull cancellation without session termination; `routeMismatch` for an active Viewer Event whose epoch or endpoints differ from the admitted route; `sequenceViolation` for active direction, duplicate, gap, or sequence exhaustion; `outboundEncodingFailed` for a queued App Event that cannot form an active wire Event without queue mutation; `ownerUnavailable` when the bound NearWire instance is persistently shut down or cannot publish; and `clockFailed` for active same-clock reversal or unsafe deadline/rate arithmetic.

The same closed type SHALL use `terminationWaitAlreadyStarted` for a second call to the one-shot active termination observer and `terminationWaitCancelled` for cancellation of that observation only. Neither observer-local code SHALL replace stored core terminal state or terminate the session.

Attachment or a non-pre-cancelled pull after terminal state SHALL return the exact stored terminal code. A pre-cancelled pull SHALL return `pullCancelled` first. Last-handle cancellation SHALL store `cancelled` without requiring a waiter. A stale attempt, active-run, deadline, drain, wake, or publication token SHALL be ignored after invalidation. Error description and reflection SHALL be derived only from the code for every API and terminal use. They SHALL NOT include pairing code, advertised name, `vid`, endpoint/interface description, Viewer or App ID, Bundle ID, product/display metadata, policy values, queue values, certificate/fingerprint, raw Network error, remote rejection/error/disconnect text, wire bytes, or application content.

#### Scenario: Private underlying failures are mapped

- **WHEN** discovery, Network.framework, a remote control payload, or active Event contains private or hostile text
- **THEN** the returned session error contains only its fixed local code and message

#### Scenario: Attachment observes a terminal owner

- **WHEN** attachment is attempted after pump-attachment timeout or handoff overflow
- **THEN** it returns that exact stored code without underlying content

#### Scenario: Second attachment

- **WHEN** one pump attachment already succeeded
- **THEN** a second attempt fails with `alreadyAttached`

#### Scenario: Active waiter observes terminal state

- **WHEN** route, sequence, owner, clock, active bound, transport, or protocol failure terminates an active core
- **THEN** activation, termination, and every later internal operation observe the exact stored code once
- **AND** no diagnostic includes the rejected Event or route content

### Requirement: Admission does not start later ownership or event features

Session admission SHALL NOT call `ProcessConnectionLeaseRegistry`, claim or release process ownership, add supported connect/disconnect API, publish supported `NearWireState`, drain buffered events, publish incoming events, negotiate effective flow rates, admit Event messages, allocate event sequences, reconnect, observe App lifecycle, persist data, access Keychain, collect performance, or create UI. The later public-connect owner SHALL claim the lease before admission and retain its exact handle alongside the admitted session; later lifecycle code SHALL release both.

#### Scenario: Admission succeeds internally

- **WHEN** an internal admitted session is returned
- **THEN** no process lease or supported SDK state has changed
- **AND** no App or Viewer Event has been transferred

### Requirement: One attached owner can start one active runner

After pump attachment and before terminal state, the core SHALL hold one irreversible policy-consumer ownership state: unclaimed, attachment-pull-owned, or active-runner-owned. The first non-pre-cancelled attachment pull SHALL claim pull ownership before inspecting terminal state, an existing waiter, or buffered policy. That ownership SHALL persist when the pull returns immediately, waits, completes, or is later task-cancelled, and SHALL permit later sequential pulls. A pre-cancelled pull SHALL return `pullCancelled` without claiming ownership.

An active runner SHALL claim only unclaimed ownership. Runner registration precedence SHALL be: the same starter's second-run guard, stored core terminal state, pre-latched first-run cancellation, then policy-consumer ownership claim. Thus a terminal core returns its exact stored code before cancellation or ownership conflict; a live pre-cancelled first run stores and returns `cancelled`; and only then may existing pull ownership return `policyConsumerClaimed`. When pull ownership already exists, including after a completed immediate pull, runner start SHALL fail without stealing a pending waiter or consuming buffered policy. Pump attachment already cancelled its attachment deadline. Successful runner claim SHALL start one new initial-policy deadline before owner-binding suspension, keep it live through binding and policy negotiation, consume the bounded policy handoff in order only after live owner binding, and preserve the same channel, ingress, decoder, codec, route, relay, and terminal authority. A second active runner SHALL fail with `alreadyStarted` without replacing work.

After runner ownership, a pre-cancelled attachment pull SHALL retain `pullCancelled` precedence; every other pull SHALL fail immediately with `policyConsumerClaimed` and SHALL install no gate or continuation. The active runner SHALL be the only consumer of later policy Control messages.

#### Scenario: Buffered offer exists at runner start

- **WHEN** a valid policy offer was buffered before the active runner claims the attachment
- **THEN** that offer is consumed first by the runner from the existing ordered handoff
- **AND** no callback or decoder is replaced

#### Scenario: Policy pull exists at runner start

- **WHEN** one attachment policy pull is still pending as an active runner attempts to start
- **THEN** runner start fails with `policyConsumerClaimed` without stealing or duplicating the waiter
- **AND** session ownership remains exact

#### Scenario: Completed pull preceded runner

- **WHEN** an earlier attachment pull immediately consumed a buffered offer or completed after waiting
- **THEN** a later runner fails with `policyConsumerClaimed`
- **AND** it cannot wait for or reinterpret a replacement initial offer

#### Scenario: Pre-cancelled pull precedes runner

- **WHEN** a pull is cancelled before it claims policy ownership
- **THEN** it returns `pullCancelled` and ownership remains unclaimed
- **AND** a later runner may claim normally

#### Scenario: Pull follows runner claim

- **WHEN** a non-pre-cancelled pull is attempted after active-runner ownership
- **THEN** it returns `policyConsumerClaimed` without installing a continuation

#### Scenario: Terminal runner also observes task cancellation

- **WHEN** the attached core is already terminal before a first runner registration whose task cancellation is latched
- **THEN** runner start returns the exact stored terminal code
- **AND** it does not replace terminal state with `cancelled` or claim policy ownership

#### Scenario: Live first runner is pre-cancelled

- **WHEN** first-run cancellation is latched while the core remains live and policy ownership is unclaimed
- **THEN** the core terminates and run returns `cancelled`
- **AND** no owner binding, policy waiter, or wake registration is installed

### Requirement: Active-owner binding can park nonterminal ingress without losing terminal work

The existing session callback ingress SHALL add a lock-linearized `running`, `nonterminalPaused`, and `stopped` mode while retaining its single scheduled-drain latch and existing count/byte bounds. Runner binding SHALL pause before its actor suspension. A previously scheduled drain arriving while paused SHALL take terminal/overflow if latched; otherwise it SHALL clear the scheduled latch and park without consuming input or scheduling a successor. Nonterminal input while parked SHALL remain bounded and create no drain Task. Terminal or overflow SHALL replace pending nonterminal input and authorize exactly one drain through the pause.

A live binding result SHALL atomically resume running mode and authorize exactly one drain when retained input exists. Terminal racing resume SHALL use the same latch, and stop SHALL win over pause/resume and suppress successors. Drain-turn completion SHALL NOT self-reschedule parked nonterminal work. Terminal cleanup SHALL stop and release all retained input and routing closure.

#### Scenario: Terminal follows a parked scheduled drain

- **WHEN** a drain scheduled before pause arrives, parks, and a channel terminal then latches
- **THEN** the terminal authorizes exactly one drain despite nonterminal pause
- **AND** no retained nonterminal bytes or scheduled latch can strand it

#### Scenario: Binding resumes retained input

- **WHEN** live owner binding succeeds while ordered nonterminal callback items are parked
- **THEN** resume authorizes exactly one drain that consumes them in original order
- **AND** repeated paused submissions created no intermediate routing Tasks
