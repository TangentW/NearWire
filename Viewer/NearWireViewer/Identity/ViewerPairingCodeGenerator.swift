import Foundation
@_spi(NearWireInternal) import NearWireCore
import Security

struct ViewerPairingCodeGenerator: Sendable {
  static let live = ViewerPairingCodeGenerator { count in
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else { throw ViewerPairingCodeGenerationError() }
    return bytes
  }

  private static let alphabet = PairingCode.canonicalAlphabet
  private static let unbiasedUpperBound = UInt8((256 / alphabet.count) * alphabet.count)
  private let randomBytes: @Sendable (Int) throws -> [UInt8]

  init(randomBytes: @escaping @Sendable (Int) throws -> [UInt8]) {
    self.randomBytes = randomBytes
  }

  func generate() throws -> PairingCode {
    var result: [UInt8] = []
    result.reserveCapacity(PairingCode.canonicalLength)
    var batchCount = 0

    while result.count < PairingCode.canonicalLength {
      guard batchCount < 128 else { throw ViewerPairingCodeGenerationError() }
      batchCount += 1
      let bytes = try randomBytes(16)
      guard !bytes.isEmpty else { throw ViewerPairingCodeGenerationError() }
      for byte in bytes where byte < Self.unbiasedUpperBound {
        result.append(Self.alphabet[Int(byte) % Self.alphabet.count])
        if result.count == PairingCode.canonicalLength { break }
      }
    }
    return try PairingCode(String(decoding: result, as: UTF8.self))
  }
}

struct ViewerPairingCodeGenerationError: Error, Equatable, Sendable {}
