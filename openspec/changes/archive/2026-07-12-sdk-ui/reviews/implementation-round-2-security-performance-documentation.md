# SDK UI Implementation Security, Performance, and Documentation Review — Round 2

## Result

**Unresolved actionable finding count: 4** — one High and three Medium.

Round 1 remediation materially improves the implementation: exact natural termination and deinit cleanup are synchronous and tokenized, no cleanup Task is created, pairing disclosure and safe-error handling are accurate, reconnect and paused semantics reach the final accessibility label, both public views have platform-conditional rendering coverage, iOS test sources compile, and the public API gates now include mutation checks plus normalized declaration-tree comparison. Four issues remain: the required focused suite is scheduling-dependent and crashed during this review, the new lock executes external cancellation/stream operations while held, the Foundation import contradicts the exact module boundary, and several UI literals can be localized despite the fixed-English contract.

## Findings

### 1. High — The required focused test gate is nondeterministic and can terminate the test process

**Evidence**

- `testShutdownSuppressesActionsAcrossCoordinatorPhases` calls `coordinator.disconnect`, waits only until the model observes `.disconnecting`, then immediately resumes both fake operations (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:78-99`).
- The coordinator publishes `.disconnecting` synchronously when it stores the Disconnect operation, before the new Task necessarily reaches `controller.disconnect()` (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:211-217,401-413`). The fake does not append its Disconnect continuation until that later Task turn (`SDK/Tests/NearWireUITests/NearWireUITestSupport.swift:47-50`).
- `finishNextDisconnect()` unconditionally calls `removeFirst()` (`NearWireUITestSupport.swift:66-68`). If the test wins the race, the array is empty and XCTest aborts with `Fatal error: Can't remove first element from an empty collection` rather than reporting an assertion.
- Running the exact focused strict command during this review exited with unexpected signal 5 at that test. An isolated immediate rerun passed, confirming scheduling dependence rather than a deterministic satisfied barrier. The evidence records 36 passing tests as an exact current result (`openspec/changes/sdk-ui/evidence/focused-implementation-validation.md:5-31`) but does not disclose this NearWireUI flake.

**Impact**

The mandatory focused gate can randomly kill its process, so a green run cannot be treated as stable evidence of the shutdown/preemption boundary. The crash also prevents later tests from running and can conceal unrelated security/resource regressions.

**Required remediation**

Wait for `pendingDisconnectCount == 1` before resuming the fake Disconnect, and make fake completion helpers fail with a controlled XCTest assertion rather than process-fatal `removeFirst()` when a barrier is missing. Stress or repeat the affected test and full NearWireUI filter enough to demonstrate stability, then replace the focused evidence with a fresh reproducible run.

### 2. Medium — The synchronous storage performs externally executing operations while holding a non-recursive lock

**Evidence**

- `Storage.releaseModel`, `cancelConnect`, and `prepareDisconnect` call `connect.task.cancel()` inside `withLock` (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:142-162,180-209`). Task cancellation may immediately/concurrently execute cancellation handlers owned by the controller operation. The production `NearWire.connect` handler synchronously enters its transition gate (`SDK/Sources/NearWire/NearWire.swift:189-199`); test or future internal controllers may perform other reentrant work.
- `publishPhaseLocked` calls every `AsyncStream.Continuation.yield` while the same `NSLock` is held (`NearWireUIOperationCoordinator.swift:284-296`). Each continuation has an `onTermination` closure that re-enters the same storage lock (`NearWireUIOperationCoordinator.swift:316-332`).
- Explicit `finish()` and origin completion are correctly moved outside the lock, but cancellation and yield are not. Current tests use a non-reentrant fake cancellation handler and do not race natural termination against phase publication or attempt coordinator reentry from cancellation.

**Impact**

The storage's data mutation is constant-space, but its lock duration and liveness depend on Task/AsyncStream/controller behavior outside the storage. A synchronous reentry or lock-order inversion can deadlock the coordinator; a slow cancellation handler can also block model deinitialization and all panels sharing the coordinator. This is especially risky because `releaseModel` is intentionally nonisolated and may run from arbitrary teardown contexts.

**Required remediation**

Under the lock, mutate state and collect exact Tasks/continuations plus phase/version tokens; unlock before calling `Task.cancel()` or `Continuation.yield`; then reconcile terminated continuations under a second exact-token lock pass. Add adversarial tests with a cancellation handler that attempts coordinator/storage reentry and with phase publication racing iterator cancellation. If any external call must remain locked, document and prove its non-reentrant contract rather than relying on current implementation behavior.

### 3. Medium — The lock remediation silently broadens the exact production import boundary

**Evidence**

- `NearWireUIOperationCoordinator.swift` now imports Foundation to obtain `NSLock` (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:1-5`).
- The active requirement says NearWireUI production code shall import SwiftUI and the supported NearWire facade only (`openspec/changes/sdk-ui/specs/sdk-ui/spec.md:123-125`), and the design repeats that exact boundary (`openspec/changes/sdk-ui/design.md:80-84`).
- `check-sdk-ui-structure.rb` rejects selected forbidden API tokens but does not enforce an import allowlist (`Scripts/check-sdk-ui-structure.rb:52-69`). The resource and spec-to-evidence audits therefore report this requirement as satisfied without detecting the new module.

