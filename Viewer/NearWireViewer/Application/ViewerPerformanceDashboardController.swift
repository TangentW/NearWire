import Foundation

struct ViewerPerformanceDashboardTarget: Equatable, Sendable {
  private enum Storage: Equatable, Sendable {
    case current(recordingID: Int64, deviceSessionID: Int64)
    case historical(anchor: ViewerPerformanceAnchor)
  }

  let source: ViewerPerformanceSource
  let deviceStartMonotonicNanoseconds: Int64
  private let storage: Storage

  static func current(
    source: ViewerPerformanceSource,
    recordingID: Int64,
    deviceSessionID: Int64,
    deviceStartMonotonicNanoseconds: Int64
  ) throws -> ViewerPerformanceDashboardTarget {
    guard case .current = source, recordingID > 0, deviceSessionID > 0,
      deviceStartMonotonicNanoseconds >= 0
    else { throw ViewerPerformanceStoreFailure.invalidScope }
    return ViewerPerformanceDashboardTarget(
      source: source,
      deviceStartMonotonicNanoseconds: deviceStartMonotonicNanoseconds,
      storage: .current(recordingID: recordingID, deviceSessionID: deviceSessionID)
    )
  }

  static func historical(
    source: ViewerPerformanceSource,
    anchor: ViewerPerformanceAnchor
  ) throws -> ViewerPerformanceDashboardTarget {
    guard case .historical(let recordingID, let deviceSessionID, _, _) = source,
      recordingID > 0, deviceSessionID > 0, anchor.kind != .current
    else { throw ViewerPerformanceStoreFailure.invalidScope }
    return ViewerPerformanceDashboardTarget(
      source: source,
      deviceStartMonotonicNanoseconds: anchor.deviceStartMonotonicNanoseconds,
      storage: .historical(anchor: anchor)
    )
  }

  var currentStoreIdentity: (recordingID: Int64, deviceSessionID: Int64)? {
    guard case .current(let recordingID, let deviceSessionID) = storage else { return nil }
    return (recordingID, deviceSessionID)
  }

  var historicalAnchor: ViewerPerformanceAnchor? {
    guard case .historical(let anchor) = storage else { return nil }
    return anchor
  }

  var storeIdentity: (recordingID: Int64, deviceSessionID: Int64) {
    switch storage {
    case .current(let recordingID, let deviceSessionID):
      return (recordingID, deviceSessionID)
    case .historical:
      guard case .historical(let recordingID, let deviceSessionID, _, _) = source else {
        preconditionFailure("Validated historical target lost its source kind")
      }
      return (recordingID, deviceSessionID)
    }
  }
}

enum ViewerPerformanceProjectionPreparationMode: Equatable, Sendable {
  case storeBacked
  case freshLiveOnly
}

struct ViewerPerformanceProjectionPreparation: Equatable, Sendable {
  let receipt: ViewerPerformanceFrozenReceipt
  let bounds: ViewerPerformanceRangeBounds
  let deviceStartMonotonicNanoseconds: Int64
}

enum ViewerPerformanceProjectionDriverFailure: Error, Equatable, Sendable {
  case projection(ViewerPerformanceStoreFailure)
  case store(ViewerStoreExplorerFailure)
}

struct ViewerPerformanceProjectionOperationToken: Hashable, Sendable {
  let id: UUID
  fileprivate let gatewayToken: ViewerStoreExplorerOperationToken?

  init(
    id: UUID = UUID(),
    gatewayToken: ViewerStoreExplorerOperationToken? = nil
  ) {
    self.id = id
    self.gatewayToken = gatewayToken
  }
}

struct ViewerPerformanceProjectionDriver: @unchecked Sendable {
  typealias PreparationCompletion =
    @Sendable (
      Result<ViewerPerformanceProjectionPreparation, ViewerPerformanceProjectionDriverFailure>
    ) -> Void
  typealias EventPageCompletion =
    @Sendable (
      Result<ViewerPerformanceEventPage, ViewerStoreExplorerFailure>
    ) -> Void
  typealias GapPageCompletion =
    @Sendable (
      Result<ViewerPerformanceGapPage, ViewerStoreExplorerFailure>
    ) -> Void
  typealias EndCompletion = @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void

  let prepare:
    @Sendable (
      ViewerPerformanceDashboardTarget,
      ViewerPerformanceRangeKind,
      ViewerPerformanceProjectionPreparationMode,
      @escaping PreparationCompletion
    ) -> ViewerPerformanceProjectionOperationToken?
  let loadEventPage:
    @Sendable (
      ViewerPerformanceContinuation?,
      @escaping EventPageCompletion
    ) -> ViewerPerformanceProjectionOperationToken
  let loadGapPage:
    @Sendable (
      @escaping GapPageCompletion
    ) -> ViewerPerformanceProjectionOperationToken
  let endTraversal:
    @Sendable (
      @escaping EndCompletion
    ) -> ViewerPerformanceProjectionOperationToken
  let cancel: @Sendable (ViewerPerformanceProjectionOperationToken) -> Void
  let currentUptimeNanoseconds: @Sendable () -> Int64?

  init(
    prepare:
      @escaping @Sendable (
        ViewerPerformanceDashboardTarget,
        ViewerPerformanceRangeKind,
        ViewerPerformanceProjectionPreparationMode,
        @escaping PreparationCompletion
      ) -> ViewerPerformanceProjectionOperationToken?,
    loadEventPage:
      @escaping @Sendable (
        ViewerPerformanceContinuation?,
        @escaping EventPageCompletion
      ) -> ViewerPerformanceProjectionOperationToken,
    loadGapPage:
      @escaping @Sendable (
        @escaping GapPageCompletion
      ) -> ViewerPerformanceProjectionOperationToken,
    endTraversal:
      @escaping @Sendable (
        @escaping EndCompletion
      ) -> ViewerPerformanceProjectionOperationToken,
    cancel: @escaping @Sendable (ViewerPerformanceProjectionOperationToken) -> Void,
    currentUptimeNanoseconds: @escaping @Sendable () -> Int64?
  ) {
    self.prepare = prepare
    self.loadEventPage = loadEventPage
    self.loadGapPage = loadGapPage
    self.endTraversal = endTraversal
    self.cancel = cancel
    self.currentUptimeNanoseconds = currentUptimeNanoseconds
  }

