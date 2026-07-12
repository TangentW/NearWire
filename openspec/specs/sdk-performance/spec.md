# sdk-performance Specification

## Purpose
TBD - created by archiving change sdk-performance. Update Purpose after archive.
## Requirements
### Requirement: Performance monitoring is opt-in, injected, and instance-based

The optional `NearWirePerformance` product SHALL expose an instance-based `NearWirePerformanceMonitor` initialized with an existing exact `NearWire` and immutable `NearWirePerformanceConfiguration`. Construction SHALL start no Task, timer, display link, battery monitoring, notification, connection, file, Keychain access, event, or other collector work. Configuration SHALL default to a one-second sample interval, SHALL accept only 100 milliseconds through 60 seconds, SHALL permit process, display, device, and transport groups to be disabled independently, SHALL reject an all-disabled configuration without clamping, and SHALL expose a `managesBatteryMonitoring` ownership option that defaults to true without changing whether the device group is enabled.

#### Scenario: Monitor is constructed but not started

- **WHEN** an App initializes a monitor and retains it without calling `start()`
- **THEN** no collector, asynchronous work, platform resource, or NearWire event begins

#### Scenario: Custom interval is invalid

- **WHEN** configuration receives an interval below 100 milliseconds, above 60 seconds, non-positive, unrepresentable, or enables no metric group
- **THEN** initialization throws a content-safe `invalidConfiguration` error naming the invalid field

### Requirement: Public API is limited to monitor control and hides the V1 schema

NearWirePerformance SHALL expose exactly `NearWirePerformanceConfiguration`, `NearWirePerformanceError` and its closed `Code`, `NearWirePerformanceMonitorState`, and actor `NearWirePerformanceMonitor` as source-authored public declaration families. The monitor SHALL sample and send snapshots internally and SHALL NOT expose a public snapshot, metric, battery/thermal, unavailable, collector, clock, lease, or test-seam declaration. Public signatures SHALL contain only standard-library, Foundation, NearWire, or NearWirePerformance types and SHALL NOT expose Core SPI, UIKit, QuartzCore, Darwin, Mach, Tasks, clocks, monitor leases, or test hooks. Internal projection and encoded JSON SHALL validate against the existing Core V1 schema.

#### Scenario: Consumer inspects the Performance API

- **WHEN** SwiftPM and CocoaPods Performance consumers compile the supported declarations
- **THEN** they can configure, start, stop, and observe the monitor
- **AND** they cannot name a snapshot facade, Core schema, or collector seam

#### Scenario: Internal snapshot is encoded

- **WHEN** a sampling turn projects known or unknown battery and thermal platform states
- **THEN** the internal value validates and encodes exactly as the Core V1 schema, with future platform cases mapped to `unknown`

### Requirement: One run owns bounded exact resources

`start()` SHALL be async and actor-serialized while explicitly handling actor reentrancy with internal, non-public Idle, Starting, Running, and Stopping phases. Starting SHALL hold one exact attempt token/task. Every setup continuation SHALL validate the token before acquiring its next resource or committing. After fallible acquisition, the actor SHALL authorize activation for the exact Starting attempt; authorization SHALL block further acquisition but SHALL NOT discard a later cancellation. After activation establishes the fresh baseline and epoch, one locked cancellation-versus-final-commit transition SHALL decide whether cancellation or Running wins. Concurrent same-monitor `start()` calls SHALL join that one attempt and receive its same success or typed setup error without duplicate resources. Cancellation by any Starting waiter SHALL cancel the shared attempt for all its waiters, clean partial resources, throw `CancellationError`, and preserve the prior public state unless stop changed it.

`stop()` during Starting or Running SHALL invalidate the predecessor token, install one exact nonthrowing Stopping cleanup Task/receipt with terminal target Stopped before awaiting, release all reached resources, and clear partial interval state. A current-run sampling or submission failure SHALL enter the same Stopping barrier with terminal target Failed before cleanup. The worker SHALL release every task-owned external resource and emit the exact cleanup receipt as its final step; only receipt validation SHALL discard the Task handle and publish Failed. Concurrent stops SHALL join the same cleanup, replace a pending Failed target with Stopped, and ignore caller cancellation. A start entering during Stopping SHALL await the receipt, check its own cancellation, and then begin or join one fresh attempt; cancellation while waiting only on cleanup SHALL not cancel cleanup or a successor. Stopping SHALL admit no successor resource acquisition, and predecessor handles SHALL release only predecessor resources. One active run SHALL own exactly one sampling Task, at most one iOS display link, at most one managed battery claim, one exact monitor lease, zero or one process baseline, one bounded interval accumulator, and no unbounded callback or history list. A second active monitor for the same exact NearWire SHALL throw `monitorAlreadyRunning` before starting collectors.

