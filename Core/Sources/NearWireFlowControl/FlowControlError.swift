import Foundation

public struct FlowControlError: Error, Equatable, Sendable {
  public enum Code: String, Codable, Sendable {
    case arithmeticOverflow
    case invalidBatchConfiguration
    case invalidClock
    case invalidEntry
    case invalidKeepLatestKey
    case invalidQueueConfiguration
    case invalidRate
    case invalidTokenCount
  }

  public let code: Code
  public let path: String
  public let message: String

  public init(code: Code, path: String = "$", message: String) {
    self.code = code
    self.path = path
    self.message = message
  }
}

extension FlowControlError: CustomStringConvertible {
  public var description: String {
    "\(code.rawValue) at \(path): \(message)"
  }
}
