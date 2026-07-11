# NearWire Queue and Wake Focused Evidence

## Implementation

- Added bounded active schedule observation with a positive service quantum, per-expiration synchronous authorization, due-work continuation, next origin deadline, and nonmutating fair-candidate identity.
- Added active queue offering with independent accepted-token, service-unit, and accounted-byte bounds plus per-expiration, route-drop, and accepted-candidate authorization bodies.
- Added one exact-token outbound wake registration, atomic prebuffered schedule snapshot, level-triggered owner shutdown, stale-token-safe removal, and a synchronous pre-Task coalescing ingress.
- Added an actor-local active wire drain with exact route envelope, origin-clock TTL, accepted-only planned sequence, reserved secure-mailbox admission, Control reservation, constant-size transport block, owner availability, and split committed-prefix/result accounting.
- Added a shared lock gate and deterministic claim hooks required by later active-core composition.

## Focused Runs

- `swift test --filter BoundedEventQueueTests`: 36 executed, 36 passed, 0 skipped, 0 failed in 0.127 seconds at 2026-07-12 00:41:42 +08:00.
- `swift test --filter NearWireBufferTests`: 23 executed, 23 passed, 0 skipped, 0 failed in 0.011 seconds at 2026-07-12 00:59:42 +08:00.

Coverage includes prebuffered registration, stale and second tokens, shutdown before/after registration, notification storms, bounded expiry continuation, stable fairness observation, accepted allowance separate from maintenance, byte stops, exact wire fields/TTL/sequence, sequence-domain failure, route drops, backpressure identity/generation, zero allowance, delayed actor expiry, encoding failure, and deterministic terminal-first/candidate-first gate order.

## Regression Runs

- `swift test --filter NearWireFlowControlTests`: 57 executed, 57 passed, 0 skipped, 0 failed in 0.201 seconds at 2026-07-12 00:58:15 +08:00.
- `swift test --filter NearWireTests`: 120 executed, 120 passed, 0 skipped, 0 failed in 0.073 seconds at 2026-07-12 00:58:15 +08:00.
- The SDK regression run includes 29 session-admission tests and the production TLS admission test.

All SwiftPM commands used `/tmp` module caches and ran outside the nested sandbox because Xcode's manifest sandbox cannot run inside the workspace sandbox.

## Formatting and Specification

- `swift format lint` passed for every changed Swift source and test file.
- `git diff --check` passed.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive` passed.
