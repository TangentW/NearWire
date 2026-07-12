## MODIFIED Requirements

### Requirement: SDK implementation dependencies stay hidden

All top-level Core declarations SHALL use a repository-only SPI. Every supported public declaration in `NearWire`, `NearWireUI`, and `NearWirePerformance` SHALL use only standard-library, Foundation, SwiftUI where limited to NearWireUI view conformances and signatures, or supported SDK facade types. Boundary validation SHALL reject a supported public declaration that exposes a Core, flow-control, wire, transport, discovery, pre-handshake codec or typed result, admitted-message, Network.framework, Security.framework, internal UI controller/model/action, or Viewer-only type. A normal CocoaPods `import NearWire` SHALL NOT name Core SPI or internal NearWireUI declarations, and its non-SPI API inventory SHALL match SwiftPM for installed subspecs even though CocoaPods compiles Core and SDK sources into one module.

#### Scenario: Supported UI signatures are inspected

- **WHEN** SwiftPM and CocoaPods UI public inventories are generated
- **THEN** the aggregate CocoaPods UI-installed module matches the combined supported SwiftPM NearWire plus NearWireUI inventories
- **AND** the UI-added declaration delta is exactly `NearWireConnectionView`, `NearWireConnectionStatusView`, their exact public initializers, SwiftUI `View` conformance/body, and supported NearWire parameter types

#### Scenario: SDK-only CocoaPods consumer names UI

- **WHEN** a fixture installs the default SDK subspec without UI and attempts to name either public view
- **THEN** compilation fails, while a separate UI-subspec consumer can name both views

#### Scenario: Internal UI implementation is named by a consumer

- **WHEN** external code attempts to name the controller protocol, observable model, action generation, input limiter, status presentation model, or Task ownership type
- **THEN** compilation fails because those declarations are not public or SPI
