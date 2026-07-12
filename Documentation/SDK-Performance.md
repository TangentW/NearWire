# NearWire Performance Monitor

## Scope and installation

`NearWirePerformance` is an optional iOS 16 product that samples a conservative set of App-process, display-callback, device-state, and NearWire-buffer metrics. It sends one aggregate built-in Event through the injected `NearWire` instance. It is not a profiler, whole-device telemetry API, MetricKit replacement, background service, or persistence layer.

Swift Package consumers add both `NearWire` and `NearWirePerformance` to the App target:

```swift
import NearWire
import NearWirePerformance
```

CocoaPods consumers select the optional subspec:

```ruby
pod "NearWire/Performance"
```

The default CocoaPods subspec does not compile performance collectors. `NearWirePerformance` adds no third-party runtime dependency. Its UIKit and QuartzCore use remains inside the optional module.

## Create and start a monitor

The monitor is instance-based. Construction stores configuration and the exact injected `NearWire`; it starts no Task, display link, battery claim, connection, file, notification observer, or Event.

```swift
let nearWire = NearWire()
let performanceConfiguration = try NearWirePerformanceConfiguration(
  sampleInterval: .seconds(1),
  processMetricsEnabled: true,
  displayMetricsEnabled: true,
  deviceMetricsEnabled: true,
  transportMetricsEnabled: true,
  managesBatteryMonitoring: true
)
let monitor = NearWirePerformanceMonitor(
  nearWire: nearWire,
  configuration: performanceConfiguration
)

try await monitor.start()
// Retain the monitor for as long as sampling is required.
await monitor.stop()
```

The interval must be a whole number of nanoseconds from 100 milliseconds through 60 seconds. At least one metric group must be enabled. Invalid values throw `NearWirePerformanceError.Code.invalidConfiguration`; values are never clamped silently.

Successful start establishes collector baselines and then waits one full configured interval before the first snapshot. A late wake produces one sample with its actual elapsed interval. The monitor never replays missed intervals or creates a catch-up burst.

## Lifecycle and errors

`start()` is idempotent while Running. Concurrent starts on one monitor join one setup attempt. Only one monitor may run for one exact `NearWire` instance; another monitor receives `monitorAlreadyRunning` without starting a collector. A monitor for a different instance is independent.

`stop()` is nonthrowing and idempotent. It returns after the exact setup attempt or run has finished cleanup. Starting during cleanup waits and then begins a fresh attempt, so predecessor and successor display, battery, lease, session, and Task resources do not overlap.

Observe the latest lifecycle value through either actor-isolated state or a newest-one stream:

```swift
let state = await monitor.currentState

for await state in monitor.states {
  // stopped, running, or failed(NearWirePerformanceError)
}
```

Each stream immediately yields the current value, retains one pending update, and cancels independently. Setup failures throw while preserving the prior public state. A sampling or Event-admission failure cleans the run first and then publishes `failed(.eventSubmissionFailed)`. Error messages are fixed English engineering diagnostics and never include Event content, pairing values, endpoint data, system descriptions, or arbitrary application errors.

The same API compiles on macOS 13 for repository package validation. Calling `start()` there throws `unsupportedPlatform` before claiming a monitor lease or creating platform resources.

## Event delivery

Every due turn constructs the internal Core V1 schema and makes exactly this ordinary queue submission:

```text
type: nearwire.performance.snapshot
policy: keepLatest(key: "nearwire.performance.snapshot")
```

The Event uses the existing bounded in-memory uplink queue whether NearWire is disconnected or connected. Offline snapshots coalesce under one exact key. There is no performance-only queue, socket, persistence, retry, acknowledgement, rate bypass, connection trigger, or flush path. A successful local admission is not Viewer delivery evidence.

The snapshot and metric schema remains internal because the App API samples and sends it rather than returning caller-constructed snapshots. Viewer and SDK share that schema through repository-owned Core SPI; App consumers receive only configuration, error, lifecycle state, and monitor declarations.

## Metric semantics

