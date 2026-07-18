# sdk-offline-buffer Specification

## Purpose
TBD - created by archiving change sdk-public-api. Update Purpose after archive.
## Requirements
### Requirement: Offline uplink work is bounded in memory

Each NearWire instance SHALL own a count-bounded and byte-bounded in-memory uplink queue. Admission SHALL validate a deterministic accounted representation before retention, SHALL reject a single oversized item atomically, and SHALL enforce priority-aware overflow without exceeding configured bounds.

Public statistics SHALL distinguish application submissions, synchronous transport acceptances, actual transport admission rejections, expiration, coalescing, overflow, explicit clearing, and route-affinity drops. Internal candidate offering SHALL NOT inflate submission or rejection counters.

#### Scenario: Application sends before connection support exists

- **WHEN** application code sends a valid event on an idle instance
- **THEN** it is admitted to that instance's bounded memory queue without starting network, timer, disk, Keychain, or UI work

#### Scenario: One event exceeds its byte limit

- **WHEN** a content value produces an accounted event larger than the configured single-event limit
- **THEN** send fails without changing existing pending work

### Requirement: Expiration uses one instance-local monotonic clock

Offline TTL SHALL be measured from the enqueue timestamp on one injected monotonic clock domain. Wall-clock creation dates SHALL NOT control expiration. Admission and diagnostics SHALL remove expired work before reporting their local effects.

#### Scenario: Wall clock changes

- **WHEN** wall time moves while monotonic time remains before the TTL deadline
- **THEN** the event remains pending

#### Scenario: Diagnostics after a TTL deadline

- **WHEN** diagnostics are requested after monotonic time reaches an event's deadline
- **THEN** the event is absent and expiration counters include it

### Requirement: Instances remain isolated

Creating, sending through, observing, or shutting down one NearWire instance SHALL NOT mutate another instance's queue, state, streams, IDs, configuration, statistics, or lifecycle. One SDK-internal process connection lease MAY govern only ownership of future discovery and network-session work. The lease SHALL NOT merge instance-local data, expose a singleton NearWire facade, or mutate any instance merely because another instance claims or releases connection ownership.

#### Scenario: Two idle instances buffer work

- **WHEN** two instances enqueue different events
- **THEN** each instance reports only its own pending work

#### Scenario: One future connection owner exists

- **WHEN** one internal caller holds the process connection lease while two NearWire instances retain different queues
- **THEN** both queues remain independent and unchanged
- **AND** a competing lease claim fails without mutating either queue

### Requirement: Session integration retains local semantics

The SDK SHALL provide internal actor-isolated seams for a later session coordinator to publish validated incoming events, update safe public state, and offer bounded outbound work synchronously to transport admission. A candidate SHALL leave the queue only after the secure channel's bounded mailbox synchronously accepts its encoded bytes. A rejected candidate and the unattempted remainder SHALL remain in their original queue positions with unchanged IDs, timestamps, TTLs, and scheduler credits. No long-lived reservation SHALL exist outside the queue, and these seams SHALL remain absent from the supported public API.

#### Scenario: Transport rejects before accepting bytes

- **WHEN** transport rejects the first offered event
- **THEN** that event and the unattempted remainder never leave their original queue positions or reset TTL
- **AND** a later public clear removes them

#### Scenario: Encoding does not reach transport admission

- **WHEN** the session cannot produce encoded bytes for the offered candidate
- **THEN** the drain reports that candidate as not attempted and leaves it in its original position
- **AND** transport rejection telemetry does not change

### Requirement: Active wire drain preserves queue ownership and acceptance semantics

The NearWire actor SHALL provide one internal active-session drain that keeps the uplink queue exclusively actor-owned. It SHALL accept a validated route, negotiated codec, outbound sequence counter, nonnegative maximum accepted-Event allowance, positive service and queue-accounted-byte turn limits, secure channel, fixed Control reservation, and one shared active-operation gate. The accepted-Event allowance SHALL come from the core's refreshed captured-time whole-token snapshot and SHALL remain distinct from service/byte work bounds. After actor entry the drain SHALL report persistent owner availability and, for a live owner, sample the exact instance-local enqueue clock for expiry and remaining-TTL computation; it SHALL NOT accept a core-supplied time for that purpose. It SHALL perform route preflight before transport-byte accounting and SHALL encode and synchronously offer each eligible candidate without moving it to a second queue or retaining an external reservation.

