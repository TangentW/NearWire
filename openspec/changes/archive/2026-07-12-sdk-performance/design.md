## Context

The repository already has four relevant foundations:

1. `NearWireCore` defines and validates the internal V1 `PerformanceSnapshot` schema.
2. `NearWire` exposes a narrow `NearWireBuiltins` SPI that submits reserved `nearwire.*` content through the same bounded queue as application events.
3. `NearWirePerformance` is an optional SwiftPM product and CocoaPods subspec, but currently contains only a bootstrap marker.
4. `NearWire.bufferDiagnostics()` exposes a supported, actor-isolated snapshot of the local uplink buffer without exposing transport internals.

The new module must add observable overhead only after explicit `start()`. It must remain safe when the host never connects, enters the background, replaces or destroys the monitor, or constructs another monitor accidentally. Core remains platform-neutral; UIKit and display-link code stays in the optional SDK target.

## Goals and Non-Goals

### Goals

- Provide a complete opt-in one-second performance snapshot path for iOS 16 and later.
- Use only reviewed public Apple interfaces and label every metric according to what it actually measures.
- Preserve one aligned aggregate sample across process, display, device, and supported transport fields.
- Keep sampling, retained state, subscriptions, and queued events strictly bounded.
- Keep public API equivalent through SwiftPM and the CocoaPods Performance subspec.
- Compile distributed source in Swift 5 language mode under complete concurrency checking.

### Non-Goals

- No whole-device GPU percentage, real-time watts, Celsius temperature, private API, IOKit probe, sysctl hardware archaeology, MetricKit payload, signpost profiler, call-stack sampler, network-path sampler, or App lifecycle observer.
- No Viewer projection or chart, automatic connection, background execution request, disk persistence, event acknowledgement, retry queue, custom collector plugin API, automatic Debug/Release decision, or base-SDK API addition.
- No guarantee that observed display cadence equals rendered-frame throughput or GPU utilization.
- No public Core type, collector protocol, display-link proxy, battery lease, monitor registry, clock, or test hook.

## Supported Public API

The intended supported surface is limited to the following declaration families:

```swift
public struct NearWirePerformanceConfiguration: Equatable, Sendable {
  public static let `default`: NearWirePerformanceConfiguration
  public let sampleInterval: Duration
  public let processMetricsEnabled: Bool
  public let displayMetricsEnabled: Bool
  public let deviceMetricsEnabled: Bool
  public let transportMetricsEnabled: Bool
  public let managesBatteryMonitoring: Bool

  public init(
    sampleInterval: Duration = .seconds(1),
    processMetricsEnabled: Bool = true,
    displayMetricsEnabled: Bool = true,
    deviceMetricsEnabled: Bool = true,
    transportMetricsEnabled: Bool = true,
    managesBatteryMonitoring: Bool = true
  ) throws
}

public struct NearWirePerformanceError: Error, Equatable, Sendable {
  public enum Code: String, Equatable, Sendable { ... }
  public let code: Code
  public let field: String?
  public let message: String
}

public enum NearWirePerformanceMonitorState: Equatable, Sendable {
  case stopped
  case running
  case failed(NearWirePerformanceError)
}

public actor NearWirePerformanceMonitor {
  public nonisolated var states: AsyncStream<NearWirePerformanceMonitorState> { get }
  public var currentState: NearWirePerformanceMonitorState { get }
  public init(
    nearWire: NearWire,
    configuration: NearWirePerformanceConfiguration = .default
  )
  public func start() async throws
  public func stop() async
}
```

No public snapshot or metric facade is added. The monitor does not return snapshots or accept caller-created performance values, so the existing Core V1 schema remains an internal representation. Public signatures contain only Foundation, standard-library, `NearWire`, and `NearWirePerformance` types. Internal collector values convert directly to the Core SPI behind the module boundary.

