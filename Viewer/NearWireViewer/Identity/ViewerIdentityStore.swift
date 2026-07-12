import CryptoKit
import Foundation
import LocalAuthentication
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport
import Security

struct ViewerRuntimeIdentity: @unchecked Sendable {
  let installationID: EndpointID
  let certificate: SecCertificate
  let privateKey: SecKey
  let secIdentity: SecIdentity
  let transportIdentity: ViewerTransportIdentity
}

struct ViewerStoredIdentityMaterial: @unchecked Sendable {
  let installationID: EndpointID
  let certificate: SecCertificate
  let privateKey: SecKey
}

enum ViewerIdentityStoreError: Error, Equatable, Sendable {
  case identityUnavailable
  case resetFailed
}

enum ViewerIdentityPersistenceError: Error, Equatable, Sendable {
  case missing
  case invalid
  case operation
}

protocol ViewerIdentityPersistence: Sendable {
  func copyGenericPassword(account: String) throws -> Data
  func addGenericPassword(account: String, value: Data) throws
  func deleteGenericPassword(account: String, requirePresent: Bool) throws
  func createPrivateKey(builder: ViewerCertificateBuilder) throws -> SecKey
  func copyPrivateKey() throws -> SecKey
  func deletePrivateKey(requirePresent: Bool) throws
  func privateKeyItemExists() throws -> Bool
  func addCertificate(_ certificate: SecCertificate, label: String) throws -> Data
  func copyCertificate(persistentReference: Data) throws -> SecCertificate
  func deleteCertificate(persistentReference: Data, requirePresent: Bool) throws
  func copyIdentity(certificate: SecCertificate, privateKey: SecKey) throws -> SecIdentity
}

struct ViewerKeychainNames: Equatable, Sendable {
  static let live = ViewerKeychainNames(
    service: "com.nearwire.viewer.identity.v1",
    keyTag: "com.nearwire.viewer.tls-key.v1",
    usesDataProtectionKeychain: false
  )

  let service: String
  let keyTag: String
  let usesDataProtectionKeychain: Bool

  var keyTagData: Data { Data(keyTag.utf8) }

  static func isolated(_ identifier: String = UUID().uuidString) -> ViewerKeychainNames {
    ViewerKeychainNames(
      service: "com.nearwire.viewer.tests.\(identifier)",
      keyTag: "com.nearwire.viewer.tests.tls-key.\(identifier)",
      usesDataProtectionKeychain: false
    )
  }

}

final class ViewerIdentityStore: @unchecked Sendable {
  private enum InternalError: Error {
    case missing
    case invalid
    case operation
  }

  private struct TLSMetadata: Codable, Equatable {
    let version: Int
    let certificatePersistentReference: Data
    let certificateLabel: String
    let serial: Data
    let publicKeyHash: Data
    let certificateHash: Data
  }

  static let live = ViewerIdentityStore()

  private let names: ViewerKeychainNames
  private let certificateBuilder: ViewerCertificateBuilder
  private let persistence: (any ViewerIdentityPersistence)?
  private let lock = NSLock()

  init(
    names: ViewerKeychainNames = .live,
    certificateBuilder: ViewerCertificateBuilder = .live,
    persistence: (any ViewerIdentityPersistence)? = nil
  ) {
    self.names = names
    self.certificateBuilder = certificateBuilder
    self.persistence = persistence
  }

  func loadOrCreate() throws -> ViewerRuntimeIdentity {
    lock.lock()
    defer { lock.unlock() }
    let material: ViewerStoredIdentityMaterial
    do {
      material = try loadOrCreateMaterialLocked()
    } catch let error as ViewerIdentityStoreError {
      throw error
    } catch {
      throw ViewerIdentityStoreError.identityUnavailable
    }
    do {
      return try makeRuntimeIdentity(
        installationID: material.installationID,
        certificate: material.certificate,
        privateKey: material.privateKey
      )
    } catch {
      throw ViewerIdentityStoreError.identityUnavailable
    }
  }

