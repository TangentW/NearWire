# Implementation Architecture and API Review — Round 3

## Scope

Independently reviewed the active `sdk-ui` proposal, design, delta specifications, tasks, all NearWireUI production sources, focused tests and consumer fixtures, root SwiftPM and CocoaPods mappings, public-boundary scripts, UI/API/distribution documentation, Round 2 reports, remediation evidence, and the current requirement-to-evidence audits. The review traced injected-instance identity, model and coordinator lifetime, action admission and completion, subscriber ownership, lock boundaries, supported API exposure, and distribution compatibility. This review changed no production, test, specification, task, or documentation source.

## Verified Architecture and API Properties

- The supported source surface is currently exactly the two specified public SwiftUI structs, their injected/value initializers, and their `body` properties. Controller, model, child view, coordinator, tokens, presentation values, and input limiter remain internal and non-SPI.
- `NearWireConnectionView` retains the injected actor and keys the state-owning child by `ObjectIdentifier(nearWire)`. The distinct-controller replacement tests prove that old status, phase, and completion delivery cannot mutate the replacement model and that subsequent actions target only the new controller.
- Construction starts no Task or SDK action. Presentation owns one status observation and one bounded coordinator-phase registration. Teardown synchronously invalidates model authority, removes the exact registration, cancels only an exact UI-owned Connect, and does not disconnect an already active host-owned session.
- Connect and Disconnect admission is main-actor serialized. Per-controller storage is lock-protected, exact-token completion prevents stale removal, and task cancellation, continuation yield/finish, and origin completion occur after unlocking. No actionable lifecycle, identity-reuse, reentrancy, or operation-bound defect was found.
- SwiftPM keeps NearWireUI optional and CocoaPods keeps `SDK` as the default subspec. No additional product, target, subspec, runtime dependency, resource bundle, or public implementation type was introduced.

## Finding

### P2 — Medium: The exact API gate is coupled to one compiler's synthesized ABI metadata and is not compatible with the declared Xcode range

**Confidence: 10/10**

The Round 2 remediation correctly added an explicit declaration-tree check, but it now requires every view, initializer, and body declaration to have exactly `Custom` and `Preconcurrency` digester attributes and requires every view to have exactly the synthesized conformances `Copyable`, `Escapable`, `Sendable`, `SendableMetatype`, and `View` (`Scripts/verify-package.sh:616-633`). `Custom`, `Preconcurrency`, and the marker conformances other than the source-declared `View` conformance are compiler/SDK-generated digester details, not the supported NearWireUI source contract. Their presence and spelling can vary across Swift compiler and SwiftUI SDK releases without any source or consumer API change.

This repository declares Xcode 16 or later support (`AGENTS.md`; `Documentation/SDK-Distribution.md:3-10`; `README.md:45-52`), but the recorded gate was run only with Xcode 26.6 and Swift 6.3.3 (`openspec/changes/sdk-ui/evidence/run-identity.md:5-6`). Therefore the current script can reject an otherwise valid build on an older supported Xcode or a later compiler merely because its synthesized marker inventory differs. This makes the required package validation itself narrower than the declared compatibility range and turns compiler evolution into a false public-API break.

The checked-in source API is correct; the defect is in the completion gate and its claim of portable exactness.

**Required remediation:** validate the source-authored semantic contract rather than a fixed compiler-generated marker list. Require the two structs, their exact initializer parameter types, `body` getter/result shape, and source-declared `View` conformance; reject any source-authored extra member, extension, conformance, attribute, or public/SPI declaration. For digester output, compare SwiftPM and CocoaPods under the same toolchain while ignoring or normalizing toolchain-synthesized attributes and marker conformances, or derive the permitted synthesized baseline from a same-toolchain control SwiftUI view. Keep the current attributed-member and extra-conformance mutation probes, and add a fixture proving that harmless synthesized-marker variation does not fail the semantic schema.

## Validation Performed

- Strict focused NearWireUI suite with complete concurrency checking and warnings as errors: passed, 39 tests, 0 failures.
- `ruby Scripts/check-sdk-ui-structure.rb --self-test`: passed, including the current public-surface mutations.
- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.
- `git diff --check`: passed.
- Local toolchain inventory confirmed that only Xcode 26.6 / Swift 6.3.3 is installed, matching the run-identity evidence and leaving the declared Xcode 16 floor unexercised.

## Verdict

**Changes required. Unresolved actionable findings: 1 medium.** The implementation's current architecture, lifecycle, identity handling, and public source surface are sound, but architecture/API approval remains withheld until the API gate stops treating one toolchain's synthesized ABI metadata as the cross-toolchain supported contract.
