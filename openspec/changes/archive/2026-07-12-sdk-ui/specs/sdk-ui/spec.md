## ADDED Requirements

### Requirement: NearWireUI exposes one injected connection panel and one value-driven status view

The optional NearWireUI product SHALL expose exactly `public struct NearWireConnectionView: SwiftUI.View` with `public init(nearWire: NearWire)` and `public struct NearWireConnectionStatusView: SwiftUI.View` with `public init(status: NearWireConnectionStatus)`. Their supported signatures SHALL expose only SwiftUI and supported NearWire facade types. The UI SHALL create no `NearWire` instance, global/singleton SDK facade, public model, public controller protocol, pairing-code getter/binding, Task handle, route, endpoint, certificate, lease, or transport API. It MAY own one internal main-actor process-local operation coordinator only under the exact resource requirement below; that coordinator creates no controller and is not supported API or SPI.

#### Scenario: Host injects its configured instance

- **WHEN** an App constructs `NearWireConnectionView(nearWire: existingInstance)`
- **THEN** the view retains that exact instance and creates no replacement or hidden global owner

#### Scenario: App composes status only

- **WHEN** an App constructs `NearWireConnectionStatusView(status: snapshot)`
- **THEN** the component renders from that value without subscribing, connecting, or mutating SDK state

### Requirement: Construction and presentation preserve host lifecycle ownership

Constructing either view SHALL allocate bounded in-memory UI state only and SHALL start no Task, timer, discovery, connection, process-lease claim, Keychain access, persistence, notification, or App lifecycle observation. Presenting the connection view SHALL start at most one structured subscription to the injected instance's latest-value connection-status stream and one structured one-value-buffered coordinator-phase subscription. Disappearance SHALL cancel both observations and any pending UI-started action, clear pairing input and inline action error, and SHALL NOT disconnect an already active connection, call suspend/resume, shut down the instance, or request background execution.

#### Scenario: View is constructed but never presented

- **WHEN** host code creates the connection view without inserting it into a visible hierarchy
- **THEN** no asynchronous, network, security, storage, or lifecycle work begins

#### Scenario: Connected view disappears

- **WHEN** the panel leaves the hierarchy after the injected instance is connected
- **THEN** UI-owned observation stops but the connection remains owned by the host and is not disconnected or shut down

### Requirement: Pairing input is bounded, memory-only, and SDK-validated

The connection panel SHALL retain at most 64 valid UTF-8 bytes of pairing input, disable autocorrection, request character capitalization, and use a plain text field because the pairing code is not an authentication secret. It SHALL NOT persist, log, reflect, announce as an error, place on the pasteboard, expose through supported API, or claim secure zeroization of the input. Connect SHALL be disabled for empty input and SHALL forward the bounded raw value only after explicit user activation. The UI SHALL NOT duplicate canonical pairing grammar. Success, Cancel/Disconnect request, and disappearance SHALL clear model input; a failed action MAY retain only the bounded input while the panel remains presented. One cancelling coordinator entry MAY retain one separate bounded one-shot argument until exact SDK completion, but it SHALL retain no model and stale completion SHALL be inert.

#### Scenario: User pastes oversized input

- **WHEN** the field receives more than 64 valid UTF-8 bytes
- **THEN** UI-retained input stops at the last scalar boundary within 64 bytes and no later bytes are retained by the model

#### Scenario: User submits formatted code

- **WHEN** the user explicitly submits a nonempty bounded value
- **THEN** the exact retained value is passed once to `connect(code:)` and the SDK remains the grammar and normalization authority

### Requirement: One internal coordinator owns exact cooperative action bounds

The panel model SHALL own no unstructured action Task. One internal `@MainActor` process-local coordinator keyed by class-bound controller object identity SHALL own a closed per-controller phase: idle; connecting with one exact token, one Task, and one bounded input copy; cancelling with that same cancelled Task pending exact completion; or disconnecting with at most that cancelled Connect predecessor plus one code-free Disconnect Task. It SHALL create no controller, expose no API/SPI, and retain no pairing, status, error, or route value except the one bounded Connect argument while that exact Task lives.

