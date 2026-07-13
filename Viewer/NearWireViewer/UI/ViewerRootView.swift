import SwiftUI

enum ViewerWorkspaceRegion: String, CaseIterable, Equatable, Sendable {
  case sourceAndDevices
  case eventTimeline
  case eventInspector
  case controlComposer
}

enum ViewerWorkspaceLayout {
  static let regions = ViewerWorkspaceRegion.allCases
  static let minimumWindowWidth: CGFloat = 1_000
  static let minimumWindowHeight: CGFloat = 640
  static let sourceMinimumWidth: CGFloat = 220
  static let sourceIdealWidth: CGFloat = 260
  static let sourceMaximumWidth: CGFloat = 360
  static let timelineMinimumWidth: CGFloat = 340
  static let timelineIdealWidth: CGFloat = 500
  static let inspectorMinimumWidth: CGFloat = 280
  static let inspectorIdealWidth: CGFloat = 360
  static let composerMinimumHeight: CGFloat = 240
  static let composerIdealHeight: CGFloat = 300
  static let composerMaximumHeight: CGFloat = 460
}

struct ViewerRootView: View {
  @ObservedObject var model: ViewerApplicationModel
  @State private var showsDeviceDetails = false

  var body: some View {
    VStack(spacing: 0) {
      pairingHeader
      Divider()
      HSplitView {
        sourceAndDeviceSidebar
          .frame(
            minWidth: ViewerWorkspaceLayout.sourceMinimumWidth,
            idealWidth: ViewerWorkspaceLayout.sourceIdealWidth,
            maxWidth: ViewerWorkspaceLayout.sourceMaximumWidth
          )
          .accessibilityIdentifier("nearwire.workspace.source-devices")
        eventWorkspace
      }
    }
    .sheet(isPresented: $showsDeviceDetails) {
      deviceDetailsSheet
    }
    .onChange(of: model.selectedRoute) { route in
      if route == nil { showsDeviceDetails = false }
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

  @ViewBuilder
  private var sourceAndDeviceSidebar: some View {
    if let explorer = model.explorerController {
      ViewerExplorerSidebarView(
        application: model,
        explorer: explorer,
        showsDeviceDetails: $showsDeviceDetails
      )
    } else {
      sourceAndDevicePlaceholder
    }
  }

  private var sourceAndDevicePlaceholder: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Sources & Devices").font(.headline)
        Spacer()
        Text("\(model.sessions.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(model.sessions.count) device rows")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Divider()
      List(selection: $model.selectedRoute) {
        Section("Current Source") {
          HStack(spacing: 10) {
            Image(systemName: liveSourceIcon)
              .foregroundStyle(liveSourceTint)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text("Live")
              Text(liveSourceStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Live source, \(liveSourceStatus)")
        }
        Section("History") {
          Text("Recorded sessions will appear here.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("Devices") {
          if model.sessions.isEmpty {
            Label("No connected or recent Apps", systemImage: "iphone.slash")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
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
        if !model.pendingApps.isEmpty {
          Section("Awaiting Approval") {
            ForEach(model.pendingApps) { app in
              VStack(alignment: .leading, spacing: 6) {
                Text(app.displayName).font(.headline)
                Text(app.installationAlias).font(.caption).foregroundStyle(.secondary)
                Text(app.compatibilityStatus).font(.caption2).foregroundStyle(.secondary)
                HStack {
                  Button("Reject") { model.reject(app.id) }
                  Button("Accept") { model.accept(app.id) }.buttonStyle(.borderedProminent)
                }
              }
              .padding(.vertical, 3)
            }
          }
        }
      }
      Divider()
      Button {
        showsDeviceDetails = true
      } label: {
        Label("Device Settings & Telemetry", systemImage: "slider.horizontal.3")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .disabled(model.selectedSession == nil)
      .accessibilityHint(
        "Opens nickname, rate, queue, throughput, Event counter, and disconnect controls."
      )
      .padding(12)
    }
  }

  private var eventWorkspace: some View {
    VSplitView {
      HSplitView {
        eventTimeline
          .frame(
            minWidth: ViewerWorkspaceLayout.timelineMinimumWidth,
            idealWidth: ViewerWorkspaceLayout.timelineIdealWidth
          )
          .accessibilityIdentifier("nearwire.workspace.event-timeline")
        eventInspector
          .frame(
            minWidth: ViewerWorkspaceLayout.inspectorMinimumWidth,
            idealWidth: ViewerWorkspaceLayout.inspectorIdealWidth
          )
          .accessibilityIdentifier("nearwire.workspace.event-inspector")
      }
      controlComposer
        .frame(
          minHeight: ViewerWorkspaceLayout.composerMinimumHeight,
          idealHeight: ViewerWorkspaceLayout.composerIdealHeight,
          maxHeight: ViewerWorkspaceLayout.composerMaximumHeight
        )
        .accessibilityIdentifier("nearwire.workspace.control-composer")
    }
  }

  private var eventTimeline: some View {
    Group {
      if let explorer = model.explorerController {
        ViewerExplorerTimelineView(explorer: explorer)
      } else {
        VStack(spacing: 0) {
          workspacePaneHeader(title: "Event Timeline", systemImage: "list.bullet.rectangle")
          Divider()
          ViewerEmptyState(
            title: "Runtime Not Ready",
            systemImage: "clock.arrow.circlepath",
            description: "The Event explorer appears when the Viewer runtime starts."
          )
        }
      }
    }
  }

  private var eventInspector: some View {
    Group {
      if let explorer = model.explorerController {
        ViewerExplorerInspectorView(explorer: explorer)
      } else {
        VStack(spacing: 0) {
          workspacePaneHeader(title: "Event Inspector", systemImage: "sidebar.right")
          Divider()
          ViewerEmptyState(
            title: "Select an Event",
            systemImage: "doc.text.magnifyingglass",
            description: "Event metadata and bounded content views appear here."
          )
        }
      }
    }
  }

  private var controlComposer: some View {
    Group {
      if let composer = model.composerController {
        ViewerControlComposerView(controller: composer)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Label("Viewer → App Control", systemImage: "paperplane")
              .font(.headline)
            Spacer()
            Text("\(activeSessionCount) active")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Divider()
          Text("The memory-only control composer appears when the Viewer runtime starts.")
            .foregroundStyle(.secondary)
          Text("Local queue admission is not a delivery or processing acknowledgement.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
      }
    }
  }

  private func workspacePaneHeader(title: String, systemImage: String) -> some View {
    HStack {
      Label(title, systemImage: systemImage).font(.headline)
      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var deviceDetailsSheet: some View {
    if let session = model.selectedSession {
      ViewerDeviceDetail(model: model, session: session)
        .id(session.route.storageKey)
        .frame(minWidth: 620, minHeight: 620)
    } else {
      ViewerEmptyState(
        title: "Device No Longer Available",
        systemImage: "iphone.slash",
        description: "Close this panel and choose another connected or recent App."
      )
      .frame(width: 480, height: 320)
    }
  }

  private var activeSessionCount: Int {
    model.sessions.lazy.filter { $0.state == .active }.count
  }

  private var liveSourceStatus: String {
    switch model.status {
    case .stopped, .stopping:
      return "No current runtime"
    case .starting:
      return "Starting"
    case .failed:
      return "Unavailable"
    case .listening:
      return model.storeStatus.state == .available
        ? "Recording enabled" : "Live — not recording"
    }
  }

  private var liveSourceIcon: String {
    switch model.status {
    case .listening: return "dot.radiowaves.left.and.right"
    case .starting, .stopping: return "hourglass"
    case .stopped, .failed: return "circle.dashed"
    }
  }

  private var liveSourceTint: Color {
    switch model.status {
    case .listening: return .green
    case .starting, .stopping: return .orange
    case .stopped, .failed: return .secondary
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
        Text(storageStatusSummary)
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

  private var storageStatusSummary: String {
    let state = model.storeStatus.migration?.message ?? model.storeStatus.state.rawValue
    return
      "State: \(state) · Last cleanup: \(model.storeStatus.lastCleanupCategory.rawValue) · Logical quota: \(format(model.storeStatus.logicalQuotaBytes)) / \(format(model.storeStatus.capacityBytes)) · Allocated files: \(format(model.storeStatus.allocatedFootprintBytes)) · Pinned estimate: \(format(model.storeStatus.pinnedQuotaBytes))"
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
