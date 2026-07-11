# Post-Implementation Correctness and Testing Review — Round 3

## Scope

Reviewed the complete current diff from scratch against the proposal, design, capability specifications, task plan, documentation, evidence, prior correctness reports, and executable inventory. The review specifically retraced owner-refresh ordering before initial policy activation, successful-registration/no-offer timeout, terminal/publication gate winners, policy FIFO ordering and overflow during publication, subscriber isolation, combined FIFO/in-flight count and byte limits, capacity completion before a blocked result, owner shutdown in active and zero-rate states, and the uplink bound matrix. No production, test, specification, task, documentation, or evidence source was modified by this review.

## Remediation Verification

The two Round 2 findings are materially remediated. Initial policy offers are now bounded and deferred behind outstanding owner availability, with deterministic unavailable-first and live-first tests. The new suite also directly covers post-registration no-offer timeout, both downlink publication gate outcomes, ordered and overflowing policy deferral during publication, slow-subscriber isolation, combined in-flight count/byte overflow, completion-before-blocked-result, and owner shutdown in active positive- and zero-rate sessions. I found no new actionable production-code defect in those paths.

## Findings

### 1. HIGH — The checked uplink and race-matrix tasks still exceed their executable coverage

**Evidence**

- Task 5.3 requires zero, fractional, one, and burst-token **cross-products** against smaller, equal, and larger service, byte, depth, and mailbox bounds, together with terminal between a committed prefix and result delivery (`openspec/changes/sdk-active-event-pump/tasks.md:28`).
- `testActiveWireDrainCrossesTokenServiceByteDepthAndMailboxBounds` supplies six representative cases. Each case passes an already-integral `maximumAcceptedEventCount`; it varies one dominant limiter at a time and does not construct a fractional bucket state or cover the required smaller/equal/larger combinations across simultaneous bounds (`SDK/Tests/NearWireTests/NearWireBufferTests.swift:317-385`). Fractional/sub-one behavior is tested only inside the isolated `EventTokenBucket` unit suite, not through captured allowance, queue offer, reserved mailbox admission, and result commit together (`Core/Tests/NearWireFlowControlTests/EventRateControlTests.swift:33-58,111-141`).
- The new `beforeOutboundTurnCompletion` barrier is used for completion-before-blocked-result and deferred-policy completion (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:830-889,1078-1150`). No test closes the session after the NearWire actor has gate-committed one or more accepted Events but before the matching core result is delivered, then proves queue/mailbox/telemetry remain committed while the stale core token installs neither bucket nor sequence state. That exact ordering remains explicitly named by Task 5.3.
- Task 4.4 also names fresh dynamic-policy commit-clock failure and complete transaction backpressure/overflow (`openspec/changes/sdk-active-event-pump/tasks.md:22`). Publication FIFO order/overflow is now covered, but no active-core test reverses the bound clock at the dynamic-policy commit boundary and asserts no acceptance bytes or partial bucket installation; the only clock-reversal evidence remains unit-level bucket/queue validation.
- The required no-poll assertion is still probabilistic: `testTransportBlockWithWholeTokensDoesNotPollUntilCapacityProgress` treats 100 `Task.yield()` iterations as proof that no successor turn exists (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:773-828`). The shared polling helpers also use wall-time deadlines and repeated yields (`SDK/Tests/NearWireTests/NearWireTestSupport.swift:237-244`; `SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:4313-4320`). This does not establish the task plan's barrier-controlled “without sleeps” negative property.
- Tasks 4.4 and 5.3 remain checked complete and the requirement-to-evidence map describes the representative cases as full bounded/race coverage (`openspec/changes/sdk-active-event-pump/tasks.md:22,28`; `openspec/changes/sdk-active-event-pump/evidence/requirement-to-evidence.md:12-14,19`). The focused suites pass—65 session tests and 71 queue/rate/buffer tests—but none executes the missing combined orderings above.

**Impact**

The production implementation appears consistent under static tracing, but the most failure-sensitive uplink boundary is not protected by the test contract that is currently marked complete. A regression in fractional allowance capture, simultaneous limiter precedence, stale-result bucket/sequence rejection, or dynamic-policy clock atomicity could pass every recorded test. Yield-count quiescence can also pass or fail with executor scheduling rather than the intended no-successor invariant.

**Required remediation**

Reopen Tasks 4.4 and 5.3 until direct evidence exists. Add a table-driven permanent-core matrix that creates exact fractional/zero/one/burst bucket states and crosses them with smaller/equal/larger service, accounted-byte, queue-depth, and reserved-mailbox limits. Add a committed-prefix/result-delivery barrier test for both terminal orderings, asserting exact queue IDs, mailbox bytes, telemetry, sequence, bucket tokens, task tokens, and cleanup. Add a dynamic-policy fresh-clock reversal test around acceptance admission. Replace yield-count no-poll assertions with a controlled successor-entry barrier or scheduler counter whose unchanged state is observed only after an explicit competing actor turn.

## Review Status

**Unresolved finding count: 1 — 1 High.** Correctness/testing closure is not granted. No additional production defect was found in the Round 3 target paths, but the checked matrix tasks still require the executable evidence above.

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --filter SDKSessionAdmissionTests`: PASS — 65 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --skip-build --filter 'NearWireBufferTests|EventRateControlTests|BoundedEventQueueTests'`: PASS — 71 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
- `git diff --check -- openspec/changes/sdk-active-event-pump/reviews/implementation-round3-correctness-testing.md`: PASS with no output.
- Trailing-whitespace scan of this report: PASS with no matches.