`NearWirePerformanceError.Code` is closed over `invalidConfiguration`, `monitorAlreadyRunning`, `unsupportedPlatform`, `collectorSetupFailed`, and `eventSubmissionFailed`. Messages and optional fields are fixed content-safe engineering diagnostics. Underlying errors, event content, endpoint data, pairing values, and system descriptions are never forwarded.

## Configuration

The default interval is exactly one second. Configuration converts `Duration` to an exact positive nanosecond value and rejects fractional values outside 100 milliseconds through 60 seconds, overflow, and the all-groups-disabled configuration. Validation returns `invalidConfiguration` with `sampleInterval` or `metricGroups` as the field. It never clamps silently. `managesBatteryMonitoring` changes only ownership of UIKit's App-global battery-monitoring switch; it does not enable or disable the device group.

An interval is a requested sampling cadence, not a real-time deadline. The snapshot header records the positive monotonic elapsed interval since the prior sample, rounded to milliseconds and clamped only to the schema's representable positive range. Wall-clock `sampledAt` is display context. FPS calculation and rate deltas use monotonic time only.

## Monitor Ownership and State

Construction stores the exact injected `NearWire`, immutable validated configuration, and one bounded latest-state hub. It creates no Task, display link, timer, battery lease, notification, file, connection, or event.

`start()` and `stop()` are actor-serialized but actor reentrancy is treated explicitly. The actor owns an internal phase of Idle, Starting, Running, or Stopping in addition to the public Stopped/Running/Failed value. Starting stores one exact attempt token, cancellation gate, setup Task, waiter outcome, and prior public state; it is never public. Every continuation verifies that token before acquiring its next resource or committing. After fallible acquisition, the actor authorizes activation for that exact Starting attempt, which closes further acquisition but does not suppress cancellation. Activation then establishes the fresh collector baseline and epoch. The actor's final commit performs one locked cancellation-versus-commit transition before publishing Running. Cancellation before that final transition wins, including cancellation after authorization; cancellation after it observes an already committed run. A concurrent same-monitor `start()` joins the exact attempt and receives the same success or typed setup error without creating another lease or resource. Cancellation by any caller waiting on that shared attempt cancels the attempt for all waiters; every waiter receives `CancellationError`, partial resources are cleaned, and the prior public state is preserved unless `stop()` has already changed it.

Stopping stores one exact cleanup token, nonthrowing cleanup Task/receipt, and terminal target of Stopped or Failed after invalidating the predecessor token. Explicit `stop()` during Starting or Running installs this barrier with target Stopped before awaiting. A current-run sampling or submission failure installs the same barrier with its fixed Failed target before cleanup begins. The run worker releases every display, battery, monitor-lease, baseline, accumulator, and session handle, then emits the exact cleanup receipt as its final step; only that receipt permits the actor to discard the predecessor Task handle and publish the terminal public state. No Failed value is visible while task-owned external cleanup remains.

Another `stop()` joins the same cleanup, changes a pending Failed target to Stopped, and ignores caller cancellation so the nonthrowing API returns only after cleanup. A `start()` entering during Stopping awaits the predecessor receipt, checks its own cancellation, and then starts fresh; multiple such starts converge on the next one Starting attempt. A cancelled start waiting only on cleanup returns `CancellationError` without cancelling cleanup or a successor attempt. The predecessor's exact handles release only its own resources, and cleanup completion rechecks its token before leaving Stopping, so it cannot release or overwrite a successor generation. No new lease/session/display/battery acquisition overlaps Stopping, including when a dependency is slow or noncooperative.

`currentState` is actor-isolated and is the single authoritative stored public state. `states` is nonisolated only because the bounded hub can create an immediately current-yielding stream safely; actor commits update the stored state and publish the same value before the actor method returns. The hub uses one pending value per subscriber, retains no history or monitor, and removes only the exact cancelled subscriber.

The complete transition contract is:

