# Core Wire Protocol

## Why

NearWire now has logical events and bounded flow control, but no byte-level contract shared by an iPhone SDK and Mac Viewer. Transport and session work cannot safely begin until frame boundaries, message lanes, handshake compatibility, event encoding, receiver-local TTL, session epochs, sequence rules, and protocol errors are deterministic and independently testable without a network connection.

## What Changes

- Add a dependency-free length-prefixed frame format with an explicit control or event lane byte, separate lane limits, bounded incremental decoding, fragmentation/coalescing support, and terminal malformed-frame errors.
- Add a deterministic UTF-8 JSON message envelope with independent wire-protocol version, validated message type, plain JSON body, lane/type agreement, and forward-compatible unknown fields.
- Add typed V1 control payloads for hello, hello acknowledgement, connection rejection, flow-policy offer/acceptance, ping/pong, disconnect, and protocol error.
- Add validated version intervals, JSON codec selection, capability and send-policy intersection, endpoint-role checks, negotiated event-size limits, and typed incompatibility diagnostics before an event session becomes active.
- Add plain-JSON event records, bounded event batches, drop summaries, origin-calculated remaining TTL, and receiver-local deadline establishment without comparing iPhone and Mac monotonic clocks.
- Add per-session directional sequence allocation and validation scoped by session epoch, with explicit overflow, gap, duplicate, and wrong-epoch failures and no acknowledgement semantics.
- Add handshake-phase lane admission rules, golden V1 fixtures, compatibility fixtures, malformed-input/resource-exhaustion tests, English protocol documentation, and the complete repository validation gate.

## Capabilities

### New Capabilities

- `wire-framing`: Length-prefixed control/event frames, deterministic encoding, bounded streaming decode, and frame-level resource limits.
- `wire-message-protocol`: V1 message envelopes, typed control/event payloads, phase admission, protocol errors, and golden compatibility fixtures.
- `wire-session-negotiation`: Protocol/codec/capability negotiation plus session epoch and directional sequence rules.
- `wire-event-transfer`: Plain JSON event and batch representation, remaining-lifetime transfer, receiver-local deadlines, and drop summaries.

## Impact

- Adds platform-neutral production code under the existing `NearWireTransport` target and deterministic tests under `NearWireTransportTests`.
- Adds protocol fixtures under `IntegrationTests/Fixtures/Protocol/v1` without adding package resources or changing the locked product/target/dependency graph.
- Extends English documentation and baseline OpenSpec capabilities after archive.
- Does not implement Network.framework, sockets, TLS, Bonjour, pairing, connection leases, reconnection, SDK public API, Viewer persistence, event acknowledgement, retry, compression, or authentication.
