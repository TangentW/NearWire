## Why

NearWire needs one deterministic, platform-neutral event model before queues, wire framing, SDK APIs, or Viewer persistence can be implemented. Defining JSON content, metadata, validation, identity, correlation, and built-in performance schemas now prevents those later layers from inventing incompatible representations.

## What Changes

- Add a lossless JSON-compatible value model with deterministic Codable conversion and raw-value preservation.
- Add validated event type, event identifier, endpoint, direction, priority, correlation, session epoch, sequence, wall-clock, monotonic-clock, TTL, and schema metadata models.
- Separate caller-provided event drafts from fully enriched event envelopes so transport-assigned metadata is never optional or fabricated by call sites.
- Add bounded event validation for names, reserved namespaces, JSON depth, collection size, string size, total encoded size, timestamps, TTL, identifiers, and sequence metadata.
- Add stable Codable helpers that convert `Encodable & Sendable` payloads to JSON values and decode received JSON values without unsafe object archiving or runtime type lookup.
- Reserve the `nearwire.*` namespace for platform-owned events while allowing explicit internal construction for protocol and built-in schemas.
- Add a versioned, cross-platform performance snapshot schema with explicit units, availability semantics, and forward-compatible optional metrics.
- Add deterministic unit tests, fixtures, and English schema documentation for every new model and failure condition.

## Capabilities

### New Capabilities

- `event-model`: JSON values, event drafts and envelopes, identifiers, metadata, correlation, Codable conversion, namespace rules, and validation limits.
- `performance-snapshot-schema`: Versioned platform-neutral performance snapshot content, units, metric availability, and compatibility behavior.

### Modified Capabilities

None.

## Impact

- Replaces the `NearWireCore` bootstrap marker with production event-model source under `Core/Sources/NearWireCore/Event` and built-in schema source under `Core/Sources/NearWireCore/Builtins/Performance`.
- Adds comprehensive tests under `Core/Tests/NearWireCoreTests` and reusable fixtures under `Core/TestSupport/NearWireTestSupport` when cross-target support is useful.
- Does not add networking, queueing, persistence, SDK public API, Viewer UI, third-party dependencies, or public consumer guarantees.
- Preserves the root SwiftPM and CocoaPods distribution graph and the internal-Core/public-facade boundary established by project bootstrap.
