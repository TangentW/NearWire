import Foundation
import Security

enum SDKSecurityAttributeValue: Equatable, Sendable {
  case genericPassword
  case string(String)
  case boolean(Bool)
  case matchLimitOne
  case authenticationUISkip
  case accessibleWhenUnlockedThisDeviceOnly
  case data(Data)
}

enum SDKSecurityItemReadResult: Equatable, Sendable {
  case data(Data)
  case missing
  case unexpectedValue
  case failed
}

enum SDKSecurityItemAddResult: Equatable, Sendable {
  case added
  case duplicate
  case failed
}

protocol SDKInstallationIdentityOperations: Sendable {
  func read(attributes: [String: SDKSecurityAttributeValue]) -> SDKSecurityItemReadResult
  func add(attributes: [String: SDKSecurityAttributeValue]) -> SDKSecurityItemAddResult
  func randomBytes(count: Int) -> [UInt8]?
}

struct SDKLiveInstallationIdentityOperations: SDKInstallationIdentityOperations {
  func read(attributes: [String: SDKSecurityAttributeValue]) -> SDKSecurityItemReadResult {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(makeDictionary(attributes), &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { return .unexpectedValue }
      return .data(data)
    case errSecItemNotFound:
      return .missing
    default:
      return .failed
    }
  }

  func add(attributes: [String: SDKSecurityAttributeValue]) -> SDKSecurityItemAddResult {
    switch SecItemAdd(makeDictionary(attributes), nil) {
    case errSecSuccess: return .added
    case errSecDuplicateItem: return .duplicate
    default: return .failed
    }
  }

  func randomBytes(count: Int) -> [UInt8]? {
    guard count > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      return nil
    }
    return bytes
  }

  func makeDictionary(
    _ attributes: [String: SDKSecurityAttributeValue]
  ) -> CFDictionary {
    var dictionary: [CFString: Any] = [:]
    for (key, value) in attributes {
      dictionary[securityKey(key)] = securityValue(value)
    }
    return dictionary as CFDictionary
  }

  private func securityKey(_ key: String) -> CFString {
    switch key {
    case SDKInstallationIdentityStore.Key.itemClass: return kSecClass
    case SDKInstallationIdentityStore.Key.service: return kSecAttrService
    case SDKInstallationIdentityStore.Key.account: return kSecAttrAccount
    case SDKInstallationIdentityStore.Key.dataProtection: return kSecUseDataProtectionKeychain
    case SDKInstallationIdentityStore.Key.returnData: return kSecReturnData
    case SDKInstallationIdentityStore.Key.matchLimit: return kSecMatchLimit
    case SDKInstallationIdentityStore.Key.authenticationUI: return kSecUseAuthenticationUI
    case SDKInstallationIdentityStore.Key.accessibility: return kSecAttrAccessible
    case SDKInstallationIdentityStore.Key.valueData: return kSecValueData
    default: preconditionFailure("Unknown internal Security attribute key.")
    }
  }

  private func securityValue(_ value: SDKSecurityAttributeValue) -> Any {
    switch value {
    case .genericPassword: return kSecClassGenericPassword
    case .string(let value): return value as CFString
    case .boolean(let value): return value as CFBoolean
    case .matchLimitOne: return kSecMatchLimitOne
    case .authenticationUISkip: return kSecUseAuthenticationUISkip
    case .accessibleWhenUnlockedThisDeviceOnly:
      return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    case .data(let value): return value as CFData
    }
  }
}

struct SDKInstallationIdentityStore: Sendable {
  enum Key {
    static let itemClass = "class"
    static let service = "service"
    static let account = "account"
    static let dataProtection = "dataProtection"
    static let returnData = "returnData"
    static let matchLimit = "matchLimit"
    static let authenticationUI = "authenticationUI"
    static let accessibility = "accessibility"
    static let valueData = "valueData"
  }

  static let service = "com.nearwire.sdk.installation-identity"
  static let account = "default"

  let operations: any SDKInstallationIdentityOperations

  init(operations: any SDKInstallationIdentityOperations = SDKLiveInstallationIdentityOperations())
  {
    self.operations = operations
  }

  func load() async throws -> String {
    let operations = self.operations
    return try await Task.detached {
      try Self.loadSynchronously(operations: operations)
    }.value
  }

  static var readAttributes: [String: SDKSecurityAttributeValue] {
    [
      Key.itemClass: .genericPassword,
      Key.service: .string(service),
      Key.account: .string(account),
      Key.dataProtection: .boolean(true),
      Key.returnData: .boolean(true),
      Key.matchLimit: .matchLimitOne,
      Key.authenticationUI: .authenticationUISkip,
    ]
  }

  static func addAttributes(data: Data) -> [String: SDKSecurityAttributeValue] {
    [
      Key.itemClass: .genericPassword,
      Key.service: .string(service),
      Key.account: .string(account),
      Key.dataProtection: .boolean(true),
      Key.accessibility: .accessibleWhenUnlockedThisDeviceOnly,
      Key.valueData: .data(data),
    ]
  }

  private static func loadSynchronously(
    operations: any SDKInstallationIdentityOperations
  ) throws -> String {
    switch operations.read(attributes: readAttributes) {
    case .data(let data):
      return try validatedIdentity(data)
    case .unexpectedValue, .failed:
      throw SDKInstallationIdentityError.unavailable
    case .missing:
      break
    }

    guard var bytes = operations.randomBytes(count: 16), bytes.count == 16 else {
      throw SDKInstallationIdentityError.unavailable
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let identity = canonicalUUID(bytes)
    guard let data = identity.data(using: .utf8), data.count == 36 else {
      throw SDKInstallationIdentityError.unavailable
    }

    switch operations.add(attributes: addAttributes(data: data)) {
    case .added:
      return identity
    case .failed:
      throw SDKInstallationIdentityError.unavailable
    case .duplicate:
      switch operations.read(attributes: readAttributes) {
      case .data(let duplicateData):
        return try validatedIdentity(duplicateData)
      case .missing, .unexpectedValue, .failed:
        throw SDKInstallationIdentityError.unavailable
      }
    }
  }

  private static func validatedIdentity(_ data: Data) throws -> String {
    guard data.count == 36, let value = String(data: data, encoding: .utf8),
      value.data(using: .utf8) == data,
      let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value
    else {
      throw SDKInstallationIdentityError.unavailable
    }
    let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
    guard bytes.count == 16, bytes[6] >> 4 == 4, bytes[8] >> 6 == 2 else {
      throw SDKInstallationIdentityError.unavailable
    }
    return value
  }

  private static func canonicalUUID(_ bytes: [UInt8]) -> String {
    let hexadecimal = bytes.map { String(format: "%02x", $0) }
    return hexadecimal[0...3].joined() + "-" + hexadecimal[4...5].joined() + "-"
      + hexadecimal[6...7].joined() + "-" + hexadecimal[8...9].joined() + "-"
      + hexadecimal[10...15].joined()
  }
}
