import Foundation
@_spi(NearWireInternal) import NearWireCore

enum ViewerPerformancePipelineLimits {
  static let maximumDecodedEventsPerTurn = 64
  static let minimumDeliveryIntervalNanoseconds: UInt64 = 100_000_000
}

enum ViewerPerformanceProjectionCoverage: Equatable, Sendable {
  case completeRange
  case liveWindowOnly
}

struct ViewerPerformanceCurrentFreshnessReceipt: Equatable, Sendable {
  let sourceGeneration: UInt64
  let latestEventKey: ViewerEventJournalKey?
  let absoluteDeadlineMonotonicNanoseconds: Int64?
  let deadlineRevision: UInt64

  init(
    sourceGeneration: UInt64,
    latestEventKey: ViewerEventJournalKey?,
    absoluteDeadlineMonotonicNanoseconds: Int64?,
    deadlineRevision: UInt64
  ) throws {
    guard sourceGeneration > 0, deadlineRevision > 0,
      (latestEventKey == nil) == (absoluteDeadlineMonotonicNanoseconds == nil),
      absoluteDeadlineMonotonicNanoseconds.map({ $0 >= 0 }) ?? true
    else { throw ViewerPerformanceFailure.invalidCarrier }
    self.sourceGeneration = sourceGeneration
    self.latestEventKey = latestEventKey
    self.absoluteDeadlineMonotonicNanoseconds = absoluteDeadlineMonotonicNanoseconds
    self.deadlineRevision = deadlineRevision
  }
}

enum ViewerPerformanceFreshnessReceipt: Equatable, Sendable {
  case current(ViewerPerformanceCurrentFreshnessReceipt)

  var sourceGeneration: UInt64 {
    switch self {
    case .current(let receipt): return receipt.sourceGeneration
    }
  }
}

struct ViewerPerformanceProjectionPublication: Equatable, Sendable {
  let cacheKey: ViewerPerformanceCacheKey
  let result: ViewerPerformanceAggregationResult
  let cards: ViewerPerformanceCardEvaluation
  let chartProjections: [ViewerPerformanceChartProjection]
  let coverage: ViewerPerformanceProjectionCoverage
  let freshnessReceipt: ViewerPerformanceFreshnessReceipt
  let decodedEventCount: UInt64
  let decodeTurnCount: UInt64

  func validatingCurrentFreshness(
    currentUptimeNanoseconds: Int64?
  ) throws -> ViewerPerformanceProjectionPublication {
    guard case .current(let receipt) = freshnessReceipt else { return self }
    guard let currentUptimeNanoseconds, currentUptimeNanoseconds >= 0 else {
      throw ViewerPerformanceFailure.invalidScope
    }
    guard let deadline = receipt.absoluteDeadlineMonotonicNanoseconds,
      currentUptimeNanoseconds >= deadline
    else { return self }
    return ViewerPerformanceProjectionPublication(
      cacheKey: cacheKey,
      result: result,
      cards: try cards.restatingNoRecentSample(),
      chartProjections: chartProjections,
      coverage: coverage,
      freshnessReceipt: freshnessReceipt,
      decodedEventCount: decodedEventCount,
      decodeTurnCount: decodeTurnCount
    )
  }
}

private struct ViewerPerformanceProjectionReducer: Sendable {
  let source: ViewerPerformanceSource
  let sourceGeneration: UInt64
  let bounds: ViewerPerformanceRangeBounds
  private(set) var buckets: [ViewerPerformanceBucket]
  private var availability = ViewerPerformanceAvailabilityAccumulatorSet()
  private var details = ViewerPerformanceBoundedDetails()
  private var cardSelector: ViewerPerformanceLatestEventSelector
  private var continuity = ViewerPerformanceContinuityTracker()
  private var wallBuilder: ViewerPerformanceWallEnvelopeBuilder
  private var previousEvent: ViewerPerformanceEventCarrier?
  private(set) var decodedEventCount: UInt64 = 0

  var detailedGapCount: Int { details.gaps.count }
  var invalidDetailCount: Int { details.invalidSnapshots.count }

