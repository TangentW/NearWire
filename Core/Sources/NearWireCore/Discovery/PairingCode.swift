import Foundation

@_spi(NearWireInternal) public struct PairingCodeError: Error, Equatable, Sendable {
  public enum Code: String, Sendable {
    case invalidValue
  }

  public let code: Code

  public init(code: Code = .invalidValue) {
    self.code = code
  }
}

extension PairingCodeError: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "invalidPairingCode" }
  public var debugDescription: String { description }
}

@_spi(NearWireInternal) public struct PairingCode: Equatable, Hashable, Sendable {
  public static let canonicalLength = 6
  public static let maximumRawUTF8Length = 64

  private static let allowedBytes = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789".utf8)
  private let bytes: [UInt8]

  public init(_ rawValue: String) throws {
    var lengthIterator = rawValue.utf8.makeIterator()
    for index in 0...Self.maximumRawUTF8Length {
      guard lengthIterator.next() != nil else { break }
      if index == Self.maximumRawUTF8Length {
        throw PairingCodeError()
      }
    }

    var canonical: [UInt8] = []
    canonical.reserveCapacity(Self.canonicalLength)

    for byte in rawValue.utf8 {
      if byte == 45 || (9...13).contains(byte) || byte == 32 {
        continue
      }

      let uppercased: UInt8
      if (97...122).contains(byte) {
        uppercased = byte - 32
      } else {
        uppercased = byte
      }

      guard Self.allowedBytes.contains(uppercased), canonical.count < Self.canonicalLength
      else {
        throw PairingCodeError()
      }
      canonical.append(uppercased)
    }

    guard canonical.count == Self.canonicalLength else {
      throw PairingCodeError()
    }
    bytes = canonical
  }

  public var canonicalValue: String {
    String(decoding: bytes, as: UTF8.self)
  }
}

extension PairingCode: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String { "<redacted-pairing-code>" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}
