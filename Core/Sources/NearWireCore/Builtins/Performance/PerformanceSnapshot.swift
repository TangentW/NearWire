import Foundation

@_spi(NearWireInternal) public enum PerformanceSnapshotSchema {
  public static let version: UInt16 = 1
  public static let eventTypeRawValue = "nearwire.performance.snapshot"

  public static func eventType() throws -> EventType {
    try EventType.platform(eventTypeRawValue)
  }
}

@_spi(NearWireInternal)
public enum PerformanceMetricGroup: String, CaseIterable, Equatable, Hashable, Sendable {
  case process
  case display
  case device
  case transport

  public var keys: [PerformanceMetricKey] {
    switch self {
    case .process:
      return [.processCPUPercent, .processMemoryFootprintBytes]
    case .display:
      return [.displayEstimatedFramesPerSecond, .displayMaximumFramesPerSecond]
    case .device:
      return [
        .deviceBatteryLevel, .deviceBatteryState, .deviceThermalState,
        .deviceLowPowerModeEnabled, .deviceGPUUtilization, .devicePowerWatts,
        .deviceTemperatureCelsius,
      ]
    case .transport:
      return [
        .transportUplinkQueueDepth, .transportDroppedEventCount,
        .transportUplinkBytesPerSecond, .transportDownlinkBytesPerSecond,
        .transportDownlinkQueueDepth,
      ]
    }
  }
}

@_spi(NearWireInternal)
public enum PerformanceMetricKind: String, Equatable, Hashable, Sendable {
  case numeric
  case categorical
  case unavailableOnly
}

@_spi(NearWireInternal)
public enum PerformanceMetricKey: String, CaseIterable, Equatable, Hashable, Sendable {
  case processCPUPercent = "process.cpuPercent"
  case processMemoryFootprintBytes = "process.memoryFootprintBytes"
  case displayEstimatedFramesPerSecond = "display.estimatedFramesPerSecond"
  case displayMaximumFramesPerSecond = "display.maximumFramesPerSecond"
  case deviceBatteryLevel = "device.batteryLevel"
  case deviceBatteryState = "device.batteryState"
  case deviceThermalState = "device.thermalState"
  case deviceLowPowerModeEnabled = "device.lowPowerModeEnabled"
  case deviceGPUUtilization = "device.gpuUtilization"
  case devicePowerWatts = "device.powerWatts"
  case deviceTemperatureCelsius = "device.temperatureCelsius"
  case transportUplinkQueueDepth = "transport.uplinkQueueDepth"
  case transportDroppedEventCount = "transport.droppedEventCount"
  case transportUplinkBytesPerSecond = "transport.uplinkBytesPerSecond"
  case transportDownlinkBytesPerSecond = "transport.downlinkBytesPerSecond"
  case transportDownlinkQueueDepth = "transport.downlinkQueueDepth"

  public var group: PerformanceMetricGroup {
    switch self {
    case .processCPUPercent, .processMemoryFootprintBytes:
      return .process
    case .displayEstimatedFramesPerSecond, .displayMaximumFramesPerSecond:
      return .display
    case .deviceBatteryLevel, .deviceBatteryState, .deviceThermalState,
      .deviceLowPowerModeEnabled, .deviceGPUUtilization, .devicePowerWatts,
      .deviceTemperatureCelsius:
      return .device
    case .transportUplinkQueueDepth, .transportDroppedEventCount,
      .transportUplinkBytesPerSecond, .transportDownlinkBytesPerSecond,
      .transportDownlinkQueueDepth:
      return .transport
    }
  }

  public var kind: PerformanceMetricKind {
    switch self {
    case .deviceBatteryState, .deviceThermalState, .deviceLowPowerModeEnabled:
      return .categorical
    case .deviceGPUUtilization, .devicePowerWatts, .deviceTemperatureCelsius:
      return .unavailableOnly
    default:
      return .numeric
    }
  }
}

@_spi(NearWireInternal)
public struct ProcessPerformanceMetrics: Codable, Equatable, Hashable, Sendable {
  public let cpuPercent: Double?
  public let memoryFootprintBytes: UInt64?

  public init(cpuPercent: Double? = nil, memoryFootprintBytes: UInt64? = nil) throws {
    if let cpuPercent {
      try PerformanceMetricValidation.nonnegativeFinite(cpuPercent, path: "process.cpuPercent")
    }
    if let memoryFootprintBytes {
      try PerformanceMetricValidation.unsignedJSONInteger(
        memoryFootprintBytes,
        path: "process.memoryFootprintBytes"
      )
    }
    self.cpuPercent = cpuPercent
    self.memoryFootprintBytes = memoryFootprintBytes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      cpuPercent: container.decodeIfPresent(Double.self, forKey: .cpuPercent),
      memoryFootprintBytes: container.decodeIfPresent(UInt64.self, forKey: .memoryFootprintBytes)
    )
  }
}

@_spi(NearWireInternal)
public struct DisplayPerformanceMetrics: Codable, Equatable, Hashable, Sendable {
  public let estimatedFramesPerSecond: Double?
  public let maximumFramesPerSecond: Double?

