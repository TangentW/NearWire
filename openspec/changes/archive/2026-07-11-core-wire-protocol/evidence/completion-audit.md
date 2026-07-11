# Core Wire Protocol Completion Audit

## Audit Basis

- Canonical validation run: `20260711T001821Z-99496`
- Canonical capture status: complete, exit 0
- Automated platform results: iOS 117/117; macOS Core 114/114; NearWireTransport 39/39
- OpenSpec capabilities: wire framing, wire message protocol, wire session negotiation, and wire event transfer
- Final independent review gate: architecture/API, correctness/testing, and security/performance/documentation all reported `ZERO FINDINGS`

## Requirement-to-Evidence Matrix

| Requirement | Implementation and test evidence | Validation evidence | Result |
| --- | --- | --- | --- |
| Deterministic framed bytes | Four-byte big-endian size, lane byte, exact payload, deterministic JSON | Frame and golden suites; `raw/08-swift-package.log` | Proven |
| Independent bounded lanes | 64 KiB Control, 1 MiB Event defaults, 16 MiB hard ceiling, early lane checks | Boundary, hard-prefix, exact-limit, and oversized-lane tests | Proven |
| Incremental decoder | Fragmented/coalesced input, callback delivery, one bounded partial frame, terminal failure | Byte-at-a-time, 1,000-frame, truncation, callback, and reuse tests | Proven |
| Canonical message envelope | Required version/type/body, sorted bytes, duplicate/noncanonical rejection, unknown canonical fields | Message and golden tests | Proven |
| Lane, phase, and capability admission | Known type mapping, Event preflight before JSON, V1 session binding, optional feature gates | Wrong lane/phase/version/capability and invalid-large-preflight tests | Proven |
| Sealed payload boundary | Internal raw message/payload abstractions, opaque admitted value, twelve closed V1 overloads | Positive/negative external compiler gate | Proven |
| Bounded control payloads | Typed hello, acknowledgement, rejection, policies, ping/pong, disconnect, and safe error | Round-trip, text/token/list/rate/error tests | Proven |
| Version negotiation | Highest overlap independent from product version, registered V1 session codec only | Old/new matrix, no overlap, product independence, unsupported V2 session tests | Proven |
| Conservative session contract | JSON, opposite role, normal policy, exact intersections, non-widening event limit | Negotiation and session-codec tests | Proven |
| Viewer identity acknowledgement | Viewer hello identity retained and acknowledgement must match exactly | Valid, capability escalation, field changes, and identity substitution tests | Proven |
| Directional sequence | Public zero start per epoch/direction, exact progression, internal exhaustion hook | Duplicate, gap, direction, epoch, reconnect, and `UInt64.max` tests | Proven |
| Plain JSON events | Every envelope field and JSON case without tagged Codable representation | Event content, fixture inspection, typed golden decode | Proven |
| Canonical lossless wall time | Shortest exact 3–9 digit UTC fractional representation; alternate forms rejected | Millisecond fixture and sub-millisecond exact round trip | Proven |
| Cross-device TTL | Origin remaining duration, overflow-safe deadline, receiver-local deadline only | Partial TTL, expiry, origin overflow, receiver overflow, clock tests | Proven |
| Bounded batches | Count before record construction, per-record limits, cumulative budget, exact V1 frame budget, contiguous session | Count, byte, exact-boundary, mixed epoch/direction, gap, and overflow tests | Proven |
| Drop diagnostics | Bounded unsigned counters with no ACK or retry state | Drop-summary round trip and message-type contract | Proven |
| Error safety and disposition | Stable safe codes/paths/text, operation rejection versus terminal decoder/session promotion | Local configuration/expiry and terminal frame/session tests | Proven |
| Golden compatibility | Checked-in hello, error, event, and batch JSON/hex, exact encode and typed decode | macOS fixture harness and iOS inline golden tests | Proven |
| No transport side effects | Foundation-only protocol code with no socket, TLS, timer, persistence, lock, or UI operation | Boundary scan, package/pod builds, independent review | Proven |

## Review History

- Round 1 found origin-deadline decode overflow, late batch count enforcement, date precision loss, public nonzero sequence starts, incomplete typed golden decode, unbound session versions/capabilities, terminal classification ambiguity, Viewer identity drift, noncanonical JSON acceptance, and direct Core error leakage. All were corrected with regressions.
- Round 2 found unsupported future-version labeling, expensive Event parsing before admission, a raw typed-decode bypass, and local event-limit widening. V1 registration, lane preflight, opaque admission, and non-widening limits resolved them.
- Round 3 found a four-byte false-negative batch boundary, externally conformable wire payloads, and one missing explicit return exposed by Swift 5 compilation. Exact V1 budgeting, sealed closed payload APIs with a cross-module compiler gate, and the return fix resolved them.
- Round 4 independently reported zero findings in architecture/API, correctness/testing, and security/performance/documentation.

## Validation History

An earlier pre-final run exposed that the isolated macOS Core harness did not carry checked-in protocol fixtures. The harness now links `IntegrationTests`, verifies fixture presence before testing, and the canonical run reads and decodes all files successfully. All earlier evidence was replaced; only run `20260711T001821Z-99496` is authoritative.

## Expected Notes and Residual Scope

The CocoaPods `example.invalid` warning is the intentional bootstrap placeholder and must be replaced before release. App Intents lines are metadata notes for targets without AppIntents, not compiler diagnostics.

The next change owns Network.framework byte loops, TLS identity/trust, transport lifecycle, and network resource policy. Bonjour/P2P discovery, pairing admission, reconnection, SDK facade, Viewer persistence/UI, and performance collection remain explicitly outside this protocol change.

## Decision

Every normative requirement and scenario has implementation, automated validation, documentation, canonical evidence, and independent review coverage. The change is ready for strict validation, archive into baseline specifications, archive validation, and commit before `core-transport-security` enters apply.
