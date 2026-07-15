import Foundation
@_spi(NearWireInternal) import NearWireCore

enum ViewerPerformanceAggregationLimits {
  static let maximumBuckets = 512
  static let maximumDetailedGaps = 128
  static let maximumInvalidDetails = 128
  static let maximumCharts = 6
  static let maximumMarksPerBucketPerChart = 4
  static let maximumTotalMarks = 12_288
  static let maximumAccessibleBucketsPerChart = 64
  static let maximumResultBytes = 8_388_608
  static let maximumLedgerBytes = 16_777_216
}

enum ViewerPerformanceAccounting {
  static let controllerSourceBytes = 4_096
  static let cacheKeyBytes = 256
  static let resultBaseBytes = 4_096
  static let bucketBytes = 2_048
  static let detailedGapBytes = 256
  static let invalidDetailBytes = 128
  static let availabilityEntryBytes = 64
  static let modelWrapperBytes = 1_024
  static let deliveryWrapperBytes = 256
  static let tooltipBytes = 2_048
  static let crosshairBytes = 64

  static let deterministicPeakBytes =
    ViewerPerformanceAggregationLimits.maximumLedgerBytes
    + ViewerPerformanceLimits.maximumLiveSliceBytes
    + ViewerPerformanceLimits.decoderBufferBytes

  static func resultBytes(
    bucketCount: Int,
    detailedGapCount: Int,
    invalidDetailCount: Int,
    availabilityCount: Int
  ) throws -> Int {
    guard (0...ViewerPerformanceAggregationLimits.maximumBuckets).contains(bucketCount),
      (0...ViewerPerformanceAggregationLimits.maximumDetailedGaps).contains(detailedGapCount),
      (0...ViewerPerformanceAggregationLimits.maximumInvalidDetails).contains(invalidDetailCount),
      availabilityCount == PerformanceMetricKey.allCases.count
    else { throw ViewerPerformanceFailure.limitExceeded }
    return try checkedSum([
      resultBaseBytes,
      cacheKeyBytes,
      try checkedMultiply(bucketCount, bucketBytes),
      try checkedMultiply(detailedGapCount, detailedGapBytes),
      try checkedMultiply(invalidDetailCount, invalidDetailBytes),
      try checkedMultiply(availabilityCount, availabilityEntryBytes),
    ])
  }

  static func activeReducerBytes(
    bucketCount: Int,
    detailedGapCount: Int,
    invalidDetailCount: Int
  ) throws -> Int {
    try resultBytes(
      bucketCount: bucketCount,
      detailedGapCount: detailedGapCount,
      invalidDetailCount: invalidDetailCount,
      availabilityCount: PerformanceMetricKey.allCases.count
    )
  }

  fileprivate static func checkedSum(_ values: [Int]) throws -> Int {
    var total = 0
    for value in values {
      guard value >= 0 else { throw ViewerPerformanceFailure.limitExceeded }
      let (next, overflow) = total.addingReportingOverflow(value)
      guard !overflow else { throw ViewerPerformanceFailure.limitExceeded }
      total = next
    }
    return total
  }

  fileprivate static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
    guard lhs >= 0, rhs >= 0 else { throw ViewerPerformanceFailure.limitExceeded }
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw ViewerPerformanceFailure.limitExceeded }
    return value
  }
}

enum ViewerPerformanceLedgerOwner: String, Equatable, Hashable, Sendable {
  case controllerSource
  case activeReducer
  case completedResult
  case presentedModel
  case pendingDelivery
  case tooltip
  case crosshair
  case diagnostics
  case identities
}

final class ViewerPerformanceMemoryLedger: @unchecked Sendable {
  struct Reservation: Equatable, Hashable, Sendable {
    fileprivate let id: UUID
    let owner: ViewerPerformanceLedgerOwner
    let bytes: Int
  }

  private let lock = NSLock()
  private var reservations: [UUID: Reservation] = [:]
  private var used = 0

  func reserve(
    owner: ViewerPerformanceLedgerOwner,
    bytes: Int
  ) throws -> Reservation? {
    guard bytes > 0, bytes <= ViewerPerformanceAggregationLimits.maximumLedgerBytes else {
      throw ViewerPerformanceFailure.limitExceeded
    }
    lock.lock()
    defer { lock.unlock() }
    guard bytes <= ViewerPerformanceAggregationLimits.maximumLedgerBytes - used else {
      return nil
    }
    let reservation = Reservation(id: UUID(), owner: owner, bytes: bytes)
    reservations[reservation.id] = reservation
    used += bytes
    return reservation
  }

  @discardableResult
  func release(_ reservation: Reservation) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard reservations.removeValue(forKey: reservation.id) == reservation else { return false }
    used -= reservation.bytes
    return true
  }

  func resize(
    _ reservation: Reservation,
    to bytes: Int
  ) throws -> Reservation? {
    guard bytes > 0, bytes <= ViewerPerformanceAggregationLimits.maximumLedgerBytes else {
      throw ViewerPerformanceFailure.limitExceeded
    }
    lock.lock()
    defer { lock.unlock() }
    guard reservations[reservation.id] == reservation else {
      throw ViewerPerformanceFailure.invalidCarrier
    }
    if bytes > reservation.bytes {
      let increase = bytes - reservation.bytes
      guard increase <= ViewerPerformanceAggregationLimits.maximumLedgerBytes - used else {
        return nil
      }
      used += increase
    } else {
      used -= reservation.bytes - bytes
    }
    let resized = Reservation(id: reservation.id, owner: reservation.owner, bytes: bytes)
    reservations[reservation.id] = resized
    return resized
  }

  func transfer(
    _ reservation: Reservation,
    to owner: ViewerPerformanceLedgerOwner
  ) throws -> Reservation {
    lock.lock()
    defer { lock.unlock() }
    guard reservations[reservation.id] == reservation else {
      throw ViewerPerformanceFailure.invalidCarrier
    }
    let transferred = Reservation(id: reservation.id, owner: owner, bytes: reservation.bytes)
    reservations[reservation.id] = transferred
    return transferred
  }

  func owns(_ reservation: Reservation) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return reservations[reservation.id] == reservation
  }

  var usedBytes: Int {
    lock.lock()
    defer { lock.unlock() }
    return used
  }

  var reservationCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reservations.count
  }
}

