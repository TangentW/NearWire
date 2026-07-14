# NearWire

NearWire is a local, bidirectional event platform for iOS applications and a native macOS Viewer. It uses Bonjour discovery, peer-to-peer-enabled Network.framework connections, and mandatory TLS without a central service.

The repository is under active development. Implementation changes are specified through OpenSpec before code is applied.

The supported SDK event and explicit connection facade is documented in [Documentation/SDK-Public-API.md](Documentation/SDK-Public-API.md). The optional injected SwiftUI panel is documented in [Documentation/SDK-UI.md](Documentation/SDK-UI.md), and the optional performance monitor in [Documentation/SDK-Performance.md](Documentation/SDK-Performance.md). Pairing and Bonjour behavior is documented in [Documentation/SDK-Discovery.md](Documentation/SDK-Discovery.md), process ownership in [Documentation/SDK-Connection-Lease.md](Documentation/SDK-Connection-Lease.md), the secure hello and approval sequence in [Documentation/SDK-Session-Admission.md](Documentation/SDK-Session-Admission.md), and bidirectional transfer in [Documentation/SDK-Active-Event-Pump.md](Documentation/SDK-Active-Event-Pump.md).

The native macOS listener, persistent Viewer identity, pairing-code publication, bounded new-device admission, sandbox, and recovery behavior are documented in [Documentation/Viewer-Foundation.md](Documentation/Viewer-Foundation.md). Event inspection, live-versus-recorded semantics, filtering, history operations, JSON export, and Viewer-to-App control composition are documented in [Documentation/Viewer-Event-Explorer.md](Documentation/Viewer-Event-Explorer.md). The single-device performance analysis surface, time and availability semantics, projection bounds, raw traceability, and privacy behavior are documented in [Documentation/Viewer-Performance.md](Documentation/Viewer-Performance.md).

The maintained iOS reference application and its Swift Package Manager and CocoaPods workflows are documented in [Demo/README.md](Demo/README.md).

```swift
let nearWire = NearWire()
try await nearWire.connect(code: "ABC234")
try await nearWire.send(type: "debug.snapshot", content: snapshot)
await nearWire.disconnect()
```

Applications that want the standard connection controls can inject that same instance into the optional UI product:

```swift
import NearWireUI

NearWireConnectionView(nearWire: nearWire)
```

Applications can also inject the same instance into the optional performance monitor. Sampling remains stopped until `start()`:

```swift
import NearWirePerformance

let monitor = NearWirePerformanceMonitor(nearWire: nearWire)
try await monitor.start()
```

Connection uses peer-to-peer-enabled Bonjour discovery and mandatory TLS 1.3. The pairing code selects the Viewer but is not an authentication credential, and Event delivery is not acknowledged. Automatic recovery is opt-in and bounded; host-controlled suspend/resume never installs a hidden application lifecycle observer.

## Repository Layout

- `Core`: Shared event, protocol, transport, flow-control, and built-in schema code.
- `SDK`: iOS public API, discovery, session, optional UI, and performance collectors.
- `Viewer`: Native macOS application code and Viewer-only infrastructure.
- `Demo`: Maintained iOS integration application.
- `IntegrationTests`: Cross-module protocol, compatibility, and end-to-end fixtures.
- `Documentation`: English integration and engineering documentation.
- `openspec`: Active and archived specifications for every implementation change.

## Toolchain

- Xcode 16 or later
- iOS 16 or later
- macOS 13 or later
- Swift 5 language mode using the Xcode 16 compiler
- CocoaPods 1.16 or later for podspec validation

Swift 5 compatibility refers to the language mode and `SWIFT_VERSION = 5.0`. NearWire uses modern concurrency APIs and does not support legacy Swift 5.0 compilers.

## Package Products

- `NearWire`: Primary iOS SDK product.
- `NearWireUI`: Optional connection UI product.
- `NearWirePerformance`: Optional built-in performance collection product.
- `NearWireCore`: Internal shared product used by NearWire and the local Viewer build. It is not a supported consumer API.

## Development Workflow

Only one OpenSpec implementation change may be in apply or remediation at a time. A change must complete specification, implementation, tests, multi-agent review rounds, and zero-unresolved-finding verification before it is archived and the next change begins.

Run the bootstrap quality gate with:

```sh
./Scripts/verify-bootstrap.sh
```

## License

NearWire is available under the MIT License. See [LICENSE](LICENSE) for details.