From Stopped, unsupported platform, lease conflict, setup failure, and caller cancellation before Running commits SHALL clean partial resources, throw, preserve Stopped, and publish nothing. The same failed retry from Failed SHALL preserve the prior Failed value and publish nothing. Successful start from Stopped or Failed SHALL publish Running once. Current-run sampling or submission failure SHALL clean resources and publish Failed once. If stop invalidates a generation first, its Stopped result SHALL reject a late failure; if Failed commits first, a later stop SHALL publish Stopped. Deinitialization SHALL cancel and clean the run, finish streams, and publish no terminal value. Failure, cancellation, deinitialization, repeated start/stop, and stale completion SHALL release the same resources without duplicate work or monitor retention.

#### Scenario: Start is called twice

- **WHEN** one monitor is already Running and receives another `start()`
- **THEN** the call succeeds as a no-op and no second Task, display link, battery claim, lease, or sample sequence is created

#### Scenario: Two monitors target one SDK instance

- **WHEN** a second monitor calls `start()` while another monitor for the exact NearWire owns the lease
- **THEN** it receives `monitorAlreadyRunning` and starts no collector

#### Scenario: Two calls start one monitor concurrently

- **WHEN** a second `start()` enters while the first call is suspended during setup
- **THEN** both calls join one attempt and observe the same terminal outcome
- **AND** no second lease, display link, battery claim, baseline, or setup sequence is created

#### Scenario: Stop enters during setup

- **WHEN** `stop()` enters while setup is suspended before Running commits
- **THEN** it invalidates, cancels, and awaits that exact attempt before returning
- **AND** stale setup completion cannot later publish Running or affect a restarted attempt

#### Scenario: Start enters during stop cleanup

- **WHEN** `start()` enters while an exact predecessor cleanup is awaiting a slow dependency
- **THEN** it waits without acquiring a lease or collector resource, then begins or joins one fresh attempt after cleanup
- **AND** neither cleanup nor cancellation can release or overwrite successor resources

#### Scenario: Start enters during failure cleanup

- **WHEN** a current run begins cleanup for an event-submission failure and another caller starts
- **THEN** the caller waits until the exact cleanup receipt publishes Failed, then begins or joins one fresh attempt
- **AND** old and new resources never overlap

#### Scenario: Stop enters during failure cleanup

- **WHEN** explicit stop joins a failure-targeted Stopping barrier before its receipt commits
- **THEN** the terminal target becomes Stopped, cleanup completes once, and Failed is never published

#### Scenario: Setup fails before Running

- **WHEN** setup fails while a Stopped monitor is starting
- **THEN** partial resources are released, `start()` throws a content-safe typed error, state remains Stopped, and no state value is published

#### Scenario: Stop races a late failure

- **WHEN** stop invalidates the current generation before a noncooperative dependency returns a failure
- **THEN** Stopped wins and the stale failure cannot publish Failed or release a restarted run's resources

#### Scenario: Monitor stops or is released

- **WHEN** an active monitor is stopped, fails, is cancelled, or is deinitialized
- **THEN** its exact run terminates and display, battery, monitor-lease, accumulator, and Task resources return to their pre-run bounds

### Requirement: iOS collectors use conservative public metric semantics

On iOS 16 or later, process CPU SHALL use a successful-to-successful cumulative process CPU-time and monotonic-instant baseline and MAY exceed 100 for multi-core work; memory SHALL independently report current process physical footprint. Setup SHALL attempt the initial CPU read, but an individual failure SHALL allow Running with no CPU baseline and SHALL NOT become collector setup failure. While no baseline exists, failures remain temporarily unavailable, the first valid pair establishes a baseline without emitting CPU, and only a second valid strictly later non-regressing pair emits. A failed CPU read after a baseline SHALL retain it so recovery spans the complete elapsed duration. A regressing counter, non-positive elapsed time, overflow, or non-finite result SHALL replace the baseline with the current valid pair and mark that turn temporarily unavailable. Stop/restart SHALL clear the baseline. Only collector-session construction failure SHALL fail start.