  public init(
    estimatedFramesPerSecond: Double? = nil,
    maximumFramesPerSecond: Double? = nil
  ) throws {
    if let estimatedFramesPerSecond {
      try PerformanceMetricValidation.positiveFinite(
        estimatedFramesPerSecond,
        path: "display.estimatedFramesPerSecond"
      )
    }
    if let maximumFramesPerSecond {
      try PerformanceMetricValidation.positiveFinite(
        maximumFramesPerSecond,
        path: "display.maximumFramesPerSecond"
      )
    }
    self.estimatedFramesPerSecond = estimatedFramesPerSecond
    self.maximumFramesPerSecond = maximumFramesPerSecond
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      estimatedFramesPerSecond: container.decodeIfPresent(
        Double.self,
        forKey: .estimatedFramesPerSecond
      ),
      maximumFramesPerSecond: container.decodeIfPresent(
        Double.self,
        forKey: .maximumFramesPerSecond
      )
    )
  }
}

@_spi(NearWireInternal) public enum BatteryState: String, Codable, Equatable, Hashable, Sendable {
  case unknown
  case unplugged
  case charging
  case full

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self = BatteryState(rawValue: try container.decode(String.self)) ?? .unknown
  }
}

@_spi(NearWireInternal) public enum ThermalState: String, Codable, Equatable, Hashable, Sendable {
  case unknown
  case nominal
  case fair
  case serious
  case critical

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self = ThermalState(rawValue: try container.decode(String.self)) ?? .unknown
  }
}

@_spi(NearWireInternal)
public struct DevicePerformanceMetrics: Codable, Equatable, Hashable, Sendable {
  public let batteryLevel: Double?
  public let batteryState: BatteryState?
  public let thermalState: ThermalState?
  public let lowPowerModeEnabled: Bool?

  public init(
    batteryLevel: Double? = nil,
    batteryState: BatteryState? = nil,
    thermalState: ThermalState? = nil,
    lowPowerModeEnabled: Bool? = nil
  ) throws {
    if let batteryLevel {
      try PerformanceMetricValidation.finiteFraction(
        batteryLevel,
        path: "device.batteryLevel"
      )
    }
    self.batteryLevel = batteryLevel
    self.batteryState = batteryState
    self.thermalState = thermalState
    self.lowPowerModeEnabled = lowPowerModeEnabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      batteryLevel: container.decodeIfPresent(Double.self, forKey: .batteryLevel),
      batteryState: container.decodeIfPresent(BatteryState.self, forKey: .batteryState),
      thermalState: container.decodeIfPresent(ThermalState.self, forKey: .thermalState),
      lowPowerModeEnabled: container.decodeIfPresent(Bool.self, forKey: .lowPowerModeEnabled)
    )
  }
}

@_spi(NearWireInternal)
public struct TransportPerformanceMetrics: Codable, Equatable, Hashable, Sendable {
  public let uplinkBytesPerSecond: UInt64?
  public let downlinkBytesPerSecond: UInt64?
  public let uplinkQueueDepth: UInt64?
  public let downlinkQueueDepth: UInt64?
  public let droppedEventCount: UInt64?

  public init(
    uplinkBytesPerSecond: UInt64? = nil,
    downlinkBytesPerSecond: UInt64? = nil,
    uplinkQueueDepth: UInt64? = nil,
    downlinkQueueDepth: UInt64? = nil,
    droppedEventCount: UInt64? = nil
  ) throws {
    let values: [(UInt64?, String)] = [
      (uplinkBytesPerSecond, "transport.uplinkBytesPerSecond"),
      (downlinkBytesPerSecond, "transport.downlinkBytesPerSecond"),
      (uplinkQueueDepth, "transport.uplinkQueueDepth"),
      (downlinkQueueDepth, "transport.downlinkQueueDepth"),
      (droppedEventCount, "transport.droppedEventCount"),
    ]
    for (value, path) in values {
      if let value {
        try PerformanceMetricValidation.unsignedJSONInteger(value, path: path)
      }
    }
    self.uplinkBytesPerSecond = uplinkBytesPerSecond
    self.downlinkBytesPerSecond = downlinkBytesPerSecond
    self.uplinkQueueDepth = uplinkQueueDepth
    self.downlinkQueueDepth = downlinkQueueDepth
    self.droppedEventCount = droppedEventCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      uplinkBytesPerSecond: container.decodeIfPresent(UInt64.self, forKey: .uplinkBytesPerSecond),
      downlinkBytesPerSecond: container.decodeIfPresent(
        UInt64.self,
        forKey: .downlinkBytesPerSecond
      ),
      uplinkQueueDepth: container.decodeIfPresent(UInt64.self, forKey: .uplinkQueueDepth),
      downlinkQueueDepth: container.decodeIfPresent(UInt64.self, forKey: .downlinkQueueDepth),
      droppedEventCount: container.decodeIfPresent(UInt64.self, forKey: .droppedEventCount)
    )
  }
}

