## Why

A connected iPhone can establish TLS over the Apple peer-to-peer Wi-Fi interface, deliver Events, and then lose the route within seconds even when successive Events are close together. The captured Viewer log reports peer absence before `No network route`, and the SDK currently cancels its peer-to-peer-enabled Bonjour browser immediately after selecting the Viewer. That ends the discovery activity that made the nearby peer reachable while the active session still depends on that path. TCP keepalive remains useful transport hardening, but it is not sufficient as the root fix for prematurely releasing peer-to-peer discovery.

The Viewer can also submit timeline pagination or durable-detail work while an ordinary refresh is releasing and replacing the Store traversal. A request that reaches the query arbiter between those phases has no valid traversal, reports `invalidRequest`, and closes the traversal used by later detail requests. SwiftUI list selection currently calls the observable controller synchronously from its binding setter, producing the runtime warning about publishing during a view update.

## What Changes

- Retain the matched, peer-to-peer-enabled Bonjour browser as a silent lifetime lease for the secure App session, immediately detach its callbacks and pairing-derived selection state, then cancel it exactly once when that session terminates or connection setup fails.
- Configure bounded TCP keepalive timing for both App and Viewer transport parameters as a transport-level liveness fallback rather than as a replacement for the retained discovery lifetime.
- Map Store continuation cursors to the chronological edge identified by their direction, admit Event/gap pagination only while the Explorer owns a ready traversal, and defer durable-detail loading until the replacement traversal is ready.
- Clear obsolete page failures when a fresh presentation generation begins.
- Defer SwiftUI Event selection mutation to the next main-actor turn, bind it to the current presentation generation and latest selection intent, and reject a stale or nonresident identity.
- Add focused transport and Viewer regression coverage plus connected-device and runtime-log evidence when available.

## Capabilities

### Modified Capabilities

- `sdk-bonjour-discovery`: a matched production browser remains silently active while the selected peer-to-peer session owns it, without retaining pairing-derived selection state or processing later discovery results, and is released at session teardown.
- `secure-network-parameters`: fixed secure parameters include explicit bounded TCP keepalive timing for transport liveness.
- `viewer-event-explorer-control`: refresh replacement cannot admit predecessor pagination/detail work, and SwiftUI selection does not synchronously publish during a view update.

## Impact

The change affects SDK Bonjour discovery ownership, shared Network.framework parameter construction, Event Explorer request admission, Event timeline selection binding, and focused tests. It changes no wire message, TLS trust policy, SDK public API, persistence schema, discovery service identity, package product, entitlement, or third-party dependency.
