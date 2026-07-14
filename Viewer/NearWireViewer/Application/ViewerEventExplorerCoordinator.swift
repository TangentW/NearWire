import Foundation

private final class ViewerLiveEvaluationCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

enum ViewerExplorerTraversalReason: Equatable, Sendable {
  case scopeReplacement
  case materializationReplacement
  case resume
  case jumpToLatest
  case refresh
  case analysisModeSwitch
}

enum ViewerExplorerTraversalState: Equatable, Sendable {
  case idle
  case paused
  case releasing(ViewerExplorerTraversalReason)
  case loading(ViewerExplorerTraversalReason)
  case ready(ViewerExplorerTraversalReason)
  case failed(ViewerStoreExplorerFailure)
}

struct ViewerExplorerTraversalDiagnostics: Equatable, Sendable {
  let requestCount: UInt64
  let releaseRequestCount: UInt64
  let releaseCompletionCount: UInt64
  let durableQueryCount: UInt64
  let liveSnapshotCount: UInt64
}

struct ViewerExplorerStoreOperationToken: Sendable {
  fileprivate let gatewayToken: ViewerStoreExplorerOperationToken?
  private let deliveryIsValid: @Sendable () -> Bool

  fileprivate init(_ gatewayToken: ViewerStoreExplorerOperationToken) {
    self.gatewayToken = gatewayToken
    deliveryIsValid = { gatewayToken.isDeliveryValid }
  }

  init(deliveryIsValid: @escaping @Sendable () -> Bool) {
    gatewayToken = nil
    self.deliveryIsValid = deliveryIsValid
  }

  var isDeliveryValid: Bool { deliveryIsValid() }

  fileprivate static var invalid: ViewerExplorerStoreOperationToken {
    ViewerExplorerStoreOperationToken(deliveryIsValid: { false })
  }
}

private final class ViewerExplorerStoreDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var token: ViewerExplorerStoreOperationToken?

  func attach(_ token: ViewerExplorerStoreOperationToken) {
    lock.lock()
    precondition(self.token == nil)
    self.token = token
    lock.unlock()
  }

  var validToken: ViewerExplorerStoreOperationToken? {
    lock.lock()
    let token = token
    lock.unlock()
    guard token?.isDeliveryValid == true else { return nil }
    return token
  }
}

struct ViewerExplorerStoreDriver: Sendable {
  typealias VoidCompletion = @Sendable (Result<Void, ViewerStoreExplorerFailure>) -> Void
  typealias QueryCompletion =
    @Sendable (Result<ViewerQuerySnapshot, ViewerStoreExplorerFailure>) -> Void
  typealias PageCompletion =
    @Sendable (Result<ViewerEventPage, ViewerStoreExplorerFailure>) -> Void
  typealias GapCompletion =
    @Sendable (Result<ViewerGapPage, ViewerStoreExplorerFailure>) -> Void

  let endTraversal: @Sendable (@escaping VoidCompletion) -> ViewerExplorerStoreOperationToken
  let replaceQuery:
    @Sendable (
      ViewerEventQuery, ViewerExplorerStoreOperationToken, @escaping QueryCompletion
    ) -> ViewerExplorerStoreOperationToken
  let loadTailPage:
    @Sendable (
      ViewerExplorerStoreOperationToken, @escaping PageCompletion
    ) -> ViewerExplorerStoreOperationToken
  let loadTailGaps:
    @Sendable (
      [Int64], ViewerExplorerStoreOperationToken, @escaping GapCompletion
    ) -> ViewerExplorerStoreOperationToken

  init(gateway: ViewerStoreExplorerGateway) {
    endTraversal = { completion in
      ViewerExplorerStoreOperationToken(gateway.endTraversal(completion: completion))
    }
    replaceQuery = { query, predecessor, completion in
      guard let predecessor = predecessor.gatewayToken else {
        completion(.failure(.storeReplaced))
        return .invalid
      }
      return ViewerExplorerStoreOperationToken(
        gateway.replaceQuery(query, following: predecessor, completion: completion)
      )
    }
    loadTailPage = { predecessor, completion in
      guard let predecessor = predecessor.gatewayToken else {
        completion(.failure(.storeReplaced))
        return .invalid
      }
      return ViewerExplorerStoreOperationToken(
        gateway.loadPage(
          cursor: nil,
          direction: .backward,
          limit: 100,
          following: predecessor,
          completion: completion
        )
      )
    }
    loadTailGaps = { deviceSessionIDs, predecessor, completion in
      guard let predecessor = predecessor.gatewayToken else {
        completion(.failure(.storeReplaced))
        return .invalid
      }
      return ViewerExplorerStoreOperationToken(
        gateway.loadGapPage(
          deviceSessionIDs: deviceSessionIDs,
          cursor: nil,
          direction: .backward,
          limit: 32,
          following: predecessor,
          completion: completion
        )
      )
    }
  }

