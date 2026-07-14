import Foundation

struct ViewerPerformanceRawEventRequest: Equatable, Sendable {
  let sourceGeneration: UInt64
  let key: ViewerEventJournalKey

  init(sourceGeneration: UInt64, key: ViewerEventJournalKey) throws {
    guard sourceGeneration > 0 else { throw ViewerPerformanceStoreFailure.invalidScope }
    self.sourceGeneration = sourceGeneration
    self.key = key
  }
}

struct ViewerPerformanceResolvedRawEvent: Equatable, Sendable {
  let sourceGeneration: UInt64
  let key: ViewerEventJournalKey
  let locator: ViewerPerformanceEventLocator

  init(
    sourceGeneration: UInt64,
    key: ViewerEventJournalKey,
    locator: ViewerPerformanceEventLocator
  ) throws {
    guard sourceGeneration > 0 else { throw ViewerPerformanceStoreFailure.invalidScope }
    switch locator {
    case .durable(let rowID, let deviceSessionID):
      guard rowID > 0, deviceSessionID > 0 else {
        throw ViewerPerformanceStoreFailure.invalidCarrier
      }
    case .transient:
      break
    }
    self.sourceGeneration = sourceGeneration
    self.key = key
    self.locator = locator
  }
}

enum ViewerPerformanceRawEventGuidance: UInt8, Equatable, Sendable {
  case sourceChanged
  case eventNoLongerAvailable
  case storageUnavailable

  var message: String {
    switch self {
    case .sourceChanged:
      return "The performance source changed. Select a current data point and try again."
    case .eventNoLongerAvailable:
      return "The source Event was deleted or evicted and is no longer available."
    case .storageUnavailable:
      return "Storage is unavailable and the source Event is no longer in the live window."
    }
  }
}

enum ViewerPerformanceRawEventResolutionOutcome: Equatable, Sendable {
  case resolved(ViewerPerformanceResolvedRawEvent)
  case guidance(ViewerPerformanceRawEventGuidance)
  case failed(ViewerStoreExplorerFailure)
  case cancelled
}

enum ViewerPerformanceRawEventRevalidation: Equatable, Sendable {
  case explorerIdentity(ViewerExplorerEventIdentity)
  case requiresResolution
  case guidance(ViewerPerformanceRawEventGuidance)
}

struct ViewerPerformanceRawEventStoreOperation: Hashable, Sendable {
  let id: UUID
  fileprivate let gatewayToken: ViewerStoreExplorerOperationToken?

  init(id: UUID = UUID()) {
    self.id = id
    gatewayToken = nil
  }

  fileprivate init(gatewayToken: ViewerStoreExplorerOperationToken) {
    id = gatewayToken.operationID
    self.gatewayToken = gatewayToken
  }

  static func == (
    lhs: ViewerPerformanceRawEventStoreOperation,
    rhs: ViewerPerformanceRawEventStoreOperation
  ) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

struct ViewerPerformanceRawEventStoreDriver: @unchecked Sendable {
  typealias Completion =
    @Sendable (
      Result<ViewerPerformanceEventLocator?, ViewerStoreExplorerFailure>
    ) -> Void

  let resolve:
    @Sendable (
      Int64,
      Int64,
      ViewerEventJournalKey,
      @escaping Completion
    ) -> ViewerPerformanceRawEventStoreOperation
  let cancel: @Sendable (ViewerPerformanceRawEventStoreOperation) -> Void

  init(
    resolve:
      @escaping @Sendable (
        Int64,
        Int64,
        ViewerEventJournalKey,
        @escaping Completion
      ) -> ViewerPerformanceRawEventStoreOperation,
    cancel: @escaping @Sendable (ViewerPerformanceRawEventStoreOperation) -> Void
  ) {
    self.resolve = resolve
    self.cancel = cancel
  }

  init(gateway: ViewerStoreExplorerGateway) {
    resolve = { recordingID, deviceSessionID, key, completion in
      ViewerPerformanceRawEventStoreOperation(
        gatewayToken: gateway.resolvePerformanceEventLocator(
          recordingID: recordingID,
          deviceSessionID: deviceSessionID,
          key: key,
          completion: completion
        )
      )
    }
    cancel = { operation in
      guard let token = operation.gatewayToken else { return }
      gateway.cancel(token)
    }
  }
}

@MainActor
final class ViewerPerformanceRawEventResolver: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  typealias Completion =
    @MainActor @Sendable (
      ViewerPerformanceRawEventResolutionOutcome
    ) -> Void

