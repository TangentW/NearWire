# SDK Process Connection Lease

## Why

NearWire instances intentionally remain independent, but the product permits only one active Viewer connection attempt in one host App process. Discovery and session admission need one small, race-safe ownership primitive before public `connect(code:)` can compose them. Implementing the process lease separately prevents global ownership, networking, handshake, and event-pump concerns from becoming one unreviewable state machine.

## What Changes

- Add one SDK-internal process-wide connection lease registry using permanent Objective-C runtime namespaces, a private shared monitor, and exact-token release across loaded NearWire binary images.
- Return one opaque lease handle whose explicit release and deinitialization are idempotent.
- Reject a competing claim with one stable safe contention error while the current handle remains live and all synchronization statuses succeed; any synchronization failure takes runtime-unavailable precedence.
- Preserve per-instance event queues, streams, configuration, and public API isolation.
- Refine the roadmap so active-session delivery proceeds through process lease, session admission, active event pump, public connect orchestration, and connection lifecycle changes.

## Capabilities

### New Capabilities

- `sdk-process-connection-lease`: One internal, process-wide, exact-owner connection lease with bounded synchronous lifetime behavior.

### Modified Capabilities

- `sdk-offline-buffer`: Preserve queue and state isolation while permitting a process-wide primitive that governs only future network-session ownership.
- `sdk-public-boundary`: Permit an explicit internal lease claim without adding public API or initializer side effects.

## Impact

- Adds SDK-internal source and deterministic concurrency tests under `SDK/Sources/NearWire` and `SDK/Tests/NearWireTests`.
- Adds a macOS validation harness that builds disposable helper artifacts outside distributed source globs and dynamically loads two independent lease implementation images.
- Adds the Apple-system Objective-C runtime as an SDK implementation dependency; no third-party dependency is introduced.
- Adds no Core type, package target, product, package or third-party dependency, entitlement, privacy declaration, public symbol, or persistent state.
- Does not parse a pairing code, browse Bonjour, open TCP/TLS, access Keychain, negotiate a protocol or flow policy, send or receive events, change public state, reconnect, schedule work, observe App lifecycle, or add UI.
