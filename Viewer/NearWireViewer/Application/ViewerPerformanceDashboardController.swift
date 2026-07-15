import Foundation

struct ViewerPerformanceDashboardTarget: Equatable, Sendable {
  let source: ViewerPerformanceSource
  let deviceStartMonotonicNanoseconds: Int64

  static func memoryCurrent(
    source: ViewerPerformanceSource,
    deviceStartMonotonicNanoseconds: Int64
  ) throws -> ViewerPerformanceDashboardTarget {
    guard case .current = source, deviceStartMonotonicNanoseconds >= 0 else {
      throw ViewerPerformanceFailure.invalidScope
    }
    return ViewerPerformanceDashboardTarget(
      source: source,
      deviceStartMonotonicNanoseconds: deviceStartMonotonicNanoseconds
    )
  }
}

struct ViewerPerformanceProjectionPreparation: Equatable, Sendable {
  let receipt: ViewerPerformanceFrozenReceipt
  let bounds: ViewerPerformanceRangeBounds
  let deviceStartMonotonicNanoseconds: Int64
}

struct ViewerPerformanceProjectionDriver: @unchecked Sendable {
  let prepare:
    @Sendable (
      ViewerPerformanceDashboardTarget,
      ViewerPerformanceRangeKind
    ) throws -> ViewerPerformanceProjectionPreparation
  let currentUptimeNanoseconds: @Sendable () -> Int64?

  init(
    live: any ViewerLiveObservationProviding,
    currentUptimeNanoseconds: @escaping @Sendable () -> Int64? = {
      let value = DispatchTime.now().uptimeNanoseconds
      return value > UInt64(Int64.max) ? nil : Int64(value)
    }
  ) {
    prepare = { target, rangeKind in
      switch target.source {
      case .current(let runtimeLogicalID, let connectionID):
        guard runtimeLogicalID == live.runtimeLogicalID else {
          throw ViewerPerformanceFailure.invalidScope
        }
        let liveSlice = try live.freezePerformance(connectionID: connectionID)
        let anchor = try ViewerPerformanceAnchor.current(
          source: target.source,
          liveSlice: liveSlice,
          deviceStartMonotonicNanoseconds: target.deviceStartMonotonicNanoseconds
        )
        return ViewerPerformanceProjectionPreparation(
          receipt: ViewerPerformanceFrozenReceipt(
            source: target.source,
            liveSlice: liveSlice
          ),
          bounds: try rangeKind.bounds(
            deviceStartMonotonicNanoseconds: anchor.deviceStartMonotonicNanoseconds,
            upperMonotonicNanoseconds: anchor.upperMonotonicNanoseconds
          ),
          deviceStartMonotonicNanoseconds: anchor.deviceStartMonotonicNanoseconds
        )
      }
    }
    self.currentUptimeNanoseconds = currentUptimeNanoseconds
  }
}

struct ViewerPerformanceDashboardControllerDiagnostics: Equatable, Sendable {
  let sourceGeneration: UInt64
  let activeRefreshCount: Int
  let hasDeferredRefresh: Bool
  let hasFreshnessDeadline: Bool
  let isAnalysisActive: Bool
  let isPaused: Bool
  let isSealed: Bool
}

