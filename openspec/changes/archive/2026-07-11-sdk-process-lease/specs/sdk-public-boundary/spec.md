## MODIFIED Requirements

### Requirement: Public API work does not start session features early

NearWire construction and the supported public facade SHALL remain side-effect-free and source-compatible. Repository-internal pairing, Bonjour discovery, and process connection ownership MAY begin only through their explicit internal operations. The process lease SHALL NOT be claimed by initialization or ordinary event APIs. This change SHALL NOT add public connect/disconnect or lease APIs, open TCP/TLS, manage TLS identity, negotiate a session or rate, reconnect, observe background lifecycle, persist data, create UI, collect performance data, schedule work, or transfer events.

#### Scenario: Side-effect audit

- **WHEN** NearWire instances and internal lease-capable types are constructed
- **THEN** no lease is claimed, browser starts, local-network permission is requested, connection opens, task or timer is scheduled, persistence is accessed, or global ownership changes

#### Scenario: Explicit internal lease claim

- **WHEN** a later repository-owned connection operation explicitly claims the process lease
- **THEN** only constant-size synchronous ownership state changes
- **AND** the supported application API inventory remains unchanged