  init(
    live: any ViewerLiveObservationProviding,
    storeGateway: ViewerStoreExplorerGateway,
    currentUptimeNanoseconds: @escaping @Sendable () -> Int64? = {
      let value = DispatchTime.now().uptimeNanoseconds
      return value > UInt64(Int64.max) ? nil : Int64(value)
    }
  ) {
    self.init(
      prepare: { target, rangeKind, mode, completion in
        do {
          switch target.source {
          case .current(let runtimeLogicalID, let connectionID):
            guard runtimeLogicalID == live.runtimeLogicalID,
              let identity = target.currentStoreIdentity
            else { throw ViewerPerformanceStoreFailure.invalidScope }
            let liveSlice = try live.freezePerformance(connectionID: connectionID)
            let anchor = try ViewerPerformanceAnchor.current(
              source: target.source,
              liveSlice: liveSlice,
              deviceStartMonotonicNanoseconds: target.deviceStartMonotonicNanoseconds
            )
            let bounds = try rangeKind.bounds(
              deviceStartMonotonicNanoseconds: anchor.deviceStartMonotonicNanoseconds,
              upperMonotonicNanoseconds: anchor.upperMonotonicNanoseconds
            )
            let scanLower = Self.scanLowerBound(anchor: anchor, bounds: bounds)
            if mode == .freshLiveOnly {
              completion(
                .success(
                  ViewerPerformanceProjectionPreparation(
                    receipt: ViewerPerformanceFrozenReceipt(
                      source: target.source,
                      storeScope: nil,
                      liveSlice: liveSlice
                    ),
                    bounds: bounds,
                    deviceStartMonotonicNanoseconds: anchor.deviceStartMonotonicNanoseconds
                  )
                )
              )
              return nil
            }
            let gatewayToken = storeGateway.beginPerformanceTraversal(
              recordingID: identity.recordingID,
              deviceSessionID: identity.deviceSessionID,
              lowerMonotonicNanoseconds: scanLower,
              upperMonotonicNanoseconds: anchor.upperMonotonicNanoseconds
            ) { result in
              switch result {
              case .success(let scope):
                completion(
                  .success(
                    ViewerPerformanceProjectionPreparation(
                      receipt: ViewerPerformanceFrozenReceipt(
                        source: target.source,
                        storeScope: scope,
                        liveSlice: liveSlice
                      ),
                      bounds: bounds,
                      deviceStartMonotonicNanoseconds: anchor.deviceStartMonotonicNanoseconds
                    )
                  )
                )
              case .failure(.unavailable):
                completion(
                  .success(
                    ViewerPerformanceProjectionPreparation(
                      receipt: ViewerPerformanceFrozenReceipt(
                        source: target.source,
                        storeScope: nil,
                        liveSlice: liveSlice
                      ),
                      bounds: bounds,
                      deviceStartMonotonicNanoseconds: anchor.deviceStartMonotonicNanoseconds
                    )
                  )
                )
              case .failure(let failure):
                completion(.failure(.store(failure)))
              }
            }
            return ViewerPerformanceProjectionOperationToken(gatewayToken: gatewayToken)

          case .historical(let recordingID, let deviceSessionID, _, _):
            guard mode == .storeBacked, let anchor = target.historicalAnchor else {
              throw ViewerPerformanceStoreFailure.invalidScope
            }
            let bounds = try rangeKind.bounds(
              deviceStartMonotonicNanoseconds: anchor.deviceStartMonotonicNanoseconds,
              upperMonotonicNanoseconds: anchor.upperMonotonicNanoseconds
            )
            let scanLower = Self.scanLowerBound(anchor: anchor, bounds: bounds)
            let gatewayToken = storeGateway.beginPerformanceTraversal(
              recordingID: recordingID,
              deviceSessionID: deviceSessionID,
              lowerMonotonicNanoseconds: scanLower,
              upperMonotonicNanoseconds: anchor.upperMonotonicNanoseconds
            ) { result in
              switch result {
              case .success(let scope):
                completion(
                  .success(
                    ViewerPerformanceProjectionPreparation(
                      receipt: ViewerPerformanceFrozenReceipt(
                        source: target.source,
                        storeScope: scope,
                        liveSlice: nil
                      ),
                      bounds: bounds,
                      deviceStartMonotonicNanoseconds: anchor.deviceStartMonotonicNanoseconds
                    )
                  )
                )
              case .failure(let failure):
                completion(.failure(.store(failure)))
              }
            }
            return ViewerPerformanceProjectionOperationToken(gatewayToken: gatewayToken)
          }
        } catch let failure as ViewerPerformanceStoreFailure {
          completion(.failure(.projection(failure)))
          return nil
        } catch {
          completion(.failure(.projection(.unavailable)))
          return nil
        }
      },
      loadEventPage: { continuation, completion in
        ViewerPerformanceProjectionOperationToken(
          gatewayToken: storeGateway.loadPerformanceEventPage(
            continuation: continuation,
            completion: completion
          )
        )
      },
      loadGapPage: { completion in
        ViewerPerformanceProjectionOperationToken(
          gatewayToken: storeGateway.loadPerformanceGapPage(completion: completion)
        )
      },
      endTraversal: { completion in
        ViewerPerformanceProjectionOperationToken(
          gatewayToken: storeGateway.endPerformanceTraversal(completion: completion)
        )
      },
      cancel: { token in
        guard let gatewayToken = token.gatewayToken else { return }
        storeGateway.cancel(gatewayToken)
      },
      currentUptimeNanoseconds: currentUptimeNanoseconds
    )
  }

  private static func scanLowerBound(
    anchor: ViewerPerformanceAnchor,
    bounds: ViewerPerformanceRangeBounds
  ) -> Int64 {
    let upper = UInt64(anchor.upperMonotonicNanoseconds)
    let lookbackLower =
      upper >= ViewerPerformanceFreshness.lookbackNanoseconds
      ? upper - ViewerPerformanceFreshness.lookbackNanoseconds : 0
    let cardLower = max(
      anchor.deviceStartMonotonicNanoseconds,
      Int64(lookbackLower)
    )
    return min(bounds.lowerMonotonicNanoseconds, cardLower)
  }
}

final class ViewerPerformanceOwnedPublication: @unchecked Sendable {
  let publication: ViewerPerformanceProjectionPublication

  private let lock = NSLock()
  private let ledger: ViewerPerformanceMemoryLedger
  private var reservation: ViewerPerformanceMemoryLedger.Reservation?

  init(
    publication: ViewerPerformanceProjectionPublication,
    reservation: ViewerPerformanceMemoryLedger.Reservation,
    ledger: ViewerPerformanceMemoryLedger
  ) {
    self.publication = publication
    self.reservation = reservation
    self.ledger = ledger
  }

  deinit {
    if let reservation = takeReservation() { _ = ledger.release(reservation) }
  }

  func takeReservation() -> ViewerPerformanceMemoryLedger.Reservation? {
    lock.lock()
    defer { lock.unlock() }
    let value = reservation
    reservation = nil
    return value
  }
}

enum ViewerPerformanceProjectionRunOutcome: Sendable {
  case projected(ViewerPerformanceOwnedPublication)
  case storeFailure(ViewerStoreExplorerFailure)
  case projectionFailure(ViewerPerformanceStoreFailure)
  case cancelled
}

struct ViewerPerformanceProjectionRunOutput: Sendable {
  let token: ViewerPerformanceRefreshToken
  let outcome: ViewerPerformanceProjectionRunOutcome
}

final class ViewerPerformanceProjectionRun: @unchecked Sendable {
  typealias ProgressHandler =
    @MainActor @Sendable (
      ViewerPerformanceRefreshToken,
      ViewerPerformanceProjectionProgress
    ) -> Void
  typealias CompletionHandler =
    @MainActor @Sendable (
      ViewerPerformanceProjectionRunOutput
    ) -> Void

  private let driver: ViewerPerformanceProjectionDriver
  private let ledger: ViewerPerformanceMemoryLedger
  private let target: ViewerPerformanceDashboardTarget
  private let token: ViewerPerformanceRefreshToken
  private let preparationMode: ViewerPerformanceProjectionPreparationMode
  private let completion: CompletionHandler
  private let queue = DispatchQueue(
    label: "com.nearwire.viewer.performance-projection",
    qos: .userInitiated
  )
  private let workTracker = ViewerAsyncWorkTracker()
  private let workerID = UUID()
  private let stateLock = NSLock()
  private let progressPump: ViewerLatestMainActorDeliveryPump<ViewerPerformanceProjectionProgress>

