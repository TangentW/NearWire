import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

protocol ViewerSessionControlling: AnyObject, Sendable {
  var runtimeLogicalID: UUID { get }
  var managerGeneration: UInt64 { get }

  func setSnapshotHandler(_ handler: @escaping @Sendable ([ViewerSessionSnapshot]) -> Void)
  func disconnect(connectionID: UUID)
  func updatePolicy(connectionID: UUID, policy: ViewerRatePolicy)
  func controlTargets() -> [ViewerControlTarget]
  func send(
    _ prepared: ViewerPreparedControlEvent,
    to capabilities: [ViewerControlTargetCapability]
  ) throws -> [ViewerControlTargetResult]

  @discardableResult
  func setNickname(_ nickname: String?, route: ViewerLogicalRoute) -> Bool
}

protocol ViewerLiveObservationProviding: AnyObject, Sendable {
  var runtimeLogicalID: UUID { get }
  func snapshot() -> ViewerLiveProjectionSnapshot
  func freezePerformance(connectionID: UUID) throws -> ViewerPerformanceLiveSlice
  func performanceEventLocator(for key: ViewerEventJournalKey) -> ViewerPerformanceEventLocator?
  func setRefreshHandler(_ handler: @escaping @Sendable (UInt64) -> Void)
  func storeStateChanged(_ state: ViewerStoreStatus.State)
  func setPresentationPaused(_ paused: Bool)
  func durableRowBecameVisible(key: ViewerEventJournalKey, observationID: UUID)
}

extension ViewerLiveObservationProviding {
  func performanceEventLocator(for key: ViewerEventJournalKey) -> ViewerPerformanceEventLocator? {
    nil
  }
}

final class ViewerCompositeSessionJournal: ViewerSessionJournaling, @unchecked Sendable {
  let runtimeLogicalID: UUID

  private let durableJournal: any ViewerSessionJournaling
  private let liveWindow: ViewerLiveEventWindow

  init(
    runtimeLogicalID: UUID,
    durableJournal: any ViewerSessionJournaling,
    liveWindow: ViewerLiveEventWindow
  ) {
    precondition(liveWindow.runtimeLogicalID == runtimeLogicalID)
    self.runtimeLogicalID = runtimeLogicalID
    self.durableJournal = durableJournal
    self.liveWindow = liveWindow
  }

  func runtimeStarted(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {
    guard logicalID == runtimeLogicalID else { return }
    durableJournal.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: monotonicNanoseconds
    )
  }

  func sessionStarted(runtimeLogicalID: UUID, _ context: ViewerAdmissionSessionContext) {
    guard runtimeLogicalID == self.runtimeLogicalID else { return }
    if let metadata = try? ViewerFrozenSessionMetadata(context: context, nickname: nil) {
      liveWindow.sessionStarted(metadata, connectionID: context.connectionID)
    }
    durableJournal.sessionStarted(runtimeLogicalID: runtimeLogicalID, context)
  }

  func eventCommitted(
    _ observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) {
    guard observation.key.runtimeLogicalID == runtimeLogicalID else {
      outcome(.sealed)
      return
    }
    let offer = liveWindow.offer(observation) { [weak self] decision in
      guard let self else {
        outcome(.sealed)
        return
      }
      self.resolveLiveDecision(decision, observation: observation, outcome: outcome)
    }
    resolveLiveDecision(offer, observation: observation, outcome: outcome)
  }

  private func resolveLiveDecision(
    _ decision: ViewerLiveEventOfferOutcome,
    observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) {
    switch decision {
    case .accepted, .untracked:
      durableJournal.eventCommitted(observation) { [weak liveWindow] result in
        liveWindow?.applyStoreOutcome(
          result,
          key: observation.key,
          observationID: observation.observationID
        )
        outcome(result)
      }
    case .deferred:
      break
    case .identical:
      outcome(.identical)
    case .presentationConflict:
      outcome(.presentationConflict)
    case .sealed:
      outcome(.sealed)
    }
  }

