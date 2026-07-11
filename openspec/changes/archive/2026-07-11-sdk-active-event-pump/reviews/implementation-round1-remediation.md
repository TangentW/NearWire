# Post-Implementation Review Round 1 Remediation

## Architecture/API Findings

1. **Owner shutdown during binding or policy negotiation** — added a tokenized owner-refresh operation that is legal while binding and negotiating, consumes a signal latched before binding-result delivery, and routes owner unavailability through the single terminal authority. `testOwnerShutdownDuringPolicyNegotiationIsLevelTriggered` proves the no-offer case and the existing wake-registration matrix proves shutdown before, during, and after assignment.
2. **Pre-latched run cancellation precedence** — the first runner now claims its cancellation gate after stored-terminal and same-starter checks but before policy-consumer ownership. `testPrecancelledRunnerWinsOverExistingPolicyPullOwnership` and `testCancellationLatchedAtActivationCommitReturnsNoHandle` prove both precedence boundaries.
3. **Wake assignment and initial snapshot transaction** — callback assignment claims the shared operation gate. The initial scheduling observation then services every due expiration under its own claim, allowing terminal to win between two expirations while preserving an exact installed-token result.
4. **Discarded active diagnostics** — the permanent core now owns constant-size saturating remote overflow/expiry/coalescing counters and a local incoming-expiry counter. `testRemoteDropDiagnosticsAccumulateWithSaturation` and `testZeroRateDownlinkExpiryIncrementsLocalDiagnostic` prove saturation and receiver-local expiry accounting.

## Security/Performance/Documentation Findings

1. **Positive-token backpressure polling** — a stable blocked candidate now excludes token availability from wake selection. Only capacity progress, queue/policy/owner/terminal change, or the candidate TTL can retry it. `testTransportBlockWithWholeTokensDoesNotPollUntilCapacityProgress` proves task-turn stability until send completion.
2. **Completed-frame quantum continuation** — the active core now fails closed with `activeWorkLimitExceeded` when one receive callback contains complete work beyond the configured quantum; it retains no continuation backlog. `testActiveFrameQuantumFailsClosedWithoutContinuationChain` proves exact-limit survival and one-over-limit termination.
3. **Owner shutdown during policy negotiation** — remediated by the same level-triggered refresh described above.
4. **Incomplete integration and evidence** — the production TLS integration now performs admission handoff, policy activation, one App-to-Viewer Event, one Viewer-to-App Event, queue drain, and terminal teardown. Deterministic transport backpressure is covered separately at the same production mailbox seam. Fresh strict-concurrency, packaging, CocoaPods, static-boundary, formatting, tool, and OpenSpec gates are recorded in evidence, together with API and requirement inventories.

## Fresh Verification Before Round 2

- Focused `SDKSessionAdmissionTests`: 48 passed, 0 failed.
- Full complete-strict-concurrency package: 333 passed, 0 failed.
- Production TLS active-session filter: 1 passed, 0 skipped, 0 failed.
- SwiftPM packaging: passed; iOS package 332 passed plus one platform-expected skip; Core harness 191 passed.
- CocoaPods 1.16.2 lint and all subspec builds: passed with only the expected placeholder-URL warning.

Every Round 1 finding is implemented and covered. Closure still requires fresh independent Round 2 reviews.

## Correctness/Testing Findings

The delayed correctness report identified seven additional code defects plus an incomplete-matrix finding. They were remediated before Round 2:

