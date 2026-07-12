import Foundation
import Security

struct ViewerCertificateMaterial: @unchecked Sendable {
  let certificate: SecCertificate
  let privateKey: SecKey
  let serial: Data
  let notBefore: Date
  let notAfter: Date
  let der: Data
}

struct ViewerCertificateProfile: Equatable, Sendable {
  let serial: Data
  let notBefore: Date
  let notAfter: Date
  let publicKeyBytes: Data
}

enum ViewerCertificateError: Error, Equatable, Sendable {
  case randomUnavailable
  case keyUnavailable
  case encodingFailed
  case signingFailed
  case invalidCertificate
  case invalidProfile
  case invalidSignature
  case keyMismatch
  case trustFailed
  case invalidValidity
}

struct ViewerCertificateBuilder: Sendable {
  static let commonName = "NearWire Viewer Local TLS"
  static let lifetime: TimeInterval = 3_650 * 24 * 60 * 60
  static let validityBackdate: TimeInterval = 5 * 60
  static let renewalWindow: TimeInterval = 30 * 24 * 60 * 60

  static let live = ViewerCertificateBuilder(
    randomBytes: { count in
      var bytes = [UInt8](repeating: 0, count: count)
      guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw ViewerCertificateError.randomUnavailable
      }
      return bytes
    },
    now: { Date() }
  )

  let randomBytes: @Sendable (Int) throws -> [UInt8]
  let now: @Sendable () -> Date

  func createPrivateKey(
    applicationTag: Data,
    useDataProtectionKeychain: Bool = true
  ) throws -> SecKey {
    var attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits: 256,
      kSecUseDataProtectionKeychain: useDataProtectionKeychain,
      kSecAttrApplicationTag: applicationTag,
      kSecAttrIsPermanent: true,
      kSecAttrIsSensitive: true,
      kSecAttrIsExtractable: false,
    ]
    if useDataProtectionKeychain {
      attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw ViewerCertificateError.keyUnavailable
    }
    return key
  }

  func createEphemeralPrivateKey() throws -> SecKey {
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits: 256,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw ViewerCertificateError.keyUnavailable
    }
    return key
  }

  func build(privateKey: SecKey) throws -> ViewerCertificateMaterial {
    guard let publicKey = SecKeyCopyPublicKey(privateKey),
      let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
    else {
      throw ViewerCertificateError.keyUnavailable
    }

    var serialBytes = try randomBytes(16)
    guard serialBytes.count == 16 else { throw ViewerCertificateError.randomUnavailable }
    serialBytes[0] &= 0x7F
    if serialBytes[0] == 0 { serialBytes[0] = 1 }
    let serial = Data(serialBytes)
    let creationDate = Date(timeIntervalSince1970: floor(now().timeIntervalSince1970))
    let notBefore = creationDate.addingTimeInterval(-Self.validityBackdate)
    let notAfter = creationDate.addingTimeInterval(Self.lifetime)
    let tbs = try Self.makeTBS(
      serial: serial,
      notBefore: notBefore,
      notAfter: notAfter,
      publicKeyBytes: publicBytes
    )

    var signingError: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        privateKey,
        .ecdsaSignatureMessageX962SHA256,
        tbs as CFData,
        &signingError
      ) as Data?
    else {
      throw ViewerCertificateError.signingFailed
    }

    let certificateDER = ViewerDER.sequence([
      tbs,
      Self.signatureAlgorithm,
      ViewerDER.bitString(signature),
    ])
    guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
      throw ViewerCertificateError.invalidCertificate
    }
    _ = try validate(
      certificate: certificate,
      privateKey: privateKey,
      at: creationDate,
      requireRenewalHeadroom: false
    )
    return ViewerCertificateMaterial(
      certificate: certificate,
      privateKey: privateKey,
      serial: serial,
      notBefore: notBefore,
      notAfter: notAfter,
      der: certificateDER
    )
  }

  func validate(
    certificate: SecCertificate,
    privateKey: SecKey,
    at date: Date? = nil,
    requireRenewalHeadroom: Bool = true
  ) throws -> ViewerCertificateProfile {
    let validationDate = date ?? now()
    let parsed = try validateOwnership(certificate: certificate, privateKey: privateKey)
    guard parsed.notBefore <= validationDate, validationDate <= parsed.notAfter else {
      throw ViewerCertificateError.invalidValidity
    }
    if requireRenewalHeadroom,
      parsed.notAfter.timeIntervalSince(validationDate) < Self.renewalWindow
    {
      throw ViewerCertificateError.invalidValidity
    }
    try Self.evaluateTrust(certificate: certificate, at: validationDate)
    return parsed
  }

  func validateOwnership(
    certificate: SecCertificate,
    privateKey: SecKey
  ) throws -> ViewerCertificateProfile {
    let der = SecCertificateCopyData(certificate) as Data
    let parsed = try Self.parseFixedProfile(der)
    guard let certificateKey = SecCertificateCopyKey(certificate),
      let certificateKeyBytes = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
      let privatePublicKey = SecKeyCopyPublicKey(privateKey),
      let privatePublicBytes = SecKeyCopyExternalRepresentation(privatePublicKey, nil) as Data?,
      certificateKeyBytes == parsed.publicKeyBytes,
      privatePublicBytes == parsed.publicKeyBytes
    else {
      throw ViewerCertificateError.keyMismatch
    }

    try Self.verifySelfSignature(der: der, publicKey: certificateKey)
    let trustDate = parsed.notBefore.addingTimeInterval(1)
    try Self.evaluateTrust(certificate: certificate, at: trustDate)
    return parsed
  }

  private static func makeTBS(
    serial: Data,
    notBefore: Date,
    notAfter: Date,
    publicKeyBytes: Data
  ) throws -> Data {
    guard serial.count == 16, serial.first.map({ $0 < 0x80 }) == true,
      serial.contains(where: { $0 != 0 }), publicKeyBytes.count == 65,
      publicKeyBytes.first == 0x04
    else {
      throw ViewerCertificateError.encodingFailed
    }
    let validity = ViewerDER.sequence([
      try ViewerDER.time(notBefore),
      try ViewerDER.time(notAfter),
    ])
    let subjectPublicKeyInfo = ViewerDER.sequence([
      ViewerDER.sequence([
        ViewerDER.objectIdentifier([1, 2, 840, 10_045, 2, 1]),
        ViewerDER.objectIdentifier([1, 2, 840, 10_045, 3, 1, 7]),
      ]),
      ViewerDER.bitString(publicKeyBytes),
    ])
    return ViewerDER.sequence([
      ViewerDER.contextSpecific(0, contents: ViewerDER.integer(Data([2]))),
      ViewerDER.integer(serial),
      signatureAlgorithm,
      distinguishedName,
      validity,
      distinguishedName,
      subjectPublicKeyInfo,
      ViewerDER.contextSpecific(3, contents: extensions),
    ])
  }

  private static let signatureAlgorithm = ViewerDER.sequence([
    ViewerDER.objectIdentifier([1, 2, 840, 10_045, 4, 3, 2])
  ])

  private static let distinguishedName = ViewerDER.sequence([
    ViewerDER.set([
      ViewerDER.sequence([
        ViewerDER.objectIdentifier([2, 5, 4, 3]),
        ViewerDER.utf8String(commonName),
      ])
    ])
  ])

  private static let extensions = ViewerDER.sequence([
    ViewerDER.sequence([
      ViewerDER.objectIdentifier([2, 5, 29, 19]),
      ViewerDER.boolean(true),
      ViewerDER.octetString(ViewerDER.sequence([])),
    ]),
    ViewerDER.sequence([
      ViewerDER.objectIdentifier([2, 5, 29, 15]),
      ViewerDER.boolean(true),
      ViewerDER.octetString(ViewerDER.bitString(Data([0x80]), unusedBits: 7)),
    ]),
    ViewerDER.sequence([
      ViewerDER.objectIdentifier([2, 5, 29, 37]),
      ViewerDER.octetString(
        ViewerDER.sequence([
          ViewerDER.objectIdentifier([1, 3, 6, 1, 5, 5, 7, 3, 1])
        ])
      ),
    ]),
  ])

  private static func parseFixedProfile(_ der: Data) throws -> ViewerCertificateProfile {
    let certificateNode = try ViewerDERReader.singleNode(der)
    guard certificateNode.tag == 0x30 else { throw ViewerCertificateError.invalidProfile }
    let certificateChildren = try ViewerDERReader.children(of: certificateNode)
    guard certificateChildren.count == 3,
      certificateChildren[1].encoded == signatureAlgorithm,
      certificateChildren[2].tag == 0x03,
      certificateChildren[2].contents.first == 0
    else {
      throw ViewerCertificateError.invalidProfile
    }
    let tbs = certificateChildren[0]
    guard tbs.tag == 0x30 else { throw ViewerCertificateError.invalidProfile }
    let fields = try ViewerDERReader.children(of: tbs)
    guard fields.count == 8,
      fields[0].encoded == ViewerDER.contextSpecific(0, contents: ViewerDER.integer(Data([2]))),
      fields[2].encoded == signatureAlgorithm,
      fields[3].encoded == distinguishedName,
      fields[5].encoded == distinguishedName,
      fields[7].encoded == ViewerDER.contextSpecific(3, contents: extensions),
      fields[1].tag == 0x02,
      (1...16).contains(fields[1].contents.count),
      fields[1].contents.first.map({ $0 > 0 && $0 < 0x80 }) == true
    else {
      throw ViewerCertificateError.invalidProfile
    }
    guard fields[1].contents.count == 16,
      fields[1].contents.first.map({ $0 > 0 && $0 < 0x80 }) == true,
      fields[1].contents.contains(where: { $0 != 0 })
    else {
      throw ViewerCertificateError.invalidProfile
    }

    let validity = try ViewerDERReader.children(of: fields[4])
    guard fields[4].tag == 0x30, validity.count == 2 else {
      throw ViewerCertificateError.invalidProfile
    }
    let notBefore = try ViewerDER.parseTime(validity[0])
    let notAfter = try ViewerDER.parseTime(validity[1])
    guard notAfter.timeIntervalSince(notBefore) == Self.lifetime + Self.validityBackdate else {
      throw ViewerCertificateError.invalidProfile
    }

    let spki = try ViewerDERReader.children(of: fields[6])
    let expectedSPKIAlgorithm = ViewerDER.sequence([
      ViewerDER.objectIdentifier([1, 2, 840, 10_045, 2, 1]),
      ViewerDER.objectIdentifier([1, 2, 840, 10_045, 3, 1, 7]),
    ])
    guard fields[6].tag == 0x30, spki.count == 2,
      spki[0].encoded == expectedSPKIAlgorithm,
      spki[1].tag == 0x03,
      spki[1].contents.count == 66,
      spki[1].contents.first == 0,
      spki[1].contents.dropFirst().first == 0x04
    else {
      throw ViewerCertificateError.invalidProfile
    }
    return ViewerCertificateProfile(
      serial: fields[1].contents,
      notBefore: notBefore,
      notAfter: notAfter,
      publicKeyBytes: Data(spki[1].contents.dropFirst())
    )
  }

  private static func verifySelfSignature(der: Data, publicKey: SecKey) throws {
    let certificate = try ViewerDERReader.singleNode(der)
    let fields = try ViewerDERReader.children(of: certificate)
    guard fields.count == 3, fields[2].contents.first == 0 else {
      throw ViewerCertificateError.invalidSignature
    }
    var error: Unmanaged<CFError>?
    guard
      SecKeyVerifySignature(
        publicKey,
        .ecdsaSignatureMessageX962SHA256,
        fields[0].encoded as CFData,
        Data(fields[2].contents.dropFirst()) as CFData,
        &error
      )
    else {
      throw ViewerCertificateError.invalidSignature
    }
  }

  private static func evaluateTrust(certificate: SecCertificate, at date: Date) throws {
    var optionalTrust: SecTrust?
    guard
      SecTrustCreateWithCertificates(
        certificate,
        SecPolicyCreateBasicX509(),
        &optionalTrust
      ) == errSecSuccess, let trust = optionalTrust,
      SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
      SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess
    else {
      throw ViewerCertificateError.trustFailed
    }
    var error: CFError?
    guard SecTrustEvaluateWithError(trust, &error) else {
      throw ViewerCertificateError.trustFailed
    }
  }
}

