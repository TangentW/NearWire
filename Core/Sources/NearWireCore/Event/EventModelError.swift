import Foundation

@_spi(NearWireInternal) public struct EventModelError: Error, Equatable, Sendable {
  public enum Code: String, Codable, Sendable {
    case contentDecodingFailed
    case contentEncodingFailed
    case encodedContentTooLarge
    case integerOutOfRange
    case invalidContent
    case invalidDirection
    case invalidEnvelope
    case invalidIdentifier
    case invalidLimits
    case invalidMetric
    case invalidSchemaVersion
    case invalidTimestamp
    case invalidTTL
    case invalidType
    case nonFiniteNumber
    case reservedType
    case structuralLimitExceeded
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

extension EventModelError: CustomStringConvertible {
  public var description: String {
    "\(code.rawValue) at \(path): \(message)"
  }
}
