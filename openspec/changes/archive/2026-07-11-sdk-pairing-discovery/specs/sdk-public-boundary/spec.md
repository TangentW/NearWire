## MODIFIED Requirements

### Requirement: Public API work does not start session features early

NearWire construction and the supported public facade SHALL remain side-effect-free and source-compatible. This change MAY add repository-internal pairing and Bonjour discovery that starts only through an explicit internal `run()` operation. It SHALL NOT add public connect/disconnect APIs, open a TCP or TLS connection, manage TLS identity, acquire a process-wide lease, negotiate a session or rate, reconnect, observe background lifecycle, persist data, create UI, collect performance data, schedule retry timers, or start hidden asynchronous work from NearWire initialization.

#### Scenario: Side-effect audit

- **WHEN** a NearWire instance and an internal discovery value are constructed
- **THEN** neither starts browsing, requests local-network permission, opens a connection, schedules a task or timer, accesses persistence, or changes global ownership

#### Scenario: Explicit internal discovery run

- **WHEN** a later repository-owned session explicitly invokes discovery run
- **THEN** only the bounded Bonjour browser lifecycle described by `sdk-bonjour-discovery` begins
- **AND** the supported application API inventory remains unchanged
