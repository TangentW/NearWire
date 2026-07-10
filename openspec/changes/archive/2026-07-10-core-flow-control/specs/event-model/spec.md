## ADDED Requirements

### Requirement: Complete internal event priority vocabulary

Internal event priority SHALL contain low, normal, high, and critical values. Priority SHALL affect local queue service and overflow order only and SHALL NOT create acknowledgement, retry, persistence, or remote-delivery guarantees.

#### Scenario: Critical event enters flow control

- **WHEN** an internal event is marked critical
- **THEN** the value round trips through Codable unchanged
- **AND** flow control can place it above high, normal, and low for scheduling and overflow decisions

#### Scenario: Priority does not imply delivery

- **WHEN** a critical event is accepted into a local queue
- **THEN** the result does not imply that a remote endpoint received or processed it
