# sdk-ui Specification

## Purpose
Define the optional SwiftUI connection and status surface, its injected-instance lifecycle, bounded user-action coordination, accessibility behavior, and distribution/resource boundaries.
## Requirements
### Requirement: Construction and presentation preserve host lifecycle ownership

Constructing any NearWireUI view SHALL allocate bounded in-memory UI state only and SHALL start no
Task, timer, discovery, connection, collection, process-lease claim, Keychain access, persistence,
notification, or App lifecycle observation. Presenting connection content SHALL start at most one
structured subscription to the injected instance's latest-value connection-status stream and one
structured one-value-buffered coordinator-phase subscription. Presenting Performance content SHALL
start at most one structured latest-value state subscription. Presenting latest Event content SHALL
start at most one independent bounded Event subscription. Disappearance SHALL cancel the
component's observation and pending UI-started action, clear component input, Event presentation,
and inline action error, and SHALL NOT disconnect an already active connection, stop an already
running monitor, call suspend/resume, shut down an injected instance, or request background
execution.

#### Scenario: Views are constructed but never presented

- **WHEN** host code creates the views without inserting them into a visible hierarchy
- **THEN** no asynchronous, network, security, storage, collection, or lifecycle work begins

#### Scenario: Complete panel disappears

- **WHEN** the panel leaves the hierarchy after its instance is connected and monitor is running
- **THEN** UI-owned observation stops while connection and collection remain owned by the host

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

NearWireUI production code SHALL import SwiftUI, the supported NearWire facade,
NearWirePerformance, and Foundation solely for bounded in-memory presentation and synchronization.
It SHALL compile in Swift 5 language mode for iOS 16 and macOS 13, and use no UIKit/AppKit wrapper,
Objective-C surface, public Combine API, custom font, asset, absolute screen geometry, UI-owned
resource bundle, third-party dependency, persistence, analytics, Keychain, Security item, camera,
pasteboard, reachability, notification, App lifecycle, or background-execution API. SwiftPM and the
CocoaPods UI subspec SHALL expose equivalent supported view API and include the optional Performance
implementation and its separately owned privacy resource, while the SDK-only CocoaPods default and
SwiftPM NearWire product remain unchanged.

#### Scenario: App installs only the SDK product

- **WHEN** an App uses the default CocoaPods SDK subspec or SwiftPM NearWire product without
  NearWireUI
- **THEN** no SwiftUI source, Performance collector source, Performance privacy resource, or
  supported UI API is required by the core SDK facade

#### Scenario: UI work terminates

- **WHEN** a component disappears or its model is released
- **THEN** generations invalidate all model mutation, observation is cancelled, bounded
  presentation state clears, and no model cycle remains
- **AND** only coordinator-owned exact connection cancellation or cleanup permitted by the
  connection action requirement may outlive it until SDK cleanup completes

### Requirement: NearWireUI exposes injected composable debugging views

The optional NearWireUI product SHALL expose exactly `public struct NearWirePanelView: SwiftUI.View`
with `public init(nearWire: NearWire, performanceMonitor: NearWirePerformanceMonitor)`,
`public struct NearWireConnectionView: SwiftUI.View` with `public init(nearWire: NearWire)`,
`public struct NearWireConnectionStatusView: SwiftUI.View` with
`public init(status: NearWireConnectionStatus)`,
`public struct NearWirePerformanceControlView: SwiftUI.View` with
`public init(performanceMonitor: NearWirePerformanceMonitor)`, and
`public struct NearWireLatestViewerEventView: SwiftUI.View` with `public init(nearWire: NearWire)`.
Their supported signatures SHALL expose only SwiftUI and supported NearWire or
NearWirePerformance facade types. The complete panel SHALL compose the same connection,
Performance, and latest Viewer Event components available separately. The UI SHALL create no
`NearWire` instance, `NearWirePerformanceMonitor`, global/singleton SDK facade, public model, public
controller protocol, pairing-code getter/binding, Task handle, route, endpoint, certificate, lease,
collector, or transport API. It MAY own internal main-actor UI coordination only under the exact
resource requirements below; that coordination creates no facade or monitor and is not supported
API or SPI.