| Prior state | Operation or event | Outcome | Publication |
| --- | --- | --- | --- |
| Stopped | successful `start()` | claim exact monitor lease, finish setup, create one Task, Running | Running once |
| Running | `start()` | successful no-op | none |
| Failed | successful `start()` | fresh setup and run, Running | Running once |
| Stopped or Failed | concurrent `start()` during Starting | join one exact attempt; same terminal outcome | none beyond the attempt's one transition |
| Stopped | unsupported platform, lease conflict, setup failure, or caller cancellation before commit | clean partial resources, throw, remain Stopped | none |
| Failed | unsupported platform, lease conflict, setup failure, or caller cancellation before commit | clean partial resources, throw, preserve prior Failed | none |
| Stopped | `stop()` during Starting | invalidate/cancel/await attempt, remain Stopped | none |
| Failed | `stop()` during Starting | invalidate/cancel/await attempt, Stopped | Stopped once |
| Any public state | `start()` during Stopping | await exact cleanup, then begin/join one fresh attempt unless caller cancelled | none until the fresh outcome |
| Any public state | `stop()` during Stopping | join exact cleanup and return after it | at most the first stop's one Stopped transition |
| Running | current-run sampling or submission failure | enter Stopping, clean exact resources, receive cleanup receipt, Failed | Failed once after receipt |
| Running | `stop()` during failure-targeted Stopping | change terminal target to Stopped and join cleanup | Stopped once; no Failed |
| Running | `stop()` | invalidate run, cancel and await cleanup, Stopped | Stopped once |
| Failed | `stop()` | Stopped | Stopped once |
| Stopped | `stop()` | successful no-op | none |

`CancellationError` is preserved for caller cancellation during pre-commit setup; other start failures use the fixed `NearWirePerformanceError` codes. A failure after Running never retries every interval or creates a second queue. A later explicit `start()` is a fresh attempt.

Start-attempt, run, and cleanup tokens occupy separate generations. If `stop()` invalidates an attempt or run token first, late setup completion or run failure is ignored and Stopped wins after its cleanup barrier. If a run failure enters Stopping first, explicit stop may still replace the pending terminal target with Stopped until the cleanup receipt commits Failed. A later stop from already committed Failed transitions to Stopped without run resources. Setup completes all fallible resource acquisition, establishes the initial sampling epoch and any available collector baselines, and rechecks the exact attempt token before publishing Running. Deinitialization invalidates and cancels an attempt or run, preserves any installed cleanup, finishes all state streams, and relies on task-owned cleanup that does not strongly retain the monitor. Deinitialization has no final observable state publication.

## Collector Session

One run owns one internal session. On iOS it contains:

- one process sampler using `getrusage(RUSAGE_SELF)` deltas for process CPU percent and `task_info` with `TASK_VM_INFO` for current physical footprint;
- one `@MainActor` `CADisplayLink` observer added to the main run loop in common mode without changing preferred frame-rate policy;
- when configured for module-managed battery monitoring, one process-wide reference-counted `UIDevice.isBatteryMonitoringEnabled` claim with the best-effort policy below;
- direct per-sample reads of `ProcessInfo.thermalState` and `isLowPowerModeEnabled`; and
- one async `NearWire.bufferDiagnostics()` read for the supported transport subset.

No collector installs NotificationCenter, UIApplication, scene, reachability, or background observers. Display callbacks retain only bounded counters and timestamps for the current interval. Each sample atomically consumes and resets those counters. If the App is suspended and callbacks stop, no synthetic FPS is emitted.

UIKit battery monitoring is App-global state, not an ownership-aware resource. With `managesBatteryMonitoring == true`, the first NearWire claimant records the initial Boolean and enables monitoring; NearWire claimants reference-count that decision. The final claimant restores the recorded value only when no observable external conflict occurred. If the switch is observed `false` while a managed claim is active, battery fields become temporarily unavailable, NearWire does not fight the external write, and final release leaves the current value untouched. Another owner writing `true` while it is already `true` is inherently indistinguishable; documentation therefore requires hosts that also own this switch to set `managesBatteryMonitoring` to `false` and keep the switch enabled themselves. In unmanaged mode NearWire never mutates the switch; if the host has not enabled it, battery level and state are temporarily unavailable while thermal and low-power fields remain readable.

