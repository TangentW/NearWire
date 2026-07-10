## Context

The repository currently contains internal module markers but no production data model. Every later subsystem depends on the same event meaning: the SDK creates drafts, flow control stores and expires them, the wire protocol enriches and encodes them, and the Viewer decodes, persists, filters, and renders them. A lossy or underspecified Core representation would force incompatible conversions across those layers.

Constraints established by the baseline specifications and product architecture are:

- Core remains platform-neutral and imports no UI framework.
- Swift 5 language mode, strict concurrency, iOS 16, and macOS 13 remain supported.
- Core and SDK runtime targets add no third-party dependency.
- Core declarations may be `public` for cross-module compilation but remain an internal product contract and must not leak through supported SDK signatures.
- Ordinary event content is JSON-compatible and bounded; binary streams and executable object deserialization are out of scope.
- The `nearwire.*` namespace belongs to the platform.
- Performance snapshots are an optional built-in event schema, not a special transport lane or implicit collector.

## Goals / Non-Goals

**Goals:**

- Define one immutable, Sendable logical event model for SDK and Viewer internals.
- Preserve JSON integer and floating-point intent and support deterministic encoding.
- Make every invalid name, identifier, TTL, metadata field, content shape, or size fail with a typed error before queue insertion.
- Separate caller-controlled draft fields from session-controlled envelope fields.
- Support request/reply correlation without introducing RPC or delivery acknowledgement semantics.
- Define the V1 performance snapshot schema, units, absence behavior, and reserved event type.
- Provide deterministic tests using injected clocks and identifiers instead of timing-sensitive sleeps.

**Non-Goals:**

- Public `NearWire` SDK facade types or source compatibility guarantees.
- Queueing, coalescing, rate limiting, batching, expiration scheduling, deduplication, or acknowledgement.
- Framing, protocol version negotiation, TLS, Bonjour, installation-ID persistence, or session lifecycle.
- Viewer persistence, filtering, rendering, or performance charts.
- iOS performance collection or claims that unavailable private metrics can be measured.
- Attachments, arbitrary binary payloads, NSObject archiving, runtime class lookup, or polymorphic code execution.

## Decisions

### 1. Model JSON explicitly instead of storing Data or Any

`JSONValue` is an indirect enum with `null`, `bool`, `integer(Int64)`, `number(Double)`, `string`, `array`, and `object([String: JSONValue])` cases. It conforms to Codable, Sendable, Equatable, and Hashable where supported by its recursive values.

Integers remain distinct from floating-point numbers. Plain JSON enters through a token-aware Foundation conversion that distinguishes integer tokens from floating-point tokens, rejects non-finite values, and never silently rounds an overflowing integer into `Int64`. `JSONValue` uses an explicitly tagged internal Codable representation because Foundation's untagged scalar decoder cannot preserve `1` versus `1.0`; that tagged form is not the event-content JSON wire shape. Object keys remain strings and arrays preserve order. Deterministic plain JSON bytes use sorted object keys without changing array order.

Alternatives considered:

- `Any` or `[String: Any]` was rejected because it is neither Sendable nor statically safe.
- Raw `Data` was rejected because validation, filtering, and Viewer fallback rendering would require repeated parsing.
- Foundation `JSONSerialization` values as the stored model were rejected because NSNumber boolean/number distinctions and concurrency guarantees are too implicit.

### 2. Use a bounded Codable bridge

`EventContentCodec` owns the default JSON encoder and decoder configuration. Encoding an `Encodable & Sendable` value produces bytes, parses those bytes into `JSONValue`, validates the value and encoded-size limits, and returns the value. Decoding serializes the stored value deterministically and decodes only the requested `Decodable` type.

The default bridge uses stable ISO-8601 UTC dates with fractional seconds, Base64 data, default key names, sorted object keys, and hard failure for non-conforming floating-point values. Custom encoder and decoder injection is allowed internally for deterministic fixtures and later SDK configuration, but bypassing JSON-value validation is not.

