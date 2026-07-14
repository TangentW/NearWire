## ADDED Requirements

### Requirement: Default SDK buffering carries one-MiB Event content

The default SDK configuration SHALL admit an Event whose canonical deterministic content is exactly
1 MiB when its complete validated internal draft remains within the derived 4,259,840-byte
single-Event accounting bound. The default total offline queue budget SHALL be 16 MiB. Smaller
explicit buffer limits SHALL remain authoritative, and no oversized send SHALL partially mutate the
queue or its statistics.

#### Scenario: Default send buffers maximum content

- **WHEN** App sends structurally valid content whose canonical deterministic encoding is exactly
  1,048,576 bytes using the default SDK configuration
- **THEN** the Event enters the offline queue using its actual accounted draft bytes
- **AND** no network, timer, disk, Keychain, or UI work starts merely because it was buffered

#### Scenario: Default send rejects one byte over

- **WHEN** App sends otherwise valid content whose canonical deterministic encoding is 1,048,577
  bytes
- **THEN** send returns the existing content-size failure
- **AND** queue contents and statistics remain unchanged

#### Scenario: Explicit smaller total omits the single-Event limit

- **WHEN** App constructs buffer configuration with an explicit total below 4,259,840 bytes and
  omits `maximumEventBytes`
- **THEN** the effective single-Event accounting limit equals that explicit total
- **AND** explicitly supplying a single-Event limit above the total remains invalid
