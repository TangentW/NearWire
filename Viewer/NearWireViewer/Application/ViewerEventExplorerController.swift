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
  case failed(ViewerStoreExplorerFailure)
}

enum ViewerExplorerInspectorState: Equatable, Sendable {
  case empty
  case loading
  case ready
  case failed(ViewerStoreExplorerFailure)
}

enum ViewerExplorerCausalityState: Equatable, Sendable {
  case none
  case loading
  case ready(ViewerCausalityGraph)
  case recordedDataRequired
  case failed(ViewerStoreExplorerFailure)
}

struct ViewerExplorerSourcePresentationRow: Identifiable, Equatable, Sendable {
  let id: ViewerExplorerSource
  let title: String
  let startedWallMilliseconds: Int64?
  let state: String
  let isPinned: Bool
  let hasGap: Bool
  let hasDrop: Bool
  let isCurrent: Bool
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
  let deviceAlias: String
  let direction: String
  let priority: String
  let viewerWallMilliseconds: Int64
  let disposition: String?
  let contentByteCount: Int64
  let isTransient: Bool
  let hasGap: Bool
  let hasDrop: Bool
  let hasPresentationConflict: Bool
  let sessionEnded: Bool
}

enum ViewerExplorerSearchMode: String, CaseIterable, Equatable, Sendable {
  case literal
  case fullText
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

enum ViewerRecordingOperationState: Equatable, Sendable {
  case idle
  case running
  case awaitingDeleteConfirmation
  case succeeded(String)
  case failed(ViewerStoreExplorerFailure)
}

enum ViewerExportMode: String, CaseIterable, Equatable, Sendable {
  case completeRecording
  case currentFilteredResult
}

enum ViewerExportPresentationState: Equatable, Sendable {
  case idle
  case preparing(ViewerExportMode)
  case disclosure(ViewerExportMode, eventCount: Int64, ViewerExportDisclosure)
  case exporting(eventCount: Int64)
  case cancelling(eventCount: Int64)
  case completed(eventCount: Int64)
  case cancelled
  case failed(ViewerStoreExplorerFailure)
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

enum ViewerExportPresentationText {
  static let transientRowsExcluded = "Transient rows labeled Not recorded are excluded."
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
    with replacement: String
  ) -> ViewerTextEditResult {
    let length: Int
    switch field {
    case .search: length = operatorText.search.utf16Count
    case .eventType: length = eventType.utf16Count
    case .applicationIdentifier: length = applicationIdentifier.utf16Count
    case .applicationVersion: length = applicationVersion.utf16Count
    case .jsonPath: length = operatorText.jsonPath.utf16Count
    case .jsonComparison: length = operatorText.jsonComparison.utf16Count
    }
    return replaceText(
      field,
      range: NSRange(location: 0, length: length),
      replacement: replacement
    )
  }

