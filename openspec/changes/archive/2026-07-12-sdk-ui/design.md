## Context

`NearWireUI` is already an optional SwiftPM product and CocoaPods subspec. The supported SDK facade now provides an injected actor instance, current connection status, a latest-value status stream, explicit connect, and async disconnect. The UI layer must compose only those supported APIs while remaining optional and visually native on iOS 16 and macOS 13.

The host application remains the owner of `NearWire` construction, configuration, lifetime, suspension/resumption policy, and active-session shutdown. The UI owns only displayed input, one status observation per live model, and bounded coordinator operations created by explicit user action.

## Goals and Non-Goals

### Goals

- Provide a useful drop-in connection panel and a separately composable status view.
- Preserve exact SDK lifecycle and error semantics rather than reimplementing connection policy.
- Keep view-local state bounded, cancellation-safe, and free of persistence.
- Compile in Swift 5 language mode with complete concurrency checking.
- Use standard SwiftUI behavior that adapts to Dynamic Type, light/dark mode, and accessibility without custom assets.

### Non-Goals

- No UIKit wrapper, Objective-C API, Combine publisher as supported API, or public view model.
- No automatic connect, retry policy, suspend/resume control, lifecycle observer, navigation container, toast/alert presenter, or active disconnect on ordinary view disappearance.
- No custom theming API, localization resource bundle, analytics, clipboard action, QR scanner, history, code generator, or performance dashboard.

## Public API

The supported surface is intentionally two types:

```swift
public struct NearWireConnectionView: View {
  public init(nearWire: NearWire)
  public var body: some View { get }
}

public struct NearWireConnectionStatusView: View {
  public init(status: NearWireConnectionStatus)
  public var body: some View { get }
}
```

No public binding exposes the pairing code, action Task, error source, controller protocol, or mutable connection state. Applications needing custom behavior use the `NearWire` SDK directly and may embed `NearWireConnectionStatusView` with their own latest snapshot.

## Internal Composition

`NearWireConnectionView` is a public stateless wrapper whose body keys one internal state-owning child by `ObjectIdentifier(nearWire)`. The child creates one internal `@MainActor` observable model around an internal class-bound `Sendable` controller protocol. Replacing the injected instance at the same outer SwiftUI identity therefore tears down the old child and constructs a child for the new exact instance without requiring host `.id` choreography. `NearWire` conforms inside the UI module; tests inject a deterministic fake. The protocol, identity key, child, and model are not public or SPI.

The visible hierarchy is a system-native vertical group:

1. A labeled pairing-code `TextField` with character capitalization and autocorrection disabled.
2. `NearWireConnectionStatusView`, which presents an SF Symbol and textual state.
3. A conservative supported action set: Connect for reusable idle/disconnected presentation, Disconnect for progress/active/suspended presentation, Cancel while the coordinator owns the panel's Connect Task, disabled Cancelling/Disconnecting while acknowledgement is pending, and a secondary Disconnect/reset beside Connect for disconnected error presentation or after an ownership preflight error.
4. A fixed safe inline error region when either the latest status or the current UI action provides an error.

The component does not impose `NavigationStack`, `Form`, sheet, alert, fixed width, or screen background ownership. This keeps it embeddable inside the host App's layout.

## State and Action Model

Construction retains the injected `NearWire` reference and allocates bounded local state only. Presentation starts one structured status-observation operation under an exact observation generation. The stream immediately yields its current latest value and retains only one pending value in the SDK hub. Every update after `await` must re-enter the model weakly and match the current observation or action generation. Leaving the hierarchy synchronously advances both generations, unregisters its exact coordinator observer, cancels observation, asks the coordinator to cancel any still-owned Connect, clears model input/error, and does not automatically disconnect an already active session.

Pairing input retains at most 64 valid UTF-8 bytes and is not canonicalized by the UI. The SDK remains the single grammar authority. The panel disables Connect for empty input, forwards the bounded raw value only after explicit activation, and clears it after success. A failed attempt may retain the bounded input so the user can correct it while the view remains present.

The model owns no unstructured action Task. It has one monotonically advancing local action generation and one structured subscription to an internal `@MainActor` process-local operation coordinator. The coordinator is keyed by class-bound controller object identity. Its per-controller entry is a closed state machine: idle; connecting with one exact token, one Task, one bounded input copy, and controller; cancelling with that same cancelled Task until exact completion acknowledgement; or disconnecting with at most that cancelled Connect predecessor plus one code-free Disconnect Task. It creates no controller or SDK instance. Each phase transition also advances an internal revision. Delivery snapshots are prepared under the bounded state lock, yielded outside it, and re-read/re-yielded when a newer revision raced the external yield, so concurrent nonisolated teardown cannot leave a subscriber on an older phase.

