# Implementation Architecture and API Review — Round 5

## Scope

Independently reviewed the complete current `sdk-ui` implementation, focused tests, public-boundary scripts, package mappings, design/specifications, prior findings, remediation record, and completion evidence after the Round 4 coalescing fix. The review re-traced exact origin ownership, normal success/failure ordering, latest-value phase convergence, shared-panel action bounds, injected-instance replacement, and portable SwiftPM/CocoaPods API normalization. This review changed no production, test, specification, task, documentation, or evidence file other than this assigned report.

## Architecture and API Verification

- Revoked-origin cleanup is now phase-independent. A generation-current model with an exact active token queries locked coordinator ownership and clears that token, pairing input, and action error whenever ownership is gone, including when the only observed value is coalesced Idle (`SDK/Sources/NearWireUI/NearWireUIModel.swift:191-216`).
- Normal Connect success and failure semantics remain intact. Exact completion is invoked synchronously on the coordinator's main-actor turn after storage delivery is enqueued; it clears the model token before the phase-consumer Task can process Idle. Success clears input, failure retains bounded input and installs the safe action error, and later phase handling sees no active token to reinterpret (`NearWireUIModel.swift:218-235`; `NearWireUIOperationCoordinator.swift:560-568`). Existing success, safe-failure, action-error-winner, and origin-only error tests cover these outcomes.
- The cleanup predicate is token-exact because the model first binds its current `activeOperationToken` and `retainsOrigin` compares that same object against the exact controller entry. A stale predecessor cannot clear successor input.
- Revision-based delivery still converges after reversed unlocked publication; operation admission remains main-actor serialized and bounded to one Connect plus at most one preempting Disconnect.
- Mounted A-to-B wrapper replacement transfers the real SDK status subscription, while distinct-controller tests keep stale A yields/completion inert and route later actions only to B.
- The public source surface remains exactly the two approved SwiftUI views. The API gate normalizes compiler-synthesized markers, rejects source-authored attributes/conformances and extra declarations, and compares SwiftPM/CocoaPods semantic trees under the same toolchain.

No new production architecture, lifecycle, identity, retention, or public API defect was found.

## Finding

### P2 — Medium: The current focused completion gate is flaky and the recorded results predate the latest test inventory

**Confidence: 10/10**

The required strict focused command failed in this review: 43 tests executed with one failure. `testStartAppliesImmediateStatusAndConnectForwardsExactBoundedCode` waits only until the fake controller has entered Connect and then immediately expects the model to render Cancel (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:18-35`). Controller invocation and the model's independent coordinator-phase consumer are separate scheduled operations, so `pendingConnectCount == 1` does not prove that the model has consumed `.connecting`. In the failing run the controller condition became true first and `actionPresentation` was still `.connect(showsReset: false)` at line 31. Ten isolated reruns passed, confirming a scheduling-sensitive test rather than a deterministic production regression.

The completion evidence also still records 42 focused tests, 1,050 executions across 25 runs, and 469 full macOS/iOS tests (`openspec/changes/sdk-ui/evidence/focused-implementation-validation.md:25-43,62-66`; `spec-to-evidence-audit.md:28-30`). The newly added coalesced-Idle policy test makes the current focused inventory 43 before any other suite totals are refreshed. Thus the claimed final validation cannot describe the current test tree, and the Round 4 remediation has not yet completed the required fresh stable gate.

**Required remediation:** make the existing forwarding test wait for both the exact controller invocation and `model.operationPhase == .connecting` before asserting Cancel. Then rerun the focused suite repeatedly, the affected full macOS/iOS/package gates, and refresh every exact count and stress total in completion evidence. A fresh independent review round is required after those results exist.

## Validation Performed

- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: passed.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.
- `git diff --check`: passed.
- Strict NearWireUI suite with complete concurrency checking and warnings as errors: **failed**, 43 executed, 1 failure in `testStartAppliesImmediateStatusAndConnectForwardsExactBoundedCode`.
- Ten isolated reruns of that exact test: passed 10/10, establishing intermittent scheduling sensitivity.

## Verdict

**Changes required. Unresolved actionable findings: 1 medium.** The Round 4 production fix and all prior architecture/API remediations are approved, but zero-finding completion cannot be granted while the current required focused gate is flaky and the evidence describes the previous 42-test inventory.
