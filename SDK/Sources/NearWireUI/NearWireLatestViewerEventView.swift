import SwiftUI

#if SWIFT_PACKAGE
  import NearWire
#endif

/// A bounded presentation of the latest Viewer-to-App Event observed while visible.
public struct NearWireLatestViewerEventView: View {
  private let nearWire: NearWire

  public init(nearWire: NearWire) {
    self.nearWire = nearWire
  }

  var stateIdentity: ObjectIdentifier {
    ObjectIdentifier(nearWire)
  }

  public var body: some View {
    NearWireLatestViewerEventContent(nearWire: nearWire)
      .id(stateIdentity)
  }
}

struct NearWireLatestViewerEventContent: View {
  @StateObject private var model: NearWireUILatestViewerEventModel

  init(nearWire: NearWire) {
    _model = StateObject(
      wrappedValue: NearWireUILatestViewerEventModel(source: nearWire)
    )
  }

  init(model: NearWireUILatestViewerEventModel) {
    _model = StateObject(wrappedValue: model)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: "Latest Viewer Event")
        .font(.headline)

      if let event = model.latest {
        Text(verbatim: event.type)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .accessibilityLabel(Text(verbatim: "Event type: \(event.type)"))

        Text(verbatim: event.contentSummary)
          .font(.body.monospaced())
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .accessibilityLabel(Text(verbatim: "Event content: \(event.contentSummary)"))
      } else {
        Text(verbatim: "No Viewer Event received.")
          .foregroundStyle(.secondary)
      }

      if let message = model.displayedErrorMessage {
        Text(verbatim: message)
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityLabel(Text(verbatim: "Event observation error: \(message)"))
      }
    }
    .padding()
    .onAppear { model.startObserving() }
    .onDisappear { model.stopObserving() }
  }
}