  @discardableResult
  mutating func replaceText(
    _ field: ViewerExplorerFilterTextField,
    range: NSRange,
    replacement: String
  ) -> ViewerTextEditResult {
    switch field {
    case .search:
      return operatorText.replaceCharacters(
        field: .search,
        range: range,
        replacement: replacement
      )
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
    if !searchText.isEmpty {
      predicates.append(
        searchMode == .literal ? .contentContains(searchText) : .fullText(searchText))
    }
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

struct ViewerExplorerContentDriver: Sendable {
  typealias RecordingCompletion =
    @Sendable (Result<ViewerRecordingCatalogPage, ViewerStoreExplorerFailure>) -> Void
  typealias DeviceCompletion =
    @Sendable (Result<ViewerDeviceCatalogPage, ViewerStoreExplorerFailure>) -> Void
  typealias DeviceCatalogLoader =
    @Sendable (
      Int64, ViewerRecordingCatalogSnapshot?, ViewerDeviceCatalogCursor?,
      ViewerCatalogPageDirection, Int, @escaping DeviceCompletion
    ) -> ViewerStoreExplorerOperationToken
  typealias DeviceIdentitiesLoader =
    @Sendable (
      Int64, [UUID], ViewerDeviceCatalogSnapshot, @escaping DeviceCompletion
    ) -> ViewerStoreExplorerOperationToken
  typealias EventCompletion =
    @Sendable (Result<ViewerEventPage, ViewerStoreExplorerFailure>) -> Void
  typealias GapCompletion = @Sendable (Result<ViewerGapPage, ViewerStoreExplorerFailure>) -> Void
  typealias DetailCompletion =
    @Sendable (Result<ViewerStoredEventDetail?, ViewerStoreExplorerFailure>) -> Void
  typealias CausalityCompletion =
    @Sendable (Result<ViewerCausalityGraph, ViewerStoreExplorerFailure>) -> Void
  typealias ChangeCompletion =
    @Sendable (Result<ViewerStoreChangeSnapshot, ViewerStoreExplorerFailure>) -> Void
  typealias RecordingMutationCompletion =
    @Sendable (Result<ViewerStoreRecordingTarget, ViewerStoreExplorerFailure>) -> Void
  typealias VoidCompletion = @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  typealias DeletePreparationCompletion =
    @Sendable (Result<ViewerStoreDeleteConfirmation, ViewerStoreExplorerFailure>) -> Void
  typealias ExportPreparationCompletion =
    @Sendable (Result<ViewerStoreExportTicket, ViewerStoreExplorerFailure>) -> Void

  let loadRecordingCatalog:
    @Sendable (
      ViewerRecordingCatalogCursor?, ViewerCatalogPageDirection, Int, @escaping RecordingCompletion
    ) -> ViewerStoreExplorerOperationToken
  let loadRecordingIdentity:
    @Sendable (
      UUID, ViewerRecordingCatalogSnapshot, @escaping RecordingCompletion
    ) -> ViewerStoreExplorerOperationToken
  let loadDeviceCatalog: DeviceCatalogLoader
  let loadDeviceIdentities: DeviceIdentitiesLoader
  let loadEventPage:
    @Sendable (
      ViewerEventCursor?, ViewerStoreQueryService.Direction, Int, @escaping EventCompletion
    ) -> ViewerStoreExplorerOperationToken
  let loadGapPage:
    @Sendable (
      [Int64], ViewerGapCursor?, ViewerStoreQueryService.Direction, Int, @escaping GapCompletion
    ) -> ViewerStoreExplorerOperationToken
  let loadDetail: @Sendable (Int64, @escaping DetailCompletion) -> ViewerStoreExplorerOperationToken
  let loadCausality:
    @Sendable (Int64, @escaping CausalityCompletion) -> ViewerStoreExplorerOperationToken
  let loadChangeSnapshot:
    @Sendable (@escaping ChangeCompletion) -> ViewerStoreExplorerOperationToken
  let updateRecording:
    @Sendable (
      ViewerStoreRecordingTarget, String?, String?, Bool,
      @escaping RecordingMutationCompletion
    ) -> ViewerStoreExplorerOperationToken
  let appendAnnotation:
    @Sendable (
      ViewerStoreRecordingTarget, String, @escaping VoidCompletion
    ) -> ViewerStoreExplorerOperationToken
  let prepareDelete:
    @Sendable (
      ViewerStoreRecordingTarget, @escaping DeletePreparationCompletion
    ) -> ViewerStoreExplorerOperationToken
  let requestDelete:
    @Sendable (
      ViewerStoreDeleteConfirmation, @escaping VoidCompletion
    ) -> ViewerStoreExplorerOperationToken
  let prepareCompleteExport:
    @Sendable (
      ViewerStoreRecordingTarget, @escaping ExportPreparationCompletion
    ) -> ViewerStoreExplorerOperationToken
  let prepareFilteredExport:
    @Sendable (@escaping ExportPreparationCompletion) -> ViewerStoreExplorerOperationToken
  let executeExport:
    @Sendable (
      ViewerStoreExportTicket, URL, @escaping VoidCompletion
    ) -> ViewerStoreExplorerOperationToken
  let cancel: @Sendable (ViewerStoreExplorerOperationToken) -> Void

  init(
    gateway: ViewerStoreExplorerGateway,
    loadDeviceCatalog: DeviceCatalogLoader? = nil,
    loadDeviceIdentities: DeviceIdentitiesLoader? = nil,
    loadDetail: (
      @Sendable (Int64, @escaping DetailCompletion) -> ViewerStoreExplorerOperationToken
    )? = nil
  ) {
    loadRecordingCatalog = { cursor, direction, limit, completion in
      gateway.loadRecordingCatalog(
        cursor: cursor,
        direction: direction,
        limit: limit,
        completion: completion
      )
    }
    loadRecordingIdentity = { logicalID, snapshot, completion in
      gateway.loadRecordingIdentity(
        logicalID: logicalID,
        snapshot: snapshot,
        completion: completion
      )
    }
    self.loadDeviceCatalog =
      loadDeviceCatalog ?? {
        recordingID, recordingSnapshot, cursor, direction, limit, completion in
        gateway.loadDeviceCatalog(
          recordingID: recordingID,
          recordingSnapshot: recordingSnapshot,
          cursor: cursor,
          direction: direction,
          limit: limit,
          completion: completion
        )
      }
    self.loadDeviceIdentities =
      loadDeviceIdentities ?? {
        recordingID, logicalIDs, snapshot, completion in
        gateway.loadDeviceIdentities(
          recordingID: recordingID,
          logicalIDs: logicalIDs,
          snapshot: snapshot,
          completion: completion
        )
      }
    loadEventPage = { cursor, direction, limit, completion in
      gateway.loadPage(cursor: cursor, direction: direction, limit: limit, completion: completion)
    }
    loadGapPage = { devices, cursor, direction, limit, completion in
      gateway.loadGapPage(
        deviceSessionIDs: devices,
        cursor: cursor,
        direction: direction,
        limit: limit,
        completion: completion
      )
    }
    self.loadDetail =
      loadDetail ?? { rowID, completion in
        gateway.loadDetail(rowID: rowID, completion: completion)
      }
    loadCausality = { rowID, completion in
      gateway.loadCausality(rootRowID: rowID, completion: completion)
    }
    loadChangeSnapshot = { completion in gateway.loadChangeSnapshot(completion: completion) }
    updateRecording = { target, name, note, pinned, completion in
      gateway.updateRecording(
        target,
        name: name,
        note: note,
        pinned: pinned,
        completion: completion
      )
    }
    appendAnnotation = { target, body, completion in
      gateway.appendAnnotation(target, body: body, completion: completion)
    }
    prepareDelete = { target, completion in
      gateway.prepareDelete(target, completion: completion)
    }
    requestDelete = { confirmation, completion in
      gateway.requestDelete(confirmation, completion: completion)
    }
    prepareCompleteExport = { target, completion in
      gateway.prepareCompleteExport(target, completion: completion)
    }
    prepareFilteredExport = { completion in
      gateway.prepareFilteredExport(completion: completion)
    }
    executeExport = { ticket, destination, completion in
      gateway.executeExport(ticket, to: destination, completion: completion)
    }
    cancel = { gateway.cancel($0) }
  }
}

@MainActor
final class ViewerEventExplorerController: ObservableObject, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  typealias AnalysisSelectionHandler = @MainActor @Sendable () -> Void
  typealias AnalysisRefreshHandler = @MainActor @Sendable () -> Void
  typealias AnalysisRematerializationHandler =
    @MainActor @Sendable (Task<Void, Never>) -> Void

  private enum OperationSlot: Hashable {
    case recordings
    case devices
    case events
    case gaps
    case detail
    case causality
    case changeSnapshot
    case recordingMutation
    case deletePreparation
    case deleteExecution
    case exportPreparation
    case exportExecution
  }

  private enum StoreRematerializationResolution {
    case unresolved
    case resolved
    case recordingAbsent
  }

  private struct ActiveOperation {
    let id: UUID
    let deliveryGate: ViewerOperationDeliveryGate
    var storeToken: ViewerStoreExplorerOperationToken?
  }

  private struct OperationHandle: Sendable {
    let id: UUID
    let deliveryGate: ViewerOperationDeliveryGate
  }

  private struct RendererDelivery {
    let id: UUID
    let deliveryGate: ViewerOperationDeliveryGate
  }

  private struct RendererDeliveryValue: Sendable {
    let id: UUID
    let result: ViewerRendererPreparationResult
  }

  @MainActor
  private final class ExactRevealPreflight {
    let id: UUID
    let intentRevision: UInt64
    let identity: ViewerExplorerEventIdentity
    let completion: @MainActor @Sendable (Bool) -> Void
    var storeToken: ViewerStoreExplorerOperationToken?
    var isCancelled = false
    private var didCompleteAcceptance = false

    init(
      id: UUID,
      intentRevision: UInt64,
      identity: ViewerExplorerEventIdentity,
      completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
      self.id = id
      self.intentRevision = intentRevision
      self.identity = identity
      self.completion = completion
    }

    func completeAcceptance(_ accepted: Bool) {
      guard !didCompleteAcceptance else { return }
      didCompleteAcceptance = true
      completion(accepted)
    }
  }

  private struct ExportDestinationSelection {
    let id: UUID
    let deliveryGate: ViewerOperationDeliveryGate
    var cancellation: ViewerExportDestinationSelectionCancellation?
  }

  @Published private(set) var revision: UInt64 = 0
  private(set) var recordingsState: ViewerExplorerLoadState = .idle
  private(set) var devicesState: ViewerExplorerLoadState = .idle
  private(set) var inspectorState: ViewerExplorerInspectorState = .empty
  private(set) var causalityState: ViewerExplorerCausalityState = .none
  private(set) var timelinePageFailure: ViewerStoreExplorerFailure?
  private(set) var gapPageFailure: ViewerStoreExplorerFailure?
  private(set) var filterDraft = ViewerExplorerFilterDraft()
  private(set) var filterValidationMessage: String?
  private(set) var deviceCatalogRecordingID: Int64?
  private(set) var rawChunkIndex = 0
  private(set) var rawChunk: ViewerRawJSONChunk?
  private(set) var inspectorTreeState: ViewerJSONTreeState?
  private(set) var recordingOperationState: ViewerRecordingOperationState = .idle
  private(set) var exportState: ViewerExportPresentationState = .idle
  private(set) var workspaceOperationState: ViewerWorkspaceOperationState = .idle

  let model: ViewerEventExplorerModel
  let coordinator: ViewerEventExplorerCoordinator
  let inspector: ViewerEventInspectorModel

  private let content: ViewerExplorerContentDriver
  private let live: any ViewerLiveObservationProviding
  private let workspaceControl: any ViewerWorkspaceSessionControlling
  private let claimWorkspaceMutation:
    @MainActor (ViewerWorkspaceMutationKind) -> ViewerAdmissionWorkspaceMutationLease?
  private let rendererService: ViewerRendererPreparationService
  private let operationDeliveryClaimed: @Sendable () -> Void
  private let rendererDeliveryClaimed: @Sendable () -> Void
  private let operationTracker = ViewerAsyncWorkTracker()
  private let exactRevealTracker = ViewerAsyncWorkTracker()
  private let exportDestinationSelectionTracker = ViewerAsyncWorkTracker()
  private let storeRematerializationTracker = ViewerAsyncWorkTracker()
  private var activeOperations: [OperationSlot: ActiveOperation] = [:]
  private var exactRevealPreflights: [UUID: ExactRevealPreflight] = [:]
  private var activeExactRevealPreflightID: UUID?
  private var rendererDelivery: RendererDelivery?
  private var exportDestinationSelection: ExportDestinationSelection?
  private var recordingTargets: [Int64: ViewerStoreRecordingTarget] = [:]
  private var preparedDeleteConfirmation: ViewerStoreDeleteConfirmation?
  private var preparedExportTicket: ViewerStoreExportTicket?
  private var selectedSource: ViewerExplorerSource
  private var selectedDevices: [UUID] = []
  private var sessionSnapshots: [ViewerSessionSnapshot] = []
  private var materializationGeneration: UInt64 = 0
  private var changeSnapshotDirty = false
  private var activeStoreRematerializationID: UUID?
  private var storeRematerializationResolution: StoreRematerializationResolution = .resolved
  private(set) var changeSnapshotRequestCountForTesting = 0
  private(set) var eventPageRequestCountForTesting = 0
  private(set) var gapPageRequestCountForTesting = 0
  private var deferredSelectionRevision: UInt64 = 0
  private var pendingExactRevealIdentity: ViewerExplorerEventIdentity?
  private var started = false
  private var sealed = false
  private var cleanupTask: Task<Void, Never>?
  private var workspaceMutationLease: ViewerAdmissionWorkspaceMutationLease?
  private var analysisSelectionHandler: AnalysisSelectionHandler = {}
  private var analysisRefreshHandler: AnalysisRefreshHandler = {}
  private var analysisRematerializationHandler: AnalysisRematerializationHandler = { _ in }
  private var reconciledPresentationToken: ViewerExplorerPresentationToken?
  private lazy var rendererDeliveryPump = ViewerLatestMainActorDeliveryPump<
    RendererDeliveryValue
  > { [weak self] delivery in
    self?.handleRendererDelivery(delivery)
  }

  init(
    inputs: ViewerRuntimeExplorerInputs,
    contentDriver: ViewerExplorerContentDriver? = nil,
    rendererService: ViewerRendererPreparationService = ViewerRendererPreparationService(),
    claimWorkspaceMutation: @escaping @MainActor (ViewerWorkspaceMutationKind) ->
      ViewerAdmissionWorkspaceMutationLease? = { _ in
      .unmanagedForTesting()
    },
    operationDeliveryClaimed: @escaping @Sendable () -> Void = {},
    rendererDeliveryClaimed: @escaping @Sendable () -> Void = {}
  ) {
    model = ViewerEventExplorerModel(runtimeLogicalID: inputs.runtimeLogicalID)
    coordinator = ViewerEventExplorerCoordinator(model: model, inputs: inputs)
    inspector = ViewerEventInspectorModel(runtimeLogicalID: inputs.runtimeLogicalID)
    content = contentDriver ?? ViewerExplorerContentDriver(gateway: inputs.storeGateway)
    live = inputs.liveObservations
    workspaceControl = inputs.workspaceControl
    self.claimWorkspaceMutation = claimWorkspaceMutation
    self.rendererService = rendererService
    self.operationDeliveryClaimed = operationDeliveryClaimed
    self.rendererDeliveryClaimed = rendererDeliveryClaimed
    selectedSource = .current(runtimeLogicalID: inputs.runtimeLogicalID)
  }

  var sourceRows: [ViewerExplorerSourcePresentationRow] {
    var rows = [
      ViewerExplorerSourcePresentationRow(
        id: .current(runtimeLogicalID: model.runtimeLogicalID),
        title: "Live",
        startedWallMilliseconds: currentRecordingRow?.startedWallMilliseconds,
        state: currentRecordingRow == nil ? "Live — not recording" : "Recording",
        isPinned: currentRecordingRow?.pinned ?? false,
        hasGap: currentRecordingRow?.hasGap ?? false,
        hasDrop: currentRecordingRow?.hasDrop ?? false,
        isCurrent: true
      )
    ]
    rows.append(
      contentsOf: model.recordingRows.filter { $0.logicalID != model.runtimeLogicalID }.map { row in
        ViewerExplorerSourcePresentationRow(
          id: .historical(recordingID: row.rowID, recordingLogicalID: row.logicalID),
          title: row.name ?? "Session",
          startedWallMilliseconds: row.startedWallMilliseconds,
          state: row.state,
          isPinned: row.pinned,
          hasGap: row.hasGap,
          hasDrop: row.hasDrop,
          isCurrent: false
        )
      })
    return rows
  }

  var selectedSourceID: ViewerExplorerSource { selectedSource }

  var deviceRows: [ViewerExplorerDevicePresentationRow] {
    var values: [UUID: ViewerExplorerDevicePresentationRow] = [:]
    if storeRematerializationResolution != .unresolved,
      deviceCatalogRecordingID == selectedRecordingID
    {
      for row in model.deviceRows {
        values[row.logicalID] = ViewerExplorerDevicePresentationRow(
          id: row.logicalID,
          title: row.displayName ?? row.installationAlias,
          subtitle: "\(row.installationAlias) · \(row.connectionAlias)",
          state: row.state,
          hasGap: row.hasGap || row.partialHistory,
          hasDrop: row.hasDrop,
          isMaterialized: true
        )
      }
    }
    if case .current = selectedSource {
      for session in sessionSnapshots {
        guard let connectionID = session.connectionID else { continue }
        if values[connectionID] == nil {
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
      }
    }
    return values.values.sorted {
      $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title < $1.title
    }
  }

  var selectedDeviceIDs: Set<UUID> { Set(selectedDevices) }
  var usesAllDevices: Bool { selectedDevices.isEmpty }

  var timelineRows: [ViewerExplorerTimelinePresentationRow] {
    model.timelineRows.map { row in
      switch row {
      case .durable(let summary, _):
        return ViewerExplorerTimelinePresentationRow(
          id: row.identity,
          eventType: summary.eventType,
          deviceAlias: durableDeviceAlias(summary.deviceSessionID),
          direction: summary.direction,
          priority: summary.priority,
          viewerWallMilliseconds: summary.viewerWallMilliseconds,
          disposition: summary.resolvedDisposition,
          contentByteCount: summary.contentByteCount,
          isTransient: false,
          hasGap: false,
          hasDrop: false,
          hasPresentationConflict: false,
          sessionEnded: false
        )
      case .transient(let summary):
        return ViewerExplorerTimelinePresentationRow(
          id: row.identity,
          eventType: summary.eventType,
          deviceAlias: summary.deviceAlias,
          direction: summary.key.direction.rawValue,
          priority: summary.priority,
          viewerWallMilliseconds: summary.viewerWallMilliseconds,
          disposition: summary.resolvedDisposition,
          contentByteCount: Int64(summary.contentByteCount),
          isTransient: true,
          hasGap: summary.hasGap,
          hasDrop: summary.hasDrop,
          hasPresentationConflict: summary.hasPresentationConflict,
          sessionEnded: summary.sessionEnded
        )
      }
    }
  }

  var selectedEventID: ViewerExplorerEventIdentity? { model.selectedEventIdentity }
  var traversalState: ViewerExplorerTraversalState { coordinator.state }
  var isPaused: Bool { model.isPaused }
  var autoFollow: Bool { model.autoFollow }
  var gapRows: [ViewerGapRow] { model.gapRows }
  var liveGapLane: ViewerExplorerLiveGapLane? { model.liveGapLane }
  var rendererPreparation: ViewerRendererPreparation? { inspector.preparation }
  var inspectorMetadata: ViewerInspectorEventMetadata? { inspector.canonicalBuffer?.metadata }
  var inspectorContentByteCount: Int { inspector.canonicalBuffer?.contentByteCount ?? 0 }
  var activeFilterCount: Int { filterDraft.activePredicateCount }
  var liveEvaluationGuidance: String? {
    switch model.liveEvaluationState {
    case .complete(let exclusion): return exclusion?.guidance
    case .refineRequired: return ViewerLiveEvaluationResult.refineGuidance
    case nil: return nil
    }
  }
  var hasOlderEvents: Bool { model.eventNavigation.leadingCursor != nil }
  var hasNewerEvents: Bool { model.eventNavigation.trailingCursor != nil }
  var hasOlderRecordings: Bool { model.recordingNavigation.trailingCursor != nil }
  var hasOlderDevices: Bool { model.deviceNavigation.trailingCursor != nil }
  var hasOlderGaps: Bool { model.gapNavigation.leadingCursor != nil }
  var hasNewerGaps: Bool { model.gapNavigation.trailingCursor != nil }
  var selectedRecordingRow: ViewerRecordingCatalogRow? {
    guard storeRematerializationResolution != .unresolved else { return nil }
    guard let recordingID = selectedRecordingID else { return nil }
    return model.recordingRows.first { $0.rowID == recordingID }
  }
  var canManageSelectedRecording: Bool {
    recordingsState == .ready && selectedRecordingTarget != nil
  }
  var canExportFilteredResult: Bool {
    canManageSelectedRecording && !model.isPaused && model.compiledInputs?.durableQuery != nil
  }
  var canImportCurrentSession: Bool {
    !sessionSnapshots.contains { $0.state != .recent }
      && workspaceMutationLease == nil
      && workspaceOperationState != .clearing
      && workspaceOperationState != .selectingImport
      && workspaceOperationState != .importing
  }

  func start() {
    guard !started, !sealed else { return }
    started = true
    coordinator.setPresentationHandler { [weak self] in
      self?.coordinatorPresentationChanged()
    }
    model.setRefreshHandler { [weak self] _, _ in
      guard let self, !self.sealed else { return }
      _ = self.coordinator.refresh()
      self.publish()
    }
    live.setRefreshHandler { [weak self] _ in
      Task { @MainActor in
        guard let self, !self.sealed else { return }
        _ = self.model.noteRefresh(
          changeToken: nil,
          durableUpperRowID: nil,
          transientChangeIncrement: 1
        )
        self.publish()
        self.analysisRefreshHandler()
      }
    }
    applyScope()
    loadRecordingCatalog(placement: .replace)
  }

  func updateSessionSnapshots(_ snapshots: [ViewerSessionSnapshot]) {
    guard !sealed else { return }
    let next = Array(snapshots.prefix(64))
    guard sessionSnapshots != next else { return }
    sessionSnapshots = next
    publish()
    analysisSelectionHandler()
  }

  func setAnalysisSelectionHandler(_ handler: @escaping AnalysisSelectionHandler) {
    analysisSelectionHandler = handler
  }

  func setAnalysisRefreshHandler(_ handler: @escaping AnalysisRefreshHandler) {
    analysisRefreshHandler = handler
  }

  func setAnalysisRematerializationHandler(
    _ handler: @escaping AnalysisRematerializationHandler
  ) {
    analysisRematerializationHandler = handler
  }

  func noteStoreChanged() {
    guard !sealed else { return }
    guard activeStoreRematerializationID == nil else {
      changeSnapshotDirty = true
      return
    }
    guard activeOperations[.changeSnapshot] == nil else {
      changeSnapshotDirty = true
      return
    }
    startChangeSnapshotRequest()
  }

  /// Clears all predecessor Store-derived identity immediately and completes only after the
  /// replacement Store's change snapshot plus exact recording/device catalogs are installed.
  @discardableResult
  func rematerializeAfterStoreReplacement() -> Task<Void, Never> {
    guard !sealed else { return Task {} }
    pendingExactRevealIdentity = nil
    deferredSelectionRevision &+= 1
    let eventDeactivation = coordinator.deactivateAndReleaseTraversal()
    if let activeStoreRematerializationID {
      storeRematerializationTracker.complete(activeStoreRematerializationID)
    }
    let workID = storeRematerializationTracker.begin()
    activeStoreRematerializationID = workID
    storeRematerializationResolution = .unresolved
    changeSnapshotDirty = false
    clearStoreOperationAuthorityForReplacement()
    _ = model.beginPresentationReplacement(clearRows: true)
    recordingTargets.removeAll(keepingCapacity: true)
    deviceCatalogRecordingID = nil
    recordingsState = .loading
    devicesState = .idle
    clearInspector()
    publish()
    startChangeSnapshotRequest()
    let rematerialization = storeRematerializationTracker.waitTask()
    return Task {
      async let event: Void = eventDeactivation.value
      async let catalogs: Void = rematerialization.value
      _ = await (event, catalogs)
    }
  }

  private func clearStoreOperationAuthorityForReplacement() {
    let preservesCommittedExport: Bool
    let committedExportCount: Int64?
    switch exportState {
    case .exporting(let eventCount), .cancelling(let eventCount):
      preservesCommittedExport = true
      committedExportCount = eventCount
    default:
      preservesCommittedExport = false
      committedExportCount = nil
    }
    for slot in Array(activeOperations.keys) {
      if preservesCommittedExport, slot == .exportExecution { continue }
      cancel(slot)
    }
    cancelExportDestinationSelection()
    preparedDeleteConfirmation = nil
    preparedExportTicket = nil
    recordingOperationState = .idle
    if let committedExportCount {
      requestStoreCancellation(.exportExecution)
      exportState = .cancelling(eventCount: committedExportCount)
    } else {
      cancel(.exportExecution)
      exportState = .idle
    }
  }

  private func startChangeSnapshotRequest() {
    changeSnapshotRequestCountForTesting += 1
    let operation = begin(.changeSnapshot)
    let storeToken = content.loadChangeSnapshot { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in self?.handleChangeSnapshot(result, operationID: operation.id) }
    }
    attach(storeToken, to: .changeSnapshot, operationID: operation.id)
  }

  func selectSource(_ source: ViewerExplorerSource) {
    guard !sealed, sourceRows.contains(where: { $0.id == source }), source != selectedSource else {
      return
    }
    let changesActiveRematerialization = activeStoreRematerializationID != nil
    let startsFreshHistoricalRematerialization: Bool
    if !changesActiveRematerialization,
      storeRematerializationResolution == .unresolved,
      case .historical = source
    {
      startsFreshHistoricalRematerialization = true
    } else {
      startsFreshHistoricalRematerialization = false
    }
    if !changesActiveRematerialization { cancel(.devices) }
    cancel(.events)
    cancel(.gaps)
    clearInspector()
    selectedSource = source
    selectedDevices.removeAll(keepingCapacity: false)
    deviceCatalogRecordingID = nil
    if changesActiveRematerialization {
      switch source {
      case .current:
        completeStoreRematerializationForExplicitLiveSelection()
      case .historical:
        restartStoreRematerializationCatalogs()
        analysisSelectionHandler()
        return
      }
    }
    if startsFreshHistoricalRematerialization {
      let rematerialization = rematerializeAfterStoreReplacement()
      analysisRematerializationHandler(rematerialization)
      return
    }
    applyScope()
    if storeRematerializationResolution != .unresolved,
      let recordingID = selectedRecordingID
    {
      loadDeviceCatalog(recordingID: recordingID, placement: .replace)
    } else {
      devicesState = .empty
    }
    publish()
    analysisSelectionHandler()
  }

  func clearCurrentSession() {
    guard !sealed else { return }
    switch workspaceOperationState {
    case .clearing:
      return
    case .idle, .clearCompleted, .importCompleted, .failed:
      break
    case .selectingImport, .importing:
      return
    }
    guard workspaceMutationLease == nil, let lease = claimWorkspaceMutation(.clearEvents) else {
      workspaceOperationState = .failed(.busy)
      publish()
      return
    }
    workspaceMutationLease = lease
    workspaceOperationState = .clearing
    publish()
    workspaceControl.clearCurrentSession { [weak self] result in
      Task { @MainActor in
        guard let self, !self.sealed else { return }
        self.workspaceMutationLease?.release()
        self.workspaceMutationLease = nil
        switch result {
        case .success:
          self.workspaceOperationState = .clearCompleted
        case .failure(let failure):
          self.workspaceOperationState = .failed(failure)
        }
        self.publish()
      }
    }
  }

  @discardableResult
  func beginCurrentSessionImportSelection() -> Bool {
    guard !sealed, canImportCurrentSession else {
      workspaceOperationState = .failed(.busy)
      publish()
      return false
    }
    guard workspaceMutationLease == nil, let lease = claimWorkspaceMutation(.importSession) else {
      workspaceOperationState = .failed(.busy)
      publish()
      return false
    }
    workspaceMutationLease = lease
    workspaceOperationState = .selectingImport
    publish()
    return true
  }

  func cancelCurrentSessionImportSelection() {
    guard !sealed, workspaceOperationState == .selectingImport else { return }
    workspaceMutationLease?.release()
    workspaceMutationLease = nil
    workspaceOperationState = .idle
    publish()
  }

  func importCurrentSession(from url: URL) {
    guard !sealed, workspaceOperationState == .selectingImport,
      workspaceMutationLease != nil
    else {
      workspaceOperationState = .failed(.busy)
      publish()
      return
    }
    workspaceOperationState = .importing
    publish()
    let accessed = url.startAccessingSecurityScopedResource()
    workspaceControl.importCurrentSession(from: url) { [weak self] result in
      Task { @MainActor in
        if accessed { url.stopAccessingSecurityScopedResource() }
        guard let self, !self.sealed else { return }
        self.workspaceMutationLease?.release()
        self.workspaceMutationLease = nil
        switch result {
        case .success:
          self.workspaceOperationState = .importCompleted
        case .failure(let failure):
          self.workspaceOperationState = .failed(failure)
        }
        self.publish()
      }
    }
  }

  func cancelCurrentSessionImport() {
    guard !sealed, workspaceOperationState == .importing else { return }
    workspaceControl.cancelCurrentSessionImport()
  }

  func clearWorkspaceOperationPresentation() {
    guard !sealed, workspaceOperationState != .clearing,
      workspaceOperationState != .selectingImport,
      workspaceOperationState != .importing
    else { return }
    workspaceOperationState = .idle
    publish()
  }

  func selectAllDevices() {
    guard !sealed, !selectedDevices.isEmpty else { return }
    selectedDevices.removeAll(keepingCapacity: false)
    applyScope()
    analysisSelectionHandler()
  }

  func toggleDevice(_ logicalID: UUID) {
    guard !sealed, deviceRows.contains(where: { $0.id == logicalID }) else { return }
    if let index = selectedDevices.firstIndex(of: logicalID) {
      selectedDevices.remove(at: index)
    } else {
      guard selectedDevices.count < ViewerEventExplorerModel.maximumSelectedDevices else {
        filterValidationMessage = "Select at most 16 devices."
        publish()
        return
      }
      selectedDevices.append(logicalID)
      selectedDevices.sort { $0.uuidString < $1.uuidString }
    }
    applyScope()
    analysisSelectionHandler()
  }

  func performanceTargetSelection(
    deviceID: UUID? = nil
  ) -> ViewerPerformanceTargetSelection {
    guard storeRematerializationResolution != .unresolved else {
      return .guidance(.sourceUnavailable)
    }
    return ViewerPerformanceTargetCompiler.compile(
      source: selectedSource,
      selectedDeviceIDs: deviceID.map { [$0] } ?? selectedDevices,
      catalogRecordingID: deviceCatalogRecordingID,
      recordingRows: model.recordingRows,
      deviceRows: model.deviceRows,
      sessions: sessionSnapshots
    )
  }

  @discardableResult
  func deactivateForAnalysisSwitch() -> Task<Void, Never> {
    guard !sealed else { return Task {} }
    pendingExactRevealIdentity = nil
    cancel(.events)
    cancel(.gaps)
    clearInspector()
    cancelRendererDelivery()
    let rendererWait = rendererService.cancelAndWait()
    let rendererDeliveryWait = rendererDeliveryPump.waitForIdle()
    let traversalWait = coordinator.deactivateAndReleaseTraversal()
    let operationWait = operationTracker.waitTask()
    let exactRevealWait = exactRevealTracker.waitTask()
    publish()
    return Task {
      async let renderer: Void = rendererWait.value
      async let rendererDelivery: Void = rendererDeliveryWait.value
      async let traversal: Void = traversalWait.value
      async let operations: Void = operationWait.value
      async let exactReveal: Void = exactRevealWait.value
      _ = await (renderer, rendererDelivery, traversal, operations, exactReveal)
    }
  }

  @discardableResult
  func activateAfterAnalysisSwitch() -> Task<Void, Never> {
    guard !sealed else { return Task {} }
    return coordinator.activateAndRefresh()
  }

  @discardableResult
  func refreshTraversalForExactReveal() -> Task<Bool, Never> {
    guard !sealed else { return Task { false } }
    return coordinator.prepareExactReveal()
  }

  @discardableResult
  func revealExactEvent(_ identity: ViewerExplorerEventIdentity) -> Bool {
    guard !sealed, coordinator.isAnalysisActive else { return false }
    deferredSelectionRevision &+= 1
    clearInspector()
    _ = model.selectEvent(identity, scrollToSelection: true)
    inspectorState = .loading
    switch identity {
    case .durable(let rowID):
      if canSubmitTraversalWork {
        pendingExactRevealIdentity = nil
        loadDurableDetail(rowID: rowID, identity: identity)
        publish()
        return true
      } else {
        pendingExactRevealIdentity = identity
        publish()
        return false
      }
    case .transient(let key):
      pendingExactRevealIdentity = nil
      let accepted = loadTransientDetail(key: key, identity: identity)
      publish()
      return accepted
    }
  }

  func acceptExactReveal(_ identity: ViewerExplorerEventIdentity) async -> Bool {
    await withCheckedContinuation { continuation in
      beginExactRevealPreflight(identity) { accepted in
        continuation.resume(returning: accepted)
      }
    }
  }

  private func beginExactRevealPreflight(
    _ identity: ViewerExplorerEventIdentity,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    guard !sealed, coordinator.isAnalysisActive else {
      completion(false)
      return
    }
    cancelExactRevealPreflight()
    switch identity {
    case .durable(let rowID):
      guard canSubmitTraversalWork else {
        completion(false)
        return
      }
      let id = UUID()
      exactRevealTracker.begin(id: id)
      let preflight = ExactRevealPreflight(
        id: id,
        intentRevision: deferredSelectionRevision,
        identity: identity,
        completion: completion
      )
      exactRevealPreflights[id] = preflight
      activeExactRevealPreflightID = id
      let storeToken = content.loadDetail(rowID) { [weak self] result in
        Task { @MainActor in
          self?.finishDurableExactRevealPreflight(result, id: id)
        }
      }
      guard let active = exactRevealPreflights[id] else {
        content.cancel(storeToken)
        return
      }
      active.storeToken = storeToken
    case .transient(let key):
      let snapshot = live.snapshot()
      guard snapshot.runtimeLogicalID == model.runtimeLogicalID,
        let event = snapshot.events.first(where: { $0.observation.key == key }),
        let buffer = try? inspector.prepare(liveEvent: event, identity: identity)
      else {
        completion(false)
        return
      }
      commitTransientExactReveal(buffer, identity: identity)
      completion(true)
    }
  }

  private func finishDurableExactRevealPreflight(
    _ result: Result<ViewerStoredEventDetail?, ViewerStoreExplorerFailure>,
    id: UUID
  ) {
    guard let active = exactRevealPreflights.removeValue(forKey: id) else { return }
    if activeExactRevealPreflightID == id { activeExactRevealPreflightID = nil }
    exactRevealTracker.complete(id)
    guard !active.isCancelled, !sealed, coordinator.isAnalysisActive, canSubmitTraversalWork,
      active.intentRevision == deferredSelectionRevision,
      case .success(let detail?) = result,
      let buffer = try? inspector.prepare(detail: detail, identity: active.identity)
    else {
      active.completeAcceptance(false)
      return
    }
    commitDurableExactReveal(detail, buffer: buffer, identity: active.identity)
    active.completeAcceptance(true)
  }

  private func commitDurableExactReveal(
    _ detail: ViewerStoredEventDetail,
    buffer: ViewerCanonicalEventDetailBuffer,
    identity: ViewerExplorerEventIdentity
  ) {
    deferredSelectionRevision &+= 1
    clearInspector()
    _ = model.selectEvent(identity, scrollToSelection: true)
    inspectorState = .loading
    pendingExactRevealIdentity = nil
    _ = model.applySelectedDetail(detail, identity: identity, token: model.currentToken)
    submitRenderer(inspector.select(preparedDurableBuffer: buffer, identity: identity))
    if case .durable(let rowID) = identity {
      loadCausality(rowID: rowID, identity: identity)
    }
    publish()
  }

  private func commitTransientExactReveal(
    _ buffer: ViewerCanonicalEventDetailBuffer,
    identity: ViewerExplorerEventIdentity
  ) {
    deferredSelectionRevision &+= 1
    clearInspector()
    _ = model.selectEvent(identity, scrollToSelection: true)
    inspectorState = .loading
    pendingExactRevealIdentity = nil
    submitRenderer(inspector.select(preparedLiveBuffer: buffer, identity: identity))
    causalityState = .recordedDataRequired
    publish()
  }

  @discardableResult
  func replaceFilterText(_ field: ViewerExplorerFilterTextField, with value: String) -> Bool {
    guard !sealed else { return false }
    let result = filterDraft.replaceText(field, with: value)
    return applyFilterTextEditResult(result)
  }

  @discardableResult
  func replaceFilterCharacters(
    _ field: ViewerExplorerFilterTextField,
    range: NSRange,
    replacement: String
  ) -> Bool {
    guard !sealed else { return false }
    let result = filterDraft.replaceText(field, range: range, replacement: replacement)
    return applyFilterTextEditResult(result)
  }

  private func applyFilterTextEditResult(_ result: ViewerTextEditResult) -> Bool {
    if case .rejected = result {
      filterValidationMessage = "The filter value exceeds its supported limit."
      publish()
      return false
    }
    filterValidationMessage = nil
    publish()
    return true
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
      applyScope()
    } catch {
      filterValidationMessage = "Check the Event, time, or JSON filter values."
      publish()
    }
  }

  func clearFilter() {
    guard !sealed else { return }
    filterDraft = ViewerExplorerFilterDraft()
    filterValidationMessage = nil
    applyScope()
  }

  func pauseOrResume() {
    guard !sealed else { return }
    if model.isPaused {
      _ = coordinator.resume()
    } else {
      _ = coordinator.pause()
    }
    publish()
  }

  func jumpToLatest() {
    guard !sealed else { return }
    _ = coordinator.jumpToLatest()
    publish()
  }

  func noteManualScroll(_ identity: ViewerExplorerEventIdentity?) {
    guard !sealed else { return }
    coordinator.noteManualScroll(identity)
  }

  func loadOlderRecordings() {
    guard model.recordingNavigation.trailingCursor != nil else { return }
    loadRecordingCatalog(placement: .trailing)
  }

  func loadOlderDevices() {
    guard storeRematerializationResolution != .unresolved,
      let recordingID = selectedRecordingID, hasOlderDevices
    else { return }
    loadDeviceCatalog(recordingID: recordingID, placement: .trailing)
  }

  func loadOlderEvents() {
    guard canSubmitTraversalWork else { return }
    coordinator.noteManualScroll(model.timelineRows.first?.identity)
    loadEventPage(edge: .leading)
  }
  func loadNewerEvents() { loadEventPage(edge: .trailing) }
  func loadOlderGaps() { loadGapPage(edge: .leading) }
  func loadNewerGaps() { loadGapPage(edge: .trailing) }

  func updateSelectedRecording(name: String?, note: String?, pinned: Bool) {
    guard !sealed, canManageSelectedRecording, let target = selectedRecordingTarget else {
      recordingOperationState = .failed(.unavailable)
      publish()
      return
    }
    let normalizedName = name?.isEmpty == true ? nil : name
    let normalizedNote = note?.isEmpty == true ? nil : note
    guard validateRecordingText(name: normalizedName, note: normalizedNote) else {
      recordingOperationState = .failed(.invalidRequest)
      publish()
      return
    }
    preparedDeleteConfirmation = nil
    recordingOperationState = .running
    let recordingID = target.recordingID
    let operation = begin(.recordingMutation)
    let storeToken = content.updateRecording(
      target,
      normalizedName,
      normalizedNote,
      pinned
    ) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        self?.handleRecordingMutation(
          result,
          recordingID: recordingID,
          successMessage: "Recording metadata saved.",
          operationID: operation.id
        )
      }
    }
    attach(storeToken, to: .recordingMutation, operationID: operation.id)
    publish()
  }