One decode failure affects only the requested event and returns a typed error. It does not mutate the event, poison a stream, or terminate a session.

### 3. Separate EventDraft from EventEnvelope

`EventDraft` contains only fields chosen before session assignment:

- validated event type;
- JSON content;
- priority;
- TTL in milliseconds;
- optional correlation ID and reply-to event ID.

`EventEnvelope` adds fields owned by the active session and event factory:

- event ID;
- wall-clock creation date;
- monotonic creation nanoseconds;
- source and target endpoints;
- direction;
- session epoch;
- per-direction sequence;
- event schema version.

All envelope fields are non-optional except correlation metadata. An `EventEnvelopeFactory` accepts injected wall clock, monotonic clock, and identifier generator closures so unit tests are deterministic. Queue state and the wire protocol remain responsible for allocating sequence and session epoch values; the factory validates but does not persist counters.

This phase separation prevents callers from spoofing sequence, direction, source, or platform schema version and prevents later code from handling partially enriched envelopes.

### 4. Use small validated value types

Event type, event ID, endpoint ID, session epoch, and correlation values are validated value types rather than unstructured strings.

- Event types are 1–128 UTF-8 bytes, consist of dot-separated ASCII segments, each segment starts with an ASCII letter, and remaining characters are letters, digits, `_`, or `-`.
- User event construction rejects `nearwire` and every `nearwire.*` value. Platform construction requires that reserved namespace.
- Event and session IDs use canonical lowercase UUID text generated with Foundation UUID and reject non-canonical or malformed input.
- Endpoint IDs are opaque 1–128 byte ASCII identifiers using letters, digits, `.`, `_`, and `-`; identity generation and persistence remain later concerns.
- Sequence is an unsigned 64-bit value scoped by direction and session epoch. Ordering behavior is implemented later.

Alternatives considered:

- ULID was deferred because UUID is available without dependencies and ordering comes from explicit sequence metadata.
- Free-form event names were rejected because malformed and reserved names would reach queues, storage, and filters.

### 5. Represent time and TTL without scheduling policy

The envelope stores a wall-clock `Date` for display and the origin's monotonic uptime value in nanoseconds for origin-local duration calculations. TTL is stored as an exact positive millisecond count. Validation limits provide a maximum TTL; the default is 24 hours and the default draft TTL is 60 seconds.

No `isExpired` method reads global time. Instead, a pure TTL function accepts a current value explicitly named as belonging to the same clock that created the timestamp and uses overflow-safe arithmetic. The envelope deliberately exposes no receiver-facing expiration convenience because monotonic clocks on an iPhone and Mac are unrelated. Flow-control code may use the operation only for origin-local queue state; the later wire protocol must establish a receiver-local remaining lifetime or deadline.

### 6. Make validation limits explicit and composable

`EventValidationLimits` contains default and hard-bounded values for:

- event type UTF-8 bytes;
- content depth;
- array entries;
- object entries;
- string and object-key UTF-8 bytes;
- deterministic encoded event-content bytes;
- internal tagged draft or envelope bytes;
- TTL milliseconds.

The defaults are 128 type bytes, depth 32, 4,096 array or object entries, 64 KiB strings and keys, 256 KiB encoded content, 2 MiB internal tagged model data, and 24-hour maximum TTL. The internal Codable tag is a compact numeric array rather than a verbose keyed object. A configured model cap must be at least four times the content cap plus 64 KiB for tags and fixed envelope fields, which bounds every permitted compact-tag expansion. Invalid limit configurations fail construction instead of disabling validation. Plain and tagged JSON inputs receive byte and nesting preflight before Foundation materialization; semantic traversal remains depth-guarded and stops at the first typed validation error.

Limits validate both caller-encoded content and decoded envelopes. This prevents a trusted local transport assumption from becoming an unbounded memory or recursion assumption.

### 7. Keep event schema version separate from protocol and product versions