  init(
    source: ViewerPerformanceSource,
    sourceGeneration: UInt64,
    bounds: ViewerPerformanceRangeBounds,
    deviceStartMonotonicNanoseconds: Int64
  ) throws {
    guard sourceGeneration > 0 else { throw ViewerPerformanceFailure.invalidScope }
    self.source = source
    self.sourceGeneration = sourceGeneration
    self.bounds = bounds
    buckets = try bounds.makeBuckets()
    cardSelector = try ViewerPerformanceLatestEventSelector(
      deviceStartMonotonicNanoseconds: deviceStartMonotonicNanoseconds,
      anchorMonotonicNanoseconds: bounds.upperMonotonicNanoseconds
    )
    wallBuilder = ViewerPerformanceWallEnvelopeBuilder(bounds: bounds)
  }

  mutating func consume(_ event: ViewerPerformanceEventCarrier) throws {
    try validateSource(event)
    guard event.viewerMonotonicNanoseconds <= bounds.upperMonotonicNanoseconds else {
      throw ViewerPerformanceFailure.invalidCarrier
    }
    if let previousEvent {
      guard ViewerPerformanceCanonicalOrder.eventPrecedes(previousEvent, event) else {
        throw ViewerPerformanceFailure.invalidCarrier
      }
    }

    if let bucketIndex = bounds.bucketIndex(containing: event.viewerMonotonicNanoseconds) {
      let outcome = ViewerPerformanceSnapshotDecoder.decode(event.content)
      try cardSelector.consider(event, decodedOutcome: outcome)
      try wallBuilder.observe(event)
      switch outcome {
      case .valid(let snapshot):
        availability.record(snapshot)
      case .invalid(let reason):
        availability.recordInvalid()
        details.append(
          invalid: try ViewerPerformanceInvalidDetail(
            key: event.key,
            viewerMonotonicNanoseconds: event.viewerMonotonicNanoseconds,
            reason: reason
          )
        )
      }
      try continuity.consume(
        event: event,
        outcome: outcome,
        bucket: &buckets[bucketIndex],
        sourceGeneration: sourceGeneration
      )
    } else {
      try cardSelector.consider(event)
    }
    decodedEventCount = Self.increment(decodedEventCount)
    previousEvent = event
  }

  func makeWallIndex() -> ViewerPerformanceWallEnvelopeIndex {
    wallBuilder.makeIndex()
  }

  mutating func finalize(
    gapProjection: ViewerPerformanceGapProjection,
    coverage: ViewerPerformanceProjectionCoverage,
    referenceMonotonicNanoseconds: Int64
  ) throws -> (ViewerPerformanceAggregationResult, ViewerPerformanceCardEvaluation) {
    var gapProjection = gapProjection
    try gapProjection.applyDiscontinuities(to: &buckets)
    if coverage == .liveWindowOnly, !buckets.isEmpty {
      buckets[0].markAllDiscontinuous()
    }
    details.merge(gapProjection.details)
    let result = try ViewerPerformanceAggregationResult(
      buckets: buckets,
      details: details,
      availability: availability.entries
    )
    let cards = try cardSelector.evaluate(
      referenceMonotonicNanoseconds: referenceMonotonicNanoseconds
    )
    return (result, cards)
  }

  private func validateSource(_ event: ViewerPerformanceEventCarrier) throws {
    let expectedRuntime: UUID
    let expectedConnection: UUID
    switch source {
    case .current(let runtimeLogicalID, let connectionID):
      expectedRuntime = runtimeLogicalID
      expectedConnection = connectionID
    }
    guard event.key.runtimeLogicalID == expectedRuntime,
      event.key.connectionID == expectedConnection
    else { throw ViewerPerformanceFailure.invalidCarrier }
  }

  private static func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? value : value + 1
  }
}

enum ViewerPerformanceDecodeTurnOutcome: Equatable, Sendable {
  case processed(Int)
  case eventsComplete
}

struct ViewerPerformanceProjectionSession: Sendable {
  let receipt: ViewerPerformanceFrozenReceipt
  let rangeKind: ViewerPerformanceRangeKind
  let bounds: ViewerPerformanceRangeBounds
  let coverage: ViewerPerformanceProjectionCoverage
  private let sourceGeneration: UInt64

