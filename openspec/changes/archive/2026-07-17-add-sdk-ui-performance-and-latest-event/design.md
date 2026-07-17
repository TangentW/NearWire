# Design: SDK UI Performance and Latest Viewer Event

## Public composition

NearWireUI adds three public views:

- `NearWirePanelView(nearWire:performanceMonitor:)`
- `NearWirePerformanceControlView(performanceMonitor:)`
- `NearWireLatestViewerEventView(nearWire:)`

The complete panel composes those views with the existing `NearWireConnectionView`. The standalone
views preserve flexible host composition. All instances are injected; NearWireUI creates neither a
`NearWire` facade nor a `NearWirePerformanceMonitor`.

## Performance lifecycle

An internal main-actor model observes the monitor's latest-value state stream while visible. The
toggle starts or stops the injected monitor only after direct user activation. A closed operation
phase prevents overlapping start and stop requests and disables the control while an operation is
pending.

View construction and appearance never start collection. Disappearance cancels UI observation and
pending UI participation but does not stop a running host-owned monitor. Public
`NearWirePerformanceError.message` is safe to present; unexpected errors use one fixed message.
macOS keeps the view available for source compatibility but disables collection because the
collector has unsupported start semantics there.

## Latest Viewer Event

The Event component opens one independent `NearWire.events` subscription while visible. NearWire's
Event hub gives each subscriber its own bounded continuation, so the UI does not consume Events from
the App's business subscriber. The component ignores App-to-Viewer Events.

For the latest Viewer-to-App Event it stores only a presentation value containing a bounded Event
type and bounded deterministic content summary. The formatter sorts object keys, limits traversal,
escapes JSON-style strings, and stops at a fixed UTF-8 boundary. It never retains Event history,
session metadata, identifiers, or the complete Event after presentation. Disappearance clears the
presentation and stream error. Stream failure uses one fixed content-safe message.

## Identity and replacement

The complete panel keys its content by the pair of injected object identities. Each standalone
component keys state-owning content by its corresponding injected object. Replacing an injected
instance invalidates and removes old observation and action state before creating the replacement
content.

## Packaging and privacy

The SwiftPM NearWireUI target depends on `NearWire` and `NearWirePerformance`. The CocoaPods UI
subspec depends on the Performance subspec, which already depends on SDK. Therefore UI consumers get
the Performance implementation and its separate privacy resource in both distributions.

The default SwiftPM NearWire product and default CocoaPods SDK subspec remain independent of UI and
Performance. Collection remains dormant until the host explicitly enables it.

## Rejected alternatives

- Creating a hidden monitor in the view was rejected because it would conflict with App lifecycle,
  reset, and teardown ownership.
- Automatically starting collection on appearance was rejected because presentation is not consent
  or lifecycle authority.
- Reusing one shared business Event iterator was rejected because UI presentation must not steal
  application controls.
- Retaining a UI Event history was rejected because the requested surface needs only the newest
  downlink Event and NearWireUI has no persistence role.