  private enum Phase: Equatable {
    case initialDurableLookup
    case durableConfirmation
  }

  private struct ActiveResolution {
    let id: UUID
    let workID: UUID
    let request: ViewerPerformanceRawEventRequest
    let scope: ViewerPerformanceDashboardScope
    let target: ViewerPerformanceDashboardTarget
    let completion: Completion
    var phase: Phase
    var firstLiveCandidate: ViewerPerformanceEventLocator?
    var operation: ViewerPerformanceRawEventStoreOperation?
  }

  private let store: ViewerPerformanceRawEventStoreDriver
  private let live: any ViewerLiveObservationProviding
  private let workTracker = ViewerAsyncWorkTracker()
  private var active: ActiveResolution?
  private var sealed = false

  init(
    store: ViewerPerformanceRawEventStoreDriver,
    live: any ViewerLiveObservationProviding
  ) {
    self.store = store
    self.live = live
  }

  @discardableResult
  func resolve(
    _ request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget,
    completion: @escaping Completion
  ) -> Bool {
    guard !sealed else {
      completion(.failed(.storeReplaced))
      return false
    }
    guard active == nil else {
      completion(.failed(.busy))
      return false
    }
    guard Self.validates(request: request, scope: scope, target: target) else {
      completion(.guidance(.sourceChanged))
      return true
    }
    let workID = workTracker.begin()
    let id = UUID()
    active = ActiveResolution(
      id: id,
      workID: workID,
      request: request,
      scope: scope,
      target: target,
      completion: completion,
      phase: .initialDurableLookup,
      firstLiveCandidate: nil,
      operation: nil
    )
    startStoreLookup(id: id)
    return true
  }

  func cancelActiveAndWait() -> Task<Void, Never> {
    if let operation = active?.operation { store.cancel(operation) }
    return workTracker.waitTask()
  }

  func sealAndWait() -> Task<Void, Never> {
    guard !sealed else { return workTracker.waitTask() }
    sealed = true
    return cancelActiveAndWait()
  }

  var pendingWorkCount: Int { workTracker.activeCount }

  func revalidate(
    _ resolved: ViewerPerformanceResolvedRawEvent,
    request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget
  ) -> ViewerPerformanceRawEventRevalidation {
    guard Self.validates(request: request, scope: scope, target: target),
      resolved.sourceGeneration == request.sourceGeneration,
      resolved.key == request.key
    else { return .guidance(.sourceChanged) }
    switch resolved.locator {
    case .durable(let rowID, let deviceSessionID):
      guard deviceSessionID == target.storeIdentity.deviceSessionID else {
        return .guidance(.sourceChanged)
      }
      return .explorerIdentity(.durable(rowID: rowID))
    case .transient:
      guard case .current = target.source else {
        return .guidance(.sourceChanged)
      }
      guard live.performanceEventLocator(for: request.key) == resolved.locator else {
        return .requiresResolution
      }
      return .explorerIdentity(.transient(request.key))
    }
  }

  nonisolated var description: String { "ViewerPerformanceRawEventResolver(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private func startStoreLookup(id: UUID) {
    guard let active, active.id == id else { return }
    let identity = active.target.storeIdentity
    let operation = store.resolve(
      identity.recordingID,
      identity.deviceSessionID,
      active.request.key
    ) { [weak self] result in
      Task { @MainActor in self?.receive(result, id: id) }
    }
    guard self.active?.id == id else {
      store.cancel(operation)
      return
    }
    self.active?.operation = operation
  }

  private func receive(
    _ result: Result<ViewerPerformanceEventLocator?, ViewerStoreExplorerFailure>,
    id: UUID
  ) {
    guard var active, active.id == id else { return }
    active.operation = nil
    self.active = active
    switch active.phase {
    case .initialDurableLookup:
      receiveInitial(result, active: active)
    case .durableConfirmation:
      receiveConfirmation(result, active: active)
    }
  }

