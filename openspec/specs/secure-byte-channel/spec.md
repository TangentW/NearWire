# secure-byte-channel Specification

## Purpose
TBD - created by archiving change core-transport-security. Update Purpose after archive.
## Requirements
### Requirement: Secure byte channel has one explicit lifecycle

The channel SHALL start exactly once, SHALL expose setup/preparing/ready/closing/failed/cancelled states, and SHALL emit at most one terminal outcome. Cancellation SHALL be idempotent and SHALL cancel its driver at most once.

#### Scenario: Ready lifecycle

- **WHEN** a new channel starts and its driver becomes ready
- **THEN** state progresses in order and receive work begins once

#### Scenario: Late callback after cancellation

- **WHEN** a receive, send, or state callback arrives after cancellation
- **THEN** it is ignored and no new work or second terminal outcome is emitted

### Requirement: Receive work is bounded and serial

The channel SHALL maintain at most one outstanding receive, SHALL request no more than the configured chunk bytes, and SHALL reject oversized, anomalous, EOF, or failed deliveries with a typed terminal result without accumulating an unbounded output array.

Every receive operation SHALL have a distinct token. Duplicate or replayed callbacks from an older receive SHALL be ignored and SHALL NOT clear or duplicate a newer outstanding receive.

#### Scenario: Sequential receives

- **WHEN** the driver returns a valid chunk
- **THEN** that chunk is delivered once before exactly one next receive is requested

#### Scenario: Oversized driver delivery

- **WHEN** a driver supplies more bytes than requested
- **THEN** the channel fails terminally and does not request another receive

### Requirement: Pending sends are bounded before retention

The channel SHALL bound pending send count and total bytes with overflow-safe accounting, SHALL reject excess admission atomically, and SHALL keep exactly one FIFO send in flight. Rejection SHALL leave existing work unchanged. In addition to actor-isolated send, the channel SHALL provide synchronous nonisolated mailbox admission for an actor-isolated session handoff. Concurrent admission SHALL be linearized under one lock with the same count, total-byte, and single-send limits. Success SHALL transfer byte ownership to the channel; failure SHALL retain no part of the candidate. Terminal transition SHALL reject new admission and clear retained mailbox bytes.

Synchronous admission SHALL additionally accept nonnegative reserved pending-count and pending-byte values for repository-owned Event transfer. Under the same lock, the candidate SHALL be accepted only when its post-admission count and retained bytes plus those reservations fit the configured global bounds. Reservation values SHALL retain no storage, SHALL create no separate queue or priority lane, and SHALL NOT affect already admitted FIFO order. Invalid or overflowed reservation arithmetic SHALL fail before mutation. Ordinary admission SHALL use zero reservation and preserve existing behavior.

The mailbox SHALL expose a constant-size nonisolated capacity snapshot under the same lock. The snapshot SHALL contain accepting state, available pending count, available pending bytes, and a monotonic progress generation that changes whenever completion releases retained capacity or terminal cleanup closes admission. A cheap predicate SHALL report whether a known positive byte count could currently fit with supplied valid reservations. It SHALL retain no payload, reserve no capacity, and SHALL NOT replace atomic admission revalidation.

#### Scenario: FIFO completion

- **WHEN** several admitted sends complete successfully
- **THEN** the driver observes them in original order with one in flight

#### Scenario: Backpressure rejection

- **WHEN** a new send would exceed count or bytes
- **THEN** it is rejected without retaining the bytes or disturbing admitted sends

#### Scenario: Completed payload release

- **WHEN** an in-flight send completes successfully
- **THEN** its payload storage is released immediately rather than waiting for queue compaction

#### Scenario: Concurrent synchronous admission reaches a bound

- **WHEN** multiple callers attempt synchronous admission concurrently
- **THEN** exactly the candidates within count and byte bounds transfer to the channel
- **AND** all excess candidates fail without exceeding either bound

#### Scenario: Event admission preserves Control capacity

- **WHEN** an Event candidate would fit the raw mailbox but not fit after adding the requested Control count or byte reservation
- **THEN** Event admission fails atomically
- **AND** ordinary Control admission may still use the reserved global capacity

#### Scenario: Reservation arithmetic is invalid

- **WHEN** a reservation is negative, exceeds the configured bound, or overflows with the candidate
- **THEN** admission fails without retaining bytes or changing FIFO state

#### Scenario: Capacity is insufficient for known blocked bytes

- **WHEN** a caller checks one known encoded Event size plus Control reservation while available count or bytes are insufficient
- **THEN** the predicate returns false without encoding, retaining, reserving, or mutating work

#### Scenario: Completion advances progress

- **WHEN** an in-flight payload completes and releases retained capacity
- **THEN** a later snapshot has a different progress generation and exact new availability

#### Scenario: Predicate races admission

- **WHEN** a predicate reports sufficient capacity but another caller admits first
- **THEN** the later atomic admission still enforces the global count, byte, single-send, and reservation bounds

#### Scenario: Channel becomes terminal

- **WHEN** cancellation or failure races with synchronous admission
- **THEN** admission linearizes either before terminal cleanup or after admission closes
- **AND** terminal cleanup retains no mailbox bytes and all later admission fails

### Requirement: Transport faults do not retry ambiguous bytes

A receive or send error SHALL fail the channel, clear pending data, cancel the driver, and SHALL NOT retry, reconnect, or resend bytes. Underlying error descriptions SHALL not enter safe public diagnostics by default.

#### Scenario: In-flight send failure

- **WHEN** the driver reports a send error
- **THEN** the channel becomes terminal, later callbacks are ignored, and no send is retried
