## MODIFIED Requirements

### Requirement: Foundation UI is truthful and recovery-oriented

The main window SHALL show pairing/listener status, Copy, Refresh, Pause/Resume, the approval setting, pending approval actions, fixed identity/listener recovery actions, one bounded Devices strip, memory-Session import/export actions, and Timeline/Inspector/Composer visibility controls. It SHALL NOT present a Sources or recorded-session sidebar, local-database settings, database status, cleanup, retry, capacity, retention, or durable-recording state. It SHALL label transport as `TLS encrypted; Viewer identity is not authenticated` and SHALL state that the pairing code and stable `vid` are visible to nearby Bonjour browsers.

All controls SHALL expose accessibility labels, help, keyboard focus, and disabled states derived from the single application model. User-visible and diagnostic errors SHALL use closed safe categories and SHALL NOT include pairing code, identity material, endpoint/interface descriptions, wire bytes, App content, imported Event content, or arbitrary system error text.

#### Scenario: Listener is ready

- **WHEN** the exact service is registered
- **THEN** pairing, Device, memory-Session, and available workspace actions use truthful enabled states
- **AND** no database lifecycle or storage setting is presented

### Requirement: Viewer is a native multi-window macOS application

The repository SHALL contain a manually maintained `Viewer/NearWireViewer.xcodeproj` with a native SwiftUI application named `NearWire`, module name `NearWireViewer`, one unit-test target, macOS 13 deployment, and Swift 5 language mode. It SHALL use the repository-local `NearWireCore` product and Apple frameworks only. It SHALL NOT add a nested package manifest, podspec, project generator, menu-bar agent, daemon, root Swift Package dependency, or local Session database.

The application SHALL expose one singleton main Event window, one singleton auxiliary Performance window, one process-lifetime memory Session, and no supported second-listener window or historical Source browser. Opening the application SHALL start one runtime generation without a Start button. Either window MAY remain open or reopen while reusing that exact runtime generation. Closing the last window or terminating the application SHALL synchronously close admission, stop publication/listening, cancel pending attempts, clear received memory content, and await one idempotent cleanup receipt for at most one second without leaving a hidden listener. Expiry of that wait SHALL NOT reopen admission.

#### Scenario: Main and Performance windows open and close

- **WHEN** the NearWire main window starts one successful runtime and the operator opens Performance
- **THEN** exactly one Viewer runtime generation and one memory Session serve both singleton windows
- **AND** closing the last window stops that generation and clears its Session without a database, menu-bar item, daemon, or historical Source lifetime
