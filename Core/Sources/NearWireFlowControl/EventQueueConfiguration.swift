import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

@_spi(NearWireInternal) public struct KeepLatestKey: Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard (1...128).contains(rawValue.utf8.count),
      rawValue.unicodeScalars.allSatisfy({ scalar in
        !CharacterSet.controlCharacters.contains(scalar)
      })
    else {
      throw FlowControlError(
        code: .invalidKeepLatestKey,
        path: "policy.key",
        message: "Keep-latest key must use 1 through 128 UTF-8 bytes without control characters."
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
}

@_spi(NearWireInternal) public enum EventQueuePolicy: Codable, Equatable, Hashable, Sendable {
  case normal
  case keepLatest(KeepLatestKey)
}

@_spi(NearWireInternal) public struct EventQueueLimits: Equatable, Sendable {
  public static let `default` = EventQueueLimits(
    uncheckedMaximumEventCount: 1_000,
    maximumTotalBytes: 4 * 1_024 * 1_024,
    maximumSingleEventBytes: 256 * 1_024
  )

  public let maximumEventCount: Int
  public let maximumTotalBytes: Int
  public let maximumSingleEventBytes: Int

  public init(
    maximumEventCount: Int = 1_000,
    maximumTotalBytes: Int = 4 * 1_024 * 1_024,
    maximumSingleEventBytes: Int = 256 * 1_024
  ) throws {
    guard (1...10_000).contains(maximumEventCount) else {
      throw FlowControlError(
        code: .invalidQueueConfiguration,
        path: "maximumEventCount",
        message: "Queue event limit must be between 1 and 10,000."
      )
    }
    guard (1...536_870_912).contains(maximumTotalBytes) else {
      throw FlowControlError(
        code: .invalidQueueConfiguration,
        path: "maximumTotalBytes",
        message: "Queue byte limit must be between 1 and 512 MiB."
      )
    }
    guard (1...16_777_216).contains(maximumSingleEventBytes),
      maximumSingleEventBytes <= maximumTotalBytes
    else {
      throw FlowControlError(
        code: .invalidQueueConfiguration,
        path: "maximumSingleEventBytes",
        message:
          "Single-event limit must be positive, at most 16 MiB, and no larger than the queue."
      )
    }
    self.init(
      uncheckedMaximumEventCount: maximumEventCount,
      maximumTotalBytes: maximumTotalBytes,
      maximumSingleEventBytes: maximumSingleEventBytes
    )
  }

  private init(
    uncheckedMaximumEventCount: Int,
    maximumTotalBytes: Int,
    maximumSingleEventBytes: Int
  ) {
    maximumEventCount = uncheckedMaximumEventCount
    self.maximumTotalBytes = maximumTotalBytes
    self.maximumSingleEventBytes = maximumSingleEventBytes
  }
}

@_spi(NearWireInternal) public struct PendingEvent<Value: Sendable>: Sendable {
  public let id: EventID
  public let value: Value
  public let priority: EventPriority
  public let ttl: EventTTL
  public let policy: EventQueuePolicy
  public let accountedByteCount: Int
  public let enqueuedAtNanoseconds: UInt64
  public let expirationDeadlineNanoseconds: UInt64?

  public init(
    id: EventID,
    value: Value,
    priority: EventPriority = .normal,
    ttl: EventTTL = .default,
    policy: EventQueuePolicy = .normal,
    accountedByteCount: Int,
    enqueuedAtNanoseconds: UInt64,
    expirationDeadlineNanoseconds: UInt64? = nil
  ) throws {
    guard accountedByteCount > 0 else {
      throw FlowControlError(
        code: .invalidEntry,
        path: "accountedByteCount",
        message: "Accounted byte count must be positive."
      )
    }
    self.id = id
    self.value = value
    self.priority = priority
    self.ttl = ttl
    self.policy = policy
    self.accountedByteCount = accountedByteCount
    self.enqueuedAtNanoseconds = enqueuedAtNanoseconds
    self.expirationDeadlineNanoseconds = expirationDeadlineNanoseconds
  }
}

extension PendingEvent: Equatable where Value: Equatable {}
