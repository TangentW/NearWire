import Foundation

enum ViewerExplorerPagePlacement: Equatable, Sendable {
  case replace
  case leading
  case trailing
}

enum ViewerExplorerWindowEdge: Equatable, Sendable {
  case leading
  case trailing
}

struct ViewerExplorerPresentationToken: Equatable, Sendable {
  let runtimeLogicalID: UUID
  let generation: UInt64
}

enum ViewerExplorerRecordingIdentity: Equatable, Hashable, Sendable {
  case current(runtimeLogicalID: UUID)
  case durable(rowID: Int64, logicalID: UUID)
}

enum ViewerExplorerEventIdentity: Equatable, Hashable, Sendable {
  case durable(rowID: Int64)
  case transient(ViewerEventJournalKey)
}

struct ViewerExplorerGapIdentity: Equatable, Hashable, Sendable {
  let recordingID: Int64
  let deviceSessionID: Int64?
  let namespace: String
  let sequence: Int64
}

struct ViewerExplorerReloadAnchor<Identity: Hashable & Sendable>: Equatable, Sendable {
  let edge: ViewerExplorerWindowEdge
  let identity: Identity
}

struct ViewerExplorerListNavigation<Cursor: Equatable & Sendable, Identity: Hashable & Sendable>:
  Equatable, Sendable
{
  var leadingCursor: Cursor?
  var trailingCursor: Cursor?
  var reloadAnchor: ViewerExplorerReloadAnchor<Identity>?
  var hasUnloadedLeadingRows = false
  var hasUnloadedTrailingRows = false
}

struct ViewerExplorerWindowMutation<Identity: Hashable & Sendable>: Equatable, Sendable {
  let evictedIdentities: [Identity]
  let evictedEdge: ViewerExplorerWindowEdge?
}

struct ViewerExplorerResidentWindow<
  Row: Sendable,
  Cursor: Equatable & Sendable,
  Identity: Hashable & Sendable
