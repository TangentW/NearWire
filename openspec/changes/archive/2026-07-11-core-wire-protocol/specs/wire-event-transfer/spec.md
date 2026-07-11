## ADDED Requirements

### Requirement: Plain JSON wire event records

A wire event record SHALL contain every required logical `EventEnvelope` field plus positive remaining TTL nanoseconds. Event content SHALL be encoded as ordinary deterministic JSON and SHALL NOT use the internal tagged `JSONValue` Codable representation. Dates SHALL use canonical ISO-8601 UTC with a `Z` suffix and the shortest 3 through 9 digit fractional part that reconstructs the `Date` exactly. Decode SHALL reject alternate or lossy date forms and apply active event validation limits.

#### Scenario: Every JSON content case round trips

- **WHEN** event content contains null, Boolean, signed integer, finite floating-point, string, array, and object values
- **THEN** wire round trip preserves every logical case and nested order

#### Scenario: Tagged representation is absent

- **WHEN** an event fixture is inspected
- **THEN** its content appears as ordinary JSON rather than internal kind/value tags

### Requirement: Sender remaining lifetime

Creating a wire event SHALL require current nanoseconds from the same monotonic clock that created the envelope timestamp. Core SHALL calculate the origin deadline without overflow and SHALL reject an event that has reached it. The transmitted remaining duration SHALL be positive and no greater than the original TTL duration.

#### Scenario: Partially consumed TTL

- **WHEN** 250 milliseconds have elapsed from a one-second event TTL
- **THEN** the wire record carries 750 million remaining nanoseconds

#### Scenario: Event already expired

- **WHEN** sender time is at or beyond the origin deadline
- **THEN** wire record construction fails before encoding

### Requirement: Receiver-local deadline

Receiving code SHALL establish a deadline by adding transmitted remaining nanoseconds to an explicitly supplied receiver-local monotonic value with overflow-safe arithmetic. It SHALL NOT compare receiver uptime to the sender monotonic timestamp. The resulting wrapper SHALL evaluate expiration only against the receiver clock.

#### Scenario: Receiver deadline

- **WHEN** a record with 750 million remaining nanoseconds is received at local value 10 billion
- **THEN** its receiver-local deadline is 10.75 billion

#### Scenario: Receiver clock overflow

- **WHEN** the remaining duration cannot be added to the receiver-local value
- **THEN** establishment fails without wrapping

### Requirement: Bounded event batches and drop summaries

The Event lane SHALL support one event, batches of 1 through 256 events, and bounded drop summaries. Every batch SHALL fit the Event frame limit, SHALL use one session epoch and direction, and SHALL contain contiguous ascending sequences. Drop summaries SHALL report nonnegative counts by documented reason and SHALL NOT imply acknowledgement.

Decode SHALL reject an out-of-range batch count before constructing records. Construction SHALL stop when an overflow-safe cumulative byte budget cannot fit the Event frame and SHALL verify the complete encoded message size.

#### Scenario: Valid batch

- **WHEN** a batch contains contiguous events from one epoch and direction within all count and byte limits
- **THEN** it encodes and decodes in sequence order

#### Scenario: Mixed batch session

- **WHEN** a batch mixes epochs, directions, or noncontiguous sequences
- **THEN** construction or decode fails with a typed batch error

#### Scenario: Drop summary

- **WHEN** overflow, expiration, or coalescing counts are reported
- **THEN** the diagnostic payload round-trips
- **AND** no delivery receipt or retry state is created