Every expiration, route drop, and accepted candidate SHALL use a separate operation-gate claim around only its small irreversible mutation. A candidate SHALL leave the queue only when one claim covers mailbox admission plus queue removal, fairness, live-ID, accounting, telemetry, and returned planned-sequence-prefix commit. Terminal-first SHALL mutate none of those values; operation-first SHALL be an explicit committed-before-terminal result. The drain SHALL accept no more live Events than its captured allowance; after exhausting that allowance it MAY continue expiry and route-drop service but SHALL offer no later live candidate. The returned planned sequence counter SHALL advance only for accepted bytes and SHALL remain unchanged for route drops, expiration, encoding failure, transport rejection, and terminal-first gate loss. Only a live matching core result may prevalidated-consume the accepted count from the exact refreshed bucket copy and install that bucket plus returned counter; terminal or stale result delivery SHALL discard route-local state without undoing an already committed mailbox/queue/telemetry prefix.

Each expiration, route drop, accepted candidate, or rejected candidate SHALL consume one service unit; only offered live candidates SHALL consume the byte budget. The result SHALL distinguish owner unavailable from a live empty queue and SHALL report exact queue IDs, accepted Event count/encoded bytes, due-work and eligible-work state, next origin-local expiration deadline, and either the planned committed-prefix counter or one closed local failure. A transport block SHALL additionally report the candidate identity, exact encoded byte requirement, Control reservation, and observed mailbox progress generation without retaining encoded `Data`. Existing public queue statistics SHALL count actual mailbox acceptance/rejection, expiration, coalescing, overflow, clearing, and route drops according to their existing meanings.

#### Scenario: Encoding fails before mailbox admission

- **WHEN** an eligible candidate cannot produce a valid active wire Event
- **THEN** it remains at its original queue position with unchanged TTL and identity
- **AND** neither sequence nor transport acceptance/rejection telemetry changes

#### Scenario: Mailbox accepts a prefix

- **WHEN** transport accepts a fair prefix and rejects the next candidate
- **THEN** only the accepted prefix leaves the queue and advances sequence
- **AND** the rejected candidate and unattempted remainder remain unchanged

#### Scenario: Terminal closes before candidate commit

- **WHEN** the active gate closes before an encoded candidate claims its irreversible transaction
- **THEN** no bytes, queue identity, sequence, fairness credit, or telemetry changes

#### Scenario: Candidate commits before terminal close

- **WHEN** the candidate claims the active gate and mailbox admission succeeds before terminal close
- **THEN** its complete mailbox, queue, fairness, live-ID, telemetry, and returned planned-prefix transaction is committed-before-terminal
- **AND** terminal cleanup may discard only route-local counter and token-bucket state that was not installed by a live result

### Requirement: Active owner receives coalesced outbound-work signals

The NearWire actor SHALL allow exactly one internal tokenized outbound-work callback registration. Registration SHALL first distinguish persistent shutdown from a live owner, then claim the shared active-operation gate around actual callback assignment and atomically return the initial owner-availability/fair-candidate/deadline snapshot from that actor turn. Shutdown-first SHALL return unavailable without assignment; terminal-first SHALL install nothing; install-first SHALL return the exact token that cleanup must remove. Registration and removal SHALL otherwise be actor-isolated and side-effect-free with respect to network, timer, state, lease, and persistence work. A stale token SHALL NOT replace or remove a newer registration.