Connect is accepted only from coordinator idle. Repeated activation or a new panel during connecting, cancelling, or disconnecting starts no Task. The Connect Task captures only controller, exact token, and bounded input; completion returns to the coordinator and never captures a model. Coordinator subscription is one synchronous main-actor operation returning an atomic `(initialPhase, stream, registrationToken)` handoff. The model applies `initialPhase` before exposing actions or starting asynchronous consumption; the `AsyncStream` with `bufferingNewest(1)` carries only later phase changes. Every simultaneously visible panel therefore renders the same current gate without a first-yield gap. Subscription termination removes only its exact continuation; repeated disappearance/reappearance cannot accumulate subscribers. A separate single weak origin-completion closure belongs only to the Connect token so safe action success/failure is delivered to the initiating model if it still exists, never broadcast to other panels, and never forms a strong model cycle.

The visible Cancel action for a UI-owned Connect is the same preemption operation as Disconnect: it advances local authority, clears model input/error, cancels the exact Connect Task, immediately starts or joins one Disconnect Task, and changes coordinator presentation to Disconnecting. A different visible panel may initiate that same shared preemption. Revoking the exact coordinator origin then causes the initiating model to reconcile and clear only that exact stale token and bounded input; it cannot clear an unrelated or successor Connect token. No new Connect is admitted until both operations acknowledge completion and the entry returns to idle. Repeated Cancel/Disconnect and recreated panels reuse the exact entry.

Ordinary disappearance is different. It invalidates the model, unregisters its exact observer, and asks the coordinator only to cancel a still-owned Connect. The entry remains Cancelling until that Task completes, so a recreated panel synchronously sees the gate and cannot start Connect B while predecessor A lives. Disappearance does not start Disconnect and therefore does not automatically end a connection that committed concurrently or was already active.

The Disconnect Task captures only controller and no model, code, status, error, or view. It is removed after exact return; if SDK cleanup is deliberately fail-closed, one code-free Task may remain for the sole process-owned route. The process-wide lease means at most one such nonterminating entry can exist. During explicit preemption the hard bound is the exact cancelled Connect predecessor plus one Disconnect Task; no per-panel Task, waiter list, or callback list exists.

A newly presented model synchronously applies the atomic initial coordinator phase before exposing actions, then consumes later values from the paired stream. Simultaneous panels remain coherent and action serialization still occurs at the shared coordinator. Coordinator phase completion, rather than public status inference, clears Cancelling/Disconnecting. The per-controller entry is removed only when it is idle and its exact phase-subscriber count is zero; this also prevents stale `ObjectIdentifier` reuse. SDK status still controls lifecycle presentation.

The public status does not reveal retained intent or pre-discovery host work. The panel therefore does not infer it. Its total action rule is: shutdown has no actions; coordinator connecting shows Cancel; cancelling or disconnecting shows disabled Cancelling/Disconnecting; discovering/connecting/connected/reconnecting or suspended with coordinator idle offers Disconnect; disconnected with an error offers Connect plus Disconnect/reset; idle and error-free disconnected offers Connect. Cancel invokes the same shared Disconnect preemption path, so there is no cancellation-only button outcome. If Connect returns `connectionInProgress`, `alreadyConnected`, `connectionSuspended`, `connectionIntentExists`, or `anotherConnectionIsActive`, the panel preserves the safe action error and exposes Disconnect/reset. A host-started pre-discovery attempt may first produce the safe preflight error because its prior stable state is intentionally not a public ownership signal.

## Status and Error Presentation

Every `NearWireState` has a fixed English label and SF Symbol name. Progress states include `ProgressView`; connected, suspended, disconnected, shutdown, and error states remain distinguishable by text/icon rather than color alone. Reconnect attempt is shown only when present. `isSuspended` adds a visible paused indicator without replacing the underlying lifecycle state.

The panel displays the current action error first, then the latest status error. A `NearWireError` uses its already content-safe `message`; an unexpected internal error uses one fixed generic sentence and never interpolates descriptions, pairing input, endpoints, Viewer data, or underlying framework errors. Status observation never clears an action error because it has no causal action identifier. Action error is cleared only by a new Connect start, generation-current Connect success, Cancel/Disconnect request, or teardown. This is the total winner rule for simultaneous status and action completion.

## Platform and Accessibility

