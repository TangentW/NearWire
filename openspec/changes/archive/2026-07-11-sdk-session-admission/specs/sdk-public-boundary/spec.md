## MODIFIED Requirements

### Requirement: Public API work does not start session features early

NearWire construction and every supported public facade operation SHALL remain side-effect-free with respect to connection work and source-compatible. Repository-internal pairing, Bonjour discovery, secure session admission, and process connection ownership MAY begin only through their explicit internal operations. The process lease SHALL NOT be claimed by initialization, ordinary event APIs, or `SDKSessionAdmission`; the later public-connect orchestrator SHALL claim it explicitly before invoking admission.

This change SHALL add no supported connect/disconnect or lease API. Only one explicit internal admission `run()` MAY open the reviewed peer-to-peer-enabled TLS transport and negotiate hello/approval. It SHALL NOT mutate supported SDK state, negotiate effective rates, reconnect, observe background lifecycle, persist data, access Keychain, create UI, collect performance data, schedule recurring work, or transfer Events.

#### Scenario: Side-effect audit

- **WHEN** NearWire instances, idle admission values, and internal lease-capable types are constructed
- **THEN** no lease is claimed, browser starts, local-network permission is requested, connection opens, Task or timer is scheduled, persistence is accessed, or global ownership changes

#### Scenario: Explicit internal admission run

- **WHEN** repository-owned code explicitly runs one session admission
- **THEN** only that operation may start exact discovery, mandatory TLS, and hello/approval negotiation
- **AND** supported API inventory and NearWire state remain unchanged

#### Scenario: Explicit internal lease claim

- **WHEN** a later repository-owned public connection operation explicitly claims the process lease
- **THEN** only constant-size synchronous ownership state changes
- **AND** the supported application API inventory remains unchanged