Connect SHALL start only from coordinator idle; repeated or successor panels SHALL start no second call while connecting, cancelling, or disconnecting. The Task SHALL capture only controller, token, and bounded input and return completion to the coordinator without capturing a model. Registration SHALL synchronously return one atomic tuple containing current phase, exact registration token, and an independently cancellable `AsyncStream` using `bufferingNewest(1)` for later phase changes. The model SHALL apply that initial phase before exposing actions or awaiting the stream, so no asynchronous first-yield gap may render stale Connect. Termination SHALL remove only the exact continuation; an idle entry SHALL be removed only after its subscriber count reaches zero. The coordinator SHALL keep no cleanup waiter or callback list. One weak origin-completion closure MAY belong only to the exact Connect token to deliver its safe result to the initiating model; it SHALL NOT be broadcast or strongly retain that model. The model SHALL accept results only under its current subscription and action generation.

The visible Cancel action for coordinator connecting SHALL be the same operation as Disconnect preemption: synchronously advance model authority, clear model input/error, cancel the exact Connect Task without claiming termination, start or join one Disconnect Task, and expose Disconnecting until both operations acknowledge completion. Repeated Cancel/Disconnect or recreated panels SHALL reuse that entry. When SDK cleanup deliberately cannot complete, one code-free Disconnect Task MAY remain for the sole process-owned route. Ordinary disappearance SHALL instead unregister/invalidate the model and cancel a still-owned Connect into shared Cancelling without starting Disconnect; a recreated panel SHALL observe Cancelling and cannot start another Connect until exact predecessor completion. Cancellation/disappearance SHALL produce no synthetic error and SHALL NOT weaken SDK cleanup or host semantics.

#### Scenario: Connect is tapped twice

- **WHEN** the first UI-started connect action remains incomplete and Connect is activated again
- **THEN** the controller receives exactly one connect invocation

#### Scenario: Disconnect preempts connect

- **WHEN** the user activates Disconnect while the UI-started connect action is pending
- **THEN** the Cancel-labeled control cancels that exact Task, one shared code-free disconnect begins immediately, phase becomes Disconnecting, and late connect completion cannot overwrite the outcome

#### Scenario: Panel is recreated during held cleanup

- **WHEN** disconnect remains incomplete and another panel for the same instance requests Disconnect
- **THEN** it observes the existing coordinator entry, creates no second waiter or SDK call, and exposes no Connect action until a later disconnected or shutdown status

#### Scenario: Panel disappears during noncooperative Connect

- **WHEN** Connect A remains live after disappearance cancellation and a panel for the same controller reappears
- **THEN** the new phase subscriber immediately receives Cancelling, Connect B cannot start, and the entry returns to idle only after exact completion of A

#### Scenario: Two panels are visible for one instance

- **WHEN** one panel changes the shared coordinator from idle to connecting, cancelling, or disconnecting
- **THEN** both bounded phase subscriptions receive the same latest action gate and neither panel can start a duplicate operation

#### Scenario: Panel appears during held cancellation

- **WHEN** a panel registers while the exact controller is already Cancelling or Disconnecting
- **THEN** the synchronous initial phase disables Connect before the first action presentation, without waiting for an AsyncStream executor turn

#### Scenario: Preemption acknowledgements arrive asymmetrically

- **WHEN** the cancelled Connect and Disconnect Tasks complete in either order
- **THEN** the coordinator remains Disconnecting until both exact tokens acknowledge completion and removes no entry or action gate early

### Requirement: Action availability is conservative and total over public state

The panel SHALL NOT infer private lifecycle intent. Shutdown SHALL expose no action. Coordinator connecting SHALL expose Cancel, whose effect is Disconnect preemption. Cancelling or disconnecting SHALL expose disabled Cancelling/Disconnecting and no Connect. Discovering, connecting, connected, reconnecting, or suspended SDK presentation with coordinator idle SHALL expose Disconnect. Disconnected with `lastError` SHALL expose Connect plus Disconnect/reset; idle and error-free disconnected SHALL expose Connect. An ownership preflight error with code `connectionInProgress`, `alreadyConnected`, `connectionSuspended`, `connectionIntentExists`, or `anotherConnectionIsActive` SHALL preserve the safe action error and expose Disconnect/reset. Host-owned pre-discovery work MAY first be learned through that supported preflight error. This conservative extra reset action SHALL be an explicit no-op when no intent or work exists and SHALL NOT duplicate private recovery classification.

