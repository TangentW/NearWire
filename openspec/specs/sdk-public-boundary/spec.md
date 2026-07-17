# sdk-public-boundary Specification

## Purpose
TBD - created by archiving change sdk-public-api. Update Purpose after archive.
## Requirements
### Requirement: SwiftPM and CocoaPods expose one supported API

The repository SHALL compile the same representative iOS consumer source against the Swift Package product and CocoaPods default SDK subspec in Swift 5 language mode for iOS 16 or later. Both paths SHALL link the SDK's Apple Security.framework use without requiring a host-facing third-party dependency or supported Security type.

#### Scenario: Consumer compile gate

- **WHEN** distribution validation runs
- **THEN** construction, configuration including recovery policy, connect, disconnect, suspend, resume, public connection errors and status, state handling, send, decode, reply, streams, diagnostics, and shutdown compile through both integrations

### Requirement: SDK implementation dependencies stay hidden

All top-level Core declarations SHALL use a repository-only SPI. Every supported public declaration
in `NearWire`, `NearWireUI`, and `NearWirePerformance` SHALL use only standard-library, Foundation,
SwiftUI where limited to NearWireUI view conformances and signatures, or supported SDK facade
types. Boundary validation SHALL reject a supported public declaration that exposes a Core,
flow-control, wire, transport, discovery, pre-handshake codec or typed result, admitted-message,
Network.framework, Security.framework, internal UI controller/model/action/presentation, internal
performance collector/session/clock/lease, UIKit or QuartzCore implementation value, or Viewer-only
type. A normal CocoaPods `import NearWire` SHALL NOT name Core SPI or internal UI/Performance
declarations. Equivalent small consumers SHALL compile the supported API through SwiftPM and
installed CocoaPods subspecs even though CocoaPods merges Core and SDK sources into one module.

#### Scenario: Supported UI signatures are inspected

- **WHEN** SwiftPM and CocoaPods UI public inventories are generated
- **THEN** the aggregate CocoaPods UI-installed module matches the combined supported SwiftPM
  NearWire, NearWirePerformance, and NearWireUI inventories
- **AND** the UI-added declaration delta is exactly `NearWirePanelView`,
  `NearWireConnectionView`, `NearWireConnectionStatusView`,
  `NearWirePerformanceControlView`, `NearWireLatestViewerEventView`, their exact public
  initializers, SwiftUI `View` conformance/body, and supported NearWire or NearWirePerformance
  parameter types

#### Scenario: Supported Performance API is consumed

- **WHEN** small SwiftPM and CocoaPods Performance consumers compile the documented monitor,
  configuration, lifecycle state, and error surface
- **THEN** both integrations support that source-level usage
- **AND** the consumer-facing signatures require no snapshot, metric, battery/thermal, unavailable,
  collector, clock, lease, Core, or test-seam type

#### Scenario: SDK-only CocoaPods consumer names an optional module

- **WHEN** a fixture installs the default SDK subspec without UI or Performance and attempts to name
  an optional public type
- **THEN** compilation fails, while separate UI- and Performance-subspec consumers can name their
  approved public types

#### Scenario: Internal optional-module implementation is named by a consumer

- **WHEN** external code attempts to name an internal UI model/coordinator/presentation or
  Performance collector/session/clock/lease/test seam
- **THEN** compilation fails because those declarations are not public or SPI

### Requirement: Optional framework modules have a narrow built-in event bridge

The NearWire module SHALL expose a non-supported `NearWireBuiltins` SPI that admits validated reserved `nearwire.*` events through the same facade queue. It SHALL NOT expose the broader Core SPI or create a second buffering/session path.

#### Scenario: Performance module compiles through both distributions

- **WHEN** a repository-owned optional module imports the built-in SPI and sends `nearwire.performance.snapshot`
- **THEN** SwiftPM and CocoaPods compile the same call and normal application send still rejects that reserved type

### Requirement: Public API work does not start session features early

NearWire construction and every supported public operation without an explicit connection request or existing lifecycle intent SHALL remain side-effect-free with respect to connection ownership. Pairing and connection-limit validation SHALL precede lease claim. Only one token-current explicit connect or generation-current lifecycle recovery SHALL claim the lease, access installation identity, discover, open mandatory TLS, perform admission, attach the active pump, publish connection state, and transfer Events. Disconnect, suspension, shutdown, and active-owner deinitialization MAY only detach and cancel exact existing ownership and initiate terminal cleanup. Resume MAY start recovery only from an existing non-suspended intent. Ordinary Event and observation APIs SHALL NOT implicitly connect.

This change SHALL expose no active-pump handle, effective rate, lease, protocol, Network.framework, Security.framework, endpoint, certificate, or Keychain type. It SHALL register no automatic UIKit, SwiftUI scene, NotificationCenter, reachability, or background-execution observer. Supported signatures SHALL continue to use only standard-library, Foundation, or supported NearWire facade types. Products, targets, pod subspecs, third-party dependencies, entitlements, and privacy declarations SHALL remain unchanged.

#### Scenario: Side-effect audit

- **WHEN** NearWire is constructed and public operations without a valid explicit request or retained intent are exercised
- **THEN** no lease, Keychain, browser, permission request, connection, handshake, pump, lifecycle observer, or background work begins

#### Scenario: Explicit public connect

- **WHEN** a token-current call invokes connect with valid input
- **THEN** only that operation may compose the reviewed internal discovery, secure admission, and active pump
- **AND** no implementation type enters the supported API

#### Scenario: Lifecycle recovery

- **WHEN** a generation-current retained intent becomes eligible for resume or bounded transient recovery
- **THEN** only one fresh lifecycle attempt may compose the same reviewed pipeline

