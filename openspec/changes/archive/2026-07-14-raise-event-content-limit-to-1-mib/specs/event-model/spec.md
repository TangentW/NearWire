## ADDED Requirements

### Requirement: Default Event content capacity is one MiB

The default Event validation limits SHALL accept canonical deterministic ordinary JSON content up
to and including 1,048,576 bytes and SHALL reject content at 1,048,577 bytes. The limit SHALL apply
to actual encoded content bytes and SHALL NOT pad, reserve, or allocate 1 MiB for smaller Events.
All existing structural, collection, string, key, numeric, depth, and finite-number validation SHALL
remain active.

#### Scenario: Content is exactly one MiB

- **WHEN** a structurally valid Event content value deterministically encodes to 1,048,576 bytes
- **THEN** default Event validation accepts it
- **AND** its recorded content byte count remains exactly 1,048,576

#### Scenario: Content exceeds one MiB by one byte

- **WHEN** otherwise valid Event content deterministically encodes to 1,048,577 bytes
- **THEN** default Event validation rejects it before Event retention or transport work

#### Scenario: Small content remains dynamically sized

- **WHEN** valid Event content encodes below 1 MiB
- **THEN** validation and encoding use its actual byte count without maximum-size padding