  func uplinkTerminated(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    direction: EventDirection,
    wireSequence: UInt64,
    disposition: ViewerStoredDisposition,
    monotonicNanoseconds: UInt64
  ) {
    guard runtimeLogicalID == self.runtimeLogicalID else { return }
    liveWindow.laterDisposition(
      key: ViewerEventJournalKey(
        runtimeLogicalID: runtimeLogicalID,
        connectionID: connectionID,
        direction: direction,
        wireSequence: wireSequence
      ),
      disposition: disposition
    )
    durableJournal.uplinkTerminated(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      direction: direction,
      wireSequence: wireSequence,
      disposition: disposition,
      monotonicNanoseconds: monotonicNanoseconds
    )
  }

  func policyChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    policy: ViewerRatePolicy,
    monotonicNanoseconds: UInt64
  ) {
    guard runtimeLogicalID == self.runtimeLogicalID else { return }
    durableJournal.policyChanged(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      policy: policy,
      monotonicNanoseconds: monotonicNanoseconds
    )
  }

  func dropsChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    samples: [ViewerDropJournalSample],
    monotonicNanoseconds: UInt64
  ) {
    guard runtimeLogicalID == self.runtimeLogicalID else { return }
    liveWindow.dropsChanged(connectionID: connectionID, samples: samples)
    durableJournal.dropsChanged(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      samples: samples,
      monotonicNanoseconds: monotonicNanoseconds
    )
  }

  func sessionEnded(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {
    guard runtimeLogicalID == self.runtimeLogicalID else { return }
    liveWindow.sessionEnded(
      connectionID: connectionID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: monotonicNanoseconds
    )
    durableJournal.sessionEnded(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: monotonicNanoseconds
    )
  }

  func retryStorage() {
    durableJournal.retryStorage()
  }

  func runtimeEnded(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) async {
    guard logicalID == runtimeLogicalID else { return }
    await liveWindow.finishIngress()
    await durableJournal.runtimeEnded(
      logicalID: logicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: monotonicNanoseconds
    )
    await liveWindow.runtimeEnded()
  }
}

struct ViewerRuntimeExplorerInputs: @unchecked Sendable {
  let runtimeLogicalID: UUID
  let storeGateway: ViewerStoreExplorerGateway
  let liveObservations: any ViewerLiveObservationProviding

  init(
    runtimeLogicalID: UUID,
    storeGateway: ViewerStoreExplorerGateway,
    liveObservations: any ViewerLiveObservationProviding
  ) {
    precondition(liveObservations.runtimeLogicalID == runtimeLogicalID)
    self.runtimeLogicalID = runtimeLogicalID
    self.storeGateway = storeGateway
    self.liveObservations = liveObservations
  }
}

final class ViewerOperationDeliveryGate: @unchecked Sendable {
  private enum State: Equatable {
    case waiting
    case deliveryClaimed
    case cancelled
  }

  private let lock = NSLock()
  private let deliveryClaimed: @Sendable () -> Void
  private var state = State.waiting

  init(deliveryClaimed: @escaping @Sendable () -> Void = {}) {
    self.deliveryClaimed = deliveryClaimed
  }

  func claimDelivery() -> Bool {
    lock.lock()
    guard state == .waiting else {
      lock.unlock()
      return false
    }
    state = .deliveryClaimed
    lock.unlock()
    deliveryClaimed()
    return true
  }

  /// Returns `true` when an already-claimed delivery still owns the tracked work.
  func cancel() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .waiting:
      state = .cancelled
      return false
    case .deliveryClaimed:
      state = .cancelled
      return true
    case .cancelled:
      return false
    }
  }
}

final class ViewerLatestMainActorDeliveryPump<Value: Sendable>: @unchecked Sendable {
  typealias Handler = @MainActor @Sendable (Value) -> Void

