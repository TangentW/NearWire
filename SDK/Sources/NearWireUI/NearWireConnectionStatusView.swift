import SwiftUI

#if SWIFT_PACKAGE
  import NearWire
#endif

public struct NearWireConnectionStatusView: View {
  private let status: NearWireConnectionStatus

  public init(status: NearWireConnectionStatus) {
    self.status = status
  }

  public var body: some View {
    NearWireConnectionStatusContent(status: status, showsError: true)
  }
}

struct NearWireConnectionStatusContent: View {
  let status: NearWireConnectionStatus
  let showsError: Bool

  var body: some View {
    let presentation = NearWireUIStatusPresentation.make(status: status)
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: presentation.symbolName)
        .foregroundStyle(presentation.color.color)
        .font(.title2)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(verbatim: presentation.label)
            .font(.headline)
          if presentation.showsProgress {
            ProgressView()
              .controlSize(.small)
              .accessibilityHidden(true)
          }
        }
        if let secondaryText = presentation.secondaryText {
          Text(verbatim: secondaryText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        if showsError, let message = status.lastError?.message {
          Text(verbatim: message)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))
    .accessibilityHint(Text(verbatim: accessibilityHint(for: presentation)))
  }

  private func accessibilityHint(for presentation: NearWireUIStatusPresentation) -> String {
    guard showsError, let message = status.lastError?.message else { return presentation.hint }
    return presentation.hint + " Connection error: \(message)"
  }
}
