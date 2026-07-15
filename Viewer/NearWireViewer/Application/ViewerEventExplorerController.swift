import Combine
import Foundation

typealias ViewerExportDestinationSelectionCancellation = @MainActor () -> Void
typealias ViewerExportDestinationSelectionStarter =
  @MainActor (@escaping @Sendable (URL?) -> Void) -> ViewerExportDestinationSelectionCancellation

enum ViewerExplorerLoadState: Equatable, Sendable {
  case idle
  case loading
  case ready
  case empty
  case failed(ViewerExplorerFailure)
}

enum ViewerExplorerInspectorState: Equatable, Sendable {
  case empty
  case loading
  case ready
  case failed(ViewerExplorerFailure)
}

struct ViewerExplorerDevicePresentationRow: Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let subtitle: String
  let state: String
  let hasGap: Bool
  let hasDrop: Bool
  let isMaterialized: Bool
}

struct ViewerExplorerTimelinePresentationRow: Identifiable, Equatable, Sendable {
  let id: ViewerExplorerEventIdentity
  let eventType: String
  let contentSummary: String
  let viewerWallMilliseconds: Int64
  let disposition: String?
  let hasGap: Bool
  let hasDrop: Bool
  let hasPresentationConflict: Bool
  let sessionEnded: Bool
}

enum ViewerExplorerSearchMode: String, CaseIterable, Equatable, Sendable {
  case literal
}

enum ViewerExplorerEventTypeMode: String, CaseIterable, Equatable, Sendable {
  case exact
  case prefix
}

enum ViewerExplorerJSONFilterMode: String, CaseIterable, Equatable, Sendable {
  case none
  case exists
  case equals
  case stringContains
}

enum ViewerExplorerJSONScalarKind: String, CaseIterable, Equatable, Sendable {
  case string
  case integer
  case real
  case boolean
  case null
}

enum ViewerExportMode: String, CaseIterable, Equatable, Sendable {
  case completeSession
}

enum ViewerExportPresentationState: Equatable, Sendable {
  case idle
  case preparing(ViewerExportMode)
  case disclosure(ViewerExportMode, eventCount: Int64, ViewerExportDisclosure)
  case exporting(eventCount: Int64)
  case cancelling(eventCount: Int64)
  case completed(eventCount: Int64)
  case cancelled
  case failed(ViewerExplorerFailure)
}

enum ViewerWorkspaceOperationState: Equatable, Sendable {
  case idle
  case selectingImport
  case clearing
  case clearCompleted
  case importing
  case importCompleted
  case failed(ViewerWorkspaceMutationFailure)
}

enum ViewerExplorerFilterTextField: Equatable, Sendable {
  case search
  case eventType
  case applicationIdentifier
  case applicationVersion
  case jsonPath
  case jsonComparison
}

struct ViewerExplorerFilterDraft: Sendable {
  private(set) var operatorText = ViewerExplorerOperatorTextBuffers()
  private(set) var eventType = ViewerIncrementalTextBuffer(maximumUTF8Bytes: 128)
  private(set) var applicationIdentifier = ViewerIncrementalTextBuffer(maximumUTF8Bytes: 512)
  private(set) var applicationVersion = ViewerIncrementalTextBuffer(maximumUTF8Bytes: 256)

  var searchMode: ViewerExplorerSearchMode = .literal
  var eventTypeMode: ViewerExplorerEventTypeMode = .exact
  var directions: Set<String> = []
  var priorities: Set<String> = []
  var fromDate: Date?
  var throughDate: Date?
  var jsonMode: ViewerExplorerJSONFilterMode = .none
  var jsonScalarKind: ViewerExplorerJSONScalarKind = .string
  var requiresGap = false
  var requiresDrop = false
  var requiresTerminalDisposition = false

  var searchText: String { operatorText.search.value }
  var eventTypeText: String { eventType.value }
  var applicationIdentifierText: String { applicationIdentifier.value }
  var applicationVersionText: String { applicationVersion.value }
  var jsonPathText: String { operatorText.jsonPath.value }
  var jsonComparisonText: String { operatorText.jsonComparison.value }

  var activePredicateCount: Int {
    (searchText.isEmpty ? 0 : 1)
      + (eventTypeText.isEmpty ? 0 : 1)
      + (applicationIdentifierText.isEmpty ? 0 : 1)
      + (applicationVersionText.isEmpty ? 0 : 1)
      + (directions.isEmpty ? 0 : 1)
      + (priorities.isEmpty ? 0 : 1)
      + ((fromDate == nil && throughDate == nil) ? 0 : 1)
      + (jsonMode == .none ? 0 : 1)
      + (requiresGap ? 1 : 0)
      + (requiresDrop ? 1 : 0)
      + (requiresTerminalDisposition ? 1 : 0)
  }

