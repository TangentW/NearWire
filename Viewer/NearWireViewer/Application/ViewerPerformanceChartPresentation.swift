import Foundation

struct ViewerPerformanceChartPoint: Equatable, Sendable {
  let metric: ViewerPerformanceNumericMetric
  let bucketIndex: Int
  let segmentStartBucketIndex: Int
  let lowerMonotonicNanoseconds: Int64
  let centerMonotonicNanoseconds: Int64
  let upperMonotonicNanoseconds: Int64
  let minimum: Double
  let average: Double
  let maximum: Double
  let measurementCount: UInt64
  let isDiscontinuous: Bool
}

struct ViewerPerformanceChartProjection: Identifiable, Equatable, Sendable {
  let group: ViewerPerformanceChartGroupKind
  let metrics: [ViewerPerformanceNumericMetric]
  let bucketCount: Int
  let lowerMonotonicNanoseconds: Int64?
  let upperMonotonicNanoseconds: Int64?
  let markCount: Int

  var id: ViewerPerformanceChartGroupKind { group }
  var hasMeasurements: Bool { markCount > 0 }

  static func makeAll(
    buckets: [ViewerPerformanceBucket]
  ) throws -> [ViewerPerformanceChartProjection] {
    guard buckets.count <= ViewerPerformanceAggregationLimits.maximumBuckets,
      buckets.enumerated().allSatisfy({ $0.offset == $0.element.index })
    else { throw ViewerPerformanceFailure.limitExceeded }

    let groups = ViewerPerformanceChartGroup.all
    let metrics = groups.flatMap(\.metrics)
    guard groups.count == ViewerPerformanceAggregationLimits.maximumCharts,
      metrics == ViewerPerformanceNumericMetric.allCases,
      Set(metrics).count == metrics.count
    else { throw ViewerPerformanceFailure.invalidCarrier }

    var totalMarkCount = 0
    var projections: [ViewerPerformanceChartProjection] = []
    projections.reserveCapacity(groups.count)
    for group in groups {
      var measuredBucketCount = 0
      for metric in group.metrics {
        for bucket in buckets {
          let accumulator = bucket.numeric.accumulator(for: metric)
          guard accumulator.measurementCount > 0 else { continue }
          try validate(accumulator)
          measuredBucketCount += 1
        }
      }
      let (markCount, multiplicationOverflow) =
        measuredBucketCount
        .multipliedReportingOverflow(by: 2)
      let (nextMarkCount, additionOverflow) = totalMarkCount.addingReportingOverflow(markCount)
      guard !multiplicationOverflow, !additionOverflow,
        nextMarkCount <= ViewerPerformanceAggregationLimits.maximumTotalMarks
      else { throw ViewerPerformanceFailure.limitExceeded }
      totalMarkCount = nextMarkCount
      projections.append(
        ViewerPerformanceChartProjection(
          group: group.id,
          metrics: group.metrics,
          bucketCount: buckets.count,
          lowerMonotonicNanoseconds: buckets.first?.lowerMonotonicNanoseconds,
          upperMonotonicNanoseconds: buckets.last?.upperMonotonicNanoseconds,
          markCount: markCount
        )
      )
    }
    return projections
  }

  func point(
    metric: ViewerPerformanceNumericMetric,
    bucketIndex: Int,
    buckets: [ViewerPerformanceBucket]
  ) -> ViewerPerformanceChartPoint? {
    guard metrics.contains(metric), buckets.count == bucketCount,
      buckets.indices.contains(bucketIndex), buckets[bucketIndex].index == bucketIndex
    else { return nil }
    let bucket = buckets[bucketIndex]
    let accumulator = bucket.numeric.accumulator(for: metric)
    guard accumulator.measurementCount > 0,
      let minimum = accumulator.minimum,
      let average = accumulator.average,
      let maximum = accumulator.maximum
    else { return nil }
    return ViewerPerformanceChartPoint(
      metric: metric,
      bucketIndex: bucketIndex,
      segmentStartBucketIndex: segmentStartBucketIndex(
        metric: metric,
        bucketIndex: bucketIndex,
        buckets: buckets
      ),
      lowerMonotonicNanoseconds: bucket.lowerMonotonicNanoseconds,
      centerMonotonicNanoseconds: bucket.centerMonotonicNanoseconds,
      upperMonotonicNanoseconds: bucket.upperMonotonicNanoseconds,
      minimum: minimum,
      average: average,
      maximum: maximum,
      measurementCount: accumulator.measurementCount,
      isDiscontinuous: accumulator.isDiscontinuous
    )
  }

