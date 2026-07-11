# Core Transport Security

## Why

NearWire now has deterministic bounded frames and a session-bound V1 codec, but it has no network implementation or encryption boundary. Discovery and SDK session work must not invent Network.framework parameters, accept plaintext, trust arbitrary callbacks without explicit policy, or accumulate unbounded send/receive work independently on iPhone and Mac.

## What Changes

- Add immutable transport limits, timeouts, TLS policy, endpoint role, and safe typed transport errors.
- Add Network.framework parameter factories for ordered TCP with mandatory TLS 1.3, NearWire V1 ALPN, peer-to-peer routing enabled, and no plaintext factory or downgrade path.
- Add Viewer identity injection for a caller-owned self-signed `SecIdentity`; identity generation, Keychain persistence, and Viewer lifecycle remain later Viewer work.
- Add an explicit iOS client trust evaluator that validates and anchors the presented leaf only for the current connection, without system CA dependence or persistent pinning, and document that this provides encryption without strong pre-established Viewer authentication.
- Add a bounded secure byte-channel state machine with injected driver seams, one receive at a time, bounded pending sends, ordered completion, cancellation, terminal fault handling, and no automatic retry.
- Add fault-injection, race, resource-boundary, no-plaintext, TLS-policy, identity, trust, and lifecycle tests plus English security documentation and full repository gates.

## Capabilities

### New Capabilities

- `secure-network-parameters`: Mandatory TLS Network.framework parameters, TLS/ALPN policy, P2P routing, roles, and no-downgrade guarantees.
- `viewer-tls-identity`: Caller-owned Viewer identity adaptation and connection-local iOS trust behavior for self-signed Viewer certificates.
- `secure-byte-channel`: Bounded ordered byte transfer, connection lifecycle, backpressure, cancellation, and injected transport fault handling.

## Impact

- Extends the existing `NearWireTransport` target with Apple Network and Security framework integrations while preserving the package product/target/dependency graph and CocoaPods source mapping.
- Adds deterministic unit and platform tests under `NearWireTransportTests`; tests do not require a real Bonjour service or external server.
- Does not implement Bonjour names, pairing codes, process connection leases, reconnection, SDK facade APIs, Viewer certificate generation/storage, application UI, or event persistence. It does expose the identity-required secure Viewer listener boundary needed by later discovery work.