  private var cancellationRequested = false
  private var operation: ViewerPerformanceProjectionOperationToken?
  private var releasingTraversal = false
  private var lifetime: ViewerPerformanceProjectionRun?

  private var session: ViewerPerformanceProjectionSession?
  private var activeReservation: ViewerPerformanceMemoryLedger.Reservation?
  private var eventContinuation: ViewerPerformanceContinuation?
  private var eventPageCount: UInt64 = 0
  private var gapPageCount: UInt64 = 0
  private var decodedEventCount: UInt64 = 0
  private var traversalBegan = false
  private var terminalStarted = false

  init(
    driver: ViewerPerformanceProjectionDriver,
    ledger: ViewerPerformanceMemoryLedger,
    target: ViewerPerformanceDashboardTarget,
    token: ViewerPerformanceRefreshToken,
    preparationMode: ViewerPerformanceProjectionPreparationMode,
    progress: @escaping ProgressHandler,
    completion: @escaping CompletionHandler
  ) {
    self.driver = driver
    self.ledger = ledger
    self.target = target
    self.token = token
    self.preparationMode = preparationMode
    self.completion = completion
    progressPump = ViewerLatestMainActorDeliveryPump { value in progress(token, value) }
    workTracker.begin(id: workerID)
    lifetime = self
    queue.async { [weak self] in self?.begin() }
  }

  func cancelAndWait() -> Task<Void, Never> {
    let operationToCancel: ViewerPerformanceProjectionOperationToken?
    stateLock.lock()
    cancellationRequested = true
    operationToCancel = releasingTraversal ? nil : operation
    stateLock.unlock()
    if let operationToCancel { driver.cancel(operationToCancel) }
    queue.async { [weak self] in
      guard let self, !self.terminalStarted else { return }
      guard !self.hasActiveOperation else { return }
      self.beginFinish(.cancelled)
    }
    return workTracker.waitTask()
  }

  var refreshToken: ViewerPerformanceRefreshToken { token }
  var pendingWorkCount: Int { workTracker.activeCount + progressPump.pendingWorkCount }

  private func begin() {
    guard !isCancellationRequested else {
      beginFinish(.cancelled)
      return
    }
    let operation = driver.prepare(target, token.rangeKind, preparationMode) { [weak self] result in
      self?.enqueue { $0.receivePreparation(result) }
    }
    install(operation)
  }

  private func receivePreparation(
    _ result: Result<
      ViewerPerformanceProjectionPreparation,
      ViewerPerformanceProjectionDriverFailure
    >
  ) {
    clearOperation()
    guard !terminalStarted else { return }
    guard !isCancellationRequested else {
      beginFinish(.cancelled)
      return
    }
    switch result {
    case .failure(.projection(let failure)):
      beginFinish(.projectionFailure(failure))
    case .failure(.store(let failure)):
      beginFinish(.storeFailure(failure))
    case .success(let preparation):
      do {
        let nextSession = try ViewerPerformanceProjectionSession(
          receipt: preparation.receipt,
          rangeKind: token.rangeKind,
          bounds: preparation.bounds,
          deviceStartMonotonicNanoseconds: preparation.deviceStartMonotonicNanoseconds,
          sourceGeneration: token.sourceGeneration
        )
        guard
          let reservation = try ledger.reserve(
            owner: .activeReducer,
            bytes: try nextSession.activeAccountedBytes
          )
        else {
          beginFinish(.projectionFailure(.limitExceeded))
          return
        }
        session = nextSession
        activeReservation = reservation
        traversalBegan = preparation.receipt.storeScope != nil
        emitProgress(stage: .events)
        processEventTurn()
      } catch let failure as ViewerPerformanceStoreFailure {
        beginFinish(.projectionFailure(failure))
      } catch {
        beginFinish(.projectionFailure(.unavailable))
      }
    }
  }

  private func processEventTurn() {
    guard !terminalStarted else { return }
    guard !isCancellationRequested else {
      beginFinish(.cancelled)
      return
    }
    guard var session else {
      beginFinish(.projectionFailure(.invalidContinuation))
      return
    }
    do {
      let outcome = try session.runDecodeTurn()
      self.session = session
      switch outcome {
      case .processed(let count):
        decodedEventCount = Self.add(decodedEventCount, UInt64(count))
        try resizeActiveReservation(to: try session.activeAccountedBytes)
        emitProgress(stage: .events)
        queue.async { [weak self] in self?.processEventTurn() }
      case .needsEventPage:
        loadEventPage()
      case .eventsComplete:
        if session.needsGapPage {
          emitProgress(stage: .gaps)
          loadGapPage()
        } else {
          finalize()
        }
      }
    } catch let failure as ViewerPerformanceStoreFailure {
      beginFinish(.projectionFailure(failure))
    } catch {
      beginFinish(.projectionFailure(.unavailable))
    }
  }

  private func loadEventPage() {
    guard !isCancellationRequested else {
      beginFinish(.cancelled)
      return
    }
    let operation = driver.loadEventPage(eventContinuation) { [weak self] result in
      self?.enqueue { $0.receiveEventPage(result) }
    }
    install(operation)
  }

  private func receiveEventPage(
    _ result: Result<ViewerPerformanceEventPage, ViewerStoreExplorerFailure>
  ) {
    clearOperation()
    guard !terminalStarted else { return }
    guard !isCancellationRequested else {
      beginFinish(.cancelled)
      return
    }
    switch result {
    case .failure(let failure):
      beginFinish(.storeFailure(failure))
    case .success(let page):
      do {
        guard var session else { throw ViewerPerformanceStoreFailure.invalidContinuation }
        try session.accept(eventPage: page)
        self.session = session
        eventContinuation = page.continuation
        eventPageCount = Self.increment(eventPageCount)
        emitProgress(stage: .events)
        processEventTurn()
      } catch let failure as ViewerPerformanceStoreFailure {
        beginFinish(.projectionFailure(failure))
      } catch {
        beginFinish(.projectionFailure(.unavailable))
      }
    }
  }

  private func loadGapPage() {
    guard !isCancellationRequested else {
      beginFinish(.cancelled)
      return
    }
    let operation = driver.loadGapPage { [weak self] result in
      self?.enqueue { $0.receiveGapPage(result) }
    }
    install(operation)
  }

  private func receiveGapPage(
    _ result: Result<ViewerPerformanceGapPage, ViewerStoreExplorerFailure>
  ) {
    clearOperation()
    guard !terminalStarted else { return }
    guard !isCancellationRequested else {
      beginFinish(.cancelled)
      return
    }
    switch result {
    case .failure(let failure):
      beginFinish(.storeFailure(failure))
    case .success(let page):
      do {
        guard var session else { throw ViewerPerformanceStoreFailure.invalidContinuation }
        try session.accept(gapPage: page)
        self.session = session
        gapPageCount = Self.increment(gapPageCount)
        try resizeActiveReservation(to: try session.activeAccountedBytes)
        emitProgress(stage: .gaps)
        if session.needsGapPage { loadGapPage() } else { finalize() }
      } catch let failure as ViewerPerformanceStoreFailure {
        beginFinish(.projectionFailure(failure))
      } catch {
        beginFinish(.projectionFailure(.unavailable))
      }
    }
  }