The implementation imports SwiftUI, the supported NearWire facade, and Foundation solely for the coordinator's bounded in-memory lock. It uses semantic foreground styles, system spacing, SF Symbols by name, default control metrics, and no absolute screen geometry. One closed internal accessibility presentation value defines exact status label, hint, icon, progress, retry, suspension, action label/hint, and error text for every state. Controls bind those values; status combines icon and text into one accessible element; progress and paused state are textual; meaning never depends on color. NearWireUI does not promise automatic live-region error announcement on iOS 16 or macOS 13.

The SwiftPM target must compile for iOS 16 and macOS 13. CocoaPods UI sources compile into the root `NearWire` module, so conditional self-import remains limited to `#if SWIFT_PACKAGE` and public API inventory must be equivalent across both distribution modes.

## Resource and Security Boundaries

- One live model owns one SDK-status observation and one coordinator-phase observation but no action Task. Each phase subscription retains only the newest pending phase and removes itself by exact identity on termination. One internal main-actor coordinator owns per exact controller at most one Connect Task and, only during explicit preemption, one code-free Disconnect Task plus one weak origin completion.
- The model and Tasks retain no second SDK instance and create no network object directly.
- Pairing input is memory-only, capped, cleared from the model at defined boundaries, absent from diagnostics, and not claimed to be securely zeroized. One cancelling coordinator entry may retain its one-shot capped argument until exact SDK completion acknowledgement.
- The UI does not access Keychain, UserDefaults, files, pasteboard, camera, notifications, background execution, reachability, or App lifecycle APIs.
- No runtime dependency, resource bundle, asset, font, entitlement, or privacy manifest is added.

## Test Strategy

- Pure status/action/accessibility presentation tests cover every state, retry, suspension, icon, label, hint, progress, error, and total action mapping. NearWireUITests adds `NearWire` as a direct test dependency and uses `@testable import NearWire` only for deterministic internal status/error fixtures; no initializer becomes public for tests.
- UTF-8 tests cover 63/64/65 ASCII bytes, exact-fit and one-byte-short two-/three-/four-byte scalars, decomposed combining scalars across byte 64, and a multi-scalar joined emoji across the boundary. They assert exact scalar prefix, byte count, forwarded value, and discarded suffix.
- Main-actor model/coordinator tests use an internal fake controller to prove construction side-effect freedom, atomic initial-phase application before first action rendering, bounded input, exact connect forwarding, safe errors, action serialization, cross-panel Cancel-as-Disconnect preemption in both completion orders, shared operation deduplication, exact origin-token reconciliation, coherent simultaneous phase subscribers, exact subscriber removal, weak origin completion, stale-completion isolation, generation invalidation, replacement by controller identity, and no automatic active disconnect.
- Held noncooperative Connect/status/disconnect fixtures, weak probes, rapid disappear/reappear, and live-operation counters prove `Connect A -> disappear -> recreate -> attempted Connect B` cannot start B before A acknowledges completion; explicit Cancel proves the one-predecessor plus one-shared-cleanup bound, no model cycle, no duplicate Task/waiter/callback, and stale-tail inertness.
- SwiftUI smoke tests instantiate both public views and evaluate their body without network work. A platform hosting controller mounts the public connection view and replaces injected instance A with B at the same root, proving the exact SDK status subscription transfers from A to B through the `.id(ObjectIdentifier)` lifecycle boundary.
- Accessibility evidence combines exhaustive presentation-value tests, a source-structure audit for bound accessibility modifiers/grouping and no color-only branch, and `ImageRenderer` construction at a large accessibility Dynamic Type size on supported macOS/iOS test platforms. Fixed English strings are explicitly non-localized and use no resource bundle.
- SwiftPM and CocoaPods public consumers name both view types and confirm no model/controller becomes public.
- Full package, iOS Simulator, podspec, formatting, strict-concurrency, no-persistence/no-observer, and OpenSpec gates remain required.

## Risks and Mitigations

- SwiftUI view identity may preserve state across value replacement. The public wrapper keys the state-owning child by controller object identity; deterministic replacement tests prove the old generation is invalidated and the new exact controller is used.
- A connect completion may race disconnect or disappearance. Exact coordinator token, per-entry phase revision with latest-value convergence, bounded phase subscription, weak origin completion, local generation, and Task cancellation prevent stale UI mutation; SDK lifecycle logic remains the connection authority.
- CocoaPods compiles UI and SDK into one module. Public boundary fixtures compare inventories and forbid internal model/controller exposure.
- Default English strings are not a localization system. This narrow change deliberately ships fixed English SDK UI; localization and styling APIs require a later explicit compatibility decision.
