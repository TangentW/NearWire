import SwiftUI

#if SWIFT_PACKAGE
  import NearWirePerformance
#endif

/// An explicit control for a host-owned NearWire performance monitor.
public struct NearWirePerformanceControlView: View {
  private let performanceMonitor: NearWirePerformanceMonitor

  public init(performanceMonitor: NearWirePerformanceMonitor) {
    self.performanceMonitor = performanceMonitor
  }

  var stateIdentity: ObjectIdentifier {
    ObjectIdentifier(performanceMonitor)
  }

  public var body: some View {
    NearWirePerformanceControlContent(performanceMonitor: performanceMonitor)
      .id(stateIdentity)
  }
}

struct NearWirePerformanceControlContent: View {
  @StateObject private var model: NearWireUIPerformanceModel

  init(performanceMonitor: NearWirePerformanceMonitor) {
    _model = StateObject(
      wrappedValue: NearWireUIPerformanceModel(controller: performanceMonitor)
    )
  }

  init(model: NearWireUIPerformanceModel) {
    _model = StateObject(wrappedValue: model)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(
        isOn: Binding(
          get: { model.isEnabled },
          set: { model.setEnabled($0) }
        )
      ) {
        VStack(alignment: .leading, spacing: 3) {
          Text(verbatim: "Performance Collection")
            .font(.headline)
          Text(verbatim: model.stateLabel)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .disabled(!collectionIsSupported || model.isOperationPending)
      .accessibilityIdentifier("nearwire.performance.toggle")
      .accessibilityHint(
        Text(
          verbatim: collectionIsSupported
            ? "Start or stop performance snapshots sent through NearWire."
            : "Performance collection is unavailable on this platform."
        )
      )

      if model.isOperationPending {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(Text(verbatim: model.stateLabel))
      }

      if !collectionIsSupported {
        Text(verbatim: "Performance collection is unavailable on this platform.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else if let message = model.displayedErrorMessage {
        Text(verbatim: message)
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityLabel(Text(verbatim: "Performance error: \(message)"))
      }
    }
    .padding()
    .onAppear { model.startObserving() }
    .onDisappear { model.stopObserving() }
  }

  private var collectionIsSupported: Bool {
    #if os(iOS)
      true
    #else
      false
    #endif
  }
}
