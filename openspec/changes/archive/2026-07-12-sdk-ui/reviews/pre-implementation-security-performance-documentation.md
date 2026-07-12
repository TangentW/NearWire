# SDK UI Pre-Implementation Security, Performance, and Documentation Review

## Result

**Unresolved actionable finding count: 2** — one High and one Medium.

The change has strong boundaries: it injects rather than constructs `NearWire`, keeps the status view value-only, treats `NearWireError.message` as the only displayable SDK diagnostic, maps unexpected errors to fixed text, adds no automatic connect/disconnect/suspend/resume policy, and explicitly excludes persistence, Keychain, pasteboard APIs, camera, background execution, observers, analytics, resources, entitlements, and dependencies. The current NearWireUI source is still a side-effect-free internal bootstrap marker. The two plan-level issues below must be resolved before implementation.

## Findings

### 1. High — Cancellation is treated as Task termination, making the action/resource and pairing-retention promises mutually unsatisfiable

**Evidence**

- The design says the model owns at most one action Task; Disconnect cancels a pending UI Connect Task and then awaits `nearWire.disconnect()`; disappearance cancels any action and leaves no UI-owned work (`design.md:54-60,74-80`). The capability requires at most one action Task and says no UI-owned Task, input, or error remains after disappearance or release (`specs/sdk-ui/spec.md:17-20,45-47,82-85`).
- The SDK contract deliberately does not equate cancellation with completion. A connect Task may remain alive through non-cancellable identity or pre-admission work and retains the actor while it runs (`openspec/specs/sdk-async-facade/spec.md:8-10,27-30`).
- `disconnect()` ignores caller Task cancellation, returns only after the exact cleanup receipt, and may deliberately never return when terminal evidence cannot be proved (`openspec/specs/sdk-connection-lifecycle/spec.md:57-78`).
- A SwiftUI Button action is synchronous. Preempting a still-running connect therefore requires starting a disconnect Task while the cancelled connect Task may remain live. Replacing or dropping the old handle does not terminate that Task. Likewise, cancelling a disconnect Task on disappearance cannot make its `await disconnect()` finish.
- The UI forwards a bounded raw `String` from model state into the connect Task (`design.md:56-60`; `specs/sdk-ui/spec.md:31-43`). Without an explicit capture/release rule, that cancelled Task may retain an additional raw input copy after the model clears its field on disappearance.
- Tasks 3.2, 4.1, and their planned tests assume one Task, teardown completion, and no cycle/retention but do not define a cancellation-completion handshake, an allowed detached cleanup owner, or a hard bound for cancelled predecessors (`tasks.md:9,15,20`).

**Impact**

The implementation cannot simultaneously preempt connect, await non-cancellable disconnect, promise at most one live UI action Task, and promise that disappearance leaves no UI-started Task. A straightforward `Task { await model... }` also strongly retains the model across an await, preserving input/error and creating a model/Task lifetime cycle until SDK cleanup. If terminal cleanup is fail-closed, repeated view recreation and user disconnect actions can accumulate caller Tasks waiting on the same receipt even though the SDK actor itself stores only one constant-space receipt.

The pairing code is a selector rather than a credential and is capped at 64 bytes, so this is not a secret-exfiltration issue. It is still a direct violation of the stated minimal-retention contract and a potentially unbounded caller-side resource path.

**Recommended change**

Define action ownership in terms of live operations, not stored handles:

- Permit and state the exact hard bound required for preemption, such as one cancelled connect predecessor plus one current disconnect waiter, rather than claiming one live Task.
- Make Task closures capture only the controller, generation, and the minimal one-shot input needed to invoke connect; completion must re-enter the model weakly. Synchronously invalidate generation and clear model input/error on teardown before cancellation.
- Specify that a disconnect waiter is non-cancellable by SDK contract. Either allow one code-free detached cleanup waiter to outlive the view, or keep the model alive until it finishes; do not promise immediate Task disappearance. Prevent another UI model/presentation from starting an unbounded duplicate waiter, or explicitly narrow the resource guarantee to one waiter per live panel and document the host-level limitation.
- Observation and action cancellation must have explicit completion acknowledgement or weak/content-free detached tails before a successor operation is counted as the sole live owner.