  private func segmentStartBucketIndex(
    metric: ViewerPerformanceNumericMetric,
    bucketIndex: Int,
    buckets: [ViewerPerformanceBucket]
  ) -> Int {
    let selected = buckets[bucketIndex].numeric.accumulator(for: metric)
    guard !selected.isDiscontinuous else { return bucketIndex }
    var start = bucketIndex
    while start > 0 {
      let current = buckets[start].numeric.accumulator(for: metric)
      let previous = buckets[start - 1].numeric.accumulator(for: metric)
      guard current.measurementCount > 0, previous.measurementCount > 0,
        !current.isDiscontinuous, !previous.isDiscontinuous
      else { break }
      start -= 1
    }
    return start
  }

  private static func validate(
    _ accumulator: ViewerPerformanceNumericAccumulator
  ) throws {
    guard let minimum = accumulator.minimum,
      let average = accumulator.average,
      let maximum = accumulator.maximum,
      minimum.isFinite, average.isFinite, maximum.isFinite,
      minimum >= 0, minimum <= average, average <= maximum
    else { throw ViewerPerformanceFailure.invalidCarrier }
  }
}

enum ViewerPerformanceKeyboardDirection: Equatable, Sendable {
  case left
  case right
  case up
  case down
}

struct ViewerPerformanceKeyboardSelection: Equatable, Sendable {
  let viewerMonotonicNanoseconds: Int64
  let chartGroup: ViewerPerformanceChartGroupKind
  let selectedMetric: ViewerPerformanceNumericMetric?
}

enum ViewerPerformanceKeyboardNavigation {
  static func selection(
    direction: ViewerPerformanceKeyboardDirection,
    current: ViewerPerformanceCrosshair?,
    projection: ViewerPerformanceChartProjection,
    buckets: [ViewerPerformanceBucket]
  ) -> ViewerPerformanceKeyboardSelection? {
    guard !buckets.isEmpty, buckets.count == projection.bucketCount else { return nil }
    let currentIndex = min(max(current?.bucketIndex ?? 0, 0), buckets.count - 1)

    switch direction {
    case .left, .right:
      let targetIndex: Int
      if current == nil {
        targetIndex = direction == .left ? buckets.count - 1 : 0
      } else {
        let delta = direction == .left ? -1 : 1
        targetIndex = min(max(currentIndex + delta, 0), buckets.count - 1)
      }
      let selectedMetric =
        current?.chartGroup == projection.group
        ? current?.selectedMetric
        : firstMeasuredMetric(
          bucketIndex: targetIndex,
          projection: projection,
          buckets: buckets
        )
      return ViewerPerformanceKeyboardSelection(
        viewerMonotonicNanoseconds: buckets[targetIndex].centerMonotonicNanoseconds,
        chartGroup: projection.group,
        selectedMetric: selectedMetric
      )

    case .up, .down:
      guard !projection.metrics.isEmpty else { return nil }
      let selectedIndex = current?.selectedMetric.flatMap(projection.metrics.firstIndex(of:)) ?? 0
      let delta = direction == .up ? -1 : 1
      let nextIndex =
        (selectedIndex + delta + projection.metrics.count) % projection.metrics.count
      return ViewerPerformanceKeyboardSelection(
        viewerMonotonicNanoseconds: current?.viewerMonotonicNanoseconds
          ?? buckets[currentIndex].centerMonotonicNanoseconds,
        chartGroup: projection.group,
        selectedMetric: projection.metrics[nextIndex]
      )
    }
  }

  private static func firstMeasuredMetric(
    bucketIndex: Int,
    projection: ViewerPerformanceChartProjection,
    buckets: [ViewerPerformanceBucket]
  ) -> ViewerPerformanceNumericMetric? {
    projection.metrics.first {
      buckets[bucketIndex].numeric.accumulator(for: $0).average != nil
    }
  }
}

extension ViewerPerformanceChartPoint: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceChartPoint(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceChartProjection: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceChartProjection(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
