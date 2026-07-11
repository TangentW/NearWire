# Post-Implementation Correctness and Testing Review — Round 2

## Scope

Reviewed the complete stable Round 2 diff from scratch against the proposal, design, capability specifications, Tasks 4.4, 5.3, and 6.4, current documentation and evidence, the Round 1 correctness/testing report, and the full active-pump test inventory. The review rechecked all eight Round 1 findings, then independently traced actor reentrancy, cancellation precedence, policy and bucket commit boundaries, decoder fragmentation, retained-byte accounting, queue/heap work bounds, backpressure, lost wakes, and claimed deterministic coverage. No production, test, specification, task, documentation, or evidence source was modified by this review.

## Round 1 Remediation Verification

The current implementation resolves the eight specific Round 1 defects: refresh completion honors relatched work; blocked outbound completion commits deferred policies; observer cleanup respects the cancellation-gate winner; the frame decoder distinguishes a partial successor from a completed over-quantum frame; transport and retention use their correct encoded-byte units; downlink expiry consumes the shared quantum; wrong direction maps to `sequenceViolation`; and focused barrier tests were added for those remediations.

## Findings

### 1. HIGH — A captured `ownerUnavailable` result can be overtaken by initial policy activation

**Evidence**

- During negotiation, a generic owner signal starts one owner-refresh Task, which obtains a level-triggered `SDKOutboundScheduleResult` and may suspend at the new result-delivery barrier before the core consumes it (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:600-628`).
- While that Task remains installed, `receiveRunnerPolicy` does not check `ownerRefreshTask`, `ownerRefreshToken`, or relatched `outboundWorkRequested`. In `.negotiatingPolicy` it immediately calls `activateInitialPolicy` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1066-1093`).
- Activation admits `flow-policy.accepted`, installs both buckets and sequence state, changes the core to `.active`, clears `pendingActivation`, and resumes `run()` (`SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift:1095-1170`). Therefore this deterministic ordering is possible: `NearWire.shutdown()` persists shutdown; refresh captures `.ownerUnavailable` and is held before completion; a Viewer policy offer arrives; the core accepts it and returns an active handle; only after the barrier releases does the already-captured refresh result terminate the session with `ownerUnavailable`.
- The contract requires every generic signal to be followed by its level-triggered availability read and says owner shutdown during policy negotiation terminates through registration or the next refresh without policy timeout or unrelated producer input (`openspec/changes/sdk-active-event-pump/specs/sdk-active-event-pump/spec.md:170-193`). Returning a successfully activated handle after the refresh has already observed persistent shutdown is not a live-owner outcome.
- `testOwnerShutdownSignalDuringRefreshSchedulesOneSuccessor` holds only a live `.available` result and injects no policy while held (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:544-579`). `testOwnerShutdownDuringPolicyNegotiationIsLevelTriggered` has no in-flight refresh result (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:891-906`). Neither test covers the ordering above.

**Impact**

The App can receive an apparently successful active handle and the Viewer can receive policy acceptance even though the exact bound owner was already persistently unavailable and that fact had already been captured by the session's level-triggered refresh. The handle then terminates asynchronously, violating activation's live-owner boundary and making the outcome depend on core mailbox ordering.

**Required remediation**

Do not activate an initial offer while an owner-availability refresh is outstanding or a generic owner signal remains unconsumed. Retain complete offers within the existing bounded policy transaction limits, consume the matching refresh first, and activate only after a live `.available` result; `.ownerUnavailable` must terminate without acceptance bytes or a handle. Add a deterministic test that captures and holds `.ownerUnavailable`, injects an initial offer, proves `run()` and policy acceptance remain pending, then releases the result and asserts exact terminal cleanup. Cover the inverse live-result ordering as well.

### 2. HIGH — Tasks 4.4, 5.3, and 6.4 are marked complete without their required deterministic matrices

**Evidence**

