## ADDED Requirements

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
