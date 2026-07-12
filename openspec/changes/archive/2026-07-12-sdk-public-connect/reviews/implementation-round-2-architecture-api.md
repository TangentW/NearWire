# Post-Implementation Architecture and API Review — Round 2

## Scope Reviewed

I reviewed the current stable `sdk-public-connect` worktree against the proposal, design, capability specifications, task plan, evidence set, `NearWire-Platform-Architecture.md`, package/API boundaries, and all three Round 1 architecture/API findings. This was a report-only review; no production, test, specification, evidence, or documentation source was modified.

The public surface and repository placement remain appropriate: only the instance-actor `connect(code:)` and fixed public error cases are added; platform-neutral wire sizing remains in `Core`; Keychain, process lease, admission orchestration, and active ownership remain in `SDK`; no implementation type crosses the supported API; and SwiftPM/CocoaPods preserve the required SDK-only `Security.framework` linkage.

## Round 1 Disposition

1. **Cancellation after lease claim starting identity — resolved.** `NearWire` now rechecks exact actor token, shared-gate authorization, and `Task.isCancelled` immediately after the lease-claim barrier and before installing/starting the identity stage (`SDK/Sources/NearWire/NearWire.swift:179-234`). `testCancellationAfterLeaseClaimSkipsIdentityAndReleasesExactlyOnce` proves the cancellation winner performs zero identity calls and one release (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:232-254`).
2. **Production lease handle releasing twice — resolved.** `ProcessConnectionLeaseHandle` now owns a lock-protected one-shot release state shared by explicit release and deinitialization (`SDK/Sources/NearWire/Session/ProcessConnectionLease.swift:96-127`). The production-shaped wrapper test observes one claim and one release synchronization sequence total (`SDK/Tests/NearWireTests/ProcessConnectionLeaseTests.swift:484-502`).
3. **Duplicate cancellation delivery — partially resolved.** `SDKSessionTransitionTarget` now makes each installed target closure one-shot, and gate requests remove the current target before delivery (`SDK/Sources/NearWire/Connection/SDKSessionTransitionGate.swift:15-39,119-140`). One owner-level duplicate path remains below.

## Finding

### 1. P2 / Medium — Nested cancellation handlers can still call the admission owner twice

**Evidence**

- The public `connect` cancellation handler calls `transitionGate.requestCancellation(.task)` (`SDK/Sources/NearWire/NearWire.swift:137-143`). While admission is current, its installed target schedules `admission.cancel()` (`NearWire.swift:324-330`).
- `SDKSessionAdmission.run()` has a nested cancellation handler that calls `requestCancellationResult(.task)` and, whenever that particular call reports no target delivery, separately schedules `self.cancel()` (`SDK/Sources/NearWire/Session/SDKSessionAdmission.swift:77-84`).
- The first gate request atomically removes the target and reports `deliveredToTarget == true`; a later repeated request necessarily reports `deliveredToTarget == false` (`SDK/Sources/NearWire/Connection/SDKSessionTransitionGate.swift:119-140`). Therefore, if the outer public handler wins first, it schedules `admission.cancel()` through the target, and the nested admission handler then sees no current target and schedules `admission.cancel()` again.
- The direct gate test explicitly confirms that the second request reports `deliveredToTarget == false` (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:43-69`), but no test counts admission-owner cancellation calls in both handler orders. The secure-driver count remains one only because `SDKSessionAdmission.cancel()` and the cancellation relay are independently idempotent (`SDKPublicConnectionOrchestrationTests.swift:344-359`).
- The normative contract requires target-before-cancellation to receive one request and every ordering to use one cancellation request per owner (`openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:86-95,106-114`). The ownership evidence currently overstates that nested handlers cannot notify the same owner twice (`openspec/changes/sdk-public-connect/evidence/terminal-ownership-and-retain-graph-audit.md:14-18`).

**Requirement impact**

Target closures are now one-shot, but the admission actor is still not governed by one exact cancellation authority. Correctness currently depends on downstream idempotence and on cancellation-handler ordering. This leaves the Round 1 ownership finding incompletely remediated and makes the evidence claim stronger than the implementation.

**Recommended fix**

Make the cancellation result distinguish “this call delivered a target” from “this cancellation reason already delivered the stage owner,” or give public admission an explicit mode in which the shared gate is its sole outer cancellation authority. The nested handler should call `self.cancel()` only when no public target was ever responsible for that admission run, not merely when the current repeated request finds the target already consumed. Add deterministic tests for both handler orders that count the admission owner's cancellation entry, not only the final secure-driver cancellation, and require exactly one.

## Validation

- `swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter SDKPublicConnection` passed: 29 tests, 0 failures.
- `git diff --check` passed.
- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive` passed.

## Review Result

**Unresolved actionable findings: 1** — one Medium. A fresh architecture/API review is required after remediation.