  private var reducer: ViewerPerformanceProjectionReducer
  private let events: [ViewerPerformanceEventCarrier]
  private var eventIndex = 0
  private var gapProjection: ViewerPerformanceGapProjection?
  private(set) var decodeTurnCount: UInt64 = 0

  init(
    receipt: ViewerPerformanceFrozenReceipt,
    rangeKind: ViewerPerformanceRangeKind,
    bounds: ViewerPerformanceRangeBounds,
    deviceStartMonotonicNanoseconds: Int64,
    sourceGeneration: UInt64
  ) throws {
    switch receipt.source {
    case .current(let runtimeLogicalID, let connectionID):
      guard receipt.liveSlice.runtimeLogicalID == runtimeLogicalID,
        receipt.liveSlice.connectionID == connectionID,
        Int64(exactly: receipt.liveSlice.anchorMonotonicNanoseconds)
          == bounds.upperMonotonicNanoseconds
      else { throw ViewerPerformanceFailure.invalidScope }
    }
    self.receipt = receipt
    self.rangeKind = rangeKind
    self.bounds = bounds
    self.sourceGeneration = sourceGeneration
    coverage = .liveWindowOnly
    reducer = try ViewerPerformanceProjectionReducer(
      source: receipt.source,
      sourceGeneration: sourceGeneration,
      bounds: bounds,
      deviceStartMonotonicNanoseconds: deviceStartMonotonicNanoseconds
    )
    events = receipt.liveSlice.events
  }

  var eventsAreComplete: Bool {
    eventIndex == events.count
  }

  var isReadyToFinalize: Bool { eventsAreComplete }

  var retainedRawEventCount: Int { events.count }

  var activeAccountedBytes: Int {
    get throws {
      let projectedGapCount = min(
        ViewerPerformanceAggregationLimits.maximumDetailedGaps,
        reducer.detailedGapCount + (gapProjection?.details.gaps.count ?? 0)
      )
      return try ViewerPerformanceAccounting.activeReducerBytes(
        bucketCount: bounds.bucketCount,
        detailedGapCount: projectedGapCount,
        invalidDetailCount: reducer.invalidDetailCount
      )
    }
  }

  mutating func runDecodeTurn() throws -> ViewerPerformanceDecodeTurnOutcome {
    guard !eventsAreComplete else { return .eventsComplete }
    var processed = 0
    while processed < ViewerPerformancePipelineLimits.maximumDecodedEventsPerTurn,
      eventIndex < events.count
    {
      try reducer.consume(events[eventIndex])
      eventIndex += 1
      processed += 1
    }
    if processed > 0 {
      decodeTurnCount = Self.increment(decodeTurnCount)
      return .processed(processed)
    }
    return .eventsComplete
  }

  mutating func finalize(
    sourceGeneration: UInt64,
    deadlineRevision: UInt64,
    currentUptimeNanoseconds: Int64?
  ) throws -> ViewerPerformanceProjectionPublication {
    guard sourceGeneration == self.sourceGeneration, deadlineRevision > 0, isReadyToFinalize else {
      throw ViewerPerformanceFailure.invalidContinuation
    }
    try ensureGapProjection()
    let reference: Int64
    switch receipt.source {
    case .current:
      guard let currentUptimeNanoseconds,
        currentUptimeNanoseconds >= bounds.upperMonotonicNanoseconds
      else { throw ViewerPerformanceFailure.invalidScope }
      reference = currentUptimeNanoseconds
    }
    let (result, cards) = try reducer.finalize(
      gapProjection: gapProjection!,
      coverage: coverage,
      referenceMonotonicNanoseconds: reference
    )
    let freshnessReceipt = ViewerPerformanceFreshnessReceipt.current(
      try ViewerPerformanceCurrentFreshnessReceipt(
        sourceGeneration: sourceGeneration,
        latestEventKey: cards.latestEventKey,
        absoluteDeadlineMonotonicNanoseconds: cards.freshnessDeadlineMonotonicNanoseconds,
        deadlineRevision: deadlineRevision
      )
    )
    return ViewerPerformanceProjectionPublication(
      cacheKey: try ViewerPerformanceCacheKey(
        receipt: receipt,
        rangeKind: rangeKind,
        bounds: bounds
      ),
      result: result,
      cards: cards,
      chartProjections: try ViewerPerformanceChartProjection.makeAll(buckets: result.buckets),
      coverage: coverage,
      freshnessReceipt: freshnessReceipt,
      decodedEventCount: reducer.decodedEventCount,
      decodeTurnCount: decodeTurnCount
    )
  }

