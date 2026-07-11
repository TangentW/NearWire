## MODIFIED Requirements

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
