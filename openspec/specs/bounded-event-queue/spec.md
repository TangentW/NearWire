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

An event queue SHALL enforce positive event-count, total accounted-byte, and single-event-byte
limits. The default SHALL be 1,000 events, 16 MiB total, and 4,259,840 bytes per Event, where the
single-Event value is the derived worst-case internal model bound for 1 MiB canonical content. The
event-count hard bound SHALL be 10,000. Configuration SHALL reject a single-event limit above total
bytes and values above hard safety bounds.

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

The queue SHALL provide low, normal, high, and critical lanes with respective service weights 1, 2, 4, and 8. It SHALL preserve insertion order within each priority, skip empty lanes without wasting capacity, and SHALL NOT promise global FIFO across priorities. In addition to unconditional dequeue, it SHALL support synchronous candidate offering. An eligible candidate SHALL be removed and charged scheduler credit only after admission accepts it. Stopping on a candidate SHALL leave that candidate's insertion ordinal, queue indexes, accounted bytes, and scheduler credit unchanged. An owner preflight MAY remove locally invalid work before transport byte-budget evaluation; that removal SHALL count as queue service but SHALL NOT consume transport batch bytes or invoke transport admission.

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

#### Scenario: Candidate is rejected synchronously

- **WHEN** the offer decision stops on the next fairly selected candidate
- **THEN** the candidate remains in its original queue position
- **AND** a later offer observes the same fair selection as if the rejected offer had not occurred

#### Scenario: Locally invalid candidate exceeds transport budget

- **WHEN** owner preflight removes the next candidate and that candidate is larger than the transport batch budget
- **THEN** removal occurs without invoking transport admission or consuming transport batch bytes
- **AND** the next eligible candidate can still use the remaining offer limits

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

### Requirement: Queue scheduling observation services expiry with bounded terminal authorization

A queue scheduling observation SHALL accept one same-domain monotonic value, one positive service quantum, and one synchronous per-mutation authorization body supplied by the active owner. Its enclosing NearWire actor operation SHALL first return level-triggered owner availability so a shutdown owner is distinct from a live empty queue. For a live owner it SHALL validate the clock before mutation and remove at most the quantum of Events already due. Every expiry removal SHALL invoke the authorization body around only the exact queue, live-ID, accounting, and telemetry mutation. If authorization reports terminal-first, that Event and all related values SHALL remain unchanged and observation SHALL stop.

The result SHALL state whether due work remains. Only when no due work remains SHALL it return the earliest remaining origin-local expiration deadline plus the stable ID of the next fairly selectable candidate, or nil values when no work remains. The deadline SHALL come from the queue's bounded deadline index and use the exact `NearWire` instance's enqueue-clock domain. Fair-candidate observation SHALL plan on a value copy and SHALL NOT mutate stored fairness credits. Observation SHALL NOT dequeue live work, start a Task/timer, or expose queued values beyond that stable ID.

The operation SHALL fail atomically on backward clock, invalid quantum, or unsafe deadline state. Callers MAY schedule one immediate coalesced continuation while due work remains or one one-shot wake for a returned future deadline; the queue itself SHALL remain timer-free.

#### Scenario: Paused queue has one future deadline

- **WHEN** rate is zero and live pending Events remain after bounded due-expiry service
- **THEN** observation returns the earliest exact monotonic deadline
- **AND** no live Event or fairness credit changes

#### Scenario: More due work exceeds one quantum

- **WHEN** more Events are due than the supplied positive service quantum
- **THEN** observation removes no more than the quantum through separate authorization claims and reports that due work remains
- **AND** the caller can schedule one immediate continuation without polling

#### Scenario: Terminal closes before an expiry

- **WHEN** terminal close wins the shared authorization gate before one due removal
- **THEN** that Event, live ID, accounting, and telemetry remain unchanged
- **AND** observation performs no later mutation

#### Scenario: Queue becomes empty

- **WHEN** authorized expiration or clearing removes the final pending Event
- **THEN** the next expiration deadline and fair candidate ID are nil

#### Scenario: Owner is unavailable with no queue work

- **WHEN** scheduling observation reaches a permanently shutdown NearWire owner
- **THEN** it reports owner unavailable rather than a live empty snapshot
- **AND** performs no queue, clock, fairness, or telemetry mutation

#### Scenario: Blocked candidate remains selected

- **WHEN** unrelated queue mutation does not change the next fair stable ID
- **THEN** scheduling observation reports the same ID without consuming fairness credit

#### Scenario: Fair selection changes

- **WHEN** authorized removal, replacement, expiration, overflow, or newly eligible priority work changes the next fair candidate
- **THEN** scheduling observation reports the new stable ID without dequeuing it

### Requirement: Active queue offering separates preparation from gated mutation

The queue SHALL provide one internal active-offer seam that plans fair selection on value copies and performs potentially failing envelope construction and encoding before claiming terminal authorization. Preparation SHALL NOT change stored fairness, queue order, live IDs, sequence, telemetry, or transport state.

Each expiry, route-affinity drop, and accepted candidate SHALL use one separate synchronous authorization/body closure around only its small irreversible mutation. For an accepted candidate, that body SHALL cover secure-mailbox admission plus exact queue removal, fairness credit, live-ID, accounting, and telemetry changes. Terminal-first SHALL leave all those values unchanged. Authorization-first SHALL return an explicit committed prefix that a stale outer actor result cannot roll back. A transport rejection SHALL leave queue identity, TTL, ordinal, fairness, and planned sequence unchanged while recording only telemetry defined as actual rejection.

#### Scenario: Prepared candidate loses terminal authorization

- **WHEN** a candidate encodes successfully but terminal close wins before its authorization body
- **THEN** mailbox, queue, fairness, live IDs, accounting, sequence, and telemetry remain unchanged

#### Scenario: Route drop commits before terminal

- **WHEN** a stale route-affinity candidate claims authorization before terminal close
- **THEN** only its exact route-drop queue and telemetry mutation commits
- **AND** it consumes no sequence, rate token, or transport byte budget
