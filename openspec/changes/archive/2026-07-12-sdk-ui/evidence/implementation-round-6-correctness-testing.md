# Implementation Review — Round 6 Correctness and Testing

Date: 2026-07-12

## Scope

Independently reviewed the current `sdk-ui` production source, focused tests and support code, active specifications/tasks, all prior implementation findings, Round 4/5 remediation, and refreshed completion evidence. The review specifically re-traced actual revoked-origin model mutations under coalesced Idle, successor Connect admission, natural success/failure ordering, cross-panel completion orders, reverse phase-delivery convergence, exact subscriber/operation cleanup, mounted A-to-B replacement, async test waits, and the final 43/470 validation record. Only this assigned report was added.

## Findings

**Zero actionable findings.**

## Verification Details

### Coalesced revoked-origin behavior

`receivePhase` now queries ownership for the model's exact active token and delegates the observed latest phase plus the locked ownership result to one model-state transition. A revoked exact origin clears the token, advances action authority, and clears pairing input and action error for every surviving phase value, including Idle (`SDK/Sources/NearWireUI/NearWireUIModel.swift:191-214`). The transition is token-exact because it requires the model's current `activeOperationToken`; a stale phase cannot erase successor state after that token has been cleared or replaced.

The behavioral test now creates a presented model, starts a real held fake-controller Connect, waits for both the controller invocation and Connecting presentation, applies the coalesced Idle boundary with revoked ownership, and asserts the old input is cleared. It then completes the predecessor, supplies new input, and proves exactly one successor Connect reaches the controller with the expected ordered codes (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:370-397`). The existing two-panel test independently proves real coordinator preemption revokes origin ownership and remains coherent in both Connect-first and Disconnect-first acknowledgement orders (`NearWireUIModelTests.swift:365-368,525-569`). Together these tests cover the real ownership cause and the model-side effect of a latest-value coalesced observation.

### Normal completion ordering

Natural completion remains distinct from revocation. The coordinator removes the exact Connect operation, publishes its phase, and invokes the captured generation-current origin completion synchronously on `MainActor` before the model's asynchronous stream consumer can run (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:560-568`). The origin callback clears the active token first; success clears input/error, while failure preserves bounded input and installs only the safe error (`SDK/Sources/NearWireUI/NearWireUIModel.swift:216-233`). Existing exact-forwarding/success, generic failure, ownership failure, origin-only failure, and both status/action winner-order tests cover these outcomes. No revoked-origin cleanup can overwrite a natural failure after the callback has cleared the token.

### Prior race and lifecycle findings

- Cross-panel Cancel no longer leaves a stale origin token and admits exactly one later Connect after both acknowledgements.
- Per-entry phase revisions and repeat-on-change delivery converge after the forced reverse Cancelling/Disconnecting publication while all continuation yields remain outside the lock.
- Connect A disappearance/recreation, both preemption orders, repeated Disconnect joining, natural subscriber termination, release during Connect, burst release, and controller weak-release tests preserve exact operation and retention bounds.
- The reentrant cancellation observer is cleared and weak probes prove its fake graph releases.
- Mounted platform hosting transfers the real NearWire status subscription from injected instance A to B; distinct-controller tests prove stale A events/completion are inert and subsequent actions target only B.
- Previously schedule-sensitive model assertions now wait for both the controller continuation and the corresponding consumed coordinator phase before checking presentation.

### Evidence consistency

The current focused inventory is 43 tests. Completion evidence consistently records 43 focused passes, 25 consecutive focused runs totaling 1,075 test executions, 100 reverse-delivery race passes, 470 macOS tests with seven existing skips, and 470 iOS tests with four existing skips. Package, CocoaPods, Core, TLS integration, public-boundary, formatting, and strict OpenSpec results are recorded against this final tree.

## Independent Validation

- Strict focused NearWireUI suite with complete concurrency checking and warnings as errors: **PASS**, 43 tests, zero failures.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: **PASS**.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.

## Verdict

**Correctness/testing approval granted. Unresolved actionable finding count: 0.**

The Round 4 coalescing defect, Round 5 behavioral-evidence gap, async test nondeterminism, and stale validation counts are resolved. All earlier correctness, race, replacement, and retention findings remain closed.
