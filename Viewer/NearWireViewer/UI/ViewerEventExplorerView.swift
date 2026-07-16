import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ViewerTimelinePresentationSignature: Equatable {
  let rows: [ViewerExplorerTimelinePresentationRow]
  let selectedEventID: ViewerExplorerEventIdentity?
  let emptyTraversalState: ViewerExplorerTraversalState?
  let isPaused: Bool
  let autoFollow: Bool
  let searchText: String
  let searchMode: ViewerExplorerSearchMode
  let activeFilterCount: Int
  let filterValidationMessage: String?
  let liveEvaluationGuidance: String?
  let pageFailure: ViewerExplorerFailure?
  let workspaceOperationState: ViewerWorkspaceOperationState
  let liveGapLane: ViewerExplorerMemoryGapLane?
  let hasOlderEvents: Bool
  let hasNewerEvents: Bool

  @MainActor
  static func make(_ explorer: ViewerEventExplorerController) -> Self {
    Self(
      rows: explorer.timelineRows,
      selectedEventID: explorer.selectedEventID,
      emptyTraversalState: explorer.timelineRows.isEmpty ? explorer.traversalState : nil,
      isPaused: explorer.isPaused,
      autoFollow: explorer.autoFollow,
      searchText: explorer.filterDraft.searchText,
      searchMode: explorer.filterDraft.searchMode,
      activeFilterCount: explorer.activeFilterCount,
      filterValidationMessage: explorer.filterValidationMessage,
      liveEvaluationGuidance: explorer.liveEvaluationGuidance,
      pageFailure: explorer.timelinePageFailure,
      workspaceOperationState: explorer.workspaceOperationState,
      liveGapLane: explorer.liveGapLane,
      hasOlderEvents: explorer.hasOlderEvents,
      hasNewerEvents: explorer.hasNewerEvents
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
  @State private var isApplyingTailScroll = false
  @State private var tailFrame = CGRect.null
  @State private var timelineViewportSize = CGSize.zero
  @State private var tailViewport = ViewerTimelineTailViewportState()
  @State private var tailScrollGeneration: UInt64 = 0
  @State private var fallbackAppendState =
    ViewerTimelineFallbackAppendState<ViewerExplorerEventIdentity>()

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
        "This removes retained Events, Event details, diagnostics, and Performance data from the current Session. Connected Devices stay connected and new Events continue to arrive."
      )
    }
    .transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
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
      .disabled(!explorer.canClearCurrentSession || workspaceOperationIsRunning)
      .accessibilityLabel("Clear current Session Events")
      .accessibilityHint("Removes retained Events from the current memory Session.")
      .help("Clear retained Events from the current Session")
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
    .disabled(!explorer.canClearCurrentSession || workspaceOperationIsRunning)
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
      switch presentation.emptyTraversalState ?? .idle {
      case .loading:
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
      ScrollViewReader { proxy in
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
          Color.clear
            .frame(height: 1)
            .id(ViewerTimelineScrollAnchor.tail)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .onDisappear { reportFallbackTailVisibility(false) }
            .background {
              GeometryReader { geometry in
                Color.clear.preference(
                  key: ViewerTimelineTailFramePreferenceKey.self,
                  value: geometry.frame(in: .named(ViewerTimelineCoordinateSpace.name))
                )
              }
            }
        }
        .background {
          GeometryReader { geometry in
            Color.clear.preference(
              key: ViewerTimelineViewportSizePreferenceKey.self,
              value: geometry.size
            )
          }
        }
        .coordinateSpace(name: ViewerTimelineCoordinateSpace.name)
        .modifier(
          ViewerTimelineScrollGeometryModifier { previous, current in
            handleScrollGeometryChange(
              previous: previous,
              current: current,
              proxy: proxy
            )
          }
        )
        .onAppear {
          tailViewport.mount()
          mountFallbackAppendState(lastEventID: rows.last?.id)
          if presentation.autoFollow, !presentation.isPaused {
            scrollToTail(using: proxy)
          }
        }
        .onDisappear {
          tailViewport.unmount()
          unmountFallbackAppendState()
          tailScrollGeneration &+= 1
          isApplyingTailScroll = false
        }
        .onPreferenceChange(ViewerTimelineTailFramePreferenceKey.self) { frame in
          tailFrame = frame
          reportMeasuredTailVisibility()
        }
        .onPreferenceChange(ViewerTimelineViewportSizePreferenceKey.self) { size in
          timelineViewportSize = size
          reportMeasuredTailVisibility()
        }
        .onChange(of: rows.last?.id) { _ in
          if tailViewport.shouldFollowNewEvents, !presentation.isPaused {
            scrollToTail(using: proxy)
          } else {
            settleFallbackAppendState(lastEventID: rows.last?.id)
          }
        }
        .onChange(of: presentation.autoFollow) { isFollowing in
          if isFollowing, !presentation.isPaused {
            scrollToTail(using: proxy)
          }
        }
        .accessibilityLabel("Event timeline")
        .transaction { transaction in transaction.animation = nil }
      }
    }
  }

  private func scrollToTail(using proxy: ScrollViewProxy) {
    tailScrollGeneration &+= 1
    let generation = tailScrollGeneration
    isApplyingTailScroll = true
    Task { @MainActor in
      await Task.yield()
      guard generation == tailScrollGeneration else { return }
      guard tailViewport.isMounted else {
        isApplyingTailScroll = false
        return
      }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        proxy.scrollTo(ViewerTimelineScrollAnchor.tail, anchor: .bottom)
      }
      await Task.yield()
      guard generation == tailScrollGeneration else { return }
      isApplyingTailScroll = false
      reportTailVisibility(true)
      settleFallbackAppendState(lastEventID: presentation.rows.last?.id)
    }
  }

  private func handleScrollGeometryChange(
    previous: ViewerTimelineScrollGeometry,
    current: ViewerTimelineScrollGeometry,
    proxy: ScrollViewProxy
  ) {
    guard !isApplyingTailScroll,
      let token = tailViewport.observe(previous: previous, current: current)
    else { return }
    publishTailVisibility(token)
    if tailViewport.shouldFollowNewEvents, current.contentHeight > previous.contentHeight,
      !current.isAtBottom
    {
      scrollToTail(using: proxy)
    }
  }

  private func reportMeasuredTailVisibility() {
    if #available(macOS 15.0, *) { return }
    guard !isApplyingTailScroll else { return }
    let wasFollowing = tailViewport.shouldFollowNewEvents
    guard var token = tailViewport.observe(
        tailFrame: tailFrame,
        viewportSize: timelineViewportSize
      )
    else { return }
    token = preserveFallbackAppendFollowIfNeeded(
      wasFollowing: wasFollowing,
      reportedToken: token
    )
    publishTailVisibility(token)
  }

  private func reportFallbackTailVisibility(_ isVisible: Bool) {
    if #available(macOS 15.0, *) { return }
    guard !isApplyingTailScroll else { return }
    let wasFollowing = tailViewport.shouldFollowNewEvents
    guard var token = tailViewport.observe(isVisible: isVisible) else { return }
    token = preserveFallbackAppendFollowIfNeeded(
      wasFollowing: wasFollowing,
      reportedToken: token
    )
    publishTailVisibility(token)
  }

  private func reportTailVisibility(_ isVisible: Bool) {
    guard let token = tailViewport.observe(isVisible: isVisible) else { return }
    publishTailVisibility(token)
  }

  private func publishTailVisibility(_ token: UInt64) {
    Task { @MainActor in
      await Task.yield()
      guard tailViewport.accepts(token) else { return }
      explorer.updateTimelineTailFollowing(tailViewport.isTailVisible)
    }
  }

  private func preserveFallbackAppendFollowIfNeeded(
    wasFollowing: Bool,
    reportedToken: UInt64
  ) -> UInt64 {
    guard !tailViewport.shouldFollowNewEvents,
      fallbackAppendState.shouldPreserveFollow(
        wasFollowing: wasFollowing,
        currentLastEventID: presentation.rows.last?.id
      ),
      let restoredToken = tailViewport.observe(isVisible: true)
    else { return reportedToken }
    return restoredToken
  }

  private func mountFallbackAppendState(lastEventID: ViewerExplorerEventIdentity?) {
    if #available(macOS 15.0, *) { return }
    fallbackAppendState.mount(lastEventID: lastEventID)
  }

  private func settleFallbackAppendState(lastEventID: ViewerExplorerEventIdentity?) {
    if #available(macOS 15.0, *) { return }
    fallbackAppendState.settle(lastEventID: lastEventID)
  }

  private func unmountFallbackAppendState() {
    if #available(macOS 15.0, *) { return }
    fallbackAppendState.unmount()
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
    presentation.liveGapLane?.hasDiagnostic == true
  }

  private var diagnosticLane: some View {
    DisclosureGroup(isExpanded: $showsGaps) {
      VStack(alignment: .leading, spacing: 8) {
        if let gaps = presentation.liveGapLane?.gaps {
          Text(
            "Memory: ingress \(gaps.ingressOverflowCount), window \(gaps.windowOverflowCount), conflicts \(gaps.residentConflictCount), diagnostic loss \(gaps.diagnosticLossCount)"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
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

struct ViewerExplorerTimelineRowView: View {
  @Environment(\.locale) private var locale
  let row: ViewerExplorerTimelinePresentationRow

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ViewThatFits(in: .horizontal) {
        timelineHeader(compactStatuses: false)
        timelineHeader(compactStatuses: true)
      }
      Text(row.contentSummary)
        .font(.body)
        .lineLimit(3)
        .truncationMode(.tail)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilitySummary)
  }

  private var accessibilitySummary: String {
    var states: [String] = []
    if let disposition = visibleDisposition {
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
      "%@, %@, %@, %@",
      locale: locale,
      arguments: [
        row.eventType,
        states.joined(separator: ", "),
        ViewerExplorerFormatting.date(row.viewerWallMilliseconds, locale: locale),
        row.contentSummary,
      ]
    )
  }

  private var visibleDisposition: String? {
    ViewerExplorerTimelineDispositionPresentation.visibleDisposition(row.disposition)
  }

  private var visibleStatusCount: Int {
    (visibleDisposition == nil ? 0 : 1)
      + (row.hasGap ? 1 : 0)
      + (row.hasDrop ? 1 : 0)
      + (row.hasPresentationConflict ? 1 : 0)
      + (row.sessionEnded ? 1 : 0)
  }

  private var compactStatusColor: Color {
    if row.hasDrop || row.hasPresentationConflict { return .red }
    if row.hasGap { return .orange }
    return .secondary
  }

  private func timelineHeader(compactStatuses: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(row.eventType)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(minWidth: 60, alignment: .leading)
      if compactStatuses {
        if visibleStatusCount > 0 {
          badge("+\(visibleStatusCount)", color: compactStatusColor, localized: false)
        }
      } else {
        if let disposition = visibleDisposition { badge(disposition, color: .secondary) }
        if row.hasGap { badge("Gap", color: .orange) }
        if row.hasDrop { badge("Drop", color: .red) }
        if row.hasPresentationConflict { badge("Conflict", color: .red) }
        if row.sessionEnded { badge("Session ended", color: .secondary) }
      }
      Spacer(minLength: 8)
      Text(ViewerExplorerFormatting.time(row.viewerWallMilliseconds, locale: locale))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private func badge(_ text: String, color: Color, localized: Bool = true) -> some View {
    Group {
      if localized {
        Text(LocalizedStringKey(text))
      } else {
        Text(verbatim: text)
      }
    }
      .font(.caption2)
      .foregroundStyle(color)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(color.opacity(0.1), in: Capsule())
  }
}

enum ViewerExplorerTimelineDispositionPresentation {
  static func visibleDisposition(_ value: String?) -> String? {
    guard let value else { return nil }
    switch ViewerEventDisposition(rawValue: value) {
    case .buffered, .transportAdmitted, .consumerAccepted:
      return nil
    case .expired, .overflowDisplaced, .sessionEnded, .none:
      return value
    }
  }
}

private enum ViewerTimelineScrollAnchor: Hashable {
  case tail
}

struct ViewerTimelineTailViewportState: Equatable {
  private(set) var isMounted = false
  private(set) var isTailVisible = false
  private var reportGeneration: UInt64 = 0

  var shouldFollowNewEvents: Bool { isMounted && isTailVisible }

  mutating func mount() {
    isMounted = true
  }

  mutating func unmount() {
    isMounted = false
    isTailVisible = false
    reportGeneration &+= 1
  }

  mutating func observe(tailFrame: CGRect, viewportSize: CGSize) -> UInt64? {
    guard isMounted, viewportSize.width > 0, viewportSize.height > 0 else { return nil }
    let tolerance: CGFloat = 1
    let isVisible =
      !tailFrame.isNull
      && tailFrame.minY >= -tolerance
      && tailFrame.maxY <= viewportSize.height + tolerance
    return observe(isVisible: isVisible)
  }

  mutating func observe(isVisible: Bool) -> UInt64? {
    guard isMounted else { return nil }
    isTailVisible = isVisible
    reportGeneration &+= 1
    return reportGeneration
  }

  mutating func observe(
    previous: ViewerTimelineScrollGeometry,
    current: ViewerTimelineScrollGeometry
  ) -> UInt64? {
    guard isMounted else { return nil }
    let movedUp = current.visibleMaxY < previous.visibleMaxY - current.tolerance
    let contentGrew = current.contentHeight > previous.contentHeight + current.tolerance
    if current.isAtBottom {
      return observe(isVisible: true)
    }
    if isTailVisible, contentGrew, !movedUp {
      return observe(isVisible: true)
    }
    return observe(isVisible: false)
  }

  func accepts(_ token: UInt64) -> Bool {
    isMounted && reportGeneration == token
  }
}

struct ViewerTimelineScrollGeometry: Equatable {
  let visibleMaxY: CGFloat
  let contentHeight: CGFloat
  let tolerance: CGFloat

  init(visibleMaxY: CGFloat, contentHeight: CGFloat, tolerance: CGFloat = 2) {
    self.visibleMaxY = visibleMaxY
    self.contentHeight = contentHeight
    self.tolerance = tolerance
  }

  var isAtBottom: Bool {
    contentHeight <= tolerance || visibleMaxY >= contentHeight - tolerance
  }
}

struct ViewerTimelineFallbackAppendState<EventID: Equatable>: Equatable {
  private(set) var settledLastEventID: EventID?

  mutating func mount(lastEventID: EventID?) {
    settledLastEventID = lastEventID
  }

  mutating func settle(lastEventID: EventID?) {
    settledLastEventID = lastEventID
  }

  mutating func unmount() {
    settledLastEventID = nil
  }

  func shouldPreserveFollow(
    wasFollowing: Bool,
    currentLastEventID: EventID?
  ) -> Bool {
    wasFollowing && settledLastEventID != currentLastEventID
  }
}

private struct ViewerTimelineScrollGeometryModifier: ViewModifier {
  let onChange: (ViewerTimelineScrollGeometry, ViewerTimelineScrollGeometry) -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.onScrollGeometryChange(for: ViewerTimelineScrollGeometry.self) { geometry in
        ViewerTimelineScrollGeometry(
          visibleMaxY: geometry.visibleRect.maxY,
          contentHeight: geometry.contentSize.height
        )
      } action: { previous, current in
        onChange(previous, current)
      }
    } else {
      content
    }
  }
}

private enum ViewerTimelineCoordinateSpace {
  static let name = "ViewerTimelineViewport"
}

private struct ViewerTimelineTailFramePreferenceKey: PreferenceKey {
  static let defaultValue = CGRect.null

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}

private struct ViewerTimelineViewportSizePreferenceKey: PreferenceKey {
  static let defaultValue = CGSize.zero

  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    value = nextValue()
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
        Text("Exporting \(eventCount) retained Event(s)")
        Text("The destination is replaced only after the complete JSON file commits.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .cancelling(let eventCount):
      VStack(spacing: 12) {
        ProgressView()
        Text("Cancelling export of \(eventCount) retained Event(s)")
        Text("Waiting for the export commit boundary before reporting the final result.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .completed(let eventCount):
      ViewerExplorerEmptyState(
        title: "Export Complete",
        systemImage: "checkmark.circle",
        description: "Committed \(eventCount) retained Event(s) to the selected JSON file."
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
      Text("This export contains \(eventCount) Events retained in the current memory Session.")
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
          "Viewer does not manage, retain, clean up, or delete the exported file.")
      }
      if disclosure.mayBeSyncedOrBackedUpByDestinationProvider {
        disclosureLine("The chosen destination provider may sync or back up the file.")
      }
      disclosureLine("Only Events currently retained in memory are included.")
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
    case .completeSession: return "Complete Session"
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
  let rendererPreparation: ViewerRendererPreparation?

  @MainActor
  static func make(_ explorer: ViewerEventExplorerController) -> Self {
    Self(
      selectedEventID: explorer.selectedEventID,
      state: explorer.inspectorState,
      metadata: explorer.inspectorMetadata,
      contentByteCount: explorer.inspectorContentByteCount,
      rawChunkIndex: explorer.rawChunkIndex,
      rawChunk: explorer.rawChunk,
      rendererPreparation: explorer.rendererPreparation
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
  case pretty = "Pretty"
  case preview = "Preview"
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
    case .pretty: prettyView
    case .preview: previewView
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
        .accessibilityHint("Select Event content to copy it.")
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
  private var prettyView: some View {
    if let pretty = explorer.rendererPreparation?.generic.prettyText {
      ViewerReceivedEventText(
        text: pretty,
        accessibilityText: ViewerStructuredTextEscaper.escape(
          pretty,
          maximumBytes: ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
        )
      )
      .accessibilityHint("Select Event content to copy it.")
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
  private var previewView: some View {
    if let preparation = explorer.rendererPreparation {
      if let guidance = preparation.fallbackGuidance {
        VStack(spacing: 0) {
          Label(LocalizedStringKey(guidance), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
          Divider()
          genericPreview(preparation)
        }
      } else if let specialized = preparation.specialized {
        specializedRenderer(specialized)
      } else {
        genericPreview(preparation)
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

  @ViewBuilder
  private func genericPreview(_ preparation: ViewerRendererPreparation) -> some View {
    if let pretty = preparation.generic.prettyText {
      ViewerReceivedEventText(
        text: pretty,
        accessibilityText: ViewerStructuredTextEscaper.escape(
          pretty,
          maximumBytes: ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
        )
      )
      .accessibilityHint("Select Event content to copy it.")
    } else if let chunk = explorer.previewRawChunk {
      VStack(spacing: 0) {
        Label(
          "Showing the first bounded Raw chunk because formatted JSON is unavailable.",
          systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        Divider()
        ViewerReceivedEventText(
          text: chunk.text,
          accessibilityText: chunk.focusedAccessibilityText
        )
        .accessibilityHint("Select Event content to copy it.")
      }
    } else {
      ViewerExplorerEmptyState(
        title: "Preview Unavailable",
        systemImage: "curlybraces",
        description: "The selected Event could not be prepared for preview."
      )
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

extension ViewerExplorerFailure {
  var operatorMessage: String {
    switch self {
    case .cancelled: return "The operation was cancelled."
    case .unavailable: return "The Event is no longer retained in the current Session."
    case .invalidRequest: return "The requested bounded view is no longer valid."
    case .busy: return "Another Session operation is still finishing. Try again shortly."
    case .refineQuery: return "Refine the filters to stay within bounded evaluation work."
    case .exportTooLarge:
      return "The complete Session is too large to export. Clear unneeded Events and try again."
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
      return
        "The imported Session is too large for the current memory limit. Import a smaller Session."
    case .cancelled: return "The Session operation was cancelled."
    }
  }
}
