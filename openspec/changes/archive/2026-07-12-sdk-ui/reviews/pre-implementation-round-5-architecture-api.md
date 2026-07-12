# Pre-Implementation Architecture and API Review — Round 5

## Scope

Performed a final pre-implementation review of the latest proposal, design, both delta specifications, tasks, current NearWire lifecycle/status API, distribution mappings, and all prior architecture/API reports after the atomic phase-subscription handoff remediation. This is report-only; no production, test, specification, or documentation source was modified.

## Atomic Subscription Handoff

The coordinator subscription contract now closes the initial-render race.

- Registration is one synchronous main-actor operation that returns an atomic `(initialPhase, stream, registrationToken)` tuple (`design.md:60-62`; `specs/sdk-ui/spec.md:45-49`). No coordinator operation can interleave between capturing the phase and installing the exact continuation.
- The model must apply `initialPhase` before exposing actions or awaiting the stream. A panel appearing during Cancelling or Disconnecting therefore renders the disabled gate on its first action presentation rather than briefly exposing Connect (`design.md:62,70`; `specs/sdk-ui/spec.md:78-81`).
- The paired `AsyncStream` carries later phase changes only and uses `bufferingNewest(1)`. If a phase changes before asynchronous consumption begins, the newest pending value remains available; there is no snapshot-to-stream gap and no duplicate initial value requirement.
- Exact registration identity governs both explicit unregister and termination cleanup. A stale termination cannot remove a continuation or idle entry belonging to a later registration, including after `ObjectIdentifier` reuse (`specs/sdk-ui/spec.md:49`; `tasks.md:21-25`).

## Full Architecture/API Recheck

No actionable finding remains.

### Concurrent panels and bounded ownership

Every live panel receives the same current gate through its own newest-one phase subscription, while the main-actor coordinator remains the sole admission point for Connect, Cancel/Disconnect, and successor work. Subscriber storage is bounded by currently presented panels; termination removes the exact continuation, and repeated disappear/reappear cannot accumulate terminated subscribers (`design.md:62,70,86-99`; `specs/sdk-ui/spec.md:49,68-81`).

Models own no action Task. Per exact controller, the coordinator owns at most one Connect Task, one bounded input copy, one weak origin completion, and—only during explicit preemption—one code-free Disconnect Task. Origin success/failure is not broadcast and cannot form a model cycle. Ordinary disappearance starts no Disconnect and holds the entry in Cancelling only until the exact Connect acknowledges cancellation.

### Completion ordering and entry lifetime

The cancelled Connect and Disconnect use independent exact tokens. During preemption the phase remains Disconnecting whether Connect finishes first or Disconnect finishes first, and returns to idle only after both acknowledgements (`design.md:64-68`; `specs/sdk-ui/spec.md:58-86`; `tasks.md:13-19`). Thus no completion can clear the action gate, remove the entry, or admit a successor early.

An entry is removed only when idle and its exact phase-subscriber count is zero. Non-idle Tasks retain the exact controller; live subscribers are owned by models that retain that controller. Once both sources are absent, entry removal prevents stale phase, continuation, token, input, completion, or controller authority from surviving into an `ObjectIdentifier` reuse (`design.md:68-70`; `specs/sdk-ui/spec.md:47-51`; `tasks.md:21-25`).

### Earlier findings and supported scope

- The conservative action matrix covers default-disabled retained intent and permanent no-intent terminal presentation without exposing lifecycle intent.
- Visible Cancel is immediate Disconnect preemption; disappearance-only cancellation remains distinct and safe across recreation.
- Simultaneous panels are coherent; the prior single-observer replacement problem is eliminated.
- The internal coordinator carveout creates no SDK instance or facade and remains an implementation-only action registry.
- The injected-instance child is keyed by `ObjectIdentifier(nearWire)`, so in-place replacement resets model ownership.
- CocoaPods parity uses aggregate-plus-UI-delta comparison and retains an SDK-only negative fixture.
- The public surface remains exactly two SwiftUI view types using supported NearWire values. The design remains feasible in Swift 5 complete-concurrency mode for iOS 16 and macOS 13 without public implementation types, third-party dependencies, resource bundles, persistence, lifecycle observers, or SDK semantic changes.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.
- `git diff --check`: passed.

## Verdict

**Unresolved actionable findings: 0. Approved for implementation from the architecture/API perspective.**