>: Sendable {
  private(set) var rows: [Row] = []
  private(set) var navigation = ViewerExplorerListNavigation<Cursor, Identity>()

  let capacity: Int
  private let identity: @Sendable (Row) -> Identity
  private let isOrderedBefore: @Sendable (Row, Row) -> Bool

  init(
    capacity: Int,
    identity: @escaping @Sendable (Row) -> Identity,
    isOrderedBefore: @escaping @Sendable (Row, Row) -> Bool
  ) {
    precondition(capacity > 0)
    self.capacity = capacity
    self.identity = identity
    self.isOrderedBefore = isOrderedBefore
  }

  mutating func apply(
    _ incomingRows: [Row],
    leadingCursor: Cursor?,
    trailingCursor: Cursor?,
    placement: ViewerExplorerPagePlacement
  ) -> ViewerExplorerWindowMutation<Identity>? {
    var incomingIdentities = Set<Identity>()
    for row in incomingRows where !incomingIdentities.insert(identity(row)).inserted {
      return nil
    }
    guard Self.isStrictlyOrdered(incomingRows, by: isOrderedBefore) else { return nil }

    var nextNavigation = navigation
    if let anchor = nextNavigation.reloadAnchor,
      (placement == .leading && anchor.edge == .leading)
        || (placement == .trailing && anchor.edge == .trailing),
      incomingIdentities.contains(anchor.identity)
    {
      nextNavigation.reloadAnchor = nil
      nextNavigation.hasUnloadedLeadingRows = false
      nextNavigation.hasUnloadedTrailingRows = false
    }

    let combined: [Row]
    switch placement {
    case .replace:
      combined = incomingRows
      nextNavigation = ViewerExplorerListNavigation(
        leadingCursor: leadingCursor,
        trailingCursor: trailingCursor,
        reloadAnchor: nil,
        hasUnloadedLeadingRows: false,
        hasUnloadedTrailingRows: false
      )
    case .leading:
      combined = incomingRows + rows.filter { !incomingIdentities.contains(identity($0)) }
      nextNavigation.leadingCursor = leadingCursor
      if rows.isEmpty { nextNavigation.trailingCursor = trailingCursor }
    case .trailing:
      combined = rows.filter { !incomingIdentities.contains(identity($0)) } + incomingRows
      nextNavigation.trailingCursor = trailingCursor
      if rows.isEmpty { nextNavigation.leadingCursor = leadingCursor }
    }
    guard Self.isStrictlyOrdered(combined, by: isOrderedBefore) else { return nil }

    var retained = combined
    var evicted: [Row] = []
    var evictedEdge: ViewerExplorerWindowEdge?
    if retained.count > capacity {
      let excess = retained.count - capacity
      switch placement {
      case .replace, .trailing:
        evicted = Array(retained.prefix(excess))
        retained.removeFirst(excess)
        evictedEdge = .leading
      case .leading:
        evicted = Array(retained.suffix(excess))
        retained.removeLast(excess)
        evictedEdge = .trailing
      }
    }

    if let evictedEdge, !evicted.isEmpty {
      let closestEvicted = evictedEdge == .leading ? evicted.last! : evicted.first!
      nextNavigation.reloadAnchor = ViewerExplorerReloadAnchor(
        edge: evictedEdge,
        identity: identity(closestEvicted)
      )
      nextNavigation.hasUnloadedLeadingRows = evictedEdge == .leading
      nextNavigation.hasUnloadedTrailingRows = evictedEdge == .trailing
    }
    rows = retained
    navigation = nextNavigation
    return ViewerExplorerWindowMutation(
      evictedIdentities: evicted.map(identity),
      evictedEdge: evictedEdge
    )
  }

  mutating func clear() {
    rows.removeAll(keepingCapacity: false)
    navigation = ViewerExplorerListNavigation()
  }

  func contains(_ value: Identity) -> Bool {
    rows.contains { identity($0) == value }
  }

  func firstIdentity() -> Identity? { rows.first.map(identity) }
  func lastIdentity() -> Identity? { rows.last.map(identity) }

  private static func isStrictlyOrdered(
    _ values: [Row],
    by predicate: (Row, Row) -> Bool
  ) -> Bool {
    guard values.count > 1 else { return true }
    for index in 1..<values.count where !predicate(values[index - 1], values[index]) {
      return false
    }
    return true
  }
}

struct ViewerExplorerRefreshSignal: Equatable, Sendable {
  let latestChangeToken: String?
  let durableUpperRowID: Int64?
  let transientChangeCount: UInt64
  let transientGapCount: UInt64
}

struct ViewerExplorerRefreshDiagnostics: Equatable, Sendable {
  let scheduleCount: UInt64
  let deliveryCount: UInt64
  let wakeScheduled: Bool
}

struct ViewerExplorerRefreshScheduler: Sendable {
  let now: @Sendable () -> UInt64
  let scheduleOnMain: @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void

  static let live = ViewerExplorerRefreshScheduler(
    now: { DispatchTime.now().uptimeNanoseconds },
    scheduleOnMain: { delay, action in
      Task { @MainActor in
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        guard !Task.isCancelled else { return }
        action()
      }
    }
  )
}

