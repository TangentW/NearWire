import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

@_spi(NearWireInternal) public struct WireNegotiationResult: Equatable, Sendable {
  public let selectedVersion: WireProtocolVersion
  public let selectedCodec: WireCodecIdentifier
  public let maximumEventBytes: Int
  public let capabilities: Set<WireCapability>
  public let sendPolicies: Set<WireSendPolicy>
  public let viewerInstallationID: EndpointID

}

@_spi(NearWireInternal) public enum WireNegotiator {
  public static func negotiate(
    local: WireHello,
    remote: WireHello
  ) throws -> WireNegotiationResult {
    guard local.role != remote.role else {
      throw WireProtocolError(
        code: .invalidRole,
        path: "hello.role",
        message: "Wire peers must have opposite App and Viewer roles."
      )
    }
    let minimum = max(local.versions.minimum, remote.versions.minimum)
    let maximum = min(local.versions.maximum, remote.versions.maximum)
    guard minimum <= maximum else {
      throw WireProtocolError(
        code: .incompatibleVersion,
        path: "hello.versions",
        message: "Wire protocol version intervals do not overlap."
      )
    }

    let commonCodecs = local.codecs.intersection(remote.codecs)
    guard commonCodecs.contains(.json) else {
      throw WireProtocolError(
        code: .noCommonCodec,
        path: "hello.codecs",
        message: "V1 peers require the JSON codec."
      )
    }
    let policies = local.sendPolicies.intersection(remote.sendPolicies)
    guard policies.contains(.normal) else {
      throw WireProtocolError(
        code: .invalidPolicy,
        path: "hello.sendPolicies",
        message: "V1 peers must share the normal send policy."
      )
    }

    return WireNegotiationResult(
      selectedVersion: maximum,
      selectedCodec: .json,
      maximumEventBytes: min(local.maximumEventBytes, remote.maximumEventBytes),
      capabilities: local.capabilities.intersection(remote.capabilities),
      sendPolicies: policies,
      viewerInstallationID: local.role == .viewer ? local.installationID : remote.installationID
    )
  }

  public static func makeAcknowledgement(
    result: WireNegotiationResult,
    sessionEpoch: SessionEpoch,
    limits: WireProtocolLimits = .default
  ) throws -> WireHelloAcknowledgement {
    guard result.selectedVersion == .v1 else {
      throw WireProtocolError(
        code: .incompatibleVersion,
        path: "negotiation.selectedVersion",
        message: "No acknowledgement codec is registered for the selected wire version."
      )
    }
    return try WireHelloAcknowledgement(
      selectedVersion: result.selectedVersion,
      selectedCodec: result.selectedCodec,
      maximumEventBytes: result.maximumEventBytes,
      capabilities: result.capabilities,
      sendPolicies: result.sendPolicies,
      viewerInstallationID: result.viewerInstallationID,
      sessionEpoch: sessionEpoch,
      limits: limits
    )
  }

  public static func validate(
    acknowledgement: WireHelloAcknowledgement,
    against result: WireNegotiationResult
  ) throws {
    guard acknowledgement.selectedVersion == result.selectedVersion,
      acknowledgement.selectedCodec == result.selectedCodec,
      acknowledgement.maximumEventBytes == result.maximumEventBytes,
      acknowledgement.capabilities == result.capabilities,
      acknowledgement.sendPolicies == result.sendPolicies,
      acknowledgement.viewerInstallationID == result.viewerInstallationID
    else {
      throw WireProtocolError(
        code: .acknowledgementEscalation,
        path: "helloAcknowledgement",
        message: "Acknowledgement differs from the negotiated intersection."
      )
    }
  }
}