Display FPS SHALL be estimated from the monitor's main-display `CADisplayLink.timestamp` callbacks serialized on MainActor without changing display policy. A turn SHALL consume callbacks serialized since the preceding reset through its MainActor sampling closure. At least two finite strictly increasing timestamps SHALL be required, and the formula SHALL be `(callbackCount - 1) / (lastTimestamp - firstTimestamp)`. Zero/one callback or invalid/equal/regressing timestamps SHALL mark estimated FPS temporarily unavailable and reset the bounded interval accumulator. Because the monitor has no view/window screen context, it SHALL NOT use deprecated `UIScreen.main`/`UIScreen.screens`, guess a multi-scene/external-display context, or emit `display.maximumFramesPerSecond`; that field SHALL be stable unsupported while display is enabled. Estimated FPS SHALL NOT be labeled rendering throughput or GPU utilization.

Battery level/state SHALL use battery monitoring, thermal SHALL remain categorical, and low-power mode SHALL be Boolean. Managed battery mode SHALL reference-count NearWire claims, record the first value, enable the switch, and restore the recorded value on final release only when no observable external conflict occurred. Observing an external disable SHALL make battery fields temporarily unavailable, SHALL not re-enable or fight the write, and SHALL leave current state untouched on release. Unmanaged mode SHALL never mutate the switch and SHALL require the host to keep it enabled for battery readings. Because an external owner writing true over true is unobservable, documentation SHALL require any host that owns the switch to select unmanaged mode and SHALL NOT claim exact isolation from external owners.

Transport SHALL use only supported NearWire diagnostics. No collector SHALL use private API, fabricate a missing value, register App lifecycle/background/reachability observers, or expose numeric whole-device GPU utilization, power watts, or Celsius temperature.

#### Scenario: A supported value is measured as zero

- **WHEN** CPU, a queue depth, or a drop counter is actually measured as zero
- **THEN** the snapshot contains a present zero and does not mark the field unavailable

#### Scenario: Display callbacks do not arrive

- **WHEN** no display callback is observed during a sampling interval
- **THEN** estimated FPS is absent and recorded as temporarily unavailable rather than zero

#### Scenario: CPU read recovers after one failure

- **WHEN** one CPU read fails between two valid cumulative readings
- **THEN** the failed turn is temporarily unavailable and the recovered percentage divides the full CPU delta by the full successful-to-successful monotonic duration

#### Scenario: Initial CPU reading fails

- **WHEN** setup and repeated early turns cannot read CPU, followed by two valid strictly increasing pairs
- **THEN** Running and all other metrics continue, failed/first-valid turns mark CPU temporarily unavailable, and only the second valid pair emits CPU
- **AND** no public Failed state or `collectorSetupFailed` is produced

#### Scenario: Sixty-Hertz callbacks span one second

- **WHEN** 61 strictly increasing callbacks span exactly one second before the sample closure consumes them
- **THEN** estimated FPS is present as 60 and the accumulator resets for the next interval

#### Scenario: Host manages battery monitoring

- **WHEN** configuration disables NearWire battery-switch management
- **THEN** start, sampling, stop, failure, and deinitialization never mutate the global switch
- **AND** disabled host monitoring makes only battery level/state temporarily unavailable

#### Scenario: Module starts on macOS

- **WHEN** the package-built monitor calls `start()` on macOS
- **THEN** it throws `unsupportedPlatform` before claiming a lease or starting any AppKit or collector work

### Requirement: Missing and unavailable semantics are deterministic

Every snapshot SHALL preserve absent, real zero, disabled, temporarily unavailable, permission denied, and unsupported as distinct meanings. The closed V1 inventory SHALL assign `process.cpuPercent` and `process.memoryFootprintBytes` to process; `display.estimatedFramesPerSecond` and stable-unsupported `display.maximumFramesPerSecond` to display; `device.batteryLevel`, `device.batteryState`, `device.thermalState`, `device.lowPowerModeEnabled`, `device.gpuUtilization`, `device.powerWatts`, and `device.temperatureCelsius` to device; and `transport.uplinkQueueDepth`, `transport.droppedEventCount`, `transport.uplinkBytesPerSecond`, `transport.downlinkBytesPerSecond`, and `transport.downlinkQueueDepth` to transport.

