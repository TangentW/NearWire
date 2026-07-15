import Foundation
@_spi(NearWireInternal) import NearWireCore

enum ViewerPerformanceFreshness {
  static let minimumHorizonNanoseconds: UInt64 = 3_000_000_000
  static let maximumHorizonNanoseconds: UInt64 = 180_000_000_000
  static let lookbackNanoseconds: UInt64 = 180_000_000_000

  static func horizonNanoseconds(sampleIntervalMilliseconds: UInt64?) -> UInt64 {
    guard let sampleIntervalMilliseconds else { return minimumHorizonNanoseconds }
    let maximumIntervalMilliseconds = maximumHorizonNanoseconds / 3 / 1_000_000
    if sampleIntervalMilliseconds >= maximumIntervalMilliseconds {
      return maximumHorizonNanoseconds
    }
    let intervalNanoseconds = sampleIntervalMilliseconds * 1_000_000
    return min(
      maximumHorizonNanoseconds,
      max(minimumHorizonNanoseconds, intervalNanoseconds * 3)
    )
  }

  static func adjacencyHorizonNanoseconds(
    previousIntervalMilliseconds: UInt64?,
    currentIntervalMilliseconds: UInt64?
  ) -> UInt64 {
    horizonNanoseconds(
      sampleIntervalMilliseconds: max(
        previousIntervalMilliseconds ?? 0,
        currentIntervalMilliseconds ?? 0
      )
    )
  }

  static func deadline(
    eventMonotonicNanoseconds: Int64,
    horizonNanoseconds: UInt64
  ) throws -> Int64 {
    guard eventMonotonicNanoseconds >= 0,
      horizonNanoseconds > 0,
      horizonNanoseconds <= UInt64(Int64.max)
    else { throw ViewerPerformanceFailure.invalidScope }
    let (deadline, overflow) = eventMonotonicNanoseconds.addingReportingOverflow(
      Int64(horizonNanoseconds)
    )
    return overflow ? Int64.max : deadline
  }

  static func isFresh(
    eventMonotonicNanoseconds: Int64,
    referenceMonotonicNanoseconds: Int64,
    horizonNanoseconds: UInt64
  ) throws -> Bool {
    guard eventMonotonicNanoseconds >= 0,
      referenceMonotonicNanoseconds >= eventMonotonicNanoseconds
    else { throw ViewerPerformanceFailure.invalidScope }
    return UInt64(referenceMonotonicNanoseconds - eventMonotonicNanoseconds)
      < horizonNanoseconds
  }
}

enum ViewerPerformanceCardState: Equatable, Sendable {
  case measured(ViewerPerformanceMetricState)
  case invalidSnapshot(ViewerPerformanceInvalidSnapshotReason)
  case unavailable(UnavailablePerformanceMetricReason)
  case notCollected
  case noRecentSample
}

struct ViewerPerformanceCardEntry: Equatable, Sendable {
  let key: PerformanceMetricKey
  let state: ViewerPerformanceCardState
}

struct ViewerPerformanceCardEvaluation: Equatable, Sendable {
  let latestEventKey: ViewerEventJournalKey?
  let horizonNanoseconds: UInt64?
  let freshnessDeadlineMonotonicNanoseconds: Int64?
  let isFresh: Bool
  let entries: [ViewerPerformanceCardEntry]

  init(
    latestEventKey: ViewerEventJournalKey?,
    horizonNanoseconds: UInt64?,
    freshnessDeadlineMonotonicNanoseconds: Int64?,
    isFresh: Bool,
    entries: [ViewerPerformanceCardEntry]
  ) throws {
    guard entries.map(\.key) == PerformanceMetricKey.allCases,
      (latestEventKey == nil) == (horizonNanoseconds == nil),
      (latestEventKey == nil) == (freshnessDeadlineMonotonicNanoseconds == nil),
      !isFresh || latestEventKey != nil
    else { throw ViewerPerformanceFailure.invalidCarrier }
    self.latestEventKey = latestEventKey
    self.horizonNanoseconds = horizonNanoseconds
    self.freshnessDeadlineMonotonicNanoseconds = freshnessDeadlineMonotonicNanoseconds
    self.isFresh = isFresh
    self.entries = entries
  }

