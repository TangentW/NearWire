## ADDED Requirements

### Requirement: Lossless bounded JSON values

Core SHALL represent event content as immutable Sendable JSON values with distinct null, Boolean, signed 64-bit integer, finite floating-point number, string, ordered array, and string-keyed object cases. It SHALL reject lexical integer overflow before Foundation numeric conversion, non-finite numbers, excessive nesting, excessive collection entries, oversized strings or keys, and encoded content above the active limit.

#### Scenario: JSON value round trip

- **WHEN** a valid JSON document containing every supported scalar and nested collection case is decoded and re-encoded
- **THEN** Boolean, integer, floating-point, string, null, array order, object content, and integer boundary values are preserved
- **AND** deterministic output sorts object keys without sorting arrays

#### Scenario: Invalid numeric input

- **WHEN** content contains a non-finite floating-point value or an integer outside signed 64-bit range
- **THEN** conversion fails with a typed content error
- **AND** no partial JSON value is returned

#### Scenario: Structural limit exceeded

- **WHEN** content exceeds configured depth, collection-count, string, key, or encoded-byte limits
- **THEN** validation fails at the violated limit
- **AND** the invalid content cannot enter an event draft or decoded envelope

### Requirement: Deterministic Codable content bridge

Core SHALL convert `Encodable & Sendable` payloads into validated JSON values and SHALL decode stored JSON values into an explicitly requested Decodable type. Default coding SHALL use stable UTC ISO-8601 dates with fractional seconds, Base64 data, sorted object keys, and rejection of non-conforming floating-point values.

#### Scenario: Typed payload conversion

- **WHEN** a valid nested Codable payload is encoded with the default content codec
- **THEN** a validated JSON value is produced
- **AND** decoding that value into the original type restores an equal value

#### Scenario: Content decoding failure isolation

- **WHEN** stored JSON content does not match a requested Decodable type
- **THEN** the decode call returns a typed content-decoding error for that call
- **AND** the original JSON value remains unchanged and usable

#### Scenario: Unsafe object representation

- **WHEN** a caller attempts to provide content that is not representable through Codable JSON semantics
- **THEN** conversion fails
- **AND** Core performs no NSObject archiving, class-name lookup, or executable deserialization

### Requirement: Validated event type namespaces

Event types SHALL be 1 through 128 UTF-8 bytes of dot-separated ASCII segments. Each segment SHALL start with an ASCII letter and continue only with ASCII letters, digits, underscore, or hyphen. User construction SHALL reject `nearwire` and `nearwire.*`; platform construction SHALL require that reserved namespace.

#### Scenario: User event type accepted

- **WHEN** a caller constructs `business.order.stateChanged` as a user event type
- **THEN** the exact type is accepted and preserved

#### Scenario: Malformed event type rejected

- **WHEN** a type is empty, oversized, contains whitespace or unsupported characters, has an empty segment, or has a segment that does not start with a letter
- **THEN** construction fails with a typed event-type validation error

#### Scenario: Reserved namespace protected

- **WHEN** user construction receives `nearwire.performance.snapshot`
- **THEN** it is rejected as reserved
- **AND** platform construction accepts that exact valid reserved type

### Requirement: Draft and envelope ownership separation

Core SHALL model caller-controlled event drafts separately from fully enriched event envelopes. A draft SHALL contain type, content, priority, TTL, and optional causality. An envelope SHALL additionally require ID, wall timestamp, monotonic timestamp, source, target, direction, session epoch, per-direction sequence, and nonzero event schema version.

Internal tagged Codable draft and envelope decoding SHALL cap raw model bytes and JSON nesting before materialization, then apply one active validation-limit set to nested event types, TTL values, and content.

#### Scenario: Draft enrichment

- **WHEN** a valid draft and complete session context are passed to the envelope factory
- **THEN** the result contains every draft field unchanged
- **AND** every factory-owned metadata field is present and validated

#### Scenario: Caller cannot spoof session metadata

- **WHEN** application content is used to create a draft
- **THEN** the draft API has no source, target, direction, session epoch, sequence, timestamp, or schema-version input

#### Scenario: Incomplete decoded envelope

