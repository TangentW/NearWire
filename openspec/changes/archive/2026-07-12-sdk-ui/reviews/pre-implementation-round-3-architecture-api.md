# Pre-Implementation Architecture and API Review — Round 3

## Scope

Re-reviewed the latest proposal, design, both delta specifications, tasks, current NearWire lifecycle/status API, distribution mappings, and prior architecture/API reports after the operation-coordinator redesign. This is report-only; no production, test, specification, or documentation source was modified.

## Prior-Finding Disposition

All Round 1 and Round 2 findings are resolved by the current contracts.

- The conservative public-status action matrix covers disconnected retained-intent and no-intent shapes without exposing private lifecycle ownership (`design.md:70-72`; `specs/sdk-ui/spec.md:73-85`).
- CocoaPods parity is defined as aggregate SwiftPM NearWire plus NearWireUI versus the CocoaPods UI-installed module, with a separate exact UI delta and SDK-only negative fixture (`specs/sdk-public-boundary/spec.md:3-21`).
- The public wrapper keys its state-owning child by `ObjectIdentifier(nearWire)`, making injected-instance replacement explicit and testable (`design.md:41-43,105-108`; `specs/sdk-ui/spec.md:123-130`).
- Models own no unstructured action Task. One internal main-actor per-controller coordinator owns the exact Connect Task, its cancelling phase, and only during visible Cancel/Disconnect preemption one code-free Disconnect Task (`design.md:54-70`; `specs/sdk-ui/spec.md:45-71`). Ordinary disappearance cancels into shared Cancelling without disconnect, while a recreated panel synchronously observes the gate and cannot start Connect B before A acknowledges completion.
- The singleton language now expressly forbids a global SDK facade or constructed instance while permitting only the exact internal operation coordinator (`specs/sdk-ui/spec.md:3-5`). The coordinator creates no controller, keys the injected object, stores no route/status/error, and retains a controller only through its bounded operation Task or the SDK's documented fail-closed noncompletion.

The coordinator is implementable in Swift 5 complete-concurrency mode as an internal `@MainActor` registry. Main-actor model actions can synchronously register/query/request operations; class-bound `Sendable` controllers may be captured by Tasks across async NearWire calls; exact entry and operation tokens can reject stale completion/removal without public API or SPI.

## Finding

### P2 — Medium: One replaceable observer leaves simultaneous panels with stale actionable UI

The coordinator retains exactly one replaceable weak-model observer per controller and delivers phase changes only to that current observer (`design.md:60-70,86-90`; `specs/sdk-ui/spec.md:47-51`). This fully handles disappearance/recreation, which is the tested scenario. The public API, however, does not restrict a host to one simultaneously presented `NearWireConnectionView` for the same instance.

If panel B registers while panel A remains visible, B replaces A's observer. A no longer receives connecting, cancelling, disconnecting, or completion phase changes. It can therefore continue showing stale Connect/Disconnect controls or action error while B owns an operation. Coordinator admission still prevents duplicate Tasks, so lifecycle safety survives, but the supported action/presentation contract is false for A and its controls appear actionable while their requests are rejected or joined invisibly. Exact unregister identity protects B from A's teardown, but does not make A's presentation inert.

Action: define and enforce one policy. To preserve the one-observer bound, synchronously notify the displaced registration that it is superseded before replacement; the displaced model must invalidate local action authority and expose a fixed disabled/unavailable presentation until it becomes the registered panel again or leaves the hierarchy. Alternatively, support multiple live panels through a shared observable phase source or observer set and revise the resource bound. Add a deterministic two-simultaneous-panel test covering registration replacement, operation start, old-panel action attempt, exact unregister, and re-registration. Merely testing sequential recreation does not cover this public composition case.

## Additional Architecture/API Recheck

- Visible Cancel is now the same immediate SDK Disconnect-preemption operation, so Connect cancellation and disconnect precedence share one exact coordinator phase and resource bound.
- Disappearance remains semantically distinct: it cancels only the panel-owned Connect, never starts active disconnect, and preserves a Cancelling gate across recreation.
- Exact Task tokens, coordinator phase, observer registration, and model action/observation generations have separate ownership responsibilities; stale work cannot authorize another route or mutate a replacement model.
- Public view signatures remain limited to SwiftUI and supported NearWire facade types. Internal controller, coordinator, identity, model, presentation, Task, and token values remain hideable in both distribution modes.
- iOS 16, macOS 13, Swift 5 language mode, native accessibility presentation, test-only internal status fixtures, and the optional CocoaPods/SwiftPM module layouts remain feasible without new runtime dependencies or lifecycle API changes.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.
- `git diff --check`: passed.

## Verdict

**Changes required. Unresolved actionable findings: 1 medium. Pre-implementation architecture/API approval remains withheld until simultaneous panels have an explicit coherent observer/presentation policy.**
