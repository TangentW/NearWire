## 1. Public Event and Configuration Values

- [x] 1.1 Implement NearWire-owned configuration, buffer limits, stream limits, priorities, delivery policies, TTL, state, direction, event, content, send-result, diagnostics, and safe error values.
- [x] 1.2 Implement exhaustive internal conversion to Core event/flow values without public implementation-module leakage.
- [x] 1.3 Implement deterministic Codable encode/decode behavior, instance/session-affine causal replies, collision-safe IDs, built-in event SPI, and safe error mapping.
- [x] 1.4 Add API value, validation, nested-content, date/data, non-finite-number, causality routing, cross-instance, built-in SPI, collision, and error-safety tests.

## 2. Instance Facade and Offline Buffer

- [x] 2.1 Implement the instance-based NearWire actor with side-effect-free initialization and isolated clocks/ID generation.
- [x] 2.2 Implement normal and keep-latest send admission into the bounded in-memory uplink queue with exact local-effect results.
- [x] 2.3 Implement monotonic TTL expiration, priority-aware overflow, public diagnostics, explicit clearing on shutdown, and no persistence.
- [x] 2.4 Implement narrow internal publish, state-update, and atomic transport-admission drain seams for the later session coordinator without long-lived reservations.
- [x] 2.5 Add deterministic instance isolation, queue boundary, replacement, TTL, overflow, in-place rejection, routing-drop, clear, and lifecycle tests.
- [x] 2.6 Add transactional fair-candidate offering and synchronous secure-channel mailbox admission with concurrent bound, ownership, terminal cleanup, real-channel handoff, and encoding-deferral tests.

## 3. Bounded Async Observation

- [x] 3.1 Implement latest-state multi-subscriber streams with an immediate current snapshot and cancellation cleanup.
- [x] 3.2 Implement bounded incoming-event multi-subscriber streams that fail only a slow subscriber instead of silently dropping.
- [x] 3.3 Implement idempotent shutdown, final state delivery, stream termination, post-shutdown rejection, and deinitialization cleanup.
- [x] 3.4 Add deterministic multi-subscriber, overflow, cancellation, shutdown, late-publish, and no-retention tests without sleeps.

## 4. Distribution Boundary and Documentation

- [x] 4.1 Add iOS SwiftPM and CocoaPods-generated public consumer compile fixtures covering the supported facade and built-in SPI APIs.
- [x] 4.2 Hide Core behind repository-only SPI and extend package/pod boundary gates to prove normal consumers expose no Core, flow-control, transport, or platform networking type.
- [x] 4.3 Add English SDK API documentation covering setup, instance ownership, send/decode/reply examples, buffering, streams, shutdown, errors, and non-guarantees.
- [x] 4.4 Confirm this change adds no Bonjour, pairing, connection, persistence, UI, performance collector, singleton, hidden task, or timer behavior.

## 5. Validation, Review, and Archive

- [x] 5.1 Run focused SDK tests plus full iOS Simulator, macOS Core/SDK, strict-concurrency, CocoaPods, boundary, distribution, English, and OpenSpec gates.
- [x] 5.2 Capture exact commands, run identity, outputs, counts, expected notes, public API inventory, and residual scope under the change evidence directory.
- [x] 5.3 Run independent architecture/API, correctness/testing, and security/performance/documentation review and record every finding.
- [x] 5.4 Resolve every finding, add regressions, recapture evidence, and repeat fresh reviews until all dimensions report zero unresolved findings.
- [x] 5.5 Complete a requirement audit, mark every task complete, validate strictly, archive into baseline specs, and commit before `sdk-discovery-session` enters apply.
