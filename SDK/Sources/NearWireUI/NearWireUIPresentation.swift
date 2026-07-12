import SwiftUI

#if SWIFT_PACKAGE
  import NearWire
#endif

enum NearWireUIStatusColor: Equatable {
  case neutral
  case positive
  case warning
  case negative

  var color: Color {
    switch self {
    case .neutral:
      return .secondary
    case .positive:
      return .green
    case .warning:
      return .orange
    case .negative:
      return .red
    }
  }
}

struct NearWireUIStatusPresentation: Equatable {
  let label: String
  let hint: String
  let symbolName: String
  let showsProgress: Bool
  let secondaryText: String?
  let color: NearWireUIStatusColor

  var accessibilityLabel: String {
    guard let secondaryText else { return label }
    return label + ", " + secondaryText
  }

  static func make(status: NearWireConnectionStatus) -> Self {
    let base: Self
    switch status.state {
    case .idle:
      base = Self(
        label: "Not Connected",
        hint: "Enter the Viewer pairing code to connect.",
        symbolName: "antenna.radiowaves.left.and.right",
        showsProgress: false,
        secondaryText: nil,
        color: .neutral
      )
    case .discovering:
      base = Self(
        label: "Searching for Viewer",
        hint: "NearWire is looking for a Viewer with this pairing code.",
        symbolName: "magnifyingglass",
        showsProgress: true,
        secondaryText: nil,
        color: .neutral
      )
    case .connecting:
      base = Self(
        label: "Securing Connection",
        hint: "NearWire is establishing an encrypted connection.",
        symbolName: "lock",
        showsProgress: true,
        secondaryText: nil,
        color: .neutral
      )
    case .connected:
      base = Self(
        label: "Connected",
        hint: "NearWire is connected to the Viewer.",
        symbolName: "checkmark.circle.fill",
        showsProgress: false,
        secondaryText: nil,
        color: .positive
      )
    case .reconnecting:
      let secondary = status.reconnectAttempt.map { "Attempt \($0)" }
      base = Self(
        label: "Reconnecting",
        hint: "NearWire is trying to restore the Viewer connection.",
        symbolName: "arrow.clockwise",
        showsProgress: true,
        secondaryText: secondary,
        color: .warning
      )
    case .disconnected:
      base = Self(
        label: "Disconnected",
        hint: "NearWire is not connected to a Viewer.",
        symbolName: "xmark.circle",
        showsProgress: false,
        secondaryText: nil,
        color: .negative
      )
    case .shutdown:
      base = Self(
        label: "Unavailable",
        hint: "This NearWire instance has been shut down.",
        symbolName: "slash.circle",
        showsProgress: false,
        secondaryText: nil,
        color: .negative
      )
    }

    guard status.isSuspended else { return base }
    return Self(
      label: base.label,
      hint: base.hint + " Connection recovery is paused.",
      symbolName: base.symbolName,
      showsProgress: base.showsProgress,
      secondaryText: base.secondaryText.map { "\($0) - Paused" } ?? "Paused",
      color: .warning
    )
  }
}

enum NearWireUIActionPresentation: Equatable {
  case connect(showsReset: Bool)
  case cancel
  case cancelling
  case disconnecting
  case disconnect
  case none

  var primaryLabel: String? {
    switch self {
    case .connect:
      return "Connect"
    case .cancel:
      return "Cancel"
    case .cancelling:
      return "Cancelling"
    case .disconnecting:
      return "Disconnecting"
    case .disconnect:
      return "Disconnect"
    case .none:
      return nil
    }
  }

  var primaryHint: String? {
    switch self {
    case .connect:
      return "Connect to the Viewer using this pairing code."
    case .cancel:
      return "Cancel the current connection attempt and disconnect."
    case .cancelling:
      return "NearWire is waiting for the connection attempt to stop."
    case .disconnecting:
      return "NearWire is disconnecting from the Viewer."
    case .disconnect:
      return "Disconnect from the current Viewer."
    case .none:
      return nil
    }
  }

  var isPrimaryEnabled: Bool {
    switch self {
    case .connect, .cancel, .disconnect:
      return true
    case .cancelling, .disconnecting, .none:
      return false
    }
  }

  var showsReset: Bool {
    if case .connect(let showsReset) = self { return showsReset }
    return false
  }
}

enum NearWireUIInputLimiter {
  static let maximumUTF8Bytes = 64

  static func limit(_ value: String, maximumUTF8Bytes: Int = maximumUTF8Bytes) -> String {
    var output = String.UnicodeScalarView()
    var byteCount = 0
    for scalar in value.unicodeScalars {
      let width: Int
      switch scalar.value {
      case 0...0x7F:
        width = 1
      case 0x80...0x7FF:
        width = 2
      case 0x800...0xFFFF:
        width = 3
      default:
        width = 4
      }
      guard byteCount + width <= maximumUTF8Bytes else { break }
      output.append(scalar)
      byteCount += width
    }
    return String(output)
  }
}