@_spi(NearWireInternal)
public enum UnavailablePerformanceMetricReason: String, Codable, Equatable, Hashable, Sendable {
  case unsupported
  case disabled
  case permissionDenied
  case temporarilyUnavailable
}

@_spi(NearWireInternal)
public struct UnavailablePerformanceMetric: Codable, Equatable, Hashable, Sendable {
  public let metric: String
  public let reason: UnavailablePerformanceMetricReason

  public init(metric: String, reason: UnavailablePerformanceMetricReason) throws {
    guard (1...128).contains(metric.utf8.count),
      metric.utf8.allSatisfy({ byte in
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
          || byte == 46 || byte == 95 || byte == 45
      })
    else {
      throw EventModelError(
        code: .invalidMetric,
        path: "unavailable.metric",
        message: "Metric key must use 1 through 128 supported ASCII bytes."
      )
    }
    self.metric = metric
    self.reason = reason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      metric: container.decode(String.self, forKey: .metric),
      reason: container.decode(UnavailablePerformanceMetricReason.self, forKey: .reason)
    )
  }
}

@_spi(NearWireInternal) public struct PerformanceSnapshot: Codable, Equatable, Hashable, Sendable {
  public let schemaVersion: UInt16
  public let sampledAt: Date
  public let sampleIntervalMilliseconds: UInt64
  public let process: ProcessPerformanceMetrics?
  public let display: DisplayPerformanceMetrics?
  public let device: DevicePerformanceMetrics?
  public let transport: TransportPerformanceMetrics?
  public let unavailable: [UnavailablePerformanceMetric]

  public init(
    schemaVersion: UInt16 = PerformanceSnapshotSchema.version,
    sampledAt: Date,
    sampleIntervalMilliseconds: UInt64,
    process: ProcessPerformanceMetrics? = nil,
    display: DisplayPerformanceMetrics? = nil,
    device: DevicePerformanceMetrics? = nil,
    transport: TransportPerformanceMetrics? = nil,
    unavailable: [UnavailablePerformanceMetric] = []
  ) throws {
    guard schemaVersion == PerformanceSnapshotSchema.version else {
      throw EventModelError(
        code: .invalidSchemaVersion,
        path: "schemaVersion",
        message: "Performance snapshot schema version must be 1."
      )
    }
    guard sampledAt.timeIntervalSinceReferenceDate.isFinite else {
      throw EventModelError(
        code: .invalidTimestamp,
        path: "sampledAt",
        message: "Sample timestamp must be finite."
      )
    }
    guard sampleIntervalMilliseconds > 0 else {
      throw EventModelError(
        code: .invalidMetric,
        path: "sampleIntervalMilliseconds",
        message: "Sample interval must be positive."
      )
    }
    try PerformanceMetricValidation.unsignedJSONInteger(
      sampleIntervalMilliseconds,
      path: "sampleIntervalMilliseconds"
    )
    self.schemaVersion = schemaVersion
    self.sampledAt = sampledAt
    self.sampleIntervalMilliseconds = sampleIntervalMilliseconds
    self.process = process
    self.display = display
    self.device = device
    self.transport = transport
    self.unavailable = unavailable
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
      sampledAt: container.decode(Date.self, forKey: .sampledAt),
      sampleIntervalMilliseconds: container.decode(
        UInt64.self,
        forKey: .sampleIntervalMilliseconds
      ),
      process: container.decodeIfPresent(ProcessPerformanceMetrics.self, forKey: .process),
      display: container.decodeIfPresent(DisplayPerformanceMetrics.self, forKey: .display),
      device: container.decodeIfPresent(DevicePerformanceMetrics.self, forKey: .device),
      transport: container.decodeIfPresent(
        TransportPerformanceMetrics.self,
        forKey: .transport
      ),
      unavailable: container.decodeIfPresent(
        [UnavailablePerformanceMetric].self,
        forKey: .unavailable
      ) ?? []
    )
  }
}

private enum PerformanceMetricValidation {
  static func nonnegativeFinite(_ value: Double, path: String) throws {
    guard value.isFinite, value >= 0 else {
      throw invalid(path: path, expectation: "a finite non-negative value")
    }
  }

  static func positiveFinite(_ value: Double, path: String) throws {
    guard value.isFinite, value > 0 else {
      throw invalid(path: path, expectation: "a finite positive value")
    }
  }

  static func finiteFraction(_ value: Double, path: String) throws {
    guard value.isFinite, (0...1).contains(value) else {
      throw invalid(path: path, expectation: "a finite value from 0 through 1")
    }
  }

  static func unsignedJSONInteger(_ value: UInt64, path: String) throws {
    guard value <= UInt64(Int64.max) else {
      throw invalid(
        path: path,
        expectation: "an unsigned value no greater than the signed 64-bit JSON limit"
      )
    }
  }

  private static func invalid(path: String, expectation: String) -> EventModelError {
    EventModelError(
      code: .invalidMetric,
      path: path,
      message: "Expected \(expectation)."
    )
  }
}
