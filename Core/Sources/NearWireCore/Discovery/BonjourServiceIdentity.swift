import CryptoKit
import Foundation

@_spi(NearWireInternal) public enum NearWireBonjour {
  public static let serviceType = "_nearwire._tcp"
  public static let localDomain = "local."
  public static let txtViewerIDKey = "vid"
  public static let maximumInstanceBytes = 63
  public static let maximumDomainBytes = 255
  public static let maximumRawResults = 256
  public static let maximumInterfacesPerResult = 32

  public static func instanceName(for pairingCode: PairingCode) -> String {
    "NearWire-\(pairingCode.canonicalValue)"
  }

  public static func canonicalType(_ rawValue: String) -> String? {
    guard
      hasBoundedASCII(rawValue, minimum: serviceType.utf8.count, maximum: serviceType.utf8.count),
      rawValue.lowercased() == serviceType
    else {
      return nil
    }
    return serviceType
  }

  public static func canonicalDomain(_ rawValue: String) -> String? {
    guard hasBoundedASCII(rawValue, minimum: 1, maximum: maximumDomainBytes)
    else {
      return nil
    }
    let lowered = rawValue.lowercased()
    guard lowered == "local" || lowered == localDomain else { return nil }
    return localDomain
  }

  public static func isSafeInstanceName(_ rawValue: String) -> Bool {
    var count = 0
    for byte in rawValue.utf8 {
      count += 1
      guard count <= maximumInstanceBytes, (33...126).contains(byte) else { return false }
    }
    return count >= 1
  }

  private static func hasBoundedASCII(
    _ rawValue: String,
    minimum: Int,
    maximum: Int
  ) -> Bool {
    var count = 0
    for byte in rawValue.utf8 {
      count += 1
      guard count <= maximum, byte < 128 else { return false }
    }
    return count >= minimum
  }
}

@_spi(NearWireInternal) public struct ViewerDiscoveryDiscriminator: Equatable, Hashable, Sendable {
  public static let encodedLength = 16
  private let bytes: [UInt8]

  public init(viewerInstallationID: EndpointID) {
    let digest = SHA256.hash(data: Data(viewerInstallationID.rawValue.utf8))
    bytes = digest.prefix(8).flatMap { byte in
      [Self.hexadecimal[Int(byte >> 4)], Self.hexadecimal[Int(byte & 0x0F)]]
    }
  }

  public init?(rawValue: String) {
    var candidate: [UInt8] = []
    candidate.reserveCapacity(Self.encodedLength)
    var iterator = rawValue.utf8.makeIterator()
    for index in 0...Self.encodedLength {
      guard let byte = iterator.next() else { break }
      guard index < Self.encodedLength,
        (48...57).contains(byte) || (97...102).contains(byte)
      else {
        return nil
      }
      candidate.append(byte)
    }
    guard candidate.count == Self.encodedLength else { return nil }
    bytes = candidate
  }

  public var rawValue: String {
    String(decoding: bytes, as: UTF8.self)
  }

  private static let hexadecimal = Array("0123456789abcdef".utf8)
}

extension ViewerDiscoveryDiscriminator: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public var description: String { "<redacted-viewer-discriminator>" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

@_spi(NearWireInternal) public struct NearWireBonjourServiceIdentity: Equatable, Hashable, Sendable
{
  public let instanceName: String
  public let type: String
  public let domain: String
  public let viewerDiscriminator: ViewerDiscoveryDiscriminator

  public init?(
    instanceName: String,
    type: String,
    domain: String,
    viewerDiscriminator: ViewerDiscoveryDiscriminator
  ) {
    guard NearWireBonjour.isSafeInstanceName(instanceName),
      let canonicalType = NearWireBonjour.canonicalType(type),
      let canonicalDomain = NearWireBonjour.canonicalDomain(domain)
    else {
      return nil
    }
    self.instanceName = instanceName
    self.type = canonicalType
    self.domain = canonicalDomain
    self.viewerDiscriminator = viewerDiscriminator
  }
}

extension NearWireBonjourServiceIdentity: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public var description: String { "<redacted-bonjour-service>" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}
