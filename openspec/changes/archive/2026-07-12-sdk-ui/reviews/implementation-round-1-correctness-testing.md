# Implementation Review — Round 1 Correctness and Testing

## Scope

Reviewed the active `sdk-ui` proposal, design, delta specifications, completed task claims, all current NearWireUI production source, all NearWireUITests, package dependency change, and relevant SDK status-stream behavior. Traced atomic phase registration, Connect/Cancel/Disconnect acknowledgement orders, simultaneous panels, disappearance/deinit/replacement, stale generations, error precedence, Unicode scalar limiting, and the total action matrix. This is report-only; no production or test source was modified.

## Findings

### 1. P1 / High — The required focused UI test gate fails on exact operation cleanup

**Confidence: 10/10**

The strict focused command compiled successfully but failed consistently in `NearWireUIOperationCoordinatorTests.testLiveTaskRetainsControllerOnlyUntilExactCompletionAndCleanup` (`SDK/Tests/NearWireUITests/NearWireUIOperationCoordinatorTests.swift:109-129`). After the fake Connect continuation is resumed, the test times out waiting for the coordinator to reach idle at line 120, then observes `entryCount == 1` instead of zero at line 128. Re-running only that test produces the same two failures.

This is the direct proof claimed by tasks 3.4 and 4.1 for exact completion, controller lifetime, entry cleanup, and `ObjectIdentifier` reuse safety. Whether the defect is in the coordinator's completion/lifetime behavior or in the weak-controller test harness, the current evidence is invalid and the required focused suite is red. The change cannot claim correctness completion while this deterministic gate fails.

**Required remediation:** root-cause the held completion rather than weakening the assertion. Add named barriers around fake continuation resumption and coordinator `finishConnect`, prove the exact task reaches its token-matched acknowledgement, then prove the Connect handle, controller, idle entry, and final subscriber are released in that order. Re-run both the isolated test and the full NearWireUI filter under complete concurrency checking and warnings as errors.

### 2. P2 / Medium — Shutdown does not have the required highest action precedence

**Confidence: 10/10**

The total matrix requires shutdown to expose no action before considering coordinator phase (`design.md:72`; `specs/sdk-ui/spec.md:88-90`). The implementation instead switches on `operationPhase` first and checks `status.state == .shutdown` only after the phase is idle (`SDK/Sources/NearWireUI/NearWireUIModel.swift:135-159`). A shutdown snapshot racing a held Connect, disappearance cancellation, or Disconnect therefore renders Cancel, Cancelling, or Disconnecting rather than no action. In the connecting case the user can invoke a new Disconnect path against an instance already declared final.

The existing shutdown assertion covers only coordinator idle (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:40-59`), so it cannot detect the defect.

**Required remediation:** make shutdown the first action guard after presentation/status availability, before coordinator phase. Add table cases for shutdown combined with every coordinator phase and suspension/error fields; assert no primary or reset action and no controller invocation.

### 3. P2 / Medium — Phase-stream termination does not remove its exact continuation

**Confidence: 9/10**

The specification requires termination itself to remove only the exact continuation and allows idle-entry removal only after the subscriber count reaches zero (`specs/sdk-ui/spec.md:49`). `subscribe` stores the continuation but installs no `onTermination` callback (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:107-127`). Continuations are removed only by explicit `unsubscribe` or opportunistically when a later phase yield reports `.terminated` (`NearWireUIOperationCoordinator.swift:129-138,267-279`). If a consumer cancels/drops its stream while the entry is idle and no later phase is published, the coordinator retains the terminated continuation and idle entry indefinitely.

The model normally calls explicit unsubscribe, but the implementation contract and completed task 4.1 claim exact termination removal, including no terminated-subscriber accumulation. Current tests always explicitly unsubscribe or stop the model; none cancels a raw subscription consumer and verifies removal without a later phase.

**Required remediation:** install an exact-token `onTermination` path that re-enters the main-actor coordinator without removing a replacement registration, and keep explicit unsubscribe idempotent. Add cancellation-before-first-next, cancellation-while-idle, cancellation-during-operation, and repeated subscribe/cancel tests; prove the count drops without requiring another phase yield and the idle entry prunes exactly once.

### 4. P2 / Medium — Completed correctness tasks materially overstate deterministic coverage

**Confidence: 10/10**

Tasks 3.1 through 3.4 and 4.1 are checked complete, but the current suite does not provide several named proofs:

- The synchronous `initialPhase` requirement is not asserted before the first suspension/executor yield. The recreation test calls `start()`, awaits asynchronous SDK status, and only then checks Cancelling (`NearWireUIModelTests.swift:87-120`).
- The total action matrix lacks shutdown crossed with non-idle coordinator phases, all ownership preflight codes, and explicit host-owned pre-discovery behavior. Only `connectionIntentExists` is exercised as an action failure (`NearWireUIModelTests.swift:172-197`).
- Status/action winner behavior is tested only by delivering healthy status after an action failure; the opposite readiness order and simultaneous barriers are absent (`NearWireUIModelTests.swift:136-170`).
- No test proves a Connect result is delivered only to its weak origin, is dropped after origin teardown, and is never broadcast to a second live panel. The two-panel test checks shared phase only (`NearWireUIModelTests.swift:199-229`).
- Stale action completion after stop/start and distinct-controller replacement is not exercised. The existing stale-status check covers only a stopped status observer (`NearWireUIModelTests.swift:250-271`).
- Scalar-boundary tests validate the limiter value, but the model/controller forwarding test uses only ASCII. The required exact forwarded decomposed/joined/multibyte scalar prefix and discarded suffix are not observed at the fake controller (`NearWireUIInputLimiterTests.swift:5-52`; `NearWireUIModelTests.swift:18-38`).
- Natural phase-stream termination removal is not tested, matching Finding 3.

These omissions matter because they leave the shutdown defect and termination leak undetected while the corresponding tasks are already marked complete.

**Required remediation:** add the missing barrier/table/lifetime tests and map each normative scenario to an exact assertion before retaining the completed checkboxes. In particular, make the first-phase test assert immediately after synchronous `start()` with a pre-held coordinator phase and before any `await`, and make multibyte cases assert the exact code recorded by the fake controller.

## Validation

- `HOME="$PWD/.build/home" XDG_CACHE_HOME="$PWD/.build/cache" CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" swift test --disable-sandbox --scratch-path "$PWD/.build/sdk-ui-review-tests" --filter NearWireUI -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: **FAIL** — 26 tests executed, 2 assertion failures in one coordinator cleanup test.
- Isolated rerun of `NearWireUIOperationCoordinatorTests/testLiveTaskRetainsControllerOnlyUntilExactCompletionAndCleanup` with the same strict flags: **FAIL**, same two assertions.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS.
- `git diff --check -- openspec/changes/sdk-ui SDK/Sources/NearWireUI SDK/Tests/NearWireUITests Package.swift`: PASS.

## Verdict

**Unresolved actionable finding count: 4 — 1 High, 3 Medium. Correctness/testing approval is not granted.**

The core coordinator shape, asymmetric acknowledgement logic, scalar-prefix implementation, action-error priority, and ordinary active-session disappearance behavior are directionally sound. The failing cleanup gate, shutdown precedence defect, missing termination cleanup, and incomplete claimed evidence must be resolved before a zero-finding implementation review.
