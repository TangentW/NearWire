import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  import NearWire
#endif

struct PerformanceProcessReading: Sendable {
  var cpuPercent: Double? = nil
  var memoryFootprintBytes: UInt64? = nil
}

struct PerformanceDisplayReading: Sendable {
  var estimatedFramesPerSecond: Double? = nil
}

struct PerformanceDeviceReading: Sendable {
  var batteryLevel: Double? = nil
  var batteryState: BatteryState? = nil
  var thermalState: ThermalState? = nil
  var lowPowerModeEnabled: Bool? = nil
}

struct PerformanceTransportReading: Sendable {
  var uplinkQueueDepth: UInt64? = nil
  var droppedEventCount: UInt64? = nil
}

struct PerformanceCollectedReading: Sendable {
  var process: PerformanceProcessReading? = nil
  var display: PerformanceDisplayReading? = nil
  var device: PerformanceDeviceReading? = nil
  var transport: PerformanceTransportReading? = nil
  var unavailableReasons: [PerformanceMetricKey: UnavailablePerformanceMetricReason] = [:]
}

enum PerformanceSnapshotProjection {
  static func makeSnapshot(
    configuration: NearWirePerformanceConfiguration,
    sampledAt: Date,
    intervalMilliseconds: UInt64,
    reading: PerformanceCollectedReading
  ) throws -> PerformanceSnapshot {
    var unavailable: [PerformanceMetricKey: UnavailablePerformanceMetricReason] = [:]

    let process: ProcessPerformanceMetrics?
    if configuration.processMetricsEnabled {
      process = try ProcessPerformanceMetrics(
        cpuPercent: reading.process?.cpuPercent,
        memoryFootprintBytes: reading.process?.memoryFootprintBytes
      )
      markMissing(
        .processCPUPercent,
        valueIsPresent: reading.process?.cpuPercent != nil,
        reportedReason: reading.unavailableReasons[.processCPUPercent],
        into: &unavailable
      )
      markMissing(
        .processMemoryFootprintBytes,
        valueIsPresent: reading.process?.memoryFootprintBytes != nil,
        reportedReason: reading.unavailableReasons[.processMemoryFootprintBytes],
        into: &unavailable
      )
    } else {
      process = nil
      markDisabled(.process, into: &unavailable)
    }

    let display: DisplayPerformanceMetrics?
    if configuration.displayMetricsEnabled {
      display = try DisplayPerformanceMetrics(
        estimatedFramesPerSecond: reading.display?.estimatedFramesPerSecond
      )
      markMissing(
        .displayEstimatedFramesPerSecond,
        valueIsPresent: reading.display?.estimatedFramesPerSecond != nil,
        reportedReason: reading.unavailableReasons[.displayEstimatedFramesPerSecond],
        into: &unavailable
      )
      unavailable[.displayMaximumFramesPerSecond] = .unsupported
    } else {
      display = nil
      markDisabled(.display, into: &unavailable)
    }

    let device: DevicePerformanceMetrics?
    if configuration.deviceMetricsEnabled {
      device = try DevicePerformanceMetrics(
        batteryLevel: reading.device?.batteryLevel,
        batteryState: reading.device?.batteryState,
        thermalState: reading.device?.thermalState,
        lowPowerModeEnabled: reading.device?.lowPowerModeEnabled
      )
      markMissing(
        .deviceBatteryLevel,
        valueIsPresent: reading.device?.batteryLevel != nil,
        reportedReason: reading.unavailableReasons[.deviceBatteryLevel],
        into: &unavailable
      )
      markMissing(
        .deviceBatteryState,
        valueIsPresent: reading.device?.batteryState != nil,
        reportedReason: reading.unavailableReasons[.deviceBatteryState],
        into: &unavailable
      )
      markMissing(
        .deviceThermalState,
        valueIsPresent: reading.device?.thermalState != nil,
        reportedReason: reading.unavailableReasons[.deviceThermalState],
        into: &unavailable
      )
      markMissing(
        .deviceLowPowerModeEnabled,
        valueIsPresent: reading.device?.lowPowerModeEnabled != nil,
        reportedReason: reading.unavailableReasons[.deviceLowPowerModeEnabled],
        into: &unavailable
      )
      unavailable[.deviceGPUUtilization] = .unsupported
      unavailable[.devicePowerWatts] = .unsupported
      unavailable[.deviceTemperatureCelsius] = .unsupported
    } else {
      device = nil
      markDisabled(.device, into: &unavailable)
    }

    let transport: TransportPerformanceMetrics?
    if configuration.transportMetricsEnabled {
      transport = try TransportPerformanceMetrics(
        uplinkQueueDepth: reading.transport?.uplinkQueueDepth,
        droppedEventCount: reading.transport?.droppedEventCount
      )
      markMissing(
        .transportUplinkQueueDepth,
        valueIsPresent: reading.transport?.uplinkQueueDepth != nil,
        reportedReason: reading.unavailableReasons[.transportUplinkQueueDepth],
        into: &unavailable
      )
      markMissing(
        .transportDroppedEventCount,
        valueIsPresent: reading.transport?.droppedEventCount != nil,
        reportedReason: reading.unavailableReasons[.transportDroppedEventCount],
        into: &unavailable
      )
      unavailable[.transportUplinkBytesPerSecond] = .unsupported
      unavailable[.transportDownlinkBytesPerSecond] = .unsupported
      unavailable[.transportDownlinkQueueDepth] = .unsupported
    } else {
      transport = nil
      markDisabled(.transport, into: &unavailable)
    }

    let unavailableValues =
      try unavailable
      .sorted { $0.key.rawValue < $1.key.rawValue }
      .map { key, reason in
        try UnavailablePerformanceMetric(metric: key.rawValue, reason: reason)
      }

    return try PerformanceSnapshot(
      sampledAt: sampledAt,
      sampleIntervalMilliseconds: intervalMilliseconds,
      process: process,
      display: display,
      device: device,
      transport: transport,
      unavailable: unavailableValues
    )
  }

  static func droppedEventCount(_ statistics: NearWireBufferStatistics) -> UInt64 {
    droppedEventCount(
      overflowDropped: statistics.overflowDropped,
      expired: statistics.expired,
      routingDropped: statistics.routingDropped
    )
  }

  static func droppedEventCount(
    overflowDropped: UInt64,
    expired: UInt64,
    routingDropped: UInt64
  ) -> UInt64 {
    let first = saturatedJSONSafeSum(overflowDropped, expired)
    return saturatedJSONSafeSum(first, routingDropped)
  }

  private static func markMissing(
    _ key: PerformanceMetricKey,
    valueIsPresent: Bool,
    reportedReason: UnavailablePerformanceMetricReason?,
    into unavailable: inout [PerformanceMetricKey: UnavailablePerformanceMetricReason]
  ) {
    guard !valueIsPresent else { return }
    switch reportedReason {
    case .permissionDenied:
      unavailable[key] = .permissionDenied
    default:
      unavailable[key] = .temporarilyUnavailable
    }
  }

  private static func markDisabled(
    _ group: PerformanceMetricGroup,
    into unavailable: inout [PerformanceMetricKey: UnavailablePerformanceMetricReason]
  ) {
    for key in group.keys {
      unavailable[key] = .disabled
    }
  }

  private static func saturatedJSONSafeSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let maximum = PerformanceDurationConversion.maximumJSONSafeUnsigned
    guard lhs < maximum, rhs < maximum, lhs <= maximum - rhs else { return maximum }
    return lhs + rhs
  }
}
