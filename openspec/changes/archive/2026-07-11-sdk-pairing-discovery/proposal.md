# SDK Pairing Discovery

## Why

The SDK now owns a stable event facade and offline queue, but it cannot identify or discover the Viewer selected by the user. Pairing-code parsing and Bonjour result selection must be deterministic before a public connection method or session actor depends on them. Implementing discovery as a separate change keeps untrusted service metadata, Network.framework callback ordering, and local-network resource bounds out of the later handshake and reconnection state machine.

## What Changes

- Add repository-internal Core values for the validated six-character pairing code, Bonjour constants, and logical service identity so the SDK browser and later Viewer publisher share one contract.
- Add deterministic conversion between a pairing code and the exact NearWire Bonjour service instance name.
- Add an internal SDK discovery state machine that browses only `_nearwire._tcp`, enables peer-to-peer paths, matches only the requested instance, and never falls back to an arbitrary Viewer.
- Add a Network.framework browser adapter behind an injected driver boundary so callback ordering, cancellation, duplicate results, and failures can be tested without relying on live Bonjour traffic.
- Add safe discovery diagnostics that do not include the full pairing code, endpoint descriptions, TXT records, or arbitrary underlying errors.
- Document host-App local-network declarations and the discovery boundary.

## Capabilities

### New Capabilities

- `sdk-pairing-code`: Validated in-memory pairing codes and exact Bonjour instance-name derivation.
- `sdk-bonjour-discovery`: Explicit bounded peer-to-peer-enabled browsing, exact Viewer selection, safe state, and deterministic cancellation.

### Modified Capabilities

- `sdk-public-boundary`: Preserve side-effect-free public construction while permitting explicitly started repository-internal discovery.

## Impact

- Adds platform-neutral pairing and Bonjour identity source under `Core/Sources/NearWireCore`, plus iOS-specific browsing under `SDK/Sources/NearWire` and deterministic tests in both owning test targets.
- Adds Network.framework to the SDK target and CryptoKit to the shared Core implementation as Apple-system dependencies; no third-party dependency is introduced.
- Keeps the supported NearWire application API unchanged, so existing SwiftPM and CocoaPods consumers remain source-equivalent.
- Refines the implementation roadmap by splitting the former `sdk-discovery-session` milestone into narrow discovery, active-session, and lifecycle changes.
- Restores the executable bit on the existing Core SPI boundary checker because the mandatory repository structure gate executes every validation script directly; its contents and validation policy remain unchanged.
- Does not add public `connect` or `disconnect`, open a TLS connection, acquire a process-wide lease, persist an installation ID or pairing code, perform wire negotiation, send events, reconnect, schedule timers, observe app background state, or add UI.