  private func finalize() {
    guard !isCancellationRequested else {
      beginFinish(.cancelled)
      return
    }
    do {
      guard var session, let activeReservation else {
        throw ViewerPerformanceStoreFailure.invalidContinuation
      }
      let publication = try session.finalize(
        sourceGeneration: token.sourceGeneration,
        deadlineRevision: token.sequence,
        currentUptimeNanoseconds: driver.currentUptimeNanoseconds()
      )
      self.session = session
      guard
        let resized = try ledger.resize(
          activeReservation,
          to: publication.result.accountedBytes
        )
      else { throw ViewerPerformanceStoreFailure.limitExceeded }
      let completed = try ledger.transfer(resized, to: .completedResult)
      self.activeReservation = nil
      let owned = ViewerPerformanceOwnedPublication(
        publication: publication,
        reservation: completed,
        ledger: ledger
      )
      beginFinish(.projected(owned))
    } catch let failure as ViewerPerformanceStoreFailure {
      beginFinish(.projectionFailure(failure))
    } catch {
      beginFinish(.projectionFailure(.unavailable))
    }
  }

  private func beginFinish(_ outcome: ViewerPerformanceProjectionRunOutcome) {
    guard !terminalStarted else { return }
    terminalStarted = true
    if let activeReservation {
      _ = ledger.release(activeReservation)
      self.activeReservation = nil
    }
    session = nil
    eventContinuation = nil
    if traversalBegan {
      markReleasingTraversal(true)
      let operation = driver.endTraversal { [weak self] result in
        self?.enqueue { $0.finishAfterTraversalRelease(outcome, releaseResult: result) }
      }
      install(operation, releasingTraversal: true)
    } else {
      finishAfterTraversalRelease(outcome, releaseResult: .success(()))
    }
  }

  private func finishAfterTraversalRelease(
    _ outcome: ViewerPerformanceProjectionRunOutcome,
    releaseResult: Result<Void, ViewerStoreExplorerFailure>
  ) {
    clearOperation()
    markReleasingTraversal(false)
    traversalBegan = false
    let finalOutcome: ViewerPerformanceProjectionRunOutcome
    if isCancellationRequested {
      finalOutcome = .cancelled
    } else {
      switch releaseResult {
      case .success:
        finalOutcome = outcome
      case .failure(let failure):
        finalOutcome = .storeFailure(failure)
      }
    }
    let progressWait = progressPump.sealAndWait()
    Task { [self] in
      await progressWait.value
      await MainActor.run {
        completion(
          ViewerPerformanceProjectionRunOutput(token: token, outcome: finalOutcome)
        )
        releaseLifetime()
        workTracker.complete(workerID)
      }
    }
  }

  private func emitProgress(stage: ViewerPerformanceProjectionStage) {
    guard let session else { return }
    progressPump.submit(
      ViewerPerformanceProjectionProgress(
        stage: stage,
        eventPageCount: eventPageCount,
        gapPageCount: gapPageCount,
        decodedEventCount: decodedEventCount,
        decodeTurnCount: session.decodeTurnCount
      )
    )
  }

  private func enqueue(
    _ operation: @escaping @Sendable (ViewerPerformanceProjectionRun) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      operation(self)
    }
  }

  private func resizeActiveReservation(to bytes: Int) throws {
    guard let activeReservation else {
      throw ViewerPerformanceStoreFailure.invalidContinuation
    }
    guard let resized = try ledger.resize(activeReservation, to: bytes) else {
      throw ViewerPerformanceStoreFailure.limitExceeded
    }
    self.activeReservation = resized
  }

  private func install(
    _ nextOperation: ViewerPerformanceProjectionOperationToken?,
    releasingTraversal: Bool = false
  ) {
    guard let nextOperation else { return }
    let shouldCancel: Bool
    stateLock.lock()
    operation = nextOperation
    if releasingTraversal { self.releasingTraversal = true }
    shouldCancel = cancellationRequested && !self.releasingTraversal
    stateLock.unlock()
    if shouldCancel { driver.cancel(nextOperation) }
  }

  private func clearOperation() {
    stateLock.lock()
    operation = nil
    stateLock.unlock()
  }

  private func markReleasingTraversal(_ value: Bool) {
    stateLock.lock()
    releasingTraversal = value
    stateLock.unlock()
  }

  private var isCancellationRequested: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return cancellationRequested
  }

  private var hasActiveOperation: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return operation != nil
  }

  private func releaseLifetime() {
    stateLock.lock()
    lifetime = nil
    stateLock.unlock()
  }

  private static func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? value : value + 1
  }

  private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : value
  }
}

private final class ViewerPerformanceDeliveryEnvelope: @unchecked Sendable {
  let publication: ViewerPerformanceProjectionPublication

  private let lock = NSLock()
  private let ledger: ViewerPerformanceMemoryLedger
  private var resultReservation: ViewerPerformanceMemoryLedger.Reservation?
  private var wrapperReservation: ViewerPerformanceMemoryLedger.Reservation?

  init?(
    owned: ViewerPerformanceOwnedPublication,
    ledger: ViewerPerformanceMemoryLedger
  ) throws {
    guard
      let wrapperReservation = try ledger.reserve(
        owner: .pendingDelivery,
        bytes: ViewerPerformanceAccounting.deliveryWrapperBytes
      )
    else { return nil }
    guard let resultReservation = owned.takeReservation() else {
      _ = ledger.release(wrapperReservation)
      return nil
    }
    publication = owned.publication
    self.ledger = ledger
    self.resultReservation = resultReservation
    self.wrapperReservation = wrapperReservation
  }

  deinit {
    let reservations = takeAllReservations()
    if let result = reservations.result { _ = ledger.release(result) }
    if let wrapper = reservations.wrapper { _ = ledger.release(wrapper) }
  }

  func takeResultReservation() -> ViewerPerformanceMemoryLedger.Reservation? {
    lock.lock()
    defer { lock.unlock() }
    let value = resultReservation
    resultReservation = nil
    return value
  }

  private func takeAllReservations() -> (
    result: ViewerPerformanceMemoryLedger.Reservation?,
    wrapper: ViewerPerformanceMemoryLedger.Reservation?
  ) {
    lock.lock()
    defer { lock.unlock() }
    let values = (resultReservation, wrapperReservation)
    resultReservation = nil
    wrapperReservation = nil
    return values
  }
}

private final class ViewerPerformanceDeliveryRelay: @unchecked Sendable {
  typealias Action = @MainActor @Sendable (ViewerPerformanceDeliveryEnvelope) -> Void

  private let lock = NSLock()
  private var action: Action?

  func install(_ action: @escaping Action) {
    lock.lock()
    self.action = action
    lock.unlock()
  }

  func deliver(_ envelope: ViewerPerformanceDeliveryEnvelope) {
    let action: Action?
    lock.lock()
    action = self.action
    lock.unlock()
    MainActor.assumeIsolated { action?(envelope) }
  }

  func clear() {
    lock.lock()
    action = nil
    lock.unlock()
  }
}

struct ViewerPerformanceDashboardControllerDiagnostics: Equatable, Sendable {
  let ledgerBytes: Int
  let ledgerReservationCount: Int
  let cacheEntryCount: Int
  let runningRefreshCount: Int
  let dirtyRefreshCount: Int
  let activeRunCount: Int
  let pendingDeliveryCount: Int
  let pendingDeliveryWorkCount: Int
  let activeDeadlineCount: Int
  let isAnalysisActive: Bool
  let isPaused: Bool
  let isSealed: Bool
}

final class ViewerPerformanceDetachedCleanupRegistry: @unchecked Sendable {
  static let shared = ViewerPerformanceDetachedCleanupRegistry()

