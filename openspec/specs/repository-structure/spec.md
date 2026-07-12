# repository-structure Specification

## Purpose
TBD - created by archiving change project-bootstrap. Update Purpose after archive.
## Requirements
### Requirement: Authoritative monorepo roots

The repository SHALL use root-level `Core`, `SDK`, `Viewer`, `Demo`, `IntegrationTests`, `Documentation`, and `Scripts` directories, and SHALL keep `Package.swift`, `NearWire.podspec`, `NearWire.xcworkspace`, `VERSION`, and the architecture document at the repository root.

#### Scenario: Repository structure validation

- **WHEN** the repository structure validation command runs
- **THEN** every required root entry exists at its specified path
- **AND** no nested `Package.swift` or additional podspec exists below the repository root

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