  private let lock = NSLock()
  private let workTracker = ViewerAsyncWorkTracker()
  private let handler: Handler
  private var pending: Value?
  private var drainID: UUID?
  private var processing = false
  private var sealed = false

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  @discardableResult
  func submit(_ value: Value) -> Bool {
    var displaced: Value?
    var shouldSchedule = false
    lock.lock()
    guard !sealed else {
      lock.unlock()
      return false
    }
    swap(&displaced, &pending)
    pending = value
    if drainID == nil {
      let id = UUID()
      drainID = id
      workTracker.begin(id: id)
      shouldSchedule = true
    }
    lock.unlock()
    withExtendedLifetime(displaced) {}
    if shouldSchedule { scheduleDrain() }
    return true
  }

  func cancelPending() {
    var displaced: Value?
    lock.lock()
    swap(&displaced, &pending)
    lock.unlock()
    withExtendedLifetime(displaced) {}
  }

  func sealAndWait() -> Task<Void, Never> {
    var displaced: Value?
    lock.lock()
    sealed = true
    swap(&displaced, &pending)
    lock.unlock()
    withExtendedLifetime(displaced) {}
    return workTracker.waitTask()
  }

  func waitForIdle() -> Task<Void, Never> {
    workTracker.waitTask()
  }

  var pendingWorkCount: Int { workTracker.activeCount }
  var maximumRetainedValueCount: Int { 2 }

  var retainedValueCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return (pending == nil ? 0 : 1) + (processing ? 1 : 0)
  }

  private func scheduleDrain() {
    Task { @MainActor [self] in drainOne() }
  }

  @MainActor
  private func drainOne() {
    let value: Value?
    var completionID: UUID?
    lock.lock()
    if sealed || pending == nil {
      value = nil
      completionID = drainID
      drainID = nil
    } else {
      value = pending
      pending = nil
      processing = true
    }
    lock.unlock()

    guard let value else {
      if let completionID { workTracker.complete(completionID) }
      return
    }

    handler(value)

    var displaced: Value?
    var shouldSchedule = false
    lock.lock()
    processing = false
    if sealed {
      swap(&displaced, &pending)
      completionID = drainID
      drainID = nil
    } else if pending != nil {
      shouldSchedule = true
    } else {
      completionID = drainID
      drainID = nil
    }
    lock.unlock()
    withExtendedLifetime(displaced) {}
    if let completionID { workTracker.complete(completionID) }
    if shouldSchedule { scheduleDrain() }
  }
}

final class ViewerAsyncWorkTracker: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let lock = NSLock()
  private let group = DispatchGroup()
  private var activeIDs: Set<UUID> = []

  @discardableResult
  func begin(id: UUID = UUID()) -> UUID {
    lock.lock()
    precondition(activeIDs.insert(id).inserted)
    group.enter()
    lock.unlock()
    return id
  }

  func complete(_ id: UUID) {
    lock.lock()
    let removed = activeIDs.remove(id) != nil
    lock.unlock()
    if removed { group.leave() }
  }

  var activeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return activeIDs.count
  }

  func waitTask() -> Task<Void, Never> {
    let group = group
    return Task {
      await withCheckedContinuation { continuation in
        group.notify(queue: .global(qos: .utility)) {
          continuation.resume()
        }
      }
    }
  }

  var description: String { "ViewerAsyncWorkTracker(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

final class ViewerRuntimeCleanupReceipt: @unchecked Sendable {
  private let lock = NSLock()
  private let start: @Sendable () -> Task<Void, Never>
  private var task: Task<Void, Never>?

  init(start: @escaping @Sendable () -> Task<Void, Never>) {
    self.start = start
  }

  func begin() -> Task<Void, Never> {
    lock.lock()
    if let task {
      lock.unlock()
      return task
    }
    let task = start()
    self.task = task
    lock.unlock()
    return task
  }
}

final class ViewerManagerGenerationSource: @unchecked Sendable {
  private let lock = NSLock()
  private var nextGeneration: UInt64 = 1

  func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let generation = nextGeneration
    nextGeneration = nextGeneration == UInt64.max ? 1 : nextGeneration + 1
    return generation
  }
}

