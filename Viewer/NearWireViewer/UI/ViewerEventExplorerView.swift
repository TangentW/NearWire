import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ViewerTimelinePresentationSignature: Equatable {
  let rows: [ViewerExplorerTimelinePresentationRow]
  let selectedEventID: ViewerExplorerEventIdentity?
  let traversalState: ViewerExplorerTraversalState
  let isPaused: Bool
  let autoFollow: Bool
  let searchText: String
  let searchMode: ViewerExplorerSearchMode
  let activeFilterCount: Int
  let filterValidationMessage: String?
  let liveEvaluationGuidance: String?
  let pageFailure: ViewerStoreExplorerFailure?
  let workspaceOperationState: ViewerWorkspaceOperationState
  let gapRows: [ViewerGapRow]
  let liveGapLane: ViewerExplorerLiveGapLane?
  let gapPageFailure: ViewerStoreExplorerFailure?
  let hasOlderEvents: Bool
  let hasNewerEvents: Bool
  let hasOlderGaps: Bool
  let hasNewerGaps: Bool

  @MainActor
  static func make(_ explorer: ViewerEventExplorerController) -> Self {
    Self(
      rows: explorer.timelineRows,
      selectedEventID: explorer.selectedEventID,
      traversalState: explorer.traversalState,
      isPaused: explorer.isPaused,
      autoFollow: explorer.autoFollow,
      searchText: explorer.filterDraft.searchText,
      searchMode: explorer.filterDraft.searchMode,
      activeFilterCount: explorer.activeFilterCount,
      filterValidationMessage: explorer.filterValidationMessage,
      liveEvaluationGuidance: explorer.liveEvaluationGuidance,
      pageFailure: explorer.timelinePageFailure,
      workspaceOperationState: explorer.workspaceOperationState,
      gapRows: explorer.gapRows,
      liveGapLane: explorer.liveGapLane,
      gapPageFailure: explorer.gapPageFailure,
      hasOlderEvents: explorer.hasOlderEvents,
      hasNewerEvents: explorer.hasNewerEvents,
      hasOlderGaps: explorer.hasOlderGaps,
      hasNewerGaps: explorer.hasNewerGaps
    )
  }
}

struct ViewerFilterPresentationSignature: Equatable {
  let eventTypeText: String
  let applicationIdentifierText: String
  let applicationVersionText: String
  let eventTypeMode: ViewerExplorerEventTypeMode
  let directions: Set<String>
  let priorities: Set<String>
  let fromDate: Date?
  let throughDate: Date?
  let jsonMode: ViewerExplorerJSONFilterMode
  let jsonScalarKind: ViewerExplorerJSONScalarKind
  let jsonPathText: String
  let jsonComparisonText: String
  let requiresGap: Bool
  let requiresDrop: Bool
  let requiresTerminalDisposition: Bool
  let validationMessage: String?

  @MainActor
  static func make(_ explorer: ViewerEventExplorerController) -> Self {
    let draft = explorer.filterDraft
    return Self(
      eventTypeText: draft.eventTypeText,
      applicationIdentifierText: draft.applicationIdentifierText,
      applicationVersionText: draft.applicationVersionText,
      eventTypeMode: draft.eventTypeMode,
      directions: draft.directions,
      priorities: draft.priorities,
      fromDate: draft.fromDate,
      throughDate: draft.throughDate,
      jsonMode: draft.jsonMode,
      jsonScalarKind: draft.jsonScalarKind,
      jsonPathText: draft.jsonPathText,
      jsonComparisonText: draft.jsonComparisonText,
      requiresGap: draft.requiresGap,
      requiresDrop: draft.requiresDrop,
      requiresTerminalDisposition: draft.requiresTerminalDisposition,
      validationMessage: explorer.filterValidationMessage
    )
  }
}

@MainActor
final class ViewerFilterPresentationObserver: ObservableObject {
  @Published private(set) var value: ViewerFilterPresentationSignature
  @Published private(set) var revision: UInt64 = 0
  private weak var explorer: ViewerEventExplorerController?
  private var cancellable: AnyCancellable?
  private var refreshScheduled = false

