import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireInternal) import NearWireTransport
#endif

enum SDKPublicConnectionPlanError: Error, Equatable, Sendable {
  case invalidMaximumEventBytes
}

struct SDKPublicConnectionLimitPlan: Sendable {
  let wireLimits: WireProtocolLimits
  let transportLimits: SecureTransportLimits
  let admissionLimits: SDKSessionAdmissionLimits
  let activeLimits: SDKActiveEventPumpLimits
  let maximumEventRecordBytes: Int
  let maximumEncodedEventFrameBytes: Int

  static func make(configuration: NearWireConfiguration) throws -> SDKPublicConnectionLimitPlan {
    do {
      let eventLimits = EventValidationLimits.default
      let recordBytes = try WireEventRecord.maximumDeterministicEncodedByteCount(
        eventLimits: eventLimits
      )
      let sizingFrame = try WireFrameLimits(
        maximumControlPayloadBytes: WireFrameLimits.default.maximumControlPayloadBytes,
        maximumEventPayloadBytes: WireFrameLimits.hardMaximumPayloadBytes
      )
      let sizingFrameBytes = try WireSessionCodec.maximumEncodedV1SingleEventFrameBytes(
        maximumEventBytes: recordBytes,
        frameLimits: sizingFrame
      )
      let requiredEventPayloadBytes = sizingFrameBytes - WireFrameLimits.encodedFrameOverheadBytes
      let frameLimits = try WireFrameLimits(
        maximumControlPayloadBytes: WireFrameLimits.default.maximumControlPayloadBytes,
        maximumEventPayloadBytes: max(
          WireFrameLimits.default.maximumEventPayloadBytes,
          requiredEventPayloadBytes
        )
      )
      let wireLimits = try WireProtocolLimits(
        frame: frameLimits,
        maximumEventBytes: recordBytes,
        maximumBatchEventCount: WireProtocolLimits.default.maximumBatchEventCount,
        maximumCollectionCount: WireProtocolLimits.default.maximumCollectionCount,
        maximumControlTextBytes: WireProtocolLimits.default.maximumControlTextBytes,
        eventValidationLimits: eventLimits
      )
      let eventFrameBytes = try WireSessionCodec.maximumEncodedV1SingleEventFrameBytes(
        maximumEventBytes: recordBytes,
        frameLimits: frameLimits
      )
      let controlFrameBytes = frameLimits.maximumEncodedFrameBytes(for: .control)
      let (reservedControlBytes, controlOverflow) = controlFrameBytes.multipliedReportingOverflow(
        by: 2
      )
      let (requiredPendingBytes, pendingOverflow) = reservedControlBytes.addingReportingOverflow(
        eventFrameBytes
      )
      guard !controlOverflow, !pendingOverflow else {
        throw SDKPublicConnectionPlanError.invalidMaximumEventBytes
      }
      let transportLimits = try SecureTransportLimits(
        receiveChunkBytes: SecureTransportLimits.default.receiveChunkBytes,
        maximumPendingSendCount: max(
          SecureTransportLimits.default.maximumPendingSendCount,
          3
        ),
        maximumPendingSendBytes: max(
          SecureTransportLimits.default.maximumPendingSendBytes,
          requiredPendingBytes
        ),
        maximumSingleSendBytes: max(
          SecureTransportLimits.default.maximumSingleSendBytes,
          eventFrameBytes,
          controlFrameBytes
        ),
        connectionTimeoutSeconds: SecureTransportLimits.default.connectionTimeoutSeconds
      )
      let defaults = SDKActiveEventPumpLimits.default
      let activeLimits = try SDKActiveEventPumpLimits(
        initialPolicyTimeoutSeconds: defaults.initialPolicyTimeoutSeconds,
        maximumIncomingEvents: defaults.maximumIncomingEvents,
        maximumIncomingEncodedBytes: max(defaults.maximumIncomingEncodedBytes, recordBytes),
        maximumCompletedFramesPerReceive: defaults.maximumCompletedFramesPerReceive,
        maximumOutboundServiceUnitsPerTurn: defaults.maximumOutboundServiceUnitsPerTurn,
        maximumOutboundAccountedBytesPerTurn: max(
          defaults.maximumOutboundAccountedBytesPerTurn,
          configuration.buffer.maximumEventBytes
        ),
        maximumIncomingPublicationsPerTurn: defaults.maximumIncomingPublicationsPerTurn,
        maximumDeferredPolicyTransactions: defaults.maximumDeferredPolicyTransactions
      )
      return SDKPublicConnectionLimitPlan(
        wireLimits: wireLimits,
        transportLimits: transportLimits,
        admissionLimits: .default,
        activeLimits: activeLimits,
        maximumEventRecordBytes: recordBytes,
        maximumEncodedEventFrameBytes: eventFrameBytes
      )
    } catch let error as SDKPublicConnectionPlanError {
      throw error
    } catch {
      throw SDKPublicConnectionPlanError.invalidMaximumEventBytes
    }
  }
}
