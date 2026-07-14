## ADDED Requirements

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
