import Foundation

/// A stable, content-safe error produced by the supported NearWire SDK API.
public struct NearWireError: Error, Equatable, Sendable {
  public enum Code: String, Sendable {
    case invalidConfiguration
    case invalidEventType
    case invalidContent
    case contentEncodingFailed
    case contentDecodingFailed
    case invalidEventOptions
    case invalidReply
    case identifierGenerationFailed
    case eventTooLarge
    case bufferOperationFailed
    case streamOverflow
    case invalidPairingCode
    case connectionInProgress
    case alreadyConnected
    case anotherConnectionIsActive
    case connectionOwnershipUnavailable
    case connectionCancelled
    case discoveryTimedOut
    case localNetworkDenied
    case discoveryUnavailable
    case discoveryAmbiguous
    case connectionTimedOut
    case secureConnectionFailed
    case incompatibleViewer
    case viewerIdentityMismatch
    case viewerRejected
    case connectionClosed
    case connectionInternalFailure
    case shutdown
  }

  public let code: Code
  public let field: String?
  public let message: String

  internal init(code: Code, field: String? = nil, message: String) {
    self.code = code
    self.field = field
    self.message = message
  }
}

extension NearWireError: CustomStringConvertible {
  public var description: String {
    if let field {
      return "\(code.rawValue) at \(field): \(message)"
    }
    return "\(code.rawValue): \(message)"
  }
}

extension NearWireError {
  static let shutdown = NearWireError(
    code: .shutdown,
    message: "The NearWire instance has been shut down."
  )

  static let streamOverflow = NearWireError(
    code: .streamOverflow,
    message: "The event stream consumer exceeded its configured buffer."
  )

  static let connectionCancelled = NearWireError(
    code: .connectionCancelled,
    message: "The NearWire connection attempt was cancelled."
  )
}