For every inventory key, disabled owning group SHALL take precedence and perform no group work; otherwise GPU utilization, power watts, Celsius temperature, both byte-rate directions, and downlink queue depth SHALL be unsupported; otherwise an attempted supported read SHALL produce either one present value or one permission-denied/temporarily-unavailable record. A key SHALL never be both present and unavailable. Every absent stable field SHALL have exactly one unavailable record, and the unavailable list SHALL be unique and sorted by metric key. Failed individual reads SHALL not discard successful groups.

#### Scenario: Device collection is disabled

- **WHEN** a run disables device metrics
- **THEN** it does not claim battery monitoring or read device state
- **AND** every device field is absent and has one disabled unavailable record

#### Scenario: One process read fails

- **WHEN** memory collection fails while CPU collection succeeds
- **THEN** CPU remains present, memory is absent, and only memory is marked temporarily unavailable

#### Scenario: Unsupported device field belongs to a disabled group

- **WHEN** device collection is disabled
- **THEN** `device.gpuUtilization`, `device.powerWatts`, and `device.temperatureCelsius` each carry disabled rather than unsupported
- **AND** no device key appears more than once

### Requirement: Sampling sends one ordinary keep-latest built-in event

Successful start SHALL establish a fresh monotonic header epoch and collector baselines during final activation after setup and immediately before Running commits, and SHALL emit no immediate sample. Setup and collector-construction delay SHALL be excluded. A bounded activation-to-actor scheduling gap MAY be included in the first interval and display accumulator when commit wins; if cancellation wins, cleanup SHALL discard that activated state. The first turn SHALL begin only after one requested configured sleep. Each turn SHALL capture `sampledAt` and its monotonic header boundary immediately after waking and before collector reads. Header elapsed time SHALL run from the prior boundary, including preceding collection duration and the new sleep, and SHALL round to nearest millisecond with exact half milliseconds upward before clamping to `1...Int64.max`. The next sleep SHALL begin only after the current turn completes. Restart SHALL discard the old epoch, CPU baseline, and display accumulator.

Each due sampling turn SHALL produce at most one aggregate Core-validated `nearwire.performance.snapshot` and submit it through `NearWire.sendPlatformEvent` with `.keepLatest(key: "nearwire.performance.snapshot")`. It SHALL use NearWire's ordinary bounded in-memory queue whether disconnected or connected and SHALL create no direct transport, persistence, rate-control, retry, acknowledgement, or flush path. A delayed turn SHALL produce no catch-up burst. Snapshot wall time SHALL be display context while interval, CPU, FPS, and rate calculations use monotonic time.

Transport `droppedEventCount` SHALL be the cumulative sum of overflow-dropped, expired, and routing-dropped terminal removals only, saturated at the Core schema's maximum JSON-safe unsigned integer (`Int64.max`). It SHALL exclude deliberate keep-latest coalescing, owner-requested explicit clear, and transport-admission rejection because rejection retains the event and can repeat for the same buffered event.

#### Scenario: Several samples occur while disconnected

- **WHEN** three sampling turns submit while the exact NearWire has no connection
- **THEN** ordinary queue diagnostics retain at most the newest pending performance event for the exact keep-latest key
- **AND** no hidden performance queue retains the predecessors

#### Scenario: Sampling is delayed

- **WHEN** a sampling Task wakes after multiple requested intervals elapsed
- **THEN** it produces one sample with the actual positive elapsed interval and schedules the next turn without replaying missed samples

#### Scenario: A buffered event is rejected repeatedly by transport admission

- **WHEN** diagnostics record repeated admission rejection while the same event remains queued
- **THEN** `transport.droppedEventCount` does not increase for those attempts

### Requirement: Lifecycle failure is observable and content-safe

