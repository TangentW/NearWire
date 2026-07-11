## MODIFIED Requirements

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