enum ViewerPerformanceNumericMetric: Int, CaseIterable, Equatable, Hashable, Sendable {
  case estimatedFramesPerSecond
  case maximumFramesPerSecond
  case cpuPercent
  case memoryFootprintBytes
  case batteryFraction
  case uplinkBytesPerSecond
  case downlinkBytesPerSecond
  case uplinkQueueDepth
  case downlinkQueueDepth
  case droppedEventCount

  var key: PerformanceMetricKey {
    switch self {
    case .estimatedFramesPerSecond: return .displayEstimatedFramesPerSecond
    case .maximumFramesPerSecond: return .displayMaximumFramesPerSecond
    case .cpuPercent: return .processCPUPercent
    case .memoryFootprintBytes: return .processMemoryFootprintBytes
    case .batteryFraction: return .deviceBatteryLevel
    case .uplinkBytesPerSecond: return .transportUplinkBytesPerSecond
    case .downlinkBytesPerSecond: return .transportDownlinkBytesPerSecond
    case .uplinkQueueDepth: return .transportUplinkQueueDepth
    case .downlinkQueueDepth: return .transportDownlinkQueueDepth
    case .droppedEventCount: return .transportDroppedEventCount
    }
  }
}

struct ViewerPerformanceMetricRepresentative: Equatable, Sendable {
  let sourceGeneration: UInt64
  let key: ViewerEventJournalKey
  let viewerMonotonicNanoseconds: Int64
  let distanceFromBucketCenter: Int64
}

enum ViewerPerformanceNonmeasurement: Equatable, Sendable {
  case invalid
  case unavailable(UnavailablePerformanceMetricReason)
  case notCollected
}

struct ViewerPerformanceNonmeasurementCounts: Equatable, Sendable {
  private(set) var invalid: UInt64 = 0
  private(set) var unsupported: UInt64 = 0
  private(set) var disabled: UInt64 = 0
  private(set) var permissionDenied: UInt64 = 0
  private(set) var temporarilyUnavailable: UInt64 = 0
  private(set) var notCollected: UInt64 = 0

  mutating func record(_ value: ViewerPerformanceNonmeasurement) {
    switch value {
    case .invalid:
      invalid = Self.increment(invalid)
    case .unavailable(.unsupported):
      unsupported = Self.increment(unsupported)
    case .unavailable(.disabled):
      disabled = Self.increment(disabled)
    case .unavailable(.permissionDenied):
      permissionDenied = Self.increment(permissionDenied)
    case .unavailable(.temporarilyUnavailable):
      temporarilyUnavailable = Self.increment(temporarilyUnavailable)
    case .notCollected:
      notCollected = Self.increment(notCollected)
    }
  }

  private static func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? value : value + 1
  }
}

struct ViewerPerformanceAvailabilityCounts: Equatable, Sendable {
  private(set) var measured: UInt64 = 0
  private(set) var invalid: UInt64 = 0
  private(set) var unsupported: UInt64 = 0
  private(set) var disabled: UInt64 = 0
  private(set) var permissionDenied: UInt64 = 0
  private(set) var temporarilyUnavailable: UInt64 = 0
  private(set) var notCollected: UInt64 = 0

  mutating func record(_ state: ViewerPerformanceMetricState) {
    switch state {
    case .numeric, .unsigned, .batteryState, .thermalState, .boolean:
      measured = Self.increment(measured)
    case .unavailable(.unsupported):
      unsupported = Self.increment(unsupported)
    case .unavailable(.disabled):
      disabled = Self.increment(disabled)
    case .unavailable(.permissionDenied):
      permissionDenied = Self.increment(permissionDenied)
    case .unavailable(.temporarilyUnavailable):
      temporarilyUnavailable = Self.increment(temporarilyUnavailable)
    case .notCollected:
      notCollected = Self.increment(notCollected)
    }
  }

  mutating func recordInvalid() { invalid = Self.increment(invalid) }

  mutating func merge(_ other: ViewerPerformanceAvailabilityCounts) {
    measured = Self.add(measured, other.measured)
    invalid = Self.add(invalid, other.invalid)
    unsupported = Self.add(unsupported, other.unsupported)
    disabled = Self.add(disabled, other.disabled)
    permissionDenied = Self.add(permissionDenied, other.permissionDenied)
    temporarilyUnavailable = Self.add(
      temporarilyUnavailable,
      other.temporarilyUnavailable
    )
    notCollected = Self.add(notCollected, other.notCollected)
  }

  var presentation: ViewerPerformanceAvailabilityPresentation {
    if measured > 0 { return .measured }
    if invalid > 0 { return .invalidSnapshot }
    if permissionDenied > 0 { return .unavailable(.permissionDenied) }
    if temporarilyUnavailable > 0 { return .unavailable(.temporarilyUnavailable) }
    if disabled > 0 { return .unavailable(.disabled) }
    if unsupported > 0 { return .unavailable(.unsupported) }
    return .notCollected
  }

  private static func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? value : value + 1
  }

  private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : value
  }
}

enum ViewerPerformanceAvailabilityPresentation: Equatable, Sendable {
  case measured
  case invalidSnapshot
  case unavailable(UnavailablePerformanceMetricReason)
  case notCollected
}

struct ViewerPerformanceAvailabilityAccumulatorSet: Equatable, Sendable {
  private var storage = Array(
    repeating: ViewerPerformanceAvailabilityCounts(),
    count: PerformanceMetricKey.allCases.count
  )

  func counts(for key: PerformanceMetricKey) -> ViewerPerformanceAvailabilityCounts {
    storage[Self.keyIndex(key)]
  }

  mutating func record(_ snapshot: ViewerDecodedPerformanceSnapshot) {
    for key in PerformanceMetricKey.allCases {
      storage[Self.keyIndex(key)].record(snapshot.state(for: key))
    }
  }

  mutating func recordInvalid() {
    for index in storage.indices { storage[index].recordInvalid() }
  }