1. An owner signal relatched while a negotiation refresh is in flight now schedules one bounded successor after the matching result. `testOwnerShutdownSignalDuringRefreshSchedulesOneSuccessor` holds result delivery behind a one-shot barrier.
2. Every outbound completion, including a blocked scheduling result, reaches the common deferred-policy commit boundary. `testDeferredPolicyCommitsAfterBlockedOutboundResult` injects a policy while that result is held.
3. Terminal cleanup now asks the observer cancellation gate which side already won. Cancellation-first returns only `terminationWaitCancelled`; terminal-first returns the terminal code. `testTerminationObservationCancellationWinnerSurvivesTerminalCleanup` delays the cancellation callback until after cleanup.
4. Bounded frame decoding now consumes and retains a partial next frame but reports overflow only when frame `N + 1` completes in the same callback. The primitive test covers every split point, and the active test covers fragmented and complete overflow cases.
5. Transport activation validates the exact maximum single-Event frame including the deterministic message wrapper and frame overhead. Incoming retention charges each record's deterministic bytes independently, including heterogeneous batches. Exact helper, transport cross-limit, and atomic batch-overflow tests cover the units.
6. Incoming expiries consume the same per-turn allowance as publications. When expiry consumes the full allowance, an identity-tokenized immediate continuation is scheduled before a live head can publish. A barrier holds that continuation for exact state assertions.
7. Epoch and endpoint mismatches map to `routeMismatch`; wrong active direction reaches `sequenceViolation` before endpoint comparison. A dedicated active test proves the closed code.
8. The requirement map links every capability requirement and its scenario groups to named deterministic tests. The new race tests use one-shot barriers and controlled clocks rather than timing sleeps for winner assertions.

Fresh focused result after these changes: 55 active-session tests, 12 Event protocol tests, and 11 frame tests passed (78 total, zero failures).

## Round 2 Remediation

1. Initial policy activation now waits while an owner refresh or relatched owner signal is outstanding. Complete offers use the existing bounded deferred-policy FIFO. A captured `ownerUnavailable` terminates without acceptance or a handle; a captured live result activates the buffered offer. Both orders have one-shot barrier tests.
2. Downlink-specific operation-gate evidence now forces terminal-first and publication-first. It proves in-flight count/byte charge retention, no post-terminal publication, exactly one publication-first Event, deferred policy FIFO ordering and overflow, combined FIFO/in-flight count and byte overflow, and slow-subscriber isolation.
3. Successful wake registration followed by no policy now has a controlled deadline test. Active empty and zero-rate owner shutdown are covered directly.
4. Uplink coverage now includes completion-before-blocked-result and a table-driven token-allowance/service/byte/depth/mailbox matrix. The active uplink test no longer installs a real sleeping timer.
5. The documentation and task/power audit now include the negotiation-only tokenized owner refresh, its single-successor rule, mutual exclusion, and cleanup.

Fresh focused result: 65 active-session tests plus 24 queue/wire-drain tests passed with zero failures.

## Round 3 Remediation

1. A live owner-refresh result now activates the oldest buffered initial policy before granting another Event-work successor. The signal remains latched for active drain. A held-refresh signal storm proves the valid Control offer cannot be starved until timeout.
2. Wake registration now claims only token assignment; its initial schedule uses the ordinary per-expiration gate path. A three-claim barrier proves terminal can win after the first of two due expirations and the second remains for a later open claim.
3. One immutable typed live-operation value is bound before active mutation to the exact `NearWire`, secure channel, session clock, and operation gate. Active wake, schedule, drain, mailbox, and publication calls use that value and expose operation-specific internal hooks.
4. Publication-first terminal coverage now cancels after Event-hub publication wins but before the core result returns, then proves exact cleanup, one publication, one channel cancellation, and rejection of the stale result. Policy deferral remains a separate nonterminal test.
5. Uplink coverage now includes a permanent-core zero/fractional/one/burst allowance test, an 81-case service/byte/depth/mailbox Cartesian limiter matrix, dynamic-policy clock reversal before acceptance, a terminal-after-committed-prefix stale-result test, and an operation-entry counter with explicit competing actor turns for the no-poll property.
6. The task/timer/power inventory now distinguishes the one unretained binding-time wake-registration Task from core-retained Tasks. Terminal invalidates its binding token and gate but the Task self-releases only after its bounded owner-actor call returns; a stale installed wake is removed through the captured live-operation value.
7. Wake assignment now captures a nonmutating exact scheduling snapshot inside the same gate claim. Due work is level-triggered into the ordinary refresh, preserving a separate gate claim for every expiration. Named hooks now target expiration, route-drop, candidate, Event-mailbox admission/progress, mailbox completion, observer cancellation, and terminal close; race tests no longer locate these operations by global claim number.

Fresh focused result after these changes: 70 active-session tests plus 26 queue/wire-drain tests; the complete `NearWireTests` target ran 165 tests with zero failures.