  @discardableResult
  mutating func replaceText(
    _ field: ViewerExplorerFilterTextField,
    range: NSRange,
    replacement: String
  ) -> ViewerTextEditResult {
    switch field {
    case .search:
      return operatorText.replaceCharacters(field: .search, range: range, replacement: replacement)
    case .eventType:
      return eventType.replaceCharacters(in: range, with: replacement)
    case .applicationIdentifier:
      return applicationIdentifier.replaceCharacters(in: range, with: replacement)
    case .applicationVersion:
      return applicationVersion.replaceCharacters(in: range, with: replacement)
    case .jsonPath:
      return operatorText.replaceCharacters(
        field: .jsonPath,
        range: range,
        replacement: replacement
      )
    case .jsonComparison:
      return operatorText.replaceCharacters(
        field: .jsonComparison,
        range: range,
        replacement: replacement
      )
    }
  }

  func makeFilter() throws -> ViewerExplorerFilter {
    var predicates: [ViewerEventPredicate] = []
    if !searchText.isEmpty { predicates.append(.contentContains(searchText)) }
    if !eventTypeText.isEmpty {
      predicates.append(
        eventTypeMode == .exact
          ? .eventTypeEquals(eventTypeText) : .eventTypePrefix(eventTypeText)
      )
    }
    if !applicationIdentifierText.isEmpty {
      predicates.append(.applicationIdentifiers([applicationIdentifierText]))
    }
    if !applicationVersionText.isEmpty {
      predicates.append(.applicationVersions([applicationVersionText]))
    }
    if !directions.isEmpty { predicates.append(.directions(directions.sorted())) }
    if !priorities.isEmpty { predicates.append(.priorities(priorities.sorted())) }
    if fromDate != nil || throughDate != nil {
      predicates.append(
        .wallTime(
          from: try fromDate.map(Self.wallMilliseconds),
          through: try throughDate.map(Self.wallMilliseconds)
        )
      )
    }
    switch jsonMode {
    case .none:
      break
    case .exists:
      guard !jsonPathText.isEmpty else { throw ViewerExplorerScopeError.invalidFilter }
      predicates.append(.jsonExists(path: jsonPathText))
    case .equals:
      guard !jsonPathText.isEmpty else { throw ViewerExplorerScopeError.invalidFilter }
      predicates.append(.json(path: jsonPathText, equals: try scalar()))
    case .stringContains:
      guard !jsonPathText.isEmpty, !jsonComparisonText.isEmpty else {
        throw ViewerExplorerScopeError.invalidFilter
      }
      predicates.append(.jsonStringContains(path: jsonPathText, value: jsonComparisonText))
    }
    if requiresGap { predicates.append(.hasGap) }
    if requiresDrop { predicates.append(.hasDrop) }
    if requiresTerminalDisposition { predicates.append(.hasTerminalDisposition) }
    return try ViewerExplorerFilter(predicates: predicates)
  }

  private func scalar() throws -> ViewerQueryScalar {
    switch jsonScalarKind {
    case .string:
      return .string(jsonComparisonText)
    case .integer:
      guard let value = Int64(jsonComparisonText) else {
        throw ViewerExplorerScopeError.invalidFilter
      }
      return .integer(value)
    case .real:
      guard let value = Double(jsonComparisonText), value.isFinite else {
        throw ViewerExplorerScopeError.invalidFilter
      }
      return .real(value)
    case .boolean:
      switch jsonComparisonText.lowercased() {
      case "true": return .boolean(true)
      case "false": return .boolean(false)
      default: throw ViewerExplorerScopeError.invalidFilter
      }
    case .null:
      guard jsonComparisonText.isEmpty else { throw ViewerExplorerScopeError.invalidFilter }
      return .null
    }
  }

  private static func wallMilliseconds(_ date: Date) throws -> Int64 {
    let value = (date.timeIntervalSince1970 * 1_000).rounded()
    guard value.isFinite, let milliseconds = Int64(exactly: value) else {
      throw ViewerExplorerScopeError.invalidFilter
    }
    return milliseconds
  }
}