  func loadOrCreateMaterial() throws -> ViewerStoredIdentityMaterial {
    lock.lock()
    defer { lock.unlock() }
    do {
      return try loadOrCreateMaterialLocked()
    } catch let error as ViewerIdentityStoreError {
      throw error
    } catch {
      throw ViewerIdentityStoreError.identityUnavailable
    }
  }

  private func loadOrCreateMaterialLocked() throws -> ViewerStoredIdentityMaterial {
    let installationID = try loadOrCreateInstallationID()
    do {
      return try loadTLSIdentity(installationID: installationID)
    } catch InternalError.missing {
      try resetTLSInternal(requireCertificateDeletion: false)
    } catch InternalError.invalid {
      try resetTLSInternal(requireCertificateDeletion: false)
    } catch {
      throw ViewerIdentityStoreError.identityUnavailable
    }
    do {
      return try createTLSIdentity(installationID: installationID)
    } catch {
      try? resetTLSInternal(requireCertificateDeletion: false)
      throw ViewerIdentityStoreError.identityUnavailable
    }
  }

  func resetTLSIdentity() throws {
    lock.lock()
    defer { lock.unlock() }
    do {
      try resetTLSInternal(requireCertificateDeletion: true)
    } catch {
      throw ViewerIdentityStoreError.resetFailed
    }
  }

  func resetAllIdentity() throws {
    lock.lock()
    defer { lock.unlock() }
    do {
      try resetTLSInternal(requireCertificateDeletion: true)
      try deleteGenericPassword(account: "installation-id")
    } catch {
      throw ViewerIdentityStoreError.resetFailed
    }
  }

  private func loadOrCreateInstallationID() throws -> EndpointID {
    do {
      let data = try copyGenericPassword(account: "installation-id")
      guard let value = String(data: data, encoding: .utf8),
        let id = try? EndpointID(rawValue: value),
        UUID(uuidString: value) != nil
      else {
        try deleteGenericPassword(account: "installation-id")
        return try createInstallationID()
      }
      return id
    } catch InternalError.missing {
      return try createInstallationID()
    }
  }

  private func createInstallationID() throws -> EndpointID {
    let value = UUID().uuidString.lowercased()
    let id = try EndpointID(rawValue: value)
    try addGenericPassword(account: "installation-id", value: Data(value.utf8))
    return id
  }

  private func loadTLSIdentity(installationID: EndpointID) throws
    -> ViewerStoredIdentityMaterial
  {
    let metadataData = try copyGenericPassword(account: "tls-metadata")
    guard let metadata = try? JSONDecoder().decode(TLSMetadata.self, from: metadataData),
      metadata.version == 1
    else {
      throw InternalError.invalid
    }
    let certificate: SecCertificate
    do {
      certificate = try copyCertificate(
        persistentReference: metadata.certificatePersistentReference)
    } catch {
      throw error
    }
    let certificateData = SecCertificateCopyData(certificate) as Data
    guard digest(certificateData) == metadata.certificateHash,
      (SecCertificateCopySerialNumberData(certificate, nil) as Data?) == metadata.serial
    else {
      throw InternalError.invalid
    }
    let privateKey: SecKey
    do {
      privateKey = try copyPrivateKey()
    } catch {
      throw error
    }
    let profile: ViewerCertificateProfile
    do {
      profile = try certificateBuilder.validate(
        certificate: certificate,
        privateKey: privateKey
      )
    } catch {
      throw InternalError.invalid
    }
    guard digest(profile.publicKeyBytes) == metadata.publicKeyHash else {
      throw InternalError.invalid
    }
    return ViewerStoredIdentityMaterial(
      installationID: installationID,
      certificate: certificate,
      privateKey: privateKey
    )
  }

