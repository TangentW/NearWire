import Foundation

public struct EventID: Codable, Hashable, Sendable {
  public let rawValue: String

  public init() {
    rawValue = UUID().uuidString.lowercased()
  }

  public init(rawValue: String) throws {
    try Self.validate(rawValue, path: "id")
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  fileprivate static func validate(_ rawValue: String, path: String) throws {
    guard let uuid = UUID(uuidString: rawValue),
      uuid.uuidString.lowercased() == rawValue
    else {
      throw EventModelError(
        code: .invalidIdentifier,
        path: path,
        message: "Expected a canonical lowercase UUID."
      )
    }
  }
}

public struct SessionEpoch: Codable, Hashable, Sendable {
  public let rawValue: String

  public init() {
    rawValue = UUID().uuidString.lowercased()
  }

  public init(rawValue: String) throws {
    try EventID.validate(rawValue, path: "sessionEpoch")
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct EndpointID: Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) throws {
    guard (1...128).contains(rawValue.utf8.count),
      rawValue.utf8.allSatisfy({ byte in
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
          || byte == 46 || byte == 95 || byte == 45
      })
    else {
      throw EventModelError(
        code: .invalidIdentifier,
        path: "endpoint.id",
        message: "Endpoint ID must use 1 through 128 supported ASCII bytes."
      )
    }
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum EndpointRole: String, Codable, Hashable, Sendable {
  case app
  case viewer
}

public struct EventEndpoint: Codable, Hashable, Sendable {
  public let role: EndpointRole
  public let id: EndpointID

  public init(role: EndpointRole, id: EndpointID) {
    self.role = role
    self.id = id
  }
}

public enum EventDirection: String, Codable, Hashable, Sendable {
  case appToViewer
  case viewerToApp

  public func validate(source: EventEndpoint, target: EventEndpoint) throws {
    let expected: (EndpointRole, EndpointRole)
    switch self {
    case .appToViewer:
      expected = (.app, .viewer)
    case .viewerToApp:
      expected = (.viewer, .app)
    }
    guard source.role == expected.0, target.role == expected.1 else {
      throw EventModelError(
        code: .invalidDirection,
        path: "direction",
        message: "Source and target roles do not match \(rawValue)."
      )
    }
  }
}

public enum EventPriority: String, Codable, Hashable, Sendable {
  case low
  case normal
  case high
}

public struct EventSequence: Codable, Hashable, Sendable {
  public let rawValue: UInt64

  public init(_ rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public struct EventSchemaVersion: Codable, Hashable, Sendable {
  public static let current = EventSchemaVersion(unchecked: 1)

  public let rawValue: UInt16

  public init(_ rawValue: UInt16) throws {
    guard rawValue > 0 else {
      throw EventModelError(
        code: .invalidSchemaVersion,
        path: "schemaVersion",
        message: "Event schema version must be nonzero."
      )
    }
    self.rawValue = rawValue
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

public struct EventTTL: Codable, Hashable, Sendable {
  public static let `default` = EventTTL(unchecked: 60_000)

  public let milliseconds: UInt64

  public init(
    milliseconds: UInt64,
    limits: EventValidationLimits = .default
  ) throws {
    guard milliseconds > 0, milliseconds <= limits.maximumTTLMilliseconds else {
      throw EventModelError(
        code: .invalidTTL,
        path: "ttlMilliseconds",
        message: "TTL must be between 1 and \(limits.maximumTTLMilliseconds) milliseconds."
      )
    }
    self.milliseconds = milliseconds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(
      milliseconds: container.decode(UInt64.self),
      limits: decoder.nearWireEventValidationLimits
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(milliseconds)
  }

  public func isExpired(
    createdAtNanoseconds: UInt64,
    nowOnCreationClockNanoseconds: UInt64
  ) throws -> Bool {
    let (duration, multiplyOverflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
    let (deadline, addOverflow) = createdAtNanoseconds.addingReportingOverflow(duration)
    guard !multiplyOverflow, !addOverflow else {
      throw EventModelError(
        code: .invalidTTL,
        path: "ttlMilliseconds",
        message: "TTL cannot be represented on the monotonic clock."
      )
    }
    return nowOnCreationClockNanoseconds >= deadline
  }

  private init(unchecked milliseconds: UInt64) {
    self.milliseconds = milliseconds
  }
}

public struct EventCausality: Codable, Hashable, Sendable {
  public let correlationID: EventID?
  public let replyTo: EventID?

  public init(correlationID: EventID? = nil, replyTo: EventID? = nil) {
    self.correlationID = correlationID
    self.replyTo = replyTo
  }
}