  mutating func merge(_ other: ViewerPerformanceAvailabilityAccumulatorSet) {
    precondition(storage.count == other.storage.count)
    for index in storage.indices { storage[index].merge(other.storage[index]) }
  }

  var entries: [ViewerPerformanceAvailabilityEntry] {
    PerformanceMetricKey.allCases.map { key in
      ViewerPerformanceAvailabilityEntry(key: key, counts: counts(for: key))
    }
  }

  private static func keyIndex(_ key: PerformanceMetricKey) -> Int {
    guard let index = PerformanceMetricKey.allCases.firstIndex(of: key) else {
      preconditionFailure("Core performance metric inventory is incomplete")
    }
    return index
  }
}

struct ViewerPerformanceNumericAccumulator: Equatable, Sendable {
  private(set) var minimum: Double?
  private(set) var maximum: Double?
  private(set) var average: Double?
  private(set) var finiteSum: Double = 0
  private(set) var sumSaturated = false
  private(set) var measurementCount: UInt64 = 0
  private(set) var firstViewerMonotonicNanoseconds: Int64?
  private(set) var lastViewerMonotonicNanoseconds: Int64?
  private(set) var nonmeasurements = ViewerPerformanceNonmeasurementCounts()
  private(set) var representative: ViewerPerformanceMetricRepresentative?
  private(set) var isDiscontinuous = false

  mutating func recordMeasurement(
    _ value: Double,
    sourceGeneration: UInt64 = 1,
    viewerMonotonicNanoseconds: Int64,
    journalKey: ViewerEventJournalKey,
    bucketCenterMonotonicNanoseconds: Int64
  ) throws {
    guard sourceGeneration > 0, value.isFinite, value >= 0, viewerMonotonicNanoseconds >= 0,
      bucketCenterMonotonicNanoseconds >= 0
    else { throw ViewerPerformanceFailure.invalidCarrier }
    let priorCount = measurementCount
    measurementCount = Self.increment(measurementCount)
    minimum = min(minimum ?? value, value)
    maximum = max(maximum ?? value, value)
    if let currentAverage = average, priorCount < UInt64.max {
      let nextAverage =
        currentAverage
        + (value - currentAverage) / Double(priorCount + 1)
      guard nextAverage.isFinite else { throw ViewerPerformanceFailure.limitExceeded }
      average = nextAverage
    } else if average == nil {
      average = value
    }
    let candidateSum = finiteSum + value
    if candidateSum.isFinite {
      finiteSum = candidateSum
    } else {
      finiteSum = Double.greatestFiniteMagnitude
      sumSaturated = true
    }
    if firstViewerMonotonicNanoseconds == nil {
      firstViewerMonotonicNanoseconds = viewerMonotonicNanoseconds
    }
    lastViewerMonotonicNanoseconds = viewerMonotonicNanoseconds
    let distance =
      viewerMonotonicNanoseconds >= bucketCenterMonotonicNanoseconds
      ? viewerMonotonicNanoseconds - bucketCenterMonotonicNanoseconds
      : bucketCenterMonotonicNanoseconds - viewerMonotonicNanoseconds
    let candidate = ViewerPerformanceMetricRepresentative(
      sourceGeneration: sourceGeneration,
      key: journalKey,
      viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
      distanceFromBucketCenter: distance
    )
    if Self.representative(candidate, precedes: representative) {
      representative = candidate
    }
  }

  mutating func recordNonmeasurement(_ value: ViewerPerformanceNonmeasurement) {
    nonmeasurements.record(value)
  }

  mutating func markDiscontinuous() { isDiscontinuous = true }

  private static func representative(
    _ candidate: ViewerPerformanceMetricRepresentative,
    precedes current: ViewerPerformanceMetricRepresentative?
  ) -> Bool {
    guard let current else { return true }
    if candidate.distanceFromBucketCenter != current.distanceFromBucketCenter {
      return candidate.distanceFromBucketCenter < current.distanceFromBucketCenter
    }
    if candidate.viewerMonotonicNanoseconds != current.viewerMonotonicNanoseconds {
      return candidate.viewerMonotonicNanoseconds < current.viewerMonotonicNanoseconds
    }
    return ViewerPerformanceCanonicalOrder.keyPrecedes(candidate.key, current.key)
  }

  private static func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? value : value + 1
  }
}

struct ViewerPerformanceNumericAccumulatorSet: Equatable, Sendable {
  private var storage = Array(
    repeating: ViewerPerformanceNumericAccumulator(),
    count: ViewerPerformanceNumericMetric.allCases.count
  )

  func accumulator(
    for metric: ViewerPerformanceNumericMetric
  ) -> ViewerPerformanceNumericAccumulator {
    storage[metric.rawValue]
  }

  mutating func record(
    _ state: ViewerPerformanceMetricState,
    metric: ViewerPerformanceNumericMetric,
    sourceGeneration: UInt64 = 1,
    viewerMonotonicNanoseconds: Int64,
    journalKey: ViewerEventJournalKey,
    bucketCenterMonotonicNanoseconds: Int64
  ) throws {
    switch state {
    case .numeric(let value):
      try storage[metric.rawValue].recordMeasurement(
        value,
        sourceGeneration: sourceGeneration,
        viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
        journalKey: journalKey,
        bucketCenterMonotonicNanoseconds: bucketCenterMonotonicNanoseconds
      )
    case .unsigned(let value):
      try storage[metric.rawValue].recordMeasurement(
        Double(value),
        sourceGeneration: sourceGeneration,
        viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
        journalKey: journalKey,
        bucketCenterMonotonicNanoseconds: bucketCenterMonotonicNanoseconds
      )
    case .unavailable(let reason):
      storage[metric.rawValue].recordNonmeasurement(.unavailable(reason))
    case .notCollected:
      storage[metric.rawValue].recordNonmeasurement(.notCollected)
    case .batteryState, .thermalState, .boolean:
      storage[metric.rawValue].recordNonmeasurement(.invalid)
    }
  }

  mutating func markAllDiscontinuous() {
    for index in storage.indices { storage[index].markDiscontinuous() }
  }

  mutating func recordInvalidForAllMetrics() {
    for index in storage.indices {
      storage[index].recordNonmeasurement(.invalid)
      storage[index].markDiscontinuous()
    }
  }

