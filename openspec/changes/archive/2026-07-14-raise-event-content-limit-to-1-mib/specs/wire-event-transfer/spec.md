## ADDED Requirements

### Requirement: One-MiB content fits the production Event record

The production wire-capacity calculation SHALL add the exact maximum non-content V1 Event-record
wrapper to the fixed 1 MiB content capacity using checked arithmetic and without constructing a
maximum-size content body. A maximum-content Event SHALL encode and decode through one ordinary-JSON
record and one Event frame. The encoded record and frame SHALL use their actual lengths and SHALL
remain below the 16 MiB hard ceiling.

#### Scenario: Maximum content crosses one Event frame

- **WHEN** a maximum-shape Event contains valid canonical content of exactly 1,048,576 bytes
- **THEN** its deterministic record equals the reviewed exact maximum record bound
- **AND** its complete V1 Event message fits one configured Event frame
- **AND** decoding preserves the complete content without truncation

#### Scenario: Wire sizing does not allocate maximum content

- **WHEN** production connection capacities are derived before an Event exists
- **THEN** sizing allocates only fixed-size wrapper metadata
- **AND** no 1 MiB content buffer is created from the advertised maximum
