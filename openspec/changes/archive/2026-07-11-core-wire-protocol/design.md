# Core Wire Protocol Design

## Context

`NearWireCore` defines logical events, and `NearWireFlowControl` decides which pending events may leave a local queue. The next layer must turn control and business messages into bounded bytes while remaining independent of Network.framework and TLS. The same implementation must compile in Swift 5 language mode for iOS 16 and macOS 13, through both SwiftPM and the monolithic CocoaPods Core subspec.

The protocol is internal infrastructure, but its bytes are a compatibility boundary. Ambiguous framing, cross-device uptime comparison, unbounded parsing, product-version coupling, or implicit downgrade behavior would become expensive to correct after SDK and Viewer sessions depend on it.

## Goals / Non-Goals

**Goals:**

- Define one deterministic, stream-safe, resource-bounded V1 frame format.
- Preserve two logical lanes over one ordered connection without claiming transport multiplexing.
- Negotiate compatibility before business events become active.
- Encode event content as ordinary JSON rather than the internal tagged `JSONValue` Codable representation.
- Scope event order to one direction and one session epoch.
- Carry remaining lifetime without comparing unrelated monotonic clocks.
- Preserve unknown JSON fields and capability tokens where forward compatibility requires it.
- Produce checked-in golden fixtures that fail visibly on accidental byte drift.

**Non-Goals:**

- Network.framework parameters, receive loops, sockets, TLS configuration, certificates, trust callbacks, Bonjour, or P2P routing.
- Viewer admission UI, connection leases, reconnection, background lifecycle, or timer ownership.
- Event ACK, retransmission, deduplication across sessions, exactly-once, persistence, or RPC dispatch.
- Compression, attachments, WebSocket framing, protobuf, CBOR, or multiple codecs in V1.
- Supported public SDK protocol types.

## Decisions

### 1. Use a four-byte length prefix plus one lane byte

Each frame is:

```text
0               4 5                                  N
+----------------+------------------------------------+
| UInt32 BE size | lane | deterministic UTF-8 JSON    |
+----------------+------------------------------------+
```

The unsigned big-endian size counts the lane byte and JSON payload, but not the four-byte prefix. Lane `0x01` is Control and `0x02` is Event. No other lane value is valid in V1. The JSON payload must be nonempty, so declared lengths below two are invalid.

This format is smaller and easier to bound than WebSocket while preserving message boundaries over an ordered byte stream. TLS remains mandatory in the later transport change; the frame codec has no plaintext mode and makes no security claim by itself.

### 2. Bound lanes independently and decode incrementally

`WireFrameLimits` defaults to 64 KiB for Control and 1 MiB for Event, with a 16 MiB hard ceiling. The prefix is rejected before payload buffering if it exceeds the hard ceiling. After the lane byte arrives, the lane-specific limit is enforced before accepting the remaining payload.

`WireFrameDecoder.consume` processes arbitrary fragments and multiple coalesced frames through a synchronous callback. It retains at most one bounded partial frame instead of concatenating an entire input chunk or accumulating an unbounded result array. A malformed prefix, lane, or size places the decoder in a terminal failed state; callers must close the connection and create a new decoder rather than attempt ambiguous resynchronization.

### 3. Use a small deterministic JSON message envelope

Every frame payload is a JSON object:

```json
{
  "body": {},
  "type": "hello",
  "version": 1
}
```

Keys are encoded in sorted order without insignificant whitespace. Decode requires parsed deterministic re-encoding to equal the original payload bytes, rejecting duplicate or escaped-equivalent keys, whitespace, alternate key order, and alternate numeric spellings. `version` is the selected or proposed wire version, `type` is a validated 1–64 byte lowercase dot-separated ASCII identifier, and `body` is a plain `JSONValue`. Unknown object fields are ignored during typed V1 decode when the complete message remains canonical. Missing required fields, invalid integers, excessive nesting, and non-object roots fail with typed errors.

The lane byte remains outside JSON so a decoder can apply the smaller Control limit before materializing a body. Known message types have one required lane. An event type on Control or control type on Event fails before typed payload dispatch.

### 4. Keep wire, event-schema, and product versions independent

`WireProtocolVersion` is a nonzero `UInt16`; V1 has current and minimum-compatible value 1. A hello advertises a closed supported interval. Negotiation selects the highest overlapping value, but session construction requires a registered implementation and this change registers V1 only. An overlap selecting a future version therefore cannot label V1 schemas as that version.

Product versions remain bounded display/diagnostic strings. They never determine wire compatibility, and product version comparison is not implemented in Core.

### 5. Negotiate one required JSON codec and explicit capabilities

V1 requires the `json` codec. Codec and capability identifiers use bounded lowercase ASCII tokens. Unknown capability tokens are retained and can intersect by exact value, but they do not enable behavior unless later code recognizes them. Known capabilities cover bidirectional events, normal queueing, keep-latest, batching, flow policy, and drop summaries.

Hello also advertises endpoint role, installation ID, maximum event bytes, and supported send policies. Negotiation requires opposite App/Viewer roles, a common protocol version, JSON, at least normal send policy, and coherent event-size limits. Effective capabilities and policies are intersections; the effective event limit is the smaller endpoint limit, and the result retains the identity advertised by the Viewer hello. A missing optional capability disables that feature rather than silently changing required V1 framing or TLS behavior.

### 6. Keep admission state explicit

