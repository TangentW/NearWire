## ADDED Requirements

### Requirement: Viewer project is committed incrementally

The first Viewer application change SHALL create one manually maintained `Viewer/NearWireViewer.xcodeproj` and SHALL add it to root `NearWire.xcworkspace` with a relative reference. The project SHALL own Viewer application and Viewer unit-test sources below `Viewer`, SHALL reference the root repository package locally, and SHALL NOT create a second `Package.swift`, podspec, generated-project configuration, or Demo implementation.

#### Scenario: Viewer workspace composition

- **WHEN** the Viewer application foundation is complete
- **THEN** the root workspace opens the committed Viewer project without a generation step
- **AND** the not-yet-implemented Demo project remains absent rather than represented by a placeholder project