  mutating func markDiscontinuous(_ metric: ViewerPerformanceNumericMetric) {
    storage[metric.rawValue].markDiscontinuous()
  }
}

struct ViewerPerformanceCategoricalSample<Value: Equatable & Sendable>: Equatable, Sendable {
  let value: Value
  let viewerMonotonicNanoseconds: Int64
  let key: ViewerEventJournalKey
}

struct ViewerPerformanceCategoricalAccumulator<Value: Equatable & Sendable>: Equatable,
  Sendable
{
  private(set) var first: ViewerPerformanceCategoricalSample<Value>?
  private(set) var latest: ViewerPerformanceCategoricalSample<Value>?
  private(set) var last: ViewerPerformanceCategoricalSample<Value>?
  private(set) var changeCount: UInt64 = 0

  mutating func record(
    _ value: Value,
    viewerMonotonicNanoseconds: Int64,
    key: ViewerEventJournalKey
  ) throws {
    guard viewerMonotonicNanoseconds >= 0 else {
      throw ViewerPerformanceFailure.invalidCarrier
    }
    let sample = ViewerPerformanceCategoricalSample(
      value: value,
      viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
      key: key
    )
    if first == nil { first = sample }
    if let latest, latest.value != value {
      changeCount = changeCount == UInt64.max ? changeCount : changeCount + 1
    }
    last = latest ?? sample
    latest = sample
  }
}

struct ViewerPerformanceBucket: Equatable, Sendable {
  let index: Int
  let lowerMonotonicNanoseconds: Int64
  let upperMonotonicNanoseconds: Int64
  private(set) var numeric = ViewerPerformanceNumericAccumulatorSet()
  private(set) var batteryState = ViewerPerformanceCategoricalAccumulator<BatteryState>()
  private(set) var thermalState = ViewerPerformanceCategoricalAccumulator<ThermalState>()
  private(set) var lowPowerMode = ViewerPerformanceCategoricalAccumulator<Bool>()
  private(set) var availability = ViewerPerformanceAvailabilityAccumulatorSet()

  init(index: Int, lowerMonotonicNanoseconds: Int64, upperMonotonicNanoseconds: Int64) throws {
    guard (0..<ViewerPerformanceAggregationLimits.maximumBuckets).contains(index),
      lowerMonotonicNanoseconds >= 0,
      upperMonotonicNanoseconds >= lowerMonotonicNanoseconds
    else { throw ViewerPerformanceFailure.invalidScope }
    self.index = index
    self.lowerMonotonicNanoseconds = lowerMonotonicNanoseconds
    self.upperMonotonicNanoseconds = upperMonotonicNanoseconds
  }

  var centerMonotonicNanoseconds: Int64 {
    lowerMonotonicNanoseconds + (upperMonotonicNanoseconds - lowerMonotonicNanoseconds) / 2
  }

  mutating func record(
    _ snapshot: ViewerDecodedPerformanceSnapshot,
    event: ViewerPerformanceEventCarrier,
    sourceGeneration: UInt64 = 1
  ) throws {
    guard event.viewerMonotonicNanoseconds >= lowerMonotonicNanoseconds,
      event.viewerMonotonicNanoseconds <= upperMonotonicNanoseconds
    else { throw ViewerPerformanceFailure.invalidCarrier }
    availability.record(snapshot)
    for metric in ViewerPerformanceNumericMetric.allCases {
      let state = snapshot.state(for: metric.key)
      try numeric.record(
        state,
        metric: metric,
        sourceGeneration: sourceGeneration,
        viewerMonotonicNanoseconds: event.viewerMonotonicNanoseconds,
        journalKey: event.key,
        bucketCenterMonotonicNanoseconds: centerMonotonicNanoseconds
      )
      if !state.isMeasurement { numeric.markDiscontinuous(metric) }
    }
    if case .batteryState(let value) = snapshot.state(for: .deviceBatteryState) {
      try batteryState.record(
        value,
        viewerMonotonicNanoseconds: event.viewerMonotonicNanoseconds,
        key: event.key
      )
    }
    if case .thermalState(let value) = snapshot.state(for: .deviceThermalState) {
      try thermalState.record(
        value,
        viewerMonotonicNanoseconds: event.viewerMonotonicNanoseconds,
        key: event.key
      )
    }
    if case .boolean(let value) = snapshot.state(for: .deviceLowPowerModeEnabled) {
      try lowPowerMode.record(
        value,
        viewerMonotonicNanoseconds: event.viewerMonotonicNanoseconds,
        key: event.key
      )
    }
  }

  mutating func recordInvalidSnapshot() {
    availability.recordInvalid()
    numeric.recordInvalidForAllMetrics()
  }

  mutating func markAllDiscontinuous() { numeric.markAllDiscontinuous() }
  mutating func markDiscontinuous(_ metric: ViewerPerformanceNumericMetric) {
    numeric.markDiscontinuous(metric)
  }
}

struct ViewerPerformanceInvalidDetail: Equatable, Sendable {
  let key: ViewerEventJournalKey
  let viewerMonotonicNanoseconds: Int64
  let reason: ViewerPerformanceInvalidSnapshotReason

  init(
    key: ViewerEventJournalKey,
    viewerMonotonicNanoseconds: Int64,
    reason: ViewerPerformanceInvalidSnapshotReason
  ) throws {
    guard viewerMonotonicNanoseconds >= 0 else {
      throw ViewerPerformanceFailure.invalidCarrier
    }
    self.key = key
    self.viewerMonotonicNanoseconds = viewerMonotonicNanoseconds
    self.reason = reason
  }
}

struct ViewerPerformanceBoundedDetails: Equatable, Sendable {
  private(set) var gaps: [ViewerPerformanceGapCarrier] = []
  private(set) var invalidSnapshots: [ViewerPerformanceInvalidDetail] = []
  private(set) var detailLossCount: UInt64 = 0

  mutating func append(gap: ViewerPerformanceGapCarrier) {
    if gaps.count < ViewerPerformanceAggregationLimits.maximumDetailedGaps {
      gaps.append(gap)
    } else {
      detailLossCount = Self.add(detailLossCount, gap.count)
    }
  }

