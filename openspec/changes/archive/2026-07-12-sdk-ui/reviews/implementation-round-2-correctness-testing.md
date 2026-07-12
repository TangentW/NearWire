# Implementation Review — Round 2 Correctness and Testing

## Scope

Re-reviewed the current NearWireUI production source, tests, package/validation scripts, documentation, specifications, completed tasks, Round 1 reports, remediation report, and evidence. Independently traced shutdown precedence, repeated Connect, natural termination, atomic initial phase, locked storage re-entry, both preemption orders, deinit/burst release, action/error/input behavior, replacement identity, and platform-conditional `ImageRenderer` compilation. This is report-only; no production or test source was modified.

## Round 1 Remediation Status

- **Shutdown precedence is fixed in production.** `actionPresentation` now returns no action for shutdown before examining coordinator phase (`SDK/Sources/NearWireUI/NearWireUIModel.swift:125-150`).
- **Repeated Connect no longer overwrites the accepted origin token.** The model rejects another activation while its exact token is live, and coordinator admission remains serialized (`NearWireUIModel.swift:161-175`).
- **Natural phase termination has exact cleanup.** Each continuation now receives an exact-token `onTermination`; explicit unsubscribe remains idempotent (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:316-345`).
- **Atomic first-phase handoff is implemented and directly asserted before the first await after `start()`.** Later phase changes retain a one-value buffer (`NearWireUIModelTests.swift:40-54`).
- **Locked storage and synchronous model release close the prior cleanup backlog.** Entry mutations are serialized by one lock; deinit uses the nonisolated exact release path without spawning a cleanup Task (`NearWireUIOperationCoordinator.swift:103-310,347-357`; `NearWireUIModel.swift:40-48`). Source tracing found no lock-order cycle in the production NearWire conformance: continuation finishing occurs after unlocking, phase consumers resume asynchronously, and NearWire cancellation does not re-enter coordinator storage.
- **Both preemption orders, weak origin-only error delivery, status/action error orders, multibyte forwarding, shutdown gating, 100-model release, release-during-Connect, and ownership reset codes now have focused tests.**
- **The iOS renderer source is correctly platform-conditional.** `nsImage` is used on macOS and `uiImage` on iOS, inside a main-actor test; `verify-package.sh` builds all test sources for arm64 iOS 16 under complete concurrency and warnings-as-errors before simulator execution (`SDK/Tests/NearWireUITests/NearWireUIViewSmokeTests.swift:7-64`; `Scripts/verify-package.sh:137-164`).

## Findings

### 1. P1 / High — The remediated UI suite remains schedule-dependent and can crash the test process

**Confidence: 10/10**

`testShutdownSuppressesActionsAcrossCoordinatorPhases` waits for published coordinator phases but does not wait for the fake controller's Connect and Disconnect continuations to be registered before calling `finishNextConnect()` and `finishNextDisconnect()` (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:78-100`). Phase publication is synchronous when the coordinator creates each Task, while the Task body appends its fake continuation later. The fake completion helpers unconditionally call `removeFirst()` (`SDK/Tests/NearWireUITests/NearWireUITestSupport.swift:61-68`). Therefore the test can observe Connecting/Disconnecting and then remove from an empty continuation array.

This occurred in independent execution: the latest built full xctest crashed at that test with `Fatal error: Can't remove first element from an empty collection` and exit 133. Three additional full-suite processes produced two passes and one identical crash. Isolated executions happened to pass, confirming a scheduling race rather than a deterministic assertion. The recorded “36 passed” focused result is consequently not stable evidence, and the fake-controller suite does not yet meet task 3.3's deterministic requirement.

**Required remediation:** before each `finishNext...`, wait on the corresponding exact pending count, or better return named operation handles/tokens from the fake and complete those exact handles without `removeFirst()`. Make empty or duplicate completion an XCTest failure rather than a process trap. Stress the focused UI suite repeatedly and concurrently enough to demonstrate zero crash/flaky outcomes, then refresh the evidence with exact run counts.

### 2. P2 / Medium — Distinct injected-instance replacement still lacks behavioral evidence

**Confidence: 9/10**

The normative scenario requires SwiftUI to recompute the public wrapper with a distinct `NearWire` at the same structural location, tear down the old child, and prevent old-controller yields/completions from mutating the new child (`specs/sdk-ui/spec.md:138-145`). Production uses `.id(ObjectIdentifier(nearWire))`, which is the appropriate mechanism (`SDK/Sources/NearWireUI/NearWireConnectionView.swift:7-17`). However, the evidence maps this scenario to a source-string structure check, a same-controller disappearance/recreation gate, and a stopped-status test (`evidence/requirement-to-evidence.md:12`; `evidence/spec-to-evidence-audit.md:16`). None mounts or updates the public wrapper with two distinct controllers/instances, and none drives an old-controller status/action completion after replacement while asserting the new model remains unchanged.

The same-controller Connect A/Connect B test proves coordinator cancellation ownership, not SwiftUI identity replacement. A syntax mutation check proves the `.id` call exists, not that the state-owning child is actually replaced at the required lifecycle boundary.

**Required remediation:** add a behavioral replacement harness using two distinct controllable instances at one outer SwiftUI identity. Start observation/action on A, replace with B, then deliver held status and Connect completion from A. Assert A's subscriptions and model release, B's synchronous initial phase/status ownership, no stale error/input/action mutation, and all new actions targeting B only. If a reliable SwiftUI mounting harness is unavailable, factor the identity-keyed child boundary into an internal testable composition seam while retaining a public-view smoke/integration check.

## Validation

- Fresh strict `swift test --filter NearWireUITests` compilation was attempted in a new scratch directory but stopped with `No space left on device` after production modules compiled; this is an environment-capacity failure, not a source diagnostic. Existing repository evidence records a prior strict 36/36 pass.
- Latest built full macOS xctest, first independent run: **CRASH**, exit 133 in the shutdown test's fake `removeFirst()`.
- Three additional concurrent full xctest runs: **2 PASS, 1 CRASH** with the identical shutdown-test fatal error. Passing runs each executed 463 tests with seven existing skips.
- Eight concurrent isolated shutdown-test runs: 8 PASS, demonstrating that isolation masks the scheduling race.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: PASS.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS.
- `git diff --check -- openspec/changes/sdk-ui SDK/Sources/NearWireUI SDK/Tests/NearWireUITests Scripts Package.swift Documentation README.md`: PASS.

## Verdict

**Unresolved actionable finding count: 2 — 1 High, 1 Medium. Correctness/testing approval is not granted.**

The Round 1 production defects and most evidence gaps are substantively remediated. Approval remains blocked by a reproducible schedule-dependent test-process crash and the absence of behavioral evidence for replacement with a distinct injected instance.