enum ViewerDER {
  static func sequence(_ fields: [Data]) -> Data { tagged(0x30, Data(fields.joined())) }
  static func set(_ fields: [Data]) -> Data { tagged(0x31, Data(fields.joined())) }
  static func integer(_ bytes: Data) -> Data { tagged(0x02, bytes) }
  static func boolean(_ value: Bool) -> Data { tagged(0x01, Data([value ? 0xFF : 0])) }
  static func octetString(_ bytes: Data) -> Data { tagged(0x04, bytes) }
  static func utf8String(_ value: String) -> Data { tagged(0x0C, Data(value.utf8)) }

  static func bitString(_ bytes: Data, unusedBits: UInt8 = 0) -> Data {
    tagged(0x03, Data([unusedBits]) + bytes)
  }

  static func contextSpecific(_ number: UInt8, contents: Data) -> Data {
    tagged(0xA0 | number, contents)
  }

  static func objectIdentifier(_ arcs: [UInt64]) -> Data {
    precondition(arcs.count >= 2 && arcs[0] <= 2 && arcs[1] < 40)
    var body = encodeBase128(arcs[0] * 40 + arcs[1])
    for arc in arcs.dropFirst(2) { body.append(contentsOf: encodeBase128(arc)) }
    return tagged(0x06, Data(body))
  }

