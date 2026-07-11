# Post-Implementation Correctness and Testing Review — Round 4

## Scope

Reviewed the complete current `sdk-active-event-pump` diff from scratch against the proposal, design, capability specifications, task plan, production source, tests, documentation, evidence, and prior implementation reviews. The review retraced actor reentrancy, terminal linearization, policy ordering, bucket and sequence commit boundaries, queue and mailbox limits, callback and task bounds, TTL behavior, retained accounting, and the requirement-to-evidence map. No production, test, specification, task, documentation, or evidence source was modified by this review.

## Prior-Finding Verification

The Round 3 correctness/testing finding is resolved.

- `testPermanentCoreCapturesZeroFractionalOneAndBurstTokenAllowances` exercises the permanent core with exact zero, fractional-refill, one-whole-token, and four-token burst states. It verifies accepted count, retained queue count, committed sequence, transport telemetry, and the exact remaining fractional bucket value after each completed turn.
- The active-drain seam accepts only the core-captured whole-token `Int`, so fractional bucket state cannot leak into the queue actor. The tests now cover that typed boundary compositionally: zero allowance is directly immutable, a one-token allowance is directly limiting, representative cases cover each dominant limiter, and `testActiveWireDrainBurstAllowanceCartesianLimiterMatrix` executes all 81 combinations of smaller/equal/larger service, accounted-byte, queue-depth, and mailbox bounds against the four-token burst allowance. Every case checks the exact accepted prefix, service work, accounted bytes, planned sequence, and retained queue depth. This is equivalent coverage of the functional limiter cross-product without duplicating fractional bucket mechanics inside the actor seam.
- `testTerminalAfterCommittedUplinkPrefixRejectsStaleDrainResult` holds result delivery only after mailbox admission, queue removal, and telemetry commit. Terminal cleanup then clears route-local bucket, sequence, block, and task state; releasing the stale result changes neither the terminal snapshot, transport count, retained queue, nor committed telemetry.
- `testDynamicPolicyClockReversalFailsBeforeAcceptanceOrBucketInstall` reverses the bound owner clock at the dynamic-policy commit boundary and proves `clockFailed`, no acceptance frame, no surviving effective policy or bucket, and exact channel cancellation.
- `testTransportBlockWithWholeTokensDoesNotPollUntilCapacityProgress` no longer relies on a yield-count delay. It observes the permanent core's outbound-turn counter and operation-entry counter across explicit competing owner/core actor turns, proves both remain unchanged while capacity is insufficient, and then proves each controlled send completion is the event that permits the next turn.

The newly added initial-policy/owner-signal priority, per-expiration gate-claim, publication-first stale-result, combined FIFO/in-flight accounting, and complete-frame quantum tests also match the current production branches they claim to cover. Static tracing found no new actionable correctness defect in the current diff.

## Findings

None.

## Review Status

**Unresolved finding count: 0. Correctness/testing closure is granted for Round 4.**

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --filter SDKSessionAdmissionTests`: PASS — 70 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test --filter 'NearWireBufferTests|EventRateControlTests|BoundedEventQueueTests'`: PASS — 73 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-swiftpm-module-cache swift test`: PASS — 359 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-active-event-pump --strict --no-interactive`: PASS — `Change 'sdk-active-event-pump' is valid`.