#### Scenario: Host injects its configured instances

- **WHEN** an App constructs
  `NearWirePanelView(nearWire: existingInstance, performanceMonitor: existingMonitor)`
- **THEN** the panel retains those exact instances and creates no replacement or hidden global owner

#### Scenario: App composes individual capabilities

- **WHEN** an App constructs connection, Performance, latest Event, or value-driven status views
  separately
- **THEN** each component uses only its injected value or instance and starts no unrelated feature

### Requirement: Injected monitor and Event-source replacement reset state ownership

The public complete panel SHALL key its state-owning content by the combined object identities of
the injected `NearWire` and `NearWirePerformanceMonitor`. The standalone Performance and latest
Event view wrappers SHALL key their content by the identity of their injected instance. Replacing an
injected instance at the same outer SwiftUI identity SHALL remove the old child, synchronously
invalidate its observation and action generation, clear its bounded presentation, and construct a
new child for the exact replacement. Stale old-instance yields and completions SHALL NOT mutate new
state.

#### Scenario: Host replaces both injected instances

- **WHEN** SwiftUI recomputes the complete panel with a distinct NearWire and monitor at the same
  structural location
- **THEN** child identity changes and all new observation and actions target only the replacements

### Requirement: Performance collection is an explicit host-injected toggle

The Performance component SHALL observe the exact injected monitor's latest-value states and expose
one Toggle labeled `Performance Collection`. Construction, appearance, state observation, and
monitor replacement SHALL NOT call `start()` or `stop()`. Direct user activation SHALL start or
stop the monitor with at most one UI-started operation pending; the Toggle SHALL be disabled while
that operation is pending. Disappearance SHALL cancel UI observation and pending UI participation
without stopping a running host-owned monitor. `NearWirePerformanceError.message` MAY be displayed;
an unexpected error SHALL map to one fixed content-safe sentence. On a platform where collection
start is unsupported, the Toggle SHALL be disabled and the component SHALL make no start request.

#### Scenario: User enables collection

- **WHEN** the stopped monitor's Toggle is explicitly switched on
- **THEN** the component calls `start()` once and reflects the monitor's resulting state

#### Scenario: Running component disappears

- **WHEN** a visible component observing a running monitor leaves the hierarchy
- **THEN** observation stops and the component does not call `stop()` on the host-owned monitor

#### Scenario: Start fails unexpectedly

- **WHEN** monitor start throws an Error other than `NearWirePerformanceError`
- **THEN** the component shows one fixed generic sentence without interpolating the description

### Requirement: Latest Viewer Event presentation is independent and bounded

The latest Event component SHALL observe one independent subscription from the exact injected
`NearWire.events` stream while visible and SHALL ignore every Event whose direction is not
Viewer-to-App. It SHALL retain only the latest applicable presentation: a bounded Event type and a
deterministic bounded JSON-style content summary. Formatting SHALL sort object keys, bound
recursion, collection traversal, and UTF-8 output, and SHALL NOT retain Event history, the complete
Event, identifiers, session metadata, or hidden application content after presentation.
Disappearance SHALL cancel observation and clear the presentation. Stream failure SHALL show one
fixed content-safe sentence without preventing another App-owned Event subscription from
continuing.

#### Scenario: App and UI both observe Events

- **WHEN** the App's business observer and the visible UI component subscribe to the same NearWire
  instance
- **THEN** each has an independent bounded stream and both can receive the same Viewer Event

#### Scenario: App-to-Viewer Event appears in the stream

- **WHEN** the UI subscription receives an Event with App-to-Viewer direction
- **THEN** the component retains no new latest Viewer Event presentation

#### Scenario: Large nested content arrives

- **WHEN** a Viewer Event contains content beyond the formatter's depth, traversal, or UTF-8 bounds
- **THEN** the component presents a deterministic truncated summary and retains no full Event
