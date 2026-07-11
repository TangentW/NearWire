import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

@_spi(NearWireInternal)
public struct WireProtocolVersion: Codable, Equatable, Hashable, Comparable, Sendable {
  public static let v1 = WireProtocolVersion(unchecked: 1)
  public static let current = v1
  public static let minimumCompatible = v1

  public let rawValue: UInt16

  public init(_ rawValue: UInt16) throws {
    guard rawValue > 0 else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "version",
        message: "Wire protocol version must be nonzero."
      )
    }
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(UInt16.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private init(unchecked rawValue: UInt16) {
    self.rawValue = rawValue
  }
}

@_spi(NearWireInternal) public struct WireVersionRange: Equatable, Hashable, Sendable {
  public let minimum: WireProtocolVersion
  public let maximum: WireProtocolVersion

  public init(minimum: WireProtocolVersion, maximum: WireProtocolVersion) throws {
    guard minimum <= maximum else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "versions",
        message: "Minimum wire version cannot exceed maximum wire version."
      )
    }
    self.minimum = minimum
    self.maximum = maximum
  }

  public static let v1 = WireVersionRange(uncheckedMinimum: .v1, maximum: .v1)

  private init(uncheckedMinimum minimum: WireProtocolVersion, maximum: WireProtocolVersion) {
    self.minimum = minimum
    self.maximum = maximum
  }
}

@_spi(NearWireInternal) public enum WireLane: UInt8, Codable, Hashable, Sendable {
  case control = 0x01
  case event = 0x02
}

@_spi(NearWireInternal) public struct WireMessageType: Codable, Equatable, Hashable, Sendable {
  public static let hello = WireMessageType(unchecked: "hello")
  public static let helloAcknowledged = WireMessageType(unchecked: "hello.acknowledged")
  public static let connectionRejected = WireMessageType(unchecked: "connection.rejected")
  public static let flowPolicyOffer = WireMessageType(unchecked: "flow.policy.offer")
  public static let flowPolicyAccepted = WireMessageType(unchecked: "flow.policy.accepted")
  public static let ping = WireMessageType(unchecked: "ping")
  public static let pong = WireMessageType(unchecked: "pong")
  public static let disconnect = WireMessageType(unchecked: "disconnect")
  public static let error = WireMessageType(unchecked: "error")
  public static let event = WireMessageType(unchecked: "event")
  public static let eventBatch = WireMessageType(unchecked: "event.batch")
  public static let eventDropSummary = WireMessageType(unchecked: "event.drop-summary")

  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard (1...64).contains(rawValue.utf8.count) else {
      throw WireProtocolError(
        code: .invalidMessageType,
        path: "type",
        message: "Message type must use 1 through 64 UTF-8 bytes."
      )
    }
    let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
    guard
      segments.allSatisfy({ segment in
        guard let first = segment.utf8.first, (97...122).contains(first) else { return false }
        return segment.utf8.dropFirst().allSatisfy { byte in
          (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
        }
      })
    else {
      throw WireProtocolError(
        code: .invalidMessageType,
        path: "type",
        message: "Message type must contain lowercase dot-separated ASCII segments."
      )
    }
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }

  public var requiredLane: WireLane? {
    switch self {
    case .hello, .helloAcknowledged, .connectionRejected, .flowPolicyOffer,
      .flowPolicyAccepted, .ping, .pong, .disconnect, .error:
      return .control
    case .event, .eventBatch, .eventDropSummary:
      return .event
    default:
      return nil
    }
  }
}

@_spi(NearWireInternal)
public struct WireCodecIdentifier: Codable, Equatable, Hashable, Comparable, Sendable {
  public static let json = WireCodecIdentifier(unchecked: "json")

  public let rawValue: String

  public init(_ rawValue: String) throws {
    try WireValidation.validateToken(
      rawValue,
      maximumBytes: 32,
      path: "codec",
      errorCode: .invalidCodec
    )
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }
}

@_spi(NearWireInternal)
public struct WireCapability: Codable, Equatable, Hashable, Comparable, Sendable {
  public static let bidirectionalEvents = WireCapability(unchecked: "bidirectional-events")
  public static let normalQueue = WireCapability(unchecked: "normal-queue")
  public static let keepLatest = WireCapability(unchecked: "keep-latest")
  public static let batching = WireCapability(unchecked: "batching")
  public static let flowPolicy = WireCapability(unchecked: "flow-policy")
  public static let dropSummary = WireCapability(unchecked: "drop-summary")

  public let rawValue: String

  public init(_ rawValue: String) throws {
    try WireValidation.validateToken(
      rawValue,
      maximumBytes: 64,
      path: "capability",
      errorCode: .invalidCapability
    )
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }
}

@_spi(NearWireInternal)
public enum WireSendPolicy: String, Codable, CaseIterable, Comparable, Sendable {
  case normal
  case keepLatest = "keep-latest"

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

@_spi(NearWireInternal) public struct WireProductVersion: Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try WireValidation.validatePrintableASCII(
      rawValue,
      range: 1...64,
      path: "productVersion"
    )
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

@_spi(NearWireInternal) public struct WireFrameLimits: Equatable, Sendable {
  public static let encodedFrameOverheadBytes = 5
  public static let hardMaximumPayloadBytes = 16 * 1_024 * 1_024
  public static let hardMaximumEncodedFrameBytes =
    hardMaximumPayloadBytes + encodedFrameOverheadBytes
  public static let `default` = WireFrameLimits(
    uncheckedControlPayloadBytes: 64 * 1_024,
    eventPayloadBytes: 1_024 * 1_024
  )

