import Foundation

#if SWIFT_PACKAGE
  import NearWireCore
#endif

public struct WireHello: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.hello
  public static let lane = WireLane.control

  public let versions: WireVersionRange
  public let productVersion: WireProductVersion
  public let role: EndpointRole
  public let installationID: EndpointID
  public let codecs: Set<WireCodecIdentifier>
  public let maximumEventBytes: Int
  public let sendPolicies: Set<WireSendPolicy>
  public let capabilities: Set<WireCapability>
  public let displayName: String?
  public let applicationIdentifier: String?
  public let applicationVersion: String?

  public init(
    versions: WireVersionRange = .v1,
    productVersion: WireProductVersion,
    role: EndpointRole,
    installationID: EndpointID,
    codecs: Set<WireCodecIdentifier> = [.json],
    maximumEventBytes: Int = 256 * 1_024,
    sendPolicies: Set<WireSendPolicy> = [.normal, .keepLatest],
    capabilities: Set<WireCapability> = [
      .bidirectionalEvents, .normalQueue, .keepLatest, .batching, .flowPolicy,
      .dropSummary,
    ],
    displayName: String? = nil,
    applicationIdentifier: String? = nil,
    applicationVersion: String? = nil,
    limits: WireProtocolLimits = .default
  ) throws {
    guard !codecs.isEmpty, codecs.count <= limits.maximumCollectionCount else {
      throw WireProtocolError(
        code: .invalidCodec,
        path: "hello.codecs",
        message: "Hello must advertise a bounded nonempty codec set."
      )
    }
    guard (1...limits.maximumEventBytes).contains(maximumEventBytes) else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "hello.maximumEventBytes",
        message: "Hello event limit is outside the active protocol limit."
      )
    }
    guard !sendPolicies.isEmpty, sendPolicies.count <= WireSendPolicy.allCases.count,
      capabilities.count <= limits.maximumCollectionCount
    else {
      throw WireProtocolError(
        code: .invalidPolicy,
        path: "hello",
        message: "Hello policies or capabilities exceed their bounds."
      )
    }
    if let displayName {
      try WireValidation.validateHumanText(
        displayName,
        range: 1...128,
        path: "hello.displayName"
      )
    }
    if let applicationIdentifier {
      try WireValidation.validatePrintableASCII(
        applicationIdentifier,
        range: 1...128,
        path: "hello.applicationIdentifier"
      )
    }
    if let applicationVersion {
      try WireValidation.validatePrintableASCII(
        applicationVersion,
        range: 1...64,
        path: "hello.applicationVersion"
      )
    }
    self.versions = versions
    self.productVersion = productVersion
    self.role = role
    self.installationID = installationID
    self.codecs = codecs
    self.maximumEventBytes = maximumEventBytes
    self.sendPolicies = sendPolicies
    self.capabilities = capabilities
    self.displayName = displayName
    self.applicationIdentifier = applicationIdentifier
    self.applicationVersion = applicationVersion
  }

  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    let object = try WireJSON.object(body)
    let minimum = try WireProtocolVersion(
      WireJSON.uint16(
        WireJSON.required("minimumVersion", in: object, path: "body"),
        path: "body.minimumVersion"
      )
    )
    let maximum = try WireProtocolVersion(
      WireJSON.uint16(
        WireJSON.required("maximumVersion", in: object, path: "body"),
        path: "body.maximumVersion"
      )
    )
    let roleRaw = try WireJSON.string(
      WireJSON.required("role", in: object, path: "body"),
      path: "body.role"
    )
    guard let role = EndpointRole(rawValue: roleRaw) else {
      throw WireProtocolError(code: .invalidRole, path: "body.role", message: "Unknown role.")
    }
    let codecs = try Set(
      WireJSON.stringArray(
        WireJSON.required("codecs", in: object, path: "body"),
        path: "body.codecs",
        maximumCount: limits.maximumCollectionCount
      ).map(WireCodecIdentifier.init)
    )
    let policiesRaw = try WireJSON.stringArray(
      WireJSON.required("sendPolicies", in: object, path: "body"),
      path: "body.sendPolicies",
      maximumCount: limits.maximumCollectionCount
    )
    let policies = try Set(
      policiesRaw.map { raw in
        guard let policy = WireSendPolicy(rawValue: raw) else {
          throw WireProtocolError(
            code: .invalidPolicy,
            path: "body.sendPolicies",
            message: "Unknown send policy."
          )
        }
        return policy
      })
    let capabilities = try Set(
      WireJSON.stringArray(
        WireJSON.required("capabilities", in: object, path: "body"),
        path: "body.capabilities",
        maximumCount: limits.maximumCollectionCount
      ).map(WireCapability.init)
    )
    try self.init(
      versions: WireVersionRange(minimum: minimum, maximum: maximum),
      productVersion: WireProductVersion(
        WireJSON.string(
          WireJSON.required("productVersion", in: object, path: "body"),
          path: "body.productVersion"
        )
      ),
      role: role,
      installationID: decodeEndpointID(
        WireJSON.string(
          WireJSON.required("installationID", in: object, path: "body"),
          path: "body.installationID"
        ),
        path: "body.installationID"
      ),
      codecs: codecs,
      maximumEventBytes: WireJSON.positiveInt(
        WireJSON.required("maximumEventBytes", in: object, path: "body"),
        path: "body.maximumEventBytes"
      ),
      sendPolicies: policies,
      capabilities: capabilities,
      displayName: WireJSON.optionalString("displayName", in: object, path: "body"),
      applicationIdentifier: WireJSON.optionalString(
        "applicationIdentifier",
        in: object,
        path: "body"
      ),
      applicationVersion: WireJSON.optionalString(
        "applicationVersion",
        in: object,
        path: "body"
      ),
      limits: limits
    )
  }

  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue {
    _ = try WireHello(
      versions: versions,
      productVersion: productVersion,
      role: role,
      installationID: installationID,
      codecs: codecs,
      maximumEventBytes: maximumEventBytes,
      sendPolicies: sendPolicies,
      capabilities: capabilities,
      displayName: displayName,
      applicationIdentifier: applicationIdentifier,
      applicationVersion: applicationVersion,
      limits: limits
    )
    return .object([
      "applicationIdentifier": applicationIdentifier.map(JSONValue.string) ?? .null,
      "applicationVersion": applicationVersion.map(JSONValue.string) ?? .null,
      "capabilities": .array(capabilities.sorted().map { .string($0.rawValue) }),
      "codecs": .array(codecs.sorted().map { .string($0.rawValue) }),
      "displayName": displayName.map(JSONValue.string) ?? .null,
      "installationID": .string(installationID.rawValue),
      "maximumEventBytes": .integer(Int64(maximumEventBytes)),
      "maximumVersion": .integer(Int64(versions.maximum.rawValue)),
      "minimumVersion": .integer(Int64(versions.minimum.rawValue)),
      "productVersion": .string(productVersion.rawValue),
      "role": .string(role.rawValue),
      "sendPolicies": .array(sendPolicies.sorted().map { .string($0.rawValue) }),
    ])
  }
}

