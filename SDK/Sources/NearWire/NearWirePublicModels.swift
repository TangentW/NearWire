import Foundation

/// JSON-compatible event content that can be inspected without a concrete Codable type.
public indirect enum NearWireEventContent: Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([NearWireEventContent])
  case object([String: NearWireEventContent])
}

public enum NearWireEventPriority: String, CaseIterable, Sendable {
  case low
  case normal
  case high
  case critical
}

public enum NearWireEventDirection: String, Sendable {
  case appToViewer
  case viewerToApp
}

public enum NearWireSendPolicy: Equatable, Sendable {
  case normal
  case keepLatest(key: String)
}

/// A positive event lifetime. Values are validated when used in configuration or an event.
public enum NearWireEventTTL: Equatable, Sendable {
  case milliseconds(UInt64)
  case seconds(UInt64)
  case minutes(UInt64)

  public static let `default`: NearWireEventTTL = .seconds(60)
}

public struct NearWireEventOptions: Equatable, Sendable {
  public var priority: NearWireEventPriority
  public var ttl: NearWireEventTTL?

  public init(
    priority: NearWireEventPriority = .normal,
    ttl: NearWireEventTTL? = nil
  ) {
    self.priority = priority
    self.ttl = ttl
  }
}

public struct NearWireBufferConfiguration: Equatable, Sendable {
  public static let `default` = NearWireBufferConfiguration(
    validatedMaximumEventCount: 1_000,
    maximumBytes: 16 * 1_024 * 1_024,
    maximumEventBytes: 4_259_840,
    defaultTTL: .default
  )

  public let maximumEventCount: Int

  /// Maximum total encoded in-memory accounting bytes retained by the offline queue.
  public let maximumBytes: Int

  /// Maximum encoded in-memory accounting bytes for one Event.
  ///
  /// This includes the internal Event draft representation. Canonical JSON content has a separate
  /// fixed 1 MiB limit.
  public let maximumEventBytes: Int
  public let defaultTTL: NearWireEventTTL

  public init(
    maximumEventCount: Int = 1_000,
    maximumBytes: Int = 16 * 1_024 * 1_024,
    maximumEventBytes: Int,
    defaultTTL: NearWireEventTTL = .default
  ) throws {
    try SDKValidation.validateBuffer(
      maximumEventCount: maximumEventCount,
      maximumBytes: maximumBytes,
      maximumEventBytes: maximumEventBytes,
      defaultTTL: defaultTTL
    )
    self.init(
      validatedMaximumEventCount: maximumEventCount,
      maximumBytes: maximumBytes,
      maximumEventBytes: maximumEventBytes,
      defaultTTL: defaultTTL
    )
  }

  /// Creates a buffer whose implicit single-Event limit fits within the requested total.
  public init(
    maximumEventCount: Int = 1_000,
    maximumBytes: Int = 16 * 1_024 * 1_024,
    defaultTTL: NearWireEventTTL = .default
  ) throws {
    try self.init(
      maximumEventCount: maximumEventCount,
      maximumBytes: maximumBytes,
      maximumEventBytes: min(Self.default.maximumEventBytes, maximumBytes),
      defaultTTL: defaultTTL
    )
  }

  private init(
    validatedMaximumEventCount maximumEventCount: Int,
    maximumBytes: Int,
    maximumEventBytes: Int,
    defaultTTL: NearWireEventTTL
  ) {
    self.maximumEventCount = maximumEventCount
    self.maximumBytes = maximumBytes
    self.maximumEventBytes = maximumEventBytes
    self.defaultTTL = defaultTTL
  }
}

/// App-local policy for bounded recovery after a previously active connection ends.
public struct NearWireReconnectionPolicy: Equatable, Sendable {
  public static let disabled = NearWireReconnectionPolicy(
    isEnabled: false,
    maximumAttempts: 0,
    initialDelay: .zero,
    maximumDelay: .zero
  )

  public let isEnabled: Bool
  public let maximumAttempts: Int
  public let initialDelay: Duration
  public let maximumDelay: Duration

  public init(
    maximumAttempts: Int,
    initialDelay: Duration = .seconds(1),
    maximumDelay: Duration = .seconds(30)
  ) throws {
    try SDKValidation.validateReconnectionPolicy(
      maximumAttempts: maximumAttempts,
      initialDelay: initialDelay,
      maximumDelay: maximumDelay
    )
    self.init(
      isEnabled: true,
      maximumAttempts: maximumAttempts,
      initialDelay: initialDelay,
      maximumDelay: maximumDelay
    )
  }

  private init(
    isEnabled: Bool,
    maximumAttempts: Int,
    initialDelay: Duration,
    maximumDelay: Duration
  ) {
    self.isEnabled = isEnabled
    self.maximumAttempts = maximumAttempts
    self.initialDelay = initialDelay
    self.maximumDelay = maximumDelay
  }
}

public struct NearWireConfiguration: Equatable, Sendable {
  public static let `default` = NearWireConfiguration(
    validatedMaximumUplinkEventsPerSecond: 100,
    maximumDownlinkEventsPerSecond: 50,
    buffer: .default,
    eventStreamBufferCapacity: 256,
    reconnectionPolicy: .disabled
  )

  /// The App-local cap. A session later uses the minimum of this and the Viewer request.
  public let maximumUplinkEventsPerSecond: Double

  /// The App-local cap. A session later uses the minimum of this and the Viewer request.
  public let maximumDownlinkEventsPerSecond: Double

  public let buffer: NearWireBufferConfiguration
  public let eventStreamBufferCapacity: Int
  public let reconnectionPolicy: NearWireReconnectionPolicy

