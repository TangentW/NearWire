# SDK UI Pre-Implementation Security, Performance, and Documentation Review — Round 3

## Result

**Unresolved actionable finding count: 0.**

The Round 3 artifacts close the remaining cross-model Connect-retention gap by moving all unstructured action ownership into one internal main-actor exact-controller coordinator. The proposal, design, capability deltas, tasks, and planned evidence now describe mutually consistent cancellation, input-retention, fail-closed, observer, accessibility, distribution, and no-side-effect boundaries. No production or test implementation has started.

## Round 2 Finding Disposition

### Cross-model Connect predecessor accumulation — resolved

- Connect is admitted only from the exact controller's coordinator `idle` phase. The coordinator, rather than a panel model, owns the sole Connect Task, exact token, controller, and one capped one-shot input argument (`design.md:60-64`; `specs/sdk-ui/spec.md:45-51`).
- Ordinary disappearance cancels the exact owned Connect into shared `Cancelling` without starting Disconnect. The entry survives model teardown, and a recreated panel synchronously receives `Cancelling` before actions become available. Connect B therefore cannot start until Connect A returns and its exact token acknowledges completion (`design.md:56,66,70`; `specs/sdk-ui/spec.md:49-51,68-71`).
- The model owns no action Task, and Connect completion captures no model. Exact coordinator registration plus local generation makes an old result inert while allowing the coordinator to release its exact Task/input resources (`design.md:60-62`; `specs/sdk-ui/spec.md:47-49`).
- The planned adversarial evidence now names the required sequence directly: held Connect A, disappearance, reconstruction, attempted Connect B, live-operation/input probes, and exact completion cleanup (`design.md:98-101`; `tasks.md:17-23`).

## Security and Retention Verification

- Per exact controller, the closed coordinator state machine owns at most one Connect Task and, only during explicit preemption, one additional code-free Disconnect Task. Repeated controls and recreated panels reuse the same entry; there is no panel Task, waiter array, or callback list.
- The sole observer slot is a replaceable weak-model registration. Registration synchronously delivers current phase, replacement does not append, and exact registration identity prevents an old panel's teardown from unregistering the replacement. Task closures never capture a model.
- The visible Cancel action has one closed meaning: it advances model authority, clears local input/error, cancels the exact Connect Task, immediately starts or joins the one Disconnect Task, and remains `Disconnecting` until both exact operations acknowledge. This enforces the maximum of one cancelled Connect predecessor plus one shared Disconnect Task.
- Ordinary disappearance has a distinct closed meaning: observation and model authority are invalidated, the exact observer is unregistered, local input/error clears, and an owned Connect becomes `Cancelling`. It starts no Disconnect and does not automatically end a connection that was already active or committed concurrently.
- If Disconnect deliberately cannot complete at the SDK fail-closed boundary, only the one shared Disconnect Task may remain for the sole process-owned route. That Task captures the controller but no model, pairing code, status, error, view, route data, waiter, or callback. Exact Connect completion independently releases the one-shot input before a code-free fail-closed tail remains.
- Pairing input remains memory-only and scalar-boundary limited to 64 valid UTF-8 bytes. The model and the sole in-flight Connect argument are the only disclosed copies; clearing and release boundaries are explicit, no secure-zeroization claim is made, and no pairing value reaches logs, persistence, reflection, pasteboard APIs, public getters, errors, status, or diagnostics.
- Exact tokens, strong controller retention while an operation entry is live, exact removal after return, weak observer replacement, and the planned `ObjectIdentifier` reuse test form a sufficient identity-safety path. Idle/successful entries must clean up; only the documented fail-closed operation may retain its controller.

## Internal Coordinator and Ownership Boundary

- The formerly ambiguous singleton prohibition is resolved. The capability forbids a global/singleton SDK facade or constructed SDK instance while expressly allowing exactly one internal `@MainActor` process-local operation coordinator under the resource requirement (`specs/sdk-ui/spec.md:3-10,45-51`).
- The coordinator creates no `NearWire` or controller, claims no route or lease directly, changes no SDK lifecycle semantics, and is neither public API nor SPI. Host code continues to construct, configure, retain, suspend/resume, and shut down its injected `NearWire` instance.
- Construction starts no Task, timer, discovery, connection, lease claim, security/storage access, notification, or lifecycle observation. Presentation adds only one bounded latest-value SDK status observation per live model plus one weak coordinator registration.
- The public API remains exactly the injected connection view and value-driven status view. The latter performs no subscription or mutation. SwiftPM/CocoaPods aggregate and delta inventories, SDK-only negative fixtures, and forbidden internal-type consumers remain required.

## Accessibility, Documentation, and Platform Boundaries

- One closed internal accessibility presentation value covers every state, retry, suspension, icon, textual progress, action label/hint, and error. Controls bind those values; status semantics are combined; paused/progress/error meaning is textual and never color-only.
- Evidence remains proportionate and closed: exhaustive presentation-value tests, a source-structure audit of accessibility modifiers/grouping and color independence, plus `ImageRenderer` construction at a large accessibility Dynamic Type size on supported iOS/macOS test platforms.
- The documentation truthfully describes fixed English strings as non-localized, adds no localization resource bundle, and makes no automatic live-region announcement guarantee on iOS 16 or macOS 13.
- Unexpected errors map to one fixed generic sentence. Only the content-safe `NearWireError.message` may be displayed; pairing, endpoint, certificate, Viewer, framework, and application descriptions remain excluded.
- The plan adds no UIKit/AppKit wrapper, Objective-C surface, public Combine API, persistence, Keychain/Security-item access, pasteboard API, camera, analytics, reachability, notification, App lifecycle observer, background execution, runtime dependency, asset, font, bundle, entitlement, or privacy declaration.
- The optional UI remains compatible with iOS 16, macOS 13, Swift 5 language mode, complete concurrency checking, SwiftPM, and the existing CocoaPods UI subspec without changing the SDK-only default.

## Validation Performed

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: PASS — `Change 'sdk-ui' is valid`.
- `git diff --check`: PASS after this report was added.
- Current source inspection confirms NearWireUI still contains only its internal bootstrap marker and one module smoke test; no production or implementation test source was modified before approval.

## Final Verdict

**Ready for implementation from the security, performance, and documentation perspective.** The exact-controller action coordinator, one replaceable weak observer, Connect/input lifetime, Cancel preemption, disappearance-only `Cancelling`, fail-closed code-free Disconnect tail, internal singleton exception, accessibility evidence, and all prior no-side-effect and distribution boundaries are sufficiently specified and testable.