public struct WireHelloAcknowledgement: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.helloAcknowledged
  public static let lane = WireLane.control

  public let selectedVersion: WireProtocolVersion
  public let selectedCodec: WireCodecIdentifier
  public let maximumEventBytes: Int
  public let capabilities: Set<WireCapability>
  public let sendPolicies: Set<WireSendPolicy>
  public let viewerInstallationID: EndpointID
  public let sessionEpoch: SessionEpoch

  public init(
    selectedVersion: WireProtocolVersion,
    selectedCodec: WireCodecIdentifier,
    maximumEventBytes: Int,
    capabilities: Set<WireCapability>,
    sendPolicies: Set<WireSendPolicy>,
    viewerInstallationID: EndpointID,
    sessionEpoch: SessionEpoch,
    limits: WireProtocolLimits = .default
  ) throws {
    guard (1...limits.maximumEventBytes).contains(maximumEventBytes),
      capabilities.count <= limits.maximumCollectionCount,
      sendPolicies.count <= limits.maximumCollectionCount
    else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "helloAcknowledgement",
        message: "Acknowledgement values exceed active limits."
      )
    }
    self.selectedVersion = selectedVersion
    self.selectedCodec = selectedCodec
    self.maximumEventBytes = maximumEventBytes
    self.capabilities = capabilities
    self.sendPolicies = sendPolicies
    self.viewerInstallationID = viewerInstallationID
    self.sessionEpoch = sessionEpoch
  }

  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    let object = try WireJSON.object(body)
    let policiesRaw = try WireJSON.stringArray(
      WireJSON.required("sendPolicies", in: object, path: "body"),
      path: "body.sendPolicies",
      maximumCount: limits.maximumCollectionCount
    )
    let policies = try Set(
      policiesRaw.map { raw in
        guard let value = WireSendPolicy(rawValue: raw) else {
          throw WireProtocolError(
            code: .invalidPolicy, path: "body.sendPolicies", message: "Unknown policy.")
        }
        return value
      })
    try self.init(
      selectedVersion: WireProtocolVersion(
        WireJSON.uint16(
          WireJSON.required("selectedVersion", in: object, path: "body"),
          path: "body.selectedVersion"
        )
      ),
      selectedCodec: WireCodecIdentifier(
        WireJSON.string(
          WireJSON.required("selectedCodec", in: object, path: "body"),
          path: "body.selectedCodec"
        )
      ),
      maximumEventBytes: WireJSON.positiveInt(
        WireJSON.required("maximumEventBytes", in: object, path: "body"),
        path: "body.maximumEventBytes"
      ),
      capabilities: Set(
        try WireJSON.stringArray(
          WireJSON.required("capabilities", in: object, path: "body"),
          path: "body.capabilities",
          maximumCount: limits.maximumCollectionCount
        ).map(WireCapability.init)
      ),
      sendPolicies: policies,
      viewerInstallationID: decodeEndpointID(
        WireJSON.string(
          WireJSON.required("viewerInstallationID", in: object, path: "body"),
          path: "body.viewerInstallationID"
        ),
        path: "body.viewerInstallationID"
      ),
      sessionEpoch: decodeSessionEpoch(
        WireJSON.string(
          WireJSON.required("sessionEpoch", in: object, path: "body"),
          path: "body.sessionEpoch"
        ),
        path: "body.sessionEpoch"
      ),
      limits: limits
    )
  }

  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue {
    _ = try WireHelloAcknowledgement(
      selectedVersion: selectedVersion,
      selectedCodec: selectedCodec,
      maximumEventBytes: maximumEventBytes,
      capabilities: capabilities,
      sendPolicies: sendPolicies,
      viewerInstallationID: viewerInstallationID,
      sessionEpoch: sessionEpoch,
      limits: limits
    )
    return .object([
      "capabilities": .array(capabilities.sorted().map { .string($0.rawValue) }),
      "maximumEventBytes": .integer(Int64(maximumEventBytes)),
      "selectedCodec": .string(selectedCodec.rawValue),
      "selectedVersion": .integer(Int64(selectedVersion.rawValue)),
      "sendPolicies": .array(sendPolicies.sorted().map { .string($0.rawValue) }),
      "sessionEpoch": .string(sessionEpoch.rawValue),
      "viewerInstallationID": .string(viewerInstallationID.rawValue),
    ])
  }
}