struct ViewerRuntimeComponents: @unchecked Sendable {
  let runtimeLogicalID: UUID
  let managerGeneration: UInt64
  let handoffOwner: any ViewerAdmissionHandoffOwning
  let sessionControl: any ViewerSessionControlling
  let liveObservations: any ViewerLiveObservationProviding
  let compositeJournal: ViewerCompositeSessionJournal
  let explorerInputs: ViewerRuntimeExplorerInputs
  let cleanupReceipt: ViewerRuntimeCleanupReceipt

  init(
    runtimeLogicalID: UUID,
    managerGeneration: UInt64,
    handoffOwner: any ViewerAdmissionHandoffOwning,
    sessionControl: any ViewerSessionControlling,
    liveObservations: any ViewerLiveObservationProviding,
    compositeJournal: ViewerCompositeSessionJournal,
    explorerInputs: ViewerRuntimeExplorerInputs,
    cleanupReceipt: ViewerRuntimeCleanupReceipt
  ) {
    precondition(managerGeneration > 0)
    precondition((handoffOwner as AnyObject) === (sessionControl as AnyObject))
    precondition(sessionControl.runtimeLogicalID == runtimeLogicalID)
    precondition(sessionControl.managerGeneration == managerGeneration)
    precondition(liveObservations.runtimeLogicalID == runtimeLogicalID)
    precondition(compositeJournal.runtimeLogicalID == runtimeLogicalID)
    precondition(explorerInputs.runtimeLogicalID == runtimeLogicalID)
    self.runtimeLogicalID = runtimeLogicalID
    self.managerGeneration = managerGeneration
    self.handoffOwner = handoffOwner
    self.sessionControl = sessionControl
    self.liveObservations = liveObservations
    self.compositeJournal = compositeJournal
    self.explorerInputs = explorerInputs
    self.cleanupReceipt = cleanupReceipt
  }

  static func make(
    runtimeLogicalID: UUID,
    managerGeneration: UInt64,
    scheduler: ViewerAdmissionScheduler = .live,
    preferences: ViewerDevicePreferences = ViewerDevicePreferences(),
    uplinkSink: @escaping @Sendable (UUID, WireReceivedEvent) -> Void = { _, _ in },
    eventWallMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    },
    durableJournal: any ViewerSessionJournaling = ViewerNoopSessionJournal(),
    storeGateway: ViewerStoreExplorerGateway = ViewerStoreExplorerGateway()
  ) -> ViewerRuntimeComponents {
    let liveWindow = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      liveGeneration: managerGeneration
    )
    let compositeJournal = ViewerCompositeSessionJournal(
      runtimeLogicalID: runtimeLogicalID,
      durableJournal: durableJournal,
      liveWindow: liveWindow
    )
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: runtimeLogicalID,
      managerGeneration: managerGeneration,
      scheduler: scheduler,
      preferences: preferences,
      uplinkSink: uplinkSink,
      eventWallMilliseconds: eventWallMilliseconds,
      journal: compositeJournal
    )
    let explorerInputs = ViewerRuntimeExplorerInputs(
      runtimeLogicalID: runtimeLogicalID,
      storeGateway: storeGateway,
      liveObservations: liveWindow
    )
    let cleanupReceipt = ViewerRuntimeCleanupReceipt {
      manager.sealControlAdmission()
      return liveWindow.sealPresentation()
    }
    return ViewerRuntimeComponents(
      runtimeLogicalID: runtimeLogicalID,
      managerGeneration: managerGeneration,
      handoffOwner: manager,
      sessionControl: manager,
      liveObservations: liveWindow,
      compositeJournal: compositeJournal,
      explorerInputs: explorerInputs,
      cleanupReceipt: cleanupReceipt
    )
  }
}

extension ViewerCompositeSessionJournal: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerCompositeSessionJournal(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerRuntimeExplorerInputs: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRuntimeExplorerInputs(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerRuntimeCleanupReceipt: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRuntimeCleanupReceipt(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerRuntimeComponents: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRuntimeComponents(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
