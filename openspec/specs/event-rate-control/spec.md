# event-rate-control Specification

## Purpose
TBD - created by archiving change core-flow-control. Update Purpose after archive.
## Requirements
### Requirement: Conservative directional rate negotiation

Event rates SHALL be zero or finite values from 0.000000001 through 100,000 events per second. Effective App uplink and App downlink rates SHALL each be the minimum of the Viewer-requested rate and App-local maximum. Zero SHALL pause that business-event direction without defining control-lane behavior.

#### Scenario: Viewer requests above App maximum

- **WHEN** Viewer requests 100 uplink events per second and the App maximum is 20
- **THEN** effective uplink is 20 events per second

#### Scenario: Either endpoint pauses a direction

- **WHEN** either rate input for a direction is zero
- **THEN** that effective business-event direction is zero

#### Scenario: Invalid rate

- **WHEN** a rate is negative, non-finite, positive but below the supported minimum, or above the hard maximum
- **THEN** construction fails with a typed rate error

### Requirement: Monotonic bounded token bucket

A token bucket SHALL use an explicit monotonic nanosecond clock, one token per event, and a finite positive bounded burst duration defaulting to two seconds. Zero rate SHALL have zero capacity. Positive-rate capacity SHALL be the greater of one token and rate times burst duration, so every accepted positive rate can eventually admit a whole event. A new positive-rate bucket SHALL start full and SHALL never exceed capacity.

#### Scenario: Production remains below rate

- **WHEN** tokens are consumed more slowly than the configured refill rate
- **THEN** elapsed same-clock time replenishes them up to capacity

#### Scenario: Burst is exhausted

- **WHEN** a producer consumes the initial burst without sufficient elapsed refill time
- **THEN** further event admission is zero until at least one whole token accrues

#### Scenario: Clock moves backward

- **WHEN** supplied time is earlier than the bucket's last update
- **THEN** the operation fails atomically with a typed clock error

### Requirement: Pause and dynamic reconfiguration

Rate reconfiguration SHALL first refill at the old rate through the supplied same-clock time, then apply the new capacity and clamp existing tokens. Reconfiguration to zero SHALL clear capacity and tokens. Reconfiguration from zero SHALL not manufacture tokens at that instant.

#### Scenario: Rate decreases

- **WHEN** a bucket changes to a lower positive rate
- **THEN** available tokens are no greater than the new burst capacity

#### Scenario: Direction resumes from pause

- **WHEN** a zero-rate bucket changes to a positive rate
- **THEN** it begins with zero tokens
- **AND** tokens accrue only with subsequent same-clock elapsed time

#### Scenario: Rate changes after elapsed time

- **WHEN** reconfiguration occurs after time elapsed under the old rate
- **THEN** the old rate is used for refill only through the reconfiguration instant
- **AND** the new rate applies afterward

### Requirement: Exact token consumption

The bucket SHALL expose whole-token availability and SHALL consume exactly the number of events a batch actually selects. Inspecting availability SHALL NOT consume tokens, and a failed or byte-limited queue drain SHALL NOT discard unused allowance.

#### Scenario: Byte limit shortens a batch

- **WHEN** ten tokens are available but only three events fit the batch-byte limit
- **THEN** exactly three tokens are consumed
- **AND** the remaining seven tokens remain available subject to capacity

#### Scenario: Fractional token exists

- **WHEN** available tokens are greater than zero but less than one
- **THEN** whole-event allowance remains zero

### Requirement: Count-byte-interval bounded batches

Batch configuration SHALL have positive event-count, byte-count, and monotonic flush-interval limits. Defaults SHALL be 256 events, 512 KiB, and 500 milliseconds. A composed batch byte limit SHALL be large enough for any valid single queue event.

#### Scenario: Due batch is drained

- **WHEN** the flush deadline is reached with tokens and eligible events available
- **THEN** a nonempty batch is selected using queue fairness
- **AND** it exceeds none of the token, event-count, or byte-count limits

#### Scenario: Next fair event does not fit remaining bytes

- **WHEN** a nonempty batch has insufficient remaining bytes for the next fairly selected event
- **THEN** the current batch ends without skipping that event
- **AND** the event remains eligible for a later flush

#### Scenario: Batch configuration is invalid

- **WHEN** count, bytes, or interval is zero, above a hard bound, arithmetically unsafe, or incompatible with the queue single-event limit
- **THEN** scheduler construction fails with a typed configuration error

### Requirement: Stable caller-driven flush scheduling

The batch scheduler SHALL start from an explicit monotonic time and SHALL perform no work before its next deadline. A due attempt SHALL advance the next deadline to the supplied time plus one interval, including when the queue is empty or rate is zero. It SHALL NOT replay missed intervals.

#### Scenario: Flush is early

- **WHEN** drain is requested before the next deadline
- **THEN** no queue entry or token is consumed
- **AND** the deadline is unchanged

#### Scenario: Several intervals were missed

- **WHEN** drain occurs long after the deadline
- **THEN** at most one batch is produced by that call
- **AND** the next deadline is one interval after the supplied time rather than a catch-up deadline

#### Scenario: Direction is paused

- **WHEN** a flush is due while effective rate is zero
- **THEN** no business event leaves the queue
- **AND** the next flush deadline advances normally

### Requirement: Flow-control observability without timer ownership

Rate and batching primitives SHALL report available whole tokens, bounded fractional token state, estimated same-clock delay until the next token, and next flush deadline. They SHALL start no timer, task, thread, network operation, or control-lane work.

#### Scenario: Later actor schedules a wakeup

- **WHEN** no whole token is available at a positive rate
- **THEN** the bucket reports a finite delay until one token
- **AND** the caller remains responsible for scheduling any wakeup

#### Scenario: Schema-only construction

- **WHEN** queue, bucket, and scheduler values are constructed and exercised in Core tests
- **THEN** no UI framework, dispatch timer, run loop, network, or persistent storage dependency is required