  init(explorer: ViewerEventExplorerController) {
    self.explorer = explorer
    value = .make(explorer)
    cancellable = explorer.$revision.dropFirst().sink { [weak self] _ in
      self?.scheduleRefresh()
    }
  }

  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.refreshScheduled = false
      guard let explorer = self.explorer else { return }
      let next = ViewerFilterPresentationSignature.make(explorer)
      guard next != self.value else { return }
      self.value = next
      self.revision &+= 1
    }
  }
}

@MainActor
final class ViewerTimelinePresentationObserver: ObservableObject {
  @Published private(set) var revision: UInt64 = 0
  @Published private(set) var value: ViewerTimelinePresentationSignature
  private weak var explorer: ViewerEventExplorerController?
  private var cancellable: AnyCancellable?
  private var refreshScheduled = false

  init(explorer: ViewerEventExplorerController) {
    self.explorer = explorer
    value = .make(explorer)
    cancellable = explorer.$revision.dropFirst().sink { [weak self] _ in
      self?.scheduleRefresh()
    }
  }

  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.refreshScheduled = false
      guard let explorer = self.explorer else { return }
      let next = ViewerTimelinePresentationSignature.make(explorer)
      guard next != self.value else { return }
      self.value = next
      self.revision &+= 1
    }
  }
}

struct ViewerExplorerTimelineView: View {
  @Environment(\.locale) private var locale
  let explorer: ViewerEventExplorerController
  @StateObject private var presentationObserver: ViewerTimelinePresentationObserver
  @State private var showsFilters = false
  @State private var showsGaps = false
  @State private var showsClearConfirmation = false

  init(explorer: ViewerEventExplorerController) {
    self.explorer = explorer
    _presentationObserver = StateObject(
      wrappedValue: ViewerTimelinePresentationObserver(explorer: explorer)
    )
  }

