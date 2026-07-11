## ADDED Requirements

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

## MODIFIED Requirements

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
