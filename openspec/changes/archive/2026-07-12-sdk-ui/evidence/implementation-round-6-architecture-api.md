# Implementation Architecture and API Review — Round 6

## Scope

Independently reviewed the final current `sdk-ui` proposal, design, delta specifications, tasks, production sources, focused tests/support, public consumers, SwiftPM/CocoaPods validation scripts, documentation, all prior findings and remediation records, and refreshed completion evidence. The review specifically re-traced revoked-origin cleanup under latest-value coalescing, normal Connect success/failure ordering, phase-revision convergence, exact controller/token identity, mounted injected-instance replacement, resource bounds, and the portable two-view public API gate. Only this assigned report was added.

## Final Verification

### Revoked-origin and normal completion semantics

- A generation-current model applies any observed phase, then checks its exact current operation token against locked coordinator origin ownership. If that exact origin is revoked, the model clears the token, advances action authority, and clears pairing input and action error independent of whether the surviving phase is Idle, Connecting, Cancelling, or Disconnecting (`SDK/Sources/NearWireUI/NearWireUIModel.swift:191-214`).
- The behavioral coalescing test starts a real model/controller Connect with retained input, applies the only surviving Idle observation with revoked ownership, proves model input clears, lets the predecessor finish, and proves the same model starts exactly one successor Connect with new input (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:370-397`). This covers the model behavior that the earlier predicate-only test did not.
- Normal success/failure remains distinct. Coordinator completion captures the exact origin, enqueues phase delivery, and synchronously invokes the origin completion on the same main-actor turn before the phase-consumer Task can run. The completion clears the active token first; later Idle processing therefore cannot reinterpret success or failure as revocation. Existing exact-success, safe-failure, action-error-winner, and origin-only error tests pass.
- A successor token cannot be cleared by predecessor state: production `receivePhase` queries ownership for the model's token at processing time, generations reject old subscriptions, and exact coordinator object identity rejects unrelated operations.

### Coordinator, identity, and API architecture

- Per-controller action admission remains main-actor serialized and bounded to one Connect plus at most one preempting code-free Disconnect. Exact tokens gate completion, origin completion is singular and weak-model, and no waiter/callback list or model-owned action Task exists.
- Per-entry phase revisions and the unlocked re-read/re-yield loop guarantee final latest-value convergence after reversed publication without invoking cancellation, continuation, or origin callbacks under `NSLock`.
- Natural termination, explicit unsubscribe, deinit release, and idle pruning remain exact-identity operations. No actionable `ObjectIdentifier` reuse, controller retention, subscriber accumulation, or reentrancy defect was found.
- The mounted public wrapper test transfers the real SDK status subscription from instance A to B at one stable root. Distinct-controller tests separately prove stale A status/completion is inert and successor actions target B.
- Production source exposes only `NearWireConnectionView` and `NearWireConnectionStatusView` with their exact supported initializers and `View` bodies. The semantic API gate compares SwiftPM and CocoaPods under one toolchain, normalizes compiler-synthesized attributes/marker conformances, and rejects source-authored extra attributes, conformances, extensions, members, types, or SPI.
- SwiftPM/CocoaPods optionality, minimum platforms, fixed-English/resource boundaries, and absence of hidden lifecycle, persistence, dependency, or SDK construction ownership remain consistent with the active specifications.

## Prior Finding Closure

- Round 1/2 token admission, deinit/termination, shutdown action, lock/external-call, accessibility, fixed-string, replacement, and exact public-delta findings remain resolved.
- Round 3 compiler-marker portability, cross-panel stale token, reverse phase delivery, mounted replacement, test retention, and evidence consistency findings remain resolved.
- Round 4 coalesced shared-cancellation cleanup is resolved by phase-independent exact-origin cleanup plus behavioral model coverage.
- Round 5 flaky waiting is resolved by awaiting both the controller invocation and model `.connecting` phase before asserting Cancel. Final evidence now records 43 focused tests, 1,075 passes across 25 focused runs, 470 macOS tests, and 470 iOS tests with 466 passes and four existing skips.

## Validation Performed

- Strict NearWireUI suite with complete concurrency checking and warnings as errors: passed, 43 tests, 0 failures.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: passed.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.
- `git diff --check`: passed.
- Reviewed refreshed full/package/CocoaPods evidence: 470 macOS tests with seven existing skips and zero failures; 470 iOS tests with 466 passes, four existing skips, and zero failures; package and podspec gates passed.

## Verdict

**Approved. Zero actionable findings.** The implementation, public API, lifecycle/identity architecture, behavioral coverage, and refreshed evidence satisfy the active `sdk-ui` change. Architecture/API completion approval is granted.
