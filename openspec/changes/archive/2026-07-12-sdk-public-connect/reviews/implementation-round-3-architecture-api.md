# Post-Implementation Architecture and API Review — Round 3

## Scope Reviewed

I reviewed the current final-remediation `sdk-public-connect` worktree against the proposal, design, capability specifications, task plan, evidence set, `NearWire-Platform-Architecture.md`, package/API boundaries, and the Round 1 and Round 2 architecture/API findings. This was a report-only review; no production, test, specification, evidence, or documentation source was modified.

The repository and public API boundaries remain correct. Shared wire computation is in `Core`; iOS identity, lease, discovery/admission, orchestration, and active ownership remain in `SDK`; supported signatures expose no implementation, Network, Security, lease, or protocol type; and SwiftPM/CocoaPods retain SDK-only Apple `Security.framework` linkage without a third-party SDK runtime dependency.

## Prior-Finding Disposition

- The Round 1 identity-start race remains resolved by the post-lease authorization check and identity-stage target.
- The Round 1 production lease double-release remains resolved by the handle's shared one-shot release gate and production-shaped runtime test.
- The Round 2 admission-owner duplicate cancellation is behaviorally resolved. The gate now remembers prior target delivery, and both deterministic handler-order tests count exactly one admission cancellation entry and one discovery cancellation (`SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift:4149-4200`).

## Finding

### 1. P2 / Medium — Cancellation delivery status is read outside its synchronization lock

**Evidence**

- `deliveredCancellationToTarget` is mutable shared state protected by `SDKSessionTransitionGate.lock`; it is written while holding that lock in cancellation, cancelled installation, and cancelled replacement paths (`SDK/Sources/NearWire/Connection/SDKSessionTransitionGate.swift:79-90,120-136,144-160,185-205`).
- `requestCancellationResult` unlocks at line 136 and then reads `deliveredCancellationToTarget` while constructing the return value at lines 138-141. A concurrent `installTarget` or `replaceTarget` can write the same property between those operations.
- The class is `@unchecked Sendable`, so Swift's compiler cannot enforce the missing synchronization. The focused tests serialize the result assertion and therefore do not exercise the concurrent read/write (`SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift:44-70`).
- The ownership evidence says the cancellation-result API reports delivery “in the same locked operation” (`openspec/changes/sdk-public-connect/evidence/terminal-ownership-and-retain-graph-audit.md:14-18`), and the normative requirement makes the shared gate the single synchronous cancellation authority (`openspec/changes/sdk-public-connect/specs/sdk-public-connect/spec.md:86-95`). The implementation does not currently satisfy that lock-discipline claim.

**Requirement impact**

This is an unsynchronized read/write race in the shared chronology object. Besides violating the `@unchecked Sendable` safety obligation, it makes `CancellationResult.deliveredToTarget` non-linearizable relative to concurrent target installation, even though the result controls whether admission schedules a fallback owner cancellation.

**Recommended fix**

Capture the intended delivery result in a local value while `lock` is still held and return that immutable local after invoking the target outside the lock. Define whether the result means delivery at this request's linearization point or delivery previously recorded for the cancellation epoch; preserve that meaning entirely under the lock. Add a deterministic barrier test that races a no-current-target request with cancelled target installation/replacement and verifies the chosen result semantics and one owner cancellation without a data race.

## Validation

- `swift test --disable-sandbox -Xswiftc -warnings-as-errors --filter SDKPublicConnection` passed: 37 tests, 0 failures.
- `git diff --check` passed.
- `DO_NOT_TRACK=1 openspec validate sdk-public-connect --strict --no-interactive` passed.

## Review Result

**Unresolved actionable findings: 1** — one Medium. A fresh architecture/API review is required after remediation.
