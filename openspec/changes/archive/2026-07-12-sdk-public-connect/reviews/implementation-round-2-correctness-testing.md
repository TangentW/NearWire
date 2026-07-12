# Post-Implementation Correctness and Testing Review — Round 2

## Scope

Reviewed the stable current worktree, the complete `sdk-public-connect` proposal, design, capability deltas, task plan, evidence, and the Round 1 correctness report. The review retraced public-connect ordering, transition-target replacement, Task/shutdown/terminal chronology, process-lease ownership, terminal wait failure, exact release, active-owner retention, production TLS integration, deterministic size derivation, and the validation gates. No production, test, specification, or task file was modified.

## Round 1 Remediation Status

| Round 1 finding | Round 2 status |
| --- | --- |
| Failed terminal wait could release without terminal evidence | Resolved. `SDKPublicTerminalCoordinator` now moves the lease into the permanent fail-closed vault on wait failure, and `testTerminalWaitFailureVaultsLeaseWithoutReleaseOrDelivery` proves zero release and zero delivery. |
| Supported-connect production TLS integration was absent | Resolved. `testPublicConnectUsesProductionTLSBidirectionalEventsAndRealProcessLease` enters through `NearWire.connect`, uses the production TLS channel and real process lease, transfers Events in both directions, proves contention, observes terminal cleanup, and reacquires after terminal. |
| Cancellation targets were discontinuous and could receive duplicate notification | Implementation resolved. Targets now own one-shot cancellation cells and public orchestration atomically replaces identity, admission, admitted-session, attachment, and active-handle targets. The remaining deterministic race-proof gap is Finding 1. |
| Lease-claim cancellation could return the lease error or start identity | Resolved. The gate is checked before claim, a racing claim error defers to the gate failure, and a post-claim check releases before identity. Both claim-failure and successful-claim cancellation tests pass. |
| Exact/generated/downstream limit evidence was incomplete | Partially resolved. Exact-record equality, seeded valid JSON trees, planner relationships, and a peak-retention audit now exist. Exact/one-over traversal of the planned downstream boundaries remains incomplete in Finding 2. |
| Orchestration/transcript matrix was materially incomplete | Partially resolved. Wait-failure, target one-shot behavior, lease-claim precedence, terminal-transfer/commit winners, TLS, and final-owner release were added. The named public-orchestration and lease-runtime matrix remains incomplete in Finding 1. |

## Findings

### 1. MEDIUM — The required deterministic orchestration, runtime-failure, and retain-graph matrix is still incomplete

**Evidence**

- The change declares named hooks for admission target/result, activation target/result, terminal-wait registration, transfer, actor commit, terminal delivery, and release (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:8-23`). In the test tree, only the post-lease synchronous hook is exercised through `SDKPublicConnectionHooks`; none of the async public hooks above is used. The four direct gate tests cover only the two winners for terminal versus active transfer and terminal versus connected commit (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:98-179`).
- Target replacement is tested serially, not with cancellation winning and replacement winning at the admission-result, attachment-result, and active-handle-result boundaries (`SDKPublicConnectionOrchestrationTests.swift:22-96`). There is no public test for delayed terminal delivery after a newer token, delayed release/callback ordering, or retry after a synchronized release, although Task 3.7 explicitly requires those rows (`openspec/changes/sdk-public-connect/tasks.md:23`).
- Low-level lease tests cover claim-exit, release-enter, release-exit, repeated release, and stale release, and the public wrapper has one exact-release test (`SDK/Tests/NearWireTests/ProcessConnectionLeaseTests.swift:407-503`). They do not drive those injected runtime failures through `NearWire.connect` and assert the public state/error/retry result required by Task 3.9 (`openspec/changes/sdk-public-connect/tasks.md:25`).
- The final-owner test proves weak `NearWire` disappearance, one driver cancellation, and one release (`SDKPublicConnectionOrchestrationTests.swift:447-463`). It does not provide weak/reference snapshots for the coordinator, terminal Task, core, live operations, channel, callback, or pairing owner required by Task 3.8 (`openspec/changes/sdk-public-connect/tasks.md:24`). The retain-graph evidence is therefore primarily a source audit rather than the requested executable proof (`openspec/changes/sdk-public-connect/evidence/terminal-ownership-and-retain-graph-audit.md:20-27`).
- The requirement map currently says every capability scenario is represented (`openspec/changes/sdk-public-connect/evidence/requirement-to-evidence.md:20`), which is stronger than the executable matrix supports.

**Impact**

No failing runtime behavior was reproduced, and the reviewed synchronization design is internally coherent. However, the most failure-sensitive replacement, handoff, callback, and runtime-fault orderings are not deterministically exercised. Regressions in those rows could pass the present suite, so Tasks 3.7-3.9 and the corresponding evidence claims are not yet proven.