  var body: some View {
    let _ = presentationObserver.revision
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
        .frame(minWidth: 620, minHeight: 660)
    }
    .alert("Clear Current Session Events?", isPresented: $showsClearConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Clear Events", role: .destructive) { explorer.clearCurrentSession() }
    } message: {
      Text(
        "This removes recorded Events, Event details, diagnostics, and Performance data from the current Session. Connected Devices stay connected and new Events continue to arrive."
      )
    }
  }

  private var toolbar: some View {
    VStack(spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack {
          Label("Event Timeline", systemImage: "list.bullet.rectangle").font(.headline)
          Spacer()
          timelineActionButtons
        }
        HStack {
          Label("Event Timeline", systemImage: "list.bullet.rectangle").font(.headline)
          Spacer()
          Menu {
            timelineMenuActions
          } label: {
            Label("Timeline Actions", systemImage: "ellipsis.circle")
          }
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          searchEditor
          searchModePicker
          Button("Apply") { explorer.applyFilter() }
          filtersButton
        }
        VStack(spacing: 8) {
          searchEditor
          HStack(spacing: 8) {
            searchModePicker
            Spacer(minLength: 0)
            Button("Apply") { explorer.applyFilter() }
            filtersButton
          }
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .focusSection()
    .background(ViewerWorkspaceLayoutProbe(kind: .timelineToolbar))
  }

  private var timelineActionButtons: some View {
    Group {
      Button(role: .destructive) {
        showsClearConfirmation = true
      } label: {
        Label("Clear", systemImage: "trash")
      }
      .disabled(!explorer.canManageSelectedRecording || workspaceOperationIsRunning)
      .accessibilityLabel("Clear current Session Events")
      .accessibilityHint("Permanently removes recorded Events from the current Session.")
      .help("Clear recorded Events from the current Session")
      Button(presentation.isPaused ? "Resume" : "Pause") { explorer.pauseOrResume() }
        .accessibilityHint("Freezes or resumes timeline presentation only.")
      Button("Jump to Latest") { explorer.jumpToLatest() }
        .disabled(presentation.autoFollow && !presentation.isPaused)
    }
  }

  @ViewBuilder
  private var timelineMenuActions: some View {
    Button(role: .destructive) {
      showsClearConfirmation = true
    } label: {
      Label("Clear Events", systemImage: "trash")
    }
    .disabled(!explorer.canManageSelectedRecording || workspaceOperationIsRunning)
    Button(presentation.isPaused ? "Resume Timeline" : "Pause Timeline") {
      explorer.pauseOrResume()
    }
    Button("Jump to Latest") { explorer.jumpToLatest() }
      .disabled(presentation.autoFollow && !presentation.isPaused)
  }

  private var searchEditor: some View {
    ViewerBoundedTextInput(
      text: presentation.searchText,
      style: .singleLine,
      accessibilityLabel: ViewerLocalization.string("Search Event content", locale: locale),
      accessibilityHelp: ViewerLocalization.string(
        "Standard editing is bounded before this filter value is stored.",
        locale: locale
      ),
      onEdit: { range, replacement in
        explorer.replaceFilterCharacters(.search, range: range, replacement: replacement)
      },
      onSubmit: { explorer.applyFilter() }
    )
    .frame(minWidth: 120, maxWidth: .infinity)
    .frame(height: 28)
  }

  private var searchModePicker: some View {
    Picker(
      "Search mode",
      selection: Binding(
        get: { presentation.searchMode },
        set: { value in explorer.updateFilterDraft { $0.searchMode = value } }
      )
    ) {
      Text("Literal").tag(ViewerExplorerSearchMode.literal)
      Text("Full Text").tag(ViewerExplorerSearchMode.fullText)
    }
    .labelsHidden()
    .frame(width: 110)
  }

  private var filtersButton: some View {
    Button {
      showsFilters = true
    } label: {
      Label(
        presentation.activeFilterCount == 0
          ? "Filters" : "Filters \(presentation.activeFilterCount)",
        systemImage: "line.3.horizontal.decrease.circle"
      )
    }
  }

  @ViewBuilder
  private var guidance: some View {
    if let message = presentation.filterValidationMessage {
      banner(message, systemImage: "exclamationmark.triangle", color: .orange)
    }
    if let message = presentation.liveEvaluationGuidance {
      banner(message, systemImage: "info.circle", color: .secondary)
    }
    if let failure = presentation.pageFailure {
      banner(failure.operatorMessage, systemImage: "exclamationmark.triangle", color: .orange)
    }
  }

  @ViewBuilder
  private var content: some View {
    let rows = presentation.rows
    if rows.isEmpty {
      switch presentation.traversalState {
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
          description: "Adjust the Device selection or filters."
        )
      }
    } else {
      List(selection: selectedEventBinding) {
        ForEach(rows) { row in
          ViewerExplorerTimelineRowView(row: row)
            .tag(row.id)
            .onAppear {
              if row.id == rows.first?.id, presentation.hasOlderEvents {
                explorer.loadOlderEvents()
              }
              if row.id == rows.last?.id, presentation.hasNewerEvents {
                explorer.loadNewerEvents()
              }
            }
        }
      }
      .accessibilityLabel("Event timeline")
      .transaction { transaction in transaction.animation = nil }
    }
  }

  private var workspaceOperationIsRunning: Bool {
    if case .clearing = presentation.workspaceOperationState { return true }
    if case .selectingImport = presentation.workspaceOperationState { return true }
    if case .importing = presentation.workspaceOperationState { return true }
    return false
  }

  private var selectedEventBinding: Binding<ViewerExplorerEventIdentity?> {
    Binding(
      get: { explorer.selectedEventID },
      set: { identity in
        explorer.deferEventSelection(identity)
      }
    )
  }

  private var hasDiagnostics: Bool {
    !presentation.gapRows.isEmpty || presentation.liveGapLane?.hasDiagnostic == true
      || presentation.gapPageFailure != nil
  }

  private var diagnosticLane: some View {
    DisclosureGroup(isExpanded: $showsGaps) {
      VStack(alignment: .leading, spacing: 8) {
        if let gaps = presentation.liveGapLane?.gaps {
          Text(
            "Live: ingress \(gaps.ingressOverflowCount), window \(gaps.windowOverflowCount), conflicts \(gaps.residentConflictCount), diagnostic loss \(gaps.diagnosticLossCount), storage outages \(gaps.storeUnavailableCount), recoveries \(gaps.storeRecoveryCount)"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(gaps.storeUnavailable ? .orange : .secondary)
        }
        if let failure = presentation.gapPageFailure {
          Text(LocalizedStringKey(failure.operatorMessage))
            .font(.caption)
            .foregroundStyle(.orange)
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(presentation.gapRows, id: \.rowID) { gap in
              VStack(alignment: .leading, spacing: 2) {
                Text("\(gap.namespace) · \(gap.reason)").font(.caption).fontWeight(.medium)
                Text(
                  "\(gap.count) records · \(ViewerLocalization.string(gap.directions, locale: locale)) · \(ViewerExplorerFormatting.date(gap.firstViewerWallMilliseconds, locale: locale)) – \(ViewerExplorerFormatting.date(gap.lastViewerWallMilliseconds, locale: locale))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
              }
              .onAppear {
                if gap.rowID == presentation.gapRows.first?.rowID, presentation.hasOlderGaps {
                  explorer.loadOlderGaps()
                }
                if gap.rowID == presentation.gapRows.last?.rowID, presentation.hasNewerGaps {
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
    Label(LocalizedStringKey(message), systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.08))
  }

  private var presentation: ViewerTimelinePresentationSignature {
    presentationObserver.value
  }

}

private struct ViewerExplorerTimelineRowView: View {
  @Environment(\.locale) private var locale
  let row: ViewerExplorerTimelinePresentationRow

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(row.eventType).font(.headline).lineLimit(1)
        Spacer()
        Text(ViewerExplorerFormatting.time(row.viewerWallMilliseconds, locale: locale))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 7) {
        Label(row.deviceAlias, systemImage: "iphone")
        Text(LocalizedStringKey(row.direction))
        Text(LocalizedStringKey(row.priority.capitalized))
        Text(ViewerExplorerFormatting.bytes(row.contentByteCount, locale: locale))
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
    let recording = ViewerLocalization.string(
      row.isTransient ? "not recorded" : "recorded",
      locale: locale
    )
    var states = [recording]
    if let disposition = row.disposition {
      states.append(
        ViewerLocalization.format(
          "disposition %@",
          locale: locale,
          arguments: [disposition]
        )
      )
    }
    if row.hasGap { states.append(ViewerLocalization.string("gap", locale: locale)) }
    if row.hasDrop { states.append(ViewerLocalization.string("drop", locale: locale)) }
    if row.hasPresentationConflict {
      states.append(ViewerLocalization.string("presentation conflict", locale: locale))
    }
    if row.sessionEnded {
      states.append(ViewerLocalization.string("session ended", locale: locale))
    }
    return ViewerLocalization.format(
      "%@, %@, %@, %@, %@, %@",
      locale: locale,
      arguments: [
        row.eventType,
        row.deviceAlias,
        ViewerLocalization.string(row.direction, locale: locale),
        ViewerLocalization.string(row.priority.capitalized, locale: locale),
        states.joined(separator: ", "),
        ViewerExplorerFormatting.date(row.viewerWallMilliseconds, locale: locale),
      ]
    )
  }

  private func badge(_ text: String, color: Color) -> some View {
    Text(LocalizedStringKey(text))
      .font(.caption2)
      .foregroundStyle(color)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(color.opacity(0.1), in: Capsule())
  }
}

struct ViewerExportSheet: View {
  @ObservedObject var explorer: ViewerEventExplorerController
  @Binding var isPresented: Bool
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Export JSON").font(.title2).fontWeight(.semibold)
        Spacer()
        if case .disclosure(let mode, _, _) = explorer.exportState {
          Text(LocalizedStringKey(mode.title)).font(.caption).foregroundStyle(.secondary)
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
        Button(LocalizedStringKey(closeTitle)) { close() }
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
        description: "Choose Complete Session or Current Filtered Result."
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
    Label(LocalizedStringKey(text), systemImage: "circle.fill")
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
      panel.title = ViewerLocalization.string("Export NearWire JSON", locale: locale)
      panel.message = ViewerLocalization.string(
        "Choose a destination for the unencrypted JSON export.",
        locale: locale
      )
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
    case .completeRecording: return "Complete Session"
    case .currentFilteredResult: return "Current Filtered Result"
    }
  }
}

private struct ViewerInspectorPresentationSignature: Equatable {
  let selectedEventID: ViewerExplorerEventIdentity?
  let state: ViewerExplorerInspectorState
  let metadata: ViewerInspectorEventMetadata?
  let contentByteCount: Int
  let rawChunkIndex: Int
  let rawChunk: ViewerRawJSONChunk?
  let treeState: ViewerJSONTreeState?
  let rendererPreparation: ViewerRendererPreparation?
  let causalityState: ViewerExplorerCausalityState

  @MainActor
  static func make(_ explorer: ViewerEventExplorerController) -> Self {
    Self(
      selectedEventID: explorer.selectedEventID,
      state: explorer.inspectorState,
      metadata: explorer.inspectorMetadata,
      contentByteCount: explorer.inspectorContentByteCount,
      rawChunkIndex: explorer.rawChunkIndex,
      rawChunk: explorer.rawChunk,
      treeState: explorer.inspectorTreeState,
      rendererPreparation: explorer.rendererPreparation,
      causalityState: explorer.causalityState
    )
  }
}

@MainActor
final class ViewerInspectorPresentationObserver: ObservableObject {
  @Published private(set) var revision: UInt64 = 0
  private weak var explorer: ViewerEventExplorerController?
  private var signature: ViewerInspectorPresentationSignature
  private var cancellable: AnyCancellable?
  private var refreshScheduled = false

  init(explorer: ViewerEventExplorerController) {
    self.explorer = explorer
    signature = .make(explorer)
    cancellable = explorer.$revision.dropFirst().sink { [weak self] _ in
      self?.scheduleRefresh()
    }
  }

  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.refreshScheduled = false
      guard let explorer = self.explorer else { return }
      let next = ViewerInspectorPresentationSignature.make(explorer)
      guard next != self.signature else { return }
      self.signature = next
      self.revision &+= 1
    }
  }
}

enum ViewerExplorerInspectorTab: String, CaseIterable {
  case metadata = "Metadata"
  case raw = "Raw"
  case tree = "Tree"
  case pretty = "Pretty"
  case renderer = "Renderer"
  case causality = "Causality"
}

struct ViewerExplorerInspectorView: View {
  @Environment(\.locale) private var locale
  let explorer: ViewerEventExplorerController
  @StateObject private var presentationObserver: ViewerInspectorPresentationObserver
  @Binding private var tab: ViewerExplorerInspectorTab

  init(
    explorer: ViewerEventExplorerController,
    tab: Binding<ViewerExplorerInspectorTab>
  ) {
    self.explorer = explorer
    _tab = tab
    _presentationObserver = StateObject(
      wrappedValue: ViewerInspectorPresentationObserver(explorer: explorer)
    )
  }

  var body: some View {
    let _ = presentationObserver.revision
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
        ViewThatFits(in: .horizontal) {
          Picker("Inspector view", selection: $tab) {
            inspectorTabOptions
          }
          .pickerStyle(.segmented)
          Picker("Inspector view", selection: $tab) {
            inspectorTabOptions
          }
          .pickerStyle(.menu)
        }
        .padding(10)
        Divider()
        tabContent
      }
    }
  }

  @ViewBuilder
  private var inspectorTabOptions: some View {
    ForEach(ViewerExplorerInspectorTab.allCases, id: \.self) {
      Text(LocalizedStringKey($0.rawValue)).tag($0)
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
          metadataRow("Direction", ViewerLocalization.string(value.direction, locale: locale))
          metadataRow("Sequence", String(value.wireSequence))
          metadataRow(
            "Priority",
            ViewerLocalization.string(value.priority.capitalized, locale: locale)
          )
          metadataRow(
            "Created",
            ViewerExplorerFormatting.date(value.createdWallMilliseconds, locale: locale)
          )
          metadataRow(
            "Viewer received",
            ViewerExplorerFormatting.date(value.viewerWallMilliseconds, locale: locale)
          )
          metadataRow("TTL", "\(value.ttlMilliseconds) ms")
          metadataRow("Schema", String(value.schemaVersion))
          metadataRow(
            "Disposition",
            value.disposition ?? ViewerLocalization.string("None", locale: locale)
          )
          metadataRow(
            "Correlation",
            value.correlationEventUUID ?? ViewerLocalization.string("None", locale: locale)
          )
          metadataRow(
            "Reply to",
            value.replyToEventUUID ?? ViewerLocalization.string("None", locale: locale)
          )
          metadataRow(
            "Content",
            ViewerExplorerFormatting.bytes(
              Int64(explorer.inspectorContentByteCount),
              locale: locale
            )
          )
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
          Label(LocalizedStringKey(guidance), systemImage: "info.circle")
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
          metadataRow(
            "Direction",
            ViewerLocalization.string(timeline.direction, locale: locale)
          )
          metadataRow(
            "Priority",
            ViewerLocalization.string(timeline.priority.capitalized, locale: locale)
          )
          metadataRow(
            "Received",
            ViewerExplorerFormatting.date(timeline.viewerWallMilliseconds, locale: locale)
          )
          metadataRow(
            "Disposition",
            ViewerLocalization.string(timeline.disposition, locale: locale)
          )
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
              Text(
                "\(ViewerLocalization.string(node.direction, locale: locale)) · sequence \(node.wireSequence) · \(node.eventUUID)"
              )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        Section("Edges") {
          ForEach(Array(graph.edges.enumerated()), id: \.offset) { _, edge in
            VStack(alignment: .leading, spacing: 3) {
              Text(LocalizedStringKey(edge.kind == .replyTo ? "Reply to" : "Correlation"))
                .fontWeight(.medium)
              Text(edge.referencedEventUUID).font(.caption)
              Text(
                ViewerLocalization.format(
                  "%lld candidate(s)%@%@",
                  locale: locale,
                  arguments: [
                    edge.candidateRowIDs.count,
                    edge.hasMore
                      ? ViewerLocalization.string(", more omitted", locale: locale) : "",
                    edge.cyclicCandidateRowIDs.isEmpty
                      ? "" : ViewerLocalization.string(", cycle observed", locale: locale),
                  ]
                )
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
      Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
      Text(value).lineLimit(4)
    }
  }

  private func diagnosticSummary(_ value: ViewerInspectorEventMetadata) -> String {
    var values: [String] = []
    if value.hasGap { values.append(ViewerLocalization.string("gap", locale: locale)) }
    if value.hasDrop { values.append(ViewerLocalization.string("drop", locale: locale)) }
    if value.hasPresentationConflict {
      values.append(ViewerLocalization.string("presentation conflict", locale: locale))
    }
    if value.sessionEnded {
      values.append(ViewerLocalization.string("session ended", locale: locale))
    }
    return values.isEmpty
      ? ViewerLocalization.string("None", locale: locale)
      : values.joined(separator: ", ")
  }
}

struct ViewerExplorerFilterSheet: View {
  @Environment(\.locale) private var locale
  let explorer: ViewerEventExplorerController
  @StateObject private var presentationObserver: ViewerFilterPresentationObserver
  @Binding var isPresented: Bool

  init(explorer: ViewerEventExplorerController, isPresented: Binding<Bool>) {
    self.explorer = explorer
    _isPresented = isPresented
    _presentationObserver = StateObject(
      wrappedValue: ViewerFilterPresentationObserver(explorer: explorer)
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Event Filters").font(.title2).fontWeight(.semibold)
        Spacer()
        Button("Clear") { explorer.clearFilter() }
          .accessibilityIdentifier("nearwire.filters.clear")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          filterSection("Event", identifier: "event") {
            HStack(alignment: .bottom, spacing: 12) {
              boundedFilterInput("Event type", field: .eventType, value: \.eventTypeText)
                .frame(maxWidth: .infinity)
              Picker(
                "Type match",
                selection: valueBinding(\.eventTypeMode) { $0.eventTypeMode = $1 }
              ) {
                Text("Exact").tag(ViewerExplorerEventTypeMode.exact)
                Text("Prefix").tag(ViewerExplorerEventTypeMode.prefix)
              }
              .frame(width: 150)
              .accessibilityIdentifier("nearwire.filters.type-match")
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

          filterSection("Direction and priority", identifier: "direction-priority") {
            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 24) {
                setToggle(
                  "App → Viewer",
                  value: "appToViewer",
                  keyPath: \.directions,
                  draftKeyPath: \.directions
                )
                setToggle(
                  "Viewer → App",
                  value: "viewerToApp",
                  keyPath: \.directions,
                  draftKeyPath: \.directions
                )
              }
              HStack(spacing: 24) {
                setToggle("Low", value: "low", keyPath: \.priorities, draftKeyPath: \.priorities)
                setToggle(
                  "Normal",
                  value: "normal",
                  keyPath: \.priorities,
                  draftKeyPath: \.priorities
                )
                setToggle(
                  "High",
                  value: "high",
                  keyPath: \.priorities,
                  draftKeyPath: \.priorities
                )
              }
            }
          }

          filterSection("Viewer receive time", identifier: "viewer-time") {
            VStack(alignment: .leading, spacing: 10) {
              optionalDate("From", keyPath: \.fromDate, draftKeyPath: \.fromDate)
              optionalDate("Through", keyPath: \.throughDate, draftKeyPath: \.throughDate)
            }
          }

          filterSection("JSON", identifier: "json") {
            VStack(alignment: .leading, spacing: 10) {
              Picker(
                "JSON condition",
                selection: valueBinding(\.jsonMode) { $0.jsonMode = $1 }
              ) {
                ForEach(ViewerExplorerJSONFilterMode.allCases, id: \.self) {
                  Text(LocalizedStringKey(jsonModeTitle($0))).tag($0)
                }
              }
              .frame(maxWidth: 360, alignment: .leading)
              .accessibilityIdentifier("nearwire.filters.json-mode")
              if presentation.jsonMode != .none {
                boundedFilterInput("JSON path", field: .jsonPath, value: \.jsonPathText)
              }
              if presentation.jsonMode == .equals {
                Picker(
                  "Value type",
                  selection: valueBinding(\.jsonScalarKind) { $0.jsonScalarKind = $1 }
                ) {
                  ForEach(ViewerExplorerJSONScalarKind.allCases, id: \.self) {
                    Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0)
                  }
                }
                .frame(maxWidth: 360, alignment: .leading)
              }
              if presentation.jsonMode == .equals
                && presentation.jsonScalarKind != .null
                || presentation.jsonMode == .stringContains
              {
                boundedFilterInput(
                  "Comparison value",
                  field: .jsonComparison,
                  value: \.jsonComparisonText
                )
              }
            }
          }

          filterSection("Diagnostics", identifier: "diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
              Toggle(
                "Has gap",
                isOn: valueBinding(\.requiresGap) { $0.requiresGap = $1 }
              )
              .accessibilityIdentifier("nearwire.filters.diagnostic.gap")
              Toggle(
                "Has drop",
                isOn: valueBinding(\.requiresDrop) { $0.requiresDrop = $1 }
              )
              .accessibilityIdentifier("nearwire.filters.diagnostic.drop")
              Toggle(
                "Has terminal disposition",
                isOn: valueBinding(\.requiresTerminalDisposition) {
                  $0.requiresTerminalDisposition = $1
                }
              )
              .accessibilityIdentifier("nearwire.filters.diagnostic.terminal")
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
      }
      .frame(maxHeight: .infinity)
      .accessibilityIdentifier("nearwire.filters.scroll")
      if let message = presentation.validationMessage {
        Label(LocalizedStringKey(message), systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Close") { isPresented = false }
          .accessibilityIdentifier("nearwire.filters.close")
        Button("Apply") {
          explorer.applyFilter()
          if presentation.validationMessage == nil { isPresented = false }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityIdentifier("nearwire.filters.apply")
      }
    }
    .padding(22)
    .focusSection()
    .accessibilityIdentifier("nearwire.filters.sheet")
  }

  private func boundedFilterInput(
    _ label: String,
    field: ViewerExplorerFilterTextField,
    value keyPath: KeyPath<ViewerFilterPresentationSignature, String>
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(LocalizedStringKey(label)).font(.caption).foregroundStyle(.secondary)
      ViewerBoundedTextInput(
        text: presentation[keyPath: keyPath],
        style: .singleLine,
        accessibilityLabel: ViewerLocalization.string(label, locale: locale),
        accessibilityHelp: ViewerLocalization.string(
          "Standard editing is bounded before this filter value is stored.",
          locale: locale
        ),
        onEdit: { range, replacement in
          explorer.replaceFilterCharacters(field, range: range, replacement: replacement)
        }
      )
      .frame(height: 28)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func filterSection<Content: View>(
    _ title: String,
    identifier: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    GroupBox {
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    } label: {
      Text(LocalizedStringKey(title)).font(.headline)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("nearwire.filters.section.\(identifier)")
  }

  private func valueBinding<Value>(
    _ keyPath: KeyPath<ViewerFilterPresentationSignature, Value>,
    _ update: @escaping (inout ViewerExplorerFilterDraft, Value) -> Void
  ) -> Binding<Value> {
    Binding(
      get: { presentation[keyPath: keyPath] },
      set: { value in explorer.updateFilterDraft { update(&$0, value) } }
    )
  }

  private func setToggle(
    _ title: String,
    value: String,
    keyPath: KeyPath<ViewerFilterPresentationSignature, Set<String>>,
    draftKeyPath: WritableKeyPath<ViewerExplorerFilterDraft, Set<String>>
  ) -> some View {
    return Toggle(
      LocalizedStringKey(title),
      isOn: Binding(
        get: { presentation[keyPath: keyPath].contains(value) },
        set: { selected in
          explorer.updateFilterDraft {
            if selected {
              $0[keyPath: draftKeyPath].insert(value)
            } else {
              $0[keyPath: draftKeyPath].remove(value)
            }
          }
        }
      )
    )
    .accessibilityIdentifier("nearwire.filters.option.\(value)")
  }

  private func optionalDate(
    _ title: String,
    keyPath: KeyPath<ViewerFilterPresentationSignature, Date?>,
    draftKeyPath: WritableKeyPath<ViewerExplorerFilterDraft, Date?>
  ) -> some View {
    return HStack {
      Toggle(
        title,
        isOn: Binding(
          get: { presentation[keyPath: keyPath] != nil },
          set: { enabled in
            explorer.updateFilterDraft {
              $0[keyPath: draftKeyPath] =
                enabled ? ($0[keyPath: draftKeyPath] ?? Date()) : nil
            }
          }
        )
      )
      .accessibilityIdentifier("nearwire.filters.time.\(title.lowercased())")
      if presentation[keyPath: keyPath] != nil {
        DatePicker(
          title,
          selection: Binding(
            get: { presentation[keyPath: keyPath] ?? Date() },
            set: { date in explorer.updateFilterDraft { $0[keyPath: draftKeyPath] = date } }
          ),
          displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
      }
    }
  }

  private var presentation: ViewerFilterPresentationSignature {
    presentationObserver.value
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
      Text(LocalizedStringKey(title)).font(.headline)
      Text(LocalizedStringKey(description))
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private enum ViewerExplorerFormatting {
  static func date(_ milliseconds: Int64, locale: Locale) -> String {
    Date.FormatStyle(date: .abbreviated, time: .standard)
      .locale(locale)
      .format(Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000))
  }

  static func time(_ milliseconds: Int64, locale: Locale) -> String {
    Date.FormatStyle(date: .omitted, time: .standard)
      .locale(locale)
      .format(Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000))
  }

  static func bytes(_ count: Int64, locale: Locale) -> String {
    ByteCountFormatStyle(style: .binary, locale: locale).format(count)
  }
}

extension ViewerStoreExplorerFailure {
  var operatorMessage: String {
    switch self {
    case .storeReplaced: return "Storage changed. The explorer will load a fresh snapshot."
    case .cancelled: return "The operation was cancelled."
    case .unavailable: return "Recorded data is currently unavailable. Live data may still appear."
    case .invalidRequest: return "The requested bounded view is no longer valid."
    case .busy: return "Another Session operation is still finishing. Try again shortly."
    case .refineQuery: return "Refine the filters to stay within bounded query work."
    case .exportTooLarge:
      return "The complete Session is too large to export. Clear unneeded Events and try again."
    case .catalogChanged: return "The catalog changed. Reloading from a fresh snapshot is required."
    }
  }
}

extension ViewerWorkspaceMutationFailure {
  var operatorMessage: String {
    switch self {
    case .unavailable: return "The current Session is unavailable."
    case .busy: return "Another Session operation is still finishing."
    case .invalidFile: return "The selected JSON file is not a valid NearWire Session export."
    case .unsupportedFile: return "The selected JSON file uses an unsupported export format."
    case .capacityExceeded:
      return "The imported Session is too large for the current Viewer storage limit. Import a smaller Session."
    case .cancelled: return "The Session operation was cancelled."
    }
  }
}
