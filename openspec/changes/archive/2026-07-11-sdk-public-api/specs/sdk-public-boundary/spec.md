## ADDED Requirements

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

This change SHALL NOT add public connect/disconnect/pairing methods, Bonjour behavior, Network.framework connection work, TLS identity lifecycle, process-wide leases, rate negotiation, reconnection, background execution, persistence, UI, performance collection, timers, or hidden asynchronous tasks.

#### Scenario: Side-effect audit

- **WHEN** SDK sources and tests are audited
- **THEN** all behavior is limited to local validation, bounded memory, explicit actor calls, observation, and shutdown
