# Post-Implementation Correctness and Testing Review — Round 3

## Scope

Reviewed the current final-remediation worktree against the complete `sdk-public-connect` proposal, design, capability deltas, tasks, evidence, and the Round 2 correctness report. The review specifically rechecked the async orchestration matrix, facade-level lease-runtime failures, retain-graph scope, exact and one-over downstream limits, terminal wait failure, and fresh aggregate packaging evidence. No production, test, specification, task, or evidence file was modified.

## Round 2 Remediation Status

| Round 2 finding | Round 3 status |
| --- | --- |
| Deterministic orchestration, runtime-failure, and retain-graph matrix incomplete | Partially resolved. Facade claim-exit/release-enter/release-exit tests, real-lease wait-failure subprocess proof, pairing-transfer ownership checks, nested-handler order tests, async admission/activation result cancellation, and release-before-delivery were added. The remaining explicit orchestration rows are Finding 1. |
| Exact/one-over downstream traversal incomplete | Resolved. The maximum 263,107-byte record now traverses the production session encoder and frame decoder at the exact 263,148-byte frame boundary, with one-byte-smaller Event and frame limits rejected. Named existing boundary tests cover the secure mailbox, active turn, incoming retention, batch, and repeated-frame domains, and the planner test proves their public capacity relationships. |
| Aggregate packaging result stale after adding the public TLS gate | Resolved. The evidence records a fresh current-tree aggregate run, and this review independently reran the same current `verify-package.sh` successfully, including 405 iOS tests, 196 Core harness tests, and both mandatory non-skipped production TLS tests. |

The retain-graph portion is accepted as resolved. Releasing the final external facade reference while the permanent core, channel path, terminal coordinator Task, weak callback, and cancellation machinery are still capable of running proves that none has a strong path back to `NearWire`; the source audit identifies each edge. Separate public and admission one-shot ownership checks establish that pairing data is released before later suspension. Requiring artificial weak handles for every internal value would not add meaningful proof beyond this aggregate deinitialization test plus the edge inventory.

## Finding

### 1. MEDIUM — Task 3.7 is marked complete without its specified both-winner handoff and stale-callback rows

**Evidence**

- The design requires “both-winner barriers inside every target, phase, lifetime handoff, transfer, connected-commit, terminal-mark, wait-registration, shutdown, and stale callback boundary” (`openspec/changes/sdk-public-connect/design.md:182`). Task 3.7 similarly requires deterministic both-winner tests across delayed admission result, same-gate lease handoff, delayed waiter/callback delivery, stale callbacks, one wait/release, and retry (`openspec/changes/sdk-public-connect/tasks.md:23`), and is currently checked complete.
- The implementation exposes async hooks before and after admission result/target, activation result/target, terminal-wait registration, transfer, actor commit, terminal delivery, and release (`SDK/Sources/NearWire/Connection/SDKPublicConnectionOrchestration.swift:8-23`). The current tests exercise only `afterAdmissionResult`, `afterActivationResult`, and `beforeRelease` from this async hook set (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:533-617`).
- The admission-result and activation-result tests prove that Task cancellation after replacement cancels the returned owner and releases once. They do not run cancellation and terminal marking in both orders at a delayed admission result, nor force replacement and cancellation to take both lock-winning orders.
- No public test stops at `beforeTerminalWaitRegistration` or `afterTerminalWaitRegistration` to race shutdown/terminal with the same-gate coordinator lease handoff and assert one owner, one wait, and one release. The direct terminal tests cover only active-transfer and connected-commit lock winners (`SDKPublicConnectionOrchestrationTests.swift:107-188`).
- `testTerminalReleaseCompletesBeforeWeakStateDelivery` proves release precedes the current token's callback (`SDKPublicConnectionOrchestrationTests.swift:588-617`), but no test delays that callback, starts or represents a newer exact token, then proves the stale callback cannot clear or publish state for the successor. The evidence summary only claims the three rows actually added (`openspec/changes/sdk-public-connect/evidence/terminal-ownership-and-retain-graph-audit.md:18`).

**Impact**

No production race failure was reproduced, and the gate/coordinator implementation remains internally coherent under source review. However, the change's own test contract is stronger than the executable evidence. A regression at lease handoff, wait registration, or stale terminal delivery could pass the current suite while Task 3.7 and the requirement map remain marked complete.

**Recommended remediation**

Add deterministic table rows using the existing hooks for:

1. task-before-terminal and terminal-before-task while the admitted result is held;
2. cancellation/shutdown versus lease-handoff and wait-registration on both sides of the acknowledgement;
3. delayed terminal delivery after the actor slot no longer matches, proving no successor state mutation;
4. exact one-coordinator, one-wait, one-release counts for each winning order.

Use synchronous barriers for lock-winner rows and async barriers only for post-result scheduling rows. If the intended contract no longer requires every named boundary, narrow Task 3.7, the design test matrix, and the requirement-to-evidence claim before marking the task complete.

## Review Status

**Unresolved actionable finding count: 1 — 0 High, 1 Medium. Correctness/testing approval is not granted.**

All Round 2 production-behavior concerns and aggregate validation concerns are resolved. Approval is withheld solely because the checked task and evidence still overclaim the deterministic orchestration matrix.

## Validation Performed

- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round3-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round3-swiftpm swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter SDKPublicConnection`: PASS — 37 tests, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round3-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round3-swiftpm swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter WireEventTests.testMaximumRecordTraversesProductionSessionCodecAtExactBoundary`: PASS — 1 test, 0 failures.
- `env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-round3-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-round3-swiftpm swift test --disable-sandbox --quiet -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: PASS — 405 tests, 0 failures.
- Unrestricted `./Scripts/verify-package.sh`: PASS — process-lease multi-image gate; package/API boundaries; iOS 405 total, 401 passed, 4 platform skips; Core harness 196 passed; internal production TLS 1/1; public-connect production TLS 1/1; no mandatory TLS skip.
- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive`: PASS — `Change 'sdk-public-connect' is valid`.
- `git diff --check`: PASS.