  func state(for key: PerformanceMetricKey) -> ViewerPerformanceCardState {
    guard let index = PerformanceMetricKey.allCases.firstIndex(of: key) else {
      preconditionFailure("Core performance metric inventory is incomplete")
    }
    return entries[index].state
  }

  var shouldArmDeadline: Bool { isFresh && freshnessDeadlineMonotonicNanoseconds != nil }

  func restatingNoRecentSample() throws -> ViewerPerformanceCardEvaluation {
    guard latestEventKey != nil else { return self }
    return try ViewerPerformanceCardEvaluation(
      latestEventKey: latestEventKey,
      horizonNanoseconds: horizonNanoseconds,
      freshnessDeadlineMonotonicNanoseconds: freshnessDeadlineMonotonicNanoseconds,
      isFresh: false,
      entries: PerformanceMetricKey.allCases.map {
        ViewerPerformanceCardEntry(key: $0, state: .noRecentSample)
      }
    )
  }
}

struct ViewerPerformanceLatestEventSelector: Sendable {
  let anchorMonotonicNanoseconds: Int64
  let lookbackLowerMonotonicNanoseconds: Int64
  private var latestEvent: ViewerPerformanceEventCarrier?
  private var latestOutcome: ViewerPerformanceDecodeOutcome?

  init(
    deviceStartMonotonicNanoseconds: Int64,
    anchorMonotonicNanoseconds: Int64
  ) throws {
    guard deviceStartMonotonicNanoseconds >= 0,
      anchorMonotonicNanoseconds >= deviceStartMonotonicNanoseconds
    else { throw ViewerPerformanceFailure.invalidScope }
    let anchor = UInt64(anchorMonotonicNanoseconds)
    let saturatedLower =
      anchor >= ViewerPerformanceFreshness.lookbackNanoseconds
      ? anchor - ViewerPerformanceFreshness.lookbackNanoseconds : 0
    self.anchorMonotonicNanoseconds = anchorMonotonicNanoseconds
    lookbackLowerMonotonicNanoseconds = max(
      deviceStartMonotonicNanoseconds,
      Int64(saturatedLower)
    )
  }

  mutating func consider(_ event: ViewerPerformanceEventCarrier) throws {
    try consider(event, decodedOutcome: nil)
  }

  mutating func consider(
    _ event: ViewerPerformanceEventCarrier,
    decodedOutcome: ViewerPerformanceDecodeOutcome
  ) throws {
    try consider(event, decodedOutcome: Optional(decodedOutcome))
  }

  private mutating func consider(
    _ event: ViewerPerformanceEventCarrier,
    decodedOutcome: ViewerPerformanceDecodeOutcome?
  ) throws {
    guard event.viewerMonotonicNanoseconds <= anchorMonotonicNanoseconds,
      event.viewerMonotonicNanoseconds >= lookbackLowerMonotonicNanoseconds
    else { return }
    if let latestEvent, latestEvent.key == event.key {
      self.latestEvent = try ViewerPerformanceEventReconciler.reconcile(latestEvent, event)
      return
    }
    if let latestEvent,
      !ViewerPerformanceCanonicalOrder.eventPrecedes(latestEvent, event)
    {
      return
    }
    latestEvent = event
    latestOutcome = decodedOutcome ?? ViewerPerformanceSnapshotDecoder.decode(event.content)
  }

