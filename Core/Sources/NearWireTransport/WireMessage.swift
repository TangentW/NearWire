import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

struct WireMessage: Equatable, Sendable {
  let version: WireProtocolVersion
  let type: WireMessageType
  let body: JSONValue

  func deterministicPayloadData() throws -> Data {
    try JSONValue.object([
      "body": body,
      "type": .string(type.rawValue),
      "version": .integer(Int64(version.rawValue)),
    ]).deterministicData()
  }

  static func decode(
    from frame: WireFrame,
    limits: WireProtocolLimits = .default,
    expectedVersion: WireProtocolVersion? = nil
  ) throws -> WireMessage {
    guard frame.payload.count <= limits.frame.maximumPayloadBytes(for: frame.lane) else {
      throw WireProtocolError(
        code: .frameTooLarge,
        path: "payload",
        message: "Frame payload exceeds its lane limit."
      )
    }
    let eventLimits = try EventValidationLimits(
      maximumTypeBytes: 128,
      maximumContentDepth: 64,
      maximumArrayEntries: 100_000,
      maximumObjectEntries: 100_000,
      maximumStringBytes: 1_048_576,
      maximumObjectKeyBytes: 1_048_576,
      maximumEncodedContentBytes: limits.frame.maximumPayloadBytes(for: frame.lane),
      maximumEncodedModelBytes: min(
        134_217_728,
        limits.frame.maximumPayloadBytes(for: frame.lane) * 4 + 65_536
      )
    )
    let root: JSONValue
    do {
      root = try JSONValue.decodeJSON(from: frame.payload, limits: eventLimits)
      guard try root.deterministicData() == frame.payload else {
        throw WireProtocolError(
          code: .invalidJSON,
          path: "$",
          message: "Wire JSON must use the canonical deterministic representation."
        )
      }
    } catch let error as WireProtocolError {
      throw error
    } catch {
      throw WireProtocolError(
        code: .invalidJSON,
        path: "$",
        message: "Frame payload is not valid bounded wire JSON."
      )
    }
    let object = try WireJSON.object(root, path: "$")
    let versionValue = try WireJSON.required("version", in: object, path: "$")
    let version = try WireProtocolVersion(
      WireJSON.uint16IncludingZero(versionValue, path: "$.version")
    )
    if let expectedVersion, version != expectedVersion {
      throw WireProtocolError(
        code: .incompatibleVersion,
        path: "version",
        message: "Message version differs from the expected wire version."
      )
    }
    let typeValue = try WireJSON.required("type", in: object, path: "$")
    let body = try WireJSON.required("body", in: object, path: "$")
    let type = try WireMessageType(
      WireJSON.string(typeValue, path: "$.type")
    )
    if let requiredLane = type.requiredLane, requiredLane != frame.lane {
      throw WireProtocolError(
        code: .invalidLane,
        path: "lane",
        message: "Message type does not belong to this frame lane."
      )
    }
    return WireMessage(version: version, type: type, body: body)
  }
}

extension WireMessage: CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { "WireMessage(redacted, type: \(type.rawValue))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["type": type.rawValue], displayStyle: .struct)
  }
}

protocol WireMessagePayload: Sendable {
  static var messageType: WireMessageType { get }
  static var lane: WireLane { get }

  init(body: JSONValue, limits: WireProtocolLimits) throws
  func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue
}

enum WireMessageCodec {
  static func encode<Payload: WireMessagePayload>(
    _ payload: Payload,
    version: WireProtocolVersion,
    limits: WireProtocolLimits = .default
  ) throws -> Data {
    if let requiredLane = Payload.messageType.requiredLane,
      requiredLane != Payload.lane
    {
      throw WireProtocolError(
        code: .invalidLane,
        path: "lane",
        message: "Payload lane does not match its registered message type."
      )
    }
    let body = try payload.bodyJSON(limits: limits)
    let message = WireMessage(
      version: version,
      type: Payload.messageType,
      body: body
    )
    return try WireFrameEncoder.encode(
      lane: Payload.lane,
      payload: message.deterministicPayloadData(),
      limits: limits.frame
    )
  }