  private mutating func ensureGapProjection() throws {
    guard eventsAreComplete else { throw ViewerPerformanceFailure.invalidContinuation }
    guard gapProjection == nil else { return }
    var projection = ViewerPerformanceGapProjection(wallIndex: reducer.makeWallIndex())
    try projection.consume(liveSlice: receipt.liveSlice)
    gapProjection = projection
  }

  private static func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? value : value + 1
  }
}

struct ViewerPerformanceRefreshToken: Equatable, Sendable {
  let sourceGeneration: UInt64
  let sequence: UInt64
  let source: ViewerPerformanceSource
  let rangeKind: ViewerPerformanceRangeKind

  init(
    sourceGeneration: UInt64,
    sequence: UInt64,
    source: ViewerPerformanceSource,
    rangeKind: ViewerPerformanceRangeKind
  ) throws {
    guard sourceGeneration > 0, sequence > 0 else {
      throw ViewerPerformanceFailure.invalidCarrier
    }
    self.sourceGeneration = sourceGeneration
    self.sequence = sequence
    self.source = source
    self.rangeKind = rangeKind
  }
}

enum ViewerPerformanceRefreshSubmission: Equatable, Sendable {
  case start(ViewerPerformanceRefreshToken)
  case retainedDirty
  case rejectedStale
}

struct ViewerPerformanceRefreshCompletionDecision: Equatable, Sendable {
  let publishesCompletedResult: Bool
  let successorToStart: ViewerPerformanceRefreshToken?
}

final class ViewerPerformanceRefreshAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var activeSourceGeneration: UInt64
  private var running: ViewerPerformanceRefreshToken?
  private var dirty: ViewerPerformanceRefreshToken?
  private var paused = false

  init(sourceGeneration: UInt64) {
    precondition(sourceGeneration > 0)
    activeSourceGeneration = sourceGeneration
  }

  func submit(_ token: ViewerPerformanceRefreshToken) -> ViewerPerformanceRefreshSubmission {
    lock.lock()
    defer { lock.unlock() }
    guard token.sourceGeneration == activeSourceGeneration else { return .rejectedStale }
    if paused || running != nil {
      dirty = token
      return .retainedDirty
    }
    running = token
    return .start(token)
  }

  func complete(
    _ token: ViewerPerformanceRefreshToken
  ) -> ViewerPerformanceRefreshCompletionDecision {
    lock.lock()
    defer { lock.unlock() }
    guard running == token else {
      return ViewerPerformanceRefreshCompletionDecision(
        publishesCompletedResult: false,
        successorToStart: nil
      )
    }
    running = nil
    guard token.sourceGeneration == activeSourceGeneration else {
      return ViewerPerformanceRefreshCompletionDecision(
        publishesCompletedResult: false,
        successorToStart: nil
      )
    }
    if paused {
      if dirty == nil { dirty = token }
      return ViewerPerformanceRefreshCompletionDecision(
        publishesCompletedResult: false,
        successorToStart: nil
      )
    }
    let successor = dirty
    dirty = nil
    running = successor
    return ViewerPerformanceRefreshCompletionDecision(
      publishesCompletedResult: true,
      successorToStart: successor
    )
  }

  func pause() {
    lock.lock()
    paused = true
    lock.unlock()
  }

  func resume() -> ViewerPerformanceRefreshToken? {
    lock.lock()
    defer { lock.unlock() }
    paused = false
    guard running == nil else { return nil }
    let successor = dirty
    dirty = nil
    running = successor
    return successor
  }

  func replaceSourceGeneration(_ generation: UInt64) -> ViewerPerformanceRefreshToken? {
    precondition(generation > 0)
    lock.lock()
    defer { lock.unlock() }
    let invalidatedRunning = running
    activeSourceGeneration = generation
    running = nil
    dirty = nil
    return invalidatedRunning
  }

  var runningCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return running == nil ? 0 : 1
  }

  var dirtyCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return dirty == nil ? 0 : 1
  }
}

