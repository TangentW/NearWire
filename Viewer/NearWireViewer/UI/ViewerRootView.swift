import Combine
import SwiftUI
import UniformTypeIdentifiers

enum ViewerWorkspaceRegion: String, CaseIterable, Equatable, Sendable {
  case devices
  case eventTimeline
  case eventInspector
  case controlComposer
}

enum ViewerWorkspaceLayout {
  static let regions = ViewerWorkspaceRegion.allCases
  static let minimumWindowWidth: CGFloat = 1_000
  static let minimumWindowHeight: CGFloat = 720
  static let timelineMinimumWidth: CGFloat = 340
  static let timelineDefaultWidthFraction: CGFloat = 0.7
  static let timelineIdealWidth: CGFloat = minimumWindowWidth * timelineDefaultWidthFraction
  static let inspectorMinimumWidth: CGFloat = 280
  static let inspectorDefaultWidthFraction: CGFloat = 1 - timelineDefaultWidthFraction
  static let inspectorIdealWidth: CGFloat = minimumWindowWidth * inspectorDefaultWidthFraction
  static let analysisMinimumHeight: CGFloat = 260
  static let composerExpandedHeight: CGFloat = 240
}

enum ViewerWorkspaceLayoutProbeKind: Equatable, Sendable {
  case pairingHeader
  case pairingCode
  case approval
  case analysis
  case eventTimeline
  case eventInspector
  case timelineToolbar
  case composer
}

final class ViewerWorkspaceLayoutProbeView: NSView {
  var kind: ViewerWorkspaceLayoutProbeKind

  init(kind: ViewerWorkspaceLayoutProbeKind) {
    self.kind = kind
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct ViewerWorkspaceLayoutProbe: NSViewRepresentable {
  let kind: ViewerWorkspaceLayoutProbeKind

  func makeNSView(context: Context) -> ViewerWorkspaceLayoutProbeView {
    ViewerWorkspaceLayoutProbeView(kind: kind)
  }

  func updateNSView(_ nsView: ViewerWorkspaceLayoutProbeView, context: Context) {
    nsView.kind = kind
  }
}

final class ViewerWorkspaceHorizontalSplitView: NSSplitView {
  var defaultLeadingFraction: CGFloat = ViewerWorkspaceLayout.timelineDefaultWidthFraction
  var minimumLeadingWidth: CGFloat = ViewerWorkspaceLayout.timelineMinimumWidth
  var minimumTrailingWidth: CGFloat = ViewerWorkspaceLayout.inspectorMinimumWidth
  private(set) var hasAppliedDefaultPosition = false
  private var savedLeadingFraction: CGFloat?

  override func layout() {
    super.layout()
    applyDefaultPositionIfNeeded()
  }

  func updateArrangedSubviews(
    leading: NSView?,
    trailing: NSView?,
    showsLeading: Bool,
    showsTrailing: Bool
  ) {
    let previouslyShowedBoth =
      leading.map(isArrangedSubview) == true && trailing.map(isArrangedSubview) == true
    let shouldShowBoth = showsLeading && showsTrailing
    if previouslyShowedBoth && !shouldShowBoth {
      saveCurrentLeadingFraction()
    }

    if !showsLeading, let leading, isArrangedSubview(leading) {
      removeArrangedSubview(leading)
      leading.removeFromSuperview()
    }
    if !showsTrailing, let trailing, isArrangedSubview(trailing) {
      removeArrangedSubview(trailing)
      trailing.removeFromSuperview()
    }
    if showsLeading, let leading, !isArrangedSubview(leading) {
      if let trailing, isArrangedSubview(trailing) {
        insertArrangedSubview(leading, at: 0)
      } else {
        addArrangedSubview(leading)
      }
    }
    if showsTrailing, let trailing, !isArrangedSubview(trailing) {
      addArrangedSubview(trailing)
    }

    if shouldShowBoth && !previouslyShowedBoth {
      hasAppliedDefaultPosition = false
    }
    needsLayout = true
  }

  private func isArrangedSubview(_ view: NSView) -> Bool {
    arrangedSubviews.contains { $0 === view }
  }

  private func saveCurrentLeadingFraction() {
    guard arrangedSubviews.count == 2 else { return }
    let availableWidth =
      arrangedSubviews[0].frame.width + arrangedSubviews[1].frame.width
    guard availableWidth > 0 else { return }
    savedLeadingFraction = arrangedSubviews[0].frame.width / availableWidth
  }

  private func applyDefaultPositionIfNeeded() {
    guard !hasAppliedDefaultPosition, arrangedSubviews.count == 2 else { return }
    let availableWidth = bounds.width - dividerThickness
    guard availableWidth >= minimumLeadingWidth + minimumTrailingWidth else { return }
    let maximumLeadingWidth = availableWidth - minimumTrailingWidth
    let leadingFraction = savedLeadingFraction ?? defaultLeadingFraction
    let targetWidth = min(
      max(availableWidth * leadingFraction, minimumLeadingWidth),
      maximumLeadingWidth
    )
    hasAppliedDefaultPosition = true
    setPosition(targetWidth, ofDividerAt: 0)
  }
}

struct ViewerSplitHostedContent<Content: View>: View {
  let content: Content
  let locale: Locale
  let colorScheme: ColorScheme

  var body: some View {
    content
      .environment(\.locale, locale)
      .environment(\.colorScheme, colorScheme)
  }
}

struct ViewerStableHorizontalSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var colorScheme
  let defaultLeadingFraction: CGFloat
  let minimumLeadingWidth: CGFloat
  let minimumTrailingWidth: CGFloat
  let showsLeading: Bool
  let showsTrailing: Bool
  let leading: Leading
  let trailing: Trailing

  init(
    defaultLeadingFraction: CGFloat,
    minimumLeadingWidth: CGFloat,
    minimumTrailingWidth: CGFloat,
    showsLeading: Bool = true,
    showsTrailing: Bool = true,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.defaultLeadingFraction = defaultLeadingFraction
    self.minimumLeadingWidth = minimumLeadingWidth
    self.minimumTrailingWidth = minimumTrailingWidth
    self.showsLeading = showsLeading
    self.showsTrailing = showsTrailing
    self.leading = leading()
    self.trailing = trailing()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      leading: hosted(leading),
      trailing: hosted(trailing),
      showsLeading: showsLeading,
      showsTrailing: showsTrailing
    )
  }

