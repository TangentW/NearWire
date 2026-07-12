import Foundation

#if os(iOS)
  import Darwin
  import MachO
#endif

#if SWIFT_PACKAGE
  import NearWire
#endif

protocol PerformanceCollectorSession: Sendable {
  func activate(clock: PerformanceClock) async -> ContinuousClock.Instant
  func sample(at instant: ContinuousClock.Instant) async -> PerformanceCollectedReading
  func stop() async
}

actor LivePerformanceCollectorSession: PerformanceCollectorSession {
  private let configuration: NearWirePerformanceConfiguration
  private var cpuSampler: PerformanceCPUSampler
  private let readMemoryFootprint: @Sendable () -> UInt64?
  private let readTransport: @Sendable () async -> NearWireBufferDiagnostics?
  private let platform: any PerformancePlatformSession
  private var isActivated = false
  private var didStop = false

  init(
    configuration: NearWirePerformanceConfiguration,
    platform: any PerformancePlatformSession,
    readCPUSeconds: @escaping @Sendable () -> Double?,
    readMemoryFootprint: @escaping @Sendable () -> UInt64?,
    readTransport: @escaping @Sendable () async -> NearWireBufferDiagnostics?
  ) {
    self.configuration = configuration
    self.platform = platform
    self.readMemoryFootprint = readMemoryFootprint
    self.readTransport = readTransport
    cpuSampler = PerformanceCPUSampler(readCumulativeSeconds: readCPUSeconds)
  }

  func activate(clock: PerformanceClock) async -> ContinuousClock.Instant {
    await platform.activate()
    let instant = clock.now()
    if configuration.processMetricsEnabled { cpuSampler.prime(at: instant) }
    isActivated = true
    return instant
  }

  func sample(at instant: ContinuousClock.Instant) async -> PerformanceCollectedReading {
    guard isActivated, !didStop else { return PerformanceCollectedReading() }

    let process: PerformanceProcessReading?
    if configuration.processMetricsEnabled {
      process = PerformanceProcessReading(
        cpuPercent: cpuSampler.sample(at: instant),
        memoryFootprintBytes: readMemoryFootprint()
      )
    } else {
      process = nil
    }

    let platformReading:
      (
        display: PerformanceDisplayReading?,
        device: PerformanceDeviceReading?
      )
    if configuration.displayMetricsEnabled || configuration.deviceMetricsEnabled {
      platformReading = await platform.sample()
    } else {
      platformReading = (display: nil, device: nil)
    }

    let transport: PerformanceTransportReading?
    if configuration.transportMetricsEnabled, let diagnostics = await readTransport() {
      transport = PerformanceTransportReading(
        uplinkQueueDepth: UInt64(exactly: diagnostics.eventCount),
        droppedEventCount: PerformanceSnapshotProjection.droppedEventCount(diagnostics.statistics)
      )
    } else if configuration.transportMetricsEnabled {
      transport = PerformanceTransportReading()
    } else {
      transport = nil
    }

    return PerformanceCollectedReading(
      process: process,
      display: platformReading.display,
      device: platformReading.device,
      transport: transport
    )
  }

  func stop() async {
    guard !didStop else { return }
    didStop = true
    isActivated = false
    await platform.stop()
  }
}

enum PerformanceSystemReaders {
  static func processCPUSeconds() -> Double? {
    #if os(iOS)
      var usage = rusage()
      guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
      guard let user = seconds(usage.ru_utime), let system = seconds(usage.ru_stime) else {
        return nil
      }
      let total = user + system
      guard total.isFinite, total >= 0 else { return nil }
      return total
    #else
      return nil
    #endif
  }

  static func memoryFootprintBytes() -> UInt64? {
    #if os(iOS)
      var information = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
      )
      let result = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
          task_info(
            mach_task_self_,
            task_flavor_t(TASK_VM_INFO),
            rebound,
            &count
          )
        }
      }
      guard result == KERN_SUCCESS else { return nil }
      return information.phys_footprint
    #else
      return nil
    #endif
  }

  #if os(iOS)
    private static func seconds(_ value: timeval) -> Double? {
      guard value.tv_sec >= 0, value.tv_usec >= 0 else { return nil }
      let result = Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
      guard result.isFinite, result >= 0 else { return nil }
      return result
    }
  #endif
}
