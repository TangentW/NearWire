# SDK UI Implementation Security, Performance, and Documentation Review — Round 5

## Scope

Independently reviewed the current `sdk-ui` production source, focused tests and support code, active proposal/design/specifications/tasks, package and CocoaPods validation, UI/distribution documentation, all prior implementation findings, remediation evidence, and current validation records after the Round 4 coalescing fix. The review traced exact revoked-origin cleanup, sensitive pairing-input lifetime, natural success/failure ordering, revision-delivery and task/subscriber bounds, delivery-hook isolation, reentrant release, fixed-English/resource/API boundaries, and evidence freshness. Only this report was added.

## Production Remediation Verified

- Revoked exact-origin ownership is now phase-independent. A generation-current model with an exact active token queries coordinator ownership under the storage lock and, whenever that exact origin callback has been revoked, clears the token, advances action authority, and clears pairing input and action error regardless of whether the surviving phase is Idle, Connecting, Cancelling, or Disconnecting (`SDK/Sources/NearWireUI/NearWireUIModel.swift:191-215`). A coalesced Idle value therefore no longer retains the cancelled code.
- Natural Connect completion remains distinct. Exact completion removes the operation and invokes its generation-current origin callback synchronously on `MainActor` before the phase-consumer Task can run. Success clears input/error; safe failure retains only the bounded input while installing its content-safe error; the later phase update sees no active token and cannot erase that intended result.
- Pairing input remains plain, memory-only, scalar-boundary capped at 64 UTF-8 bytes, and absent from logging, persistence, pasteboard, diagnostics, public API, and unexpected-error interpolation. Success, direct Cancel/Disconnect, disappearance, model teardown, and exact shared-origin revocation now all have a clearing path. Documentation correctly disclaims secure `String` zeroization and the one bounded in-flight argument copy.
- Per-controller state remains bounded to one exact Connect Task, at most one code-free Disconnect Task during preemption, one optional weak-model origin completion, one phase/revision value, and one newest-one continuation per live panel. Revision delivery re-reads the current phase and repeats only when a newer mutation raced its unlocked yield. Cancellation, yield/finish, and origin completion remain outside `NSLock`.
- The internal delivery hook remains `nil` in the production singleton, is inaccessible through supported API/SPI, and creates no production callback, task, framework, or persistence behavior. The reentrant test clears its installed fake observer and proves its controller/coordinator graph releases.
- Fixed-English strings, semantic accessibility, import/resource boundaries, portable two-view API normalization, SwiftPM/CocoaPods optionality, and all earlier security/documentation remediations remain intact. No sensitive-content disclosure, third-party runtime dependency, forbidden system resource, or production retain cycle was found.

## Finding

### Medium — The exact coalesced cleanup schedule lacks behavioral evidence, and the recorded final counts predate the current test tree

**Confidence: 10/10**

The production condition is correct, but `testCoalescedIdleClearsRevokedOriginState` exercises only the pure `shouldClearRevokedOriginState` predicate (`SDK/Tests/NearWireUITests/NearWireUIModelTests.swift:363-388`). It does not construct a model with an active token and retained pairing code, revoke that exact token through another panel, make `bufferingNewest(1)` replace Disconnecting with Idle before the origin model consumes it, or assert the resulting token/input/error state. It would still pass if the caller stopped clearing `pairingCode`, `actionError`, or `activeOperationToken` after the predicate returns true.

The existing two-panel test proves actual clearing only after both panels have visibly consumed Disconnecting before either operation is completed (`NearWireUIModelTests.swift:516-559`). It therefore cannot execute the legal coalesced schedule that caused the Round 4 sensitive-input retention finding. This falls short of the repository requirement to match evidence to the normative scenario and of the Round 4 requested deterministic remediation.

The completion evidence is also stale relative to the current test tree. `focused-implementation-validation.md`, `spec-to-evidence-audit.md`, and `implementation-round-3-remediation.md` still record 42 focused tests and 469 full tests. The current focused command executes **43 tests**, including the new policy test, with zero failures. Thus the recorded 42/469 runs cannot be final evidence for the current sources; the production/model source and test were modified after those records were generated.

**Required remediation:** replace or supplement the predicate-only check with a deterministic model/coordinator test that forces Disconnecting to be coalesced to Idle before the origin model consumes it. Assert that only the exact revoked operation clears its token, pairing code, and action error; normal safe failure still retains its bounded code/error; and no successor Connect begins until new input is supplied. Then rerun and refresh the focused stress run, full macOS/iOS suites, package and CocoaPods gates, and every count-bearing audit against the final tree.

## Validation Performed

- Strict NearWireUI suite with complete concurrency checking and warnings as errors: **PASS**, 43 tests, 0 failures.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: **PASS**.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.
- Current Package.swift and podspec hashes match `run-identity.md`.
- Focused source scan found no forbidden resource, persistence, logging, detached production Task, or localizable SwiftUI literal.

## Verdict

**Changes required. Unresolved actionable findings: 1 Medium.** The Round 4 production defect and every earlier security/resource/documentation defect are fixed. Completion approval remains withheld only because the sensitive-input clearing boundary is not behaviorally exercised under actual newest-value coalescing and the final validation evidence still reports the pre-test 42/469 tree. A fresh zero-finding review is required after deterministic coverage and refreshed evidence.