The macOS implementation contains no AppKit collector. It compiles the public surface and throws `unsupportedPlatform` before claiming a monitor lease or starting work.

## Metric Semantics

Process CPU percent uses its own successful `(cumulativeProcessCPUSeconds, monotonicInstant)` baseline rather than the snapshot header interval. Setup attempts the first CPU read, but an individual read failure is not collector setup failure: Running still commits with an empty CPU baseline while memory and other groups continue. While empty, repeated failures remain temporarily unavailable; the first later valid pair establishes the baseline without emitting CPU; only a second valid strictly later, non-regressing pair can emit. On each calculable read it emits `(cpuDelta / elapsedSeconds) * 100`, then advances the baseline. It may exceed 100 for multi-core work and a real zero remains present. A CPU read failure after a baseline preserves the last successful pair, so the next valid calculation spans the full successful-to-successful interval. A regressing counter, zero/backward instant, subtraction/conversion overflow, or non-finite result resets the baseline to the current valid pair and makes CPU temporarily unavailable until the following valid pair. Stop/restart discards the baseline. Only failure to construct the collector session itself can fail start with `collectorSetupFailed`. Memory footprint is sampled independently as current `phys_footprint`, not peak resident size or total device memory.

Estimated FPS uses the process monitor's main-display `CADisplayLink.timestamp` values serialized on MainActor. A sampling turn consumes callbacks observed after the preceding reset and through the sampling closure's MainActor execution; a callback serialized later belongs to the next interval. At least two finite, strictly increasing timestamps are required. The exact formula is `(callbackCount - 1) / (lastTimestamp - firstTimestamp)`. Zero or one callback, an equal/regressing timestamp, or a non-finite/zero result makes only estimated FPS temporarily unavailable and resets that interval's accumulator. This yields 60 FPS for 61 callbacks spanning one second and remains based on actual callback cadence when sampling is delayed. The monitor never uses deprecated `UIScreen.main`/`UIScreen.screens`, never guesses a scene or external display, and has no view/window context; `display.maximumFramesPerSecond` is therefore stable unsupported in V1. Estimated cadence is not GPU utilization, rendered-frame throughput, or proof that each callback produced a rendered frame.

Battery level preserves a real value from 0 through 1. UIKit's negative unavailable sentinel becomes an unavailable record and never becomes zero. Battery state, thermal state, and low-power mode use their public categorical/Boolean values. Unknown cases map to `unknown`.

The supported transport subset is:

- `uplinkQueueDepth` from `bufferDiagnostics().eventCount`; and
- `droppedEventCount` from the cumulative sum of overflow-dropped, expired, and routing-dropped terminal removals, saturated at the Core schema's maximum JSON-safe unsigned integer (`Int64.max`).

Deliberate keep-latest coalescing, owner-requested explicit clear, and transport-admission rejection are excluded. Admission rejection leaves the event buffered for retry and may occur repeatedly for the same event, so it is not a drop. Saturating addition prevents diagnostic overflow.

V1 does not expose a private active-channel byte meter or incoming delivery queue through the supported SDK. Uplink/downlink bytes per second and downlink queue depth are therefore absent and recorded as unsupported rather than inferred.

The V1 metric-key inventory is closed for this change:

| Group | Metric key | Unit/source | Support class |
| --- | --- | --- | --- |
| process | `process.cpuPercent` | percent from process CPU-time delta | attempted |
| process | `process.memoryFootprintBytes` | bytes from `TASK_VM_INFO.phys_footprint` | attempted |
| display | `display.estimatedFramesPerSecond` | callbacks per second | attempted |
| display | `display.maximumFramesPerSecond` | no unambiguous view/window screen context | stable unsupported |
| device | `device.batteryLevel` | fraction 0...1 | attempted |
| device | `device.batteryState` | categorical UIKit state | attempted |
| device | `device.thermalState` | categorical ProcessInfo state | attempted |
| device | `device.lowPowerModeEnabled` | Boolean ProcessInfo state | attempted |
| device | `device.gpuUtilization` | unavailable whole-device value | stable unsupported |
| device | `device.powerWatts` | unavailable whole-device value | stable unsupported |
| device | `device.temperatureCelsius` | unavailable whole-device value | stable unsupported |
| transport | `transport.uplinkQueueDepth` | current buffered event count | attempted |
| transport | `transport.droppedEventCount` | cumulative terminal-removal count | attempted |
| transport | `transport.uplinkBytesPerSecond` | unavailable byte meter | stable unsupported |
| transport | `transport.downlinkBytesPerSecond` | unavailable byte meter | stable unsupported |
| transport | `transport.downlinkQueueDepth` | unavailable incoming queue | stable unsupported |