After send, reply, platform-event, replacement, overflow, expiration, drain, or clear mutation can change pending selection or the next deadline, NearWire SHALL invoke the callback without awaiting or blocking the public operation. The callback SHALL first enter a lock-protected signal ingress that coalesces while still synchronous, before Task creation. Idle-to-scheduled SHALL create at most one weak-routing Task; later signals SHALL set one dirty bit, and completing that turn SHALL authorize at most one successor. A binding-token signal delivered before the assignment result SHALL remain latched for one level-triggered refresh after live binding. Shutdown SHALL persist owner-unavailable state before notifying the active owner. Every later schedule observation or drain SHALL return that level-triggered availability, so a coalesced or pre-registration shutdown edge cannot be lost. The callback SHALL NOT retain the active core strongly, and removing it SHALL retain no continuation or application data.

#### Scenario: Event was buffered before registration

- **WHEN** an active owner registers while offline work already exists
- **THEN** registration's atomic initial snapshot reports that work without requiring a historical notification

#### Scenario: Owner shut down before registration

- **WHEN** registration reaches a permanently shutdown NearWire instance
- **THEN** it returns owner unavailable without assigning a callback token
- **AND** an empty live queue cannot be confused with this result

#### Scenario: Owner shuts down after assignment but before binding result delivery

- **WHEN** callback assignment wins and shutdown persists before the core handles the assignment result
- **THEN** the binding-token signal remains latched until one level-triggered refresh reports owner unavailable
- **AND** exact-token cleanup follows without waiting for unrelated queue work

#### Scenario: Notification storm occurs

- **WHEN** many queue mutations signal before the first routing turn finishes
- **THEN** synchronous ingress retains at most one routing Task plus one already-authorized successor
- **AND** no Task is created per notification

#### Scenario: Stale removal races a new owner

- **WHEN** cleanup from an older token occurs after a newer token was installed
- **THEN** the newer callback remains registered and receives later queue-state signals

### Requirement: Active publication shares terminal linearization

The internal incoming-publication seam SHALL accept the exact active-operation gate. Immediately before publishing to the event hub, NearWire SHALL claim that gate across the complete synchronous publication side effect. If terminal close wins first, the method SHALL publish nothing and report the closed-gate outcome. If publication claims first, its Event SHALL be committed-before-terminal. A stale core result token SHALL NOT be treated as a substitute for this gate.

#### Scenario: Terminal wins before publication

- **WHEN** terminal close occurs while publication is queued on the NearWire actor but before gate claim
- **THEN** no subscriber receives the Event

#### Scenario: Publication wins before terminal

- **WHEN** publication claims the gate before terminal close
- **THEN** the Event is published synchronously once before terminal cleanup continues

### Requirement: Default SDK buffering carries one-MiB Event content

The default SDK configuration SHALL admit an Event whose canonical deterministic content is exactly
1 MiB when its complete validated internal draft remains within the derived 4,259,840-byte
single-Event accounting bound. The default offline queue SHALL permit at most 10,000 Events and
64 MiB of accounted data. Smaller explicit buffer limits SHALL remain authoritative, and no
oversized send SHALL partially mutate the queue or its statistics.

#### Scenario: Default send buffers maximum content

- **WHEN** App sends structurally valid content whose canonical deterministic encoding is exactly
  1,048,576 bytes using the default SDK configuration
- **THEN** the Event enters the offline queue using its actual accounted draft bytes
- **AND** no network, timer, disk, Keychain, or UI work starts merely because it was buffered

#### Scenario: Default queue reaches a bound

- **WHEN** another Event would exceed 10,000 retained Events or 64 MiB of accounted data
- **THEN** the existing priority-aware overflow policy restores both bounds
- **AND** the queue never promises lossless retention for a prolonged 4,096-Event/s disconnect

#### Scenario: Default send rejects one byte over

- **WHEN** App sends otherwise valid content whose canonical deterministic encoding is 1,048,577
  bytes
- **THEN** send returns the existing content-size failure
- **AND** queue contents and statistics remain unchanged

#### Scenario: Explicit smaller total omits the single-Event limit

- **WHEN** App constructs buffer configuration with an explicit total below 4,259,840 bytes and
  omits `maximumEventBytes`
- **THEN** the effective single-Event accounting limit equals that explicit total
- **AND** explicitly supplying a single-Event limit above the total remains invalid

