import SwiftUI

struct ViewerRootView: View {
  @ObservedObject var model: ViewerApplicationModel

  var body: some View {
    VStack(spacing: 0) {
      pairingHeader
      Divider()
      HSplitView {
        deviceSidebar.frame(minWidth: 240, idealWidth: 280)
        deviceWorkspace.frame(minWidth: 460)
      }
    }
  }

  private var pairingHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Connect an iPhone App").font(.headline)
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
        .font(.caption).foregroundStyle(.secondary)
      Text(
        "The pairing code and stable vid are visible to nearby Bonjour browsers. They are not secrets or passwords."
      )
      .font(.caption).foregroundStyle(.secondary)
      Toggle("Require approval for new devices", isOn: $model.requiresApproval)
        .accessibilityHint("New devices wait for explicit acceptance before session handoff.")
      ViewerStorageSettings(model: model)
    }
    .padding(20)
  }

  @ViewBuilder
  private var statusContent: some View {
    switch model.status {
    case .stopped:
      Text("Listener stopped").foregroundStyle(.secondary)
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

  private var deviceSidebar: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Devices").font(.headline)
      if model.sessions.isEmpty {
        ViewerEmptyState(
          title: "No Connected Devices",
          systemImage: "iphone",
          description: "Nearby Apps using this pairing code will appear here."
        )
      } else {
        List(selection: $model.selectedRoute) {
          ForEach(model.sessions) { session in
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Text(session.title).font(.headline)
                Spacer()
                Text(session.state.rawValue.capitalized)
                  .font(.caption)
                  .foregroundStyle(session.state == .active ? .green : .secondary)
              }
              Text(session.installationAlias).font(.caption).foregroundStyle(.secondary)
              if session.downlinkCount + session.uplinkCount > 0 {
                Label(
                  "\(session.uplinkCount + session.downlinkCount) queued",
                  systemImage: "tray.full"
                )
                .font(.caption).foregroundStyle(.orange)
              }
            }
            .tag(session.route)
            .padding(.vertical, 3)
          }
        }
      }
      if !model.pendingApps.isEmpty {
        Divider()
        Text("Awaiting Approval").font(.headline)
        ForEach(model.pendingApps) { app in
          VStack(alignment: .leading, spacing: 6) {
            Text(app.displayName).font(.headline)
            Text(app.installationAlias).font(.caption).foregroundStyle(.secondary)
            HStack {
              Button("Reject") { model.reject(app.id) }
              Button("Accept") { model.accept(app.id) }.buttonStyle(.borderedProminent)
            }
          }
        }
      }
    }
    .padding(16)
  }

  @ViewBuilder
  private var deviceWorkspace: some View {
    if let session = model.selectedSession {
      ViewerDeviceDetail(model: model, session: session).id(session.route.storageKey)
    } else {
      ViewerEmptyState(
        title: "Select a Device",
        systemImage: "rectangle.3.group",
        description: "Choose a connected or recent App to inspect its bounded session telemetry."
      )
    }
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

private struct ViewerStorageSettings: View {
  @ObservedObject var model: ViewerApplicationModel
  @State private var capacityGiB: String = ""
  @State private var retentionDays: String = ""
  @State private var validationMessage: String?

  var body: some View {
    DisclosureGroup("Local storage") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          TextField("Capacity in GiB", text: $capacityGiB)
            .frame(width: 140)
            .accessibilityLabel("Local history capacity in GiB")
          TextField("History retention in days", text: $retentionDays)
            .frame(width: 190)
            .accessibilityLabel("Local history retention in days")
          Button("Save") {
            validationMessage =
              model.updateStorage(
                capacityGiB: capacityGiB,
                historyRetentionDays: retentionDays
              ) ? nil : "Capacity or history retention is outside the supported range."
          }
          Button("Clean Up Now") { model.cleanUpStorage() }
          Button("Retry Storage") { model.retryStorage() }
            .disabled(model.storeStatus.state == .available)
        }
        Text(
          "State: \(model.storeStatus.state.rawValue) · Last cleanup: \(model.storeStatus.lastCleanupCategory.rawValue) · Logical quota: \(format(model.storeStatus.logicalQuotaBytes)) / \(format(model.storeStatus.capacityBytes)) · Allocated files: \(format(model.storeStatus.allocatedFootprintBytes)) · Pinned estimate: \(format(model.storeStatus.pinnedQuotaBytes))"
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(oldestHistorySummary)
          .font(.caption).foregroundStyle(.secondary)
        Text(
          "History retention is separate from Event TTL. Deletion is logical first; secure_delete reduces remnants but does not guarantee secure erasure from storage media or backups."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let validationMessage {
          Text(validationMessage).foregroundStyle(.red).font(.caption)
        }
      }
      .padding(.top, 8)
      .onAppear {
        capacityGiB = String(model.storageConfiguration.capacityBytes / 1_024 / 1_024 / 1_024)
        retentionDays = String(model.storageConfiguration.historyRetentionDays)
        model.refreshStoreStatus()
      }
    }
  }

  private var oldestHistorySummary: String {
    guard let milliseconds = model.storeStatus.oldestHistoryMilliseconds else {
      return "Oldest retained history: none · Estimated retention: unavailable"
    }
    let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    let duration =
      model.storeStatus.estimatedRetainedDurationMilliseconds
      .map { String(format: "%.1f days", Double($0) / 86_400_000) }
      ?? "unavailable"
    return
      "Oldest retained Event: \(date.formatted(date: .abbreviated, time: .shortened)) · Estimated retained duration: \(duration)"
  }

  private func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
  }
}

