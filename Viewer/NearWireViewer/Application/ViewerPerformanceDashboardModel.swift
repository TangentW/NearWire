import Combine
import Foundation

struct ViewerPerformanceDashboardScope: Equatable, Hashable, Sendable {
  let sourceGeneration: UInt64
  let source: ViewerPerformanceSource
  let rangeKind: ViewerPerformanceRangeKind

  init(
    sourceGeneration: UInt64,
    source: ViewerPerformanceSource,
    rangeKind: ViewerPerformanceRangeKind
  ) throws {
    guard sourceGeneration > 0 else { throw ViewerPerformanceFailure.invalidScope }
    self.sourceGeneration = sourceGeneration
    self.source = source
    self.rangeKind = rangeKind
  }
}

enum ViewerPerformanceProjectionStage: UInt8, Equatable, Sendable {
  case freezing
  case events
  case gaps
  case delivering
}

struct ViewerPerformanceProjectionProgress: Equatable, Sendable {
  let stage: ViewerPerformanceProjectionStage
  let eventPageCount: UInt64
  let gapPageCount: UInt64
  let decodedEventCount: UInt64
  let decodeTurnCount: UInt64

  static let initial = ViewerPerformanceProjectionProgress(
    stage: .freezing,
    eventPageCount: 0,
    gapPageCount: 0,
    decodedEventCount: 0,
    decodeTurnCount: 0
  )
}

enum ViewerPerformanceDashboardPhase: Equatable, Sendable {
  case idle
  case loading(retainsPresentation: Bool)
  case ready(ViewerPerformanceProjectionCoverage)
  case empty(ViewerPerformanceProjectionCoverage)
  case failed(ViewerPerformanceFailure)
}

enum ViewerPerformanceChartGroupKind: UInt8, CaseIterable, Equatable, Hashable, Sendable {
  case display
  case cpu
  case memory
  case battery
  case throughput
  case queueAndDrops
}

struct ViewerPerformanceChartGroup: Identifiable, Equatable, Sendable {
  let id: ViewerPerformanceChartGroupKind
  let metrics: [ViewerPerformanceNumericMetric]

  static let all: [ViewerPerformanceChartGroup] = [
    ViewerPerformanceChartGroup(
      id: .display,
      metrics: [.estimatedFramesPerSecond, .maximumFramesPerSecond]
    ),
    ViewerPerformanceChartGroup(id: .cpu, metrics: [.cpuPercent]),
    ViewerPerformanceChartGroup(id: .memory, metrics: [.memoryFootprintBytes]),
    ViewerPerformanceChartGroup(id: .battery, metrics: [.batteryFraction]),
    ViewerPerformanceChartGroup(
      id: .throughput,
      metrics: [.uplinkBytesPerSecond, .downlinkBytesPerSecond]
    ),
    ViewerPerformanceChartGroup(
      id: .queueAndDrops,
      metrics: [.uplinkQueueDepth, .downlinkQueueDepth, .droppedEventCount]
    ),
  ]
}

struct ViewerPerformanceCrosshair: Equatable, Sendable {
  let viewerMonotonicNanoseconds: Int64
  let bucketIndex: Int
  let chartGroup: ViewerPerformanceChartGroupKind
  let selectedMetric: ViewerPerformanceNumericMetric?
}

enum ViewerPerformanceDashboardPhaseKind: UInt8, Equatable, Sendable {
  case idle
  case loading
  case ready
  case empty
  case failed
}

struct ViewerPerformanceDashboardDiagnostics: Equatable, Sendable {
  let revision: UInt64
  let phase: ViewerPerformanceDashboardPhaseKind
  let bucketCount: Int
  let gapCount: Int
  let invalidSnapshotCount: Int
  let hasCrosshair: Bool
  let hasCurrentDeadline: Bool
}

