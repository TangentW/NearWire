import Foundation

@_spi(NearWireInternal) public enum WireErrorDisposition: String, Codable, Sendable {
  case operationRejected
  case connectionTerminal
}

@_spi(NearWireInternal) public struct WireProtocolError: Error, Equatable, Sendable {
  public enum Code: String, Codable, Sendable {
    case acknowledgementEscalation
    case arithmeticOverflow
    case callbackFailed
    case decoderFailed
    case eventExpired
    case frameTooLarge
    case incompatibleVersion
    case invalidBatch
    case invalidCapability
    case invalidClock
    case invalidCodec
    case invalidConfiguration
    case invalidFrameLength
    case invalidJSON
    case invalidLane
    case invalidMessage
    case invalidMessageType
    case invalidPolicy
    case invalidRate
    case invalidRole
    case invalidSequence
    case invalidText
    case noCommonCodec
    case phaseViolation
    case unsupportedMessageType
  }

  public let code: Code
  public let path: String
  public let message: String
  public let disposition: WireErrorDisposition

  public var isTerminal: Bool { disposition == .connectionTerminal }

  public init(
    code: Code,
    path: String = "$",
    message: String
  ) {
    self.code = code
    self.path = path
    self.message = message
    disposition = .operationRejected
  }

  init(
    code: Code,
    path: String = "$",
    message: String,
    disposition: WireErrorDisposition
  ) {
    self.code = code
    self.path = path
    self.message = message
    self.disposition = disposition
  }

  func asConnectionTerminal() -> Self {
    Self(
      code: code,
      path: path,
      message: message,
      disposition: .connectionTerminal
    )
  }
}

extension WireProtocolError: CustomStringConvertible {
  public var description: String {
    "\(code.rawValue) at \(path): \(message)"
  }
}