  mutating func append(invalid: ViewerPerformanceInvalidDetail) {
    if invalidSnapshots.count < ViewerPerformanceAggregationLimits.maximumInvalidDetails {
      invalidSnapshots.append(invalid)
    } else {
      detailLossCount = Self.add(detailLossCount, 1)
    }
  }

  mutating func merge(_ other: ViewerPerformanceBoundedDetails) {
    for gap in other.gaps { append(gap: gap) }
    for invalid in other.invalidSnapshots { append(invalid: invalid) }
    detailLossCount = Self.add(detailLossCount, other.detailLossCount)
  }

  private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : value
  }
}

struct ViewerPerformanceAvailabilityEntry: Equatable, Sendable {
  let key: PerformanceMetricKey
  let counts: ViewerPerformanceAvailabilityCounts

  init(key: PerformanceMetricKey, counts: ViewerPerformanceAvailabilityCounts) {
    self.key = key
    self.counts = counts
  }

  init(key: PerformanceMetricKey, state: ViewerPerformanceMetricState) {
    self.key = key
    var counts = ViewerPerformanceAvailabilityCounts()
    counts.record(state)
    self.counts = counts
  }

  var presentation: ViewerPerformanceAvailabilityPresentation { counts.presentation }
}

struct ViewerPerformanceAggregationResult: Equatable, Sendable {
  let buckets: [ViewerPerformanceBucket]
  let gaps: [ViewerPerformanceGapCarrier]
  let invalidSnapshots: [ViewerPerformanceInvalidDetail]
  let detailLossCount: UInt64
  let availability: [ViewerPerformanceAvailabilityEntry]
  let accountedBytes: Int

  init(
    buckets: [ViewerPerformanceBucket],
    details: ViewerPerformanceBoundedDetails,
    availability: [ViewerPerformanceAvailabilityEntry]
  ) throws {
    guard buckets.count <= ViewerPerformanceAggregationLimits.maximumBuckets,
      buckets.enumerated().allSatisfy({ $0.offset == $0.element.index }),
      availability.map(\.key) == PerformanceMetricKey.allCases
    else { throw ViewerPerformanceFailure.limitExceeded }
    let accountedBytes = try ViewerPerformanceAccounting.resultBytes(
      bucketCount: buckets.count,
      detailedGapCount: details.gaps.count,
      invalidDetailCount: details.invalidSnapshots.count,
      availabilityCount: availability.count
    )
    guard accountedBytes <= ViewerPerformanceAggregationLimits.maximumResultBytes else {
      throw ViewerPerformanceFailure.limitExceeded
    }
    self.buckets = buckets
    gaps = details.gaps
    invalidSnapshots = details.invalidSnapshots
    detailLossCount = details.detailLossCount
    self.availability = availability
    self.accountedBytes = accountedBytes
  }

  func representativesBelong(to sourceGeneration: UInt64) -> Bool {
    sourceGeneration > 0
      && buckets.allSatisfy { bucket in
        ViewerPerformanceNumericMetric.allCases.allSatisfy { metric in
          guard let representative = bucket.numeric.accumulator(for: metric).representative else {
            return true
          }
          return representative.sourceGeneration == sourceGeneration
        }
      }
  }
}

enum ViewerPerformancePresentationBounds {
  static func maximumMarkCount(bucketCount: Int) throws -> Int {
    guard (0...ViewerPerformanceAggregationLimits.maximumBuckets).contains(bucketCount) else {
      throw ViewerPerformanceFailure.limitExceeded
    }
    let count = try ViewerPerformanceAccounting.checkedMultiply(
      bucketCount,
      ViewerPerformanceAggregationLimits.maximumCharts
        * ViewerPerformanceAggregationLimits.maximumMarksPerBucketPerChart
    )
    guard count <= ViewerPerformanceAggregationLimits.maximumTotalMarks else {
      throw ViewerPerformanceFailure.limitExceeded
    }
    return count
  }

  static func accessibilityBucketIndices(bucketCount: Int) throws -> [Int] {
    guard (0...ViewerPerformanceAggregationLimits.maximumBuckets).contains(bucketCount) else {
      throw ViewerPerformanceFailure.limitExceeded
    }
    guard bucketCount > ViewerPerformanceAggregationLimits.maximumAccessibleBucketsPerChart else {
      return Array(0..<bucketCount)
    }
    let finalIndex = bucketCount - 1
    let divisor = ViewerPerformanceAggregationLimits.maximumAccessibleBucketsPerChart - 1
    return (0..<ViewerPerformanceAggregationLimits.maximumAccessibleBucketsPerChart).map {
      $0 * finalIndex / divisor
    }
  }
}

enum ViewerPerformanceRangeKind: UInt8, CaseIterable, Equatable, Hashable, Sendable {
  case oneMinute = 0
  case fiveMinutes = 1
  case fifteenMinutes = 2
  case currentSession = 3

  static let defaultKind = ViewerPerformanceRangeKind.fiveMinutes

  var fixedDurationNanoseconds: UInt64? {
    switch self {
    case .oneMinute: return 60_000_000_000
    case .fiveMinutes: return 300_000_000_000
    case .fifteenMinutes: return 900_000_000_000
    case .currentSession: return nil
    }
  }

  func bounds(
    deviceStartMonotonicNanoseconds: Int64,
    upperMonotonicNanoseconds: Int64
  ) throws -> ViewerPerformanceRangeBounds {
    if let duration = fixedDurationNanoseconds {
      return try .fixed(
        deviceStartMonotonicNanoseconds: deviceStartMonotonicNanoseconds,
        upperMonotonicNanoseconds: upperMonotonicNanoseconds,
        durationNanoseconds: duration
      )
    }
    return try .currentSession(
      deviceStartMonotonicNanoseconds: deviceStartMonotonicNanoseconds,
      upperMonotonicNanoseconds: upperMonotonicNanoseconds
    )
  }
}

struct ViewerPerformanceRangeBounds: Equatable, Hashable, Sendable {
  let lowerMonotonicNanoseconds: Int64
  let upperMonotonicNanoseconds: Int64
  let inclusiveSpanNanoseconds: UInt64
  let bucketWidthNanoseconds: UInt64
  let bucketCount: Int