`EventSchemaVersion.current` is 1 and must be nonzero. It describes the logical envelope fields only. Product release version and future wire protocol negotiation remain independent. Decoders ignore unknown object fields, while missing required V1 fields fail.

### 8. Model request and reply as ordinary event causality

Correlation ID groups related events; reply-to identifies the request event. The model permits either field independently because a stream of progress events can share a correlation ID without replying to one event. A reply helper belongs to the later SDK facade and will fill both values, but Core introduces no RPC, timeout, ACK, retry, or exactly-once promise.

### 9. Define a conservative performance snapshot schema

The reserved event type is exactly `nearwire.performance.snapshot`. `PerformanceSnapshot` contains schema version 1, sample time, positive sample interval milliseconds, and optional `process`, `display`, `device`, and `transport` groups matching the architecture.

Units are encoded in field names and documentation:

- CPU percent is a finite non-negative process value and may exceed 100 on multi-core devices.
- Memory footprint and transport counters are bytes or event counts using unsigned integers.
- Battery level is a finite fraction from 0 through 1.
- Estimated and maximum frame rates are finite positive frames per second.
- Thermal and battery states are closed V1 string enums with an `unknown` case for forward input handling.

Missing optional fields mean not collected or unavailable and never mean zero. An optional array of `UnavailablePerformanceMetric` values can distinguish unsupported, disabled, permission-denied, and temporarily unavailable metrics without inventing a measurement. GPU utilization, power watts, and Celsius temperature have no numeric V1 field.

The schema has no collector, timer, CADisplayLink, UIDevice, or ProcessInfo dependency. Those belong to `sdk-performance`.

### 10. Preserve source and distribution boundaries

Production files are grouped below `NearWireCore/Event` and `NearWireCore/Builtins/Performance`. Tests live in `NearWireCoreTests`; reusable builders can live in `NearWireTestSupport` without becoming public SDK API. Package and pod manifests retain the locked target graph, so no new target or dependency is required.

## Risks / Trade-offs

- **[Risk] Exact integer and number cases can surprise generic Codable round trips** → Document the distinction and cover boundary values, exponent forms, and integer overflow with fixtures.
- **[Risk] Deterministic re-encoding costs an extra parse and serialization** → Enforce the 256 KiB default, benchmark representative payloads, and keep conversion off MainActor in the later SDK.
- **[Risk] Recursive JSON can cause stack or allocation pressure** → Validate depth and collection counts before acceptance and test adversarial nesting.
- **[Risk] UUID text is larger than a compact binary identifier** → Prefer dependency-free clarity in V1; the wire protocol may encode it efficiently without changing logical identity.
- **[Risk] Wall and monotonic timestamps originate on different devices** → Use monotonic time only for local duration/TTL and wall time only for display; Viewer receive time remains a separate later field.
- **[Risk] Optional performance fields can be misread as zero** → Keep zero as a real measurement and provide explicit unavailability records and Viewer documentation.
- **[Risk] Closed enum values can evolve** → Decode unknown battery and thermal strings to `unknown` while preserving the raw event content at the event layer.
- **[Risk] Internal Core public access may be mistaken for supported SDK API** → Retain internal product documentation and public-facade compile gates; do not expose Core types from `NearWire` signatures.

## Migration Plan

1. Replace the NearWireCore marker with additive Event and Builtins source files; retain the marker only if needed as an internal module availability namespace.
2. Add focused tests for primitives, JSON coding, validation, envelopes, causality, clocks, and performance schema.
3. Run the locked SwiftPM, CocoaPods, distribution-contract, strict-concurrency, English, and OpenSpec gates.
4. Save exact change evidence and complete multi-agent review to zero findings.
5. Archive this change before `core-flow-control` enters apply.

Rollback is a normal commit revert because no external persistence, public API, or wire compatibility contract consumes these models yet.

## Open Questions

None. Wire field spellings and framing remain deliberately deferred to `core-wire-protocol`; this change fixes logical Codable semantics and fixtures only.
