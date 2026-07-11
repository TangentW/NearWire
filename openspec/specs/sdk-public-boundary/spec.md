# sdk-public-boundary Specification

## Purpose
TBD - created by archiving change sdk-public-api. Update Purpose after archive.
## Requirements
### Requirement: SwiftPM and CocoaPods expose one supported API

The repository SHALL compile the same representative iOS consumer source against the Swift Package product and the CocoaPods default SDK subspec. Both paths SHALL use Swift 5 language mode and iOS 16 or later.

#### Scenario: Consumer compile gate

- **WHEN** repository distribution validation runs
- **THEN** construction, configuration, send, decode, reply, streams, diagnostics, and shutdown compile through both integrations

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

### Requirement: Optional framework modules have a narrow built-in event bridge

The NearWire module SHALL expose a non-supported `NearWireBuiltins` SPI that admits validated reserved `nearwire.*` events through the same facade queue. It SHALL NOT expose the broader Core SPI or create a second buffering/session path.

#### Scenario: Performance module compiles through both distributions

- **WHEN** a repository-owned optional module imports the built-in SPI and sends `nearwire.performance.snapshot`
- **THEN** SwiftPM and CocoaPods compile the same call and normal application send still rejects that reserved type

### Requirement: Public API work does not start session features early

NearWire construction and every supported public facade operation SHALL remain side-effect-free with respect to connection ownership and SHALL remain source-compatible. Repository-internal pairing, Bonjour discovery, secure session admission, process connection ownership, and active Event pumping MAY begin only through their explicit internal operations. The process lease SHALL NOT be claimed by initialization, ordinary event APIs, `SDKSessionAdmission`, or `SDKActiveEventPump`; the later public-connect orchestrator SHALL claim it explicitly before invoking admission.

This change SHALL add no supported connect/disconnect, lease, active-pump, or effective-rate API. Only one explicit internal admission `run()` MAY open the reviewed peer-to-peer-enabled TLS transport and negotiate hello/approval. Only one explicitly attached internal active-pump `run()` MAY negotiate effective flow policy, drain the bound NearWire queue, and publish validated incoming Events through that admitted transport. Neither operation SHALL publish supported SDK state, reconnect, observe background lifecycle, persist data, access Keychain, create UI, collect performance data, or schedule recurring polling work.

#### Scenario: Side-effect audit

- **WHEN** NearWire instances, idle admission values, active-pump values, and internal lease-capable types are constructed
- **THEN** no lease is claimed, browser starts, local-network permission is requested, connection opens, Task or timer is scheduled, queue drains, Event publishes, persistence is accessed, or global ownership changes

#### Scenario: Explicit internal admission run

- **WHEN** repository-owned code explicitly runs one session admission
- **THEN** only that operation may start exact discovery, mandatory TLS, and hello/approval negotiation
- **AND** supported API inventory and NearWire state remain unchanged

#### Scenario: Explicit internal active-pump run

- **WHEN** repository-owned code explicitly runs one pump for an attached admitted owner
- **THEN** only that operation may negotiate flow policy and transfer Events on the existing admitted route
- **AND** process lease, supported API inventory, and NearWire state remain unchanged

#### Scenario: Explicit internal lease claim

- **WHEN** a later repository-owned public connection operation explicitly claims the process lease
- **THEN** only constant-size synchronous ownership state changes
- **AND** the supported application API inventory remains unchanged

