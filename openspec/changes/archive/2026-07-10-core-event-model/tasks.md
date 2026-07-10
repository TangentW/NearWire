## 1. JSON Foundation

- [x] 1.1 Replace the NearWireCore marker with production source folders while preserving an internal module availability marker if tests still require it.
- [x] 1.2 Implement typed event-model errors with stable validation paths and Equatable diagnostics.
- [x] 1.3 Implement recursive `JSONValue` Codable, Sendable, Equatable, and Hashable semantics with distinct integer and finite-number cases.
- [x] 1.4 Implement deterministic JSON bytes with sorted object keys and preserved array order.
- [x] 1.5 Implement validated `EventValidationLimits` and bounded traversal for depth, collection, string, key, and encoded-byte limits.
- [x] 1.6 Add JSON scalar, numeric-boundary, nested round-trip, deterministic-order, non-finite, overflow, and adversarial-limit tests.

## 2. Event Identity and Metadata

- [x] 2.1 Implement user and platform `EventType` construction with grammar, byte-length, and reserved-namespace enforcement.
- [x] 2.2 Implement canonical event ID, session epoch, endpoint ID, endpoint role, target, direction, priority, sequence, and schema-version value types.
- [x] 2.3 Implement positive bounded millisecond TTL values, default TTL, and overflow-safe pure monotonic expiration evaluation.
- [x] 2.4 Implement causality metadata with independent correlation and reply-to identifiers.
- [x] 2.5 Add exhaustive valid, malformed, boundary, namespace, direction-role, TTL, overflow, sequence, schema, and causality tests.

## 3. Draft, Envelope, and Codable Bridge

- [x] 3.1 Implement immutable `EventDraft` with type, JSON content, priority, TTL, and optional causality only.
- [x] 3.2 Implement immutable `EventEnvelope` with every required V1 session and timestamp field plus validation of cross-field invariants.
- [x] 3.3 Implement an injected-clock and injected-identifier envelope factory with deterministic fixtures.
- [x] 3.4 Implement `EventContentCodec` for `Encodable & Sendable` conversion, deterministic default JSON settings, and explicit Decodable conversion.
- [x] 3.5 Implement unknown-field compatibility fixtures and required-field failure fixtures for V1 envelopes.
- [x] 3.6 Add draft ownership, deterministic enrichment, Codable round-trip, decode isolation, unsafe representation, and strict-concurrency tests.

## 4. Performance Snapshot Schema

- [x] 4.1 Add the exact reserved performance snapshot event type and schema-version constant.
- [x] 4.2 Implement process, display, device, transport, battery, thermal, and unavailable-metric value models with explicit units.
- [x] 4.3 Implement aggregate snapshot validation for schema header, interval, finite values, ranges, optional groups, and unavailable-versus-zero semantics.
- [x] 4.4 Implement forward-compatible unknown battery and thermal state decoding while retaining event-level raw JSON.
- [x] 4.5 Add complete snapshot round-trip, metric boundary, invalid metric, missing, unavailable, real-zero, unknown-field, unknown-enum, and no-side-effect tests.

## 5. Documentation and Distribution Safety

- [x] 5.1 Add English event-schema documentation covering JSON semantics, field ownership, units, validation defaults, causality, version independence, and performance limitations.
- [x] 5.2 Add reusable deterministic Core test builders only where they reduce duplication without creating supported SDK API.
- [x] 5.3 Format all Swift source and confirm the locked SwiftPM and CocoaPods target, product, provenance, and source-mapping contracts remain unchanged.
- [x] 5.4 Verify new production code and documentation contain no platform UI imports, external dependencies, unsafe object deserialization, or non-English natural-language content.

## 6. Validation, Review, and Archive

- [x] 6.1 Run focused NearWireCore tests plus full iOS Simulator, macOS Core, strict-concurrency, CocoaPods, boundary, distribution-contract, English, and OpenSpec gates.
- [x] 6.2 Capture exact commands, outputs, run identity, test counts, failures, expected tool notes, and residual limitations under the change evidence directory.
- [x] 6.3 Run independent architecture/API, correctness/testing, and security/performance/documentation review round 1 and record every actionable finding.
- [x] 6.4 Resolve every finding, add regression coverage, recapture affected evidence, and repeat fresh multi-agent review rounds until all three dimensions report zero unresolved findings.
- [x] 6.5 Complete a requirement-by-requirement spec-to-evidence audit, mark every task complete, validate OpenSpec strictly, archive the change, and commit it before `core-flow-control` enters apply.