  func evaluate(
    referenceMonotonicNanoseconds: Int64
  ) throws -> ViewerPerformanceCardEvaluation {
    guard let latestEvent, let latestOutcome else {
      return try ViewerPerformanceCardEvaluation(
        latestEventKey: nil,
        horizonNanoseconds: nil,
        freshnessDeadlineMonotonicNanoseconds: nil,
        isFresh: false,
        entries: Self.uniformEntries(.noRecentSample)
      )
    }
    let sampleInterval: UInt64?
    switch latestOutcome {
    case .valid(let snapshot): sampleInterval = snapshot.sampleIntervalMilliseconds
    case .invalid: sampleInterval = nil
    }
    let horizon = ViewerPerformanceFreshness.horizonNanoseconds(
      sampleIntervalMilliseconds: sampleInterval
    )
    let deadline = try ViewerPerformanceFreshness.deadline(
      eventMonotonicNanoseconds: latestEvent.viewerMonotonicNanoseconds,
      horizonNanoseconds: horizon
    )
    let fresh = try ViewerPerformanceFreshness.isFresh(
      eventMonotonicNanoseconds: latestEvent.viewerMonotonicNanoseconds,
      referenceMonotonicNanoseconds: referenceMonotonicNanoseconds,
      horizonNanoseconds: horizon
    )
    let entries: [ViewerPerformanceCardEntry]
    if !fresh {
      entries = Self.uniformEntries(.noRecentSample)
    } else {
      switch latestOutcome {
      case .invalid(let reason):
        entries = Self.uniformEntries(.invalidSnapshot(reason))
      case .valid(let snapshot):
        entries = PerformanceMetricKey.allCases.map { key in
          ViewerPerformanceCardEntry(key: key, state: Self.cardState(snapshot.state(for: key)))
        }
      }
    }
    return try ViewerPerformanceCardEvaluation(
      latestEventKey: latestEvent.key,
      horizonNanoseconds: horizon,
      freshnessDeadlineMonotonicNanoseconds: deadline,
      isFresh: fresh,
      entries: entries
    )
  }

  private static func uniformEntries(
    _ state: ViewerPerformanceCardState
  ) -> [ViewerPerformanceCardEntry] {
    PerformanceMetricKey.allCases.map { ViewerPerformanceCardEntry(key: $0, state: state) }
  }

  private static func cardState(
    _ state: ViewerPerformanceMetricState
  ) -> ViewerPerformanceCardState {
    switch state {
    case .numeric, .unsigned, .batteryState, .thermalState, .boolean:
      return .measured(state)
    case .unavailable(let reason):
      return .unavailable(reason)
    case .notCollected:
      return .notCollected
    }
  }
}

struct ViewerPerformanceContinuityTracker: Sendable {
  private var previousMonotonicNanoseconds: Int64?
  private var previousIntervalMilliseconds: UInt64?
  private var pendingMetricBreaks = Array(
    repeating: false,
    count: ViewerPerformanceNumericMetric.allCases.count
  )

  mutating func consume(
    event: ViewerPerformanceEventCarrier,
    outcome: ViewerPerformanceDecodeOutcome,
    bucket: inout ViewerPerformanceBucket,
    sourceGeneration: UInt64 = 1
  ) throws {
    if let previousMonotonicNanoseconds {
      guard event.viewerMonotonicNanoseconds >= previousMonotonicNanoseconds else {
        throw ViewerPerformanceFailure.invalidCarrier
      }
      let currentInterval: UInt64?
      switch outcome {
      case .valid(let snapshot): currentInterval = snapshot.sampleIntervalMilliseconds
      case .invalid: currentInterval = nil
      }
      let horizon = ViewerPerformanceFreshness.adjacencyHorizonNanoseconds(
        previousIntervalMilliseconds: previousIntervalMilliseconds,
        currentIntervalMilliseconds: currentInterval
      )
      if UInt64(event.viewerMonotonicNanoseconds - previousMonotonicNanoseconds) >= horizon {
        bucket.markAllDiscontinuous()
      }
    }

    switch outcome {
    case .valid(let snapshot):
      for metric in ViewerPerformanceNumericMetric.allCases {
        let isMeasurement = snapshot.state(for: metric.key).isMeasurement
        if pendingMetricBreaks[metric.rawValue] && isMeasurement {
          bucket.markDiscontinuous(metric)
        }
        pendingMetricBreaks[metric.rawValue] = !isMeasurement
      }
      try bucket.record(
        snapshot,
        event: event,
        sourceGeneration: sourceGeneration
      )
      previousIntervalMilliseconds = snapshot.sampleIntervalMilliseconds
    case .invalid:
      bucket.recordInvalidSnapshot()
      pendingMetricBreaks = Array(
        repeating: true,
        count: ViewerPerformanceNumericMetric.allCases.count
      )
      previousIntervalMilliseconds = nil
    }
    previousMonotonicNanoseconds = event.viewerMonotonicNanoseconds
  }
}

