import Foundation

@_spi(NearWireInternal) public struct EventDraft: Codable, Equatable, Hashable, Sendable {
  public let type: EventType
  public let content: JSONValue
  public let priority: EventPriority
  public let ttl: EventTTL
  public let causality: EventCausality

  public init(
    type: EventType,
    content: JSONValue,
    priority: EventPriority = .normal,
    ttl: EventTTL = .default,
    causality: EventCausality = EventCausality(),
    limits: EventValidationLimits = .default
  ) throws {
    try type.validate(limits: limits)
    try content.validate(limits: limits)
    guard ttl.milliseconds <= limits.maximumTTLMilliseconds else {
      throw EventModelError(
        code: .invalidTTL,
        path: "ttlMilliseconds",
        message: "TTL exceeds the active validation limit."
      )
    }
    self.type = type
    self.content = content
    self.priority = priority
    self.ttl = ttl
    self.causality = causality
  }

  public init(from decoder: Decoder) throws {
    let limits = decoder.nearWireEventValidationLimits
    do {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        type: container.decode(EventType.self, forKey: .type),
        content: container.decode(JSONValue.self, forKey: .content),
        priority: container.decode(EventPriority.self, forKey: .priority),
        ttl: container.decode(EventTTL.self, forKey: .ttl),
        causality: container.decodeIfPresent(EventCausality.self, forKey: .causality)
          ?? EventCausality(),
        limits: limits
      )
    } catch let error as EventModelError {
      throw error
    } catch {
      throw EventModelError(
        code: .invalidEnvelope,
        message: "Unable to decode event draft: \(error.localizedDescription)"
      )
    }
  }

  public static func decode(
    from data: Data,
    limits: EventValidationLimits = .default
  ) throws -> EventDraft {
    try JSONValue.preflightJSONInput(
      data,
      maximumByteCount: limits.maximumEncodedModelBytes,
      maximumNestingDepth: limits.maximumContentDepth * 2 + 8,
      validateIntegerRange: false
    )
    let decoder = JSONDecoder()
    decoder.userInfo[.nearWireEventValidationLimits] = limits
    return try decoder.decode(EventDraft.self, from: data)
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case content
    case priority
    case ttl
    case causality
  }
}

extension EventDraft: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var description: String { "EventDraft(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .struct)
  }
}
