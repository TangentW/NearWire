# Implementation Review Round 3 — Architecture and API

Date: 2026-07-12

## Scope

Independently reviewed the current `sdk-performance` shared tree after the Round 2 remediation and deliberate simplification of validation. The review covered the public Performance API, SwiftPM and CocoaPods manifests, setup/run ownership, actor reentrancy, activation authorization, cancellation versus final commit, cleanup transfer, the explicitly documented activation-to-actor scheduling tolerance, current focused tests, active tasks, validation scripts, and evidence truthfulness. The deleted Performance-specific structure/mutation script was not treated as a required artifact: the current design intentionally keeps behavior and privacy-manifest semantics in XCTest and limits packaging validation to small real consumer and resource smoke checks. This report is the only file modified by the review.

## Finding

### P2 / Medium — The required boundary gate deterministically crashes, while current evidence says it passed

**Confidence: 10/10**

The current implementation progress records `./Scripts/verify-boundaries.sh` as passed and states that module boundary and dependency isolation verification succeeded (`evidence/implementation-progress.md:27-44`). The interim spec-to-evidence audit likewise cites that script as current evidence (`evidence/spec-to-evidence-audit.md:5-9`). On the current shared tree, however, the command fails before producing a boundary result.

`Scripts/check-swift-boundaries.rb` invokes `xcrun swiftc -frontend -dump-parse` separately for every Swift source (`Scripts/check-swift-boundaries.rb:98-107`). With the recorded Apple Swift 6.3.3 toolchain, parsing `SDK/Sources/NearWirePerformance/Internal/PerformanceLiveCollector.swift` in isolation reproducibly crashes the compiler while it resolves the same-file `PerformanceCollectorSession` declaration. Running the Ruby validator directly with the Performance source root reproduces the same crash. This is therefore neither a successful boundary check nor a transient canonical-recapture omission.

The gate remains required: both preflight and full canonical evidence capture invoke `verify-boundaries.sh` and require it to succeed (`Scripts/capture-bootstrap-evidence.sh:197-208,218-232`). Task 5.2 is correctly still unchecked, and `final-validation.md` correctly says final canonical recapture is pending, but the two current evidence documents above overstate the result already available from the present tree.

**Required remediation:** make the existing generic boundary validator robust on the current Swift/Xcode toolchain without restoring the deleted Performance-specific structure framework or adding a heavy parallel API-digester system. A small import-boundary implementation that does not parse every source as an isolated compilation unit is sufficient, provided the existing positive and mutation tests still prove the intended forbidden imports and re-exports. Until that gate passes on the current tree, correct `implementation-progress.md` and `spec-to-evidence-audit.md` so they do not claim current boundary success. Then rerun the affected gate and final canonical capture before checking tasks 5.2 and 5.3.

## Lifecycle and API Disposition

- The Round 2 cancellation/commit race is resolved. Activation authorization closes later resource acquisition but leaves cancellation effective. `PerformanceStartAttempt.commitActivation()` then makes cancellation versus final commit one locked winner, and `commitActivatedStart` performs that decision, run-worker creation, Running publication, and shared-attempt resolution in one non-suspending actor turn.
- A cancellation that wins before the final transition rejects commit and drives setup-owned collector stop followed by lease release. Cancellation after the locked final commit observes the committed run. The focused tests include the cancellation-after-authorization winner, and acquisition-gate tests verify that authorization or cancellation rejects subsequent setup acquisition.
- The bounded activation-to-actor gap is no longer a contract defect. The active specification and design explicitly permit this sub-turn interval to contribute to the first successful interval/display accumulator, require activated state to be discarded when cancellation wins, and record the decision to avoid more complex synchronization solely to redefine that small interval (`specs/sdk-performance/spec.md:164-168`; `design.md:181-185`). The implementation matches that stated tradeoff.
- Setup ownership remains bounded and coherent: one setup Task and shared outcome belong to the exact Starting attempt; lease and collector stay setup-owned until successful final commit; failure cleanup stops the collector before releasing the lease; the run worker receives ownership only after the commit winner is fixed.
- The supported public surface remains limited to configuration, fixed error/code, lifecycle state, and the actor monitor. Snapshot/schema, collector, runtime, clock, lease, setup/run workers, and test seams remain internal. The removed `CustomStringConvertible` conformance has not returned.
- SwiftPM and CocoaPods continue to model Performance as optional and dependent on the base SDK while keeping Core/SDK free of third-party runtime dependencies. The narrowed packaging strategy is proportionate: real SwiftPM and CocoaPods consumer/resource smoke checks provide packaging evidence, while behavioral and plist-semantic assertions remain in XCTest.

## Validation Performed by This Review

- Focused Performance suite with complete concurrency and warnings as errors: **PASS**, 51 tests, 0 failures.
- Complete distributed-source and test-source graph for arm64 iOS 16 with complete concurrency and warnings as errors: **PASS**.
- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- `./Scripts/verify-english.sh`: **PASS**.
- `git diff --check`: **PASS**.
- `./Scripts/verify-boundaries.sh`: **FAIL**, reproducible Swift compiler crash while isolated parse validation reaches `PerformanceLiveCollector.swift`.
- Direct `ruby Scripts/check-swift-boundaries.rb --sdk-root SDK/Sources/NearWirePerformance`: **FAIL** with the same reproducible compiler crash.

## Verdict

**Implementation architecture and API approval withheld. Exact unresolved actionable finding count: 1 Medium.**
