import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ViewerExplorerSidebarView: View {
  @ObservedObject var application: ViewerApplicationModel
  @ObservedObject var explorer: ViewerEventExplorerController
  @Binding var showsDeviceDetails: Bool
  @State private var showsRecordingEditor = false
  @State private var showsExport = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Sources & Devices").font(.headline)
        Spacer()
        Text("\(explorer.deviceRows.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(explorer.deviceRows.count) device rows")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Divider()
      List {
        Section("Sources") {
          ForEach(explorer.sourceRows) { row in
            sourceRow(row)
              .onAppear {
                guard row.id == explorer.sourceRows.last?.id, explorer.hasOlderRecordings else {
                  return
                }
                explorer.loadOlderRecordings()
              }
          }
          if explorer.recordingsState == .loading {
            ProgressView("Loading recordings")
              .controlSize(.small)
          }
          if case .failed(let failure) = explorer.recordingsState {
            Label(failure.operatorMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        Section("Devices") {
          Button {
            explorer.selectAllDevices()
          } label: {
            selectionRow(
              title: "All Devices",
              subtitle: "Merge every materialized App lane",
              selected: explorer.usesAllDevices,
              systemImage: "rectangle.3.group"
            )
          }
          .buttonStyle(.plain)
          ForEach(explorer.deviceRows) { row in
            Button {
              explorer.toggleDevice(row.id)
              if let session = application.sessions.first(where: { $0.connectionID == row.id }) {
                application.selectedRoute = session.route
              }
            } label: {
              deviceRow(row)
            }
            .buttonStyle(.plain)
            .onAppear {
              guard row.id == explorer.deviceRows.last?.id, explorer.hasOlderDevices else { return }
              explorer.loadOlderDevices()
            }
          }
          if explorer.devicesState == .loading {
            ProgressView("Loading devices")
              .controlSize(.small)
          } else if explorer.deviceRows.isEmpty {
            Label("No Apps in this source", systemImage: "iphone.slash")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if case .failed(let failure) = explorer.devicesState {
            Label(failure.operatorMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        if !application.pendingApps.isEmpty {
          Section("Awaiting Approval") {
            ForEach(application.pendingApps) { app in
              VStack(alignment: .leading, spacing: 6) {
                Text(app.displayName).font(.headline)
                Text(app.installationAlias).font(.caption).foregroundStyle(.secondary)
                Text(app.compatibilityStatus).font(.caption2).foregroundStyle(.secondary)
                HStack {
                  Button("Reject") { application.reject(app.id) }
                  Button("Accept") { application.accept(app.id) }
                    .buttonStyle(.borderedProminent)
                }
              }
              .padding(.vertical, 3)
            }
          }
        }
      }
      Divider()
      if let recording = explorer.selectedRecordingRow {
        recordingActions(recording)
        Divider()
      }
      Button {
        showsDeviceDetails = true
      } label: {
        Label("Device Settings & Telemetry", systemImage: "slider.horizontal.3")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .disabled(application.selectedSession == nil)
      .accessibilityHint(
        "Opens nickname, rate, queue, throughput, Event counter, and disconnect controls."
      )
      .padding(12)
    }
    .sheet(isPresented: $showsRecordingEditor) {
      if let recording = explorer.selectedRecordingRow {
        ViewerRecordingEditorSheet(
          explorer: explorer,
          recording: recording,
          isPresented: $showsRecordingEditor
        )
        .id("\(recording.rowID)-\(recording.revision)")
        .frame(minWidth: 560, minHeight: 620)
      }
    }
    .sheet(isPresented: $showsExport) {
      ViewerExportSheet(explorer: explorer, isPresented: $showsExport)
        .frame(minWidth: 540, minHeight: 480)
    }
  }

  private func sourceRow(_ row: ViewerExplorerSourcePresentationRow) -> some View {
    Button {
      explorer.selectSource(row.id)
    } label: {
      HStack(alignment: .top, spacing: 9) {
        Image(
          systemName: row.isCurrent ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath"
        )
        .foregroundStyle(
          row.id == explorer.selectedSourceID ? Color.accentColor : Color.secondary
        )
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(row.title).lineLimit(1)
            if row.isPinned {
              Image(systemName: "pin.fill").accessibilityLabel("Pinned")
            }
            Spacer()
            if row.id == explorer.selectedSourceID {
              Image(systemName: "checkmark").accessibilityLabel("Selected")
            }
          }
          Text(row.state).font(.caption).foregroundStyle(.secondary)
          if let wall = row.startedWallMilliseconds {
            Text(ViewerExplorerFormatting.date(wall))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          if row.hasGap || row.hasDrop {
            Label("Incomplete diagnostics", systemImage: "exclamationmark.triangle")
              .font(.caption2)
              .foregroundStyle(.orange)
          }
        }
      }
      .padding(.vertical, 3)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "\(row.title), \(row.state), \(row.id == explorer.selectedSourceID ? "selected" : "not selected")\(row.isPinned ? ", pinned" : "")\(row.hasGap || row.hasDrop ? ", incomplete diagnostics" : "")"
    )
    .accessibilityHint("Selects this Event source.")
  }

  private func deviceRow(_ row: ViewerExplorerDevicePresentationRow) -> some View {
    selectionRow(
      title: row.title,
      subtitle: "\(row.subtitle) · \(row.state)",
      selected: explorer.selectedDeviceIDs.contains(row.id),
      systemImage: row.isMaterialized ? "iphone" : "iphone.radiowaves.left.and.right"
    )
    .overlay(alignment: .bottomLeading) {
      if row.hasGap || row.hasDrop {
        Text("Gap or drop observed")
          .font(.caption2)
          .foregroundStyle(.orange)
          .padding(.leading, 25)
          .offset(y: 8)
      }
    }
    .padding(.bottom, row.hasGap || row.hasDrop ? 8 : 0)
    .accessibilityHint("Adds or removes this App from the merged timeline.")
  }

  private func selectionRow(
    title: String,
    subtitle: String,
    selected: Bool,
    systemImage: String
  ) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: systemImage).foregroundStyle(.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).lineLimit(1)
        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      Image(systemName: selected ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .accessibilityLabel(selected ? "Selected" : "Not selected")
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title), \(subtitle), \(selected ? "selected" : "not selected")")
  }

  private func recordingActions(_ recording: ViewerRecordingCatalogRow) -> some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Button {
          explorer.clearOperationPresentation()
          showsRecordingEditor = true
        } label: {
          Label("Recording", systemImage: "square.and.pencil")
        }
        .disabled(!explorer.canManageSelectedRecording)
        Button {
          explorer.setSelectedRecordingPinned(!recording.pinned)
        } label: {
          Label(
            recording.pinned ? "Unpin" : "Pin", systemImage: recording.pinned ? "pin.slash" : "pin")
        }
        .disabled(!explorer.canManageSelectedRecording || recordingOperationIsRunning)
        Menu {
          Button("Complete Recording") {
            explorer.prepareExport(.completeRecording)
            showsExport = true
          }
          Button("Current Filtered Result") {
            explorer.prepareExport(.currentFilteredResult)
            showsExport = true
          }
          .disabled(!explorer.canExportFilteredResult)
        } label: {
          Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(!explorer.canManageSelectedRecording)
      }
      .buttonStyle(.bordered)
      if case .failed(let failure) = explorer.recordingOperationState {
        Text(failure.operatorMessage)
          .font(.caption2)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var recordingOperationIsRunning: Bool {
    if case .running = explorer.recordingOperationState { return true }
    return false
  }
}

struct ViewerExplorerTimelineView: View {
  @ObservedObject var explorer: ViewerEventExplorerController
  @State private var showsFilters = false
  @State private var showsGaps = false

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      guidance
      content
      if hasDiagnostics {
        Divider()
        diagnosticLane
      }
    }
    .sheet(isPresented: $showsFilters) {
      ViewerExplorerFilterSheet(explorer: explorer, isPresented: $showsFilters)
        .frame(minWidth: 560, minHeight: 620)
    }
  }

  private var toolbar: some View {
    VStack(spacing: 8) {
      HStack {
        Label("Event Timeline", systemImage: "list.bullet.rectangle").font(.headline)
        Spacer()
        Button(explorer.isPaused ? "Resume" : "Pause") { explorer.pauseOrResume() }
          .accessibilityHint("Freezes or resumes timeline presentation only.")
        Button("Jump to Latest") { explorer.jumpToLatest() }
          .disabled(explorer.autoFollow && !explorer.isPaused)
      }
      HStack(spacing: 8) {
        ViewerBoundedTextInput(
          text: explorer.filterDraft.searchText,
          style: .singleLine,
          accessibilityLabel: "Search Event content",
          accessibilityHelp: "Standard editing is bounded before this filter value is stored.",
          onEdit: { range, replacement in
            explorer.replaceFilterCharacters(.search, range: range, replacement: replacement)
          },
          onSubmit: { explorer.applyFilter() }
        )
        .frame(height: 28)
        Picker(
          "Search mode",
          selection: Binding(
            get: { explorer.filterDraft.searchMode },
            set: { value in explorer.updateFilterDraft { $0.searchMode = value } }
          )
        ) {
          Text("Literal").tag(ViewerExplorerSearchMode.literal)
          Text("Full Text").tag(ViewerExplorerSearchMode.fullText)
        }
        .labelsHidden()
        .frame(width: 110)
        Button("Apply") { explorer.applyFilter() }
        Button {
          showsFilters = true
        } label: {
          Label(
            explorer.activeFilterCount == 0 ? "Filters" : "Filters \(explorer.activeFilterCount)",
            systemImage: "line.3.horizontal.decrease.circle"
          )
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .focusSection()
  }

  @ViewBuilder
  private var guidance: some View {
    if let message = explorer.filterValidationMessage {
      banner(message, systemImage: "exclamationmark.triangle", color: .orange)
    }
    if let message = explorer.liveEvaluationGuidance {
      banner(message, systemImage: "info.circle", color: .secondary)
    }
    if let failure = explorer.timelinePageFailure {
      banner(failure.operatorMessage, systemImage: "exclamationmark.triangle", color: .orange)
    }
  }

  @ViewBuilder
  private var content: some View {
    if explorer.timelineRows.isEmpty {
      switch explorer.traversalState {
      case .loading, .releasing:
        VStack(spacing: 10) {
          ProgressView()
          Text("Loading bounded Event window").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let failure):
        ViewerExplorerEmptyState(
          title: "Timeline Unavailable",
          systemImage: "exclamationmark.triangle",
          description: failure.operatorMessage
        )
      case .paused:
        ViewerExplorerEmptyState(
          title: "Timeline Paused",
          systemImage: "pause.circle",
          description: "Resume to load a fresh bounded Event window."
        )
      case .idle, .ready:
        ViewerExplorerEmptyState(
          title: "No Matching Events",
          systemImage: "line.3.horizontal.decrease.circle",
          description: "Adjust the source, device selection, or filters."
        )
      }
    } else {
      List(selection: selectedEventBinding) {
        ForEach(explorer.timelineRows) { row in
          ViewerExplorerTimelineRowView(row: row)
            .tag(row.id)
            .onAppear {
              if row.id == explorer.timelineRows.first?.id, explorer.hasOlderEvents {
                explorer.loadOlderEvents()
              }
              if row.id == explorer.timelineRows.last?.id, explorer.hasNewerEvents {
                explorer.loadNewerEvents()
              }
            }
        }
      }
      .accessibilityLabel("Event timeline")
    }
  }

  private var selectedEventBinding: Binding<ViewerExplorerEventIdentity?> {
    Binding(
      get: { explorer.selectedEventID },
      set: { explorer.selectEvent($0) }
    )
  }

  private var hasDiagnostics: Bool {
    !explorer.gapRows.isEmpty || explorer.liveGapLane?.hasDiagnostic == true
      || explorer.gapPageFailure != nil
  }

  private var diagnosticLane: some View {
    DisclosureGroup(isExpanded: $showsGaps) {
      VStack(alignment: .leading, spacing: 8) {
        if let gaps = explorer.liveGapLane?.gaps {
          Text(
            "Live: ingress \(gaps.ingressOverflowCount), window \(gaps.windowOverflowCount), conflicts \(gaps.residentConflictCount), diagnostic loss \(gaps.diagnosticLossCount), storage outages \(gaps.storeUnavailableCount), recoveries \(gaps.storeRecoveryCount)"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(gaps.storeUnavailable ? .orange : .secondary)
        }
        if let failure = explorer.gapPageFailure {
          Text(failure.operatorMessage).font(.caption).foregroundStyle(.orange)
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(explorer.gapRows, id: \.rowID) { gap in
              VStack(alignment: .leading, spacing: 2) {
                Text("\(gap.namespace) · \(gap.reason)").font(.caption).fontWeight(.medium)
                Text(
                  "\(gap.count) records · \(gap.directions) · \(ViewerExplorerFormatting.date(gap.firstViewerWallMilliseconds)) – \(ViewerExplorerFormatting.date(gap.lastViewerWallMilliseconds))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
              }
              .onAppear {
                if gap.rowID == explorer.gapRows.first?.rowID, explorer.hasOlderGaps {
                  explorer.loadOlderGaps()
                }
                if gap.rowID == explorer.gapRows.last?.rowID, explorer.hasNewerGaps {
                  explorer.loadNewerGaps()
                }
              }
            }
          }
        }
        .frame(maxHeight: 120)
      }
      .padding(.top, 8)
    } label: {
      Label("Diagnostic Gap Lane", systemImage: "exclamationmark.triangle")
        .font(.caption)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private func banner(_ message: String, systemImage: String, color: Color) -> some View {
    Label(message, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.08))
  }
}

private struct ViewerExplorerTimelineRowView: View {
  let row: ViewerExplorerTimelinePresentationRow

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(row.eventType).font(.headline).lineLimit(1)
        Spacer()
        Text(ViewerExplorerFormatting.time(row.viewerWallMilliseconds))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 7) {
        Label(row.deviceAlias, systemImage: "iphone")
        Text(row.direction)
        Text(row.priority)
        Text(ByteCountFormatter.string(fromByteCount: row.contentByteCount, countStyle: .binary))
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      HStack(spacing: 6) {
        if row.isTransient { badge("Not recorded", color: .orange) }
        if let disposition = row.disposition { badge(disposition, color: .secondary) }
        if row.hasGap { badge("Gap", color: .orange) }
        if row.hasDrop { badge("Drop", color: .red) }
        if row.hasPresentationConflict { badge("Conflict", color: .red) }
        if row.sessionEnded { badge("Session ended", color: .secondary) }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilitySummary)
  }

  private var accessibilitySummary: String {
    let recording = row.isTransient ? "not recorded" : "recorded"
    var states = [recording]
    if let disposition = row.disposition { states.append("disposition \(disposition)") }
    if row.hasGap { states.append("gap") }
    if row.hasDrop { states.append("drop") }
    if row.hasPresentationConflict { states.append("presentation conflict") }
    if row.sessionEnded { states.append("session ended") }
    return
      "\(row.eventType), \(row.deviceAlias), \(row.direction), \(row.priority), \(states.joined(separator: ", ")), \(ViewerExplorerFormatting.date(row.viewerWallMilliseconds))"
  }

  private func badge(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(color)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(color.opacity(0.1), in: Capsule())
  }
}

private struct ViewerRecordingEditorSheet: View {
  @ObservedObject var explorer: ViewerEventExplorerController
  let recording: ViewerRecordingCatalogRow
  @Binding var isPresented: Bool
  @StateObject private var editor: ViewerRecordingEditorModel
  @State private var showsDeleteConfirmation = false

  init(
    explorer: ViewerEventExplorerController,
    recording: ViewerRecordingCatalogRow,
    isPresented: Binding<Bool>
  ) {
    self.explorer = explorer
    self.recording = recording
    _isPresented = isPresented
    _editor = StateObject(
      wrappedValue: ViewerRecordingEditorModel(name: recording.name, note: recording.note)
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Recording").font(.title2).fontWeight(.semibold)
          Text(recording.state.capitalized)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if recording.pinned {
          Label("Pinned", systemImage: "pin.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Form {
        Section("Metadata") {
          VStack(alignment: .leading, spacing: 5) {
            Text("Optional name").font(.caption).foregroundStyle(.secondary)
            ViewerBoundedTextInput(
              text: editor.name,
              style: .singleLine,
              accessibilityLabel: "Optional recording name",
              accessibilityHelp: "Up to 80 characters and 120 UTF-8 bytes.",
              onEdit: { range, replacement in
                editor.replaceCharacters(field: .name, range: range, replacement: replacement)
              }
            )
            .frame(height: 28)
          }
          VStack(alignment: .leading, spacing: 6) {
            Text("Optional note").font(.caption).foregroundStyle(.secondary)
            ViewerBoundedTextInput(
              text: editor.note,
              style: .multiline,
              accessibilityLabel: "Optional recording note",
              accessibilityHelp: "Standard editing is bounded before this note is stored.",
              onEdit: { range, replacement in
                editor.replaceCharacters(field: .note, range: range, replacement: replacement)
              }
            )
            .frame(minHeight: 120)
          }
          HStack {
            Spacer()
            Button("Save Metadata") {
              explorer.updateSelectedRecording(
                name: editor.name,
                note: editor.note,
                pinned: recording.pinned
              )
            }
            .buttonStyle(.borderedProminent)
            .disabled(operationIsRunning)
          }
        }
        Section("Append-only annotation") {
          Text(
            "Annotations are appended to recording history. Saving metadata does not append this text."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          ViewerBoundedTextInput(
            text: editor.annotation,
            style: .multiline,
            accessibilityLabel: "Append-only recording annotation",
            accessibilityHelp: "Standard editing is bounded before this annotation is stored.",
            onEdit: { range, replacement in
              editor.replaceCharacters(field: .annotation, range: range, replacement: replacement)
            }
          )
          .frame(minHeight: 120)
          HStack {
            Spacer()
            Button("Append Annotation") {
              explorer.appendSelectedRecordingAnnotation(editor.annotation)
            }
            .disabled(editor.annotation.isEmpty || operationIsRunning)
          }
        }
      }
      if let validation = editor.validationMessage {
        Label(validation, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
      operationStatus
      Divider()
      HStack {
        Button("Delete Recording", role: .destructive) {
          explorer.prepareSelectedRecordingDelete()
        }
        .disabled(recording.state.lowercased() == "active" || operationIsRunning)
        .accessibilityHint(
          "Requests a revision-bound confirmation. Active or leased recordings cannot be deleted."
        )
        Spacer()
        Button("Done") {
          explorer.cancelDeleteConfirmation()
          explorer.clearOperationPresentation()
          isPresented = false
        }
      }
    }
    .padding(22)
    .focusSection()
    .confirmationDialog(
      "Delete this recording?",
      isPresented: $showsDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete Recording", role: .destructive) {
        explorer.confirmSelectedRecordingDelete()
      }
      Button("Cancel", role: .cancel) {
        explorer.cancelDeleteConfirmation()
      }
    } message: {
      Text(
        "Deletion is permanent. The confirmation is valid only for the exact current recording and annotation revisions."
      )
    }
    .onChange(of: explorer.revision) { _ in
      if explorer.recordingOperationState == .awaitingDeleteConfirmation {
        showsDeleteConfirmation = true
      }
      if explorer.recordingOperationState == .succeeded("Annotation appended."),
        !editor.annotation.isEmpty
      {
        editor.clearAnnotation()
      }
      if explorer.recordingOperationState == .succeeded("Recording deleted.") {
        isPresented = false
      }
    }
    .onChange(of: showsDeleteConfirmation) { presented in
      if !presented, explorer.recordingOperationState == .awaitingDeleteConfirmation {
        explorer.cancelDeleteConfirmation()
      }
    }
  }

  @ViewBuilder
  private var operationStatus: some View {
    switch explorer.recordingOperationState {
    case .idle:
      EmptyView()
    case .running:
      ProgressView("Applying revision-safe recording operation")
    case .awaitingDeleteConfirmation:
      Label("Delete confirmation ready", systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
    case .succeeded(let message):
      Label(message, systemImage: "checkmark.circle")
        .font(.caption)
        .foregroundStyle(.green)
    case .failed(let failure):
      Label(failure.operatorMessage, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private var operationIsRunning: Bool {
    if case .running = explorer.recordingOperationState { return true }
    return false
  }

}

private struct ViewerExportSheet: View {
  @ObservedObject var explorer: ViewerEventExplorerController
  @Binding var isPresented: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Export JSON").font(.title2).fontWeight(.semibold)
        Spacer()
        if case .disclosure(let mode, _, _) = explorer.exportState {
          Text(mode.title).font(.caption).foregroundStyle(.secondary)
        }
      }
      Divider()
      content
      Spacer(minLength: 0)
      Divider()
      HStack {
        if isExporting {
          Button("Cancel Export", role: .destructive) { explorer.cancelExport() }
            .disabled(isCancellingExport)
        }
        Spacer()
        Button(closeTitle) { close() }
          .disabled(isExporting)
      }
    }
    .padding(22)
    .interactiveDismissDisabled(isExporting)
  }

  @ViewBuilder
  private var content: some View {
    switch explorer.exportState {
    case .idle:
      ViewerExplorerEmptyState(
        title: "No Export Prepared",
        systemImage: "square.and.arrow.up",
        description: "Choose Complete Recording or Current Filtered Result."
      )
    case .preparing:
      VStack(spacing: 12) {
        ProgressView()
        Text("Preparing one frozen export scope")
        Text("No destination has been requested and no file has been written.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .disclosure(_, let eventCount, let disclosure):
      disclosureView(eventCount: eventCount, disclosure: disclosure)
    case .exporting(let eventCount):
      VStack(spacing: 12) {
        ProgressView()
        Text("Exporting \(eventCount) recorded Event(s)")
        Text("The destination is replaced only after the complete JSON file commits.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .cancelling(let eventCount):
      VStack(spacing: 12) {
        ProgressView()
        Text("Cancelling export of \(eventCount) recorded Event(s)")
        Text("Waiting for the export commit boundary before reporting the final result.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .completed(let eventCount):
      ViewerExplorerEmptyState(
        title: "Export Complete",
        systemImage: "checkmark.circle",
        description: "Committed \(eventCount) recorded Event(s) to the selected JSON file."
      )
    case .cancelled:
      ViewerExplorerEmptyState(
        title: "Export Cancelled",
        systemImage: "xmark.circle",
        description: "No partial file replaced a prior destination."
      )
    case .failed(let failure):
      ViewerExplorerEmptyState(
        title: "Export Unavailable",
        systemImage: "exclamationmark.triangle",
        description: failure.operatorMessage
      )
    }
  }

  private func disclosureView(
    eventCount: Int64,
    disclosure: ViewerExportDisclosure
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Review Before Choosing a Destination", systemImage: "exclamationmark.shield")
        .font(.headline)
      Text("This export contains \(eventCount) recorded Event(s).")
        .font(.body.monospacedDigit())
      disclosureLine(disclosure.warning)
      if disclosure.unencrypted {
        disclosureLine("The JSON file is unencrypted.")
      }
      if disclosure.aliasesArePseudonymsNotRedaction {
        disclosureLine("Exported aliases are pseudonyms, not redaction.")
      }
      if disclosure.outsideViewerQuotaAndRetention {
        disclosureLine(
          "The file is outside Viewer quota, retention, cleanup, and automatic deletion.")
      }
      if disclosure.mayBeSyncedOrBackedUpByDestinationProvider {
        disclosureLine("The chosen destination provider may sync or back up the file.")
      }
      disclosureLine(ViewerExportPresentationText.transientRowsExcluded)
      Text("NearWire does not remember the selected destination.")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("I Understand — Choose Destination") { chooseDestination() }
          .buttonStyle(.borderedProminent)
      }
    }
  }

  private func disclosureLine(_ text: String) -> some View {
    Label(text, systemImage: "circle.fill")
      .font(.body)
      .symbolRenderingMode(.hierarchical)
  }

  private var isExporting: Bool {
    if case .exporting = explorer.exportState { return true }
    if case .cancelling = explorer.exportState { return true }
    return false
  }

  private var isCancellingExport: Bool {
    if case .cancelling = explorer.exportState { return true }
    return false
  }

  private var closeTitle: String {
    if case .completed = explorer.exportState { return "Done" }
    return "Close"
  }

  private func chooseDestination() {
    explorer.beginExportDestinationSelection { completion in
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      panel.nameFieldStringValue = "NearWire-Export.json"
      panel.title = "Export NearWire JSON"
      panel.message = "Choose a destination for the unencrypted JSON export."
      panel.begin { response in
        completion(response == .OK ? panel.url : nil)
      }
      return {
        panel.cancel(nil)
        panel.orderOut(nil)
      }
    }
  }

  private func close() {
    switch explorer.exportState {
    case .preparing, .disclosure:
      explorer.cancelExport()
    case .idle, .completed, .cancelled, .failed:
      explorer.clearOperationPresentation()
    case .exporting, .cancelling:
      return
    }
    isPresented = false
  }
}

extension ViewerExportMode {
  fileprivate var title: String {
    switch self {
    case .completeRecording: return "Complete Recording"
    case .currentFilteredResult: return "Current Filtered Result"
    }
  }
}

struct ViewerExplorerInspectorView: View {
  enum Tab: String, CaseIterable {
    case metadata = "Metadata"
    case raw = "Raw"
    case tree = "Tree"
    case pretty = "Pretty"
    case renderer = "Renderer"
    case causality = "Causality"
  }

  @ObservedObject var explorer: ViewerEventExplorerController
  @State private var tab: Tab = .metadata

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Event Inspector", systemImage: "sidebar.right").font(.headline)
        Spacer()
        if let metadata = explorer.inspectorMetadata {
          Text(metadata.isRecorded ? "Recorded" : "Not recorded")
            .font(.caption)
            .foregroundStyle(metadata.isRecorded ? Color.secondary : Color.orange)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      Divider()
      inspectorContent
    }
  }

  @ViewBuilder
  private var inspectorContent: some View {
    switch explorer.inspectorState {
    case .empty:
      ViewerExplorerEmptyState(
        title: "Select an Event",
        systemImage: "doc.text.magnifyingglass",
        description: "Bounded metadata and content views appear here."
      )
    case .loading:
      VStack(spacing: 10) {
        ProgressView()
        Text("Preparing bounded Event detail").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let failure):
      ViewerExplorerEmptyState(
        title: "Event Detail Unavailable",
        systemImage: "exclamationmark.triangle",
        description: failure.operatorMessage
      )
    case .ready:
      VStack(spacing: 0) {
        Picker("Inspector view", selection: $tab) {
          ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(10)
        Divider()
        tabContent
      }
    }
  }

  @ViewBuilder
  private var tabContent: some View {
    switch tab {
    case .metadata: metadataView
    case .raw: rawView
    case .tree: treeView
    case .pretty: prettyView
    case .renderer: rendererView
    case .causality: causalityView
    }
  }

  @ViewBuilder
  private var metadataView: some View {
    if let value = explorer.inspectorMetadata {
      ScrollView {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
          metadataRow("Type", value.eventType)
          metadataRow("Event UUID", value.eventUUID)
          metadataRow("Device", value.deviceAlias)
          metadataRow("Connection", value.connectionAlias)
          metadataRow("Direction", value.direction)
          metadataRow("Sequence", String(value.wireSequence))
          metadataRow("Priority", value.priority)
          metadataRow("Created", ViewerExplorerFormatting.date(value.createdWallMilliseconds))
          metadataRow(
            "Viewer received", ViewerExplorerFormatting.date(value.viewerWallMilliseconds))
          metadataRow("TTL", "\(value.ttlMilliseconds) ms")
          metadataRow("Schema", String(value.schemaVersion))
          metadataRow("Disposition", value.disposition ?? "None")
          metadataRow("Correlation", value.correlationEventUUID ?? "None")
          metadataRow("Reply to", value.replyToEventUUID ?? "None")
          metadataRow(
            "Content",
            ByteCountFormatter.string(
              fromByteCount: Int64(explorer.inspectorContentByteCount),
              countStyle: .binary
            ))
          metadataRow("Diagnostics", diagnosticSummary(value))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
      }
    }
  }

  private var rawView: some View {
    VStack(spacing: 0) {
      if let chunk = explorer.rawChunk {
        HStack {
          Button("Previous") { explorer.showRawChunk(explorer.rawChunkIndex - 1) }
            .disabled(!chunk.hasPrevious)
          Text("Chunk \(chunk.index + 1)").font(.caption.monospacedDigit())
          Button("Next") { explorer.showRawChunk(explorer.rawChunkIndex + 1) }
            .disabled(!chunk.hasNext)
          Spacer()
          Text("Bytes \(chunk.byteRange.lowerBound)–\(chunk.byteRange.upperBound)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(10)
        Divider()
        ViewerReceivedEventText(
          text: chunk.text,
          accessibilityText: chunk.focusedAccessibilityText
        )
        .accessibilityHint("Received Event content is display-only and has no clipboard command.")
      } else {
        ViewerExplorerEmptyState(
          title: "Raw JSON Unavailable",
          systemImage: "curlybraces",
          description: "The selected chunk could not be prepared."
        )
      }
    }
  }

  @ViewBuilder
  private var treeView: some View {
    if let tree = explorer.inspectorTreeState {
      List(tree.nodes, id: \.id) { node in
        HStack(alignment: .top) {
          Image(systemName: node.kind.hasChildren ? "chevron.right.circle" : "circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(node.preview)
            .font(.system(.body, design: .monospaced))
            .lineLimit(3)
          Spacer()
          if let offset = node.nextChildOffset {
            Button(offset == 0 ? "Expand" : "More") {
              explorer.expandTree(nodeID: node.id, offset: offset)
            }
            .controlSize(.small)
          }
        }
        .padding(.leading, node.parentID == nil ? 0 : 14)
      }
    } else {
      ViewerExplorerEmptyState(
        title: "Tree Needs Refinement",
        systemImage: "point.3.connected.trianglepath.dotted",
        description: explorer.rendererPreparation?.generic.treeGuidance
          ?? "Use raw JSON or narrow the selected Event."
      )
    }
  }

  @ViewBuilder
  private var prettyView: some View {
    if let pretty = explorer.rendererPreparation?.generic.prettyText {
      ViewerReceivedEventText(
        text: pretty,
        accessibilityText: ViewerStructuredTextEscaper.escape(
          pretty,
          maximumBytes: ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
        )
      )
      .accessibilityHint("Received Event content is display-only and has no clipboard command.")
    } else {
      ViewerExplorerEmptyState(
        title: "Pretty JSON Unavailable",
        systemImage: "text.alignleft",
        description: explorer.rendererPreparation?.generic.prettyGuidance
          ?? "Use the bounded raw JSON chunks."
      )
    }
  }

  @ViewBuilder
  private var rendererView: some View {
    if let preparation = explorer.rendererPreparation {
      if let guidance = preparation.fallbackGuidance {
        VStack(spacing: 0) {
          Label(guidance, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
          Divider()
          genericRendererSummary(preparation)
        }
      } else if let specialized = preparation.specialized {
        specializedRenderer(specialized)
      } else {
        genericRendererSummary(preparation)
      }
    }
  }

  @ViewBuilder
  private func specializedRenderer(_ value: ViewerSpecializedRendererPreparation) -> some View {
    switch value {
    case .log(let log):
      List(Array(log.chunks.enumerated()), id: \.offset) { _, chunk in
        Text(chunk)
          .font(.system(.body, design: .monospaced))
          .accessibilityLabel(log.focusedAccessibilityText)
      }
    case .table(let table):
      List(Array(table.rows.enumerated()), id: \.offset) { _, row in
        HStack(alignment: .top) {
          Text(row.keyPreview).fontWeight(.medium)
          Spacer()
          Text(row.valuePreview).font(.system(.body, design: .monospaced)).lineLimit(3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.focusedAccessibilityText)
      }
    case .numeric(let numeric):
      List(Array(numeric.points.enumerated()), id: \.offset) { _, point in
        HStack {
          Text("Row \(point.row), field \(point.field)")
          Spacer()
          Text(String(point.value)).font(.system(.body, design: .monospaced))
        }
      }
    case .timeline(let timeline):
      ScrollView {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
          metadataRow("Type", timeline.eventType)
          metadataRow("Device", timeline.deviceAlias)
          metadataRow("Direction", timeline.direction)
          metadataRow("Priority", timeline.priority)
          metadataRow("Received", ViewerExplorerFormatting.date(timeline.viewerWallMilliseconds))
          metadataRow("Disposition", timeline.disposition)
        }
        .padding(14)
      }
    }
  }

  private func genericRendererSummary(_ preparation: ViewerRendererPreparation) -> some View {
    ViewerExplorerEmptyState(
      title: "Generic JSON",
      systemImage: "curlybraces",
      description:
        "Use Raw, Tree, or Pretty. \(preparation.generic.rawChunkCount) bounded raw chunk(s) are available."
    )
  }

  @ViewBuilder
  private var causalityView: some View {
    switch explorer.causalityState {
    case .none:
      ViewerExplorerEmptyState(
        title: "No Causality Selection",
        systemImage: "point.3.filled.connected.trianglepath.dotted",
        description: "Select a recorded Event to inspect bounded causality candidates."
      )
    case .loading:
      ProgressView("Loading causality").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .recordedDataRequired:
      ViewerExplorerEmptyState(
        title: "Recorded Data Required",
        systemImage: "externaldrive.badge.exclamationmark",
        description: "Transient Events do not have durable causality candidates."
      )
    case .failed(let failure):
      ViewerExplorerEmptyState(
        title: "Causality Unavailable",
        systemImage: "exclamationmark.triangle",
        description: failure.operatorMessage
      )
    case .ready(let graph):
      List {
        Section("Candidates") {
          ForEach(graph.nodes, id: \.rowID) { node in
            VStack(alignment: .leading, spacing: 3) {
              Text(node.eventType).font(.headline)
              Text("\(node.direction) · sequence \(node.wireSequence) · \(node.eventUUID)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        Section("Edges") {
          ForEach(Array(graph.edges.enumerated()), id: \.offset) { _, edge in
            VStack(alignment: .leading, spacing: 3) {
              Text(edge.kind == .replyTo ? "Reply to" : "Correlation").fontWeight(.medium)
              Text(edge.referencedEventUUID).font(.caption)
              Text(
                "\(edge.candidateRowIDs.count) candidate(s)\(edge.hasMore ? ", more omitted" : "")\(edge.cyclicCandidateRowIDs.isEmpty ? "" : ", cycle observed")"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
          }
        }
        if graph.truncated {
          Text("Causality candidates were bounded; additional matches may exist.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
    }
  }

  private func metadataRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).lineLimit(4)
    }
  }

  private func diagnosticSummary(_ value: ViewerInspectorEventMetadata) -> String {
    var values: [String] = []
    if value.hasGap { values.append("gap") }
    if value.hasDrop { values.append("drop") }
    if value.hasPresentationConflict { values.append("presentation conflict") }
    if value.sessionEnded { values.append("session ended") }
    return values.isEmpty ? "None" : values.joined(separator: ", ")
  }
}

private struct ViewerExplorerFilterSheet: View {
  @ObservedObject var explorer: ViewerEventExplorerController
  @Binding var isPresented: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Event Filters").font(.title2).fontWeight(.semibold)
        Spacer()
        Button("Clear") { explorer.clearFilter() }
      }
      Form {
        Section("Event") {
          HStack {
            boundedFilterInput("Event type", field: .eventType, value: \.eventTypeText)
            Picker(
              "Type match",
              selection: valueBinding(\.eventTypeMode) { $0.eventTypeMode = $1 }
            ) {
              Text("Exact").tag(ViewerExplorerEventTypeMode.exact)
              Text("Prefix").tag(ViewerExplorerEventTypeMode.prefix)
            }
            .frame(width: 130)
          }
          boundedFilterInput(
            "Application identifier",
            field: .applicationIdentifier,
            value: \.applicationIdentifierText
          )
          boundedFilterInput(
            "Application version",
            field: .applicationVersion,
            value: \.applicationVersionText
          )
        }
        Section("Direction and priority") {
          HStack {
            setToggle("App → Viewer", value: "appToViewer", keyPath: \.directions)
            setToggle("Viewer → App", value: "viewerToApp", keyPath: \.directions)
          }
          HStack {
            setToggle("Low", value: "low", keyPath: \.priorities)
            setToggle("Normal", value: "normal", keyPath: \.priorities)
            setToggle("High", value: "high", keyPath: \.priorities)
          }
        }
        Section("Viewer receive time") {
          optionalDate("From", keyPath: \.fromDate)
          optionalDate("Through", keyPath: \.throughDate)
        }
        Section("JSON") {
          Picker("JSON condition", selection: valueBinding(\.jsonMode) { $0.jsonMode = $1 }) {
            ForEach(ViewerExplorerJSONFilterMode.allCases, id: \.self) {
              Text(jsonModeTitle($0)).tag($0)
            }
          }
          if explorer.filterDraft.jsonMode != .none {
            boundedFilterInput("JSON path", field: .jsonPath, value: \.jsonPathText)
          }
          if explorer.filterDraft.jsonMode == .equals {
            Picker(
              "Value type",
              selection: valueBinding(\.jsonScalarKind) { $0.jsonScalarKind = $1 }
            ) {
              ForEach(ViewerExplorerJSONScalarKind.allCases, id: \.self) {
                Text($0.rawValue.capitalized).tag($0)
              }
            }
          }
          if explorer.filterDraft.jsonMode == .equals
            && explorer.filterDraft.jsonScalarKind != .null
            || explorer.filterDraft.jsonMode == .stringContains
          {
            boundedFilterInput(
              "Comparison value",
              field: .jsonComparison,
              value: \.jsonComparisonText
            )
          }
        }
        Section("Diagnostics") {
          Toggle(
            "Has gap",
            isOn: valueBinding(\.requiresGap) { $0.requiresGap = $1 }
          )
          Toggle(
            "Has drop",
            isOn: valueBinding(\.requiresDrop) { $0.requiresDrop = $1 }
          )
          Toggle(
            "Has terminal disposition",
            isOn: valueBinding(\.requiresTerminalDisposition) {
              $0.requiresTerminalDisposition = $1
            }
          )
        }
      }
      if let message = explorer.filterValidationMessage {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Close") { isPresented = false }
        Button("Apply") {
          explorer.applyFilter()
          if explorer.filterValidationMessage == nil { isPresented = false }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: [.command])
      }
    }
    .padding(22)
    .focusSection()
  }

  private func boundedFilterInput(
    _ label: String,
    field: ViewerExplorerFilterTextField,
    value keyPath: KeyPath<ViewerExplorerFilterDraft, String>
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      ViewerBoundedTextInput(
        text: explorer.filterDraft[keyPath: keyPath],
        style: .singleLine,
        accessibilityLabel: label,
        accessibilityHelp: "Standard editing is bounded before this filter value is stored.",
        onEdit: { range, replacement in
          explorer.replaceFilterCharacters(field, range: range, replacement: replacement)
        }
      )
      .frame(height: 28)
    }
  }

  private func valueBinding<Value>(
    _ keyPath: KeyPath<ViewerExplorerFilterDraft, Value>,
    _ update: @escaping (inout ViewerExplorerFilterDraft, Value) -> Void
  ) -> Binding<Value> {
    Binding(
      get: { explorer.filterDraft[keyPath: keyPath] },
      set: { value in explorer.updateFilterDraft { update(&$0, value) } }
    )
  }

  private func setToggle(
    _ title: String,
    value: String,
    keyPath: WritableKeyPath<ViewerExplorerFilterDraft, Set<String>>
  ) -> some View {
    Toggle(
      title,
      isOn: Binding(
        get: { explorer.filterDraft[keyPath: keyPath].contains(value) },
        set: { selected in
          explorer.updateFilterDraft {
            if selected {
              $0[keyPath: keyPath].insert(value)
            } else {
              $0[keyPath: keyPath].remove(value)
            }
          }
        }
      )
    )
  }

  private func optionalDate(
    _ title: String,
    keyPath: WritableKeyPath<ViewerExplorerFilterDraft, Date?>
  ) -> some View {
    HStack {
      Toggle(
        title,
        isOn: Binding(
          get: { explorer.filterDraft[keyPath: keyPath] != nil },
          set: { enabled in
            explorer.updateFilterDraft {
              $0[keyPath: keyPath] = enabled ? ($0[keyPath: keyPath] ?? Date()) : nil
            }
          }
        )
      )
      if explorer.filterDraft[keyPath: keyPath] != nil {
        DatePicker(
          title,
          selection: Binding(
            get: { explorer.filterDraft[keyPath: keyPath] ?? Date() },
            set: { date in explorer.updateFilterDraft { $0[keyPath: keyPath] = date } }
          ),
          displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
      }
    }
  }

  private func jsonModeTitle(_ mode: ViewerExplorerJSONFilterMode) -> String {
    switch mode {
    case .none: return "None"
    case .exists: return "Path exists"
    case .equals: return "Value equals"
    case .stringContains: return "String contains"
    }
  }
}

private struct ViewerExplorerEmptyState: View {
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

private enum ViewerExplorerFormatting {
  static func date(_ milliseconds: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
      .formatted(date: .abbreviated, time: .standard)
  }

  static func time(_ milliseconds: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
      .formatted(date: .omitted, time: .standard)
  }
}

extension ViewerStoreExplorerFailure {
  var operatorMessage: String {
    switch self {
    case .storeReplaced: return "Storage changed. The explorer will load a fresh snapshot."
    case .cancelled: return "The operation was cancelled."
    case .unavailable: return "Recorded data is currently unavailable. Live data may still appear."
    case .invalidRequest: return "The requested bounded view is no longer valid."
    case .busy: return "Another history operation is still finishing. Try again shortly."
    case .refineQuery: return "Refine the filters to stay within bounded query work."
    case .catalogChanged: return "The catalog changed. Reloading from a fresh snapshot is required."
    }
  }
}
