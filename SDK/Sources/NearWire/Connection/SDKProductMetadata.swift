import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireTransport
#endif

enum SDKProductVersion {
  static let current = "0.1.0"

  static func wireValue() throws -> WireProductVersion {
    try WireProductVersion(current)
  }
}

struct SDKBundleMetadataInput: Equatable, Sendable {
  let applicationIdentifier: String?
  let shortVersion: String?
  let buildVersion: String?
  let displayName: String?
  let bundleName: String?

  static func live() -> SDKBundleMetadataInput {
    let dictionary = Bundle.main.infoDictionary ?? [:]
    return SDKBundleMetadataInput(
      applicationIdentifier: Bundle.main.bundleIdentifier,
      shortVersion: dictionary["CFBundleShortVersionString"] as? String,
      buildVersion: dictionary["CFBundleVersion"] as? String,
      displayName: dictionary["CFBundleDisplayName"] as? String,
      bundleName: dictionary["CFBundleName"] as? String
    )
  }
}

struct SDKHostApplicationMetadata: Equatable, Sendable {
  let applicationIdentifier: String?
  let applicationVersion: String?
  let displayName: String?

  static func resolve(_ input: SDKBundleMetadataInput) -> SDKHostApplicationMetadata {
    SDKHostApplicationMetadata(
      applicationIdentifier: validatedASCII(input.applicationIdentifier, maximumBytes: 128),
      applicationVersion: validatedASCII(input.shortVersion, maximumBytes: 64)
        ?? validatedASCII(input.buildVersion, maximumBytes: 64),
      displayName: validatedHumanText(input.displayName, maximumBytes: 128)
        ?? validatedHumanText(input.bundleName, maximumBytes: 128)
    )
  }

  private static func validatedASCII(_ value: String?, maximumBytes: Int) -> String? {
    guard let value, (1...maximumBytes).contains(value.utf8.count),
      value.utf8.allSatisfy({ (32...126).contains($0) })
    else {
      return nil
    }
    return value
  }

  private static func validatedHumanText(_ value: String?, maximumBytes: Int) -> String? {
    guard let value, (1...maximumBytes).contains(value.utf8.count),
      value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      return nil
    }
    return value
  }
}
