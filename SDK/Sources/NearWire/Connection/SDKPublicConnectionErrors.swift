import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

enum SDKInstallationIdentityError: Error, Equatable, Sendable {
  case unavailable
}

enum SDKPublicConnectionErrorMapping {
  static func invalidPairingCode() -> NearWireError {
    NearWireError(
      code: .invalidPairingCode,
      field: "code",
      message:
        "The pairing code must contain \(PairingCode.canonicalLength) supported NearWire characters."
    )
  }

  static func connectionInProgress() -> NearWireError {
    NearWireError(
      code: .connectionInProgress,
      message: "This NearWire instance is already attempting a connection."
    )
  }

  static func alreadyConnected() -> NearWireError {
    NearWireError(
      code: .alreadyConnected,
      message: "This NearWire instance is already connected."
    )
  }

  static func connectionSuspended() -> NearWireError {
    NearWireError(
      code: .connectionSuspended,
      message: "This NearWire instance is suspended. Resume it before connecting."
    )
  }

  static func connectionIntentExists() -> NearWireError {
    NearWireError(
      code: .connectionIntentExists,
      message: "This NearWire instance already has a connection intent. Disconnect it first."
    )
  }

  static func invalidConnectionConfiguration(field: String) -> NearWireError {
    NearWireError(
      code: .invalidConfiguration,
      field: field,
      message: "The NearWire configuration cannot form a bounded connection plan."
    )
  }

  static func map(_ error: ProcessConnectionLeaseError) -> NearWireError {
    switch error.code {
    case .anotherConnectionIsActive:
      return NearWireError(
        code: .anotherConnectionIsActive,
        message: "Another NearWire instance owns the process connection."
      )
    case .runtimeUnavailable:
      return NearWireError(
        code: .connectionOwnershipUnavailable,
        message: "NearWire process connection ownership is unavailable."
      )
    }
  }

  static func map(_ error: SDKInstallationIdentityError) -> NearWireError {
    switch error {
    case .unavailable:
      return NearWireError(
        code: .connectionInternalFailure,
        message: "NearWire could not prepare its local connection identity."
      )
    }
  }

  static func map(_ code: SDKSessionAdmissionError.Code) -> NearWireError {
    switch code {
    case .cancelled, .pullCancelled:
      return .connectionCancelled
    case .discoveryTimedOut:
      return fixed(.discoveryTimedOut, "NearWire Viewer discovery timed out.")
    case .discoveryDenied:
      return fixed(.localNetworkDenied, "Local-network access was denied.")
    case .discoveryUnavailable, .discoveryFailed:
      return fixed(.discoveryUnavailable, "NearWire Viewer discovery is unavailable.")
    case .discoveryAmbiguous:
      return fixed(.discoveryAmbiguous, "More than one NearWire Viewer matched the code.")
    case .secureAdmissionTimedOut, .pumpAttachmentTimedOut, .policyNegotiationTimedOut:
      return fixed(.connectionTimedOut, "The NearWire secure connection timed out.")
    case .transportFailed, .ingressOverflow, .handshakeWorkLimitExceeded,
      .handoffWorkLimitExceeded, .handoffBufferOverflow, .activeIngressOverflow,
      .activeWorkLimitExceeded, .outboundEncodingFailed, .clockFailed:
      return fixed(.secureConnectionFailed, "The NearWire secure connection failed.")
    case .protocolViolation, .incompatiblePeer, .routeMismatch, .sequenceViolation:
      return fixed(.incompatibleViewer, "The NearWire Viewer is not protocol-compatible.")
    case .viewerIdentityMismatch:
      return fixed(
        .viewerIdentityMismatch,
        "The discovered Viewer and connected Viewer identifiers do not agree."
      )
    case .viewerRejected:
      return fixed(.viewerRejected, "The NearWire Viewer rejected this connection.")
    case .remoteClosed:
      return fixed(.connectionClosed, "The NearWire Viewer closed the connection.")
    case .invalidLocalConfiguration, .alreadyStarted, .alreadyAttached,
      .pullAlreadyPending, .policyConsumerClaimed, .terminationWaitAlreadyStarted,
      .terminationWaitCancelled, .ownerUnavailable:
      return fixed(
        .connectionInternalFailure,
        "NearWire could not complete its internal connection transition."
      )
    }
  }

  private static func fixed(_ code: NearWireError.Code, _ message: String) -> NearWireError {
    NearWireError(code: code, message: message)
  }
}
