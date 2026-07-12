## Why

NearWire now has a complete instance-based connection lifecycle, but every host App must still build and maintain the same pairing-code, connection-status, error, and disconnect UI. The optional `NearWireUI` product already exists as an empty distribution shell; it needs one small native SwiftUI surface that applications can adopt without giving the UI hidden ownership of SDK construction, persistence, or App lifecycle policy.

## What Changes

- Add `NearWireConnectionView`, an opinionated system-native SwiftUI connection panel initialized with an existing `NearWire` instance.
- Add `NearWireConnectionStatusView`, a value-driven status component initialized with `NearWireConnectionStatus` for applications that want to compose their own surrounding UI.
- Keep pairing input in bounded view-local memory, forward it only to explicit user-initiated `connect(code:)`, clear it after success or view teardown, and never persist, log, reflect, or expose it through a public getter.
- Observe the injected instance's latest-value connection-status stream only while the panel is presented. View construction starts no Task, discovery, connection, timer, Keychain, disk, or notification work.
- Serialize UI actions in one internal exact-controller operation coordinator. Per injected instance it owns at most one Connect Task and one preempting Disconnect Task, while every live panel receives the same latest coordinator phase through an independently cancellable one-value subscription; repeated panels cannot start another operation while cancellation or cleanup remains unacknowledged.
- Use native SwiftUI controls, semantic colors, Dynamic Type, SF Symbols by name, text plus icon status, and accessibility labels. Add no image asset, resource bundle, custom font, third-party dependency, or alternate design system.
- Use a conservative action matrix expressible through supported status: terminal error states offer an explicit Disconnect/reset beside Connect, UI-owned pending Connect offers Cancel, and a preflight ownership error reveals reset without guessing private intent. Keep automatic connection, automatic disconnect of an active session, suspension/resumption policy, App lifecycle observation, persistence, navigation, alerts, Viewer UI, and performance UI out of scope.

## Capabilities

### New Capabilities

- `sdk-ui`: Optional injected-instance SwiftUI connection and status components with bounded local state and explicit user actions.

### Modified Capabilities

- `sdk-public-boundary`: The two NearWireUI view types become supported public API through SwiftPM and the CocoaPods UI subspec without exposing internal controller or model types.

## Impact

The change affects only `SDK/Sources/NearWireUI`, `SDK/Tests/NearWireUITests`, public API consumer fixtures, SDK UI documentation, distribution validation, and OpenSpec evidence. It adds no target, product, pod subspec, entitlement, privacy declaration, resource bundle, persistence, runtime dependency, SDK lifecycle observer, or change to `NearWire` connection semantics.