| Metric | Source and meaning |
| --- | --- |
| `process.cpuPercent` | Delta of cumulative App-process user and system CPU time over a successful-to-successful monotonic interval. It may exceed 100 on multi-core work. |
| `process.memoryFootprintBytes` | Current App-process `TASK_VM_INFO.phys_footprint`, not peak RSS or device memory. |
| `display.estimatedFramesPerSecond` | `(callback count - 1) / (last timestamp - first timestamp)` from finite, strictly increasing main-display `CADisplayLink` callbacks. It is callback cadence, not rendered frames or GPU utilization. |
| `device.batteryLevel` | UIKit fraction from 0 through 1 when battery monitoring is available. A negative UIKit sentinel is unavailable, never zero. |
| `device.batteryState` | UIKit unknown, unplugged, charging, or full state. |
| `device.thermalState` | ProcessInfo categorical unknown, nominal, fair, serious, or critical state. It is not Celsius. |
| `device.lowPowerModeEnabled` | Current ProcessInfo Boolean. |
| `transport.uplinkQueueDepth` | Current count in the exact NearWire instance's in-memory App-to-Viewer queue. |
| `transport.droppedEventCount` | Saturated cumulative overflow, expiry, and route-affinity terminal removals. It excludes keep-latest coalescing, explicit clear, and transport admission rejection. |

The process sampler uses public Darwin and Mach SDK interfaces only. CPU read failure preserves an existing successful baseline. If the initial read fails, the first later valid read establishes a baseline without emitting CPU, and the second valid pair may emit. Memory failure is independent.

The display collector creates one observing display link and does not alter preferred frame-rate policy. With no view or window screen context, V1 marks `display.maximumFramesPerSecond` unsupported instead of using deprecated `UIScreen.main`, guessing among scenes, or conflating current cadence with hardware capability.

V1 also marks whole-device GPU utilization, real-time watts, Celsius temperature, uplink/downlink byte rates, and downlink queue depth unsupported. It does not use private API, IOKit, `sysctl` probing, MetricKit periodic payloads, or fabricated estimates.

## Missing and unavailable values

A present zero is a real measurement. Missing never means zero. Each absent stable metric has exactly one sorted unavailable record:

- `disabled`: the owning group is disabled and its collector performs no work;
- `unsupported`: the enabled V1 module has no reviewed source for that field;
- `permissionDenied`: reserved for an attempted public source that reports denial;
- `temporarilyUnavailable`: an attempted source has no valid value for this turn.

Disabled takes precedence over unsupported. A metric cannot be both present and unavailable.

## Battery-monitoring ownership

`UIDevice.isBatteryMonitoringEnabled` is App-global mutable state without owner tokens.

The default `managesBatteryMonitoring: true` mode reference-counts NearWire claims, records the initial value, and restores it after the final claim when no observable external conflict occurred. If another owner turns monitoring off during a run, NearWire does not fight the write; battery values become temporarily unavailable and release leaves the current value untouched.

Another owner writing `true` while it is already `true` is unobservable. If host code or another framework owns battery monitoring, set `managesBatteryMonitoring` to `false` and keep the UIKit switch enabled for the desired lifetime. In unmanaged mode NearWire never mutates it. Thermal and low-power readings remain independent of battery availability.

## Privacy and release audit

Privacy manifest ownership follows the collecting component:

- the base `NearWire` target declares its persistent App installation UUID as linked Device ID data used for App functionality, with tracking disabled;
- the optional `NearWirePerformance` target declares linked Performance Data used for App functionality, with tracking disabled.

Performance data is linked because the complete TLS session lets the Viewer correlate Events to that installation UUID even though the snapshot body contains no identifier. Neither component uses tracking domains.

The collector uses Swift `ContinuousClock` and does not directly call `mach_absolute_time()` or `ProcessInfo.systemUptime`. SDK validation re-audits source, linked/archive symbols, both packaged manifests, and current Apple Required Reason API policy. The aggregate Xcode privacy report is generated later from the maintained Demo and release App archives, where Xcode can evaluate the whole host product rather than a fabricated temporary App. The manifests describe this SDK; the host remains responsible for its own collection, consent, and App Store declarations.

## Overhead bounds

Stopped construction has no sampling resource. One Running monitor owns one sleeping sampling Task, at most one display link, at most one managed battery claim, one exact monitor lease, a bounded CPU baseline and display accumulator, and one snapshot at a time. Each caller-created state stream adds one newest-one continuation. MainActor work is limited to display accumulator and public device-state access; process reads, Core projection, encoding, and NearWire queue admission stay off MainActor.

Repository gates include focused start/stop and cleanup assertions, 1,000 deterministic fake-resource teardown cycles, 10,000 no-sleep projection turns, iOS collector compilation and smoke coverage, small SwiftPM/CocoaPods consumer builds, packaged privacy resources, and full SDK regressions. Runtime behavior and manifest semantics stay in XCTest; packaging smoke checks cover only integration facts XCTest cannot observe. Reported benchmark timing is diagnostic only; exact fake-resource and work counts are the correctness contract.