  func makeNSView(context: Context) -> ViewerWorkspaceHorizontalSplitView {
    let splitView = ViewerWorkspaceHorizontalSplitView()
    splitView.isVertical = true
    splitView.dividerStyle = .thin
    splitView.delegate = context.coordinator
    configure(splitView, coordinator: context.coordinator)
    return splitView
  }

  func updateNSView(_ splitView: ViewerWorkspaceHorizontalSplitView, context: Context) {
    context.coordinator.prepare(
      leading: hosted(leading),
      trailing: hosted(trailing),
      showsLeading: showsLeading,
      showsTrailing: showsTrailing
    )
    configure(splitView, coordinator: context.coordinator)
    context.coordinator.releaseHidden(
      showsLeading: showsLeading,
      showsTrailing: showsTrailing
    )
  }

  private func hosted<Content: View>(_ content: Content) -> ViewerSplitHostedContent<Content> {
    ViewerSplitHostedContent(
      content: content,
      locale: locale,
      colorScheme: colorScheme
    )
  }

  private func configure(
    _ splitView: ViewerWorkspaceHorizontalSplitView,
    coordinator: Coordinator
  ) {
    splitView.defaultLeadingFraction = defaultLeadingFraction
    splitView.minimumLeadingWidth = minimumLeadingWidth
    splitView.minimumTrailingWidth = minimumTrailingWidth
    splitView.updateArrangedSubviews(
      leading: coordinator.leadingHostingView,
      trailing: coordinator.trailingHostingView,
      showsLeading: showsLeading,
      showsTrailing: showsTrailing
    )
  }

  @MainActor
  final class Coordinator: NSObject, NSSplitViewDelegate {
    private(set) var leadingHostingView: NSHostingView<ViewerSplitHostedContent<Leading>>?
    private(set) var trailingHostingView: NSHostingView<ViewerSplitHostedContent<Trailing>>?

    init(
      leading: ViewerSplitHostedContent<Leading>,
      trailing: ViewerSplitHostedContent<Trailing>,
      showsLeading: Bool,
      showsTrailing: Bool
    ) {
      if showsLeading {
        leadingHostingView = NSHostingView(rootView: leading)
      }
      if showsTrailing {
        trailingHostingView = NSHostingView(rootView: trailing)
      }
    }

    func prepare(
      leading: ViewerSplitHostedContent<Leading>,
      trailing: ViewerSplitHostedContent<Trailing>,
      showsLeading: Bool,
      showsTrailing: Bool
    ) {
      if showsLeading {
        if let leadingHostingView {
          leadingHostingView.rootView = leading
        } else {
          leadingHostingView = NSHostingView(rootView: leading)
        }
      }
      if showsTrailing {
        if let trailingHostingView {
          trailingHostingView.rootView = trailing
        } else {
          trailingHostingView = NSHostingView(rootView: trailing)
        }
      }
    }

    func releaseHidden(showsLeading: Bool, showsTrailing: Bool) {
      if !showsLeading {
        leadingHostingView = nil
      }
      if !showsTrailing {
        trailingHostingView = nil
      }
    }

    func splitView(
      _ splitView: NSSplitView,
      constrainMinCoordinate proposedMinimumPosition: CGFloat,
      ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
      guard let splitView = splitView as? ViewerWorkspaceHorizontalSplitView else {
        return proposedMinimumPosition
      }
      return max(proposedMinimumPosition, splitView.minimumLeadingWidth)
    }

    func splitView(
      _ splitView: NSSplitView,
      constrainMaxCoordinate proposedMaximumPosition: CGFloat,
      ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
      guard let splitView = splitView as? ViewerWorkspaceHorizontalSplitView else {
        return proposedMaximumPosition
      }
      return min(
        proposedMaximumPosition,
        splitView.bounds.width - splitView.dividerThickness - splitView.minimumTrailingWidth
      )
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
      false
    }
  }
}