Add deterministic tests with held non-cancellable connect and disconnect operations, rapid disappear/reappear, repeated preemption, weak model/controller probes, live Task counts, and a pairing-input lifetime sentinel. Prove the chosen hard bound and that stale completions cannot restore input, error, status, or action authority.

### 2. Medium — Accessibility guarantees have no evidence path beyond presentation-model and body smoke tests

**Evidence**

- The normative status requirement promises Dynamic Type, text plus icon rather than color alone, one combined accessibility label, visible paused state, textual progress, and safe error presentation (`specs/sdk-ui/spec.md:59-71`).
- The design additionally promises explicit control labels and hints, combined status semantics, textual progress announcement, and a live-region-compatible error update where supported (`design.md:62-72`).
- The test strategy covers pure state/icon/text presentation, model behavior, and public-view body evaluation. It does not inspect accessibility labels/hints/element grouping, progress or error announcements, Dynamic Type behavior, or the no-color-only result (`design.md:82-88`).
- Tasks 3.1 through 3.3 similarly require mapping/model/smoke/package tests but name no accessibility or large-content-size evidence. Task 5.3's later audit cannot supply behavioral evidence that was never captured (`tasks.md:12-16,24-28`).

**Impact**

The implementation could omit `.accessibilityElement`, label/hint composition, paused/error wording, or Dynamic Type-safe layout while every planned automated gate passes. Documentation would then overstate accessibility support. The vague “where available” live-region phrase also has no closed platform behavior for iOS 16 and macOS 13.

**Recommended change**

Define one closed accessibility presentation model for every state, retry, suspension, action, and error combination, including exact fixed-English label/hint/progress/error strings. Add pure tests for that model and an implementation/source or UI-accessibility audit proving controls bind those values, status is one combined element, and meaning never depends on color alone. Add at least large accessibility content-size construction/layout evidence on supported platforms without introducing a runtime dependency. State exactly what error announcement behavior exists on iOS 16 and macOS 13; if live-region behavior cannot be guaranteed, document it as a non-guarantee rather than “where available.” Confirm through the resource/API inventory that fixed English strings add no localization bundle and are not claimed to be localized.

## Other Boundary Conclusions

- Bounded scalar-aware input and SDK-only grammar validation are appropriate. System paste through `TextField` is consistent with the oversized-paste scenario; the prohibition should continue to mean no NearWireUI pasteboard API or custom paste action.
- Fixed generic handling for unexpected errors and use of content-safe `NearWireError.message` preserve the SDK's no-echo/no-underlying-description boundary.
- A value-driven `NearWireConnectionStatusView` can remain completely free of subscriptions and connection side effects.
- The controller seam must remain internal and expose only supported status/connect/disconnect behavior. UI code must not import or construct Network, Security, discovery, route, lease, TLS, Keychain, or internal SDK types.
- Cancelling a UI-started pending connect on disappearance is consistent with host ownership; automatically disconnecting an already active route, calling suspend/resume, or shutting down remains forbidden.
- SwiftPM and CocoaPods already have optional NearWireUI product/subspec shells with no third-party dependency. The change needs no new target, product, subspec, resource bundle, entitlement, or privacy declaration.
- Fixed English UI is truthfully identified as non-localized. Future localization or theming remains a separate compatibility change.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS — `Change 'sdk-ui' is valid`.
- `git diff --check`: PASS.

## Final Verdict

**Not ready for implementation.** Resolve the Task cancellation/lifetime contradiction with an enforceable live-operation and pairing-retention model, and add a concrete accessibility evidence path before completing the pre-implementation review gate.
