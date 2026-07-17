# sdk-distribution Specification

## Purpose
TBD - created by archiving change project-bootstrap. Update Purpose after archive.
## Requirements
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

Supported public SDK signatures SHALL declare their consumer-facing models in `NearWire`, `NearWireUI`, or `NearWirePerformance` and SHALL NOT expose types declared only in the internal NearWireCore, NearWireTransport, NearWireFlowControl, UI implementation, or Performance collector implementation modules.

#### Scenario: SwiftPM consumer API compilation

- **WHEN** a SwiftPM consumer imports a supported NearWire product and compiles its public API usage
- **THEN** the consumer does not need to import an internal Core module
- **AND** no supported signature contains an internal-only type

#### Scenario: CocoaPods consumer API compilation

- **WHEN** equivalent public API usage is compiled through the CocoaPods module with the corresponding optional subspec installed
- **THEN** it has the same supported source-level model boundary as the SwiftPM integration

### Requirement: Maintained Demo proves SwiftPM and CocoaPods application parity

The repository SHALL compile the same maintained Demo business source and resources as an iOS 16
application through the root Swift Package products and through CocoaPods `NearWire/UI` plus
`NearWire/Performance`. Both paths SHALL compile in Swift 5 language mode with warnings as errors,
SHALL use only supported public API, and SHALL exercise equivalent connection UI, Event,
diagnostics, control-reply, and Performance call sites. `NearWire` SHALL be imported
unconditionally; a SwiftPM-App-only compilation condition SHALL guard only the separate UI and
Performance module imports and SHALL NOT alter behavior. CocoaPods installation SHALL run in a
temporary root-layout snapshot against its canonical copied root podspec and SHALL NOT commit
generated integration state. The Podfile SHALL default to the parent of `Demo`, canonicalize any
`NEARWIRE_ROOT` override, validate the expected repository markers, and record the resolved identity.

#### Scenario: Swift Package Demo builds

- **WHEN** the root workspace builds and tests the `NearWireDemo` scheme on an iOS Simulator
- **THEN** the App links `NearWire`, `NearWireUI`, and `NearWirePerformance` from the repository-local package
- **AND** no Viewer-only or third-party dependency enters the root package graph

#### Scenario: CocoaPods Demo builds

- **WHEN** CocoaPods 1.16 or later installs the local UI and Performance subspecs for `NearWireDemoCocoaPods`
- **THEN** the generated temporary workspace builds the same Demo source and resources for an iOS Simulator
- **AND** the App imports the single CocoaPods `NearWire` module without implementation-only API

#### Scenario: Package-manager source parity is audited

- **WHEN** target membership, public call sites, deployment target, Swift language mode, and host resources are compared
- **THEN** both consumer paths are equivalent except for bundle identifier, product name, module imports, and package-manager linkage metadata
- **AND** no second behavior implementation or package-manager conditional behavior exists

### Requirement: Built Demo products expose complete privacy composition inputs

Both Demo distribution paths SHALL embed the base SDK Device ID privacy resource and the optional
Performance Data privacy resource as separate valid bundles. The built host Info.plist SHALL contain
the exact local-network and Bonjour declarations, and no default-only SDK consumer SHALL be required
to embed the optional Performance resource. Validation SHALL inspect real built App products rather
than infer composition only from manifests. An unsigned generic iOS archive SHALL be prepared for
Xcode's App Privacy Report action. When host UI automation is available, the exported report plus
archive identity SHALL be saved as evidence. When macOS denies UI automation and Xcode exposes no
command-line equivalent, the exact failed access and tool search SHALL be recorded, no report SHALL
be claimed, and report export SHALL remain a mandatory `release-hardening` gate. The configured
signed archive privacy report, embedded entitlement assertion, and stable-signer update matrix SHALL
remain mandatory `release-hardening` gates.

#### Scenario: SwiftPM App privacy inputs are inspected

- **WHEN** the SwiftPM Demo App and unsigned generic iOS archive are built
- **THEN** exact base and Performance privacy manifests are present in separate embedded resource bundles
- **AND** Xcode exports an App Privacy Report whose inspected inputs include both owning products when host UI automation is available
- **OR** the denied UI access and absence of a command-line exporter are recorded without claiming report completion

#### Scenario: CocoaPods App privacy inputs are inspected

- **WHEN** the CocoaPods Demo App product is built from the temporary workspace
- **THEN** its separate SDK and Performance privacy bundles contain the exact root manifests
- **AND** generated Pods state is not mistaken for committed product evidence

#### Scenario: Signing evidence is not available in this change

- **WHEN** completion evidence summarizes the unsigned Demo builds and App Privacy Report or its recorded host-UI limitation
- **THEN** it explicitly excludes installed-device permissions, signed entitlement embedding, Keychain update continuity, and stable-signer behavior
- **AND** those checks remain open for `release-hardening`

### Requirement: Demo and repository release metadata remain coherent

Both Demo application targets' `MARKETING_VERSION` values SHALL equal the root `VERSION` value used
by the podspec and Viewer, SHALL use explicit internal build numbers, and SHALL NOT infer wire
protocol version from product version. The version validation gate SHALL compare root `VERSION`, the
podspec, compiled SDK metadata, Viewer, and every Demo configuration rather than claiming duplicated
Xcode literals are sourced dynamically. The checked-in projects and Podfile SHALL use
repository-relative paths and SHALL contain no developer team, provisioning profile UUID, signing
certificate hash, absolute user path, or generated dependency lock.

#### Scenario: Demo metadata is inspected

- **WHEN** project build settings, root version, podspec evaluation, and workspace references are validated
- **THEN** product versions and relative paths are coherent and protocol version remains independent
- **AND** no machine-specific signing or generated package-manager state is committed
