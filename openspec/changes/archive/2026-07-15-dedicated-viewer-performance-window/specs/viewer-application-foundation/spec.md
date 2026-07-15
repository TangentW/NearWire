## MODIFIED Requirements

### Requirement: Viewer is a native multi-window macOS application

The repository SHALL contain a manually maintained `Viewer/NearWireViewer.xcodeproj` with a native SwiftUI application named `NearWire`, module name `NearWireViewer`, one unit-test target, macOS 13 deployment, and Swift 5 language mode. It SHALL use the repository-local `NearWireCore` product and Apple frameworks only. It SHALL NOT add a nested package manifest, podspec, project generator, menu-bar agent, daemon, or root Swift Package dependency.

The application SHALL expose one singleton main Event window, one singleton auxiliary Performance window, one process-scoped working Session, and no supported second-listener window or historical Source browser. Opening the application SHALL start one runtime generation without a Start button. Either supported window MAY remain open or reopen while reusing that exact runtime generation. Closing the last window or terminating the application SHALL synchronously close admission, stop publication/listening, cancel pending attempts, close the working Store, and await one idempotent cleanup receipt for at most one second without leaving a hidden listener. Expiry of that wait SHALL NOT reopen admission. The retained cleanup owner MAY continue finite removal retries while the process remains alive, and termination SHALL NOT wait without a bound. The working Session SHALL NOT be reopened as Viewer history on a later process launch.

#### Scenario: Main and Performance windows open and close

- **WHEN** the NearWire main window starts one successful runtime and the operator opens Performance
- **THEN** exactly one Viewer runtime generation and one working Session serve both singleton windows
- **AND** closing only one window preserves that generation while the other remains open
- **AND** closing the last window stops that exact generation without a menu-bar, daemon, or retained historical Source lifetime

#### Scenario: Application is built from the repository

- **WHEN** the committed Viewer scheme is built and tested on macOS 13 compatibility settings
- **THEN** it compiles in Swift 5 language mode from the manual Xcode project
- **AND** no Viewer dependency appears in root `Package.swift` or `NearWire.podspec`

#### Scenario: Shutdown cleanup does not complete promptly

- **WHEN** application termination or identity reset closes a runtime whose owned handoff or working-Store cleanup does not complete within one second
- **THEN** the bounded wait returns without reopening listener admission
- **AND** the retained cleanup owner uses finite retries while the process remains alive, while an interrupted marked workspace is never reopened as history

## RENAMED Requirements

- FROM: `### Requirement: Viewer is a native single-window macOS application`
- TO: `### Requirement: Viewer is a native multi-window macOS application`
