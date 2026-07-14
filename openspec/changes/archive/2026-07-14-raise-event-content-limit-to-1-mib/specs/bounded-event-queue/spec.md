## MODIFIED Requirements

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
