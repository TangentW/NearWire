## 1. Early Streaming Lane Admission

- [x] 1.1 Add a synchronous non-retained lane-preflight operation to `WireFrameDecoder` after lane and declared-size validation but before payload reservation or copy.
- [x] 1.2 Preserve allow-all behavior for existing callers and terminal error normalization for wire and non-wire preflight failures.
- [x] 1.3 Add fragmentation, coalescing, exact-once invocation, early Event rejection, no-payload-retention, callback-failure, and terminal-reuse tests.

## 2. Internal Session Admission State Machine

- [x] 2.1 Add closed internal admission/core states, the complete concrete limit table including outbound hello/pong capacity relationships, exhaustive code-only admission/attachment errors, production dependencies, and one explicit side-effect-free-until-run actor.
- [x] 2.2 Compose exact pairing discovery and `SecureAppTransport` creation without claiming the process lease or touching the `NearWire` facade.
- [x] 2.3 Add one permanent transport-core actor plus bounded single-drain weak-routed channel callback ingress with terminal priority, byte/event overflow failure, no callback retargeting, no retain cycle, and no late retention; transfer result/terminal authority from discovery exactly once with an invalidatable attempt token.
- [x] 2.4 Revalidate and encode the local App hello against the exact admission wire limits before discovery, then add one continuous frame decoder and exact TLS-ready, App-hello, Viewer-hello, discriminator-binding, negotiation, and acknowledgement sequence using those same limits.
- [x] 2.5 Add bounded awaiting-approval ping/pong handling and fixed terminal mapping for rejection, error, disconnect, malformed, out-of-order, incompatible, and escalated input.
- [x] 2.6 Add discovery, secure-admission, and pump-attachment deadline tokens; explicit/task/last-handle cancellation; exact cleanup; and at-most-once discovery/channel cancellation.

## 3. Admitted Session Ownership

- [x] 3.1 Add internal redacted `SDKAdmittedSession` and exactly-once pump-attachment handles that alone share one relay retaining the permanent core owner of channel, decoder, negotiated codec, route, capabilities, policies, and event limit at `negotiatingPolicy`; the core must not retain the relay.
- [x] 3.2 Add provisional acknowledgement commit at the end of its receive chunk, one permanent flow-policy FIFO across attachment, exactly one tokenized async pull with a pre-handler lock-protected cancellation gate and immediate/suspended/concurrent/pre-cancelled/cancelled/terminal behavior, cumulative handoff work budgets covering ping/pong and retained policy messages, terminal handling, and Event-lane early rejection.
- [x] 3.3 Add one external-handle-owned exact-once cancellation relay for explicit cancellation and final-handle release; prove dropping the admission handle after pump attachment preserves the session, final pump-handle release cancels once, admission-actor release after success loses no callbacks, and terminal paths release pairing code, discovery identity, remote metadata, raw frames, partial bytes, pull waiter, backlog, deadlines, and callbacks.

## 4. Deterministic Coverage and Boundaries

- [x] 4.1 Add happy-path fragmented and coalesced admission tests with exact sent bytes, identity binding, route, negotiated values, and post-acknowledgement handoff.
- [x] 4.2 Add full negative protocol, identity, frame, ingress, all-three-deadline, cancellation/authority-transfer, stale-attempt-token, provisional-acknowledgement, callback/attachment, admission-vs-final-pump-handle release, empty/concurrent/pre-cancelled/pre-registration-cancelled/post-immediate-cancelled/terminal policy pull, compound pre-cancelled-plus-terminal/FIFO/waiter precedence, cumulative ping/pong-work, outbound-send-capacity, limit-relationship, exhaustive error-code, and diagnostic-redaction matrices without sleeps or live Bonjour dependence.
- [x] 4.3 Add production composition and real TLS integration coverage proportional to the network boundary, while preserving deterministic unit seams.
- [x] 4.4 Prove normal SwiftPM and CocoaPods consumers cannot name any admission type and supported API, products, targets, dependencies, pod subspecs, entitlements, and privacy declarations remain unchanged.
- [x] 4.5 Prove the change claims no process lease, mutates no supported NearWire state, drains no queue, publishes no incoming event, negotiates no effective rate, and transfers no Event message.

## 5. Documentation, Validation, Review, and Archive

- [x] 5.1 Add English session-admission documentation covering sequence, state, identity limits, TLS non-authentication, timeouts, cancellation, ownership handoff, and residual scope.
- [x] 5.2 Run focused and full platform tests, production TLS tests, packaging, CocoaPods, API inventory, boundary, structure, English, formatting, version, validation-tool, and strict OpenSpec gates.
- [x] 5.3 Capture exact commands, run identity, counts, API inventory, expected notes, retention audit, and residual scope under the active change evidence directory.
- [x] 5.4 Run independent architecture/API, correctness/testing, and security/performance/documentation reviews before apply and after implementation; record and resolve every finding with fresh rounds until all report zero.
- [x] 5.5 Complete the spec-to-evidence audit, mark every task complete, validate strictly, archive, and commit before `sdk-active-event-pump` apply begins.
