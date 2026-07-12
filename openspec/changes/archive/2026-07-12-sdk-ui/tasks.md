## 1. Change Gate

- [x] 1.1 Validate proposal, design, delta specs, and tasks in strict mode before production or test source changes.
- [x] 1.2 Obtain independent pre-implementation architecture/API, correctness/testing, and security/performance/documentation reviews; record and resolve every actionable finding.

## 2. Public UI and Internal Model

- [x] 2.1 Replace the bootstrap marker with the exact public `NearWireConnectionView` and `NearWireConnectionStatusView` surface without adding another product, target, pod subspec, or public implementation type.
- [x] 2.2 Add the internal class-bound controller seam, identity-keyed state child, and `@MainActor` observable model with bounded code input, SDK-status/coordinator-phase observation generations, conservative action matrix, and teardown invalidation.
- [x] 2.3 Add the internal main-actor exact-controller operation coordinator with idle/connecting/cancelling/disconnecting phases, one Connect Task, at most one preempting code-free Disconnect Task, atomic synchronous initial-phase plus bounded later-value stream registrations, one exact weak origin completion, exact completion/removal, no cleanup waiter/callback list, and fail-closed noncompletion semantics.
- [x] 2.4 Implement complete state/icon/text/retry/suspension/action/error accessibility presentation with native semantic SwiftUI layout, Dynamic Type, keyboard submission, and no live-region guarantee.

## 3. Correctness and Boundary Tests

- [x] 3.1 Add pure status/action/accessibility presentation tests for every state, retry, suspension, ownership error, winner order, fixed label/hint/icon/progress/error value, and safe generic error.
- [x] 3.2 Add scalar-prefix UTF-8 tests at 63/64/65 ASCII bytes, exact/short 2-4 byte scalars, decomposed combining scalars, and joined emoji; assert exact retained/forwarded bytes and absent suffix.
- [x] 3.3 Add deterministic fake-controller tests for construction freedom, synchronous initial phase before first action presentation, immediate latest SDK status, host/UI-owned pre-discovery, disabled transient/permanent/exhausted terminal shapes, exact connect, double activation, Cancel-as-Disconnect preemption, disappearance-only Cancelling, shared operation deduplication, simultaneous panel coherence, fail-closed hold, stale action/status completion, repeated subscribe/cancel, replacement identity, and no automatic active disconnect.
- [x] 3.4 Add asymmetric barriers where Connect completes first and Disconnect completes first, proving Disconnecting remains until both exact acknowledgements; add weak-model/controller, live-operation, subscriber, and pairing-input probes proving `Connect A -> disappear -> recreate -> Connect B` cannot start B before A completes and no model cycle, duplicate Task, cleanup waiter, origin callback, or terminated subscriber accumulates.
- [x] 3.5 Add SwiftUI public-view smoke tests, large-accessibility-Dynamic-Type `ImageRenderer` evidence, accessibility source-structure audit, direct NearWire test dependency for internal fixtures, and SwiftPM/CocoaPods aggregate/delta/forbidden public API fixtures.

## 4. Resource and Platform Boundaries

- [x] 4.1 Prove one SDK-status plus one one-value coordinator-phase subscription per live model and one coordinator entry per controller with at most one Connect plus one preempting Disconnect Task and one weak origin completion; prove exact subscriber removal, generation/token invalidation, no model cycle or cleanup list, bounded input/error retention, deduplication, ObjectIdentifier reuse safety, and cleanup after return.
- [x] 4.2 Prove no persistence, Keychain, pasteboard, camera, analytics, lifecycle observer, notification, reachability, background execution, resource bundle, asset, font, entitlement, privacy declaration, or runtime dependency was added.
- [x] 4.3 Compile NearWireUI for iOS 16 and macOS 13 in Swift 5 language mode under complete concurrency checking and warnings as errors through SwiftPM and CocoaPods UI integration.

## 5. Documentation and Evidence

- [x] 5.1 Update English README, SDK UI/API, distribution, and roadmap documentation with injection, ownership, action, teardown, accessibility, localization, and non-goal guarantees.
- [x] 5.2 Run focused UI tests, full Core/SDK/UI suites, formatting, diff, version, public-boundary, package, podspec, and strict OpenSpec gates; save exact results and tool versions under `evidence`.
- [x] 5.3 Record requirement-to-evidence, public API inventory, resource/retention, and spec-to-evidence audits.

## 6. Independent Completion Review

- [x] 6.1 Obtain independent architecture/API, correctness/testing, and security/performance/documentation implementation reviews and save each report.
- [x] 6.2 Fix every actionable finding, rerun affected validation, and obtain a fresh zero-finding review round across all three dimensions.
- [x] 6.3 Validate all OpenSpec specs strictly, archive `sdk-ui`, verify archived evidence, and commit the isolated completed change before starting `sdk-performance`.