@MainActor
final class ViewerPerformanceDashboardController: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  let model: ViewerPerformanceDashboardModel

  private typealias ProjectionResult = Result<
    ViewerPerformanceProjectionPublication,
    ViewerPerformanceFailure
  >

  private let driver: ViewerPerformanceProjectionDriver
  private var target: ViewerPerformanceDashboardTarget?
  private var rangeKind = ViewerPerformanceRangeKind.defaultKind
  private var sourceGeneration: UInt64 = 1
  private var operationRevision: UInt64 = 0
  private var analysisActive: Bool
  private var paused = false
  private var rawRevealSuspended = false
  private var dirtyRefresh = false
  private var sealed = false
  private var workerTask: Task<ProjectionResult, Never>?
  private var deliveryTask: Task<Void, Never>?
  private var deadlineTask: Task<Void, Never>?

  init(
    driver: ViewerPerformanceProjectionDriver,
    model: ViewerPerformanceDashboardModel = ViewerPerformanceDashboardModel(),
    analysisActive: Bool = true
  ) {
    self.driver = driver
    self.model = model
    self.analysisActive = analysisActive
  }

  @discardableResult
  func replace(
    target nextTarget: ViewerPerformanceDashboardTarget?,
    rangeKind nextRangeKind: ViewerPerformanceRangeKind
  ) -> Task<Void, Never> {
    guard !sealed else { return Task {} }
    let targetChanged = target != nextTarget
    let rangeChanged = rangeKind != nextRangeKind
    guard targetChanged || rangeChanged else { return Task {} }

    let wait = cancelProjectionWork()
    deadlineTask?.cancel()
    deadlineTask = nil
    operationRevision = Self.increment(operationRevision)
    sourceGeneration = Self.increment(sourceGeneration)
    target = nextTarget
    rangeKind = nextRangeKind
    dirtyRefresh = false

    guard let nextTarget else {
      model.replaceScope(nil)
      return wait
    }
    do {
      model.replaceScope(
        try ViewerPerformanceDashboardScope(
          sourceGeneration: sourceGeneration,
          source: nextTarget.source,
          rangeKind: nextRangeKind
        )
      )
      if analysisActive, !paused, !rawRevealSuspended { requestRefresh() }
    } catch let failure as ViewerPerformanceFailure {
      if let scope = try? ViewerPerformanceDashboardScope(
        sourceGeneration: sourceGeneration,
        source: nextTarget.source,
        rangeKind: nextRangeKind
      ) {
        model.replaceScope(scope)
        model.showFailure(failure, for: scope)
      }
    } catch {
      if let scope = model.scope { model.showFailure(.unavailable, for: scope) }
    }
    return wait
  }

  func requestRefresh() {
    guard !sealed, analysisActive, target != nil else { return }
    guard !paused, !rawRevealSuspended else {
      dirtyRefresh = true
      return
    }
    guard workerTask == nil else {
      dirtyRefresh = true
      return
    }
    startProjection()
  }

  func activate() {
    guard !sealed else { return }
    analysisActive = true
    requestRefresh()
  }

  func deactivateAndWait() -> Task<Void, Never> {
    analysisActive = false
    dirtyRefresh = false
    deadlineTask?.cancel()
    deadlineTask = nil
    return cancelProjectionWork()
  }

  func suspendForRawRevealAndWait() -> Task<Void, Never> {
    guard !sealed else { return Task {} }
    rawRevealSuspended = true
    deadlineTask?.cancel()
    deadlineTask = nil
    return cancelProjectionWork()
  }

  func resumeAfterRawReveal() {
    guard !sealed, rawRevealSuspended else { return }
    rawRevealSuspended = false
    requestRefresh()
  }

  func pause() {
    guard !sealed, !paused else { return }
    paused = true
    dirtyRefresh = dirtyRefresh || workerTask != nil
    deadlineTask?.cancel()
    deadlineTask = nil
    _ = cancelProjectionWork()
  }

  func resume() {
    guard !sealed, paused else { return }
    paused = false
    let shouldRefresh = dirtyRefresh || model.cards != nil
    dirtyRefresh = false
    if shouldRefresh { requestRefresh() }
  }

  func resetPauseForWindowClose() {
    guard !sealed, !analysisActive else { return }
    paused = false
    dirtyRefresh = false
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
    return model.setCrosshair(
      viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
      chartGroup: chartGroup,
      selectedMetric: selectedMetric
    )
  }

  func clearCrosshair() {
    model.clearCrosshair()
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
    sealed = true
    analysisActive = false
    dirtyRefresh = false
    target = nil
    deadlineTask?.cancel()
    let deadlineWait = deadlineTask
    deadlineTask = nil
    let projectionWait = cancelProjectionWork()
    model.seal()
    return Task {
      await projectionWait.value
      await deadlineWait?.value
    }
  }

  var diagnostics: ViewerPerformanceDashboardControllerDiagnostics {
    ViewerPerformanceDashboardControllerDiagnostics(
      sourceGeneration: sourceGeneration,
      activeRefreshCount: workerTask == nil ? 0 : 1,
      hasDeferredRefresh: dirtyRefresh,
      hasFreshnessDeadline: deadlineTask != nil,
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

  private func startProjection() {
    guard !sealed, analysisActive, !paused, !rawRevealSuspended,
      let target, let scope = model.scope
    else { return }

    operationRevision = Self.increment(operationRevision)
    let revision = operationRevision
    dirtyRefresh = false
    _ = model.beginLoading(for: scope)
    let driver = self.driver
    let rangeKind = self.rangeKind
    let sourceGeneration = self.sourceGeneration
    let worker = Task.detached(priority: .userInitiated) { () -> ProjectionResult in
      do {
        guard !Task.isCancelled else { throw ViewerPerformanceFailure.cancelled }
        let preparation = try driver.prepare(target, rangeKind)
        var projection = try ViewerPerformanceProjectionSession(
          receipt: preparation.receipt,
          rangeKind: rangeKind,
          bounds: preparation.bounds,
          deviceStartMonotonicNanoseconds: preparation.deviceStartMonotonicNanoseconds,
          sourceGeneration: sourceGeneration
        )
        while !projection.eventsAreComplete {
          guard !Task.isCancelled else { throw ViewerPerformanceFailure.cancelled }
          _ = try projection.runDecodeTurn()
          await Task.yield()
        }
        guard !Task.isCancelled else { throw ViewerPerformanceFailure.cancelled }
        let now = max(
          driver.currentUptimeNanoseconds() ?? preparation.bounds.upperMonotonicNanoseconds,
          preparation.bounds.upperMonotonicNanoseconds
        )
        return .success(
          try projection.finalize(
            sourceGeneration: sourceGeneration,
            deadlineRevision: revision,
            currentUptimeNanoseconds: now
          )
        )
      } catch let failure as ViewerPerformanceFailure {
        return .failure(failure)
      } catch {
        return .failure(.unavailable)
      }
    }
    workerTask = worker
    deliveryTask = Task { [weak self] in
      let result = await worker.value
      guard !Task.isCancelled else { return }
      self?.finishProjection(
        result,
        revision: revision,
        target: target,
        scope: scope
      )
    }
  }

  private func finishProjection(
    _ result: ProjectionResult,
    revision: UInt64,
    target expectedTarget: ViewerPerformanceDashboardTarget,
    scope expectedScope: ViewerPerformanceDashboardScope
  ) {
    guard operationRevision == revision else { return }
    workerTask = nil
    deliveryTask = nil
    guard !sealed, analysisActive, !paused, !rawRevealSuspended,
      target == expectedTarget, model.scope == expectedScope
    else { return }

    switch result {
    case .success(let publication):
      if model.apply(publication, for: expectedScope) {
        scheduleDeadline(for: publication)
      }
    case .failure(.cancelled):
      break
    case .failure(let failure):
      model.showFailure(failure, for: expectedScope)
    }

    if dirtyRefresh {
      dirtyRefresh = false
      requestRefresh()
    }
  }

  private func scheduleDeadline(for publication: ViewerPerformanceProjectionPublication) {
    deadlineTask?.cancel()
    deadlineTask = nil
    guard case .current(let receipt) = publication.freshnessReceipt,
      publication.cards.shouldArmDeadline,
      let deadline = receipt.absoluteDeadlineMonotonicNanoseconds
    else { return }
    let now = driver.currentUptimeNanoseconds() ?? deadline
    let delay = UInt64(max(0, deadline - now))
    deadlineTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
      } catch {
        return
      }
      guard let self, !self.sealed, self.analysisActive, !self.paused,
        !self.rawRevealSuspended
      else { return }
      _ = self.model.expireCurrentCards(matching: receipt)
      self.deadlineTask = nil
    }
  }

  private func cancelProjectionWork() -> Task<Void, Never> {
    operationRevision = Self.increment(operationRevision)
    let worker = workerTask
    let delivery = deliveryTask
    workerTask = nil
    deliveryTask = nil
    worker?.cancel()
    delivery?.cancel()
    return Task {
      _ = await worker?.value
      await delivery?.value
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

extension ViewerPerformanceProjectionDriver: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceProjectionDriver(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