  static func time(_ date: Date) throws -> Data {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let year = calendar.component(.year, from: date)
    guard year >= 1950, year <= 9_999 else { throw ViewerCertificateError.encodingFailed }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    if year <= 2049 {
      formatter.dateFormat = "yyMMddHHmmss'Z'"
      return tagged(0x17, Data(formatter.string(from: date).utf8))
    }
    formatter.dateFormat = "yyyyMMddHHmmss'Z'"
    return tagged(0x18, Data(formatter.string(from: date).utf8))
  }

  static func parseTime(_ encoded: Data) throws -> Date {
    try parseTime(ViewerDERReader.singleNode(encoded))
  }

  fileprivate static func parseTime(_ node: ViewerDERNode) throws -> Date {
    guard let value = String(data: node.contents, encoding: .ascii) else {
      throw ViewerCertificateError.invalidProfile
    }
    let format: String
    let expectedLength: Int
    switch node.tag {
    case 0x17:
      format = "yyMMddHHmmss'Z'"
      expectedLength = 13
    case 0x18:
      format = "yyyyMMddHHmmss'Z'"
      expectedLength = 15
    default:
      throw ViewerCertificateError.invalidProfile
    }
    guard value.utf8.count == expectedLength, value.last == "Z" else {
      throw ViewerCertificateError.invalidProfile
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    formatter.isLenient = false
    guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
      throw ViewerCertificateError.invalidProfile
    }
    let year: Int
    if node.tag == 0x17 {
      year = formatter.calendar.component(.year, from: date)
      guard (1950...2049).contains(year) else {
        throw ViewerCertificateError.invalidProfile
      }
    } else {
      guard let encodedYear = Int(value.prefix(4)) else {
        throw ViewerCertificateError.invalidProfile
      }
      year = encodedYear
      guard (2050...9_999).contains(year) else {
        throw ViewerCertificateError.invalidProfile
      }
    }
    return date
  }

