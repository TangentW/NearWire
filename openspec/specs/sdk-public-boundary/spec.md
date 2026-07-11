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

All top-level Core declarations SHALL use a repository-only SPI. Boundary validation SHALL reject a supported public declaration that exposes a Core, flow-control, transport, Network.framework, Security.framework, or Viewer-only type. A normal CocoaPods `import NearWire` SHALL NOT name Core SPI declarations, and its non-SPI API inventory SHALL match SwiftPM.

#### Scenario: Implementation type enters a public signature

- **WHEN** a source change returns or accepts an implementation-only type publicly
- **THEN** the boundary gate fails before archive

#### Scenario: CocoaPods consumer tries a Core value

- **WHEN** a normal CocoaPods consumer imports NearWire and names a Core event value
- **THEN** compilation fails because the declaration requires the internal SPI

### Requirement: Optional framework modules have a narrow built-in event bridge

The NearWire module SHALL expose a non-supported `NearWireBuiltins` SPI that admits validated reserved `nearwire.*` events through the same facade queue. It SHALL NOT expose the broader Core SPI or create a second buffering/session path.

#### Scenario: Performance module compiles through both distributions

- **WHEN** a repository-owned optional module imports the built-in SPI and sends `nearwire.performance.snapshot`
- **THEN** SwiftPM and CocoaPods compile the same call and normal application send still rejects that reserved type

### Requirement: Public API work does not start session features early

NearWire construction and the supported public facade SHALL remain side-effect-free and source-compatible. Repository-internal pairing, Bonjour discovery, and process connection ownership MAY begin only through their explicit internal operations. The process lease SHALL NOT be claimed by initialization or ordinary event APIs. This change SHALL NOT add public connect/disconnect or lease APIs, open TCP/TLS, manage TLS identity, negotiate a session or rate, reconnect, observe background lifecycle, persist data, create UI, collect performance data, schedule work, or transfer events.

#### Scenario: Side-effect audit

- **WHEN** NearWire instances and internal lease-capable types are constructed
- **THEN** no lease is claimed, browser starts, local-network permission is requested, connection opens, task or timer is scheduled, persistence is accessed, or global ownership changes

#### Scenario: Explicit internal lease claim

- **WHEN** a later repository-owned connection operation explicitly claims the process lease
- **THEN** only constant-size synchronous ownership state changes
- **AND** the supported application API inventory remains unchanged

