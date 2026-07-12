# Pre-Implementation Architecture and API Review — Round 4

## Scope

Re-reviewed the latest proposal, design, both delta specifications, tasks, current NearWire lifecycle/status API, distribution mappings, and all prior architecture/API reports after the phase-subscription redesign. This is report-only; no production, test, specification, or documentation source was modified.

## Prior-Finding Disposition

All prior architecture/API findings are resolved.

- Disconnected retained-intent and no-intent states use a conservative public-status action matrix with explicit optional reset, without exposing or inferring private lifecycle intent (`design.md:70-72`; `specs/sdk-ui/spec.md:83-95`).
- Connect cancellation and immediate visible Disconnect preemption are owned by one exact-controller main-actor coordinator with closed idle/connecting/cancelling/disconnecting phases and an explicit bound of one Connect plus at most one preempting Disconnect Task (`design.md:54-68`; `specs/sdk-ui/spec.md:45-81`).
- Ordinary disappearance cancels only the originating UI Connect into shared Cancelling, starts no active disconnect, and prevents a recreated panel from admitting Connect B before A acknowledges completion (`design.md:66`; `specs/sdk-ui/spec.md:68-71`).
- The internal coordinator is expressly carved out from the ban on a global SDK facade. It creates no controller or NearWire instance, exposes no API/SPI, and owns only exact injected-controller operations (`specs/sdk-ui/spec.md:3-5,45-51`).
- CocoaPods parity uses the correct aggregate-plus-UI-delta model, with separate SDK-only negative coverage (`specs/sdk-public-boundary/spec.md:3-21`).
- `ObjectIdentifier(nearWire)` keys the state-owning child, so replacing the injected instance resets model ownership and makes stale old-controller work inert (`design.md:41-43,105-108`; `specs/sdk-ui/spec.md:133-140`).
- Simultaneously visible panels now receive the same coordinator phase through independent `AsyncStream` subscriptions with `bufferingNewest(1)` instead of competing for one observer slot (`design.md:60-70`; `specs/sdk-ui/spec.md:47-49,73-76`).

## Architecture/API Recheck

No actionable finding remains.

### Simultaneous panels and subscription ownership

Each live panel owns one structured coordinator-phase subscription, receives the current phase immediately, and retains only the newest pending phase. The coordinator serializes operations independently of subscriber speed, so a slow panel may coalesce intermediate values but cannot expose a stale final gate or admit duplicate work. Termination removes only the exact continuation, making concurrent panel teardown and rapid disappearance/reappearance safe (`design.md:56,60-70,86-90`; `specs/sdk-ui/spec.md:17-29,47-51`).

The subscriber collection is proportional only to currently presented panels and is not a cleanup-completion waiter list. One separate weak origin-completion belongs to the exact Connect token and delivers safe action success/failure only to the initiating model when its subscription/generation remains current; it is neither broadcast nor a strong model cycle.

### Entry cleanup and identity reuse

An entry remains only while non-idle work or live phase subscribers exist. Exact subscriber removal plus removal of an idle zero-subscriber entry ensures an old `ObjectIdentifier` cannot retain stale phase, observer, controller, Task, input, or completion authority for a later object reuse (`design.md:68-70,86-90`; `specs/sdk-ui/spec.md:47-51`; `tasks.md:21-25`). Non-idle Tasks themselves retain the exact controller until their reviewed completion or fail-closed boundary, so identity cannot be reused while work remains authorized.

### Completion-order totality

Visible Cancel is Disconnect preemption. The coordinator tracks the cancelled Connect token and Disconnect token independently and remains Disconnecting until both acknowledge. The specification and tasks cover both asymmetric orders—Connect first and Disconnect first—so neither completion can clear the gate, remove the entry, or admit a successor early (`design.md:64-68`; `specs/sdk-ui/spec.md:58-81`; `tasks.md:13-19`). A disconnect started without a Connect predecessor is the same phase with only its applicable acknowledgement.

### Implementability and supported API

The design is implementable in Swift 5 complete-concurrency mode with an internal `@MainActor` coordinator, class-bound `Sendable` controller existential, exact object/token keys, `AsyncStream` newest-one phase hubs, and weak main-actor origin completion. Model and coordinator isolation do not require a public controller, model, Task, binding, status initializer, or Combine publisher.

The supported surface remains exactly the two SwiftUI view types and their initializers. SwiftPM's separate NearWireUI module and CocoaPods' aggregate NearWire module can expose equivalent supported declarations while the SDK-only default remains UI-free. The implementation remains feasible for iOS 16 and macOS 13 with native SwiftUI, Dynamic Type, SF Symbols, fixed accessible text, and no new resource bundle, runtime dependency, persistence, lifecycle observer, or SDK semantic change.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.
- `git diff --check`: passed.

## Verdict

**Unresolved actionable findings: 0. Approved for implementation from the architecture/API perspective.**