struct ViewerWorkspaceVisibility: Equatable, Sendable {
  var timeline = true
  var inspector = true
  var composer = false
}

private struct ViewerRootPresentationSignature: Equatable {
  struct Session: Equatable {
    let route: ViewerLogicalRoute
    let connectionID: UUID?
    let state: ViewerSessionState
  }

  let status: ViewerApplicationModel.Status
  let requiresApproval: Bool
  let selectedRoute: ViewerLogicalRoute?
  let explorerIdentity: ObjectIdentifier?
  let analysisIdentity: ObjectIdentifier?
  let composerIdentity: ObjectIdentifier?
  let sessions: [Session]

  @MainActor
  static func make(_ model: ViewerApplicationModel) -> Self {
    Self(
      status: model.status,
      requiresApproval: model.requiresApproval,
      selectedRoute: model.selectedRoute,
      explorerIdentity: model.explorerController.map(ObjectIdentifier.init),
      analysisIdentity: model.analysisCoordinator.map(ObjectIdentifier.init),
      composerIdentity: model.composerController.map(ObjectIdentifier.init),
      sessions: model.sessions.map {
        Session(route: $0.route, connectionID: $0.connectionID, state: $0.state)
      }
    )
  }
}

@MainActor
private final class ViewerRootPresentationObserver: ObservableObject {
  @Published private(set) var revision: UInt64 = 0
  private weak var model: ViewerApplicationModel?
  private var signature: ViewerRootPresentationSignature
  private var cancellables: Set<AnyCancellable> = []
  private var refreshScheduled = false

  init(model: ViewerApplicationModel) {
    self.model = model
    signature = .make(model)
    let publishers: [AnyPublisher<Void, Never>] = [
      model.$status.map { _ in () }.eraseToAnyPublisher(),
      model.$requiresApproval.map { _ in () }.eraseToAnyPublisher(),
      model.$selectedRoute.map { _ in () }.eraseToAnyPublisher(),
      model.$explorerController.map { _ in () }.eraseToAnyPublisher(),
      model.$analysisCoordinator.map { _ in () }.eraseToAnyPublisher(),
      model.$composerController.map { _ in () }.eraseToAnyPublisher(),
      model.$sessions.map { _ in () }.eraseToAnyPublisher(),
    ]
    Publishers.MergeMany(publishers)
      .sink { [weak self] in self?.scheduleRefresh() }
      .store(in: &cancellables)
  }

  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.refreshScheduled = false
      guard let model = self.model else { return }
      let next = ViewerRootPresentationSignature.make(model)
      guard next != self.signature else { return }
      self.signature = next
      self.revision &+= 1
    }
  }
}

struct ViewerRootView: View {
  let model: ViewerApplicationModel
  let openPerformanceWindow: () -> Void
  @StateObject private var presentationObserver: ViewerRootPresentationObserver
  @State private var showsDeviceDetails = false
  @State private var focusedDeviceID: UUID?
  @State private var workspaceVisibility = ViewerWorkspaceVisibility()

  init(
    model: ViewerApplicationModel,
    initialWorkspaceVisibility: ViewerWorkspaceVisibility = ViewerWorkspaceVisibility(),
    openPerformanceWindow: @escaping () -> Void = {}
  ) {
    self.model = model
    self.openPerformanceWindow = openPerformanceWindow
    _workspaceVisibility = State(initialValue: initialWorkspaceVisibility)
    _presentationObserver = StateObject(
      wrappedValue: ViewerRootPresentationObserver(model: model)
    )
  }

  var body: some View {
    let _ = presentationObserver.revision
    VStack(spacing: 0) {
      pairingHeader
      Divider()
      deviceStrip
      Divider()
      analysisWorkspace
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(isPresented: $showsDeviceDetails) {
      deviceDetailsSheet
    }
  }

  private var pairingHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Connect an iPhone App").font(.headline)
        Spacer(minLength: 12)
        performanceWindowButton
        workspaceVisibilityControls
      }
      HStack(alignment: .center, spacing: 12) {
        connectionStatusAndActions
          .layoutPriority(1)
          .background(ViewerWorkspaceLayoutProbe(kind: .pairingCode))
        Spacer(minLength: 12)
        Toggle(
          "Require approval for new devices",
          isOn: Binding(
            get: { model.requiresApproval },
            set: { model.requiresApproval = $0 }
          )
        )
        .fixedSize()
        .background(ViewerWorkspaceLayoutProbe(kind: .approval))
        .accessibilityHint("New devices wait for explicit acceptance before session handoff.")
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .background(ViewerWorkspaceLayoutProbe(kind: .pairingHeader))
  }

