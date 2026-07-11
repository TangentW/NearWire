# Core Wire Pre-Handshake Codec

## Why

The internal SDK session-admission layer must send its App hello and validate the Viewer hello before `WireNegotiator` can produce a result. The current cross-module SPI starts at `WireSessionCodec`, whose initializer already requires that result. Using it for the first hello is therefore circular, while exposing the raw message or payload protocols would weaken the sealed wire boundary.

## What Changes

- Add one repository-only `WirePreHandshakeCodec` SPI fixed to the registered V1 bootstrap envelope.
- Encode only the three messages admitted before negotiation: hello, safe error, and disconnect.
- Decode a bounded frame through lane, version, phase, message, and model validation before returning a sealed Sendable hello, safe-error, or disconnect enum.
- Add a module-internal expected-version guard to raw envelope decoding so a future envelope cannot be interpreted with V1 type, lane, or body semantics before rejection.
- Preserve `WireSessionCodec` as the codec constructed from a negotiation result; the new codec is the only repository codec constructible before negotiation.
- Refine the implementation roadmap so this prerequisite is archived before SDK session admission.

## Capabilities

### Modified Capabilities

- `wire-message-protocol`: Add a sealed V1 pre-handshake codec for the exact messages admitted before negotiation.
- `wire-session-negotiation`: Define the fixed V1 bootstrap envelope used to exchange hello before selecting the negotiated session codec.
- `sdk-public-boundary`: Keep the new codec and sealed pre-handshake enum inaccessible to a normal NearWire application consumer.

## Impact

- Adds platform-neutral Core source behavior and deterministic tests in `NearWireTransport`.
- Adds no SDK production source, network operation, session state, timer, task, persistence, Keychain access, UI, package target, product, dependency, entitlement, or supported application API.
- Does not start a channel, perform TLS, browse Bonjour, claim a process lease, negotiate Viewer approval, establish an active route, apply flow policy, or transfer events.
