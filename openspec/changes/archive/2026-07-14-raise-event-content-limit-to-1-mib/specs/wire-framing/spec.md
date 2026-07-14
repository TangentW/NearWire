## MODIFIED Requirements

### Requirement: Independent bounded lane sizes

Frame limits SHALL default to 64 KiB for Control and 2 MiB for Event, SHALL be positive and coherent,
and SHALL have a 16 MiB hard ceiling. The Event default SHALL fit one maximum production V1 Event
record containing 1 MiB canonical content plus its message wrapper. After reading the lane byte,
decoding SHALL reject a declared payload above that lane's configured limit before buffering the
remaining payload.

#### Scenario: Oversized Control frame

- **WHEN** a frame uses the Control lane and declares more than the Control payload limit
- **THEN** it is rejected even if it is below the Event limit

#### Scenario: Boundary payload

- **WHEN** a payload exactly equals its lane limit
- **THEN** framing and decoding succeed

#### Scenario: Event frame carries maximum content overhead

- **WHEN** the exact maximum production Event record is wrapped in a V1 Event message
- **THEN** its payload fits the default 2 MiB Event lane
- **AND** the frame retains only its actual payload bytes
