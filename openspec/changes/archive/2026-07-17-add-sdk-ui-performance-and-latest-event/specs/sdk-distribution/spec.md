## MODIFIED Requirements

### Requirement: Swift Package products

The root Swift Package SHALL support iOS 16 and macOS 13, SHALL compile in Swift 5 language mode on
Xcode 16, and SHALL provide `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal
`NearWireCore` library products from explicit paths under Core and SDK. NearWireUI SHALL depend on
NearWire and NearWirePerformance so its host-injected controls have the same implementation and
privacy composition as direct Performance integration. The NearWire product SHALL remain independent
of both optional products.

#### Scenario: Swift Package build

- **WHEN** the package is resolved, built, and tested with Xcode 16
- **THEN** every declared target compiles in Swift 5 language mode
- **AND** all package tests pass

#### Scenario: Swift Package UI integration

- **WHEN** a consumer links NearWireUI
- **THEN** NearWirePerformance and its separate privacy resource are included transitively
- **AND** a consumer linking only NearWire receives neither optional implementation

### Requirement: CocoaPods subspecs

The root `NearWire.podspec` SHALL target iOS 16, SHALL declare Swift version 5.0, SHALL use the
`NearWire` module name, and SHALL provide Core, SDK, UI, and Performance subspecs over the same Core
and SDK sources used by SwiftPM. SDK SHALL be the sole default subspec and SHALL package the base
installation-identity privacy manifest through a uniquely named SDK resource bundle. The Performance
subspec SHALL remain optional, SHALL depend only on SDK, MAY link UIKit and QuartzCore solely for its
iOS collector source, and SHALL package its Performance Data privacy manifest through a separate
uniquely named resource bundle. The UI subspec SHALL depend on Performance, which transitively
includes SDK, and SHALL add no other framework or resource. The podspec SHALL retain default
CocoaPods linkage selection and SHALL NOT declare an unapproved framework, library, binary, script,
compiler, or consumer build-setting injection.

#### Scenario: Default CocoaPods integration

- **WHEN** a consumer installs `NearWire` without naming a subspec
- **THEN** the Core and SDK sources are included
- **AND** UI and Performance sources and Performance-only framework declarations remain optional
- **AND** the base SDK Device ID privacy resource bundle is included while the Performance privacy
  bundle remains absent
- **AND** the consumer imports the `NearWire` module

#### Scenario: Performance CocoaPods integration

- **WHEN** a consumer installs `NearWire/Performance`
- **THEN** Core, SDK, and Performance source compile in one NearWire module for iOS 16 in Swift 5
  language mode
- **AND** the supported Performance monitor API matches the SwiftPM product without exposing Core
  or collector internals
- **AND** the Performance privacy resource is packaged in addition to, and separately from, the base
  SDK Device ID resource

#### Scenario: UI CocoaPods integration

- **WHEN** a consumer installs `NearWire/UI`
- **THEN** Core, SDK, Performance, and UI sources compile in one NearWire module
- **AND** the SDK and Performance privacy resources remain separate while the default subspec is
  unchanged
