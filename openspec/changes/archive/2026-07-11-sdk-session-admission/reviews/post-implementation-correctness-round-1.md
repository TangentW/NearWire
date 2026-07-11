# Post-Implementation Correctness Review — Round 1

## Findings

### HIGH — Cancellation can be lost or a cancelled admission can be revived during discovery-to-core transfer

Evidence:

- `SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:142-189`
- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:176-201`
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:756-798`
- `openspec/changes/sdk-session-admission/specs/sdk-session-admission/spec.md:29-31`

After discovery succeeds, `SDKSessionAdmission.execute()` leaves its state as `discovering`, constructs the transport core and channel, and crosses the actor boundary at `await transportCore.bind(channel:)`. It does not record `transferred` or install the attempt token until after that suspension. Cancellation processed in this interval sets the admission to `cancelled`, but execution resumes after `bind`, overwrites the state with `transferred`, and proceeds to `run()`.

A second loss window exists after the admission records `transferred` but before `SDKSessionTransportCore.run()` stores its attempt token. A forwarded `cancelAttempt` processed first sees a nil token and returns; `run()` can then start the channel and deadline with no remaining cancellation request. The existing cancellation test waits until the secure driver has started, which is after both windows, so it cannot detect either failure.

Remediation:

- Make authority transfer atomic before the first post-discovery suspension.
- Install or latch the attempt token in the core as part of construction/arming, before the admission actor exposes `transferred`.
- Make cancellation arriving before `bind` or `run` persist and prevent channel startup; never rely on a one-shot request that can observe an unarmed core.
- Add deterministic barriers for cancellation (a) before/during bind and (b) after admission records transfer but before core run registration. Assert one `cancelled` result, no revival, no deadline leak, and at-most-once channel cancellation.

### HIGH — Reused pull tokens allow stale cancellation to cancel a later pull

Evidence:

- `SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:261-305`
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:405-474`
- `openspec/changes/sdk-session-admission/specs/sdk-session-admission/spec.md:119-123`

`registerPolicyPull` captures `nextPullToken` in the cancellation notification, but increments it only when an empty FIFO installs a waiter. Terminal, `pullAlreadyPending`, and immediate-FIFO outcomes close their gates without retiring the captured token. Cancellation can already have submitted the notification before `close()` wins. A subsequent empty pull may then reuse that token, allowing the stale notification from the earlier completed call to match and cancel the new waiter.

This violates the requirement that losing tokens are ignored. The current pull test covers immediate FIFO delivery and pending cancellation separately, but never delays cancellation from an immediate or `pullAlreadyPending` outcome until after a later waiter reuses the token.

Remediation:

- Allocate a unique token for every successfully claimed gate before installing its cancellation callback, including immediate and rejected core outcomes; a reference-identity token avoids counter ABA and exhaustion concerns.
- Alternatively advance the counter for every claimed gate with an explicitly specified exhaustion outcome.
- Add deterministic stale-callback tests for both immediate-FIFO and `pullAlreadyPending` outcomes: delay their cancellation notification, install a newer pending pull, release the stale notification, and prove the newer waiter remains intact.

### MEDIUM — Required negative protocol and exact error-mapping coverage is incomplete

Evidence:

- `openspec/changes/sdk-session-admission/design.md:232-240`
- `openspec/changes/sdk-session-admission/tasks.md:24-26`
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:696-754`
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:929-981`

The focused suite passes 22 tests, but several cases explicitly required by the design/test task are absent. In particular, there is no end-to-end admission test for incompatible version intervals, no common JSON codec, no common normal policy, unregistered future-version selection, partial-frame EOF, valid pong discard, or a channel terminal racing queued acknowledgement bytes. The current incompatibility test covers only remote role, and the ordering test covers acknowledgement escalation, duplicate hello, and early policy.

These gaps leave branches in `map(wireError:)`, terminal-priority behavior, and the exact `incompatiblePeer`/`transportFailed`/`protocolViolation` taxonomy unproven.

Remediation:

- Add deterministic table-driven hello/negotiation tests for every incompatibility source and assert the exact closed code.
- Add partial-prefix and partial-payload EOF cases and assert `transportFailed` under terminal priority.
- Add valid pong-discard coverage and a queued acknowledgement-versus-latched-terminal test that proves no admitted handle is returned.
- Keep each peer payload hostile/redacted to verify mapping does not leak source text.

### MEDIUM — The required real-TLS admission composition test is not implemented

Evidence:

- `openspec/changes/sdk-session-admission/tasks.md:26`
- `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:873-892`

Task 4.3 requires production composition and real TLS integration coverage. `testLiveDependenciesConstructTheReviewedSecureAppChannel` only constructs the live channel and inspects its setup state and limits; it never starts TLS, exchanges fragmented/coalesced hello and acknowledgement bytes, or returns an admitted session through the production transport boundary. Existing lower-level transport tests do not prove this new admission composition.

Remediation:

- Add an unrestricted integration test using the real secure Viewer listener/App channel path and the admission wire sequence through acknowledgement.
- Assert TLS 1.3/ALPN completion via the existing transport boundary, exact one-time App hello, Viewer identity binding, admitted route, and deterministic cleanup.
- If the environment cannot execute it in the ordinary Swift sandbox, keep the intended integration gate in the packaging script and record the exact unrestricted result rather than replacing it with the construction-only test.

## Validation Performed

- `swift test --disable-sandbox --filter SDKSessionAdmissionTests`: 22 passed, 0 failed.
- Static comparison of the complete active OpenSpec artifacts, current uncommitted implementation, tests, package boundary changes, and documentation.
