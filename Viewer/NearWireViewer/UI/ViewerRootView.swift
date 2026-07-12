import SwiftUI

struct ViewerRootView: View {
  @ObservedObject var model: ViewerApplicationModel

  var body: some View {
    VStack(spacing: 0) {
      pairingHeader
      Divider()
      HSplitView {
        pendingSidebar
          .frame(minWidth: 240, idealWidth: 280)
        workspacePlaceholder
          .frame(minWidth: 460)
      }
    }
  }

  private var pairingHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Connect an iPhone App")
            .font(.headline)
          statusContent
        }
        Spacer()
        Button("Copy") { model.copyPairingCode() }
          .disabled(pairingCode == nil)
          .accessibilityLabel("Copy pairing code")
        Button("Refresh") { model.refreshPairingCode() }
          .disabled(pairingCode == nil)
          .accessibilityLabel("Refresh pairing code")
        Button(isPaused ? "Resume New Devices" : "Pause New Devices") {
          model.togglePaused()
        }
        .disabled(pairingCode == nil)
      }
      Text("TLS encrypted; Viewer identity is not authenticated.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(
        "The pairing code and stable vid are visible to nearby Bonjour browsers. They are not secrets or passwords."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Toggle("Require approval for new devices", isOn: $model.requiresApproval)
        .accessibilityHint("New devices wait for explicit acceptance before session handoff.")
    }
    .padding(20)
  }

  @ViewBuilder
  private var statusContent: some View {
    switch model.status {
    case .stopped:
      Text("Listener stopped")
        .foregroundStyle(.secondary)
    case .starting:
      ProgressView("Preparing secure listener")
    case .listening(let code, let paused):
      HStack(spacing: 8) {
        Text(code)
          .font(.system(.title, design: .monospaced, weight: .semibold))
          .textSelection(.enabled)
          .accessibilityLabel("Pairing code \(code)")
        Text(paused ? "Paused" : "Listening")
          .foregroundStyle(paused ? .orange : .green)
      }
    case .stopping:
      ProgressView("Stopping listener")
    case .failed(let error):
      HStack {
        VStack(alignment: .leading) {
          Text(error.title).foregroundStyle(.red)
          Text(error.recovery).font(.caption).foregroundStyle(.secondary)
        }
        Button("Retry") { model.retry() }
        if error == .identityUnavailable {
          Button("Reset TLS Identity") { model.resetTLSIdentity() }
          Button("Reset All Viewer Identity") { model.requestFullIdentityReset() }
        }
      }
    }
  }

  private var pendingSidebar: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Devices")
        .font(.headline)
      if model.pendingApps.isEmpty {
        ViewerEmptyState(
          title: "No Pending Devices",
          systemImage: "iphone",
          description: "Apps awaiting approval will appear here."
        )
      } else {
        List(model.pendingApps) { app in
          VStack(alignment: .leading, spacing: 6) {
            Text(app.displayName).font(.headline)
            if let identifier = app.applicationIdentifier {
              Text(identifier).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Text(app.installationAlias)
              Text(app.compatibilityStatus)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
              Button("Reject") { model.reject(app.id) }
              Button("Accept") { model.accept(app.id) }
                .buttonStyle(.borderedProminent)
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .padding(16)
  }

  private var workspacePlaceholder: some View {
    ViewerEmptyState(
      title: "No Active Device Workspace",
      systemImage: "rectangle.3.group",
      description: "Device sessions and event timelines arrive in the next Viewer changes."
    )
  }

  private var pairingCode: String? {
    guard case .listening(let code, _) = model.status else { return nil }
    return code
  }

  private var isPaused: Bool {
    guard case .listening(_, let paused) = model.status else { return false }
    return paused
  }
}

private struct ViewerEmptyState: View {
  let title: String
  let systemImage: String
  let description: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 30))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
      Text(description)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