private struct ViewerDeviceDetail: View {
  @ObservedObject var model: ViewerApplicationModel
  let session: ViewerSessionSnapshot
  @State private var nickname: String
  @State private var uplink: String
  @State private var downlink: String
  @State private var validationMessage: String?

  init(model: ViewerApplicationModel, session: ViewerSessionSnapshot) {
    self.model = model
    self.session = session
    _nickname = State(initialValue: session.nickname ?? "")
    _uplink = State(initialValue: String(session.requestedPolicy.appUplink))
    _downlink = State(initialValue: String(session.requestedPolicy.appDownlink))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.title2).fontWeight(.semibold)
            Text("Unauthenticated App identity hint")
              .font(.caption).foregroundStyle(.orange)
          }
          Spacer()
          Button("Disconnect") { model.disconnectSelectedDevice() }
            .disabled(session.connectionID == nil || session.state == .disconnecting)
        }
        GroupBox("Identity") {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            detailRow("Installation", session.installationAlias)
            detailRow("Bundle ID", session.route.applicationIdentifier ?? "Not supplied")
            detailRow("App version", session.applicationVersion ?? "Not supplied")
            detailRow("State", session.state.rawValue.capitalized)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Local nickname") {
          HStack {
            TextField("Optional nickname", text: $nickname)
              .accessibilityLabel("Device nickname")
            Button("Save") {
              validationMessage =
                model.updateSelectedNickname(nickname)
                ? nil : "Nickname must be 1–80 characters without control characters."
            }
          }
        }
        GroupBox("Flow policy") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              TextField("App uplink events per second", text: $uplink)
              TextField("App downlink events per second", text: $downlink)
              Button("Request") {
                validationMessage =
                  model.updateSelectedRates(
                    appUplink: uplink,
                    appDownlink: downlink
                  ) ? nil : "Rates must be zero or supported positive numbers."
              }
              .disabled(session.connectionID == nil)
            }
            Text(
              "Requested: ↑ \(session.requestedPolicy.appUplink)/s  ↓ \(session.requestedPolicy.appDownlink)/s"
            )
            if let effective = session.effectivePolicy {
              Text("Effective: ↑ \(effective.appUplink)/s  ↓ \(effective.appDownlink)/s")
            } else {
              Text("Effective: awaiting App acceptance").foregroundStyle(.secondary)
            }
          }
        }
        if let validationMessage {
          Text(validationMessage).foregroundStyle(.red).accessibilityLabel(validationMessage)
        }
        GroupBox("Queues and throughput") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            detailRow(
              "App → Viewer queue",
              queueSummary(
                count: session.uplinkCount,
                bytes: session.uplinkBytes,
                oldestWaitNanoseconds: session.uplinkOldestWaitNanoseconds
              )
            )
            detailRow(
              "Viewer → App queue",
              queueSummary(
                count: session.downlinkCount,
                bytes: session.downlinkBytes,
                oldestWaitNanoseconds: session.downlinkOldestWaitNanoseconds
              )
            )
            detailRow("Current ingress", "\(session.ingressEventsPerSecond) events/s")
            detailRow("Current egress", "\(session.egressEventsPerSecond) events/s")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Event counters") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            detailRow("Received", String(session.receivedEvents))
            detailRow("Delivered locally", String(session.deliveredEvents))
            detailRow("Sent", String(session.sentEvents))
            detailRow("Local drops", String(session.droppedEvents))
            detailRow("Overflow drops", String(session.overflowDroppedEvents))
            detailRow("Expired", String(session.expiredEvents))
            detailRow("Keep-latest replacements", String(session.coalescedEvents))
            detailRow("Connection-owned clears", String(session.routeDroppedEvents))
            detailRow("Remote-reported drops", String(session.remoteDroppedEvents))
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(24)
    }
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }

  private func queueSummary(
    count: Int,
    bytes: Int,
    oldestWaitNanoseconds: UInt64?
  ) -> String {
    let wait =
      oldestWaitNanoseconds.map {
        String(format: "%.3f s oldest", Double($0) / 1_000_000_000)
      } ?? "no pending wait"
    return "\(count) events, \(bytes) bytes, \(wait)"
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
      Text(title).font(.headline)
      Text(description).multilineTextAlignment(.center).foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