struct ViewerPerformanceBucketWallEnvelope: Equatable, Sendable {
  let bucketIndex: Int
  private(set) var lowerWallMilliseconds: Int64
  private(set) var upperWallMilliseconds: Int64

  mutating func include(_ wallMilliseconds: Int64) {
    lowerWallMilliseconds = min(lowerWallMilliseconds, wallMilliseconds)
    upperWallMilliseconds = max(upperWallMilliseconds, wallMilliseconds)
  }

  func overlaps(lower: Int64, upper: Int64) -> Bool {
    lower <= upperWallMilliseconds && upper >= lowerWallMilliseconds
  }
}

struct ViewerPerformanceWallEnvelopeIndex: Equatable, Sendable {
  let bucketCount: Int
  let hasWallRegression: Bool
  private let envelopes: [ViewerPerformanceBucketWallEnvelope?]

  fileprivate init(
    bucketCount: Int,
    hasWallRegression: Bool,
    envelopes: [ViewerPerformanceBucketWallEnvelope?]
  ) {
    self.bucketCount = bucketCount
    self.hasWallRegression = hasWallRegression
    self.envelopes = envelopes
  }

  func uniquelyOverlappingBucket(lowerWallMilliseconds: Int64, upperWallMilliseconds: Int64)
    -> Int?
  {
    guard !hasWallRegression, lowerWallMilliseconds <= upperWallMilliseconds else { return nil }
    var match: Int?
    for envelope in envelopes.compactMap({ $0 })
    where envelope.overlaps(lower: lowerWallMilliseconds, upper: upperWallMilliseconds) {
      if match != nil { return nil }
      match = envelope.bucketIndex
    }
    return match
  }
}

struct ViewerPerformanceWallEnvelopeBuilder: Sendable {
  private let bounds: ViewerPerformanceRangeBounds
  private var envelopes: [ViewerPerformanceBucketWallEnvelope?]
  private var previousEvent: ViewerPerformanceEventCarrier?
  private var hasWallRegression = false

  init(bounds: ViewerPerformanceRangeBounds) {
    self.bounds = bounds
    envelopes = Array(repeating: nil, count: bounds.bucketCount)
  }

  mutating func observe(_ event: ViewerPerformanceEventCarrier) throws {
    guard let index = bounds.bucketIndex(containing: event.viewerMonotonicNanoseconds) else {
      return
    }
    if let previousEvent {
      guard ViewerPerformanceCanonicalOrder.eventPrecedes(previousEvent, event) else {
        throw ViewerPerformanceFailure.invalidCarrier
      }
      if event.viewerWallMilliseconds < previousEvent.viewerWallMilliseconds {
        hasWallRegression = true
      }
    }
    if var envelope = envelopes[index] {
      envelope.include(event.viewerWallMilliseconds)
      envelopes[index] = envelope
    } else {
      envelopes[index] = ViewerPerformanceBucketWallEnvelope(
        bucketIndex: index,
        lowerWallMilliseconds: event.viewerWallMilliseconds,
        upperWallMilliseconds: event.viewerWallMilliseconds
      )
    }
    previousEvent = event
  }

  func makeIndex() -> ViewerPerformanceWallEnvelopeIndex {
    ViewerPerformanceWallEnvelopeIndex(
      bucketCount: bounds.bucketCount,
      hasWallRegression: hasWallRegression,
      envelopes: envelopes
    )
  }
}

enum ViewerPerformanceUnplacedGapReason: UInt8, Equatable, Hashable, Sendable {
  case intervalLess
  case unknownKind
  case invalidInterval
  case wallRegression
  case ambiguousOrNonoverlapping
  case applicableOverflow
  case combinedApplicableOverflow
  case inconsistentReceipt
}