public struct WireFlowPolicy: Equatable, Sendable {
  public let appUplinkEventsPerSecond: Double
  public let appDownlinkEventsPerSecond: Double

  public init(appUplinkEventsPerSecond: Double, appDownlinkEventsPerSecond: Double) throws {
    try Self.validate(appUplinkEventsPerSecond, path: "appUplinkEventsPerSecond")
    try Self.validate(appDownlinkEventsPerSecond, path: "appDownlinkEventsPerSecond")
    self.appUplinkEventsPerSecond = appUplinkEventsPerSecond == 0 ? 0 : appUplinkEventsPerSecond
    self.appDownlinkEventsPerSecond =
      appDownlinkEventsPerSecond == 0 ? 0 : appDownlinkEventsPerSecond
  }

  fileprivate init(body: JSONValue) throws {
    let object = try WireJSON.object(body)
    try self.init(
      appUplinkEventsPerSecond: WireJSON.double(
        WireJSON.required("appUplinkEventsPerSecond", in: object, path: "body"),
        path: "body.appUplinkEventsPerSecond"
      ),
      appDownlinkEventsPerSecond: WireJSON.double(
        WireJSON.required("appDownlinkEventsPerSecond", in: object, path: "body"),
        path: "body.appDownlinkEventsPerSecond"
      )
    )
  }