  static func fixed(
    deviceStartMonotonicNanoseconds: Int64,
    upperMonotonicNanoseconds: Int64,
    durationNanoseconds: UInt64
  ) throws -> ViewerPerformanceRangeBounds {
    guard deviceStartMonotonicNanoseconds >= 0,
      upperMonotonicNanoseconds >= deviceStartMonotonicNanoseconds
    else { throw ViewerPerformanceFailure.invalidScope }
    let effectiveDuration = max(durationNanoseconds, 1)
    let distance = effectiveDuration - 1
    let upper = UInt64(upperMonotonicNanoseconds)
    let saturatedLower = upper >= distance ? upper - distance : 0
    let lower = max(UInt64(deviceStartMonotonicNanoseconds), saturatedLower)
    guard let exactLower = Int64(exactly: lower) else {
      throw ViewerPerformanceFailure.limitExceeded
    }
    return try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: exactLower,
      upperMonotonicNanoseconds: upperMonotonicNanoseconds
    )
  }

  static func currentSession(
    deviceStartMonotonicNanoseconds: Int64,
    upperMonotonicNanoseconds: Int64
  ) throws -> ViewerPerformanceRangeBounds {
    try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: deviceStartMonotonicNanoseconds,
      upperMonotonicNanoseconds: upperMonotonicNanoseconds
    )
  }

  init(
    lowerMonotonicNanoseconds: Int64,
    upperMonotonicNanoseconds: Int64
  ) throws {
    guard lowerMonotonicNanoseconds >= 0,
      upperMonotonicNanoseconds >= lowerMonotonicNanoseconds
    else { throw ViewerPerformanceFailure.invalidScope }
    let lower = UInt64(lowerMonotonicNanoseconds)
    let upper = UInt64(upperMonotonicNanoseconds)
    let inclusiveSpanNanoseconds = upper - lower + 1
    let bucketLimit = UInt64(ViewerPerformanceAggregationLimits.maximumBuckets)
    let bucketWidthNanoseconds = Self.ceilingDivision(
      inclusiveSpanNanoseconds,
      by: bucketLimit
    )
    let count = Self.ceilingDivision(inclusiveSpanNanoseconds, by: bucketWidthNanoseconds)
    guard let bucketCount = Int(exactly: count),
      (1...ViewerPerformanceAggregationLimits.maximumBuckets).contains(bucketCount)
    else { throw ViewerPerformanceFailure.limitExceeded }
    self.lowerMonotonicNanoseconds = lowerMonotonicNanoseconds
    self.upperMonotonicNanoseconds = upperMonotonicNanoseconds
    self.inclusiveSpanNanoseconds = inclusiveSpanNanoseconds
    self.bucketWidthNanoseconds = bucketWidthNanoseconds
    self.bucketCount = bucketCount
  }

  func bucketIndex(containing monotonicNanoseconds: Int64) -> Int? {
    guard monotonicNanoseconds >= lowerMonotonicNanoseconds,
      monotonicNanoseconds <= upperMonotonicNanoseconds
    else { return nil }
    let offset = UInt64(monotonicNanoseconds) - UInt64(lowerMonotonicNanoseconds)
    return Int(offset / bucketWidthNanoseconds)
  }

  func bucketBounds(at index: Int) throws -> ClosedRange<Int64> {
    guard (0..<bucketCount).contains(index) else {
      throw ViewerPerformanceFailure.invalidScope
    }
    let (bucketOffset, multiplicationOverflow) = UInt64(index).multipliedReportingOverflow(
      by: bucketWidthNanoseconds
    )
    let (bucketLower, additionOverflow) = UInt64(lowerMonotonicNanoseconds)
      .addingReportingOverflow(bucketOffset)
    guard !multiplicationOverflow, !additionOverflow,
      bucketLower <= UInt64(upperMonotonicNanoseconds)
    else { throw ViewerPerformanceFailure.limitExceeded }
    let (unclampedUpper, upperOverflow) = bucketLower.addingReportingOverflow(
      bucketWidthNanoseconds - 1
    )
    let bucketUpper =
      upperOverflow
      ? UInt64(upperMonotonicNanoseconds)
      : min(unclampedUpper, UInt64(upperMonotonicNanoseconds))
    guard let lower = Int64(exactly: bucketLower), let upper = Int64(exactly: bucketUpper)
    else { throw ViewerPerformanceFailure.limitExceeded }
    return lower...upper
  }

  func makeBuckets() throws -> [ViewerPerformanceBucket] {
    try (0..<bucketCount).map { index in
      let bounds = try bucketBounds(at: index)
      return try ViewerPerformanceBucket(
        index: index,
        lowerMonotonicNanoseconds: bounds.lowerBound,
        upperMonotonicNanoseconds: bounds.upperBound
      )
    }
  }

  private static func ceilingDivision(_ numerator: UInt64, by denominator: UInt64) -> UInt64 {
    precondition(numerator > 0 && denominator > 0)
    let quotient = numerator / denominator
    return numerator % denominator == 0 ? quotient : quotient + 1
  }
}

enum ViewerPerformanceAnchorKind: Equatable, Sendable {
  case current
}

struct ViewerPerformanceAnchor: Equatable, Sendable {
  let kind: ViewerPerformanceAnchorKind
  let deviceStartMonotonicNanoseconds: Int64
  let upperMonotonicNanoseconds: Int64

  static func current(
    source: ViewerPerformanceSource,
    liveSlice: ViewerPerformanceLiveSlice,
    deviceStartMonotonicNanoseconds: Int64
  ) throws -> ViewerPerformanceAnchor {
    guard case .current(let runtimeLogicalID, let connectionID) = source,
      liveSlice.runtimeLogicalID == runtimeLogicalID,
      liveSlice.connectionID == connectionID,
      let upper = Int64(exactly: liveSlice.anchorMonotonicNanoseconds)
    else { throw ViewerPerformanceFailure.invalidScope }
    return try ViewerPerformanceAnchor(
      kind: .current,
      deviceStartMonotonicNanoseconds: deviceStartMonotonicNanoseconds,
      upperMonotonicNanoseconds: upper
    )
  }