  @ViewBuilder
  private var connectionStatusAndActions: some View {
    if pairingCode != nil {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Pairing Code")
          .font(.caption)
          .foregroundStyle(.secondary)
        statusContent
        Button("Copy") { model.copyPairingCode() }
          .accessibilityLabel("Copy pairing code")
        Button("Refresh") { model.refreshPairingCode() }
          .accessibilityLabel("Refresh pairing code")
        Button(LocalizedStringKey(isPaused ? "Resume New Devices" : "Pause New Devices")) {
          model.togglePaused()
        }
      }
    } else {
      statusContent
    }
  }

  @ViewBuilder
  private var performanceWindowButton: some View {
    Button {
      model.analysisCoordinator?.showPerformance()
      openPerformanceWindow()
    } label: {
      Label("Performance", systemImage: "chart.xyaxis.line")
    }
    .disabled(model.analysisCoordinator == nil)
    .help("Open the Performance window")
    .accessibilityLabel("Open Performance window")
    .accessibilityIdentifier("nearwire.workspace.open-performance")
  }

  @ViewBuilder
  private var workspaceVisibilityControls: some View {
    if let analysis = model.analysisCoordinator {
      ViewerWorkspaceVisibilityControls(
        analysis: analysis,
        visibility: $workspaceVisibility
      )
      .onChange(of: analysis.eventRevealRevision) { _ in
        workspaceVisibility.inspector = true
      }
    } else {
      ViewerWorkspaceVisibilityControlsPlaceholder(visibility: $workspaceVisibility)
    }
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
          .font(.system(size: 36, weight: .semibold, design: .monospaced))
          .textSelection(.enabled)
          .accessibilityLabel("Pairing code \(code)")
        Text(LocalizedStringKey(paused ? "Paused" : "Listening"))
          .foregroundStyle(paused ? .orange : .green)
      }
    case .stopping:
      ProgressView("Stopping listener")
    case .failed(let error):
      HStack {
        VStack(alignment: .leading) {
          Text(LocalizedStringKey(error.title)).foregroundStyle(.red)
          Text(LocalizedStringKey(error.recovery)).font(.caption).foregroundStyle(.secondary)
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
  private var deviceStrip: some View {
    if let explorer = model.explorerController {
      ViewerDevicesStrip(
        application: model,
        explorer: explorer,
        focusedDeviceID: $focusedDeviceID,
        showsDeviceDetails: $showsDeviceDetails
      )
    } else {
      ViewerDevicesStripPlaceholder(sessionCount: model.sessions.count)
    }
  }

  private var analysisWorkspace: some View {
    VStack(spacing: 0) {
      analysisContent
        .frame(minHeight: ViewerWorkspaceLayout.analysisMinimumHeight, maxHeight: .infinity)
        .layoutPriority(1)
        .background(ViewerWorkspaceLayoutProbe(kind: .analysis))
        .clipped()
      if workspaceVisibility.composer {
        Divider()
        controlComposer
          .frame(height: ViewerWorkspaceLayout.composerExpandedHeight)
          .background(ViewerWorkspaceLayoutProbe(kind: .composer))
          .clipped()
          .accessibilityIdentifier("nearwire.workspace.control-composer")
      }
    }
  }

  @ViewBuilder
  private var analysisContent: some View {
    ViewerAnalysisWorkspacePane(
      explorer: model.explorerController,
      showsTimeline: workspaceVisibility.timeline,
      showsInspector: workspaceVisibility.inspector
    )
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

  @ViewBuilder
  private var deviceDetailsSheet: some View {
    if let focusedDeviceID,
      let row = model.explorerController?.deviceRows.first(where: { $0.id == focusedDeviceID }),
      let session = model.sessions.first(where: { $0.connectionID == row.connectionID })
    {
      ViewerDeviceDetail(model: model, session: session)
        .id(session.route.storageKey)
        .frame(minWidth: 620, minHeight: 620)
    } else if let focusedDeviceID,
      let row = model.explorerController?.deviceRows.first(where: { $0.id == focusedDeviceID })
    {
      ViewerOfflineDeviceDetail(row: row)
        .id(row.id)
        .frame(minWidth: 520, minHeight: 420)
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

  private var pairingCode: String? {
    guard case .listening(let code, _) = model.status else { return nil }
    return code
  }

  private var isPaused: Bool {
    guard case .listening(_, let paused) = model.status else { return false }
    return paused
  }
}

private struct ViewerWorkspaceVisibilityControls: View {
  @Environment(\.locale) private var locale
  @ObservedObject var analysis: ViewerAnalysisModeCoordinator
  @Binding var visibility: ViewerWorkspaceVisibility

  var body: some View {
    HStack(spacing: 4) {
      visibilityButton(
        title: "Event Timeline",
        systemImage: "rectangle.leadinghalf.inset.filled",
        isVisible: $visibility.timeline
      )
      visibilityButton(
        title: "Event Inspector",
        systemImage: "rectangle.trailinghalf.inset.filled",
        isVisible: $visibility.inspector
      )
      visibilityButton(
        title: "Viewer to App Composer",
        systemImage: "rectangle.bottomhalf.inset.filled",
        isVisible: $visibility.composer
      )
    }
    .controlSize(.small)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Workspace panels")
  }

  private func visibilityButton(
    title: String,
    systemImage: String,
    isVisible: Binding<Bool>
  ) -> some View {
    Button {
      isVisible.wrappedValue.toggle()
    } label: {
      ZStack(alignment: .bottomTrailing) {
        Image(systemName: systemImage)
          .foregroundStyle(isVisible.wrappedValue ? Color.accentColor : Color.secondary)
        if isVisible.wrappedValue {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.accentColor)
            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
            .offset(x: 3, y: 3)
            .accessibilityHidden(true)
        }
      }
        .frame(width: 18, height: 18)
        .padding(3)
        .background(
          isVisible.wrappedValue ? Color.accentColor.opacity(0.14) : Color.clear,
          in: RoundedRectangle(cornerRadius: 4)
        )
    }
    .buttonStyle(.bordered)
    .help(visibilityDescription(title: title, isVisible: isVisible.wrappedValue))
    .accessibilityLabel(visibilityDescription(title: title, isVisible: isVisible.wrappedValue))
    .accessibilityValue(Text(LocalizedStringKey(isVisible.wrappedValue ? "Expanded" : "Collapsed")))
  }

  private func visibilityDescription(title: String, isVisible: Bool) -> String {
    ViewerLocalization.format(
      "%@ %@",
      locale: locale,
      arguments: [
        ViewerLocalization.string(isVisible ? "Hide" : "Show", locale: locale),
        ViewerLocalization.string(title, locale: locale),
      ]
    )
  }
}

private struct ViewerWorkspaceVisibilityControlsPlaceholder: View {
  @Environment(\.locale) private var locale
  @Binding var visibility: ViewerWorkspaceVisibility

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "rectangle.leadinghalf.inset.filled")
        .frame(width: 30, height: 24)
      Image(systemName: "rectangle.trailinghalf.inset.filled")
        .frame(width: 30, height: 24)
      Button {
        visibility.composer.toggle()
      } label: {
        Image(systemName: "rectangle.bottomhalf.inset.filled")
      }
      .help(composerVisibilityDescription)
      .accessibilityLabel(composerVisibilityDescription)
      .accessibilityValue(Text(LocalizedStringKey(visibility.composer ? "Expanded" : "Collapsed")))
    }
    .controlSize(.small)
    .buttonStyle(.bordered)
    .disabled(true)
    .accessibilityLabel("Workspace panels unavailable while runtime starts")
  }

  private var composerVisibilityDescription: String {
    ViewerLocalization.format(
      "%@ %@",
      locale: locale,
      arguments: [
        ViewerLocalization.string(visibility.composer ? "Hide" : "Show", locale: locale),
        ViewerLocalization.string("Viewer to App Composer", locale: locale),
      ]
    )
  }
}

