import SwiftUI

#if SWIFT_PACKAGE
  import NearWire
#endif

public struct NearWireConnectionView: View {
  private let nearWire: NearWire

  public init(nearWire: NearWire) {
    self.nearWire = nearWire
  }

  var stateIdentity: ObjectIdentifier {
    ObjectIdentifier(nearWire)
  }

  public var body: some View {
    NearWireConnectionContent(nearWire: nearWire)
      .id(stateIdentity)
  }
}

struct NearWireConnectionContent: View {
  @StateObject private var model: NearWireUIConnectionModel

  init(nearWire: NearWire) {
    _model = StateObject(
      wrappedValue: NearWireUIConnectionModel(controller: nearWire)
    )
  }

  init(model: NearWireUIConnectionModel) {
    _model = StateObject(wrappedValue: model)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let status = model.status {
        NearWireConnectionStatusContent(status: status, showsError: false)
      } else {
        HStack(spacing: 12) {
          ProgressView()
          Text(verbatim: "Reading Connection Status")
            .font(.headline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "Reading connection status"))
      }

      TextField(
        String("Pairing code"),
        text: Binding(
          get: { model.pairingCode },
          set: { model.updatePairingCode($0) }
        )
      )
      .textFieldStyle(.roundedBorder)
      .modifier(NearWirePairingCodeInputModifier())
      .disabled(!inputIsEnabled)
      .onSubmit {
        if model.canSubmitPairingCode { model.performPrimaryAction() }
      }
      .accessibilityLabel(Text(verbatim: "Viewer pairing code"))
      .accessibilityHint(Text(verbatim: "Enter the pairing code shown by NearWire Viewer."))

      actionControls

      if let message = model.displayedErrorMessage {
        Text(verbatim: message)
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityLabel(Text(verbatim: "Connection error: \(message)"))
      }
    }
    .padding()
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }

  @ViewBuilder
  private var actionControls: some View {
    let action = model.actionPresentation
    if let label = action.primaryLabel {
      HStack(spacing: 12) {
        Button {
          model.performPrimaryAction()
        } label: {
          Text(verbatim: label)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!action.isPrimaryEnabled || (isConnect(action) && !model.canSubmitPairingCode))
        .accessibilityHint(Text(verbatim: action.primaryHint ?? ""))

        if action.showsReset {
          Button {
            model.resetConnection()
          } label: {
            Text(verbatim: "Reset Connection")
          }
          .buttonStyle(.bordered)
          .accessibilityHint(
            Text(verbatim: "Clear the existing connection ownership before trying again.")
          )
        }
      }
    }
  }

  private var inputIsEnabled: Bool {
    if case .connect = model.actionPresentation { return true }
    return false
  }

  private func isConnect(_ action: NearWireUIActionPresentation) -> Bool {
    if case .connect = action { return true }
    return false
  }
}

private struct NearWirePairingCodeInputModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      content
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
    #else
      content
        .autocorrectionDisabled()
    #endif
  }
}
