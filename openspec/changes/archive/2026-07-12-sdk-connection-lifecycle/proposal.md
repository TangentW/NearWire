## Why

NearWire can establish one supported connection, but an application still cannot intentionally disconnect, safely pause transport for background policy, understand why an active session ended, or opt into bounded recovery. The SDK needs one explicit lifecycle owner before UI and performance features can depend on predictable connection behavior.

## What Changes

- Add an idempotent async `disconnect()` operation that clears connection intent, cancels the exact attempt or active route, and awaits one shared exact-route cleanup receipt after the process lease release invocation.
- Add a validated App-local reconnection policy. Automatic reconnection is disabled by default; when enabled it uses an intent-wide total attempt budget that does not reset on brief reconnection, a capped delay, phase-aware transient classification, and no replay of old bytes.
- Add explicit `suspendConnection()` and `resumeConnection()` operations. NearWire does not subscribe to UIKit or lifecycle notifications; the host App decides whether and when to forward foreground or background policy.
- Retain the normalized pairing code only in one actor-owned pending/active intent capsule; route owners and delay Tasks never retain it. Manual disconnect, permanent failure, enabled-budget exhaustion, and shutdown clear it.
- Add a latest-value public connection-status snapshot and stream containing the existing state, a content-safe terminal error, retry progress, and suspension state. Preserve the existing state stream as the simple compatibility surface.
- Replace every recovered route with a new admission, epoch, pump, terminal coordinator, and exact lease ownership. An old callback may settle only its exact cleanup receipt and cannot mutate or release a newer route.
- Keep persistence, background execution requests, reachability polling, delivery acknowledgement, UIKit observation, UI, performance collection, and Viewer behavior out of scope.

## Capabilities

### New Capabilities

- `sdk-connection-lifecycle`: Explicit disconnect, host-controlled suspension and resumption, bounded transient recovery, safe terminal status, and exact route replacement.

### Modified Capabilities

- `sdk-public-connect`: A successful explicit connection establishes an in-memory connection intent that later lifecycle operations may suspend, resume, retry, or clear.
- `sdk-public-boundary`: The lifecycle methods, reconnection configuration, and connection-status observation become supported and equivalent through SwiftPM and CocoaPods.
- `sdk-async-facade`: State publication is extended with real reconnecting behavior and a latest-value connection-status stream while shutdown remains terminal.
- `sdk-process-connection-lease`: Disconnect and every replacement attempt wait for exact prior terminal release and claim a fresh exact lease without overlap.

## Impact

The change affects supported NearWire configuration and facade APIs, SDK lifecycle orchestration, stream hubs, process-lease composition, public consumer fixtures, tests, documentation, and validation evidence. It adds no product, target, pod subspec, entitlement, privacy declaration, third-party dependency, persistent storage, or automatic platform lifecycle observer.