private struct ViewerDevicesPresentation: Equatable {
  struct DeviceChip: Identifiable, Equatable {
    let id: UUID
    let connectionID: UUID
    let title: String
    let subtitle: String
    let state: String
  }

  let deviceRows: [DeviceChip]
  let selectedDeviceIDs: Set<UUID>
  let pendingApps: [ViewerPendingAppSummary]
  let canExport: Bool
  let canImport: Bool
  let workspaceOperationState: ViewerWorkspaceOperationState

  @MainActor
  static func make(
    application: ViewerApplicationModel,
    explorer: ViewerEventExplorerController
  ) -> Self {
    let operation = explorer.workspaceOperationState
    let operationIsRunning = operation == .clearing || operation == .importing
    return Self(
      deviceRows: explorer.deviceRows.map {
        DeviceChip(
          id: $0.id,
          connectionID: $0.connectionID,
          title: $0.title,
          subtitle: $0.subtitle,
          state: $0.state
        )
      },
      selectedDeviceIDs: explorer.selectedDeviceIDs,
      pendingApps: application.pendingApps,
      canExport: explorer.canExportCurrentSession && !operationIsRunning,
      canImport: explorer.canImportCurrentSession && application.pendingApps.isEmpty,
      workspaceOperationState: operation
    )
  }
}

@MainActor
private final class ViewerDevicesPresentationObserver: ObservableObject {
  @Published private(set) var value: ViewerDevicesPresentation
  private weak var application: ViewerApplicationModel?
  private weak var explorer: ViewerEventExplorerController?
  private var cancellables: Set<AnyCancellable> = []
  private var refreshScheduled = false

  init(application: ViewerApplicationModel, explorer: ViewerEventExplorerController) {
    self.application = application
    self.explorer = explorer
    value = .make(application: application, explorer: explorer)
    Publishers.MergeMany([
      application.$pendingApps.map { _ in () }.eraseToAnyPublisher(),
      application.$sessions.map { _ in () }.eraseToAnyPublisher(),
      application.$selectedRoute.map { _ in () }.eraseToAnyPublisher(),
      explorer.$revision.map { _ in () }.eraseToAnyPublisher(),
    ])
    .sink { [weak self] in self?.scheduleRefresh() }
    .store(in: &cancellables)
  }

  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.refreshScheduled = false
      guard let application = self.application, let explorer = self.explorer else { return }
      let next = ViewerDevicesPresentation.make(application: application, explorer: explorer)
      guard next != self.value else { return }
      self.value = next
    }
  }
}

