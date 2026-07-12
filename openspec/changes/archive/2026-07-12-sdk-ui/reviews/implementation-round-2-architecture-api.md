# Implementation Architecture and API Review — Round 2

## Scope

Re-reviewed all current NearWireUI production sources, tests, consumer fixtures, package and CocoaPods mappings, validation scripts, documentation, active specifications and tasks, all three Round 1 implementation reports, and `implementation-round-1-remediation.md`. The review independently traced rapid Connect admission, synchronous termination/deinit cleanup, controller and token identity lifetime, lock ordering, action atomicity, exact public exposure, and the normalized SwiftPM/CocoaPods UI delta. This was report-only; no production, test, specification, task, or documentation source was modified.

## Round 1 Remediation Verification

### Rapid Connect ownership

The accepted-origin token defect is fixed. `NearWireUIConnectionModel.connect()` now rejects another local activation while an exact token is live, before changing action generation or assigning another result (`SDK/Sources/NearWireUI/NearWireUIModel.swift:161-175`). Because the coordinator call and assignment execute in one main-actor turn, its Connect Task cannot complete on the main actor before the model stores the returned token. `testBackToBackConnectActivationKeepsAcceptedOriginToken` performs both activations without an intervening suspension, proves one controller invocation, and proves the accepted failure still reaches the origin model (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:56-76`).

### Termination, deinit, and object identity

Natural phase-stream termination now removes the exact `(ObjectIdentifier, registrationToken)` synchronously through lock-protected storage and applies the same idle-prune rule (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:103-140,316-337`). Explicit unsubscribe removes under the lock and calls `finish()` after unlocking, so its termination callback is idempotent rather than recursively locking (`NearWireUIOperationCoordinator.swift:130-140,340-345`).

Model deinit calls the nonisolated locked `releaseModel` directly, then cancels observation handles; it creates no cleanup Task (`SDK/Sources/NearWireUI/NearWireUIModel.swift:40-48`; `NearWireUIOperationCoordinator.swift:142-162,347-357`). That path removes only the exact registration and cancels only an identity-matching Connect. A stale termination retains its old registration token, so it cannot remove a replacement token even if a controller address is later reused. During non-idle work the operation Task strongly captures the exact controller until its token-matched finish call; during a live idle registration the model retains the controller. The public model path therefore closes the `ObjectIdentifier` reuse window.

The direct termination, release-during-Connect, and 100-model burst tests pass (`NearWireUIOperationCoordinatorTests.swift:31-44`; `NearWireUIModelTests.swift:354-410`).

### Atomicity, locks, and operation bounds

No actionable action-state race or deadlock was found.

- Connect and Disconnect admission remain main-actor serialized. Although their storage eligibility and insertion use separate lock acquisitions, the only concurrent nonisolated paths can remove a subscriber, prune an idle entry, or cancel an exact existing Connect; they cannot admit another action. Pruning between those calls merely causes insertion into a fresh idle entry for the same still-retained controller.
- Every entry mutation is performed under one `NSLock`. Continuation `finish()` and origin completion invocation occur after unlocking (`NearWireUIOperationCoordinator.swift:340-357,442-448`), avoiding coordinator re-entry while the lock is held.
- The production `NearWire.connect` cancellation handler only signals its transition gate and has no dependency back into NearWireUI (`SDK/Sources/NearWire/NearWire.swift:189-199`), so cancelling the Connect Task while holding coordinator storage cannot form a cross-layer lock cycle.
- Exact tokens gate both completion paths. Preemption remains bounded to one Connect and one Disconnect, and both asymmetric completion-order tests pass (`NearWireUIOperationCoordinatorTests.swift:46-85`).

### Current supported API and distribution shape

The current production source exposes exactly the two specified public structs, initializers, and `View.body` properties. The controller, model, state-owning child, storage, tokens, coordinator, input limiter, and presentation types remain internal. The wrapper still keys the child by `ObjectIdentifier(nearWire)` (`SDK/Sources/NearWireUI/NearWireConnectionView.swift:7-17`), and no hidden facade or additional product, target, pod subspec, runtime dependency, resource bundle, or SPI was added. SwiftPM keeps a separate optional `NearWireUI` product; CocoaPods keeps SDK as the default and adds UI only through `NearWire/UI`.

## Finding

### P2 — Medium: The normalized distribution check still does not enforce the exact approved UI declaration tree

**Confidence: 10/10**

The new API-digester comparison is a useful parity check, but it is not an exact contract check. It selects the two expected root nodes and compares their normalized SwiftPM and CocoaPods trees (`Scripts/verify-package.sh:614-624`). It then treats every declaration nested under those two aggregate view trees as an allowed UI addition (`Scripts/verify-package.sh:626-630`). Consequently, an extra public member or conformance added to either approved view passes the semantic step as long as the same source produces it in both distributions.

The source backstop only selects lines whose trimmed text starts with `public ` (`Scripts/check-sdk-ui-structure.rb:30-42`; `Scripts/verify-package.sh:632-646`). An attributed declaration such as `extension NearWireConnectionView { @MainActor public func extra() {} }`, or a supported marker conformance without a `public` token, bypasses that check. A read-only mutation probe in this review confirmed that the attributed public-member mutation passes `validate_ui`. The built-in mutation self-test covers only an un-attributed top-level type and member (`Scripts/check-sdk-ui-structure.rb:72-90`). The canonical API projection also discards declaration attributes and other ABI metadata, retaining only kind, name, printed name, and children (`Scripts/verify-package.sh:598-607`).

The current checked-in UI source does not contain an extra supported declaration, so the shipped surface itself is correct. The defect is that the gate and evidence claim an exact aggregate/delta guarantee that they do not enforce (`openspec/changes/sdk-ui/specs/sdk-public-boundary/spec.md:7-11`; `openspec/changes/sdk-ui/evidence/public-api-inventory.md:23-36`).

**Required remediation:** compare the normalized SwiftPM UI declaration tree against an explicit expected schema for the two views, including their sole `View` conformances, initializers, body properties, actor/availability attributes, parameter/result types, and no other children or conformances. Then compare the CocoaPods aggregate-minus-SDK normalized declarations to that same expected schema. Extend mutation tests with an attributed public member and an extra marker conformance; both must fail the complete gate, not only a source regex.

## Validation Performed

- Strict focused NearWireUI suite with complete concurrency checking and warnings as errors: passed, 36 tests, 0 failures.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: passed its two built-in mutations.
- Additional read-only source-gate mutation: an attributed public member was accepted, confirming the finding.
- `./Scripts/verify-package.sh`: all NearWireUI iOS/macOS builds, iOS test-source compile, SwiftPM/CocoaPods consumers, forbidden fixtures, and the current normalized aggregate check passed; the command then failed only when the unavailable CoreSimulator service was reached.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.
- `git diff --check`: passed.

## Verdict

**Changes required. Unresolved actionable findings: 1 medium. The Round 1 Connect, termination/deinit, shutdown, accessibility, and current-source API defects are resolved, but architecture/API approval remains withheld until the public-delta gate rejects every declaration beyond the explicit two-view contract.**
