# Implementation Correctness and Testing Review — Round 1

## Scope

Reviewed the production diff, lifecycle tests, public documentation, active OpenSpec requirements/tasks, and current evidence for connection races, cleanup settlement, Task cancellation, recovery budget/delay, suspend/resume, stale callbacks, and status coherence. No production or test source was modified.

## Actionable Findings

### 1. P1 / High — A cancelled held recovery delay can still start the stale campaign after suspend/resume

**Confidence: 9/10**

`scheduleRecovery` installs a Task whose normal return from the injected sleeper enters `runScheduledRecovery`; cancellation is effective only if the sleeper throws (`SDK/Sources/NearWire/NearWire.swift:1123-1136`). Suspension increments `lifecycleGeneration` but neither changes the retained intent generation nor invalidates the recovery token before awaiting the Task (`SDK/Sources/NearWire/NearWire.swift:1253-1272`). If resume arrives while that held Task remains present, it clears the suspension latch and records the Boolean request (`SDK/Sources/NearWire/NearWire.swift:1291-1304`). When a noncooperative sleeper then returns normally, the old Task still matches its token, and its guard compares only the unchanged intent generation rather than `lifecycleGeneration`; it can therefore claim a route with the old attempt number before suspension acknowledges completion (`SDK/Sources/NearWire/NearWire.swift:1139-1157`). The suspended call may then wait for that whole stale connection attempt and overwrite its resulting presentation.

This violates the cancellation-completion handshake, resume campaign reset, and no-successor-before-ack requirements (`specs/sdk-connection-lifecycle/spec.md:149-158`). The existing held-sleeper test covers disconnect only (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:983-1014`), while Task 5.1 is already marked complete.

**Required fix:** invalidate the scheduled token or make the captured generation compare against an actor-current command generation before awaiting cancellation. A cancelled delay must report only completion; the actor should start a fresh attempt-one campaign after the suspension cleanup owner observes that acknowledgement. Add a barrier test that suspends an enabled held delay, resumes before the sleeper returns normally, proves no claim occurs before acknowledgement, and proves the eventual delay/attempt restarts at one.

### 2. P1 / High — Resume during a suspended recovery attempt loses the retained intent

**Confidence: 9/10**

Once a delayed Task wakes, `runScheduledRecovery` clears `recoveryTask` and starts the recovery attempt (`SDK/Sources/NearWire/NearWire.swift:1139-1157`). Suspension then cancels the attempt gate and waits on its receipt, while resume can clear the latch and set `resumeAfterSuspendedCleanup` because the receipt is still current (`SDK/Sources/NearWire/NearWire.swift:1253-1270,1291-1304`). When the cancelled attempt returns `connectionCancelled`, the catch guard now passes because resume already cleared suspension and the intent generation was never changed; `handleRecoveryAttemptFailure` classifies that lifecycle cancellation as terminal and clears the retained intent (`SDK/Sources/NearWire/NearWire.swift:1158-1165,1179-1197`). The suspended caller later sees the Boolean request, but `scheduleRecovery` has no intent left and starts nothing (`SDK/Sources/NearWire/NearWire.swift:1284-1287`).

This contradicts the required resume-before-cleanup behavior and post-commit suspension intent retention (`specs/sdk-connection-lifecycle/spec.md:77-103`). There is no suspend/resume winner-order test during a recovery attempt; the only resume test waits for suspension to finish first (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:779-807`).

**Required fix:** distinguish lifecycle-command cancellation from a generation-current recovery failure. After suspended attempt cleanup, preserve active intent and let exactly one post-cleanup owner consume the Boolean request and start fresh attempt one. Add deterministic barriers at recovery identity/admission/activation cleanup, with resume arriving before receipt settlement, and assert intent retention, one claim after release, reset budget, and no cancellation error in status.

### 3. P1 / High — Active-route deferred resume is scheduled and then its status is overwritten to disconnected

**Confidence: 9/10**

For an active route, terminal delivery sees `resumeAfterSuspendedCleanup`, publishes disconnected, and immediately schedules recovery (`SDK/Sources/NearWire/NearWire.swift:1024-1033`). That delivery also settles the receipt, so the still-running `suspendConnection()` resumes afterward and unconditionally chooses disconnected whenever it originally captured a receipt, overwriting the reconnecting status that was just published while leaving the recovery Task alive (`SDK/Sources/NearWire/NearWire.swift:1261-1287`). Under a fast disabled-policy attempt it can similarly overwrite a connected successor. The public state/status can therefore say disconnected while recovery or an active route exists.

This violates the canonical requirement that recovery remain reconnecting through delay, discovery, admission, and activation (`specs/sdk-connection-lifecycle/spec.md:126-137`). No test resumes before the held active-route release; the sequential test at `SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:779-807` cannot exercise this reentrant actor ordering.

**Required fix:** give one actor path ownership of post-suspension cleanup finalization and successor scheduling. A stale suspended continuation must not publish after a successor campaign or route has been installed. Add a release barrier test that resumes before settlement and asserts, after `suspendConnection()` returns, exactly one fresh campaign, reconnecting/attempt-one status during its held delay, and connected status after commit.

### 4. P2 / Medium — A new explicit connection carries a previous terminal error into initial phases

**Confidence: 9/10**

Permanent recovery failure or budget exhaustion clears intent but deliberately leaves `lastError` in disconnected status (`SDK/Sources/NearWire/NearWire.swift:1082-1095,1190-1197`), so a new explicit `connect(code:)` is allowed. Its discovering and connecting transitions call `updateSessionState` (`SDK/Sources/NearWire/NearWire.swift:410-412,856-866`), which copies the prior `lastError` and retry fields into the new status (`SDK/Sources/NearWire/NearWire.swift:1936-1943`). The new initial attempt therefore exposes an unrelated old terminal failure, contrary to the canonical initial-phase row requiring nil error and retry number (`specs/sdk-connection-lifecycle/spec.md:126-132`).

No test starts a new explicit connection after permanent failure or enabled exhaustion; the evidence matrix's status row does not identify such a scenario (`evidence/requirement-to-evidence.md:11-12`).

**Required fix:** clear terminal error and retry progress when a new explicit attempt enters its initial presentation, without changing preflight-failure behavior. Add permanent-failure/exhaustion-to-new-connect tests that inspect both discovering and connecting snapshots and late subscribers.

## Validation

- `swift test --package-path . --filter SDKPublicConnectionOrchestrationTests`: PASS — 37 tests, 0 failures.
- `DO_NOT_TRACK=1 openspec validate sdk-connection-lifecycle --strict --no-interactive`: PASS.
- `git diff --check`: PASS.
- The first sandboxed SwiftPM attempt could not access compiler caches; the same command was rerun outside the sandbox and passed. This was an environment limitation, not a test failure.

## Verdict

**Unresolved actionable finding count: 4 — 3 High, 1 Medium. Implementation correctness/testing approval is not granted.**

Tasks 3.4 and 5.1 and the suspension/resumption evidence row should be reopened until the three resume-before-cleanup winner orders are fixed and covered. Task 5.1's current claim of all stale winner orders is not supported by the present test set.
