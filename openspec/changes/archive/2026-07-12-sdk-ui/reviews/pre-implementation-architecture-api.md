# Pre-Implementation Architecture and API Review

## Scope

Reviewed `proposal.md`, `design.md`, both delta specifications, `tasks.md`, the current supported connection-lifecycle and public-boundary specifications, the public `NearWire` lifecycle/status API, root Swift Package and podspec mappings, and the existing NearWireUI bootstrap shell. This is report-only; no production, test, specification, or documentation source was modified.

The two-type public surface is appropriately narrow, injected-instance ownership is directionally sound, and native SwiftUI implementation is feasible in Swift 5 language mode for iOS 16 and macOS 13. Four architecture/API decisions must be resolved before implementation.

## Findings

### P1 — High: The panel cannot distinguish a disconnected retained intent from a disconnected reusable instance

The proposed action matrix shows Connect for every idle/disconnected state and Disconnect only for attempt, recovery, active, or suspended work (`design.md:45-50`; `specs/sdk-ui/spec.md:45-57`). The supported lifecycle deliberately has a different ownership case: with the default-disabled recovery policy, an active transient failure publishes `disconnected` while retaining the active intent for only explicit resume or disconnect (`openspec/specs/sdk-connection-lifecycle/spec.md:6-15,129-135`). A permanent failure or exhausted campaign can publish the same state/error-shaped status after clearing intent. `NearWireConnectionStatus` exposes state, last error, retry attempt, and suspension only; it exposes no intent/can-connect capability (`SDK/Sources/NearWire/NearWirePublicModels.swift:209-237`).

Consequently the UI cannot implement its promised state-only action choice. In the default-policy retained-intent case it will ask for a new code and invoke `connect(code:)`, which must reject with `connectionIntentExists`; because resume control is explicitly out of scope and Disconnect is not offered for this row, the drop-in panel cannot recover without host UI outside the component. Inferring intent from public error codes is not reliable because the same safe error can arise on a permanent pre-active path with no retained intent.

Action: define a complete, testable action matrix for disconnected ownership without silently adding lifecycle policy. Within the current public SDK surface, the narrow option is to make an explicit Disconnect/reset action available for disconnected error states (possibly alongside retry Connect) and document the user-driven disconnect-then-connect flow. If the product instead requires a single context-perfect action, explicitly broaden the lifecycle status API with a reviewed supported capability value and update this change's impact/public-boundary deltas. Add a default-disabled active-transient scenario proving the panel never enters an unrecoverable Connect/`connectionIntentExists` loop.

### P1 — High: “One live action Task” and immediate disconnect preemption lack a realizable ownership contract

The model is required to own at most one action Task, while Disconnect must cancel a still-pending Connect Task and independently await async `disconnect()` (`design.md:54-60,74-80`; `specs/sdk-ui/spec.md:45-57`; `tasks.md:8-10,18-22`). A normal SwiftUI button action is synchronous. If the model cancels the connect Task and replaces its stored handle with a new disconnect Task, the cancelled predecessor can remain live until SDK cleanup acknowledges cancellation, so two UI-owned Tasks exist despite only one stored handle. If the same cancelled Task waits for `connect` to return before invoking disconnect, user disconnect no longer reaches the SDK while connect is pending and does not exercise the specified disconnect-over-caller-cancellation precedence.

Action: choose and specify the exact handoff. The architecture-consistent option is a constant bound of one current disconnect Task plus at most one cancelled connect predecessor, with the disconnect Task retaining and awaiting that exact predecessor as part of completion; generation still makes the predecessor's UI completion inert. Alternatively, explicitly specify a same-Task state machine and accept that SDK disconnect begins only after connect cancellation completes. Align the resource requirement, disappearance behavior, model ownership, and tests with the chosen bound; do not claim one live Task while implementing handle replacement.

### P2 — Medium: The CocoaPods UI inventory scenario is impossible as written

SwiftPM exposes `NearWire` and `NearWireUI` as separate modules/products (`Package.swift:11-19,49-65`), whereas the CocoaPods UI subspec depends on SDK and compiles both source sets into the single `NearWire` module (`NearWire.podspec:4-5,41-50`; `design.md:68-72`). The modified boundary scenario nevertheless requires the CocoaPods UI subspec inventory itself to contain only the two UI view types and their signatures (`specs/sdk-public-boundary/spec.md:7-10`). That module necessarily also contains every supported SDK facade declaration, so it cannot match the literal NearWireUI-only inventory.

Action: define parity at the correct granularity: compare the CocoaPods UI-installed aggregate module with the aggregate SwiftPM `NearWire` plus `NearWireUI` supported inventories, and separately allowlist the UI-added declaration delta as exactly the two view types. Require an SDK-only CocoaPods fixture that cannot name the views and a UI-subspec fixture that can, plus forbidden internal controller/model fixtures. Clarify how the existing pod test spec obtains the UI subspec without changing the default runtime subspec.

### P2 — Medium: `@StateObject` pins the first injected instance, but replacement semantics are unspecified

The public contract says each `NearWireConnectionView(nearWire:)` retains the exact injected instance (`specs/sdk-ui/spec.md:3-10`), while the design initializes its internal model through `@StateObject` in the public view initializer (`design.md:41-43,90-93`). SwiftUI preserves a StateObject by structural view identity and can discard later wrapper initial values. If a host replaces `NearWireConnectionView(nearWire: old)` with `NearWireConnectionView(nearWire: new)` at the same identity, the displayed model can continue observing and controlling `old`, contrary to the apparent injection contract and host lifetime ownership.

Action: specify one supported rule. Either make the injected instance identity-stable for the lifetime of the SwiftUI view identity and document/test that replacement requires a new `.id`, or structure the public wrapper so `ObjectIdentifier(nearWire)` resets an internal state-owning child and tears down observation/action work for the old instance. Include a deterministic replacement test; construction of a second value alone is not sufficient to prove displayed ownership.

## Other Architecture/API Checks

- The exact public view signatures expose only SwiftUI and supported NearWire facade values; no public controller or view model is required.
- An internal `Sendable` controller seam can model the actor's nonisolated status stream plus async connect/disconnect operations without exposing SPI.
- An internal status-presentation value can make every state/retry/suspension mapping testable even though `NearWireConnectionStatus` has no public initializer.
- The existing platform declarations, Swift 5 language mode, optional package product, UI pod subspec, conditional package-only self-import, Dynamic Type, semantic styling, SF Symbols, and availability-gated accessibility behavior are feasible without a new target, resource bundle, or runtime dependency.
- Construction side-effect freedom, bounded UTF-8 input, safe error projection, observation teardown, and no automatic active disconnect are implementable once the ownership decisions above are fixed.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-ui --strict --no-interactive`: passed.
- `git diff --check`: passed.

## Verdict

**Changes required. Unresolved actionable findings: 4 (2 high, 2 medium). Pre-implementation architecture/API approval is withheld until the lifecycle action matrix, async handoff bound, CocoaPods parity gate, and injected-instance identity semantics are explicit and testable.**