@MainActor
final class ViewerPerformanceDashboardModel: ObservableObject, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  static let chartGroups = ViewerPerformanceChartGroup.all

  @Published private(set) var revision: UInt64 = 0
  private(set) var scope: ViewerPerformanceDashboardScope?
  private(set) var phase: ViewerPerformanceDashboardPhase = .idle
  private(set) var progress: ViewerPerformanceProjectionProgress?
  private(set) var currentFreshnessReceipt: ViewerPerformanceCurrentFreshnessReceipt?
  private(set) var crosshair: ViewerPerformanceCrosshair?
  private(set) var sealed = false

  private var publication: ViewerPerformanceProjectionPublication?

  var rangeKind: ViewerPerformanceRangeKind? { scope?.rangeKind }
  var coverage: ViewerPerformanceProjectionCoverage? { publication?.coverage }
  var cards: ViewerPerformanceCardEvaluation? { publication?.cards }
  var buckets: [ViewerPerformanceBucket] { publication?.result.buckets ?? [] }
  var chartProjections: [ViewerPerformanceChartProjection] {
    publication?.chartProjections ?? []
  }
  var gaps: [ViewerPerformanceGapCarrier] { publication?.result.gaps ?? [] }
  var invalidSnapshots: [ViewerPerformanceInvalidDetail] {
    publication?.result.invalidSnapshots ?? []
  }
  var availability: [ViewerPerformanceAvailabilityEntry] {
    publication?.result.availability ?? []
  }
  var selectedBucket: ViewerPerformanceBucket? {
    guard let crosshair, let publication,
      publication.result.buckets.indices.contains(crosshair.bucketIndex)
    else { return nil }
    return publication.result.buckets[crosshair.bucketIndex]
  }

  var diagnostics: ViewerPerformanceDashboardDiagnostics {
    ViewerPerformanceDashboardDiagnostics(
      revision: revision,
      phase: phaseKind,
      bucketCount: publication?.result.buckets.count ?? 0,
      gapCount: publication?.result.gaps.count ?? 0,
      invalidSnapshotCount: publication?.result.invalidSnapshots.count ?? 0,
      hasCrosshair: crosshair != nil,
      hasCurrentDeadline: currentFreshnessReceipt?.absoluteDeadlineMonotonicNanoseconds != nil
        && publication?.cards.shouldArmDeadline == true
    )
  }

  func replaceScope(_ nextScope: ViewerPerformanceDashboardScope?) {
    guard !sealed, scope != nextScope else { return }
    scope = nextScope
    clearPresentation()
    phase = .idle
    publish()
  }

  @discardableResult
  func beginLoading(
    for expectedScope: ViewerPerformanceDashboardScope,
    progress nextProgress: ViewerPerformanceProjectionProgress = .initial
  ) -> Bool {
    guard !sealed, scope == expectedScope else { return false }
    let retainsPresentation = publication != nil
    progress = nextProgress
    phase = .loading(retainsPresentation: retainsPresentation)
    if !retainsPresentation { publish() }
    return true
  }

  @discardableResult
  func restartLoadingWithoutPresentation(
    for expectedScope: ViewerPerformanceDashboardScope
  ) -> Bool {
    guard !sealed, scope == expectedScope else { return false }
    clearPresentation()
    progress = .initial
    phase = .loading(retainsPresentation: false)
    publish()
    return true
  }

  @discardableResult
  func updateProgress(
    _ nextProgress: ViewerPerformanceProjectionProgress,
    for expectedScope: ViewerPerformanceDashboardScope
  ) -> Bool {
    guard !sealed, scope == expectedScope, case .loading = phase else { return false }
    progress = nextProgress
    if publication == nil { publish() }
    return true
  }

  @discardableResult
  func apply(
    _ nextPublication: ViewerPerformanceProjectionPublication,
    for expectedScope: ViewerPerformanceDashboardScope
  ) -> Bool {
    guard !sealed, scope == expectedScope,
      Self.isValid(nextPublication, for: expectedScope)
    else { return false }
    let priorPublication = publication
    let priorCrosshair = crosshair
    publication = nextPublication
    progress = nil
    crosshair = Self.revalidatedCrosshair(priorCrosshair, in: nextPublication)
    switch nextPublication.freshnessReceipt {
    case .current(let receipt):
      currentFreshnessReceipt = receipt
    }
    phase =
      nextPublication.decodedEventCount == 0
      ? .empty(nextPublication.coverage) : .ready(nextPublication.coverage)
    if priorPublication != nextPublication || priorCrosshair != crosshair {
      publish()
    }
    return true
  }

  @discardableResult
  func expireCurrentCards(
    matching receipt: ViewerPerformanceCurrentFreshnessReceipt
  ) -> Bool {
    guard !sealed, currentFreshnessReceipt == receipt, var publication,
      case .current(let publicationReceipt) = publication.freshnessReceipt,
      publicationReceipt == receipt, publication.cards.isFresh,
      let restated = try? publication.cards.restatingNoRecentSample()
    else { return false }
    publication = ViewerPerformanceProjectionPublication(
      cacheKey: publication.cacheKey,
      result: publication.result,
      cards: restated,
      chartProjections: publication.chartProjections,
      coverage: publication.coverage,
      freshnessReceipt: publication.freshnessReceipt,
      decodedEventCount: publication.decodedEventCount,
      decodeTurnCount: publication.decodeTurnCount
    )
    self.publication = publication
    publish()
    return true
  }

  @discardableResult
  func showFailure(
    _ failure: ViewerPerformanceFailure,
    for expectedScope: ViewerPerformanceDashboardScope
  ) -> Bool {
    guard !sealed, scope == expectedScope else { return false }
    clearPresentation()
    phase = .failed(failure)
    publish()
    return true
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
    chartGroup requestedGroup: ViewerPerformanceChartGroupKind?,
    selectedMetric requestedMetric: ViewerPerformanceNumericMetric?
  ) -> Bool {
    guard !sealed, let publication,
      viewerMonotonicNanoseconds >= publication.cacheKey.lowerMonotonicNanoseconds,
      viewerMonotonicNanoseconds <= publication.cacheKey.upperMonotonicNanoseconds,
      let bucket = publication.result.buckets.first(where: {
        viewerMonotonicNanoseconds >= $0.lowerMonotonicNanoseconds
          && viewerMonotonicNanoseconds <= $0.upperMonotonicNanoseconds
      })
    else { return false }
    let inferredMetric = ViewerPerformanceNumericMetric.allCases.first {
      bucket.numeric.accumulator(for: $0).measurementCount > 0
    }
    let group =
      requestedGroup
      ?? inferredMetric.flatMap(Self.group(containing:))
      ?? .display
    guard let groupDescriptor = ViewerPerformanceChartGroup.all.first(where: { $0.id == group })
    else { return false }
    if let requestedMetric, !groupDescriptor.metrics.contains(requestedMetric) { return false }
    let selectedMetric =
      requestedMetric
      ?? groupDescriptor.metrics.first {
        bucket.numeric.accumulator(for: $0).measurementCount > 0
      }
    let next = ViewerPerformanceCrosshair(
      viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
      bucketIndex: bucket.index,
      chartGroup: group,
      selectedMetric: selectedMetric
    )
    guard crosshair != next else { return true }
    crosshair = next
    publish()
    return true
  }

  func clearCrosshair() {
    guard crosshair != nil else { return }
    crosshair = nil
    publish()
  }

  func clear() {
    guard !sealed else { return }
    scope = nil
    clearPresentation()
    phase = .idle
    publish()
  }

  func seal() {
    guard !sealed else { return }
    scope = nil
    clearPresentation()
    phase = .idle
    sealed = true
    publish()
  }

  nonisolated var description: String { "ViewerPerformanceDashboardModel(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private var phaseKind: ViewerPerformanceDashboardPhaseKind {
    switch phase {
    case .idle: return .idle
    case .loading: return .loading
    case .ready: return .ready
    case .empty: return .empty
    case .failed: return .failed
    }
  }

  private func clearPresentation() {
    publication = nil
    progress = nil
    currentFreshnessReceipt = nil
    crosshair = nil
  }

  private func publish() {
    revision = revision == UInt64.max ? 1 : revision + 1
  }

  private static func isValid(
    _ publication: ViewerPerformanceProjectionPublication,
    for scope: ViewerPerformanceDashboardScope
  ) -> Bool {
    guard publication.cacheKey.source == scope.source,
      publication.cacheKey.rangeKind == scope.rangeKind,
      publication.freshnessReceipt.sourceGeneration == scope.sourceGeneration,
      let first = publication.result.buckets.first,
      let last = publication.result.buckets.last,
      first.lowerMonotonicNanoseconds == publication.cacheKey.lowerMonotonicNanoseconds,
      last.upperMonotonicNanoseconds == publication.cacheKey.upperMonotonicNanoseconds,
      bucketsAreContiguous(publication.result.buckets),
      publication.chartProjections.map(\.group) == ViewerPerformanceChartGroupKind.allCases,
      publication.chartProjections.allSatisfy({
        $0.bucketCount == publication.result.buckets.count
      })
    else { return false }
    return true
  }

  private static func revalidatedCrosshair(
    _ crosshair: ViewerPerformanceCrosshair?,
    in publication: ViewerPerformanceProjectionPublication
  ) -> ViewerPerformanceCrosshair? {
    guard let crosshair,
      let bucket = publication.result.buckets.first(where: {
        crosshair.viewerMonotonicNanoseconds >= $0.lowerMonotonicNanoseconds
          && crosshair.viewerMonotonicNanoseconds <= $0.upperMonotonicNanoseconds
      })
    else { return nil }
    return ViewerPerformanceCrosshair(
      viewerMonotonicNanoseconds: crosshair.viewerMonotonicNanoseconds,
      bucketIndex: bucket.index,
      chartGroup: crosshair.chartGroup,
      selectedMetric: crosshair.selectedMetric
    )
  }

  private static func bucketsAreContiguous(_ buckets: [ViewerPerformanceBucket]) -> Bool {
    guard !buckets.isEmpty else { return false }
    for index in 1..<buckets.count {
      let previous = buckets[index - 1]
      let current = buckets[index]
      let (expectedLower, overflow) = previous.upperMonotonicNanoseconds.addingReportingOverflow(1)
      if overflow || current.lowerMonotonicNanoseconds != expectedLower { return false }
    }
    return true
  }

  private static func group(
    containing metric: ViewerPerformanceNumericMetric
  ) -> ViewerPerformanceChartGroupKind? {
    ViewerPerformanceChartGroup.all.first { $0.metrics.contains(metric) }?.id
  }
}

extension ViewerPerformanceDashboardScope: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceDashboardScope(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceCrosshair: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceCrosshair(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceDashboardDiagnostics: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerPerformanceDashboardDiagnostics(phase: \(phase), buckets: \(bucketCount))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["phase": phase, "bucketCount": bucketCount],
      displayStyle: .struct
    )
  }
}