  public init(
    maximumUplinkEventsPerSecond: Double = 100,
    maximumDownlinkEventsPerSecond: Double = 50,
    buffer: NearWireBufferConfiguration = .default,
    eventStreamBufferCapacity: Int = 256,
    reconnectionPolicy: NearWireReconnectionPolicy = .disabled
  ) throws {
    try SDKValidation.validateRate(
      maximumUplinkEventsPerSecond,
      field: "maximumUplinkEventsPerSecond"
    )
    try SDKValidation.validateRate(
      maximumDownlinkEventsPerSecond,
      field: "maximumDownlinkEventsPerSecond"
    )
    guard (1...4_096).contains(eventStreamBufferCapacity) else {
      throw NearWireError(
        code: .invalidConfiguration,
        field: "eventStreamBufferCapacity",
        message: "Event stream capacity must be between 1 and 4,096."
      )
    }
    self.init(
      validatedMaximumUplinkEventsPerSecond: maximumUplinkEventsPerSecond,
      maximumDownlinkEventsPerSecond: maximumDownlinkEventsPerSecond,
      buffer: buffer,
      eventStreamBufferCapacity: eventStreamBufferCapacity,
      reconnectionPolicy: reconnectionPolicy
    )
  }

  private init(
    validatedMaximumUplinkEventsPerSecond maximumUplinkEventsPerSecond: Double,
    maximumDownlinkEventsPerSecond: Double,
    buffer: NearWireBufferConfiguration,
    eventStreamBufferCapacity: Int,
    reconnectionPolicy: NearWireReconnectionPolicy
  ) {
    self.maximumUplinkEventsPerSecond = maximumUplinkEventsPerSecond
    self.maximumDownlinkEventsPerSecond = maximumDownlinkEventsPerSecond
    self.buffer = buffer
    self.eventStreamBufferCapacity = eventStreamBufferCapacity
    self.reconnectionPolicy = reconnectionPolicy
  }
}

public enum NearWireState: String, Equatable, Sendable {
  case idle
  case discovering
  case connecting
  case connected
  case reconnecting
  case disconnected
  case shutdown
}

/// The newest supported connection lifecycle snapshot.
public struct NearWireConnectionStatus: Equatable, Sendable {
  public let state: NearWireState
  public let lastError: NearWireError?
  public let reconnectAttempt: Int?
  public let isSuspended: Bool

  internal init(
    state: NearWireState,
    lastError: NearWireError? = nil,
    reconnectAttempt: Int? = nil,
    isSuspended: Bool = false
  ) {
    self.state = state
    self.lastError = lastError
    self.reconnectAttempt = reconnectAttempt
    self.isSuspended = isSuspended
  }
}

public struct NearWireSessionMetadata: Equatable, Sendable {
  public let epoch: UUID
  public let sequence: UInt64
  public let sourceID: String
  public let targetID: String
  public let schemaVersion: UInt16
}

public struct NearWireEvent: Equatable, Sendable {
  public let id: UUID
  public let type: String
  public let content: NearWireEventContent
  public let createdAt: Date
  public let priority: NearWireEventPriority
  public let direction: NearWireEventDirection
  public let correlationID: UUID?
  public let replyToEventID: UUID?
  public let session: NearWireSessionMetadata?
  internal let originInstanceID: UUID?

  internal init(
    id: UUID,
    type: String,
    content: NearWireEventContent,
    createdAt: Date,
    priority: NearWireEventPriority,
    direction: NearWireEventDirection,
    correlationID: UUID? = nil,
    replyToEventID: UUID? = nil,
    session: NearWireSessionMetadata? = nil,
    originInstanceID: UUID? = nil
  ) {
    self.id = id
    self.type = type
    self.content = content
    self.createdAt = createdAt
    self.priority = priority
    self.direction = direction
    self.correlationID = correlationID
    self.replyToEventID = replyToEventID
    self.session = session
    self.originInstanceID = originInstanceID
  }

  public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
    try SDKContentConversion.decode(type, from: content)
  }

  public static func == (lhs: NearWireEvent, rhs: NearWireEvent) -> Bool {
    lhs.id == rhs.id
      && lhs.type == rhs.type
      && lhs.content == rhs.content
      && lhs.createdAt == rhs.createdAt
      && lhs.priority == rhs.priority
      && lhs.direction == rhs.direction
      && lhs.correlationID == rhs.correlationID
      && lhs.replyToEventID == rhs.replyToEventID
      && lhs.session == rhs.session
  }
}

public struct NearWireSendResult: Equatable, Sendable {
  public let eventID: UUID
  public let enqueuedAt: Date
  public let isBuffered: Bool
  public let coalescedEventID: UUID?
  public let expiredEventIDs: [UUID]
  public let overflowDroppedEventIDs: [UUID]
}

public struct NearWireBufferStatistics: Equatable, Sendable {
  public let submitted: UInt64
  public let transportAccepted: UInt64
  public let transportAdmissionRejected: UInt64
  public let overflowDropped: UInt64
  public let expired: UInt64
  public let coalesced: UInt64
  public let explicitlyCleared: UInt64
  public let routingDropped: UInt64
}

public struct NearWireBufferDiagnostics: Equatable, Sendable {
  public let eventCount: Int
  public let accountedByteCount: Int
  public let oldestWait: Duration?
  public let expiredEventIDs: [UUID]
  public let statistics: NearWireBufferStatistics
}

public struct NearWireClearResult: Equatable, Sendable {
  public let removedEventIDs: [UUID]
}
