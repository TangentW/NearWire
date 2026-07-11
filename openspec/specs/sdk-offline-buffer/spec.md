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

