## MODIFIED Requirements

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

## ADDED Requirements

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

## RENAMED Requirements

- FROM: `### Requirement: NearWireUI exposes one injected connection panel and one value-driven status view`
- TO: `### Requirement: NearWireUI exposes injected composable debugging views`
- FROM: `### Requirement: Injected-instance replacement resets state ownership`
- TO: `### Requirement: Injected monitor and Event-source replacement reset state ownership`
