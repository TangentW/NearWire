# SDK UI Implementation Security, Performance, and Documentation Review — Round 3

## Scope

Independently reviewed `AGENTS.md`, the complete active `sdk-ui` proposal, design, delta specifications, tasks, production source, focused tests, package and CocoaPods mappings, validation scripts, documentation, prior implementation reviews, remediation record, and current evidence. The review traced pairing-code and error-content handling, persistence and framework boundaries, task/subscriber/controller retention, lock and external-call boundaries, fixed-English rendering, platform compatibility, and evidence consistency. This report changes no production, test, specification, task, or documentation source.

## Round 2 Remediation Verified

- Pairing input remains memory-only and capped at 64 valid UTF-8 bytes. It is absent from diagnostics, persistence, pasteboard, error interpolation, and supported API. Documentation accurately discloses the one bounded in-flight argument copy and lack of secure `String` zeroization.
- Unexpected errors map to one fixed generic sentence; only the SDK's internally constructed, content-safe `NearWireError.message` is displayed. No underlying error description, pairing code, endpoint, certificate, framework error, or Viewer payload is interpolated.
- Task cancellation, continuation yield/finish, and origin completion now execute outside `NSLock`. The production import allowlist is exactly Foundation, NearWire, and SwiftUI, with Foundation used only for the bounded synchronization primitive.
- Fixed UI strings use explicit verbatim or `String` value paths. The structure gate rejects direct localizable `Text`, `Button`, and accessibility literal overloads. Retry and paused state are included in the final accessibility label.
- The focused suite is stable in the reviewed run: 39 tests passed under complete concurrency checking and warnings as errors. Fake completion helpers no longer trap on an empty queue, and the shutdown test waits for exact pending operations.
- No third-party runtime dependency, resource bundle, asset, font, entitlement, privacy declaration, persistence, Keychain/Security item operation, camera, pasteboard, analytics, reachability, notification, application lifecycle observer, background execution, UIKit/AppKit wrapper, public Combine API, or detached production Task was found.

## Findings

### 1. Medium — Unlocked phase deliveries can be published out of mutation order and leave a live panel on a stale action gate

**Confidence: 9/10**

The Round 2 lock remediation correctly prepares phase deliveries while locked and calls `Continuation.yield` after unlocking. However, a `PhaseDelivery` carries only the entry identity, phase, and a subscriber snapshot (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:103-110,354-366`). `Storage.deliver` yields that snapshot unconditionally and checks entry identity only later when reconciling terminated continuations (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:312-325`). It does not carry or validate a monotonic phase revision, and it does not serialize deliveries for one entry.

This matters because `releaseModel` is intentionally `nonisolated` and may execute concurrently with main-actor completion (`SDK/Sources/NearWireUI/NearWireUIOperationCoordinator.swift:418-431,523-531`). One valid ordering is:

1. model release changes an entry from Connecting to Cancelling under the lock and receives a Cancelling delivery;
2. exact Connect completion then changes the same entry from Cancelling to Idle and receives an Idle delivery;
3. Idle is yielded first, followed by the older Cancelling snapshot.

The entry remains the same, so the existing identity check cannot reject the older yield. A second live panel can consequently finish on Cancelling while coordinator storage is already Idle, with no later phase change to repair it. That panel exposes a permanently disabled action until it is recreated. This contradicts the requirement that simultaneous panels receive the same latest action gate (`openspec/changes/sdk-ui/specs/sdk-ui/spec.md:73-76`) and weakens the claimed fail-closed/liveness behavior.

The new publication/termination race test covers subscriber removal racing publication, but it does not force phase mutation A and phase mutation B to deliver in reverse order.

**Required remediation:** give every per-entry phase transition a monotonic revision and make subscribers discard an update older than the latest applied revision, or otherwise serialize each entry's external deliveries without returning external calls to the storage lock. Add a deterministic barrier test that races nonisolated model release against exact Connect completion, forces reverse external delivery order, and proves every surviving model ends on the coordinator's current phase with no stale disabled action.

### 2. Low — The reentrant-cancellation test retains its fake controller and coordinator through a self-cycle

**Confidence: 10/10**

`testCancellationHandlerCanReenterStorageWithoutDeadlock` installs a closure captured strongly by the fake controller, and that closure strongly captures the same controller plus the coordinator (`SDK/Tests/NearWireUITests/NearWireUIOperationCoordinatorTests.swift:124-145`; `SDK/Tests/NearWireUITests/NearWireUITestSupport.swift:14-15,101-103`). Unlike the preceding cancellation test, it never clears the observer. The resulting `controller -> observer -> controller` cycle survives the test, and the closure also retains the coordinator. Repeated executions therefore leak one fake graph per invocation, which is undesirable in the stress evidence for a resource-bounded implementation.

**Required remediation:** clear the observer after the reentrant assertion (including failure-safe cleanup), or use weak captures, and add weak probes confirming both test objects release. This is a test/evidence leak; no equivalent production closure cycle was found.

### 3. Low — The public API inventory still describes a simulator failure that the final evidence says was resolved

**Confidence: 10/10**

`openspec/changes/sdk-ui/evidence/public-api-inventory.md:36` says the listed gates passed “before the unrelated simulator service failure.” The final validation evidence records a successful complete iOS simulator run with 466 total, 462 passed, four skipped, and zero failed (`focused-implementation-validation.md:48-66`), and the spec-to-evidence audit repeats that success (`spec-to-evidence-audit.md:28-33`). The stale sentence makes the completion evidence internally inconsistent.

**Required remediation:** replace the stale simulator-failure qualifier with the final successful simulator result, or limit the sentence strictly to the consumer/API checks without implying a current unresolved environment failure.

## Validation Performed

- Strict focused NearWireUI suite with complete concurrency checking and warnings as errors: **PASS**, 39 tests, 0 failures.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: **PASS**.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: **PASS**.
- `git diff --check` over the active change, UI source/tests, scripts, manifests, and documentation: **PASS**.
- Manifest identity: recorded Package.swift and podspec SHA-256 values match the current files; recorded Xcode, Swift, CocoaPods, and OpenSpec versions match the current tools.

## Verdict

**Changes required. Unresolved actionable findings: 3 — one Medium and two Low.** The Round 2 security, fixed-English, import-boundary, lock reentrancy, and flaky-test findings are resolved, and no sensitive-data disclosure or forbidden runtime resource was found. Completion approval remains withheld until phase delivery ordering is made exact, the adversarial test releases its retained graph, and the stale simulator evidence is corrected, followed by a fresh review.