  private func createTLSIdentity(installationID: EndpointID) throws
    -> ViewerStoredIdentityMaterial
  {
    let privateKey = try createPrivateKey()
    var persistentReference: Data?
    do {
      let material = try certificateBuilder.build(privateKey: privateKey)
      guard let publicKey = SecKeyCopyPublicKey(privateKey),
        let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
      else {
        throw InternalError.invalid
      }
      let label = "NearWire Viewer \(UUID().uuidString)"
      let reference = try addCertificate(material.certificate, label: label)
      persistentReference = reference
      let metadata = TLSMetadata(
        version: 1,
        certificatePersistentReference: reference,
        certificateLabel: label,
        serial: material.serial,
        publicKeyHash: digest(publicBytes),
        certificateHash: digest(material.der)
      )
      try addGenericPassword(
        account: "tls-metadata",
        value: try JSONEncoder().encode(metadata)
      )
      return ViewerStoredIdentityMaterial(
        installationID: installationID,
        certificate: material.certificate,
        privateKey: privateKey
      )
    } catch {
      if let persistentReference {
        try? deleteCertificate(persistentReference: persistentReference)
      }
      try? deletePrivateKey()
      try? deleteGenericPassword(account: "tls-metadata")
      throw error
    }
  }

  private func makeRuntimeIdentity(
    installationID: EndpointID,
    certificate: SecCertificate,
    privateKey: SecKey
  ) throws -> ViewerRuntimeIdentity {
    let secIdentity = try copyIdentity(certificate: certificate, privateKey: privateKey)
    let transportIdentity: ViewerTransportIdentity
    do {
      transportIdentity = try ViewerTransportIdentity(identity: secIdentity)
    } catch {
      throw InternalError.invalid
    }
    return ViewerRuntimeIdentity(
      installationID: installationID,
      certificate: certificate,
      privateKey: privateKey,
      secIdentity: secIdentity,
      transportIdentity: transportIdentity
    )
  }

  private func resetTLSInternal(requireCertificateDeletion: Bool) throws {
    let metadataData: Data?
    do {
      metadataData = try copyGenericPassword(account: "tls-metadata")
    } catch InternalError.missing {
      metadataData = nil
    }

    if let metadataData {
      guard let metadata = try? JSONDecoder().decode(TLSMetadata.self, from: metadataData),
        metadata.version == 1
      else {
        if requireCertificateDeletion { throw InternalError.invalid }
        try deletePrivateKey(requirePresent: false)
        try deleteGenericPassword(account: "tls-metadata", requirePresent: false)
        return
      }
      do {
        _ = try validateOwnedTLSMetadata(metadata)
        try deleteCertificate(
          persistentReference: metadata.certificatePersistentReference,
          requirePresent: requireCertificateDeletion
        )
      } catch InternalError.missing where !requireCertificateDeletion {
      } catch InternalError.invalid where !requireCertificateDeletion {
      }
    } else if requireCertificateDeletion, try privateKeyItemExists() {
      throw InternalError.invalid
    }
    try deletePrivateKey(requirePresent: requireCertificateDeletion)
    try deleteGenericPassword(
      account: "tls-metadata",
      requirePresent: requireCertificateDeletion
    )
  }

  private func validateOwnedTLSMetadata(
    _ metadata: TLSMetadata
  ) throws -> (certificate: SecCertificate, privateKey: SecKey) {
    guard metadata.version == 1,
      metadata.certificateLabel.hasPrefix("NearWire Viewer "),
      metadata.certificateLabel.count > "NearWire Viewer ".count
    else {
      throw InternalError.invalid
    }
    let certificate = try copyCertificate(
      persistentReference: metadata.certificatePersistentReference
    )
    let certificateData = SecCertificateCopyData(certificate) as Data
    guard digest(certificateData) == metadata.certificateHash,
      (SecCertificateCopySerialNumberData(certificate, nil) as Data?) == metadata.serial
    else {
      throw InternalError.invalid
    }
    let privateKey = try copyPrivateKey()
    let profile: ViewerCertificateProfile
    do {
      profile = try certificateBuilder.validateOwnership(
        certificate: certificate,
        privateKey: privateKey
      )
    } catch {
      throw InternalError.invalid
    }
    guard profile.serial == metadata.serial,
      digest(profile.publicKeyBytes) == metadata.publicKeyHash
    else {
      throw InternalError.invalid
    }
    return (certificate, privateKey)
  }

