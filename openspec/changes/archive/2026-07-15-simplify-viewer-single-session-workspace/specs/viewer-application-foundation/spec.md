## MODIFIED Requirements

### Requirement: Viewer is a native single-window macOS application

The repository SHALL contain a manually maintained `Viewer/NearWireViewer.xcodeproj` with a native SwiftUI application named `NearWire`, module name `NearWireViewer`, one unit-test target, macOS 13 deployment, and Swift 5 language mode. It SHALL use the repository-local `NearWireCore` product and Apple frameworks only. It SHALL NOT add a nested package manifest, podspec, project generator, menu-bar agent, daemon, or root Swift Package dependency.

The application SHALL expose one main window, one process-scoped working Session, and no supported second-listener window or historical Source browser. Opening the window SHALL start one runtime generation without a Start button. Closing the last window or terminating the application SHALL synchronously close admission, stop publication/listening, cancel pending attempts, close the working Store, and await one idempotent cleanup receipt for at most one second without leaving a hidden listener. Expiry of that wait SHALL NOT reopen admission. The retained cleanup owner MAY continue finite removal retries while the process remains alive, and termination SHALL NOT wait without a bound. The working Session SHALL NOT be reopened as Viewer history on a later process launch.

#### Scenario: Main window opens and closes

- **WHEN** the NearWire main window opens and its runtime dependencies succeed
- **THEN** exactly one Viewer runtime generation and one working Session start automatically
- **AND** closing the last window stops that exact generation without a menu-bar, daemon, or retained historical Source lifetime

#### Scenario: Application is built from the repository

- **WHEN** the committed Viewer scheme is built and tested on macOS 13 compatibility settings
- **THEN** it compiles in Swift 5 language mode from the manual Xcode project
- **AND** no Viewer dependency appears in root `Package.swift` or `NearWire.podspec`

#### Scenario: Shutdown cleanup does not complete promptly

- **WHEN** application termination or identity reset closes a runtime whose owned handoff or working-Store cleanup does not complete within one second
- **THEN** the bounded wait returns without reopening listener admission
- **AND** the retained cleanup owner uses finite retries while the process remains alive, while an interrupted marked workspace is never reopened as history

### Requirement: Foundation UI is truthful and recovery-oriented

The main window SHALL show pairing/listener status, Copy, Refresh, Pause/Resume, the approval setting, pending approval actions, fixed identity/listener recovery actions, one bounded Devices strip, Session import/export actions, and Timeline/Inspector/Composer visibility controls. It SHALL NOT present a Sources or recorded-session sidebar. It SHALL label transport as `TLS encrypted; Viewer identity is not authenticated` and SHALL state that the pairing code and stable `vid` are visible to nearby Bonjour browsers. It SHALL NOT call either value a password, secret, authentication token, or secure connection proof.

All controls SHALL expose accessibility labels, help, keyboard focus, and disabled states derived from the single application model. Panel controls SHALL expose selected state without relying only on color. User-visible and diagnostic errors SHALL use closed safe categories and SHALL NOT include pairing code, Keychain labels, identity values, certificate data, endpoint/interface descriptions, wire bytes, App content, imported Event content, or arbitrary system error text.

#### Scenario: Listener is ready

- **WHEN** the exact service is registered
- **THEN** pairing, Device, Session, and available workspace actions use their truthful enabled states
- **AND** the TLS limitation remains visible

#### Scenario: Runtime enters a safe failure

- **WHEN** identity, listener, registration, admission, working Store, or Session transfer startup fails
- **THEN** the window remains usable with category-specific recovery actions
- **AND** no sensitive or untrusted diagnostic value is rendered
