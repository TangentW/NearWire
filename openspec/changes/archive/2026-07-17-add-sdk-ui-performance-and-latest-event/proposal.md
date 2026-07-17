# Change: Add SDK UI Performance and Latest Viewer Event

## Why

`NearWireUI` currently provides only connection controls. An App that wants a small built-in
debugging surface must build its own Performance controls and its own Viewer-to-App Event
presentation even though both capabilities already exist in the SDK. The optional UI product
should provide those pieces without taking lifecycle ownership away from the host App.

## What Changes

- Add a complete `NearWirePanelView` that composes connection controls, an explicit Performance
  collection toggle, and the latest Viewer-to-App Event.
- Add standalone `NearWirePerformanceControlView` and `NearWireLatestViewerEventView` components so
  Apps can compose only the pieces they need.
- Require the host App to inject its existing `NearWire` and `NearWirePerformanceMonitor`
  instances. Construction and presentation do not automatically connect or start collection.
- Observe Viewer-to-App Events through an independent bounded stream subscription, retain only one
  bounded presentation, and clear it when the component disappears.
- Make the optional NearWireUI distribution depend on the optional Performance implementation and
  its privacy resource while leaving the default NearWire SDK product and CocoaPods subspec
  unchanged.
- Document the complete panel and standalone composition choices.

## Capabilities

### Modified Capabilities

- `sdk-ui`: Expand the optional SwiftUI surface with host-owned Performance controls, latest
  Viewer Event presentation, and a composed panel.
- `sdk-performance`: Permit only NearWireUI to depend on Performance while preserving explicit
  lifecycle ownership and optional packaging.
- `sdk-distribution`: Keep SwiftPM and CocoaPods UI packaging equivalent with the Performance
  dependency and separate privacy resources.
- `sdk-public-boundary`: Add the three approved SwiftUI declarations without exposing UI models,
  collectors, transports, or Core implementation types.

## Impact

The change affects only the optional NearWireUI product/subspec, its tests, package metadata, and
documentation. Apps that import NearWireUI will also receive NearWirePerformance and its Performance
Data privacy resource. Apps that import only NearWire or install the default CocoaPods subspec are
unchanged. No connection, collection, persistence, background execution, event history, Viewer,
Core, transport, or wire behavior changes.
