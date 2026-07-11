# NearWire

NearWire is a local, bidirectional event platform for iOS applications and a native macOS Viewer. It uses Bonjour discovery, peer-to-peer-enabled Network.framework connections, and mandatory TLS without a central service.

The repository is under active development. The architecture is defined in [NearWire-Platform-Architecture.md](NearWire-Platform-Architecture.md), and every implementation change is specified through OpenSpec before code is applied.

The current supported SDK event facade is documented in [Documentation/SDK-Public-API.md](Documentation/SDK-Public-API.md). Repository-internal pairing and Bonjour behavior is documented in [Documentation/SDK-Discovery.md](Documentation/SDK-Discovery.md), the internal process ownership primitive is documented in [Documentation/SDK-Connection-Lease.md](Documentation/SDK-Connection-Lease.md), and the internal secure hello and approval sequence is documented in [Documentation/SDK-Session-Admission.md](Documentation/SDK-Session-Admission.md). Public connection APIs and active event transfer remain scheduled for later roadmap changes.

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
