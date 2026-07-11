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

NearWire construction and the supported public facade SHALL remain side-effect-free and source-compatible. This change MAY add repository-internal pairing and Bonjour discovery that starts only through an explicit internal `run()` operation. It SHALL NOT add public connect/disconnect APIs, open a TCP or TLS connection, manage TLS identity, acquire a process-wide lease, negotiate a session or rate, reconnect, observe background lifecycle, persist data, create UI, collect performance data, schedule retry timers, or start hidden asynchronous work from NearWire initialization.

#### Scenario: Side-effect audit

- **WHEN** a NearWire instance and an internal discovery value are constructed
- **THEN** neither starts browsing, requests local-network permission, opens a connection, schedules a task or timer, accesses persistence, or changes global ownership

#### Scenario: Explicit internal discovery run

- **WHEN** a later repository-owned session explicitly invokes discovery run
- **THEN** only the bounded Bonjour browser lifecycle described by `sdk-bonjour-discovery` begins
- **AND** the supported application API inventory remains unchanged