final class ViewerPerformanceLatestDeliveryPump<Value: Sendable>: @unchecked Sendable {
  typealias Handler = @Sendable (Value) -> Void

  private let lock = NSLock()
  private let workTracker = ViewerAsyncWorkTracker()
  private let scheduler: ViewerLiveRefreshScheduler
  private let handler: Handler
  private var pending: Value?
  private var scheduled = false
  private var processing = false
  private var sealed = false
  private var lastDeliveryNanoseconds: UInt64?
  private var workID: UUID?
  private var scheduleCountValue: UInt64 = 0
  private var deliveryCountValue: UInt64 = 0

  init(
    scheduler: ViewerLiveRefreshScheduler = .live,
    handler: @escaping Handler
  ) {
    self.scheduler = scheduler
    self.handler = handler
  }

  @discardableResult
  func submit(_ value: Value) -> Bool {
    var shouldSchedule = false
    var delay: UInt64 = 0
    lock.lock()
    guard !sealed else {
      lock.unlock()
      return false
    }
    pending = value
    if !scheduled {
      scheduled = true
      if workID == nil {
        let id = UUID()
        workID = id
        workTracker.begin(id: id)
      }
      scheduleCountValue = Self.increment(scheduleCountValue)
      delay = nextDelayLocked(now: scheduler.now())
      shouldSchedule = true
    }
    lock.unlock()
    if shouldSchedule { schedule(after: delay) }
    return true
  }

  func cancelPending() {
    lock.lock()
    pending = nil
    lock.unlock()
  }

  func seal() {
    lock.lock()
    sealed = true
    pending = nil
    scheduled = false
    lock.unlock()
  }

  func sealAndWait() -> Task<Void, Never> {
    seal()
    return workTracker.waitTask()
  }

  func waitForIdle() -> Task<Void, Never> {
    workTracker.waitTask()
  }

  var retainedValueCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return (pending == nil ? 0 : 1) + (processing ? 1 : 0)
  }

  var pendingWorkCount: Int { workTracker.activeCount }

  var scheduleCount: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return scheduleCountValue
  }

  var deliveryCount: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return deliveryCountValue
  }

  private func schedule(after delay: UInt64) {
    scheduler.scheduleOnMain(delay) { [weak self] in self?.fire() }
  }

  private func fire() {
    let value: Value?
    var completionID: UUID?
    lock.lock()
    scheduled = false
    if sealed {
      value = nil
      pending = nil
      completionID = workID
      workID = nil
    } else {
      value = pending
      pending = nil
      processing = value != nil
      if value != nil {
        lastDeliveryNanoseconds = scheduler.now()
        deliveryCountValue = Self.increment(deliveryCountValue)
      }
    }
    lock.unlock()
    if let value { handler(value) }

    var shouldSchedule = false
    var delay: UInt64 = 0
    lock.lock()
    processing = false
    if !sealed, pending != nil, !scheduled {
      scheduled = true
      scheduleCountValue = Self.increment(scheduleCountValue)
      delay = nextDelayLocked(now: scheduler.now())
      shouldSchedule = true
    } else if !processing, completionID == nil {
      completionID = workID
      workID = nil
    }
    lock.unlock()
    if let completionID { workTracker.complete(completionID) }
    if shouldSchedule { schedule(after: delay) }
  }

  private func nextDelayLocked(now: UInt64) -> UInt64 {
    guard let lastDeliveryNanoseconds, now >= lastDeliveryNanoseconds else {
      return lastDeliveryNanoseconds == nil
        ? 0 : ViewerPerformancePipelineLimits.minimumDeliveryIntervalNanoseconds
    }
    let elapsed = now - lastDeliveryNanoseconds
    return elapsed >= ViewerPerformancePipelineLimits.minimumDeliveryIntervalNanoseconds
      ? 0 : ViewerPerformancePipelineLimits.minimumDeliveryIntervalNanoseconds - elapsed
  }

  private static func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? value : value + 1
  }
}

struct ViewerPerformanceDeliveryClaim: Sendable {
  fileprivate let id: UUID
  fileprivate let publication: ViewerPerformanceProjectionPublication
}

final class ViewerPerformanceDeliveryGate: @unchecked Sendable {
  private let lock = NSLock()
  private var expectedReceipt: ViewerPerformanceFreshnessReceipt?
  private var claimedID: UUID?

