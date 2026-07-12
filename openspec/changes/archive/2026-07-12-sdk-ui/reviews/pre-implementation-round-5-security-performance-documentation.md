# SDK UI Pre-Implementation Security, Performance, and Documentation Review — Round 5

## Result

**Unresolved actionable finding count: 0.**

The atomic initial-phase handoff closes the first-render race without adding a bootstrap Task, second stream, extra continuation, callback list, or new long-lived controller/model edge. The synchronous tuple is a bounded presentation-time registration result, and all action, input, subscriber, fail-closed, accessibility, public API, and distribution limits remain unchanged and testable.

## Atomic Handoff Verification

- Coordinator registration is one synchronous `@MainActor` operation returning exactly `(initialPhase, stream, registrationToken)`. Reading the current phase and installing the exact later-value subscription share one serialized boundary, so no coordinator transition can be lost between snapshot and registration (`design.md:60-62,70`; `specs/sdk-ui/spec.md:45-49`).
- The model applies the small internal `initialPhase` value synchronously before it exposes actions or reaches an `await`. A panel presented during connecting, cancelling, or disconnecting therefore renders the current gate immediately rather than temporarily exposing stale Connect.
- Only changes after registration enter the paired `AsyncStream`. If a phase changes after the tuple returns but before asynchronous iteration starts, `bufferingNewest(1)` retains that newest later value; there is no initial-value duplicate or first-yield dependency.
- The handoff starts no Task. `AsyncStream` registration itself is synchronous; the model still owns only the one previously specified structured phase-consumer operation. There is no bootstrap, snapshot, forwarding, polling, timer, or per-registration cleanup Task in the contract.
- Per live model, the additional retained values are limited to one phase value, one exact registration token, and the one stream already counted by the phase-subscription boundary. The coordinator still retains one exact continuation per live panel and no model through this handoff.
- The evidence plan now explicitly asserts initial phase and resulting action presentation synchronously before any executor yield, then verifies later streamed transitions and ordinary exact teardown (`design.md:96-99`; `tasks.md:9-18`). This distinguishes the atomic contract from eventual first-yield behavior.

## Subscriber and Entry-Lifetime Recheck

- Each presented model owns exactly one SDK-status observation and one coordinator-phase observation. Every phase stream uses `bufferingNewest(1)`, so a slow panel retains no more than one pending phase.
- Explicit unregister and stream termination are keyed by the same exact registration identity. Either cleanup path may safely encounter an already-removed token, while neither can remove a replacement or another simultaneously presented panel's continuation.
- Repeated presentation, disappearance, subscription cancellation, and model release must leave no terminated continuation. The subscriber and weak-probe tasks remain explicit evidence against accumulation.
- An idle entry is removed only when its exact subscriber count reaches zero. A non-idle entry survives zero subscribers until its exact operation completes; successful completion then permits removal, while fail-closed work remains intentionally retained.
- The atomic tuple adds no second subscriber count, hidden initial continuation, or initial-phase buffer. Strong controller lifetime during an active entry or live registration, exact removal, and reuse tests continue to close the `ObjectIdentifier` ABA boundary.

## Action, Input, and Fail-Closed Recheck

- Per exact controller, the coordinator owns at most one Connect Task and, only during explicit preemption, one additional code-free Disconnect Task. The model owns no unstructured action Task, and every panel shares the same coordinator admission gate.
- Connect remains admissible only from idle. Atomic initial phase now aligns first-render presentation with that gate; repeated panels/actions still cannot create duplicate Connect or Disconnect work.
- One weak origin-completion closure belongs only to the exact Connect token. It is not broadcast, does not strongly retain a model, and is accepted only under the origin model's current registration/action generation.
- Cancel remains exact Disconnect preemption: one Connect cancellation plus one shared Disconnect, with Disconnecting retained through both asymmetric acknowledgement orders. Ordinary disappearance still cancels only an owned Connect into Cancelling and never automatically disconnects an active or concurrently committed route.
- Pairing input remains at most 64 valid UTF-8 bytes per model plus the sole in-flight bounded Connect argument. Initial phase and registration token contain no pairing value. No pairing content is persisted, logged, reflected, copied through pasteboard APIs, exposed by API/status/error/diagnostic, or claimed to be securely zeroized.
- If SDK cleanup deliberately cannot complete, only the shared code-free Disconnect Task and exact active entry may remain for the sole process-owned route. Phase subscribers can terminate independently, and the atomic handoff adds no fail-closed waiter, callback, continuation, model, input, error, or view retention.

## Security, Accessibility, and Distribution Boundaries

- The one internal `@MainActor` process-local coordinator remains the sole explicit singleton exception. It is not a global SDK facade, creates no controller or `NearWire`, exposes no API/SPI, claims no route/lease directly, and does not change SDK lifecycle semantics.
- View construction remains side-effect free. Atomic registration occurs only at presentation and starts no discovery, connection, security/storage access, notification, lifecycle observation, background execution, or timer.
- The public surface remains exactly the injected `NearWireConnectionView` and value-driven `NearWireConnectionStatusView`; the status-only view still subscribes to nothing and mutates nothing. Internal phase, stream registration, coordinator, model, controller, token, and Task types remain inaccessible.
- Error handling remains content-safe: `NearWireError.message` is the only permitted SDK text, while unexpected errors map to a fixed sentence without pairing, endpoint, certificate, Viewer, framework, or application descriptions.
- The closed accessibility presentation, exact fixed-English labels/hints, text-plus-icon status, combined semantics, textual progress/paused state, semantic colors, and Dynamic Type guarantees are unchanged. Exhaustive presentation tests, source-structure audit, and large-size `ImageRenderer` evidence remain required; no live-region or localization guarantee is introduced.
- No persistence, Keychain/Security item, pasteboard API, camera, analytics, reachability, notification, App lifecycle observer, UIKit/AppKit wrapper, Objective-C surface, public Combine API, background execution, runtime dependency, asset, font, resource bundle, entitlement, privacy declaration, product, target, or pod subspec is added.
- SwiftPM and CocoaPods aggregate/delta/negative fixtures still enforce equivalent supported UI API while preserving the SDK-only CocoaPods default. iOS 16, macOS 13, Swift 5 language mode, complete concurrency, and warnings-as-errors remain required gates.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS — `Change 'sdk-ui' is valid`.
- `git diff --check`: PASS after this report was added.
- Current source inspection confirms NearWireUI still contains only its internal bootstrap marker and one module smoke test; no production or implementation test source was modified before approval.

## Final Verdict

**Ready for implementation from the security, performance, and documentation perspective.** The atomic initial-phase handoff removes the stale-first-render window with no hidden Task or unbounded retention, and every previously approved subscription, action, input, fail-closed, accessibility, no-side-effect, API, and distribution boundary remains closed.