The monitor SHALL expose actor-isolated `currentState` as its single state source and a nonisolated, immediately current-yielding `AsyncStream` over Stopped, Running, and Failed. An actor transition SHALL store and publish the same value before its method returns. Each subscriber SHALL retain at most one pending value and cancel independently. Collector setup failure SHALL make `start()` throw after cleanup without publishing. A post-start snapshot or event-submission failure SHALL enter Stopping, release resources, validate its cleanup receipt, and only then publish a fixed `NearWirePerformanceError` without forwarding system descriptions, event content, pairing data, endpoint data, or arbitrary application errors. Explicit stop and Task cancellation SHALL never publish Failed.

State subscriptions SHALL be bounded independently from monitor run state: each live caller-created stream owns exactly one continuation before, during, or after a run; termination SHALL remove that exact continuation; stop/restart SHALL preserve live subscriptions; and monitor deinitialization SHALL finish all remaining continuations. Resource evidence SHALL distinguish these caller-owned continuations from sampling/collector resources.

#### Scenario: NearWire rejects a periodic event

- **WHEN** a current run cannot submit its validated built-in snapshot
- **THEN** it cleans up, publishes Failed with `eventSubmissionFailed`, and does not retry every interval

#### Scenario: One state subscriber cancels

- **WHEN** one of two state streams terminates
- **THEN** only its exact continuation is removed and the other subscriber continues with one latest pending state

### Requirement: Performance overhead and packaging remain optional and measured

NearWirePerformance SHALL add no runtime dependency, entitlement, persistence, MetricKit subscriber, or framework import to Core, NearWire, or NearWireUI. Privacy ownership SHALL follow collection source. The base NearWire target/subspec SHALL package its own valid `PrivacyInfo.xcprivacy` declaring Device ID for App functionality, user-linked true, tracking false, and no tracking domains because it creates, persists, transmits, and enables Viewer correlation of the installation UUID. The optional Performance target/subspec SHALL package a separate valid manifest declaring Performance Data for App functionality, user-linked true, tracking false, and no tracking domains. Linkage SHALL be assessed over the complete transmitted envelope and Viewer correlation behavior.

SwiftPM SHALL process each manifest only in its owning target. CocoaPods SHALL package separate uniquely named SDK and Performance privacy resource bundles, with the Performance bundle remaining optional. Each manifest SHALL declare exactly the Required Reason API categories used by its owning executable. The collector SHALL use `ContinuousClock` for relative time and SHALL NOT directly call `mach_absolute_time()` or `ProcessInfo.systemUptime`; any future covered API SHALL update the owning manifest before release.

SwiftPM and CocoaPods Performance SHALL compile the supported API in Swift 5 language mode for iOS 16. The package SHALL also compile on macOS 13 with unsupported start semantics. Evidence SHALL validate manifest content in focused tests, plist syntax, packaged resource presence and default-SDK absence, and current Apple policy. Packaging validation SHALL use small real-consumer smoke checks and SHALL NOT duplicate runtime XCTest behavior with source-text, symbol, exact declaration-tree, or mutation-test machinery. Because this change produces libraries rather than a host App archive, the aggregate Xcode App privacy report SHALL remain an explicit `demo-distribution-e2e` and `release-hardening` gate instead of being fabricated from a temporary App. Evidence SHALL also record exact inactive/running resource counts, repeated teardown stress, deterministic collector work counts, a non-sleeping 10,000-turn microbenchmark, and iOS platform smoke coverage; timing SHALL be reported and SHALL NOT replace exact correctness bounds.

#### Scenario: Consumer omits Performance

- **WHEN** an App imports only NearWire or installs the default CocoaPods subspec
- **THEN** no Performance public type, UIKit/QuartzCore collector source, Performance privacy resource bundle, display link, battery monitoring, sampling Task, or additional dependency is required
- **AND** the base SDK still packages its correctly owned Device ID privacy manifest

#### Scenario: Consumer includes Performance

- **WHEN** SwiftPM or CocoaPods integrates the optional Performance module
- **THEN** its packaged artifact contains one valid Performance privacy manifest with the approved collection declaration
- **AND** the declaration reports installation linkage while tracking remains false
- **AND** the base NearWire artifact contains its separate Device ID declaration

#### Scenario: Overhead evidence runs

- **WHEN** the deterministic benchmark and resource probes complete
- **THEN** their exact work/resource counts meet the specified bounds
- **AND** measured timing is recorded without being treated as a universal device threshold
