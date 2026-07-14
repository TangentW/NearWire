# NearWire Core Event Model

This document describes the internal logical event contract shared by NearWire components. The declarations are `public` only because Swift modules in this repository must compile against one another. They are not supported SDK API, and the `NearWire` facade must not expose them in its public signatures.

## Event lifecycle and field ownership

An `EventDraft` contains only values supplied before a connection assigns session metadata:

| Field | Meaning |
| --- | --- |
| `type` | Validated event type. User event types cannot use the `nearwire` namespace. |
| `content` | Bounded JSON-compatible content. |
| `priority` | Local queue priority: low, normal, high, or critical. It is not a delivery guarantee. |
| `ttl` | Positive lifetime in milliseconds; the default is 60,000 milliseconds. |
| `causality` | Optional correlation and reply-to event identifiers. |

`EventEnvelopeFactory` combines a draft with connection-owned context. An `EventEnvelope` adds an event ID, wall-clock creation date, monotonic creation time, source and target endpoints, direction, session epoch, per-direction sequence, and logical schema version. Callers that create ordinary SDK events cannot assign or spoof those fields.

The wall-clock date is approximate display context, not authoritative cross-device ordering. It must not determine expiration because clocks can be skewed and a user or the system can change wall time. An origin-local TTL calculation may compare the monotonic timestamp only with a value from the same clock that created it; a Mac uptime must never be compared with an iPhone uptime. Expiration arithmetic fails instead of wrapping on overflow. Receiver flow control must wait for the wire protocol to establish a receiver-local remaining lifetime or deadline.

The logical event schema version is independent of the NearWire product version and the future wire protocol version. Its current value is 1. Codable decoders require all V1 fields they know and ignore additional object fields.

## Event types and identifiers

Event types use dot-separated ASCII segments. Each segment starts with a letter and continues with letters, digits, `_`, or `-`. The complete type uses 1 through 128 UTF-8 bytes.

- `EventType.user` rejects `nearwire` and `nearwire.*`.
- `EventType.platform` requires the reserved `nearwire` namespace.
- The built-in performance type is exactly `nearwire.performance.snapshot`.

Event IDs and session epochs are canonical lowercase UUID strings. Endpoint IDs are opaque, use 1 through 128 ASCII bytes, and accept letters, digits, `.`, `_`, and `-`. Direction validation requires an App source and Viewer target for `appToViewer`, and the inverse roles for `viewerToApp`.

## JSON content

`JSONValue` explicitly represents null, Boolean, signed 64-bit integer, finite floating-point number, string, ordered array, and string-keyed object values. Integer and floating-point cases remain distinct. Deterministic encoding sorts object keys, preserves array order, and emits floating-point syntax with a decimal point or exponent as appropriate so decoding does not turn an integral floating-point value into an integer.

`EventContentCodec` is the default bridge for typed Swift content. It accepts `Encodable & Sendable`, then validates the encoded JSON representation before returning it. Decoding always names a specific `Decodable` destination type. A decode failure returns an error for that call and does not mutate the stored JSON value.

Default typed-content coding uses:

- ISO-8601 UTC dates with fractional seconds;
- Base64 data;
- sorted object keys and unchanged key names;
- hard failure for NaN and positive or negative infinity.

NearWire does not use `NSKeyedArchiver`, runtime class-name lookup, arbitrary `NSObject` reconstruction, or executable deserialization.

### Default validation limits

| Limit | Default | Hard configuration range |
| --- | ---: | ---: |
| Event type | 128 bytes | 1–128 bytes |
| JSON depth | 32 | 1–128 |
| Array entries | 4,096 | 1–100,000 |
| Object entries | 4,096 | 1–100,000 |
| String bytes | 65,536 | 1–1,048,576 |
| Object-key bytes | 65,536 | 1–1,048,576 |
| Encoded content | 1,048,576 bytes | 1–16,777,216 bytes |
| Internal encoded draft or envelope | 4,259,840 bytes | 1–134,217,728 bytes and at least four times the content limit plus 65,536 bytes |
| TTL | 86,400,000 ms | 1–604,800,000 ms |

Every draft and decoded envelope validates its type, content, and TTL against the active limits. `EventDraft.decode` and `EventEnvelope.decode` cap the internal tagged document's bytes and nesting before materialization, then install one limit set for the aggregate and every nested value; using a bare `JSONDecoder` intentionally selects the defaults and is only suitable for already-trusted in-process data. Later wire decoding must first cap frame length, parse event content through `decodeJSON`, and then construct an envelope with the negotiated active limits.

The 1 MiB content value is a maximum for canonical deterministic JSON, not a fixed allocation.
Smaller Events retain and transmit only their actual encoded bytes. Internal draft, wire record, and
frame limits are larger because they include tagged-model or protocol metadata overhead.

The `Codable` representation of `JSONValue` is an internal tagged representation that preserves the distinction between an integral floating-point value and an integer. Plain event-content JSON always enters and leaves through `decodeJSON` and `deterministicData`; it does not use the tagged internal representation.

## Causality is not delivery assurance

`correlationID` groups related ordinary events. `replyTo` identifies another event, commonly a request. Either value may appear independently; for example, progress events can share a correlation ID without replying to one specific event.

These fields do not imply acknowledgements, retries, timeouts, RPC dispatch, at-least-once delivery, exactly-once delivery, or a response requirement. Those behaviors must be designed separately if they are ever needed.

## Built-in performance snapshot

`PerformanceSnapshot` is a versioned, aggregate payload for the reserved `nearwire.performance.snapshot` event. It is only a schema. Constructing, encoding, or decoding it does not start timers, battery monitoring, display links, notifications, or network activity.

The V1 header contains:

- `schemaVersion`: exactly 1;
- `sampledAt`: a finite wall-clock date;
- `sampleIntervalMilliseconds`: a positive interval.

Optional metric groups are:

| Group | Fields and units |
| --- | --- |
| Process | `cpuPercent` is finite and non-negative and may exceed 100 on multi-core devices. `memoryFootprintBytes` is a byte count. |
| Display | `estimatedFramesPerSecond` and `maximumFramesPerSecond` are finite and positive when present. Estimated FPS is observed display-link callback cadence, not rendered throughput or GPU utilization. The current V1 SDK collector marks maximum FPS unsupported because it has no view/window screen context. |
| Device | `batteryLevel` is a finite fraction from 0 through 1. Battery state is unknown, unplugged, charging, or full. Thermal state is unknown, nominal, fair, serious, or critical. Thermal state is categorical and does not imply Celsius. |
| Transport | Uplink and downlink rates are bytes per second. Queue depths and dropped-event values are event counts. |

Byte and count values use unsigned Swift types, but V1 restricts content integers to the non-negative signed 64-bit JSON range so every value is representable by `JSONValue` without precision loss.

An absent optional field means that the metric was not collected or is unavailable. It never means zero. A present zero is a real measurement. `UnavailablePerformanceMetric` can record a stable metric key and one of `unsupported`, `disabled`, `permissionDenied`, or `temporarilyUnavailable`.

Unknown battery or thermal strings decode as `unknown`. Unknown object fields are ignored by typed V1 decoding while the enclosing event's raw `JSONValue` remains available to preserve them.

V1 deliberately defines no numeric whole-device GPU utilization, power watts, or Celsius temperature. The current collector also marks byte rates and downlink queue depth unsupported. `droppedEventCount` contains only overflow, expiration, and route-affinity terminal removals; coalescing, explicit clear, and retained transport-admission rejection are excluded. Collectors added by `NearWirePerformance` must use approved public interfaces and omit or explicitly mark metrics that cannot be obtained reliably.
