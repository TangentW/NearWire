# Implementation Review — Round 5 Correctness and Testing

Date: 2026-07-12

## Scope

Independently reviewed the active `sdk-ui` implementation, focused tests, active specifications, prior Round 3/4 findings and remediation, and refreshed evidence after the Round 4 coalescing fix. The review traced revoked-origin reconciliation for every phase, normal success/failure ordering, cross-panel preemption in both acknowledgement orders, revision-based reverse delivery, mounted instance replacement, subscriber/controller retention, and current validation counts. Only this assigned report was added.

## Production Correctness

The Round 4 production defect is fixed. `receivePhase` now checks the model's exact active token against coordinator origin ownership and, whenever that exact origin has been revoked, clears the token, advances action authority, and clears pairing input and action error independent of the phase value (`SDK/Sources/NearWireUI/NearWireUIModel.swift:191-215`). A coalesced Idle value therefore takes the same cleanup path as Cancelling or Disconnecting.

Normal completion ordering remains correct. Natural Connect completion removes the exact operation, synchronously invokes the generation-current origin callback on `MainActor`, and only then releases the actor for the phase consumer. The callback clears the token before a later Idle delivery can enter revoked-origin cleanup; success clears input/error and failure preserves bounded input while installing the safe error (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:560-568`; `SDK/Sources/NearWireUI/NearWireUIModel.swift:218-235`). Existing success, generic failure, ownership failure, and both status/action winner-order tests remain consistent with that trace.

No regression was found in the previous fixes: two-panel cancellation admits exactly one later Connect in both acknowledgement orders, revision delivery converges after forced reverse publication, the reentrant fake observer graph releases, and mounted replacement transfers A's status subscription to B while stale controllable-model events remain inert.

## Finding

### P2 / Medium — The coalesced-Idle remediation is not exercised through model state or a coalesced stream, and final evidence counts are stale

**Confidence: 10/10**

The new `testCoalescedIdleClearsRevokedOriginState` calls only the pure `shouldClearRevokedOriginState` Boolean helper (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:363-388`). It does not construct a model with an active exact token, revoke that token through a second panel, coalesce Disconnecting to Idle in the `bufferingNewest(1)` stream, or assert the resulting token/input/error state and subsequent Connect behavior.

The existing cross-panel integration test still waits until both models consume Disconnecting before either operation completes (`NearWireUIModelTests.swift:531-547`). Consequently the suite has no behavioral execution of the legal schedule that caused the Round 4 finding. The pure helper test proves only the predicate used by the implementation; it would continue passing if `receivePhase` stopped clearing `pairingCode`, `actionError`, or `activeOperationToken` after the helper returns true. This does not satisfy the Round 4 required remediation or the repository rule to match evidence to every normative scenario.

The evidence also still records 42 focused tests, 1,050 executions across 25 runs, and 469 full tests (`openspec/changes/sdk-ui/evidence/focused-implementation-validation.md`; `openspec/changes/sdk-ui/evidence/spec-to-evidence-audit.md`; `openspec/changes/sdk-ui/evidence/implementation-round-3-remediation.md`). The current focused suite executes **43** tests after adding the policy test. Therefore those claimed final results predate the current test tree; a corresponding full suite would contain at least 470 tests, not 469.

**Required remediation:** add a deterministic model/coordinator test that blocks the origin panel's phase consumer or uses an immediate controller so Disconnecting is replaced by Idle before consumption. Assert that the exact revoked token, pairing input, and action error clear, that retained-origin normal failure still preserves input/error, and that exactly one later Connect starts only after new input. Then rerun and refresh the focused stress, full macOS/iOS, package/podspec, and audit counts against the final test tree.

## Independent Validation

- Strict focused NearWireUI suite with complete concurrency checking and warnings as errors: **PASS**, 43 tests, zero failures.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: **PASS**.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.

## Verdict

**Unresolved actionable finding count: 1 Medium. Correctness/testing approval is not granted.**

The production coalescing fix and all earlier production remediations are sound. Completion remains blocked by missing behavioral coverage for the exact coalesced schedule and by final evidence that has not been regenerated after the test addition.