**Recommended remediation**

Use the existing named hooks and synchronous barriers to add table-driven both-winner tests for each result-to-target replacement, lease handoff/wait registration, delayed release/terminal delivery, stale callback, and retry row. Route isolated claim-exit/release-enter/release-exit runtime fixtures through the public facade and assert exact public error, state, identity/channel counts, release behavior, and whether retry is supported. Add explicit weak/reference snapshots for the retain-graph owners named by Task 3.8, or narrow the task and evidence language if a particular owner cannot be observed without changing production design.

### 2. MEDIUM — The exact formula is better proven, but exact/one-over downstream traversal is still not demonstrated

**Evidence**

- `testMaximumEventRecordBoundCoversAdversarialProductionEncodings` proves equality for one maximum deterministic-content record, and the seeded test checks 256 small valid trees (`Core/Tests/NearWireTransportTests/WireEventTests.swift:8-66`). This is meaningful remediation of the structural formula gap.
- The exact maximum record is not encoded through `WireSessionCodec` and then admitted at the public planner's exact frame, secure single-send, pending-send-with-two-Control, active-turn, decoder, and incoming-retention limits. `testLimitPlanUsesExactReviewedDownstreamCapacities` recomputes and compares planner arithmetic (`SDK/Tests/NearWireTests/SDKPublicConnectionFoundationTests.swift:113-169`), while the existing real-boundary tests use smaller synthetic limits or ordinary Events (for example `SDKSessionAdmissionTests.swift:2242-2261` and `WireEventTests.swift:224-296`).
- The evidence states that existing suites exercise exact limits, one-over rejection, repeated frames, hostile batches, and overflow paths (`openspec/changes/sdk-public-connect/evidence/connection-limit-and-peak-retention-audit.md:20-26`), but it does not map those claims to named tests or show that a maximum public-plan Event and its one-over variants traverse each downstream boundary. Task 2.4 explicitly requires exact/one-over downstream tests and hostile maximum Event/batch/overflow coverage (`openspec/changes/sdk-public-connect/tasks.md:11`).

**Impact**

The formula and planner arithmetic appear correct, but a mismatch between the formula and a real downstream admission point could remain hidden. The current evidence proves the components more strongly than Round 1 did, but it does not yet prove the end-to-end boundary contract requested by the task and design.

**Recommended remediation**

Create one maximum-shape record fixture shared by the formula and downstream tests. Encode it through the production session codec, assert exact frame size, and drive exact and one-over values through frame decoding, secure mailbox reservation including two maximum Control frames, active outbound accounting, active incoming accounting, and batch/repeated-frame overflow. Update the audit with a named-test mapping for every boundary and explicitly distinguish arithmetic proof from executable boundary proof.

### 3. MEDIUM — Final packaging validation evidence predates the new mandatory public-connect TLS gate

**Evidence**

- `Scripts/verify-package.sh` now contains an additional non-skippable invocation of `testPublicConnectUsesProductionTLSBidirectionalEventsAndRealProcessLease` (`Scripts/verify-package.sh:591-608`).
- The recorded package result was captured before that sub-gate was added. The evidence explicitly says the script was extended afterward and that a final validation refresh still must rerun it (`openspec/changes/sdk-public-connect/evidence/validation-gates.md:18,34`).
- Tasks 4.4 and 4.5 require current packaging, production TLS, counts, and exact command evidence before completion (`openspec/changes/sdk-public-connect/tasks.md:33-34`).

**Impact**

The public TLS test itself passes independently in this review, so this is not a production TLS failure. It is a stale composite-gate result: the current packaging script, including its new mandatory sub-gate, has not yet been proven as one successful run.

**Recommended remediation**

Run the current unrestricted `./Scripts/verify-package.sh` after all Round 2 remediation, record the exact command/result and fresh test counts, then remove the prospective “must rerun” note from the evidence. Refresh the remaining final gates from the same stable revision before the spec-to-evidence audit.

## Review Status

**Unresolved actionable finding count: 3 — 0 High, 3 Medium. Correctness/testing approval is not granted.**

No confirmed production correctness defect was reproduced in Round 2. Approval is withheld because required deterministic race/runtime-failure coverage and exact downstream boundary evidence remain incomplete, and the final composite packaging gate is stale.

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round2-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round2-swiftpm swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter SDKPublicConnection`: PASS — 29 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round2-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round2-swiftpm swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SDKSessionAdmissionTests.testPublicConnectUsesProductionTLSBidirectionalEventsAndRealProcessLease`: PASS — 1 test, 0 failures; production Network.framework TLS and the real process lease were exercised.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round2-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round2-swiftpm swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: PASS — 394 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- `git diff --check`: PASS.