  static func decode<Payload: WireMessagePayload>(
    _ type: Payload.Type,
    from message: WireMessage,
    limits: WireProtocolLimits = .default
  ) throws -> Payload {
    guard message.type == Payload.messageType else {
      throw WireProtocolError(
        code: .invalidMessageType,
        path: "type",
        message: "Message type does not match the requested payload."
      )
    }
    do {
      return try Payload(body: message.body, limits: limits)
    } catch let error as WireProtocolError {
      throw error
    } catch {
      throw WireProtocolError(
        code: .invalidMessage,
        path: "body",
        message: "Message body violates the active model limits."
      )
    }
  }
}

@_spi(NearWireInternal) public enum WirePreHandshakeMessage: Equatable, Sendable {
  case hello(WireHello)
  case error(WireErrorPayload)
  case disconnect(WireDisconnect)
}

@_spi(NearWireInternal) public struct WirePreHandshakeCodec: Sendable {
  public let limits: WireProtocolLimits

  public init(limits: WireProtocolLimits = .default) {
    self.limits = limits
  }

  private func encodePayload<Payload: WireMessagePayload>(_ payload: Payload) throws -> Data {
    try WireMessageAdmission.validate(
      lane: Payload.lane,
      type: Payload.messageType,
      phase: .preHandshake,
      capabilities: []
    )
    return try WireMessageCodec.encode(payload, version: .v1, limits: limits)
  }

  public func encode(_ payload: WireHello) throws -> Data {
    try encodePayload(payload)
  }

  public func encode(_ payload: WireErrorPayload) throws -> Data {
    try encodePayload(payload)
  }

  public func encode(_ payload: WireDisconnect) throws -> Data {
    try encodePayload(payload)
  }

  public func decode(frame: WireFrame) throws -> WirePreHandshakeMessage {
    do {
      try WireMessageAdmission.preflight(
        lane: frame.lane,
        phase: .preHandshake,
        capabilities: []
      )
      let message = try WireMessage.decode(
        from: frame,
        limits: limits,
        expectedVersion: .v1
      )
      try WireMessageAdmission.validate(
        lane: frame.lane,
        type: message.type,
        phase: .preHandshake,
        capabilities: []
      )
      switch message.type {
      case .hello:
        return .hello(try WireMessageCodec.decode(WireHello.self, from: message, limits: limits))
      case .error:
        return .error(
          try WireMessageCodec.decode(WireErrorPayload.self, from: message, limits: limits)
        )
      case .disconnect:
        return .disconnect(
          try WireMessageCodec.decode(WireDisconnect.self, from: message, limits: limits)
        )
      default:
        throw WireProtocolError(
          code: .unsupportedMessageType,
          path: "type",
          message: "Message type is unavailable before handshake."
        )
      }
    } catch let error as WireProtocolError {
      throw error.asConnectionTerminal()
    }
  }
}

@_spi(NearWireInternal) public struct WireSessionCodec: Sendable {
  public let selectedVersion: WireProtocolVersion
  public let capabilities: Set<WireCapability>
  public let sendPolicies: Set<WireSendPolicy>
  public let limits: WireProtocolLimits