@MainActor
final class ViewerEventExplorerModel: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  typealias RefreshHandler =
    @MainActor @Sendable (ViewerExplorerPresentationToken, ViewerExplorerRefreshSignal) -> Void

  static let maximumRecordingRows = 200
  static let maximumDeviceRows = 200
  static let maximumEventRows = 600
  static let maximumGapRows = 128
  static let maximumSelectedDevices = 16
  static let maximumCatalogPageRows = 200
  static let maximumEventPageRows = 200
  static let maximumGapPageRows = 32
  static let refreshIntervalNanoseconds: UInt64 = 100_000_000
  static let maximumChangeTokenBytes = 256

  private(set) var runtimeLogicalID: UUID
  private(set) var presentationGeneration: UInt64 = 1
  private(set) var isPaused = false
  private(set) var autoFollow = true
  private(set) var selectedRecordingIdentity: ViewerExplorerRecordingIdentity?
  private(set) var selectedRecordingNeedsReload = false
  private(set) var selectedDeviceLogicalIDs: [UUID] = []
  private(set) var selectedDeviceLogicalIDsNeedingReload: Set<UUID> = []
  private(set) var selectedEventIdentity: ViewerExplorerEventIdentity?
  private(set) var selectedEventDetail: ViewerStoredEventDetail?
  private(set) var selectedEventNeedsReload = false
  private(set) var scrollAnchor: ViewerExplorerEventIdentity?
  private(set) var explorerScope: ViewerExplorerScope?
  private(set) var materializationSnapshot: ViewerExplorerMaterializationSnapshot?
  private(set) var compiledInputs: ViewerExplorerCompiledInputs?
  private(set) var liveGapLane: ViewerExplorerLiveGapLane?
  private(set) var liveEvaluationState: ViewerExplorerLiveEvaluationState?
  private(set) var sealed = false

  private var recordingWindow:
    ViewerExplorerResidentWindow<
      ViewerRecordingCatalogRow, ViewerRecordingCatalogCursor, Int64
    >
  private var deviceWindow:
    ViewerExplorerResidentWindow<
      ViewerDeviceCatalogRow, ViewerDeviceCatalogCursor, Int64
    >
  private var eventWindow: ViewerExplorerTimelineWindow
  private var gapWindow:
    ViewerExplorerResidentWindow<
      ViewerGapRow, ViewerGapCursor, ViewerExplorerGapIdentity
    >

  private let refreshScheduler: ViewerExplorerRefreshScheduler
  private var refreshHandler: RefreshHandler
  private var pendingChangeToken: String?
  private var pendingDurableUpperRowID: Int64?
  private var pendingTransientChangeCount: UInt64 = 0
  private var pendingTransientGapCount: UInt64 = 0
  private var refreshDirty = false
  private var wakeScheduled = false
  private var wakeToken: UInt64 = 0
  private var lastWakeNanoseconds: UInt64?
  private var refreshScheduleCount: UInt64 = 0
  private var refreshDeliveryCount: UInt64 = 0

  init(
    runtimeLogicalID: UUID,
    refreshScheduler: ViewerExplorerRefreshScheduler = .live,
    onRefresh: @escaping RefreshHandler = { _, _ in }
  ) {
    self.runtimeLogicalID = runtimeLogicalID
    self.refreshScheduler = refreshScheduler
    refreshHandler = onRefresh
    recordingWindow = ViewerExplorerResidentWindow(
      capacity: Self.maximumRecordingRows,
      identity: { $0.rowID },
      isOrderedBefore: { $0.rowID > $1.rowID }
    )
    deviceWindow = ViewerExplorerResidentWindow(
      capacity: Self.maximumDeviceRows,
      identity: { $0.rowID },
      isOrderedBefore: {
        $0.connectionOrdinal == $1.connectionOrdinal
          ? $0.rowID > $1.rowID : $0.connectionOrdinal > $1.connectionOrdinal
      }
    )
    eventWindow = ViewerExplorerTimelineWindow(capacity: Self.maximumEventRows)
    gapWindow = ViewerExplorerResidentWindow(
      capacity: Self.maximumGapRows,
      identity: {
        ViewerExplorerGapIdentity(
          recordingID: $0.recordingID,
          deviceSessionID: $0.deviceSessionID,
          namespace: $0.namespace,
          sequence: $0.sequence
        )
      },
      isOrderedBefore: {
        $0.lastViewerWallMilliseconds == $1.lastViewerWallMilliseconds
          ? $0.rowID < $1.rowID
          : $0.lastViewerWallMilliseconds < $1.lastViewerWallMilliseconds
      }
    )
  }

  var currentToken: ViewerExplorerPresentationToken {
    ViewerExplorerPresentationToken(
      runtimeLogicalID: runtimeLogicalID,
      generation: presentationGeneration
    )
  }

  var recordingRows: [ViewerRecordingCatalogRow] { recordingWindow.rows }
  var deviceRows: [ViewerDeviceCatalogRow] { deviceWindow.rows }
  var timelineRows: [ViewerExplorerTimelineRow] { eventWindow.rows }
  var eventRows: [ViewerStoredEventRow] {
    eventWindow.rows.compactMap { row in
      if case .durable(let summary, _) = row { return summary }
      return nil
    }
  }
  var gapRows: [ViewerGapRow] { gapWindow.rows }
  var recordingNavigation: ViewerExplorerListNavigation<ViewerRecordingCatalogCursor, Int64> {
    recordingWindow.navigation
  }
  var deviceNavigation: ViewerExplorerListNavigation<ViewerDeviceCatalogCursor, Int64> {
    deviceWindow.navigation
  }
  var eventNavigation:
    ViewerExplorerListNavigation<
      ViewerEventCursor, ViewerExplorerEventIdentity
    >
  { eventWindow.navigation }
  var gapNavigation: ViewerExplorerListNavigation<ViewerGapCursor, ViewerExplorerGapIdentity> {
    gapWindow.navigation
  }
  var refreshDiagnostics: ViewerExplorerRefreshDiagnostics {
    ViewerExplorerRefreshDiagnostics(
      scheduleCount: refreshScheduleCount,
      deliveryCount: refreshDeliveryCount,
      wakeScheduled: wakeScheduled
    )
  }
  var pendingRefreshSignal: ViewerExplorerRefreshSignal? {
    guard refreshDirty else { return nil }
    return ViewerExplorerRefreshSignal(
      latestChangeToken: pendingChangeToken,
      durableUpperRowID: pendingDurableUpperRowID,
      transientChangeCount: pendingTransientChangeCount,
      transientGapCount: pendingTransientGapCount
    )
  }

  @discardableResult
  func beginPresentationReplacement(clearRows: Bool) -> ViewerExplorerPresentationToken {
    guard !sealed else { return currentToken }
    incrementPresentationGeneration()
    if clearRows { clearResidentPresentation() }
    return currentToken
  }

  @discardableResult
  func replaceRuntime(_ runtimeLogicalID: UUID) -> ViewerExplorerPresentationToken {
    guard !sealed else { return currentToken }
    self.runtimeLogicalID = runtimeLogicalID
    incrementPresentationGeneration()
    clearResidentPresentation()
    clearPendingRefresh()
    return currentToken
  }

  @discardableResult
  func setPaused(_ paused: Bool) -> ViewerExplorerPresentationToken {
    guard !sealed, paused != isPaused else { return currentToken }
    incrementPresentationGeneration()
    isPaused = paused
    if !paused { scheduleRefreshIfNeeded() }
    return currentToken
  }

  func setAutoFollow(_ enabled: Bool) {
    guard !sealed else { return }
    autoFollow = enabled
  }

  @discardableResult
  func replaceScope(
    _ scope: ViewerExplorerScope,
    materialization: ViewerExplorerMaterializationSnapshot
  ) throws -> ViewerExplorerPresentationToken {
    guard !sealed else { return currentToken }
    let compiled = try ViewerExplorerScopeCompiler.compile(
      scope: scope,
      materialization: materialization
    )
    incrementPresentationGeneration()
    explorerScope = scope
    materializationSnapshot = materialization
    compiledInputs = compiled
    switch scope.source {
    case .current(let runtimeLogicalID):
      selectedRecordingIdentity = .current(runtimeLogicalID: runtimeLogicalID)
    case .historical(let recordingID, let logicalID):
      selectedRecordingIdentity = .durable(rowID: recordingID, logicalID: logicalID)
    }
    switch scope.devices {
    case .all:
      selectedDeviceLogicalIDs = []
    case .selected(let logicalIDs):
      selectedDeviceLogicalIDs = logicalIDs
    }
    reconcileRecordingSelection()
    reconcileDeviceSelection()
    clearTimelinePresentation()
    return currentToken
  }

  @discardableResult
  func replaceMaterialization(
    _ materialization: ViewerExplorerMaterializationSnapshot
  ) throws -> ViewerExplorerPresentationToken? {
    guard !sealed, let explorerScope else { return nil }
    guard materializationSnapshot != materialization else { return currentToken }
    let compiled = try ViewerExplorerScopeCompiler.compile(
      scope: explorerScope,
      materialization: materialization
    )
    incrementPresentationGeneration()
    materializationSnapshot = materialization
    compiledInputs = compiled
    clearTimelinePresentation()
    return currentToken
  }

  @discardableResult
  func applyRecordingPage(
    _ page: ViewerRecordingCatalogPage,
    placement: ViewerExplorerPagePlacement,
    token: ViewerExplorerPresentationToken
  ) -> Bool {
    guard acceptsSelection(token), page.rows.count <= Self.maximumCatalogPageRows else {
      return false
    }
    guard
      recordingWindow.apply(
        page.rows,
        leadingCursor: page.newerCursor,
        trailingCursor: page.olderCursor,
        placement: placement
      ) != nil
    else { return false }
    reconcileRecordingSelection()
    return true
  }

  @discardableResult
  func applyDevicePage(
    _ page: ViewerDeviceCatalogPage,
    placement: ViewerExplorerPagePlacement,
    token: ViewerExplorerPresentationToken
  ) -> Bool {
    guard acceptsSelection(token), page.rows.count <= Self.maximumCatalogPageRows else {
      return false
    }
    guard
      deviceWindow.apply(
        page.rows,
        leadingCursor: page.newerCursor,
        trailingCursor: page.olderCursor,
        placement: placement
      ) != nil
    else { return false }
    reconcileDeviceSelection()
    return true
  }

  @discardableResult
  func applyEventPage(
    _ page: ViewerEventPage,
    placement: ViewerExplorerPagePlacement,
    token: ViewerExplorerPresentationToken
  ) -> Bool {
    applyTimelinePage(page, placement: placement, token: token) != nil
  }

  @discardableResult
  func applyTimelinePage(
    _ page: ViewerEventPage,
    placement: ViewerExplorerPagePlacement,
    token: ViewerExplorerPresentationToken
  ) -> ViewerExplorerTimelineMutation? {
    guard accepts(token), page.rows.count <= Self.maximumEventPageRows,
      let mutation = eventWindow.applyDurablePage(
        page,
        placement: placement,
        scope: explorerScope,
        materialization: materializationSnapshot
      )
    else { return nil }
    reconcileEventSelection(after: mutation)
    reconcileDurableVisibilities(mutation.durableVisibilities)
    return mutation
  }

  @discardableResult
  func applyLiveEvaluation(
    snapshot: ViewerLiveProjectionSnapshot,
    output: ViewerLiveEvaluationOutput,
    token: ViewerExplorerPresentationToken
  ) throws -> ViewerExplorerTimelineMutation? {
    guard accepts(token), output.snapshotGeneration == snapshot.generation,
      case .current(let currentRuntimeLogicalID) = explorerScope?.source,
      currentRuntimeLogicalID == runtimeLogicalID,
      compiledInputs?.liveRequest != nil
    else { return nil }
    let transientRows = try ViewerExplorerTimelineReconciler.transientRows(
      snapshot: snapshot,
      matchedKeys: output.matchedKeys,
      runtimeLogicalID: runtimeLogicalID
    )
    guard let mutation = eventWindow.applyLiveRows(transientRows, autoFollow: autoFollow) else {
      return nil
    }
    liveGapLane = ViewerExplorerLiveGapLane(
      snapshotGeneration: snapshot.generation,
      gaps: snapshot.gaps
    )
    liveEvaluationState = .complete(output.transientExclusion)
    reconcileEventSelection(after: mutation)
    reconcileDurableVisibilities(mutation.durableVisibilities)
    if autoFollow { scrollAnchor = eventWindow.lastIdentity() }
    return mutation
  }

  @discardableResult
  func applyLiveRefineRequired(
    snapshot: ViewerLiveProjectionSnapshot,
    token: ViewerExplorerPresentationToken
  ) -> Bool {
    guard accepts(token), snapshot.runtimeLogicalID == runtimeLogicalID else { return false }
    liveGapLane = ViewerExplorerLiveGapLane(
      snapshotGeneration: snapshot.generation,
      gaps: snapshot.gaps
    )
    liveEvaluationState = .refineRequired
    return true
  }

  @discardableResult
  func applyGapPage(
    _ page: ViewerGapPage,
    placement: ViewerExplorerPagePlacement,
    token: ViewerExplorerPresentationToken
  ) -> Bool {
    guard accepts(token), page.rows.count <= Self.maximumGapPageRows else { return false }
    return gapWindow.apply(
      page.rows,
      leadingCursor: page.previousCursor,
      trailingCursor: page.nextCursor,
      placement: placement
    ) != nil
  }

  @discardableResult
  func selectRecording(_ identity: ViewerExplorerRecordingIdentity?) -> Bool {
    guard !sealed else { return false }
    selectedRecordingIdentity = identity
    reconcileRecordingSelection()
    return true
  }

  @discardableResult
  func selectDevices(_ logicalIDs: [UUID]) -> Bool {
    guard !sealed, (0...Self.maximumSelectedDevices).contains(logicalIDs.count),
      Set(logicalIDs).count == logicalIDs.count
    else { return false }
    selectedDeviceLogicalIDs = logicalIDs
    reconcileDeviceSelection()
    return true
  }

  @discardableResult
  func selectEvent(_ identity: ViewerExplorerEventIdentity?, scrollToSelection: Bool = false)
    -> Bool
  {
    guard !sealed else { return false }
    if selectedEventIdentity != identity { selectedEventDetail = nil }
    selectedEventIdentity = identity
    selectedEventNeedsReload = identity.map { !eventWindow.contains($0) } ?? false
    if scrollToSelection { scrollAnchor = identity }
    return true
  }

  @discardableResult
  func applySelectedDetail(
    _ detail: ViewerStoredEventDetail?,
    identity: ViewerExplorerEventIdentity,
    token: ViewerExplorerPresentationToken
  ) -> Bool {
    // Pausing freezes timeline replacement, but operators must still be able to inspect the
    // already-visible snapshot. The generation check continues to reject stale detail work.
    guard acceptsSelection(token), selectedEventIdentity == identity else { return false }
    if let detail {
      guard identity == .durable(rowID: detail.summary.rowID) else { return false }
    }
    selectedEventDetail = detail
    return true
  }

  func setScrollAnchor(_ identity: ViewerExplorerEventIdentity?) {
    guard !sealed else { return }
    scrollAnchor = identity
  }

  func noteManualScroll(_ identity: ViewerExplorerEventIdentity?) {
    guard !sealed else { return }
    autoFollow = false
    scrollAnchor = identity
  }

  @discardableResult
  func beginTimelineReplacement() -> ViewerExplorerPresentationToken {
    guard !sealed else { return currentToken }
    incrementPresentationGeneration()
    selectedEventDetail = nil
    selectedEventNeedsReload = selectedEventIdentity != nil
    liveEvaluationState = nil
    return currentToken
  }

  @discardableResult
  func prepareFreshTraversal(
    token: ViewerExplorerPresentationToken,
    jumpsToLatest: Bool
  ) -> Bool {
    guard accepts(token) else { return false }
    eventWindow.clear()
    gapWindow.clear()
    selectedEventDetail = nil
    selectedEventNeedsReload = selectedEventIdentity != nil
    liveGapLane = nil
    liveEvaluationState = nil
    if jumpsToLatest {
      autoFollow = true
      scrollAnchor = nil
    }
    return true
  }

  func finishFreshTraversal(token: ViewerExplorerPresentationToken) {
    guard accepts(token) else { return }
    if let selectedEventIdentity, !eventWindow.contains(selectedEventIdentity) {
      self.selectedEventIdentity = nil
      selectedEventDetail = nil
      selectedEventNeedsReload = false
    }
    if autoFollow {
      scrollAnchor = eventWindow.lastIdentity()
    } else if let scrollAnchor, !eventWindow.contains(scrollAnchor) {
      self.scrollAnchor = nil
    }
  }

  @discardableResult
  func noteRefresh(
    changeToken: String?,
    durableUpperRowID: Int64?,
    transientChangeIncrement: UInt64 = 0,
    transientGapIncrement: UInt64 = 0
  ) -> Bool {
    guard !sealed,
      changeToken.map({ !$0.isEmpty && $0.utf8.count <= Self.maximumChangeTokenBytes }) ?? true,
      durableUpperRowID.map({ $0 >= 0 }) ?? true
    else { return false }
    if let changeToken { pendingChangeToken = changeToken }
    if let durableUpperRowID {
      pendingDurableUpperRowID = max(pendingDurableUpperRowID ?? 0, durableUpperRowID)
    }
    pendingTransientChangeCount = Self.saturatingAdd(
      pendingTransientChangeCount,
      transientChangeIncrement
    )
    pendingTransientGapCount = Self.saturatingAdd(
      pendingTransientGapCount,
      transientGapIncrement
    )
    refreshDirty = true
    scheduleRefreshIfNeeded()
    return true
  }

  func setRefreshHandler(_ handler: @escaping RefreshHandler) {
    guard !sealed else { return }
    refreshHandler = handler
  }

  func sealAndClear() {
    guard !sealed else { return }
    incrementPresentationGeneration()
    sealed = true
    isPaused = true
    autoFollow = false
    wakeScheduled = false
    wakeToken = Self.saturatingIncrement(wakeToken)
    refreshHandler = { _, _ in }
    clearPendingRefresh()
    clearResidentPresentation()
  }

  nonisolated var description: String { "ViewerEventExplorerModel(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private func accepts(_ token: ViewerExplorerPresentationToken) -> Bool {
    !sealed && !isPaused && token == currentToken
  }

  private func acceptsSelection(_ token: ViewerExplorerPresentationToken) -> Bool {
    !sealed && token == currentToken
  }

  private func incrementPresentationGeneration() {
    presentationGeneration = Self.saturatingIncrement(presentationGeneration)
  }

  private func clearResidentPresentation() {
    recordingWindow.clear()
    deviceWindow.clear()
    eventWindow.clear()
    gapWindow.clear()
    selectedRecordingIdentity = nil
    selectedRecordingNeedsReload = false
    selectedDeviceLogicalIDs.removeAll(keepingCapacity: false)
    selectedDeviceLogicalIDsNeedingReload.removeAll(keepingCapacity: false)
    selectedEventIdentity = nil
    selectedEventDetail = nil
    selectedEventNeedsReload = false
    scrollAnchor = nil
    explorerScope = nil
    materializationSnapshot = nil
    compiledInputs = nil
    liveGapLane = nil
    liveEvaluationState = nil
  }

  private func clearTimelinePresentation() {
    eventWindow.clear()
    gapWindow.clear()
    selectedEventIdentity = nil
    selectedEventDetail = nil
    selectedEventNeedsReload = false
    scrollAnchor = nil
    liveGapLane = nil
    liveEvaluationState = nil
  }

  private func reconcileEventSelection(after mutation: ViewerExplorerTimelineMutation) {
    if let selectedEventIdentity {
      selectedEventNeedsReload = !eventWindow.contains(selectedEventIdentity)
    }
    guard let scrollAnchor, !eventWindow.contains(scrollAnchor) else { return }
    switch mutation.evictedEdge {
    case .leading:
      self.scrollAnchor = eventWindow.firstIdentity()
    case .trailing:
      self.scrollAnchor = eventWindow.lastIdentity()
    case nil:
      self.scrollAnchor = nil
    }
  }

  private func reconcileDurableVisibilities(
    _ visibilities: [ViewerExplorerDurableVisibility]
  ) {
    guard !visibilities.isEmpty else { return }
    let rowIDsByKey = Dictionary(
      uniqueKeysWithValues: visibilities.map { ($0.key, $0.durableRowID) }
    )
    if case .transient(let key) = selectedEventIdentity,
      let rowID = rowIDsByKey[key]
    {
      selectedEventIdentity = .durable(rowID: rowID)
      selectedEventNeedsReload = !eventWindow.contains(.durable(rowID: rowID))
    }
    if case .transient(let key) = scrollAnchor, let rowID = rowIDsByKey[key] {
      scrollAnchor = .durable(rowID: rowID)
    }
  }

  private func reconcileRecordingSelection() {
    guard let selectedRecordingIdentity else {
      selectedRecordingNeedsReload = false
      return
    }
    switch selectedRecordingIdentity {
    case .current:
      selectedRecordingNeedsReload = false
    case .durable(let rowID, _):
      selectedRecordingNeedsReload = !recordingWindow.contains(rowID)
    }
  }

  private func reconcileDeviceSelection() {
    let resident = Set(deviceWindow.rows.map(\.logicalID))
    selectedDeviceLogicalIDsNeedingReload = Set(selectedDeviceLogicalIDs).subtracting(resident)
  }

  private func scheduleRefreshIfNeeded() {
    guard refreshDirty, !isPaused, !sealed, !wakeScheduled else { return }
    let now = refreshScheduler.now()
    let delay: UInt64
    if let lastWakeNanoseconds {
      let (deadline, overflow) = lastWakeNanoseconds.addingReportingOverflow(
        Self.refreshIntervalNanoseconds
      )
      delay = overflow || deadline <= now ? 0 : deadline - now
    } else {
      delay = 0
    }
    wakeToken = Self.saturatingIncrement(wakeToken)
    let token = wakeToken
    wakeScheduled = true
    refreshScheduleCount = Self.saturatingIncrement(refreshScheduleCount)
    refreshScheduler.scheduleOnMain(delay) { [weak self] in
      Task { @MainActor in self?.deliverRefresh(token: token) }
    }
  }

  private func deliverRefresh(token: UInt64) {
    guard wakeScheduled, token == wakeToken else { return }
    wakeScheduled = false
    guard refreshDirty, !isPaused, !sealed else { return }
    let signal = ViewerExplorerRefreshSignal(
      latestChangeToken: pendingChangeToken,
      durableUpperRowID: pendingDurableUpperRowID,
      transientChangeCount: pendingTransientChangeCount,
      transientGapCount: pendingTransientGapCount
    )
    refreshDirty = false
    pendingTransientChangeCount = 0
    pendingTransientGapCount = 0
    lastWakeNanoseconds = refreshScheduler.now()
    refreshDeliveryCount = Self.saturatingIncrement(refreshDeliveryCount)
    refreshHandler(currentToken, signal)
  }

  private func clearPendingRefresh() {
    pendingChangeToken = nil
    pendingDurableUpperRowID = nil
    pendingTransientChangeCount = 0
    pendingTransientGapCount = 0
    refreshDirty = false
  }

  private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? UInt64.max : value + 1
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : sum
  }
}

extension ViewerExplorerPresentationToken: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerPresentationToken(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExplorerRefreshSignal: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerRefreshSignal(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "transientChangeCount": transientChangeCount,
        "transientGapCount": transientGapCount,
      ],
      displayStyle: .struct
    )
  }
}

extension ViewerExplorerResidentWindow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerResidentWindow(rows: \(rows.count), redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["rowCount": rows.count], displayStyle: .struct)
  }
}
