## MODIFIED Requirements

### Requirement: Viewer admission accepts the production SDK Event-size offer

Viewer admission SHALL decode an otherwise valid App Hello that advertises the exact maximum
deterministic Event-record size calculated for 1 MiB canonical content. Viewer SHALL advertise and
enforce the same production capacity by default, retain existing bounded admission ownership, and
continue to the normal automatic or approval handoff. It SHALL NOT allocate an offered-size Event
buffer during Hello decoding. Negotiation with an explicitly smaller peer SHALL still select the
smaller value.

#### Scenario: Production SDK Hello reaches handoff

- **WHEN** Bonjour, TCP, and TLS succeed and App sends a valid production Hello whose Event-record
  offer includes 1 MiB content plus its envelope
- **THEN** Viewer decodes and negotiates the Hello instead of cancelling the secure connection
- **AND** the effective Event limit carries the exact production record maximum
- **AND** the attempt reaches its configured automatic or approval handoff

#### Scenario: Smaller peer remains conservative

- **WHEN** a valid peer advertises less than the Viewer production Event-record capacity
- **THEN** negotiation selects the smaller peer offer
- **AND** Viewer does not widen the resulting active session
