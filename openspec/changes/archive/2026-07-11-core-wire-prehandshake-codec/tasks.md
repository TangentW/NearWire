## 1. Sealed Pre-Handshake Codec

- [x] 1.1 Implement immutable Sendable `WirePreHandshakeCodec` and sealed Sendable `WirePreHandshakeMessage` as repository SPI with a fixed V1 envelope and stored validated limits only.
- [x] 1.2 Add closed hello, safe-error, and disconnect encode operations using existing deterministic framing and exact pre-handshake admission.
- [x] 1.3 Add lane-preflight-first frame decode and a module-internal raw-decoder expected-version guard that rejects non-V1 Control envelopes before type, required-lane, or body interpretation; then apply exact phase admission, closed payload-model switching before result construction, terminal error normalization, and a sealed typed result enum with no admitted-message input.

## 2. Deterministic Protocol Coverage

- [x] 2.1 Add deterministic round trips and byte assertions for hello, safe error, and disconnect, including a wider advertised interval carried in the V1 bootstrap envelope.
- [x] 2.2 Add exact terminal-code tests for raw zero and future Control-envelope versions, including future envelopes whose later fields conflict with V1 type, lane, or body rules; hello acknowledgement; connection rejection; flow-policy offer and acceptance; ping; pong; event; event batch; drop summary; and unknown type. Add malformed Event-lane preflight, malformed/noncanonical/duplicate-key JSON, oversized payload, and malformed or over-limit hello/error/disconnect body failures at `decode(frame:)`.
- [x] 2.3 Add tighter-limit, compile-time codec-and-result Sendable, no-retained-content, and negotiation-handoff tests without network, tasks, timers, or sleeps.

## 3. Boundaries and Documentation

- [x] 3.1 Prove raw messages, payload conformance, admitted internals, the sealed pre-handshake enum, and the codec remain unavailable to normal NearWire consumers in SwiftPM and CocoaPods modes.
- [x] 3.2 Prove package products, targets, dependencies, pod subspecs, supported SDK API inventory, and platform-neutral Core ownership remain unchanged.
- [x] 3.3 Update English wire-protocol and roadmap documentation to distinguish the fixed V1 bootstrap envelope from the later negotiated session codec.
- [x] 3.4 Confirm the change adds no network operation, channel lifecycle, timeout, cancellation, discovery, process-lease claim, Viewer approval, route, flow policy, event transfer, persistence, Keychain access, or UI.

## 4. Validation, Review, and Archive

- [x] 4.1 Run focused and full platform tests, golden fixtures, packaging, API inventory, boundary, structure, English, formatting, version, validation-tool, and OpenSpec gates.
- [x] 4.2 Capture exact commands, run identity, counts, expected notes, API inventory, and residual scope under the change evidence directory.
- [x] 4.3 Run independent architecture/API, correctness/testing, and security/performance/documentation reviews and record every finding.
- [x] 4.4 Resolve every finding, add regressions, and repeat fresh multidimensional review rounds until all report zero unresolved findings.
- [x] 4.5 Complete the spec-to-evidence audit, mark every task complete, validate strictly, archive, and commit before SDK session-admission apply begins.