private struct ViewerDevicesStrip: View {
  @Environment(\.locale) private var locale
  let application: ViewerApplicationModel
  let explorer: ViewerEventExplorerController
  @StateObject private var presentation: ViewerDevicesPresentationObserver
  @Binding var focusedDeviceID: UUID?
  @Binding var showsDeviceDetails: Bool
  @State private var showsExport = false
  @State private var showsImportDisclosure = false
  @State private var showsImportPicker = false

  init(
    application: ViewerApplicationModel,
    explorer: ViewerEventExplorerController,
    focusedDeviceID: Binding<UUID?>,
    showsDeviceDetails: Binding<Bool>
  ) {
    self.application = application
    self.explorer = explorer
    _focusedDeviceID = focusedDeviceID
    _showsDeviceDetails = showsDeviceDetails
    _presentation = StateObject(
      wrappedValue: ViewerDevicesPresentationObserver(
        application: application,
        explorer: explorer
      )
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Label("Devices", systemImage: "iphone.gen3")
          .font(.headline)
        Text("\(presentation.value.deviceRows.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(presentation.value.deviceRows.count) devices")
        Spacer()
        Button {
          if explorer.beginCurrentSessionImportSelection() {
            showsImportDisclosure = true
          }
        } label: {
          Label("Import Session", systemImage: "square.and.arrow.down")
        }
        .disabled(importIsDisabled)
        .help("Replace the inactive current Session from a complete NearWire JSON export")
        Button {
          explorer.prepareExport(.completeSession)
          showsExport = true
        } label: {
          Label("Export Session", systemImage: "square.and.arrow.up")
        }
        .disabled(!presentation.value.canExport)
        .help("Export the complete current Session as unencrypted JSON")
        Button {
          showsDeviceDetails = true
        } label: {
          Label("Device Details", systemImage: "slider.horizontal.3")
        }
        .disabled(!hasFocusedDevice)
        .help("Open details for the focused Device; connected Devices also expose settings")
      }

      ScrollView(.horizontal, showsIndicators: true) {
        HStack(spacing: 8) {
          deviceScopeButton(
            title: ViewerLocalization.string("All Devices", locale: locale),
            subtitle: ViewerLocalization.string("Merged timeline", locale: locale),
            systemImage: "rectangle.3.group",
            selected: presentation.value.selectedDeviceIDs.isEmpty,
            focused: false
          ) {
            explorer.selectAllDevices()
          }
          ForEach(presentation.value.deviceRows) { row in
            deviceButton(row)
          }
          if presentation.value.deviceRows.isEmpty {
            Label("Waiting for an App", systemImage: "iphone.slash")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
          }
        }
        .padding(.vertical, 1)
      }
      .accessibilityLabel("Current Session Devices")

      if !presentation.value.pendingApps.isEmpty {
        Divider()
        ScrollView(.horizontal, showsIndicators: true) {
          HStack(spacing: 10) {
            Text("Awaiting approval")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(presentation.value.pendingApps) { app in
              HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(app.displayName).font(.caption.weight(.semibold))
                  Text(app.installationAlias).font(.caption2).foregroundStyle(.secondary)
                }
                Button("Reject") { application.reject(app.id) }
                  .controlSize(.small)
                Button("Accept") { application.accept(app.id) }
                  .controlSize(.small)
                  .buttonStyle(.borderedProminent)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
      }
      workspaceOperationStatus
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .accessibilityIdentifier("nearwire.workspace.devices")
    .sheet(isPresented: $showsExport) {
      ViewerExportSheet(explorer: explorer, isPresented: $showsExport)
        .frame(minWidth: 540, minHeight: 480)
    }
    .alert("Replace Current Session?", isPresented: $showsImportDisclosure) {
      Button("Cancel", role: .cancel) {
        explorer.cancelCurrentSessionImportSelection()
      }
      Button("Choose JSON", role: .destructive) { showsImportPicker = true }
    } message: {
      Text(
        "Import replaces all Events and offline Device rows in the current Session. Only a complete NearWire JSON export is accepted. Imported Devices remain offline and receive new local identities."
      )
    }
    .fileImporter(
      isPresented: $showsImportPicker,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else {
        explorer.cancelCurrentSessionImportSelection()
        return
      }
      explorer.importCurrentSession(from: url)
    }
    .onChange(of: presentation.value.deviceRows) { rows in
      if let focusedDeviceID, !rows.contains(where: { $0.id == focusedDeviceID }) {
        self.focusedDeviceID = nil
        showsDeviceDetails = false
      }
    }
  }

  private var importIsDisabled: Bool {
    !presentation.value.canImport
  }

  private func deviceButton(_ row: ViewerDevicesPresentation.DeviceChip) -> some View {
    deviceScopeButton(
      title: row.title,
      subtitle: "\(row.subtitle) · \(ViewerLocalization.string(row.state.capitalized, locale: locale))",
      systemImage: row.state == "active" ? "iphone.radiowaves.left.and.right" : "iphone",
      selected: presentation.value.selectedDeviceIDs.contains(row.connectionID),
      focused: focusedDeviceID == row.id
    ) {
      explorer.toggleDevice(row.connectionID)
      focusedDeviceID = row.id
      if let session = application.sessions.first(where: {
        $0.connectionID == row.connectionID
      }) {
        application.selectedRoute = session.route
      } else {
        application.selectedRoute = nil
      }
    }
  }

  @ViewBuilder
  private var workspaceOperationStatus: some View {
    switch presentation.value.workspaceOperationState {
    case .idle:
      EmptyView()
    case .selectingImport:
      Label("Choose a complete Session export to import", systemImage: "doc.badge.ellipsis")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .clearing:
      operationBanner(
        title: "Clearing current Session Events",
        systemImage: "trash",
        color: .secondary,
        showsProgress: true
      )
    case .clearCompleted:
      operationBanner(
        title: "Current Session Events cleared",
        systemImage: "checkmark.circle",
        color: .green,
        actionTitle: "Dismiss",
        action: explorer.clearWorkspaceOperationPresentation
      )
    case .importing:
      operationBanner(
        title: "Importing Session",
        systemImage: "square.and.arrow.down",
        color: .secondary,
        showsProgress: true,
        actionTitle: "Cancel",
        action: explorer.cancelCurrentSessionImport
      )
    case .importCompleted:
      operationBanner(
        title: "Session import completed",
        systemImage: "checkmark.circle",
        color: .green,
        actionTitle: "Dismiss",
        action: explorer.clearWorkspaceOperationPresentation
      )
    case .failed(let failure):
      operationBanner(
        title: failure.operatorMessage,
        systemImage: "exclamationmark.triangle",
        color: .orange,
        actionTitle: "Dismiss",
        action: explorer.clearWorkspaceOperationPresentation
      )
    }
  }

  private func operationBanner(
    title: String,
    systemImage: String,
    color: Color,
    showsProgress: Bool = false,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) -> some View {
    HStack(spacing: 8) {
      if showsProgress {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: systemImage).foregroundStyle(color)
      }
      Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(color)
      Spacer()
      if let actionTitle, let action {
        Button(LocalizedStringKey(actionTitle), action: action).controlSize(.small)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
  }

  private func deviceScopeButton(
    title: String,
    subtitle: String,
    systemImage: String,
    selected: Bool,
    focused: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.body)
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.caption.weight(.semibold)).lineLimit(1)
          Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
        }
        if focused {
          Image(systemName: "viewfinder.circle.fill")
            .foregroundStyle(Color.primary)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.18))
      }
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      ViewerLocalization.format(
        "%@, %@%@",
        locale: locale,
        arguments: [
          title,
          subtitle,
          focused
            ? ViewerLocalization.string(", focused for Device Details", locale: locale) : "",
        ]
      )
    )
    .accessibilityValue(Text(LocalizedStringKey(selected ? "Selected" : "Not selected")))
  }

  private var hasFocusedDevice: Bool {
    guard let focusedDeviceID else { return false }
    return presentation.value.deviceRows.contains { $0.id == focusedDeviceID }
  }
}

