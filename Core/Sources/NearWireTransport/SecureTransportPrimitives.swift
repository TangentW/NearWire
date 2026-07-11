import Foundation

public enum SecureTransportRole: String, Codable, Sendable {
  case appClient
  case viewerServer
}

public enum SecureTransportState: String, Codable, Sendable {
  case setup
  case preparing
  case ready
  case closing
  case failed
  case cancelled
}

public enum SecureTransportDisposition: String, Codable, Sendable {
  case operationRejected
  case connectionTerminal
}

public struct SecureTransportError: Error, Equatable, Sendable {
  public enum Code: String, Codable, Sendable {
    case alreadyStarted
    case arithmeticOverflow
    case backpressure
    case cancelled
    case driverFailure
    case endOfStream
    case identityAdaptationFailed
    case invalidConfiguration
    case invalidDelivery
    case invalidState
    case listenerCreationFailed
    case trustEvaluationFailed
    case unsupportedTLS
  }

  public let code: Code
  public let path: String
  public let message: String
  public let disposition: SecureTransportDisposition

  public init(
    code: Code,
    path: String = "$",
    message: String,
    disposition: SecureTransportDisposition = .operationRejected
  ) {
    self.code = code
    self.path = path
    self.message = message
    self.disposition = disposition
  }
}

extension SecureTransportError: CustomStringConvertible {
  public var description: String {
    "\(code.rawValue) at \(path): \(message)"
  }
}

public struct SecureTransportLimits: Equatable, Sendable {
  public static let hardMaximumReceiveChunkBytes = 1_048_576
  public static let hardMaximumPendingSendCount = 4_096
  public static let hardMaximumPendingSendBytes = 64 * 1_024 * 1_024
  public static let hardMaximumSingleSendBytes = WireFrameLimits.hardMaximumEncodedFrameBytes
  public static let hardMaximumConnectionTimeoutSeconds = 120

  public static let `default` = SecureTransportLimits(
    uncheckedReceiveChunkBytes: 64 * 1_024,
    maximumPendingSendCount: 256,
    maximumPendingSendBytes: 4 * 1_024 * 1_024,
    maximumSingleSendBytes: WireFrameLimits.default.maximumEncodedFrameBytes(for: .event),
    connectionTimeoutSeconds: 10
  )

  public let receiveChunkBytes: Int
  public let maximumPendingSendCount: Int
  public let maximumPendingSendBytes: Int
  public let maximumSingleSendBytes: Int
  public let connectionTimeoutSeconds: Int

  public init(
    receiveChunkBytes: Int = 64 * 1_024,
    maximumPendingSendCount: Int = 256,
    maximumPendingSendBytes: Int = 4 * 1_024 * 1_024,
    maximumSingleSendBytes: Int = WireFrameLimits.default.maximumEncodedFrameBytes(for: .event),
    connectionTimeoutSeconds: Int = 10
  ) throws {
    guard (1...Self.hardMaximumReceiveChunkBytes).contains(receiveChunkBytes) else {
      throw Self.invalid("receiveChunkBytes")
    }
    guard (1...Self.hardMaximumPendingSendCount).contains(maximumPendingSendCount) else {
      throw Self.invalid("maximumPendingSendCount")
    }
    guard (1...Self.hardMaximumPendingSendBytes).contains(maximumPendingSendBytes) else {
      throw Self.invalid("maximumPendingSendBytes")
    }
    guard (1...Self.hardMaximumSingleSendBytes).contains(maximumSingleSendBytes),
      maximumSingleSendBytes <= maximumPendingSendBytes
    else {
      throw Self.invalid("maximumSingleSendBytes")
    }
    guard (1...Self.hardMaximumConnectionTimeoutSeconds).contains(connectionTimeoutSeconds) else {
      throw Self.invalid("connectionTimeoutSeconds")
    }
    self.init(
      uncheckedReceiveChunkBytes: receiveChunkBytes,
      maximumPendingSendCount: maximumPendingSendCount,
      maximumPendingSendBytes: maximumPendingSendBytes,
      maximumSingleSendBytes: maximumSingleSendBytes,
      connectionTimeoutSeconds: connectionTimeoutSeconds
    )
  }

  private init(
    uncheckedReceiveChunkBytes receiveChunkBytes: Int,
    maximumPendingSendCount: Int,
    maximumPendingSendBytes: Int,
    maximumSingleSendBytes: Int,
    connectionTimeoutSeconds: Int
  ) {
    self.receiveChunkBytes = receiveChunkBytes
    self.maximumPendingSendCount = maximumPendingSendCount
    self.maximumPendingSendBytes = maximumPendingSendBytes
    self.maximumSingleSendBytes = maximumSingleSendBytes
    self.connectionTimeoutSeconds = connectionTimeoutSeconds
  }

  private static func invalid(_ path: String) -> SecureTransportError {
    SecureTransportError(
      code: .invalidConfiguration,
      path: path,
      message: "Secure transport limit is outside its supported range."
    )
  }
}

public struct SecureTLSPlan: Equatable, Sendable {
  public static let v1 = SecureTLSPlan()

  public let requiresTLS = true
  public let orderedTCP = true
  public let minimumTLSVersion = "1.3"
  public let maximumTLSVersion = "1.3"
  public let applicationProtocols = ["nearwire/1"]
  public let includesPeerToPeer = true

  private init() {}
}
