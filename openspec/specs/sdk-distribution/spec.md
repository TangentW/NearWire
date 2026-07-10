# sdk-distribution Specification

## Purpose
TBD - created by archiving change project-bootstrap. Update Purpose after archive.
## Requirements
### Requirement: Swift Package products

The root Swift Package SHALL support iOS 16 and macOS 13, SHALL compile in Swift 5 language mode on Xcode 16, and SHALL provide `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore` library products from explicit paths under Core and SDK.

#### Scenario: Swift Package build

- **WHEN** the package is resolved, built, and tested with Xcode 16
- **THEN** every declared target compiles in Swift 5 language mode
- **AND** all package tests pass

### Requirement: CocoaPods subspecs

The root `NearWire.podspec` SHALL target iOS 16, SHALL declare Swift version 5.0, SHALL use the `NearWire` module name, and SHALL provide Core, SDK, UI, and Performance subspecs over the same Core and SDK sources used by SwiftPM. SDK SHALL be the sole default subspec. The podspec SHALL retain default CocoaPods linkage selection and SHALL NOT declare unapproved framework, library, binary, script, compiler, or consumer build-setting injection.

#### Scenario: Default CocoaPods integration

- **WHEN** a consumer installs `NearWire` without naming a subspec
- **THEN** the Core and SDK sources are included
- **AND** UI and Performance sources remain optional
- **AND** the consumer imports the `NearWire` module

### Requirement: SDK dependency isolation

Core and SDK runtime targets SHALL NOT depend on third-party packages or pods. Viewer-only dependencies SHALL be owned by the Viewer Xcode project and SHALL NOT appear in the root Package manifest.

#### Scenario: Dependency graph validation

- **WHEN** the root Swift Package dependency graph is inspected
- **THEN** it contains no external package dependency
- **AND** SDK consumers do not resolve Viewer-only libraries

### Requirement: Swift compatibility definition

NearWire SHALL define Swift 5 compatibility as Swift 5 language mode and `SWIFT_VERSION = 5.0` compiled by Xcode 16, and SHALL NOT claim compatibility with legacy compilers that cannot compile modern concurrency syntax.

#### Scenario: Modern concurrency in Swift 5 mode

- **WHEN** public SDK source uses async/await, actor, AsyncSequence, or Sendable
- **THEN** it compiles with Xcode 16 in Swift 5 language mode
- **AND** the documentation does not claim Xcode 10.2 or legacy Swift 5.0 compiler support

### Requirement: Unified release version

The repository SHALL use one semantic release version for SDK, Viewer marketing version, CocoaPods, and Git tags, while protocol versioning remains independent.

#### Scenario: Release version validation

- **WHEN** a release validation runs
- **THEN** root `VERSION`, podspec version, Viewer marketing version when present, and the intended Git tag agree
- **AND** protocol version is not inferred from the product version

### Requirement: Supported public API isolation

Supported public SDK signatures SHALL declare their consumer-facing models in `NearWire`, `NearWireUI`, or `NearWirePerformance` and SHALL NOT expose types declared only in the internal NearWireCore, NearWireTransport, or NearWireFlowControl modules.

#### Scenario: SwiftPM consumer API compilation

- **WHEN** a SwiftPM consumer imports a supported NearWire product and compiles its public API usage
- **THEN** the consumer does not need to import an internal Core module
- **AND** no supported signature contains an internal-only type

#### Scenario: CocoaPods consumer API compilation

- **WHEN** equivalent public API usage is compiled through the CocoaPods module
- **THEN** it has the same supported source-level model boundary as the SwiftPM integration
