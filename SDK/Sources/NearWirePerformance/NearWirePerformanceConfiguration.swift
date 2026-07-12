import Foundation

/// Immutable sampling and collector ownership settings for one performance monitor.
public struct NearWirePerformanceConfiguration: Equatable, Sendable {
  public static let `default` = NearWirePerformanceConfiguration(
    sampleInterval: .seconds(1),
    sampleIntervalNanoseconds: 1_000_000_000,
    processMetricsEnabled: true,
    displayMetricsEnabled: true,
    deviceMetricsEnabled: true,
    transportMetricsEnabled: true,
    managesBatteryMonitoring: true
  )

  public let sampleInterval: Duration
  public let processMetricsEnabled: Bool
  public let displayMetricsEnabled: Bool
  public let deviceMetricsEnabled: Bool
  public let transportMetricsEnabled: Bool
  public let managesBatteryMonitoring: Bool

  let sampleIntervalNanoseconds: UInt64

  public init(
    sampleInterval: Duration = .seconds(1),
    processMetricsEnabled: Bool = true,
    displayMetricsEnabled: Bool = true,
    deviceMetricsEnabled: Bool = true,
    transportMetricsEnabled: Bool = true,
    managesBatteryMonitoring: Bool = true
  ) throws {
    let interval = try NearWirePerformanceValidation.exactNanoseconds(sampleInterval)
    guard interval >= NearWirePerformanceValidation.minimumIntervalNanoseconds,
      interval <= NearWirePerformanceValidation.maximumIntervalNanoseconds
    else {
      throw NearWirePerformanceError.invalidSampleInterval
    }
    guard
      processMetricsEnabled || displayMetricsEnabled || deviceMetricsEnabled
        || transportMetricsEnabled
    else {
      throw NearWirePerformanceError.noMetricGroups
    }

    self.init(
      sampleInterval: sampleInterval,
      sampleIntervalNanoseconds: interval,
      processMetricsEnabled: processMetricsEnabled,
      displayMetricsEnabled: displayMetricsEnabled,
      deviceMetricsEnabled: deviceMetricsEnabled,
      transportMetricsEnabled: transportMetricsEnabled,
      managesBatteryMonitoring: managesBatteryMonitoring
    )
  }

  private init(
    sampleInterval: Duration,
    sampleIntervalNanoseconds: UInt64,
    processMetricsEnabled: Bool,
    displayMetricsEnabled: Bool,
    deviceMetricsEnabled: Bool,
    transportMetricsEnabled: Bool,
    managesBatteryMonitoring: Bool
  ) {
    self.sampleInterval = sampleInterval
    self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
    self.processMetricsEnabled = processMetricsEnabled
    self.displayMetricsEnabled = displayMetricsEnabled
    self.deviceMetricsEnabled = deviceMetricsEnabled
    self.transportMetricsEnabled = transportMetricsEnabled
    self.managesBatteryMonitoring = managesBatteryMonitoring
  }
}

enum NearWirePerformanceValidation {
  static let minimumIntervalNanoseconds: UInt64 = 100_000_000
  static let maximumIntervalNanoseconds: UInt64 = 60_000_000_000

  static func exactNanoseconds(_ duration: Duration) throws -> UInt64 {
    let components = duration.components
    guard components.seconds >= 0, components.attoseconds >= 0,
      components.attoseconds % 1_000_000_000 == 0
    else {
      throw NearWirePerformanceError.invalidSampleInterval
    }

    let (wholeSeconds, secondsOverflow) = UInt64(components.seconds)
      .multipliedReportingOverflow(by: 1_000_000_000)
    let fractional = UInt64(components.attoseconds / 1_000_000_000)
    let (nanoseconds, additionOverflow) = wholeSeconds.addingReportingOverflow(fractional)
    guard !secondsOverflow, !additionOverflow else {
      throw NearWirePerformanceError.invalidSampleInterval
    }
    return nanoseconds
  }
}