  func install(_ receipt: ViewerPerformanceFreshnessReceipt) {
    lock.lock()
    expectedReceipt = receipt
    claimedID = nil
    lock.unlock()
  }

  func claim(
    _ publication: ViewerPerformanceProjectionPublication,
    currentUptimeNanoseconds: Int64?
  ) throws -> ViewerPerformanceDeliveryClaim? {
    lock.lock()
    guard expectedReceipt == publication.freshnessReceipt, claimedID == nil else {
      lock.unlock()
      return nil
    }
    lock.unlock()
    let validated = try publication.validatingCurrentFreshness(
      currentUptimeNanoseconds: currentUptimeNanoseconds
    )

    lock.lock()
    guard expectedReceipt == publication.freshnessReceipt, claimedID == nil else {
      lock.unlock()
      return nil
    }
    let id = UUID()
    claimedID = id
    lock.unlock()
    return ViewerPerformanceDeliveryClaim(id: id, publication: validated)
  }

  func apply(
    _ claim: ViewerPerformanceDeliveryClaim,
    currentUptimeNanoseconds: Int64?
  ) throws -> ViewerPerformanceProjectionPublication? {
    lock.lock()
    guard claimedID == claim.id,
      expectedReceipt == claim.publication.freshnessReceipt
    else {
      lock.unlock()
      return nil
    }
    claimedID = nil
    lock.unlock()
    return try claim.publication.validatingCurrentFreshness(
      currentUptimeNanoseconds: currentUptimeNanoseconds
    )
  }

  func invalidate() {
    lock.lock()
    expectedReceipt = nil
    claimedID = nil
    lock.unlock()
  }
}

struct ViewerPerformanceScheduledDeadlineWork: Sendable {
  private let scheduleAction: @Sendable (UInt64) -> Void
  private let disarmAction: @Sendable () -> Void
  private let cancelAction: @Sendable () -> Void
  private let waitAction: @Sendable () async -> Void

  init(
    schedule: @escaping @Sendable (UInt64) -> Void,
    disarm: @escaping @Sendable () -> Void,
    cancel: @escaping @Sendable () -> Void,
    wait: @escaping @Sendable () async -> Void
  ) {
    scheduleAction = schedule
    disarmAction = disarm
    cancelAction = cancel
    waitAction = wait
  }

  func schedule(after delayNanoseconds: UInt64) { scheduleAction(delayNanoseconds) }
  func disarm() { disarmAction() }
  func cancel() { cancelAction() }
  func wait() async { await waitAction() }

  static let completed = ViewerPerformanceScheduledDeadlineWork(
    schedule: { _ in },
    disarm: {},
    cancel: {},
    wait: {}
  )
}

struct ViewerPerformanceDeadlineScheduler: Sendable {
  let now: @Sendable () -> Int64
  let makeMainWorker:
    @Sendable (@escaping @Sendable () -> Void) -> ViewerPerformanceScheduledDeadlineWork

  static let live = ViewerPerformanceDeadlineScheduler(
    now: {
      let value = DispatchTime.now().uptimeNanoseconds
      return value > UInt64(Int64.max) ? Int64.max : Int64(value)
    },
    makeMainWorker: { action in
      let worker = ViewerPerformanceDispatchDeadlineWorker(action: action)
      return ViewerPerformanceScheduledDeadlineWork(
        schedule: { worker.schedule(after: $0) },
        disarm: { worker.disarm() },
        cancel: { worker.cancel() },
        wait: { await worker.wait() }
      )
    }
  )
}

private final class ViewerPerformanceDispatchDeadlineWorker: @unchecked Sendable {
  private let lock = NSLock()
  private let completionGroup = DispatchGroup()
  private let source: DispatchSourceTimer
  private var cancelled = false

  init(action: @escaping @Sendable () -> Void) {
    let source = DispatchSource.makeTimerSource(queue: .main)
    self.source = source
    completionGroup.enter()
    source.setEventHandler(handler: action)
    source.setCancelHandler { [completionGroup] in completionGroup.leave() }
    source.schedule(deadline: .distantFuture)
    source.activate()
  }

  deinit { cancel() }