  private init(
    kind: ViewerPerformanceAnchorKind,
    deviceStartMonotonicNanoseconds: Int64,
    upperMonotonicNanoseconds: Int64
  ) throws {
    guard deviceStartMonotonicNanoseconds >= 0,
      upperMonotonicNanoseconds >= deviceStartMonotonicNanoseconds
    else { throw ViewerPerformanceFailure.invalidScope }
    self.kind = kind
    self.deviceStartMonotonicNanoseconds = deviceStartMonotonicNanoseconds
    self.upperMonotonicNanoseconds = upperMonotonicNanoseconds
  }
}

struct ViewerPerformanceCacheKey: Equatable, Hashable, Sendable {
  let source: ViewerPerformanceSource
  let rangeKind: ViewerPerformanceRangeKind
  let lowerMonotonicNanoseconds: Int64
  let upperMonotonicNanoseconds: Int64
  let liveGeneration: UInt64
  let liveSliceRevision: UInt64

  var runtimeLogicalID: UUID {
    switch source {
    case .current(let runtimeLogicalID, _): return runtimeLogicalID
    }
  }

  init(
    source: ViewerPerformanceSource,
    rangeKind: ViewerPerformanceRangeKind,
    bounds: ViewerPerformanceRangeBounds,
    liveGeneration: UInt64,
    liveSliceRevision: UInt64
  ) throws {
    switch source {
    case .current:
      guard liveGeneration > 0, liveSliceRevision > 0
      else { throw ViewerPerformanceFailure.invalidScope }
    }
    self.source = source
    self.rangeKind = rangeKind
    lowerMonotonicNanoseconds = bounds.lowerMonotonicNanoseconds
    upperMonotonicNanoseconds = bounds.upperMonotonicNanoseconds
    self.liveGeneration = liveGeneration
    self.liveSliceRevision = liveSliceRevision
  }

  init(
    receipt: ViewerPerformanceFrozenReceipt,
    rangeKind: ViewerPerformanceRangeKind,
    bounds: ViewerPerformanceRangeBounds
  ) throws {
    switch receipt.source {
    case .current(let runtimeLogicalID, let connectionID):
      guard receipt.liveSlice.runtimeLogicalID == runtimeLogicalID,
        receipt.liveSlice.connectionID == connectionID,
        Int64(exactly: receipt.liveSlice.anchorMonotonicNanoseconds)
          == bounds.upperMonotonicNanoseconds
      else { throw ViewerPerformanceFailure.invalidScope }
    }
    try self.init(
      source: receipt.source,
      rangeKind: rangeKind,
      bounds: bounds,
      liveGeneration: receipt.liveSlice.liveGeneration,
      liveSliceRevision: receipt.liveSlice.revision
    )
  }
}

enum ViewerPerformanceCacheCanonicalOrder {
  static func keyPrecedes(_ lhs: ViewerPerformanceCacheKey, _ rhs: ViewerPerformanceCacheKey)
    -> Bool
  {
    let sourceComparison = compareSourceIdentity(lhs.source, rhs.source)
    if sourceComparison != 0 { return sourceComparison < 0 }
    let deviceComparison = compareDeviceIdentity(lhs.source, rhs.source)
    if deviceComparison != 0 { return deviceComparison < 0 }
    let rangeComparison = compare(lhs.rangeKind.rawValue, rhs.rangeKind.rawValue)
    if rangeComparison != 0 { return rangeComparison < 0 }
    let lowerComparison = compare(
      UInt64(lhs.lowerMonotonicNanoseconds),
      UInt64(rhs.lowerMonotonicNanoseconds)
    )
    if lowerComparison != 0 { return lowerComparison < 0 }
    let upperComparison = compare(
      UInt64(lhs.upperMonotonicNanoseconds),
      UInt64(rhs.upperMonotonicNanoseconds)
    )
    if upperComparison != 0 { return upperComparison < 0 }
    let runtimeComparison = ViewerPerformanceCanonicalOrder.compareUUID(
      lhs.runtimeLogicalID,
      rhs.runtimeLogicalID
    )
    if runtimeComparison != 0 { return runtimeComparison < 0 }
    let liveComparison = compare(lhs.liveGeneration, rhs.liveGeneration)
    if liveComparison != 0 { return liveComparison < 0 }
    return lhs.liveSliceRevision < rhs.liveSliceRevision
  }

  private static func compareSourceIdentity(
    _ lhs: ViewerPerformanceSource,
    _ rhs: ViewerPerformanceSource
  ) -> Int {
    switch (lhs, rhs) {
    case (.current(let left, _), .current(let right, _)):
      return ViewerPerformanceCanonicalOrder.compareUUID(left, right)
    }
  }

  private static func compareDeviceIdentity(
    _ lhs: ViewerPerformanceSource,
    _ rhs: ViewerPerformanceSource
  ) -> Int {
    switch (lhs, rhs) {
    case (.current(_, let left), .current(_, let right)):
      return ViewerPerformanceCanonicalOrder.compareUUID(left, right)
    }
  }

  private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> Int {
    lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
  }
}

struct ViewerPerformanceResultCache: Sendable {
  static let maximumEntryCount = 4

  private struct Entry: Sendable {
    let result: ViewerPerformanceAggregationResult
    let reservation: ViewerPerformanceMemoryLedger.Reservation
    var touchOrdinal: UInt64
  }

  private(set) var activeSource: ViewerPerformanceSource?
  private var entries: [ViewerPerformanceCacheKey: Entry] = [:]
  private var latestTouchOrdinal: UInt64 = 0

  var count: Int { entries.count }
  var accountedBytes: Int { entries.values.reduce(0) { $0 + $1.reservation.bytes } }

  func contains(_ key: ViewerPerformanceCacheKey) -> Bool { entries[key] != nil }

  func touchOrdinal(for key: ViewerPerformanceCacheKey) -> UInt64? {
    entries[key]?.touchOrdinal
  }

  mutating func activate(
    source: ViewerPerformanceSource,
    ledger: ViewerPerformanceMemoryLedger
  ) {
    guard activeSource != source else { return }
    releaseAllEntries(ledger: ledger)
    activeSource = source
  }