**Impact**

Foundation itself is an Apple system framework and the current use is only an in-memory lock, so this is not a third-party or persistence defect. It is nevertheless a direct implementation/spec mismatch and demonstrates that the resource audit cannot enforce the documented module boundary.

**Required remediation**

Either implement synchronization within the currently allowed imports or explicitly revise and review the requirement/design to permit Foundation solely for the bounded synchronization primitive. Add an exact production import audit so future framework additions cannot bypass the OpenSpec boundary.

### 4. Medium — Several controls are localizable even though the supported UI is documented as fixed English

**Evidence**

- The connection view passes string literals directly to `Text`, `TextField`, `Button`, `accessibilityLabel`, and `accessibilityHint`, including Reading Connection Status, Pairing code, Viewer pairing code, and Reset Connection (`SDK/Sources/NearWireUI/NearWireConnectionView.swift:38-61,89-95`).
- SwiftUI's literal overloads use `LocalizedStringKey`; the generic `StringProtocol` overloads are marked `@_disfavoredOverload`. These literals may therefore resolve through the host application's localization tables even though NearWireUI has no resource bundle.
- Presentation-generated `String` values now provide correct retry/paused accessibility text, but the remaining literal controls are not forced through verbatim `Text`/String APIs. Documentation states that V1 strings are fixed English and are not localized (`Documentation/SDK-UI.md:57-63`), and the accessibility/source tests do not test host localization interference.

**Impact**

A host application containing matching localization keys can change a subset of NearWireUI labels and accessibility text. The rendered product can therefore be partly localized while documentation and exact-string evidence claim a fixed-English surface.

**Required remediation**

Use explicit verbatim `Text` or non-localized `String` label paths for every fixed control and accessibility string, including TextField and reset/loading/error labels. Extend the source audit or a host-bundle fixture so direct localizable-literal overloads cannot re-enter the fixed-English UI.

## Round 1 Finding Disposition and Verified Boundaries

- Natural phase-stream termination now removes the exact subscriber through a synchronous locked key/token path; explicit unsubscribe and deinit cleanup are idempotent. Model deinit creates no cleanup Task, burst release leaves no coordinator entry, and non-idle Task captures retain the exact controller until completion.
- The accepted Connect token is protected against back-to-back activation, shutdown wins before coordinator phase, origin failure is delivered only to the initiating weak model, both status/error winner orders are tested, and all ownership reset codes are covered.
- Pairing input remains scalar-boundary capped at 64 UTF-8 bytes. Only one in-flight Connect capture may outlive model clearing; documentation now discloses that lifetime and the lack of secure String zeroization. No pairing content reaches production logs, persistence, pasteboard, diagnostics, status, or unexpected-error text.
- Unknown errors map to the fixed generic sentence; only content-safe `NearWireError.message` is shown. No underlying description is interpolated.
- The fail-closed resource shape remains one code-free Disconnect Task and one exact entry for the sole process route, without per-panel cleanup waiters or callback lists. Phase subscribers terminate independently.
- Reconnect attempt and paused text now enter `presentation.accessibilityLabel`; the status view binds that final value. Both public views and reset/error/progress panel shapes render at accessibility Dynamic Type size, using `nsImage` on macOS and `uiImage` on iOS.
- The current iOS 16 `--build-tests` strict compile passes, as do the recorded iOS 16/macOS 13 production target builds. Swift 5 language mode, complete concurrency, and warnings-as-errors remain configured.
- Structure mutation tests reject extra public top-level/member lines. The package gate compares normalized SwiftPM/CocoaPods view declaration trees and rejects aggregate declarations outside the two approved view roots while retaining SDK-only and forbidden-internal fixtures.
- No production persistence, Keychain/Security-item access, file I/O, pasteboard, camera, analytics, notification, reachability, application-lifecycle observer, background execution, UIKit/AppKit wrapper, public Combine API, detached Task, asset, font, entitlement, privacy declaration, resource bundle, or third-party dependency was found.
- Evidence and audits now explicitly leave unrestricted simulator execution and `pod lib lint` pending under task 5.2 rather than claiming final closure.

## Validation Performed

- Strict NearWireUI filter with complete concurrency and warnings as errors: **FAIL/FLAKY** — process exited with signal 5 from the shutdown test's empty fake Disconnect queue; isolated rerun of that test passed.
- iOS 16 SwiftPM `--build-tests` compile with complete concurrency and warnings as errors: PASS.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: PASS.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS.
- `git diff --check`: PASS.

## Final Verdict

**Not ready for completion.** Stabilize the focused gate, remove external cancellation/yield work from the storage lock, reconcile the Foundation import with the exact specification, and make all fixed-English strings truly verbatim. A fresh security/performance/documentation implementation review is required after remediation.
