## MODIFIED Requirements

### Requirement: Pending sends are bounded before retention

The channel SHALL bound pending send count and total bytes with overflow-safe accounting, SHALL reject excess admission atomically, and SHALL keep exactly one FIFO send in flight. Rejection SHALL leave existing work unchanged. In addition to actor-isolated send, the channel SHALL provide synchronous nonisolated mailbox admission for an actor-isolated session handoff. Concurrent admission SHALL be linearized under one lock with the same count, total-byte, and single-send limits. Success SHALL transfer byte ownership to the channel; failure SHALL retain no part of the candidate. Terminal transition SHALL reject new admission and clear retained mailbox bytes.

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

#### Scenario: Channel becomes terminal

- **WHEN** cancellation or failure races with synchronous admission
- **THEN** admission linearizes either before terminal cleanup or after admission closes
- **AND** terminal cleanup retains no mailbox bytes and all later admission fails