  mutating func result(
    for key: ViewerPerformanceCacheKey
  ) throws -> ViewerPerformanceAggregationResult? {
    guard key.source == activeSource else { throw ViewerPerformanceFailure.invalidScope }
    guard var entry = entries[key] else { return nil }
    entry.touchOrdinal = nextTouchOrdinal()
    entries[key] = entry
    return entry.result
  }

  @discardableResult
  mutating func insert(
    _ result: ViewerPerformanceAggregationResult,
    for key: ViewerPerformanceCacheKey,
    ledger: ViewerPerformanceMemoryLedger
  ) throws -> Bool {
    guard key.source == activeSource,
      result.accountedBytes <= ViewerPerformanceAggregationLimits.maximumResultBytes
    else { throw ViewerPerformanceFailure.invalidScope }
    if entries[key] != nil {
      _ = try self.result(for: key)
      return true
    }
    if entries.count == Self.maximumEntryCount, let keyToEvict = evictionKey() {
      release(key: keyToEvict, ledger: ledger)
    }
    guard
      let reservation = try ledger.reserve(
        owner: .completedResult,
        bytes: result.accountedBytes
      )
    else { return false }
    let touchOrdinal = nextTouchOrdinal()
    entries[key] = Entry(
      result: result,
      reservation: reservation,
      touchOrdinal: touchOrdinal
    )
    return true
  }

  @discardableResult
  mutating func insertOwned(
    _ result: ViewerPerformanceAggregationResult,
    reservation: ViewerPerformanceMemoryLedger.Reservation,
    for key: ViewerPerformanceCacheKey,
    ledger: ViewerPerformanceMemoryLedger
  ) throws -> Bool {
    guard key.source == activeSource,
      result.accountedBytes <= ViewerPerformanceAggregationLimits.maximumResultBytes,
      reservation.owner == .completedResult,
      reservation.bytes == result.accountedBytes,
      ledger.owns(reservation)
    else { throw ViewerPerformanceFailure.invalidScope }
    if entries[key] != nil {
      _ = ledger.release(reservation)
      _ = try self.result(for: key)
      return true
    }
    if entries.count == Self.maximumEntryCount, let keyToEvict = evictionKey() {
      release(key: keyToEvict, ledger: ledger)
    }
    let touchOrdinal = nextTouchOrdinal()
    entries[key] = Entry(
      result: result,
      reservation: reservation,
      touchOrdinal: touchOrdinal
    )
    return true
  }

  @discardableResult
  mutating func replaceOwned(
    _ result: ViewerPerformanceAggregationResult,
    reservation: ViewerPerformanceMemoryLedger.Reservation,
    for key: ViewerPerformanceCacheKey,
    ledger: ViewerPerformanceMemoryLedger
  ) throws -> Bool {
    guard key.source == activeSource,
      result.accountedBytes <= ViewerPerformanceAggregationLimits.maximumResultBytes,
      reservation.owner == .completedResult,
      reservation.bytes == result.accountedBytes,
      ledger.owns(reservation),
      let predecessor = entries[key]
    else { throw ViewerPerformanceFailure.invalidScope }
    let touchOrdinal = nextTouchOrdinal()
    entries[key] = Entry(
      result: result,
      reservation: reservation,
      touchOrdinal: touchOrdinal
    )
    _ = ledger.release(predecessor.reservation)
    return true
  }

  mutating func clear(ledger: ViewerPerformanceMemoryLedger) {
    releaseAllEntries(ledger: ledger)
    activeSource = nil
  }

  mutating func clearResults(ledger: ViewerPerformanceMemoryLedger) {
    releaseAllEntries(ledger: ledger)
  }

  @discardableResult
  mutating func remove(
    _ key: ViewerPerformanceCacheKey,
    ledger: ViewerPerformanceMemoryLedger
  ) -> Bool {
    guard entries[key] != nil else { return false }
    release(key: key, ledger: ledger)
    return true
  }

  private mutating func releaseAllEntries(ledger: ViewerPerformanceMemoryLedger) {
    for entry in entries.values { _ = ledger.release(entry.reservation) }
    entries.removeAll(keepingCapacity: false)
    latestTouchOrdinal = 0
  }

  private mutating func release(
    key: ViewerPerformanceCacheKey,
    ledger: ViewerPerformanceMemoryLedger
  ) {
    guard let entry = entries.removeValue(forKey: key) else { return }
    _ = ledger.release(entry.reservation)
  }

  private func evictionKey() -> ViewerPerformanceCacheKey? {
    entries.min { lhs, rhs in
      if lhs.value.touchOrdinal != rhs.value.touchOrdinal {
        return lhs.value.touchOrdinal < rhs.value.touchOrdinal
      }
      return ViewerPerformanceCacheCanonicalOrder.keyPrecedes(lhs.key, rhs.key)
    }?.key
  }

  private mutating func nextTouchOrdinal() -> UInt64 {
    if latestTouchOrdinal == UInt64.max { normalizeTouchOrdinals() }
    latestTouchOrdinal += 1
    return latestTouchOrdinal
  }

  private mutating func normalizeTouchOrdinals() {
    let orderedKeys = entries.sorted { lhs, rhs in
      if lhs.value.touchOrdinal != rhs.value.touchOrdinal {
        return lhs.value.touchOrdinal < rhs.value.touchOrdinal
      }
      return ViewerPerformanceCacheCanonicalOrder.keyPrecedes(lhs.key, rhs.key)
    }.map(\.key)
    for (offset, key) in orderedKeys.enumerated() {
      entries[key]?.touchOrdinal = UInt64(offset + 1)
    }
    latestTouchOrdinal = UInt64(orderedKeys.count)
  }
}

extension ViewerPerformanceCacheKey: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceCacheKey(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceResultCache: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceResultCache(redacted, count: \(count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["count": count], displayStyle: .struct)
  }
}

extension ViewerPerformanceAggregationResult: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerPerformanceAggregationResult(redacted, buckets: \(buckets.count))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["bucketCount": buckets.count], displayStyle: .struct)
  }
}

extension ViewerPerformanceMemoryLedger: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceMemoryLedger(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
