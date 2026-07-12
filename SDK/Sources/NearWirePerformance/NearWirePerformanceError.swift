import Foundation

/// A stable, content-safe error produced by the optional performance monitor.
public struct NearWirePerformanceError: Error, Equatable, Sendable {
  public enum Code: String, Equatable, Sendable {
    case invalidConfiguration
    case monitorAlreadyRunning
    case unsupportedPlatform
    case collectorSetupFailed
    case eventSubmissionFailed
  }

  public let code: Code
  public let field: String?
  public let message: String

  init(code: Code, field: String? = nil, message: String) {
    self.code = code
    self.field = field
    self.message = message
  }
}

extension NearWirePerformanceError {
  static let invalidSampleInterval = NearWirePerformanceError(
    code: .invalidConfiguration,
    field: "sampleInterval",
    message: "The sample interval must be between 100 milliseconds and 60 seconds."
  )

  static let noMetricGroups = NearWirePerformanceError(
    code: .invalidConfiguration,
    field: "metricGroups",
    message: "At least one performance metric group must be enabled."
  )

  static let monitorAlreadyRunning = NearWirePerformanceError(
    code: .monitorAlreadyRunning,
    message: "Another performance monitor already uses this NearWire instance."
  )

  static let unsupportedPlatform = NearWirePerformanceError(
    code: .unsupportedPlatform,
    message: "Performance collection is available only on iOS."
  )

  static let collectorSetupFailed = NearWirePerformanceError(
    code: .collectorSetupFailed,
    message: "The performance collector could not be prepared."
  )

  static let eventSubmissionFailed = NearWirePerformanceError(
    code: .eventSubmissionFailed,
    message: "The performance snapshot could not enter the NearWire event queue."
  )
}
