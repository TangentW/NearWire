## Why

NearWire already defines the cross-platform V1 performance snapshot schema, the optional `NearWirePerformance` SwiftPM product and CocoaPods subspec, and a narrow built-in event SPI. The optional module itself is still a bootstrap marker. Applications therefore cannot opt into supported iOS process, display, battery, thermal, low-power, or NearWire buffer sampling without writing their own collectors and reserved-event bridge.

## What Changes

- Replace the bootstrap marker with an instance-based `NearWirePerformanceMonitor` that receives an existing `NearWire` instance and starts no work during construction.
- Add only the supported monitor configuration, lifecycle state, typed error, and monitor declarations. Snapshot values remain an internal Core schema because this API samples and sends them rather than returning them to App code.
- Collect process CPU time and current memory footprint through approved Darwin interfaces; estimate display cadence with one observing `CADisplayLink`; sample battery, charging, thermal, and low-power state through public UIKit/Foundation APIs; and derive the supported NearWire transport subset from `bufferDiagnostics()`.
- Preserve missing, measured zero, disabled, temporarily unavailable, and unsupported as distinct states. Never fabricate GPU utilization, power watts, Celsius temperature, downlink rate, or another value not available through the reviewed public boundary.
- Send one aggregate `nearwire.performance.snapshot` event per sampling turn through `NearWire.sendPlatformEvent`, using `.keepLatest(key: "nearwire.performance.snapshot")` and the ordinary bounded SDK queue. Add no transport, persistence, retry, acknowledgement, or connection side path.
- Default to a one-second interval, permit a validated 100-millisecond through 60-second interval, and allow process, display, device, and transport groups to be disabled independently while requiring at least one enabled group.
- Make `start()` and `stop()` idempotent for one monitor, reject a second active monitor for the same exact `NearWire`, release timer/display/battery/lease resources on stop, failure, cancellation, and deinitialization, and expose an actor-isolated current state plus a latest-value lifecycle stream for asynchronous submission failure.
- Assign complete-envelope privacy ownership across two manifests: the base NearWire target declares its persistent installation identifier as linked, non-tracking Device ID data for App functionality, while the optional Performance target declares linked, non-tracking Performance Data for App functionality. NearWire intentionally sends snapshots through an installation-correlated session, so neither declaration considers only the snapshot body. Audit the exact collector implementation for Required Reason API use.
- Keep iOS collection code under SDK. The product continues to compile on macOS 13 for repository package validation, but `start()` fails with a typed unsupported-platform error and creates no AppKit collector.

## Capabilities

### New Capabilities

- `sdk-performance`: Optional supported performance monitor, resource-bounded collectors, unavailable semantics, privacy disclosure, and ordinary keep-latest event delivery.

### Modified Capabilities

- `sdk-public-boundary`: SwiftPM and CocoaPods Performance integrations expose the same narrow monitor API while Core schema and collector seams remain unavailable to normal consumers.
- `sdk-distribution`: The existing optional Performance product/subspec gains real source, platform-framework, privacy-resource, consumer, and packaging validation without becoming part of the default SDK installation.

## Impact

The change is limited to `SDK/Sources/NearWirePerformance`, the base SDK's installation-identity privacy manifest, tests and consumer fixtures, root package/pod validation, documentation, and OpenSpec evidence. Existing Core schema source is reused without moving platform code into Core. The base SDK and optional Performance target/subspec each add their correctly owned privacy-manifest resource. The change adds no product, target, pod subspec, third-party runtime dependency, entitlement, persistence, MetricKit integration, lifecycle observer, background mode, Viewer projection, or supported API to the base `NearWire` product.
