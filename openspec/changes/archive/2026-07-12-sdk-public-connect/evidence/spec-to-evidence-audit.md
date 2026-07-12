# Spec-to-Evidence Audit

## Audit result

Every normative requirement and scenario in the active `sdk-public-connect` capability and its modified capability deltas has a production implementation, executable test or explicit source/boundary audit, and preserved validation evidence. No unresolved finding remains in the final independent review round.

## Requirement closure

- Public connect, preflight precedence, state publication, safe errors, and lifecycle non-policy are implemented by the tokenized `NearWire` actor orchestration and covered by focused public tests and the compiled consumer fixture.
- Exact constant-space limits are proven structurally, by equality at the maximum record, by 256 seeded content trees, by exact/one-under production codec traversal, and by named secure-mailbox, active-turn, incoming, batch, and decoder boundary tests.
- App hello product and Bundle metadata are bounded, fixed, and production-TLS verified.
- Installation identity uses the exact modern Keychain transcript, bounded V4 generation, one duplicate reread, no update/delete surface, and complete failure tests.
- Pairing ownership is one-shot at both public and admission boundaries; no connected or terminal owner stores it.
- Cancellation, terminal chronology, target replacement, transfer, connected commit, shutdown authority, lease handoff, sole wait/release, fail-closed wait failure, weak callbacks, and retry outcomes are covered by lock-linearization tests, public async barriers, facade runtime faults, a real-lease child process, and source edge audits.
- Active ownership has no strong path back to `NearWire`; final facade release reaches terminal and exact lease release.
- SwiftPM and CocoaPods expose the same Swift 5/iOS 16 SDK contract, attach only Apple's Security framework to SDK, and expose no implementation type.
- Public supported connect completes production TLS, bidirectional Events, live contention, terminal cleanup, and post-terminal real-lease reacquisition.

## Evidence integrity

- Final focused public suite: 38 passed, 0 failed.
- Final strict full suite independently reviewed: 406 passed, 0 failed on macOS; platform-specific skips are recorded separately by the iOS aggregate gate.
- Final aggregate package gate: iOS 406 total, 402 passed, 4 platform skips, 0 failed; Core 196 passed; internal and public production TLS tests each passed 1/1 without skipping.
- Final CocoaPods gate passed for 0.1.0 with only the documented placeholder-URL warning.
- Boundary, structure, English, version, validation-tool, formatting, diff, and strict OpenSpec gates passed.
- Preserved aggregate summaries match `evidence/logs/SHA256SUMS`.
- Round 4 architecture/API, correctness/testing, and security/performance/documentation reports each record zero unresolved actionable findings.

## Residual scope

Disconnect, retained-code reconnect, retry policy, foreground/background behavior, route replacement, terminal-reason observation, Viewer UI, and broader lifecycle semantics remain outside this change. No residual item is required for supported one-shot `connect(code:)`.