private struct ViewerDevicesStripPlaceholder: View {
  let sessionCount: Int

  var body: some View {
    HStack(spacing: 10) {
      Label("Devices", systemImage: "iphone.gen3").font(.headline)
      Text("\(sessionCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      Spacer()
      ProgressView().controlSize(.small)
      Text("Preparing current Session").font(.caption).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .accessibilityIdentifier("nearwire.workspace.devices")
  }
}

private struct ViewerDeviceDetail: View {
  @Environment(\.locale) private var locale
  @ObservedObject var model: ViewerApplicationModel
  let initialSession: ViewerSessionSnapshot
  @State private var nickname: String
  @State private var uplink: String
  @State private var downlink: String
  @State private var validationMessage: String?

  init(model: ViewerApplicationModel, session: ViewerSessionSnapshot) {
    self.model = model
    initialSession = session
    _nickname = State(initialValue: session.nickname ?? "")
    _uplink = State(initialValue: String(session.requestedPolicy.appUplink))
    _downlink = State(initialValue: String(session.requestedPolicy.appDownlink))
  }

  private var session: ViewerSessionSnapshot {
    model.sessions.first(where: { $0.route == initialSession.route }) ?? initialSession
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
            detailRow(
              "Bundle ID",
              session.route.applicationIdentifier
                ?? ViewerLocalization.string("Not supplied", locale: locale)
            )
            detailRow(
              "App version",
              session.applicationVersion ?? ViewerLocalization.string("Not supplied", locale: locale)
            )
            detailRow(
              "State",
              ViewerLocalization.string(session.state.rawValue.capitalized, locale: locale)
            )
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
          Text(LocalizedStringKey(validationMessage))
            .foregroundStyle(.red)
            .accessibilityLabel(Text(LocalizedStringKey(validationMessage)))
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
            detailRow(
              "Current ingress",
              ViewerLocalization.format(
                "%lld events/s",
                locale: locale,
                arguments: [session.ingressEventsPerSecond]
              )
            )
            detailRow(
              "Current egress",
              ViewerLocalization.format(
                "%lld events/s",
                locale: locale,
                arguments: [session.egressEventsPerSecond]
              )
            )
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
      Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
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
        ViewerLocalization.format(
          "%.3f s oldest",
          locale: locale,
          arguments: [Double($0) / 1_000_000_000]
        )
      } ?? ViewerLocalization.string("no pending wait", locale: locale)
    return ViewerLocalization.format(
      "%lld events, %lld bytes, %@",
      locale: locale,
      arguments: [count, bytes, wait]
    )
  }
}

private struct ViewerOfflineDeviceDetail: View {
  @Environment(\.locale) private var locale
  let row: ViewerExplorerDevicePresentationRow

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text(row.title).font(.title2).fontWeight(.semibold)
          Text("Offline Device details")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Label(LocalizedStringKey(row.state.capitalized), systemImage: "iphone.slash")
          .foregroundStyle(.secondary)
      }
      GroupBox("Current Session") {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
          offlineDetailRow("Application", row.subtitle)
          offlineDetailRow(
            "State",
            ViewerLocalization.string(row.state.capitalized, locale: locale)
          )
          offlineDetailRow(
            "Retained Events",
            ViewerLocalization.string(
              row.isMaterialized ? "Available" : "Not available",
              locale: locale
            )
          )
          offlineDetailRow(
            "Gap diagnostics",
            ViewerLocalization.string(row.hasGap ? "Present" : "None", locale: locale)
          )
          offlineDetailRow(
            "Drop diagnostics",
            ViewerLocalization.string(row.hasDrop ? "Present" : "None", locale: locale)
          )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Text(
        "Connection settings and live telemetry are available only while this Device is connected. Imported and recent offline Devices remain available for Event scope and read-only Session details."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(24)
  }

  private func offlineDetailRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }
}