Core defines phases for pre-handshake, awaiting approval, negotiating policy, active, and closing. Before active state, only the documented small set of Control messages is admissible. Event-lane preflight runs before JSON parsing and rejects a non-active phase or absent baseline event capability. After negotiation, a session codec binds the selected envelope version, non-widening local limit, capabilities, and policies to encode and decode. Frame admission returns an unforgeable admitted-message value required by typed session decode. The payload protocol and raw codec remain internal, while the session codec exposes only closed overloads for V1 payloads; external conformers cannot claim a known type with an unvalidated body. Event, batch, drop-summary, and flow-policy types require their negotiated capabilities. Version mismatch or a non-negotiated optional type is terminal on receive. Session actors and approval timeouts remain later work.

### 7. Define typed bounded control payloads

V1 control types are:

- `hello` and `hello.acknowledged`
- `connection.rejected`
- `flow.policy.offer` and `flow.policy.accepted`
- `ping` and `pong`
- `disconnect`
- `error`

Strings, lists, metadata, and error text have explicit byte/count limits. Flow policies carry independent App uplink and downlink event rates and reuse the same accepted numeric range as Core flow control without importing that module. Error frames contain a stable code, bounded human-readable message, fatal flag, and optional related message type; they never contain arbitrary underlying error descriptions by default. Local validation errors have an operation-rejected disposition, while frame and negotiated-session decoders promote peer byte violations to connection-terminal errors.

### 8. Encode logical events as plain JSON records

`WireEventRecord` maps every required `EventEnvelope` field to a documented JSON object while embedding `content` as ordinary deterministic JSON. It does not use the internal tagged `JSONValue: Codable` representation. Dates use canonical ISO-8601 UTC with a `Z` suffix and the shortest 3–9 digit fractional part that reconstructs the `Date` exactly; decode rejects missing, redundant, offset, or lossy forms. Integer and floating-point content intent remains preserved by the existing plain JSON codec.

The Event lane supports `event`, `event.batch`, and `event.drop-summary`. Batch count is rejected before element construction, and construction applies an overflow-safe cumulative budget plus an exact complete-message frame check. A drop summary reports bounded cumulative deltas by reason; it is diagnostic and does not become an ACK.

### 9. Transfer remaining lifetime, not sender uptime meaning

When a sender creates a `WireEventRecord`, it supplies the current value from the same monotonic clock as the envelope timestamp. Core calculates the origin deadline and includes positive `remainingTTLNanoseconds`. An already expired event fails before encoding.

On receipt, Core adds that duration to an explicitly supplied receiver-local monotonic value using overflow-safe arithmetic and returns a receiver-local deadline wrapper. The sender's original monotonic timestamp remains diagnostic event metadata and is never compared with receiver uptime. Network transit can extend effective lifetime by the transit duration; V1 accepts that bounded practical trade-off instead of using unsafe cross-device clock arithmetic.

### 10. Scope sequence to direction and session epoch

A `WireSequenceCounter` owns one session epoch and the next event sequence for one direction. Sequence is allocated only after flow control selects an event. A validator accepts exactly the expected sequence for its epoch, rejects duplicates, gaps, wrong epochs, and counter overflow, and can be replaced for a new epoch after reconnect.

Batches require one epoch, one direction, and contiguous ascending sequences. This detects protocol and session wiring errors on an ordered stream without adding ACK, replay, or cross-session deduplication semantics.

### 11. Make golden fixtures authoritative

Checked-in V1 fixtures contain canonical JSON and complete framed hexadecimal bytes for representative hello, error, event, and event-batch messages. Tests compare deterministic encodings to inline golden values on every platform and additionally read the checked-in files on macOS, avoiding a package-resource graph change.

Decoders also exercise fixtures with unknown fields/capabilities, supported-version overlap, malformed lengths, fragmented prefixes/payloads, coalesced frames, invalid UTF-8/JSON, oversized lane payloads, sequence faults, and receiver deadline overflow.

## Risks / Trade-offs

- **JSON overhead** → Keep V1 inspectable and dependency-free; enforce event, batch, and frame limits.
- **One-byte lane is visible before JSON** → TLS later encrypts the complete frame; the byte exists for early resource policy, not security.
- **Unknown capability is retained but inert** → Require explicit known behavior checks after exact-value negotiation.
- **No resynchronization after a malformed prefix** → Fail the connection rather than scan attacker-controlled bytes for a guessed boundary.
- **Remaining TTL starts at receive time** → Document possible transit extension and never compare unrelated uptimes.
- **Strict contiguous sequence rejects gaps** → Allocate sequence after dequeue and immediately before record construction; dropped/coalesced pending work never consumes sequence.
- **Fixtures can make intentional changes noisy** → Protocol byte drift requires an explicit version/compatibility decision and fixture update.

## Migration Plan

1. Add wire errors, identifiers, limits, framing, message envelopes, payload models, event mapping, negotiation, and sequence helpers under `NearWireTransport`.
2. Add deterministic unit, adversarial, compatibility, and golden fixture coverage under `NearWireTransportTests` and `IntegrationTests/Fixtures/Protocol/v1`.
3. Add English wire-protocol documentation and preserve the locked package/pod dependency graph.
4. Run complete validation, multi-agent remediation to zero findings, archive, and commit before `core-transport-security` begins.

Rollback is a normal commit revert because no Network.framework session, SDK facade, Viewer database, or released peer consumes V1 bytes yet.

## Open Questions

None. TLS identity/trust, receive chunk sizing, connection timeouts, admission UI, reconnection, and Bonjour metadata remain explicitly assigned to later changes.
