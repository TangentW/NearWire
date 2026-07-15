# Integrate Demo Lifecycle Recovery

## Why

The SDK already supports bounded reconnection and explicit host-owned suspension/resumption, and the Viewer already replaces an exact reconnecting route. The maintained iOS Demo does not use either lifecycle surface: it constructs NearWire with recovery disabled and does not forward SwiftUI scene transitions. After iOS suspends the App and the old peer-to-peer route expires, returning to the Demo can therefore leave the SDK disconnected until the operator reconnects manually. This also leaves the previously reported post-reconnect Event path without one maintained end-to-end reference flow.

## What Changes

- Configure the Demo's one NearWire instance with a small bounded reconnection policy.
- Forward Demo scene background to `suspendConnection()` and active to `resumeConnection()` through one structured SwiftUI task; ignore inactive transitions.
- Preserve explicit first connection and explicit manual disconnect semantics. With no retained connection intent, foreground activation performs no discovery or connection work.
- Migrate an explicitly selected active Viewer Device to the same logical route's replacement connection so fresh-session Events are not hidden by a stale connection-ID scope.
- Document that iOS background suspension can end the route, recovery occurs only while the App can run, and no background mode or process-termination recovery is added.
- Add proportionate regressions for Demo lifecycle forwarding/configuration, an Event queued while suspended and drained on the fresh SDK route, and Viewer visibility of a fresh Event after exact-route replacement.

## Capabilities

### Modified Capabilities

- `demo-integration-application`: the maintained Demo becomes the reference integration for host-owned scene suspension and bounded foreground recovery.
- `viewer-event-explorer-control`: an active Device selection follows the same logical App route across exact reconnect replacement.

## Impact

The change affects Demo construction, scene integration, Demo documentation/tests, the Viewer's in-memory Device-selection scope, and focused SDK/Viewer regression tests. It changes no public SDK API, transport protocol, entitlement, persistence boundary, pairing-code lifetime, dependency, or background-execution capability.
