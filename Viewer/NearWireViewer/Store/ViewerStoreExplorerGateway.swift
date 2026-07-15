import Foundation

private typealias ViewerStoreExplorerDeferredDelivery = @Sendable () -> Void

enum ViewerStoreExplorerFailure: Error, Equatable, Sendable {
  case storeReplaced
  case cancelled
  case unavailable
  case invalidRequest
  case busy
  case refineQuery
  case exportTooLarge
  case catalogChanged
}

private final class ViewerStoreExplorerGenerationValidity: @unchecked Sendable {
  private let lock = NSLock()
  private var valid = true

  func invalidate() {
    lock.lock()
    valid = false
    lock.unlock()
  }

  var isValid: Bool {
    lock.lock()
    defer { lock.unlock() }
    return valid
  }
}

struct ViewerStoreExplorerOperationToken: Hashable, Sendable {
  let coordinatorGeneration: UInt64
  let operationID: UUID
  fileprivate let deliveryValidity: ViewerStoreExplorerGenerationValidity?

  fileprivate init(
    coordinatorGeneration: UInt64,
    operationID: UUID,
    deliveryValidity: ViewerStoreExplorerGenerationValidity?
  ) {
    self.coordinatorGeneration = coordinatorGeneration
    self.operationID = operationID
    self.deliveryValidity = deliveryValidity
  }

  init(coordinatorGeneration: UInt64, operationID: UUID) {
    self.init(
      coordinatorGeneration: coordinatorGeneration,
      operationID: operationID,
      deliveryValidity: nil
    )
  }

  var isDeliveryValid: Bool {
    (deliveryValidity?.isValid) ?? (coordinatorGeneration == 0)
  }

  fileprivate static func invalidDeliveryToken() -> ViewerStoreExplorerOperationToken {
    let validity = ViewerStoreExplorerGenerationValidity()
    validity.invalidate()
    return ViewerStoreExplorerOperationToken(
      coordinatorGeneration: 0,
      operationID: UUID(),
      deliveryValidity: validity
    )
  }

  static func == (
    lhs: ViewerStoreExplorerOperationToken,
    rhs: ViewerStoreExplorerOperationToken
  ) -> Bool {
    lhs.coordinatorGeneration == rhs.coordinatorGeneration
      && lhs.operationID == rhs.operationID
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(coordinatorGeneration)
    hasher.combine(operationID)
  }
}

struct ViewerStoreRecordingTarget: Equatable, Sendable {
  fileprivate let coordinatorGeneration: UInt64
  let recordingID: Int64
  let revision: Int64
}

struct ViewerStoreDeleteConfirmation: Equatable, Sendable {
  fileprivate let coordinatorGeneration: UInt64
  fileprivate let value: ViewerDeleteConfirmation
  let recordingID: Int64
}

private enum ViewerStoreExportSelection: Equatable, Sendable {
  case complete(ViewerCompleteExportScope)
  case filtered(ViewerFilteredExportScope)
}

struct ViewerStoreExportTicket: Equatable, Sendable {
  let eventCount: Int64
  let disclosure: ViewerExportDisclosure
  fileprivate let coordinatorGeneration: UInt64
  fileprivate let selection: ViewerStoreExportSelection
}

extension ViewerRecordingCatalogPage {
  func recordingTarget(rowID: Int64) -> ViewerStoreRecordingTarget? {
    guard let row = rows.first(where: { $0.rowID == rowID }) else { return nil }
    return ViewerStoreRecordingTarget(
      coordinatorGeneration: snapshot.storeGeneration,
      recordingID: row.rowID,
      revision: row.revision
    )
  }
}

final class ViewerStoreExplorerGateway: @unchecked Sendable {
  typealias SnapshotCompletion =
    @Sendable (Result<ViewerStoreChangeSnapshot, ViewerStoreExplorerFailure>) -> Void

  private let lock = NSLock()
  private let replacementLock = NSLock()
  private let operationExecutionGate: @Sendable () -> Void
  private let operationCompletionGate: @Sendable () -> Void
  private let cancellationRegistrationGate: @Sendable () -> Void
  private let wallMilliseconds: @Sendable () -> Int64
  private var nextGeneration: UInt64 = 1
  private var activeGeneration: ViewerStoreExplorerCoordinatorGeneration?

  init(
    operationExecutionGate: @escaping @Sendable () -> Void = {},
    operationCompletionGate: @escaping @Sendable () -> Void = {},
    cancellationRegistrationGate: @escaping @Sendable () -> Void = {},
    wallMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
  ) {
    self.operationExecutionGate = operationExecutionGate
    self.operationCompletionGate = operationCompletionGate
    self.cancellationRegistrationGate = cancellationRegistrationGate
    self.wallMilliseconds = wallMilliseconds
  }

  func install(_ coordinator: ViewerStoreCoordinator) {
    install(coordinator, preservingGeneration: nil)
  }