  init(
    endTraversal:
      @escaping @Sendable (@escaping VoidCompletion) -> ViewerExplorerStoreOperationToken,
    replaceQuery:
      @escaping @Sendable (
        ViewerEventQuery, ViewerExplorerStoreOperationToken, @escaping QueryCompletion
      ) -> ViewerExplorerStoreOperationToken,
    loadTailPage:
      @escaping @Sendable (
        ViewerExplorerStoreOperationToken, @escaping PageCompletion
      ) -> ViewerExplorerStoreOperationToken,
    loadTailGaps:
      @escaping @Sendable (
        [Int64], ViewerExplorerStoreOperationToken, @escaping GapCompletion
      ) -> ViewerExplorerStoreOperationToken
  ) {
    self.endTraversal = endTraversal
    self.replaceQuery = replaceQuery
    self.loadTailPage = loadTailPage
    self.loadTailGaps = loadTailGaps
  }
}

@MainActor
final class ViewerEventExplorerCoordinator: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  typealias PresentationHandler = @MainActor @Sendable () -> Void

  private struct LoadProgress {
    let token: ViewerExplorerPresentationToken
    let reason: ViewerExplorerTraversalReason
    var durableFinished: Bool
    var gapFinished: Bool
    var liveFinished: Bool
    var liveObservationIDsByKey: [ViewerEventJournalKey: UUID]
  }

  private struct LiveEvaluationOperation {
    let token: ViewerExplorerPresentationToken
    let cancellation: ViewerLiveEvaluationCancellation
  }

  let model: ViewerEventExplorerModel
  private let store: ViewerExplorerStoreDriver
  private let live: any ViewerLiveObservationProviding
  private let evaluationQueue: DispatchQueue
  private let evaluator: ViewerLiveEventEvaluator
  private let workTracker = ViewerAsyncWorkTracker()

  private(set) var state: ViewerExplorerTraversalState = .idle
  private var progress: LoadProgress?
  private var requestCount: UInt64 = 0
  private var releaseRequestCount: UInt64 = 0
  private var releaseCompletionCount: UInt64 = 0
  private var durableQueryCount: UInt64 = 0
  private var liveSnapshotCount: UInt64 = 0
  private var presentationHandler: PresentationHandler = {}
  private var liveEvaluationOperation: LiveEvaluationOperation?
  private(set) var isAnalysisActive = true

  init(
    model: ViewerEventExplorerModel,
    inputs: ViewerRuntimeExplorerInputs,
    evaluationQueue: DispatchQueue? = nil,
    evaluator: ViewerLiveEventEvaluator = ViewerLiveEventEvaluator()
  ) {
    precondition(model.runtimeLogicalID == inputs.runtimeLogicalID)
    self.model = model
    store = ViewerExplorerStoreDriver(gateway: inputs.storeGateway)
    live = inputs.liveObservations
    self.evaluationQueue =
      evaluationQueue
      ?? DispatchQueue(
        label: "com.nearwire.viewer.explorer-live-evaluation.\(inputs.runtimeLogicalID.uuidString)",
        qos: .userInitiated
      )
    self.evaluator = evaluator
  }

  init(
    model: ViewerEventExplorerModel,
    store: ViewerExplorerStoreDriver,
    live: any ViewerLiveObservationProviding,
    evaluationQueue: DispatchQueue? = nil,
    evaluator: ViewerLiveEventEvaluator = ViewerLiveEventEvaluator()
  ) {
    precondition(model.runtimeLogicalID == live.runtimeLogicalID)
    self.model = model
    self.store = store
    self.live = live
    self.evaluationQueue =
      evaluationQueue
      ?? DispatchQueue(
        label: "com.nearwire.viewer.explorer-live-evaluation.\(live.runtimeLogicalID.uuidString)",
        qos: .userInitiated
      )
    self.evaluator = evaluator
  }

  var diagnostics: ViewerExplorerTraversalDiagnostics {
    ViewerExplorerTraversalDiagnostics(
      requestCount: requestCount,
      releaseRequestCount: releaseRequestCount,
      releaseCompletionCount: releaseCompletionCount,
      durableQueryCount: durableQueryCount,
      liveSnapshotCount: liveSnapshotCount
    )
  }

  var pendingWorkCount: Int { workTracker.activeCount }

  func waitForIdle() -> Task<Void, Never> {
    workTracker.waitTask()
  }

  func cancelActiveWork() {
    cancelLiveEvaluation()
  }

  @discardableResult
  func deactivateAndReleaseTraversal() -> Task<Void, Never> {
    guard isAnalysisActive else { return waitForIdle() }
    isAnalysisActive = false
    _ = model.beginPresentationReplacement(clearRows: false)
    cancelLiveEvaluation()
    progress = nil
    releaseRequestCount = Self.saturatingIncrement(releaseRequestCount)
    state = .releasing(.analysisModeSwitch)
    presentationHandler()

    let workID = workTracker.begin()
    let delivery = ViewerExplorerStoreDelivery()
    let storeToken = store.endTraversal { [weak self, workTracker, delivery] result in
      Task { @MainActor in
        self?.handleAnalysisDeactivation(result, delivery: delivery)
        workTracker.complete(workID)
      }
    }
    delivery.attach(storeToken)
    return waitForIdle()
  }

  @discardableResult
  func activateAndRefresh() -> Task<Void, Never> {
    guard !isAnalysisActive else { return waitForIdle() }
    isAnalysisActive = true
    guard !model.isPaused else {
      state = .paused
      presentationHandler()
      return waitForIdle()
    }
    let token = model.beginTimelineReplacement()
    requestFreshTraversal(
      reason: .analysisModeSwitch,
      token: token,
      jumpsToLatest: model.autoFollow
    )
    presentationHandler()
    return waitForIdle()
  }

  func setPresentationHandler(_ handler: @escaping PresentationHandler) {
    presentationHandler = handler
  }

  @discardableResult
  func pause() -> ViewerExplorerPresentationToken {
    guard !model.isPaused else { return model.currentToken }
    let token = model.setPaused(true)
    cancelLiveEvaluation()
    live.setPresentationPaused(true)
    progress = nil
    state = .paused
    presentationHandler()
    return token
  }

  @discardableResult
  func resume() -> ViewerExplorerPresentationToken {
    guard model.isPaused else { return model.currentToken }
    let token = model.setPaused(false)
    live.setPresentationPaused(false)
    if isAnalysisActive {
      requestFreshTraversal(reason: .resume, token: token, jumpsToLatest: false)
    }
    presentationHandler()
    return token
  }

  @discardableResult
  func jumpToLatest() -> ViewerExplorerPresentationToken {
    model.setAutoFollow(true)
    let token = model.beginTimelineReplacement()
    if isAnalysisActive {
      requestFreshTraversal(reason: .jumpToLatest, token: token, jumpsToLatest: true)
    }
    presentationHandler()
    return token
  }

  @discardableResult
  func refresh() -> ViewerExplorerPresentationToken {
    guard !model.isPaused, isAnalysisActive else { return model.currentToken }
    let token = model.beginTimelineReplacement(retainingPresentation: true)
    requestFreshTraversal(reason: .refresh, token: token, jumpsToLatest: false)
    presentationHandler()
    return token
  }

  @discardableResult
  func replaceScope(
    _ scope: ViewerExplorerScope,
    materialization: ViewerExplorerMaterializationSnapshot
  ) throws -> ViewerExplorerPresentationToken {
    let token = try model.replaceScope(scope, materialization: materialization)
    guard !model.isPaused, isAnalysisActive else { return token }
    requestFreshTraversal(reason: .scopeReplacement, token: token, jumpsToLatest: true)
    presentationHandler()
    return token
  }

  @discardableResult
  func replaceMaterialization(
    _ materialization: ViewerExplorerMaterializationSnapshot
  ) throws -> ViewerExplorerPresentationToken? {
    let unchanged = model.materializationSnapshot == materialization
    guard let token = try model.replaceMaterialization(materialization) else { return nil }
    guard !unchanged else { return token }
    guard !model.isPaused, isAnalysisActive else { return token }
    requestFreshTraversal(
      reason: .materializationReplacement,
      token: token,
      jumpsToLatest: model.autoFollow
    )
    presentationHandler()
    return token
  }

  func noteManualScroll(_ identity: ViewerExplorerEventIdentity?) {
    model.noteManualScroll(identity)
    presentationHandler()
  }

  nonisolated var description: String { "ViewerEventExplorerCoordinator(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private func requestFreshTraversal(
    reason: ViewerExplorerTraversalReason,
    token: ViewerExplorerPresentationToken,
    jumpsToLatest: Bool
  ) {
    guard isAnalysisActive, !model.isPaused, token == model.currentToken else { return }
    cancelLiveEvaluation()
    requestCount = Self.saturatingIncrement(requestCount)
    releaseRequestCount = Self.saturatingIncrement(releaseRequestCount)
    state = .releasing(reason)
    presentationHandler()
    let workID = workTracker.begin()
    let delivery = ViewerExplorerStoreDelivery()
    let storeToken = store.endTraversal { [weak self, workTracker, delivery] result in
      Task { @MainActor in
        self?.handleRelease(
          result,
          reason: reason,
          token: token,
          jumpsToLatest: jumpsToLatest,
          delivery: delivery
        )
        workTracker.complete(workID)
      }
    }
    delivery.attach(storeToken)
  }

  private func handleRelease(
    _ result: Result<Void, ViewerStoreExplorerFailure>,
    reason: ViewerExplorerTraversalReason,
    token: ViewerExplorerPresentationToken,
    jumpsToLatest: Bool,
    delivery: ViewerExplorerStoreDelivery
  ) {
    releaseCompletionCount = Self.saturatingIncrement(releaseCompletionCount)
    guard let storeToken = delivery.validToken else { return }
    guard isAnalysisActive, token == model.currentToken, !model.isPaused else { return }
    guard case .success = result else {
      if case .failure(let failure) = result {
        failFreshTraversal(failure, token: token, reason: reason)
      }
      return
    }
    let retainsPresentation = reason == .refresh
    guard
      model.prepareFreshTraversal(
        token: token,
        jumpsToLatest: jumpsToLatest,
        retainingPresentation: retainsPresentation
      )
    else { return }
    state = .loading(reason)
    presentationHandler()
    let compiledInputs = model.compiledInputs
    if retainsPresentation,
      !model.clearAbsentRefreshLanes(
        hasDurableLane: compiledInputs?.durableQuery != nil,
        hasLiveLane: compiledInputs?.liveRequest != nil,
        token: token
      )
    {
      failFreshTraversal(.invalidRequest, token: token)
      return
    }
    progress = LoadProgress(
      token: token,
      reason: reason,
      durableFinished: compiledInputs?.durableQuery == nil,
      gapFinished: compiledInputs?.durableQuery == nil,
      liveFinished: compiledInputs?.liveRequest == nil,
      liveObservationIDsByKey: [:]
    )
    if let liveRequest = compiledInputs?.liveRequest {
      evaluateLive(liveRequest, token: token)
    }
    if let durableQuery = compiledInputs?.durableQuery {
      startDurableTraversal(durableQuery, following: storeToken, token: token)
    }
    finishIfReady(token: token)
  }

  private func evaluateLive(
    _ request: ViewerLiveEvaluationRequest,
    token: ViewerExplorerPresentationToken
  ) {
    let snapshot = live.snapshot()
    liveSnapshotCount = Self.saturatingIncrement(liveSnapshotCount)
    if var current = progress, current.token == token {
      let liveObservationPairs = snapshot.events.map {
        ($0.observation.key, $0.observation.observationID)
      }
      guard Set(liveObservationPairs.map(\.0)).count == liveObservationPairs.count else {
        failFreshTraversal(.invalidRequest, token: token)
        return
      }
      current.liveObservationIDsByKey = Dictionary(uniqueKeysWithValues: liveObservationPairs)
      progress = current
    }
    let evaluator = evaluator
    let cancellation = ViewerLiveEvaluationCancellation()
    liveEvaluationOperation?.cancellation.cancel()
    liveEvaluationOperation = LiveEvaluationOperation(token: token, cancellation: cancellation)
    let workID = workTracker.begin()
    evaluationQueue.async { [weak self, workTracker] in
      let result = evaluator.evaluate(snapshot: snapshot, request: request) {
        cancellation.isCancelled
      }
      Task { @MainActor in
        self?.handleLiveEvaluation(result, snapshot: snapshot, token: token)
        workTracker.complete(workID)
      }
    }
  }

  private func handleLiveEvaluation(
    _ result: ViewerLiveEvaluationResult,
    snapshot: ViewerLiveProjectionSnapshot,
    token: ViewerExplorerPresentationToken
  ) {
    if liveEvaluationOperation?.token == token { liveEvaluationOperation = nil }
    guard isAnalysisActive, token == model.currentToken, !model.isPaused else { return }
    switch result {
    case .complete(let output):
      do {
        guard
          let mutation = try model.applyLiveEvaluation(
            snapshot: snapshot,
            output: output,
            token: token
          )
        else {
          failFreshTraversal(.invalidRequest, token: token)
          return
        }
        publishDurableVisibilities(mutation.durableVisibilities, token: token)
      } catch {
        failFreshTraversal(.invalidRequest, token: token)
        return
      }
    case .refineRequired:
      _ = model.applyLiveRefineRequired(snapshot: snapshot, token: token)
    case .cancelled:
      return
    }
    presentationHandler()
    markFinished(\.liveFinished, token: token)
  }

  private func startDurableTraversal(
    _ query: ViewerEventQuery,
    following predecessor: ViewerExplorerStoreOperationToken,
    token: ViewerExplorerPresentationToken
  ) {
    durableQueryCount = Self.saturatingIncrement(durableQueryCount)
    let workID = workTracker.begin()
    let delivery = ViewerExplorerStoreDelivery()
    let storeToken = store.replaceQuery(query, predecessor) {
      [weak self, workTracker, delivery] result in
      Task { @MainActor in
        self?.handleQueryReplacement(result, token: token, delivery: delivery)
        workTracker.complete(workID)
      }
    }
    delivery.attach(storeToken)
  }

  private func handleQueryReplacement(
    _ result: Result<ViewerQuerySnapshot, ViewerStoreExplorerFailure>,
    token: ViewerExplorerPresentationToken,
    delivery: ViewerExplorerStoreDelivery
  ) {
    guard let storeToken = delivery.validToken else { return }
    guard isAnalysisActive, token == model.currentToken, !model.isPaused else { return }
    guard case .success = result else {
      if case .failure(let failure) = result {
        failFreshTraversal(failure, token: token)
      }
      return
    }
    let pageWorkID = workTracker.begin()
    let pageDelivery = ViewerExplorerStoreDelivery()
    let pageStoreToken = store.loadTailPage(storeToken) {
      [weak self, workTracker, pageDelivery] result in
      Task { @MainActor in
        self?.handleTailPage(result, token: token, delivery: pageDelivery)
        workTracker.complete(pageWorkID)
      }
    }
    pageDelivery.attach(pageStoreToken)
    let gapWorkID = workTracker.begin()
    let gapDelivery = ViewerExplorerStoreDelivery()
    let gapStoreToken = store.loadTailGaps(currentDurableDeviceSessionIDs(), storeToken) {
      [weak self, workTracker, gapDelivery] result in
      Task { @MainActor in
        self?.handleTailGaps(result, token: token, delivery: gapDelivery)
        workTracker.complete(gapWorkID)
      }
    }
    gapDelivery.attach(gapStoreToken)
  }

  private func handleTailPage(
    _ result: Result<ViewerEventPage, ViewerStoreExplorerFailure>,
    token: ViewerExplorerPresentationToken,
    delivery: ViewerExplorerStoreDelivery
  ) {
    guard delivery.validToken != nil else { return }
    guard isAnalysisActive, token == model.currentToken, !model.isPaused else { return }
    switch result {
    case .success(let page):
      guard let mutation = model.applyTimelinePage(page, placement: .replace, token: token) else {
        failFreshTraversal(.invalidRequest, token: token)
        return
      }
      publishDurableVisibilities(mutation.durableVisibilities, token: token)
      publishVisibleDurableRows(page.rows, token: token)
      markFinished(\.durableFinished, token: token)
      presentationHandler()
    case .failure(let failure):
      failFreshTraversal(failure, token: token)
    }
  }

  private func handleTailGaps(
    _ result: Result<ViewerGapPage, ViewerStoreExplorerFailure>,
    token: ViewerExplorerPresentationToken,
    delivery: ViewerExplorerStoreDelivery
  ) {
    guard delivery.validToken != nil else { return }
    guard isAnalysisActive, token == model.currentToken, !model.isPaused else { return }
    switch result {
    case .success(let page):
      guard model.applyGapPage(page, placement: .replace, token: token) else {
        failFreshTraversal(.invalidRequest, token: token)
        return
      }
      markFinished(\.gapFinished, token: token)
      presentationHandler()
    case .failure(let failure):
      failFreshTraversal(failure, token: token)
    }
  }

  private func publishDurableVisibilities(
    _ values: [ViewerExplorerDurableVisibility],
    token: ViewerExplorerPresentationToken
  ) {
    guard var current = progress, current.token == token else { return }
    for value in values {
      guard current.liveObservationIDsByKey[value.key] == value.observationID else { continue }
      current.liveObservationIDsByKey.removeValue(forKey: value.key)
      live.durableRowBecameVisible(key: value.key, observationID: value.observationID)
    }
    progress = current
  }

  private func publishVisibleDurableRows(
    _ rows: [ViewerStoredEventRow],
    token: ViewerExplorerPresentationToken
  ) {
    guard var current = progress, current.token == token else { return }
    for row in rows {
      guard
        let key = ViewerExplorerTimelineReconciler.durableJournalKey(
          for: row,
          scope: model.explorerScope,
          materialization: model.materializationSnapshot
        ),
        let observationID = current.liveObservationIDsByKey.removeValue(forKey: key)
      else { continue }
      live.durableRowBecameVisible(key: key, observationID: observationID)
    }
    progress = current
  }

  private func currentDurableDeviceSessionIDs() -> [Int64] {
    guard let scope = model.explorerScope, let materialization = model.materializationSnapshot
    else {
      return []
    }
    switch scope.devices {
    case .all:
      return []
    case .selected(let logicalIDs):
      return logicalIDs.compactMap { materialization.deviceSessionIDsByLogicalID[$0] }.sorted()
    }
  }

  private func markFinished(
    _ keyPath: WritableKeyPath<LoadProgress, Bool>,
    token: ViewerExplorerPresentationToken
  ) {
    guard var current = progress, current.token == token else { return }
    current[keyPath: keyPath] = true
    progress = current
    finishIfReady(token: token)
  }

  private func finishIfReady(token: ViewerExplorerPresentationToken) {
    guard isAnalysisActive, let current = progress, current.token == token,
      current.durableFinished, current.gapFinished, current.liveFinished
    else { return }
    progress = nil
    model.finishFreshTraversal(token: token)
    state = .ready(current.reason)
    presentationHandler()
  }

  private func failFreshTraversal(
    _ failure: ViewerStoreExplorerFailure,
    token: ViewerExplorerPresentationToken,
    reason: ViewerExplorerTraversalReason? = nil
  ) {
    let failedReason = reason ?? progress?.reason
    if failedReason == .refresh {
      _ = model.finishRetainedRefreshFailure(token: token)
    }
    progress = nil
    state = .failed(failure)
    presentationHandler()
  }

  private func cancelLiveEvaluation() {
    liveEvaluationOperation?.cancellation.cancel()
    liveEvaluationOperation = nil
  }

  private func handleAnalysisDeactivation(
    _ result: Result<Void, ViewerStoreExplorerFailure>,
    delivery: ViewerExplorerStoreDelivery
  ) {
    releaseCompletionCount = Self.saturatingIncrement(releaseCompletionCount)
    guard delivery.validToken != nil, !isAnalysisActive else { return }
    progress = nil
    switch result {
    case .success:
      state = model.isPaused ? .paused : .idle
    case .failure(let failure):
      state = .failed(failure)
    }
    presentationHandler()
  }

  private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? UInt64.max : value + 1
  }
}
