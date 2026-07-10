# bounded-event-queue Specification

## Purpose
TBD - created by archiving change core-flow-control. Update Purpose after archive.
## Requirements
### Requirement: Session-neutral pending events

Flow control SHALL queue immutable Sendable pending values with a stable event ID, value, priority, TTL, queue policy, positive accounted byte count, and origin-local enqueue monotonic timestamp. Pending entries SHALL NOT own a transport direction, endpoint, session epoch, or sequence number.

#### Scenario: Pending work crosses a reconnect

- **WHEN** an unexpired pending App event remains buffered while a session ends
- **THEN** its event ID and caller-controlled value can remain in the queue
- **AND** a later layer can allocate the new session epoch and sequence only after dequeue

#### Scenario: Byte cost is invalid

- **WHEN** a pending event declares zero bytes or more than the configured single-event or total queue-byte limit
- **THEN** enqueue fails before queue mutation

### Requirement: Coherent bounded queue limits

An event queue SHALL enforce positive event-count, total accounted-byte, and single-event-byte limits. The default SHALL be 1,000 events, 4 MiB total, and 256 KiB per event. The event-count hard bound SHALL be 10,000. Configuration SHALL reject a single-event limit above total bytes and values above hard safety bounds.

#### Scenario: Count limit reached

- **WHEN** enqueue would exceed the configured event count
- **THEN** overflow policy runs until the count is within the limit
- **AND** current count never exceeds the configured maximum after the operation

#### Scenario: Byte limit reached first

- **WHEN** enqueue remains below the count limit but exceeds total accounted bytes
- **THEN** overflow policy runs until accounted bytes are within the limit

#### Scenario: Invalid limit configuration

- **WHEN** any limit is zero, arithmetically unsafe, above its hard bound, or internally inconsistent
- **THEN** queue construction fails with a typed configuration error

### Requirement: Normal and keep-latest policy

The queue SHALL support distinct normal entries and keep-latest entries identified by a queue-local key of 1 through 128 UTF-8 bytes without control characters. At most one pending entry for a keep-latest key SHALL remain after enqueue.

#### Scenario: Normal events remain distinct

- **WHEN** two normal events have the same event type or content
- **THEN** both occupy independent queue entries unless overflow evicts one

#### Scenario: Keep-latest replaces in place

- **WHEN** a new keep-latest event uses a key already pending
- **THEN** the new event replaces the old event's ID, value, priority, byte cost, enqueue time, and TTL
- **AND** it retains the old logical insertion ordinal
- **AND** the coalesced counter and enqueue result identify the replaced event

#### Scenario: Replacement grows beyond capacity

- **WHEN** a replacement uses more bytes than the entry it replaces
- **THEN** coalescing occurs before overflow enforcement
- **AND** normal overflow rules determine which entries remain

### Requirement: Origin-local TTL expiration

The queue SHALL remove expired entries before enqueue, dequeue, and mutable telemetry observation using only an explicitly supplied value from the same monotonic clock as enqueue. Deadline arithmetic and backward clock movement SHALL fail without wrapping or partial mutation.

#### Scenario: Event reaches TTL

- **WHEN** same-clock time reaches enqueue time plus TTL
- **THEN** the event is removed before it can be selected or reported as pending
- **AND** expiration statistics identify the removal

#### Scenario: Fresh replacement resets lifetime

- **WHEN** keep-latest replaces an older entry
- **THEN** expiration uses the replacement's enqueue time and TTL rather than the replaced deadline

#### Scenario: Clock is invalid

- **WHEN** supplied time is earlier than a pending entry's enqueue time or deadline arithmetic overflows
- **THEN** the operation fails atomically with a typed clock error

### Requirement: Priority-aware overflow

After expiration and coalescing, the queue SHALL restore count and byte bounds by repeatedly evicting the oldest insertion ordinal from the lowest priority currently present. The incoming event MAY be the evicted candidate. Overflow SHALL be observable and SHALL NOT block or crash the producer.

#### Scenario: Lower priority is evicted first

- **WHEN** overflow occurs with low, normal, high, and critical entries present
- **THEN** the oldest low entry is selected before any higher-priority entry

#### Scenario: Incoming event cannot displace urgent work

- **WHEN** a new low-priority event enters a full queue containing only critical events
- **THEN** overflow may evict the incoming event
- **AND** the enqueue result reports that it is not buffered

#### Scenario: Multiple evictions restore byte capacity

- **WHEN** one eviction is insufficient to fit a large valid incoming entry
- **THEN** eviction repeats in priority and age order until both bounds hold

### Requirement: Weighted fair priority dequeue

The queue SHALL provide low, normal, high, and critical lanes with respective service weights 1, 2, 4, and 8. It SHALL preserve insertion order within each priority, skip empty lanes without wasting capacity, and SHALL NOT promise global FIFO across priorities.

#### Scenario: All priorities remain busy

- **WHEN** every priority remains continuously nonempty
- **THEN** a complete weighted cycle selects at most 8 critical, 4 high, 2 normal, and 1 low event
- **AND** low and normal events are not starved

#### Scenario: Only one lane has work

- **WHEN** only low-priority entries remain
- **THEN** each dequeue opportunity selects low work without waiting for empty-lane credits

#### Scenario: FIFO within a lane

- **WHEN** several high-priority entries are pending
- **THEN** they are selected in their logical insertion order relative to other high-priority entries

### Requirement: Queue results, clearing, and telemetry

Queue mutations SHALL report exact coalesced, evicted, expired, dequeued, and cleared event IDs. A queue SHALL reject an event ID that is already pending. Cumulative statistics SHALL saturate at `UInt64.max` and snapshots SHALL include current count, bytes, counts by priority, and oldest same-clock wait without including expired work.

#### Scenario: Duplicate pending ID

- **WHEN** an incoming event ID already exists in the queue
- **THEN** enqueue fails atomically with a typed entry error

#### Scenario: Queue snapshot

- **WHEN** a snapshot is requested with valid same-clock time
- **THEN** expired entries are removed first
- **AND** current depth, bytes, priority counts, oldest wait, and cumulative counters match remaining state

#### Scenario: Queue is explicitly cleared

- **WHEN** the owner clears pending work with a reason
- **THEN** all removed IDs are returned
- **AND** current count and bytes become zero
- **AND** the matching clear statistic is updated

### Requirement: Memory-only non-delivery semantics

The queue SHALL perform no disk I/O, network I/O, timer scheduling, producer suspension, acknowledgement, retry, or remote-delivery inference. Mutable queue values SHALL be designed for ownership by one later actor and SHALL make no claim of safe simultaneous mutation.

#### Scenario: Enqueue succeeds locally

- **WHEN** a valid event remains buffered after enqueue
- **THEN** the result means only that local in-memory policy currently retains it
- **AND** no remote receipt or processing guarantee is created
