# SDK Session Admission

## Why

NearWire can discover one exact Viewer, create a mandatory-TLS App channel, encode the V1 bootstrap hello, negotiate a session, and enforce one process connection lease, but no component composes those pieces into one bounded App-side admission attempt. The later public connection API and event pump need a single internal owner that either returns one validated Viewer route and live negotiated channel or tears every stage down exactly once.

## What Changes

- Add an internal one-shot `SDKSessionAdmission` operation that explicitly performs pairing discovery, peer-to-peer-enabled TLS connection, bootstrap hello exchange, Viewer approval, and acknowledgement validation.
- Bind the discovered public `vid` discriminator to the fully decoded Viewer hello installation ID before negotiation, without claiming certificate authentication or persistent identity continuity.
- Add an early synchronous lane-preflight hook to `WireFrameDecoder` so pre-active Event frames fail after the lane byte and declared lane bound are known but before payload buffering.
- Add bounded channel callback ingress, handshake byte and frame budgets, stage deadlines, exact cancellation, stable internal errors, and deterministic race precedence.
- Return one redacted `SDKAdmittedSession` handle to a single long-lived transport-core actor that remains the channel's permanent callback target and owns the live channel, decoder, negotiated route, bounded post-acknowledgement Control handoff, attachment deadline, and cumulative pre-active work budgets.
- Keep process-lease claim, supported `connect` and `disconnect`, flow-policy completion, Event transfer, reconnection, background behavior, persistence, and UI outside this change.

## Capabilities

### Added Capabilities

- `sdk-session-admission`: Compose one exact discovery result and one secure byte channel into a validated App-side session admission result.

### Modified Capabilities

- `wire-framing`: Permit synchronous lane admission before payload allocation or copy while preserving terminal incremental-decoder behavior.
- `sdk-bonjour-discovery`: Require the later admission layer to compare the advertisement discriminator with the Viewer hello identity while preserving its non-authentication semantics.
- `sdk-public-boundary`: Allow only an explicit internal admission operation to start discovery and TLS while keeping supported SDK construction and ordinary event APIs side-effect-free and source-compatible.

## Impact

- Adds iOS-specific internal session coordination under `SDK/Sources/NearWire/Session` and a small platform-neutral framing hook in Core.
- Adds deterministic SDK and Core tests, English session documentation, boundary fixtures, and packaging evidence.
- Adds no supported SDK declaration, package product, target, dependency, pod subspec, entitlement, privacy manifest, Viewer source, Demo source, or third-party runtime dependency.
- Does not claim or release the process lease, publish supported state, transfer Events, negotiate effective rates, retry, reconnect, observe App lifecycle, persist a code or identity, access Keychain, or create UI.