Every snapshot contains a deterministic, unique, metric-key-sorted unavailable list. For every key, the total precedence is: a disabled owning group emits exactly one `disabled` record and performs no group work; otherwise a stable-unsupported field emits exactly one `unsupported` record; otherwise a supported attempted read either emits one present value or one `permissionDenied`/`temporarilyUnavailable` record. A key can never be both present and unavailable, and duplicate reasons are rejected before Core construction. Missing never becomes numeric zero.

## Snapshot Construction and Event Delivery

Internal collector values construct and validate the existing Core V1 schema directly. Encoding uses that Core value as `sendPlatformEvent` content so field names, date strategy, numeric limits, and future decoder behavior remain identical. Tests exercise every field projection, unavailable rule, and deterministic encoded JSON without making the schema public to App consumers.

Successful start records a fresh monotonic header epoch and establishes CPU/display baselines during final activation after setup and immediately before committing Running. It emits no immediate sample. Collector-construction delay is excluded; a bounded activation-to-actor scheduling gap can be included in the first successful interval and display accumulator. If cancellation wins the final transition, cleanup discards that activated state. This modest scheduling tolerance avoids complex synchronization solely to redefine a sub-turn interval. The first Task sleep requests one configured interval, and only then begins the first sampling turn. Each turn captures its wall-clock `sampledAt` and monotonic header boundary immediately after wake and before collector reads. Header elapsed time is measured from the preceding header boundary, including any preceding collection duration plus the new sleep. It converts elapsed duration to milliseconds by rounding to nearest with exact half milliseconds rounded upward, then clamps to `1...Int64.max`. The turn completes its one aggregate and only then begins the next configured sleep; delayed wakes never cause catch-up. Restart discards the prior epoch, CPU baseline, and display accumulator and establishes fresh ones.

Every successful sampling turn calls exactly:

```swift
nearWire.sendPlatformEvent(
  type: "nearwire.performance.snapshot",
  content: coreSnapshot,
  policy: .keepLatest(key: "nearwire.performance.snapshot")
)
```

The call uses the existing actor queue whether disconnected or connected. There is no direct transport access, hidden persistence, separate rate limiter, flush trigger, or delivery claim. A new offline sample replaces the older pending sample under the exact key. `NearWireSendResult` remains local admission evidence only.

## Resource and Performance Bounds

While Idle/Stopped with no start attempt: zero sampling Task, display link, managed battery claim, timer, monitor lease, collector baseline, or event. Starting owns one bounded setup Task and only the partial resources reached so far. Running owns one sampling Task, at most one display link, at most one shared managed-battery claim, one exact monitor lease, zero or one process baseline, one latest-state value, one interval counter set, and one snapshot at a time. Stopping owns one cleanup Task plus only predecessor resources awaiting release and admits no successor resources until cleanup completes. Independently of run state, each caller-created live state stream owns exactly one bounded continuation; termination removes that exact continuation, and monitor deinitialization finishes all remaining continuations. NearWire's queue retains at most one pending event for the exact keep-latest key, subject to ordinary queue admission.

The sampling Task sleeps between turns and performs no polling spin. MainActor work is limited to reading/resetting bounded display/device state and never performs JSON encoding, system calls, queue admission, file, or network I/O. Tests use deterministic clocks and collectors to prove no catch-up burst after a delayed turn: one late wake produces one sample and schedules the next interval from that completion.