- **WHEN** decoded envelope data omits a required V1 metadata field
- **THEN** decoding fails with a typed envelope error
- **AND** no partially valid envelope is delivered

### Requirement: Validated identity and endpoint metadata

Event IDs and session epochs SHALL use canonical lowercase UUID strings. Endpoint identifiers SHALL be opaque ASCII values from 1 through 128 bytes using letters, digits, dot, underscore, and hyphen. Event direction SHALL be either App-to-Viewer or Viewer-to-App, and source and target roles SHALL agree with that direction.

#### Scenario: Generated identifiers

- **WHEN** the default identifier generator creates event and epoch identifiers
- **THEN** each identifier is a valid canonical lowercase UUID string

#### Scenario: Malformed identifier rejected

- **WHEN** an identifier is malformed, non-canonical, empty, oversized, or contains an unsupported endpoint character
- **THEN** construction or decoding fails with a typed identifier error

#### Scenario: Direction and endpoint mismatch

- **WHEN** an App-to-Viewer envelope names a Viewer source or an App target
- **THEN** envelope validation fails

### Requirement: Deterministic time and TTL semantics

An envelope SHALL carry wall-clock creation time for display and origin monotonic uptime nanoseconds for origin-local duration logic. TTL SHALL be a positive integer millisecond value bounded by validation limits. Expiration SHALL be evaluated by a pure overflow-safe operation using an explicitly supplied current value from the same monotonic clock that produced the creation timestamp. A receiver SHALL NOT compare its local monotonic clock with the sender's timestamp; the future wire protocol SHALL establish a receiver-local remaining lifetime or deadline.

#### Scenario: Default TTL

- **WHEN** a draft omits a custom TTL
- **THEN** it uses 60,000 milliseconds

#### Scenario: Monotonic expiration

- **WHEN** a value from the creation timestamp's same monotonic clock reaches or exceeds creation monotonic time plus TTL
- **THEN** the event is expired regardless of wall-clock changes

#### Scenario: Invalid TTL or clock arithmetic

- **WHEN** TTL is zero, exceeds the active maximum, or expiration arithmetic would overflow
- **THEN** validation fails without wrapping the integer value

### Requirement: Correlation without delivery guarantees

Core SHALL support optional correlation ID and reply-to event ID metadata on ordinary events. These fields SHALL NOT imply acknowledgement, retry, timeout, RPC dispatch, at-least-once, or exactly-once delivery.

#### Scenario: Correlated reply model

- **WHEN** a response envelope carries a request event ID as reply-to and a shared correlation ID
- **THEN** both identifiers round trip unchanged
- **AND** the response remains an ordinary event envelope

#### Scenario: Independent progress correlation

- **WHEN** an event carries a correlation ID without reply-to
- **THEN** the event is valid

### Requirement: Independent schema versioning and forward fields

The logical event schema version SHALL be nonzero, SHALL default to V1, and SHALL remain independent of product and wire-protocol versions. V1 decoding SHALL ignore unknown object fields while requiring every V1 required field.

#### Scenario: Unknown future field

- **WHEN** a V1 envelope contains an additional unknown JSON field
- **THEN** V1 decoding succeeds and preserves all known fields

#### Scenario: Invalid schema version

- **WHEN** an envelope uses schema version zero
- **THEN** validation fails

### Requirement: Core portability and internal API boundary

All event-model production values SHALL be Sendable value types, SHALL compile in Swift 5 language mode for iOS 16 and macOS 13, SHALL import no UIKit, SwiftUI, or AppKit, and SHALL add no external dependency. Supported SDK signatures SHALL NOT expose these internal Core-only declarations.

#### Scenario: Strict platform builds

- **WHEN** repository package verification compiles Core and all SDK products with complete concurrency diagnostics and warnings as errors
- **THEN** iOS 16 and macOS 13 builds pass
- **AND** Core UI-import and dependency boundary gates pass

#### Scenario: Bootstrap distribution graph retained

- **WHEN** distribution manifests are validated after the event model is added
- **THEN** products, targets, paths, dependencies, platforms, language mode, and pod subspec mappings still match the locked contract
