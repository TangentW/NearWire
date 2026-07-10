# Core Event Model Completion Audit

## Audit basis

- Canonical validation run: `20260710T222748Z-85587`
- Canonical capture status: complete, exit 0
- Final archive review: round 6, zero findings in all three required dimensions after the round-5 audit regressions
- OpenSpec capabilities: event model and performance snapshot schema

## Requirement-to-evidence matrix

| Requirement | Implementation and test evidence | Validation evidence | Result |
| --- | --- | --- | --- |
| Lossless bounded JSON values | `JSONValue`, lexical preflight, compact tagged Codable, JSON limit and numeric tests | `raw/08-swift-package.log` | Proven |
| Deterministic Codable content bridge | `EventContentCodec`, stable date/Base64 tests, decode-isolation test | 31 NearWireCore tests under macOS and iOS | Proven |
| Validated event type namespaces | `EventType`, grammar/length/reserved tests | Strict package and pod builds | Proven |
| Draft and envelope ownership | `EventDraft`, `EventEnvelope`, compact-tagged draft round trip, injected factory, required/unknown-field tests | iOS 37/37; macOS 34/34 | Proven |
| Identity and endpoint metadata | UUID, endpoint, role, direction types and malformed/mismatch tests | Strict concurrency and warnings-as-errors | Proven |
| Deterministic time and TTL | Origin-clock-labeled overflow-safe TTL operation and boundary tests | Design, specification, and final semantic review | Proven |
| Correlation without guarantees | Independent optional correlation and reply-to model and round trip | Documentation semantic review | Proven |
| Independent schema version and forward fields | Nonzero V1 type, unknown-field and required-field fixtures | OpenSpec strict validation | Proven |
| Core portability and internal boundary | Sendable value types, no UI imports or dependency changes | `raw/07-boundaries.log`, `raw/08-swift-package.log`, `raw/09-cocoapods.log` | Proven |
| Reserved performance snapshot | Exact platform type and V1 snapshot round trip | NearWireCore performance tests | Proven |
| Metric units and ranges | Validated process/display/device/transport types and boundary fixtures | Documentation and final semantic review | Proven |
| Missing, unavailable, and zero semantics | Optional fields, explicit reasons, missing/unavailable/zero tests | NearWireCore performance tests | Proven |
| Conservative metric boundary | No numeric GPU, watts, or Celsius fields; categorical thermal and estimated FPS | Import/side-effect checks and documentation | Proven |
| Forward-compatible performance content | Unknown fields retained in raw JSON; unknown states map to `unknown` | Future-field and future-enum fixtures | Proven |
| No collection side effects | Schema contains only Foundation value logic | Boundary scan and no-side-effect test | Proven |

## Scenario audit

- Plain JSON preserves null, Boolean, `Int64` boundaries, floating-point syntax, strings, arrays, and objects; object keys are deterministic and array order is unchanged.
- Lexical integers outside signed 64-bit range fail before Foundation can round them into doubles. Decimal and exponent forms remain finite floating-point numbers.
- Raw content, canonical content, and internal tagged aggregate bytes and nesting are bounded before costly decoding. A valid 254,015-byte many-scalar payload round-trips under defaults.
- User event construction cannot claim `nearwire.*`; the exact performance type is available through the platform path.
- Draft callers cannot supply session metadata. Factory clocks and IDs are injectable and deterministic in tests.
- Custom limit sets propagate through aggregate and nested decoding; stricter type and default TTL policies reject noncompliant models.
- Monotonic expiration is explicitly origin-local. Mac and iPhone uptimes are never treated as comparable.
- Missing required envelope and each required snapshot header fail, while unknown fields and future battery or thermal values remain forward-compatible.
- Performance zero remains a real value, absence remains missing, and explicit unavailability never fabricates a numeric metric.
- Core compiles for iOS 16 and macOS 13 in Swift 5 language mode with complete concurrency diagnostics and warnings as errors.
- SwiftPM products, target paths, dependencies, CocoaPods source mappings, subspec graph, and provenance remain unchanged.

## Review history

- Round 1 found numeric Codable loss, inconsistent custom limits, pre-materialization input limits, and cross-device monotonic misuse. All were fixed with regressions.
- Round 2 found very-large lexical integer rounding, tagged aggregate bounding, and remaining clock-language ambiguity. All were fixed with regressions.
- Round 3 found verbose-tag expansion beyond the model cap and one inaccurate numeric-format sentence. Both were fixed with a compact representation, cap invariant, near-limit test, and documentation correction.
- Round 4 independently reported zero findings in architecture/API, correctness/testing, and security/performance/documentation.
- Round 5 completion audit found missing direct draft Codable and required performance-header fixtures; both were added and the full canonical run was recaptured.
- Round 6 reviewed the corrected tests, canonical run, requirement mapping, and archive readiness with zero unresolved findings.

## Expected notes and residual scope

The CocoaPods `example.invalid` URL warning is an intentional non-resolving bootstrap placeholder and must be replaced before release. App Intents metadata extraction lines are CocoaPods notes for targets that do not link AppIntents.

Wire framing, receiver-local TTL establishment, queueing, flow control, transport, Bonjour, pairing, SDK facade APIs, collectors, persistence, and Viewer UI remain explicitly assigned to later changes. No residual issue blocks archiving this logical event-model change.

## Decision

Every requirement and scenario has implementation, automated validation, documentation, and independent zero-finding review evidence. The change is ready for strict validation, archive into baseline specifications, and commit before the next apply phase.
