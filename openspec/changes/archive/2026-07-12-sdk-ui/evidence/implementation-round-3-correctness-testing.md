# Implementation Review — Round 3 Correctness and Testing

Date: 2026-07-12

## Scope

Independently reviewed the active `sdk-ui` proposal, design, delta specifications, tasks, production source, focused tests, validation scripts, documentation, Round 2 reports, remediation record, and current evidence. The review traced exact operation-token ownership, two-panel preemption, status and coordinator generations, nonisolated model release, phase publication, subscriber termination, retention, replacement identity, and the relationship between recorded evidence and normative scenarios. No production, test, specification, or documentation source was modified by this review.

## Findings

### 1. P1 / High — Cross-panel Cancel leaves the initiating model with a permanently stale operation token

**Confidence: 10/10**

The initiating model stores its accepted Connect token in `activeOperationToken` and refuses every later Connect while that property is non-`nil` (`SDK/Sources/NearWireUI/NearWireUIModel.swift:161-175`). The token is normally cleared only by that model's origin completion, its own `disconnect()`, or `stop()` (`NearWireUIModel.swift:82-103,177-214`).

With two live panels for the same controller, panel A can start Connect and panel B can invoke the shared Cancel/Disconnect action. `prepareDisconnect` deliberately clears the Connect operation's sole origin completion before cancelling it (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:237-258`). Consequently panel A never receives `receiveConnectOutcome`, and merely receiving later coordinator phases does not clear A's token (`NearWireUIModel.swift:191-194`). After both exact operations acknowledge and every panel receives `.idle`, panel A renders Connect again, but activating it is silently rejected by `activeOperationToken == nil` in the private Connect guard. Panel A remains unusable until it disappears or performs a separate reset path.

This violates the two-visible-panel coherence and repeated shared preemption requirements: coordinator state is idle and the UI advertises Connect, yet the displayed action cannot start. Existing two-model coverage starts from panel A and then stops panel B; it never has a non-origin panel cancel and then proves the origin panel can start the next Connect (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:326-356`).

**Required remediation:** reconcile a model's exact active token when the shared phase proves that token no longer owns a Connect operation, without allowing a stale phase or unrelated operation to clear current ownership. Add a deterministic two-panel test: A starts Connect, B cancels, both acknowledgements complete in each order, both panels reach idle, and A can start exactly one subsequent Connect. Include the fail-closed order where Disconnect remains pending long enough to verify both panels retain the correct disabled gate.

### 2. P2 / Medium — Phase snapshots can be delivered out of order across the nonisolated release path

**Confidence: 9/10**

Storage mutations correctly prepare delivery effects under `NSLock` and execute continuation callbacks after unlocking. However, `Storage.deliver` yields a captured phase snapshot without first confirming that the exact entry still has that phase (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:312-325`). Its entry-identity check happens only after yielding and only when removing terminated subscribers.

`releaseModel` is intentionally `nonisolated` and calls `storage.releaseModel` and `storage.deliver` as separate operations (`NearWireUIOperationCoordinator.swift:418-431`). Therefore this valid interleaving exists for the same exact Connect token:

1. nonisolated release changes storage from Connecting to Cancelling and captures a Cancelling delivery;
2. before that snapshot is yielded, main-actor Disconnect installs a Disconnect operation, changes storage to Disconnecting, and yields Disconnecting;
3. release resumes and yields its older Cancelling snapshot, which can replace Disconnecting in the subscribers' `bufferingNewest(1)` streams.

Storage remains Disconnecting, so if one predecessor completes while the other is still fail-closed, `preparePhaseLocked(.disconnecting, ...)` produces no corrective delivery because storage already has that phase. A panel may consequently display Cancelling indefinitely while the coordinator's actual fail-closed state is Disconnecting. The publication/termination stress test races phase publication only against consumer cancellation; it does not race two phase transitions or assert monotonic correspondence with the exact current storage phase (`SDK/Tests/NearWireUITests/NearWireUIOperationCoordinatorTests.swift:46-62`).

**Required remediation:** give phase deliveries an exact revision/generation and suppress a snapshot unless the entry and revision are still current at yield time, or otherwise serialize publication so an older snapshot cannot follow a newer one. Add a controlled barrier test that forces the release-delivery versus Disconnect transition order above and asserts every surviving subscriber ends at the coordinator's current phase. Exercise both operation-completion orders and a held fail-closed Disconnect.

### 3. P2 / Medium — The distinct-instance replacement scenario is still not tested through SwiftUI identity/lifecycle behavior

**Confidence: 9/10**

The normative scenario requires recomputing `NearWireConnectionView` with a distinct injected `NearWire` at the same structural location and proving SwiftUI removes the old state-owning child (`openspec/changes/sdk-ui/specs/sdk-ui/spec.md:138-145`). Round 2 remediation added two useful but separate checks: the smoke test confirms two wrappers produce different `stateIdentity` values (`SDK/Tests/NearWireUITests/NearWireUIViewSmokeTests.swift:9-16`), and the model test manually stops/releases an old model before manually constructing a new model with another fake controller (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:439-482`).

Neither check mounts one public wrapper, updates it in place, and observes SwiftUI invoke the old child's teardown because of `.id`. The model test therefore proves generation isolation after explicit manual lifecycle calls, not the required identity-triggered lifecycle behavior. Nevertheless the requirement and spec-to-evidence matrices currently mark the full replacement scenario implemented and passing.

**Required remediation:** add a deterministic SwiftUI hosting/mounting test that replaces the public wrapper in one stable parent slot, or factor the identity-keyed state-child construction boundary into a testable internal seam and retain a mounted public-view integration assertion. Hold A's status and Connect completion across replacement, then prove A loses its subscriptions, stale A events are inert, and all subsequent observation/actions target B.

## Independent Validation

- Strict focused command with complete concurrency checking and warnings as errors: **PASS**, 39 tests, zero failures.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: **PASS**.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.

The passing focused suite is consistent with the implementation but does not exercise Findings 1 or 2, and its replacement checks do not establish the mounted identity transition in Finding 3.

## Verdict

**Unresolved actionable finding count: 3 — one High and two Medium. Correctness/testing approval is not granted.**

The Round 2 flaky fake-controller crash and missing distinct-controller model isolation test were successfully remediated, and the current focused suite is stable in this run. Completion remains blocked by one deterministic cross-panel operation-ownership defect, one concurrent stale-phase publication path, and one overclaimed SwiftUI replacement scenario.
