# repository-structure Specification

## Purpose
TBD - created by archiving change project-bootstrap. Update Purpose after archive.
## Requirements
### Requirement: Authoritative monorepo roots

The repository SHALL use root-level `Core`, `SDK`, `Viewer`, `Demo`, `IntegrationTests`, and
`Documentation` directories, and SHALL keep `Package.swift`, `NearWire.podspec`,
`NearWire.xcworkspace`, `VERSION`, `README.md`, and `LICENSE` at the repository root. The repository
SHALL NOT require a custom validation-script directory when maintained product tests and standard
toolchain commands provide the required verification.

#### Scenario: Repository structure is inspected

- **WHEN** a clean checkout is inspected
- **THEN** every required root entry exists at its specified path
- **AND** no nested `Package.swift` or additional podspec exists below the repository root
- **AND** routine verification does not depend on a repository-specific `Scripts` directory

### Requirement: Shared Core ownership

The `Core` directory SHALL contain only platform-neutral event, protocol, transport, flow-control, identity, utility, built-in schema, and test-support code shared by SDK and Viewer.

#### Scenario: Platform framework isolation

- **WHEN** Core source imports are inspected
- **THEN** Core does not import UIKit, SwiftUI, or AppKit

### Requirement: Platform-specific ownership

iOS connection, lifecycle, UI, and performance collection code SHALL reside under `SDK`, while macOS listener, multi-device, persistence, search, renderer, and application code SHALL reside under `Viewer`.

#### Scenario: Performance model and collector placement

- **WHEN** the built-in performance capability is implemented
- **THEN** the cross-platform snapshot schema is located in Core
- **AND** iOS collectors are located in SDK
- **AND** Viewer projections and charts are located in Viewer

### Requirement: Root Demo ownership

The maintained integration Demo SHALL reside directly under the root `Demo` directory and SHALL not be duplicated under an `Examples` directory.

#### Scenario: Demo path validation

- **WHEN** Demo integration work begins
- **THEN** its Xcode project and source root are created below `Demo`
- **AND** no second Demo business implementation is created for a different package manager

### Requirement: Manual Apple project management

Viewer and Demo Xcode projects SHALL be manually maintained and committed, and the project SHALL NOT depend on Tuist, XcodeGen, or another project generator.

#### Scenario: Workspace composition

- **WHEN** Viewer and Demo project changes are complete
- **THEN** the root workspace references their committed `.xcodeproj` files using relative paths
- **AND** opening or building the workspace does not require a project-generation command

### Requirement: Viewer project is committed incrementally

The first Viewer application change SHALL create one manually maintained `Viewer/NearWireViewer.xcodeproj` and SHALL add it to root `NearWire.xcworkspace` with a relative reference. The project SHALL own Viewer application and Viewer unit-test sources below `Viewer`, SHALL reference the root repository package locally, and SHALL NOT create a second `Package.swift`, podspec, generated-project configuration, or Demo implementation.

#### Scenario: Viewer workspace composition

- **WHEN** the Viewer application foundation is complete
- **THEN** the root workspace opens the committed Viewer project without a generation step
- **AND** the not-yet-implemented Demo project remains absent rather than represented by a placeholder project

### Requirement: Demo project completes the root workspace

The repository SHALL contain one manually maintained `Demo/NearWireDemo.xcodeproj` below the root
Demo source tree. It SHALL contain the maintained SwiftPM application scheme, a CocoaPods consumer
target over the same business source membership, one small unit test target, and one launch
smoke UI-test target. The root `NearWire.xcworkspace` SHALL reference both Viewer and Demo projects
using repository-relative paths and SHALL build the SwiftPM Demo without project generation or
CocoaPods installation. The repository SHALL NOT add a nested package manifest, nested podspec,
project generator, second Demo implementation, or committed generated Pods state.

#### Scenario: Root workspace builds the Demo

- **WHEN** the root workspace resolves its local package and builds the `NearWireDemo` scheme
- **THEN** the committed iOS application compiles in Swift 5 language mode for iOS 16 compatibility
- **AND** Viewer and Demo remain separate manually maintained projects with only relative workspace references

#### Scenario: Demo source ownership is inspected

- **WHEN** application source membership is compared between SwiftPM and CocoaPods consumer targets
- **THEN** every Demo business and resource file is identical across the two targets
- **AND** no package-manager-specific copy, generated project, nested manifest, or alternate source root exists

#### Scenario: Repository is clean after CocoaPods validation

- **WHEN** the CocoaPods consumer is installed and built from a temporary root-layout snapshot that preserves the Demo's `..` package reference
- **THEN** the committed Demo project and source files remain byte-identical
- **AND** the canonical temporary root contains the expected package manifest, podspec, version, Core, and SDK inputs
- **AND** no Pods directory, generated workspace, lockfile, derived data, or package-manager mutation is added to Git