struct ViewerAnalysisWorkspacePane: View {
  let explorer: ViewerEventExplorerController?
  let showsTimeline: Bool
  let showsInspector: Bool
  @State private var inspectorTab = ViewerExplorerInspectorTab.defaultSelection

  init(
    explorer: ViewerEventExplorerController?,
    showsTimeline: Bool = true,
    showsInspector: Bool = true
  ) {
    self.explorer = explorer
    self.showsTimeline = showsTimeline
    self.showsInspector = showsInspector
  }

  var body: some View {
    ZStack {
      if showsTimeline || showsInspector {
        ViewerStableHorizontalSplitView(
          defaultLeadingFraction: ViewerWorkspaceLayout.timelineDefaultWidthFraction,
          minimumLeadingWidth: ViewerWorkspaceLayout.timelineMinimumWidth,
          minimumTrailingWidth: ViewerWorkspaceLayout.inspectorMinimumWidth,
          showsLeading: showsTimeline,
          showsTrailing: showsInspector
        ) {
          timelinePanel
        } trailing: {
          inspectorPanel
        }
      } else {
        ViewerEmptyState(
          title: "Event Panels Hidden",
          systemImage: "rectangle.dashed",
          description: "Use the Timeline or Inspector buttons at the top to restore a panel. Event capture continues."
        )
        .accessibilityIdentifier("nearwire.workspace.events-hidden")
      }
    }
  }

  private var timelinePanel: some View {
    eventTimeline
      .frame(
        minWidth: ViewerWorkspaceLayout.timelineMinimumWidth,
        idealWidth: ViewerWorkspaceLayout.timelineIdealWidth,
        maxWidth: .infinity,
        maxHeight: .infinity
      )
      .background(ViewerWorkspaceLayoutProbe(kind: .eventTimeline))
      .accessibilityIdentifier("nearwire.workspace.event-timeline")
  }

  private var inspectorPanel: some View {
    eventInspector
      .frame(
        minWidth: ViewerWorkspaceLayout.inspectorMinimumWidth,
        idealWidth: ViewerWorkspaceLayout.inspectorIdealWidth,
        maxWidth: .infinity,
        maxHeight: .infinity
      )
      .background(ViewerWorkspaceLayoutProbe(kind: .eventInspector))
      .accessibilityIdentifier("nearwire.workspace.event-inspector")
  }

  @ViewBuilder
  private var eventTimeline: some View {
    if let explorer {
      ViewerExplorerTimelineView(explorer: explorer)
    } else {
      VStack(spacing: 0) {
        paneHeader(title: "Event Timeline", systemImage: "list.bullet.rectangle")
        Divider()
        ViewerEmptyState(
          title: "Runtime Not Ready",
          systemImage: "clock.arrow.circlepath",
          description: "The Event explorer appears when the Viewer runtime starts."
        )
      }
    }
  }

  @ViewBuilder
  private var eventInspector: some View {
    if let explorer {
      ViewerExplorerInspectorView(explorer: explorer, tab: $inspectorTab)
    } else {
      VStack(spacing: 0) {
        paneHeader(title: "Event Inspector", systemImage: "sidebar.right")
        Divider()
        ViewerEmptyState(
          title: "Select an Event",
          systemImage: "doc.text.magnifyingglass",
          description: "Event metadata and bounded content views appear here."
        )
      }
    }
  }

  private func paneHeader(title: String, systemImage: String) -> some View {
    HStack {
      Label(LocalizedStringKey(title), systemImage: systemImage).font(.headline)
      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }
}

struct ViewerEmptyState: View {
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