  private final class Entry: @unchecked Sendable {
    let retainedObjects: [AnyObject]
    var task: Task<Void, Never>?

    init(retainedObjects: [AnyObject]) {
      self.retainedObjects = retainedObjects
    }
  }

  private let lock = NSLock()
  private var entries: [UUID: Entry] = [:]

  func retainUntilComplete(
    runWait: Task<Void, Never>,
    deliveryWait: Task<Void, Never>,
    deadlineWait: Task<Void, Never>,
    retaining objects: [AnyObject]
  ) {
    let id = UUID()
    let entry = Entry(retainedObjects: objects)
    lock.lock()
    entries[id] = entry
    lock.unlock()
    entry.task = Task { [self] in
      async let run: Void = runWait.value
      async let delivery: Void = deliveryWait.value
      async let deadline: Void = deadlineWait.value
      _ = await (run, delivery, deadline)
      remove(id)
    }
  }

  private func remove(_ id: UUID) {
    lock.lock()
    entries.removeValue(forKey: id)
    lock.unlock()
  }

  var pendingCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }
}

@MainActor
final class ViewerPerformanceDashboardController: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  let model: ViewerPerformanceDashboardModel

  private let driver: ViewerPerformanceProjectionDriver
  private let ledger: ViewerPerformanceMemoryLedger
  private let uptimeNanoseconds: @Sendable () -> Int64?
  private let deliveryClaimed: @MainActor @Sendable () -> Void
  private let deliveryGate = ViewerPerformanceDeliveryGate()
  private let deadlineOwner: ViewerPerformanceFreshnessDeadlineOwner
  private let admission = ViewerPerformanceRefreshAdmission(sourceGeneration: 1)
  private let deliveryRelay: ViewerPerformanceDeliveryRelay
  private let deliveryPump:
    ViewerPerformanceLatestDeliveryPump<
      ViewerPerformanceDeliveryEnvelope
    >

  private var cache = ViewerPerformanceResultCache()
  private var target: ViewerPerformanceDashboardTarget?
  private var rangeKind = ViewerPerformanceRangeKind.defaultKind
  private var sourceGeneration: UInt64 = 1
  private var nextSequence: UInt64 = 0
  private var transitionRevision: UInt64 = 0
  private var sourceReservation: ViewerPerformanceMemoryLedger.Reservation?
  private var presentationReservation: ViewerPerformanceMemoryLedger.Reservation?
  private var crosshairReservation: ViewerPerformanceMemoryLedger.Reservation?
  private var tooltipReservation: ViewerPerformanceMemoryLedger.Reservation?
  private var presentedCacheKey: ViewerPerformanceCacheKey?
  private var activeRun: ViewerPerformanceProjectionRun?
  private var liveOnlyToken: ViewerPerformanceRefreshToken?
  private var analysisDeactivationTask: Task<Void, Never>?
  private var analysisActive: Bool
  private var paused = false
  private var rawRevealSuspended = false
  private var sealed = false

  init(
    driver: ViewerPerformanceProjectionDriver,
    model: ViewerPerformanceDashboardModel = ViewerPerformanceDashboardModel(),
    ledger: ViewerPerformanceMemoryLedger = ViewerPerformanceMemoryLedger(),
    deliveryScheduler: ViewerLiveRefreshScheduler = .live,
    deadlineScheduler: ViewerPerformanceDeadlineScheduler = .live,
    uptimeNanoseconds: @escaping @Sendable () -> Int64? = {
      let value = DispatchTime.now().uptimeNanoseconds
      return value > UInt64(Int64.max) ? nil : Int64(value)
    },
    analysisActive: Bool = true,
    deliveryClaimed: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    self.driver = driver
    self.model = model
    self.ledger = ledger
    self.deadlineOwner = ViewerPerformanceFreshnessDeadlineOwner(
      scheduler: deadlineScheduler
    )
    self.uptimeNanoseconds = uptimeNanoseconds
    self.analysisActive = analysisActive
    self.deliveryClaimed = deliveryClaimed
    let deliveryRelay = ViewerPerformanceDeliveryRelay()
    self.deliveryRelay = deliveryRelay
    deliveryPump = ViewerPerformanceLatestDeliveryPump(
      scheduler: deliveryScheduler,
      handler: { [deliveryRelay] envelope in deliveryRelay.deliver(envelope) }
    )
    deliveryRelay.install { [weak self] envelope in self?.applyDelivery(envelope) }
  }

  isolated deinit {
    guard !sealed else { return }
    deliveryGate.invalidate()
    let deadlineWait = deadlineOwner.invalidateAndWait()
    deliveryRelay.clear()
    let retainedRun = activeRun
    let runWait = retainedRun?.cancelAndWait() ?? Task {}
    activeRun = nil
    let deliveryWait = deliveryPump.sealAndWait()
    cache.clear(ledger: ledger)
    releasePresentationOwnership()
    if let sourceReservation { _ = ledger.release(sourceReservation) }
    model.seal()
    var retainedObjects: [AnyObject] = [deliveryPump, deadlineOwner, ledger]
    if let retainedRun { retainedObjects.append(retainedRun) }
    ViewerPerformanceDetachedCleanupRegistry.shared.retainUntilComplete(
      runWait: runWait,
      deliveryWait: deliveryWait,
      deadlineWait: deadlineWait,
      retaining: retainedObjects
    )
  }

  @discardableResult
  func replace(
    target nextTarget: ViewerPerformanceDashboardTarget?,
    rangeKind nextRangeKind: ViewerPerformanceRangeKind
  ) -> Task<Void, Never> {
    guard !sealed else { return Task {} }
    if target == nextTarget, rangeKind == nextRangeKind {
      if analysisActive { requestRefresh() }
      return Task {}
    }

    cancelRawRevealSuspensionForTransition()
    let targetChanged = target != nextTarget
    target = nextTarget
    rangeKind = nextRangeKind
    transitionRevision = Self.increment(transitionRevision)
    let transition = transitionRevision
    sourceGeneration = Self.increment(sourceGeneration)
    _ = admission.replaceSourceGeneration(sourceGeneration)
    deliveryGate.invalidate()
    let deadlineWait = deadlineOwner.invalidateAndWait()
    deliveryPump.cancelPending()
    let deliveryWait = deliveryPump.waitForIdle()
    let runWait = activeRun?.cancelAndWait() ?? Task {}
    activeRun = nil
    liveOnlyToken = nil
    releasePresentationOwnership()
    model.replaceScope(nil)

    if targetChanged {
      cache.clear(ledger: ledger)
      release(&sourceReservation)
    }

    return Task { [weak self] in
      await runWait.value
      await deliveryWait.value
      await deadlineWait.value
      guard let self, !self.sealed, self.transitionRevision == transition else { return }
      self.finishReplacement()
    }
  }

  func requestRefresh() {
    guard !sealed, analysisActive, let scope = model.scope,
      let token = makeToken(scope: scope)
    else { return }
    submit(token, preparationMode: .storeBacked)
  }

  /// Invalidates every projection and presentation bound to the replaced Store instance.
  /// The selected logical target is retained so an active dashboard can rebuild only after all
  /// predecessor work has joined under a new source generation.
  @discardableResult
  func replaceStoreGenerationAndWait() -> Task<Void, Never> {
    guard !sealed else { return Task {} }
    cancelRawRevealSuspensionForTransition()
    transitionRevision = Self.increment(transitionRevision)
    let transition = transitionRevision
    sourceGeneration = Self.increment(sourceGeneration)
    _ = admission.replaceSourceGeneration(sourceGeneration)
    deliveryGate.invalidate()
    let deadlineWait = deadlineOwner.invalidateAndWait()
    deliveryPump.cancelPending()
    let deliveryWait = deliveryPump.waitForIdle()
    let runWait = activeRun?.cancelAndWait() ?? Task {}
    activeRun = nil
    liveOnlyToken = nil
    releasePresentationOwnership()
    model.replaceScope(nil)
    cache.clear(ledger: ledger)
    release(&sourceReservation)

    return Task { [weak self] in
      await runWait.value
      await deliveryWait.value
      await deadlineWait.value
      guard let self, !self.sealed, self.transitionRevision == transition else { return }
      self.finishReplacement()
    }
  }

  /// Invalidates Store-bound projection authority without admitting a successor. The analysis-mode
  /// coordinator uses this half of Store replacement so predecessor mode transitions and raw
  /// resolution can join before it recompiles selection and explicitly rebuilds Performance.
  @discardableResult
  func invalidateStoreGenerationAndWait() -> Task<Void, Never> {
    guard !sealed else { return Task {} }
    cancelRawRevealSuspensionForTransition()
    transitionRevision = Self.increment(transitionRevision)
    sourceGeneration = Self.increment(sourceGeneration)
    _ = admission.replaceSourceGeneration(sourceGeneration)
    deliveryGate.invalidate()
    let deadlineWait = deadlineOwner.invalidateAndWait()
    deliveryPump.cancelPending()
    let deliveryWait = deliveryPump.waitForIdle()
    let runWait = activeRun?.cancelAndWait() ?? Task {}
    activeRun = nil
    liveOnlyToken = nil
    releasePresentationOwnership()
    model.replaceScope(nil)
    cache.clear(ledger: ledger)
    release(&sourceReservation)
    return Task {
      await runWait.value
      await deliveryWait.value
      await deadlineWait.value
    }
  }

  /// Rebuilds the exact selection after `invalidateStoreGenerationAndWait()` has completed. This
  /// method does not advance generation again and must only be called by the serialized analysis
  /// coordinator after its transition and resolver barriers have joined.
  func rebuildAfterStoreGenerationReplacement(
    target nextTarget: ViewerPerformanceDashboardTarget?,
    rangeKind nextRangeKind: ViewerPerformanceRangeKind
  ) {
    guard !sealed else { return }
    target = nextTarget
    rangeKind = nextRangeKind
    finishReplacement()
  }

  @discardableResult
  func deactivateAndWait() -> Task<Void, Never> {
    if let analysisDeactivationTask, !analysisActive { return analysisDeactivationTask }
    guard !sealed, analysisActive else { return Task {} }
    cancelRawRevealSuspensionForTransition()
    analysisActive = false
    transitionRevision = Self.increment(transitionRevision)
    sourceGeneration = Self.increment(sourceGeneration)
    _ = admission.replaceSourceGeneration(sourceGeneration)
    deliveryGate.invalidate()
    let deadlineWait = deadlineOwner.invalidateAndWait()
    deliveryPump.cancelPending()
    clearCrosshair()
    releasePresentationOwnership()
    let runWait = activeRun?.cancelAndWait() ?? Task {}
    activeRun = nil
    liveOnlyToken = nil
    let deliveryWait = deliveryPump.waitForIdle()
    let cleanup = Task {
      await runWait.value
      await deliveryWait.value
      await deadlineWait.value
    }
    analysisDeactivationTask = cleanup
    return cleanup
  }

  func activate() {
    guard !sealed, !analysisActive else { return }
    analysisActive = true
    analysisDeactivationTask = nil
    finishReplacement()
  }

  @discardableResult
  func suspendForRawRevealAndWait() -> Task<Void, Never> {
    guard !sealed, analysisActive else { return Task {} }
    guard !rawRevealSuspended else {
      let runWait = activeRun?.cancelAndWait() ?? Task {}
      let deliveryWait = deliveryPump.waitForIdle()
      return Task {
        await runWait.value
        await deliveryWait.value
      }
    }
    rawRevealSuspended = true
    admission.pause()
    deadlineOwner.setPaused(true)
    deliveryGate.invalidate()
    deliveryPump.cancelPending()
    let runWait = activeRun?.cancelAndWait() ?? Task {}
    activeRun = nil
    liveOnlyToken = nil
    let deliveryWait = deliveryPump.waitForIdle()
    return Task {
      await runWait.value
      await deliveryWait.value
    }
  }

  func resumeAfterRawReveal() {
    guard !sealed, rawRevealSuspended else { return }
    rawRevealSuspended = false
    guard !paused else { return }
    _ = deadlineOwner.resumeConsumesDirtyExpiry()
    guard analysisActive, let scope = model.scope else {
      _ = admission.resume()
      return
    }
    if let freshToken = makeToken(scope: scope) {
      _ = admission.submit(freshToken)
      liveOnlyToken = nil
    }
    if let successor = admission.resume() {
      startRun(successor, preparationMode: .storeBacked)
    }
  }

  func pause() {
    guard !sealed, !paused else { return }
    paused = true
    admission.pause()
    deadlineOwner.setPaused(true)
    deliveryGate.invalidate()
    deliveryPump.cancelPending()
  }

  func resume() {
    guard !sealed, paused, let scope = model.scope else { return }
    paused = false
    guard !rawRevealSuspended else { return }
    _ = deadlineOwner.resumeConsumesDirtyExpiry()
    guard analysisActive else {
      _ = admission.resume()
      return
    }
    if let freshToken = makeToken(scope: scope) {
      _ = admission.submit(freshToken)
      liveOnlyToken = nil
    }
    if let successor = admission.resume() {
      startRun(successor, preparationMode: .storeBacked)
    }
  }

  func resetPauseForWindowClose() {
    guard !sealed, !analysisActive, paused else { return }
    paused = false
    _ = deadlineOwner.resumeConsumesDirtyExpiry()
    _ = admission.resume()
  }

  @discardableResult
  func setCrosshair(viewerMonotonicNanoseconds: Int64) -> Bool {
    setCrosshair(
      viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
      chartGroup: nil,
      selectedMetric: nil
    )
  }

  @discardableResult
  func setCrosshair(
    viewerMonotonicNanoseconds: Int64,
    chartGroup: ViewerPerformanceChartGroupKind?,
    selectedMetric: ViewerPerformanceNumericMetric?
  ) -> Bool {
    guard !sealed, analysisActive else { return false }
    let crosshairReservedNow: Bool
    if crosshairReservation == nil {
      guard
        let reservation = try? ledger.reserve(
          owner: .crosshair,
          bytes: ViewerPerformanceAccounting.crosshairBytes
        )
      else { return false }
      crosshairReservation = reservation
      crosshairReservedNow = true
    } else {
      crosshairReservedNow = false
    }
    let tooltipReservedNow: Bool
    if tooltipReservation == nil {
      guard
        let reservation = try? ledger.reserve(
          owner: .tooltip,
          bytes: ViewerPerformanceAccounting.tooltipBytes
        )
      else {
        if crosshairReservedNow { release(&crosshairReservation) }
        return false
      }
      tooltipReservation = reservation
      tooltipReservedNow = true
    } else {
      tooltipReservedNow = false
    }
    guard
      model.setCrosshair(
        viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
        chartGroup: chartGroup,
        selectedMetric: selectedMetric
      )
    else {
      if crosshairReservedNow { release(&crosshairReservation) }
      if tooltipReservedNow { release(&tooltipReservation) }
      return false
    }
    return true
  }

  func clearCrosshair() {
    model.clearCrosshair()
    release(&crosshairReservation)
    release(&tooltipReservation)
  }

  func rawEventRequest(
    bucketIndex: Int,
    metric: ViewerPerformanceNumericMetric
  ) -> ViewerPerformanceRawEventRequest? {
    guard !sealed, analysisActive, let scope = model.scope,
      model.buckets.indices.contains(bucketIndex),
      let representative = model.buckets[bucketIndex].numeric.accumulator(for: metric)
        .representative,
      representative.sourceGeneration == scope.sourceGeneration
    else { return nil }
    return try? ViewerPerformanceRawEventRequest(
      sourceGeneration: representative.sourceGeneration,
      key: representative.key
    )
  }

  var currentTarget: ViewerPerformanceDashboardTarget? { target }
  var currentRangeKind: ViewerPerformanceRangeKind { rangeKind }
  var isAnalysisActive: Bool { analysisActive }

  func sealAndWait() -> Task<Void, Never> {
    guard !sealed else { return Task {} }
    cancelRawRevealSuspensionForTransition()
    sealed = true
    transitionRevision = Self.increment(transitionRevision)
    sourceGeneration = Self.increment(sourceGeneration)
    _ = admission.replaceSourceGeneration(sourceGeneration)
    deliveryGate.invalidate()
    let deadlineWait = deadlineOwner.invalidateAndWait()
    deliveryRelay.clear()
    let runWait = activeRun?.cancelAndWait() ?? Task {}
    activeRun = nil
    let deliveryWait = deliveryPump.sealAndWait()
    cache.clear(ledger: ledger)
    releasePresentationOwnership()
    release(&sourceReservation)
    target = nil
    liveOnlyToken = nil
    model.seal()
    return Task {
      await runWait.value
      await deliveryWait.value
      await deadlineWait.value
    }
  }

  var diagnostics: ViewerPerformanceDashboardControllerDiagnostics {
    ViewerPerformanceDashboardControllerDiagnostics(
      ledgerBytes: ledger.usedBytes,
      ledgerReservationCount: ledger.reservationCount,
      cacheEntryCount: cache.count,
      runningRefreshCount: admission.runningCount,
      dirtyRefreshCount: admission.dirtyCount,
      activeRunCount: activeRun == nil ? 0 : 1,
      pendingDeliveryCount: deliveryPump.retainedValueCount,
      pendingDeliveryWorkCount: deliveryPump.pendingWorkCount,
      activeDeadlineCount: deadlineOwner.activeWakeCount,
      isAnalysisActive: analysisActive,
      isPaused: paused,
      isSealed: sealed
    )
  }

  nonisolated var description: String {
    "ViewerPerformanceDashboardController(redacted)"
  }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private func finishReplacement() {
    guard let target else { return }
    do {
      if sourceReservation == nil {
        guard
          let reservation = try ledger.reserve(
            owner: .controllerSource,
            bytes: ViewerPerformanceAccounting.controllerSourceBytes
          )
        else { throw ViewerPerformanceStoreFailure.limitExceeded }
        sourceReservation = reservation
      }
      cache.activate(source: target.source, ledger: ledger)
      let scope = try ViewerPerformanceDashboardScope(
        sourceGeneration: sourceGeneration,
        source: target.source,
        rangeKind: rangeKind
      )
      model.replaceScope(scope)
      guard analysisActive else { return }
      guard let token = makeToken(scope: scope) else { return }
      if paused {
        _ = admission.submit(token)
      } else {
        submit(token, preparationMode: .storeBacked)
      }
    } catch let failure as ViewerPerformanceStoreFailure {
      if let scope = try? ViewerPerformanceDashboardScope(
        sourceGeneration: sourceGeneration,
        source: target.source,
        rangeKind: rangeKind
      ) {
        model.replaceScope(scope)
        model.showFailure(failure, for: scope)
      }
    } catch {
      if let scope = model.scope { model.showFailure(.unavailable, for: scope) }
    }
  }

  private func makeToken(
    scope: ViewerPerformanceDashboardScope
  ) -> ViewerPerformanceRefreshToken? {
    nextSequence = Self.increment(nextSequence)
    return try? ViewerPerformanceRefreshToken(
      sourceGeneration: scope.sourceGeneration,
      sequence: nextSequence,
      source: scope.source,
      rangeKind: scope.rangeKind
    )
  }

  private func submit(
    _ token: ViewerPerformanceRefreshToken,
    preparationMode: ViewerPerformanceProjectionPreparationMode
  ) {
    guard analysisActive else { return }
    switch admission.submit(token) {
    case .start:
      startRun(token, preparationMode: preparationMode)
    case .retainedDirty:
      if preparationMode == .freshLiveOnly { liveOnlyToken = token }
    case .rejectedStale:
      break
    }
  }

  private func startRun(
    _ token: ViewerPerformanceRefreshToken,
    preparationMode: ViewerPerformanceProjectionPreparationMode
  ) {
    guard !sealed, analysisActive, let target, let scope = model.scope,
      scope.sourceGeneration == token.sourceGeneration,
      scope.source == token.source,
      scope.rangeKind == token.rangeKind
    else { return }
    model.beginLoading(for: scope)
    let run = ViewerPerformanceProjectionRun(
      driver: driver,
      ledger: ledger,
      target: target,
      token: token,
      preparationMode: preparationMode,
      progress: { [weak self] progressToken, progress in
        self?.handleProgress(progress, token: progressToken)
      },
      completion: { [weak self] output in
        self?.handleCompletion(output)
      }
    )
    activeRun = run
  }

  private func handleProgress(
    _ progress: ViewerPerformanceProjectionProgress,
    token: ViewerPerformanceRefreshToken
  ) {
    guard !sealed, analysisActive, let scope = model.scope,
      scope.sourceGeneration == token.sourceGeneration,
      scope.source == token.source,
      scope.rangeKind == token.rangeKind
    else { return }
    model.updateProgress(progress, for: scope)
  }

  private func handleCompletion(_ output: ViewerPerformanceProjectionRunOutput) {
    if activeRun?.refreshToken == output.token {
      self.activeRun = nil
    }
    let decision = admission.complete(output.token)
    guard !sealed, analysisActive else { return }

    if decision.publishesCompletedResult, let scope = model.scope,
      scope.sourceGeneration == output.token.sourceGeneration,
      scope.source == output.token.source,
      scope.rangeKind == output.token.rangeKind
    {
      publish(output.outcome, scope: scope)
    }

    if let successor = decision.successorToStart, !sealed, analysisActive {
      let mode: ViewerPerformanceProjectionPreparationMode =
        successor == liveOnlyToken ? .freshLiveOnly : .storeBacked
      if successor == liveOnlyToken { liveOnlyToken = nil }
      startRun(successor, preparationMode: mode)
    }
  }

  private func publish(
    _ outcome: ViewerPerformanceProjectionRunOutcome,
    scope: ViewerPerformanceDashboardScope
  ) {
    guard analysisActive else { return }
    switch outcome {
    case .cancelled:
      break
    case .projectionFailure(let failure):
      releasePresentationOwnership()
      model.showFailure(failure, for: scope)
    case .storeFailure(let failure):
      switch ViewerPerformanceStoreFailurePolicy.resolution(
        for: scope.source,
        failure: failure
      ) {
      case .restartWithFreshLiveOnlyFreeze:
        deliveryGate.invalidate()
        deadlineOwner.invalidate()
        deliveryPump.cancelPending()
        releasePresentationOwnership()
        cache.clearResults(ledger: ledger)
        guard model.restartLoadingWithoutPresentation(for: scope) else { return }
        guard let fallback = makeToken(scope: scope) else { return }
        liveOnlyToken = fallback
        switch admission.submit(fallback) {
        case .start:
          liveOnlyToken = nil
          startRun(fallback, preparationMode: .freshLiveOnly)
        case .retainedDirty, .rejectedStale:
          break
        }
      case .publishStorageUnavailable:
        releasePresentationOwnership()
        model.showStorageUnavailable(for: scope)
      case .discard:
        releasePresentationOwnership()
        model.showFailure(Self.map(failure), for: scope)
      }
    case .projected(let owned):
      model.updateProgress(
        ViewerPerformanceProjectionProgress(
          stage: .delivering,
          eventPageCount: model.progress?.eventPageCount ?? 0,
          gapPageCount: model.progress?.gapPageCount ?? 0,
          decodedEventCount: owned.publication.decodedEventCount,
          decodeTurnCount: owned.publication.decodeTurnCount
        ),
        for: scope
      )
      deliveryGate.install(owned.publication.freshnessReceipt)
      do {
        guard let envelope = try ViewerPerformanceDeliveryEnvelope(owned: owned, ledger: ledger)
        else {
          releasePresentationOwnership()
          model.showFailure(.limitExceeded, for: scope)
          return
        }
        if !deliveryPump.submit(envelope) {
          deliveryGate.invalidate()
        }
      } catch let failure as ViewerPerformanceStoreFailure {
        releasePresentationOwnership()
        model.showFailure(failure, for: scope)
      } catch {
        releasePresentationOwnership()
        model.showFailure(.unavailable, for: scope)
      }
    }
  }

  private func applyDelivery(_ envelope: ViewerPerformanceDeliveryEnvelope) {
    guard !sealed, analysisActive, !paused, let scope = model.scope else { return }
    do {
      guard
        let claim = try deliveryGate.claim(
          envelope.publication,
          currentUptimeNanoseconds: uptimeNanoseconds()
        )
      else { return }
      deliveryClaimed()
      guard
        var publication = try deliveryGate.apply(
          claim,
          currentUptimeNanoseconds: uptimeNanoseconds()
        ),
        publication.freshnessReceipt.sourceGeneration == scope.sourceGeneration,
        publication.cacheKey.source == scope.source,
        publication.cacheKey.rangeKind == scope.rangeKind
      else { return }

      let reservedPresentationNow: Bool
      if presentationReservation == nil {
        guard
          let reservation = try ledger.reserve(
            owner: .presentedModel,
            bytes: ViewerPerformanceAccounting.modelWrapperBytes
          )
        else { throw ViewerPerformanceStoreFailure.limitExceeded }
        presentationReservation = reservation
        reservedPresentationNow = true
      } else {
        reservedPresentationNow = false
      }

      if let presentedCacheKey { _ = try cache.result(for: presentedCacheKey) }
      let insertedNewResult: Bool
      if let cachedResult = try cache.result(for: publication.cacheKey) {
        guard let incoming = envelope.takeResultReservation() else {
          throw ViewerPerformanceStoreFailure.invalidCarrier
        }
        if cachedResult.representativesBelong(to: scope.sourceGeneration) {
          _ = ledger.release(incoming)
          publication = ViewerPerformanceProjectionPublication(
            cacheKey: publication.cacheKey,
            result: cachedResult,
            cards: publication.cards,
            coverage: publication.coverage,
            freshnessReceipt: publication.freshnessReceipt,
            decodedEventCount: publication.decodedEventCount,
            decodeTurnCount: publication.decodeTurnCount
          )
          insertedNewResult = false
        } else {
          do {
            try cache.replaceOwned(
              publication.result,
              reservation: incoming,
              for: publication.cacheKey,
              ledger: ledger
            )
          } catch {
            _ = ledger.release(incoming)
            throw error
          }
          insertedNewResult = true
        }
      } else {
        guard let resultReservation = envelope.takeResultReservation() else {
          throw ViewerPerformanceStoreFailure.invalidCarrier
        }
        do {
          try cache.insertOwned(
            publication.result,
            reservation: resultReservation,
            for: publication.cacheKey,
            ledger: ledger
          )
        } catch {
          _ = ledger.release(resultReservation)
          throw error
        }
        insertedNewResult = true
      }

      guard model.apply(publication, for: scope) else {
        if insertedNewResult { cache.remove(publication.cacheKey, ledger: ledger) }
        if reservedPresentationNow { release(&presentationReservation) }
        return
      }
      presentedCacheKey = publication.cacheKey
      release(&crosshairReservation)
      release(&tooltipReservation)
      if publication.cards.shouldArmDeadline {
        deadlineOwner.arm(receipt: publication.freshnessReceipt) { [weak self] receipt in
          MainActor.assumeIsolated { self?.expireCurrentCards(receipt) }
        }
      } else {
        deadlineOwner.invalidate()
      }
    } catch let failure as ViewerPerformanceStoreFailure {
      releasePresentationOwnership()
      model.showFailure(failure, for: scope)
    } catch {
      releasePresentationOwnership()
      model.showFailure(.unavailable, for: scope)
    }
  }

  private func expireCurrentCards(_ receipt: ViewerPerformanceCurrentFreshnessReceipt) {
    guard !sealed, analysisActive, !paused else { return }
    _ = model.expireCurrentCards(matching: receipt)
  }

  private func releasePresentationOwnership() {
    presentedCacheKey = nil
    release(&presentationReservation)
    release(&crosshairReservation)
    release(&tooltipReservation)
  }

  private func cancelRawRevealSuspensionForTransition() {
    guard rawRevealSuspended else { return }
    rawRevealSuspended = false
    deadlineOwner.setPaused(paused)
    if !paused {
      _ = deadlineOwner.resumeConsumesDirtyExpiry()
      _ = admission.resume()
    }
  }

  private func release(
    _ reservation: inout ViewerPerformanceMemoryLedger.Reservation?
  ) {
    guard let value = reservation else { return }
    reservation = nil
    _ = ledger.release(value)
  }

  private static func map(
    _ failure: ViewerStoreExplorerFailure
  ) -> ViewerPerformanceStoreFailure {
    switch failure {
    case .storeReplaced: return .storeReplaced
    case .cancelled: return .cancelled
    case .unavailable, .busy: return .unavailable
    case .invalidRequest, .refineQuery, .exportTooLarge, .catalogChanged: return .invalidScope
    }
  }

  private static func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? 1 : value + 1
  }
}

extension ViewerPerformanceDashboardTarget: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceDashboardTarget(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceProjectionPreparation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceProjectionPreparation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceProjectionOperationToken: CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceProjectionOperationToken(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceProjectionDriver: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceProjectionDriver(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceOwnedPublication: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceOwnedPublication(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerPerformanceProjectionRunOutcome: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceProjectionRunOutcome(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerPerformanceProjectionRunOutput: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceProjectionRunOutput(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceProjectionRun: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceProjectionRun(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerPerformanceDashboardControllerDiagnostics: CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceDashboardControllerDiagnostics(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
