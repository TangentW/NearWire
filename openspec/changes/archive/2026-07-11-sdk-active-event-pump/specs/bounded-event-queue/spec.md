## ADDED Requirements

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
