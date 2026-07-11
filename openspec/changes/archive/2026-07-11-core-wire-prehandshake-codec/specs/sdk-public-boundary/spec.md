## MODIFIED Requirements

### Requirement: SDK implementation dependencies stay hidden

All top-level Core declarations SHALL use a repository-only SPI. Every supported public declaration in `NearWire`, `NearWireUI`, and `NearWirePerformance` SHALL use only standard-library, Foundation, or supported SDK facade types. Boundary validation SHALL reject a supported public declaration that exposes a Core, flow-control, wire, transport, discovery, pre-handshake codec or typed result, admitted-message, Network.framework, Security.framework, or Viewer-only type. A normal CocoaPods `import NearWire` SHALL NOT name Core SPI declarations, and its non-SPI API inventory SHALL match SwiftPM, including when CocoaPods compiles Core and SDK sources into one module.

#### Scenario: Implementation type enters a public signature

- **WHEN** a source change returns or accepts an implementation-only type publicly
- **THEN** the boundary gate fails before archive

#### Scenario: CocoaPods consumer tries a Core value

- **WHEN** a normal CocoaPods consumer imports NearWire and names a Core event, pre-handshake codec, typed result, or admitted-message value
- **THEN** compilation fails because the declaration requires the internal SPI

#### Scenario: Consumer compiles supported API

- **WHEN** external SwiftPM and CocoaPods fixtures import a supported SDK product and use its documented public API
- **THEN** they compile without importing or naming Core modules, `WirePreHandshakeCodec`, `WirePreHandshakeMessage`, `WireAdmittedMessage`, raw wire messages, payload protocols, Network.framework transport values, or Security framework values
