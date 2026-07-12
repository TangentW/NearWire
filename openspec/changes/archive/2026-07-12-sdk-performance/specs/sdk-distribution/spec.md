## MODIFIED Requirements

### Requirement: CocoaPods subspecs

The root `NearWire.podspec` SHALL target iOS 16, SHALL declare Swift version 5.0, SHALL use the `NearWire` module name, and SHALL provide Core, SDK, UI, and Performance subspecs over the same Core and SDK sources used by SwiftPM. SDK SHALL be the sole default subspec and SHALL package the base installation-identity privacy manifest through a uniquely named SDK resource bundle. The Performance subspec SHALL remain optional, SHALL depend only on SDK, MAY link UIKit and QuartzCore solely for its iOS collector source, and SHALL package its Performance Data privacy manifest through a separate uniquely named resource bundle. The podspec SHALL retain default CocoaPods linkage selection and SHALL NOT declare an unapproved framework, library, binary, script, compiler, or consumer build-setting injection.

#### Scenario: Default CocoaPods integration

- **WHEN** a consumer installs `NearWire` without naming a subspec
- **THEN** the Core and SDK sources are included
- **AND** UI and Performance sources and Performance-only framework declarations remain optional
- **AND** the base SDK Device ID privacy resource bundle is included while the Performance privacy bundle remains absent
- **AND** the consumer imports the `NearWire` module

#### Scenario: Performance CocoaPods integration

- **WHEN** a consumer installs `NearWire/Performance`
- **THEN** Core, SDK, and Performance source compile in one NearWire module for iOS 16 in Swift 5 language mode
- **AND** the supported Performance monitor API matches the SwiftPM product without exposing Core or collector internals
- **AND** the Performance privacy resource is packaged in addition to, and separately from, the base SDK Device ID resource

### Requirement: Supported public API isolation

Supported public SDK signatures SHALL declare their consumer-facing models in `NearWire`, `NearWireUI`, or `NearWirePerformance` and SHALL NOT expose types declared only in the internal NearWireCore, NearWireTransport, NearWireFlowControl, UI implementation, or Performance collector implementation modules.

#### Scenario: SwiftPM consumer API compilation

- **WHEN** a SwiftPM consumer imports a supported NearWire product and compiles its public API usage
- **THEN** the consumer does not need to import an internal Core module
- **AND** no supported signature contains an internal-only type

#### Scenario: CocoaPods consumer API compilation

- **WHEN** equivalent public API usage is compiled through the CocoaPods module with the corresponding optional subspec installed
- **THEN** it has the same supported source-level model boundary as the SwiftPM integration
