# NearWireUI

NearWireUI is the optional SwiftUI connection surface for applications that do not want to build their own pairing panel. It supports iOS 16 and later, retains the host application's injected `NearWire` instance while the view exists, and never constructs or replaces that facade. The host remains the connection-lifecycle policy owner.

## Integration

With Swift Package Manager, add both `NearWire` and `NearWireUI` to the application target. With CocoaPods, install the optional UI subspec:

```ruby
pod "NearWire/UI"
```

Inject the same configured SDK instance that the rest of the application uses:

```swift
import NearWire
import NearWireUI

struct DiagnosticsView: View {
  let nearWire: NearWire

  var body: some View {
    NearWireConnectionView(nearWire: nearWire)
  }
}
```

Applications that already own their connection controls can render a snapshot without starting any observation or action:

```swift
NearWireConnectionStatusView(status: currentStatus)
```

These are the only supported NearWireUI types. The connection model, controller seam, input limiter, action state, and operation coordinator are implementation details.

## Ownership and Actions

Constructing either view starts no Task, discovery, connection, timer, persistence, Keychain access, or application lifecycle observation. A presented connection panel observes the injected instance's latest connection status and a process-local UI action gate. It offers the conservative action that public state can support:

- idle or error-free disconnected: Connect;
- a UI-started pending attempt: Cancel;
- discovering, connecting, connected, reconnecting, or suspended: Disconnect;
- disconnected with an error or an ownership preflight failure: Connect plus Reset Connection;
- cancelling or disconnecting: a disabled progress action;
- shutdown: no action.

Cancel preempts the pending Connect by cancelling that Task and immediately joining one shared `disconnect()` call. The panel remains Disconnecting until both operations acknowledge completion. Repeated panels for the same `NearWire` instance share this gate and cannot start duplicate connection work.

Ordinary disappearance is different: it cancels a UI-started pending Connect and stops observation, but does not automatically disconnect an active host-owned session. The application remains responsible for retaining the `NearWire` instance and for choosing when to call `disconnect()`, `suspendConnection()`, `resumeConnection()`, or `shutdown()`.

## Pairing Input and Errors

The field retains at most 64 UTF-8 bytes and truncates only at a Unicode-scalar boundary. It forwards the exact retained value after explicit activation; the SDK remains the only pairing grammar and normalization authority. Input is memory-only and clears after success, Cancel/Disconnect, disappearance, or model teardown. A failed Connect may retain the bounded value while the panel remains visible. If a cancelled Connect does not cooperate immediately, the coordinator may retain one separate bounded argument copy until that exact SDK call returns. Swift `String` does not provide secure zeroization, and NearWireUI makes no secure-erasure guarantee.

NearWireUI displays only the content-safe message from `NearWireError`. An unexpected error becomes the fixed sentence `NearWire could not complete the connection action.` Its underlying description is never interpolated. The UI adds no logging, analytics, pasteboard, camera, persistence, reachability, notification, lifecycle, or background-execution behavior.

## Accessibility and Localization

The components use native semantic SwiftUI layout, Dynamic Type, SF Symbols, visible text, icons, progress indicators, and combined accessibility labels and hints. Connected, disconnected, paused, progress, shutdown, and error states do not rely on color alone. The controls support keyboard submission when Connect is available.

V1 strings are fixed English and are not localized. The components do not promise automatic live-region announcement on iOS 16 or macOS 13; a host that requires a specialized announcement policy should build its own controls from `connectionStatuses`.

NearWireUI uses Foundation only for bounded in-memory synchronization. It uses no resource bundle, custom font, image asset, third-party dependency, UIKit/AppKit wrapper, or absolute screen geometry.