  public let maximumControlPayloadBytes: Int
  public let maximumEventPayloadBytes: Int

  public init(
    maximumControlPayloadBytes: Int = 64 * 1_024,
    maximumEventPayloadBytes: Int = 1_024 * 1_024
  ) throws {
    guard (1...Self.hardMaximumPayloadBytes).contains(maximumControlPayloadBytes),
      (1...Self.hardMaximumPayloadBytes).contains(maximumEventPayloadBytes)
    else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "frameLimits",
        message: "Lane payload limits must be positive and at most 16 MiB."
      )
    }
    self.init(
      uncheckedControlPayloadBytes: maximumControlPayloadBytes,
      eventPayloadBytes: maximumEventPayloadBytes
    )
  }

  public func maximumPayloadBytes(for lane: WireLane) -> Int {
    switch lane {
    case .control: maximumControlPayloadBytes
    case .event: maximumEventPayloadBytes
    }
  }

  public func maximumEncodedFrameBytes(for lane: WireLane) -> Int {
    maximumPayloadBytes(for: lane) + Self.encodedFrameOverheadBytes
  }

  private init(uncheckedControlPayloadBytes: Int, eventPayloadBytes: Int) {
    maximumControlPayloadBytes = uncheckedControlPayloadBytes
    maximumEventPayloadBytes = eventPayloadBytes
  }
}

@_spi(NearWireInternal) public struct WireProtocolLimits: Equatable, Sendable {
  public static let `default` = WireProtocolLimits(
    uncheckedFrame: .default,
    maximumEventBytes: 256 * 1_024,
    maximumBatchEventCount: 256,
    maximumCollectionCount: 64,
    maximumControlTextBytes: 512,
    eventValidationLimits: .default
  )

  public let frame: WireFrameLimits
  public let maximumEventBytes: Int
  public let maximumBatchEventCount: Int
  public let maximumCollectionCount: Int
  public let maximumControlTextBytes: Int
  public let eventValidationLimits: EventValidationLimits

  public init(
    frame: WireFrameLimits = .default,
    maximumEventBytes: Int = 256 * 1_024,
    maximumBatchEventCount: Int = 256,
    maximumCollectionCount: Int = 64,
    maximumControlTextBytes: Int = 512,
    eventValidationLimits: EventValidationLimits = .default
  ) throws {
    guard (1...16_777_216).contains(maximumEventBytes),
      maximumEventBytes <= frame.maximumEventPayloadBytes
    else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "maximumEventBytes",
        message: "Event limit must be positive, at most 16 MiB, and fit the Event lane."
      )
    }
    guard (1...256).contains(maximumBatchEventCount),
      (1...1_024).contains(maximumCollectionCount),
      (1...4_096).contains(maximumControlTextBytes)
    else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "protocolLimits",
        message: "Protocol collection, batch, or text limits are outside hard bounds."
      )
    }
    self.frame = frame
    self.maximumEventBytes = maximumEventBytes
    self.maximumBatchEventCount = maximumBatchEventCount
    self.maximumCollectionCount = maximumCollectionCount
    self.maximumControlTextBytes = maximumControlTextBytes
    self.eventValidationLimits = eventValidationLimits
  }

  private init(
    uncheckedFrame frame: WireFrameLimits,
    maximumEventBytes: Int,
    maximumBatchEventCount: Int,
    maximumCollectionCount: Int,
    maximumControlTextBytes: Int,
    eventValidationLimits: EventValidationLimits
  ) {
    self.frame = frame
    self.maximumEventBytes = maximumEventBytes
    self.maximumBatchEventCount = maximumBatchEventCount
    self.maximumCollectionCount = maximumCollectionCount
    self.maximumControlTextBytes = maximumControlTextBytes
    self.eventValidationLimits = eventValidationLimits
  }
}

enum WireValidation {
  static func validateToken(
    _ value: String,
    maximumBytes: Int,
    path: String,
    errorCode: WireProtocolError.Code = .invalidText
  ) throws {
    guard (1...maximumBytes).contains(value.utf8.count),
      value.utf8.allSatisfy({ byte in
        (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
      })
    else {
      throw WireProtocolError(
        code: errorCode,
        path: path,
        message: "Expected a bounded lowercase ASCII token."
      )
    }
  }

  static func validatePrintableASCII(
    _ value: String,
    range: ClosedRange<Int>,
    path: String
  ) throws {
    guard range.contains(value.utf8.count),
      value.utf8.allSatisfy({ (32...126).contains($0) })
    else {
      throw WireProtocolError(
        code: .invalidText,
        path: path,
        message: "Expected bounded printable ASCII text."
      )
    }
  }

  static func validateHumanText(
    _ value: String,
    range: ClosedRange<Int>,
    path: String
  ) throws {
    guard range.contains(value.utf8.count),
      value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      throw WireProtocolError(
        code: .invalidText,
        path: path,
        message: "Expected bounded text without control characters."
      )
    }
  }
}