  public init(
    negotiation: WireNegotiationResult,
    baseLimits: WireProtocolLimits = .default
  ) throws {
    guard negotiation.selectedVersion == .v1 else {
      throw WireProtocolError(
        code: .incompatibleVersion,
        path: "negotiation.selectedVersion",
        message: "No session codec is registered for the negotiated wire version."
      )
    }
    guard negotiation.maximumEventBytes <= baseLimits.maximumEventBytes else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "negotiation.maximumEventBytes",
        message: "Negotiation cannot widen the local event-size limit."
      )
    }
    selectedVersion = negotiation.selectedVersion
    capabilities = negotiation.capabilities
    sendPolicies = negotiation.sendPolicies
    limits = try WireProtocolLimits(
      frame: baseLimits.frame,
      maximumEventBytes: negotiation.maximumEventBytes,
      maximumBatchEventCount: baseLimits.maximumBatchEventCount,
      maximumCollectionCount: baseLimits.maximumCollectionCount,
      maximumControlTextBytes: baseLimits.maximumControlTextBytes,
      eventValidationLimits: baseLimits.eventValidationLimits
    )
  }

  public static func encodeMaximumV1Pong(
    limits: WireProtocolLimits = .default
  ) throws -> Data {
    try WireMessageCodec.encode(
      WirePong(nonce: UInt64.max),
      version: .v1,
      limits: limits
    )
  }

  public func maximumEncodedSingleEventFrameBytes() throws -> Int {
    try Self.maximumEncodedV1SingleEventFrameBytes(
      maximumEventBytes: limits.maximumEventBytes,
      frameLimits: limits.frame
    )
  }

  public static func maximumEncodedV1SingleEventFrameBytes(
    maximumEventBytes: Int,
    frameLimits: WireFrameLimits
  ) throws -> Int {
    let placeholderBody = JSONValue.null
    let placeholderBodyBytes = try placeholderBody.deterministicData().count
    let placeholderMessageBytes = try WireMessage(
      version: .v1,
      type: .event,
      body: placeholderBody
    ).deterministicPayloadData().count
    let wrapperBytes = placeholderMessageBytes - placeholderBodyBytes
    let (payloadBytes, payloadOverflow) = maximumEventBytes.addingReportingOverflow(
      wrapperBytes
    )
    let (frameBytes, frameOverflow) = payloadBytes.addingReportingOverflow(
      WireFrameLimits.encodedFrameOverheadBytes
    )
    guard !payloadOverflow, !frameOverflow,
      payloadBytes <= frameLimits.maximumEventPayloadBytes
    else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "maximumEventBytes",
        message: "Maximum Event record cannot fit its fully encoded Event frame."
      )
    }
    return frameBytes
  }

  private func encodePayload<Payload: WireMessagePayload>(
    _ payload: Payload,
    phase: WireSessionPhase
  ) throws -> Data {
    try WireMessageAdmission.validate(
      lane: Payload.lane,
      type: Payload.messageType,
      phase: phase,
      capabilities: capabilities
    )
    return try WireMessageCodec.encode(
      payload,
      version: selectedVersion,
      limits: limits
    )
  }

  public func decode(
    frame: WireFrame,
    phase: WireSessionPhase
  ) throws -> WireAdmittedMessage {
    do {
      try WireMessageAdmission.preflight(
        lane: frame.lane,
        phase: phase,
        capabilities: capabilities
      )
      let message = try WireMessage.decode(
        from: frame,
        limits: limits,
        expectedVersion: selectedVersion
      )
      try WireMessageAdmission.validate(
        lane: frame.lane,
        type: message.type,
        phase: phase,
        capabilities: capabilities
      )
      return WireAdmittedMessage(message: message)
    } catch let error as WireProtocolError {
      throw error.asConnectionTerminal()
    }
  }

  private func decodePayload<Payload: WireMessagePayload>(
    _ type: Payload.Type,
    from admittedMessage: WireAdmittedMessage
  ) throws -> Payload {
    do {
      let message = admittedMessage.message
      guard message.version == selectedVersion else {
        throw WireProtocolError(
          code: .incompatibleVersion,
          path: "version",
          message: "Message version differs from the negotiated session version."
        )
      }
      try WireMessageAdmission.validateCapabilities(
        type: message.type,
        capabilities: capabilities
      )
      return try WireMessageCodec.decode(type, from: message, limits: limits)
    } catch let error as WireProtocolError {
      throw error.asConnectionTerminal()
    }
  }

  public func encode(_ payload: WireHello, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(
    _ payload: WireHelloAcknowledgement,
    phase: WireSessionPhase
  ) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(_ payload: WireConnectionRejected, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(_ payload: WireFlowPolicyOffer, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(_ payload: WireFlowPolicyAccepted, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(_ payload: WirePing, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(_ payload: WirePong, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(_ payload: WireDisconnect, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(_ payload: WireErrorPayload, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(_ payload: WireEventPayload, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(_ payload: WireEventBatchPayload, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func encode(_ payload: WireDropSummaryPayload, phase: WireSessionPhase) throws -> Data {
    try encodePayload(payload, phase: phase)
  }

  public func decode(
    _ type: WireHello.Type,
    from message: WireAdmittedMessage
  ) throws -> WireHello {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WireHelloAcknowledgement.Type,
    from message: WireAdmittedMessage
  ) throws -> WireHelloAcknowledgement {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WireConnectionRejected.Type,
    from message: WireAdmittedMessage
  ) throws -> WireConnectionRejected {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WireFlowPolicyOffer.Type,
    from message: WireAdmittedMessage
  ) throws -> WireFlowPolicyOffer {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WireFlowPolicyAccepted.Type,
    from message: WireAdmittedMessage
  ) throws -> WireFlowPolicyAccepted {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WirePing.Type,
    from message: WireAdmittedMessage
  ) throws -> WirePing {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WirePong.Type,
    from message: WireAdmittedMessage
  ) throws -> WirePong {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WireDisconnect.Type,
    from message: WireAdmittedMessage
  ) throws -> WireDisconnect {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WireErrorPayload.Type,
    from message: WireAdmittedMessage
  ) throws -> WireErrorPayload {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WireEventPayload.Type,
    from message: WireAdmittedMessage
  ) throws -> WireEventPayload {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WireEventBatchPayload.Type,
    from message: WireAdmittedMessage
  ) throws -> WireEventBatchPayload {
    try decodePayload(type, from: message)
  }

  public func decode(
    _ type: WireDropSummaryPayload.Type,
    from message: WireAdmittedMessage
  ) throws -> WireDropSummaryPayload {
    try decodePayload(type, from: message)
  }
}

@_spi(NearWireInternal) public struct WireAdmittedMessage: Sendable {
  fileprivate let message: WireMessage

  public var version: WireProtocolVersion { message.version }
  public var type: WireMessageType { message.type }
}

extension WireAdmittedMessage: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var description: String { "WireAdmittedMessage(redacted, type: \(type.rawValue))" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: ["type": type.rawValue], displayStyle: .struct)
  }
}

@_spi(NearWireInternal) public enum WireSessionPhase: String, Codable, Sendable {
  case preHandshake
  case awaitingApproval
  case negotiatingPolicy
  case active
  case closing
}

enum WireMessageAdmission {
  static func preflight(
    lane: WireLane,
    phase: WireSessionPhase,
    capabilities: Set<WireCapability>
  ) throws {
    guard lane == .event else { return }
    guard phase == .active else {
      throw WireProtocolError(
        code: .phaseViolation,
        path: "phase",
        message: "Event lane is unavailable before active state."
      )
    }
    guard capabilities.contains(.bidirectionalEvents) else {
      throw WireProtocolError(
        code: .unsupportedMessageType,
        path: "lane",
        message: "Event lane requires the bidirectional-events capability."
      )
    }
  }

  static func validate(
    lane: WireLane,
    type: WireMessageType,
    phase: WireSessionPhase,
    capabilities: Set<WireCapability>
  ) throws {
    try preflight(lane: lane, phase: phase, capabilities: capabilities)
    if let requiredLane = type.requiredLane, requiredLane != lane {
      throw WireProtocolError(
        code: .invalidLane,
        path: "lane",
        message: "Message type does not belong to this lane."
      )
    }
    guard type.requiredLane != nil else {
      throw WireProtocolError(
        code: .unsupportedMessageType,
        path: "type",
        message: "Unknown message types require an explicit future capability."
      )
    }

    try validateCapabilities(type: type, capabilities: capabilities)

    let allowed: Set<WireMessageType>
    switch phase {
    case .preHandshake:
      allowed = [.hello, .error, .disconnect]
    case .awaitingApproval:
      allowed = [
        .helloAcknowledged, .connectionRejected, .ping, .pong, .error, .disconnect,
      ]
    case .negotiatingPolicy:
      allowed = [
        .flowPolicyOffer, .flowPolicyAccepted, .ping, .pong, .error, .disconnect,
      ]
    case .active:
      allowed = [
        .flowPolicyOffer, .flowPolicyAccepted, .ping, .pong, .disconnect, .error,
        .event, .eventBatch, .eventDropSummary,
      ]
    case .closing:
      allowed = [.pong, .disconnect, .error]
    }
    guard allowed.contains(type) else {
      throw WireProtocolError(
        code: .phaseViolation,
        path: "phase",
        message: "Message type is not allowed in the current session phase."
      )
    }
  }

  static func validateCapabilities(
    type: WireMessageType,
    capabilities: Set<WireCapability>
  ) throws {
    let requiredCapabilities: Set<WireCapability>
    switch type {
    case .event:
      requiredCapabilities = [.bidirectionalEvents]
    case .eventBatch:
      requiredCapabilities = [.bidirectionalEvents, .batching]
    case .eventDropSummary:
      requiredCapabilities = [.bidirectionalEvents, .dropSummary]
    case .flowPolicyOffer, .flowPolicyAccepted:
      requiredCapabilities = [.flowPolicy]
    default:
      requiredCapabilities = []
    }
    guard requiredCapabilities.isSubset(of: capabilities) else {
      throw WireProtocolError(
        code: .unsupportedMessageType,
        path: "type",
        message: "Message type requires a capability absent from this session."
      )
    }
  }
}