  fileprivate func bodyJSON() -> JSONValue {
    .object([
      "appDownlinkEventsPerSecond": .number(appDownlinkEventsPerSecond),
      "appUplinkEventsPerSecond": .number(appUplinkEventsPerSecond),
    ])
  }

  private static func validate(_ value: Double, path: String) throws {
    let isPaused = value == 0
    let isPositive = (0.000_000_001...100_000).contains(value)
    guard value.isFinite, isPaused || isPositive else {
      throw WireProtocolError(
        code: .invalidRate,
        path: path,
        message: "Rate must be zero or between 0.000000001 and 100,000."
      )
    }
  }
}

public struct WireFlowPolicyOffer: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.flowPolicyOffer
  public static let lane = WireLane.control
  public let policy: WireFlowPolicy

  public init(policy: WireFlowPolicy) { self.policy = policy }
  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    policy = try WireFlowPolicy(body: body)
  }
  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue { policy.bodyJSON() }
}

public struct WireFlowPolicyAccepted: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.flowPolicyAccepted
  public static let lane = WireLane.control
  public let policy: WireFlowPolicy

  public init(policy: WireFlowPolicy) { self.policy = policy }
  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    policy = try WireFlowPolicy(body: body)
  }
  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue { policy.bodyJSON() }
}

public struct WireNoncePayload: Equatable, Sendable {
  public let nonce: UInt64
  fileprivate init(nonce: UInt64) { self.nonce = nonce }
  fileprivate init(body: JSONValue) throws {
    let object = try WireJSON.object(body)
    nonce = try WireJSON.uint64(
      WireJSON.required("nonce", in: object, path: "body"),
      path: "body.nonce"
    )
  }
  fileprivate func bodyJSON() -> JSONValue { .object(["nonce": nonce.wireJSONValue]) }
}

public struct WirePing: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.ping
  public static let lane = WireLane.control
  public let nonce: UInt64
  public init(nonce: UInt64) { self.nonce = nonce }
  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    nonce = try WireNoncePayload(body: body).nonce
  }
  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue {
    WireNoncePayload(nonce: nonce).bodyJSON()
  }
}

public struct WirePong: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.pong
  public static let lane = WireLane.control
  public let nonce: UInt64
  public init(nonce: UInt64) { self.nonce = nonce }
  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    nonce = try WireNoncePayload(body: body).nonce
  }
  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue {
    WireNoncePayload(nonce: nonce).bodyJSON()
  }
}

