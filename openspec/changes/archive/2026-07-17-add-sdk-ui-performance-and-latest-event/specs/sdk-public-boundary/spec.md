## MODIFIED Requirements

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