#### Scenario: Disabled policy retains intent after transient terminal

- **WHEN** status is disconnected with a terminal error while active intent may be retained
- **THEN** the panel exposes Disconnect/reset so the user can normalize the instance before supplying a different code

#### Scenario: Permanent terminal cleared intent

- **WHEN** the same public status shape follows a permanent failure with no retained intent
- **THEN** Connect remains available and the conservative Disconnect/reset is a safe optional no-op

### Requirement: Status and errors are complete, safe, and accessible

The status view SHALL map every `NearWireState` to a closed internal presentation containing fixed English label, hint, SF Symbol name, progress flag, retry text, suspension text, and semantic color role. It SHALL add a visible paused indicator when `isSuspended` is true. Progress, connected, disconnected, suspended, shutdown, and error presentation SHALL use text and icon rather than color alone, Dynamic Type, and one combined accessibility label/hint. Action controls and errors SHALL likewise bind closed fixed-English accessibility values. NearWireUI SHALL NOT promise automatic live-region error announcement on iOS 16 or macOS 13 and SHALL document its fixed strings as non-localized.

The connection panel SHALL display the generation-current action error before the latest status error. A `NearWireError` MAY display only its content-safe `message`; an unexpected Error SHALL map to one fixed generic sentence without interpolating its description or any pairing, Viewer, endpoint, certificate, framework, or application content. Status observation SHALL never clear action error. Only new Connect start, generation-current Connect success, Cancel/Disconnect request, or teardown SHALL clear it.

#### Scenario: Late status subscriber appears

- **WHEN** the connection panel begins observation after lifecycle state already changed
- **THEN** the SDK stream's initial latest value immediately drives a coherent status presentation

#### Scenario: Unknown action failure occurs

- **WHEN** a controller throws an Error that is not `NearWireError`
- **THEN** the panel shows the fixed generic connection-action sentence and no underlying description

#### Scenario: Healthy status races action failure

- **WHEN** a healthy status yield and generation-current Connect failure become ready in either order
- **THEN** the action error remains the displayed source until one of its explicit clearing boundaries occurs

### Requirement: NearWireUI remains optional and resource-safe across distributions

NearWireUI production code SHALL import SwiftUI, the supported NearWire facade, and Foundation solely for bounded in-memory synchronization. It SHALL compile in Swift 5 language mode for iOS 16 and macOS 13, and use no UIKit/AppKit wrapper, Objective-C surface, public Combine API, custom font, asset, absolute screen geometry, resource bundle, third-party dependency, persistence, analytics, Keychain, Security item, camera, pasteboard, reachability, notification, App lifecycle, or background-execution API. SwiftPM and the CocoaPods UI subspec SHALL expose equivalent supported view API while the SDK-only CocoaPods default remains unchanged.

#### Scenario: App installs only the SDK product

- **WHEN** an App uses the default CocoaPods SDK subspec or SwiftPM NearWire product without NearWireUI
- **THEN** no SwiftUI source or supported UI API is required by the core SDK facade

#### Scenario: UI work terminates

- **WHEN** the panel disappears or its model is released
- **THEN** generations invalidate all model mutation, observation is cancelled, model input/error clears, and no model cycle remains
- **AND** only coordinator-owned exact Connect cancellation and/or the shared code-free Disconnect Task permitted by the action requirement may outlive it until SDK cleanup completes

### Requirement: Injected-instance replacement resets state ownership

The public connection view wrapper SHALL key its internal state-owning child by `ObjectIdentifier` of the injected `NearWire`. Replacing the injected instance at the same outer SwiftUI identity SHALL remove the old child, synchronously invalidate its observation/action generations, and construct a new child for the exact replacement. Stale old-controller yields and completions SHALL NOT mutate the new child's input, error, status, or actions.

#### Scenario: Host replaces the injected instance in place

- **WHEN** SwiftUI recomputes the public wrapper with a distinct `NearWire` actor at the same structural location
- **THEN** child identity changes, old UI work becomes inert, and all new actions and observation target only the replacement