  func install(
    _ coordinator: ViewerStoreCoordinator,
    preservingGeneration preservedGeneration: UInt64?
  ) {
    replacementLock.lock()
    let previous: ViewerStoreExplorerCoordinatorGeneration?
    let generation: UInt64
    lock.lock()
    previous = activeGeneration
    previous?.invalidateDelivery()
    activeGeneration = nil
    if let preservedGeneration {
      generation = preservedGeneration
    } else {
      generation = nextGeneration
      nextGeneration = nextGeneration == UInt64.max ? 1 : nextGeneration + 1
    }
    lock.unlock()

    let deferredDeliveries = previous?.sealAndWait() ?? []
    let replacement = ViewerStoreExplorerCoordinatorGeneration(
      generation: generation,
      coordinator: coordinator,
      operationExecutionGate: operationExecutionGate,
      operationCompletionGate: operationCompletionGate,
      cancellationRegistrationGate: cancellationRegistrationGate,
      wallMilliseconds: wallMilliseconds
    )
    lock.lock()
    activeGeneration = replacement
    lock.unlock()
    replacementLock.unlock()
    for delivery in deferredDeliveries { delivery() }
  }

  var currentStoreGeneration: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return activeGeneration?.generation ?? 0
  }

  @discardableResult
  func loadChangeSnapshot(
    completion: @escaping SnapshotCompletion
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadChangeSnapshot(completion: completion)
    }
  }

  @discardableResult
  func replaceQuery(
    _ query: ViewerEventQuery,
    completion:
      @escaping @Sendable (
        Result<ViewerQuerySnapshot, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.replaceQuery(query, completion: completion)
    }
  }

  @discardableResult
  func replaceQuery(
    _ query: ViewerEventQuery,
    following predecessor: ViewerStoreExplorerOperationToken,
    completion:
      @escaping @Sendable (
        Result<ViewerQuerySnapshot, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(following: predecessor, completion: completion) { generation in
      generation.replaceQuery(query, completion: completion)
    }
  }

  @discardableResult
  func loadPage(
    cursor: ViewerEventCursor?,
    direction: ViewerStoreQueryService.Direction,
    limit: Int = 100,
    completion: @escaping @Sendable (Result<ViewerEventPage, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadPage(
        cursor: cursor,
        direction: direction,
        limit: limit,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadPage(
    cursor: ViewerEventCursor?,
    direction: ViewerStoreQueryService.Direction,
    limit: Int = 100,
    following predecessor: ViewerStoreExplorerOperationToken,
    completion:
      @escaping @Sendable (
        Result<ViewerEventPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(following: predecessor, completion: completion) { generation in
      generation.loadPage(
        cursor: cursor,
        direction: direction,
        limit: limit,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadDetail(
    rowID: Int64,
    completion:
      @escaping @Sendable (
        Result<ViewerStoredEventDetail?, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadDetail(rowID: rowID, completion: completion)
    }
  }

  @discardableResult
  func makeFilteredExportScope(
    completion:
      @escaping @Sendable (
        Result<ViewerFilteredExportScope, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.makeFilteredExportScope(completion: completion)
    }
  }

  @discardableResult
  func endTraversal(
    completion: @escaping @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.endTraversal(completion: completion)
    }
  }

  @discardableResult
  func endPerformanceTraversal(
    completion: @escaping @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.endPerformanceTraversal(completion: completion)
    }
  }

  @discardableResult
  func beginPerformanceTraversal(
    recordingID: Int64,
    deviceSessionID: Int64,
    lowerMonotonicNanoseconds: Int64,
    upperMonotonicNanoseconds: Int64,
    completion:
      @escaping @Sendable (
        Result<ViewerPerformanceStoreScope, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.beginPerformanceTraversal(
        recordingID: recordingID,
        deviceSessionID: deviceSessionID,
        lowerMonotonicNanoseconds: lowerMonotonicNanoseconds,
        upperMonotonicNanoseconds: upperMonotonicNanoseconds,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadPerformanceEventPage(
    continuation: ViewerPerformanceContinuation?,
    completion:
      @escaping @Sendable (
        Result<ViewerPerformanceEventPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadPerformanceEventPage(
        continuation: continuation,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadPerformanceGapPage(
    completion:
      @escaping @Sendable (
        Result<ViewerPerformanceGapPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadPerformanceGapPage(completion: completion)
    }
  }

  @discardableResult
  func resolvePerformanceEventLocator(
    recordingID: Int64,
    deviceSessionID: Int64,
    key: ViewerEventJournalKey,
    completion:
      @escaping @Sendable (
        Result<ViewerPerformanceEventLocator?, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.resolvePerformanceEventLocator(
        recordingID: recordingID,
        deviceSessionID: deviceSessionID,
        key: key,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadRecordingCatalog(
    cursor: ViewerRecordingCatalogCursor?,
    direction: ViewerCatalogPageDirection = .older,
    limit: Int = 50,
    completion:
      @escaping @Sendable (
        Result<ViewerRecordingCatalogPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadRecordingCatalog(
        cursor: cursor,
        direction: direction,
        limit: limit,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadRecordingIdentity(
    logicalID: UUID,
    snapshot: ViewerRecordingCatalogSnapshot,
    completion:
      @escaping @Sendable (
        Result<ViewerRecordingCatalogPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadRecordingIdentity(
        logicalID: logicalID,
        snapshot: snapshot,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadDeviceCatalog(
    recordingID: Int64,
    recordingSnapshot: ViewerRecordingCatalogSnapshot? = nil,
    cursor: ViewerDeviceCatalogCursor?,
    direction: ViewerCatalogPageDirection = .older,
    limit: Int = 100,
    completion:
      @escaping @Sendable (
        Result<ViewerDeviceCatalogPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadDeviceCatalog(
        recordingID: recordingID,
        recordingSnapshot: recordingSnapshot,
        cursor: cursor,
        direction: direction,
        limit: limit,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadDeviceIdentities(
    recordingID: Int64,
    logicalIDs: [UUID],
    snapshot: ViewerDeviceCatalogSnapshot,
    completion:
      @escaping @Sendable (
        Result<ViewerDeviceCatalogPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadDeviceIdentities(
        recordingID: recordingID,
        logicalIDs: logicalIDs,
        snapshot: snapshot,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadGapPage(
    deviceSessionIDs: [Int64],
    cursor: ViewerGapCursor?,
    direction: ViewerStoreQueryService.Direction,
    limit: Int = 32,
    completion: @escaping @Sendable (Result<ViewerGapPage, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadGapPage(
        deviceSessionIDs: deviceSessionIDs,
        cursor: cursor,
        direction: direction,
        limit: limit,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadGapPage(
    deviceSessionIDs: [Int64],
    cursor: ViewerGapCursor?,
    direction: ViewerStoreQueryService.Direction,
    limit: Int = 32,
    following predecessor: ViewerStoreExplorerOperationToken,
    completion:
      @escaping @Sendable (
        Result<ViewerGapPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(following: predecessor, completion: completion) { generation in
      generation.loadGapPage(
        deviceSessionIDs: deviceSessionIDs,
        cursor: cursor,
        direction: direction,
        limit: limit,
        completion: completion
      )
    }
  }

  @discardableResult
  func loadCausality(
    rootRowID: Int64,
    completion:
      @escaping @Sendable (
        Result<ViewerCausalityGraph, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.loadCausality(rootRowID: rootRowID, completion: completion)
    }
  }

  @discardableResult
  func updateRecording(
    _ target: ViewerStoreRecordingTarget,
    name: String?,
    note: String?,
    pinned: Bool,
    completion:
      @escaping @Sendable (
        Result<ViewerStoreRecordingTarget, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.updateRecording(
        target,
        name: name,
        note: note,
        pinned: pinned,
        completion: completion
      )
    }
  }

  @discardableResult
  func appendAnnotation(
    _ target: ViewerStoreRecordingTarget,
    body: String,
    completion: @escaping @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.appendAnnotation(target, body: body, completion: completion)
    }
  }

  @discardableResult
  func prepareDelete(
    _ target: ViewerStoreRecordingTarget,
    completion:
      @escaping @Sendable (
        Result<ViewerStoreDeleteConfirmation, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.prepareDelete(target, completion: completion)
    }
  }

  @discardableResult
  func requestDelete(
    _ confirmation: ViewerStoreDeleteConfirmation,
    completion: @escaping @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.requestDelete(confirmation, completion: completion)
    }
  }

  @discardableResult
  func prepareCompleteExport(
    _ target: ViewerStoreRecordingTarget,
    completion:
      @escaping @Sendable (
        Result<ViewerStoreExportTicket, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.prepareCompleteExport(target, completion: completion)
    }
  }

  @discardableResult
  func prepareFilteredExport(
    completion:
      @escaping @Sendable (
        Result<ViewerStoreExportTicket, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.prepareFilteredExport(completion: completion)
    }
  }

  @discardableResult
  func executeExport(
    _ ticket: ViewerStoreExportTicket,
    to destination: URL,
    completion: @escaping @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    withGeneration(completion: completion) { generation in
      generation.executeExport(ticket, to: destination, completion: completion)
    }
  }

  func cancel(_ token: ViewerStoreExplorerOperationToken) {
    lock.lock()
    let generation = activeGeneration
    lock.unlock()
    guard generation?.generation == token.coordinatorGeneration else { return }
    generation?.cancel(token)
  }

  @discardableResult
  func sealAndWait(originatingFrom coordinator: ViewerStoreCoordinator) -> UInt64? {
    replacementLock.lock()
    let generation: ViewerStoreExplorerCoordinatorGeneration?
    lock.lock()
    if activeGeneration?.coordinatorIdentity == ObjectIdentifier(coordinator) {
      generation = activeGeneration
      generation?.invalidateDelivery()
      activeGeneration = nil
    } else {
      generation = nil
    }
    lock.unlock()
    let deferredDeliveries = generation?.sealAndWait() ?? []
    replacementLock.unlock()
    for delivery in deferredDeliveries { delivery() }
    return generation?.generation
  }

  var operationCountForTesting: Int {
    lock.lock()
    let generation = activeGeneration
    lock.unlock()
    return generation?.operationCountForTesting ?? 0
  }

  var pendingOperationCountForTesting: Int {
    lock.lock()
    let generation = activeGeneration
    lock.unlock()
    return generation?.pendingOperationCountForTesting ?? 0
  }

  private func withGeneration<Value: Sendable>(
    completion: @escaping @Sendable (Result<Value, ViewerStoreExplorerFailure>) -> Void,
    submit: (ViewerStoreExplorerCoordinatorGeneration) -> ViewerStoreExplorerOperationToken
  ) -> ViewerStoreExplorerOperationToken {
    lock.lock()
    let generation = activeGeneration
    lock.unlock()
    guard let generation else {
      let token = ViewerStoreExplorerOperationToken(
        coordinatorGeneration: 0,
        operationID: UUID()
      )
      completion(.failure(.unavailable))
      return token
    }
    return submit(generation)
  }

  private func withGeneration<Value: Sendable>(
    following predecessor: ViewerStoreExplorerOperationToken,
    completion: @escaping @Sendable (Result<Value, ViewerStoreExplorerFailure>) -> Void,
    submit: (ViewerStoreExplorerCoordinatorGeneration) -> ViewerStoreExplorerOperationToken
  ) -> ViewerStoreExplorerOperationToken {
    lock.lock()
    let generation = activeGeneration
    let matchesPredecessor = generation?.generation == predecessor.coordinatorGeneration
    lock.unlock()
    guard predecessor.isDeliveryValid, matchesPredecessor, let generation else {
      let token = ViewerStoreExplorerOperationToken.invalidDeliveryToken()
      completion(.failure(.storeReplaced))
      return token
    }
    return submit(generation)
  }
}

private final class ViewerStoreExplorerCoordinatorGeneration: @unchecked Sendable {
  private static let maximumRetainedOperations = 16

  private enum OperationState: Equatable {
    case queued
    case active
    case completing
    case cancelled
    case storeReplaced
  }

  private struct OperationRecord {
    var state: OperationState
    let interruptsWhenActive: Bool
    let execute: @Sendable () -> Void
    let reject: @Sendable (ViewerStoreExplorerFailure) -> Void
  }

  let generation: UInt64
  let coordinatorIdentity: ObjectIdentifier

  private let lock = NSLock()
  private let queue: DispatchQueue
  private let completionGroup = DispatchGroup()
  private let services: ViewerStoreCoordinator.Services
  private let arbiter: ViewerExplorerQueryArbiter
  private let operationExecutionGate: @Sendable () -> Void
  private let operationCompletionGate: @Sendable () -> Void
  private let cancellationRegistrationGate: @Sendable () -> Void
  private let wallMilliseconds: @Sendable () -> Int64
  private let deliveryValidity = ViewerStoreExplorerGenerationValidity()
  private var sealed = false
  private var operations: [UUID: OperationRecord] = [:]
  private var pendingOperationIDs: [UUID] = []
  private var drainScheduled = false
  private var activeOperationID: UUID?

  init(
    generation: UInt64,
    coordinator: ViewerStoreCoordinator,
    operationExecutionGate: @escaping @Sendable () -> Void,
    operationCompletionGate: @escaping @Sendable () -> Void,
    cancellationRegistrationGate: @escaping @Sendable () -> Void,
    wallMilliseconds: @escaping @Sendable () -> Int64
  ) {
    self.generation = generation
    coordinatorIdentity = ObjectIdentifier(coordinator)
    services = coordinator.services
    arbiter = ViewerExplorerQueryArbiter(
      queryService: services.query,
      diagnosticService: services.diagnostics,
      performanceService: services.performance,
      exportService: services.export
    )
    self.operationExecutionGate = operationExecutionGate
    self.operationCompletionGate = operationCompletionGate
    self.cancellationRegistrationGate = cancellationRegistrationGate
    self.wallMilliseconds = wallMilliseconds
    queue = DispatchQueue(
      label: "com.nearwire.viewer.explorer-generation.\(generation)",
      qos: .userInitiated
    )
  }

  func loadChangeSnapshot(
    completion: @escaping ViewerStoreExplorerGateway.SnapshotCompletion
  ) -> ViewerStoreExplorerOperationToken {
    submit(completion: completion) { [services] in
      services.eventStore.currentChangeSnapshot()
    }
  }

  func replaceQuery(
    _ query: ViewerEventQuery,
    completion:
      @escaping @Sendable (
        Result<ViewerQuerySnapshot, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [arbiter] operationID in
      try arbiter.replaceQuery(query, operationID: operationID)
    }
  }

  func loadPage(
    cursor: ViewerEventCursor?,
    direction: ViewerStoreQueryService.Direction,
    limit: Int,
    completion: @escaping @Sendable (Result<ViewerEventPage, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [arbiter] operationID in
      try arbiter.page(
        cursor: cursor,
        direction: direction,
        limit: limit,
        operationID: operationID
      )
    }
  }

  func beginPerformanceTraversal(
    recordingID: Int64,
    deviceSessionID: Int64,
    lowerMonotonicNanoseconds: Int64,
    upperMonotonicNanoseconds: Int64,
    completion:
      @escaping @Sendable (
        Result<ViewerPerformanceStoreScope, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(
      discardedSuccessfulCandidate: { [arbiter] in arbiter.endPerformanceTraversal() },
      completion: completion,
      operation: { [arbiter, generation] operationID in
        try arbiter.replacePerformanceTraversal(
          storeGeneration: generation,
          recordingID: recordingID,
          deviceSessionID: deviceSessionID,
          lowerMonotonicNanoseconds: lowerMonotonicNanoseconds,
          upperMonotonicNanoseconds: upperMonotonicNanoseconds,
          operationID: operationID
        )
      }
    )
  }

  func loadPerformanceEventPage(
    continuation: ViewerPerformanceContinuation?,
    completion:
      @escaping @Sendable (
        Result<ViewerPerformanceEventPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(
      discardedSuccessfulCandidate: { [arbiter] in arbiter.endPerformanceTraversal() },
      completion: completion,
      operation: { [arbiter] operationID in
        try arbiter.performanceEventPage(
          continuation: continuation,
          operationID: operationID
        )
      }
    )
  }

  func loadPerformanceGapPage(
    completion:
      @escaping @Sendable (
        Result<ViewerPerformanceGapPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(
      discardedSuccessfulCandidate: { [arbiter] in arbiter.endPerformanceTraversal() },
      completion: completion,
      operation: { [arbiter] operationID in
        try arbiter.performanceGapPage(operationID: operationID)
      }
    )
  }

  func resolvePerformanceEventLocator(
    recordingID: Int64,
    deviceSessionID: Int64,
    key: ViewerEventJournalKey,
    completion:
      @escaping @Sendable (
        Result<ViewerPerformanceEventLocator?, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [arbiter] operationID in
      try arbiter.resolvePerformanceEventLocator(
        recordingID: recordingID,
        deviceSessionID: deviceSessionID,
        key: key,
        operationID: operationID
      )
    }
  }

  func loadDetail(
    rowID: Int64,
    completion:
      @escaping @Sendable (
        Result<ViewerStoredEventDetail?, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [arbiter] operationID in
      try arbiter.detail(rowID: rowID, operationID: operationID)
    }
  }

  func makeFilteredExportScope(
    completion:
      @escaping @Sendable (
        Result<ViewerFilteredExportScope, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [arbiter] operationID in
      try arbiter.makeFilteredExportScope(operationID: operationID)
    }
  }

  func endTraversal(
    completion: @escaping @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submit(completion: completion) { [arbiter] in
      arbiter.endTraversal()
    }
  }

  func endPerformanceTraversal(
    completion: @escaping @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submit(completion: completion) { [arbiter] in
      arbiter.endPerformanceTraversal()
    }
  }

  func loadRecordingCatalog(
    cursor: ViewerRecordingCatalogCursor?,
    direction: ViewerCatalogPageDirection,
    limit: Int,
    completion:
      @escaping @Sendable (
        Result<ViewerRecordingCatalogPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [generation, services] operationID in
      try services.catalog.recordingPage(
        storeGeneration: generation,
        cursor: cursor,
        direction: direction,
        limit: limit,
        operationID: operationID
      )
    }
  }

  func loadRecordingIdentity(
    logicalID: UUID,
    snapshot: ViewerRecordingCatalogSnapshot,
    completion:
      @escaping @Sendable (
        Result<ViewerRecordingCatalogPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [generation, services] operationID in
      try services.catalog.recordingIdentityPage(
        logicalID: logicalID,
        snapshot: snapshot,
        storeGeneration: generation,
        operationID: operationID
      )
    }
  }

  func loadDeviceCatalog(
    recordingID: Int64,
    recordingSnapshot: ViewerRecordingCatalogSnapshot?,
    cursor: ViewerDeviceCatalogCursor?,
    direction: ViewerCatalogPageDirection,
    limit: Int,
    completion:
      @escaping @Sendable (
        Result<ViewerDeviceCatalogPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [generation, services] operationID in
      try services.catalog.devicePage(
        recordingID: recordingID,
        storeGeneration: generation,
        recordingSnapshot: recordingSnapshot,
        cursor: cursor,
        direction: direction,
        limit: limit,
        operationID: operationID
      )
    }
  }

  func loadDeviceIdentities(
    recordingID: Int64,
    logicalIDs: [UUID],
    snapshot: ViewerDeviceCatalogSnapshot,
    completion:
      @escaping @Sendable (
        Result<ViewerDeviceCatalogPage, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [generation, services] operationID in
      try services.catalog.deviceIdentityPage(
        recordingID: recordingID,
        logicalIDs: logicalIDs,
        snapshot: snapshot,
        storeGeneration: generation,
        operationID: operationID
      )
    }
  }

  func loadGapPage(
    deviceSessionIDs: [Int64],
    cursor: ViewerGapCursor?,
    direction: ViewerStoreQueryService.Direction,
    limit: Int,
    completion: @escaping @Sendable (Result<ViewerGapPage, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [arbiter] operationID in
      try arbiter.gapPage(
        deviceSessionIDs: deviceSessionIDs,
        cursor: cursor,
        direction: direction,
        limit: limit,
        operationID: operationID
      )
    }
  }

  func loadCausality(
    rootRowID: Int64,
    completion:
      @escaping @Sendable (
        Result<ViewerCausalityGraph, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [arbiter] operationID in
      try arbiter.causality(rootRowID: rootRowID, operationID: operationID)
    }
  }

  func updateRecording(
    _ target: ViewerStoreRecordingTarget,
    name: String?,
    note: String?,
    pinned: Bool,
    completion:
      @escaping @Sendable (
        Result<ViewerStoreRecordingTarget, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submit(interruptsWhenActive: false, completion: completion) {
      [generation, services, wallMilliseconds] in
      guard target.coordinatorGeneration == generation else {
        throw ViewerStoreExplorerFailure.storeReplaced
      }
      let revision = try services.maintenance.updateRecording(
        ViewerRecordingRevision(
          recordingID: target.recordingID,
          revision: target.revision
        ),
        name: name,
        note: note,
        pinned: pinned,
        wallMilliseconds: wallMilliseconds()
      )
      return ViewerStoreRecordingTarget(
        coordinatorGeneration: generation,
        recordingID: revision.recordingID,
        revision: revision.revision
      )
    }
  }

  func appendAnnotation(
    _ target: ViewerStoreRecordingTarget,
    body: String,
    completion: @escaping @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submit(interruptsWhenActive: false, completion: completion) {
      [generation, services, wallMilliseconds] in
      guard target.coordinatorGeneration == generation else {
        throw ViewerStoreExplorerFailure.storeReplaced
      }
      _ = try services.maintenance.appendAnnotation(
        ViewerRecordingRevision(
          recordingID: target.recordingID,
          revision: target.revision
        ),
        body: body,
        wallMilliseconds: wallMilliseconds()
      )
    }
  }

  func prepareDelete(
    _ target: ViewerStoreRecordingTarget,
    completion:
      @escaping @Sendable (
        Result<ViewerStoreDeleteConfirmation, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submit(interruptsWhenActive: false, completion: completion) { [generation, services] in
      guard target.coordinatorGeneration == generation else {
        throw ViewerStoreExplorerFailure.storeReplaced
      }
      let value = try services.maintenance.prepareDelete(
        ViewerRecordingRevision(
          recordingID: target.recordingID,
          revision: target.revision
        )
      )
      return ViewerStoreDeleteConfirmation(
        coordinatorGeneration: generation,
        value: value,
        recordingID: value.recordingID
      )
    }
  }

  func requestDelete(
    _ confirmation: ViewerStoreDeleteConfirmation,
    completion: @escaping @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submit(interruptsWhenActive: false, completion: completion) {
      [generation, services, wallMilliseconds] in
      guard confirmation.coordinatorGeneration == generation else {
        throw ViewerStoreExplorerFailure.storeReplaced
      }
      try services.maintenance.requestDelete(
        confirmation.value,
        wallMilliseconds: wallMilliseconds()
      )
    }
  }

  func prepareCompleteExport(
    _ target: ViewerStoreRecordingTarget,
    completion:
      @escaping @Sendable (
        Result<ViewerStoreExportTicket, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [arbiter, generation] operationID in
      guard target.coordinatorGeneration == generation else {
        throw ViewerStoreExplorerFailure.storeReplaced
      }
      let scope = try arbiter.makeCompleteExportScope(
        recordingID: target.recordingID,
        operationID: operationID
      )
      let preflight = try arbiter.preflight(scope: scope, operationID: operationID)
      return ViewerStoreExportTicket(
        eventCount: preflight.eventCount,
        disclosure: preflight.disclosure,
        coordinatorGeneration: generation,
        selection: .complete(scope)
      )
    }
  }

  func prepareFilteredExport(
    completion:
      @escaping @Sendable (
        Result<ViewerStoreExportTicket, ViewerStoreExplorerFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(completion: completion) { [arbiter, generation] operationID in
      let scope = try arbiter.makeFilteredExportScope(operationID: operationID)
      let preflight = try arbiter.preflight(scope: scope, operationID: operationID)
      return ViewerStoreExportTicket(
        eventCount: preflight.eventCount,
        disclosure: preflight.disclosure,
        coordinatorGeneration: generation,
        selection: .filtered(scope)
      )
    }
  }

  func executeExport(
    _ ticket: ViewerStoreExportTicket,
    to destination: URL,
    completion: @escaping @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(
      successfulCandidateIsAuthoritative: true,
      completion: completion
    ) { [arbiter, generation] operationID in
      guard ticket.coordinatorGeneration == generation else {
        throw ViewerStoreExplorerFailure.storeReplaced
      }
      switch ticket.selection {
      case .complete(let scope):
        do {
          try arbiter.export(scope: scope, to: destination, operationID: operationID)
        } catch ViewerStoreError.workLimitExceeded {
          throw ViewerStoreExplorerFailure.exportTooLarge
        }
      case .filtered(let scope):
        try arbiter.export(scope: scope, to: destination, operationID: operationID)
      }
    }
  }

  func cancel(_ token: ViewerStoreExplorerOperationToken) {
    let shouldInterrupt: Bool
    var queuedRejection: (@Sendable (ViewerStoreExplorerFailure) -> Void)?
    lock.lock()
    guard token.coordinatorGeneration == generation,
      var operation = operations[token.operationID]
    else {
      lock.unlock()
      return
    }
    switch operation.state {
    case .queued:
      operations.removeValue(forKey: token.operationID)
      pendingOperationIDs.removeAll { $0 == token.operationID }
      queuedRejection = operation.reject
      shouldInterrupt = false
    case .active where operation.interruptsWhenActive:
      operation.state = .cancelled
      operations[token.operationID] = operation
      shouldInterrupt = activeOperationID == token.operationID
    case .active:
      shouldInterrupt = false
    case .completing, .cancelled, .storeReplaced:
      shouldInterrupt = false
    }
    if shouldInterrupt {
      cancellationRegistrationGate()
      cancelOperation(token.operationID)
    }
    lock.unlock()
    if let queuedRejection {
      retireRejectedOperation(token.operationID)
      deliverRejectedOperation(failure: .cancelled, rejection: queuedRejection)
    }
  }

  func sealAndWait() -> [ViewerStoreExplorerDeferredDelivery] {
    invalidateDelivery()
    let interruptOperationID: UUID?
    var queuedRejections: [(UUID, @Sendable (ViewerStoreExplorerFailure) -> Void)] = []
    lock.lock()
    if !sealed {
      sealed = true
      for operationID in pendingOperationIDs {
        if let operation = operations.removeValue(forKey: operationID) {
          queuedRejections.append((operationID, operation.reject))
        }
      }
      pendingOperationIDs.removeAll(keepingCapacity: false)
      for operationID in Array(operations.keys) {
        if var operation = operations[operationID], operation.state == .active {
          operation.state = .storeReplaced
          operations[operationID] = operation
        }
      }
    }
    interruptOperationID =
      activeOperationID.flatMap {
        operations[$0]?.interruptsWhenActive == true ? $0 : nil
      }
    if let interruptOperationID {
      cancellationRegistrationGate()
      cancelOperation(interruptOperationID)
    }
    lock.unlock()
    for (operationID, _) in queuedRejections {
      retireRejectedOperation(operationID)
    }
    completionGroup.wait()
    arbiter.close()
    return queuedRejections.map { _, rejection in
      { rejection(.storeReplaced) }
    }
  }

  var operationCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return operations.count
  }

  var pendingOperationCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return pendingOperationIDs.count
  }

  private func submit<Value: Sendable>(
    interruptsWhenActive: Bool = true,
    successfulCandidateIsAuthoritative: Bool = false,
    discardedSuccessfulCandidate: @escaping @Sendable () -> Void = {},
    completion: @escaping @Sendable (Result<Value, ViewerStoreExplorerFailure>) -> Void,
    operation: @escaping @Sendable () throws -> Value
  ) -> ViewerStoreExplorerOperationToken {
    submitIdentified(
      interruptsWhenActive: interruptsWhenActive,
      successfulCandidateIsAuthoritative: successfulCandidateIsAuthoritative,
      discardedSuccessfulCandidate: discardedSuccessfulCandidate,
      completion: completion
    ) { _ in
      try operation()
    }
  }

  private func submitIdentified<Value: Sendable>(
    interruptsWhenActive: Bool = true,
    successfulCandidateIsAuthoritative: Bool = false,
    discardedSuccessfulCandidate: @escaping @Sendable () -> Void = {},
    completion: @escaping @Sendable (Result<Value, ViewerStoreExplorerFailure>) -> Void,
    operation: @escaping @Sendable (UUID) throws -> Value
  ) -> ViewerStoreExplorerOperationToken {
    let token = ViewerStoreExplorerOperationToken(
      coordinatorGeneration: generation,
      operationID: UUID(),
      deliveryValidity: deliveryValidity
    )
    let execute: @Sendable () -> Void = { [self] in
      operationExecutionGate()
      let candidate: Result<Value, ViewerStoreExplorerFailure>
      if let failure = operationFailure(token.operationID) {
        candidate = .failure(failure)
      } else {
        candidate = Self.capture { try operation(token.operationID) }
      }
      operationCompletionGate()
      let result = finish(
        token.operationID,
        candidate: candidate,
        successfulCandidateIsAuthoritative: successfulCandidateIsAuthoritative
      )
      if case .success = candidate, case .failure = result {
        discardedSuccessfulCandidate()
      }
      prepareCompletion(token.operationID)
      complete(token.operationID)
      completion(result)
    }
    let reject: @Sendable (ViewerStoreExplorerFailure) -> Void = { failure in
      completion(.failure(failure))
    }
    let shouldSchedule: Bool
    lock.lock()
    guard !sealed else {
      lock.unlock()
      completion(.failure(.storeReplaced))
      return token
    }
    guard operations.count < Self.maximumRetainedOperations else {
      lock.unlock()
      completion(.failure(.busy))
      return token
    }
    operations[token.operationID] = OperationRecord(
      state: .queued,
      interruptsWhenActive: interruptsWhenActive,
      execute: execute,
      reject: reject
    )
    pendingOperationIDs.append(token.operationID)
    completionGroup.enter()
    shouldSchedule = !drainScheduled
    if shouldSchedule { drainScheduled = true }
    lock.unlock()

    if shouldSchedule { queue.async { [self] in drain() } }
    return token
  }

  private func cancelOperation(_ operationID: UUID) {
    arbiter.cancel(operationID: operationID)
    services.catalog.cancel(operationID: operationID)
  }

  private func drain() {
    while true {
      let execute: (@Sendable () -> Void)?
      lock.lock()
      if let operationID = pendingOperationIDs.first {
        pendingOperationIDs.removeFirst()
        if var operation = operations[operationID], operation.state == .queued {
          operation.state = .active
          operations[operationID] = operation
          activeOperationID = operationID
          execute = operation.execute
        } else {
          execute = nil
        }
        lock.unlock()
        execute?()
      } else {
        drainScheduled = false
        lock.unlock()
        return
      }
    }
  }

  private func operationFailure(_ operationID: UUID) -> ViewerStoreExplorerFailure? {
    lock.lock()
    defer { lock.unlock() }
    switch operations[operationID]?.state {
    case .active: return nil
    case .cancelled: return .cancelled
    case .queued, .completing, .storeReplaced, .none: return .storeReplaced
    }
  }

  private func finish<Value: Sendable>(
    _ operationID: UUID,
    candidate: Result<Value, ViewerStoreExplorerFailure>,
    successfulCandidateIsAuthoritative: Bool
  ) -> Result<Value, ViewerStoreExplorerFailure> {
    lock.lock()
    let state = operations[operationID]?.state
    if activeOperationID == operationID { activeOperationID = nil }
    if var operation = operations[operationID] {
      operation.state = .completing
      operations[operationID] = operation
    }
    lock.unlock()
    switch state {
    case .active: return candidate
    case .cancelled:
      if successfulCandidateIsAuthoritative, case .success = candidate { return candidate }
      return .failure(.cancelled)
    case .storeReplaced:
      if successfulCandidateIsAuthoritative, case .success = candidate { return candidate }
      return .failure(.storeReplaced)
    case .queued, .completing, .none:
      return .failure(.storeReplaced)
    }
  }

  private func prepareCompletion(_ operationID: UUID) {
    arbiter.clearCancellation(operationID: operationID)
    services.catalog.clearCancellation(operationID: operationID)
  }

  private func complete(_ operationID: UUID) {
    lock.lock()
    operations.removeValue(forKey: operationID)
    lock.unlock()
    completionGroup.leave()
  }

  private func retireRejectedOperation(_ operationID: UUID) {
    arbiter.clearCancellation(operationID: operationID)
    services.catalog.clearCancellation(operationID: operationID)
    completionGroup.leave()
  }

  private func deliverRejectedOperation(
    failure: ViewerStoreExplorerFailure,
    rejection: @Sendable (ViewerStoreExplorerFailure) -> Void
  ) {
    rejection(failure)
  }

  private static func capture<Value: Sendable>(
    _ operation: @Sendable () throws -> Value
  ) -> Result<Value, ViewerStoreExplorerFailure> {
    do {
      return .success(try operation())
    } catch let failure as ViewerStoreExplorerFailure {
      return .failure(failure)
    } catch let error as ViewerStoreError {
      switch error {
      case .cancelled:
        return .failure(.cancelled)
      case .invalidValue:
        return .failure(.invalidRequest)
      case .busy, .sqliteBusy, .staleObservation:
        return .failure(.busy)
      case .workLimitExceeded:
        return .failure(.refineQuery)
      case .invalidPath, .unsupportedSchema, .corruptStore, .capacityExceeded,
        .writeNotAuthorized, .unavailable:
        return .failure(.unavailable)
      }
    } catch let error as ViewerPerformanceStoreFailure {
      switch error {
      case .storeReplaced:
        return .failure(.storeReplaced)
      case .cancelled:
        return .failure(.cancelled)
      case .invalidScope, .invalidContinuation:
        return .failure(.invalidRequest)
      case .workLimitExceeded, .limitExceeded:
        return .failure(.refineQuery)
      case .invalidCarrier, .unavailable:
        return .failure(.unavailable)
      }
    } catch {
      return .failure(.unavailable)
    }
  }

  func invalidateDelivery() {
    deliveryValidity.invalidate()
  }
}

extension ViewerStoreExplorerOperationToken: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreExplorerOperationToken(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoreRecordingTarget: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreRecordingTarget(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoreDeleteConfirmation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreDeleteConfirmation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoreExportTicket: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreExportTicket(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoreExplorerGateway: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreExplorerGateway(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