Overhead evidence includes construction/start-stop resource counters, repeated start-stop/deinit stress, a deterministic 10,000-turn collector microbenchmark with no real sleep or UI resource, and an iOS simulator/available-device smoke run. Timing evidence is reported rather than used as a fragile universal correctness threshold; hard correctness gates are the exact resource and work counts.

## Packaging and Documentation

SwiftPM keeps `NearWirePerformance` as a separate optional product depending only on NearWire and Core. CocoaPods keeps `Performance` optional and dependent on SDK. UIKit and QuartzCore are Apple frameworks used only by the Performance subspec/target and do not enter Core, NearWire, NearWireUI, or the default CocoaPods install. No third-party runtime dependency or entitlement is introduced.

Privacy ownership follows the source that collects each type. `SDK/Sources/NearWire/PrivacyInfo.xcprivacy` declares `NSPrivacyCollectedDataTypeDeviceID` for App functionality, linked `true`, tracking `false`, because the base SDK creates, persists, transmits, and lets the Viewer store/correlate its installation UUID. SwiftPM processes it only for the NearWire target; CocoaPods packages it through a uniquely named base-SDK privacy resource bundle.

`SDK/Sources/NearWirePerformance/PrivacyInfo.xcprivacy` declares `NSPrivacyCollectedDataTypePerformanceData` for App functionality, linked `true`, tracking `false`. SwiftPM processes it only for the NearWirePerformance target; CocoaPods packages it through a separate uniquely named Performance resource bundle. Performance linkage is true because its complete session envelope uses the base installation identifier; an identifier-free snapshot body does not remove that association. Neither manifest declares tracking domains. The planned implementation uses Swift `ContinuousClock` for relative elapsed time and does not directly call `mach_absolute_time()`, `ProcessInfo.systemUptime`, or another currently listed Required Reason API. Focused manifest tests, both packaged resources, plist validation, and the envelope fixture confirm the final declarations; policy can change, so the aggregate App privacy report remains a release gate rather than a permanent exemption claim.

Small public consumer fixtures compile the supported monitor API through SwiftPM and CocoaPods Performance and prove that the base SDK cannot name optional Performance types. XCTest remains the primary correctness gate; packaging smoke checks only cover facts that XCTest cannot observe.

Documentation states metric source, units, unavailable behavior, estimated-FPS limitation, optional overhead, explicit lifecycle, failure state, keep-latest queue semantics, platform support, and the absence of GPU/power/temperature numbers.

## Risks and Mitigations

- **Collector overhead distorts the App.** The module is optional, starts explicitly, defaults to one second, sleeps between turns, bounds all state, and records on/off resource and microbenchmark evidence.
- **Display cadence is misread as rendering or GPU throughput.** Public names and documentation say estimated FPS; unsupported GPU remains explicit.
- **Global battery monitoring conflicts with another owner.** Managed mode is explicitly best-effort and requires no concurrent host ownership; host owners select unmanaged mode. Tests cover initially on/off state, shared NearWire claims, observable external disable, and no-mutation unmanaged behavior without claiming impossible ownership isolation.
- **Privacy ownership or policy drifts.** The base SDK owns its Device ID declaration, the optional product owns its Performance Data declaration, and this library change audits complete-envelope collection, collector APIs, manifest content, and packaged resources against current Apple documentation. The aggregate Xcode App privacy report remains a Demo and release-hardening gate because it requires a real host App archive.
- **A stale run mutates a restarted monitor.** Exact run/lease tokens and actor serialization reject stale completion and failure publication.
- **Offline samples accumulate.** Every run uses the same exact keep-latest key through the ordinary bounded queue.
- **CocoaPods merges modules.** A small consumer compiles the supported surface from the merged module; the same source declarations and Swift access control remain authoritative.
- **Mac package validation accidentally gains platform work.** Conditional source boundaries compile the monitor API but fail `start()` before resources, with no AppKit import.
