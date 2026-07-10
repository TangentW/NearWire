import Foundation

public struct EventType: Codable, Hashable, Sendable {
  public enum Namespace: Sendable {
    case user
    case platform
  }

  public let rawValue: String

  public static func user(
    _ rawValue: String,
    limits: EventValidationLimits = .default
  ) throws -> EventType {
    try EventType(rawValue, namespace: .user, limits: limits)
  }

  public static func platform(
    _ rawValue: String,
    limits: EventValidationLimits = .default
  ) throws -> EventType {
    try EventType(rawValue, namespace: .platform, limits: limits)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    try Self.validateGrammar(rawValue, limits: decoder.nearWireEventValidationLimits)
    self.rawValue = rawValue
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public func validate(limits: EventValidationLimits = .default) throws {
    try Self.validateGrammar(rawValue, limits: limits)
  }

  private init(
    _ rawValue: String,
    namespace: Namespace,
    limits: EventValidationLimits
  ) throws {
    try Self.validateGrammar(rawValue, limits: limits)
    let reserved = Self.isReserved(rawValue)
    switch namespace {
    case .user where reserved:
      throw EventModelError(
        code: .reservedType,
        path: "type",
        message: "The nearwire namespace is reserved for platform events."
      )
    case .platform where !reserved:
      throw EventModelError(
        code: .reservedType,
        path: "type",
        message: "Platform events must use the nearwire namespace."
      )
    default:
      self.rawValue = rawValue
    }
  }

  private static func isReserved(_ rawValue: String) -> Bool {
    rawValue == "nearwire" || rawValue.hasPrefix("nearwire.")
  }

  private static func validateGrammar(
    _ rawValue: String,
    limits: EventValidationLimits
  ) throws {
    let byteCount = rawValue.utf8.count
    guard byteCount > 0, byteCount <= limits.maximumTypeBytes else {
      throw EventModelError(
        code: .invalidType,
        path: "type",
        message: "Event type must use 1 through \(limits.maximumTypeBytes) UTF-8 bytes."
      )
    }

    let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.allSatisfy({ Self.isValidSegment($0) }) else {
      throw EventModelError(
        code: .invalidType,
        path: "type",
        message: "Event type must contain dot-separated ASCII segments that start with a letter."
      )
    }
  }

  private static func isValidSegment(_ segment: Substring) -> Bool {
    guard let first = segment.utf8.first, Self.isASCIIAlpha(first) else {
      return false
    }
    return segment.utf8.dropFirst().allSatisfy {
      Self.isASCIIAlpha($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
    }
  }

  private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte)
  }
}
