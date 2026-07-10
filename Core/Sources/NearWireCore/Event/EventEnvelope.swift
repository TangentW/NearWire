import Foundation

public struct EventEnvelope: Codable, Equatable, Hashable, Sendable {
  public let id: EventID
  public let type: EventType
  public let content: JSONValue
  public let createdAt: Date
  public let monotonicTimestampNanoseconds: UInt64
  public let source: EventEndpoint
  public let target: EventEndpoint
  public let direction: EventDirection
  public let sessionEpoch: SessionEpoch
  public let sequence: EventSequence
  public let priority: EventPriority
  public let ttl: EventTTL
  public let causality: EventCausality
  public let schemaVersion: EventSchemaVersion

  public init(
    id: EventID,
    type: EventType,
    content: JSONValue,
    createdAt: Date,
    monotonicTimestampNanoseconds: UInt64,
    source: EventEndpoint,
    target: EventEndpoint,
    direction: EventDirection,
    sessionEpoch: SessionEpoch,
    sequence: EventSequence,
    priority: EventPriority,
    ttl: EventTTL,
    causality: EventCausality,
    schemaVersion: EventSchemaVersion = .current,
    limits: EventValidationLimits = .default
  ) throws {
    guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
      throw EventModelError(
        code: .invalidTimestamp,
        path: "createdAt",
        message: "Wall-clock timestamp must be finite."
      )
    }
    try type.validate(limits: limits)
    try direction.validate(source: source, target: target)
    try content.validate(limits: limits)
    guard ttl.milliseconds <= limits.maximumTTLMilliseconds else {
      throw EventModelError(
        code: .invalidTTL,
        path: "ttlMilliseconds",
        message: "TTL exceeds the active validation limit."
      )
    }

    self.id = id
    self.type = type
    self.content = content
    self.createdAt = createdAt
    self.monotonicTimestampNanoseconds = monotonicTimestampNanoseconds
    self.source = source
    self.target = target
    self.direction = direction
    self.sessionEpoch = sessionEpoch
    self.sequence = sequence
    self.priority = priority
    self.ttl = ttl
    self.causality = causality
    self.schemaVersion = schemaVersion
  }

  public init(from decoder: Decoder) throws {
    let limits = decoder.nearWireEventValidationLimits
    do {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        id: container.decode(EventID.self, forKey: .id),
        type: container.decode(EventType.self, forKey: .type),
        content: container.decode(JSONValue.self, forKey: .content),
        createdAt: container.decode(Date.self, forKey: .createdAt),
        monotonicTimestampNanoseconds: container.decode(
          UInt64.self,
          forKey: .monotonicTimestampNanoseconds
        ),
        source: container.decode(EventEndpoint.self, forKey: .source),
        target: container.decode(EventEndpoint.self, forKey: .target),
        direction: container.decode(EventDirection.self, forKey: .direction),
        sessionEpoch: container.decode(SessionEpoch.self, forKey: .sessionEpoch),
        sequence: container.decode(EventSequence.self, forKey: .sequence),
        priority: container.decode(EventPriority.self, forKey: .priority),
        ttl: container.decode(EventTTL.self, forKey: .ttl),
        causality: container.decodeIfPresent(EventCausality.self, forKey: .causality)
          ?? EventCausality(),
        schemaVersion: container.decode(EventSchemaVersion.self, forKey: .schemaVersion),
        limits: limits
      )
    } catch let error as EventModelError {
      throw error
    } catch {
      throw EventModelError(
        code: .invalidEnvelope,
        message: "Unable to decode event envelope: \(error.localizedDescription)"
      )
    }
  }

  public static func decode(
    from data: Data,
    limits: EventValidationLimits = .default
  ) throws -> EventEnvelope {
    try JSONValue.preflightJSONInput(
      data,
      maximumByteCount: limits.maximumEncodedModelBytes,
      maximumNestingDepth: limits.maximumContentDepth * 2 + 8,
      validateIntegerRange: false
    )
    let decoder = JSONDecoder()
    decoder.userInfo[.nearWireEventValidationLimits] = limits
    return try decoder.decode(EventEnvelope.self, from: data)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case type
    case content
    case createdAt
    case monotonicTimestampNanoseconds
    case source
    case target
    case direction
    case sessionEpoch
    case sequence
    case priority
    case ttl
    case causality
    case schemaVersion
  }
}

public struct EventEnvelopeContext: Equatable, Hashable, Sendable {
  public let source: EventEndpoint
  public let target: EventEndpoint
  public let direction: EventDirection
  public let sessionEpoch: SessionEpoch
  public let sequence: EventSequence
  public let schemaVersion: EventSchemaVersion

  public init(
    source: EventEndpoint,
    target: EventEndpoint,
    direction: EventDirection,
    sessionEpoch: SessionEpoch,
    sequence: EventSequence,
    schemaVersion: EventSchemaVersion = .current
  ) throws {
    try direction.validate(source: source, target: target)
    self.source = source
    self.target = target
    self.direction = direction
    self.sessionEpoch = sessionEpoch
    self.sequence = sequence
    self.schemaVersion = schemaVersion
  }
}

public struct EventEnvelopeFactory: Sendable {
  public typealias WallClock = @Sendable () -> Date
  public typealias MonotonicClock = @Sendable () -> UInt64
  public typealias IdentifierGenerator = @Sendable () -> EventID

  private let wallClock: WallClock
  private let monotonicClock: MonotonicClock
  private let identifierGenerator: IdentifierGenerator

  public init(
    wallClock: @escaping WallClock = { Date() },
    monotonicClock: @escaping MonotonicClock = { DispatchTime.now().uptimeNanoseconds },
    identifierGenerator: @escaping IdentifierGenerator = { EventID() }
  ) {
    self.wallClock = wallClock
    self.monotonicClock = monotonicClock
    self.identifierGenerator = identifierGenerator
  }

  public func makeEnvelope(
    from draft: EventDraft,
    context: EventEnvelopeContext,
    limits: EventValidationLimits = .default
  ) throws -> EventEnvelope {
    try EventEnvelope(
      id: identifierGenerator(),
      type: draft.type,
      content: draft.content,
      createdAt: wallClock(),
      monotonicTimestampNanoseconds: monotonicClock(),
      source: context.source,
      target: context.target,
      direction: context.direction,
      sessionEpoch: context.sessionEpoch,
      sequence: context.sequence,
      priority: draft.priority,
      ttl: draft.ttl,
      causality: draft.causality,
      schemaVersion: context.schemaVersion,
      limits: limits
    )
  }
}