struct ViewerPerformanceGapProjection: Equatable, Sendable {
  private let wallIndex: ViewerPerformanceWallEnvelopeIndex
  private(set) var details = ViewerPerformanceBoundedDetails()
  private(set) var irrelevantCount: UInt64 = 0
  private(set) var observedApplicableOrUncertainCount: UInt64 = 0
  private(set) var applicableOrUncertainCount: UInt64 = 0
  private(set) var unplacedReasons: Set<ViewerPerformanceUnplacedGapReason> = []
  private var placedBuckets: [Bool]
  private var consumedLiveSlice = false

  init(wallIndex: ViewerPerformanceWallEnvelopeIndex) {
    self.wallIndex = wallIndex
    placedBuckets = Array(repeating: false, count: wallIndex.bucketCount)
  }

  mutating func consume(liveSlice: ViewerPerformanceLiveSlice) throws {
    guard !consumedLiveSlice else { throw ViewerPerformanceFailure.invalidCarrier }
    consumedLiveSlice = true
    applicableOrUncertainCount = liveSlice.applicableOrUncertainCount
    if liveSlice.hasMoreApplicableGaps {
      unplacedReasons.insert(.applicableOverflow)
    }
    for gap in liveSlice.gaps { consume(gap) }
    evaluateApplicableOverflow()
  }

  var hasUnplacedGap: Bool { !unplacedReasons.isEmpty }
  var suppressesEveryInterbucketConnection: Bool { hasUnplacedGap }
  var placedBucketIndices: [Int] {
    placedBuckets.indices.filter { placedBuckets[$0] }
  }

  mutating func applyDiscontinuities(to buckets: inout [ViewerPerformanceBucket]) throws {
    guard buckets.count == placedBuckets.count,
      buckets.enumerated().allSatisfy({ $0.offset == $0.element.index })
    else { throw ViewerPerformanceFailure.invalidScope }
    if suppressesEveryInterbucketConnection {
      for index in buckets.indices { buckets[index].markAllDiscontinuous() }
      return
    }
    for index in placedBuckets.indices where placedBuckets[index] {
      buckets[index].markAllDiscontinuous()
    }
  }

  private mutating func consume(_ gap: ViewerPerformanceGapCarrier) {
    details.append(gap: gap)
    if gap.applicability == .irrelevant {
      irrelevantCount = Self.saturatingAdd(irrelevantCount, gap.count)
      return
    }
    observedApplicableOrUncertainCount = Self.saturatingAdd(
      observedApplicableOrUncertainCount,
      gap.count
    )
    guard gap.kind != .unknown else {
      unplacedReasons.insert(.unknownKind)
      return
    }
    guard let lower = gap.firstViewerWallMilliseconds,
      let upper = gap.lastViewerWallMilliseconds
    else {
      unplacedReasons.insert(.intervalLess)
      return
    }
    guard lower <= upper else {
      unplacedReasons.insert(.invalidInterval)
      return
    }
    guard !wallIndex.hasWallRegression else {
      unplacedReasons.insert(.wallRegression)
      return
    }
    guard
      let bucket = wallIndex.uniquelyOverlappingBucket(
        lowerWallMilliseconds: lower,
        upperWallMilliseconds: upper
      )
    else {
      unplacedReasons.insert(.ambiguousOrNonoverlapping)
      return
    }
    placedBuckets[bucket] = true
  }

  private mutating func evaluateApplicableOverflow() {
    if max(observedApplicableOrUncertainCount, applicableOrUncertainCount)
      > UInt64(ViewerPerformanceAggregationLimits.maximumDetailedGaps)
    {
      unplacedReasons.insert(.combinedApplicableOverflow)
    }
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : value
  }
}

extension ViewerPerformanceCardState: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceCardState(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerPerformanceCardEvaluation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceCardEvaluation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceLatestEventSelector: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceLatestEventSelector(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceWallEnvelopeBuilder: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceWallEnvelopeBuilder(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceWallEnvelopeIndex: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceWallEnvelopeIndex(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceGapProjection: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceGapProjection(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "detailCount": details.gaps.count,
        "hasUnplacedGap": hasUnplacedGap,
      ],
      displayStyle: .struct
    )
  }
}