  func schedule(after delayNanoseconds: UInt64) {
    lock.lock()
    guard !cancelled else {
      lock.unlock()
      return
    }
    let delay = Int(clamping: delayNanoseconds)
    source.schedule(deadline: .now() + .nanoseconds(delay))
    lock.unlock()
  }

  func disarm() {
    lock.lock()
    if !cancelled { source.schedule(deadline: .distantFuture) }
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    guard !cancelled else {
      lock.unlock()
      return
    }
    cancelled = true
    source.cancel()
    lock.unlock()
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      completionGroup.notify(queue: .global(qos: .utility)) { continuation.resume() }
    }
  }
}

final class ViewerPerformanceFreshnessDeadlineOwner: @unchecked Sendable {
  typealias Handler = @Sendable (ViewerPerformanceCurrentFreshnessReceipt) -> Void

  private struct ActiveWake {
    let receipt: ViewerPerformanceCurrentFreshnessReceipt
    let handler: Handler
  }

  private let lock = NSLock()
  private let scheduler: ViewerPerformanceDeadlineScheduler
  private var active: ActiveWake?
  private var worker: ViewerPerformanceScheduledDeadlineWork?
  private var paused = false
  private var pausedExpiryDirty = false
  private var scheduleCountValue: UInt64 = 0
  private var fireCountValue: UInt64 = 0

  init(scheduler: ViewerPerformanceDeadlineScheduler = .live) {
    self.scheduler = scheduler
  }

  @discardableResult
  func arm(
    receipt: ViewerPerformanceFreshnessReceipt,
    handler: @escaping Handler
  ) -> Bool {
    guard case .current(let current) = receipt,
      current.latestEventKey != nil,
      let deadline = current.absoluteDeadlineMonotonicNanoseconds
    else {
      invalidate()
      return false
    }
    let now = scheduler.now()
    guard now >= 0, deadline > now else {
      invalidate()
      return false
    }
    lock.lock()
    if worker == nil {
      worker = scheduler.makeMainWorker { [weak self] in self?.fire() }
    }
    guard let installedWorker = worker else {
      lock.unlock()
      return false
    }
    active = ActiveWake(receipt: current, handler: handler)
    scheduleCountValue = Self.increment(scheduleCountValue)
    // Keep the physical command inside the owner lock so a concurrent arm or invalidation cannot
    // reorder an older deadline after the latest logical receipt.
    installedWorker.schedule(after: UInt64(deadline - now))
    lock.unlock()
    return true
  }

  func setPaused(_ value: Bool) {
    lock.lock()
    paused = value
    lock.unlock()
  }

  func resumeConsumesDirtyExpiry() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    paused = false
    let dirty = pausedExpiryDirty
    pausedExpiryDirty = false
    return dirty
  }

  func invalidate() {
    lock.lock()
    active = nil
    pausedExpiryDirty = false
    worker?.disarm()
    lock.unlock()
  }

  func invalidateAndWait() -> Task<Void, Never> {
    lock.lock()
    active = nil
    pausedExpiryDirty = false
    let work = worker
    worker = nil
    work?.cancel()
    lock.unlock()
    return Task { await work?.wait() }
  }

  var activeWakeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return active == nil ? 0 : 1
  }

  var scheduleCount: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return scheduleCountValue
  }

  var fireCount: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return fireCountValue
  }

  private func fire() {
    let wake: ActiveWake?
    lock.lock()
    guard let active else {
      lock.unlock()
      return
    }
    let now = scheduler.now()
    guard let deadline = active.receipt.absoluteDeadlineMonotonicNanoseconds,
      now >= deadline
    else {
      lock.unlock()
      return
    }
    self.active = nil
    fireCountValue = Self.increment(fireCountValue)
    if paused {
      pausedExpiryDirty = true
      wake = nil
    } else {
      wake = active
    }
    lock.unlock()
    if let wake { wake.handler(wake.receipt) }
  }

  private static func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? value : value + 1
  }
}

extension ViewerPerformanceProjectionPublication: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceProjectionPublication(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceProjectionSession: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceProjectionSession(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceDeliveryClaim: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceDeliveryClaim(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceLatestDeliveryPump: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceLatestDeliveryPump(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
