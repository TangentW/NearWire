## 1. Protocol Primitives and Limits

- [x] 1.1 Implement typed wire errors with stable codes, paths, safe messages, and terminal/nonterminal classification.
- [x] 1.2 Implement validated wire version, interval, lane, message type, codec, capability, send-policy, product string, and bounded-text values.
- [x] 1.3 Implement coherent frame, control-payload, event, batch, and collection limits with documented defaults and hard ceilings.
- [x] 1.4 Add construction, Codable/plain-JSON, invalid UTF-8/token, boundary, Sendable, and arithmetic tests.

## 2. Length-Prefixed Framing

- [x] 2.1 Implement four-byte big-endian length encoding with one Control/Event lane byte and exact payload preservation.
- [x] 2.2 Implement a bounded incremental callback decoder for split prefixes, split lane/payload, byte-at-a-time input, coalesced frames, and empty input.
- [x] 2.3 Enforce hard and lane-specific limits before payload buffering, terminal failure after malformed input, and atomic decoder state on callback errors.
- [x] 2.4 Add zero/one length, UInt32 boundary, unknown lane, oversized Control/Event, truncation, terminal reuse, many-frame, and no-side-effect tests.

## 3. Message Envelope and Control Payloads

- [x] 3.1 Implement deterministic sorted-key plain JSON message envelopes with required version/type/body and forward-compatible unknown fields.
- [x] 3.2 Implement lane/type mapping plus pure pre-handshake, approval, policy-negotiation, active, and closing admission rules.
- [x] 3.3 Implement typed hello, acknowledgement, rejection, flow offer/acceptance, ping/pong, disconnect, and protocol-error bodies with explicit bounds.
- [x] 3.4 Add exact JSON, missing/wrong field, unknown field/type, wrong lane/phase, bounded text/list/metadata, safe error, and round-trip tests.

## 4. Negotiation and Session Sequence

- [x] 4.1 Implement highest-overlap wire-version selection independent of product and event-schema versions.
- [x] 4.2 Implement JSON codec, opposite-role, normal-policy, conservative event-byte, capability, and send-policy negotiation.
- [x] 4.3 Implement acknowledgement validation that cannot escalate version, codec, size, capability, or policy beyond the negotiated result.
- [x] 4.4 Implement per-epoch/per-direction sequence counters and validators with zero start, exact progression, overflow, duplicate, gap, direction, and epoch errors.
- [x] 4.5 Add old/new peer matrices, no-overlap/no-codec/same-role cases, unknown capability behavior, acknowledgement escalation, reconnect epoch, and sequence tests.

## 5. Event Transfer and Receiver TTL

- [x] 5.1 Implement explicit plain-JSON mapping for every `EventEnvelope` field and every `JSONValue` case without internal Codable tags.
- [x] 5.2 Implement origin-local remaining TTL calculation plus receiver-local deadline establishment and expiry checks with overflow safety.
- [x] 5.3 Implement bounded single-event, contiguous one-session batch, and diagnostic drop-summary payloads.
- [x] 5.4 Add content fidelity, ISO date, validation-limit, exact TTL, expired sender, receiver overflow, mixed batch, noncontiguous batch, count, byte, and non-ACK tests.

## 6. Golden Fixtures and Documentation

- [x] 6.1 Add canonical V1 hello, error, event, and event-batch JSON and framed hexadecimal fixtures under `IntegrationTests/Fixtures/Protocol/v1`.
- [x] 6.2 Verify golden bytes inline on every platform and checked-in fixture files on macOS without changing package resources or runtime dependency graphs.
- [x] 6.3 Add English protocol documentation covering bytes, limits, lanes, handshake, negotiation, phases, events, batches, TTL, sequence, errors, compatibility, and non-guarantees.
- [x] 6.4 Confirm no supported SDK signature exposes internal wire types and no protocol primitive starts network, TLS, timer, persistence, lock, or UI work.

## 7. Validation, Review, and Archive

- [x] 7.1 Run focused NearWireTransport and affected NearWireCore tests plus full iOS Simulator, macOS Core, strict-concurrency, CocoaPods, boundary, distribution, English, and OpenSpec gates.
- [x] 7.2 Capture exact commands, run identity, outputs, test counts, failures, expected notes, and residual limitations under the change evidence directory.
- [x] 7.3 Run independent architecture/API, correctness/testing, and security/performance/documentation review round 1 and record every finding.
- [x] 7.4 Resolve every finding, add regressions, recapture affected evidence, and repeat fresh review rounds until all three dimensions report zero unresolved findings.
- [x] 7.5 Complete a requirement-by-requirement audit, mark every task complete, validate strictly, archive into baseline specs, and commit before `core-transport-security` enters apply.