  private func genericPasswordQuery(account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: names.service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: names.usesDataProtectionKeychain,
    ]
  }

  private func nonInteractiveQuery(
    _ query: [CFString: Any]
  ) -> [CFString: Any] {
    var query = query
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext] = context
    return query
  }

  private func copyGenericPassword(account: String) throws -> Data {
    if let persistence {
      return try mapPersistenceError { try persistence.copyGenericPassword(account: account) }
    }
    var query = nonInteractiveQuery(genericPasswordQuery(account: account))
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { throw InternalError.missing }
    guard status == errSecSuccess, let data = result as? Data else {
      throw InternalError.operation
    }
    return data
  }

  private func addGenericPassword(account: String, value: Data) throws {
    if let persistence {
      return try mapPersistenceError {
        try persistence.addGenericPassword(account: account, value: value)
      }
    }
    var attributes = genericPasswordQuery(account: account)
    if names.usesDataProtectionKeychain {
      attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
    attributes[kSecValueData] = value
    guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
      throw InternalError.operation
    }
  }

  private func deleteGenericPassword(account: String, requirePresent: Bool = false) throws {
    if let persistence {
      return try mapPersistenceError {
        try persistence.deleteGenericPassword(
          account: account,
          requirePresent: requirePresent
        )
      }
    }
    try acceptDeleteStatus(
      SecItemDelete(
        nonInteractiveQuery(genericPasswordQuery(account: account)) as CFDictionary
      ),
      requirePresent: requirePresent
    )
  }

  private func privateKeyQuery() -> [CFString: Any] {
    [
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: names.keyTagData,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: names.usesDataProtectionKeychain,
    ]
  }

  private func createPrivateKey() throws -> SecKey {
    if let persistence {
      return try mapPersistenceError {
        try persistence.createPrivateKey(builder: certificateBuilder)
      }
    }
    return try certificateBuilder.createPrivateKey(
      applicationTag: names.keyTagData,
      useDataProtectionKeychain: names.usesDataProtectionKeychain
    )
  }

  private func copyPrivateKey() throws -> SecKey {
    if let persistence {
      return try mapPersistenceError { try persistence.copyPrivateKey() }
    }
    var query = nonInteractiveQuery(privateKeyQuery())
    query[kSecReturnRef] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { throw InternalError.missing }
    guard status == errSecSuccess, let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
      throw InternalError.operation
    }
    let key = result as! SecKey
    let attributes = SecKeyCopyAttributes(key) as NSDictionary? as? [CFString: Any]
    let isExternallyRepresentable = SecKeyCopyExternalRepresentation(key, nil) != nil
    guard
      Self.hasRequiredLoadedPrivateKeyProperties(
        attributes,
        isExternallyRepresentable: isExternallyRepresentable
      )
    else {
      throw InternalError.invalid
    }
    return key
  }

  private func deletePrivateKey(requirePresent: Bool = false) throws {
    if let persistence {
      return try mapPersistenceError {
        try persistence.deletePrivateKey(requirePresent: requirePresent)
      }
    }
    try acceptDeleteStatus(
      SecItemDelete(nonInteractiveQuery(privateKeyQuery()) as CFDictionary),
      requirePresent: requirePresent
    )
  }

  private func privateKeyItemExists() throws -> Bool {
    if let persistence {
      return try mapPersistenceError { try persistence.privateKeyItemExists() }
    }
    var query = nonInteractiveQuery(privateKeyQuery())
    query[kSecMatchLimit] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else { throw InternalError.operation }
    return true
  }

  private func addCertificate(_ certificate: SecCertificate, label: String) throws -> Data {
    if let persistence {
      return try mapPersistenceError {
        try persistence.addCertificate(certificate, label: label)
      }
    }
    let attributes: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecValueRef: certificate,
      kSecAttrLabel: label,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: names.usesDataProtectionKeychain,
      kSecReturnPersistentRef: true,
    ]
    var result: CFTypeRef?
    let status = SecItemAdd(attributes as CFDictionary, &result)
    guard status == errSecSuccess else {
      throw InternalError.operation
    }
    if let reference = result as? Data { return reference }
    if let values = result as? NSDictionary,
      let reference = values[kSecValuePersistentRef] as? Data
    {
      return reference
    }

    let lookup = nonInteractiveQuery([
      kSecClass: kSecClassCertificate,
      kSecMatchItemList: [certificate],
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: names.usesDataProtectionKeychain,
      kSecReturnPersistentRef: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ])
    var lookupResult: CFTypeRef?
    guard SecItemCopyMatching(lookup as CFDictionary, &lookupResult) == errSecSuccess,
      let reference = lookupResult as? Data
    else {
      throw InternalError.operation
    }
    return reference
  }

  private func copyCertificate(persistentReference: Data) throws -> SecCertificate {
    if let persistence {
      return try mapPersistenceError {
        try persistence.copyCertificate(persistentReference: persistentReference)
      }
    }
    let query = nonInteractiveQuery([
      kSecClass: kSecClassCertificate,
      kSecMatchItemList: [persistentReference],
      kSecUseDataProtectionKeychain: names.usesDataProtectionKeychain,
      kSecReturnRef: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ])
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { throw InternalError.missing }
    guard status == errSecSuccess, let result,
      CFGetTypeID(result) == SecCertificateGetTypeID()
    else {
      throw InternalError.operation
    }
    return result as! SecCertificate
  }

  private func deleteCertificate(
    persistentReference: Data,
    requirePresent: Bool = false
  ) throws {
    if let persistence {
      return try mapPersistenceError {
        try persistence.deleteCertificate(
          persistentReference: persistentReference,
          requirePresent: requirePresent
        )
      }
    }
    let query = nonInteractiveQuery([
      kSecClass: kSecClassCertificate,
      kSecMatchItemList: [persistentReference],
      kSecUseDataProtectionKeychain: names.usesDataProtectionKeychain,
    ])
    try acceptDeleteStatus(
      SecItemDelete(query as CFDictionary),
      requirePresent: requirePresent
    )
  }

  private func copyIdentity(
    certificate: SecCertificate,
    privateKey: SecKey
  ) throws -> SecIdentity {
    if let persistence {
      return try mapPersistenceError {
        try persistence.copyIdentity(certificate: certificate, privateKey: privateKey)
      }
    }
    let query = nonInteractiveQuery([
      kSecClass: kSecClassIdentity,
      kSecMatchItemList: [certificate],
      kSecReturnRef: true,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecUseDataProtectionKeychain: names.usesDataProtectionKeychain,
    ])
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result,
      CFGetTypeID(result) == SecIdentityGetTypeID()
    else {
      throw InternalError.invalid
    }
    let identity = result as! SecIdentity
    var identityPrivateKey: SecKey?
    guard SecIdentityCopyPrivateKey(identity, &identityPrivateKey) == errSecSuccess,
      let identityPrivateKey,
      Self.privateKeysCorrespond(identityPrivateKey, privateKey)
    else {
      throw InternalError.invalid
    }
    return identity
  }

  static func hasRequiredLoadedPrivateKeyProperties(
    _ attributes: [CFString: Any]?,
    isExternallyRepresentable: Bool
  ) -> Bool {
    attributes?[kSecAttrKeySizeInBits] as? Int == 256
      && !isExternallyRepresentable
  }

  private static func privateKeysCorrespond(_ lhs: SecKey, _ rhs: SecKey) -> Bool {
    guard let lhsPublic = SecKeyCopyPublicKey(lhs),
      let rhsPublic = SecKeyCopyPublicKey(rhs),
      let lhsBytes = SecKeyCopyExternalRepresentation(lhsPublic, nil) as Data?,
      let rhsBytes = SecKeyCopyExternalRepresentation(rhsPublic, nil) as Data?
    else {
      return false
    }
    return lhsBytes == rhsBytes
  }

  private func acceptDeleteStatus(_ status: OSStatus, requirePresent: Bool = false) throws {
    guard status == errSecSuccess || (!requirePresent && status == errSecItemNotFound) else {
      throw InternalError.operation
    }
  }

  private func mapPersistenceError<Value>(_ operation: () throws -> Value) throws -> Value {
    do {
      return try operation()
    } catch let error as ViewerIdentityPersistenceError {
      switch error {
      case .missing:
        throw InternalError.missing
      case .invalid:
        throw InternalError.invalid
      case .operation:
        throw InternalError.operation
      }
    }
  }

  private func digest(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }
}
