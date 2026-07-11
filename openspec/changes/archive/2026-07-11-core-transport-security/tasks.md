## 1. Transport Values and TLS Plan

- [x] 1.1 Implement typed roles, lifecycle states, safe transport errors/dispositions, validated limits, and fixed V1 TLS/ALPN constants.
- [x] 1.2 Implement role-specific mandatory-TLS Network.framework parameter factories with TCP ordering and peer-to-peer routing.
- [x] 1.3 Make plaintext, weaker TLS, alternate ALPN, and missing Viewer identity unrepresentable through supported factories.
- [x] 1.4 Add construction, hard-bound, platform availability, Swift 5, Sendable, and parameter-plan tests.

## 2. Viewer Identity and App Trust

- [x] 2.1 Implement caller-owned Viewer `SecIdentity` adaptation without Keychain, generation, export, logging, or persistence side effects.
- [x] 2.2 Implement fixed App verification using presented-leaf connection-local anchoring, Basic X.509 policy, anchor-only evaluation, and fail-closed completion.
- [x] 2.3 Add optional safe SHA-256 leaf fingerprint derivation for diagnostics without persistence or automatic trust comparison.
- [x] 2.4 Add valid, missing, malformed, expired/evaluation-failure, callback-once, private-material, and no-trust-all tests through injected Security seams where required.

## 3. Bounded Secure Byte Channel

- [x] 3.1 Implement an injected connection driver contract and thin NWConnection production adapter.
- [x] 3.2 Implement single-start lifecycle, one outstanding bounded receive, exact chunk delivery, EOF/anomaly handling, and one terminal outcome.
- [x] 3.3 Implement pre-retention pending count/byte admission, overflow-safe accounting, one FIFO send in flight, and exact completion release.
- [x] 3.4 Implement idempotent cancellation, generation-safe late callback rejection, pending cleanup, and no retry/reconnect behavior.
- [x] 3.5 Add deterministic fault-injection, ordering, reentrancy, race, backpressure, overflow, cancellation, late-callback, and resource-bound tests.

## 4. Security Documentation and Boundary Proofs

- [x] 4.1 Add English transport-security documentation covering TLS policy, ALPN, P2P routing, identity ownership, connection-local trust, authentication limitation, lifecycle, bounds, and non-guarantees.
- [x] 4.2 Confirm no SDK signature exposes transport internals and no transport primitive performs discovery, pairing, persistence, retry, UI, or certificate lifecycle work.
- [x] 4.3 Add compile/boundary checks proving supported factories cannot construct plaintext and Core remains SwiftPM/CocoaPods compatible without graph drift.

## 5. Validation, Review, and Archive

- [x] 5.1 Run focused transport and affected protocol tests plus full iOS Simulator, macOS Core, strict-concurrency, CocoaPods, boundary, distribution, English, and OpenSpec gates.
- [x] 5.2 Capture exact commands, run identity, outputs, counts, expected notes, security limitations, and residual scope under the change evidence directory.
- [x] 5.3 Run independent architecture/API, correctness/testing, and security/performance/documentation review and record every finding.
- [x] 5.4 Resolve every finding, add regressions, recapture evidence, and repeat fresh reviews until all dimensions report zero unresolved findings.
- [x] 5.5 Complete a requirement audit, mark every task complete, validate strictly, archive into baseline specs, and commit before `sdk-public-api` enters apply.