  static func tagged(_ tag: UInt8, _ contents: Data) -> Data {
    Data([tag]) + length(contents.count) + contents
  }

  static func length(_ value: Int) -> Data {
    precondition(value >= 0)
    if value < 128 { return Data([UInt8(value)]) }
    var remaining = value
    var bytes: [UInt8] = []
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0xFF), at: 0)
      remaining >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
  }

  private static func encodeBase128(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes = [UInt8(value & 0x7F)]
    value >>= 7
    while value > 0 {
      bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
      value >>= 7
    }
    return bytes
  }
}

private struct ViewerDERNode {
  let tag: UInt8
  let contents: Data
  let encoded: Data
}

private enum ViewerDERReader {
  static func singleNode(_ data: Data) throws -> ViewerDERNode {
    var offset = 0
    let node = try readNode(data, offset: &offset)
    guard offset == data.count else { throw ViewerCertificateError.invalidProfile }
    return node
  }

  static func children(of node: ViewerDERNode) throws -> [ViewerDERNode] {
    var offset = 0
    var result: [ViewerDERNode] = []
    while offset < node.contents.count {
      result.append(try readNode(node.contents, offset: &offset))
    }
    return result
  }

  private static func readNode(_ data: Data, offset: inout Int) throws -> ViewerDERNode {
    let start = offset
    guard offset < data.count else { throw ViewerCertificateError.invalidProfile }
    let tag = data[offset]
    offset += 1
    guard offset < data.count else { throw ViewerCertificateError.invalidProfile }
    let firstLength = data[offset]
    offset += 1
    let length: Int
    if firstLength & 0x80 == 0 {
      length = Int(firstLength)
    } else {
      let byteCount = Int(firstLength & 0x7F)
      guard (1...4).contains(byteCount), offset + byteCount <= data.count,
        data[offset] != 0
      else {
        throw ViewerCertificateError.invalidProfile
      }
      var decoded = 0
      for _ in 0..<byteCount {
        let (multiplied, overflow1) = decoded.multipliedReportingOverflow(by: 256)
        let (added, overflow2) = multiplied.addingReportingOverflow(Int(data[offset]))
        guard !overflow1, !overflow2 else { throw ViewerCertificateError.invalidProfile }
        decoded = added
        offset += 1
      }
      guard decoded >= 128 else { throw ViewerCertificateError.invalidProfile }
      length = decoded
    }
    guard length >= 0, offset + length <= data.count else {
      throw ViewerCertificateError.invalidProfile
    }
    let contents = Data(data[offset..<(offset + length)])
    offset += length
    return ViewerDERNode(tag: tag, contents: contents, encoded: Data(data[start..<offset]))
  }
}
