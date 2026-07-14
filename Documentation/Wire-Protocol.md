# NearWire Wire Protocol V1

## Purpose and Scope

The wire protocol is the shared byte contract between an App using the NearWire SDK and the NearWire macOS Viewer. It lives in `NearWireTransport` so both products use the same parser, validation rules, and compatibility logic.

This layer is deliberately transport-neutral. It frames and validates in-memory bytes but does not open sockets, advertise Bonjour services, establish peer-to-peer routes, configure TLS, persist events, run timers, or touch UI. A frame is not encrypted merely because it is valid. The later secure transport layer must place every frame inside an authenticated TLS connection and must not provide a plaintext fallback.

V1 provides ordered at-most-once transfer within one live connection. It does not provide delivery acknowledgement, retransmission, cross-session replay, exactly-once delivery, RPC semantics, or durable storage.

## Frame Format

Every message uses this binary frame:

```text
0               4 5                                  N
+----------------+------------------------------------+
| UInt32 BE size | lane | deterministic UTF-8 JSON    |
+----------------+------------------------------------+
```

The four-byte unsigned big-endian size counts the lane byte and JSON payload, but excludes the size prefix itself. The JSON payload must not be empty, so the smallest valid declared size is two.

V1 lanes are:

| Byte | Lane | Purpose | Default payload limit |
| --- | --- | --- | ---: |
| `0x01` | Control | Handshake, policy, health, shutdown, and protocol errors | 64 KiB |
| `0x02` | Event | Events, event batches, and drop summaries | 2 MiB |

No other lane byte is valid. Both lane limits are configurable but positive, and neither may exceed the 16 MiB hard payload ceiling. A decoder rejects a prefix over the hard ceiling before buffering payload bytes. Once the lane byte is known, it applies that lane's smaller configured limit before accepting the rest of the payload.

The incremental decoder accepts any fragmentation, including a prefix or payload supplied one byte at a time, and it emits multiple coalesced frames in stream order. It retains no more than one bounded partial frame. A malformed frame or consumer callback failure makes that decoder terminal; the connection must close instead of trying to guess a new boundary.

## Deterministic Message Envelope

The frame payload is a UTF-8 JSON object with three required fields:

```json
{"body":{},"type":"hello","version":1}
```

Keys are sorted recursively and no insignificant whitespace is emitted. The same logical message therefore produces the same payload and frame bytes. Decode re-encodes the parsed value and requires an exact byte match, which rejects duplicate or escaped-equivalent keys, alternate key order, whitespace, and alternate numeric spellings before dispatch. Unknown envelope fields are ignored by V1 typed decoders when the complete message still uses this canonical representation, while `body`, `type`, and `version` remain mandatory.

`version` is a nonzero wire-protocol `UInt16`. It is independent of the NearWire product version and each event's schema version. `type` is 1 through 64 bytes and consists of lowercase, dot-separated ASCII segments. A known type must use its assigned lane.

Control message types are:

- `hello`
- `hello.acknowledged`
- `connection.rejected`
- `flow.policy.offer`
- `flow.policy.accepted`
- `ping`
- `pong`
- `disconnect`
- `error`

Event message types are:

- `event`
- `event.batch`
- `event.drop-summary`

A syntactically valid future type can be parsed as raw data, but V1 admission rejects it until a future negotiated capability defines its behavior.

## Handshake and Negotiation

Each endpoint sends a `hello` containing:

- its supported minimum and maximum wire version;
- a diagnostic product version;
- its `app` or `viewer` role and installation identifier;
- supported codecs, send policies, and capability tokens;
- its maximum event size;
- optional display and application metadata.

V1 negotiation requires opposite roles, an overlapping wire-version interval, the `json` codec, and the `normal` send policy. It selects the highest overlapping wire version. The effective maximum event size is the smaller advertised value. Capabilities and send policies are exact set intersections. Unknown capability tokens survive parsing and can intersect by value, but they activate no behavior unless the implementation explicitly recognizes them.

