import Foundation

enum ViewerPresentationError: Error, Equatable, Sendable {
  case identityUnavailable
  case pairingUnavailable
  case localNetworkUnavailable
  case listenerUnavailable

  var title: String {
    switch self {
    case .identityUnavailable:
      return "Viewer identity is unavailable"
    case .pairingUnavailable:
      return "Pairing code generation failed"
    case .localNetworkUnavailable:
      return "Local network access is unavailable"
    case .listenerUnavailable:
      return "Viewer listener could not start"
    }
  }

  var recovery: String {
    switch self {
    case .identityUnavailable:
      return "Retry or reset the NearWire TLS identity."
    case .pairingUnavailable:
      return "Retry to generate a new pairing code."
    case .localNetworkUnavailable:
      return "Allow local network access in System Settings, then retry."
    case .listenerUnavailable:
      return "Check network availability, then retry."
    }
  }
}

struct ViewerPendingAppSummary: Identifiable, Equatable, Sendable {
  let id: UUID
  let displayName: String
  let applicationIdentifier: String?
  let applicationVersion: String?
  let installationAlias: String
  let compatibilityStatus: String

  init(
    id: UUID,
    displayName: String,
    applicationIdentifier: String?,
    applicationVersion: String?,
    installationAlias: String,
    compatibilityStatus: String = "Compatible"
  ) {
    self.id = id
    self.displayName = displayName
    self.applicationIdentifier = applicationIdentifier
    self.applicationVersion = applicationVersion
    self.installationAlias = installationAlias
    self.compatibilityStatus = compatibilityStatus
  }
}