  func setSelectedRecordingPinned(_ pinned: Bool) {
    guard let row = selectedRecordingRow else { return }
    updateSelectedRecording(name: row.name, note: row.note, pinned: pinned)
  }

  func appendSelectedRecordingAnnotation(_ body: String) {
    guard !sealed, canManageSelectedRecording, let target = selectedRecordingTarget else {
      recordingOperationState = .failed(.unavailable)
      publish()
      return
    }
    guard validateAnnotation(body) else {
      recordingOperationState = .failed(.invalidRequest)
      publish()
      return
    }
    preparedDeleteConfirmation = nil
    recordingOperationState = .running
    let operation = begin(.recordingMutation)
    let storeToken = content.appendAnnotation(target, body) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        guard let self, self.finish(.recordingMutation, operationID: operation.id), !self.sealed
        else { return }
        switch result {
        case .success:
          self.recordingOperationState = .succeeded("Annotation appended.")
        case .failure(let failure):
          self.recordingOperationState = .failed(failure)
        }
        self.loadRecordingCatalog(placement: .replace)
        self.publish()
      }
    }
    attach(storeToken, to: .recordingMutation, operationID: operation.id)
    publish()
  }

  func prepareSelectedRecordingDelete() {
    guard !sealed, canManageSelectedRecording, let target = selectedRecordingTarget else {
      recordingOperationState = .failed(.unavailable)
      publish()
      return
    }
    preparedDeleteConfirmation = nil
    recordingOperationState = .running
    let operation = begin(.deletePreparation)
    let storeToken = content.prepareDelete(target) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        guard let self, self.finish(.deletePreparation, operationID: operation.id), !self.sealed
        else { return }
        switch result {
        case .success(let confirmation):
          guard confirmation.recordingID == target.recordingID,
            self.selectedRecordingID == target.recordingID
          else {
            self.recordingOperationState = .failed(.invalidRequest)
            self.publish()
            return
          }
          self.preparedDeleteConfirmation = confirmation
          self.recordingOperationState = .awaitingDeleteConfirmation
        case .failure(let failure):
          self.recordingOperationState = .failed(failure)
          self.loadRecordingCatalog(placement: .replace)
        }
        self.publish()
      }
    }
    attach(storeToken, to: .deletePreparation, operationID: operation.id)
    publish()
  }

  func cancelDeleteConfirmation() {
    cancel(.deletePreparation)
    preparedDeleteConfirmation = nil
    if recordingOperationState == .awaitingDeleteConfirmation {
      recordingOperationState = .idle
    }
    publish()
  }

  func confirmSelectedRecordingDelete() {
    guard !sealed, let confirmation = preparedDeleteConfirmation,
      selectedRecordingID == confirmation.recordingID
    else {
      preparedDeleteConfirmation = nil
      recordingOperationState = .failed(.invalidRequest)
      loadRecordingCatalog(placement: .replace)
      publish()
      return
    }
    preparedDeleteConfirmation = nil
    recordingOperationState = .running
    let deletedRecordingID = confirmation.recordingID
    let operation = begin(.deleteExecution)
    let storeToken = content.requestDelete(confirmation) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        guard let self, self.finish(.deleteExecution, operationID: operation.id), !self.sealed
        else { return }
        switch result {
        case .success:
          self.recordingTargets.removeValue(forKey: deletedRecordingID)
          if self.selectedRecordingID == deletedRecordingID {
            self.selectedSource = .current(runtimeLogicalID: self.model.runtimeLogicalID)
            self.selectedDevices.removeAll(keepingCapacity: false)
            self.deviceCatalogRecordingID = nil
            self.clearInspector()
            self.applyScope()
            self.analysisSelectionHandler()
          }
          self.recordingOperationState = .succeeded("Recording deleted.")
        case .failure(let failure):
          self.recordingOperationState = .failed(failure)
        }
        self.loadRecordingCatalog(placement: .replace)
        self.publish()
      }
    }
    attach(storeToken, to: .deleteExecution, operationID: operation.id)
    publish()
  }

  func prepareExport(_ mode: ViewerExportMode) {
    guard !sealed, canManageSelectedRecording, selectedRecordingTarget != nil else {
      exportState = .failed(.unavailable)
      publish()
      return
    }
    if mode == .currentFilteredResult, !canExportFilteredResult {
      exportState = .failed(.invalidRequest)
      publish()
      return
    }
    if case .exporting = exportState { return }
    if case .cancelling = exportState { return }
    cancelExport(clearState: false)
    exportState = .preparing(mode)
    let operation = begin(.exportPreparation)
    let completion: ViewerExplorerContentDriver.ExportPreparationCompletion = {
      [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        self?.handleExportPreparation(result, mode: mode, operationID: operation.id)
      }
    }
    let storeToken: ViewerStoreExplorerOperationToken
    switch mode {
    case .completeRecording:
      guard let target = selectedRecordingTarget else { return }
      storeToken = content.prepareCompleteExport(target, completion)
    case .currentFilteredResult:
      storeToken = content.prepareFilteredExport(completion)
    }
    attach(storeToken, to: .exportPreparation, operationID: operation.id)
    publish()
  }

  func beginExportDestinationSelection(_ start: ViewerExportDestinationSelectionStarter) {
    guard !sealed, case .disclosure = exportState else { return }
    cancelExportDestinationSelection()
    let id = UUID()
    let deliveryGate = ViewerOperationDeliveryGate()
    exportDestinationSelectionTracker.begin(id: id)
    exportDestinationSelection = ExportDestinationSelection(
      id: id,
      deliveryGate: deliveryGate,
      cancellation: nil
    )
    let tracker = exportDestinationSelectionTracker
    let cancellation = start { [weak self, tracker] destination in
      guard deliveryGate.claimDelivery() else { return }
      Task { @MainActor [weak self, tracker] in
        guard let self else {
          tracker.complete(id)
          return
        }
        guard self.finishExportDestinationSelection(id: id), !self.sealed,
          let destination
        else { return }
        self.executePreparedExport(to: destination)
      }
    }
    guard var active = exportDestinationSelection, active.id == id else {
      cancellation()
      return
    }
    active.cancellation = cancellation
    exportDestinationSelection = active
  }

  func executePreparedExport(to destination: URL) {
    guard !sealed else { return }
    guard destination.isFileURL, let ticket = preparedExportTicket,
      case .disclosure(_, let eventCount, _) = exportState
    else {
      exportState = .failed(.invalidRequest)
      publish()
      return
    }
    preparedExportTicket = nil
    exportState = .exporting(eventCount: eventCount)
    let operation = begin(.exportExecution)
    let storeToken = content.executeExport(ticket, destination) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        guard
          let self,
          self.finish(
            .exportExecution,
            operationID: operation.id,
            acceptsInvalidatedStoreDelivery: true
          ),
          !self.sealed
        else { return }
        switch result {
        case .success: self.exportState = .completed(eventCount: eventCount)
        case .failure(.cancelled): self.exportState = .cancelled
        case .failure(let failure): self.exportState = .failed(failure)
        }
        self.publish()
      }
    }
    attach(storeToken, to: .exportExecution, operationID: operation.id)
    publish()
  }

  func cancelExport(clearState: Bool = true) {
    cancelExportDestinationSelection()
    cancel(.exportPreparation)
    if case .exporting(let eventCount) = exportState {
      requestStoreCancellation(.exportExecution)
      exportState = .cancelling(eventCount: eventCount)
      publish()
      return
    }
    if case .cancelling = exportState { return }
    cancel(.exportExecution)
    preparedExportTicket = nil
    if clearState { exportState = .cancelled }
    publish()
  }

  func clearOperationPresentation() {
    guard !sealed else { return }
    if case .running = recordingOperationState {
    } else {
      cancel(.deletePreparation)
      preparedDeleteConfirmation = nil
      recordingOperationState = .idle
    }
    if case .exporting = exportState {
    } else if case .cancelling = exportState {
    } else {
      cancelExportDestinationSelection()
      cancel(.exportPreparation)
      preparedExportTicket = nil
      exportState = .idle
    }
    publish()
  }

  func deferEventSelection(_ identity: ViewerExplorerEventIdentity?) {
    guard !sealed else { return }
    pendingExactRevealIdentity = nil
    deferredSelectionRevision &+= 1
    let intentRevision = deferredSelectionRevision
    let presentationToken = model.currentToken
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.applyDeferredEventSelection(
        identity,
        presentationToken: presentationToken,
        intentRevision: intentRevision
      )
    }
  }

  func selectEvent(_ identity: ViewerExplorerEventIdentity?) {
    guard !sealed else { return }
    pendingExactRevealIdentity = nil
    deferredSelectionRevision &+= 1
    applyEventSelection(identity)
  }

  private func applyDeferredEventSelection(
    _ identity: ViewerExplorerEventIdentity?,
    presentationToken: ViewerExplorerPresentationToken,
    intentRevision: UInt64
  ) {
    guard !sealed, intentRevision == deferredSelectionRevision,
      presentationToken == model.currentToken,
      identity.map(model.isEventResident) ?? true
    else { return }
    deferredSelectionRevision &+= 1
    applyEventSelection(identity)
  }

  private func applyEventSelection(_ identity: ViewerExplorerEventIdentity?) {
    guard !sealed else { return }
    clearInspector()
    guard let identity else {
      _ = model.selectEvent(nil)
      publish()
      return
    }
    _ = model.selectEvent(identity)
    inspectorState = .loading
    loadSelectedEvent(identity)
    publish()
  }

  func coordinatorPresentationChanged() {
    guard !sealed else { return }
    let token = model.currentToken
    let tokenChanged = reconciledPresentationToken.map { $0 != token } ?? false
    reconciledPresentationToken = token
    if tokenChanged {
      timelinePageFailure = nil
      gapPageFailure = nil
    }
    revealPendingExactEventIfReady()

    guard let selectedIdentity = model.selectedEventIdentity else {
      if inspectorState != .empty || inspector.selectedIdentity != nil {
        clearInspector()
      }
      publish()
      return
    }

    if let inspectorIdentity = inspector.selectedIdentity,
      inspectorIdentity != selectedIdentity
    {
      clearInspector()
      inspectorState = .loading
    }
    if tokenChanged, activeOperations[.detail] != nil {
      cancel(.detail)
      if inspector.selectedIdentity == nil { inspectorState = .loading }
    }
    if !model.selectedEventNeedsReload,
      activeOperations[.detail] == nil,
      inspector.selectedIdentity == nil,
      inspectorState == .loading
    {
      loadSelectedEvent(selectedIdentity)
    }
    publish()
  }

  private func revealPendingExactEventIfReady() {
    guard coordinator.isAnalysisActive, canSubmitTraversalWork,
      let identity = pendingExactRevealIdentity,
      case .durable(let rowID) = identity
    else { return }
    pendingExactRevealIdentity = nil
    guard model.isEventResident(identity) else {
      clearInspector()
      _ = model.selectEvent(nil)
      return
    }
    clearInspector()
    _ = model.selectEvent(identity, scrollToSelection: true)
    inspectorState = .loading
    loadDurableDetail(rowID: rowID, identity: identity)
  }

  func showRawChunk(_ index: Int) {
    guard !sealed else { return }
    do {
      rawChunk = try inspector.rawChunk(at: index)
      rawChunkIndex = index
    } catch {
      rawChunk = nil
    }
    publish()
  }

  func expandTree(nodeID: Int, offset: Int) {
    guard !sealed, var tree = inspectorTreeState, let content = inspector.canonicalBuffer?.content
    else { return }
    do {
      _ = try tree.expand(nodeID: nodeID, offset: offset, data: content)
      inspectorTreeState = tree
    } catch {
      return
    }
    publish()
  }

  @discardableResult
  func sealAndClear() -> Task<Void, Never> {
    if let cleanupTask { return cleanupTask }
    sealed = true
    workspaceControl.cancelCurrentSessionImport()
    workspaceMutationLease?.release()
    workspaceMutationLease = nil
    changeSnapshotDirty = false
    if let activeStoreRematerializationID {
      self.activeStoreRematerializationID = nil
      storeRematerializationTracker.complete(activeStoreRematerializationID)
    }
    let exactRevealCleanup = cancelExactRevealAndWait()
    for slot in Array(activeOperations.keys) { cancel(slot) }
    cancelRendererDelivery()
    cancelExportDestinationSelection()
    let rendererCleanup = rendererService.cancelAndWait()
    let rendererDeliveryCleanup = rendererDeliveryPump.sealAndWait()
    let exportDestinationCleanup = exportDestinationSelectionTracker.waitTask()
    let storeRematerializationCleanup = storeRematerializationTracker.waitTask()
    live.setRefreshHandler { _ in }
    analysisSelectionHandler = {}
    analysisRefreshHandler = {}
    analysisRematerializationHandler = { _ in }
    live.setPresentationPaused(true)
    coordinator.setPresentationHandler {}
    coordinator.cancelActiveWork()
    model.setRefreshHandler { _, _ in }
    model.sealAndClear()
    let coordinatorCleanup = coordinator.waitForIdle()
    let operationCleanup = operationTracker.waitTask()
    inspector.clear()
    sessionSnapshots.removeAll(keepingCapacity: false)
    recordingTargets.removeAll(keepingCapacity: false)
    preparedDeleteConfirmation = nil
    preparedExportTicket = nil
    pendingExactRevealIdentity = nil
    selectedDevices.removeAll(keepingCapacity: false)
    rawChunk = nil
    inspectorTreeState = nil
    timelinePageFailure = nil
    gapPageFailure = nil
    filterDraft = ViewerExplorerFilterDraft()
    filterValidationMessage = nil
    causalityState = .none
    inspectorState = .empty
    recordingOperationState = .idle
    exportState = .idle
    workspaceOperationState = .idle
    publish()
    let cleanup = Task { [self] in
      async let renderer: Void = rendererCleanup.value
      async let coordinator: Void = coordinatorCleanup.value
      async let operations: Void = operationCleanup.value
      async let exactReveal: Void = exactRevealCleanup.value
      async let rendererDelivery: Void = rendererDeliveryCleanup.value
      async let exportDestination: Void = exportDestinationCleanup.value
      async let storeRematerialization: Void = storeRematerializationCleanup.value
      _ = await (
        renderer, coordinator, operations, exactReveal, rendererDelivery, exportDestination,
        storeRematerialization
      )
      _ = revision
    }
    cleanupTask = cleanup
    return cleanup
  }

  var pendingCleanupWorkCount: Int {
    rendererService.pendingWorkCount + coordinator.pendingWorkCount + operationTracker.activeCount
      + exactRevealTracker.activeCount
      + rendererDeliveryPump.pendingWorkCount + exportDestinationSelectionTracker.activeCount
      + storeRematerializationTracker.activeCount
  }

  var pendingExactRevealIdentityForTesting: ViewerExplorerEventIdentity? {
    pendingExactRevealIdentity
  }

  var rendererDeliveryRetainedResultCountForTesting: Int {
    rendererDeliveryPump.retainedValueCountForTesting
  }

  var rendererDeliveryMaximumRetainedResultCountForTesting: Int {
    rendererDeliveryPump.maximumRetainedValueCount
  }

  var hasPendingChangeSnapshotSuccessorForTesting: Bool { changeSnapshotDirty }

  nonisolated var description: String { "ViewerEventExplorerController(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private var selectedRecordingID: Int64? {
    switch selectedSource {
    case .current:
      return currentRecordingRow?.rowID
    case .historical(let recordingID, let logicalID):
      return model.recordingRows.first {
        $0.rowID == recordingID && $0.logicalID == logicalID
      }?.rowID
    }
  }

  private var selectedRecordingTarget: ViewerStoreRecordingTarget? {
    guard storeRematerializationResolution != .unresolved else { return nil }
    return selectedRecordingID.flatMap { recordingTargets[$0] }
  }

  private var currentRecordingRow: ViewerRecordingCatalogRow? {
    model.recordingRows.first { $0.logicalID == model.runtimeLogicalID }
  }

  private var selectedRecordingLogicalID: UUID {
    switch selectedSource {
    case .current(let runtimeLogicalID): return runtimeLogicalID
    case .historical(_, let logicalID): return logicalID
    }
  }

  private func adoptRematerializedRecordingIdentity() -> Int64? {
    guard
      let row = model.recordingRows.first(where: {
        $0.logicalID == selectedRecordingLogicalID
      })
    else { return nil }
    if case .historical(_, let logicalID) = selectedSource {
      selectedSource = .historical(recordingID: row.rowID, recordingLogicalID: logicalID)
    }
    return row.rowID
  }

  private func validateRecordingText(name: String?, note: String?) -> Bool {
    var buffers = ViewerExplorerOperatorTextBuffers()
    if let name {
      guard
        case .applied = buffers.replaceCharacters(
          field: .name,
          range: NSRange(location: 0, length: 0),
          replacement: name
        )
      else { return false }
    }
    if let note {
      guard
        case .applied = buffers.replaceCharacters(
          field: .note,
          range: NSRange(location: 0, length: 0),
          replacement: note
        )
      else { return false }
    }
    return true
  }

  private func validateAnnotation(_ body: String) -> Bool {
    guard !body.isEmpty else { return false }
    var buffers = ViewerExplorerOperatorTextBuffers()
    guard
      case .applied = buffers.replaceCharacters(
        field: .annotation,
        range: NSRange(location: 0, length: 0),
        replacement: body
      )
    else { return false }
    return true
  }

  private func handleRecordingMutation(
    _ result: Result<ViewerStoreRecordingTarget, ViewerStoreExplorerFailure>,
    recordingID: Int64,
    successMessage: String,
    operationID: UUID
  ) {
    guard finish(.recordingMutation, operationID: operationID), !sealed else { return }
    switch result {
    case .success(let target):
      guard target.recordingID == recordingID else {
        recordingOperationState = .failed(.invalidRequest)
        publish()
        return
      }
      recordingTargets[recordingID] = target
      recordingOperationState = .succeeded(successMessage)
    case .failure(let failure):
      recordingOperationState = .failed(failure)
    }
    loadRecordingCatalog(placement: .replace)
    publish()
  }

  private func handleExportPreparation(
    _ result: Result<ViewerStoreExportTicket, ViewerStoreExplorerFailure>,
    mode: ViewerExportMode,
    operationID: UUID
  ) {
    guard finish(.exportPreparation, operationID: operationID), !sealed else { return }
    switch result {
    case .success(let ticket):
      guard ticket.eventCount >= 0 else {
        exportState = .failed(.invalidRequest)
        publish()
        return
      }
      preparedExportTicket = ticket
      exportState = .disclosure(mode, eventCount: ticket.eventCount, ticket.disclosure)
    case .failure(.cancelled):
      preparedExportTicket = nil
      exportState = .cancelled
    case .failure(let failure):
      preparedExportTicket = nil
      exportState = .failed(failure)
    }
    publish()
  }

  private func applyScope() {
    guard !sealed else { return }
    pendingExactRevealIdentity = nil
    do {
      let devices: ViewerExplorerDeviceScope =
        selectedDevices.isEmpty
        ? .all : try ViewerExplorerDeviceScope(selectedLogicalIDs: selectedDevices)
      let scope = try ViewerExplorerScope(
        source: selectedSource,
        devices: devices,
        filter: filterDraft.makeFilter()
      )
      _ = try coordinator.replaceScope(scope, materialization: makeMaterialization())
      filterValidationMessage = nil
      timelinePageFailure = nil
      gapPageFailure = nil
    } catch {
      filterValidationMessage = "The selected Session, Devices, or filters are no longer valid."
    }
    publish()
  }

  private func makeMaterialization() throws -> ViewerExplorerMaterializationSnapshot {
    if storeRematerializationResolution == .unresolved {
      guard case .current = selectedSource else {
        throw ViewerExplorerScopeError.staleMaterialization
      }
      materializationGeneration =
        materializationGeneration == UInt64.max
        ? 1 : materializationGeneration + 1
      return try ViewerExplorerMaterializationSnapshot(
        source: selectedSource,
        generation: materializationGeneration,
        recordingID: nil,
        deviceSessionIDsByLogicalID: [:]
      )
    }
    materializationGeneration =
      materializationGeneration == UInt64.max
      ? 1 : materializationGeneration + 1
    let recordingID = selectedRecordingID
    let mappings: [UUID: Int64]
    if recordingID == deviceCatalogRecordingID {
      mappings = Dictionary(uniqueKeysWithValues: model.deviceRows.map { ($0.logicalID, $0.rowID) })
    } else {
      mappings = [:]
    }
    return try ViewerExplorerMaterializationSnapshot(
      source: selectedSource,
      generation: materializationGeneration,
      recordingID: recordingID,
      deviceSessionIDsByLogicalID: mappings
    )
  }

  private func updateMaterializationIfNeeded() {
    guard !sealed, let existing = model.materializationSnapshot else { return }
    do {
      let candidate = try makeMaterialization()
      guard
        existing.source != candidate.source || existing.recordingID != candidate.recordingID
          || existing.deviceSessionIDsByLogicalID != candidate.deviceSessionIDsByLogicalID
      else { return }
      _ = try coordinator.replaceMaterialization(candidate)
    } catch {
      filterValidationMessage = "The current Session changed; try again."
    }
    publish()
  }

  private func loadRecordingCatalog(placement: ViewerExplorerPagePlacement) {
    guard !sealed else { return }
    let cursor: ViewerRecordingCatalogCursor?
    let direction: ViewerCatalogPageDirection
    switch placement {
    case .replace:
      cursor = nil
      direction = .older
    case .leading:
      cursor = model.recordingNavigation.leadingCursor
      direction = .newer
    case .trailing:
      cursor = model.recordingNavigation.trailingCursor
      direction = .older
    }
    recordingsState = .loading
    let operation = begin(.recordings)
    let storeToken = content.loadRecordingCatalog(cursor, direction, 50) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        self?.handleRecordingCatalog(
          result,
          placement: placement,
          operationID: operation.id
        )
      }
    }
    attach(storeToken, to: .recordings, operationID: operation.id)
    publish()
  }

  private func handleRecordingCatalog(
    _ result: Result<ViewerRecordingCatalogPage, ViewerStoreExplorerFailure>,
    placement: ViewerExplorerPagePlacement,
    operationID: UUID
  ) {
    guard finish(.recordings, operationID: operationID), !sealed else { return }
    switch result {
    case .success(let page):
      guard model.applyRecordingPage(page, placement: placement, token: model.currentToken) else {
        recordingsState = .failed(.invalidRequest)
        if activeStoreRematerializationID != nil {
          devicesState = .empty
          finishStoreRematerialization()
        } else {
          publish()
        }
        return
      }
      let pageTargets = page.rows.compactMap { row in
        page.recordingTarget(rowID: row.rowID).map { (row.rowID, $0) }
      }
      if placement == .replace { recordingTargets.removeAll(keepingCapacity: true) }
      for (recordingID, target) in pageTargets { recordingTargets[recordingID] = target }
      let residentRecordingIDs = Set(model.recordingRows.map(\.rowID))
      recordingTargets = recordingTargets.filter { residentRecordingIDs.contains($0.key) }
      recordingsState = model.recordingRows.isEmpty ? .empty : .ready
      if activeStoreRematerializationID == nil,
        storeRematerializationResolution != .unresolved,
        case .current = selectedSource,
        let recordingID = currentRecordingRow?.rowID
      {
        updateMaterializationIfNeeded()
        if deviceCatalogRecordingID != recordingID {
          loadDeviceCatalog(recordingID: recordingID, placement: .replace)
        }
      }
    case .failure(.catalogChanged):
      loadRecordingCatalog(placement: .replace)
      return
    case .failure(let failure):
      recordingsState = failure == .unavailable ? .empty : .failed(failure)
    }
    if activeStoreRematerializationID != nil {
      switch result {
      case .success(let page):
        if let recordingID = adoptRematerializedRecordingIdentity() {
          loadDeviceCatalog(
            recordingID: recordingID,
            placement: .replace,
            recordingSnapshot: page.snapshot
          )
        } else {
          loadRecordingIdentity(
            logicalID: selectedRecordingLogicalID,
            snapshot: page.snapshot
          )
        }
        publish()
      case .failure:
        devicesState = .empty
        finishStoreRematerialization()
      }
      return
    }
    publish()
    analysisSelectionHandler()
  }

  private func loadRecordingIdentity(
    logicalID: UUID,
    snapshot: ViewerRecordingCatalogSnapshot
  ) {
    guard !sealed, activeStoreRematerializationID != nil else { return }
    let operation = begin(.recordings)
    let storeToken = content.loadRecordingIdentity(logicalID, snapshot) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        self?.handleRecordingIdentity(result, operationID: operation.id)
      }
    }
    attach(storeToken, to: .recordings, operationID: operation.id)
  }

  private func handleRecordingIdentity(
    _ result: Result<ViewerRecordingCatalogPage, ViewerStoreExplorerFailure>,
    operationID: UUID
  ) {
    guard finish(.recordings, operationID: operationID), !sealed,
      activeStoreRematerializationID != nil
    else { return }
    switch result {
    case .success(let page):
      guard model.mergeRecordingIdentityPage(page, token: model.currentToken) else {
        recordingsState = .failed(.invalidRequest)
        devicesState = .empty
        finishStoreRematerialization()
        return
      }
      for row in page.rows {
        if let target = page.recordingTarget(rowID: row.rowID) {
          recordingTargets[row.rowID] = target
        }
      }
      recordingsState = model.recordingRows.isEmpty ? .empty : .ready
      if let recordingID = adoptRematerializedRecordingIdentity() {
        loadDeviceCatalog(
          recordingID: recordingID,
          placement: .replace,
          recordingSnapshot: page.snapshot
        )
      } else {
        storeRematerializationResolution = .recordingAbsent
        devicesState = .empty
        finishStoreRematerialization()
      }
    case .failure(.catalogChanged):
      restartStoreRematerializationCatalogs()
    case .failure(let failure):
      recordingsState = failure == .unavailable ? .empty : .failed(failure)
      devicesState = .empty
      finishStoreRematerialization()
    }
  }

  private func loadDeviceCatalog(
    recordingID: Int64,
    placement: ViewerExplorerPagePlacement,
    recordingSnapshot: ViewerRecordingCatalogSnapshot? = nil
  ) {
    guard !sealed, recordingID > 0 else { return }
    let cursor: ViewerDeviceCatalogCursor?
    let direction: ViewerCatalogPageDirection
    switch placement {
    case .replace:
      cursor = nil
      direction = .older
    case .leading:
      cursor = model.deviceNavigation.leadingCursor
      direction = .newer
    case .trailing:
      cursor = model.deviceNavigation.trailingCursor
      direction = .older
    }
    devicesState = .loading
    let operation = begin(.devices)
    let storeToken = content.loadDeviceCatalog(
      recordingID,
      recordingSnapshot,
      cursor,
      direction,
      100
    ) {
      [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        self?.handleDeviceCatalog(
          result,
          recordingID: recordingID,
          placement: placement,
          operationID: operation.id
        )
      }
    }
    attach(storeToken, to: .devices, operationID: operation.id)
    publish()
  }

  private func handleDeviceCatalog(
    _ result: Result<ViewerDeviceCatalogPage, ViewerStoreExplorerFailure>,
    recordingID: Int64,
    placement: ViewerExplorerPagePlacement,
    operationID: UUID
  ) {
    let isCurrent = finish(.devices, operationID: operationID)
    guard isCurrent, !sealed else { return }
    guard
      adoptRematerializedRecordingIdentity() == recordingID
        || activeStoreRematerializationID == nil
    else {
      devicesState = .empty
      finishStoreRematerialization()
      return
    }
    guard selectedRecordingID == recordingID else {
      if activeStoreRematerializationID != nil { finishStoreRematerialization() }
      return
    }
    switch result {
    case .success(let page):
      guard model.applyDevicePage(page, placement: placement, token: model.currentToken) else {
        devicesState = .failed(.invalidRequest)
        if activeStoreRematerializationID != nil {
          finishStoreRematerialization()
        } else {
          publish()
        }
        return
      }
      deviceCatalogRecordingID = recordingID
      devicesState = model.deviceRows.isEmpty ? .empty : .ready
      if activeStoreRematerializationID == nil { updateMaterializationIfNeeded() }
    case .failure(.catalogChanged):
      if activeStoreRematerializationID != nil {
        restartStoreRematerializationCatalogs()
      } else {
        loadDeviceCatalog(recordingID: recordingID, placement: .replace)
      }
      return
    case .failure(let failure):
      devicesState = failure == .unavailable ? .empty : .failed(failure)
    }
    if activeStoreRematerializationID != nil {
      let residentDeviceIDs = Set(model.deviceRows.map(\.logicalID))
      let missingDeviceIDs = selectedDevices.filter { !residentDeviceIDs.contains($0) }
      if case .success(let page) = result, !missingDeviceIDs.isEmpty {
        loadDeviceIdentities(
          recordingID: recordingID,
          logicalIDs: missingDeviceIDs,
          snapshot: page.snapshot
        )
      } else {
        if case .success = result {
          storeRematerializationResolution = .resolved
        }
        finishStoreRematerialization()
      }
      return
    }
    publish()
    analysisSelectionHandler()
  }

  private func loadDeviceIdentities(
    recordingID: Int64,
    logicalIDs: [UUID],
    snapshot: ViewerDeviceCatalogSnapshot
  ) {
    guard !sealed, activeStoreRematerializationID != nil, !logicalIDs.isEmpty else { return }
    let operation = begin(.devices)
    let storeToken = content.loadDeviceIdentities(recordingID, logicalIDs, snapshot) {
      [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        self?.handleDeviceIdentities(
          result,
          recordingID: recordingID,
          operationID: operation.id
        )
      }
    }
    attach(storeToken, to: .devices, operationID: operation.id)
  }

  private func handleDeviceIdentities(
    _ result: Result<ViewerDeviceCatalogPage, ViewerStoreExplorerFailure>,
    recordingID: Int64,
    operationID: UUID
  ) {
    guard finish(.devices, operationID: operationID), !sealed,
      activeStoreRematerializationID != nil,
      adoptRematerializedRecordingIdentity() == recordingID
    else { return }
    switch result {
    case .success(let page):
      guard model.mergeDeviceIdentityPage(page, token: model.currentToken) else {
        devicesState = .failed(.invalidRequest)
        finishStoreRematerialization()
        return
      }
      deviceCatalogRecordingID = recordingID
      devicesState = model.deviceRows.isEmpty ? .empty : .ready
      storeRematerializationResolution = .resolved
      finishStoreRematerialization()
    case .failure(.catalogChanged):
      restartStoreRematerializationCatalogs()
    case .failure(let failure):
      devicesState = failure == .unavailable ? .empty : .failed(failure)
      finishStoreRematerialization()
    }
  }

  private func loadEventPage(edge: ViewerExplorerWindowEdge) {
    guard !sealed, !model.isPaused, canSubmitTraversalWork,
      activeOperations[.events] == nil
    else { return }
    let cursor: ViewerEventCursor?
    let placement: ViewerExplorerPagePlacement
    switch edge {
    case .leading:
      cursor = model.eventNavigation.leadingCursor
      placement = .leading
    case .trailing:
      cursor = model.eventNavigation.trailingCursor
      placement = .trailing
    }
    guard let cursor else { return }
    timelinePageFailure = nil
    let presentationToken = model.currentToken
    let operation = begin(.events)
    eventPageRequestCountForTesting += 1
    let storeToken = content.loadEventPage(cursor, cursor.direction, 100) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        self?.handleEventPage(
          result,
          placement: placement,
          presentationToken: presentationToken,
          operationID: operation.id
        )
      }
    }
    attach(storeToken, to: .events, operationID: operation.id)
  }

  private func handleEventPage(
    _ result: Result<ViewerEventPage, ViewerStoreExplorerFailure>,
    placement: ViewerExplorerPagePlacement,
    presentationToken: ViewerExplorerPresentationToken,
    operationID: UUID
  ) {
    guard finish(.events, operationID: operationID), !sealed,
      presentationToken == model.currentToken, !model.isPaused
    else { return }
    switch result {
    case .success(let page):
      guard
        let mutation = model.applyTimelinePage(
          page,
          placement: placement,
          token: presentationToken
        )
      else {
        timelinePageFailure = .invalidRequest
        publish()
        return
      }
      for visibility in mutation.durableVisibilities {
        live.durableRowBecameVisible(
          key: visibility.key,
          observationID: visibility.observationID
        )
      }
    case .failure(let failure):
      timelinePageFailure = failure
    }
    publish()
  }

  private func loadGapPage(edge: ViewerExplorerWindowEdge) {
    guard !sealed, !model.isPaused, canSubmitTraversalWork,
      activeOperations[.gaps] == nil
    else { return }
    let cursor: ViewerGapCursor?
    let placement: ViewerExplorerPagePlacement
    switch edge {
    case .leading:
      cursor = model.gapNavigation.leadingCursor
      placement = .leading
    case .trailing:
      cursor = model.gapNavigation.trailingCursor
      placement = .trailing
    }
    guard let cursor else { return }
    gapPageFailure = nil
    let presentationToken = model.currentToken
    let operation = begin(.gaps)
    gapPageRequestCountForTesting += 1
    let storeToken = content.loadGapPage(
      durableDeviceSessionIDs(),
      cursor,
      cursor.direction,
      32
    ) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        self?.handleGapPage(
          result,
          placement: placement,
          presentationToken: presentationToken,
          operationID: operation.id
        )
      }
    }
    attach(storeToken, to: .gaps, operationID: operation.id)
  }

  private func handleGapPage(
    _ result: Result<ViewerGapPage, ViewerStoreExplorerFailure>,
    placement: ViewerExplorerPagePlacement,
    presentationToken: ViewerExplorerPresentationToken,
    operationID: UUID
  ) {
    guard finish(.gaps, operationID: operationID), !sealed,
      presentationToken == model.currentToken, !model.isPaused
    else { return }
    switch result {
    case .success(let page):
      if !model.applyGapPage(page, placement: placement, token: presentationToken) {
        gapPageFailure = .invalidRequest
      }
    case .failure(let failure):
      gapPageFailure = failure
    }
    publish()
  }

  private func durableDeviceSessionIDs() -> [Int64] {
    guard let scope = model.explorerScope, let materialization = model.materializationSnapshot
    else { return [] }
    switch scope.devices {
    case .all:
      return []
    case .selected(let logicalIDs):
      return logicalIDs.compactMap { materialization.deviceSessionIDsByLogicalID[$0] }.sorted()
    }
  }

  private func loadDurableDetail(rowID: Int64, identity: ViewerExplorerEventIdentity) {
    let token = model.currentToken
    let operation = begin(.detail)
    let storeToken = content.loadDetail(rowID) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        self?.handleDurableDetail(
          result,
          identity: identity,
          presentationToken: token,
          operationID: operation.id
        )
      }
    }
    attach(storeToken, to: .detail, operationID: operation.id)
  }

  private func loadSelectedEvent(_ identity: ViewerExplorerEventIdentity) {
    switch identity {
    case .durable(let rowID):
      guard canSubmitTraversalWork else { return }
      loadDurableDetail(rowID: rowID, identity: identity)
    case .transient(let key):
      loadTransientDetail(key: key, identity: identity)
    }
  }

  private var canSubmitTraversalWork: Bool {
    return coordinator.state.ownsQueryableTraversal
  }

  private func handleDurableDetail(
    _ result: Result<ViewerStoredEventDetail?, ViewerStoreExplorerFailure>,
    identity: ViewerExplorerEventIdentity,
    presentationToken: ViewerExplorerPresentationToken,
    operationID: UUID
  ) {
    guard finish(.detail, operationID: operationID), !sealed,
      model.selectedEventIdentity == identity, presentationToken == model.currentToken
    else { return }
    switch result {
    case .success(let detail?):
      guard model.applySelectedDetail(detail, identity: identity, token: presentationToken) else {
        inspectorState = .failed(.invalidRequest)
        publish()
        return
      }
      do {
        submitRenderer(try inspector.select(detail: detail, identity: identity))
        if case .durable(let rowID) = identity { loadCausality(rowID: rowID, identity: identity) }
      } catch {
        inspectorState = .failed(.invalidRequest)
      }
    case .success(nil):
      inspectorState = .failed(.invalidRequest)
    case .failure(let failure):
      inspectorState = .failed(failure)
    }
    publish()
  }

  @discardableResult
  private func loadTransientDetail(
    key: ViewerEventJournalKey,
    identity: ViewerExplorerEventIdentity
  ) -> Bool {
    let snapshot = live.snapshot()
    guard snapshot.runtimeLogicalID == model.runtimeLogicalID,
      let event = snapshot.events.first(where: { $0.observation.key == key })
    else {
      inspectorState = .failed(.invalidRequest)
      publish()
      return false
    }
    do {
      submitRenderer(try inspector.select(liveEvent: event, identity: identity))
      causalityState = .recordedDataRequired
      return true
    } catch {
      inspectorState = .failed(.invalidRequest)
      return false
    }
  }

  private func submitRenderer(_ request: ViewerRendererPreparationRequest) {
    cancelRendererDelivery()
    let id = UUID()
    let deliveryGate = ViewerOperationDeliveryGate()
    rendererDelivery = RendererDelivery(id: id, deliveryGate: deliveryGate)
    let deliveryPump = rendererDeliveryPump
    let deliveryClaimed = rendererDeliveryClaimed
    rendererService.submit(request) { result in
      guard deliveryGate.claimDelivery() else { return }
      guard deliveryPump.submit(RendererDeliveryValue(id: id, result: result))
      else { return }
      deliveryClaimed()
    }
  }

  func submitRendererForTesting(_ request: ViewerRendererPreparationRequest) {
    guard !sealed else { return }
    submitRenderer(request)
  }

  private func loadCausality(rowID: Int64, identity: ViewerExplorerEventIdentity) {
    causalityState = .loading
    let operation = begin(.causality)
    let storeToken = content.loadCausality(rowID) { [weak self] result in
      guard operation.deliveryGate.claimDelivery() else { return }
      Task { @MainActor in
        guard let self, self.finish(.causality, operationID: operation.id), !self.sealed,
          self.model.selectedEventIdentity == identity
        else { return }
        switch result {
        case .success(let graph): self.causalityState = .ready(graph)
        case .failure(let failure): self.causalityState = .failed(failure)
        }
        self.publish()
      }
    }
    attach(storeToken, to: .causality, operationID: operation.id)
  }

  private func clearInspector() {
    cancelExactRevealPreflight()
    cancel(.detail)
    cancel(.causality)
    cancelRendererDelivery()
    rendererService.cancel()
    inspector.clear()
    rawChunkIndex = 0
    rawChunk = nil
    inspectorTreeState = nil
    inspectorState = .empty
    causalityState = .none
  }

  private func cancelExactRevealPreflight() {
    guard let id = activeExactRevealPreflightID,
      let active = exactRevealPreflights[id]
    else { return }
    activeExactRevealPreflightID = nil
    active.isCancelled = true
    if let storeToken = active.storeToken { content.cancel(storeToken) }
    active.completeAcceptance(false)
  }

  func cancelExactRevealAndWait() -> Task<Void, Never> {
    cancelExactRevealPreflight()
    return exactRevealTracker.waitTask()
  }

  private func handleChangeSnapshot(
    _ result: Result<ViewerStoreChangeSnapshot, ViewerStoreExplorerFailure>,
    operationID: UUID
  ) {
    let isCurrent = finish(.changeSnapshot, operationID: operationID)
    guard !sealed else {
      changeSnapshotDirty = false
      return
    }
    if isCurrent {
      switch result {
      case .success(let snapshot):
        _ = model.noteRefresh(
          changeToken: "event-\(snapshot.eventUpperRowID)",
          durableUpperRowID: snapshot.eventUpperRowID
        )
        loadRecordingCatalog(placement: .replace)
        if activeStoreRematerializationID != nil {
          publish()
          return
        }
      case .failure(let failure):
        if activeStoreRematerializationID != nil {
          recordingsState = failure == .unavailable ? .empty : .failed(failure)
          devicesState = .empty
          finishStoreRematerialization()
          return
        }
      }
    }
    if activeStoreRematerializationID != nil {
      publish()
      return
    }
    let needsSuccessor = changeSnapshotDirty
    changeSnapshotDirty = false
    if needsSuccessor { startChangeSnapshotRequest() }
    publish()
  }

  private func restartStoreRematerializationCatalogs() {
    guard !sealed, activeStoreRematerializationID != nil else { return }
    cancel(.recordings)
    cancel(.devices)
    _ = model.beginPresentationReplacement(clearRows: true)
    recordingTargets.removeAll(keepingCapacity: true)
    deviceCatalogRecordingID = nil
    storeRematerializationResolution = .unresolved
    recordingsState = .loading
    devicesState = .idle
    loadRecordingCatalog(placement: .replace)
    publish()
  }

  private func completeStoreRematerializationForExplicitLiveSelection() {
    guard activeStoreRematerializationID != nil else { return }
    cancel(.changeSnapshot)
    cancel(.recordings)
    cancel(.devices)
    _ = model.beginPresentationReplacement(clearRows: true)
    recordingTargets.removeAll(keepingCapacity: true)
    deviceCatalogRecordingID = nil
    storeRematerializationResolution = .unresolved
    recordingsState = .empty
    devicesState = .empty
    finishStoreRematerialization()
  }

  private func finishStoreRematerialization() {
    guard let workID = activeStoreRematerializationID else { return }
    activeStoreRematerializationID = nil
    switch storeRematerializationResolution {
    case .resolved:
      applyScope()
    case .recordingAbsent:
      reconcileSelectionAfterConfirmedRecordingAbsence()
      applyScope()
    case .unresolved:
      clearUnresolvedStoreMaterialization()
    }
    storeRematerializationTracker.complete(workID)
    let needsSuccessor = changeSnapshotDirty
    changeSnapshotDirty = false
    if needsSuccessor { startChangeSnapshotRequest() }
    publish()
  }

  private func reconcileSelectionAfterConfirmedRecordingAbsence() {
    if case .historical(_, let logicalID) = selectedSource,
      !model.recordingRows.contains(where: { $0.logicalID == logicalID })
    {
      selectedSource = .current(runtimeLogicalID: model.runtimeLogicalID)
      selectedDevices.removeAll(keepingCapacity: false)
    }
  }

  private func clearUnresolvedStoreMaterialization() {
    _ = model.beginPresentationReplacement(clearRows: true)
    recordingTargets.removeAll(keepingCapacity: true)
    deviceCatalogRecordingID = nil
    switch recordingsState {
    case .failed, .empty:
      break
    case .idle, .loading, .ready:
      recordingsState = .empty
    }
    switch devicesState {
    case .failed, .empty:
      break
    case .idle, .loading, .ready:
      devicesState = .empty
    }
  }

  private func durableDeviceAlias(_ deviceSessionID: Int64) -> String {
    model.deviceRows.first(where: { $0.rowID == deviceSessionID })?.installationAlias
      ?? "Recorded App"
  }

  @discardableResult
  private func begin(_ slot: OperationSlot) -> OperationHandle {
    cancel(slot)
    let id = UUID()
    let deliveryGate = ViewerOperationDeliveryGate(
      deliveryClaimed: operationDeliveryClaimed
    )
    operationTracker.begin(id: id)
    activeOperations[slot] = ActiveOperation(
      id: id,
      deliveryGate: deliveryGate,
      storeToken: nil
    )
    return OperationHandle(id: id, deliveryGate: deliveryGate)
  }

  private func attach(
    _ storeToken: ViewerStoreExplorerOperationToken,
    to slot: OperationSlot,
    operationID: UUID
  ) {
    guard var active = activeOperations[slot], active.id == operationID else {
      content.cancel(storeToken)
      return
    }
    active.storeToken = storeToken
    activeOperations[slot] = active
  }

  @discardableResult
  private func finish(
    _ slot: OperationSlot,
    operationID: UUID,
    acceptsInvalidatedStoreDelivery: Bool = false
  ) -> Bool {
    let active = activeOperations[slot]
    let isCurrent = active?.id == operationID
    let isDeliveryValid = active?.storeToken?.isDeliveryValid == true
    if isCurrent { activeOperations.removeValue(forKey: slot) }
    operationTracker.complete(operationID)
    return isCurrent && (isDeliveryValid || acceptsInvalidatedStoreDelivery)
  }

  private func requestStoreCancellation(_ slot: OperationSlot) {
    guard let storeToken = activeOperations[slot]?.storeToken else { return }
    content.cancel(storeToken)
  }

  private func cancel(_ slot: OperationSlot) {
    guard let active = activeOperations.removeValue(forKey: slot) else { return }
    if !active.deliveryGate.cancel() { operationTracker.complete(active.id) }
    if let storeToken = active.storeToken { content.cancel(storeToken) }
  }

  @discardableResult
  private func finishRendererDelivery(id: UUID) -> Bool {
    let isCurrent = rendererDelivery?.id == id
    if isCurrent { rendererDelivery = nil }
    return isCurrent
  }

  private func cancelRendererDelivery() {
    if let delivery = rendererDelivery {
      rendererDelivery = nil
      _ = delivery.deliveryGate.cancel()
    }
    rendererDeliveryPump.cancelPending()
  }

  @discardableResult
  private func finishExportDestinationSelection(id: UUID) -> Bool {
    let isCurrent = exportDestinationSelection?.id == id
    if isCurrent { exportDestinationSelection = nil }
    exportDestinationSelectionTracker.complete(id)
    return isCurrent
  }

  private func cancelExportDestinationSelection() {
    guard let selection = exportDestinationSelection else { return }
    exportDestinationSelection = nil
    if !selection.deliveryGate.cancel() {
      exportDestinationSelectionTracker.complete(selection.id)
    }
    selection.cancellation?()
  }

  private func handleRendererDelivery(_ delivery: RendererDeliveryValue) {
    guard finishRendererDelivery(id: delivery.id), !sealed,
      inspector.apply(delivery.result)
    else { return }
    inspectorTreeState = delivery.result.preparation.generic.treeState
    rawChunkIndex = 0
    rawChunk = try? inspector.rawChunk(at: 0)
    inspectorState = .ready
    publish()
  }

  private func publish() {
    revision = revision == UInt64.max ? 1 : revision + 1
  }
}

extension ViewerExplorerSourcePresentationRow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerSourcePresentationRow(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
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
  var description: String {
    "ViewerExplorerTimelinePresentationRow(redacted, contentBytes: \(contentByteCount))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["contentBytes": contentByteCount], displayStyle: .struct)
  }
}

extension ViewerExplorerFilterDraft: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerFilterDraft(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExplorerCausalityState: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerCausalityState(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerRecordingOperationState: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRecordingOperationState(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerExportPresentationState: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExportPresentationState(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}
