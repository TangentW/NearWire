# Implementation Architecture and API Review — Round 4

## Scope

Independently re-reviewed the complete active `sdk-ui` change after Round 3 remediation: proposal, design, delta specifications, tasks, production sources, focused tests and fixtures, SwiftPM/CocoaPods mappings, validation scripts, documentation, prior reports, remediation record, and current evidence. The review specifically traced portable API normalization, source-authored API rejection, phase-revision convergence, exact origin-token reconciliation, simultaneous-panel preemption, and mounted injected-instance replacement. This review changed no production, test, specification, task, or documentation source.

## Round 3 Remediation Verified

- The API gate now validates the source-authored two-view semantic contract while normalizing compiler-synthesized declaration attributes and marker conformances. It still rejects an extra public type/member, an attributed public member, a source-authored attribute on an approved view, and an extra source conformance. SwiftPM and CocoaPods declaration trees remain compared under the same toolchain.
- Every coordinator phase transition advances an entry revision. External delivery re-reads the current phase and subscriber set, yields outside the lock, and repeats when a newer revision raced the yield. The forced reverse-delivery test establishes final convergence to the current fail-closed phase.
- Exact origin ownership is now queried under the coordinator storage lock. Cross-panel preemption can revoke only the matching origin token, and the initiating model can accept a later Connect after both predecessor operations acknowledge.
- The public wrapper replacement is now exercised through a real platform hosting controller. Replacing A with B at one stable root removes A's SDK status subscription and establishes B's subscription. The distinct-controller model test separately proves stale A status/completion is inert and later actions target B.
- Reentrant cancellation no longer leaves a test-only controller/coordinator cycle, and the completion evidence consistently records the successful simulator result.

## Finding

### P2 — Medium: A coalesced shared cancellation can reconcile the origin token without clearing its pairing input

**Confidence: 10/10**

`NearWireUIConnectionModel.receivePhase` correctly detects when its exact active token no longer retains the coordinator's origin completion and clears that token (`SDK/Sources/NearWireUI/NearWireUIModel.swift:191-198`). However, it clears the pairing input and action error only if the particular delivered phase is `.cancelling` or `.disconnecting` (`NearWireUIModel.swift:199-202`).

The phase stream is intentionally `AsyncStream.bufferingNewest(1)` (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:417-438`). If another panel cancels and both the cancelled Connect and shared Disconnect complete before the initiating model consumes the transient Disconnecting value, the stream may legally coalesce directly to the final Idle value. On that Idle delivery, `retainsOrigin` is false, so the stale token is reconciled and Connect becomes usable again, but the previous pairing code remains populated because the phase-specific clearing branch is skipped. The panel can therefore present an enabled Connect action with the cancelled code still retained.

This contradicts the normative rule that a Cancel/Disconnect request clears model input (`openspec/changes/sdk-ui/specs/sdk-ui/spec.md:31-33`) and the Round 3 design statement that revoking the exact coordinator origin causes the initiating model to clear that exact stale token **and bounded input** (`openspec/changes/sdk-ui/design.md:62-64`). The current cross-panel test waits until both models have consumed Disconnecting before completing either operation (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:504-519`), so it cannot exercise latest-value coalescing across the clearing boundary.

**Required remediation:** make exact origin revocation itself the input/error clearing boundary, independent of which later phase survives coalescing. Clearing must remain token-exact so an old revocation cannot erase a successor operation's input. Add a deterministic test that starts Connect in panel A, preempts from panel B, prevents A from consuming the transient cancellation phase until both exact operations reach Idle, and proves A receives only/coalesces to Idle yet clears its old code and can start exactly one new Connect only after new input is supplied.

## Validation Performed

- Strict NearWireUI suite with complete concurrency checking and warnings as errors: passed, 42 tests, 0 failures.
- Mounted public-view replacement test: passed as part of the focused suite.
- Reverse phase-delivery convergence and both cross-panel completion-order tests: passed as part of the focused suite.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: passed.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.

The passing suite is consistent with the current implementation, but its cross-panel test deliberately observes the transient Disconnecting phase and therefore does not cover the finding's permitted `bufferingNewest(1)` coalescing order.

## Verdict

**Changes required. Unresolved actionable findings: 1 medium.** Portable API validation, coordinator phase convergence, exact identity ownership, and mounted replacement are approved. Final architecture approval remains withheld until token-origin reconciliation clears cancelled input even when the transient cancellation phase is coalesced away.