- All three matrix tasks are checked complete (`openspec/changes/sdk-active-event-pump/tasks.md:22,28,35`), but the executable inventory still contains focused representatives rather than the enumerated cross-products and both-winner races.
- Task 4.4 explicitly requires registration-success-with-no-offer. The only `policyNegotiationTimedOut` active test fires the deadline while wake registration itself is still suspended (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:209-237`); it does not complete registration, enter negotiation, withhold the offer, and fire the same deadline. The requirement-to-evidence map nevertheless labels that test as “no policy” evidence (`openspec/changes/sdk-active-event-pump/evidence/requirement-to-evidence.md:17`).
- Task 4.4 also requires dynamic policy during both drain and publication plus multiple-transaction order/backpressure/overflow. The added test covers one deferred offer during one blocked outbound turn (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:581-653`); there is no publication-held transaction test and no `maximumDeferredPolicyTransactions` overflow test.
- Task 5.3 requires zero/fractional/one/burst token cross-products against smaller/equal/larger service, byte, depth, and mailbox bounds, owner shutdown in policy/empty/zero-rate/active states, completion-before-block-result, terminal between committed prefix and result, and exact wake/telemetry matrices. The evidence map composes separate token-bucket, queue, and representative active-drain tests instead of exercising those cross-products through the permanent core (`openspec/changes/sdk-active-event-pump/evidence/requirement-to-evidence.md:9,13-14,19`).
- Task 6.4 requires terminal-before/after-publication and stream-subscriber isolation. The evidence map claims publication gate winners using `NearWireBufferTests.testActiveWireDrainGateHasExactTerminalFirstAndCandidateFirstOutcomes`, but that test exercises outbound queue removal and transport admission, not `NearWire.publishIncomingActive`; the cited downlink and TLS tests publish normally and do not race terminal close (`openspec/changes/sdk-active-event-pump/evidence/requirement-to-evidence.md:16,21`). No active test creates slow and fast subscribers and proves isolation.
- The task wording requires barrier-controlled tests without sleeps. `testTransportBlockWithWholeTokensDoesNotPollUntilCapacityProgress` still treats 100 `Task.yield()` iterations as proof of quiescence (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:436-484`), the shared wait helpers poll wall time while yielding (`SDK/Tests/NearWireTests/NearWireTestSupport.swift:237-244`; `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:3635-3642`), and the active uplink test installs real `Task.sleep` (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:321-360`). These are not barrier proofs of the specified negative/scheduling properties.
- The focused suites pass, but passing does not supply the missing scenarios: the current `SDKSessionAdmissionTests` run executed 55 tests with 0 failures; `NearWireBufferTests`, `WireEventTests`, and `WireFrameTests` executed 46 tests with 0 failures.

**Impact**

The checked task state and requirement-to-evidence map overstate closure. Critical actor-order, bucket/sequence commit, publication-gate, subscriber, overflow, and exact-bound behavior can regress without failing the recorded suite. Finding 1 is one example of a policy/owner ordering that remains outside the claimed matrix.

**Required remediation**

Reopen Tasks 4.4, 5.3, and 6.4 until every named matrix has direct executable evidence. Add table-driven barrier tests for each cross-product and both-winner race, replace yield-count or wall-time negative assertions with observable task-entry/result/completion barriers, and map each normative scenario only to a test that exercises the same production path. In particular, add successful-registration/no-offer, policy-during-publication, deferred FIFO overflow/order, full token/service/byte/depth/mailbox combinations, completion-before-block-result, committed-prefix/terminal orderings, combined FIFO/in-flight count and byte boundaries, publication gate winners, actor-side TTL expiry, subscriber isolation, and terminal cleanup assertions.

## Review Status

**Unresolved finding count: 2 — 2 High.** Correctness/testing closure is not granted. The eight Round 1 defects are remediated, but these two current findings require changes and a fresh independent review round.

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --filter SDKSessionAdmissionTests`: PASS — 55 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --skip-build --filter 'NearWireBufferTests|WireFrameTests|WireEventTests'`: PASS — 46 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
- `git diff --check -- openspec/changes/sdk-active-event-pump/reviews/implementation-round2-correctness-testing.md`: PASS with no output.
- Trailing-whitespace scan of this report: PASS with no matches.