public struct WireConnectionRejected: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.connectionRejected
  public static let lane = WireLane.control
  public let code: String
  public let message: String?

  public init(code: String, message: String? = nil, limits: WireProtocolLimits = .default) throws {
    try WireValidation.validateToken(code, maximumBytes: 64, path: "rejection.code")
    if let message {
      try WireValidation.validateHumanText(
        message,
        range: 1...limits.maximumControlTextBytes,
        path: "rejection.message"
      )
    }
    self.code = code
    self.message = message
  }

  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    let object = try WireJSON.object(body)
    try self.init(
      code: WireJSON.string(
        WireJSON.required("code", in: object, path: "body"),
        path: "body.code"
      ),
      message: WireJSON.optionalString("message", in: object, path: "body"),
      limits: limits
    )
  }

  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue {
    _ = try WireConnectionRejected(code: code, message: message, limits: limits)
    return .object([
      "code": .string(code),
      "message": message.map(JSONValue.string) ?? .null,
    ])
  }
}

public struct WireDisconnect: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.disconnect
  public static let lane = WireLane.control
  public let code: String
  public let reason: String?

  public init(code: String, reason: String? = nil, limits: WireProtocolLimits = .default) throws {
    try WireValidation.validateToken(code, maximumBytes: 64, path: "disconnect.code")
    if let reason {
      try WireValidation.validateHumanText(
        reason,
        range: 1...limits.maximumControlTextBytes,
        path: "disconnect.reason"
      )
    }
    self.code = code
    self.reason = reason
  }

  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    let object = try WireJSON.object(body)
    try self.init(
      code: WireJSON.string(
        WireJSON.required("code", in: object, path: "body"),
        path: "body.code"
      ),
      reason: WireJSON.optionalString("reason", in: object, path: "body"),
      limits: limits
    )
  }

  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue {
    _ = try WireDisconnect(code: code, reason: reason, limits: limits)
    return .object([
      "code": .string(code),
      "reason": reason.map(JSONValue.string) ?? .null,
    ])
  }
}

public struct WireErrorPayload: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.error
  public static let lane = WireLane.control
  public let code: String
  public let message: String
  public let isFatal: Bool
  public let relatedType: WireMessageType?

  public init(
    code: String,
    message: String,
    isFatal: Bool,
    relatedType: WireMessageType? = nil,
    limits: WireProtocolLimits = .default
  ) throws {
    try WireValidation.validateToken(code, maximumBytes: 64, path: "error.code")
    try WireValidation.validateHumanText(
      message,
      range: 1...limits.maximumControlTextBytes,
      path: "error.message"
    )
    self.code = code
    self.message = message
    self.isFatal = isFatal
    self.relatedType = relatedType
  }

  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    let object = try WireJSON.object(body)
    let related = try WireJSON.optionalString("relatedType", in: object, path: "body")
    try self.init(
      code: WireJSON.string(
        WireJSON.required("code", in: object, path: "body"),
        path: "body.code"
      ),
      message: WireJSON.string(
        WireJSON.required("message", in: object, path: "body"),
        path: "body.message"
      ),
      isFatal: WireJSON.bool(
        WireJSON.required("fatal", in: object, path: "body"),
        path: "body.fatal"
      ),
      relatedType: try related.map(WireMessageType.init),
      limits: limits
    )
  }

  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue {
    _ = try WireErrorPayload(
      code: code,
      message: message,
      isFatal: isFatal,
      relatedType: relatedType,
      limits: limits
    )
    return .object([
      "code": .string(code),
      "fatal": .bool(isFatal),
      "message": .string(message),
      "relatedType": relatedType.map { .string($0.rawValue) } ?? .null,
    ])
  }
}

private func decodeEndpointID(_ rawValue: String, path: String) throws -> EndpointID {
  do {
    return try EndpointID(rawValue: rawValue)
  } catch {
    throw WireJSON.invalid(path, "Endpoint identifier is invalid.")
  }
}

private func decodeSessionEpoch(_ rawValue: String, path: String) throws -> SessionEpoch {
  do {
    return try SessionEpoch(rawValue: rawValue)
  } catch {
    throw WireJSON.invalid(path, "Session epoch is invalid.")
  }
}