@MainActor
final class ViewerEventExplorerController: ObservableObject, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  typealias AnalysisSelectionHandler = @MainActor @Sendable () -> Void
  typealias AnalysisRefreshHandler = @MainActor @Sendable () -> Void

  private struct EvaluationDelivery: Sendable {
    let id: UUID
    let reason: ViewerExplorerTraversalReason
    let snapshot: ViewerLiveProjectionSnapshot
    let result: ViewerLiveEvaluationResult
  }

  @Published private(set) var revision: UInt64 = 0
  private(set) var inspectorState: ViewerExplorerInspectorState = .empty
  private(set) var traversalState: ViewerExplorerTraversalState = .idle
  private(set) var timelinePageFailure: ViewerExplorerFailure?
  private(set) var filterDraft = ViewerExplorerFilterDraft()
  private(set) var filterValidationMessage: String?
  private(set) var rawChunkIndex = 0
  private(set) var rawChunk: ViewerRawJSONChunk?
  private(set) var previewRawChunk: ViewerRawJSONChunk?
  private(set) var exportState: ViewerExportPresentationState = .idle
  private(set) var workspaceOperationState: ViewerWorkspaceOperationState = .idle

  let inspector: ViewerEventInspectorModel

  private let runtimeLogicalID: UUID
  private let live: any ViewerLiveObservationProviding
  private let workspaceControl: any ViewerWorkspaceSessionControlling
  private let transfer: ViewerMemorySessionTransferService?
  private let claimWorkspaceMutation:
    @MainActor (ViewerWorkspaceMutationKind) -> ViewerAdmissionWorkspaceMutationLease?
  private let rendererService: ViewerRendererPreparationService
  private let evaluator: ViewerLiveEventEvaluator
  private let evaluationQueue: DispatchQueue
  private let evaluationTracker = ViewerAsyncWorkTracker()
  private let rendererTracker = ViewerAsyncWorkTracker()

  private var rows: [ViewerExplorerMemoryEventRow] = []
  private var selectedEventIdentity: ViewerExplorerEventIdentity?
  private var selectedDevices: [UUID] = []
  private var sessionSnapshots: [ViewerSessionSnapshot] = []
  private var evaluationState: ViewerExplorerLiveEvaluationState?
  private var memoryGapLane: ViewerExplorerMemoryGapLane?
  private var activeEvaluationID: UUID?
  private var evaluationCancellation: ViewerLiveEvaluationCancellation?
  private var activeRendererID: UUID?
  private var activeExportToken: ViewerOperationToken?
  private var activeExportOperationID: UUID?
  private var preparedExportTicket: ViewerMemorySessionExportTicket?
  private var exportDestinationCancellation: ViewerExportDestinationSelectionCancellation?
  private var workspaceMutationLease: ViewerAdmissionWorkspaceMutationLease?
  private var analysisSelectionHandler: AnalysisSelectionHandler = {}
  private var analysisRefreshHandler: AnalysisRefreshHandler = {}
  private var isPausedValue = false
  private var autoFollowValue = true
  private var started = false
  private var sealed = false
  private var cleanupTask: Task<Void, Never>?

  init(
    inputs: ViewerRuntimeExplorerInputs,
    rendererService: ViewerRendererPreparationService = ViewerRendererPreparationService(),
    evaluator: ViewerLiveEventEvaluator = ViewerLiveEventEvaluator(),
    claimWorkspaceMutation:
      @escaping @MainActor (ViewerWorkspaceMutationKind) ->
      ViewerAdmissionWorkspaceMutationLease? = { _ in .unmanagedForTesting() }
  ) {
    runtimeLogicalID = inputs.runtimeLogicalID
    live = inputs.liveObservations
    workspaceControl = inputs.workspaceControl
    transfer = inputs.memorySessionTransfer
    inspector = ViewerEventInspectorModel(runtimeLogicalID: inputs.runtimeLogicalID)
    self.rendererService = rendererService
    self.evaluator = evaluator
    self.claimWorkspaceMutation = claimWorkspaceMutation
    evaluationQueue = DispatchQueue(
      label: "com.nearwire.viewer.memory-event-evaluation.\(inputs.runtimeLogicalID.uuidString)",
      qos: .userInitiated
    )
  }

  var deviceRows: [ViewerExplorerDevicePresentationRow] {
    let snapshot = live.snapshot()
    let eventConnections = Set(snapshot.events.map { $0.observation.key.connectionID })
    var values: [UUID: ViewerExplorerDevicePresentationRow] = [:]
    for session in snapshot.sessions {
      values[session.connectionID] = ViewerExplorerDevicePresentationRow(
        id: session.connectionID,
        title: session.metadata.nickname ?? session.metadata.displayName,
        subtitle: session.metadata.installationAlias,
        state: session.isImported
          ? "offline" : (session.endedWallMilliseconds == nil ? "active" : "recent"),
        hasGap: false,
        hasDrop: session.positiveDropCount > 0,
        isMaterialized: eventConnections.contains(session.connectionID)
      )
    }
    for session in sessionSnapshots {
      guard let connectionID = session.connectionID, values[connectionID] == nil else { continue }
      values[connectionID] = ViewerExplorerDevicePresentationRow(
        id: connectionID,
        title: session.title,
        subtitle: session.installationAlias,
        state: session.state.rawValue,
        hasGap: false,
        hasDrop: session.droppedEvents > 0 || session.remoteDroppedEvents > 0,
        isMaterialized: false
      )
    }
    return values.values.sorted {
      $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title < $1.title
    }
  }

  var selectedDeviceIDs: Set<UUID> { Set(selectedDevices) }
  var usesAllDevices: Bool { selectedDevices.isEmpty }
  var timelineRows: [ViewerExplorerTimelinePresentationRow] {
    rows.map {
      ViewerExplorerTimelinePresentationRow(
        id: .memory($0.key),
        eventType: $0.eventType,
        contentSummary: $0.contentSummary,
        viewerWallMilliseconds: $0.viewerWallMilliseconds,
        disposition: $0.disposition,
        hasGap: $0.hasGap,
        hasDrop: $0.hasDrop,
        hasPresentationConflict: $0.hasPresentationConflict,
        sessionEnded: $0.sessionEnded
      )
    }
  }
  var selectedEventID: ViewerExplorerEventIdentity? { selectedEventIdentity }
  var isPaused: Bool { isPausedValue }
  var autoFollow: Bool { autoFollowValue }
  var liveGapLane: ViewerExplorerMemoryGapLane? { memoryGapLane }
  var rendererPreparation: ViewerRendererPreparation? { inspector.preparation }
  var inspectorMetadata: ViewerInspectorEventMetadata? { inspector.canonicalBuffer?.metadata }
  var inspectorContentByteCount: Int { inspector.canonicalBuffer?.contentByteCount ?? 0 }
  var activeFilterCount: Int { filterDraft.activePredicateCount }
  var liveEvaluationGuidance: String? {
    switch evaluationState {
    case .complete(let exclusion): return exclusion?.guidance
    case .refineRequired: return ViewerLiveEvaluationResult.refineGuidance
    case nil: return nil
    }
  }
  var hasOlderEvents: Bool { false }
  var hasNewerEvents: Bool { false }
  var canClearCurrentSession: Bool { !sealed && workspaceMutationLease == nil }
  var canExportCurrentSession: Bool { !sealed && transfer != nil }
  var canImportCurrentSession: Bool {
    !sealed && workspaceMutationLease == nil
      && !sessionSnapshots.contains { $0.state != .recent }
  }

  func start() {
    guard !started, !sealed else { return }
    started = true
    live.setRefreshHandler { [weak self] _ in
      Task { @MainActor in
        guard let self, !self.sealed, !self.isPausedValue else { return }
        self.refresh(reason: .refresh)
        self.analysisRefreshHandler()
      }
    }
    refresh(reason: .initialLoad)
  }

  func updateSessionSnapshots(_ snapshots: [ViewerSessionSnapshot]) {
    guard !sealed, sessionSnapshots != snapshots else { return }
    sessionSnapshots = snapshots
    let liveSessions = live.snapshot().sessions
    selectedDevices.removeAll { id in
      !snapshots.contains { $0.connectionID == id }
        && !liveSessions.contains { $0.connectionID == id }
    }
    publish()
  }

  func selectAllDevices() {
    guard !sealed, !selectedDevices.isEmpty else { return }
    selectedDevices.removeAll()
    refresh(reason: .deviceSelection)
    analysisSelectionHandler()
  }

  func toggleDevice(_ id: UUID) {
    guard !sealed else { return }
    if let index = selectedDevices.firstIndex(of: id) {
      selectedDevices.remove(at: index)
    } else {
      guard selectedDevices.count < ViewerExplorerLimits.maximumSelectedDevices else {
        filterValidationMessage = "Select at most 16 devices."
        publish()
        return
      }
      selectedDevices.append(id)
      selectedDevices.sort { $0.uuidString < $1.uuidString }
    }
    refresh(reason: .deviceSelection)
    analysisSelectionHandler()
  }

  func performanceTargetSelection(deviceID: UUID? = nil) -> ViewerPerformanceTargetSelection {
    let ids = deviceID.map { [$0] } ?? selectedDevices
    guard ids.count == 1, let connectionID = ids.first else {
      return .guidance(.selectOneDevice)
    }
    let snapshot = live.snapshot()
    guard snapshot.sessions.contains(where: { $0.connectionID == connectionID }) else {
      return .guidance(.deviceNotReady)
    }
    let retainedStart =
      snapshot.events.lazy
      .filter { $0.observation.key.connectionID == connectionID }
      .map { $0.observation.viewerMonotonicNanoseconds }
      .min() ?? 0
    guard let start = Int64(exactly: retainedStart) else {
      return .guidance(.sourceUnavailable)
    }
    do {
      return .target(
        try .memoryCurrent(
          source: .current(runtimeLogicalID: runtimeLogicalID, connectionID: connectionID),
          deviceStartMonotonicNanoseconds: start
        )
      )
    } catch {
      return .guidance(.sourceUnavailable)
    }
  }

  func replaceFilterCharacters(
    _ field: ViewerExplorerFilterTextField,
    range: NSRange,
    replacement: String
  ) -> Bool {
    guard !sealed else { return false }
    let result = filterDraft.replaceText(field, range: range, replacement: replacement)
    if case .rejected = result {
      filterValidationMessage = "The filter value is too large."
    } else {
      filterValidationMessage = nil
    }
    publish()
    return result == .applied
  }

  func updateFilterDraft(_ update: (inout ViewerExplorerFilterDraft) -> Void) {
    guard !sealed else { return }
    update(&filterDraft)
    filterValidationMessage = nil
    publish()
  }

  func applyFilter() {
    guard !sealed else { return }
    do {
      _ = try filterDraft.makeFilter()
      filterValidationMessage = nil
      refresh(reason: .filterChange)
    } catch {
      filterValidationMessage = "Check the filter values and try again."
      publish()
    }
  }

  func clearFilter() {
    guard !sealed else { return }
    filterDraft = ViewerExplorerFilterDraft()
    filterValidationMessage = nil
    refresh(reason: .filterChange)
  }

  func pauseOrResume() {
    guard !sealed else { return }
    isPausedValue.toggle()
    live.setPresentationPaused(isPausedValue)
    if isPausedValue {
      cancelEvaluation()
      traversalState = .paused
      publish()
    } else {
      refresh(reason: .resume)
    }
  }

  func jumpToLatest() {
    guard !sealed else { return }
    autoFollowValue = true
    if isPausedValue {
      isPausedValue = false
      live.setPresentationPaused(false)
    }
    refresh(reason: .jumpToLatest)
  }

  func updateTimelineTailFollowing(_ isFollowing: Bool) {
    guard !sealed, !rows.isEmpty, autoFollowValue != isFollowing else { return }
    autoFollowValue = isFollowing
    publish()
  }

  func loadOlderEvents() {}
  func loadNewerEvents() {}

  func deferEventSelection(_ identity: ViewerExplorerEventIdentity?) {
    Task { @MainActor [weak self] in self?.selectEvent(identity) }
  }

  func selectEvent(_ identity: ViewerExplorerEventIdentity?) {
    guard !sealed else { return }
    guard let identity else {
      clearInspector()
      selectedEventIdentity = nil
      publish()
      return
    }
    guard case .memory(let key) = identity,
      rows.contains(where: { $0.key == key })
    else { return }
    selectedEventIdentity = identity
    prepareInspector(for: key)
    analysisSelectionHandler()
  }

  func acceptExactReveal(_ identity: ViewerExplorerEventIdentity) async -> Bool {
    guard !sealed, case .memory(let key) = identity,
      rows.contains(where: { $0.key == key })
    else { return false }
    selectEvent(identity)
    return true
  }

  func refreshTraversalForExactReveal() -> Task<Bool, Never> {
    refresh(reason: .exactReveal)
    return Task { true }
  }

  func cancelExactRevealAndWait() -> Task<Void, Never> { Task {} }
  func deactivateForAnalysisSwitch() -> Task<Void, Never> { Task {} }
  func activateAfterAnalysisSwitch() -> Task<Void, Never> { Task {} }

  func setAnalysisSelectionHandler(_ handler: @escaping AnalysisSelectionHandler) {
    analysisSelectionHandler = handler
  }

  func setAnalysisRefreshHandler(_ handler: @escaping AnalysisRefreshHandler) {
    analysisRefreshHandler = handler
  }

  func showRawChunk(_ index: Int) {
    guard !sealed, index >= 0, let chunk = try? inspector.rawChunk(at: index) else { return }
    rawChunkIndex = index
    rawChunk = chunk
    publish()
  }

  func clearCurrentSession() {
    guard canClearCurrentSession,
      let lease = claimWorkspaceMutation(.clearEvents)
    else {
      workspaceOperationState = .failed(.busy)
      publish()
      return
    }
    workspaceMutationLease = lease
    workspaceOperationState = .clearing
    publish()
    workspaceControl.clearCurrentSession(afterCommit: {}) { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        self.workspaceMutationLease?.release()
        self.workspaceMutationLease = nil
        if result.isSuccess {
          self.resetMemoryPresentation()
          self.workspaceOperationState = .clearCompleted
          self.refresh(reason: .initialLoad)
        } else {
          self.workspaceOperationState = .failed(result.failure!)
        }
        self.publish()
      }
    }
  }

  func beginCurrentSessionImportSelection() -> Bool {
    guard canImportCurrentSession else { return false }
    workspaceOperationState = .selectingImport
    publish()
    return true
  }

  func cancelCurrentSessionImportSelection() {
    guard case .selectingImport = workspaceOperationState else { return }
    workspaceOperationState = .idle
    publish()
  }

  func importCurrentSession(from url: URL) {
    guard canImportCurrentSession,
      let lease = claimWorkspaceMutation(.importSession)
    else {
      workspaceOperationState = .failed(.busy)
      publish()
      return
    }
    workspaceMutationLease = lease
    workspaceOperationState = .importing
    publish()
    let ownsSecurityScopedAccess = url.startAccessingSecurityScopedResource()
    workspaceControl.importCurrentSession(from: url, afterCommit: {}) { [weak self] result in
      if ownsSecurityScopedAccess { url.stopAccessingSecurityScopedResource() }
      Task { @MainActor in
        guard let self else { return }
        self.workspaceMutationLease?.release()
        self.workspaceMutationLease = nil
        switch result {
        case .success:
          self.resetMemoryPresentation()
          self.workspaceOperationState = .importCompleted
          self.refresh(reason: .initialLoad)
        case .failure(let failure):
          self.workspaceOperationState = .failed(failure)
          self.publish()
        }
      }
    }
  }

  func cancelCurrentSessionImport() { workspaceControl.cancelCurrentSessionImport() }

  func clearWorkspaceOperationPresentation() {
    switch workspaceOperationState {
    case .clearCompleted, .importCompleted, .failed, .selectingImport:
      workspaceOperationState = .idle
      publish()
    case .idle, .clearing, .importing:
      break
    }
  }

  func prepareExport(_ mode: ViewerExportMode) {
    guard !sealed, let transfer else {
      exportState = .failed(.unavailable)
      publish()
      return
    }
    cancelExport(clearState: false)
    let operationID = UUID()
    activeExportOperationID = operationID
    exportState = .preparing(mode)
    publish()
    activeExportToken = transfer.prepareExport { [weak self] result in
      Task { @MainActor in
        guard let self, !self.sealed, self.activeExportOperationID == operationID else {
          if case .success(let ticket) = result { transfer.discardExport(ticket) }
          return
        }
        self.activeExportToken = nil
        switch result {
        case .success(let ticket):
          self.preparedExportTicket = ticket
          self.exportState = .disclosure(mode, eventCount: ticket.eventCount, ticket.disclosure)
        case .failure(let failure):
          self.activeExportOperationID = nil
          self.exportState = failure == .cancelled ? .cancelled : .failed(failure)
        }
        self.publish()
      }
    }
  }

  func beginExportDestinationSelection(_ start: ViewerExportDestinationSelectionStarter) {
    guard case .disclosure(_, let eventCount, _) = exportState,
      let ticket = preparedExportTicket,
      let transfer,
      let operationID = activeExportOperationID
    else { return }
    exportDestinationCancellation?()
    exportDestinationCancellation = start { [weak self] destination in
      Task { @MainActor in
        guard let self, !self.sealed, self.activeExportOperationID == operationID else { return }
        self.exportDestinationCancellation = nil
        guard let destination else { return }
        self.exportState = .exporting(eventCount: eventCount)
        self.publish()
        self.activeExportToken = transfer.executeExport(ticket, to: destination) {
          [weak self] result in
          Task { @MainActor in
            guard let self, !self.sealed, self.activeExportOperationID == operationID else {
              return
            }
            self.activeExportToken = nil
            self.activeExportOperationID = nil
            self.preparedExportTicket = nil
            switch result {
            case .success: self.exportState = .completed(eventCount: eventCount)
            case .failure(let failure):
              self.exportState = failure == .cancelled ? .cancelled : .failed(failure)
            }
            self.publish()
          }
        }
      }
    }
  }

  func cancelExport(clearState: Bool = true) {
    exportDestinationCancellation?()
    exportDestinationCancellation = nil
    if clearState, let activeExportToken {
      switch exportState {
      case .exporting(let eventCount), .cancelling(let eventCount):
        transfer?.cancel(activeExportToken)
        exportState = .cancelling(eventCount: eventCount)
        publish()
        return
      case .idle, .preparing, .disclosure, .completed, .cancelled, .failed:
        break
      }
    }
    if let activeExportToken { transfer?.cancel(activeExportToken) }
    activeExportToken = nil
    activeExportOperationID = nil
    if let preparedExportTicket { transfer?.discardExport(preparedExportTicket) }
    preparedExportTicket = nil
    if clearState { exportState = .cancelled }
    publish()
  }

  func clearOperationPresentation() {
    switch exportState {
    case .idle, .preparing, .disclosure, .exporting, .cancelling:
      break
    case .completed, .cancelled, .failed:
      exportState = .idle
      publish()
    }
  }

  func sealAndClear() -> Task<Void, Never> {
    if let cleanupTask { return cleanupTask }
    sealed = true
    live.setRefreshHandler { _ in }
    live.setPresentationPaused(false)
    cancelEvaluation()
    rendererService.cancel()
    cancelExport(clearState: false)
    workspaceControl.cancelCurrentSessionImport()
    workspaceMutationLease?.release()
    workspaceMutationLease = nil
    resetMemoryPresentation()
    let evaluationWait = evaluationTracker.waitTask()
    let rendererWait = rendererTracker.waitTask()
    let rendererServiceWait = rendererService.cancelAndWait()
    let task = Task {
      async let evaluation: Void = evaluationWait.value
      async let renderer: Void = rendererWait.value
      async let service: Void = rendererServiceWait.value
      _ = await (evaluation, renderer, service)
    }
    cleanupTask = task
    return task
  }

  var pendingCleanupWorkCount: Int {
    evaluationTracker.activeCount + rendererTracker.activeCount + rendererService.pendingWorkCount
  }

  nonisolated var description: String { "ViewerEventExplorerController(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private func refresh(reason: ViewerExplorerTraversalReason) {
    guard !sealed, !isPausedValue else { return }
    let filter: ViewerExplorerFilter
    do {
      filter = try filterDraft.makeFilter()
    } catch {
      filterValidationMessage = "Check the filter values and try again."
      publish()
      return
    }
    let deviceScope: ViewerLiveDeviceScope
    do {
      deviceScope =
        selectedDevices.isEmpty
        ? .all : try ViewerLiveDeviceScope(selectedConnectionIDs: selectedDevices)
    } catch {
      filterValidationMessage = "Select at most 16 devices."
      publish()
      return
    }
    let request: ViewerLiveEvaluationRequest
    do {
      request = try ViewerLiveEvaluationRequest(
        runtimeLogicalID: runtimeLogicalID,
        deviceScope: deviceScope,
        predicates: filter.predicates
      )
    } catch {
      filterValidationMessage = "Check the filter values and try again."
      publish()
      return
    }
    cancelEvaluation()
    let id = UUID()
    let cancellation = ViewerLiveEvaluationCancellation()
    let snapshot = live.snapshot()
    activeEvaluationID = id
    evaluationCancellation = cancellation
    evaluationTracker.begin(id: id)
    if rows.isEmpty {
      traversalState = .loading(reason)
      publish()
    }
    evaluationQueue.async { [weak self, evaluationTracker] in
      guard let self else {
        evaluationTracker.complete(id)
        return
      }
      let result = self.evaluator.evaluate(
        snapshot: snapshot,
        request: request,
        isCancelled: { cancellation.isCancelled }
      )
      Task { @MainActor [weak self] in
        self?.applyEvaluation(
          EvaluationDelivery(id: id, reason: reason, snapshot: snapshot, result: result)
        )
        evaluationTracker.complete(id)
      }
    }
  }

  private func applyEvaluation(_ delivery: EvaluationDelivery) {
    guard !sealed, activeEvaluationID == delivery.id else { return }
    activeEvaluationID = nil
    evaluationCancellation = nil
    switch delivery.result {
    case .cancelled:
      return
    case .refineRequired:
      evaluationState = .refineRequired
      traversalState = rows.isEmpty ? .failed(.refineQuery) : .ready(delivery.reason)
    case .complete(let output):
      let matched = Set(output.matchedKeys)
      let successor = delivery.snapshot.events.compactMap {
        event -> ViewerExplorerMemoryEventRow? in
        matched.contains(event.observation.key) ? ViewerExplorerMemoryEventRow(event) : nil
      }
      rows = Array(successor.suffix(ViewerExplorerLimits.maximumEventRows))
      evaluationState = .complete(output.transientExclusion)
      memoryGapLane = ViewerExplorerMemoryGapLane(
        snapshotGeneration: delivery.snapshot.generation,
        gaps: delivery.snapshot.gaps
      )
      traversalState = .ready(delivery.reason)
      reconcileSelection(with: delivery.snapshot)
    }
    timelinePageFailure = nil
    publish()
  }

  private func reconcileSelection(with snapshot: ViewerLiveProjectionSnapshot) {
    guard let selectedEventIdentity, case .memory(let key) = selectedEventIdentity else { return }
    guard rows.contains(where: { $0.key == key }),
      let event = snapshot.events.first(where: { $0.observation.key == key })
    else {
      clearInspector()
      self.selectedEventIdentity = nil
      return
    }
    if inspector.selectedIdentity == selectedEventIdentity {
      do {
        let buffer = try inspector.prepare(liveEvent: event, identity: selectedEventIdentity)
        guard
          inspector.canonicalBuffer?.metadata != buffer.metadata
            || inspector.canonicalBuffer?.content != buffer.content
        else { return }
        prepareInspector(buffer: buffer, identity: selectedEventIdentity)
      } catch {
        inspectorState = .failed(.invalidRequest)
      }
    }
  }

  private func prepareInspector(for key: ViewerEventJournalKey) {
    let snapshot = live.snapshot()
    guard let event = snapshot.events.first(where: { $0.observation.key == key }) else {
      inspectorState = .failed(.unavailable)
      publish()
      return
    }
    prepareInspector(event: event, identity: .memory(key))
  }

  private func prepareInspector(
    event: ViewerLiveEventSnapshot,
    identity: ViewerExplorerEventIdentity
  ) {
    do {
      prepareInspector(
        buffer: try inspector.prepare(liveEvent: event, identity: identity),
        identity: identity
      )
    } catch {
      inspectorState = .failed(.invalidRequest)
      publish()
    }
  }

  private func prepareInspector(
    buffer: ViewerCanonicalEventDetailBuffer,
    identity: ViewerExplorerEventIdentity
  ) {
    rendererService.cancel()
    activeRendererID = nil
    let request = inspector.select(preparedLiveBuffer: buffer, identity: identity)
    inspectorState = .loading
    rawChunkIndex = 0
    rawChunk = nil
    previewRawChunk = nil
    publish()
    let id = UUID()
    activeRendererID = id
    rendererTracker.begin(id: id)
    rendererService.submit(request) { [weak self, rendererTracker] result in
      Task { @MainActor [weak self] in
        defer { rendererTracker.complete(id) }
        guard let self, !self.sealed, self.activeRendererID == id else { return }
        self.activeRendererID = nil
        guard self.inspector.apply(result) else { return }
        let firstRawChunk = try? self.inspector.rawChunk(at: 0)
        self.rawChunk = firstRawChunk
        self.previewRawChunk = firstRawChunk
        self.inspectorState = .ready
        self.publish()
      }
    }
  }

  private func clearInspector() {
    rendererService.cancel()
    activeRendererID = nil
    inspector.clear()
    inspectorState = .empty
    rawChunkIndex = 0
    rawChunk = nil
    previewRawChunk = nil
  }

  private func resetMemoryPresentation() {
    cancelEvaluation()
    rows.removeAll(keepingCapacity: false)
    memoryGapLane = nil
    evaluationState = nil
    selectedEventIdentity = nil
    clearInspector()
    traversalState = .idle
  }

  private func cancelEvaluation() {
    evaluationCancellation?.cancel()
    evaluationCancellation = nil
    activeEvaluationID = nil
  }

  private func publish() {
    revision = revision == UInt64.max ? 1 : revision + 1
  }
}

extension Result where Success == Void, Failure == ViewerWorkspaceMutationFailure {
  fileprivate var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }

  fileprivate var failure: ViewerWorkspaceMutationFailure? {
    if case .failure(let failure) = self { return failure }
    return nil
  }
}

extension ViewerExplorerDevicePresentationRow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerDevicePresentationRow(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExplorerTimelinePresentationRow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerTimelinePresentationRow(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExplorerFilterDraft: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerFilterDraft(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExportPresentationState: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExportPresentationState(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}