The negotiation result retains the installation identifier from the endpoint whose hello role is `viewer`. The Viewer creates `hello.acknowledged` with the exact negotiated version, codec, event limit, capabilities, policies, and retained Viewer identity, plus a new session epoch. Validation rejects an acknowledgement that adds or changes any negotiated value or substitutes a different Viewer identity.

Product versions never participate in compatibility decisions. Interval negotiation is version-agnostic, but a session can start only when the process has a registered codec for the selected version; this change registers V1 only. A new product can communicate with an older product whenever V1 lies in both intervals and their required features remain compatible.

Before a negotiation result exists, both endpoints use the repository-only `WirePreHandshakeCodec`. It always carries the initial hello, safe protocol error, or disconnect in the registered V1 bootstrap envelope, even when a hello advertises a wider version interval. Event-lane preflight occurs before JSON parsing. On the Control lane, version zero retains the invalid-configuration failure, while a nonzero version other than V1 is rejected before its type, required lane, or body can be interpreted as V1. The codec returns only a sealed typed hello, error, or disconnect after the complete payload model passes its active limits.

After hello exchange, `WireNegotiator` selects the session version and `WireSessionCodec` becomes the only negotiated message codec. Supporting another bootstrap envelope requires an explicit future codec registry; a caller cannot select a bootstrap version or label V1 bytes as a future envelope. The bootstrap codec, its typed result, raw messages, payload protocol, and admitted-message token are repository SPI or module-internal implementation, not supported application API.

## Session Phases

Message admission is explicit and independent of network code:

| Phase | Admitted behavior |
| --- | --- |
| `preHandshake` | Initial hello, error, or disconnect |
| `awaitingApproval` | Acknowledgement or rejection, ping/pong, error, or disconnect |
| `negotiatingPolicy` | Flow-policy offer/acceptance, ping/pong, error, or disconnect |
| `active` | Policy updates, health messages, shutdown/errors, and all known Event messages |
| `closing` | Pong, disconnect, or error only |

No Event-lane message is admitted before the session becomes active. Lane preflight rejects it before JSON parsing when the phase or baseline capability is absent. After negotiation, `WireSessionCodec` binds the selected version, conservative event limit, capabilities, and policies to every encoded and decoded message, and it never widens the supplied local limit. A mismatched envelope version is terminal before later envelope fields are interpreted. Event transfer requires `bidirectional-events`; batching, drop summaries, and flow-policy messages additionally require their corresponding negotiated capability. Frame admission returns a non-forgeable `WireAdmittedMessage`, and typed session decode accepts only that value so a raw message cannot bypass phase and lane checks. The payload protocol and raw message codec are internal; repository encode/decode consists only of closed overloads for the twelve V1 payload types, so an external conformer cannot impersonate an internal message type or skip its model limits. The later session actor owns timeouts, Viewer approval, TLS state, and transitions; Core validates the requested combination.

## Flow Policy and Control Safety

Flow policy carries separate App-uplink and App-downlink event rates. A rate is either zero, meaning paused, or a finite value from `0.000000001` through `100000` events per second. The session layer will combine endpoint offers conservatively before applying them to the local flow controller.

Control strings and collections are bounded. Protocol errors contain a stable token code, bounded human-readable text, a fatal flag, and an optional related message type. Implementations must construct this safe payload intentionally and must not serialize arbitrary underlying error descriptions, stack traces, credentials, pairing codes, or private application data.

## Event Record

An `event` body is a plain JSON object containing the complete logical event:

| Field | Encoding |
| --- | --- |
| `id` | Validated event identifier string |
| `type` | Validated logical event type |
| `content` | Ordinary JSON; never NearWire's internal tagged Codable form |
| `createdAt` | Canonical ISO-8601 UTC with a `Z` suffix and the shortest 3–9 digit fractional part that preserves the `Date` exactly |
| `monotonicTimestampNanoseconds` | Canonical decimal string |
| `source`, `target` | Objects containing endpoint `role` and `id` |
| `direction` | `appToViewer` or `viewerToApp` |
| `sessionEpoch` | Current session epoch identifier |
| `sequence` | Canonical decimal string |
| `priority` | Logical event priority |
| `ttlMilliseconds` | Canonical decimal string |
| `remainingTTLNanoseconds` | Canonical decimal string |
| `causality` | Nullable `correlationID` and `replyTo` identifiers |
| `schemaVersion` | Positive event-schema `UInt16` |

