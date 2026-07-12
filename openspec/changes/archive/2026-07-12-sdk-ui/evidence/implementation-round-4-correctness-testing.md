# Implementation Review — Round 4 Correctness and Testing

Date: 2026-07-12

## Scope

Independently re-reviewed the active `sdk-ui` change after Round 3 remediation. The review covered all current production UI source, focused tests and fakes, mounted SwiftUI replacement coverage, active design/specification requirements, task state, prior findings/remediation, and refreshed validation evidence. It specifically traced cross-panel cancellation in both completion orders, exact origin-token reconciliation, reverse-delivery revisions and loop termination, cancellation-observer retention, public-view A-to-B subscription transfer, and the recorded focused/full gate counts. No production, test, specification, documentation, or evidence file other than this assigned report was modified.

## Round 3 Remediation Status

- **The stale origin-token defect is fixed.** Every received shared phase reconciles the model's exact token against the coordinator's locked origin ownership; the two-panel test proves a non-origin panel can cancel and the origin panel can start exactly one later Connect in both acknowledgement orders (`SDK/Sources/NearWireUI/NearWireUIModel.swift:191-203`; `SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:358-361,489-533`).
- **Reverse phase delivery converges.** Each entry advances a revision on phase mutation. Delivery re-reads the latest phase, yields outside the lock, and repeats when the revision changed during that yield (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:317-348,383-395`). The barrier test forces Cancelling publication to resume after Disconnecting and holds cleanup long enough to assert convergence (`SDK/Tests/NearWireUITests/NearWireUIOperationCoordinatorTests.swift:155-194`). Source tracing found no unbounded production loop: one entry has a finite closed operation state machine, and another iteration occurs only after a phase revision changes.
- **The fake observer cycle is fixed.** The reentrant test clears the observer and weakly verifies both controller and coordinator release (`NearWireUIOperationCoordinatorTests.swift:123-153`).
- **Mounted replacement evidence now exists.** A real platform hosting controller replaces the public root view from NearWire A to B and proves the SDK status subscription transfers from A to B; the separate controllable-model test continues to prove stale A yields/completion are inert and later actions target only B (`SDK/Tests/NearWireUITests/NearWireUIViewSmokeTests.swift:15-55`; `NearWireUIModelTests.swift:444-487`).

## Finding

### P2 / Medium — Fast cross-panel cancellation can retain the cancelled pairing input when phase buffering coalesces directly to Idle

**Confidence: 10/10**

The exact-token reconciliation now runs for every received phase, so a coalesced Idle update correctly clears the stale token and restores Connect liveness. Pairing input and action error, however, are cleared only when that received value is `.cancelling` or `.disconnecting` (`SDK/Sources/NearWireUI/NearWireUIModel.swift:191-203`).

The phase stream is deliberately `bufferingNewest(1)` (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:417-438`). If panel B requests shared Cancel while panel A owns Connect, and the controller's Connect cancellation and Disconnect both return before A's phase-consumer Task runs, Disconnecting is replaced in A's one-value buffer by Idle. A then receives only Idle, observes that its origin ownership was revoked, clears its token, and increments the action generation, but leaves the cancelled code in `pairingCode`. The UI consequently returns to an enabled Connect presentation prefilled with the code the user just cancelled.

This contradicts the normative requirement that a Cancel/Disconnect request clear model input (`openspec/changes/sdk-ui/specs/sdk-ui/spec.md:33`) and the remediation/evidence claim that the initiating panel clears its bounded input on shared cancellation (`openspec/changes/sdk-ui/evidence/implementation-round-3-remediation.md:23`). The current two-panel test always waits until both models visibly consume Disconnecting before completing either fake continuation, so it cannot exercise the legal newest-value coalescing path (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:504-520`).

**Required remediation:** when an active exact token loses coordinator origin ownership, clear pairing input and action error regardless of which latest phase triggered reconciliation. Natural success/failure remains distinguishable because its main-actor origin completion clears the token before the asynchronously yielded Idle phase can be consumed. Add a deterministic immediate-completion or blocked-consumer test that coalesces Disconnecting to Idle, then assert the origin token, pairing input, and error are cleared and exactly one subsequent Connect can start.

## Independent Validation

- Strict focused NearWireUI suite with complete concurrency checking and warnings as errors: **PASS**, 42 tests, zero failures.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: **PASS**.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.

The refreshed evidence counts match the current 42-test suite and source inventory. The full macOS/iOS, 25-suite, 100-race, package, and podspec results are recorded consistently, but they do not create the deliberately coalesced cancellation schedule described above.

## Verdict

**Unresolved actionable finding count: 1 Medium. Correctness/testing approval is not granted.**

All three Round 3 defects are substantively remediated. Completion remains blocked only by the input-clearing behavior and missing deterministic coverage for a legal newest-value phase coalescing schedule.