  private func receiveInitial(
    _ result: Result<ViewerPerformanceEventLocator?, ViewerStoreExplorerFailure>,
    active: ActiveResolution
  ) {
    switch result {
    case .success(.some(let locator)):
      finishStoreResolved(locator, active: active)
    case .success(nil):
      guard case .current = active.target.source else {
        finish(.guidance(.eventNoLongerAvailable), id: active.id)
        return
      }
      var next = active
      next.phase = .durableConfirmation
      next.firstLiveCandidate = live.performanceEventLocator(for: active.request.key)
      self.active = next
      startStoreLookup(id: active.id)
    case .failure(.cancelled):
      finish(.cancelled, id: active.id)
    case .failure(.storeReplaced):
      finish(.guidance(.sourceChanged), id: active.id)
    case .failure(.unavailable):
      if let liveLocator = live.performanceEventLocator(for: active.request.key) {
        finishResolved(liveLocator, active: active)
      } else {
        finish(.guidance(.storageUnavailable), id: active.id)
      }
    case .failure(let failure):
      finish(.failed(failure), id: active.id)
    }
  }

  private func receiveConfirmation(
    _ result: Result<ViewerPerformanceEventLocator?, ViewerStoreExplorerFailure>,
    active: ActiveResolution
  ) {
    switch result {
    case .success(.some(let locator)):
      finishStoreResolved(locator, active: active)
    case .success(nil):
      let currentLive = live.performanceEventLocator(for: active.request.key)
      if let currentLive,
        active.firstLiveCandidate == nil || active.firstLiveCandidate == currentLive
      {
        finishResolved(currentLive, active: active)
      } else {
        finish(.guidance(.eventNoLongerAvailable), id: active.id)
      }
    case .failure(.cancelled):
      finish(.cancelled, id: active.id)
    case .failure(.storeReplaced):
      finish(.guidance(.sourceChanged), id: active.id)
    case .failure(.unavailable):
      if let currentLive = live.performanceEventLocator(for: active.request.key) {
        finishResolved(currentLive, active: active)
      } else {
        finish(.guidance(.storageUnavailable), id: active.id)
      }
    case .failure(let failure):
      finish(.failed(failure), id: active.id)
    }
  }

  private func finishResolved(
    _ locator: ViewerPerformanceEventLocator,
    active: ActiveResolution
  ) {
    do {
      switch locator {
      case .durable(_, let deviceSessionID):
        guard deviceSessionID == active.target.storeIdentity.deviceSessionID else {
          finish(.guidance(.sourceChanged), id: active.id)
          return
        }
      case .transient:
        guard case .current = active.target.source else {
          finish(.guidance(.sourceChanged), id: active.id)
          return
        }
      }
      finish(
        .resolved(
          try ViewerPerformanceResolvedRawEvent(
            sourceGeneration: active.request.sourceGeneration,
            key: active.request.key,
            locator: locator
          )
        ),
        id: active.id
      )
    } catch {
      finish(.failed(.invalidRequest), id: active.id)
    }
  }

  private func finishStoreResolved(
    _ locator: ViewerPerformanceEventLocator,
    active: ActiveResolution
  ) {
    guard case .durable = locator else {
      finish(.failed(.invalidRequest), id: active.id)
      return
    }
    finishResolved(locator, active: active)
  }

  private func finish(
    _ outcome: ViewerPerformanceRawEventResolutionOutcome,
    id: UUID
  ) {
    guard let active, active.id == id else { return }
    self.active = nil
    active.completion(outcome)
    workTracker.complete(active.workID)
  }

  private static func validates(
    request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget
  ) -> Bool {
    guard request.sourceGeneration == scope.sourceGeneration,
      target.source == scope.source
    else { return false }
    switch scope.source {
    case .current(let runtimeLogicalID, let connectionID):
      return request.key.runtimeLogicalID == runtimeLogicalID
        && request.key.connectionID == connectionID
    case .historical(_, _, let recordingLogicalID, let deviceLogicalID):
      return request.key.runtimeLogicalID == recordingLogicalID
        && request.key.connectionID == deviceLogicalID
    }
  }
}

extension ViewerPerformanceRawEventRequest: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceRawEventRequest(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceResolvedRawEvent: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceResolvedRawEvent(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceRawEventResolutionOutcome: CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceRawEventResolutionOutcome(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerPerformanceRawEventStoreDriver: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceRawEventStoreDriver(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