`UInt64` values use canonical decimal strings because JSON numbers cannot represent every `UInt64` exactly across implementations. Leading zeros, signs, whitespace, fractions, and overflow are invalid. Signed event-content integers and finite floating-point values remain ordinary JSON numbers and preserve their logical NearWire `JSONValue` cases.

V1 preserves sub-millisecond event dates instead of silently truncating them. Decode rejects missing fractions, redundant fraction digits, numeric UTC offsets, and any longer spelling when a shorter fractional part would reconstruct the same `Date`. It applies the active `EventValidationLimits` as well as the negotiated event byte limit. Canonical Event content defaults to at most 1 MiB. The advertised Event-record limit additionally includes the exact metadata envelope, and the default 2 MiB Event lane includes the V1 message wrapper. Each layer retains only its actual encoded bytes.

## TTL Across Devices

Monotonic clocks are local to one device and cannot be compared across the network. The sender therefore calculates:

```text
origin deadline = event monotonic timestamp + original TTL
remaining TTL   = origin deadline - sender monotonic time at encoding
```

The calculation is overflow-checked, and an event at or beyond its deadline is rejected before framing. On receipt, the peer establishes:

```text
receiver deadline = receiver monotonic time at receipt + remaining TTL
```

Only the receiver's monotonic clock is used after that point. The original sender timestamp remains diagnostic metadata. V1 does not subtract network transit time, so effective lifetime can be extended by transit duration; it never makes the unsafe assumption that device uptimes share an origin.

## Sequence, Batches, and Drops

Sequence belongs to one session epoch and one direction. Allocation starts at zero after flow control selects an event for transmission. The receiver accepts exactly the next value and rejects duplicates, gaps, the wrong direction, the wrong epoch, and `UInt64` exhaustion. Reconnecting creates a new epoch and a new sequence space beginning at zero.

An `event.batch` contains 1 through 256 records by default. Decode rejects the count before constructing any record. Every record must share an epoch and direction, and sequences must be contiguous and ascending. Construction maintains an overflow-safe cumulative byte budget and verifies the complete encoded message against the Event frame limit.

`event.drop-summary` reports nonnegative `overflowDropped`, `expired`, and `coalesced` counters. It is diagnostic only: it is not an event acknowledgement, delivery receipt, or retry instruction.

## Error Handling

Malformed framing, invalid JSON, an illegal lane/type pair, incompatible negotiation, invalid phase admission, sequence faults, expired TTL, arithmetic overflow, or model-limit failure returns a typed `WireProtocolError`. The error includes a stable code, a safe path, safe explanatory text, and a disposition of `operationRejected` or `connectionTerminal`. Local construction and validation failures reject only that operation. The frame decoder and negotiated session decoder promote untrusted stream or session violations to terminal errors and require connection teardown.

Framing errors are terminal because stream resynchronization would be ambiguous. Session code must send a safe protocol error only when doing so is possible without trusting attacker-controlled text, then close the connection. It must not continue decoding after terminal failure.

## Compatibility Fixtures

Canonical V1 JSON and complete framed hexadecimal fixtures live in `IntegrationTests/Fixtures/Protocol/v1` for hello, error, event, and event-batch messages. Tests compare encoding byte for byte and decode those same values. Any intentional fixture change requires a wire-compatibility decision; editing a fixture merely to make a failed test pass is not an acceptable migration strategy.

## Security Boundary and Non-Guarantees

This protocol supplies strict parsing and resource limits, not confidentiality or peer identity. The secure transport layer must provide TLS, certificate identity, trust persistence, pairing-code discovery policy, and connection ownership. Bonjour metadata and pairing codes must be treated as discoverability inputs rather than secrets.

V1 does not guarantee delivery, persistence, ordering across different connections, cross-session deduplication, clock synchronization, background execution, or protection when used over plaintext transport.
