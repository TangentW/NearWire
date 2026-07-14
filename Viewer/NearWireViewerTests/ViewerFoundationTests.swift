import Combine
import CryptoKit
import Darwin
import LocalAuthentication
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport
import Security
import SwiftUI
import XCTest

@testable import NearWireViewer

final class ViewerPerformanceInventoryTests: XCTestCase {
  func testViewerConsumesCoreMetricInventoryWithoutReordering() {
    XCTAssertEqual(
      ViewerPerformanceMetricInventory.descriptors.map(\.key),
      PerformanceMetricKey.allCases
    )
    XCTAssertEqual(
      ViewerPerformanceMetricInventory.descriptors.map(\.group),
      PerformanceMetricKey.allCases.map(\.group)
    )
    XCTAssertEqual(
      ViewerPerformanceMetricInventory.descriptors.map(\.kind),
      PerformanceMetricKey.allCases.map(\.kind)
    )
  }

  func testPerformanceReconciliationPrefersDurableLocatorWithoutChangingIdentity() throws {
    let key = ViewerEventJournalKey(
      runtimeLogicalID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      direction: .appToViewer,
      wireSequence: 7
    )
    let content = Data("{\"value\":1}".utf8)
    let transient = try ViewerPerformanceEventCarrier(
      locator: .transient(
        observationID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
      ),
      key: key,
      viewerWallMilliseconds: 11,
      viewerMonotonicNanoseconds: 13,
      content: .canonical(content)
    )
    let durable = try ViewerPerformanceEventCarrier(
      locator: .durable(rowID: 17, deviceSessionID: 19),
      key: key,
      viewerWallMilliseconds: 11,
      viewerMonotonicNanoseconds: 13,
      content: .canonical(content)
    )

    XCTAssertEqual(
      try ViewerPerformanceEventReconciler.reconcile(transient, durable),
      durable
    )
    XCTAssertEqual(
      try ViewerPerformanceEventReconciler.reconcile(durable, transient),
      durable
    )
    let conflicting = try ViewerPerformanceEventCarrier(
      locator: transient.locator,
      key: key,
      viewerWallMilliseconds: 11,
      viewerMonotonicNanoseconds: 13,
      content: .canonical(Data("{\"value\":2}".utf8))
    )
    XCTAssertThrowsError(
      try ViewerPerformanceEventReconciler.reconcile(transient, conflicting)
    ) { error in
      XCTAssertEqual(error as? ViewerPerformanceStoreFailure, .invalidCarrier)
    }
  }

  func testPerformanceDecoderPreservesMeasurementsAvailabilityAndUnknownRawOnlyValues() throws {
    let outcome = ViewerPerformanceSnapshotDecoder.decode(
      .canonical(
        Data(
          """
          {
            "schemaVersion": 1,
            "sampledAt": "2026-07-14T01:02:03.456Z",
            "sampleIntervalMilliseconds": 1000,
            "process": {"cpuPercent": 0, "memoryFootprintBytes": 0},
            "display": {"estimatedFramesPerSecond": 60},
            "device": {
              "batteryLevel": 0,
              "batteryState": "future-battery-state",
              "thermalState": "future-thermal-state",
              "lowPowerModeEnabled": false,
              "futureMetric": 12
            },
            "transport": {
              "uplinkBytesPerSecond": 0,
              "downlinkBytesPerSecond": 0,
              "uplinkQueueDepth": 0,
              "droppedEventCount": 0
            },
            "unavailable": [
              {"metric": "device.gpuUtilization", "reason": "unsupported"},
              {"metric": "device.powerWatts", "reason": "disabled"},
              {"metric": "device.temperatureCelsius", "reason": "permissionDenied"},
              {"metric": "display.maximumFramesPerSecond", "reason": "temporarilyUnavailable"},
              {"metric": "future.metric", "reason": "unsupported"},
              {"metric": "future.metric", "reason": "disabled"}
            ],
            "futureGroup": {"value": 1}
          }
          """.utf8
        )
      )
    )
    guard case .valid(let decoded) = outcome else {
      return XCTFail("Expected a valid Core V1 performance snapshot")
    }

    XCTAssertEqual(decoded.sampleIntervalMilliseconds, 1_000)
    XCTAssertEqual(decoded.state(for: .processCPUPercent), .numeric(0))
    XCTAssertEqual(decoded.state(for: .processMemoryFootprintBytes), .unsigned(0))
    XCTAssertEqual(decoded.state(for: .deviceBatteryLevel), .numeric(0))
    XCTAssertEqual(decoded.state(for: .deviceBatteryState), .batteryState(.unknown))
    XCTAssertEqual(decoded.state(for: .deviceThermalState), .thermalState(.unknown))
    XCTAssertEqual(decoded.state(for: .deviceLowPowerModeEnabled), .boolean(false))
    XCTAssertEqual(decoded.state(for: .transportDroppedEventCount), .unsigned(0))
    XCTAssertEqual(decoded.state(for: .transportDownlinkQueueDepth), .notCollected)
    XCTAssertEqual(
      decoded.state(for: .deviceGPUUtilization),
      .unavailable(.unsupported)
    )
    XCTAssertEqual(decoded.state(for: .devicePowerWatts), .unavailable(.disabled))
    XCTAssertEqual(
      decoded.state(for: .deviceTemperatureCelsius),
      .unavailable(.permissionDenied)
    )
    XCTAssertEqual(
      decoded.state(for: .displayMaximumFramesPerSecond),
      .unavailable(.temporarilyUnavailable)
    )
    XCTAssertNil(PerformanceMetricKey(rawValue: "future.metric"))
  }

  func testPerformanceDecoderInvalidatesKnownUnavailableConflicts() {
    let identicalDuplicate = ViewerPerformanceSnapshotDecoder.decode(
      .canonical(
        performanceJSON(
          body:
            "\"unavailable\":[{\"metric\":\"process.cpuPercent\",\"reason\":\"disabled\"},{\"metric\":\"process.cpuPercent\",\"reason\":\"disabled\"}]"
        )
      )
    )
    XCTAssertEqual(identicalDuplicate, .invalid(.duplicateKnownUnavailable))

    let duplicate = ViewerPerformanceSnapshotDecoder.decode(
      .canonical(
        performanceJSON(
          body:
            "\"unavailable\":[{\"metric\":\"process.cpuPercent\",\"reason\":\"disabled\"},{\"metric\":\"process.cpuPercent\",\"reason\":\"unsupported\"}]"
        )
      )
    )
    XCTAssertEqual(duplicate, .invalid(.duplicateKnownUnavailable))

    let presentAndUnavailable = ViewerPerformanceSnapshotDecoder.decode(
      .canonical(
        performanceJSON(
          body:
            "\"process\":{\"cpuPercent\":0},\"unavailable\":[{\"metric\":\"process.cpuPercent\",\"reason\":\"disabled\"}]"
        )
      )
    )
    XCTAssertEqual(presentAndUnavailable, .invalid(.presentAndUnavailable))
  }

  func testPerformanceDecoderClassifiesMalformedSchemaCoreAndSizeFailures() {
    XCTAssertEqual(
      ViewerPerformanceSnapshotDecoder.decode(.canonical(Data("{".utf8))),
      .invalid(.malformedJSON)
    )
    XCTAssertEqual(
      ViewerPerformanceSnapshotDecoder.decode(
        .canonical(
          Data(
            "{\"schemaVersion\":2,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000}"
              .utf8)
        )
      ),
      .invalid(.unsupportedSchema)
    )
    XCTAssertEqual(
      ViewerPerformanceSnapshotDecoder.decode(
        .canonical(
          Data("{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\"}".utf8)
        )
      ),
      .invalid(.invalidCoreContent)
    )
    XCTAssertEqual(
      ViewerPerformanceSnapshotDecoder.decode(.oversized(byteCount: 65_537)),
      .invalid(.oversizedContent)
    )
    XCTAssertEqual(
      ViewerPerformanceSnapshotDecoder.decode(.canonical(Data(repeating: 0x20, count: 65_537))),
      .invalid(.oversizedContent)
    )

    let prefix =
      "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\"future\":\""
    let suffix = "\"}"
    let paddingCount =
      ViewerPerformanceLimits.decoderBufferBytes
      - prefix.utf8.count - suffix.utf8.count
    let exact = Data((prefix + String(repeating: "x", count: paddingCount) + suffix).utf8)
    XCTAssertEqual(exact.count, ViewerPerformanceLimits.decoderBufferBytes)
    guard case .valid = ViewerPerformanceSnapshotDecoder.decode(.canonical(exact)) else {
      return XCTFail("Expected the exact 65,536-byte boundary to decode")
    }
  }

  private func performanceJSON(body: String) -> Data {
    Data(
      "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\(body)}"
        .utf8
    )
  }
}

final class ViewerPerformancePresentationTests: XCTestCase {
  func testMetricPresentationUsesExactInventoryAndExplicitCurrentCardSubset() {
    XCTAssertEqual(
      ViewerPerformanceMetricPresentation.all.map(\.key),
      PerformanceMetricKey.allCases
    )
    XCTAssertEqual(
      PerformanceMetricGroup.allCases.flatMap(\.keys),
      PerformanceMetricKey.allCases
    )
    XCTAssertEqual(ViewerPerformanceMetricPresentation.all.count, 16)
    XCTAssertEqual(ViewerPerformanceMetricPresentation.currentCardKeys.count, 12)
    XCTAssertEqual(
      Set(ViewerPerformanceMetricPresentation.currentCardKeys).count,
      ViewerPerformanceMetricPresentation.currentCardKeys.count
    )
    XCTAssertFalse(
      ViewerPerformanceMetricPresentation.currentCardKeys.contains(.deviceGPUUtilization)
    )
    XCTAssertFalse(
      ViewerPerformanceMetricPresentation.currentCardKeys.contains(.devicePowerWatts)
    )
    XCTAssertFalse(
      ViewerPerformanceMetricPresentation.currentCardKeys.contains(.deviceTemperatureCelsius)
    )
    XCTAssertFalse(
      ViewerPerformanceMetricPresentation.currentCardKeys.contains(.transportDownlinkQueueDepth)
    )
    XCTAssertTrue(
      ViewerPerformanceMetricPresentation.all.allSatisfy {
        !$0.title.isEmpty && !$0.unit.isEmpty && !$0.systemImage.isEmpty
      }
    )
    XCTAssertEqual(
      ViewerPerformanceMetricPresentation.descriptor(for: .deviceTemperatureCelsius).unit,
      "°C"
    )
  }

  func testCurrentCardFormattingPreservesMeasuredZeroAndClosedStates() {
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.numeric(0)),
        for: .processCPUPercent
      ),
      "0%"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.numeric(0)),
        for: .deviceBatteryLevel
      ),
      "0%"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.unsigned(0)),
        for: .processMemoryFootprintBytes
      ),
      "0 B"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.unsigned(1_536)),
        for: .transportUplinkBytesPerSecond
      ),
      "1.5 KiB/s"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.thermalState(.unknown)),
        for: .deviceThermalState
      ),
      "Unknown"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .measured(.boolean(false)),
        for: .deviceLowPowerModeEnabled
      ),
      "Off"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(
        .unavailable(.unsupported),
        for: .deviceGPUUtilization
      ),
      "Unsupported"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(.notCollected, for: .devicePowerWatts),
      "Not collected"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.cardValue(.noRecentSample, for: .processCPUPercent),
      "No recent sample"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.chartValue(0.5, metric: .batteryFraction),
      50
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.chartAxisValue(1_536, group: .throughput),
      "1.5 KiB/s"
    )
    XCTAssertEqual(ViewerPerformanceFormatting.elapsedTime(90), "1.5m")
  }

  func testAvailabilityFormattingDisclosesEveryRetainedStateCount() {
    var counts = ViewerPerformanceAvailabilityCounts()
    counts.record(.numeric(0))
    counts.record(.unavailable(.permissionDenied))
    counts.record(.unavailable(.temporarilyUnavailable))
    counts.record(.unavailable(.disabled))
    counts.record(.unavailable(.unsupported))
    counts.record(.notCollected)
    counts.recordInvalid()

    XCTAssertEqual(counts.presentation, .measured)
    XCTAssertEqual(
      ViewerPerformanceFormatting.availabilityDetail(counts),
      "1 measured · 1 invalid · 1 permission denied · 1 temporarily unavailable · 1 disabled · 1 unsupported · 1 not collected"
    )
    XCTAssertEqual(
      ViewerPerformanceFormatting.availability(.unavailable(.permissionDenied)),
      "Permission denied"
    )
  }

  @MainActor
  func testPerformanceSummaryComposesAtCompactAndWideWidthsWithoutRuntime() {
    let model = ViewerPerformanceDashboardModel()
    let hostingView = NSHostingView(
      rootView: ViewerPerformanceDashboardContent(model: model, guidance: .selectOneDevice)
    )
    for width in [360.0, 540.0, 980.0] {
      hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 720)
      hostingView.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
      XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }
    XCTAssertEqual(model.diagnostics.phase, .idle)
    XCTAssertTrue(model.availability.isEmpty)
  }

  func testChartProjectionBuildsSixGroupsAndPreservesAggregatedEnvelope() throws {
    let buckets = try chartBuckets(count: 2, samplesPerBucket: 2)
    let projections = try ViewerPerformanceChartProjection.makeAll(buckets: buckets)

    XCTAssertEqual(projections.map(\.group), ViewerPerformanceChartGroupKind.allCases)
    XCTAssertEqual(projections.flatMap(\.metrics), ViewerPerformanceNumericMetric.allCases)
    XCTAssertEqual(projections.reduce(0) { $0 + $1.markCount }, 40)
    let cpu = try XCTUnwrap(projections.first { $0.group == .cpu })
    let first = try XCTUnwrap(cpu.point(metric: .cpuPercent, bucketIndex: 0, buckets: buckets))
    XCTAssertEqual(first.minimum, 1)
    XCTAssertEqual(first.average, 1.5)
    XCTAssertEqual(first.maximum, 2)
    XCTAssertEqual(first.measurementCount, 2)
    XCTAssertEqual(first.segmentStartBucketIndex, 0)
    XCTAssertFalse(first.isDiscontinuous)
  }

  func testChartProjectionStaysBelowExactGlobalMarkBoundAt512Buckets() throws {
    let buckets = try chartBuckets(count: 512, samplesPerBucket: 1)
    let projections = try ViewerPerformanceChartProjection.makeAll(buckets: buckets)

    XCTAssertEqual(projections.count, 6)
    XCTAssertEqual(projections.map(\.markCount), [2_048, 1_024, 1_024, 1_024, 2_048, 3_072])
    XCTAssertEqual(projections.reduce(0) { $0 + $1.markCount }, 10_240)
    XCTAssertLessThanOrEqual(
      projections.reduce(0) { $0 + $1.markCount },
      ViewerPerformanceAggregationLimits.maximumTotalMarks
    )
    XCTAssertEqual(
      try ViewerPerformancePresentationBounds.maximumMarkCount(bucketCount: 512),
      12_288
    )
  }

  func testChartAccessibilityUsesAtMost64DeterministicNonColorSummaries() throws {
    var buckets = try chartBuckets(count: 512, samplesPerBucket: 2)
    buckets[511].markDiscontinuous(.estimatedFramesPerSecond)
    let projection = try XCTUnwrap(
      ViewerPerformanceChartProjection.makeAll(buckets: buckets).first { $0.group == .display }
    )
    let indices = ViewerPerformanceAccessibilityFormatting.bucketIndices(for: projection)

    XCTAssertEqual(indices.count, 64)
    XCTAssertEqual(indices.first, 0)
    XCTAssertEqual(indices.last, 511)
    XCTAssertEqual(Set(indices).count, indices.count)
    XCTAssertEqual(
      ViewerPerformanceAccessibilityFormatting.chartLabel(projection),
      "Frame Rate performance chart. Aggregated average lines and min–max envelopes. 512 buckets."
    )
    let label = try XCTUnwrap(
      ViewerPerformanceAccessibilityFormatting.bucketLabel(
        511,
        projection: projection,
        buckets: buckets
      )
    )
    XCTAssertTrue(label.contains("Aggregated bucket 512 of 512. Viewer time"))
    XCTAssertTrue(label.contains("Estimated Frame Rate, unit fps"))
    XCTAssertTrue(label.contains("minimum 3 fps, average 3.5 fps, maximum 4 fps, 2 samples"))
    XCTAssertTrue(label.contains("discontinuous"))
    XCTAssertTrue(label.contains("availability Measured"))
    XCTAssertTrue(label.contains("Maximum Frame Rate, unit fps"))

    let point = try XCTUnwrap(
      projection.point(
        metric: .estimatedFramesPerSecond,
        bucketIndex: 511,
        buckets: buckets
      )
    )
    XCTAssertEqual(String(reflecting: point), "ViewerPerformanceChartPoint(redacted)")
    XCTAssertEqual(String(reflecting: projection), "ViewerPerformanceChartProjection(redacted)")
  }

  func testKeyboardNavigationClampsBucketsAndCyclesMetricSeries() throws {
    let buckets = try chartBuckets(count: 3, samplesPerBucket: 1)
    let projection = try XCTUnwrap(
      ViewerPerformanceChartProjection.makeAll(buckets: buckets).first {
        $0.group == .queueAndDrops
      }
    )

    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .right,
        current: nil,
        projection: projection,
        buckets: buckets
      ),
      ViewerPerformanceKeyboardSelection(
        viewerMonotonicNanoseconds: buckets[0].centerMonotonicNanoseconds,
        chartGroup: .queueAndDrops,
        selectedMetric: .uplinkQueueDepth
      )
    )
    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .left,
        current: nil,
        projection: projection,
        buckets: buckets
      )?.viewerMonotonicNanoseconds,
      buckets[2].centerMonotonicNanoseconds
    )

    let selected = ViewerPerformanceCrosshair(
      viewerMonotonicNanoseconds: buckets[1].centerMonotonicNanoseconds,
      bucketIndex: 1,
      chartGroup: .queueAndDrops,
      selectedMetric: .uplinkQueueDepth
    )
    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .right,
        current: selected,
        projection: projection,
        buckets: buckets
      ),
      ViewerPerformanceKeyboardSelection(
        viewerMonotonicNanoseconds: buckets[2].centerMonotonicNanoseconds,
        chartGroup: .queueAndDrops,
        selectedMetric: .uplinkQueueDepth
      )
    )
    let last = ViewerPerformanceCrosshair(
      viewerMonotonicNanoseconds: buckets[2].centerMonotonicNanoseconds,
      bucketIndex: 2,
      chartGroup: .queueAndDrops,
      selectedMetric: .uplinkQueueDepth
    )
    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .right,
        current: last,
        projection: projection,
        buckets: buckets
      )?.viewerMonotonicNanoseconds,
      buckets[2].centerMonotonicNanoseconds
    )
    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .down,
        current: selected,
        projection: projection,
        buckets: buckets
      )?.selectedMetric,
      .downlinkQueueDepth
    )
    XCTAssertEqual(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .up,
        current: selected,
        projection: projection,
        buckets: buckets
      )?.selectedMetric,
      .droppedEventCount
    )
    XCTAssertNil(
      ViewerPerformanceKeyboardNavigation.selection(
        direction: .left,
        current: nil,
        projection: projection,
        buckets: []
      )
    )
  }

  func testChartSegmentsDisconnectBothSidesOfMetricBreaksAndMissingBuckets() throws {
    var buckets = try chartBuckets(count: 4, samplesPerBucket: 1)
    buckets[1].markDiscontinuous(.cpuPercent)
    let projection = try XCTUnwrap(
      ViewerPerformanceChartProjection.makeAll(buckets: buckets).first { $0.group == .cpu }
    )
    XCTAssertEqual(
      (0..<4).compactMap {
        projection.point(metric: .cpuPercent, bucketIndex: $0, buckets: buckets)?
          .segmentStartBucketIndex
      },
      [0, 1, 2, 2]
    )

    var missing = try chartBuckets(count: 3, samplesPerBucket: 1)
    missing[1] = try ViewerPerformanceBucket(
      index: 1,
      lowerMonotonicNanoseconds: 100,
      upperMonotonicNanoseconds: 199
    )
    let missingProjection = try XCTUnwrap(
      ViewerPerformanceChartProjection.makeAll(buckets: missing).first { $0.group == .cpu }
    )
    XCTAssertNil(
      missingProjection.point(metric: .cpuPercent, bucketIndex: 1, buckets: missing)
    )
    XCTAssertEqual(
      missingProjection.point(metric: .cpuPercent, bucketIndex: 2, buckets: missing)?
        .segmentStartBucketIndex,
      2
    )
  }

  func testEveryDiscontinuousBucketUsesAnIsolatedSegmentForUnplacedGapSuppression() throws {
    var buckets = try chartBuckets(count: 4, samplesPerBucket: 1)
    for index in buckets.indices { buckets[index].markAllDiscontinuous() }
    let projections = try ViewerPerformanceChartProjection.makeAll(buckets: buckets)

    for projection in projections {
      for metric in projection.metrics {
        XCTAssertEqual(
          (0..<4).compactMap {
            projection.point(metric: metric, bucketIndex: $0, buckets: buckets)?
              .segmentStartBucketIndex
          },
          [0, 1, 2, 3]
        )
      }
    }
  }

  private func chartBuckets(
    count: Int,
    samplesPerBucket: Int
  ) throws -> [ViewerPerformanceBucket] {
    try (0..<count).map { index in
      let lower = Int64(index * 100)
      var bucket = try ViewerPerformanceBucket(
        index: index,
        lowerMonotonicNanoseconds: lower,
        upperMonotonicNanoseconds: lower + 99
      )
      for sample in 0..<samplesPerBucket {
        let monotonic = lower + Int64(25 + sample * 50)
        try bucket.record(
          chartSnapshot(offset: Double(sample)),
          event: chartEvent(
            sequence: UInt64(index * max(samplesPerBucket, 1) + sample + 1), monotonic: monotonic)
        )
      }
      return bucket
    }
  }

  private func chartSnapshot(offset: Double) throws -> ViewerDecodedPerformanceSnapshot {
    try ViewerDecodedPerformanceSnapshot(
      sampledAt: Date(timeIntervalSince1970: offset),
      sampleIntervalMilliseconds: 1_000,
      states: PerformanceMetricKey.allCases.map { key in
        switch key {
        case .processCPUPercent: return .numeric(1 + offset)
        case .processMemoryFootprintBytes: return .unsigned(UInt64(2 + offset))
        case .displayEstimatedFramesPerSecond: return .numeric(3 + offset)
        case .displayMaximumFramesPerSecond: return .numeric(4 + offset)
        case .deviceBatteryLevel: return .numeric(0.5)
        case .deviceBatteryState: return .batteryState(.unplugged)
        case .deviceThermalState: return .thermalState(.nominal)
        case .deviceLowPowerModeEnabled: return .boolean(false)
        case .transportUplinkQueueDepth: return .unsigned(UInt64(5 + offset))
        case .transportDroppedEventCount: return .unsigned(UInt64(6 + offset))
        case .transportUplinkBytesPerSecond: return .unsigned(UInt64(7 + offset))
        case .transportDownlinkBytesPerSecond: return .unsigned(UInt64(8 + offset))
        case .transportDownlinkQueueDepth: return .unsigned(UInt64(9 + offset))
        case .deviceGPUUtilization, .devicePowerWatts, .deviceTemperatureCelsius:
          return .unavailable(.unsupported)
        }
      }
    )
  }

  private func chartEvent(
    sequence: UInt64,
    monotonic: Int64
  ) throws -> ViewerPerformanceEventCarrier {
    try ViewerPerformanceEventCarrier(
      locator: .transient(observationID: UUID()),
      key: ViewerEventJournalKey(
        runtimeLogicalID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        direction: .appToViewer,
        wireSequence: sequence
      ),
      viewerWallMilliseconds: monotonic,
      viewerMonotonicNanoseconds: monotonic,
      content: .canonical(Data("{}".utf8))
    )
  }
}

final class ViewerPerformanceAggregationTests: XCTestCase {
  func testNumericAccumulatorHandlesZeroOne512513And100000SamplesWithoutRawStorage() throws {
    let counts = [0, 1, 512, 513, 100_000]
    for count in counts {
      var accumulator = ViewerPerformanceNumericAccumulator()
      var expectedSum = 0.0
      let center = Int64(count / 2)
      for index in 0..<count {
        let value = Double(index % 10)
        expectedSum += value
        try accumulator.recordMeasurement(
          value,
          viewerMonotonicNanoseconds: Int64(index),
          journalKey: journalKey(UInt64(index)),
          bucketCenterMonotonicNanoseconds: center
        )
      }

      XCTAssertEqual(accumulator.measurementCount, UInt64(count), "count \(count)")
      if count == 0 {
        XCTAssertNil(accumulator.minimum)
        XCTAssertNil(accumulator.average)
        XCTAssertNil(accumulator.maximum)
        XCTAssertNil(accumulator.representative)
      } else {
        XCTAssertEqual(accumulator.minimum, 0, "count \(count)")
        XCTAssertEqual(accumulator.maximum, count == 1 ? 0 : 9, "count \(count)")
        XCTAssertEqual(
          try XCTUnwrap(accumulator.average),
          expectedSum / Double(count),
          accuracy: 0.000_000_001,
          "count \(count)"
        )
        XCTAssertEqual(accumulator.finiteSum, expectedSum, "count \(count)")
        XCTAssertEqual(accumulator.firstViewerMonotonicNanoseconds, 0, "count \(count)")
        XCTAssertEqual(
          accumulator.lastViewerMonotonicNanoseconds,
          Int64(count - 1),
          "count \(count)"
        )
        XCTAssertEqual(
          accumulator.representative?.key,
          journalKey(UInt64(count / 2)),
          "count \(count)"
        )
      }
    }
  }

  func testTenMetricsKeepDisjointContributorsAndCanonicalRepresentativeTies() throws {
    var bucket = try ViewerPerformanceBucket(
      index: 0,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 100
    )
    for metric in ViewerPerformanceNumericMetric.allCases {
      let states = PerformanceMetricKey.allCases.map { key -> ViewerPerformanceMetricState in
        guard key == metric.key else {
          return key.kind == .unavailableOnly ? .unavailable(.unsupported) : .notCollected
        }
        return disjointMeasurement(for: metric)
      }
      let snapshot = try ViewerDecodedPerformanceSnapshot(
        sampledAt: Date(timeIntervalSince1970: Double(metric.rawValue)),
        sampleIntervalMilliseconds: 1_000,
        states: states
      )
      try bucket.record(
        snapshot,
        event: event(
          sequence: UInt64(metric.rawValue + 1),
          monotonic: Int64(metric.rawValue * 10 + 1)
        )
      )
    }

    for metric in ViewerPerformanceNumericMetric.allCases {
      let accumulator = bucket.numeric.accumulator(for: metric)
      XCTAssertEqual(accumulator.measurementCount, 1, "metric \(metric)")
      XCTAssertEqual(
        accumulator.representative?.key,
        journalKey(UInt64(metric.rawValue + 1)),
        "metric \(metric)"
      )
      XCTAssertEqual(accumulator.nonmeasurements.notCollected, 9, "metric \(metric)")
      let availability = bucket.availability.counts(for: metric.key)
      XCTAssertEqual(availability.measured, 1, "metric \(metric)")
      XCTAssertEqual(availability.notCollected, 9, "metric \(metric)")
    }

    var tie = ViewerPerformanceNumericAccumulator()
    try tie.recordMeasurement(
      2,
      viewerMonotonicNanoseconds: 50,
      journalKey: journalKey(2),
      bucketCenterMonotonicNanoseconds: 50
    )
    try tie.recordMeasurement(
      1,
      viewerMonotonicNanoseconds: 50,
      journalKey: journalKey(1),
      bucketCenterMonotonicNanoseconds: 50
    )
    XCTAssertEqual(tie.representative?.key, journalKey(1))
  }

  func testCategoricalGapAndInvalidStormsRetainOnlyBoundedState() throws {
    var categorical = ViewerPerformanceCategoricalAccumulator<Bool>()
    var details = ViewerPerformanceBoundedDetails()
    let gap = try ViewerPerformanceGapCarrier(
      rowID: nil,
      recordingID: nil,
      deviceSessionID: nil,
      count: 1,
      firstViewerWallMilliseconds: nil,
      lastViewerWallMilliseconds: nil,
      kind: .unknown,
      applicability: .uncertain
    )
    for index in 0..<100_000 {
      try categorical.record(
        index.isMultiple(of: 2),
        viewerMonotonicNanoseconds: Int64(index),
        key: journalKey(UInt64(index))
      )
      details.append(gap: gap)
      details.append(
        invalid: try ViewerPerformanceInvalidDetail(
          key: journalKey(UInt64(index)),
          viewerMonotonicNanoseconds: Int64(index),
          reason: .invalidCoreContent
        )
      )
    }

    XCTAssertEqual(categorical.first?.value, true)
    XCTAssertEqual(categorical.latest?.value, false)
    XCTAssertEqual(categorical.last?.value, true)
    XCTAssertEqual(categorical.changeCount, 99_999)
    XCTAssertEqual(details.gaps.count, 128)
    XCTAssertEqual(details.invalidSnapshots.count, 128)
    XCTAssertEqual(details.detailLossCount, 199_744)
  }

  func testTenMetricAccumulatorsPreserveStatisticsStatesAndRepresentatives() throws {
    XCTAssertEqual(ViewerPerformanceNumericMetric.allCases.count, 10)
    XCTAssertEqual(
      Set(ViewerPerformanceNumericMetric.allCases.map(\.key)).count,
      ViewerPerformanceNumericMetric.allCases.count
    )
    XCTAssertTrue(
      ViewerPerformanceNumericMetric.allCases.allSatisfy { $0.key.kind == .numeric }
    )

    let runtimeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    func key(_ sequence: UInt64) -> ViewerEventJournalKey {
      ViewerEventJournalKey(
        runtimeLogicalID: runtimeID,
        connectionID: connectionID,
        direction: .appToViewer,
        wireSequence: sequence
      )
    }
    var accumulator = ViewerPerformanceNumericAccumulator()
    try accumulator.recordMeasurement(
      20,
      viewerMonotonicNanoseconds: 40,
      journalKey: key(2),
      bucketCenterMonotonicNanoseconds: 50
    )
    try accumulator.recordMeasurement(
      40,
      viewerMonotonicNanoseconds: 60,
      journalKey: key(1),
      bucketCenterMonotonicNanoseconds: 50
    )
    accumulator.recordNonmeasurement(.invalid)
    accumulator.recordNonmeasurement(.unavailable(.unsupported))
    accumulator.recordNonmeasurement(.unavailable(.disabled))
    accumulator.recordNonmeasurement(.unavailable(.permissionDenied))
    accumulator.recordNonmeasurement(.unavailable(.temporarilyUnavailable))
    accumulator.recordNonmeasurement(.notCollected)
    accumulator.markDiscontinuous()

    XCTAssertEqual(accumulator.minimum, 20)
    XCTAssertEqual(accumulator.maximum, 40)
    XCTAssertEqual(accumulator.average, 30)
    XCTAssertEqual(accumulator.finiteSum, 60)
    XCTAssertEqual(accumulator.measurementCount, 2)
    XCTAssertEqual(accumulator.firstViewerMonotonicNanoseconds, 40)
    XCTAssertEqual(accumulator.lastViewerMonotonicNanoseconds, 60)
    XCTAssertEqual(accumulator.representative?.key, key(2))
    XCTAssertEqual(accumulator.nonmeasurements.invalid, 1)
    XCTAssertEqual(accumulator.nonmeasurements.unsupported, 1)
    XCTAssertEqual(accumulator.nonmeasurements.disabled, 1)
    XCTAssertEqual(accumulator.nonmeasurements.permissionDenied, 1)
    XCTAssertEqual(accumulator.nonmeasurements.temporarilyUnavailable, 1)
    XCTAssertEqual(accumulator.nonmeasurements.notCollected, 1)
    XCTAssertTrue(accumulator.isDiscontinuous)

    var finite = ViewerPerformanceNumericAccumulator()
    try finite.recordMeasurement(
      Double.greatestFiniteMagnitude,
      viewerMonotonicNanoseconds: 1,
      journalKey: key(1),
      bucketCenterMonotonicNanoseconds: 1
    )
    try finite.recordMeasurement(
      Double.greatestFiniteMagnitude,
      viewerMonotonicNanoseconds: 2,
      journalKey: key(2),
      bucketCenterMonotonicNanoseconds: 1
    )
    XCTAssertTrue(try XCTUnwrap(finite.average).isFinite)
    XCTAssertTrue(finite.finiteSum.isFinite)
    XCTAssertTrue(finite.sumSaturated)
  }

  func testBucketAggregatesTenMetricsAndBoundedCategoricalChanges() throws {
    let first = try decodedSnapshot(numericOffset: 0, battery: .unplugged, thermal: .nominal)
    let second = try decodedSnapshot(numericOffset: 10, battery: .charging, thermal: .serious)
    var bucket = try ViewerPerformanceBucket(
      index: 0,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 99
    )
    let firstEvent = try event(sequence: 1, monotonic: 25)
    let secondEvent = try event(sequence: 2, monotonic: 75)
    try bucket.record(first, event: firstEvent)
    try bucket.record(second, event: secondEvent)
    bucket.markDiscontinuous(.cpuPercent)

    for metric in ViewerPerformanceNumericMetric.allCases {
      let accumulator = bucket.numeric.accumulator(for: metric)
      XCTAssertEqual(accumulator.measurementCount, 2)
      XCTAssertNotNil(accumulator.representative)
    }
    XCTAssertTrue(bucket.numeric.accumulator(for: .cpuPercent).isDiscontinuous)
    XCTAssertEqual(bucket.batteryState.first?.value, .unplugged)
    XCTAssertEqual(bucket.batteryState.latest?.value, .charging)
    XCTAssertEqual(bucket.batteryState.last?.value, .unplugged)
    XCTAssertEqual(bucket.batteryState.changeCount, 1)
    XCTAssertEqual(bucket.thermalState.changeCount, 1)
    XCTAssertEqual(bucket.lowPowerMode.changeCount, 0)
  }

  func testDetailsAccountingPresentationAndLedgerStayAtExactCaps() throws {
    var details = ViewerPerformanceBoundedDetails()
    let gap = try ViewerPerformanceGapCarrier(
      rowID: nil,
      recordingID: nil,
      deviceSessionID: nil,
      count: 1,
      firstViewerWallMilliseconds: nil,
      lastViewerWallMilliseconds: nil,
      kind: .unknown,
      applicability: .uncertain
    )
    let key = try event(sequence: 1, monotonic: 1).key
    for index in 0..<129 {
      details.append(gap: gap)
      details.append(
        invalid: try ViewerPerformanceInvalidDetail(
          key: key,
          viewerMonotonicNanoseconds: Int64(index),
          reason: .invalidCoreContent
        )
      )
    }
    XCTAssertEqual(details.gaps.count, 128)
    XCTAssertEqual(details.invalidSnapshots.count, 128)
    XCTAssertEqual(details.detailLossCount, 2)

    let buckets = try (0..<512).map {
      try ViewerPerformanceBucket(
        index: $0,
        lowerMonotonicNanoseconds: Int64($0),
        upperMonotonicNanoseconds: Int64($0)
      )
    }
    let availability = PerformanceMetricKey.allCases.map {
      ViewerPerformanceAvailabilityEntry(key: $0, state: .notCollected)
    }
    let result = try ViewerPerformanceAggregationResult(
      buckets: buckets,
      details: details,
      availability: availability
    )
    let expectedResultBytes =
      4_096 + 256 + 512 * 2_048 + 128 * 256 + 128 * 128
      + 16 * 64
    XCTAssertEqual(result.accountedBytes, expectedResultBytes)
    XCTAssertLessThanOrEqual(
      result.accountedBytes,
      ViewerPerformanceAggregationLimits.maximumResultBytes
    )
    XCTAssertEqual(ViewerPerformanceAccounting.deterministicPeakBytes, 25_805_312)
    XCTAssertEqual(ViewerPerformanceAggregationLimits.maximumResultBytes, 8_388_608)
    XCTAssertEqual(ViewerPerformanceAggregationLimits.maximumLedgerBytes, 16_777_216)
    XCTAssertEqual(
      try ViewerPerformancePresentationBounds.maximumMarkCount(bucketCount: 512), 12_288)
    let accessible = try ViewerPerformancePresentationBounds.accessibilityBucketIndices(
      bucketCount: 512
    )
    XCTAssertEqual(accessible.count, 64)
    XCTAssertEqual(accessible.first, 0)
    XCTAssertEqual(accessible.last, 511)
    XCTAssertEqual(Set(accessible).count, accessible.count)

    let ledger = ViewerPerformanceMemoryLedger()
    let reservation = try XCTUnwrap(
      ledger.reserve(
        owner: .completedResult,
        bytes: ViewerPerformanceAggregationLimits.maximumLedgerBytes
      )
    )
    XCTAssertEqual(ledger.usedBytes, 16_777_216)
    XCTAssertNil(try ledger.reserve(owner: .crosshair, bytes: 1))
    XCTAssertTrue(ledger.release(reservation))
    XCTAssertFalse(ledger.release(reservation))
    XCTAssertEqual(ledger.usedBytes, 0)
    XCTAssertEqual(ledger.reservationCount, 0)

    var active = try XCTUnwrap(ledger.reserve(owner: .activeReducer, bytes: 1_024))
    active = try XCTUnwrap(ledger.resize(active, to: 2_048))
    XCTAssertEqual(active.bytes, 2_048)
    XCTAssertEqual(ledger.usedBytes, 2_048)
    XCTAssertTrue(ledger.owns(active))
    let completed = try ledger.transfer(active, to: .completedResult)
    XCTAssertEqual(completed.owner, .completedResult)
    XCTAssertFalse(ledger.owns(active))
    XCTAssertTrue(ledger.owns(completed))
    let reduced = try XCTUnwrap(ledger.resize(completed, to: 1_024))
    XCTAssertEqual(ledger.usedBytes, 1_024)
    XCTAssertTrue(ledger.release(reduced))
    XCTAssertEqual(ledger.usedBytes, 0)
    XCTAssertFalse(String(reflecting: result).contains("process.cpuPercent"))
  }

  func testEveryDeterministicAccountingFormulaMatchesTheOwnershipContract() throws {
    XCTAssertEqual(ViewerPerformanceAccounting.controllerSourceBytes, 4_096)
    XCTAssertEqual(ViewerPerformanceAccounting.cacheKeyBytes, 256)
    XCTAssertEqual(ViewerPerformanceAccounting.resultBaseBytes, 4_096)
    XCTAssertEqual(ViewerPerformanceAccounting.bucketBytes, 2_048)
    XCTAssertEqual(ViewerPerformanceAccounting.detailedGapBytes, 256)
    XCTAssertEqual(ViewerPerformanceAccounting.invalidDetailBytes, 128)
    XCTAssertEqual(ViewerPerformanceAccounting.availabilityEntryBytes, 64)
    XCTAssertEqual(ViewerPerformanceAccounting.modelWrapperBytes, 1_024)
    XCTAssertEqual(ViewerPerformanceAccounting.deliveryWrapperBytes, 256)
    XCTAssertEqual(ViewerPerformanceAccounting.tooltipBytes, 2_048)
    XCTAssertEqual(ViewerPerformanceAccounting.crosshairBytes, 64)

    let emptyResultBytes = 4_096 + 256 + 16 * 64
    XCTAssertEqual(
      try ViewerPerformanceAccounting.resultBytes(
        bucketCount: 0,
        detailedGapCount: 0,
        invalidDetailCount: 0,
        availabilityCount: 16
      ),
      emptyResultBytes
    )
    let populatedBytes = emptyResultBytes + 3 * 2_048 + 2 * 256 + 1 * 128
    XCTAssertEqual(
      try ViewerPerformanceAccounting.resultBytes(
        bucketCount: 3,
        detailedGapCount: 2,
        invalidDetailCount: 1,
        availabilityCount: 16
      ),
      populatedBytes
    )
    XCTAssertEqual(
      try ViewerPerformanceAccounting.activeReducerBytes(
        bucketCount: 3,
        detailedGapCount: 2,
        invalidDetailCount: 1
      ),
      populatedBytes
    )
    XCTAssertThrowsError(
      try ViewerPerformanceAccounting.resultBytes(
        bucketCount: 513,
        detailedGapCount: 0,
        invalidDetailCount: 0,
        availabilityCount: 16
      )
    )
  }

  func testHundredThousandAlternatingInputsStayAtExactProjectionCapsAndCleanUp() throws {
    let sampleCount = 100_000
    let expectedEventCount = 75_000
    let expectedGapCount = 25_000
    let recordingLogicalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let deviceLogicalID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let source = try ViewerPerformanceSource.makeHistorical(
      recordingID: 11,
      deviceSessionID: 12,
      recordingLogicalID: recordingLogicalID,
      deviceLogicalID: deviceLogicalID
    )
    let bounds = try ViewerPerformanceRangeBounds.currentSession(
      deviceStartMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 131_071
    )
    let scope = try ViewerPerformanceStoreScope(
      storeGeneration: 1,
      recordingID: 11,
      deviceSessionID: 12,
      lowerMonotonicNanoseconds: bounds.lowerMonotonicNanoseconds,
      upperMonotonicNanoseconds: bounds.upperMonotonicNanoseconds,
      eventUpperRowID: Int64(expectedEventCount),
      gapUpperRowID: Int64(expectedGapCount)
    )
    var session = try ViewerPerformanceProjectionSession(
      receipt: ViewerPerformanceFrozenReceipt(
        source: source,
        storeScope: scope,
        liveSlice: nil
      ),
      rangeKind: .currentSession,
      bounds: bounds,
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: 1
    )
    let fixedObservationID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let measuredContent = [
      benchmarkPerformanceContent(measured: true, alternateCategory: false),
      benchmarkPerformanceContent(measured: true, alternateCategory: true),
    ]
    let missingContent = [
      benchmarkPerformanceContent(measured: false, alternateCategory: false),
      benchmarkPerformanceContent(measured: false, alternateCategory: true),
    ]
    let invalidContent = Data("{".utf8)
    let baselineFootprint = currentFoundationProcessPhysicalFootprintBytes()
    let startedAt = DispatchTime.now().uptimeNanoseconds

    var pageEvents: [ViewerPerformanceEventCarrier] = []
    pageEvents.reserveCapacity(ViewerPerformanceLimits.maximumEmittedEvents)
    var emittedEventCount = 0
    var eventPageCount = 0
    var validOrdinal = 0

    func drainEventPage() throws {
      guard !pageEvents.isEmpty else { return }
      let isComplete = emittedEventCount == expectedEventCount
      let last = try XCTUnwrap(pageEvents.last)
      let continuation =
        isComplete
        ? nil
        : ViewerPerformanceContinuation(
          scope: scope,
          lastExaminedMonotonicNanoseconds: last.viewerMonotonicNanoseconds,
          lastExaminedRowID: Int64(last.key.wireSequence + 1)
        )
      try session.accept(
        eventPage: ViewerPerformanceEventPage(
          scope: scope,
          events: pageEvents,
          examinedCandidateCount: pageEvents.count,
          continuation: continuation,
          isComplete: isComplete
        )
      )
      eventPageCount += 1
      while true {
        switch try session.runDecodeTurn() {
        case .processed:
          continue
        case .needsEventPage, .eventsComplete:
          pageEvents.removeAll(keepingCapacity: true)
          return
        }
      }
    }

    for inputIndex in 0..<sampleCount {
      if inputIndex % 4 == 2 { continue }
      let monotonic = Int64(UInt64(inputIndex) * 131_072 / UInt64(sampleCount))
      let content: Data
      switch inputIndex % 4 {
      case 0:
        content = measuredContent[validOrdinal % 2]
        validOrdinal += 1
      case 1:
        content = missingContent[validOrdinal % 2]
        validOrdinal += 1
      default:
        content = invalidContent
      }
      pageEvents.append(
        try ViewerPerformanceEventCarrier(
          locator: .transient(observationID: fixedObservationID),
          key: ViewerEventJournalKey(
            runtimeLogicalID: recordingLogicalID,
            connectionID: deviceLogicalID,
            direction: .appToViewer,
            wireSequence: UInt64(inputIndex)
          ),
          viewerWallMilliseconds: monotonic,
          viewerMonotonicNanoseconds: monotonic,
          content: .canonical(content)
        )
      )
      emittedEventCount += 1
      if pageEvents.count == ViewerPerformanceLimits.maximumEmittedEvents
        || emittedEventCount == expectedEventCount
      {
        try drainEventPage()
      }
    }
    XCTAssertEqual(emittedEventCount, expectedEventCount)
    XCTAssertTrue(session.eventsAreComplete)

    let gap = try ViewerPerformanceGapCarrier(
      rowID: nil,
      recordingID: nil,
      deviceSessionID: nil,
      count: 1,
      firstViewerWallMilliseconds: nil,
      lastViewerWallMilliseconds: nil,
      kind: .unknown,
      applicability: .uncertain
    )
    var gapPage: [ViewerPerformanceGapCarrier] = []
    gapPage.reserveCapacity(ViewerPerformanceLimits.maximumGapPageEvents)
    var consumedGapCount = 0
    var gapPageCount = 0
    for _ in 0..<expectedGapCount {
      gapPage.append(gap)
      consumedGapCount += 1
      if gapPage.count == ViewerPerformanceLimits.maximumGapPageEvents
        || consumedGapCount == expectedGapCount
      {
        try session.accept(
          gapPage: ViewerPerformanceGapPage(
            gaps: gapPage,
            hasMoreRows: consumedGapCount < expectedGapCount,
            applicableOrUncertainCount: UInt64(expectedGapCount),
            hasMoreApplicableGaps: true
          )
        )
        gapPageCount += 1
        gapPage.removeAll(keepingCapacity: true)
      }
    }
    XCTAssertTrue(session.isReadyToFinalize)

    let publication = try session.finalize(
      sourceGeneration: 1,
      deadlineRevision: 1,
      currentUptimeNanoseconds: nil
    )
    let result = publication.result
    let projections = try ViewerPerformanceChartProjection.makeAll(buckets: result.buckets)
    let accessibilityCount = projections.reduce(0) {
      $0 + ViewerPerformanceAccessibilityFormatting.bucketIndices(for: $1).count
    }
    let totalMeasurements = ViewerPerformanceNumericMetric.allCases.map { metric in
      result.buckets.reduce(UInt64(0)) {
        $0 + $1.numeric.accumulator(for: metric).measurementCount
      }
    }
    let categoricalChangeCount = result.buckets.reduce(UInt64(0)) {
      $0 + $1.lowPowerMode.changeCount
    }

    XCTAssertEqual(bounds.bucketCount, 512)
    XCTAssertEqual(eventPageCount, 147)
    XCTAssertEqual(gapPageCount, 782)
    XCTAssertEqual(publication.decodedEventCount, UInt64(expectedEventCount))
    XCTAssertEqual(publication.decodeTurnCount, 1_172)
    XCTAssertEqual(totalMeasurements, Array(repeating: 25_000, count: 10))
    XCTAssertEqual(categoricalChangeCount, 49_488)
    XCTAssertEqual(result.buckets.count, 512)
    XCTAssertTrue(
      result.buckets.allSatisfy { bucket in
        ViewerPerformanceNumericMetric.allCases.allSatisfy { metric in
          bucket.numeric.accumulator(for: metric).isDiscontinuous
        }
      }
    )
    XCTAssertEqual(result.gaps.count, 128)
    XCTAssertEqual(result.invalidSnapshots.count, 128)
    XCTAssertEqual(result.detailLossCount, 49_744)
    XCTAssertEqual(
      result.availability.first { $0.key == .processCPUPercent }?.counts.measured,
      25_000
    )
    XCTAssertEqual(
      result.availability.first { $0.key == .processCPUPercent }?.counts.notCollected,
      25_000
    )
    XCTAssertEqual(
      result.availability.first { $0.key == .processCPUPercent }?.counts.invalid,
      25_000
    )
    XCTAssertEqual(projections.reduce(0) { $0 + $1.markCount }, 10_240)
    XCTAssertEqual(
      try ViewerPerformancePresentationBounds.maximumMarkCount(bucketCount: 512),
      12_288
    )
    XCTAssertEqual(accessibilityCount, 384)
    XCTAssertEqual(result.accountedBytes, 1_103_104)
    XCTAssertEqual(ViewerPerformanceLimits.maximumExaminedEvents, 4_096)
    XCTAssertEqual(ViewerSQLiteBudget.performance().maximumVirtualMachineSteps, 5_000_000)
    XCTAssertEqual(ViewerPerformanceStoreService.maximumTurnNanoseconds, 50_000_000)

    let ledger = ViewerPerformanceMemoryLedger()
    var cache = ViewerPerformanceResultCache()
    cache.activate(source: source, ledger: ledger)
    var keys: [ViewerPerformanceCacheKey] = []
    for revision in 1...5 {
      let key = try ViewerPerformanceCacheKey(
        source: source,
        rangeKind: .currentSession,
        bounds: bounds,
        storeGeneration: 1,
        eventUpperRowID: Int64(expectedEventCount + revision),
        gapUpperRowID: Int64(expectedGapCount),
        liveGeneration: 0,
        liveSliceRevision: 0
      )
      keys.append(key)
      XCTAssertTrue(try cache.insert(result, for: key, ledger: ledger))
    }
    XCTAssertEqual(cache.count, 4)
    XCTAssertFalse(cache.contains(keys[0]))
    XCTAssertTrue(cache.contains(keys[4]))
    XCTAssertEqual(cache.accountedBytes, 4_412_416)
    XCTAssertEqual(ledger.usedBytes, 4_412_416)
    XCTAssertEqual(ledger.reservationCount, 4)
    cache.clear(ledger: ledger)
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(cache.accountedBytes, 0)
    XCTAssertEqual(ledger.usedBytes, 0)
    XCTAssertEqual(ledger.reservationCount, 0)

    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
    let endingFootprint = currentFoundationProcessPhysicalFootprintBytes()
    let footprintGrowth: UInt64? = {
      guard let baselineFootprint, let endingFootprint else { return nil }
      return endingFootprint >= baselineFootprint ? endingFootprint - baselineFootprint : 0
    }()
    let footprintText = footprintGrowth.map(String.init) ?? "unavailable"
    print(
      "NearWire 100,000 projection diagnostics: elapsed-ns=\(elapsed), process-footprint-growth=\(footprintText), event-candidates=\(expectedEventCount), event-pages=\(eventPageCount), gap-pages=\(gapPageCount), decode-turns=\(publication.decodeTurnCount), buckets=\(result.buckets.count), cache-entries-before-cleanup=4, marks=\(projections.reduce(0) { $0 + $1.markCount }), accessibility-values=\(accessibilityCount), result-bytes=\(result.accountedBytes), cleanup-ledger-bytes=\(ledger.usedBytes)"
    )
  }

  private func decodedSnapshot(
    numericOffset: Double,
    battery: BatteryState,
    thermal: ThermalState
  ) throws -> ViewerDecodedPerformanceSnapshot {
    let states = PerformanceMetricKey.allCases.map { key -> ViewerPerformanceMetricState in
      switch key {
      case .processCPUPercent: return .numeric(1 + numericOffset)
      case .processMemoryFootprintBytes: return .unsigned(UInt64(2 + numericOffset))
      case .displayEstimatedFramesPerSecond: return .numeric(3 + numericOffset)
      case .displayMaximumFramesPerSecond: return .numeric(4 + numericOffset)
      case .deviceBatteryLevel: return .numeric(0.5)
      case .deviceBatteryState: return .batteryState(battery)
      case .deviceThermalState: return .thermalState(thermal)
      case .deviceLowPowerModeEnabled: return .boolean(false)
      case .transportUplinkQueueDepth: return .unsigned(UInt64(5 + numericOffset))
      case .transportDroppedEventCount: return .unsigned(UInt64(6 + numericOffset))
      case .transportUplinkBytesPerSecond: return .unsigned(UInt64(7 + numericOffset))
      case .transportDownlinkBytesPerSecond: return .unsigned(UInt64(8 + numericOffset))
      case .transportDownlinkQueueDepth: return .unsigned(UInt64(9 + numericOffset))
      case .deviceGPUUtilization, .devicePowerWatts, .deviceTemperatureCelsius:
        return .unavailable(.unsupported)
      }
    }
    return try ViewerDecodedPerformanceSnapshot(
      sampledAt: Date(timeIntervalSince1970: 1),
      sampleIntervalMilliseconds: 1_000,
      states: states
    )
  }

  private func benchmarkPerformanceContent(
    measured: Bool,
    alternateCategory: Bool
  ) -> Data {
    let numeric =
      measured
      ? "\"process\":{\"cpuPercent\":1,\"memoryFootprintBytes\":2},\"display\":{\"estimatedFramesPerSecond\":3,\"maximumFramesPerSecond\":4},\"transport\":{\"uplinkBytesPerSecond\":5,\"downlinkBytesPerSecond\":6,\"uplinkQueueDepth\":7,\"downlinkQueueDepth\":8,\"droppedEventCount\":9},"
      : ""
    let battery = alternateCategory ? "charging" : "unplugged"
    let thermal = alternateCategory ? "serious" : "nominal"
    let batteryLevel = measured ? "0.5" : "null"
    return Data(
      "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\(numeric)\"device\":{\"batteryLevel\":\(batteryLevel),\"batteryState\":\"\(battery)\",\"thermalState\":\"\(thermal)\",\"lowPowerModeEnabled\":\(alternateCategory)},\"unavailable\":[{\"metric\":\"device.gpuUtilization\",\"reason\":\"unsupported\"},{\"metric\":\"device.powerWatts\",\"reason\":\"unsupported\"},{\"metric\":\"device.temperatureCelsius\",\"reason\":\"unsupported\"}]}"
        .utf8
    )
  }

  private func event(sequence: UInt64, monotonic: Int64) throws -> ViewerPerformanceEventCarrier {
    try ViewerPerformanceEventCarrier(
      locator: .transient(observationID: UUID()),
      key: ViewerEventJournalKey(
        runtimeLogicalID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        direction: .appToViewer,
        wireSequence: sequence
      ),
      viewerWallMilliseconds: monotonic,
      viewerMonotonicNanoseconds: monotonic,
      content: .canonical(Data("{}".utf8))
    )
  }

  private func journalKey(_ sequence: UInt64) -> ViewerEventJournalKey {
    ViewerEventJournalKey(
      runtimeLogicalID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      direction: .appToViewer,
      wireSequence: sequence
    )
  }

  private func disjointMeasurement(
    for metric: ViewerPerformanceNumericMetric
  ) -> ViewerPerformanceMetricState {
    switch metric {
    case .estimatedFramesPerSecond, .maximumFramesPerSecond, .cpuPercent, .batteryFraction:
      return .numeric(Double(metric.rawValue + 1))
    case .memoryFootprintBytes, .uplinkBytesPerSecond, .downlinkBytesPerSecond,
      .uplinkQueueDepth, .downlinkQueueDepth, .droppedEventCount:
      return .unsigned(UInt64(metric.rawValue + 1))
    }
  }
}

final class ViewerPerformanceRangeAndCacheTests: XCTestCase {
  func testInclusiveGeometryHandlesDefaultsEdgesUnderflowAndInt64Maximum() throws {
    XCTAssertEqual(ViewerPerformanceRangeKind.defaultKind, .fiveMinutes)
    XCTAssertEqual(ViewerPerformanceRangeKind.oneMinute.fixedDurationNanoseconds, 60_000_000_000)
    XCTAssertEqual(
      ViewerPerformanceRangeKind.fiveMinutes.fixedDurationNanoseconds,
      300_000_000_000
    )
    XCTAssertEqual(
      ViewerPerformanceRangeKind.fifteenMinutes.fixedDurationNanoseconds,
      900_000_000_000
    )
    XCTAssertNil(ViewerPerformanceRangeKind.currentSession.fixedDurationNanoseconds)

    let zeroDuration = try ViewerPerformanceRangeBounds.fixed(
      deviceStartMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 99,
      durationNanoseconds: 0
    )
    XCTAssertEqual(zeroDuration.lowerMonotonicNanoseconds, 99)
    XCTAssertEqual(zeroDuration.inclusiveSpanNanoseconds, 1)

    let saturatedLower = try ViewerPerformanceRangeBounds.fixed(
      deviceStartMonotonicNanoseconds: 10,
      upperMonotonicNanoseconds: 20,
      durationNanoseconds: UInt64.max
    )
    XCTAssertEqual(saturatedLower.lowerMonotonicNanoseconds, 10)
    XCTAssertEqual(saturatedLower.inclusiveSpanNanoseconds, 11)

    let maximum = try ViewerPerformanceRangeBounds.currentSession(
      deviceStartMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: Int64.max
    )
    XCTAssertEqual(maximum.inclusiveSpanNanoseconds, UInt64(Int64.max) + 1)
    XCTAssertEqual(maximum.bucketWidthNanoseconds, 1 << 54)
    XCTAssertEqual(maximum.bucketCount, 512)
    XCTAssertEqual(try maximum.bucketBounds(at: 511).upperBound, Int64.max)

    let edge = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 100,
      upperMonotonicNanoseconds: 612
    )
    XCTAssertEqual(edge.inclusiveSpanNanoseconds, 513)
    XCTAssertEqual(edge.bucketWidthNanoseconds, 2)
    XCTAssertEqual(edge.bucketCount, 257)
    XCTAssertEqual(edge.bucketIndex(containing: 99), nil)
    XCTAssertEqual(edge.bucketIndex(containing: 100), 0)
    XCTAssertEqual(edge.bucketIndex(containing: 101), 0)
    XCTAssertEqual(edge.bucketIndex(containing: 102), 1)
    XCTAssertEqual(edge.bucketIndex(containing: 612), 256)
    XCTAssertEqual(edge.bucketIndex(containing: 613), nil)
    XCTAssertEqual(try edge.bucketBounds(at: 0), 100...101)
    XCTAssertEqual(try edge.bucketBounds(at: 1), 102...103)
    XCTAssertEqual(try edge.bucketBounds(at: 256), 612...612)
    let buckets = try edge.makeBuckets()
    XCTAssertEqual(buckets.count, 257)
    XCTAssertEqual(buckets.last?.upperMonotonicNanoseconds, 612)
  }

  func testCurrentEndedInterruptedAndEmptyAnchorsAreExact() throws {
    let runtimeID = uuid(1)
    let connectionID = uuid(2)
    let source = ViewerPerformanceSource.current(
      runtimeLogicalID: runtimeID,
      connectionID: connectionID
    )
    let live = try ViewerPerformanceLiveSlice(
      runtimeLogicalID: runtimeID,
      connectionID: connectionID,
      liveGeneration: 3,
      revision: 4,
      anchorMonotonicNanoseconds: 50,
      events: [],
      gaps: [],
      applicableOrUncertainCount: 0,
      hasMoreApplicableGaps: false
    )
    XCTAssertEqual(
      try ViewerPerformanceAnchor.current(
        source: source,
        liveSlice: live,
        deviceStartMonotonicNanoseconds: 10
      ),
      try anchor(kind: .current, start: 10, upper: 50)
    )
    XCTAssertEqual(
      try ViewerPerformanceAnchor.ended(
        deviceStartMonotonicNanoseconds: 10,
        deviceEndMonotonicNanoseconds: 40
      ),
      try anchor(kind: .ended, start: 10, upper: 40)
    )
    XCTAssertEqual(
      try ViewerPerformanceAnchor.interrupted(
        deviceStartMonotonicNanoseconds: 10,
        frozenRecordingUpperMonotonicNanoseconds: 45
      ),
      try anchor(kind: .interrupted, start: 10, upper: 45)
    )
    XCTAssertEqual(
      try ViewerPerformanceAnchor.empty(deviceStartMonotonicNanoseconds: 10),
      try anchor(kind: .empty, start: 10, upper: 10)
    )
    XCTAssertThrowsError(
      try ViewerPerformanceAnchor.ended(
        deviceStartMonotonicNanoseconds: 10,
        deviceEndMonotonicNanoseconds: 9
      )
    )
    XCTAssertThrowsError(
      try ViewerPerformanceAnchor.current(
        source: .current(runtimeLogicalID: runtimeID, connectionID: uuid(3)),
        liveSlice: live,
        deviceStartMonotonicNanoseconds: 10
      )
    )
  }

  func testViewerReceiveOrderUsesCompleteCanonicalJournalTuple() throws {
    let runtime1 = uuid(1)
    let runtime2 = uuid(2)
    let connection1 = uuid(3)
    let connection2 = uuid(4)
    let ordered = try [
      event(
        runtime: runtime1, connection: connection1, direction: .appToViewer, sequence: 1, time: 11),
      event(
        runtime: runtime2, connection: connection1, direction: .appToViewer, sequence: 1, time: 10),
      event(
        runtime: runtime1, connection: connection2, direction: .appToViewer, sequence: 1, time: 10),
      event(
        runtime: runtime1, connection: connection1, direction: .viewerToApp, sequence: 1, time: 10),
      event(
        runtime: runtime1, connection: connection1, direction: .appToViewer, sequence: 2, time: 10),
      event(
        runtime: runtime1, connection: connection1, direction: .appToViewer, sequence: 1, time: 10),
      event(
        runtime: runtime1, connection: connection1, direction: .appToViewer, sequence: 9, time: 9),
    ].sorted(by: ViewerPerformanceCanonicalOrder.eventPrecedes)
    XCTAssertEqual(ordered.map(\.viewerMonotonicNanoseconds), [9, 10, 10, 10, 10, 10, 11])
    XCTAssertEqual(
      ordered.dropFirst().dropLast().map(\.key),
      [
        journal(runtime1, connection1, .appToViewer, 1),
        journal(runtime1, connection1, .appToViewer, 2),
        journal(runtime1, connection1, .viewerToApp, 1),
        journal(runtime1, connection2, .appToViewer, 1),
        journal(runtime2, connection1, .appToViewer, 1),
      ]
    )
  }

  func testCacheComparatorCoversEveryCanonicalTupleComponent() throws {
    let currentSource1 = ViewerPerformanceSource.current(
      runtimeLogicalID: uuid(1),
      connectionID: uuid(10)
    )
    let currentSource2 = ViewerPerformanceSource.current(
      runtimeLogicalID: uuid(2),
      connectionID: uuid(10)
    )
    let currentDevice2 = ViewerPerformanceSource.current(
      runtimeLogicalID: uuid(1),
      connectionID: uuid(11)
    )
    let historical1 = try ViewerPerformanceSource.makeHistorical(
      recordingID: 1,
      deviceSessionID: 10,
      recordingLogicalID: uuid(20),
      deviceLogicalID: uuid(30)
    )
    let historicalSource2 = try ViewerPerformanceSource.makeHistorical(
      recordingID: 2,
      deviceSessionID: 10,
      recordingLogicalID: uuid(20),
      deviceLogicalID: uuid(30)
    )
    let historicalDevice2 = try ViewerPerformanceSource.makeHistorical(
      recordingID: 1,
      deviceSessionID: 11,
      recordingLogicalID: uuid(20),
      deviceLogicalID: uuid(30)
    )
    let historicalRuntime2 = try ViewerPerformanceSource.makeHistorical(
      recordingID: 1,
      deviceSessionID: 10,
      recordingLogicalID: uuid(21),
      deviceLogicalID: uuid(30)
    )

    assertPrecedes(
      try key(source: currentSource1),
      try key(source: historical1)
    )
    assertPrecedes(try key(source: currentSource1), try key(source: currentSource2))
    assertPrecedes(try key(source: currentSource1), try key(source: currentDevice2))
    assertPrecedes(try key(source: historical1), try key(source: historicalSource2))
    assertPrecedes(try key(source: historical1), try key(source: historicalDevice2))
    assertPrecedes(
      try key(source: currentSource1, range: .oneMinute),
      try key(source: currentSource1, range: .fiveMinutes)
    )
    assertPrecedes(
      try key(source: currentSource1, lower: 0, upper: 10),
      try key(source: currentSource1, lower: 1, upper: 10)
    )
    assertPrecedes(
      try key(source: currentSource1, lower: 0, upper: 10),
      try key(source: currentSource1, lower: 0, upper: 11)
    )
    assertPrecedes(
      try key(source: currentSource1, store: 1),
      try key(source: currentSource1, store: 2)
    )
    assertPrecedes(
      try key(source: currentSource1, eventUpper: 1),
      try key(source: currentSource1, eventUpper: 2)
    )
    assertPrecedes(
      try key(source: currentSource1, gapUpper: 1),
      try key(source: currentSource1, gapUpper: 2)
    )
    assertPrecedes(try key(source: historical1), try key(source: historicalRuntime2))
    assertPrecedes(
      try key(source: currentSource1, liveGeneration: 1),
      try key(source: currentSource1, liveGeneration: 2)
    )
    assertPrecedes(
      try key(source: currentSource1, revision: 1),
      try key(source: currentSource1, revision: 2)
    )
  }

  func testFrozenReceiptsCreateCompleteCurrentAndHistoricalCacheKeys() throws {
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 10,
      upperMonotonicNanoseconds: 50
    )
    let scope = try ViewerPerformanceStoreScope(
      storeGeneration: 7,
      recordingID: 11,
      deviceSessionID: 12,
      lowerMonotonicNanoseconds: 10,
      upperMonotonicNanoseconds: 50,
      eventUpperRowID: 13,
      gapUpperRowID: 14
    )
    let live = try ViewerPerformanceLiveSlice(
      runtimeLogicalID: uuid(1),
      connectionID: uuid(2),
      liveGeneration: 3,
      revision: 4,
      anchorMonotonicNanoseconds: 50,
      events: [],
      gaps: [],
      applicableOrUncertainCount: 0,
      hasMoreApplicableGaps: false
    )
    let current = try ViewerPerformanceCacheKey(
      receipt: ViewerPerformanceFrozenReceipt(
        source: .current(runtimeLogicalID: uuid(1), connectionID: uuid(2)),
        storeScope: scope,
        liveSlice: live
      ),
      rangeKind: .fiveMinutes,
      bounds: bounds
    )
    XCTAssertEqual(current.storeGeneration, 7)
    XCTAssertEqual(current.eventUpperRowID, 13)
    XCTAssertEqual(current.gapUpperRowID, 14)
    XCTAssertEqual(current.runtimeLogicalID, uuid(1))
    XCTAssertEqual(current.liveGeneration, 3)
    XCTAssertEqual(current.liveSliceRevision, 4)

    let historicalSource = try ViewerPerformanceSource.makeHistorical(
      recordingID: 11,
      deviceSessionID: 12,
      recordingLogicalID: uuid(5),
      deviceLogicalID: uuid(6)
    )
    let historical = try ViewerPerformanceCacheKey(
      receipt: ViewerPerformanceFrozenReceipt(
        source: historicalSource,
        storeScope: scope,
        liveSlice: nil
      ),
      rangeKind: .currentSession,
      bounds: bounds
    )
    XCTAssertEqual(historical.runtimeLogicalID, uuid(5))
    XCTAssertEqual(historical.liveGeneration, 0)
    XCTAssertEqual(historical.liveSliceRevision, 0)

    let liveOnly = try ViewerPerformanceCacheKey(
      receipt: ViewerPerformanceFrozenReceipt(
        source: .current(runtimeLogicalID: uuid(1), connectionID: uuid(2)),
        storeScope: nil,
        liveSlice: live
      ),
      rangeKind: .fiveMinutes,
      bounds: bounds
    )
    XCTAssertEqual(liveOnly.storeGeneration, 0)
    XCTAssertEqual(liveOnly.eventUpperRowID, 0)
    XCTAssertEqual(liveOnly.gapUpperRowID, 0)
    XCTAssertNotEqual(current, liveOnly)
  }

  func testExactHitTouchesLRUFifthInsertionEvictsAndSourceReplacementClears() throws {
    let source = ViewerPerformanceSource.current(
      runtimeLogicalID: uuid(1),
      connectionID: uuid(2)
    )
    let keys = try [
      key(source: source, range: .oneMinute),
      key(source: source, range: .fiveMinutes),
      key(source: source, range: .fifteenMinutes),
      key(source: source, range: .currentSession),
      key(source: source, range: .fiveMinutes, lower: 1, upper: 1),
    ]
    let result = try aggregationResult()
    let ledger = ViewerPerformanceMemoryLedger()
    var cache = ViewerPerformanceResultCache()
    cache.activate(source: source, ledger: ledger)
    for key in keys.prefix(4) {
      XCTAssertTrue(try cache.insert(result, for: key, ledger: ledger))
    }
    XCTAssertEqual(cache.count, 4)
    XCTAssertEqual(cache.accountedBytes, result.accountedBytes * 4)
    XCTAssertEqual(ledger.usedBytes, result.accountedBytes * 4)

    let priorTouch = try XCTUnwrap(cache.touchOrdinal(for: keys[0]))
    XCTAssertEqual(try cache.result(for: keys[0]), result)
    XCTAssertGreaterThan(try XCTUnwrap(cache.touchOrdinal(for: keys[0])), priorTouch)
    XCTAssertNil(try cache.result(for: keys[4]))

    let bytesBeforeExactPublication = ledger.usedBytes
    XCTAssertTrue(try cache.insert(result, for: keys[0], ledger: ledger))
    XCTAssertEqual(ledger.usedBytes, bytesBeforeExactPublication)

    XCTAssertTrue(try cache.insert(result, for: keys[4], ledger: ledger))
    XCTAssertEqual(cache.count, 4)
    XCTAssertTrue(cache.contains(keys[0]))
    XCTAssertFalse(cache.contains(keys[1]))
    XCTAssertTrue(cache.contains(keys[4]))
    XCTAssertEqual(ledger.usedBytes, result.accountedBytes * 4)

    let replacement = ViewerPerformanceSource.current(
      runtimeLogicalID: uuid(1),
      connectionID: uuid(3)
    )
    cache.activate(source: replacement, ledger: ledger)
    XCTAssertEqual(cache.activeSource, replacement)
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(cache.accountedBytes, 0)
    XCTAssertEqual(ledger.usedBytes, 0)
    XCTAssertThrowsError(try cache.result(for: keys[0]))

    let replacementKey = try key(source: replacement)
    XCTAssertTrue(try cache.insert(result, for: replacementKey, ledger: ledger))
    let sourceReplacement = ViewerPerformanceSource.current(
      runtimeLogicalID: uuid(4),
      connectionID: uuid(3)
    )
    cache.activate(source: sourceReplacement, ledger: ledger)
    XCTAssertEqual(cache.activeSource, sourceReplacement)
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(ledger.usedBytes, 0)
    XCTAssertFalse(String(reflecting: cache).contains(uuid(1).uuidString))
  }

  func testCacheAcceptsTransferredCompletedOwnershipWithoutDoubleCharging() throws {
    let source = ViewerPerformanceSource.current(
      runtimeLogicalID: uuid(1),
      connectionID: uuid(2)
    )
    let key = try key(source: source)
    let result = try aggregationResult()
    let ledger = ViewerPerformanceMemoryLedger()
    var cache = ViewerPerformanceResultCache()
    cache.activate(source: source, ledger: ledger)
    let active = try XCTUnwrap(
      ledger.reserve(owner: .activeReducer, bytes: result.accountedBytes)
    )
    let completed = try ledger.transfer(active, to: .completedResult)

    XCTAssertTrue(
      try cache.insertOwned(
        result,
        reservation: completed,
        for: key,
        ledger: ledger
      )
    )
    XCTAssertEqual(cache.count, 1)
    XCTAssertEqual(ledger.usedBytes, result.accountedBytes)

    let duplicate = try XCTUnwrap(
      ledger.reserve(owner: .completedResult, bytes: result.accountedBytes)
    )
    XCTAssertTrue(
      try cache.insertOwned(
        result,
        reservation: duplicate,
        for: key,
        ledger: ledger
      )
    )
    XCTAssertEqual(cache.count, 1)
    XCTAssertEqual(ledger.usedBytes, result.accountedBytes)
    cache.clear(ledger: ledger)
    XCTAssertEqual(ledger.usedBytes, 0)
  }

  private func anchor(
    kind: ViewerPerformanceAnchorKind,
    start: Int64,
    upper: Int64
  ) throws -> ViewerPerformanceAnchor {
    switch kind {
    case .current:
      let source = ViewerPerformanceSource.current(
        runtimeLogicalID: uuid(1),
        connectionID: uuid(2)
      )
      return try .current(
        source: source,
        liveSlice: ViewerPerformanceLiveSlice(
          runtimeLogicalID: uuid(1),
          connectionID: uuid(2),
          liveGeneration: 1,
          revision: 1,
          anchorMonotonicNanoseconds: UInt64(upper),
          events: [],
          gaps: [],
          applicableOrUncertainCount: 0,
          hasMoreApplicableGaps: false
        ),
        deviceStartMonotonicNanoseconds: start
      )
    case .ended:
      return try .ended(
        deviceStartMonotonicNanoseconds: start,
        deviceEndMonotonicNanoseconds: upper
      )
    case .interrupted:
      return try .interrupted(
        deviceStartMonotonicNanoseconds: start,
        frozenRecordingUpperMonotonicNanoseconds: upper
      )
    case .empty:
      return try .empty(deviceStartMonotonicNanoseconds: start)
    }
  }

  private func event(
    runtime: UUID,
    connection: UUID,
    direction: EventDirection,
    sequence: UInt64,
    time: Int64
  ) throws -> ViewerPerformanceEventCarrier {
    try ViewerPerformanceEventCarrier(
      locator: .transient(observationID: UUID()),
      key: journal(runtime, connection, direction, sequence),
      viewerWallMilliseconds: time,
      viewerMonotonicNanoseconds: time,
      content: .canonical(Data("{}".utf8))
    )
  }

  private func journal(
    _ runtime: UUID,
    _ connection: UUID,
    _ direction: EventDirection,
    _ sequence: UInt64
  ) -> ViewerEventJournalKey {
    ViewerEventJournalKey(
      runtimeLogicalID: runtime,
      connectionID: connection,
      direction: direction,
      wireSequence: sequence
    )
  }

  private func key(
    source: ViewerPerformanceSource,
    range: ViewerPerformanceRangeKind = .oneMinute,
    lower: Int64 = 0,
    upper: Int64 = 0,
    store: UInt64 = 1,
    eventUpper: Int64 = 1,
    gapUpper: Int64 = 1,
    liveGeneration: UInt64 = 1,
    revision: UInt64 = 1
  ) throws -> ViewerPerformanceCacheKey {
    let historical: Bool
    switch source {
    case .current: historical = false
    case .historical: historical = true
    }
    return try ViewerPerformanceCacheKey(
      source: source,
      rangeKind: range,
      bounds: ViewerPerformanceRangeBounds(
        lowerMonotonicNanoseconds: lower,
        upperMonotonicNanoseconds: upper
      ),
      storeGeneration: store,
      eventUpperRowID: eventUpper,
      gapUpperRowID: gapUpper,
      liveGeneration: historical ? 0 : liveGeneration,
      liveSliceRevision: historical ? 0 : revision
    )
  }

  private func assertPrecedes(
    _ lhs: ViewerPerformanceCacheKey,
    _ rhs: ViewerPerformanceCacheKey,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertTrue(
      ViewerPerformanceCacheCanonicalOrder.keyPrecedes(lhs, rhs),
      file: file,
      line: line
    )
    XCTAssertFalse(
      ViewerPerformanceCacheCanonicalOrder.keyPrecedes(rhs, lhs),
      file: file,
      line: line
    )
  }

  private func aggregationResult() throws -> ViewerPerformanceAggregationResult {
    let details = ViewerPerformanceBoundedDetails()
    let availability = PerformanceMetricKey.allCases.map {
      ViewerPerformanceAvailabilityEntry(key: $0, state: .notCollected)
    }
    return try ViewerPerformanceAggregationResult(
      buckets: [
        ViewerPerformanceBucket(
          index: 0,
          lowerMonotonicNanoseconds: 0,
          upperMonotonicNanoseconds: 0
        )
      ],
      details: details,
      availability: availability
    )
  }

  private func uuid(_ suffix: UInt8) -> UUID {
    UUID(
      uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, suffix
      )
    )
  }
}

final class ViewerPerformanceSemanticsTests: XCTestCase {
  func testAvailabilityPrecedenceAndMetricSpecificContinuityRemainDistinct() throws {
    var precedence = ViewerPerformanceAvailabilityCounts()
    precedence.record(.unavailable(.unsupported))
    precedence.record(.unavailable(.disabled))
    precedence.record(.unavailable(.temporarilyUnavailable))
    precedence.record(.unavailable(.permissionDenied))
    XCTAssertEqual(precedence.presentation, .unavailable(.permissionDenied))
    precedence.recordInvalid()
    XCTAssertEqual(precedence.presentation, .invalidSnapshot)
    precedence.record(.numeric(0))
    XCTAssertEqual(precedence.presentation, .measured)

    var bucket = try ViewerPerformanceBucket(
      index: 0,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 10
    )
    var tracker = ViewerPerformanceContinuityTracker()
    let first = try semanticSnapshot(cpu: .numeric(0))
    let second = try semanticSnapshot(cpu: .notCollected)
    try tracker.consume(
      event: event(sequence: 1, monotonic: 1, wall: 100),
      outcome: .valid(first),
      bucket: &bucket
    )
    try tracker.consume(
      event: event(sequence: 2, monotonic: 2, wall: 101),
      outcome: .valid(second),
      bucket: &bucket
    )

    let cpu = bucket.numeric.accumulator(for: .cpuPercent)
    let memory = bucket.numeric.accumulator(for: .memoryFootprintBytes)
    XCTAssertEqual(cpu.measurementCount, 1)
    XCTAssertEqual(cpu.nonmeasurements.notCollected, 1)
    XCTAssertTrue(cpu.isDiscontinuous)
    XCTAssertFalse(memory.isDiscontinuous)
    XCTAssertEqual(
      bucket.availability.counts(for: .processCPUPercent).presentation,
      .measured
    )
    XCTAssertEqual(
      bucket.availability.counts(for: .deviceGPUUtilization).presentation,
      .unavailable(.unsupported)
    )

    try tracker.consume(
      event: event(sequence: 3, monotonic: 3, wall: 102),
      outcome: .invalid(.malformedJSON),
      bucket: &bucket
    )
    for metric in ViewerPerformanceNumericMetric.allCases {
      XCTAssertTrue(bucket.numeric.accumulator(for: metric).isDiscontinuous)
      XCTAssertEqual(bucket.numeric.accumulator(for: metric).nonmeasurements.invalid, 1)
    }
    XCTAssertEqual(
      bucket.availability.counts(for: .processCPUPercent).presentation,
      .measured
    )
    XCTAssertEqual(
      bucket.availability.counts(for: .deviceGPUUtilization).presentation,
      .invalidSnapshot
    )

    var firstBucketAvailability = ViewerPerformanceAvailabilityAccumulatorSet()
    firstBucketAvailability.record(first)
    var secondBucketAvailability = ViewerPerformanceAvailabilityAccumulatorSet()
    secondBucketAvailability.record(second)
    secondBucketAvailability.recordInvalid()
    firstBucketAvailability.merge(secondBucketAvailability)
    XCTAssertEqual(
      firstBucketAvailability.counts(for: .processCPUPercent).measured,
      1
    )
    XCTAssertEqual(
      firstBucketAvailability.counts(for: .processCPUPercent).notCollected,
      1
    )
    XCTAssertEqual(
      firstBucketAvailability.counts(for: .processCPUPercent).invalid,
      1
    )
    XCTAssertEqual(
      firstBucketAvailability.counts(for: .processCPUPercent).presentation,
      .measured
    )
    XCTAssertEqual(
      firstBucketAvailability.counts(for: .deviceGPUUtilization).presentation,
      .invalidSnapshot
    )
  }

  func testLongAdjacentIntervalBreaksEveryMetricAtEquality() throws {
    var bucket = try ViewerPerformanceBucket(
      index: 0,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 3_000_000_001
    )
    var tracker = ViewerPerformanceContinuityTracker()
    let snapshot = try semanticSnapshot(cpu: .numeric(1), interval: 1_000)
    try tracker.consume(
      event: event(sequence: 1, monotonic: 0, wall: 100),
      outcome: .valid(snapshot),
      bucket: &bucket
    )
    try tracker.consume(
      event: event(sequence: 2, monotonic: 3_000_000_000, wall: 101),
      outcome: .valid(snapshot),
      bucket: &bucket
    )
    for metric in ViewerPerformanceNumericMetric.allCases {
      XCTAssertTrue(bucket.numeric.accumulator(for: metric).isDiscontinuous)
    }
  }

  func testUniqueGapPlacementAndIrrelevantPaginationDoNotOverSuppress() throws {
    let index = try wallIndex([
      (monotonic: 0, wall: 100),
      (monotonic: 1, wall: 200),
      (monotonic: 2, wall: 300),
    ])
    var placed = ViewerPerformanceGapProjection(wallIndex: index)
    placed.consume(
      storePage: try gapPage(
        gaps: [try gap(count: 1, lowerWall: 200, upperWall: 200)],
        hasMoreRows: false,
        applicableCount: 1,
        hasMoreApplicable: false
      )
    )
    XCTAssertEqual(placed.placedBucketIndices, [1])
    XCTAssertFalse(placed.hasUnplacedGap)

    var buckets = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 2
    ).makeBuckets()
    try placed.applyDiscontinuities(to: &buckets)
    XCTAssertFalse(buckets[0].numeric.accumulator(for: .cpuPercent).isDiscontinuous)
    XCTAssertTrue(buckets[1].numeric.accumulator(for: .cpuPercent).isDiscontinuous)
    XCTAssertFalse(buckets[2].numeric.accumulator(for: .cpuPercent).isDiscontinuous)

    var irrelevant = ViewerPerformanceGapProjection(wallIndex: index)
    irrelevant.consume(
      storePage: try gapPage(
        gaps: [
          try gap(
            count: 7,
            lowerWall: nil,
            upperWall: nil,
            kind: .unknown,
            applicability: .irrelevant
          )
        ],
        hasMoreRows: true,
        applicableCount: 0,
        hasMoreApplicable: false
      )
    )
    XCTAssertTrue(irrelevant.genericHasMoreRows)
    XCTAssertEqual(irrelevant.irrelevantCount, 7)
    XCTAssertFalse(irrelevant.hasUnplacedGap)
    XCTAssertFalse(irrelevant.suppressesEveryInterbucketConnection)
  }

  func testWallEnvelopeMapsInBucketAndExactEdgeGapsWithoutInterpolation() throws {
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 1_023
    )
    XCTAssertEqual(bounds.bucketWidthNanoseconds, 2)
    var builder = ViewerPerformanceWallEnvelopeBuilder(bounds: bounds)
    try builder.observe(event(sequence: 1, monotonic: 0, wall: 100))
    try builder.observe(event(sequence: 2, monotonic: 1, wall: 110))
    try builder.observe(event(sequence: 3, monotonic: 2, wall: 200))
    try builder.observe(event(sequence: 4, monotonic: 3, wall: 210))

    var projection = ViewerPerformanceGapProjection(wallIndex: builder.makeIndex())
    projection.consume(
      storePage: try gapPage(
        gaps: [
          try gap(count: 1, lowerWall: 105, upperWall: 109),
          try gap(count: 1, lowerWall: 110, upperWall: 110),
          try gap(count: 1, lowerWall: 200, upperWall: 200),
        ],
        hasMoreRows: false,
        applicableCount: 3,
        hasMoreApplicable: false
      )
    )
    XCTAssertEqual(projection.placedBucketIndices, [0, 1])
    XCTAssertEqual(projection.details.gaps.count, 3)
    XCTAssertFalse(projection.hasUnplacedGap)

    var buckets = try bounds.makeBuckets()
    try projection.applyDiscontinuities(to: &buckets)
    for metric in ViewerPerformanceNumericMetric.allCases {
      XCTAssertTrue(buckets[0].numeric.accumulator(for: metric).isDiscontinuous)
      XCTAssertTrue(buckets[1].numeric.accumulator(for: metric).isDiscontinuous)
      XCTAssertFalse(buckets[2].numeric.accumulator(for: metric).isDiscontinuous)
      XCTAssertEqual(buckets[0].numeric.accumulator(for: metric).measurementCount, 0)
      XCTAssertEqual(buckets[1].numeric.accumulator(for: metric).measurementCount, 0)
    }
  }

  func testUnknownIntervalRegressionAmbiguityAndApplicableOverflowAreUnplaced() throws {
    let monotonic = try wallIndex([
      (monotonic: 0, wall: 100),
      (monotonic: 1, wall: 200),
      (monotonic: 2, wall: 300),
    ])
    var unknown = ViewerPerformanceGapProjection(wallIndex: monotonic)
    unknown.consume(
      storePage: try gapPage(
        gaps: [
          try gap(
            count: 1,
            lowerWall: 200,
            upperWall: 200,
            kind: .unknown,
            applicability: .performance
          )
        ],
        hasMoreRows: false,
        applicableCount: 1,
        hasMoreApplicable: false
      )
    )
    XCTAssertTrue(unknown.unplacedReasons.contains(.unknownKind))

    var invalidInterval = ViewerPerformanceGapProjection(wallIndex: monotonic)
    invalidInterval.consume(
      storePage: try gapPage(
        gaps: [try gap(count: 1, lowerWall: 201, upperWall: 200)],
        hasMoreRows: false,
        applicableCount: 1,
        hasMoreApplicable: false
      )
    )
    XCTAssertTrue(invalidInterval.unplacedReasons.contains(.invalidInterval))

    let ambiguousIndex = try wallIndex([
      (monotonic: 0, wall: 100),
      (monotonic: 1, wall: 100),
      (monotonic: 2, wall: 200),
    ])
    var ambiguous = ViewerPerformanceGapProjection(wallIndex: ambiguousIndex)
    ambiguous.consume(
      storePage: try gapPage(
        gaps: [try gap(count: 1, lowerWall: 100, upperWall: 100)],
        hasMoreRows: false,
        applicableCount: 1,
        hasMoreApplicable: false
      )
    )
    XCTAssertTrue(ambiguous.unplacedReasons.contains(.ambiguousOrNonoverlapping))

    let regressedIndex = try wallIndex([
      (monotonic: 0, wall: 200),
      (monotonic: 1, wall: 100),
      (monotonic: 2, wall: 300),
    ])
    var regressed = ViewerPerformanceGapProjection(wallIndex: regressedIndex)
    regressed.consume(
      storePage: try gapPage(
        gaps: [try gap(count: 1, lowerWall: 100, upperWall: 100)],
        hasMoreRows: false,
        applicableCount: 1,
        hasMoreApplicable: false
      )
    )
    XCTAssertTrue(regressed.unplacedReasons.contains(.wallRegression))

    var overflow = ViewerPerformanceGapProjection(wallIndex: monotonic)
    overflow.consume(
      storePage: try gapPage(
        gaps: [],
        hasMoreRows: true,
        applicableCount: 1,
        hasMoreApplicable: true
      )
    )
    XCTAssertTrue(overflow.unplacedReasons.contains(.applicableOverflow))
    XCTAssertTrue(overflow.suppressesEveryInterbucketConnection)
  }

  func testLiveAndCombinedApplicableCountsPreserveUnplacedEvidence() throws {
    let index = try wallIndex([
      (monotonic: 0, wall: 100),
      (monotonic: 1, wall: 200),
      (monotonic: 2, wall: 300),
    ])
    var exact = ViewerPerformanceGapProjection(wallIndex: index)
    exact.consume(
      storePage: try gapPage(
        gaps: [try gap(count: 128, lowerWall: 200, upperWall: 200)],
        hasMoreRows: false,
        applicableCount: 128,
        hasMoreApplicable: false
      )
    )
    XCTAssertEqual(exact.combinedApplicableOrUncertainCount, 128)
    XCTAssertFalse(exact.hasUnplacedGap)

    var combined = ViewerPerformanceGapProjection(wallIndex: index)
    combined.consume(
      storePage: try gapPage(
        gaps: [try gap(count: 64, lowerWall: 200, upperWall: 200)],
        hasMoreRows: false,
        applicableCount: 64,
        hasMoreApplicable: false
      )
    )
    let liveGap = try gap(
      count: 65,
      lowerWall: nil,
      upperWall: nil,
      kind: .eventLoss,
      applicability: .uncertain
    )
    try combined.consume(
      liveSlice: ViewerPerformanceLiveSlice(
        runtimeLogicalID: uuid(1),
        connectionID: uuid(2),
        liveGeneration: 1,
        revision: 1,
        anchorMonotonicNanoseconds: 2,
        events: [],
        gaps: [liveGap],
        applicableOrUncertainCount: 65,
        hasMoreApplicableGaps: false
      )
    )
    XCTAssertEqual(combined.combinedApplicableOrUncertainCount, 129)
    XCTAssertTrue(combined.unplacedReasons.contains(.intervalLess))
    XCTAssertTrue(combined.unplacedReasons.contains(.combinedApplicableOverflow))
  }

  func testStoreLiveAndCombinedGapCountsCrossThe127128129BoundaryExactly() throws {
    let index = try wallIndex([(monotonic: 0, wall: 100)])
    for count in [UInt64(127), 128, 129] {
      var store = ViewerPerformanceGapProjection(wallIndex: index)
      store.consume(
        storePage: try gapPage(
          gaps: [try gap(count: count, lowerWall: 100, upperWall: 100)],
          hasMoreRows: false,
          applicableCount: count,
          hasMoreApplicable: false
        )
      )
      XCTAssertEqual(store.combinedApplicableOrUncertainCount, count)
      XCTAssertEqual(
        store.unplacedReasons.contains(.combinedApplicableOverflow),
        count == 129
      )
      XCTAssertEqual(store.suppressesEveryInterbucketConnection, count == 129)

      var live = ViewerPerformanceGapProjection(wallIndex: index)
      try live.consume(
        liveSlice: ViewerPerformanceLiveSlice(
          runtimeLogicalID: uuid(1),
          connectionID: uuid(2),
          liveGeneration: 1,
          revision: count,
          anchorMonotonicNanoseconds: 0,
          events: [],
          gaps: [try gap(count: count, lowerWall: 100, upperWall: 100)],
          applicableOrUncertainCount: count,
          hasMoreApplicableGaps: false
        )
      )
      XCTAssertEqual(live.combinedApplicableOrUncertainCount, count)
      XCTAssertEqual(
        live.unplacedReasons.contains(.combinedApplicableOverflow),
        count == 129
      )
      XCTAssertEqual(live.suppressesEveryInterbucketConnection, count == 129)
    }

    for liveCount in [UInt64(63), 64, 65] {
      var combined = ViewerPerformanceGapProjection(wallIndex: index)
      combined.consume(
        storePage: try gapPage(
          gaps: [try gap(count: 64, lowerWall: 100, upperWall: 100)],
          hasMoreRows: false,
          applicableCount: 64,
          hasMoreApplicable: false
        )
      )
      try combined.consume(
        liveSlice: ViewerPerformanceLiveSlice(
          runtimeLogicalID: uuid(1),
          connectionID: uuid(2),
          liveGeneration: 1,
          revision: liveCount,
          anchorMonotonicNanoseconds: 0,
          events: [],
          gaps: [try gap(count: liveCount, lowerWall: 100, upperWall: 100)],
          applicableOrUncertainCount: liveCount,
          hasMoreApplicableGaps: false
        )
      )
      let expected = 64 + liveCount
      XCTAssertEqual(combined.combinedApplicableOrUncertainCount, expected)
      XCTAssertEqual(
        combined.unplacedReasons.contains(.combinedApplicableOverflow),
        expected == 129
      )
      XCTAssertEqual(combined.suppressesEveryInterbucketConnection, expected == 129)
    }
  }

  func testDroppedApplicableDetailKeepsItsPlacedBreakAfterIrrelevantStorm() throws {
    let index = try wallIndex([(monotonic: 0, wall: 100)])
    let irrelevant = try gap(
      count: 1,
      lowerWall: nil,
      upperWall: nil,
      kind: .eventLoss,
      applicability: .irrelevant
    )
    var projection = ViewerPerformanceGapProjection(wallIndex: index)
    for _ in 0..<4 {
      projection.consume(
        storePage: try gapPage(
          gaps: Array(repeating: irrelevant, count: 32),
          hasMoreRows: true,
          applicableCount: 1,
          hasMoreApplicable: false
        )
      )
    }
    projection.consume(
      storePage: try gapPage(
        gaps: [try gap(count: 1, lowerWall: 100, upperWall: 100)],
        hasMoreRows: false,
        applicableCount: 1,
        hasMoreApplicable: false
      )
    )
    XCTAssertEqual(projection.details.gaps.count, 128)
    XCTAssertEqual(projection.details.detailLossCount, 1)
    XCTAssertEqual(projection.placedBucketIndices, [0])
    XCTAssertFalse(projection.hasUnplacedGap)

    var buckets = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 0
    ).makeBuckets()
    try projection.applyDiscontinuities(to: &buckets)
    for metric in ViewerPerformanceNumericMetric.allCases {
      XCTAssertTrue(buckets[0].numeric.accumulator(for: metric).isDiscontinuous)
    }
  }

  func testLatestEventCardsApplyFreshnessBeforeTypedStateWithoutFallback() throws {
    let anchor: Int64 = 200_000_000_000
    var selector = try ViewerPerformanceLatestEventSelector(
      deviceStartMonotonicNanoseconds: 0,
      anchorMonotonicNanoseconds: anchor
    )
    try selector.consider(
      event(
        sequence: 1,
        monotonic: anchor - 2_000_000_000,
        wall: 100,
        content: performanceJSON(interval: 1_000, processBody: "\"cpuPercent\":42")
      )
    )
    try selector.consider(
      event(
        sequence: 2,
        monotonic: anchor - 1_000_000_000,
        wall: 101,
        content: performanceJSON(interval: 1_000, processBody: nil)
      )
    )
    let latestMissing = try selector.evaluate(referenceMonotonicNanoseconds: anchor)
    XCTAssertEqual(latestMissing.state(for: .processCPUPercent), .notCollected)
    XCTAssertEqual(latestMissing.latestEventKey?.wireSequence, 2)
    XCTAssertEqual(latestMissing.horizonNanoseconds, 3_000_000_000)
    XCTAssertTrue(latestMissing.shouldArmDeadline)

    var invalid = try ViewerPerformanceLatestEventSelector(
      deviceStartMonotonicNanoseconds: 0,
      anchorMonotonicNanoseconds: anchor
    )
    try invalid.consider(
      event(
        sequence: 3,
        monotonic: anchor - 3_000_000_000,
        wall: 102,
        content: Data("{".utf8)
      )
    )
    let staleInvalid = try invalid.evaluate(referenceMonotonicNanoseconds: anchor)
    XCTAssertEqual(staleInvalid.state(for: .processCPUPercent), .noRecentSample)
    XCTAssertEqual(staleInvalid.horizonNanoseconds, 3_000_000_000)
    XCTAssertEqual(staleInvalid.freshnessDeadlineMonotonicNanoseconds, anchor)
    XCTAssertFalse(staleInvalid.shouldArmDeadline)

    var freshInvalid = try ViewerPerformanceLatestEventSelector(
      deviceStartMonotonicNanoseconds: 0,
      anchorMonotonicNanoseconds: anchor
    )
    try freshInvalid.consider(
      event(
        sequence: 4,
        monotonic: anchor - 2_000_000_000,
        wall: 103,
        content: Data("{".utf8)
      )
    )
    XCTAssertEqual(
      try freshInvalid.evaluate(referenceMonotonicNanoseconds: anchor)
        .state(for: .processCPUPercent),
      .invalidSnapshot(.malformedJSON)
    )
  }

  func testLatestCardsUseTheFullLookbackIndependentOfChartRangeAndPreservePrecedence()
    throws
  {
    let anchor: Int64 = 200_000_000_000
    var empty = try ViewerPerformanceLatestEventSelector(
      deviceStartMonotonicNanoseconds: 0,
      anchorMonotonicNanoseconds: anchor
    )
    let noSnapshot = try empty.evaluate(referenceMonotonicNanoseconds: anchor)
    XCTAssertNil(noSnapshot.latestEventKey)
    XCTAssertNil(noSnapshot.freshnessDeadlineMonotonicNanoseconds)
    XCTAssertEqual(noSnapshot.state(for: .processCPUPercent), .noRecentSample)

    let oneMinute = try ViewerPerformanceRangeBounds.fixed(
      deviceStartMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: anchor,
      durationNanoseconds: 60_000_000_000
    )
    let outsideChartTime = oneMinute.lowerMonotonicNanoseconds - 1
    XCTAssertEqual(empty.lookbackLowerMonotonicNanoseconds, 20_000_000_000)
    XCTAssertLessThan(outsideChartTime, oneMinute.lowerMonotonicNanoseconds)
    try empty.consider(
      event(
        sequence: 1,
        monotonic: outsideChartTime,
        wall: 100,
        content: performanceJSON(interval: 60_000, processBody: "\"cpuPercent\":7")
      )
    )
    let outsideRangeButFresh = try empty.evaluate(referenceMonotonicNanoseconds: anchor)
    XCTAssertEqual(outsideRangeButFresh.latestEventKey?.wireSequence, 1)
    XCTAssertEqual(
      outsideRangeButFresh.state(for: .processCPUPercent),
      .measured(.numeric(7))
    )

    var unavailable = try ViewerPerformanceLatestEventSelector(
      deviceStartMonotonicNanoseconds: 0,
      anchorMonotonicNanoseconds: anchor
    )
    try unavailable.consider(
      event(
        sequence: 2,
        monotonic: anchor - 2_000_000_000,
        wall: 101,
        content: performanceJSON(interval: 1_000, processBody: "\"cpuPercent\":42")
      )
    )
    try unavailable.consider(
      event(
        sequence: 3,
        monotonic: anchor - 1_000_000_000,
        wall: 102,
        content: Data(
          "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\"unavailable\":[{\"metric\":\"process.cpuPercent\",\"reason\":\"permissionDenied\"}]}"
            .utf8
        )
      )
    )
    let freshUnavailable = try unavailable.evaluate(referenceMonotonicNanoseconds: anchor)
    XCTAssertEqual(freshUnavailable.latestEventKey?.wireSequence, 3)
    XCTAssertEqual(
      freshUnavailable.state(for: .processCPUPercent),
      .unavailable(.permissionDenied)
    )

    var staleUnavailable = try ViewerPerformanceLatestEventSelector(
      deviceStartMonotonicNanoseconds: 0,
      anchorMonotonicNanoseconds: anchor
    )
    try staleUnavailable.consider(
      event(
        sequence: 4,
        monotonic: anchor - 3_000_000_000,
        wall: 103,
        content: Data(
          "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\"unavailable\":[{\"metric\":\"process.cpuPercent\",\"reason\":\"disabled\"}]}"
            .utf8
        )
      )
    )
    let stale = try staleUnavailable.evaluate(referenceMonotonicNanoseconds: anchor)
    XCTAssertEqual(stale.state(for: .processCPUPercent), .noRecentSample)
    XCTAssertFalse(stale.shouldArmDeadline)
  }

  func testFreshnessFormulaCovers100MillisecondsThrough60SecondsAndExactEquality() throws {
    let cases: [(milliseconds: UInt64, horizon: UInt64)] = [
      (100, 3_000_000_000),
      (999, 3_000_000_000),
      (1_000, 3_000_000_000),
      (1_001, 3_003_000_000),
      (10_000, 30_000_000_000),
      (59_999, 179_997_000_000),
      (60_000, 180_000_000_000),
    ]
    for item in cases {
      XCTAssertEqual(
        ViewerPerformanceFreshness.horizonNanoseconds(
          sampleIntervalMilliseconds: item.milliseconds
        ),
        item.horizon
      )
      XCTAssertTrue(
        try ViewerPerformanceFreshness.isFresh(
          eventMonotonicNanoseconds: 0,
          referenceMonotonicNanoseconds: Int64(item.horizon - 1),
          horizonNanoseconds: item.horizon
        )
      )
      XCTAssertFalse(
        try ViewerPerformanceFreshness.isFresh(
          eventMonotonicNanoseconds: 0,
          referenceMonotonicNanoseconds: Int64(item.horizon),
          horizonNanoseconds: item.horizon
        )
      )
    }
    XCTAssertEqual(
      ViewerPerformanceFreshness.adjacencyHorizonNanoseconds(
        previousIntervalMilliseconds: 100,
        currentIntervalMilliseconds: 60_000
      ),
      180_000_000_000
    )
  }

  func testCheckedLookbackAndMaximumHorizonHandleUInt64Maximum() throws {
    XCTAssertEqual(
      ViewerPerformanceFreshness.horizonNanoseconds(sampleIntervalMilliseconds: nil),
      3_000_000_000
    )
    XCTAssertEqual(
      ViewerPerformanceFreshness.horizonNanoseconds(sampleIntervalMilliseconds: 2_000),
      6_000_000_000
    )
    XCTAssertEqual(
      ViewerPerformanceFreshness.horizonNanoseconds(
        sampleIntervalMilliseconds: UInt64.max),
      180_000_000_000
    )

    let anchor: Int64 = 200_000_000_000
    var exactBoundary = try ViewerPerformanceLatestEventSelector(
      deviceStartMonotonicNanoseconds: 0,
      anchorMonotonicNanoseconds: anchor
    )
    try exactBoundary.consider(
      event(
        sequence: 1,
        monotonic: anchor - 180_000_000_000,
        wall: 100,
        content: performanceJSON(interval: 100_000, processBody: "\"cpuPercent\":1")
      )
    )
    let equality = try exactBoundary.evaluate(referenceMonotonicNanoseconds: anchor)
    XCTAssertEqual(equality.latestEventKey?.wireSequence, 1)
    XCTAssertEqual(equality.state(for: .processCPUPercent), .noRecentSample)

    var outside = try ViewerPerformanceLatestEventSelector(
      deviceStartMonotonicNanoseconds: 0,
      anchorMonotonicNanoseconds: anchor
    )
    try outside.consider(
      event(
        sequence: 2,
        monotonic: anchor - 180_000_000_001,
        wall: 99,
        content: performanceJSON(interval: 100_000, processBody: "\"cpuPercent\":2")
      )
    )
    let noRecent = try outside.evaluate(referenceMonotonicNanoseconds: anchor)
    XCTAssertNil(noRecent.latestEventKey)
    XCTAssertEqual(noRecent.state(for: .processCPUPercent), .noRecentSample)
    XCTAssertFalse(String(reflecting: outside).contains("cpuPercent"))
  }

  private func semanticSnapshot(
    cpu: ViewerPerformanceMetricState,
    interval: UInt64 = 1_000
  ) throws -> ViewerDecodedPerformanceSnapshot {
    let states = PerformanceMetricKey.allCases.map { key -> ViewerPerformanceMetricState in
      switch key {
      case .processCPUPercent: return cpu
      case .processMemoryFootprintBytes: return .unsigned(1)
      case .displayEstimatedFramesPerSecond, .displayMaximumFramesPerSecond,
        .deviceBatteryLevel:
        return .numeric(1)
      case .deviceBatteryState: return .batteryState(.unknown)
      case .deviceThermalState: return .thermalState(.unknown)
      case .deviceLowPowerModeEnabled: return .boolean(false)
      case .transportUplinkQueueDepth, .transportDroppedEventCount,
        .transportUplinkBytesPerSecond, .transportDownlinkBytesPerSecond,
        .transportDownlinkQueueDepth:
        return .unsigned(1)
      case .deviceGPUUtilization, .devicePowerWatts, .deviceTemperatureCelsius:
        return .unavailable(.unsupported)
      }
    }
    return try ViewerDecodedPerformanceSnapshot(
      sampledAt: Date(timeIntervalSince1970: 1),
      sampleIntervalMilliseconds: interval,
      states: states
    )
  }

  private func wallIndex(
    _ samples: [(monotonic: Int64, wall: Int64)]
  ) throws -> ViewerPerformanceWallEnvelopeIndex {
    let upper = try XCTUnwrap(samples.map(\.monotonic).max())
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: upper
    )
    var builder = ViewerPerformanceWallEnvelopeBuilder(bounds: bounds)
    for (offset, sample) in samples.enumerated() {
      try builder.observe(
        event(
          sequence: UInt64(offset + 1),
          monotonic: sample.monotonic,
          wall: sample.wall
        )
      )
    }
    return builder.makeIndex()
  }

  private func gapPage(
    gaps: [ViewerPerformanceGapCarrier],
    hasMoreRows: Bool,
    applicableCount: UInt64,
    hasMoreApplicable: Bool
  ) throws -> ViewerPerformanceGapPage {
    try ViewerPerformanceGapPage(
      gaps: gaps,
      hasMoreRows: hasMoreRows,
      applicableOrUncertainCount: applicableCount,
      hasMoreApplicableGaps: hasMoreApplicable
    )
  }

  private func gap(
    count: UInt64,
    lowerWall: Int64?,
    upperWall: Int64?,
    kind: ViewerPerformanceGapKind = .eventLoss,
    applicability: ViewerPerformanceGapApplicability = .performance
  ) throws -> ViewerPerformanceGapCarrier {
    try ViewerPerformanceGapCarrier(
      rowID: nil,
      recordingID: nil,
      deviceSessionID: nil,
      count: count,
      firstViewerWallMilliseconds: lowerWall,
      lastViewerWallMilliseconds: upperWall,
      kind: kind,
      applicability: applicability
    )
  }

  private func event(
    sequence: UInt64,
    monotonic: Int64,
    wall: Int64,
    content: Data = Data("{}".utf8)
  ) throws -> ViewerPerformanceEventCarrier {
    try ViewerPerformanceEventCarrier(
      locator: .transient(observationID: UUID()),
      key: ViewerEventJournalKey(
        runtimeLogicalID: uuid(1),
        connectionID: uuid(2),
        direction: .appToViewer,
        wireSequence: sequence
      ),
      viewerWallMilliseconds: wall,
      viewerMonotonicNanoseconds: monotonic,
      content: .canonical(content)
    )
  }

  private func performanceJSON(
    interval: UInt64,
    processBody: String?
  ) -> Data {
    let process = processBody.map { ",\"process\":{\($0)}" } ?? ""
    return Data(
      "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":\(interval)\(process)}"
        .utf8
    )
  }

  private func uuid(_ suffix: UInt8) -> UUID {
    UUID(
      uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, suffix
      )
    )
  }
}

final class ViewerPerformancePipelineTests: XCTestCase {
  func testCompleteProjectionReconcilesLiveDuplicateAndDecodesAtMost64EventsPerTurn()
    throws
  {
    let source = currentSource()
    let scope = try storeScope(upper: 200)
    let storeEvents = try (1...129).map { value in
      try event(
        source: source,
        sequence: UInt64(value),
        monotonic: Int64(value),
        durableRowID: Int64(value)
      )
    }
    let duplicate = try event(source: source, sequence: 129, monotonic: 129)
    let receipt = try currentReceipt(
      source: source,
      anchor: 200,
      storeScope: scope,
      liveEvents: [duplicate]
    )
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 1,
      upperMonotonicNanoseconds: 200
    )
    var session = try ViewerPerformanceProjectionSession(
      receipt: receipt,
      rangeKind: .currentSession,
      bounds: bounds,
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: 1
    )

    XCTAssertTrue(session.needsEventPage)
    XCTAssertEqual(
      try session.activeAccountedBytes,
      try ViewerPerformanceAccounting.activeReducerBytes(
        bucketCount: bounds.bucketCount,
        detailedGapCount: 0,
        invalidDetailCount: 0
      )
    )
    try session.accept(
      eventPage:
        eventPage(scope: scope, events: storeEvents, isComplete: true)
    )
    XCTAssertEqual(session.retainedRawEventCount, 130)
    XCTAssertEqual(try session.runDecodeTurn(), .processed(64))
    XCTAssertEqual(try session.runDecodeTurn(), .processed(64))
    XCTAssertEqual(try session.runDecodeTurn(), .processed(1))
    XCTAssertEqual(try session.runDecodeTurn(), .eventsComplete)
    XCTAssertTrue(session.needsGapPage)
    try session.accept(gapPage: gapPage())

    let publication = try session.finalize(
      sourceGeneration: 1,
      deadlineRevision: 1,
      currentUptimeNanoseconds: 200
    )
    XCTAssertEqual(publication.coverage, .completeRange)
    XCTAssertEqual(try session.activeAccountedBytes, publication.result.accountedBytes)
    XCTAssertEqual(publication.decodedEventCount, 129)
    XCTAssertEqual(publication.decodeTurnCount, 3)
    XCTAssertEqual(publication.cards.latestEventKey?.wireSequence, 129)
    XCTAssertEqual(
      publication.cards.state(for: .processCPUPercent),
      .measured(.numeric(42))
    )
    XCTAssertEqual(
      publication.result.availability.first(where: { $0.key == .processCPUPercent })?.counts
        .measured,
      129
    )
  }

  func testLiveOnlyProjectionLabelsCoverageAndBreaksUnknownLeadingHistory() throws {
    let source = currentSource()
    let receipt = try currentReceipt(
      source: source,
      anchor: 200,
      storeScope: nil,
      liveEvents: [try event(source: source, sequence: 1, monotonic: 200)]
    )
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 200
    )
    var session = try ViewerPerformanceProjectionSession(
      receipt: receipt,
      rangeKind: .currentSession,
      bounds: bounds,
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: 1
    )

    XCTAssertFalse(session.needsEventPage)
    XCTAssertEqual(try session.runDecodeTurn(), .processed(1))
    XCTAssertEqual(try session.runDecodeTurn(), .eventsComplete)
    let publication = try session.finalize(
      sourceGeneration: 1,
      deadlineRevision: 1,
      currentUptimeNanoseconds: 200
    )

    XCTAssertEqual(publication.coverage, .liveWindowOnly)
    XCTAssertTrue(
      publication.result.buckets[0].numeric.accumulator(for: .cpuPercent).isDiscontinuous
    )
    XCTAssertEqual(publication.cards.state(for: .processCPUPercent), .measured(.numeric(42)))
  }

  func testHistoricalProjectionUsesFrozenRecordingUpperAndRequiresNoCurrentClock() throws {
    let source = try historicalSource()
    let scope = try storeScope(upper: 100)
    let receipt = ViewerPerformanceFrozenReceipt(
      source: source,
      storeScope: scope,
      liveSlice: nil
    )
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 100
    )
    var session = try ViewerPerformanceProjectionSession(
      receipt: receipt,
      rangeKind: .currentSession,
      bounds: bounds,
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: 7
    )
    try session.accept(
      eventPage:
        eventPage(
          scope: scope,
          events: [try event(source: source, sequence: 1, monotonic: 99, durableRowID: 1)],
          isComplete: true
        )
    )
    XCTAssertEqual(try session.runDecodeTurn(), .processed(1))
    XCTAssertEqual(try session.runDecodeTurn(), .eventsComplete)
    try session.accept(gapPage: gapPage())

    let publication = try session.finalize(
      sourceGeneration: 7,
      deadlineRevision: 1,
      currentUptimeNanoseconds: nil
    )
    XCTAssertTrue(publication.cards.isFresh)
    XCTAssertEqual(publication.cards.state(for: .processCPUPercent), .measured(.numeric(42)))
    for simulatedCurrentUptime in [Int64(1), 99, 100, 101, Int64.max] {
      XCTAssertEqual(
        try publication.validatingCurrentFreshness(
          currentUptimeNanoseconds: simulatedCurrentUptime
        ),
        publication
      )
    }
    guard case .historical(let freshness) = publication.freshnessReceipt else {
      return XCTFail("Expected historical freshness")
    }
    XCTAssertEqual(freshness.source, source)
    XCTAssertEqual(freshness.frozenUpperMonotonicNanoseconds, 100)
  }

  func testIncompleteProjectionCannotPublishAndFailurePolicyStartsFreshState() throws {
    let source = currentSource()
    let scope = try storeScope(upper: 200)
    let receipt = try currentReceipt(
      source: source,
      anchor: 200,
      storeScope: scope,
      liveEvents: []
    )
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 200
    )
    var partial = try ViewerPerformanceProjectionSession(
      receipt: receipt,
      rangeKind: .currentSession,
      bounds: bounds,
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: 1
    )
    let continuation = ViewerPerformanceContinuation(
      scope: scope,
      lastExaminedMonotonicNanoseconds: 50,
      lastExaminedRowID: 1
    )
    try partial.accept(
      eventPage:
        ViewerPerformanceEventPage(
          scope: scope,
          events: [try event(source: source, sequence: 1, monotonic: 50, durableRowID: 1)],
          examinedCandidateCount: 1,
          continuation: continuation,
          isComplete: false
        )
    )
    XCTAssertEqual(try partial.runDecodeTurn(), .processed(1))
    XCTAssertThrowsError(
      try partial.finalize(
        sourceGeneration: 1,
        deadlineRevision: 1,
        currentUptimeNanoseconds: 200
      )
    )
    XCTAssertEqual(
      ViewerPerformanceStoreFailurePolicy.resolution(for: source, failure: .unavailable),
      .restartWithFreshLiveOnlyFreeze
    )
    XCTAssertEqual(
      ViewerPerformanceStoreFailurePolicy.resolution(
        for: try historicalSource(),
        failure: .unavailable
      ),
      .publishStorageUnavailable
    )
    XCTAssertEqual(
      ViewerPerformanceStoreFailurePolicy.resolution(for: source, failure: .busy),
      .discard
    )

    let freshReceipt = try currentReceipt(
      source: source,
      anchor: 200,
      storeScope: nil,
      liveEvents: [try event(source: source, sequence: 2, monotonic: 200)]
    )
    var recovery = try ViewerPerformanceProjectionSession(
      receipt: freshReceipt,
      rangeKind: .currentSession,
      bounds: bounds,
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: 2
    )
    XCTAssertEqual(try recovery.runDecodeTurn(), .processed(1))
    XCTAssertEqual(try recovery.runDecodeTurn(), .eventsComplete)
    let recovered = try recovery.finalize(
      sourceGeneration: 2,
      deadlineRevision: 2,
      currentUptimeNanoseconds: 200
    )
    XCTAssertEqual(recovered.coverage, .liveWindowOnly)
    XCTAssertEqual(recovered.decodedEventCount, 1)
    XCTAssertEqual(recovered.cards.latestEventKey?.wireSequence, 2)
  }

  func testRefreshAdmissionRetainsOneLatestSuccessorAcross100000Submissions() throws {
    let source = currentSource()
    let admission = ViewerPerformanceRefreshAdmission(sourceGeneration: 1)
    let first = try refreshToken(source: source, generation: 1, sequence: 1)
    XCTAssertEqual(admission.submit(first), .start(first))
    var last = first
    for sequence in 2...100_000 {
      last = try refreshToken(source: source, generation: 1, sequence: UInt64(sequence))
      XCTAssertEqual(admission.submit(last), .retainedDirty)
    }
    XCTAssertEqual(admission.runningCount, 1)
    XCTAssertEqual(admission.dirtyCount, 1)

    let firstCompletion = admission.complete(first)
    XCTAssertTrue(firstCompletion.publishesCompletedResult)
    XCTAssertEqual(firstCompletion.successorToStart, last)
    XCTAssertEqual(admission.runningCount, 1)
    XCTAssertEqual(admission.dirtyCount, 0)

    let finalCompletion = admission.complete(last)
    XCTAssertTrue(finalCompletion.publishesCompletedResult)
    XCTAssertNil(finalCompletion.successorToStart)
    XCTAssertEqual(admission.runningCount, 0)
  }

  func testPauseRangeAndSourceReplacementKeepOnlyLatestEligibleRefresh() throws {
    let source = currentSource()
    let admission = ViewerPerformanceRefreshAdmission(sourceGeneration: 1)
    let oldRunning = try refreshToken(source: source, generation: 1, sequence: 1)
    XCTAssertEqual(admission.submit(oldRunning), .start(oldRunning))
    admission.pause()
    let invalidated = admission.replaceSourceGeneration(2)
    XCTAssertEqual(invalidated, oldRunning)
    XCTAssertEqual(admission.runningCount, 0)
    XCTAssertEqual(admission.dirtyCount, 0)

    let firstRange = try refreshToken(
      source: source,
      generation: 2,
      sequence: 2,
      rangeKind: .oneMinute
    )
    let desiredRange = try refreshToken(
      source: source,
      generation: 2,
      sequence: 3,
      rangeKind: .fifteenMinutes
    )
    XCTAssertEqual(admission.submit(firstRange), .retainedDirty)
    XCTAssertEqual(admission.submit(desiredRange), .retainedDirty)
    XCTAssertEqual(admission.dirtyCount, 1)
    XCTAssertEqual(admission.resume(), desiredRange)
    XCTAssertFalse(admission.complete(oldRunning).publishesCompletedResult)
    XCTAssertTrue(admission.complete(desiredRange).publishesCompletedResult)
  }

  func testLatestDeliveryPumpCoalesces100000ValuesAndEnforces100Milliseconds() {
    let scheduler = ManualLiveRefreshScheduler()
    let delivered = LockedUInt64Collection()
    let pump = ViewerPerformanceLatestDeliveryPump<UInt64>(scheduler: scheduler.value) {
      delivered.append($0)
    }
    XCTAssertTrue(Mirror(reflecting: pump).children.isEmpty)

    for value in 0..<100_000 { XCTAssertTrue(pump.submit(UInt64(value))) }
    XCTAssertEqual(pump.retainedValueCount, 1)
    XCTAssertEqual(pump.pendingWorkCount, 1)
    XCTAssertEqual(pump.scheduleCount, 1)
    XCTAssertEqual(scheduler.pendingCount, 1)
    XCTAssertEqual(scheduler.nextDelay, 0)
    scheduler.runNext()
    XCTAssertEqual(delivered.values, [99_999])
    XCTAssertEqual(pump.deliveryCount, 1)
    XCTAssertEqual(pump.retainedValueCount, 0)

    XCTAssertTrue(pump.submit(100_000))
    XCTAssertEqual(scheduler.nextDelay, 100_000_000)
    scheduler.runNext()
    XCTAssertEqual(delivered.values, [99_999, 100_000])
    XCTAssertEqual(pump.deliveryCount, 2)
    XCTAssertEqual(pump.pendingWorkCount, 0)
    pump.seal()
    XCTAssertFalse(pump.submit(100_001))
  }

  func testDeliveryGateRestatesCardsAtApplyEqualityAndRejectsStaleReceipts() throws {
    let publication = try currentPublication()
    let deadline = try XCTUnwrap(
      publication.cards.freshnessDeadlineMonotonicNanoseconds
    )
    let gate = ViewerPerformanceDeliveryGate()
    gate.install(publication.freshnessReceipt)
    XCTAssertThrowsError(
      try gate.claim(publication, currentUptimeNanoseconds: nil)
    )
    let claim = try XCTUnwrap(
      gate.claim(publication, currentUptimeNanoseconds: deadline - 1)
    )
    XCTAssertTrue(Mirror(reflecting: claim).children.isEmpty)
    let applied = try XCTUnwrap(
      gate.apply(claim, currentUptimeNanoseconds: deadline)
    )
    XCTAssertEqual(applied.cards.state(for: .processCPUPercent), .noRecentSample)
    XCTAssertFalse(applied.cards.isFresh)
    XCTAssertFalse(applied.cards.shouldArmDeadline)

    let lateDuplicate = try XCTUnwrap(
      gate.claim(publication, currentUptimeNanoseconds: deadline + 1)
    )
    let lateApplied = try XCTUnwrap(
      gate.apply(lateDuplicate, currentUptimeNanoseconds: deadline + 1)
    )
    XCTAssertEqual(lateApplied.cards.state(for: .processCPUPercent), .noRecentSample)
    XCTAssertFalse(lateApplied.cards.isFresh)
    XCTAssertFalse(lateApplied.cards.shouldArmDeadline)

    let replacement = try ViewerPerformanceCurrentFreshnessReceipt(
      sourceGeneration: 2,
      latestEventKey: publication.cards.latestEventKey,
      absoluteDeadlineMonotonicNanoseconds: deadline,
      deadlineRevision: 2
    )
    gate.install(.current(replacement))
    XCTAssertNil(try gate.claim(publication, currentUptimeNanoseconds: deadline))
    gate.invalidate()
    XCTAssertNil(try gate.claim(publication, currentUptimeNanoseconds: deadline))
  }

  func testFreshnessDeadlineOwnsOneFutureWakeAndHistoricalOwnsZero() async throws {
    let scheduler = ManualPerformanceDeadlineScheduler(now: 0)
    let owner = ViewerPerformanceFreshnessDeadlineOwner(scheduler: scheduler.value)
    let fired = LockedUInt64Collection()
    let first = try currentFreshness(generation: 1, sequence: 1, deadline: 100, revision: 1)
    let replacement = try currentFreshness(
      generation: 1,
      sequence: 2,
      deadline: 200,
      revision: 2
    )
    XCTAssertTrue(owner.arm(receipt: .current(first)) { fired.append($0.deadlineRevision) })
    XCTAssertTrue(
      owner.arm(receipt: .current(replacement)) { fired.append($0.deadlineRevision) }
    )
    XCTAssertEqual(owner.activeWakeCount, 1)
    XCTAssertEqual(owner.scheduleCount, 2)
    XCTAssertEqual(scheduler.pendingCount, 1)
    scheduler.runNext()
    XCTAssertEqual(fired.values, [2])
    XCTAssertEqual(owner.fireCount, 1)
    XCTAssertEqual(owner.activeWakeCount, 0)

    let historicalSource = try historicalSource()
    let historical = try ViewerPerformanceHistoricalFreshnessReceipt(
      sourceGeneration: 2,
      source: historicalSource,
      frozenUpperMonotonicNanoseconds: 1_000
    )
    XCTAssertFalse(
      owner.arm(receipt: .historical(historical)) { _ in
        XCTFail("Historical freshness must not schedule")
      })
    XCTAssertEqual(owner.scheduleCount, 2)
    XCTAssertEqual(owner.activeWakeCount, 0)

    let stressScheduler = ManualPerformanceDeadlineScheduler(now: 0)
    let stressOwner = ViewerPerformanceFreshnessDeadlineOwner(scheduler: stressScheduler.value)
    for revision in 1...1_800 {
      let receipt = try currentFreshness(
        generation: 1,
        sequence: UInt64(revision),
        deadline: Int64(10_000 + revision),
        revision: UInt64(revision)
      )
      XCTAssertTrue(stressOwner.arm(receipt: .current(receipt)) { _ in })
    }
    XCTAssertEqual(stressOwner.activeWakeCount, 1)
    XCTAssertEqual(stressScheduler.pendingCount, 1)
    XCTAssertEqual(stressScheduler.physicalWorkerCount, 1)
    await stressOwner.invalidateAndWait().value
    XCTAssertEqual(stressOwner.activeWakeCount, 0)
    XCTAssertEqual(stressScheduler.pendingCount, 0)
    XCTAssertEqual(stressScheduler.physicalWorkerCount, 0)
  }

  func testFreshnessDeadlineUsesOneCooperativeWorkerAndJoinsItsPhysicalCancellation()
    async throws
  {
    let scheduler = CooperativePerformanceDeadlineScheduler(now: 0)
    let owner = ViewerPerformanceFreshnessDeadlineOwner(scheduler: scheduler.value)
    for revision in 1...1_800 {
      let receipt = try currentFreshness(
        generation: 1,
        sequence: UInt64(revision),
        deadline: Int64(10_000 + revision),
        revision: UInt64(revision)
      )
      XCTAssertTrue(owner.arm(receipt: .current(receipt)) { _ in })
    }

    XCTAssertEqual(owner.activeWakeCount, 1)
    XCTAssertEqual(scheduler.pendingCount, 1)
    XCTAssertEqual(scheduler.physicalWorkerCount, 1)
    XCTAssertEqual(scheduler.createdWorkerCount, 1)

    let cleanup = owner.invalidateAndWait()
    let cleanupFinished = LockedTestCounter()
    let observer = Task {
      await cleanup.value
      cleanupFinished.increment()
    }
    await Task.yield()
    XCTAssertEqual(cleanupFinished.value, 0)
    XCTAssertEqual(owner.activeWakeCount, 0)
    XCTAssertEqual(scheduler.pendingCount, 0)
    XCTAssertEqual(scheduler.physicalWorkerCount, 1)

    scheduler.drainAll()
    await observer.value
    XCTAssertEqual(cleanupFinished.value, 1)
    XCTAssertEqual(scheduler.pendingCount, 0)
    XCTAssertEqual(scheduler.physicalWorkerCount, 0)
    XCTAssertEqual(scheduler.createdWorkerCount, 1)
  }

  func testFreshnessDeadlineCleanupOwnsWorkerWithoutRetainingDroppedOwner() async throws {
    let scheduler = CooperativePerformanceDeadlineScheduler(now: 0)
    var owner: ViewerPerformanceFreshnessDeadlineOwner? =
      ViewerPerformanceFreshnessDeadlineOwner(scheduler: scheduler.value)
    let receipt = try currentFreshness(
      generation: 1,
      sequence: 1,
      deadline: 10_000,
      revision: 1
    )
    XCTAssertTrue(owner?.arm(receipt: .current(receipt)) { _ in } ?? false)
    let cleanup = try XCTUnwrap(owner).invalidateAndWait()
    weak let retainedOwner = owner
    owner = nil

    await Task.yield()
    XCTAssertNil(retainedOwner)
    XCTAssertEqual(scheduler.physicalWorkerCount, 1)
    scheduler.drainAll()
    await cleanup.value
    XCTAssertEqual(scheduler.physicalWorkerCount, 0)
  }

  func testFreshnessDeadlineEqualityDoesNotArmAndPauseRetainsOneExpiryBit() throws {
    let equalityScheduler = ManualPerformanceDeadlineScheduler(now: 100)
    let equalityOwner = ViewerPerformanceFreshnessDeadlineOwner(
      scheduler: equalityScheduler.value
    )
    let equality = try currentFreshness(
      generation: 1,
      sequence: 1,
      deadline: 100,
      revision: 1
    )
    XCTAssertFalse(
      equalityOwner.arm(receipt: .current(equality)) { _ in
        XCTFail("Elapsed deadlines must not fire")
      })
    XCTAssertEqual(equalityScheduler.pendingCount, 0)

    let scheduler = ManualPerformanceDeadlineScheduler(now: 0)
    let owner = ViewerPerformanceFreshnessDeadlineOwner(scheduler: scheduler.value)
    let fired = LockedUInt64Collection()
    let future = try currentFreshness(
      generation: 1,
      sequence: 2,
      deadline: 100,
      revision: 2
    )
    XCTAssertTrue(owner.arm(receipt: .current(future)) { fired.append($0.deadlineRevision) })
    owner.setPaused(true)
    scheduler.runNext()
    XCTAssertEqual(fired.values, [])
    XCTAssertEqual(owner.fireCount, 1)
    XCTAssertTrue(owner.resumeConsumesDirtyExpiry())
    XCTAssertFalse(owner.resumeConsumesDirtyExpiry())
  }

  private func currentPublication() throws -> ViewerPerformanceProjectionPublication {
    let source = currentSource()
    let receipt = try currentReceipt(
      source: source,
      anchor: 10,
      storeScope: nil,
      liveEvents: [try event(source: source, sequence: 1, monotonic: 10)]
    )
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 10
    )
    var session = try ViewerPerformanceProjectionSession(
      receipt: receipt,
      rangeKind: .currentSession,
      bounds: bounds,
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: 1
    )
    XCTAssertEqual(try session.runDecodeTurn(), .processed(1))
    XCTAssertEqual(try session.runDecodeTurn(), .eventsComplete)
    return try session.finalize(
      sourceGeneration: 1,
      deadlineRevision: 1,
      currentUptimeNanoseconds: 10
    )
  }

  private func currentReceipt(
    source: ViewerPerformanceSource,
    anchor: UInt64,
    storeScope: ViewerPerformanceStoreScope?,
    liveEvents: [ViewerPerformanceEventCarrier]
  ) throws -> ViewerPerformanceFrozenReceipt {
    guard case .current(let runtimeLogicalID, let connectionID) = source else {
      throw ViewerPerformanceStoreFailure.invalidScope
    }
    return ViewerPerformanceFrozenReceipt(
      source: source,
      storeScope: storeScope,
      liveSlice: try ViewerPerformanceLiveSlice(
        runtimeLogicalID: runtimeLogicalID,
        connectionID: connectionID,
        liveGeneration: 1,
        revision: 1,
        anchorMonotonicNanoseconds: anchor,
        events: liveEvents,
        gaps: [],
        applicableOrUncertainCount: 0,
        hasMoreApplicableGaps: false
      )
    )
  }

  private func eventPage(
    scope: ViewerPerformanceStoreScope,
    events: [ViewerPerformanceEventCarrier],
    isComplete: Bool
  ) throws -> ViewerPerformanceEventPage {
    try ViewerPerformanceEventPage(
      scope: scope,
      events: events,
      examinedCandidateCount: events.count,
      continuation: isComplete
        ? nil
        : ViewerPerformanceContinuation(
          scope: scope,
          lastExaminedMonotonicNanoseconds: events.last?.viewerMonotonicNanoseconds,
          lastExaminedRowID: events.last.flatMap {
            guard case .durable(let rowID, _) = $0.locator else { return nil }
            return rowID
          }
        ),
      isComplete: isComplete
    )
  }

  private func gapPage() throws -> ViewerPerformanceGapPage {
    try ViewerPerformanceGapPage(
      gaps: [],
      hasMoreRows: false,
      applicableOrUncertainCount: 0,
      hasMoreApplicableGaps: false
    )
  }

  private func storeScope(upper: Int64) throws -> ViewerPerformanceStoreScope {
    try ViewerPerformanceStoreScope(
      storeGeneration: 1,
      recordingID: 11,
      deviceSessionID: 12,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: upper,
      eventUpperRowID: 1_000,
      gapUpperRowID: 1_000
    )
  }

  private func event(
    source: ViewerPerformanceSource,
    sequence: UInt64,
    monotonic: Int64,
    durableRowID: Int64? = nil
  ) throws -> ViewerPerformanceEventCarrier {
    let runtimeLogicalID: UUID
    let connectionID: UUID
    switch source {
    case .current(let runtime, let connection):
      runtimeLogicalID = runtime
      connectionID = connection
    case .historical(_, _, let recording, let device):
      runtimeLogicalID = recording
      connectionID = device
    }
    let locator: ViewerPerformanceEventLocator =
      if let durableRowID {
        .durable(rowID: durableRowID, deviceSessionID: 12)
      } else {
        .transient(observationID: uuid(UInt8(truncatingIfNeeded: sequence + 32)))
      }
    return try ViewerPerformanceEventCarrier(
      locator: locator,
      key: ViewerEventJournalKey(
        runtimeLogicalID: runtimeLogicalID,
        connectionID: connectionID,
        direction: .appToViewer,
        wireSequence: sequence
      ),
      viewerWallMilliseconds: 1_000 + monotonic,
      viewerMonotonicNanoseconds: monotonic,
      content: .canonical(performanceJSON())
    )
  }

  private func refreshToken(
    source: ViewerPerformanceSource,
    generation: UInt64,
    sequence: UInt64,
    rangeKind: ViewerPerformanceRangeKind = .fiveMinutes
  ) throws -> ViewerPerformanceRefreshToken {
    try ViewerPerformanceRefreshToken(
      sourceGeneration: generation,
      sequence: sequence,
      source: source,
      rangeKind: rangeKind
    )
  }

  private func currentFreshness(
    generation: UInt64,
    sequence: UInt64,
    deadline: Int64,
    revision: UInt64
  ) throws -> ViewerPerformanceCurrentFreshnessReceipt {
    try ViewerPerformanceCurrentFreshnessReceipt(
      sourceGeneration: generation,
      latestEventKey: ViewerEventJournalKey(
        runtimeLogicalID: uuid(1),
        connectionID: uuid(2),
        direction: .appToViewer,
        wireSequence: sequence
      ),
      absoluteDeadlineMonotonicNanoseconds: deadline,
      deadlineRevision: revision
    )
  }

  private func currentSource() -> ViewerPerformanceSource {
    .current(runtimeLogicalID: uuid(1), connectionID: uuid(2))
  }

  private func historicalSource() throws -> ViewerPerformanceSource {
    try .makeHistorical(
      recordingID: 11,
      deviceSessionID: 12,
      recordingLogicalID: uuid(3),
      deviceLogicalID: uuid(4)
    )
  }

  private func performanceJSON() -> Data {
    Data(
      "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\"process\":{\"cpuPercent\":42}}"
        .utf8
    )
  }

  private func uuid(_ suffix: UInt8) -> UUID {
    UUID(
      uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, suffix
      )
    )
  }
}

private final class ManualPerformanceDeadlineScheduler: @unchecked Sendable {
  private struct Job {
    let id: UUID
    let action: @Sendable () -> Void
    var delay: UInt64 = 0
    var armed = false
  }

  private let lock = NSLock()
  private var currentNanoseconds: Int64
  private var jobs: [Job] = []

  init(now: Int64) {
    currentNanoseconds = now
  }

  var value: ViewerPerformanceDeadlineScheduler {
    ViewerPerformanceDeadlineScheduler(
      now: { [weak self] in self?.now() ?? 0 },
      makeMainWorker: { [weak self] action in
        self?.makeWorker(action: action) ?? .completed
      }
    )
  }

  var pendingCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return jobs.filter(\.armed).count
  }

  var physicalWorkerCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return jobs.count
  }

  func runNext() {
    let job: Job?
    lock.lock()
    if let index = jobs.firstIndex(where: \.armed) {
      job = jobs[index]
      jobs[index].armed = false
      if let job {
        let delay = Int64(clamping: job.delay)
        let (advanced, overflow) = currentNanoseconds.addingReportingOverflow(delay)
        currentNanoseconds = overflow ? Int64.max : advanced
      }
    } else {
      job = nil
    }
    lock.unlock()
    job?.action()
  }

  private func now() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return currentNanoseconds
  }

  private func makeWorker(
    action: @escaping @Sendable () -> Void
  ) -> ViewerPerformanceScheduledDeadlineWork {
    let id = UUID()
    lock.lock()
    jobs.append(Job(id: id, action: action))
    lock.unlock()
    return ViewerPerformanceScheduledDeadlineWork(
      schedule: { [weak self] in self?.schedule(id: id, delay: $0) },
      disarm: { [weak self] in self?.disarm(id: id) },
      cancel: { [weak self] in self?.cancel(id: id) },
      wait: {}
    )
  }

  private func schedule(id: UUID, delay: UInt64) {
    lock.lock()
    if let index = jobs.firstIndex(where: { $0.id == id }) {
      jobs[index].delay = delay
      jobs[index].armed = true
    }
    lock.unlock()
  }

  private func disarm(id: UUID) {
    lock.lock()
    if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].armed = false }
    lock.unlock()
  }

  private func cancel(id: UUID) {
    lock.lock()
    jobs.removeAll { $0.id == id }
    lock.unlock()
  }
}

private final class CooperativePerformanceDeadlineScheduler: @unchecked Sendable {
  private final class Job: @unchecked Sendable {
    let id = UUID()
    let action: @Sendable () -> Void

    private let lock = NSLock()
    private var cancelled = false
    private var armed = false
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(action: @escaping @Sendable () -> Void) {
      self.action = action
    }

    func cancel() {
      lock.lock()
      cancelled = true
      armed = false
      lock.unlock()
    }

    func schedule() {
      lock.lock()
      if !cancelled { armed = true }
      lock.unlock()
    }

    func disarm() {
      lock.lock()
      armed = false
      lock.unlock()
    }

    var isArmed: Bool {
      lock.lock()
      defer { lock.unlock() }
      return armed
    }

    func wait() async {
      await withCheckedContinuation { continuation in
        lock.lock()
        if completed {
          lock.unlock()
          continuation.resume()
        } else {
          waiters.append(continuation)
          lock.unlock()
        }
      }
    }

    func drain() {
      lock.lock()
      guard !completed else {
        lock.unlock()
        return
      }
      let shouldRun = armed && !cancelled
      armed = false
      lock.unlock()
      if shouldRun { action() }

      let completions: [CheckedContinuation<Void, Never>]
      lock.lock()
      completed = true
      completions = waiters
      waiters.removeAll(keepingCapacity: false)
      lock.unlock()
      for completion in completions { completion.resume() }
    }
  }

  private let lock = NSLock()
  private let currentNanoseconds: Int64
  private var jobs: [Job] = []
  private var storedCreatedWorkerCount = 0

  init(now: Int64) {
    currentNanoseconds = now
  }

  var value: ViewerPerformanceDeadlineScheduler {
    ViewerPerformanceDeadlineScheduler(
      now: { [currentNanoseconds] in currentNanoseconds },
      makeMainWorker: { [weak self] action in
        self?.makeWorker(action: action) ?? .completed
      }
    )
  }

  var pendingCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return jobs.filter(\.isArmed).count
  }

  var physicalWorkerCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return jobs.count
  }

  var createdWorkerCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedCreatedWorkerCount
  }

  func drainAll() {
    let pending: [Job]
    lock.lock()
    pending = jobs
    jobs.removeAll(keepingCapacity: false)
    lock.unlock()
    for job in pending { job.drain() }
  }

  private func makeWorker(
    action: @escaping @Sendable () -> Void
  ) -> ViewerPerformanceScheduledDeadlineWork {
    let job = Job(action: action)
    lock.lock()
    jobs.append(job)
    storedCreatedWorkerCount += 1
    lock.unlock()
    return ViewerPerformanceScheduledDeadlineWork(
      schedule: { _ in job.schedule() },
      disarm: { job.disarm() },
      cancel: { job.cancel() },
      wait: { await job.wait() }
    )
  }
}

final class ViewerPerformanceDashboardModelTests: XCTestCase {
  @MainActor
  func testCurrentScopeOwnsCardsSixChartGroupsProgressAndSynchronizedCrosshair() throws {
    let source = currentSource()
    let scope = try ViewerPerformanceDashboardScope(
      sourceGeneration: 1,
      source: source,
      rangeKind: .currentSession
    )
    let model = ViewerPerformanceDashboardModel()
    model.replaceScope(scope)
    XCTAssertTrue(model.beginLoading(for: scope))
    let progress = ViewerPerformanceProjectionProgress(
      stage: .events,
      eventPageCount: 2,
      gapPageCount: 0,
      decodedEventCount: 64,
      decodeTurnCount: 1
    )
    XCTAssertTrue(model.updateProgress(progress, for: scope))
    XCTAssertEqual(model.phase, .loading(retainsPresentation: false))
    XCTAssertEqual(model.progress, progress)

    let publication = try currentPublication(source: source, sourceGeneration: 1)
    XCTAssertTrue(model.apply(publication, for: scope))
    XCTAssertEqual(model.phase, .ready(.liveWindowOnly))
    XCTAssertNil(model.progress)
    XCTAssertNotNil(model.currentFreshnessReceipt)
    XCTAssertNil(model.historicalFreshnessReceipt)
    XCTAssertEqual(model.availability.count, 16)
    XCTAssertEqual(model.cards?.state(for: .processCPUPercent), .measured(.numeric(42)))
    XCTAssertEqual(ViewerPerformanceDashboardModel.chartGroups.count, 6)
    XCTAssertEqual(
      ViewerPerformanceDashboardModel.chartGroups.flatMap(\.metrics),
      ViewerPerformanceNumericMetric.allCases
    )

    XCTAssertFalse(model.setCrosshair(viewerMonotonicNanoseconds: -1))
    XCTAssertTrue(model.setCrosshair(viewerMonotonicNanoseconds: 5))
    XCTAssertEqual(model.crosshair?.viewerMonotonicNanoseconds, 5)
    XCTAssertEqual(model.selectedBucket?.index, 5)
    XCTAssertEqual(model.crosshair?.chartGroup, .display)
    XCTAssertNil(model.crosshair?.selectedMetric)
    XCTAssertTrue(
      model.setCrosshair(
        viewerMonotonicNanoseconds: 10,
        chartGroup: .cpu,
        selectedMetric: .cpuPercent
      )
    )
    XCTAssertEqual(model.crosshair?.chartGroup, .cpu)
    XCTAssertEqual(model.crosshair?.selectedMetric, .cpuPercent)
    XCTAssertFalse(
      model.setCrosshair(
        viewerMonotonicNanoseconds: 10,
        chartGroup: .display,
        selectedMetric: .cpuPercent
      )
    )
    XCTAssertEqual(model.diagnostics.phase, .ready)
    XCTAssertEqual(model.diagnostics.bucketCount, 11)
    XCTAssertTrue(model.diagnostics.hasCrosshair)
    XCTAssertTrue(model.diagnostics.hasCurrentDeadline)
    XCTAssertFalse(model.diagnostics.hasHistoricalAnchor)
    XCTAssertTrue(Mirror(reflecting: model).children.isEmpty)
    XCTAssertTrue(Mirror(reflecting: scope).children.isEmpty)
    XCTAssertTrue(Mirror(reflecting: try XCTUnwrap(model.crosshair)).children.isEmpty)
  }

  @MainActor
  func testCurrentExpiryRequiresExactReceiptAndNeverMutatesChartData() throws {
    let source = currentSource()
    let scope = try ViewerPerformanceDashboardScope(
      sourceGeneration: 1,
      source: source,
      rangeKind: .currentSession
    )
    let model = ViewerPerformanceDashboardModel()
    model.replaceScope(scope)
    let publication = try currentPublication(source: source, sourceGeneration: 1)
    XCTAssertTrue(model.apply(publication, for: scope))
    let originalBuckets = model.buckets
    let receipt = try XCTUnwrap(model.currentFreshnessReceipt)
    let predecessor = try ViewerPerformanceCurrentFreshnessReceipt(
      sourceGeneration: receipt.sourceGeneration,
      latestEventKey: receipt.latestEventKey,
      absoluteDeadlineMonotonicNanoseconds: receipt.absoluteDeadlineMonotonicNanoseconds,
      deadlineRevision: receipt.deadlineRevision + 1
    )

    XCTAssertFalse(model.expireCurrentCards(matching: predecessor))
    XCTAssertTrue(model.expireCurrentCards(matching: receipt))
    XCTAssertEqual(model.cards?.state(for: .processCPUPercent), .noRecentSample)
    XCTAssertEqual(model.buckets, originalBuckets)
    XCTAssertFalse(model.diagnostics.hasCurrentDeadline)
    XCTAssertFalse(model.expireCurrentCards(matching: receipt))
  }

  @MainActor
  func testHistoricalScopeKeepsFrozenReceiptAndShowsStorageUnavailableWithoutOldValues()
    throws
  {
    let source = try historicalSource()
    let scope = try ViewerPerformanceDashboardScope(
      sourceGeneration: 7,
      source: source,
      rangeKind: .currentSession
    )
    let model = ViewerPerformanceDashboardModel()
    model.replaceScope(scope)
    let publication = try historicalPublication(source: source, sourceGeneration: 7)
    XCTAssertTrue(model.apply(publication, for: scope))
    XCTAssertEqual(model.phase, .ready(.completeRange))
    XCTAssertNil(model.currentFreshnessReceipt)
    XCTAssertEqual(model.historicalFreshnessReceipt?.source, source)
    XCTAssertEqual(model.historicalFreshnessReceipt?.frozenUpperMonotonicNanoseconds, 10)
    XCTAssertTrue(model.diagnostics.hasHistoricalAnchor)
    XCTAssertFalse(model.diagnostics.hasCurrentDeadline)

    XCTAssertTrue(model.showStorageUnavailable(for: scope))
    XCTAssertEqual(model.phase, .storageUnavailable)
    XCTAssertTrue(model.buckets.isEmpty)
    XCTAssertNil(model.cards)
    XCTAssertNil(model.historicalFreshnessReceipt)
    XCTAssertFalse(model.showStorageUnavailable(for: try currentScope(generation: 7)))
  }

  @MainActor
  func testModelRejectsStaleGenerationSourceAndRangeThenClearsOnReplacement() throws {
    let source = currentSource()
    let scope = try ViewerPerformanceDashboardScope(
      sourceGeneration: 1,
      source: source,
      rangeKind: .currentSession
    )
    let model = ViewerPerformanceDashboardModel()
    model.replaceScope(scope)
    let stale = try currentPublication(source: source, sourceGeneration: 2)
    XCTAssertFalse(model.apply(stale, for: scope))
    XCTAssertEqual(model.phase, .idle)

    let current = try currentPublication(source: source, sourceGeneration: 1)
    XCTAssertTrue(model.apply(current, for: scope))
    XCTAssertTrue(model.setCrosshair(viewerMonotonicNanoseconds: 5))
    let rangeReplacement = try ViewerPerformanceDashboardScope(
      sourceGeneration: 1,
      source: source,
      rangeKind: .fiveMinutes
    )
    model.replaceScope(rangeReplacement)
    XCTAssertEqual(model.phase, .idle)
    XCTAssertTrue(model.buckets.isEmpty)
    XCTAssertNil(model.crosshair)
    XCTAssertFalse(model.apply(current, for: rangeReplacement))

    XCTAssertTrue(model.beginLoading(for: rangeReplacement))
    XCTAssertTrue(model.showFailure(.workLimitExceeded, for: rangeReplacement))
    XCTAssertEqual(model.phase, .failed(.workLimitExceeded))
    XCTAssertTrue(model.buckets.isEmpty)
    model.seal()
    XCTAssertTrue(model.sealed)
    XCTAssertFalse(model.beginLoading(for: rangeReplacement))
  }

  @MainActor
  func testZeroEventProjectionUsesExplicitEmptyCoverage() throws {
    let source = currentSource()
    let scope = try ViewerPerformanceDashboardScope(
      sourceGeneration: 1,
      source: source,
      rangeKind: .currentSession
    )
    let model = ViewerPerformanceDashboardModel()
    model.replaceScope(scope)
    let publication = try currentPublication(
      source: source,
      sourceGeneration: 1,
      includesEvent: false
    )
    XCTAssertTrue(model.apply(publication, for: scope))
    XCTAssertEqual(model.phase, .empty(.liveWindowOnly))
    XCTAssertNil(model.cards?.latestEventKey)
    XCTAssertEqual(model.diagnostics.phase, .empty)
  }

  @MainActor
  func testCurrentProjectionComposesSystemChartsWithoutStartingAnotherRuntime() throws {
    let source = currentSource()
    let scope = try ViewerPerformanceDashboardScope(
      sourceGeneration: 1,
      source: source,
      rangeKind: .currentSession
    )
    let model = ViewerPerformanceDashboardModel()
    model.replaceScope(scope)
    XCTAssertTrue(
      model.apply(
        try currentPublication(source: source, sourceGeneration: 1),
        for: scope
      )
    )
    XCTAssertTrue(
      model.setCrosshair(
        viewerMonotonicNanoseconds: 10,
        chartGroup: .cpu,
        selectedMetric: .cpuPercent
      )
    )

    let hostingView = NSHostingView(
      rootView: ViewerPerformanceDashboardContent(model: model, guidance: nil)
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 980, height: 1_600)
    hostingView.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    XCTAssertEqual(model.diagnostics.bucketCount, 11)
    XCTAssertEqual(model.diagnostics.phase, .ready)
    XCTAssertTrue(model.diagnostics.hasCrosshair)
  }

  private func currentPublication(
    source: ViewerPerformanceSource,
    sourceGeneration: UInt64,
    includesEvent: Bool = true
  ) throws -> ViewerPerformanceProjectionPublication {
    guard case .current(let runtimeLogicalID, let connectionID) = source else {
      throw ViewerPerformanceStoreFailure.invalidScope
    }
    let events =
      includesEvent
      ? [try event(source: source, sequence: 1, monotonic: 10)] : []
    let liveSlice = try ViewerPerformanceLiveSlice(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      liveGeneration: 1,
      revision: 1,
      anchorMonotonicNanoseconds: 10,
      events: events,
      gaps: [],
      applicableOrUncertainCount: 0,
      hasMoreApplicableGaps: false
    )
    let receipt = ViewerPerformanceFrozenReceipt(
      source: source,
      storeScope: nil,
      liveSlice: liveSlice
    )
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 10
    )
    var session = try ViewerPerformanceProjectionSession(
      receipt: receipt,
      rangeKind: .currentSession,
      bounds: bounds,
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: sourceGeneration
    )
    if includesEvent { XCTAssertEqual(try session.runDecodeTurn(), .processed(1)) }
    XCTAssertEqual(try session.runDecodeTurn(), .eventsComplete)
    return try session.finalize(
      sourceGeneration: sourceGeneration,
      deadlineRevision: 1,
      currentUptimeNanoseconds: 10
    )
  }

  private func historicalPublication(
    source: ViewerPerformanceSource,
    sourceGeneration: UInt64
  ) throws -> ViewerPerformanceProjectionPublication {
    guard case .historical(let recordingID, let deviceSessionID, _, _) = source else {
      throw ViewerPerformanceStoreFailure.invalidScope
    }
    let storeScope = try ViewerPerformanceStoreScope(
      storeGeneration: 1,
      recordingID: recordingID,
      deviceSessionID: deviceSessionID,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 10,
      eventUpperRowID: 1,
      gapUpperRowID: 0
    )
    let receipt = ViewerPerformanceFrozenReceipt(
      source: source,
      storeScope: storeScope,
      liveSlice: nil
    )
    let bounds = try ViewerPerformanceRangeBounds(
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 10
    )
    var session = try ViewerPerformanceProjectionSession(
      receipt: receipt,
      rangeKind: .currentSession,
      bounds: bounds,
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: sourceGeneration
    )
    try session.accept(
      eventPage: ViewerPerformanceEventPage(
        scope: storeScope,
        events: [try event(source: source, sequence: 1, monotonic: 10, durable: true)],
        examinedCandidateCount: 1,
        continuation: nil,
        isComplete: true
      )
    )
    XCTAssertEqual(try session.runDecodeTurn(), .processed(1))
    XCTAssertEqual(try session.runDecodeTurn(), .eventsComplete)
    try session.accept(
      gapPage: ViewerPerformanceGapPage(
        gaps: [],
        hasMoreRows: false,
        applicableOrUncertainCount: 0,
        hasMoreApplicableGaps: false
      )
    )
    return try session.finalize(
      sourceGeneration: sourceGeneration,
      deadlineRevision: 1,
      currentUptimeNanoseconds: nil
    )
  }

  private func event(
    source: ViewerPerformanceSource,
    sequence: UInt64,
    monotonic: Int64,
    durable: Bool = false
  ) throws -> ViewerPerformanceEventCarrier {
    let runtimeLogicalID: UUID
    let connectionID: UUID
    switch source {
    case .current(let runtime, let connection):
      runtimeLogicalID = runtime
      connectionID = connection
    case .historical(_, _, let recording, let device):
      runtimeLogicalID = recording
      connectionID = device
    }
    return try ViewerPerformanceEventCarrier(
      locator: durable
        ? .durable(rowID: Int64(sequence), deviceSessionID: 12)
        : .transient(observationID: uuid(9)),
      key: ViewerEventJournalKey(
        runtimeLogicalID: runtimeLogicalID,
        connectionID: connectionID,
        direction: .appToViewer,
        wireSequence: sequence
      ),
      viewerWallMilliseconds: 1_000 + monotonic,
      viewerMonotonicNanoseconds: monotonic,
      content: .canonical(
        Data(
          "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\"process\":{\"cpuPercent\":42}}"
            .utf8
        )
      )
    )
  }

  private func currentScope(generation: UInt64) throws -> ViewerPerformanceDashboardScope {
    try ViewerPerformanceDashboardScope(
      sourceGeneration: generation,
      source: currentSource(),
      rangeKind: .currentSession
    )
  }

  private func currentSource() -> ViewerPerformanceSource {
    .current(runtimeLogicalID: uuid(1), connectionID: uuid(2))
  }

  private func historicalSource() throws -> ViewerPerformanceSource {
    try .makeHistorical(
      recordingID: 11,
      deviceSessionID: 12,
      recordingLogicalID: uuid(3),
      deviceLogicalID: uuid(4)
    )
  }

  private func uuid(_ suffix: UInt8) -> UUID {
    UUID(
      uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, suffix
      )
    )
  }
}

final class ViewerPerformanceDashboardControllerTests: XCTestCase {
  @MainActor
  func testProjectionRunStreamsStorePagesOffMainAndTransfersExactResultOwnership() async throws {
    let source = try historicalSource()
    let scope = try storeScope(upper: 10)
    let preparation = try historicalPreparation(source: source, scope: scope)
    let page = try eventPage(
      scope: scope,
      events: [try Self.makeEvent(source: source, sequence: 1, monotonic: 10, durable: true)]
    )
    let harness = PerformanceProjectionDriverHarness(
      prepare: { _, _, _ in .success(preparation) },
      eventResults: [.success(page)],
      gapResults: [.success(try emptyGapPage())],
      currentUptimeNanoseconds: { nil }
    )
    let ledger = ViewerPerformanceMemoryLedger()
    let output = PerformanceProjectionRunOutputBox()
    let completed = expectation(description: "Projection completion")
    let target = try ViewerPerformanceDashboardTarget.historical(
      source: source,
      anchor: .ended(
        deviceStartMonotonicNanoseconds: 0,
        deviceEndMonotonicNanoseconds: 10
      )
    )
    let token = try ViewerPerformanceRefreshToken(
      sourceGeneration: 1,
      sequence: 1,
      source: source,
      rangeKind: .currentSession
    )
    let run = ViewerPerformanceProjectionRun(
      driver: harness.driver,
      ledger: ledger,
      target: target,
      token: token,
      preparationMode: .storeBacked,
      progress: { _, _ in },
      completion: {
        output.set($0)
        completed.fulfill()
      }
    )

    await fulfillment(of: [completed], timeout: 2)
    guard let result = output.value else { return XCTFail("Missing run output") }
    guard case .projected(let owned) = result.outcome else {
      return XCTFail("Expected a complete projection")
    }
    XCTAssertFalse(harness.prepareWasMainThread)
    XCTAssertEqual(harness.eventLoadCount, 1)
    XCTAssertEqual(harness.gapLoadCount, 1)
    XCTAssertEqual(harness.endTraversalCount, 1)
    XCTAssertEqual(owned.publication.decodedEventCount, 1)
    XCTAssertEqual(owned.publication.coverage, .completeRange)
    XCTAssertEqual(ledger.usedBytes, owned.publication.result.accountedBytes)
    guard let reservation = owned.takeReservation() else {
      return XCTFail("Missing completed-result ownership")
    }
    XCTAssertEqual(reservation.owner, .completedResult)
    XCTAssertTrue(ledger.release(reservation))
    await run.cancelAndWait().value
    XCTAssertEqual(ledger.usedBytes, 0)
    XCTAssertEqual(ledger.reservationCount, 0)
  }

  @MainActor
  func testProjectionRunDropsCompletedResultWhenTraversalReleaseFails() async throws {
    for failure in [
      ViewerStoreExplorerFailure.storeReplaced,
      .unavailable,
      .cancelled,
    ] {
      let source = try historicalSource()
      let scope = try storeScope(upper: 10)
      let preparation = try historicalPreparation(source: source, scope: scope)
      let harness = PerformanceProjectionDriverHarness(
        prepare: { _, _, _ in .success(preparation) },
        eventResults: [
          .success(
            try eventPage(
              scope: scope,
              events: [
                try Self.makeEvent(
                  source: source,
                  sequence: 1,
                  monotonic: 10,
                  durable: true
                )
              ]
            ))
        ],
        gapResults: [.success(try emptyGapPage())],
        endTraversalResult: .failure(failure),
        currentUptimeNanoseconds: { nil }
      )
      let ledger = ViewerPerformanceMemoryLedger()
      let output = PerformanceProjectionRunOutputBox()
      let completed = expectation(description: "Traversal release failure \(failure)")
      let token = try ViewerPerformanceRefreshToken(
        sourceGeneration: 1,
        sequence: 1,
        source: source,
        rangeKind: .currentSession
      )
      let run = ViewerPerformanceProjectionRun(
        driver: harness.driver,
        ledger: ledger,
        target: try ViewerPerformanceDashboardTarget.historical(
          source: source,
          anchor: .ended(
            deviceStartMonotonicNanoseconds: 0,
            deviceEndMonotonicNanoseconds: 10
          )
        ),
        token: token,
        preparationMode: .storeBacked,
        progress: { _, _ in },
        completion: {
          output.set($0)
          completed.fulfill()
        }
      )

      await fulfillment(of: [completed], timeout: 2)
      guard let result = output.value else { return XCTFail("Missing release-failure output") }
      guard case .storeFailure(let deliveredFailure) = result.outcome else {
        return XCTFail("Traversal release failure must replace the completed projection")
      }
      XCTAssertEqual(deliveredFailure, failure)
      XCTAssertEqual(harness.endTraversalCount, 1)
      XCTAssertEqual(ledger.usedBytes, 0)
      XCTAssertEqual(ledger.reservationCount, 0)
      await run.cancelAndWait().value
    }
  }

  @MainActor
  func testProjectionRunCancellationJoinsBlockedPageAndTraversalRelease() async throws {
    let source = try historicalSource()
    let scope = try storeScope(upper: 10)
    let preparation = try historicalPreparation(source: source, scope: scope)
    let harness = PerformanceProjectionDriverHarness(
      prepare: { _, _, _ in .success(preparation) },
      eventResults: [],
      gapResults: [],
      currentUptimeNanoseconds: { nil }
    )
    let ledger = ViewerPerformanceMemoryLedger()
    let output = PerformanceProjectionRunOutputBox()
    let completed = expectation(description: "Cancelled projection completion")
    let target = try ViewerPerformanceDashboardTarget.historical(
      source: source,
      anchor: .ended(
        deviceStartMonotonicNanoseconds: 0,
        deviceEndMonotonicNanoseconds: 10
      )
    )
    let token = try ViewerPerformanceRefreshToken(
      sourceGeneration: 1,
      sequence: 1,
      source: source,
      rangeKind: .currentSession
    )
    let run = ViewerPerformanceProjectionRun(
      driver: harness.driver,
      ledger: ledger,
      target: target,
      token: token,
      preparationMode: .storeBacked,
      progress: { _, _ in },
      completion: {
        output.set($0)
        completed.fulfill()
      }
    )
    await waitUntil { harness.eventLoadCount == 1 }

    let cleanup = run.cancelAndWait()
    await Task.yield()
    XCTAssertNil(output.value)
    XCTAssertEqual(harness.cancelCount, 1)
    harness.resolveBlockedEvent(.failure(.cancelled))
    await cleanup.value
    await fulfillment(of: [completed], timeout: 2)

    guard let result = output.value else { return XCTFail("Missing cancelled output") }
    guard case .cancelled = result.outcome else {
      return XCTFail("Cancelled work must not publish content")
    }
    XCTAssertEqual(harness.endTraversalCount, 1)
    XCTAssertEqual(ledger.usedBytes, 0)
    XCTAssertEqual(ledger.reservationCount, 0)
  }

  @MainActor
  func testControllerRecoversCurrentStoreFailureAndRevalidatesClaimAtApply() async throws {
    let source = currentSource()
    let storeScope = try self.storeScope(upper: 10)
    let clock = LockedPerformanceClock(10)
    let preparationFactory: PerformanceProjectionDriverHarness.Preparation = {
      target, rangeKind, mode in
      .success(
        try Self.makeCurrentPreparation(
          source: target.source,
          rangeKind: rangeKind,
          storeScope: mode == .storeBacked ? storeScope : nil,
          revision: mode == .storeBacked ? 1 : 2
        )
      )
    }
    let harness = PerformanceProjectionDriverHarness(
      prepare: preparationFactory,
      eventResults: [.failure(.unavailable)],
      gapResults: [],
      currentUptimeNanoseconds: { clock.value }
    )
    let delivery = ManualLiveRefreshScheduler()
    let deadline = ManualPerformanceDeadlineScheduler(now: 10)
    let ledger = ViewerPerformanceMemoryLedger()
    let controller = ViewerPerformanceDashboardController(
      driver: harness.driver,
      ledger: ledger,
      deliveryScheduler: delivery.value,
      deadlineScheduler: deadline.value,
      uptimeNanoseconds: { clock.value },
      deliveryClaimed: { clock.set(3_000_000_010) }
    )
    let target = try ViewerPerformanceDashboardTarget.current(
      source: source,
      recordingID: 11,
      deviceSessionID: 12,
      deviceStartMonotonicNanoseconds: 0
    )

    await controller.replace(target: target, rangeKind: .currentSession).value
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }

    XCTAssertEqual(harness.preparationModes, [.storeBacked, .freshLiveOnly])
    XCTAssertEqual(harness.endTraversalCount, 1)
    XCTAssertEqual(controller.model.coverage, .liveWindowOnly)
    XCTAssertFalse(controller.model.cards?.isFresh ?? true)
    XCTAssertEqual(controller.diagnostics.activeDeadlineCount, 0)
    XCTAssertEqual(controller.diagnostics.cacheEntryCount, 1)
    let cpuBucketIndex = try XCTUnwrap(
      controller.model.buckets.firstIndex {
        $0.numeric.accumulator(for: .cpuPercent).representative != nil
      }
    )
    let representative = try XCTUnwrap(
      controller.model.buckets[cpuBucketIndex].numeric.accumulator(for: .cpuPercent)
        .representative
    )
    let rawRequest = try XCTUnwrap(
      controller.rawEventRequest(bucketIndex: cpuBucketIndex, metric: .cpuPercent)
    )
    XCTAssertEqual(representative.sourceGeneration, controller.model.scope?.sourceGeneration)
    XCTAssertEqual(rawRequest.sourceGeneration, representative.sourceGeneration)
    XCTAssertEqual(rawRequest.key, representative.key)
    XCTAssertEqual(
      rawRequest.key.wireSequence,
      2
    )
    XCTAssertNil(
      controller.rawEventRequest(
        bucketIndex: cpuBucketIndex,
        metric: .estimatedFramesPerSecond
      )
    )
    let bytesBeforeCrosshair = controller.diagnostics.ledgerBytes
    let reservationsBeforeCrosshair = controller.diagnostics.ledgerReservationCount
    XCTAssertTrue(
      controller.setCrosshair(
        viewerMonotonicNanoseconds: 10,
        chartGroup: .cpu,
        selectedMetric: .cpuPercent
      )
    )
    XCTAssertTrue(controller.model.diagnostics.hasCrosshair)
    XCTAssertEqual(
      controller.diagnostics.ledgerBytes,
      bytesBeforeCrosshair + ViewerPerformanceAccounting.crosshairBytes
        + ViewerPerformanceAccounting.tooltipBytes
    )
    XCTAssertEqual(
      controller.diagnostics.ledgerReservationCount,
      reservationsBeforeCrosshair + 2
    )
    XCTAssertTrue(
      controller.setCrosshair(
        viewerMonotonicNanoseconds: 10,
        chartGroup: .cpu,
        selectedMetric: .cpuPercent
      )
    )
    XCTAssertEqual(controller.diagnostics.ledgerReservationCount, reservationsBeforeCrosshair + 2)
    controller.clearCrosshair()
    XCTAssertFalse(controller.model.diagnostics.hasCrosshair)
    XCTAssertEqual(controller.diagnostics.ledgerBytes, bytesBeforeCrosshair)
    XCTAssertEqual(
      controller.diagnostics.ledgerReservationCount,
      reservationsBeforeCrosshair
    )

    await controller.sealAndWait().value
    XCTAssertEqual(controller.diagnostics.ledgerBytes, 0)
    XCTAssertEqual(controller.diagnostics.ledgerReservationCount, 0)
  }

  @MainActor
  func testHistoricalRangeRoundTripReplacesStaleGenerationCacheEntryForRawReveal()
    async throws
  {
    let source = try historicalSource()
    let scope = try storeScope(upper: 10)
    let preparation = try historicalPreparation(source: source, scope: scope)
    let event = try Self.makeEvent(
      source: source,
      sequence: 1,
      monotonic: 10,
      durable: true
    )
    let page = try eventPage(scope: scope, events: [event])
    let harness = PerformanceProjectionDriverHarness(
      prepare: { _, _, _ in .success(preparation) },
      eventResults: [.success(page), .success(page), .success(page)],
      gapResults: [
        .success(try emptyGapPage()),
        .success(try emptyGapPage()),
        .success(try emptyGapPage()),
      ],
      currentUptimeNanoseconds: { nil }
    )
    let delivery = ManualLiveRefreshScheduler()
    let controller = ViewerPerformanceDashboardController(
      driver: harness.driver,
      deliveryScheduler: delivery.value
    )
    let target = try ViewerPerformanceDashboardTarget.historical(
      source: source,
      anchor: .ended(
        deviceStartMonotonicNanoseconds: 0,
        deviceEndMonotonicNanoseconds: 10
      )
    )

    await controller.replace(target: target, rangeKind: .currentSession).value
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }
    let firstGeneration = try XCTUnwrap(controller.model.scope?.sourceGeneration)
    let firstBucketIndex = try XCTUnwrap(
      controller.model.buckets.firstIndex {
        $0.numeric.accumulator(for: .cpuPercent).representative != nil
      }
    )
    XCTAssertNotNil(
      controller.rawEventRequest(bucketIndex: firstBucketIndex, metric: .cpuPercent)
    )

    await controller.replace(target: target, rangeKind: .oneMinute).value
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }

    await controller.replace(target: target, rangeKind: .currentSession).value
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }

    let roundTripGeneration = try XCTUnwrap(controller.model.scope?.sourceGeneration)
    XCTAssertGreaterThan(roundTripGeneration, firstGeneration)
    let roundTripBucketIndex = try XCTUnwrap(
      controller.model.buckets.firstIndex {
        $0.numeric.accumulator(for: .cpuPercent).representative != nil
      }
    )
    let representative = try XCTUnwrap(
      controller.model.buckets[roundTripBucketIndex].numeric
        .accumulator(for: .cpuPercent).representative
    )
    XCTAssertEqual(representative.sourceGeneration, roundTripGeneration)
    XCTAssertEqual(
      controller.rawEventRequest(bucketIndex: roundTripBucketIndex, metric: .cpuPercent)?.key,
      representative.key
    )
    XCTAssertEqual(controller.diagnostics.cacheEntryCount, 2)

    await controller.sealAndWait().value
    XCTAssertEqual(controller.diagnostics.ledgerBytes, 0)
    XCTAssertEqual(controller.diagnostics.ledgerReservationCount, 0)
  }

  @MainActor
  func testCurrentLiveOnlyFallbackClearsPredecessorBeforeBlockedFreezeCompletes() async throws {
    let source = currentSource()
    let scope = try storeScope(upper: 10)
    let page = try eventPage(
      scope: scope,
      events: [try Self.makeEvent(source: source, sequence: 1, monotonic: 10, durable: true)]
    )
    let harness = PerformanceProjectionDriverHarness(
      prepare: { target, rangeKind, mode in
        .success(
          try Self.makeCurrentPreparation(
            source: target.source,
            rangeKind: rangeKind,
            storeScope: mode == .storeBacked ? scope : nil,
            revision: mode == .storeBacked ? 1 : 2
          )
        )
      },
      eventResults: [.success(page), .failure(.unavailable)],
      gapResults: [.success(try emptyGapPage())],
      blockedPreparationMode: .freshLiveOnly,
      currentUptimeNanoseconds: { 10 }
    )
    let delivery = ManualLiveRefreshScheduler()
    let deadline = ManualPerformanceDeadlineScheduler(now: 10)
    let controller = ViewerPerformanceDashboardController(
      driver: harness.driver,
      deliveryScheduler: delivery.value,
      deadlineScheduler: deadline.value,
      uptimeNanoseconds: { 10 }
    )
    let target = try ViewerPerformanceDashboardTarget.current(
      source: source,
      recordingID: 11,
      deviceSessionID: 12,
      deviceStartMonotonicNanoseconds: 0
    )

    await controller.replace(target: target, rangeKind: .currentSession).value
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }
    let bucketIndex = try XCTUnwrap(
      controller.model.buckets.firstIndex {
        $0.numeric.accumulator(for: .cpuPercent).representative != nil
      }
    )
    XCTAssertTrue(controller.setCrosshair(viewerMonotonicNanoseconds: 10))
    XCTAssertNotNil(controller.rawEventRequest(bucketIndex: bucketIndex, metric: .cpuPercent))
    XCTAssertEqual(deadline.pendingCount, 1)

    controller.requestRefresh()
    await waitUntil { harness.preparationModes.last == .freshLiveOnly }

    guard case .loading(let retainsPresentation) = controller.model.phase else {
      return XCTFail("Fallback must remain visibly loading while the fresh freeze is blocked")
    }
    XCTAssertFalse(retainsPresentation)
    XCTAssertNil(controller.model.cards)
    XCTAssertTrue(controller.model.buckets.isEmpty)
    XCTAssertFalse(controller.model.diagnostics.hasCrosshair)
    XCTAssertEqual(controller.diagnostics.cacheEntryCount, 0)
    XCTAssertEqual(controller.diagnostics.activeDeadlineCount, 0)
    XCTAssertEqual(deadline.pendingCount, 0)
    XCTAssertNil(controller.rawEventRequest(bucketIndex: bucketIndex, metric: .cpuPercent))

    harness.resolveBlockedPreparation()
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }
    XCTAssertEqual(
      controller.model.diagnostics.phase,
      .ready,
      "Unexpected fallback phase: \(controller.model.phase); diagnostics: \(controller.diagnostics)"
    )
    XCTAssertEqual(controller.model.coverage, .liveWindowOnly)
    XCTAssertEqual(
      controller.rawEventRequest(bucketIndex: bucketIndex, metric: .cpuPercent)?.key.wireSequence,
      2
    )
    await controller.sealAndWait().value
  }

  @MainActor
  func testStoreGenerationReplacementClearsReadyAndPausedStateBeforeRebuilding() async throws {
    let source = currentSource()
    let harness = PerformanceProjectionDriverHarness(
      prepare: { target, rangeKind, _ in
        .success(
          try Self.makeCurrentPreparation(
            source: target.source,
            rangeKind: rangeKind,
            storeScope: nil,
            revision: 1
          )
        )
      },
      eventResults: [],
      gapResults: [],
      currentUptimeNanoseconds: { 10 }
    )
    let delivery = ManualLiveRefreshScheduler()
    let deadline = ManualPerformanceDeadlineScheduler(now: 10)
    let controller = ViewerPerformanceDashboardController(
      driver: harness.driver,
      deliveryScheduler: delivery.value,
      deadlineScheduler: deadline.value,
      uptimeNanoseconds: { 10 }
    )
    let target = try ViewerPerformanceDashboardTarget.current(
      source: source,
      recordingID: 11,
      deviceSessionID: 12,
      deviceStartMonotonicNanoseconds: 0
    )

    await controller.replace(target: target, rangeKind: .currentSession).value
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }
    let firstGeneration = try XCTUnwrap(controller.model.scope?.sourceGeneration)
    XCTAssertEqual(deadline.pendingCount, 1)

    let readyReplacement = controller.replaceStoreGenerationAndWait()
    XCTAssertNil(controller.model.scope)
    XCTAssertNil(controller.model.cards)
    XCTAssertTrue(controller.model.buckets.isEmpty)
    XCTAssertEqual(controller.diagnostics.cacheEntryCount, 0)
    XCTAssertEqual(deadline.pendingCount, 0)
    await readyReplacement.value
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }
    let secondGeneration = try XCTUnwrap(controller.model.scope?.sourceGeneration)
    XCTAssertGreaterThan(secondGeneration, firstGeneration)

    controller.pause()
    let pausedReplacement = controller.replaceStoreGenerationAndWait()
    XCTAssertNil(controller.model.scope)
    XCTAssertNil(controller.model.cards)
    XCTAssertEqual(controller.diagnostics.cacheEntryCount, 0)
    await pausedReplacement.value
    let pausedGeneration = try XCTUnwrap(controller.model.scope?.sourceGeneration)
    XCTAssertGreaterThan(pausedGeneration, secondGeneration)
    XCTAssertEqual(controller.model.diagnostics.phase, .idle)
    XCTAssertEqual(controller.diagnostics.runningRefreshCount, 0)
    XCTAssertEqual(controller.diagnostics.dirtyRefreshCount, 1)
    XCTAssertEqual(delivery.pendingCount, 0)

    controller.resume()
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }
    XCTAssertEqual(controller.model.scope?.sourceGeneration, pausedGeneration)
    await controller.sealAndWait().value
  }

  @MainActor
  func testStoreGenerationReplacementJoinsBlockedScanBeforeStartingSuccessor() async throws {
    let source = try historicalSource()
    let scope = try storeScope(upper: 10)
    let preparation = try historicalPreparation(source: source, scope: scope)
    let harness = PerformanceProjectionDriverHarness(
      prepare: { _, _, _ in .success(preparation) },
      eventResults: [],
      gapResults: [],
      currentUptimeNanoseconds: { nil }
    )
    let ledger = ViewerPerformanceMemoryLedger()
    let controller = ViewerPerformanceDashboardController(driver: harness.driver, ledger: ledger)
    let target = try ViewerPerformanceDashboardTarget.historical(
      source: source,
      anchor: .ended(
        deviceStartMonotonicNanoseconds: 0,
        deviceEndMonotonicNanoseconds: 10
      )
    )

    let initialReplacement = controller.replace(target: target, rangeKind: .currentSession)
    await waitUntil { harness.eventLoadCount == 1 }
    let initialGeneration = controller.model.scope?.sourceGeneration

    let storeReplacement = controller.replaceStoreGenerationAndWait()
    XCTAssertNil(controller.model.scope)
    XCTAssertEqual(harness.cancelCount, 1)
    XCTAssertEqual(harness.eventLoadCount, 1)
    harness.resolveBlockedEvent(.failure(.cancelled))
    await initialReplacement.value
    await storeReplacement.value
    await waitUntil { harness.eventLoadCount == 2 }
    XCTAssertGreaterThan(
      try XCTUnwrap(controller.model.scope?.sourceGeneration),
      try XCTUnwrap(initialGeneration)
    )
    XCTAssertNil(controller.model.cards)
    XCTAssertEqual(controller.diagnostics.cacheEntryCount, 0)

    let cleanup = controller.sealAndWait()
    harness.resolveBlockedEvent(.failure(.cancelled))
    await cleanup.value
    XCTAssertEqual(ledger.usedBytes, 0)
    XCTAssertEqual(ledger.reservationCount, 0)
  }

  @MainActor
  func testStoreGenerationReplacementInvalidatesClaimedDeliveryBeforeApply() async throws {
    let source = currentSource()
    let harness = PerformanceProjectionDriverHarness(
      prepare: { target, rangeKind, _ in
        .success(
          try Self.makeCurrentPreparation(
            source: target.source,
            rangeKind: rangeKind,
            storeScope: nil,
            revision: 1
          )
        )
      },
      eventResults: [],
      gapResults: [],
      currentUptimeNanoseconds: { 10 }
    )
    let delivery = ManualLiveRefreshScheduler()
    let owner = PerformanceControllerOwner()
    let controller = ViewerPerformanceDashboardController(
      driver: harness.driver,
      deliveryScheduler: delivery.value,
      uptimeNanoseconds: { 10 },
      deliveryClaimed: {
        owner.claimCount += 1
        if owner.claimCount == 1 {
          owner.cleanup = owner.controller?.replaceStoreGenerationAndWait()
        }
      }
    )
    owner.controller = controller
    let target = try ViewerPerformanceDashboardTarget.current(
      source: source,
      recordingID: 11,
      deviceSessionID: 12,
      deviceStartMonotonicNanoseconds: 0
    )

    await controller.replace(target: target, rangeKind: .currentSession).value
    let firstGeneration = try XCTUnwrap(controller.model.scope?.sourceGeneration)
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    guard let cleanup = owner.cleanup else {
      return XCTFail("The claim hook did not begin Store replacement")
    }
    XCTAssertNil(controller.model.scope)
    XCTAssertNil(controller.model.cards)
    await cleanup.value
    await waitUntil { delivery.pendingCount == 1 }
    XCTAssertNil(controller.model.cards)
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }
    XCTAssertEqual(owner.claimCount, 2)
    XCTAssertGreaterThan(
      try XCTUnwrap(controller.model.scope?.sourceGeneration), firstGeneration
    )
    await controller.sealAndWait().value
  }

  @MainActor
  func testUnsealedDeinitializationClearsRetainedModelAndJoinsBlockedWork() async throws {
    let source = try historicalSource()
    let scope = try storeScope(upper: 10)
    let preparation = try historicalPreparation(source: source, scope: scope)
    let page = try eventPage(
      scope: scope,
      events: [try Self.makeEvent(source: source, sequence: 1, monotonic: 10, durable: true)]
    )
    let harness = PerformanceProjectionDriverHarness(
      prepare: { _, _, _ in .success(preparation) },
      eventResults: [.success(page)],
      gapResults: [.success(try emptyGapPage())],
      currentUptimeNanoseconds: { nil }
    )
    let delivery = ManualLiveRefreshScheduler()
    let ledger = ViewerPerformanceMemoryLedger()
    let model = ViewerPerformanceDashboardModel()
    let initialDetachedCleanupCount =
      ViewerPerformanceDetachedCleanupRegistry.shared.pendingCountForTesting
    var controller: ViewerPerformanceDashboardController? =
      ViewerPerformanceDashboardController(
        driver: harness.driver,
        model: model,
        ledger: ledger,
        deliveryScheduler: delivery.value
      )
    let target = try ViewerPerformanceDashboardTarget.historical(
      source: source,
      anchor: .ended(
        deviceStartMonotonicNanoseconds: 0,
        deviceEndMonotonicNanoseconds: 10
      )
    )

    await controller?.replace(target: target, rangeKind: .currentSession).value
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { model.diagnostics.phase == .ready }
    XCTAssertNotNil(model.cards)

    controller?.requestRefresh()
    await waitUntil { harness.eventLoadCount == 2 }
    weak let weakController = controller
    controller = nil

    XCTAssertNil(weakController)
    XCTAssertTrue(model.sealed)
    XCTAssertNil(model.scope)
    XCTAssertNil(model.cards)
    XCTAssertTrue(model.buckets.isEmpty)
    XCTAssertEqual(
      ViewerPerformanceDetachedCleanupRegistry.shared.pendingCountForTesting,
      initialDetachedCleanupCount + 1
    )
    harness.resolveBlockedEvent(.failure(.cancelled))
    await waitUntil {
      ledger.usedBytes == 0
        && ledger.reservationCount == 0
        && ViewerPerformanceDetachedCleanupRegistry.shared.pendingCountForTesting
          == initialDetachedCleanupCount
    }
  }

  @MainActor
  func testCurrentStoreUnavailableAtPreparationContinuationAndGapPageRecoversFreshly()
    async throws
  {
    enum FailurePoint: CaseIterable, Sendable {
      case preparation
      case continuation
      case gapPage
    }

    for failurePoint in FailurePoint.allCases {
      let source = currentSource()
      let scope = try storeScope(upper: 10)
      let partialEvent = try Self.makeEvent(
        source: source,
        sequence: 9,
        monotonic: 5,
        durable: true
      )
      let continuation = ViewerPerformanceContinuation(
        scope: scope,
        lastExaminedMonotonicNanoseconds: 5,
        lastExaminedRowID: 9
      )
      let partialPage = try ViewerPerformanceEventPage(
        scope: scope,
        events: [partialEvent],
        examinedCandidateCount: 1,
        continuation: continuation,
        isComplete: false
      )
      let completePage = try eventPage(scope: scope, events: [partialEvent])
      let eventResults: [Result<ViewerPerformanceEventPage, ViewerStoreExplorerFailure>]
      let gapResults: [Result<ViewerPerformanceGapPage, ViewerStoreExplorerFailure>]
      switch failurePoint {
      case .preparation:
        eventResults = []
        gapResults = []
      case .continuation:
        eventResults = [.success(partialPage), .failure(.unavailable)]
        gapResults = []
      case .gapPage:
        eventResults = [.success(completePage)]
        gapResults = [.failure(.unavailable)]
      }
      let harness = PerformanceProjectionDriverHarness(
        prepare: { target, rangeKind, mode in
          if mode == .storeBacked, failurePoint == .preparation {
            return .failure(.store(.unavailable))
          }
          return .success(
            try Self.makeCurrentPreparation(
              source: target.source,
              rangeKind: rangeKind,
              storeScope: mode == .storeBacked ? scope : nil,
              revision: mode == .storeBacked ? 1 : 2
            )
          )
        },
        eventResults: eventResults,
        gapResults: gapResults,
        currentUptimeNanoseconds: { 10 }
      )
      let delivery = ManualLiveRefreshScheduler()
      let deadline = ManualPerformanceDeadlineScheduler(now: 10)
      let ledger = ViewerPerformanceMemoryLedger()
      let controller = ViewerPerformanceDashboardController(
        driver: harness.driver,
        ledger: ledger,
        deliveryScheduler: delivery.value,
        deadlineScheduler: deadline.value,
        uptimeNanoseconds: { 10 }
      )
      let target = try ViewerPerformanceDashboardTarget.current(
        source: source,
        recordingID: 11,
        deviceSessionID: 12,
        deviceStartMonotonicNanoseconds: 0
      )

      await controller.replace(target: target, rangeKind: .currentSession).value
      await waitUntil { delivery.pendingCount == 1 }
      delivery.runNext()
      await waitUntil { controller.model.diagnostics.phase == .ready }

      XCTAssertEqual(harness.preparationModes, [.storeBacked, .freshLiveOnly])
      XCTAssertEqual(controller.model.coverage, .liveWindowOnly)
      XCTAssertEqual(controller.model.cards?.latestEventKey?.wireSequence, 2)
      XCTAssertEqual(controller.diagnostics.cacheEntryCount, 1)
      XCTAssertEqual(controller.diagnostics.runningRefreshCount, 0)
      XCTAssertEqual(controller.diagnostics.dirtyRefreshCount, 0)
      XCTAssertEqual(controller.diagnostics.pendingDeliveryCount, 0)
      XCTAssertEqual(controller.diagnostics.pendingDeliveryWorkCount, 0)
      XCTAssertLessThanOrEqual(
        controller.diagnostics.ledgerBytes,
        ViewerPerformanceAggregationLimits.maximumLedgerBytes
      )

      await controller.sealAndWait().value
      XCTAssertEqual(controller.diagnostics.ledgerBytes, 0)
      XCTAssertEqual(controller.diagnostics.ledgerReservationCount, 0)
    }
  }

  @MainActor
  func testDeadlineCrossedWhileEventPageIsBlockedPublishesChartsStaleWithoutWakeLoop()
    async throws
  {
    let source = currentSource()
    let scope = try storeScope(upper: 10)
    let clock = LockedPerformanceClock(10)
    let harness = PerformanceProjectionDriverHarness(
      prepare: { target, rangeKind, _ in
        .success(
          try Self.makeCurrentPreparation(
            source: target.source,
            rangeKind: rangeKind,
            storeScope: scope,
            revision: 1
          )
        )
      },
      eventResults: [],
      gapResults: [.success(try emptyGapPage())],
      currentUptimeNanoseconds: { clock.value }
    )
    let delivery = ManualLiveRefreshScheduler()
    let deadline = ManualPerformanceDeadlineScheduler(now: 10)
    let ledger = ViewerPerformanceMemoryLedger()
    let controller = ViewerPerformanceDashboardController(
      driver: harness.driver,
      ledger: ledger,
      deliveryScheduler: delivery.value,
      deadlineScheduler: deadline.value,
      uptimeNanoseconds: { clock.value }
    )
    let target = try ViewerPerformanceDashboardTarget.current(
      source: source,
      recordingID: 11,
      deviceSessionID: 12,
      deviceStartMonotonicNanoseconds: 0
    )

    await controller.replace(target: target, rangeKind: .currentSession).value
    await waitUntil { harness.eventLoadCount == 1 }
    clock.set(3_000_000_010)
    harness.resolveBlockedEvent(.success(try eventPage(scope: scope, events: [])))
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }

    XCTAssertFalse(controller.model.buckets.isEmpty)
    XCTAssertEqual(
      controller.model.cards?.state(for: .processCPUPercent),
      .noRecentSample
    )
    XCTAssertEqual(controller.diagnostics.activeDeadlineCount, 0)
    XCTAssertEqual(deadline.pendingCount, 0)
    XCTAssertEqual(controller.diagnostics.runningRefreshCount, 0)
    XCTAssertEqual(controller.diagnostics.dirtyRefreshCount, 0)

    await controller.sealAndWait().value
    XCTAssertEqual(controller.diagnostics.ledgerBytes, 0)
    XCTAssertEqual(controller.diagnostics.ledgerReservationCount, 0)
  }

  @MainActor
  func testClaimedDeliveryCleanupDiscardsResultBeforeReplacementCompletes() async throws {
    let source = currentSource()
    let harness = PerformanceProjectionDriverHarness(
      prepare: { target, rangeKind, _ in
        .success(
          try Self.makeCurrentPreparation(
            source: target.source,
            rangeKind: rangeKind,
            storeScope: nil,
            revision: 1
          )
        )
      },
      eventResults: [],
      gapResults: [],
      currentUptimeNanoseconds: { 10 }
    )
    let delivery = ManualLiveRefreshScheduler()
    let deadline = ManualPerformanceDeadlineScheduler(now: 10)
    let ledger = ViewerPerformanceMemoryLedger()
    let owner = PerformanceControllerOwner()
    let controller = ViewerPerformanceDashboardController(
      driver: harness.driver,
      ledger: ledger,
      deliveryScheduler: delivery.value,
      deadlineScheduler: deadline.value,
      uptimeNanoseconds: { 10 },
      deliveryClaimed: {
        owner.cleanup = owner.controller?.replace(
          target: nil,
          rangeKind: .currentSession
        )
      }
    )
    owner.controller = controller
    let target = try ViewerPerformanceDashboardTarget.current(
      source: source,
      recordingID: 11,
      deviceSessionID: 12,
      deviceStartMonotonicNanoseconds: 0
    )

    await controller.replace(target: target, rangeKind: .currentSession).value
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    guard let cleanup = owner.cleanup else {
      return XCTFail("The claim hook did not begin cleanup")
    }
    await cleanup.value

    XCTAssertNil(controller.model.scope)
    XCTAssertNil(controller.model.cards)
    XCTAssertEqual(controller.diagnostics.cacheEntryCount, 0)
    XCTAssertEqual(controller.diagnostics.pendingDeliveryCount, 0)
    XCTAssertEqual(controller.diagnostics.ledgerBytes, 0)
    XCTAssertEqual(controller.diagnostics.ledgerReservationCount, 0)
    await controller.sealAndWait().value
  }

  @MainActor
  func testPausedRangeAndSourceReplacementClearBeforeFreshSuccessorAdmission() async throws {
    let current = currentSource()
    let historical = try historicalSource()
    let harness = PerformanceProjectionDriverHarness(
      prepare: { target, rangeKind, _ in
        switch target.source {
        case .current:
          return .success(
            try Self.makeCurrentPreparation(
              source: target.source,
              rangeKind: rangeKind,
              storeScope: nil,
              revision: rangeKind == .currentSession ? 1 : 2
            )
          )
        case .historical:
          return .failure(.store(.unavailable))
        }
      },
      eventResults: [],
      gapResults: [],
      currentUptimeNanoseconds: { 10 }
    )
    let delivery = ManualLiveRefreshScheduler()
    let deadline = ManualPerformanceDeadlineScheduler(now: 10)
    let ledger = ViewerPerformanceMemoryLedger()
    let controller = ViewerPerformanceDashboardController(
      driver: harness.driver,
      ledger: ledger,
      deliveryScheduler: delivery.value,
      deadlineScheduler: deadline.value,
      uptimeNanoseconds: { 10 }
    )
    let currentTarget = try ViewerPerformanceDashboardTarget.current(
      source: current,
      recordingID: 11,
      deviceSessionID: 12,
      deviceStartMonotonicNanoseconds: 0
    )
    await controller.replace(target: currentTarget, rangeKind: .currentSession).value
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }

    controller.pause()
    await controller.replace(target: currentTarget, rangeKind: .oneMinute).value
    XCTAssertEqual(controller.model.rangeKind, .oneMinute)
    XCTAssertEqual(controller.model.diagnostics.phase, .idle)
    XCTAssertEqual(controller.diagnostics.runningRefreshCount, 0)
    XCTAssertEqual(controller.diagnostics.dirtyRefreshCount, 1)
    controller.resume()
    await waitUntil { delivery.pendingCount == 1 }
    delivery.runNext()
    await waitUntil { controller.model.diagnostics.phase == .ready }
    XCTAssertEqual(controller.model.rangeKind, .oneMinute)

    controller.pause()
    let historicalTarget = try ViewerPerformanceDashboardTarget.historical(
      source: historical,
      anchor: .ended(
        deviceStartMonotonicNanoseconds: 0,
        deviceEndMonotonicNanoseconds: 10
      )
    )
    let replacement = controller.replace(
      target: historicalTarget,
      rangeKind: .currentSession
    )
    XCTAssertNil(controller.model.scope)
    XCTAssertNil(controller.model.cards)
    XCTAssertEqual(controller.diagnostics.cacheEntryCount, 0)
    await replacement.value
    await waitUntil { controller.diagnostics.dirtyRefreshCount == 1 }
    XCTAssertNil(controller.model.cards)
    controller.resume()
    await waitUntil { controller.model.diagnostics.phase == .storageUnavailable }
    XCTAssertEqual(controller.diagnostics.activeDeadlineCount, 0)

    await controller.sealAndWait().value
    XCTAssertEqual(controller.diagnostics.ledgerBytes, 0)
    XCTAssertEqual(controller.diagnostics.ledgerReservationCount, 0)
  }

  @MainActor
  private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<2_000 {
      if predicate() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Timed out waiting for asynchronous state", file: file, line: line)
  }

  private static func makeCurrentPreparation(
    source: ViewerPerformanceSource,
    rangeKind: ViewerPerformanceRangeKind,
    storeScope: ViewerPerformanceStoreScope?,
    revision: UInt64
  ) throws -> ViewerPerformanceProjectionPreparation {
    guard case .current(let runtimeLogicalID, let connectionID) = source else {
      throw ViewerPerformanceStoreFailure.invalidScope
    }
    let liveSlice = try ViewerPerformanceLiveSlice(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      liveGeneration: 1,
      revision: revision,
      anchorMonotonicNanoseconds: 10,
      events: [try makeEvent(source: source, sequence: revision, monotonic: 10)],
      gaps: [],
      applicableOrUncertainCount: 0,
      hasMoreApplicableGaps: false
    )
    return ViewerPerformanceProjectionPreparation(
      receipt: ViewerPerformanceFrozenReceipt(
        source: source,
        storeScope: storeScope,
        liveSlice: liveSlice
      ),
      bounds: try rangeKind.bounds(
        deviceStartMonotonicNanoseconds: 0,
        upperMonotonicNanoseconds: 10
      ),
      deviceStartMonotonicNanoseconds: 0
    )
  }

  private func historicalPreparation(
    source: ViewerPerformanceSource,
    scope: ViewerPerformanceStoreScope
  ) throws -> ViewerPerformanceProjectionPreparation {
    ViewerPerformanceProjectionPreparation(
      receipt: ViewerPerformanceFrozenReceipt(
        source: source,
        storeScope: scope,
        liveSlice: nil
      ),
      bounds: try .currentSession(
        deviceStartMonotonicNanoseconds: 0,
        upperMonotonicNanoseconds: scope.upperMonotonicNanoseconds
      ),
      deviceStartMonotonicNanoseconds: 0
    )
  }

  private func eventPage(
    scope: ViewerPerformanceStoreScope,
    events: [ViewerPerformanceEventCarrier]
  ) throws -> ViewerPerformanceEventPage {
    try ViewerPerformanceEventPage(
      scope: scope,
      events: events,
      examinedCandidateCount: events.count,
      continuation: nil,
      isComplete: true
    )
  }

  private func emptyGapPage() throws -> ViewerPerformanceGapPage {
    try ViewerPerformanceGapPage(
      gaps: [],
      hasMoreRows: false,
      applicableOrUncertainCount: 0,
      hasMoreApplicableGaps: false
    )
  }

  private func storeScope(upper: Int64) throws -> ViewerPerformanceStoreScope {
    try ViewerPerformanceStoreScope(
      storeGeneration: 1,
      recordingID: 11,
      deviceSessionID: 12,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: upper,
      eventUpperRowID: 1,
      gapUpperRowID: 1
    )
  }

  private static func makeEvent(
    source: ViewerPerformanceSource,
    sequence: UInt64,
    monotonic: Int64,
    durable: Bool = false
  ) throws -> ViewerPerformanceEventCarrier {
    let runtimeLogicalID: UUID
    let connectionID: UUID
    switch source {
    case .current(let runtime, let connection):
      runtimeLogicalID = runtime
      connectionID = connection
    case .historical(_, _, let recording, let device):
      runtimeLogicalID = recording
      connectionID = device
    }
    return try ViewerPerformanceEventCarrier(
      locator: durable
        ? .durable(rowID: Int64(sequence), deviceSessionID: 12)
        : .transient(observationID: uuid(UInt8(truncatingIfNeeded: sequence))),
      key: ViewerEventJournalKey(
        runtimeLogicalID: runtimeLogicalID,
        connectionID: connectionID,
        direction: .appToViewer,
        wireSequence: sequence
      ),
      viewerWallMilliseconds: 1_000 + monotonic,
      viewerMonotonicNanoseconds: monotonic,
      content: .canonical(
        Data(
          "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\"process\":{\"cpuPercent\":42}}"
            .utf8
        )
      )
    )
  }

  private func currentSource() -> ViewerPerformanceSource {
    .current(runtimeLogicalID: Self.uuid(1), connectionID: Self.uuid(2))
  }

  private func historicalSource() throws -> ViewerPerformanceSource {
    try .makeHistorical(
      recordingID: 11,
      deviceSessionID: 12,
      recordingLogicalID: Self.uuid(3),
      deviceLogicalID: Self.uuid(4)
    )
  }

  private static func uuid(_ suffix: UInt8) -> UUID {
    UUID(
      uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, suffix
      )
    )
  }
}

final class ViewerPerformanceRawEventResolverTests: XCTestCase {
  @MainActor
  func testRejectsStaleSourceBeforeStoreAndResolvesExactDurableIdentity() async throws {
    let fixture = try currentFixture()
    let live = ExplorerLiveObservationSpy(snapshot: emptyLiveSnapshot(fixture.runtimeLogicalID))
    let store = PerformanceRawEventStoreHarness()
    let resolver = ViewerPerformanceRawEventResolver(store: store.driver, live: live)
    let output = PerformanceRawEventOutcomeBox()
    let stale = try ViewerPerformanceRawEventRequest(
      sourceGeneration: fixture.scope.sourceGeneration + 1,
      key: fixture.key
    )

    XCTAssertTrue(
      resolver.resolve(stale, scope: fixture.scope, target: fixture.target) {
        output.value = $0
      }
    )
    XCTAssertEqual(output.value, .guidance(.sourceChanged))
    XCTAssertEqual(store.requestCount, 0)

    output.value = nil
    let resolved = expectation(description: "Exact durable raw Event resolved")
    XCTAssertTrue(
      resolver.resolve(fixture.request, scope: fixture.scope, target: fixture.target) {
        output.value = $0
        resolved.fulfill()
      }
    )
    await waitUntil { store.requestCount == 1 }
    XCTAssertEqual(store.lastRecordingID, 11)
    XCTAssertEqual(store.lastDeviceSessionID, 12)
    XCTAssertEqual(store.lastKey, fixture.key)
    store.completeNext(.success(.durable(rowID: 31, deviceSessionID: 12)))
    await fulfillment(of: [resolved], timeout: 2)

    let expected = try ViewerPerformanceResolvedRawEvent(
      sourceGeneration: fixture.scope.sourceGeneration,
      key: fixture.key,
      locator: .durable(rowID: 31, deviceSessionID: 12)
    )
    XCTAssertEqual(output.value, .resolved(expected))
    XCTAssertEqual(
      resolver.revalidate(
        expected,
        request: fixture.request,
        scope: fixture.scope,
        target: fixture.target
      ),
      .explorerIdentity(.durable(rowID: 31))
    )
    XCTAssertFalse(String(reflecting: expected).contains(fixture.key.runtimeLogicalID.uuidString))

    output.value = nil
    let invalidStoreLocator = expectation(description: "Store locator kind rejected")
    XCTAssertTrue(
      resolver.resolve(fixture.request, scope: fixture.scope, target: fixture.target) {
        output.value = $0
        invalidStoreLocator.fulfill()
      }
    )
    await waitUntil { store.requestCount == 2 }
    store.completeNext(.success(.transient(observationID: Self.uuid(32))))
    await fulfillment(of: [invalidStoreLocator], timeout: 2)
    XCTAssertEqual(output.value, .failed(.invalidRequest))
    await resolver.sealAndWait().value
    XCTAssertEqual(resolver.pendingWorkCount, 0)
  }

  @MainActor
  func testDurableConfirmationBridgesLiveCommitAndNeverSubstitutesAnEvictedEvent()
    async throws
  {
    let fixture = try currentFixture()
    let live = ExplorerLiveObservationSpy(snapshot: emptyLiveSnapshot(fixture.runtimeLogicalID))
    let transient = ViewerPerformanceEventLocator.transient(observationID: Self.uuid(9))
    live.setPerformanceEventLocator(transient, for: fixture.key)
    let store = PerformanceRawEventStoreHarness()
    let resolver = ViewerPerformanceRawEventResolver(store: store.driver, live: live)
    let output = PerformanceRawEventOutcomeBox()

    let committed = expectation(description: "Live Event became durable")
    XCTAssertTrue(
      resolver.resolve(fixture.request, scope: fixture.scope, target: fixture.target) {
        output.value = $0
        committed.fulfill()
      }
    )
    await waitUntil { store.requestCount == 1 }
    store.completeNext(.success(nil))
    await waitUntil { store.requestCount == 2 }
    store.completeNext(.success(.durable(rowID: 41, deviceSessionID: 12)))
    await fulfillment(of: [committed], timeout: 2)
    guard case .resolved(let durable) = output.value else {
      return XCTFail("Expected the durable confirmation to win")
    }
    XCTAssertEqual(durable.locator, .durable(rowID: 41, deviceSessionID: 12))

    output.value = nil
    let stillLive = expectation(description: "Exact Event remained in the live window")
    XCTAssertTrue(
      resolver.resolve(fixture.request, scope: fixture.scope, target: fixture.target) {
        output.value = $0
        stillLive.fulfill()
      }
    )
    await waitUntil { store.requestCount == 3 }
    store.completeNext(.success(nil))
    await waitUntil { store.requestCount == 4 }
    store.completeNext(.success(nil))
    await fulfillment(of: [stillLive], timeout: 2)
    guard case .resolved(let liveResolution) = output.value else {
      return XCTFail("Expected the exact live Event")
    }
    XCTAssertEqual(liveResolution.locator, transient)
    XCTAssertEqual(
      resolver.revalidate(
        liveResolution,
        request: fixture.request,
        scope: fixture.scope,
        target: fixture.target
      ),
      .explorerIdentity(.transient(fixture.key))
    )

    output.value = nil
    let evicted = expectation(description: "Evicted Event guidance returned")
    XCTAssertTrue(
      resolver.resolve(fixture.request, scope: fixture.scope, target: fixture.target) {
        output.value = $0
        evicted.fulfill()
      }
    )
    await waitUntil { store.requestCount == 5 }
    store.completeNext(.success(nil))
    await waitUntil { store.requestCount == 6 }
    live.setPerformanceEventLocator(nil, for: fixture.key)
    store.completeNext(.success(nil))
    await fulfillment(of: [evicted], timeout: 2)
    XCTAssertEqual(output.value, .guidance(.eventNoLongerAvailable))
    XCTAssertEqual(
      resolver.revalidate(
        liveResolution,
        request: fixture.request,
        scope: fixture.scope,
        target: fixture.target
      ),
      .requiresResolution
    )
    XCTAssertEqual(
      ViewerPerformanceRawEventGuidance.eventNoLongerAvailable.message,
      "The source Event was deleted or evicted and is no longer available."
    )
    await resolver.sealAndWait().value
  }

  @MainActor
  func testHistoricalMissAndCurrentStorageFailureReturnBoundedGuidanceOrExactLiveEvent()
    async throws
  {
    let historical = try historicalFixture()
    let live = ExplorerLiveObservationSpy(snapshot: emptyLiveSnapshot(Self.uuid(30)))
    let store = PerformanceRawEventStoreHarness()
    let resolver = ViewerPerformanceRawEventResolver(store: store.driver, live: live)
    let output = PerformanceRawEventOutcomeBox()

    let deleted = expectation(description: "Deleted historical Event guidance")
    XCTAssertTrue(
      resolver.resolve(
        historical.request,
        scope: historical.scope,
        target: historical.target
      ) {
        output.value = $0
        deleted.fulfill()
      }
    )
    await waitUntil { store.requestCount == 1 }
    store.completeNext(.success(nil))
    await fulfillment(of: [deleted], timeout: 2)
    XCTAssertEqual(output.value, .guidance(.eventNoLongerAvailable))

    let current = try currentFixture()
    let exactLive = ViewerPerformanceEventLocator.transient(observationID: Self.uuid(31))
    live.setPerformanceEventLocator(exactLive, for: current.key)
    output.value = nil
    let liveFallback = expectation(description: "Live fallback after Store failure")
    XCTAssertTrue(
      resolver.resolve(current.request, scope: current.scope, target: current.target) {
        output.value = $0
        liveFallback.fulfill()
      }
    )
    await waitUntil { store.requestCount == 2 }
    store.completeNext(.failure(.unavailable))
    await fulfillment(of: [liveFallback], timeout: 2)
    guard case .resolved(let resolvedLive) = output.value else {
      return XCTFail("Expected the exact live fallback")
    }
    XCTAssertEqual(resolvedLive.locator, exactLive)

    live.setPerformanceEventLocator(nil, for: current.key)
    output.value = nil
    let unavailable = expectation(description: "Storage unavailable guidance")
    XCTAssertTrue(
      resolver.resolve(current.request, scope: current.scope, target: current.target) {
        output.value = $0
        unavailable.fulfill()
      }
    )
    await waitUntil { store.requestCount == 3 }
    store.completeNext(.failure(.unavailable))
    await fulfillment(of: [unavailable], timeout: 2)
    XCTAssertEqual(output.value, .guidance(.storageUnavailable))
    await resolver.sealAndWait().value
  }

  @MainActor
  func testCancellationJoinsOutstandingStoreLookup() async throws {
    let fixture = try currentFixture()
    let live = ExplorerLiveObservationSpy(snapshot: emptyLiveSnapshot(fixture.runtimeLogicalID))
    let store = PerformanceRawEventStoreHarness()
    let resolver = ViewerPerformanceRawEventResolver(store: store.driver, live: live)
    let output = PerformanceRawEventOutcomeBox()
    let cancelled = expectation(description: "Raw Event lookup cancelled")

    XCTAssertTrue(
      resolver.resolve(fixture.request, scope: fixture.scope, target: fixture.target) {
        output.value = $0
        cancelled.fulfill()
      }
    )
    await waitUntil { store.requestCount == 1 }
    let cleanup = resolver.cancelActiveAndWait()
    XCTAssertEqual(store.cancelCount, 1)
    XCTAssertEqual(resolver.pendingWorkCount, 1)
    store.completeNext(.failure(.cancelled))
    await cleanup.value
    await fulfillment(of: [cancelled], timeout: 2)
    XCTAssertEqual(output.value, .cancelled)
    XCTAssertEqual(resolver.pendingWorkCount, 0)
    await resolver.sealAndWait().value
  }

  @MainActor
  private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<2_000 {
      if predicate() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Timed out waiting for asynchronous state", file: file, line: line)
  }

  @MainActor
  private func currentFixture() throws -> (
    runtimeLogicalID: UUID,
    key: ViewerEventJournalKey,
    request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget
  ) {
    let runtimeLogicalID = Self.uuid(1)
    let connectionID = Self.uuid(2)
    let source = ViewerPerformanceSource.current(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID
    )
    let key = ViewerEventJournalKey(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      direction: .appToViewer,
      wireSequence: 7
    )
    let scope = try ViewerPerformanceDashboardScope(
      sourceGeneration: 9,
      source: source,
      rangeKind: .fiveMinutes
    )
    return (
      runtimeLogicalID,
      key,
      try ViewerPerformanceRawEventRequest(sourceGeneration: 9, key: key),
      scope,
      try ViewerPerformanceDashboardTarget.current(
        source: source,
        recordingID: 11,
        deviceSessionID: 12,
        deviceStartMonotonicNanoseconds: 0
      )
    )
  }

  @MainActor
  private func historicalFixture() throws -> (
    request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget
  ) {
    let recordingLogicalID = Self.uuid(3)
    let deviceLogicalID = Self.uuid(4)
    let source = try ViewerPerformanceSource.makeHistorical(
      recordingID: 21,
      deviceSessionID: 22,
      recordingLogicalID: recordingLogicalID,
      deviceLogicalID: deviceLogicalID
    )
    let key = ViewerEventJournalKey(
      runtimeLogicalID: recordingLogicalID,
      connectionID: deviceLogicalID,
      direction: .appToViewer,
      wireSequence: 8
    )
    let scope = try ViewerPerformanceDashboardScope(
      sourceGeneration: 10,
      source: source,
      rangeKind: .currentSession
    )
    return (
      try ViewerPerformanceRawEventRequest(sourceGeneration: 10, key: key),
      scope,
      try ViewerPerformanceDashboardTarget.historical(
        source: source,
        anchor: .ended(
          deviceStartMonotonicNanoseconds: 0,
          deviceEndMonotonicNanoseconds: 100
        )
      )
    )
  }

  private func emptyLiveSnapshot(_ runtimeLogicalID: UUID) -> ViewerLiveProjectionSnapshot {
    ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 1,
      events: [],
      sessions: [],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 0,
        residentConflictCount: 0,
        diagnosticLossCount: 0,
        storeUnavailableCount: 0,
        storeRecoveryCount: 0,
        storeUnavailable: false
      ),
      accountedEventBytes: 0
    )
  }

  private static func uuid(_ suffix: UInt8) -> UUID {
    UUID(
      uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, suffix
      )
    )
  }
}

@MainActor
private final class PerformanceRawEventOutcomeBox {
  var value: ViewerPerformanceRawEventResolutionOutcome?
}

private final class PerformanceRawEventStoreHarness: @unchecked Sendable {
  private struct Pending {
    let operation: ViewerPerformanceRawEventStoreOperation
    let completion: ViewerPerformanceRawEventStoreDriver.Completion
  }

  private let lock = NSLock()
  private var pending: [Pending] = []
  private var storedRequestCount = 0
  private var storedCancelCount = 0
  private var storedLastRecordingID: Int64?
  private var storedLastDeviceSessionID: Int64?
  private var storedLastKey: ViewerEventJournalKey?

  lazy var driver = ViewerPerformanceRawEventStoreDriver(
    resolve: { [weak self] recordingID, deviceSessionID, key, completion in
      self?.append(
        recordingID: recordingID,
        deviceSessionID: deviceSessionID,
        key: key,
        completion: completion
      ) ?? ViewerPerformanceRawEventStoreOperation()
    },
    cancel: { [weak self] operation in
      self?.recordCancellation(operation)
    }
  )

  var requestCount: Int { locked { storedRequestCount } }
  var cancelCount: Int { locked { storedCancelCount } }
  var lastRecordingID: Int64? { locked { storedLastRecordingID } }
  var lastDeviceSessionID: Int64? { locked { storedLastDeviceSessionID } }
  var lastKey: ViewerEventJournalKey? { locked { storedLastKey } }

  func completeNext(
    _ result: Result<ViewerPerformanceEventLocator?, ViewerStoreExplorerFailure>
  ) {
    let completion: ViewerPerformanceRawEventStoreDriver.Completion = locked {
      precondition(!pending.isEmpty)
      return pending.removeFirst().completion
    }
    completion(result)
  }

  private func append(
    recordingID: Int64,
    deviceSessionID: Int64,
    key: ViewerEventJournalKey,
    completion: @escaping ViewerPerformanceRawEventStoreDriver.Completion
  ) -> ViewerPerformanceRawEventStoreOperation {
    let operation = ViewerPerformanceRawEventStoreOperation()
    locked {
      storedRequestCount += 1
      storedLastRecordingID = recordingID
      storedLastDeviceSessionID = deviceSessionID
      storedLastKey = key
      pending.append(Pending(operation: operation, completion: completion))
    }
    return operation
  }

  private func recordCancellation(_ operation: ViewerPerformanceRawEventStoreOperation) {
    locked {
      if pending.contains(where: { $0.operation == operation }) {
        storedCancelCount += 1
      }
    }
  }

  private func locked<Value>(_ body: () -> Value) -> Value {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private final class PerformanceProjectionDriverHarness: @unchecked Sendable {
  typealias Preparation =
    @Sendable (
      ViewerPerformanceDashboardTarget,
      ViewerPerformanceRangeKind,
      ViewerPerformanceProjectionPreparationMode
    ) throws -> Result<
      ViewerPerformanceProjectionPreparation,
      ViewerPerformanceProjectionDriverFailure
    >

  private let lock = NSLock()
  private let prepare: Preparation
  private let currentUptimeNanoseconds: @Sendable () -> Int64?
  private let endTraversalResult: Result<Void, ViewerStoreExplorerFailure>
  private let blockedPreparationMode: ViewerPerformanceProjectionPreparationMode?
  private var eventResults: [Result<ViewerPerformanceEventPage, ViewerStoreExplorerFailure>]
  private var gapResults: [Result<ViewerPerformanceGapPage, ViewerStoreExplorerFailure>]
  private var blockedEvent: ViewerPerformanceProjectionDriver.EventPageCompletion?
  private var blockedPreparation:
    (
      ViewerPerformanceProjectionDriver.PreparationCompletion,
      Result<ViewerPerformanceProjectionPreparation, ViewerPerformanceProjectionDriverFailure>
    )?
  private var storedPreparationModes: [ViewerPerformanceProjectionPreparationMode] = []
  private var storedPrepareWasMainThread = false
  private var storedEventLoadCount = 0
  private var storedGapLoadCount = 0
  private var storedEndTraversalCount = 0
  private var storedCancelCount = 0

  init(
    prepare: @escaping Preparation,
    eventResults: [Result<ViewerPerformanceEventPage, ViewerStoreExplorerFailure>],
    gapResults: [Result<ViewerPerformanceGapPage, ViewerStoreExplorerFailure>],
    endTraversalResult: Result<Void, ViewerStoreExplorerFailure> = .success(()),
    blockedPreparationMode: ViewerPerformanceProjectionPreparationMode? = nil,
    currentUptimeNanoseconds: @escaping @Sendable () -> Int64?
  ) {
    self.prepare = prepare
    self.eventResults = eventResults
    self.gapResults = gapResults
    self.endTraversalResult = endTraversalResult
    self.blockedPreparationMode = blockedPreparationMode
    self.currentUptimeNanoseconds = currentUptimeNanoseconds
  }

  var driver: ViewerPerformanceProjectionDriver {
    ViewerPerformanceProjectionDriver(
      prepare: { [weak self] target, rangeKind, mode, completion in
        guard let self else {
          completion(.failure(.projection(.unavailable)))
          return nil
        }
        do {
          let result = try self.prepare(target, rangeKind, mode)
          self.lock.lock()
          self.storedPreparationModes.append(mode)
          self.storedPrepareWasMainThread = Thread.isMainThread
          if self.blockedPreparationMode == mode {
            self.blockedPreparation = (completion, result)
            self.lock.unlock()
          } else {
            self.lock.unlock()
            completion(result)
          }
        } catch let failure as ViewerPerformanceStoreFailure {
          completion(.failure(.projection(failure)))
        } catch {
          completion(.failure(.projection(.unavailable)))
        }
        return ViewerPerformanceProjectionOperationToken()
      },
      loadEventPage: { [weak self] _, completion in
        guard let self else {
          completion(.failure(.unavailable))
          return ViewerPerformanceProjectionOperationToken()
        }
        let result: Result<ViewerPerformanceEventPage, ViewerStoreExplorerFailure>?
        self.lock.lock()
        self.storedEventLoadCount += 1
        if self.eventResults.isEmpty {
          result = nil
          self.blockedEvent = completion
        } else {
          result = self.eventResults.removeFirst()
        }
        self.lock.unlock()
        if let result { completion(result) }
        return ViewerPerformanceProjectionOperationToken()
      },
      loadGapPage: { [weak self] completion in
        guard let self else {
          completion(.failure(.unavailable))
          return ViewerPerformanceProjectionOperationToken()
        }
        let result: Result<ViewerPerformanceGapPage, ViewerStoreExplorerFailure>
        self.lock.lock()
        self.storedGapLoadCount += 1
        result = self.gapResults.isEmpty ? .failure(.unavailable) : self.gapResults.removeFirst()
        self.lock.unlock()
        completion(result)
        return ViewerPerformanceProjectionOperationToken()
      },
      endTraversal: { [weak self] completion in
        self?.lock.lock()
        self?.storedEndTraversalCount += 1
        self?.lock.unlock()
        completion(self?.endTraversalResult ?? .failure(.unavailable))
        return ViewerPerformanceProjectionOperationToken()
      },
      cancel: { [weak self] _ in
        self?.lock.lock()
        self?.storedCancelCount += 1
        self?.lock.unlock()
      },
      currentUptimeNanoseconds: currentUptimeNanoseconds
    )
  }

  var preparationModes: [ViewerPerformanceProjectionPreparationMode] {
    lock.lock()
    defer { lock.unlock() }
    return storedPreparationModes
  }

  var prepareWasMainThread: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storedPrepareWasMainThread
  }

  var eventLoadCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedEventLoadCount
  }

  var gapLoadCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedGapLoadCount
  }

  var endTraversalCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedEndTraversalCount
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedCancelCount
  }

  func resolveBlockedEvent(
    _ result: Result<ViewerPerformanceEventPage, ViewerStoreExplorerFailure>
  ) {
    let completion: ViewerPerformanceProjectionDriver.EventPageCompletion?
    lock.lock()
    completion = blockedEvent
    blockedEvent = nil
    lock.unlock()
    completion?(result)
  }

  func resolveBlockedPreparation() {
    let blocked:
      (
        ViewerPerformanceProjectionDriver.PreparationCompletion,
        Result<ViewerPerformanceProjectionPreparation, ViewerPerformanceProjectionDriverFailure>
      )?
    lock.lock()
    blocked = blockedPreparation
    blockedPreparation = nil
    lock.unlock()
    if let blocked { blocked.0(blocked.1) }
  }
}

private final class PerformanceProjectionRunOutputBox: @unchecked Sendable {
  private let lock = NSLock()
  private var output: ViewerPerformanceProjectionRunOutput?

  func set(_ value: ViewerPerformanceProjectionRunOutput) {
    lock.lock()
    output = value
    lock.unlock()
  }

  var value: ViewerPerformanceProjectionRunOutput? {
    lock.lock()
    defer { lock.unlock() }
    return output
  }
}

private final class LockedPerformanceClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Int64

  init(_ value: Int64) {
    storedValue = value
  }

  var value: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return storedValue
  }

  func set(_ value: Int64) {
    lock.lock()
    storedValue = value
    lock.unlock()
  }
}

@MainActor
private final class PerformanceControllerOwner {
  weak var controller: ViewerPerformanceDashboardController?
  var cleanup: Task<Void, Never>?
  var claimCount = 0
}

final class ViewerAnalysisModeCoordinatorTests: XCTestCase {
  func testTargetCompilerRequiresExactlyOneDeviceAndBuildsExactHistoricalAnchors() throws {
    let recordingLogicalID = UUID()
    let deviceLogicalID = UUID()
    let recording = makeRecordingRow(
      logicalID: recordingLogicalID,
      endedMonotonicNanoseconds: 900
    )
    let closed = makeDeviceRow(
      logicalID: deviceLogicalID,
      state: "closed",
      start: 100,
      end: 400
    )

    XCTAssertEqual(
      ViewerPerformanceTargetCompiler.compile(
        source: .historical(
          recordingID: recording.rowID,
          recordingLogicalID: recordingLogicalID
        ),
        selectedDeviceIDs: [],
        catalogRecordingID: recording.rowID,
        recordingRows: [recording],
        deviceRows: [closed],
        sessions: []
      ),
      .guidance(.selectOneDevice)
    )
    XCTAssertEqual(
      ViewerAnalysisGuidance.selectOneDevice.message,
      "Select one device to view performance"
    )

    let closedSelection = ViewerPerformanceTargetCompiler.compile(
      source: .historical(
        recordingID: recording.rowID,
        recordingLogicalID: recordingLogicalID
      ),
      selectedDeviceIDs: [deviceLogicalID],
      catalogRecordingID: recording.rowID,
      recordingRows: [recording],
      deviceRows: [closed],
      sessions: []
    )
    guard case .target(let closedTarget) = closedSelection else {
      return XCTFail("Expected an exact closed historical target")
    }
    XCTAssertEqual(closedTarget.historicalAnchor?.kind, .ended)
    XCTAssertEqual(closedTarget.historicalAnchor?.upperMonotonicNanoseconds, 400)
    XCTAssertEqual(closedTarget.storeIdentity.deviceSessionID, closed.rowID)

    let interrupted = makeDeviceRow(
      logicalID: deviceLogicalID,
      state: "recoveredAfterInterruption",
      start: 100,
      end: 500
    )
    let interruptedSelection = ViewerPerformanceTargetCompiler.compile(
      source: .historical(
        recordingID: recording.rowID,
        recordingLogicalID: recordingLogicalID
      ),
      selectedDeviceIDs: [deviceLogicalID],
      catalogRecordingID: recording.rowID,
      recordingRows: [recording],
      deviceRows: [interrupted],
      sessions: []
    )
    guard case .target(let interruptedTarget) = interruptedSelection else {
      return XCTFail("Expected an exact interrupted historical target")
    }
    XCTAssertEqual(interruptedTarget.historicalAnchor?.kind, .interrupted)
    XCTAssertEqual(interruptedTarget.historicalAnchor?.upperMonotonicNanoseconds, 900)

    let empty = makeDeviceRow(
      logicalID: deviceLogicalID,
      state: "closed",
      start: 100,
      end: 100
    )
    let emptySelection = ViewerPerformanceTargetCompiler.compile(
      source: .historical(
        recordingID: recording.rowID,
        recordingLogicalID: recordingLogicalID
      ),
      selectedDeviceIDs: [deviceLogicalID],
      catalogRecordingID: recording.rowID,
      recordingRows: [recording],
      deviceRows: [empty],
      sessions: []
    )
    guard case .target(let emptyTarget) = emptySelection else {
      return XCTFail("Expected an exact empty historical target")
    }
    XCTAssertEqual(emptyTarget.historicalAnchor?.kind, .empty)
    XCTAssertEqual(emptyTarget.historicalAnchor?.upperMonotonicNanoseconds, 100)
  }

  @MainActor
  func testEventsReleaseCompletesBeforePerformanceStarts() async throws {
    let target = try makeHistoricalTarget()
    let eventRelease = AsyncTestGate()
    let prepareCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: immediateFailurePerformanceDriver(prepareCount: prepareCount),
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .target(target) },
        deactivate: { Task { await eventRelease.wait() } },
        activate: { Task {} },
        reveal: { _ in }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )

    coordinator.showPerformance()
    await Task.yield()
    eventRelease.waitUntilEntered()
    XCTAssertEqual(coordinator.mode, .performance)
    XCTAssertEqual(prepareCount.value, 0)
    XCTAssertFalse(performance.isAnalysisActive)

    eventRelease.open()
    await waitUntil { prepareCount.value == 1 }
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    XCTAssertEqual(prepareCount.value, 1)
    XCTAssertTrue(performance.isAnalysisActive)
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testStoreReplacementDuringBlockedPerformanceTransitionRecompilesOnceAfterJoin()
    async throws
  {
    let target = try makeHistoricalTarget()
    let eventRelease = AsyncTestGate()
    let prepareCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: immediateFailurePerformanceDriver(prepareCount: prepareCount),
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .target(target) },
        deactivate: { Task { await eventRelease.wait() } },
        activate: { Task {} },
        reveal: { _ in }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )

    coordinator.showPerformance()
    await Task.yield()
    eventRelease.waitUntilEntered()
    coordinator.noteStoreReplaced()
    XCTAssertEqual(prepareCount.value, 0)
    XCTAssertNil(performance.model.scope)

    eventRelease.open()
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    await waitUntil { prepareCount.value == 1 }
    XCTAssertEqual(coordinator.mode, .performance)
    XCTAssertEqual(prepareCount.value, 1)
    XCTAssertEqual(performance.currentTarget, target)
    XCTAssertTrue(performance.isAnalysisActive)
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testRapidReturnToEventsCannotStartSupersededPerformanceTransition() async throws {
    let target = try makeHistoricalTarget()
    let eventRelease = AsyncTestGate()
    let prepareCount = LockedTestCounter()
    let eventActivationCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: immediateFailurePerformanceDriver(prepareCount: prepareCount),
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .target(target) },
        deactivate: { Task { await eventRelease.wait() } },
        activate: {
          eventActivationCount.increment()
          return Task {}
        },
        reveal: { _ in }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )

    coordinator.showPerformance()
    await Task.yield()
    eventRelease.waitUntilEntered()
    coordinator.showEvents()
    XCTAssertEqual(coordinator.mode, .events)
    XCTAssertEqual(prepareCount.value, 0)
    XCTAssertEqual(eventActivationCount.value, 0)

    eventRelease.open()
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    XCTAssertEqual(prepareCount.value, 0)
    XCTAssertEqual(eventActivationCount.value, 1)
    XCTAssertFalse(performance.isAnalysisActive)
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testPerformanceTraversalReleaseCompletesBeforeEventsReactivate() async throws {
    let target = try makeHistoricalTarget()
    let probe = try AnalysisPerformanceDriverProbe(target: target)
    let eventActivationCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: probe.driver,
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .target(target) },
        deactivate: { Task {} },
        activate: {
          eventActivationCount.increment()
          return Task {}
        },
        reveal: { _ in }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )

    coordinator.showPerformance()
    await waitUntil { probe.eventPageRequestCount == 1 }
    XCTAssertTrue(performance.isAnalysisActive)

    coordinator.showEvents()
    probe.waitUntilTraversalReleaseRequested()
    XCTAssertEqual(eventActivationCount.value, 0)
    XCTAssertFalse(performance.isAnalysisActive)

    probe.releaseTraversal()
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    XCTAssertEqual(eventActivationCount.value, 1)
    XCTAssertEqual(coordinator.mode, .events)
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testInvalidSelectionShowsFixedGuidanceWithoutPerformanceTraversal() async {
    let prepareCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: immediateFailurePerformanceDriver(prepareCount: prepareCount),
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .guidance(.selectOneDevice) },
        deactivate: { Task {} },
        activate: { Task {} },
        reveal: { _ in }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )

    coordinator.showPerformance()
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    XCTAssertEqual(coordinator.guidance, .selectOneDevice)
    XCTAssertEqual(prepareCount.value, 0)
    XCTAssertFalse(performance.isAnalysisActive)
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testPausedRangeControlRetainsOneSuccessorUntilResume() async throws {
    let target = try makeHistoricalTarget()
    let prepareCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: immediateFailurePerformanceDriver(prepareCount: prepareCount),
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .target(target) },
        deactivate: { Task {} },
        activate: { Task {} },
        reveal: { _ in }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )

    coordinator.showPerformance()
    await waitUntil { prepareCount.value == 1 }
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    XCTAssertEqual(prepareCount.value, 1)
    coordinator.setPerformancePaused(true)
    XCTAssertTrue(coordinator.isPerformancePaused)
    coordinator.setPerformanceRange(.oneMinute)
    await waitUntil {
      performance.currentRangeKind == .oneMinute && performance.isAnalysisActive
    }
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    XCTAssertEqual(coordinator.performanceRangeKind, .oneMinute)
    XCTAssertTrue(coordinator.isPerformancePaused)
    XCTAssertEqual(prepareCount.value, 1)

    coordinator.setPerformancePaused(false)
    await waitUntil { prepareCount.value == 2 }
    XCTAssertFalse(coordinator.isPerformancePaused)
    XCTAssertEqual(performance.currentRangeKind, .oneMinute)
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testStoreReplacementDuringBlockedRangeTransitionStartsOnlyLatestRangeAfterJoin()
    async throws
  {
    let target = try makeHistoricalTarget()
    let probe = try AnalysisPerformanceDriverProbe(target: target)
    let performance = ViewerPerformanceDashboardController(
      driver: probe.driver,
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .target(target) },
        deactivate: { Task {} },
        activate: { Task {} },
        reveal: { _ in }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )

    coordinator.showPerformance()
    await waitUntil { probe.eventPageRequestCount == 1 }
    coordinator.setPerformanceRange(.oneMinute)
    probe.waitUntilTraversalReleaseRequested()
    coordinator.noteStoreReplaced()
    XCTAssertEqual(probe.eventPageRequestCount, 1)
    XCTAssertNil(performance.model.scope)

    probe.releaseTraversal()
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    await waitUntil { probe.eventPageRequestCount == 2 }
    XCTAssertEqual(coordinator.mode, .performance)
    XCTAssertEqual(coordinator.performanceRangeKind, .oneMinute)
    XCTAssertEqual(performance.currentRangeKind, .oneMinute)
    XCTAssertTrue(performance.isAnalysisActive)

    let cleanup = coordinator.sealAndWait()
    probe.waitUntilTraversalReleaseRequested()
    probe.releaseTraversal()
    await cleanup.value
  }

  @MainActor
  func testStoreReplacementDuringBlockedRawRevealCancelsResolutionBeforeEventsReactivate()
    async throws
  {
    let target = try makeCurrentTarget()
    let prepareCount = LockedTestCounter()
    let eventActivationCount = LockedTestCounter()
    let revealCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: try immediateCurrentSuccessPerformanceDriver(
        target: target,
        prepareCount: prepareCount
      ),
      analysisActive: false
    )
    let rawProbe = AnalysisRawResolverProbe()
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .target(target) },
        deactivate: { Task {} },
        activate: {
          eventActivationCount.increment()
          return Task {}
        },
        reveal: { _ in revealCount.increment() }
      ),
      performanceController: performance,
      rawResolver: rawProbe.makeResolver(runtimeLogicalID: uuid(1))
    )

    coordinator.showPerformance()
    await waitUntil { performance.model.diagnostics.phase == .ready }
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    let bucketIndex = try XCTUnwrap(
      performance.model.buckets.firstIndex {
        $0.numeric.accumulator(for: .cpuPercent).representative != nil
      }
    )
    XCTAssertNotNil(
      performance.rawEventRequest(bucketIndex: bucketIndex, metric: .cpuPercent)
    )

    coordinator.openRawEvent(bucketIndex: bucketIndex, metric: .cpuPercent)
    await waitUntil { rawProbe.resolveRequestCount == 1 }
    XCTAssertEqual(coordinator.mode, .events)
    XCTAssertEqual(rawProbe.cancelCount, 0)
    coordinator.noteStoreReplaced()

    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    XCTAssertEqual(rawProbe.cancelCount, 1)
    XCTAssertEqual(coordinator.diagnostics.rawResolutionWorkCount, 0)
    XCTAssertEqual(eventActivationCount.value, 1)
    XCTAssertEqual(revealCount.value, 0)
    XCTAssertEqual(prepareCount.value, 1)
    XCTAssertEqual(coordinator.mode, .events)
    XCTAssertNil(performance.model.scope)
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testStoreReplacementAdvancesPerformanceSourceGenerationAfterJoiningRefresh() async throws {
    let target = try makeHistoricalTarget()
    let prepareCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: immediateFailurePerformanceDriver(prepareCount: prepareCount),
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .target(target) },
        deactivate: { Task {} },
        activate: { Task {} },
        reveal: { _ in }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )

    coordinator.showPerformance()
    await waitUntil { prepareCount.value == 1 }
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    let firstGeneration = try XCTUnwrap(performance.model.scope?.sourceGeneration)

    coordinator.noteStoreChanged()
    await waitUntil { prepareCount.value == 2 }
    XCTAssertEqual(performance.model.scope?.sourceGeneration, firstGeneration)

    coordinator.noteStoreReplaced()
    XCTAssertNil(performance.model.scope)
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    await waitUntil { prepareCount.value == 3 }
    XCTAssertGreaterThan(
      try XCTUnwrap(performance.model.scope?.sourceGeneration), firstGeneration
    )
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testStoreReplacementWaitsForEventRematerializationBeforeOneNewTargetSuccessor()
    async throws
  {
    let oldTarget = try makeHistoricalTarget()
    let newTarget = try ViewerPerformanceDashboardTarget.historical(
      source: .makeHistorical(
        recordingID: 21,
        deviceSessionID: 27,
        recordingLogicalID: uuid(7),
        deviceLogicalID: uuid(8)
      ),
      anchor: .ended(
        deviceStartMonotonicNanoseconds: 20,
        deviceEndMonotonicNanoseconds: 200
      )
    )
    let selection = AnalysisTargetSelectionBox(.target(oldTarget))
    let rematerialization = AsyncTestGate()
    let prepareCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: immediateFailurePerformanceDriver(prepareCount: prepareCount),
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { selection.value },
        deactivate: { Task {} },
        activate: { Task {} },
        reveal: { _ in },
        rematerializeStore: {
          Task { @MainActor in
            await rematerialization.wait()
            selection.value = .target(newTarget)
          }
        }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )

    coordinator.showPerformance()
    await waitUntil { prepareCount.value == 1 }
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    XCTAssertEqual(performance.currentTarget, oldTarget)

    coordinator.noteStoreReplaced()
    await Task.yield()
    rematerialization.waitUntilEntered()
    XCTAssertNil(performance.model.scope)
    XCTAssertEqual(prepareCount.value, 1)

    rematerialization.open()
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    await waitUntil { prepareCount.value == 2 }
    XCTAssertEqual(performance.currentTarget, newTarget)
    XCTAssertEqual(prepareCount.value, 2)
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testUserSelectionRematerializationReactivatesEventsOnlyAfterReceipt() async {
    let activationCount = LockedTestCounter()
    let handlerBox = AnalysisRematerializationHandlerBox()
    let prepareCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: immediateFailurePerformanceDriver(prepareCount: prepareCount),
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .guidance(.sourceUnavailable) },
        deactivate: { Task {} },
        activate: {
          activationCount.increment()
          return Task {}
        },
        reveal: { _ in },
        setRematerializationHandler: { handlerBox.handler = $0 }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )
    let rematerialization = AsyncTestGate()
    let receipt = Task { @MainActor in await rematerialization.wait() }
    let handler = try? XCTUnwrap(handlerBox.handler)
    XCTAssertNotNil(handler)

    handler?(receipt)
    await Task.yield()
    rematerialization.waitUntilEntered()
    XCTAssertEqual(coordinator.mode, .events)
    XCTAssertEqual(activationCount.value, 0)
    XCTAssertEqual(coordinator.diagnostics.pendingTransitionCount, 1)

    rematerialization.open()
    await waitUntil {
      activationCount.value == 1 && coordinator.diagnostics.pendingTransitionCount == 0
    }
    XCTAssertEqual(coordinator.mode, .events)
    XCTAssertEqual(activationCount.value, 1)
    XCTAssertEqual(prepareCount.value, 0)
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testUserSelectionRematerializationRebuildsPerformanceOnlyAfterReceipt() async throws {
    let oldTarget = try makeHistoricalTarget()
    let newTarget = try ViewerPerformanceDashboardTarget.historical(
      source: .makeHistorical(
        recordingID: 31,
        deviceSessionID: 37,
        recordingLogicalID: uuid(9),
        deviceLogicalID: uuid(10)
      ),
      anchor: .ended(
        deviceStartMonotonicNanoseconds: 30,
        deviceEndMonotonicNanoseconds: 300
      )
    )
    let selection = AnalysisTargetSelectionBox(.target(oldTarget))
    let handlerBox = AnalysisRematerializationHandlerBox()
    let prepareCount = LockedTestCounter()
    let performance = ViewerPerformanceDashboardController(
      driver: immediateFailurePerformanceDriver(prepareCount: prepareCount),
      analysisActive: false
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { selection.value },
        deactivate: { Task {} },
        activate: { Task {} },
        reveal: { _ in },
        setRematerializationHandler: { handlerBox.handler = $0 }
      ),
      performanceController: performance,
      rawResolver: makeRawResolver(runtimeLogicalID: UUID())
    )

    coordinator.showPerformance()
    await waitUntil { prepareCount.value == 1 }
    await waitUntil { coordinator.diagnostics.pendingTransitionCount == 0 }
    XCTAssertEqual(performance.currentTarget, oldTarget)

    let rematerialization = AsyncTestGate()
    let receipt = Task { @MainActor in
      await rematerialization.wait()
      selection.value = .target(newTarget)
    }
    let handler = try XCTUnwrap(handlerBox.handler)
    handler(receipt)
    await Task.yield()
    rematerialization.waitUntilEntered()
    XCTAssertEqual(coordinator.mode, .performance)
    XCTAssertNil(performance.model.scope)
    XCTAssertEqual(prepareCount.value, 1)
    XCTAssertEqual(coordinator.diagnostics.pendingTransitionCount, 1)

    rematerialization.open()
    await waitUntil {
      prepareCount.value == 2 && coordinator.diagnostics.pendingTransitionCount == 0
    }
    XCTAssertEqual(performance.currentTarget, newTarget)
    XCTAssertTrue(performance.isAnalysisActive)
    XCTAssertEqual(prepareCount.value, 2)
    await coordinator.sealAndWait().value
  }

  private func makeRecordingRow(
    logicalID: UUID,
    endedMonotonicNanoseconds: Int64?
  ) -> ViewerRecordingCatalogRow {
    ViewerRecordingCatalogRow(
      rowID: 11,
      logicalID: logicalID,
      revision: 1,
      name: nil,
      note: nil,
      pinned: false,
      state: "closed",
      startedWallMilliseconds: 1,
      startedMonotonicNanoseconds: 10,
      endedWallMilliseconds: 2,
      endedMonotonicNanoseconds: endedMonotonicNanoseconds,
      deviceCount: 1,
      latestDevice: nil,
      hasGap: false,
      hasDrop: false
    )
  }

  private func makeDeviceRow(
    logicalID: UUID,
    state: String,
    start: Int64,
    end: Int64?
  ) -> ViewerDeviceCatalogRow {
    ViewerDeviceCatalogRow(
      rowID: 17,
      logicalID: logicalID,
      recordingID: 11,
      installationAlias: "App 00000001",
      connectionAlias: "connection-1",
      connectionOrdinal: 1,
      revision: 1,
      displayName: nil,
      state: state,
      partialHistory: state == "recoveredAfterInterruption",
      applicationIdentifier: nil,
      applicationVersion: nil,
      startedWallMilliseconds: 1,
      startedMonotonicNanoseconds: start,
      endedWallMilliseconds: end.map { _ in 2 },
      endedMonotonicNanoseconds: end,
      hasGap: false,
      hasDrop: false
    )
  }

  private func makeHistoricalTarget() throws -> ViewerPerformanceDashboardTarget {
    let source = try ViewerPerformanceSource.makeHistorical(
      recordingID: 11,
      deviceSessionID: 17,
      recordingLogicalID: UUID(),
      deviceLogicalID: UUID()
    )
    return try .historical(
      source: source,
      anchor: .ended(
        deviceStartMonotonicNanoseconds: 10,
        deviceEndMonotonicNanoseconds: 100
      )
    )
  }

  private func makeCurrentTarget() throws -> ViewerPerformanceDashboardTarget {
    let source = ViewerPerformanceSource.current(
      runtimeLogicalID: uuid(1),
      connectionID: uuid(2)
    )
    return try .current(
      source: source,
      recordingID: 11,
      deviceSessionID: 17,
      deviceStartMonotonicNanoseconds: 0
    )
  }

  private func immediateCurrentSuccessPerformanceDriver(
    target: ViewerPerformanceDashboardTarget,
    prepareCount: LockedTestCounter
  ) throws -> ViewerPerformanceProjectionDriver {
    guard case .current(let runtimeLogicalID, let connectionID) = target.source else {
      throw ViewerPerformanceStoreFailure.invalidScope
    }
    let event = try ViewerPerformanceEventCarrier(
      locator: .transient(observationID: uuid(3)),
      key: ViewerEventJournalKey(
        runtimeLogicalID: runtimeLogicalID,
        connectionID: connectionID,
        direction: .appToViewer,
        wireSequence: 1
      ),
      viewerWallMilliseconds: 10,
      viewerMonotonicNanoseconds: 10,
      content: .canonical(
        Data(
          "{\"schemaVersion\":1,\"sampledAt\":\"2026-07-14T01:02:03Z\",\"sampleIntervalMilliseconds\":1000,\"process\":{\"cpuPercent\":42}}"
            .utf8
        )
      )
    )
    let liveSlice = try ViewerPerformanceLiveSlice(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      liveGeneration: 1,
      revision: 1,
      anchorMonotonicNanoseconds: 10,
      events: [event],
      gaps: [],
      applicableOrUncertainCount: 0,
      hasMoreApplicableGaps: false
    )
    let receipt = ViewerPerformanceFrozenReceipt(
      source: target.source,
      storeScope: nil,
      liveSlice: liveSlice
    )
    return ViewerPerformanceProjectionDriver(
      prepare: { _, rangeKind, _, completion in
        prepareCount.increment()
        do {
          completion(
            .success(
              ViewerPerformanceProjectionPreparation(
                receipt: receipt,
                bounds: try rangeKind.bounds(
                  deviceStartMonotonicNanoseconds: 0,
                  upperMonotonicNanoseconds: 10
                ),
                deviceStartMonotonicNanoseconds: 0
              )
            ))
        } catch {
          completion(.failure(.projection(.invalidScope)))
        }
        return ViewerPerformanceProjectionOperationToken()
      },
      loadEventPage: { _, completion in
        completion(.failure(.unavailable))
        return ViewerPerformanceProjectionOperationToken()
      },
      loadGapPage: { completion in
        completion(.failure(.unavailable))
        return ViewerPerformanceProjectionOperationToken()
      },
      endTraversal: { completion in
        completion(.success(()))
        return ViewerPerformanceProjectionOperationToken()
      },
      cancel: { _ in },
      currentUptimeNanoseconds: { 10 }
    )
  }

  private func immediateFailurePerformanceDriver(
    prepareCount: LockedTestCounter
  ) -> ViewerPerformanceProjectionDriver {
    ViewerPerformanceProjectionDriver(
      prepare: { _, _, _, completion in
        prepareCount.increment()
        completion(.failure(.store(.unavailable)))
        return ViewerPerformanceProjectionOperationToken()
      },
      loadEventPage: { _, completion in
        completion(.failure(.unavailable))
        return ViewerPerformanceProjectionOperationToken()
      },
      loadGapPage: { completion in
        completion(.failure(.unavailable))
        return ViewerPerformanceProjectionOperationToken()
      },
      endTraversal: { completion in
        completion(.success(()))
        return ViewerPerformanceProjectionOperationToken()
      },
      cancel: { _ in },
      currentUptimeNanoseconds: { 100 }
    )
  }

  private func uuid(_ suffix: UInt8) -> UUID {
    UUID(
      uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, suffix
      )
    )
  }

  @MainActor
  private func makeRawResolver(runtimeLogicalID: UUID) -> ViewerPerformanceRawEventResolver {
    ViewerPerformanceRawEventResolver(
      store: ViewerPerformanceRawEventStoreDriver(
        resolve: { _, _, _, completion in
          completion(.success(nil))
          return ViewerPerformanceRawEventStoreOperation()
        },
        cancel: { _ in }
      ),
      live: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    )
  }

  @MainActor
  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<2_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for analysis coordination", file: file, line: line)
  }
}

@MainActor
private final class AnalysisTargetSelectionBox {
  var value: ViewerPerformanceTargetSelection

  init(_ value: ViewerPerformanceTargetSelection) {
    self.value = value
  }
}

@MainActor
private final class AnalysisRematerializationHandlerBox {
  var handler: ViewerAnalysisEventDriver.RematerializationHandler?
}

private final class AnalysisPerformanceDriverProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let eventPageRequested = DispatchSemaphore(value: 0)
  private let traversalReleaseRequested = DispatchSemaphore(value: 0)
  private var storedEventPageRequestCount = 0
  private var eventPageCompletion: ViewerPerformanceProjectionDriver.EventPageCompletion?
  private var traversalCompletion: ViewerPerformanceProjectionDriver.EndCompletion?
  private let preparation: ViewerPerformanceProjectionPreparation
  lazy var driver: ViewerPerformanceProjectionDriver = makeDriver()

  init(target: ViewerPerformanceDashboardTarget) throws {
    let storeScope = try ViewerPerformanceStoreScope(
      storeGeneration: 1,
      recordingID: target.storeIdentity.recordingID,
      deviceSessionID: target.storeIdentity.deviceSessionID,
      lowerMonotonicNanoseconds: 10,
      upperMonotonicNanoseconds: 100,
      eventUpperRowID: 100,
      gapUpperRowID: 100
    )
    preparation = ViewerPerformanceProjectionPreparation(
      receipt: ViewerPerformanceFrozenReceipt(
        source: target.source,
        storeScope: storeScope,
        liveSlice: nil
      ),
      bounds: try ViewerPerformanceRangeBounds(
        lowerMonotonicNanoseconds: 10,
        upperMonotonicNanoseconds: 100
      ),
      deviceStartMonotonicNanoseconds: 10
    )
  }

  private func makeDriver() -> ViewerPerformanceProjectionDriver {
    ViewerPerformanceProjectionDriver(
      prepare: { _, _, _, completion in
        completion(.success(self.preparation))
        return ViewerPerformanceProjectionOperationToken()
      },
      loadEventPage: { [weak self] _, completion in
        guard let self else { return ViewerPerformanceProjectionOperationToken() }
        self.lock.lock()
        self.storedEventPageRequestCount += 1
        self.eventPageCompletion = completion
        self.lock.unlock()
        self.eventPageRequested.signal()
        return ViewerPerformanceProjectionOperationToken()
      },
      loadGapPage: { completion in
        completion(.failure(.unavailable))
        return ViewerPerformanceProjectionOperationToken()
      },
      endTraversal: { [weak self] completion in
        guard let self else { return ViewerPerformanceProjectionOperationToken() }
        self.lock.lock()
        self.traversalCompletion = completion
        self.lock.unlock()
        self.traversalReleaseRequested.signal()
        return ViewerPerformanceProjectionOperationToken()
      },
      cancel: { [weak self] _ in
        let completion: ViewerPerformanceProjectionDriver.EventPageCompletion?
        self?.lock.lock()
        completion = self?.eventPageCompletion
        self?.eventPageCompletion = nil
        self?.lock.unlock()
        completion?(.failure(.cancelled))
      },
      currentUptimeNanoseconds: { 100 }
    )
  }

  var eventPageRequestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedEventPageRequestCount
  }

  func waitUntilTraversalReleaseRequested() {
    XCTAssertEqual(traversalReleaseRequested.wait(timeout: .now() + 2), .success)
  }

  func releaseTraversal() {
    let completion: ViewerPerformanceProjectionDriver.EndCompletion?
    lock.lock()
    completion = traversalCompletion
    traversalCompletion = nil
    lock.unlock()
    completion?(.success(()))
  }
}

private final class AnalysisRawResolverProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var completion: ViewerPerformanceRawEventStoreDriver.Completion?
  private var storedResolveRequestCount = 0
  private var storedCancelCount = 0

  @MainActor
  func makeResolver(runtimeLogicalID: UUID) -> ViewerPerformanceRawEventResolver {
    ViewerPerformanceRawEventResolver(
      store: ViewerPerformanceRawEventStoreDriver(
        resolve: { [weak self] _, _, _, completion in
          guard let self else { return ViewerPerformanceRawEventStoreOperation() }
          self.lock.lock()
          self.completion = completion
          self.storedResolveRequestCount += 1
          self.lock.unlock()
          return ViewerPerformanceRawEventStoreOperation()
        },
        cancel: { [weak self] _ in self?.cancel() }
      ),
      live: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    )
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedCancelCount
  }

  var resolveRequestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedResolveRequestCount
  }

  private func cancel() {
    let pending: ViewerPerformanceRawEventStoreDriver.Completion?
    lock.lock()
    storedCancelCount += 1
    pending = completion
    completion = nil
    lock.unlock()
    pending?(.failure(.cancelled))
  }
}

final class ViewerFoundationTests: XCTestCase {
  func testPairingGeneratorUsesCanonicalAlphabetAndRejectsBiasedBytes() throws {
    let generator = ViewerPairingCodeGenerator { _ in
      [255, 0, 1, 2, 3, 4, 5]
    }

    XCTAssertEqual(try generator.generate().canonicalValue, "ABCDEF")
  }

  func testPairingGeneratorPropagatesRandomSourceFailure() {
    let generator = ViewerPairingCodeGenerator { _ in
      throw ViewerPairingCodeGenerationError()
    }

    XCTAssertThrowsError(try generator.generate()) { error in
      XCTAssertEqual(error as? ViewerPairingCodeGenerationError, ViewerPairingCodeGenerationError())
    }
  }

  func testPairingGeneratorFailsClosedWhenRandomSourceNeverProducesUsableBytes() {
    let generator = ViewerPairingCodeGenerator { count in
      Array(repeating: 255, count: count)
    }

    XCTAssertThrowsError(try generator.generate()) { error in
      XCTAssertEqual(error as? ViewerPairingCodeGenerationError, ViewerPairingCodeGenerationError())
    }
  }

  @MainActor
  func testApplicationModelStartsOnceAndStopsIdempotently() async throws {
    let generationCount = LockedTestCounter()
    let listener = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let identity = try EndpointID(rawValue: "viewer-test")
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: ViewerRuntimeDependencies(
        loadIdentity: {
          ViewerPreparedIdentity(
            installationID: identity,
            makeListener: { _ in listener }
          )
        },
        resetTLSIdentity: {},
        resetAllIdentity: {},
        generatePairingCode: {
          generationCount.increment()
          return try PairingCode("ABCDEF")
        }
      )
    )

    model.openWindow()
    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)

    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))
    XCTAssertEqual(generationCount.value, 1)

    model.closeWindow()
    model.closeWindow()
    _ = await model.prepareForTermination()
    XCTAssertEqual(model.status, .stopped)
  }

  @MainActor
  func testPairingRefreshKeepsOldListenerUntilReplacementCommits() async throws {
    let first = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let replacement = FakeViewerSecureListener()
    let factory = LockedListenerFactory([first, replacement])
    let codes = LockedPairingCodeSequence(["ABCDEF", "MNPQRS"])
    let model = makeApplicationModel(listenerFactory: factory, pairingCodes: codes)

    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)
    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))

    model.refreshPairingCode()
    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))
    XCTAssertEqual(first.cancelCount, 0)

    replacement.emit(.ready(port: 49_153))
    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))
    replacement.emit(.serviceRegistered(exact: true))
    await waitForStatus(.listening(code: "MNPQRS", paused: false), in: model)

    XCTAssertEqual(model.status, .listening(code: "MNPQRS", paused: false))
    XCTAssertEqual(first.cancelCount, 1)
    XCTAssertEqual(replacement.cancelCount, 0)
    XCTAssertEqual(
      factory.advertisements.map(\.identity.instanceName), ["NearWire-ABCDEF", "NearWire-MNPQRS"])
  }

  @MainActor
  func testReplacementFailurePreservesRegisteredListenerAndCode() async throws {
    let first = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let replacementCancelled = expectation(description: "Replacement listener cancelled")
    let replacement = FakeViewerSecureListener(onCancel: { replacementCancelled.fulfill() })
    let factory = LockedListenerFactory([first, replacement])
    let model = makeApplicationModel(
      listenerFactory: factory,
      pairingCodes: LockedPairingCodeSequence(["ABCDEF", "MNPQRS"])
    )
    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)

    model.refreshPairingCode()
    replacement.emit(
      .failed(
        SecureTransportError(
          code: .driverFailure,
          message: "Safe test failure.",
          disposition: .connectionTerminal
        )
      )
    )
    await fulfillment(of: [replacementCancelled], timeout: 1)

    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))
    XCTAssertEqual(first.cancelCount, 0)
    XCTAssertEqual(replacement.cancelCount, 1)
  }

  @MainActor
  func testRegistrationCollisionRetriesWithFreshCodeAndBoundedGeneration() async throws {
    let collision = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: false)]
    )
    let exact = FakeViewerSecureListener(
      eventsOnStart: [.serviceRegistered(exact: true), .ready(port: 49_153)]
    )
    let codes = LockedPairingCodeSequence(["ABCDEF", "MNPQRS"])
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([collision, exact]),
      pairingCodes: codes
    )

    model.openWindow()
    await waitForStatus(.listening(code: "MNPQRS", paused: false), in: model)

    XCTAssertEqual(model.status, .listening(code: "MNPQRS", paused: false))
    XCTAssertEqual(collision.cancelCount, 1)
    XCTAssertEqual(codes.requestCount, 2)
  }

  @MainActor
  func testRegistrationCollisionExhaustionFailsAfterThreeFreshCodes() async throws {
    let listeners = (0..<3).map { index in
      FakeViewerSecureListener(
        eventsOnStart: [
          .ready(port: UInt16(49_152 + index)),
          .serviceRegistered(exact: false),
        ]
      )
    }
    let codes = LockedPairingCodeSequence(["ABCDEF", "MNPQRS", "TUVWXY"])
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory(listeners),
      pairingCodes: codes
    )

    model.openWindow()
    await waitForStatus(.failed(.listenerUnavailable), in: model)

    XCTAssertEqual(model.status, .failed(.listenerUnavailable))
    XCTAssertEqual(codes.requestCount, 3)
    XCTAssertEqual(listeners.map(\.cancelCount), [1, 1, 1])
  }

  @MainActor
  func testRegisteredServiceRemovalPublishesFreshCodeInsteadOfKeepingMisleadingState()
    async throws
  {
    let first = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let recovered = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_153), .serviceRegistered(exact: true)]
    )
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([first, recovered]),
      pairingCodes: LockedPairingCodeSequence(["ABCDEF", "MNPQRS"])
    )
    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)
    XCTAssertEqual(model.status, .listening(code: "ABCDEF", paused: false))

    first.emit(.serviceRemoved)
    await waitForStatus(.listening(code: "MNPQRS", paused: false), in: model)

    XCTAssertEqual(model.status, .listening(code: "MNPQRS", paused: false))
    XCTAssertEqual(first.cancelCount, 1)
  }

  @MainActor
  func testLocalNetworkFailureUsesFixedRecoveryAndStaleCallbacksStayStopped() async throws {
    let listenerStarted = expectation(description: "Listener started")
    let listener = FakeViewerSecureListener(onStart: { listenerStarted.fulfill() })
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([listener]),
      pairingCodes: LockedPairingCodeSequence(["ABCDEF"])
    )
    model.openWindow()
    let failedExplorer = try XCTUnwrap(model.explorerController)
    let failedComposer = try XCTUnwrap(model.composerController)
    await fulfillment(of: [listenerStarted], timeout: 1)
    listener.emit(
      .failed(
        SecureTransportError(
          code: .localNetworkUnavailable,
          message: "An underlying value that must not reach UI.",
          disposition: .connectionTerminal
        )
      )
    )
    await waitForStatus(.failed(.localNetworkUnavailable), in: model)
    await waitUntilExplorer {
      failedExplorer.pendingCleanupWorkCount == 0 && failedComposer.pendingCleanupWorkCount == 0
    }
    XCTAssertEqual(model.status, .failed(.localNetworkUnavailable))
    XCTAssertTrue(failedExplorer.model.timelineRows.isEmpty)
    XCTAssertNil(failedExplorer.inspector.canonicalBuffer)
    XCTAssertEqual(failedComposer.contentJSON, "")

    model.retry()
    model.closeWindow()
    listener.emit(.ready(port: 49_152))
    listener.emit(.serviceRegistered(exact: true))
    _ = await model.prepareForTermination()
    XCTAssertEqual(model.status, .stopped)
  }

  @MainActor
  func testPairingGenerationFailureIsNotMisreportedAsIdentityFailure() async throws {
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([]),
      pairingCodes: LockedPairingCodeSequence([])
    )
    model.openWindow()
    await waitForStatus(.failed(.pairingUnavailable), in: model)
    XCTAssertEqual(model.status, .failed(.pairingUnavailable))
  }

  func testPresentationErrorsExposeOnlyFixedRecoveryText() {
    XCTAssertEqual(
      ViewerPresentationError.localNetworkUnavailable.recovery,
      "Allow local network access in System Settings, then retry."
    )
    XCTAssertFalse(ViewerPresentationError.listenerUnavailable.title.isEmpty)
  }

  @MainActor
  func testRootViewComposesWithoutStartingRuntime() {
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([]),
      pairingCodes: LockedPairingCodeSequence([])
    )
    let hostingView = NSHostingView(rootView: ViewerRootView(model: model))
    hostingView.frame = NSRect(
      x: 0,
      y: 0,
      width: ViewerWorkspaceLayout.minimumWindowWidth,
      height: ViewerWorkspaceLayout.minimumWindowHeight
    )
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      ViewerWorkspaceLayout.regions,
      [
        .sourceAndDevices, .eventTimeline, .eventInspector, .performanceDashboard,
        .controlComposer,
      ]
    )
    XCTAssertGreaterThanOrEqual(
      ViewerWorkspaceLayout.minimumWindowWidth,
      ViewerWorkspaceLayout.sourceMinimumWidth + ViewerWorkspaceLayout.timelineMinimumWidth
        + ViewerWorkspaceLayout.inspectorMinimumWidth
    )
    XCTAssertLessThan(
      ViewerWorkspaceLayout.composerMinimumHeight,
      ViewerWorkspaceLayout.minimumWindowHeight
    )
    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    XCTAssertEqual(model.status, .stopped)
  }

  @MainActor
  func testAnalysisWorkspaceRedrawsImmediatelyFromCoordinatorModePublication() async throws {
    let runtimeLogicalID = UUID()
    let performanceDriver = ViewerPerformanceProjectionDriver(
      prepare: { _, _, _, completion in
        completion(.failure(.store(.unavailable)))
        return ViewerPerformanceProjectionOperationToken()
      },
      loadEventPage: { _, completion in
        completion(.failure(.unavailable))
        return ViewerPerformanceProjectionOperationToken()
      },
      loadGapPage: { completion in
        completion(.failure(.unavailable))
        return ViewerPerformanceProjectionOperationToken()
      },
      endTraversal: { completion in
        completion(.success(()))
        return ViewerPerformanceProjectionOperationToken()
      },
      cancel: { _ in },
      currentUptimeNanoseconds: { 100 }
    )
    let performance = ViewerPerformanceDashboardController(
      driver: performanceDriver,
      analysisActive: false
    )
    let rawResolver = ViewerPerformanceRawEventResolver(
      store: ViewerPerformanceRawEventStoreDriver(
        resolve: { _, _, _, completion in
          completion(.success(nil))
          return ViewerPerformanceRawEventStoreOperation()
        },
        cancel: { _ in }
      ),
      live: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    )
    let coordinator = ViewerAnalysisModeCoordinator(
      event: ViewerAnalysisEventDriver(
        targetSelection: { .guidance(.selectOneDevice) },
        deactivate: { Task {} },
        activate: { Task {} },
        reveal: { _ in }
      ),
      performanceController: performance,
      rawResolver: rawResolver
    )
    let hostingView = NSHostingView(
      rootView: ViewerAnalysisWorkspacePane(analysis: coordinator, explorer: nil)
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 500)
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()
    let eventsImage = try XCTUnwrap(renderedPNGData(of: hostingView))

    coordinator.showPerformance()
    await Task.yield()
    await Task.yield()
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()
    let performanceImage = try XCTUnwrap(renderedPNGData(of: hostingView))

    XCTAssertEqual(coordinator.mode, ViewerAnalysisMode.performance)
    XCTAssertNotEqual(eventsImage, performanceImage)
    await coordinator.sealAndWait().value
  }

  @MainActor
  func testFilterSheetRendersExpandedControlsWithinMinimumBounds() {
    let runtimeLogicalID = UUID()
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: ViewerStoreExplorerGateway(),
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      )
    )
    let hostingView = NSHostingView(
      rootView: ViewerExplorerFilterSheet(
        explorer: controller,
        isPresented: .constant(true)
      )
    )
    controller.updateFilterDraft {
      $0.fromDate = Date(timeIntervalSince1970: 1)
      $0.throughDate = Date(timeIntervalSince1970: 2)
      $0.jsonMode = .equals
      $0.jsonScalarKind = .string
    }
    hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 660)
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()

    let editors = descendantViews(of: ViewerOperatorTextView.self, in: hostingView)
    XCTAssertEqual(
      Set(editors.compactMap { $0.accessibilityLabel() }),
      Set([
        "Event type", "Application identifier", "Application version", "JSON path",
        "Comparison value",
      ])
    )
    let editorFrames = editors.map { $0.convert($0.bounds, to: hostingView) }
    XCTAssertTrue(
      editorFrames.allSatisfy { $0.width >= 120 },
      "Unexpected filter editor frames: \(editorFrames)"
    )
    let editorOrigins = editorFrames.map(\.minY).sorted()
    XCTAssertTrue(
      zip(editorOrigins, editorOrigins.dropFirst()).allSatisfy { previous, next in
        next - previous >= 30
      },
      "Filter editors do not have enough vertical separation: \(editorFrames)"
    )
    let scrollViews = descendantViews(of: NSScrollView.self, in: hostingView)
    let outerScroll = scrollViews.max {
      $0.convert($0.bounds, to: hostingView).height
        < $1.convert($1.bounds, to: hostingView).height
    }
    let outerFrame = outerScroll.map { $0.convert($0.bounds, to: hostingView) }
    XCTAssertGreaterThanOrEqual(outerFrame?.width ?? 0, 500)
    XCTAssertGreaterThanOrEqual(outerFrame?.height ?? 0, 400)
    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)

    if let data = renderedPNGData(of: hostingView), let image = NSImage(data: data) {
      let attachment = XCTAttachment(image: image)
      attachment.name = "NearWire Filters expanded minimum layout"
      attachment.lifetime = .keepAlways
      add(attachment)
    } else {
      XCTFail("The minimum-size filter sheet could not be rendered offscreen.")
    }
    controller.model.sealAndClear()
  }

  @MainActor
  func testNativeTextControlsBoundExactEditsAndDisableInspectorClipboardSurfaces() {
    var buffer = ViewerIncrementalTextBuffer(
      maximumUTF8Bytes: 8,
      maximumUnicodeScalars: 4
    )
    let editor = ViewerOperatorTextView(frame: .zero)
    editor.controlStyle = .singleLine
    editor.onBoundedEdit = { range, replacement in
      buffer.replaceCharacters(in: range, with: replacement) == .applied
    }

    XCTAssertTrue(
      editor.textView(
        editor,
        shouldChangeTextIn: NSRange(location: 0, length: 0),
        replacementString: "é🙂"
      )
    )
    editor.string = buffer.value
    XCTAssertTrue(
      editor.textView(
        editor,
        shouldChangeTextIn: NSRange(location: 1, length: 2),
        replacementString: "ab"
      )
    )
    editor.string = buffer.value
    XCTAssertTrue(
      editor.textView(
        editor,
        shouldChangeTextIn: NSRange(location: 3, length: 0),
        replacementString: "🙂"
      )
    )
    editor.string = buffer.value
    let accepted = editor.string
    XCTAssertFalse(
      editor.textView(
        editor,
        shouldChangeTextIn: NSRange(location: 5, length: 0),
        replacementString: "x"
      )
    )
    XCTAssertEqual(editor.string, accepted)
    XCTAssertEqual(buffer.value, accepted)
    XCTAssertFalse(editor.isProcessingNativeEdit)
    XCTAssertFalse(
      editor.textView(
        editor,
        shouldChangeTextIn: NSRange(location: 0, length: 0),
        replacementString: "\n"
      )
    )
    XCTAssertTrue(editor.isEditable)
    XCTAssertTrue(editor.isSelectable)
    XCTAssertTrue(editor.acceptsFirstResponder)
    XCTAssertFalse(editor.isRichText)
    XCTAssertFalse(editor.importsGraphics)
    XCTAssertTrue(editor.responds(to: #selector(NSText.copy(_:))))
    XCTAssertTrue(editor.responds(to: #selector(NSText.cut(_:))))
    XCTAssertTrue(editor.responds(to: #selector(NSText.paste(_:))))
    XCTAssertTrue(Mirror(reflecting: editor).children.isEmpty)
    XCTAssertFalse(String(reflecting: editor).contains(accepted))

    var submitted = false
    editor.onSubmit = { submitted = true }
    XCTAssertTrue(editor.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertTrue(submitted)

    let multiline = ViewerOperatorTextView(frame: .zero)
    multiline.controlStyle = .multiline
    multiline.onBoundedEdit = { _, _ in true }
    XCTAssertTrue(
      multiline.textView(
        multiline,
        shouldChangeTextIn: NSRange(location: 0, length: 0),
        replacementString: "\n"
      )
    )

    var pastedBuffer = ViewerIncrementalTextBuffer(
      maximumUTF8Bytes: 8,
      maximumUnicodeScalars: 4
    )
    let pasteEditor = ViewerOperatorTextView(frame: .zero)
    pasteEditor.onBoundedEdit = { range, replacement in
      pastedBuffer.replaceCharacters(in: range, with: replacement) == .applied
    }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("NearWireTests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects(["é🙂" as NSString]))
    pasteEditor.setSelectedRange(NSRange(location: 0, length: 0))
    XCTAssertTrue(pasteEditor.readSelection(from: pasteboard, type: .string))
    XCTAssertEqual(pasteEditor.string, "é🙂")
    XCTAssertEqual(pastedBuffer.value, "é🙂")

    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects(["ab" as NSString]))
    pasteEditor.setSelectedRange(NSRange(location: 1, length: 2))
    XCTAssertTrue(pasteEditor.readSelection(from: pasteboard, type: .string))
    XCTAssertEqual(pasteEditor.string, "éab")
    XCTAssertEqual(pastedBuffer.value, "éab")

    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects(["🙂🙂" as NSString]))
    pasteEditor.setSelectedRange(NSRange(location: 3, length: 0))
    XCTAssertTrue(pasteEditor.readSelection(from: pasteboard, type: .string))
    XCTAssertEqual(pasteEditor.string, "éab")
    XCTAssertEqual(pastedBuffer.value, "éab")

    let received = ViewerReceivedEventTextView(frame: .zero)
    received.string = "private Event content"
    let clipboardItems = [
      NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""),
      NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""),
      NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""),
    ]
    XCTAssertFalse(received.isEditable)
    XCTAssertFalse(received.isSelectable)
    XCTAssertFalse(received.acceptsFirstResponder)
    XCTAssertFalse(received.isRichText)
    XCTAssertFalse(received.importsGraphics)
    XCTAssertNil(received.menu)
    XCTAssertTrue(received.registeredDraggedTypes.isEmpty)
    XCTAssertTrue(clipboardItems.allSatisfy { !received.validateUserInterfaceItem($0) })
    XCTAssertTrue(Mirror(reflecting: received).children.isEmpty)
    XCTAssertFalse(String(reflecting: received).contains("private Event content"))
    received.clearSensitiveState()
    XCTAssertEqual(received.string, "")

    var filter = ViewerExplorerFilterDraft()
    XCTAssertEqual(
      filter.replaceText(
        .search,
        range: NSRange(location: 0, length: 0),
        replacement: "device"
      ),
      .applied
    )
    XCTAssertEqual(
      filter.replaceText(
        .search,
        range: NSRange(location: 0, length: 6),
        replacement: String(repeating: "x", count: 513)
      ),
      .rejected(.byteLimit)
    )
    XCTAssertEqual(filter.searchText, "device")
  }

  @MainActor
  func testControlComposerScalesToCompactWidthWithDeterministicEditorFocusOrder() throws {
    let runtimeID = UUID()
    let owner = FakeAdmissionHandoffOwner(runtimeLogicalID: runtimeID)
    let controller = try ViewerControlComposerController(
      runtimeLogicalID: runtimeID,
      sessionControl: owner
    )
    let hostingView = NSHostingView(rootView: ViewerControlComposerView(controller: controller))
    hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
    hostingView.layoutSubtreeIfNeeded()

    let editors = descendantViews(of: ViewerOperatorTextView.self, in: hostingView)
    XCTAssertEqual(editors.count, 3)
    XCTAssertEqual(
      editors.compactMap { $0.accessibilityLabel() },
      ["Control Event type", "Control Event JSON content", "TTL milliseconds"]
    )
    XCTAssertTrue(editors.allSatisfy(\.acceptsFirstResponder))
    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    controller.sealAndClear()
  }

  @MainActor
  func testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt() async throws {
    let listener = FakeViewerSecureListener(
      eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
    )
    let model = makeApplicationModel(
      listenerFactory: LockedListenerFactory([listener]),
      pairingCodes: LockedPairingCodeSequence(["ABCDEF"])
    )

    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)
    let explorer = try XCTUnwrap(model.explorerController)
    let analysis = try XCTUnwrap(model.analysisCoordinator)
    let composer = try XCTUnwrap(model.composerController)
    let hostingView = NSHostingView(rootView: ViewerRootView(model: model))
    hostingView.frame = NSRect(
      x: 0,
      y: 0,
      width: ViewerWorkspaceLayout.minimumWindowWidth,
      height: ViewerWorkspaceLayout.minimumWindowHeight
    )
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(explorer.sourceRows.map(\.title).first, "Live")
    XCTAssertEqual(analysis.mode, .events)
    XCTAssertFalse(analysis.performanceController.isAnalysisActive)
    XCTAssertTrue(explorer.usesAllDevices)
    XCTAssertTrue(explorer.replaceFilterText(.eventType, with: "log.network"))
    explorer.updateFilterDraft {
      $0.eventTypeMode = .prefix
      $0.directions = ["appToViewer"]
      $0.requiresDrop = true
    }
    XCTAssertEqual(explorer.activeFilterCount, 3)
    XCTAssertNoThrow(try explorer.filterDraft.makeFilter())
    explorer.prepareExport(.completeRecording)
    XCTAssertEqual(explorer.exportState, .failed(.unavailable))
    explorer.updateSelectedRecording(name: "Unavailable", note: nil, pinned: false)
    XCTAssertEqual(explorer.recordingOperationState, .failed(.unavailable))
    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)

    _ = await model.prepareForTermination()
    XCTAssertNil(model.explorerController)
    XCTAssertNil(model.analysisCoordinator)
    XCTAssertNil(model.composerController)
    XCTAssertTrue(analysis.diagnostics.isSealed)
    XCTAssertTrue(analysis.performanceController.diagnostics.isSealed)
    XCTAssertTrue(explorer.model.isPaused)
    XCTAssertTrue(explorer.model.timelineRows.isEmpty)
    XCTAssertNil(explorer.inspectorMetadata)
    XCTAssertTrue(composer.targetRows.isEmpty)
    XCTAssertTrue(composer.resultRows.isEmpty)
    XCTAssertEqual(composer.eventType, "")
    XCTAssertEqual(composer.contentJSON, "")
    XCTAssertEqual(composer.ttlText, "")
  }

  @MainActor
  func testRecordingEditorEnforcesMetadataCapsBeforeStorageAndRedactsContent() {
    let editor = ViewerRecordingEditorModel(name: "Initial", note: "Initial note")
    XCTAssertEqual(editor.name, "Initial")
    XCTAssertEqual(editor.note, "Initial note")

    let maximumName = String(repeating: "n", count: 80)
    XCTAssertTrue(editor.replaceWhole(.name, with: maximumName))
    XCTAssertFalse(editor.replaceWhole(.name, with: maximumName + "x"))
    XCTAssertEqual(editor.name, maximumName)

    let maximumNote = String(repeating: "a", count: 4_096)
    XCTAssertTrue(editor.replaceWhole(.note, with: maximumNote))
    XCTAssertFalse(editor.replaceWhole(.note, with: maximumNote + "b"))
    XCTAssertEqual(editor.note, maximumNote)

    let maximumAnnotation = String(repeating: "z", count: 4_096)
    XCTAssertTrue(editor.replaceWhole(.annotation, with: maximumAnnotation))
    XCTAssertFalse(editor.replaceWhole(.annotation, with: maximumAnnotation + "z"))
    XCTAssertEqual(editor.annotation, maximumAnnotation)
    editor.clearAnnotation()
    XCTAssertEqual(editor.annotation, "")
    XCTAssertEqual(editor.buffers.name.diagnostics.fullValueRescanCount, 0)
    XCTAssertEqual(editor.buffers.note.diagnostics.fullValueRescanCount, 0)
    XCTAssertEqual(editor.buffers.annotation.diagnostics.fullValueRescanCount, 0)
    XCTAssertTrue(Mirror(reflecting: editor).children.isEmpty)
    XCTAssertFalse(String(reflecting: editor).contains(maximumNote))
  }

  func testExplorerOperationMessagesAndExportExclusionDisclosureAreFixedAndSafe() {
    let failures: [ViewerStoreExplorerFailure] = [
      .storeReplaced,
      .cancelled,
      .unavailable,
      .invalidRequest,
      .busy,
      .refineQuery,
      .catalogChanged,
    ]
    let messages = failures.map(\.operatorMessage)

    XCTAssertEqual(Set(messages).count, failures.count)
    XCTAssertTrue(messages.allSatisfy { !$0.isEmpty && !$0.contains("/") })
    XCTAssertFalse(messages.joined().contains("SQLite"))
    XCTAssertFalse(messages.joined().contains("NSUnderlyingError"))
    XCTAssertEqual(
      ViewerExportPresentationText.transientRowsExcluded,
      "Transient rows labeled Not recorded are excluded."
    )
  }

  func testBuiltApplicationMetadataAndPrivacyManifestMatchDiscoveryContract() throws {
    let info = try XCTUnwrap(Bundle.main.infoDictionary)
    XCTAssertEqual(info["NSBonjourServices"] as? [String], ["_nearwire._tcp"])
    XCTAssertEqual(
      info["NSLocalNetworkUsageDescription"] as? String,
      "NearWire advertises a local service so your iPhone apps can connect to this Mac."
    )

    let privacyURL = try XCTUnwrap(
      Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    )
    let privacyData = try Data(contentsOf: privacyURL)
    let privacy = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: privacyData, format: nil) as? [String: Any]
    )
    XCTAssertEqual(privacy["NSPrivacyTracking"] as? Bool, false)
    XCTAssertNil(privacy["NSPrivacyTrackingDomains"])
    let accessed = try XCTUnwrap(privacy["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    XCTAssertEqual(accessed.count, 1)
    XCTAssertEqual(
      accessed[0]["NSPrivacyAccessedAPIType"] as? String,
      "NSPrivacyAccessedAPICategoryUserDefaults"
    )
    XCTAssertEqual(accessed[0]["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    let collected = try XCTUnwrap(privacy["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    XCTAssertEqual(collected.count, 1)
    XCTAssertEqual(
      collected[0]["NSPrivacyCollectedDataType"] as? String,
      "NSPrivacyCollectedDataTypeDeviceID"
    )
    XCTAssertEqual(collected[0]["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
    XCTAssertEqual(collected[0]["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
    XCTAssertEqual(
      collected[0]["NSPrivacyCollectedDataTypePurposes"] as? [String],
      ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
    )
  }

  func testRunningApplicationHasRequiredFoundationNetworkEntitlements() throws {
    let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
    XCTAssertEqual(
      SecTaskCopyValueForEntitlement(
        task,
        "com.apple.security.app-sandbox" as CFString,
        nil
      ) as? Bool,
      true
    )
    XCTAssertEqual(
      SecTaskCopyValueForEntitlement(
        task,
        "com.apple.security.network.client" as CFString,
        nil
      ) as? Bool,
      true
    )
    XCTAssertEqual(
      SecTaskCopyValueForEntitlement(
        task,
        "com.apple.security.network.server" as CFString,
        nil
      ) as? Bool,
      true
    )
    for forbidden in [
      "com.apple.developer.networking.multicast",
      "keychain-access-groups",
      "com.apple.security.application-groups",
    ] {
      XCTAssertNil(SecTaskCopyValueForEntitlement(task, forbidden as CFString, nil))
    }
  }

  func testCertificateBuilderProducesAndValidatesFixedProfile() throws {
    let creationDate = Date(timeIntervalSince1970: 1_800_000_000)
    let builder = ViewerCertificateBuilder(
      randomBytes: { count in Array(repeating: 0x31, count: count) },
      now: { creationDate }
    )
    let key = try builder.createEphemeralPrivateKey()
    let material = try builder.build(privateKey: key)
    let profile = try builder.validate(
      certificate: material.certificate,
      privateKey: key,
      at: creationDate,
      requireRenewalHeadroom: false
    )

    XCTAssertEqual(profile.serial, Data(repeating: 0x31, count: 16))
    XCTAssertEqual(profile.publicKeyBytes.count, 65)
    XCTAssertEqual(profile.notBefore, creationDate.addingTimeInterval(-300))
    XCTAssertEqual(
      profile.notAfter, creationDate.addingTimeInterval(ViewerCertificateBuilder.lifetime))
    XCTAssertEqual(
      SecCertificateCopySubjectSummary(material.certificate) as String?,
      ViewerCertificateBuilder.commonName
    )
  }

  func testCertificateBuilderRejectsRenewalWindow() throws {
    let creationDate = Date(timeIntervalSince1970: 1_800_000_000)
    let builder = ViewerCertificateBuilder(
      randomBytes: { count in Array(repeating: 0x22, count: count) },
      now: { creationDate }
    )
    let key = try builder.createEphemeralPrivateKey()
    let material = try builder.build(privateKey: key)
    let renewalDate = material.notAfter.addingTimeInterval(-29 * 24 * 60 * 60)

    XCTAssertThrowsError(
      try builder.validate(certificate: material.certificate, privateKey: key, at: renewalDate)
    ) { error in
      XCTAssertEqual(error as? ViewerCertificateError, .invalidValidity)
    }
  }

  func testCertificateBuilderEnforcesExactValidityBoundaries() throws {
    let creationDate = Date(timeIntervalSince1970: 1_800_000_000)
    let builder = ViewerCertificateBuilder(
      randomBytes: { count in Array(repeating: 0, count: count) },
      now: { creationDate }
    )
    let key = try builder.createEphemeralPrivateKey()
    let material = try builder.build(privateKey: key)

    let profile = try builder.validate(
      certificate: material.certificate,
      privateKey: key,
      at: material.notBefore,
      requireRenewalHeadroom: false
    )
    XCTAssertEqual(profile.serial.first, 1)
    XCTAssertNoThrow(
      try builder.validate(
        certificate: material.certificate,
        privateKey: key,
        at: material.notAfter,
        requireRenewalHeadroom: false
      )
    )
    XCTAssertThrowsError(
      try builder.validate(
        certificate: material.certificate,
        privateKey: key,
        at: material.notBefore.addingTimeInterval(-1),
        requireRenewalHeadroom: false
      )
    )
    XCTAssertNoThrow(
      try builder.validate(
        certificate: material.certificate,
        privateKey: key,
        at: material.notAfter.addingTimeInterval(-ViewerCertificateBuilder.renewalWindow)
      )
    )
    XCTAssertThrowsError(
      try builder.validate(
        certificate: material.certificate,
        privateKey: key,
        at: material.notAfter.addingTimeInterval(-ViewerCertificateBuilder.renewalWindow + 1)
      )
    )
  }

  func testCertificateBuilderRejectsWrongKeyAndTamperedSignature() throws {
    let creationDate = Date(timeIntervalSince1970: 1_800_000_000)
    let builder = ViewerCertificateBuilder(
      randomBytes: { count in Array(repeating: 0x41, count: count) },
      now: { creationDate }
    )
    let key = try builder.createEphemeralPrivateKey()
    let material = try builder.build(privateKey: key)
    let otherKey = try builder.createEphemeralPrivateKey()

    XCTAssertThrowsError(
      try builder.validate(
        certificate: material.certificate,
        privateKey: otherKey,
        at: creationDate,
        requireRenewalHeadroom: false
      )
    ) { error in
      XCTAssertEqual(error as? ViewerCertificateError, .keyMismatch)
    }

    var tamperedDER = material.der
    tamperedDER[tamperedDER.index(before: tamperedDER.endIndex)] ^= 0x01
    let tamperedCertificate = try XCTUnwrap(
      SecCertificateCreateWithData(nil, tamperedDER as CFData)
    )
    XCTAssertThrowsError(
      try builder.validate(
        certificate: tamperedCertificate,
        privateKey: key,
        at: creationDate,
        requireRenewalHeadroom: false
      )
    ) { error in
      XCTAssertEqual(error as? ViewerCertificateError, .invalidSignature)
    }
  }

  func testCertificateBuilderRejectsInvalidRandomByteCount() throws {
    let builder = ViewerCertificateBuilder(
      randomBytes: { _ in [1] },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let key = try builder.createEphemeralPrivateKey()

    XCTAssertThrowsError(try builder.build(privateKey: key)) { error in
      XCTAssertEqual(error as? ViewerCertificateError, .randomUnavailable)
    }
  }

  func testIdentityStorePersistsSeparatelyAndResetsWithDocumentedScopes() throws {
    let names = ViewerKeychainNames.isolated()
    let store = ViewerIdentityStore(names: names)
    addTeardownBlock { try? store.resetAllIdentity() }

    do {
      _ = try store.loadOrCreateMaterial()
    } catch {
      XCTFail("Initial file-based identity material creation failed: \(error)")
      return
    }

    let first: ViewerRuntimeIdentity
    do {
      first = try store.loadOrCreate()
    } catch {
      XCTFail("Initial identity creation failed: \(error)")
      return
    }
    let reloaded = try store.loadOrCreate()
    XCTAssertEqual(first.installationID, reloaded.installationID)
    XCTAssertEqual(
      SecCertificateCopyData(first.certificate) as Data,
      SecCertificateCopyData(reloaded.certificate) as Data
    )
    XCTAssertNil(SecKeyCopyExternalRepresentation(first.privateKey, nil))

    try store.resetTLSIdentity()
    let afterTLSReset = try store.loadOrCreate()
    XCTAssertEqual(first.installationID, afterTLSReset.installationID)
    XCTAssertNotEqual(
      SecCertificateCopyData(first.certificate) as Data,
      SecCertificateCopyData(afterTLSReset.certificate) as Data
    )

    try store.resetAllIdentity()
    let afterFullReset = try store.loadOrCreate()
    XCTAssertNotEqual(first.installationID, afterFullReset.installationID)
  }

  func testStableSignerUpdateBoundaryProbe() throws {
    let signedConfiguration = try XCTUnwrap(Bundle.main.infoDictionary)
    guard
      let phaseValue = signedConfiguration["NearWireSignerProbePhase"] as? String,
      !phaseValue.isEmpty
    else {
      throw XCTSkip("Set the stable-signer probe build settings to run this packaging test.")
    }
    let phase = try XCTUnwrap(StableSignerProbePhase(rawValue: phaseValue))
    let token = try XCTUnwrap(signedConfiguration["NearWireSignerProbeToken"] as? String)
    let buildID = try XCTUnwrap(signedConfiguration["NearWireSignerProbeBuildID"] as? String)
    let stateRoot = try XCTUnwrap(
      signedConfiguration["NearWireSignerProbeStateRoot"] as? String
    )
    guard isValidStableSignerProbeComponent(token),
      isValidStableSignerProbeComponent(buildID),
      isValidStableSignerProbeStateRoot(stateRoot)
    else {
      throw ViewerTestError.invalidProbeConfiguration
    }

    let probeDirectory = URL(fileURLWithPath: stateRoot, isDirectory: true)
      .appendingPathComponent(token, isDirectory: true)
    let store = ViewerIdentityStore(names: .isolated("stable-signer-\(token)"))
    let expectedURL = probeDirectory.appendingPathComponent("expected.json")
    let deniedURL = probeDirectory.appendingPathComponent("deny-complete")
    let hostFingerprint = try currentStableSignerProbeFingerprint()
    let signer = hostFingerprint.signer
    let bundleVersion = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )
    let productPath = Bundle.main.bundleURL.path

    switch phase {
    case .create:
      try FileManager.default.createDirectory(
        at: probeDirectory,
        withIntermediateDirectories: true
      )
      guard !FileManager.default.fileExists(atPath: expectedURL.path) else {
        throw ViewerTestError.invalidProbeConfiguration
      }
      let identity = try store.loadOrCreate()
      try assertPrivateKeyCanSign(identity.privateKey)
      let expected = StableSignerProbeRecord(
        installationID: identity.installationID.rawValue,
        certificateHash: Data(
          SHA256.hash(data: SecCertificateCopyData(identity.certificate) as Data)
        ),
        certificatePersistentReference: try persistentReference(
          for: identity.certificate
        ),
        signer: signer,
        codeDirectoryHash: hostFingerprint.codeDirectoryHash,
        bundleVersion: bundleVersion,
        buildID: buildID,
        productPath: productPath
      )
      try JSONEncoder().encode(expected).write(to: expectedURL, options: .atomic)

    case .deny:
      let expected = try loadStableSignerProbeRecord(from: expectedURL)
      guard buildID != expected.buildID, productPath != expected.productPath,
        bundleVersion != expected.bundleVersion,
        hostFingerprint.codeDirectoryHash != expected.codeDirectoryHash,
        signer != expected.signer,
        signer.designatedRequirement != expected.signer.designatedRequirement,
        !FileManager.default.fileExists(atPath: deniedURL.path)
      else {
        throw ViewerTestError.invalidProbeConfiguration
      }
      XCTAssertThrowsError(try store.loadOrCreate())
      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertThrowsError(try store.resetAllIdentity())
      assertUnrelatedSignerCannotReadUseOrDelete(
        names: .isolated("stable-signer-\(token)"),
        certificatePersistentReference: expected.certificatePersistentReference
      )

    case .verify:
      let expected = try loadStableSignerProbeRecord(from: expectedURL)
      guard buildID != expected.buildID, productPath != expected.productPath,
        bundleVersion != expected.bundleVersion,
        hostFingerprint.codeDirectoryHash != expected.codeDirectoryHash,
        signer == expected.signer,
        FileManager.default.fileExists(atPath: deniedURL.path)
      else {
        throw ViewerTestError.invalidProbeConfiguration
      }
      let reloaded = try store.loadOrCreate()
      XCTAssertEqual(reloaded.installationID.rawValue, expected.installationID)
      XCTAssertEqual(
        Data(SHA256.hash(data: SecCertificateCopyData(reloaded.certificate) as Data)),
        expected.certificateHash
      )
      try assertPrivateKeyCanSign(reloaded.privateKey)

      try store.resetTLSIdentity()
      let afterTLSReset = try store.loadOrCreate()
      XCTAssertEqual(afterTLSReset.installationID.rawValue, expected.installationID)
      XCTAssertNotEqual(
        Data(SHA256.hash(data: SecCertificateCopyData(afterTLSReset.certificate) as Data)),
        expected.certificateHash
      )
      try store.resetAllIdentity()
      try FileManager.default.removeItem(at: probeDirectory)
    }
  }

  private func isValidStableSignerProbeComponent(_ value: String) -> Bool {
    (6...64).contains(value.count)
      && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
  }

  private func isValidStableSignerProbeStateRoot(_ value: String) -> Bool {
    let url = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    return url.path == value
      && url.lastPathComponent == "nearwire-viewer-stable-signer-probe"
      && url.path.contains("/Library/Containers/com.nearwire.viewer/Data/tmp/")
  }

  private func loadStableSignerProbeRecord(from url: URL) throws -> StableSignerProbeRecord {
    try JSONDecoder().decode(StableSignerProbeRecord.self, from: Data(contentsOf: url))
  }

  private func currentStableSignerProbeFingerprint() throws -> (
    signer: StableSignerProbeFingerprint,
    codeDirectoryHash: Data
  ) {
    var dynamicCode: SecCode?
    guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
      let requirement
    else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    var requirementText: CFString?
    guard SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
      let requirementText
    else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let values = information as? [CFString: Any],
      let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
      !teamIdentifier.isEmpty,
      let certificates = values[kSecCodeInfoCertificates] as? [SecCertificate],
      let leafCertificate = certificates.first,
      let codeDirectoryHash = values[kSecCodeInfoUnique] as? Data
    else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    return (
      signer: StableSignerProbeFingerprint(
        teamIdentifier: teamIdentifier,
        certificateHash: Data(
          SHA256.hash(data: SecCertificateCopyData(leafCertificate) as Data)
        ),
        designatedRequirement: requirementText as String
      ),
      codeDirectoryHash: codeDirectoryHash
    )
  }

  private func persistentReference(for certificate: SecCertificate) throws -> Data {
    let context = LAContext()
    context.interactionNotAllowed = true
    let query: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecMatchItemList: [certificate],
      kSecReturnPersistentRef: true,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecUseDataProtectionKeychain: false,
      kSecUseAuthenticationContext: context,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let reference = result as? Data
    else {
      throw ViewerTestError.signingMetadataUnavailable
    }
    return reference
  }

  private func assertUnrelatedSignerCannotReadUseOrDelete(
    names: ViewerKeychainNames,
    certificatePersistentReference: Data
  ) {
    let context = LAContext()
    context.interactionNotAllowed = true
    func protected(_ query: [CFString: Any]) -> [CFString: Any] {
      var value = query
      value[kSecUseAuthenticationContext] = context
      return value
    }
    func genericPassword(_ account: String) -> [CFString: Any] {
      protected([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: names.service,
        kSecAttrAccount: account,
        kSecAttrSynchronizable: false,
        kSecUseDataProtectionKeychain: false,
      ])
    }
    let privateKey = protected([
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: names.keyTagData,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: false,
    ])
    let certificate = protected([
      kSecClass: kSecClassCertificate,
      kSecMatchItemList: [certificatePersistentReference],
      kSecUseDataProtectionKeychain: false,
    ])

    for account in ["installation-id", "tls-metadata"] {
      var query = genericPassword(account)
      query[kSecReturnData] = true
      query[kSecMatchLimit] = kSecMatchLimitOne
      var result: CFTypeRef?
      XCTAssertNotEqual(
        SecItemCopyMatching(query as CFDictionary, &result),
        errSecSuccess,
        "An unrelated signer read \(account)."
      )
    }

    var privateKeyLookup = privateKey
    privateKeyLookup[kSecReturnRef] = true
    privateKeyLookup[kSecMatchLimit] = kSecMatchLimitOne
    var privateKeyResult: CFTypeRef?
    let privateKeyStatus = SecItemCopyMatching(
      privateKeyLookup as CFDictionary,
      &privateKeyResult
    )
    if privateKeyStatus == errSecSuccess, let privateKeyResult,
      CFGetTypeID(privateKeyResult) == SecKeyGetTypeID()
    {
      let key = privateKeyResult as! SecKey
      XCTAssertNil(
        SecKeyCreateSignature(
          key,
          .ecdsaSignatureMessageX962SHA256,
          Data("NearWire unrelated signer probe".utf8) as CFData,
          nil
        ),
        "An unrelated signer used the private key."
      )
    }
    XCTAssertNotEqual(
      privateKeyStatus,
      errSecSuccess,
      "An unrelated signer loaded the private key."
    )

    for query in [
      genericPassword("installation-id"),
      genericPassword("tls-metadata"),
      privateKey,
      certificate,
    ] {
      XCTAssertNotEqual(
        SecItemDelete(query as CFDictionary),
        errSecSuccess,
        "An unrelated signer deleted an exact identity record."
      )
    }
  }

  func testProductionKeychainConfigurationUsesZeroConfigurationMacKeychain() {
    XCTAssertFalse(ViewerKeychainNames.live.usesDataProtectionKeychain)
    XCTAssertEqual(ViewerKeychainNames.live.service, "com.nearwire.viewer.identity.v1")
    XCTAssertEqual(ViewerKeychainNames.live.keyTag, "com.nearwire.viewer.tls-key.v1")
  }

  func testExplicitTLSResetFailsClosedOnMalformedOwnedMetadata() throws {
    let names = ViewerKeychainNames.isolated()
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: names.service,
      kSecAttrAccount: "tls-metadata",
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: false,
    ]
    var add = query
    add[kSecValueData] = Data("malformed".utf8)
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    XCTAssertEqual(addStatus, errSecSuccess)
    let service = names.service
    addTeardownBlock {
      let cleanup: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: "tls-metadata",
        kSecAttrSynchronizable: false,
        kSecUseDataProtectionKeychain: false,
      ]
      SecItemDelete(cleanup as CFDictionary)
    }

    let store = ViewerIdentityStore(names: names)
    XCTAssertThrowsError(try store.resetTLSIdentity()) { error in
      XCTAssertEqual(error as? ViewerIdentityStoreError, .resetFailed)
    }

    var lookup = query
    lookup[kSecReturnData] = true
    lookup[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, &result), errSecSuccess)
    XCTAssertEqual(result as? Data, Data("malformed".utf8))
  }

  func testTLSResetPreservesCertificateWithoutOwnedMetadataReference() throws {
    let names = ViewerKeychainNames.isolated()
    let uniqueSerialBytes = Array(UUID().uuidString.utf8)
    let builder = ViewerCertificateBuilder(
      randomBytes: { count in Array(uniqueSerialBytes.prefix(count)) },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let key = try builder.createEphemeralPrivateKey()
    let certificate = try builder.build(privateKey: key).certificate
    let label = "NearWire foreign test \(UUID().uuidString)"
    let add: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecValueRef: certificate,
      kSecAttrLabel: label,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: false,
      kSecReturnPersistentRef: true,
    ]
    var persistentResult: CFTypeRef?
    let addStatus = SecItemAdd(add as CFDictionary, &persistentResult)
    XCTAssertEqual(addStatus, errSecSuccess)
    var lookupResult: CFTypeRef?
    let lookupStatus = SecItemCopyMatching(
      [
        kSecClass: kSecClassCertificate,
        kSecMatchItemList: [certificate],
        kSecUseDataProtectionKeychain: false,
        kSecReturnPersistentRef: true,
        kSecMatchLimit: kSecMatchLimitOne,
      ] as CFDictionary, &lookupResult)
    XCTAssertEqual(lookupStatus, errSecSuccess)
    let persistentReference = try XCTUnwrap(lookupResult as? Data)
    let persistentQuery: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecMatchItemList: [persistentReference],
      kSecUseDataProtectionKeychain: false,
    ]
    addTeardownBlock {
      let cleanup: [CFString: Any] = [
        kSecClass: kSecClassCertificate,
        kSecMatchItemList: [persistentReference],
        kSecUseDataProtectionKeychain: false,
      ]
      SecItemDelete(cleanup as CFDictionary)
    }

    XCTAssertThrowsError(try ViewerIdentityStore(names: names).resetTLSIdentity()) { error in
      XCTAssertEqual(error as? ViewerIdentityStoreError, .resetFailed)
    }

    var lookup = persistentQuery
    lookup[kSecReturnRef] = true
    lookup[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, &result), errSecSuccess)
    XCTAssertEqual(CFGetTypeID(result), SecCertificateGetTypeID())
  }

  func testAdmissionBudgetRejectsTheThirtyThirdSlotAndReleasesExactlyOnce() throws {
    let budget = ViewerAdmissionBudget()
    var reservations: [ViewerAdmissionBudget.Reservation] = []

    for _ in 0..<ViewerAdmissionManager.maximumAttempts {
      reservations.append(try XCTUnwrap(budget.reserve()))
    }
    XCTAssertEqual(budget.occupiedCount, 32)
    XCTAssertNil(budget.reserve())

    XCTAssertTrue(budget.release(reservations[0]))
    XCTAssertFalse(budget.release(reservations[0]))
    XCTAssertEqual(budget.occupiedCount, 31)
    XCTAssertNotNil(budget.reserve())
  }

  func testAdmissionCoreSendsViewerHelloOnceAndRejectsCoalescedPostHelloInput() throws {
    let sent = expectation(description: "Viewer Hello admitted")
    sent.expectedFulfillmentCount = 1
    let remoteHello = expectation(description: "App Hello decoded")
    remoteHello.expectedFulfillmentCount = 1
    let terminal = expectation(description: "Protocol violation closes core")
    terminal.expectedFulfillmentCount = 1
    let channel = FakeAdmissionChannel(
      supportsReceivePause: false,
      onSend: { _ in sent.fulfill() }
    )
    let viewerID = try EndpointID(rawValue: "viewer-test")
    let appID = try EndpointID(rawValue: "app-test")
    let core = try ViewerAdmissionConnectionCore(
      id: UUID(),
      viewerInstallationID: viewerID,
      onHello: { summary in
        XCTAssertEqual(summary.displayName, "Demo App")
        XCTAssertEqual(summary.installationAlias.count, 12)
        XCTAssertFalse(summary.installationAlias.contains("app-test"))
        remoteHello.fulfill()
      },
      onTerminal: { terminal.fulfill() }
    )
    try core.attach(channel)
    core.start()
    core.start()
    core.receive(.stateChanged(.ready))
    core.receive(.stateChanged(.ready))

    wait(for: [sent], timeout: 1)
    XCTAssertEqual(channel.startCount, 1)
    XCTAssertEqual(channel.sentPayloads.count, 1)

    let hello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      displayName: "Demo App"
    )
    let frame = try WirePreHandshakeCodec().encode(hello)
    core.receive(.received(frame + frame))

    wait(for: [remoteHello, terminal], timeout: 1)
    XCTAssertEqual(channel.cancelCount, 1)
  }

  func testAdmissionManagerHandsOffProductionSDKEventRecordOffer() throws {
    let started = expectation(description: "Channel started")
    let viewerHelloSent = expectation(description: "Viewer Hello sent")
    let handedOff = expectation(description: "Production App Hello handed off")
    let channelClosed = expectation(description: "Handed-off channel closed at shutdown")
    let retainedHandle = LockedHandleBox()
    let handoffOwner = FakeAdmissionHandoffOwner { handle in
      retainedHandle.set(handle)
      handedOff.fulfill()
    }
    let channel = FakeAdmissionChannel(
      onSend: { _ in viewerHelloSent.fulfill() },
      onStart: { started.fulfill() },
      onCancel: { channelClosed.fulfill() }
    )
    let incoming = FakeIncomingConnection(channel: channel)
    let manager = ViewerAdmissionManager(
      onPending: { _ in },
      handoffOwner: handoffOwner
    )
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-production-offer")
    )

    wait(for: [started], timeout: 1)
    incoming.emit(.stateChanged(.ready))
    wait(for: [viewerHelloSent], timeout: 1)

    let oneMiBEventLimits = try EventValidationLimits(
      maximumEncodedContentBytes: 1_024 * 1_024,
      maximumEncodedModelBytes: 4_259_840
    )
    let peerOffer = try WireEventRecord.maximumDeterministicEncodedByteCount(
      eventLimits: oneMiBEventLimits
    )
    XCTAssertGreaterThan(peerOffer, 1_024 * 1_024)
    let peerFrameLimits = try WireFrameLimits(
      maximumControlPayloadBytes: WireFrameLimits.default.maximumControlPayloadBytes,
      maximumEventPayloadBytes: peerOffer
    )
    let peerLimits = try WireProtocolLimits(
      frame: peerFrameLimits,
      maximumEventBytes: peerOffer,
      eventValidationLimits: oneMiBEventLimits
    )
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: EndpointID(rawValue: "production-sdk-app"),
      maximumEventBytes: peerOffer,
      displayName: "Production SDK App",
      limits: peerLimits
    )
    let frame = try WirePreHandshakeCodec(limits: peerLimits).encode(appHello)
    incoming.emit(.received(frame))

    wait(for: [handedOff], timeout: 1)
    let handle = try XCTUnwrap(retainedHandle.value)
    let context = try handle.connectionCore.pendingSessionContext()
    XCTAssertEqual(context.appHello.displayName, "Production SDK App")
    XCTAssertEqual(context.appHello.maximumEventBytes, peerOffer)
    XCTAssertEqual(
      context.negotiation.maximumEventBytes,
      peerOffer
    )
    XCTAssertEqual(channel.cancelCount, 0)
    manager.stop()
    wait(for: [channelClosed], timeout: 1)
  }

  func testAdmissionCoreRejectsViewerRoleWithoutPublishingAppSummary() throws {
    let sent = expectation(description: "Viewer Hello admitted")
    let terminal = expectation(description: "Wrong role terminates admission")
    let cancelled = expectation(description: "Wrong-role channel cancelled")
    let summary = expectation(description: "No App summary")
    summary.isInverted = true
    let channel = FakeAdmissionChannel(
      onSend: { _ in sent.fulfill() },
      onCancel: { cancelled.fulfill() }
    )
    let core = try ViewerAdmissionConnectionCore(
      id: UUID(),
      viewerInstallationID: EndpointID(rawValue: "viewer-test"),
      onHello: { _ in summary.fulfill() },
      onTerminal: { terminal.fulfill() }
    )
    try core.attach(channel)
    core.start()
    core.receive(.stateChanged(.ready))
    wait(for: [sent], timeout: 1)

    let wrongRole = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .viewer,
      installationID: EndpointID(rawValue: "other-viewer")
    )
    core.receive(.received(try WirePreHandshakeCodec().encode(wrongRole)))

    wait(for: [terminal, cancelled, summary], timeout: 0.3)
    XCTAssertEqual(channel.cancelCount, 1)
  }

  func testAdmissionCoreBackpressuresReceiveUntilHelloProcessingReturns() throws {
    let viewerHelloSent = expectation(description: "Viewer Hello sent")
    let helloProcessingEntered = expectation(description: "Hello processing entered")
    let allowHelloProcessing = DispatchSemaphore(value: 0)
    let receiveReturned = DispatchSemaphore(value: 0)
    let channel = FakeAdmissionChannel(onSend: { _ in viewerHelloSent.fulfill() })
    let core = try ViewerAdmissionConnectionCore(
      id: UUID(),
      viewerInstallationID: EndpointID(rawValue: "viewer-test"),
      onHello: { _ in
        helloProcessingEntered.fulfill()
        _ = allowHelloProcessing.wait(timeout: .now() + 2)
      },
      onTerminal: {}
    )
    try core.attach(channel)
    core.start()
    core.receive(.stateChanged(.ready))
    wait(for: [viewerHelloSent], timeout: 1)
    let frame = try makeAppHelloFrame(installationID: "backpressured-app")

    DispatchQueue.global().async {
      core.receive(.received(frame))
      receiveReturned.signal()
    }
    wait(for: [helloProcessingEntered], timeout: 1)
    XCTAssertEqual(receiveReturned.wait(timeout: .now() + 0.02), .timedOut)

    allowHelloProcessing.signal()
    XCTAssertEqual(receiveReturned.wait(timeout: .now() + 1), .success)
    core.requestCancellation()
  }

  @MainActor
  func testPendingCoalescerYieldsBetweenSnapshotsAndDropsDeactivatedGeneration() async {
    let first = ViewerPendingAppSummary.fixture(name: "First")
    let latest = ViewerPendingAppSummary.fixture(name: "Latest")
    let stale = ViewerPendingAppSummary.fixture(name: "Stale")
    let heartbeat = expectation(description: "MainActor heartbeat")
    let latestDelivered = expectation(description: "Latest snapshot delivered")
    let order = LockedStringSequence()
    let coalescerBox = LockedCoalescerBox()
    let coalescer = ViewerPendingCoalescer { pending in
      if pending == [first] {
        order.append("first")
        coalescerBox.value?.submit([latest])
        Task { @MainActor in
          order.append("heartbeat")
          heartbeat.fulfill()
        }
      } else if pending == [latest] {
        order.append("latest")
        latestDelivered.fulfill()
      }
    }
    coalescerBox.set(coalescer)
    coalescer.submit([first])
    await fulfillment(of: [heartbeat, latestDelivered], timeout: 1)
    XCTAssertEqual(order.values, ["first", "heartbeat", "latest"])

    let staleDeliveries = LockedTestCounter()
    let oldGeneration = ViewerPendingCoalescer { _ in staleDeliveries.increment() }
    oldGeneration.submit([stale])
    oldGeneration.deactivate()
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(staleDeliveries.value, 0)
  }

  @MainActor
  func testStoreStatusRefreshRetainsOneLoadAndOneDirtySuccessorAcrossSustainedBurst() async {
    let status = ViewerStoreStatus(
      state: .available,
      capacityBytes: 1,
      logicalQuotaBytes: 0,
      allocatedFootprintBytes: 0,
      oldestHistoryMilliseconds: nil,
      pinnedQuotaBytes: 0,
      estimatedRetainedDurationMilliseconds: nil,
      lastCleanupCategory: .none
    )
    let firstLoadEntered = DispatchSemaphore(value: 0)
    let firstLoadRelease = DispatchSemaphore(value: 0)
    let secondLoadEntered = expectation(description: "Dirty successor load entered")
    let secondLoadRelease = DispatchSemaphore(value: 0)
    let loads = LockedTestCounter()
    let deliveries = LockedTestCounter()
    let delivered = expectation(description: "Bounded status deliveries")
    delivered.expectedFulfillmentCount = 3
    let coordinator = ViewerStoreStatusRefreshCoordinator(
      load: {
        loads.increment()
        switch loads.value {
        case 1:
          firstLoadEntered.signal()
          firstLoadRelease.wait()
        case 2:
          secondLoadEntered.fulfill()
          secondLoadRelease.wait()
        default:
          break
        }
        return status
      },
      delivery: { _ in
        deliveries.increment()
        delivered.fulfill()
      }
    )

    coordinator.request()
    XCTAssertEqual(firstLoadEntered.wait(timeout: .now() + 1), .success)
    for _ in 0..<100_000 { coordinator.request() }
    XCTAssertEqual(loads.value, 1)
    XCTAssertEqual(coordinator.pendingWorkCountForTesting, 1)
    XCTAssertTrue(coordinator.hasDirtySuccessorForTesting)

    firstLoadRelease.signal()
    await fulfillment(of: [secondLoadEntered], timeout: 1)
    for _ in 0..<100_000 { coordinator.request() }
    XCTAssertEqual(loads.value, 2)
    XCTAssertEqual(coordinator.pendingWorkCountForTesting, 1)
    XCTAssertTrue(coordinator.hasDirtySuccessorForTesting)

    secondLoadRelease.signal()
    await fulfillment(of: [delivered], timeout: 1)
    XCTAssertEqual(loads.value, 3)
    XCTAssertEqual(deliveries.value, 3)
    XCTAssertEqual(coordinator.pendingWorkCountForTesting, 0)
    XCTAssertFalse(coordinator.hasDirtySuccessorForTesting)

    await coordinator.deactivateAndWait().value
    for _ in 0..<1_000 { coordinator.request() }
    await Task.yield()
    XCTAssertEqual(loads.value, 3)

    let cleanupLoadEntered = DispatchSemaphore(value: 0)
    let cleanupLoadRelease = DispatchSemaphore(value: 0)
    let cleanupCoordinator = ViewerStoreStatusRefreshCoordinator(
      load: {
        cleanupLoadEntered.signal()
        cleanupLoadRelease.wait()
        return status
      },
      delivery: { _ in XCTFail("Deactivated load must not publish status.") }
    )
    cleanupCoordinator.request()
    XCTAssertEqual(cleanupLoadEntered.wait(timeout: .now() + 1), .success)
    let cleanupFinished = expectation(description: "Blocked status load joined")
    let cleanup = cleanupCoordinator.deactivateAndWait()
    Task {
      await cleanup.value
      cleanupFinished.fulfill()
    }
    await Task.yield()
    XCTAssertEqual(cleanupCoordinator.pendingWorkCountForTesting, 1)
    cleanupLoadRelease.signal()
    await fulfillment(of: [cleanupFinished], timeout: 1)
    XCTAssertEqual(cleanupCoordinator.pendingWorkCountForTesting, 0)
  }

  func testAdmissionManagerAutomaticallyHandsOffAndPlaceholderClosesCore() throws {
    let started = expectation(description: "Channel started")
    let viewerHelloSent = expectation(description: "Viewer Hello sent")
    let cancelled = expectation(description: "Placeholder closed accepted handoff")
    let channel = FakeAdmissionChannel(
      onSend: { _ in viewerHelloSent.fulfill() },
      onStart: { started.fulfill() },
      onCancel: { cancelled.fulfill() }
    )
    let incoming = FakeIncomingConnection(channel: channel)
    let pendingUpdates = LockedTestCounter()
    let manager = ViewerAdmissionManager(
      onPending: { summaries in
        if !summaries.isEmpty { pendingUpdates.increment() }
      }
    )
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )

    wait(for: [started], timeout: 1)
    incoming.emit(.stateChanged(.ready))
    wait(for: [viewerHelloSent], timeout: 1)
    incoming.emit(.received(try makeAppHelloFrame(installationID: "app-auto")))

    wait(for: [cancelled], timeout: 1)
    XCTAssertEqual(manager.occupiedCount, 0)
    XCTAssertEqual(channel.cancelCount, 1)
    XCTAssertEqual(pendingUpdates.value, 0)
  }

  func testAdmissionManagerSnapshotsApprovalPolicyAndHandsOffSameCore() throws {
    let started = expectation(description: "Channel started")
    let viewerHelloSent = expectation(description: "Viewer Hello sent")
    let pendingUpdated = expectation(description: "Pending approval published")
    let handedOff = expectation(description: "Attempt handed off")
    let channelClosed = expectation(description: "Handed-off channel closed at shutdown")
    let retainedHandle = LockedHandleBox()
    let pendingSummary = LockedSummaryBox()
    let handoffOwner = FakeAdmissionHandoffOwner { handle in
      retainedHandle.set(handle)
      handedOff.fulfill()
    }
    let channel = FakeAdmissionChannel(
      onSend: { _ in viewerHelloSent.fulfill() },
      onStart: { started.fulfill() },
      onCancel: { channelClosed.fulfill() }
    )
    let incoming = FakeIncomingConnection(channel: channel)
    let manager = ViewerAdmissionManager(
      onPending: { summaries in
        guard let summary = summaries.first else { return }
        pendingSummary.set(summary)
        pendingUpdated.fulfill()
      },
      handoffOwner: handoffOwner
    )
    manager.setRequiresApproval(true)
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )

    wait(for: [started], timeout: 1)
    incoming.emit(.stateChanged(.ready))
    wait(for: [viewerHelloSent], timeout: 1)
    incoming.emit(.received(try makeAppHelloFrame(installationID: "app-policy")))
    wait(for: [pendingUpdated], timeout: 1)

    manager.setRequiresApproval(false)
    XCTAssertEqual(manager.occupiedCount, 1)
    XCTAssertEqual(channel.cancelCount, 0)
    manager.accept(try XCTUnwrap(pendingSummary.value).id)

    wait(for: [handedOff], timeout: 1)
    XCTAssertEqual(manager.occupiedCount, 1)
    manager.stop()
    manager.stop()
    wait(for: [channelClosed], timeout: 1)
    XCTAssertEqual(channel.cancelCount, 1)
  }

  func testAdmissionDeadlineCoversSilentAndPartialPeersInBothPolicies() throws {
    struct TestCase {
      let requiresApproval: Bool
      let sendsPartialHello: Bool
    }
    let cases = [
      TestCase(requiresApproval: false, sendsPartialHello: false),
      TestCase(requiresApproval: true, sendsPartialHello: false),
      TestCase(requiresApproval: false, sendsPartialHello: true),
      TestCase(requiresApproval: true, sendsPartialHello: true),
    ]

    for (index, testCase) in cases.enumerated() {
      let scheduler = ManualAdmissionScheduler()
      let started = expectation(description: "Channel \(index) started")
      let cancelled = expectation(description: "Channel \(index) timed out")
      let viewerHelloSent =
        testCase.sendsPartialHello
        ? expectation(description: "Viewer Hello \(index) sent") : nil
      let channel = FakeAdmissionChannel(
        onSend: { _ in viewerHelloSent?.fulfill() },
        onStart: { started.fulfill() },
        onCancel: { cancelled.fulfill() }
      )
      let incoming = FakeIncomingConnection(channel: channel)
      let manager = ViewerAdmissionManager(
        onPending: { _ in },
        deadlineNanoseconds: 10_000,
        scheduler: scheduler.scheduler
      )
      manager.setRequiresApproval(testCase.requiresApproval)
      let generation = UUID()
      manager.activateGeneration(generation)
      manager.admit(
        incoming,
        generation: generation,
        viewerInstallationID: try EndpointID(rawValue: "viewer-test")
      )
      wait(for: [started], timeout: 1)
      scheduler.waitUntilScheduled()

      if testCase.sendsPartialHello {
        incoming.emit(.stateChanged(.ready))
        wait(for: [try XCTUnwrap(viewerHelloSent)], timeout: 1)
        let frame = try makeAppHelloFrame(installationID: "app-partial-\(index)")
        incoming.emit(.received(Data(frame.prefix(frame.count / 2))))
      }

      scheduler.advance(by: 10_000)
      wait(for: [cancelled], timeout: 1)
      XCTAssertEqual(manager.occupiedCount, 0)
      XCTAssertEqual(channel.cancelCount, 1)
      if !testCase.sendsPartialHello { XCTAssertTrue(channel.sentPayloads.isEmpty) }
    }

    XCTAssertEqual(ViewerAdmissionManager.deadlineNanoseconds, 10_000_000_000)
  }

  func testOriginalAdmissionDeadlineContinuesWhileApprovalIsPending() throws {
    let scheduler = ManualAdmissionScheduler()
    let started = expectation(description: "Channel started")
    let viewerHelloSent = expectation(description: "Viewer Hello sent")
    let pendingPublished = expectation(description: "Approval row published")
    let cancelled = expectation(description: "Original deadline cancelled pending attempt")
    let channel = FakeAdmissionChannel(
      onSend: { _ in viewerHelloSent.fulfill() },
      onStart: { started.fulfill() },
      onCancel: { cancelled.fulfill() }
    )
    let incoming = FakeIncomingConnection(channel: channel)
    let manager = ViewerAdmissionManager(
      onPending: { summaries in
        if !summaries.isEmpty { pendingPublished.fulfill() }
      },
      deadlineNanoseconds: 10_000,
      scheduler: scheduler.scheduler
    )
    manager.setRequiresApproval(true)
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )
    wait(for: [started], timeout: 1)
    scheduler.waitUntilScheduled()
    incoming.emit(.stateChanged(.ready))
    wait(for: [viewerHelloSent], timeout: 1)
    incoming.emit(.received(try makeAppHelloFrame(installationID: "app-pending-timeout")))
    wait(for: [pendingPublished], timeout: 1)

    scheduler.advance(by: 10_000)
    wait(for: [cancelled], timeout: 1)
    XCTAssertEqual(manager.occupiedCount, 0)
    XCTAssertEqual(channel.cancelCount, 1)
  }

  func testAcceptAndTimeoutChooseExactlyOneTerminalWinnerInBothOrders() throws {
    do {
      let scheduler = ManualAdmissionScheduler()
      let pending = expectation(description: "Pending before accept")
      let handedOff = expectation(description: "Accept wins")
      let summary = LockedSummaryBox()
      let handle = LockedHandleBox()
      let handoffOwner = FakeAdmissionHandoffOwner {
        handle.set($0)
        handedOff.fulfill()
      }
      let channel = FakeAdmissionChannel()
      let incoming = FakeIncomingConnection(channel: channel)
      let manager = ViewerAdmissionManager(
        onPending: { values in
          guard let value = values.first else { return }
          summary.set(value)
          pending.fulfill()
        },
        handoffOwner: handoffOwner,
        deadlineNanoseconds: 100,
        scheduler: scheduler.scheduler
      )
      manager.setRequiresApproval(true)
      let generation = UUID()
      manager.activateGeneration(generation)
      manager.admit(
        incoming,
        generation: generation,
        viewerInstallationID: try EndpointID(rawValue: "viewer-test")
      )
      scheduler.waitUntilScheduled()
      incoming.emit(.stateChanged(.ready))
      incoming.emit(.received(try makeAppHelloFrame(installationID: "accept-wins")))
      wait(for: [pending], timeout: 1)

      manager.accept(try XCTUnwrap(summary.value).id)
      wait(for: [handedOff], timeout: 1)
      scheduler.advance(by: 100)
      XCTAssertEqual(manager.occupiedCount, 1)
      XCTAssertEqual(channel.cancelCount, 0)
      handle.value?.cancel()
      _ = manager.stop()
    }

    do {
      let scheduler = ManualAdmissionScheduler()
      let pending = expectation(description: "Pending before timeout")
      let cancelled = expectation(description: "Timeout wins")
      let handedOff = expectation(description: "No handoff after timeout")
      handedOff.isInverted = true
      let summary = LockedSummaryBox()
      let channel = FakeAdmissionChannel(onCancel: { cancelled.fulfill() })
      let incoming = FakeIncomingConnection(channel: channel)
      let handoffOwner = FakeAdmissionHandoffOwner { _ in handedOff.fulfill() }
      let manager = ViewerAdmissionManager(
        onPending: { values in
          guard let value = values.first else { return }
          summary.set(value)
          pending.fulfill()
        },
        handoffOwner: handoffOwner,
        deadlineNanoseconds: 100,
        scheduler: scheduler.scheduler
      )
      manager.setRequiresApproval(true)
      let generation = UUID()
      manager.activateGeneration(generation)
      manager.admit(
        incoming,
        generation: generation,
        viewerInstallationID: try EndpointID(rawValue: "viewer-test")
      )
      scheduler.waitUntilScheduled()
      incoming.emit(.stateChanged(.ready))
      incoming.emit(.received(try makeAppHelloFrame(installationID: "timeout-wins")))
      wait(for: [pending], timeout: 1)

      scheduler.advance(by: 100)
      wait(for: [cancelled], timeout: 1)
      manager.accept(try XCTUnwrap(summary.value).id)
      wait(for: [handedOff], timeout: 0.05)
      XCTAssertEqual(manager.occupiedCount, 0)
      XCTAssertEqual(channel.cancelCount, 1)
      _ = manager.stop()
    }
  }

  func testEveryTimeoutCompetitorSelectsOneWinnerInBothOrders() async throws {
    enum Competitor: CaseIterable {
      case reject
      case pause
      case replacement
      case stop
      case channelTermination
    }

    for competitor in Competitor.allCases {
      for competitorWins in [true, false] {
        let scheduler = ManualAdmissionScheduler()
        let pending = expectation(description: "Pending \(competitor) \(competitorWins)")
        let expectsCancellation = !(competitorWins && competitor == .channelTermination)
        let cancelled =
          expectsCancellation
          ? expectation(description: "Cancelled \(competitor) \(competitorWins)") : nil
        let summary = LockedSummaryBox()
        let handoffs = LockedTestCounter()
        let channel = FakeAdmissionChannel(onCancel: { cancelled?.fulfill() })
        let incoming = FakeIncomingConnection(channel: channel)
        let owner = FakeAdmissionHandoffOwner { _ in handoffs.increment() }
        let manager = ViewerAdmissionManager(
          onPending: { values in
            guard let value = values.first else { return }
            summary.set(value)
            pending.fulfill()
          },
          handoffOwner: owner,
          deadlineNanoseconds: 100,
          scheduler: scheduler.scheduler
        )
        manager.setRequiresApproval(true)
        let generation = UUID()
        manager.activateGeneration(generation)
        manager.admit(
          incoming,
          generation: generation,
          viewerInstallationID: try EndpointID(rawValue: "viewer-test")
        )
        scheduler.waitUntilScheduled()
        incoming.emit(.stateChanged(.ready))
        incoming.emit(
          .received(
            try makeAppHelloFrame(
              installationID: "competitor-\(competitor)-\(competitorWins)"
            )
          )
        )
        await fulfillment(of: [pending], timeout: 1)
        let summaryID = try XCTUnwrap(summary.value).id

        let applyCompetitor = {
          switch competitor {
          case .reject:
            manager.reject(summaryID)
          case .pause:
            manager.setPaused(true)
          case .replacement:
            manager.cancelGeneration(generation)
          case .stop:
            _ = manager.stop()
          case .channelTermination:
            incoming.emit(
              .terminated(
                SecureTransportError(
                  code: .driverFailure,
                  message: "Safe test termination",
                  disposition: .connectionTerminal
                )
              )
            )
          }
        }

        if competitorWins {
          applyCompetitor()
          if competitor != .channelTermination {
            await fulfillment(of: [try XCTUnwrap(cancelled)], timeout: 1)
          }
          scheduler.advance(by: 100)
        } else {
          scheduler.advance(by: 100)
          await fulfillment(of: [try XCTUnwrap(cancelled)], timeout: 1)
          applyCompetitor()
        }

        let receipt = manager.stop()
        let cleanupOutcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
        XCTAssertEqual(cleanupOutcome, .completed)
        XCTAssertEqual(manager.occupiedCount, 0)
        XCTAssertEqual(handoffs.value, 0)
        XCTAssertEqual(
          channel.cancelCount,
          competitorWins && competitor == .channelTermination ? 0 : 1
        )
      }
    }
  }

  func testAdmissionManagerRejectsThirtyThirdConnectionBeforeClaimAcrossGenerations() throws {
    let allStarted = expectation(description: "Thirty-two channels started")
    allStarted.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
    let allCancelled = expectation(description: "Thirty-two channels cancelled")
    allCancelled.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
    let manager = ViewerAdmissionManager(onPending: { _ in })
    let firstGeneration = UUID()
    let secondGeneration = UUID()
    manager.activateGeneration(firstGeneration)
    manager.activateGeneration(secondGeneration)
    let viewerID = try EndpointID(rawValue: "viewer-test")
    let incoming = (0...ViewerAdmissionManager.maximumAttempts).map { _ in
      FakeIncomingConnection(
        channel: FakeAdmissionChannel(
          onStart: { allStarted.fulfill() },
          onCancel: { allCancelled.fulfill() }
        )
      )
    }

    for index in 0..<ViewerAdmissionManager.maximumAttempts {
      manager.admit(
        incoming[index],
        generation: index.isMultiple(of: 2) ? firstGeneration : secondGeneration,
        viewerInstallationID: viewerID
      )
    }
    wait(for: [allStarted], timeout: 2)
    XCTAssertEqual(manager.occupiedCount, 32)

    manager.admit(
      incoming[ViewerAdmissionManager.maximumAttempts],
      generation: secondGeneration,
      viewerInstallationID: viewerID
    )
    XCTAssertEqual(incoming[ViewerAdmissionManager.maximumAttempts].claimCount, 0)
    XCTAssertEqual(manager.occupiedCount, 32)

    manager.stop()
    XCTAssertEqual(manager.occupiedCount, ViewerAdmissionManager.maximumAttempts)
    wait(for: [allCancelled], timeout: 2)
  }

  func testPauseCancelsExistingAttemptsAndRejectsLaterArrivalsBeforeClaim() throws {
    let started = expectation(description: "Existing channel started")
    let cancelled = expectation(description: "Existing channel cancelled")
    let manager = ViewerAdmissionManager(onPending: { _ in })
    let existing = FakeIncomingConnection(
      channel: FakeAdmissionChannel(
        onStart: { started.fulfill() },
        onCancel: { cancelled.fulfill() }
      )
    )
    let later = FakeIncomingConnection(channel: FakeAdmissionChannel())
    let viewerID = try EndpointID(rawValue: "viewer-test")
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(existing, generation: generation, viewerInstallationID: viewerID)
    wait(for: [started], timeout: 1)

    manager.setPaused(true)
    wait(for: [cancelled], timeout: 1)
    XCTAssertEqual(manager.occupiedCount, 0)
    manager.admit(later, generation: generation, viewerInstallationID: viewerID)
    XCTAssertEqual(later.claimCount, 0)
  }

  func testListenerGenerationCancellationDoesNotAffectOtherGeneration() async throws {
    let bothStarted = expectation(description: "Both generation channels started")
    bothStarted.expectedFulfillmentCount = 2
    let oldCancelled = expectation(description: "Old generation channel cancelled")
    let newCancelled = expectation(description: "New generation channel cancelled at shutdown")
    let oldIncoming = FakeIncomingConnection(
      channel: FakeAdmissionChannel(
        onStart: { bothStarted.fulfill() },
        onCancel: { oldCancelled.fulfill() }
      )
    )
    let newIncoming = FakeIncomingConnection(
      channel: FakeAdmissionChannel(
        onStart: { bothStarted.fulfill() },
        onCancel: { newCancelled.fulfill() }
      )
    )
    let oldGeneration = UUID()
    let newGeneration = UUID()
    let manager = ViewerAdmissionManager(onPending: { _ in })
    let viewerID = try EndpointID(rawValue: "viewer-test")
    manager.activateGeneration(oldGeneration)
    manager.activateGeneration(newGeneration)
    manager.admit(oldIncoming, generation: oldGeneration, viewerInstallationID: viewerID)
    manager.admit(newIncoming, generation: newGeneration, viewerInstallationID: viewerID)
    await fulfillment(of: [bothStarted], timeout: 1)

    manager.cancelGeneration(oldGeneration)
    await fulfillment(of: [oldCancelled], timeout: 1)
    await waitForAdmissionOccupancy(1, in: manager)
    XCTAssertEqual(newIncoming.channel.cancelCount, 0)

    let cleanup = manager.stop()
    await fulfillment(of: [newCancelled], timeout: 1)
    let outcome = await cleanup.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(outcome, .completed)
    XCTAssertEqual(manager.occupiedCount, 0)
  }

  func testClaimInProgressCannotSurviveGenerationCancellationOrPauseResume() async throws {
    enum CancellationMode: String {
      case generation
      case pauseResume
    }

    for mode in [CancellationMode.generation, .pauseResume] {
      let enteredClaim = expectation(description: "\(mode.rawValue) entered claim")
      let admissionReturned = expectation(description: "\(mode.rawValue) admission returned")
      let channelCancelled = expectation(description: "\(mode.rawValue) channel cancelled")
      let releaseClaim = DispatchSemaphore(value: 0)
      let channel = FakeAdmissionChannel(onCancel: { channelCancelled.fulfill() })
      let incoming = FakeIncomingConnection(
        channel: channel,
        beforeClaim: {
          enteredClaim.fulfill()
          releaseClaim.wait()
        }
      )
      let manager = ViewerAdmissionManager(onPending: { _ in })
      let generation = UUID()
      manager.activateGeneration(generation)
      let viewerID = try EndpointID(rawValue: "viewer-test")

      DispatchQueue.global().async {
        manager.admit(incoming, generation: generation, viewerInstallationID: viewerID)
        admissionReturned.fulfill()
      }
      await fulfillment(of: [enteredClaim], timeout: 1)
      XCTAssertEqual(manager.occupiedCount, 1)

      switch mode {
      case .generation:
        manager.cancelGeneration(generation)
      case .pauseResume:
        manager.setPaused(true)
        manager.setPaused(false)
      }
      XCTAssertEqual(manager.occupiedCount, 1)
      releaseClaim.signal()

      await fulfillment(of: [admissionReturned, channelCancelled], timeout: 1)
      XCTAssertEqual(channel.startCount, 0)
      XCTAssertEqual(channel.cancelCount, 1)
      XCTAssertEqual(incoming.claimCount, 1)
      let receipt = manager.stop()
      let outcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
      XCTAssertEqual(outcome, .completed)
      XCTAssertEqual(manager.occupiedCount, 0)
    }
  }

  func testListenerAdmissionIngressBoundsBurstBeforeMainActorWork() async throws {
    let allStarted = expectation(description: "Thirty-two ingress channels started")
    allStarted.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
    let allCancelled = expectation(description: "Thirty-two ingress channels cancelled")
    allCancelled.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
    let manager = ViewerAdmissionManager(onPending: { _ in })
    let ingress = ViewerListenerAdmissionIngress()
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-test")
    manager.activateGeneration(generation)
    ingress.activate(
      manager: manager,
      generation: generation,
      viewerInstallationID: viewerID
    )
    let incoming = (0...ViewerAdmissionManager.maximumAttempts).map { _ in
      FakeIncomingConnection(
        channel: FakeAdmissionChannel(
          onStart: { allStarted.fulfill() },
          onCancel: { allCancelled.fulfill() }
        )
      )
    }

    for connection in incoming { ingress.receive(connection) }
    await fulfillment(of: [allStarted], timeout: 2)
    XCTAssertEqual(manager.occupiedCount, ViewerAdmissionManager.maximumAttempts)
    XCTAssertEqual(incoming.last?.claimCount, 0)
    XCTAssertEqual(incoming.last?.rejectionCount, 1)

    let receipt = manager.stop()
    await fulfillment(of: [allCancelled], timeout: 2)
    let outcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(outcome, .completed)
    XCTAssertEqual(manager.occupiedCount, 0)
  }

  func testCleanupReceiptCompletesOrTimesOutWithoutReopeningAdmission() async throws {
    let scheduler = ManualAdmissionScheduler()
    let cancellationGate = AsyncTestGate()
    let channel = FakeAdmissionChannel(
      cancelOperation: { await cancellationGate.wait() }
    )
    let incoming = FakeIncomingConnection(channel: channel)
    let manager = ViewerAdmissionManager(
      onPending: { _ in },
      scheduler: scheduler.scheduler
    )
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )
    scheduler.waitUntilScheduled()

    let receipt = manager.stop()
    let wait = Task {
      await receipt.wait(timeoutNanoseconds: 100, scheduler: scheduler.scheduler)
    }
    scheduler.waitUntilScheduled()
    scheduler.advance(by: 100)
    let timeoutOutcome = await wait.value
    XCTAssertEqual(timeoutOutcome, .timedOut)
    XCTAssertEqual(manager.occupiedCount, 1)

    let rejected = FakeIncomingConnection(channel: FakeAdmissionChannel())
    manager.admit(
      rejected,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )
    XCTAssertEqual(rejected.rejectionCount, 1)
    XCTAssertEqual(rejected.claimCount, 0)

    cancellationGate.open()
    let final = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(final, .completed)
    XCTAssertEqual(channel.cancelCount, 1)
    XCTAssertEqual(manager.occupiedCount, 0)
    XCTAssertTrue(receipt === manager.stop())
  }

  func testStopReceiptOwnsCleanupAlreadyStartedByEveryAdmissionPolicy() async throws {
    enum TerminalAction: CaseIterable {
      case pause
      case reject
      case timeout
      case replacement
    }

    for action in TerminalAction.allCases {
      let scheduler = ManualAdmissionScheduler()
      let cancellationGate = AsyncTestGate()
      let pending = expectation(description: "Pending row published for \(action)")
      let summary = LockedSummaryBox()
      let channel = FakeAdmissionChannel(cancelOperation: { await cancellationGate.wait() })
      let incoming = FakeIncomingConnection(channel: channel)
      let manager = ViewerAdmissionManager(
        onPending: { values in
          guard let value = values.first else { return }
          summary.set(value)
          pending.fulfill()
        },
        deadlineNanoseconds: 100,
        scheduler: scheduler.scheduler
      )
      manager.setRequiresApproval(true)
      let generation = UUID()
      manager.activateGeneration(generation)
      manager.admit(
        incoming,
        generation: generation,
        viewerInstallationID: try EndpointID(rawValue: "viewer-test")
      )
      scheduler.waitUntilScheduled()
      incoming.emit(.stateChanged(.ready))
      incoming.emit(.received(try makeAppHelloFrame(installationID: "policy-\(action)")))
      await fulfillment(of: [pending], timeout: 1)

      switch action {
      case .pause:
        manager.setPaused(true)
      case .reject:
        manager.reject(try XCTUnwrap(summary.value).id)
      case .timeout:
        scheduler.advance(by: 100)
      case .replacement:
        manager.cancelGeneration(generation)
      }
      cancellationGate.waitUntilEntered()

      let receipt = manager.stop()
      let boundedWait = Task {
        await receipt.wait(timeoutNanoseconds: 100, scheduler: scheduler.scheduler)
      }
      scheduler.waitUntilScheduled()
      scheduler.advance(by: 100)
      let timeoutOutcome = await boundedWait.value
      XCTAssertEqual(timeoutOutcome, .timedOut)
      XCTAssertEqual(manager.occupiedCount, 1)

      cancellationGate.open()
      let cleanupOutcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
      XCTAssertEqual(cleanupOutcome, .completed)
      XCTAssertEqual(channel.cancelCount, 1)
      XCTAssertEqual(manager.occupiedCount, 0)
    }
  }

  func testStopReceiptRetainsClaimInProgressAndItsLateChannelCleanup() async throws {
    let scheduler = ManualAdmissionScheduler()
    let claimEntered = DispatchSemaphore(value: 0)
    let releaseClaim = DispatchSemaphore(value: 0)
    let cancellationGate = AsyncTestGate()
    let channel = FakeAdmissionChannel(cancelOperation: { await cancellationGate.wait() })
    let incoming = FakeIncomingConnection(
      channel: channel,
      beforeClaim: {
        claimEntered.signal()
        _ = releaseClaim.wait(timeout: .now() + 2)
      }
    )
    let manager = ViewerAdmissionManager(onPending: { _ in }, scheduler: scheduler.scheduler)
    let generation = UUID()
    manager.activateGeneration(generation)
    let admissionReturned = expectation(description: "Blocked admission returned")
    DispatchQueue.global().async {
      manager.admit(
        incoming,
        generation: generation,
        viewerInstallationID: try! EndpointID(rawValue: "viewer-test")
      )
      admissionReturned.fulfill()
    }
    XCTAssertEqual(claimEntered.wait(timeout: .now() + 1), .success)

    let receipt = manager.stop()
    let boundedWait = Task {
      await receipt.wait(timeoutNanoseconds: 100, scheduler: scheduler.scheduler)
    }
    scheduler.waitUntilScheduled()
    scheduler.advance(by: 100)
    let timeoutOutcome = await boundedWait.value
    XCTAssertEqual(timeoutOutcome, .timedOut)
    XCTAssertEqual(manager.occupiedCount, 1)

    releaseClaim.signal()
    cancellationGate.waitUntilEntered()
    cancellationGate.open()
    await fulfillment(of: [admissionReturned], timeout: 1)
    let cleanupOutcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(cleanupOutcome, .completed)
    XCTAssertEqual(channel.cancelCount, 1)
    XCTAssertEqual(manager.occupiedCount, 0)
  }

  func testStopReceiptIncludesAcceptedHandoffCleanup() async throws {
    let scheduler = ManualAdmissionScheduler()
    let shutdownGate = AsyncTestGate()
    let handedOff = expectation(description: "Connection handed off")
    let channel = FakeAdmissionChannel()
    let incoming = FakeIncomingConnection(channel: channel)
    let owner = FakeAdmissionHandoffOwner(
      onTransfer: { _ in handedOff.fulfill() },
      shutdownOperation: { await shutdownGate.wait() }
    )
    let manager = ViewerAdmissionManager(
      onPending: { _ in },
      handoffOwner: owner,
      scheduler: scheduler.scheduler
    )
    let generation = UUID()
    manager.activateGeneration(generation)
    manager.admit(
      incoming,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-test")
    )
    scheduler.waitUntilScheduled()
    incoming.emit(.stateChanged(.ready))
    incoming.emit(.received(try makeAppHelloFrame(installationID: "handoff-cleanup")))
    await fulfillment(of: [handedOff], timeout: 1)

    let receipt = manager.stop()
    shutdownGate.waitUntilEntered()
    let boundedWait = Task {
      await receipt.wait(timeoutNanoseconds: 100, scheduler: scheduler.scheduler)
    }
    scheduler.waitUntilScheduled()
    scheduler.advance(by: 100)
    let timeoutOutcome = await boundedWait.value
    XCTAssertEqual(timeoutOutcome, .timedOut)
    XCTAssertEqual(manager.occupiedCount, 1)

    shutdownGate.open()
    let cleanupOutcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(cleanupOutcome, .completed)
    XCTAssertEqual(channel.cancelCount, 1)
    XCTAssertEqual(manager.occupiedCount, 0)
  }

  func testCombinedAdmissionBoundIncludesCancellingAndPlaceholderOwnedConnections()
    async throws
  {
    enum RetainedMode: CaseIterable {
      case cancellation
      case placeholderHandoff
    }

    for mode in RetainedMode.allCases {
      let cleanupGate = AsyncTestGate()
      let allStarted = expectation(description: "All bounded channels started for \(mode)")
      allStarted.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
      let allCancelled = expectation(description: "All bounded channels cancelled for \(mode)")
      allCancelled.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
      let manager = ViewerAdmissionManager(onPending: { _ in })
      let generation = UUID()
      manager.activateGeneration(generation)
      let viewerID = try EndpointID(rawValue: "viewer-test")
      let incoming = (0...ViewerAdmissionManager.maximumAttempts).map { _ in
        FakeIncomingConnection(
          channel: FakeAdmissionChannel(
            onStart: { allStarted.fulfill() },
            onCancel: { allCancelled.fulfill() },
            cancelOperation: { await cleanupGate.wait() }
          )
        )
      }

      for index in 0..<ViewerAdmissionManager.maximumAttempts {
        manager.admit(incoming[index], generation: generation, viewerInstallationID: viewerID)
      }
      await fulfillment(of: [allStarted], timeout: 2)

      switch mode {
      case .cancellation:
        manager.setPaused(true)
        manager.setPaused(false)
      case .placeholderHandoff:
        for index in 0..<ViewerAdmissionManager.maximumAttempts {
          incoming[index].emit(.stateChanged(.ready))
          incoming[index].emit(
            .received(try makeAppHelloFrame(installationID: "bounded-handoff-\(index)"))
          )
        }
      }
      cleanupGate.waitUntilEntered(count: ViewerAdmissionManager.maximumAttempts)
      XCTAssertEqual(manager.occupiedCount, ViewerAdmissionManager.maximumAttempts)

      manager.admit(
        incoming[ViewerAdmissionManager.maximumAttempts],
        generation: generation,
        viewerInstallationID: viewerID
      )
      XCTAssertEqual(incoming[ViewerAdmissionManager.maximumAttempts].claimCount, 0)
      XCTAssertEqual(incoming[ViewerAdmissionManager.maximumAttempts].rejectionCount, 1)

      let receipt = manager.stop()
      cleanupGate.open()
      await fulfillment(of: [allCancelled], timeout: 2)
      let outcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
      XCTAssertEqual(outcome, .completed)
      XCTAssertEqual(manager.occupiedCount, 0)
      XCTAssertEqual(
        incoming.dropLast().map(\.channel.cancelCount),
        Array(repeating: 1, count: ViewerAdmissionManager.maximumAttempts)
      )
    }
  }

  func testHandoffCapacityRecyclesAcrossWavesInOneRuntime() async throws {
    let firstWaveTransferred = expectation(description: "First handoff wave transferred")
    firstWaveTransferred.expectedFulfillmentCount = ViewerAdmissionManager.maximumAttempts
    let secondWaveTransferred = expectation(description: "Second handoff wave transferred")
    let recycledCount = 8
    secondWaveTransferred.expectedFulfillmentCount = recycledCount
    let handles = LockedHandleCollection()
    let owner = FakeAdmissionHandoffOwner(
      onTransfer: { handle in
        let count = handles.append(handle)
        if count <= ViewerAdmissionManager.maximumAttempts {
          firstWaveTransferred.fulfill()
        } else {
          secondWaveTransferred.fulfill()
        }
      }
    )
    let manager = ViewerAdmissionManager(onPending: { _ in }, handoffOwner: owner)
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-test")
    manager.activateGeneration(generation)

    let firstWave = (0..<ViewerAdmissionManager.maximumAttempts).map { index in
      FakeIncomingConnection(channel: FakeAdmissionChannel())
    }
    for (index, incoming) in firstWave.enumerated() {
      manager.admit(incoming, generation: generation, viewerInstallationID: viewerID)
      incoming.emit(.stateChanged(.ready))
      incoming.emit(
        .received(try makeAppHelloFrame(installationID: "recycle-first-\(index)"))
      )
    }
    await fulfillment(of: [firstWaveTransferred], timeout: 2)
    XCTAssertEqual(manager.occupiedCount, ViewerAdmissionManager.maximumAttempts)

    for handle in handles.values.prefix(recycledCount) {
      await handle.cancelAndWait()
    }
    XCTAssertEqual(
      manager.occupiedCount,
      ViewerAdmissionManager.maximumAttempts - recycledCount
    )

    let secondWave = (0..<recycledCount).map { _ in
      FakeIncomingConnection(channel: FakeAdmissionChannel())
    }
    for (index, incoming) in secondWave.enumerated() {
      manager.admit(incoming, generation: generation, viewerInstallationID: viewerID)
      incoming.emit(.stateChanged(.ready))
      incoming.emit(
        .received(try makeAppHelloFrame(installationID: "recycle-second-\(index)"))
      )
    }
    await fulfillment(of: [secondWaveTransferred], timeout: 2)
    XCTAssertEqual(manager.occupiedCount, ViewerAdmissionManager.maximumAttempts)

    let overflow = FakeIncomingConnection(channel: FakeAdmissionChannel())
    manager.admit(overflow, generation: generation, viewerInstallationID: viewerID)
    XCTAssertEqual(overflow.claimCount, 0)
    XCTAssertEqual(overflow.rejectionCount, 1)

    let receipt = manager.stop()
    let outcome = await receipt.wait(timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(outcome, .completed)
    XCTAssertEqual(manager.occupiedCount, 0)
    XCTAssertEqual(
      (firstWave + secondWave).map(\.channel.cancelCount),
      Array(repeating: 1, count: ViewerAdmissionManager.maximumAttempts + recycledCount)
    )
  }

  @MainActor
  func testIdentityResetWaitsForAdmissionCleanupReceipt() async throws {
    enum ResetMode: String {
      case tls
      case full
    }

    for mode in [ResetMode.tls, .full] {
      let cleanupGate = AsyncTestGate()
      let resetCalled = expectation(description: "\(mode.rawValue) reset called after cleanup")
      let tlsResetCount = LockedTestCounter()
      let fullResetCount = LockedTestCounter()
      let listener = FakeViewerSecureListener(
        eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
      )
      let identity = try EndpointID(rawValue: "viewer-test")
      let model = ViewerApplicationModel(
        preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
        dependencies: ViewerRuntimeDependencies(
          loadIdentity: {
            ViewerPreparedIdentity(
              installationID: identity,
              makeListener: { _ in listener }
            )
          },
          resetTLSIdentity: {
            tlsResetCount.increment()
            if mode == .tls { resetCalled.fulfill() }
          },
          resetAllIdentity: {
            fullResetCount.increment()
            if mode == .full { resetCalled.fulfill() }
          },
          generatePairingCode: { try PairingCode("ABCDEF") },
          makeRuntimeComponents: { runtimeLogicalID in
            let owner = FakeAdmissionHandoffOwner(
              runtimeLogicalID: runtimeLogicalID,
              managerGeneration: 1,
              shutdownOperation: { await cleanupGate.wait() }
            )
            let liveWindow = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
            let compositeJournal = ViewerCompositeSessionJournal(
              runtimeLogicalID: runtimeLogicalID,
              durableJournal: ViewerNoopSessionJournal(),
              liveWindow: liveWindow
            )
            let explorerInputs = ViewerRuntimeExplorerInputs(
              runtimeLogicalID: runtimeLogicalID,
              storeGateway: ViewerStoreExplorerGateway(),
              liveObservations: liveWindow
            )
            return ViewerRuntimeComponents(
              runtimeLogicalID: runtimeLogicalID,
              managerGeneration: 1,
              handoffOwner: owner,
              sessionControl: owner,
              liveObservations: liveWindow,
              compositeJournal: compositeJournal,
              explorerInputs: explorerInputs,
              cleanupReceipt: ViewerRuntimeCleanupReceipt {
                liveWindow.sealPresentation()
              }
            )
          }
        )
      )
      model.openWindow()
      await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)
      let explorer = try XCTUnwrap(model.explorerController)
      let composer = try XCTUnwrap(model.composerController)

      switch mode {
      case .tls:
        model.resetTLSIdentity()
      case .full:
        model.requestFullIdentityReset()
        model.confirmFullIdentityReset()
      }
      cleanupGate.waitUntilEntered()
      XCTAssertEqual(tlsResetCount.value + fullResetCount.value, 0)
      XCTAssertEqual(model.status, .stopping)
      cleanupGate.open()
      await fulfillment(of: [resetCalled], timeout: 1)
      XCTAssertEqual(tlsResetCount.value, mode == .tls ? 1 : 0)
      XCTAssertEqual(fullResetCount.value, mode == .full ? 1 : 0)
      XCTAssertEqual(explorer.pendingCleanupWorkCount, 0)
      XCTAssertEqual(composer.pendingCleanupWorkCount, 0)
      _ = await model.prepareForTermination()
    }
  }

  func testRuntimeComponentsKeepOneTypedManagerAndClearLiveStateAfterDurableShutdown()
    async throws
  {
    let runtimeLogicalID = UUID()
    let managerGeneration: UInt64 = 41
    let durableEndGate = AsyncTestGate()
    let journal = RuntimeComponentJournalSpy(endGate: durableEndGate)
    let suiteName = "ViewerFoundationTests.runtime-components.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = ViewerDevicePreferences(defaults: defaults)
    let components = ViewerRuntimeComponents.make(
      runtimeLogicalID: runtimeLogicalID,
      managerGeneration: managerGeneration,
      preferences: preferences,
      durableJournal: journal
    )
    let liveWindow = try XCTUnwrap(components.liveObservations as? ViewerLiveEventWindow)
    let route = ViewerLogicalRoute(
      installationID: try EndpointID(rawValue: "runtime-components-app"),
      applicationIdentifier: "com.nearwire.runtime-components"
    )

    XCTAssertEqual(components.runtimeLogicalID, runtimeLogicalID)
    XCTAssertEqual(components.managerGeneration, managerGeneration)
    XCTAssertEqual(components.sessionControl.runtimeLogicalID, runtimeLogicalID)
    XCTAssertEqual(components.sessionControl.managerGeneration, managerGeneration)
    XCTAssertEqual(components.compositeJournal.runtimeLogicalID, runtimeLogicalID)
    XCTAssertEqual(components.explorerInputs.runtimeLogicalID, runtimeLogicalID)
    XCTAssertTrue(
      (components.handoffOwner as AnyObject) === (components.sessionControl as AnyObject)
    )
    XCTAssertTrue(
      (components.liveObservations as AnyObject)
        === (components.explorerInputs.liveObservations as AnyObject)
    )
    XCTAssertEqual(journal.startedRuntimeIDs, [runtimeLogicalID])
    XCTAssertTrue(components.sessionControl.setNickname("Before cleanup", route: route))

    _ = await components.cleanupReceipt.begin().value
    XCTAssertTrue(liveWindow.isPresentationSealed)
    XCTAssertFalse(liveWindow.isCleared)
    XCTAssertFalse(components.sessionControl.setNickname("After cleanup", route: route))

    let shutdown = components.handoffOwner.beginShutdown()
    durableEndGate.waitUntilEntered()
    XCTAssertFalse(liveWindow.isCleared)
    durableEndGate.open()
    await shutdown.value

    XCTAssertEqual(journal.endedRuntimeIDs, [runtimeLogicalID])
    XCTAssertTrue(liveWindow.isCleared)
    XCTAssertEqual(Array(Mirror(reflecting: components).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: components.explorerInputs).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: components.cleanupReceipt).children).count, 0)
  }

  func testCommittedObservationConsumesPrecomputedCanonicalContent() throws {
    let runtimeLogicalID = UUID()
    let context = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Precomputed Content"
    )
    let precomputed = Data(#"{"precomputed":true}"#.utf8)
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["original": .string("must-not-be-reencoded")]),
        createdAt: Date(timeIntervalSince1970: 1),
        sessionEpoch: SessionEpoch(),
        sequence: 1
      ),
      viewerWallMilliseconds: 1_000,
      viewerMonotonicNanoseconds: 1_000,
      deterministicEventBytes: 128,
      canonicalContent: precomputed,
      initialDisposition: .buffered
    )
    XCTAssertEqual(observation.durableProjection.canonicalContent, precomputed)
  }

  func testCommittedObservationComparatorAndLiveIngressPreserveTheFirstValue() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let sessionEpoch = SessionEpoch()
    let firstContext = try makeObservationContext(
      connectionID: connectionID,
      displayName: "First display"
    )
    let laterContext = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Later display"
    )
    let firstEnvelope = try makeObservationEnvelope(
      content: .object(["value": .integer(1)]),
      createdAt: Date(timeIntervalSince1970: 1_000.000_1),
      sessionEpoch: sessionEpoch
    )
    let equalEnvelope = try makeObservationEnvelope(
      id: firstEnvelope.id,
      content: firstEnvelope.content,
      createdAt: Date(timeIntervalSince1970: 1_000.000_4),
      sessionEpoch: sessionEpoch
    )
    let conflictingEnvelope = try makeObservationEnvelope(
      id: firstEnvelope.id,
      content: .object(["value": .integer(2)]),
      createdAt: firstEnvelope.createdAt,
      sessionEpoch: sessionEpoch
    )
    let nextMillisecondEnvelope = try makeObservationEnvelope(
      id: firstEnvelope.id,
      content: firstEnvelope.content,
      createdAt: Date(timeIntervalSince1970: 1_000.001_1),
      sessionEpoch: sessionEpoch
    )
    let first = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: firstContext,
      nickname: "First nickname",
      envelope: firstEnvelope,
      viewerWallMilliseconds: 10,
      viewerMonotonicNanoseconds: 20,
      deterministicEventBytes: 30,
      initialDisposition: .buffered
    )
    let identical = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: laterContext,
      nickname: "Later nickname",
      envelope: equalEnvelope,
      viewerWallMilliseconds: 100,
      viewerMonotonicNanoseconds: 200,
      deterministicEventBytes: 300,
      initialDisposition: .buffered
    )
    let conflict = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: laterContext,
      nickname: nil,
      envelope: conflictingEnvelope,
      viewerWallMilliseconds: 101,
      viewerMonotonicNanoseconds: 201,
      deterministicEventBytes: 301,
      initialDisposition: .buffered
    )
    let nextMillisecond = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: firstContext,
      nickname: nil,
      envelope: nextMillisecondEnvelope,
      viewerWallMilliseconds: 10,
      viewerMonotonicNanoseconds: 20,
      deterministicEventBytes: 30,
      initialDisposition: .buffered
    )
    let differentDisposition = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: firstContext,
      nickname: nil,
      envelope: firstEnvelope,
      viewerWallMilliseconds: 10,
      viewerMonotonicNanoseconds: 20,
      deterministicEventBytes: 30,
      initialDisposition: .consumerAccepted
    )
    let persistedFieldEnvelopes = try [
      makeObservationEnvelope(
        id: EventID(),
        content: firstEnvelope.content,
        createdAt: firstEnvelope.createdAt,
        sessionEpoch: sessionEpoch
      ),
      makeObservationEnvelope(
        typeRawValue: "test.observation.changed",
        content: firstEnvelope.content,
        createdAt: firstEnvelope.createdAt,
        sessionEpoch: sessionEpoch
      ),
      makeObservationEnvelope(
        id: firstEnvelope.id,
        content: firstEnvelope.content,
        createdAt: firstEnvelope.createdAt,
        monotonicTimestampNanoseconds: 501,
        sessionEpoch: sessionEpoch
      ),
      makeObservationEnvelope(
        id: firstEnvelope.id,
        content: firstEnvelope.content,
        createdAt: firstEnvelope.createdAt,
        sessionEpoch: sessionEpoch,
        priority: .high
      ),
      makeObservationEnvelope(
        id: firstEnvelope.id,
        content: firstEnvelope.content,
        createdAt: firstEnvelope.createdAt,
        sessionEpoch: sessionEpoch,
        ttl: EventTTL(milliseconds: 60_001)
      ),
      makeObservationEnvelope(
        id: firstEnvelope.id,
        content: firstEnvelope.content,
        createdAt: firstEnvelope.createdAt,
        sessionEpoch: sessionEpoch,
        schemaVersion: EventSchemaVersion(2)
      ),
      makeObservationEnvelope(
        id: firstEnvelope.id,
        content: firstEnvelope.content,
        createdAt: firstEnvelope.createdAt,
        sessionEpoch: sessionEpoch,
        causality: EventCausality(correlationID: EventID())
      ),
      makeObservationEnvelope(
        id: firstEnvelope.id,
        content: firstEnvelope.content,
        createdAt: firstEnvelope.createdAt,
        sessionEpoch: sessionEpoch,
        causality: EventCausality(replyTo: EventID())
      ),
    ]
    let persistedFieldConflicts = try persistedFieldEnvelopes.map { envelope in
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: firstContext,
        nickname: nil,
        envelope: envelope,
        viewerWallMilliseconds: 10,
        viewerMonotonicNanoseconds: 20,
        deterministicEventBytes: 30,
        initialDisposition: .buffered
      )
    }

    XCTAssertEqual(first.durableProjection, identical.durableProjection)
    XCTAssertNotEqual(first.session, identical.session)
    XCTAssertNotEqual(first.viewerWallMilliseconds, identical.viewerWallMilliseconds)
    XCTAssertNotEqual(first.viewerMonotonicNanoseconds, identical.viewerMonotonicNanoseconds)
    XCTAssertNotEqual(first.deterministicEventBytes, identical.deterministicEventBytes)
    XCTAssertNotEqual(first.durableProjection, conflict.durableProjection)
    XCTAssertNotEqual(first.durableProjection, nextMillisecond.durableProjection)
    XCTAssertNotEqual(first.durableProjection, differentDisposition.durableProjection)
    XCTAssertTrue(
      persistedFieldConflicts.allSatisfy { $0.durableProjection != first.durableProjection }
    )

    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.live-duplicate-comparison"
    )
    let projectionGate = DispatchSemaphore(value: 0)
    projectionQueue.async { projectionGate.wait() }
    let liveWindow = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )
    let durableJournal = CommittedObservationJournalSpy()
    let journal = ViewerCompositeSessionJournal(
      runtimeLogicalID: runtimeLogicalID,
      durableJournal: durableJournal,
      liveWindow: liveWindow
    )
    let outcomes = LockedJournalOutcomeCollection()
    journal.eventCommitted(first) { outcomes.append($0) }
    journal.eventCommitted(identical) { outcomes.append($0) }
    journal.eventCommitted(conflict) { outcomes.append($0) }
    XCTAssertEqual(outcomes.values, [.accepted])
    XCTAssertEqual(durableJournal.observations.map(\.observationID), [first.observationID])
    projectionGate.signal()
    liveWindow.waitForProjectionForTesting()

    XCTAssertEqual(outcomes.values, [.accepted, .identical, .presentationConflict])
    XCTAssertEqual(durableJournal.observations.map(\.observationID), [first.observationID])
    for fieldConflict in persistedFieldConflicts {
      XCTAssertEqual(liveWindow.offer(fieldConflict), .presentationConflict)
    }
    XCTAssertEqual(liveWindow.retainedObservationCount, 1)
    XCTAssertEqual(
      liveWindow.retainedObservationBytes,
      first.deterministicEventBytes + ViewerLiveProjectionLimits.fixedEntryOverheadBytes
    )
    XCTAssertEqual(liveWindow.conflictCount, 1)
    liveWindow.applyStoreOutcome(
      .identical,
      key: first.key,
      observationID: UUID()
    )
    liveWindow.waitForProjectionForTesting()
    XCTAssertEqual(liveWindow.retainedObservationCount, 1)
    XCTAssertEqual(liveWindow.evict(first.key)?.observationID, first.observationID)
    XCTAssertEqual(liveWindow.retainedObservationCount, 0)
    XCTAssertEqual(liveWindow.lostHorizonCount, 1)
    liveWindow.applyStoreOutcome(
      .journalConflict,
      key: first.key,
      observationID: first.observationID
    )
    liveWindow.waitForProjectionForTesting()
    XCTAssertEqual(liveWindow.lostHorizonCount, 2)
    XCTAssertEqual(liveWindow.conflictCount, 0)
    XCTAssertEqual(liveWindow.offer(conflict), .accepted)
    liveWindow.waitForProjectionForTesting()
    XCTAssertEqual(liveWindow.retainedObservationCount, 1)
    liveWindow.applyStoreOutcome(
      .journalConflict,
      key: conflict.key,
      observationID: conflict.observationID
    )
    liveWindow.waitForProjectionForTesting()
    XCTAssertEqual(liveWindow.retainedObservationCount, 0)
    XCTAssertEqual(liveWindow.conflictCount, 1)
    XCTAssertEqual(Array(Mirror(reflecting: first).children).count, 1)
    XCTAssertEqual(Array(Mirror(reflecting: first.durableProjection).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: first.session).children).count, 0)
  }

  func testUntrackedDuplicatesUseDurableAuthorityAndShutdownSealsCallbacks() async throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Untracked duplicate"
    )
    let epoch = SessionEpoch()
    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.live-untracked-duplicate"
    )
    let projectionGate = DispatchSemaphore(value: 0)
    projectionQueue.async { projectionGate.wait() }
    let liveWindow = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )
    let durableJournal = CommittedObservationJournalSpy()
    let journal = ViewerCompositeSessionJournal(
      runtimeLogicalID: runtimeLogicalID,
      durableJournal: durableJournal,
      liveWindow: liveWindow
    )
    let outcomes = LockedJournalOutcomeCollection()

    var observations: [ViewerCommittedEventObservation] = []
    for sequence in 0..<UInt64(ViewerLiveProjectionLimits.ingressCount) {
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["sequence": .integer(Int64(sequence))]),
          createdAt: Date(timeIntervalSince1970: 7_000),
          sessionEpoch: epoch,
          sequence: sequence
        ),
        viewerWallMilliseconds: 7_000_000,
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      observations.append(observation)
      journal.eventCommitted(observation) { outcomes.append($0) }
    }
    let authority = try XCTUnwrap(observations.first)
    let identical = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: "Later metadata",
      envelope: authority.envelope,
      viewerWallMilliseconds: 7_000_001,
      viewerMonotonicNanoseconds: 999,
      deterministicEventBytes: 2,
      initialDisposition: .buffered
    )
    let conflictingEnvelope = try makeObservationEnvelope(
      id: authority.envelope.id,
      content: .object(["sequence": .integer(-1)]),
      createdAt: authority.envelope.createdAt,
      sessionEpoch: epoch,
      sequence: authority.key.wireSequence
    )
    let conflict = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: conflictingEnvelope,
      viewerWallMilliseconds: 7_000_002,
      viewerMonotonicNanoseconds: 1_000,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )

    journal.eventCommitted(identical) { outcomes.append($0) }
    journal.eventCommitted(conflict) { outcomes.append($0) }
    XCTAssertEqual(outcomes.values.count, ViewerLiveProjectionLimits.ingressCount + 2)
    XCTAssertEqual(Array(outcomes.values.suffix(2)), [.identical, .journalConflict])
    XCTAssertEqual(durableJournal.commitCount, ViewerLiveProjectionLimits.ingressCount + 2)

    projectionGate.signal()
    liveWindow.waitForProjectionForTesting()
    XCTAssertEqual(liveWindow.retainedObservationCount, ViewerLiveProjectionLimits.ingressCount)
    XCTAssertEqual(liveWindow.snapshot().gaps.ingressOverflowCount, 2)

    await journal.runtimeEnded(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 7_001_000,
      monotonicNanoseconds: 2_000
    )
    XCTAssertTrue(liveWindow.isCleared)
    let commitsBeforeSealedOffer = durableJournal.commitCount
    let sealed = LockedJournalOutcomeCollection()
    journal.eventCommitted(authority) { sealed.append($0) }
    XCTAssertEqual(sealed.values, [.sealed])
    XCTAssertEqual(durableJournal.commitCount, commitsBeforeSealedOffer)
  }

  func testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState() async throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Bounded projection"
    )
    let epoch = SessionEpoch()
    let projectionQueue = DispatchQueue(label: "ViewerFoundationTests.live-projection-bound")
    let projectionGate = DispatchSemaphore(value: 0)
    projectionQueue.async { projectionGate.wait() }
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func observation(sequence: UInt64, bytes: Int = 1) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: "Device",
        envelope: makeObservationEnvelope(
          content: .object(["sequence": .integer(Int64(sequence))]),
          createdAt: Date(timeIntervalSince1970: 2_000),
          sessionEpoch: epoch,
          sequence: sequence
        ),
        viewerWallMilliseconds: 2_000_000,
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: bytes,
        initialDisposition: .buffered
      )
    }

    for sequence in 0..<UInt64(ViewerLiveProjectionLimits.ingressCount) {
      XCTAssertEqual(try window.offer(observation(sequence: sequence)), .accepted)
    }
    XCTAssertEqual(
      try window.offer(observation(sequence: UInt64(ViewerLiveProjectionLimits.ingressCount))),
      .untracked
    )
    projectionGate.signal()
    window.waitForProjectionForTesting()

    var snapshot = window.snapshot()
    XCTAssertEqual(snapshot.events.count, ViewerLiveProjectionLimits.ingressCount)
    XCTAssertEqual(snapshot.sessions.count, 1)
    XCTAssertEqual(snapshot.gaps.ingressOverflowCount, 1)
    XCTAssertEqual(
      snapshot.accountedEventBytes,
      ViewerLiveProjectionLimits.ingressCount
        * (ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 1)
    )
    let initialDiagnostics = window.diagnosticsForTesting()
    XCTAssertEqual(initialDiagnostics.ingressOfferCount, 65)
    XCTAssertEqual(initialDiagnostics.drainScheduleCount, 1)
    XCTAssertEqual(initialDiagnostics.dirtySuccessorCount, 1)
    XCTAssertEqual(initialDiagnostics.drainRunCount, 1)
    XCTAssertEqual(initialDiagnostics.maximumConcurrentDrainCount, 1)
    XCTAssertEqual(initialDiagnostics.snapshotPublicationCount, 1)

    for sequence in UInt64(ViewerLiveProjectionLimits.ingressCount + 1)..<513 {
      XCTAssertEqual(try window.offer(observation(sequence: sequence)), .accepted)
      if sequence % 32 == 0 { window.waitForProjectionForTesting() }
    }
    window.waitForProjectionForTesting()
    XCTAssertEqual(try window.offer(observation(sequence: 513)), .accepted)
    window.waitForProjectionForTesting()

    snapshot = window.snapshot()
    XCTAssertEqual(snapshot.events.count, ViewerLiveProjectionLimits.retainedCount)
    XCTAssertEqual(snapshot.gaps.windowOverflowCount, 1)
    XCTAssertEqual(window.lostHorizonCount, 2)
    XCTAssertFalse(snapshot.events.contains { $0.observation.key.wireSequence == 0 })

    let latest = try XCTUnwrap(
      snapshot.events.first { $0.observation.key.wireSequence == 513 }
    ).observation
    window.laterDisposition(key: latest.key, disposition: .consumerAccepted)
    window.dropsChanged(
      connectionID: connectionID,
      samples: [ViewerDropJournalSample(reason: .localOverflow, count: 7)]
    )
    window.sessionEnded(
      connectionID: connectionID,
      wallMilliseconds: 2_001_000,
      monotonicNanoseconds: 999
    )
    window.applyStoreOutcome(
      .unavailable,
      key: latest.key,
      observationID: latest.observationID
    )
    window.waitForProjectionForTesting()

    snapshot = window.snapshot()
    let unavailable = try XCTUnwrap(
      snapshot.events.first { $0.observation.observationID == latest.observationID }
    )
    XCTAssertEqual(unavailable.laterDisposition, .consumerAccepted)
    XCTAssertEqual(unavailable.durableState, .notRecorded)
    XCTAssertTrue(unavailable.hasDrop)
    XCTAssertTrue(unavailable.sessionEnded)
    XCTAssertTrue(snapshot.gaps.storeUnavailable)
    XCTAssertEqual(snapshot.gaps.storeUnavailableCount, 1)
    XCTAssertEqual(snapshot.sessions.first?.positiveDropCount, 7)

    window.applyStoreOutcome(
      .accepted,
      key: latest.key,
      observationID: latest.observationID
    )
    window.waitForProjectionForTesting()
    snapshot = window.snapshot()
    XCTAssertFalse(snapshot.gaps.storeUnavailable)
    XCTAssertEqual(snapshot.gaps.storeRecoveryCount, 1)
    XCTAssertEqual(
      snapshot.events.first { $0.observation.observationID == latest.observationID }?.durableState,
      .acceptedAwaitingVisibility
    )

    window.storeStateChanged(.writeFailed)
    window.waitForProjectionForTesting()
    XCTAssertTrue(window.snapshot().gaps.storeUnavailable)
    XCTAssertEqual(window.snapshot().gaps.storeUnavailableCount, 2)
    window.storeStateChanged(.available)
    window.waitForProjectionForTesting()
    XCTAssertFalse(window.snapshot().gaps.storeUnavailable)
    XCTAssertEqual(window.snapshot().gaps.storeRecoveryCount, 2)

    window.durableRowBecameVisible(key: latest.key, observationID: latest.observationID)
    window.waitForProjectionForTesting()
    XCTAssertFalse(
      window.snapshot().events.contains { $0.observation.observationID == latest.observationID }
    )

    await window.runtimeEnded()
    XCTAssertTrue(window.isCleared)
    XCTAssertTrue(window.snapshot().events.isEmpty)
    XCTAssertTrue(window.snapshot().sessions.isEmpty)
  }

  func testPerformanceFreezeDrainsIngressAndReportsBoundedApplicableLoss() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Performance freeze"
    )
    let epoch = SessionEpoch()
    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.performance-freeze"
    )
    let projectionGate = DispatchSemaphore(value: 0)
    projectionQueue.async { projectionGate.wait() }
    let anchor: UInt64 = 10_000
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      liveGeneration: 23,
      projectionQueue: projectionQueue,
      refreshScheduler: ViewerLiveRefreshScheduler(
        now: { anchor },
        scheduleOnMain: { _, _ in }
      )
    )

    for sequence in 0..<UInt64(193) {
      let envelope = try makeObservationEnvelope(
        eventType: PerformanceSnapshotSchema.eventType(),
        content: .object(["sequence": .integer(Int64(sequence))]),
        createdAt: Date(timeIntervalSince1970: 12),
        monotonicTimestampNanoseconds: sequence,
        sessionEpoch: epoch,
        sequence: sequence
      )
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: envelope,
        viewerWallMilliseconds: 12_000,
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 64,
        initialDisposition: .buffered
      )
      let outcome = window.offer(observation)
      XCTAssertEqual(
        outcome,
        sequence < UInt64(ViewerLiveProjectionLimits.ingressCount) ? .accepted : .untracked
      )
    }
    projectionGate.signal()

    let first = try window.freezePerformance(connectionID: connectionID)
    XCTAssertEqual(first.runtimeLogicalID, runtimeLogicalID)
    XCTAssertEqual(first.connectionID, connectionID)
    XCTAssertEqual(first.liveGeneration, 23)
    XCTAssertEqual(first.revision, 1)
    XCTAssertEqual(first.anchorMonotonicNanoseconds, anchor)
    XCTAssertEqual(first.events.count, ViewerLiveProjectionLimits.ingressCount)
    XCTAssertEqual(first.events.map(\.key.wireSequence), Array(0..<UInt64(64)))
    XCTAssertEqual(first.gaps.count, 1)
    XCTAssertEqual(first.gaps.first?.kind, .eventLoss)
    XCTAssertEqual(first.gaps.first?.applicability, .uncertain)
    XCTAssertEqual(first.gaps.first?.count, 129)
    XCTAssertEqual(first.applicableOrUncertainCount, 129)
    XCTAssertTrue(first.hasMoreApplicableGaps)
    XCTAssertLessThanOrEqual(first.accountedBytes, ViewerPerformanceLimits.maximumLiveSliceBytes)
    let firstCarrier = try XCTUnwrap(first.events.first)
    XCTAssertEqual(
      window.performanceEventLocator(for: firstCarrier.key),
      firstCarrier.locator
    )
    XCTAssertNil(
      window.performanceEventLocator(
        for: ViewerEventJournalKey(
          runtimeLogicalID: runtimeLogicalID,
          connectionID: connectionID,
          direction: .viewerToApp,
          wireSequence: firstCarrier.key.wireSequence
        )
      )
    )

    let second = try window.freezePerformance(connectionID: connectionID)
    XCTAssertEqual(second.revision, 2)
    XCTAssertEqual(second.anchorMonotonicNanoseconds, anchor)
    XCTAssertThrowsError(try window.freezePerformance(connectionID: UUID())) { error in
      XCTAssertEqual(error as? ViewerPerformanceStoreFailure, .invalidScope)
    }
    guard case .transient(let observationID) = firstCarrier.locator else {
      return XCTFail("Expected one transient live locator")
    }
    window.durableRowBecameVisible(key: firstCarrier.key, observationID: observationID)
    window.waitForProjectionForTesting()
    XCTAssertNil(window.performanceEventLocator(for: firstCarrier.key))
  }

  func testPerformanceFreezeClassifiesOversizedContentWithoutCopyingIt() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Oversized performance freeze"
    )
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      refreshScheduler: ViewerLiveRefreshScheduler(
        now: { 1_000 },
        scheduleOnMain: { _, _ in }
      )
    )
    let envelope = try makeObservationEnvelope(
      eventType: PerformanceSnapshotSchema.eventType(),
      content: .null,
      createdAt: Date(timeIntervalSince1970: 1),
      monotonicTimestampNanoseconds: 500,
      sessionEpoch: SessionEpoch(),
      sequence: 1
    )
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: envelope,
      viewerWallMilliseconds: 1_000,
      viewerMonotonicNanoseconds: 500,
      deterministicEventBytes: 70_000,
      canonicalContent: Data(repeating: 0x78, count: 70_000),
      initialDisposition: .buffered
    )
    XCTAssertEqual(window.offer(observation), .accepted)

    let slice = try window.freezePerformance(connectionID: connectionID)
    XCTAssertEqual(slice.events.count, 1)
    XCTAssertEqual(slice.copiedContentBytes, 0)
    guard case .oversized(let declaredBytes) = slice.events[0].content else {
      return XCTFail("Expected metadata-only oversized content")
    }
    XCTAssertGreaterThan(declaredBytes, Int64(ViewerPerformanceLimits.maximumRowContentBytes))
  }

  func testHundredThousandLiveOffersUseOneBoundedDrainAndRefreshWake() async throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Hundred thousand offers"
    )
    let epoch = SessionEpoch()
    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.hundred-thousand-live-offers"
    )
    let refreshScheduler = ManualLiveRefreshScheduler()
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue,
      refreshScheduler: refreshScheduler.value
    )

    func observation(sequence: UInt64) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["value": .integer(Int64(sequence))]),
          createdAt: Date(timeIntervalSince1970: 2_500),
          sessionEpoch: epoch,
          sequence: sequence
        ),
        viewerWallMilliseconds: 2_500_000,
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    for sequence in 0..<UInt64(ViewerLiveProjectionLimits.retainedCount) {
      XCTAssertEqual(try window.offer(observation(sequence: sequence)), .accepted)
      window.waitForProjectionForTesting()
    }
    XCTAssertEqual(window.retainedObservationCount, ViewerLiveProjectionLimits.retainedCount)
    XCTAssertEqual(refreshScheduler.pendingCount, 1)
    let baseline = window.diagnosticsForTesting()

    let gate = BlockingViewerOperationGate()
    projectionQueue.async { gate.run() }
    XCTAssertEqual(gate.waitUntilEntered(), .success)

    let repeated = try observation(sequence: UInt64(ViewerLiveProjectionLimits.retainedCount))
    let baselineFootprint = currentFoundationProcessPhysicalFootprintBytes()
    let callbackStart = DispatchTime.now().uptimeNanoseconds
    var acceptedCount = 0
    var deferredCount = 0
    var untrackedCount = 0
    var unexpectedCount = 0
    for _ in 0..<100_000 {
      switch window.offer(repeated) {
      case .accepted: acceptedCount += 1
      case .deferred: deferredCount += 1
      case .untracked: untrackedCount += 1
      case .identical, .presentationConflict, .sealed: unexpectedCount += 1
      }
    }
    let callbackElapsed = DispatchTime.now().uptimeNanoseconds - callbackStart
    let endingFootprint = currentFoundationProcessPhysicalFootprintBytes()

    XCTAssertEqual(acceptedCount, 1)
    XCTAssertEqual(deferredCount, ViewerLiveProjectionLimits.ingressCount - 1)
    XCTAssertEqual(
      untrackedCount,
      100_000 - ViewerLiveProjectionLimits.ingressCount
    )
    XCTAssertEqual(unexpectedCount, 0)

    gate.release()
    window.waitForProjectionForTesting()
    let diagnostics = window.diagnosticsForTesting()
    XCTAssertEqual(diagnostics.ingressOfferCount - baseline.ingressOfferCount, 100_000)
    XCTAssertEqual(diagnostics.drainScheduleCount - baseline.drainScheduleCount, 1)
    XCTAssertEqual(diagnostics.dirtySuccessorCount - baseline.dirtySuccessorCount, 1)
    XCTAssertEqual(diagnostics.drainRunCount - baseline.drainRunCount, 1)
    XCTAssertEqual(diagnostics.maximumConcurrentDrainCount, 1)
    XCTAssertEqual(
      diagnostics.snapshotPublicationCount - baseline.snapshotPublicationCount,
      1
    )
    XCTAssertEqual(diagnostics.refreshScheduleCount, 1)
    XCTAssertEqual(diagnostics.refreshDeliveryCount, 0)
    XCTAssertEqual(refreshScheduler.pendingCount, 1)

    let snapshot = window.snapshot()
    XCTAssertEqual(snapshot.events.count, ViewerLiveProjectionLimits.retainedCount)
    XCTAssertEqual(
      snapshot.gaps.ingressOverflowCount,
      UInt64(100_000 - ViewerLiveProjectionLimits.ingressCount)
    )
    XCTAssertEqual(snapshot.gaps.windowOverflowCount, 1)
    XCTAssertEqual(
      snapshot.accountedEventBytes,
      ViewerLiveProjectionLimits.retainedCount
        * (ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 1)
    )

    refreshScheduler.runNext()
    let delivered = window.diagnosticsForTesting()
    XCTAssertEqual(delivered.refreshScheduleCount, 1)
    XCTAssertEqual(delivered.refreshDeliveryCount, 1)

    let footprintGrowth: UInt64? = {
      guard let baselineFootprint, let endingFootprint else { return nil }
      return endingFootprint >= baselineFootprint ? endingFootprint - baselineFootprint : 0
    }()
    let footprintText = footprintGrowth.map(String.init) ?? "unavailable"
    print(
      "NearWire 100,000 live-offer diagnostics: callback-total-ns=\(callbackElapsed), process-footprint-growth=\(footprintText)"
    )

    await window.runtimeEnded()
    XCTAssertTrue(window.isCleared)
    XCTAssertTrue(window.snapshot().events.isEmpty)
  }

  func testLiveIngressAdmitsOneMaximumEventAndRejectsTheTwentyMiBOverflow() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(connectionID: connectionID, displayName: "Maximum")
    let epoch = SessionEpoch()
    let projectionQueue = DispatchQueue(label: "ViewerFoundationTests.live-projection-byte-bound")
    let projectionGate = DispatchSemaphore(value: 0)
    projectionQueue.async { projectionGate.wait() }
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )
    let maximum = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(1)]),
        createdAt: Date(timeIntervalSince1970: 3_000),
        sessionEpoch: epoch,
        sequence: 1
      ),
      viewerWallMilliseconds: 3_000_000,
      viewerMonotonicNanoseconds: 1,
      deterministicEventBytes: 16 * 1_024 * 1_024,
      initialDisposition: .buffered
    )
    let overflow = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(2)]),
        createdAt: Date(timeIntervalSince1970: 3_000),
        sessionEpoch: epoch,
        sequence: 2
      ),
      viewerWallMilliseconds: 3_000_001,
      viewerMonotonicNanoseconds: 2,
      deterministicEventBytes: 4 * 1_024 * 1_024,
      initialDisposition: .buffered
    )

    XCTAssertEqual(window.offer(maximum), .accepted)
    XCTAssertEqual(window.offer(overflow), .untracked)
    projectionGate.signal()
    window.waitForProjectionForTesting()
    XCTAssertEqual(window.retainedObservationCount, 1)
    XCTAssertEqual(window.snapshot().gaps.ingressOverflowCount, 1)

    let retainedWindow = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    let retainedEventBytes =
      16 * 1_024 * 1_024 - ViewerLiveProjectionLimits.fixedEntryOverheadBytes
    let retainedFirst = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(3)]),
        createdAt: Date(timeIntervalSince1970: 3_000),
        sessionEpoch: epoch,
        sequence: 3
      ),
      viewerWallMilliseconds: 3_000_002,
      viewerMonotonicNanoseconds: 3,
      deterministicEventBytes: retainedEventBytes,
      initialDisposition: .buffered
    )
    let retainedSecond = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(4)]),
        createdAt: Date(timeIntervalSince1970: 3_000),
        sessionEpoch: epoch,
        sequence: 4
      ),
      viewerWallMilliseconds: 3_000_003,
      viewerMonotonicNanoseconds: 4,
      deterministicEventBytes: retainedEventBytes,
      initialDisposition: .buffered
    )
    let retainedOverflow = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(5)]),
        createdAt: Date(timeIntervalSince1970: 3_000),
        sessionEpoch: epoch,
        sequence: 5
      ),
      viewerWallMilliseconds: 3_000_004,
      viewerMonotonicNanoseconds: 5,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )

    XCTAssertEqual(retainedWindow.offer(retainedFirst), .accepted)
    retainedWindow.waitForProjectionForTesting()
    XCTAssertEqual(retainedWindow.offer(retainedSecond), .accepted)
    retainedWindow.waitForProjectionForTesting()
    XCTAssertEqual(retainedWindow.retainedObservationCount, 2)
    XCTAssertEqual(
      retainedWindow.retainedObservationBytes,
      ViewerLiveProjectionLimits.retainedBytes
    )

    XCTAssertEqual(retainedWindow.offer(retainedOverflow), .accepted)
    retainedWindow.waitForProjectionForTesting()
    let retainedSnapshot = retainedWindow.snapshot()
    XCTAssertEqual(retainedWindow.retainedObservationCount, 2)
    XCTAssertEqual(retainedSnapshot.gaps.windowOverflowCount, 1)
    XCTAssertEqual(
      Set(retainedSnapshot.events.map(\.observation.observationID)),
      Set([retainedSecond.observationID, retainedOverflow.observationID])
    )
  }

  func testLiveSessionMetadataStaysBoundedAndFreshActiveSessionSurvivesChurn() throws {
    let runtimeLogicalID = UUID()
    let blockedQueue = DispatchQueue(label: "ViewerFoundationTests.session-churn-blocked")
    let blockedGate = DispatchSemaphore(value: 0)
    blockedQueue.async { blockedGate.wait() }
    let blockedWindow = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: blockedQueue
    )

    for index in 0..<1_000 {
      let connectionID = UUID()
      let context = try makeObservationContext(
        connectionID: connectionID,
        displayName: "Blocked churn \(index)"
      )
      blockedWindow.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: connectionID
      )
      blockedWindow.sessionEnded(
        connectionID: connectionID,
        wallMilliseconds: Int64(index + 1),
        monotonicNanoseconds: UInt64(index + 1)
      )
    }
    XCTAssertEqual(blockedWindow.activeSessionMetadataCountForTesting, 0)
    XCTAssertEqual(
      blockedWindow.pendingSessionTerminationCountForTesting,
      ViewerLiveProjectionLimits.maximumSessions
    )
    blockedGate.signal()
    blockedWindow.waitForProjectionForTesting()
    XCTAssertLessThanOrEqual(
      blockedWindow.snapshot().sessions.count,
      ViewerLiveProjectionLimits.maximumSessions
    )
    XCTAssertGreaterThan(blockedWindow.snapshot().gaps.diagnosticLossCount, 0)

    let window = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let connectionID = UUID()
      let context = try makeObservationContext(
        connectionID: connectionID,
        displayName: "Retained churn \(index)"
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: connectionID
      )
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["index": .integer(Int64(index))]),
          createdAt: Date(timeIntervalSince1970: Double(index + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(index + 1),
        viewerMonotonicNanoseconds: UInt64(index + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      XCTAssertEqual(window.offer(observation), .accepted)
      window.waitForProjectionForTesting()
      window.sessionEnded(
        connectionID: connectionID,
        wallMilliseconds: Int64(index + 100),
        monotonicNanoseconds: UInt64(index + 100)
      )
      window.waitForProjectionForTesting()
    }
    XCTAssertEqual(window.snapshot().sessions.count, ViewerLiveProjectionLimits.maximumSessions)

    let freshConnectionID = UUID()
    let freshContext = try makeObservationContext(
      connectionID: freshConnectionID,
      displayName: "Fresh active session"
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: freshContext, nickname: nil),
      connectionID: freshConnectionID
    )
    let freshObservation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: freshContext,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["fresh": .bool(true)]),
        createdAt: Date(timeIntervalSince1970: 100),
        sessionEpoch: SessionEpoch(),
        sequence: 1
      ),
      viewerWallMilliseconds: 100,
      viewerMonotonicNanoseconds: 100,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )
    XCTAssertEqual(window.offer(freshObservation), .accepted)
    window.waitForProjectionForTesting()
    let snapshot = window.snapshot()
    XCTAssertEqual(snapshot.sessions.count, ViewerLiveProjectionLimits.maximumSessions)
    XCTAssertTrue(snapshot.sessions.contains { $0.connectionID == freshConnectionID })
    XCTAssertTrue(
      snapshot.events.contains { $0.observation.key.connectionID == freshConnectionID }
    )
    XCTAssertEqual(snapshot.gaps.windowOverflowCount, 1)
  }

  func testBlockedProjectionRetainsTerminalTransitionsBeforeReplacementSessions() throws {
    let runtimeLogicalID = UUID()
    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.session-generation-transition"
    )
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func observation(
      context: ViewerAdmissionSessionContext,
      index: Int,
      generation: String
    ) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object([
            "generation": .string(generation),
            "index": .integer(Int64(index)),
          ]),
          createdAt: Date(timeIntervalSince1970: Double(index + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(index + 1),
        viewerMonotonicNanoseconds: UInt64(index + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    var initialContexts: [ViewerAdmissionSessionContext] = []
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Initial generation \(index)"
      )
      initialContexts.append(context)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(
        window.offer(try observation(context: context, index: index, generation: "initial")),
        .accepted
      )
    }
    window.waitForProjectionForTesting()
    XCTAssertEqual(window.snapshot().sessions.count, ViewerLiveProjectionLimits.maximumSessions)

    let projectionBlocked = DispatchSemaphore(value: 0)
    let projectionRelease = DispatchSemaphore(value: 0)
    projectionQueue.async {
      projectionBlocked.signal()
      projectionRelease.wait()
    }
    XCTAssertEqual(projectionBlocked.wait(timeout: .now() + 1), .success)

    for (index, context) in initialContexts.enumerated() {
      window.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: Int64(index + 100),
        monotonicNanoseconds: UInt64(index + 100)
      )
    }

    var replacementConnectionIDs = Set<UUID>()
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Replacement generation \(index)"
      )
      replacementConnectionIDs.insert(context.connectionID)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(
        window.offer(try observation(context: context, index: index, generation: "replacement")),
        .accepted
      )
    }
    XCTAssertEqual(
      window.activeSessionMetadataCountForTesting,
      ViewerLiveProjectionLimits.maximumSessions
    )
    XCTAssertEqual(
      window.pendingSessionTerminationCountForTesting,
      ViewerLiveProjectionLimits.maximumSessions
    )

    projectionRelease.signal()
    window.waitForProjectionForTesting()
    let snapshot = window.snapshot()
    XCTAssertEqual(snapshot.sessions.count, ViewerLiveProjectionLimits.maximumSessions)
    XCTAssertEqual(Set(snapshot.sessions.map(\.connectionID)), replacementConnectionIDs)
    XCTAssertEqual(snapshot.events.count, ViewerLiveProjectionLimits.maximumSessions)
    XCTAssertEqual(
      Set(snapshot.events.map(\.observation.key.connectionID)),
      replacementConnectionIDs
    )
    XCTAssertEqual(
      snapshot.gaps.windowOverflowCount,
      UInt64(ViewerLiveProjectionLimits.maximumSessions)
    )
  }

  func testBlockedProjectionReconcilesEndedReplacementBeforeFreshGeneration() throws {
    let runtimeLogicalID = UUID()
    let projectionQueue = DispatchQueue(
      label: "ViewerFoundationTests.three-session-generations"
    )
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func makeEvent(
      _ context: ViewerAdmissionSessionContext,
      generation: String,
      index: Int
    ) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["generation": .string(generation)]),
          createdAt: Date(timeIntervalSince1970: Double(index + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(index + 1),
        viewerMonotonicNanoseconds: UInt64(index + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    var initialContexts: [ViewerAdmissionSessionContext] = []
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Initial three-generation \(index)"
      )
      initialContexts.append(context)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(try makeEvent(context, generation: "A", index: index)), .accepted)
    }
    window.waitForProjectionForTesting()

    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    projectionQueue.async {
      blocked.signal()
      release.wait()
    }
    XCTAssertEqual(blocked.wait(timeout: .now() + 1), .success)

    for (index, context) in initialContexts.enumerated() {
      window.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: Int64(index + 100),
        monotonicNanoseconds: UInt64(index + 100)
      )
    }
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Ended replacement \(index)"
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(try makeEvent(context, generation: "B", index: index)), .accepted)
      window.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: Int64(index + 200),
        monotonicNanoseconds: UInt64(index + 200)
      )
    }

    var freshConnectionIDs = Set<UUID>()
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Fresh generation \(index)"
      )
      freshConnectionIDs.insert(context.connectionID)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(try makeEvent(context, generation: "C", index: index)), .accepted)
    }
    XCTAssertEqual(
      window.activeSessionMetadataCountForTesting,
      ViewerLiveProjectionLimits.maximumSessions
    )
    XCTAssertEqual(
      window.pendingSessionTerminationCountForTesting,
      ViewerLiveProjectionLimits.maximumSessions
    )

    release.signal()
    window.waitForProjectionForTesting()
    let snapshot = window.snapshot()
    XCTAssertEqual(Set(snapshot.sessions.map(\.connectionID)), freshConnectionIDs)
    XCTAssertEqual(Set(snapshot.events.map(\.observation.key.connectionID)), freshConnectionIDs)
    XCTAssertTrue(snapshot.sessions.allSatisfy { $0.endedMonotonicNanoseconds == nil })
    XCTAssertEqual(
      snapshot.gaps.windowOverflowCount,
      UInt64(ViewerLiveProjectionLimits.maximumSessions * 2)
    )
    XCTAssertGreaterThanOrEqual(
      snapshot.gaps.diagnosticLossCount,
      UInt64(ViewerLiveProjectionLimits.maximumSessions)
    )
  }

  func testBlockedSingleSlotChurnPreservesLatestActiveGeneration() throws {
    let runtimeLogicalID = UUID()
    let projectionQueue = DispatchQueue(label: "ViewerFoundationTests.single-slot-churn")
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func makeEvent(
      _ context: ViewerAdmissionSessionContext,
      generation: Int
    ) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["generation": .integer(Int64(generation))]),
          createdAt: Date(timeIntervalSince1970: Double(generation + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(generation + 1),
        viewerMonotonicNanoseconds: UInt64(generation + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    var initialContexts: [ViewerAdmissionSessionContext] = []
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Single-slot initial \(index)"
      )
      initialContexts.append(context)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(try makeEvent(context, generation: index)), .accepted)
    }
    window.waitForProjectionForTesting()

    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    projectionQueue.async {
      blocked.signal()
      release.wait()
    }
    XCTAssertEqual(blocked.wait(timeout: .now() + 1), .success)

    let displaced = initialContexts[0]
    window.sessionEnded(
      connectionID: displaced.connectionID,
      wallMilliseconds: 100,
      monotonicNanoseconds: 100
    )
    let intermediateCount = ViewerLiveProjectionLimits.maximumSessions + 4
    for generation in 0..<intermediateCount {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Single-slot intermediate \(generation)"
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(try makeEvent(context, generation: 100 + generation)), .accepted)
      window.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: Int64(200 + generation),
        monotonicNanoseconds: UInt64(200 + generation)
      )
    }

    let latest = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Single-slot latest"
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: latest, nickname: nil),
      connectionID: latest.connectionID
    )
    XCTAssertEqual(window.offer(try makeEvent(latest, generation: 1_000)), .accepted)

    release.signal()
    window.waitForProjectionForTesting()
    let snapshot = window.snapshot()
    let expectedSessionIDs = Set(initialContexts.dropFirst().map(\.connectionID)).union([
      latest.connectionID
    ])
    XCTAssertEqual(Set(snapshot.sessions.map(\.connectionID)), expectedSessionIDs)
    XCTAssertEqual(Set(snapshot.events.map(\.observation.key.connectionID)), expectedSessionIDs)
    XCTAssertTrue(
      snapshot.sessions.contains { session in
        session.connectionID == latest.connectionID
          && session.metadata.displayName == "Single-slot latest"
          && session.endedMonotonicNanoseconds == nil
      })
    XCTAssertEqual(
      snapshot.gaps.windowOverflowCount,
      UInt64(intermediateCount + 1)
    )
  }

  func testDirectObservationModeSurvivesDispositionAndReconcilesAtLifecycleTransition() throws {
    let runtimeLogicalID = UUID()
    let window = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)

    func makeEvent(
      _ context: ViewerAdmissionSessionContext,
      index: Int
    ) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["index": .integer(Int64(index))]),
          createdAt: Date(timeIntervalSince1970: Double(index + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(index + 1),
        viewerMonotonicNanoseconds: UInt64(index + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    var directObservations: [ViewerCommittedEventObservation] = []
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Direct observation \(index)"
      )
      let observation = try makeEvent(context, index: index)
      directObservations.append(observation)
      XCTAssertEqual(window.offer(observation), .accepted)
      window.waitForProjectionForTesting()
      if index == 0 {
        window.laterDisposition(key: observation.key, disposition: .transportAdmitted)
        window.waitForProjectionForTesting()
      }
    }
    XCTAssertEqual(window.snapshot().sessions.count, ViewerLiveProjectionLimits.maximumSessions)
    XCTAssertEqual(window.snapshot().events.count, ViewerLiveProjectionLimits.maximumSessions)
    XCTAssertEqual(window.snapshot().events.first?.laterDisposition, .transportAdmitted)

    let managedContext = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Managed lifecycle"
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: managedContext, nickname: nil),
      connectionID: managedContext.connectionID
    )
    let managedObservation = try makeEvent(managedContext, index: 1_000)
    XCTAssertEqual(window.offer(managedObservation), .accepted)
    window.waitForProjectionForTesting()

    let snapshot = window.snapshot()
    XCTAssertEqual(snapshot.sessions.map(\.connectionID), [managedContext.connectionID])
    XCTAssertEqual(
      snapshot.events.map(\.observation.observationID),
      [managedObservation.observationID]
    )
    XCTAssertEqual(
      snapshot.gaps.windowOverflowCount,
      UInt64(ViewerLiveProjectionLimits.maximumSessions)
    )
    XCTAssertTrue(
      directObservations.allSatisfy { direct in
        !snapshot.events.contains { $0.observation.observationID == direct.observationID }
      }
    )
  }

  func testLifecycleTransitionClearsDetachedDirectConflictMarker() throws {
    let runtimeLogicalID = UUID()
    let window = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    let directContext = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Conflicted direct observation"
    )
    let directObservation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: directContext,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .string("direct")]),
        createdAt: Date(timeIntervalSince1970: 1),
        sessionEpoch: SessionEpoch(),
        sequence: 1
      ),
      viewerWallMilliseconds: 1,
      viewerMonotonicNanoseconds: 1,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )
    XCTAssertEqual(window.offer(directObservation), .accepted)
    window.waitForProjectionForTesting()
    window.applyStoreOutcome(
      .journalConflict,
      key: directObservation.key,
      observationID: directObservation.observationID
    )
    window.waitForProjectionForTesting()
    XCTAssertTrue(window.snapshot().events.isEmpty)
    XCTAssertEqual(window.snapshot().gaps.residentConflictCount, 1)

    let managedContext = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Managed lifecycle"
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: managedContext, nickname: nil),
      connectionID: managedContext.connectionID
    )
    window.waitForProjectionForTesting()

    let snapshot = window.snapshot()
    XCTAssertEqual(snapshot.sessions.map(\.connectionID), [managedContext.connectionID])
    XCTAssertTrue(snapshot.events.isEmpty)
    XCTAssertEqual(snapshot.gaps.residentConflictCount, 0)
    XCTAssertEqual(snapshot.gaps.windowOverflowCount, 0)
    XCTAssertEqual(snapshot.gaps.diagnosticLossCount, 1)
  }

  func testManagedSessionReclamationRemovesDetachedConflictMarker() throws {
    let runtimeLogicalID = UUID()
    let window = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    let context = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Managed conflict reclamation"
    )
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .string("managed")]),
        createdAt: Date(timeIntervalSince1970: 1),
        sessionEpoch: SessionEpoch(),
        sequence: 1
      ),
      viewerWallMilliseconds: 1,
      viewerMonotonicNanoseconds: 1,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: context, nickname: nil),
      connectionID: context.connectionID
    )
    XCTAssertEqual(window.offer(observation), .accepted)
    window.waitForProjectionForTesting()
    window.applyStoreOutcome(
      .journalConflict,
      key: observation.key,
      observationID: observation.observationID
    )
    window.waitForProjectionForTesting()
    XCTAssertEqual(window.snapshot().gaps.residentConflictCount, 1)

    window.sessionEnded(
      connectionID: context.connectionID,
      wallMilliseconds: 2,
      monotonicNanoseconds: 2
    )
    window.waitForProjectionForTesting()

    let snapshot = window.snapshot()
    XCTAssertTrue(snapshot.sessions.isEmpty)
    XCTAssertTrue(snapshot.events.isEmpty)
    XCTAssertEqual(snapshot.gaps.residentConflictCount, 0)
    XCTAssertEqual(snapshot.gaps.windowOverflowCount, 0)
    XCTAssertEqual(snapshot.gaps.diagnosticLossCount, 1)
  }

  func testManagedSessionCapacityEvictionRemovesDetachedConflictMarker() throws {
    let runtimeLogicalID = UUID()
    let window = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    let epoch = SessionEpoch()
    var contexts: [ViewerAdmissionSessionContext] = []
    for index in 0..<ViewerLiveProjectionLimits.maximumSessions {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Managed capacity \(index)"
      )
      contexts.append(context)
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
    }
    let target = contexts[0]
    func makeTargetEvent(sequence: UInt64) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: target,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["sequence": .integer(Int64(sequence))]),
          createdAt: Date(timeIntervalSince1970: Double(sequence)),
          sessionEpoch: epoch,
          sequence: sequence
        ),
        viewerWallMilliseconds: Int64(sequence),
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }
    let conflicted = try makeTargetEvent(sequence: 1)
    let retained = try makeTargetEvent(sequence: 2)
    XCTAssertEqual(window.offer(conflicted), .accepted)
    XCTAssertEqual(window.offer(retained), .accepted)
    window.waitForProjectionForTesting()
    window.applyStoreOutcome(
      .journalConflict,
      key: conflicted.key,
      observationID: conflicted.observationID
    )
    window.sessionEnded(
      connectionID: target.connectionID,
      wallMilliseconds: 3,
      monotonicNanoseconds: 3
    )
    window.waitForProjectionForTesting()
    XCTAssertEqual(window.snapshot().gaps.residentConflictCount, 1)

    let replacement = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Managed capacity replacement"
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: replacement, nickname: nil),
      connectionID: replacement.connectionID
    )
    window.waitForProjectionForTesting()

    let snapshot = window.snapshot()
    XCTAssertFalse(snapshot.sessions.contains { $0.connectionID == target.connectionID })
    XCTAssertTrue(snapshot.sessions.contains { $0.connectionID == replacement.connectionID })
    XCTAssertFalse(
      snapshot.events.contains { $0.observation.observationID == retained.observationID }
    )
    XCTAssertEqual(snapshot.gaps.residentConflictCount, 0)
    XCTAssertEqual(snapshot.gaps.windowOverflowCount, 1)
    XCTAssertEqual(snapshot.gaps.diagnosticLossCount, 1)
  }

  func testShortLifecycleManagedSessionRetainsEventBeforeFirstAndEstablishedDrain() throws {
    func exercise(establishedLifecycle: Bool) throws {
      let runtimeLogicalID = UUID()
      let projectionQueue = DispatchQueue(
        label: "ViewerFoundationTests.short-session.\(establishedLifecycle)"
      )
      let window = ViewerLiveEventWindow(
        runtimeLogicalID: runtimeLogicalID,
        projectionQueue: projectionQueue
      )
      if establishedLifecycle {
        let establishedContext = try makeObservationContext(
          connectionID: UUID(),
          displayName: "Established lifecycle"
        )
        window.sessionStarted(
          try ViewerFrozenSessionMetadata(context: establishedContext, nickname: nil),
          connectionID: establishedContext.connectionID
        )
        window.waitForProjectionForTesting()
      }

      let projectionEntered = DispatchSemaphore(value: 0)
      let projectionRelease = DispatchSemaphore(value: 0)
      projectionQueue.async {
        projectionEntered.signal()
        projectionRelease.wait()
      }
      XCTAssertEqual(projectionEntered.wait(timeout: .now() + 1), .success)

      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Short lifecycle"
      )
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["value": .string("short")]),
          createdAt: Date(timeIntervalSince1970: 2),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: 2,
        viewerMonotonicNanoseconds: 2,
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
      XCTAssertEqual(window.offer(observation), .accepted)
      window.laterDisposition(key: observation.key, disposition: .transportAdmitted)
      window.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: 3,
        monotonicNanoseconds: 3
      )
      projectionRelease.signal()
      window.waitForProjectionForTesting()

      let snapshot = window.snapshot()
      let retained = try XCTUnwrap(
        snapshot.events.first { $0.observation.observationID == observation.observationID }
      )
      XCTAssertEqual(retained.laterDisposition, .transportAdmitted)
      XCTAssertTrue(retained.sessionEnded)
      XCTAssertTrue(
        snapshot.sessions.contains {
          $0.connectionID == context.connectionID && $0.endedMonotonicNanoseconds == 3
        }
      )
      XCTAssertEqual(snapshot.gaps.windowOverflowCount, 0)
      XCTAssertEqual(snapshot.gaps.diagnosticLossCount, 0)
    }

    try exercise(establishedLifecycle: false)
    try exercise(establishedLifecycle: true)
  }

  func testDuplicateSessionChurnReleasesOwnerlessAuthorityAcrossCapacityHorizon() throws {
    let runtimeLogicalID = UUID()
    let projectionQueue = DispatchQueue(label: "ViewerFoundationTests.authority-churn")
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      projectionQueue: projectionQueue
    )

    func makeEvent(
      context: ViewerAdmissionSessionContext,
      generation: Int
    ) throws -> ViewerCommittedEventObservation {
      try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["generation": .integer(Int64(generation))]),
          createdAt: Date(timeIntervalSince1970: Double(generation + 1)),
          sessionEpoch: SessionEpoch(),
          sequence: 1
        ),
        viewerWallMilliseconds: Int64(generation + 1),
        viewerMonotonicNanoseconds: UInt64(generation + 1),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
    }

    for index in 0..<(ViewerLiveProjectionLimits.maximumSessions - 1) {
      let context = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Authority anchor \(index)"
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: context, nickname: nil),
        connectionID: context.connectionID
      )
    }
    var currentContext = try makeObservationContext(
      connectionID: UUID(),
      displayName: "Authority generation 0"
    )
    window.sessionStarted(
      try ViewerFrozenSessionMetadata(context: currentContext, nickname: nil),
      connectionID: currentContext.connectionID
    )
    var currentEvent = try makeEvent(context: currentContext, generation: 0)
    XCTAssertEqual(window.offer(currentEvent), .accepted)
    window.waitForProjectionForTesting()

    let churnCount =
      ViewerLiveProjectionLimits.retainedCount
      + ViewerLiveProjectionLimits.ingressCount + 24
    for generation in 1...churnCount {
      let projectionEntered = DispatchSemaphore(value: 0)
      let projectionRelease = DispatchSemaphore(value: 0)
      projectionQueue.async {
        projectionEntered.signal()
        projectionRelease.wait()
      }
      XCTAssertEqual(projectionEntered.wait(timeout: .now() + 1), .success)
      let duplicate = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: currentContext,
        nickname: nil,
        envelope: currentEvent.envelope,
        viewerWallMilliseconds: Int64(generation + 10_000),
        viewerMonotonicNanoseconds: UInt64(generation + 10_000),
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      XCTAssertEqual(window.offer(duplicate), .deferred)
      window.sessionEnded(
        connectionID: currentContext.connectionID,
        wallMilliseconds: Int64(generation + 20_000),
        monotonicNanoseconds: UInt64(generation + 20_000)
      )

      let nextContext = try makeObservationContext(
        connectionID: UUID(),
        displayName: "Authority generation \(generation)"
      )
      window.sessionStarted(
        try ViewerFrozenSessionMetadata(context: nextContext, nickname: nil),
        connectionID: nextContext.connectionID
      )
      let nextEvent = try makeEvent(context: nextContext, generation: generation)
      XCTAssertEqual(window.offer(nextEvent), .accepted)
      projectionRelease.signal()
      window.waitForProjectionForTesting()
      XCTAssertEqual(window.ownerlessAuthorityCountForTesting, 0)
      XCTAssertEqual(window.authorityCountForTesting, window.retainedObservationCount)
      currentContext = nextContext
      currentEvent = nextEvent
    }

    XCTAssertEqual(window.retainedObservationCount, 1)
    XCTAssertEqual(window.authorityCountForTesting, 1)
    XCTAssertEqual(window.ownerlessAuthorityCountForTesting, 0)
    XCTAssertEqual(
      window.snapshot().events.first?.observation.observationID,
      currentEvent.observationID
    )
    XCTAssertEqual(window.snapshot().gaps.windowOverflowCount, UInt64(churnCount * 2))
  }

  @MainActor
  func testLiveRefreshIsLatestOnlyTenHertzAndPausedPresentationSchedulesNothing() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(connectionID: connectionID, displayName: "Refresh")
    let epoch = SessionEpoch()
    let scheduler = ManualLiveRefreshScheduler()
    let window = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      refreshScheduler: scheduler.value
    )
    let generations = LockedUInt64Collection()
    window.setRefreshHandler { generations.append($0) }

    func offer(_ sequence: UInt64) throws {
      let value = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          content: .object(["value": .integer(Int64(sequence))]),
          createdAt: Date(timeIntervalSince1970: 4_000),
          sessionEpoch: epoch,
          sequence: sequence
        ),
        viewerWallMilliseconds: 4_000_000,
        viewerMonotonicNanoseconds: sequence,
        deterministicEventBytes: 1,
        initialDisposition: .buffered
      )
      XCTAssertEqual(window.offer(value), .accepted)
      window.waitForProjectionForTesting()
    }

    try offer(1)
    try offer(2)
    XCTAssertEqual(scheduler.pendingCount, 1)
    scheduler.runNext()
    XCTAssertEqual(generations.values.count, 1)
    XCTAssertEqual(generations.values.last, window.snapshot().generation)

    try offer(3)
    XCTAssertEqual(scheduler.pendingCount, 1)
    XCTAssertEqual(
      scheduler.nextDelay,
      ViewerLiveProjectionLimits.refreshIntervalNanoseconds
    )
    window.setPresentationPaused(true)
    scheduler.runNext()
    XCTAssertEqual(generations.values.count, 1)
    try offer(4)
    XCTAssertEqual(scheduler.pendingCount, 0)

    window.setPresentationPaused(false)
    XCTAssertEqual(scheduler.pendingCount, 1)
    scheduler.runNext()
    XCTAssertEqual(generations.values.count, 2)
    XCTAssertEqual(generations.values.last, window.snapshot().generation)
    XCTAssertEqual(Array(Mirror(reflecting: window.snapshot()).children).count, 2)
    XCTAssertEqual(Array(Mirror(reflecting: window.snapshot().events[0]).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: window.snapshot().sessions[0]).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: window.snapshot().gaps).children).count, 0)
  }

  func testLiveEvaluatorMatchesMetadataJSONPresenceAndExcludesTransientFullText() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(connectionID: connectionID, displayName: "Evaluator")
    let epoch = SessionEpoch()
    let first = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: "Primary",
      envelope: makeObservationEnvelope(
        content: .object([
          "items": .array([.object(["value": .integer(42)])]),
          "message": .string("alpha value"),
          "nullable": .null,
          "ratio": .number(1.5),
          "enabled": .bool(true),
        ]),
        createdAt: Date(timeIntervalSince1970: 5_000),
        sessionEpoch: epoch,
        sequence: 1
      ),
      viewerWallMilliseconds: 5_000_000,
      viewerMonotonicNanoseconds: 10,
      deterministicEventBytes: 100,
      initialDisposition: .buffered
    )
    let second = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: "Primary",
      envelope: makeObservationEnvelope(
        content: .object([
          "items": .array([.object(["value": .integer(7)])]),
          "message": .string("beta value"),
          "nullable": .string("present"),
        ]),
        createdAt: Date(timeIntervalSince1970: 5_001),
        sessionEpoch: epoch,
        sequence: 2
      ),
      viewerWallMilliseconds: 5_001_000,
      viewerMonotonicNanoseconds: 20,
      deterministicEventBytes: 100,
      initialDisposition: .buffered
    )
    let snapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 9,
      events: [
        ViewerLiveEventSnapshot(
          observation: first,
          laterDisposition: .expired,
          durableState: .notRecorded,
          hasPresentationConflict: true,
          hasGap: true,
          hasDrop: true,
          sessionEnded: false
        ),
        ViewerLiveEventSnapshot(
          observation: second,
          laterDisposition: nil,
          durableState: .notRecorded,
          hasPresentationConflict: false,
          hasGap: false,
          hasDrop: false,
          sessionEnded: false
        ),
      ],
      sessions: [
        ViewerLiveSessionSnapshot(
          connectionID: connectionID,
          metadata: first.session,
          positiveDropCount: 1,
          endedWallMilliseconds: nil,
          endedMonotonicNanoseconds: nil
        )
      ],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 0,
        residentConflictCount: 1,
        diagnosticLossCount: 0,
        storeUnavailableCount: 1,
        storeRecoveryCount: 0,
        storeUnavailable: true
      ),
      accountedEventBytes: 2 * (ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 100)
    )
    let request = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      deviceScope: ViewerLiveDeviceScope(selectedConnectionIDs: [connectionID]),
      predicates: [
        .eventTypeEqualsAny(["test.other", "test.observation"]),
        .eventTypePrefix("test."),
        .contentContains("alpha"),
        .applicationIdentifiers(["com.nearwire.observation"]),
        .applicationVersions(["1.0"]),
        .directions(["appToViewer"]),
        .priorities(["normal", "high"]),
        .wallTime(from: 5_000_000, through: 5_000_000),
        .jsonExists(path: "$.items[0].value"),
        .jsonAny(path: "$.items[0].value", equalsAny: [.integer(7), .integer(42)]),
        .jsonStringContains(path: "$.message", value: "alpha"),
        .json(path: "$.nullable", equals: .null),
        .json(path: "$.ratio", equals: .real(1.5)),
        .json(path: "$.enabled", equals: .boolean(true)),
        .hasGap,
        .hasDrop,
        .hasTerminalDisposition,
      ]
    )
    let evaluator = ViewerLiveEventEvaluator(nowNanoseconds: { 0 })

    guard case .complete(let output) = evaluator.evaluate(snapshot: snapshot, request: request)
    else { return XCTFail("Expected a complete bounded live evaluation") }
    XCTAssertEqual(output.snapshotGeneration, 9)
    XCTAssertEqual(output.matchedKeys, [first.key])
    XCTAssertNil(output.transientExclusion)
    XCTAssertGreaterThan(output.predicateCheckCount, 0)
    XCTAssertGreaterThan(output.jsonNodeVisitCount, 0)

    for (from, through, expected) in [
      (5_000_000, 5_000_000, [first.key]),
      (5_000_001, 5_000_999, []),
      (5_001_000, 5_001_000, [second.key]),
    ] {
      let boundaryRequest = try ViewerLiveEvaluationRequest(
        runtimeLogicalID: runtimeLogicalID,
        predicates: [.wallTime(from: Int64(from), through: Int64(through))]
      )
      guard
        case .complete(let boundaryOutput) = evaluator.evaluate(
          snapshot: snapshot,
          request: boundaryRequest
        )
      else { return XCTFail("Expected exact receive-time boundary evaluation") }
      XCTAssertEqual(boundaryOutput.matchedKeys, expected)
    }

    let durableOnlyDeviceRequest = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      predicates: [.deviceSessionIDs([1])]
    )
    guard
      case .complete(let durableOnlyDeviceOutput) = evaluator.evaluate(
        snapshot: snapshot,
        request: durableOnlyDeviceRequest
      )
    else { return XCTFail("Expected missing durable-only metadata to be a complete non-match") }
    XCTAssertTrue(durableOnlyDeviceOutput.matchedKeys.isEmpty)

    let wrongDeviceRequest = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      deviceScope: ViewerLiveDeviceScope(selectedConnectionIDs: [UUID()]),
      predicates: []
    )
    guard
      case .complete(let wrongDeviceOutput) = evaluator.evaluate(
        snapshot: snapshot,
        request: wrongDeviceRequest
      )
    else { return XCTFail("Expected an exact-device non-match") }
    XCTAssertTrue(wrongDeviceOutput.matchedKeys.isEmpty)

    let fullTextRequest = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      predicates: [.fullText("alpha")]
    )
    guard
      case .complete(let fullTextOutput) = evaluator.evaluate(
        snapshot: snapshot,
        request: fullTextRequest
      )
    else { return XCTFail("Expected explicit transient FTS exclusion") }
    XCTAssertTrue(fullTextOutput.matchedKeys.isEmpty)
    XCTAssertEqual(fullTextOutput.transientExclusion, .fullTextRequiresRecordedData)
    XCTAssertEqual(
      fullTextOutput.transientExclusion?.guidance,
      "Full-text search requires recorded data — transient rows excluded."
    )
    XCTAssertEqual(Array(Mirror(reflecting: request).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: request.deviceScope).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: evaluator).children).count, 0)
    XCTAssertEqual(Array(Mirror(reflecting: output).children).count, 1)
  }

  func testLiveEvaluatorReturnsNoPartialCompletionOnCancellationDeadlineOrShapeOverflow()
    throws
  {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(connectionID: connectionID, displayName: "Budget")
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(1)]),
        createdAt: Date(timeIntervalSince1970: 6_000),
        sessionEpoch: SessionEpoch(),
        sequence: 1
      ),
      viewerWallMilliseconds: 6_000_000,
      viewerMonotonicNanoseconds: 1,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )
    let event = ViewerLiveEventSnapshot(
      observation: observation,
      laterDisposition: nil,
      durableState: .notRecorded,
      hasPresentationConflict: false,
      hasGap: false,
      hasDrop: false,
      sessionEnded: false
    )
    let snapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 1,
      events: [event],
      sessions: [],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 0,
        residentConflictCount: 0,
        diagnosticLossCount: 0,
        storeUnavailableCount: 0,
        storeRecoveryCount: 0,
        storeUnavailable: false
      ),
      accountedEventBytes: ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 1
    )
    let request = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      predicates: [.jsonExists(path: "$.value")]
    )

    XCTAssertEqual(
      ViewerLiveEventEvaluator(nowNanoseconds: { 0 }).evaluate(
        snapshot: snapshot,
        request: request,
        isCancelled: { true }
      ),
      .cancelled
    )
    let deadlineClock = SteppingNanosecondClock(
      values: [0, ViewerLiveEventEvaluator.deadlineNanoseconds]
    )
    XCTAssertEqual(
      ViewerLiveEventEvaluator(nowNanoseconds: { deadlineClock.now() }).evaluate(
        snapshot: snapshot,
        request: request
      ),
      .refineRequired
    )
    let oversized = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 2,
      events: Array(repeating: event, count: ViewerLiveProjectionLimits.retainedCount + 1),
      sessions: [],
      gaps: snapshot.gaps,
      accountedEventBytes: snapshot.accountedEventBytes
    )
    XCTAssertEqual(
      ViewerLiveEventEvaluator(nowNanoseconds: { 0 }).evaluate(
        snapshot: oversized,
        request: request
      ),
      .refineRequired
    )

    var nested: JSONValue = .integer(1)
    for _ in 0..<16 { nested = .object(["a": nested]) }
    let deepObservation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: nested,
        createdAt: Date(timeIntervalSince1970: 6_001),
        sessionEpoch: SessionEpoch(),
        sequence: 2
      ),
      viewerWallMilliseconds: 6_001_000,
      viewerMonotonicNanoseconds: 2,
      deterministicEventBytes: 1,
      initialDisposition: .buffered
    )
    let deepEvent = ViewerLiveEventSnapshot(
      observation: deepObservation,
      laterDisposition: nil,
      durableState: .notRecorded,
      hasPresentationConflict: false,
      hasGap: false,
      hasDrop: false,
      sessionEnded: false
    )
    let maximumSnapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 3,
      events: Array(repeating: deepEvent, count: ViewerLiveProjectionLimits.retainedCount),
      sessions: [],
      gaps: snapshot.gaps,
      accountedEventBytes: ViewerLiveProjectionLimits.retainedCount
        * (ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 1)
    )
    let maximumPath = "$" + Array(repeating: ".a", count: 16).joined()
    let maximumRequest = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      predicates: Array(repeating: .jsonExists(path: maximumPath), count: 32)
    )
    guard
      case .complete(let maximumOutput) = ViewerLiveEventEvaluator(
        nowNanoseconds: { 0 }
      ).evaluate(snapshot: maximumSnapshot, request: maximumRequest)
    else { return XCTFail("Expected the exact maximum predicate shape to complete") }
    XCTAssertEqual(maximumOutput.matchedKeys.count, ViewerLiveProjectionLimits.retainedCount)
    XCTAssertEqual(maximumOutput.predicateCheckCount, 16_384)
    XCTAssertEqual(maximumOutput.jsonNodeVisitCount, 512 * 32 * 16)
    XCTAssertLessThanOrEqual(
      maximumOutput.jsonNodeVisitCount,
      ViewerLiveEventEvaluator.maximumJSONNodeVisits
    )
    XCTAssertEqual(
      ViewerLiveEvaluationResult.refineGuidance,
      "Refine the live filter to evaluate within bounded work."
    )

    XCTAssertThrowsError(
      try ViewerLiveDeviceScope(selectedConnectionIDs: [connectionID, connectionID])
    )
    XCTAssertThrowsError(
      try ViewerLiveEvaluationRequest(
        runtimeLogicalID: runtimeLogicalID,
        predicates: Array(repeating: .hasGap, count: 33)
      )
    )
    XCTAssertThrowsError(
      try ViewerLiveEvaluationRequest(
        runtimeLogicalID: runtimeLogicalID,
        predicates: [.jsonExists(path: "$[999999999999999999999999999]")]
      )
    )
  }

  @MainActor
  func testExplorerModelCapsEveryResidentListAndReloadsOnlyExactSelection() throws {
    func recordingSnapshot() -> ViewerRecordingCatalogSnapshot {
      ViewerRecordingCatalogSnapshot(
        storeGeneration: 1,
        changeGeneration: "recording-snapshot",
        recordingUpperRowID: 1_000,
        recordingVersionUpperRowID: 1_000,
        installationAliasUpperRowID: 1_000,
        deviceSessionUpperRowID: 1_000,
        deviceVersionUpperRowID: 1_000,
        tombstoneUpperRowID: 0,
        gapUpperRowID: 1_000,
        dropUpperRowID: 1_000
      )
    }
    func deviceSnapshot() -> ViewerDeviceCatalogSnapshot {
      ViewerDeviceCatalogSnapshot(
        storeGeneration: 1,
        recordingID: 1,
        changeGeneration: "device-snapshot",
        recordingUpperRowID: 1,
        recordingVersionUpperRowID: 1,
        installationAliasUpperRowID: 1_000,
        deviceSessionUpperRowID: 1_000,
        deviceVersionUpperRowID: 1_000,
        tombstoneUpperRowID: 0,
        gapUpperRowID: 1_000,
        dropUpperRowID: 1_000
      )
    }
    func recordingRow(_ rowID: Int64) -> ViewerRecordingCatalogRow {
      ViewerRecordingCatalogRow(
        rowID: rowID,
        logicalID: UUID(),
        revision: 1,
        name: nil,
        note: nil,
        pinned: false,
        state: "closed",
        startedWallMilliseconds: rowID,
        startedMonotonicNanoseconds: rowID,
        endedWallMilliseconds: rowID,
        endedMonotonicNanoseconds: rowID,
        deviceCount: 1,
        latestDevice: nil,
        hasGap: false,
        hasDrop: false
      )
    }
    func deviceRow(_ ordinal: Int64) -> ViewerDeviceCatalogRow {
      ViewerDeviceCatalogRow(
        rowID: ordinal,
        logicalID: UUID(),
        recordingID: 1,
        installationAlias: "device-\(ordinal)",
        connectionAlias: "connection-\(ordinal)",
        connectionOrdinal: ordinal,
        revision: 1,
        displayName: nil,
        state: "closed",
        partialHistory: false,
        applicationIdentifier: nil,
        applicationVersion: nil,
        startedWallMilliseconds: ordinal,
        startedMonotonicNanoseconds: ordinal,
        endedWallMilliseconds: ordinal,
        endedMonotonicNanoseconds: ordinal,
        hasGap: false,
        hasDrop: false
      )
    }
    func eventRow(_ rowID: Int64) -> ViewerStoredEventRow {
      ViewerStoredEventRow(
        rowID: rowID,
        deviceSessionID: 1,
        direction: "appToViewer",
        wireSequence: rowID - 1,
        eventUUID: "event-\(rowID)",
        eventType: "test.explorer",
        contentByteCount: 1,
        createdWallMilliseconds: rowID,
        viewerWallMilliseconds: rowID,
        viewerMonotonicNanoseconds: rowID,
        priority: "normal",
        recordingRevision: 1,
        deviceRevision: 1,
        resolvedDisposition: "buffered"
      )
    }
    func gapRow(_ rowID: Int64) -> ViewerGapRow {
      ViewerGapRow(
        rowID: rowID,
        recordingID: 1,
        deviceSessionID: nil,
        sequence: rowID,
        namespace: "gap",
        revision: 1,
        reason: "test",
        firstViewerWallMilliseconds: rowID,
        lastViewerWallMilliseconds: rowID,
        directions: "appToViewer",
        firstWireSequence: rowID,
        lastWireSequence: rowID,
        count: 1
      )
    }

    let model = ViewerEventExplorerModel(runtimeLogicalID: UUID())
    let token = model.currentToken
    let recordingBounds = recordingSnapshot()
    let deviceBounds = deviceSnapshot()
    XCTAssertTrue(
      model.applyRecordingPage(
        ViewerRecordingCatalogPage(
          snapshot: recordingBounds,
          rows: (201...400).reversed().map { recordingRow(Int64($0)) },
          olderCursor: ViewerRecordingCatalogCursor(
            queryFingerprint: "recordings",
            snapshot: recordingBounds,
            direction: .older,
            rowID: 201
          ),
          newerCursor: ViewerRecordingCatalogCursor(
            queryFingerprint: "recordings",
            snapshot: recordingBounds,
            direction: .newer,
            rowID: 400
          )
        ),
        placement: .replace,
        token: token
      )
    )
    XCTAssertTrue(
      model.applyRecordingPage(
        ViewerRecordingCatalogPage(
          snapshot: recordingBounds,
          rows: [recordingRow(200)],
          olderCursor: nil,
          newerCursor: nil
        ),
        placement: .trailing,
        token: token
      )
    )
    XCTAssertEqual(model.recordingRows.count, ViewerEventExplorerModel.maximumRecordingRows)
    XCTAssertEqual(model.recordingRows.first?.rowID, 399)
    XCTAssertEqual(model.recordingNavigation.reloadAnchor?.identity, 400)
    let selectedRecording = ViewerExplorerRecordingIdentity.durable(
      rowID: 400,
      logicalID: UUID()
    )
    XCTAssertTrue(model.selectRecording(selectedRecording))
    XCTAssertTrue(model.selectedRecordingNeedsReload)

    XCTAssertTrue(
      model.applyDevicePage(
        ViewerDeviceCatalogPage(
          snapshot: deviceBounds,
          rows: (201...400).reversed().map { deviceRow(Int64($0)) },
          olderCursor: nil,
          newerCursor: nil
        ),
        placement: .replace,
        token: token
      )
    )
    XCTAssertTrue(
      model.applyDevicePage(
        ViewerDeviceCatalogPage(
          snapshot: deviceBounds,
          rows: [deviceRow(200)],
          olderCursor: nil,
          newerCursor: nil
        ),
        placement: .trailing,
        token: token
      )
    )
    XCTAssertEqual(model.deviceRows.count, ViewerEventExplorerModel.maximumDeviceRows)
    XCTAssertEqual(model.deviceRows.first?.connectionOrdinal, 399)
    XCTAssertEqual(model.deviceNavigation.reloadAnchor?.identity, 400)
    let selectedDevices = (0..<ViewerEventExplorerModel.maximumSelectedDevices).map { _ in UUID() }
    XCTAssertTrue(model.selectDevices(selectedDevices))
    XCTAssertFalse(model.selectDevices(selectedDevices + [UUID()]))
    XCTAssertEqual(model.selectedDeviceLogicalIDs, selectedDevices)
    XCTAssertEqual(model.selectedDeviceLogicalIDsNeedingReload, Set(selectedDevices))

    for start in stride(from: 1, through: 401, by: 200) {
      let end = min(start + 199, 600)
      XCTAssertTrue(
        model.applyEventPage(
          ViewerEventPage(
            rows: (start...end).map { eventRow(Int64($0)) },
            nextCursor: nil,
            previousCursor: nil
          ),
          placement: start == 1 ? .replace : .trailing,
          token: token
        )
      )
    }
    let selectedIdentity = ViewerExplorerEventIdentity.durable(rowID: 1)
    XCTAssertTrue(model.selectEvent(selectedIdentity, scrollToSelection: true))
    let selectedDetail = ViewerStoredEventDetail(
      summary: eventRow(1),
      contentJSON: Data("{\"secret\":\"explorer-detail-secret\"}".utf8),
      deviceLogicalID: UUID(),
      installationAlias: "device-1",
      connectionAlias: "connection-1",
      originMonotonicNanoseconds: 1,
      ttlMilliseconds: 1_000,
      schemaVersion: 1,
      correlationEventUUID: nil,
      replyToEventUUID: nil
    )
    XCTAssertTrue(
      model.applySelectedDetail(selectedDetail, identity: selectedIdentity, token: token))
    XCTAssertTrue(
      model.applyEventPage(
        ViewerEventPage(rows: [eventRow(601)], nextCursor: nil, previousCursor: nil),
        placement: .trailing,
        token: token
      )
    )
    XCTAssertEqual(model.eventRows.count, ViewerEventExplorerModel.maximumEventRows)
    XCTAssertEqual(model.eventRows.first?.rowID, 2)
    XCTAssertEqual(model.eventNavigation.reloadAnchor?.identity, selectedIdentity)
    XCTAssertTrue(model.eventNavigation.hasUnloadedLeadingRows)
    XCTAssertEqual(model.selectedEventIdentity, selectedIdentity)
    XCTAssertEqual(model.selectedEventDetail, selectedDetail)
    XCTAssertTrue(model.selectedEventNeedsReload)
    XCTAssertEqual(model.scrollAnchor, .durable(rowID: 2))

    XCTAssertTrue(
      model.applyEventPage(
        ViewerEventPage(rows: [eventRow(1)], nextCursor: nil, previousCursor: nil),
        placement: .leading,
        token: token
      )
    )
    XCTAssertEqual(model.eventRows.first?.rowID, 1)
    XCTAssertEqual(model.eventRows.last?.rowID, 600)
    XCTAssertFalse(model.selectedEventNeedsReload)
    XCTAssertEqual(model.eventNavigation.reloadAnchor?.identity, .durable(rowID: 601))
    XCTAssertTrue(model.eventNavigation.hasUnloadedTrailingRows)

    for start in stride(from: 1, through: 97, by: 32) {
      let end = min(start + 31, 128)
      XCTAssertTrue(
        model.applyGapPage(
          ViewerGapPage(
            rows: (start...end).map { gapRow(Int64($0)) },
            nextCursor: nil,
            previousCursor: nil
          ),
          placement: start == 1 ? .replace : .trailing,
          token: token
        )
      )
    }
    XCTAssertTrue(
      model.applyGapPage(
        ViewerGapPage(rows: [gapRow(129)], nextCursor: nil, previousCursor: nil),
        placement: .trailing,
        token: token
      )
    )
    XCTAssertEqual(model.gapRows.count, ViewerEventExplorerModel.maximumGapRows)
    XCTAssertEqual(model.gapRows.first?.rowID, 2)
    XCTAssertEqual(model.gapNavigation.reloadAnchor?.identity.sequence, 1)

    let replacementToken = model.beginPresentationReplacement(clearRows: false)
    XCTAssertNotEqual(replacementToken, token)
    XCTAssertFalse(
      model.applyEventPage(
        ViewerEventPage(rows: [eventRow(602)], nextCursor: nil, previousCursor: nil),
        placement: .trailing,
        token: token
      )
    )
    XCTAssertFalse(
      model.applyEventPage(
        ViewerEventPage(
          rows: (1...201).map { eventRow(Int64($0)) },
          nextCursor: nil,
          previousCursor: nil
        ),
        placement: .replace,
        token: replacementToken
      )
    )
    XCTAssertFalse(
      model.applyEventPage(
        ViewerEventPage(rows: [eventRow(2), eventRow(1)], nextCursor: nil, previousCursor: nil),
        placement: .replace,
        token: replacementToken
      )
    )
    let diagnosticText = [String(describing: model), String(reflecting: model)].joined()
    XCTAssertFalse(diagnosticText.contains("explorer-detail-secret"))
    XCTAssertTrue(Mirror(reflecting: model).children.isEmpty)

    model.sealAndClear()
    XCTAssertTrue(model.recordingRows.isEmpty)
    XCTAssertTrue(model.deviceRows.isEmpty)
    XCTAssertTrue(model.eventRows.isEmpty)
    XCTAssertTrue(model.gapRows.isEmpty)
    XCTAssertNil(model.selectedEventDetail)
  }

  @MainActor
  func testExplorerModelCoalescesOneLatestRefreshAtTenHertzAndFreezesOnPause() async {
    let scheduler = ManualLiveRefreshScheduler()
    let capture = ExplorerRefreshCapture()
    let model = ViewerEventExplorerModel(
      runtimeLogicalID: UUID(),
      refreshScheduler: scheduler.explorerValue,
      onRefresh: { token, signal in capture.append(token: token, signal: signal) }
    )
    let initialToken = model.currentToken
    for index in 0..<100_000 {
      XCTAssertTrue(
        model.noteRefresh(
          changeToken: "token-\(index)",
          durableUpperRowID: Int64(index),
          transientChangeIncrement: 1
        )
      )
    }
    XCTAssertEqual(scheduler.pendingCount, 1)
    XCTAssertEqual(model.refreshDiagnostics.scheduleCount, 1)
    XCTAssertEqual(model.pendingRefreshSignal?.transientChangeCount, 100_000)

    let pausedToken = model.setPaused(true)
    XCTAssertNotEqual(pausedToken, initialToken)
    XCTAssertTrue(model.isPaused)
    scheduler.runNext()
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(capture.count, 0)
    XCTAssertEqual(model.pendingRefreshSignal?.transientChangeCount, 100_000)

    let resumedToken = model.setPaused(false)
    XCTAssertNotEqual(resumedToken, pausedToken)
    XCTAssertEqual(scheduler.pendingCount, 1)
    scheduler.runNext()
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(capture.count, 1)
    XCTAssertEqual(capture.tokens, [resumedToken])
    XCTAssertEqual(capture.signals.first?.latestChangeToken, "token-99999")
    XCTAssertEqual(capture.signals.first?.durableUpperRowID, 99_999)
    XCTAssertEqual(capture.signals.first?.transientChangeCount, 100_000)
    XCTAssertEqual(model.refreshDiagnostics.deliveryCount, 1)

    for index in 100_000..<200_000 {
      XCTAssertTrue(
        model.noteRefresh(
          changeToken: "token-\(index)",
          durableUpperRowID: Int64(index),
          transientChangeIncrement: 1
        )
      )
    }
    XCTAssertEqual(scheduler.pendingCount, 1)
    XCTAssertEqual(scheduler.nextDelay, ViewerEventExplorerModel.refreshIntervalNanoseconds)
    XCTAssertEqual(model.refreshDiagnostics.scheduleCount, 3)
    scheduler.runNext()
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(capture.count, 2)
    XCTAssertEqual(capture.signals.last?.latestChangeToken, "token-199999")
    XCTAssertEqual(capture.signals.last?.transientChangeCount, 100_000)

    XCTAssertFalse(
      model.noteRefresh(
        changeToken: String(
          repeating: "x", count: ViewerEventExplorerModel.maximumChangeTokenBytes + 1),
        durableUpperRowID: 1
      )
    )
    XCTAssertTrue(model.noteRefresh(changeToken: "sealed", durableUpperRowID: 200_000))
    XCTAssertEqual(scheduler.pendingCount, 1)
    model.sealAndClear()
    scheduler.runNext()
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(capture.count, 2)
    XCTAssertFalse(model.refreshDiagnostics.wakeScheduled)
    XCTAssertNil(model.pendingRefreshSignal)
  }

  @MainActor
  func testExplorerScopePreservesLogicalSelectionAcrossPartialMaterialization() throws {
    let runtimeLogicalID = UUID()
    let firstDevice = UUID()
    let secondDevice = UUID()
    let missingDevice = UUID()
    let filter = try ViewerExplorerFilter(
      predicates: [
        .eventTypePrefix("test"),
        .applicationIdentifiers(["com.example.app"]),
        .directions(["appToViewer", "viewerToApp"]),
        .priorities(["normal", "high"]),
        .wallTime(from: 100, through: 200),
        .jsonExists(path: "$.value"),
        .hasGap,
        .hasDrop,
        .hasTerminalDisposition,
        .fullText("recorded needle"),
      ]
    )
    let devices = try ViewerExplorerDeviceScope(
      selectedLogicalIDs: [firstDevice, secondDevice, missingDevice]
    )
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let scope = try ViewerExplorerScope(source: source, devices: devices, filter: filter)
    let unavailable = try ViewerExplorerMaterializationSnapshot(
      source: source,
      generation: 1,
      recordingID: nil,
      deviceSessionIDsByLogicalID: [:]
    )
    let unavailableInputs = try ViewerExplorerScopeCompiler.compile(
      scope: scope,
      materialization: unavailable
    )
    XCTAssertNil(unavailableInputs.durableQuery)
    XCTAssertNotNil(unavailableInputs.liveRequest)
    XCTAssertEqual(unavailableInputs.selectedLogicalDeviceCount, 3)
    XCTAssertEqual(unavailableInputs.materializedSelectedDeviceCount, 0)
    XCTAssertTrue(unavailableInputs.liveRequest?.deviceScope.contains(firstDevice) == true)
    XCTAssertTrue(unavailableInputs.liveRequest?.deviceScope.contains(secondDevice) == true)
    XCTAssertTrue(unavailableInputs.liveRequest?.deviceScope.contains(missingDevice) == true)

    let partial = try ViewerExplorerMaterializationSnapshot(
      source: source,
      generation: 2,
      recordingID: 10,
      deviceSessionIDsByLogicalID: [firstDevice: 101, secondDevice: 102]
    )
    let partialInputs = try ViewerExplorerScopeCompiler.compile(
      scope: scope,
      materialization: partial
    )
    XCTAssertEqual(partialInputs.durableQuery?.recordingID, 10)
    XCTAssertEqual(partialInputs.materializedSelectedDeviceCount, 2)
    XCTAssertEqual(partialInputs.durableQuery?.predicates.last, .deviceSessionIDs([101, 102]))
    XCTAssertTrue(partialInputs.liveRequest?.deviceScope.contains(missingDevice) == true)
    let emptyLiveSnapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 1,
      events: [],
      sessions: [],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 0,
        residentConflictCount: 0,
        diagnosticLossCount: 0,
        storeUnavailableCount: 0,
        storeRecoveryCount: 0,
        storeUnavailable: false
      ),
      accountedEventBytes: 0
    )
    guard let liveRequest = partialInputs.liveRequest,
      case .complete(let liveOutput) = ViewerLiveEventEvaluator(
        nowNanoseconds: { 0 }
      ).evaluate(snapshot: emptyLiveSnapshot, request: liveRequest)
    else { return XCTFail("Expected one complete immutable live evaluation") }
    XCTAssertEqual(liveOutput.transientExclusion, .fullTextRequiresRecordedData)

    let allScope = try ViewerExplorerScope(source: source, devices: .all, filter: filter)
    let allInputs = try ViewerExplorerScopeCompiler.compile(
      scope: allScope,
      materialization: partial
    )
    XCTAssertEqual(allInputs.durableQuery?.predicates, filter.predicates)
    XCTAssertEqual(allInputs.materializedSelectedDeviceCount, 0)

    let model = ViewerEventExplorerModel(runtimeLogicalID: runtimeLogicalID)
    let unavailableToken = try model.replaceScope(scope, materialization: unavailable)
    XCTAssertEqual(model.selectedDeviceLogicalIDs, [firstDevice, secondDevice, missingDevice])
    XCTAssertNil(model.compiledInputs?.durableQuery)
    XCTAssertEqual(
      model.selectedRecordingIdentity,
      .current(runtimeLogicalID: runtimeLogicalID)
    )
    let partialToken = try XCTUnwrap(model.replaceMaterialization(partial))
    XCTAssertNotEqual(partialToken, unavailableToken)
    XCTAssertEqual(model.compiledInputs?.materializedSelectedDeviceCount, 2)
    XCTAssertEqual(model.selectedDeviceLogicalIDs, [firstDevice, secondDevice, missingDevice])
    XCTAssertEqual(try model.replaceMaterialization(partial), partialToken)

    let replacementFilter = try ViewerExplorerFilter(
      predicates: [.eventTypeEquals("replacement.filter")]
    )
    let replacementScope = try ViewerExplorerScope(
      source: source,
      devices: devices,
      filter: replacementFilter
    )
    let replacementToken = try model.replaceScope(
      replacementScope,
      materialization: partial
    )
    XCTAssertNotEqual(replacementToken, partialToken)
    XCTAssertEqual(model.currentToken, replacementToken)
    XCTAssertEqual(model.compiledInputs?.scope.filter, replacementFilter)
    XCTAssertFalse(
      model.applyEventPage(
        ViewerEventPage(rows: [], nextCursor: nil, previousCursor: nil),
        placement: .replace,
        token: partialToken
      )
    )

    let stale = try ViewerExplorerMaterializationSnapshot(
      source: .current(runtimeLogicalID: UUID()),
      generation: 3,
      recordingID: 10,
      deviceSessionIDsByLogicalID: [:]
    )
    XCTAssertThrowsError(try model.replaceMaterialization(stale)) { error in
      XCTAssertEqual(error as? ViewerExplorerScopeError, .staleMaterialization)
    }
    XCTAssertEqual(model.currentToken, replacementToken)

    let historicalSource = ViewerExplorerSource.historical(
      recordingID: 20,
      recordingLogicalID: UUID()
    )
    let historicalScope = try ViewerExplorerScope(
      source: historicalSource,
      devices: .all,
      filter: filter
    )
    let historical = try ViewerExplorerMaterializationSnapshot(
      source: historicalSource,
      generation: 1,
      recordingID: 20,
      deviceSessionIDsByLogicalID: [:]
    )
    let historicalInputs = try ViewerExplorerScopeCompiler.compile(
      scope: historicalScope,
      materialization: historical
    )
    XCTAssertNotNil(historicalInputs.durableQuery)
    XCTAssertNil(historicalInputs.liveRequest)

    XCTAssertThrowsError(
      try ViewerExplorerFilter(predicates: [.deviceSessionIDs([1])])
    )
    XCTAssertNoThrow(
      try ViewerExplorerDeviceScope(selectedLogicalIDs: (0..<16).map { _ in UUID() })
    )
    let cardinalityIDs = (0..<16).map { _ in UUID() }
    let cardinalityMappings = Dictionary(
      uniqueKeysWithValues: cardinalityIDs.enumerated().map {
        ($0.element, Int64($0.offset + 1))
      }
    )
    for count in 1...16 {
      let selected = Array(cardinalityIDs.prefix(count))
      let cardinalityScope = try ViewerExplorerScope(
        source: source,
        devices: ViewerExplorerDeviceScope(selectedLogicalIDs: selected),
        filter: ViewerExplorerFilter()
      )
      let cardinalityInputs = try ViewerExplorerScopeCompiler.compile(
        scope: cardinalityScope,
        materialization: ViewerExplorerMaterializationSnapshot(
          source: source,
          generation: UInt64(count),
          recordingID: 10,
          deviceSessionIDsByLogicalID: cardinalityMappings
        )
      )
      XCTAssertEqual(cardinalityInputs.selectedLogicalDeviceCount, count)
      XCTAssertEqual(cardinalityInputs.materializedSelectedDeviceCount, count)
      XCTAssertEqual(
        cardinalityInputs.durableQuery?.predicates,
        [.deviceSessionIDs((1...Int64(count)).map { $0 })]
      )
      XCTAssertTrue(
        selected.allSatisfy { cardinalityInputs.liveRequest?.deviceScope.contains($0) == true })
    }
    XCTAssertThrowsError(
      try ViewerExplorerDeviceScope(selectedLogicalIDs: (0..<17).map { _ in UUID() })
    )
    XCTAssertThrowsError(
      try ViewerExplorerMaterializationSnapshot(
        source: source,
        generation: 1,
        recordingID: 10,
        deviceSessionIDsByLogicalID: [firstDevice: 1, secondDevice: 1]
      )
    )
    let diagnostics = [
      String(describing: scope),
      String(reflecting: partialInputs),
      String(describing: filter),
      String(reflecting: partial),
    ].joined()
    XCTAssertFalse(diagnostics.contains("recorded needle"))
    XCTAssertTrue(Mirror(reflecting: scope).children.isEmpty)
  }

  func testTimelineReconcilesUniqueDurableEventDuringMaterializationLag() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Materialization Lag"
    )
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .integer(1)]),
        createdAt: Date(timeIntervalSince1970: 1),
        sessionEpoch: SessionEpoch(),
        sequence: 7
      ),
      viewerWallMilliseconds: 1_000,
      viewerMonotonicNanoseconds: 1_000,
      deterministicEventBytes: 128,
      initialDisposition: .buffered
    )
    let liveEvent = ViewerLiveEventSnapshot(
      observation: observation,
      laterDisposition: nil,
      durableState: .acceptedAwaitingVisibility,
      hasPresentationConflict: false,
      hasGap: true,
      hasDrop: false,
      sessionEnded: false
    )
    let transient = ViewerExplorerTransientEventRow(liveEvent)
    let durable = ViewerStoredEventRow(
      rowID: 99,
      deviceSessionID: 10,
      direction: observation.key.direction.rawValue,
      wireSequence: Int64(observation.key.wireSequence),
      eventUUID: observation.envelope.id.rawValue,
      eventType: observation.envelope.type.rawValue,
      contentByteCount: Int64(observation.durableProjection.canonicalContent.count),
      createdWallMilliseconds: observation.durableProjection.createdWallMilliseconds,
      viewerWallMilliseconds: observation.viewerWallMilliseconds,
      viewerMonotonicNanoseconds: Int64(observation.viewerMonotonicNanoseconds),
      priority: observation.envelope.priority.rawValue,
      recordingRevision: 1,
      deviceRevision: 1,
      resolvedDisposition: "buffered"
    )
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let scope = try ViewerExplorerScope(source: source, filter: ViewerExplorerFilter())
    let laggingMaterialization = try ViewerExplorerMaterializationSnapshot(
      source: source,
      generation: 1,
      recordingID: 1,
      deviceSessionIDsByLogicalID: [:]
    )
    var timeline = ViewerExplorerTimelineWindow(capacity: 10)
    XCTAssertNotNil(timeline.applyLiveRows([transient], autoFollow: true))
    let mutation = try XCTUnwrap(
      timeline.applyDurablePage(
        ViewerEventPage(rows: [durable], nextCursor: nil, previousCursor: nil),
        placement: .replace,
        scope: scope,
        materialization: laggingMaterialization
      )
    )

    XCTAssertEqual(timeline.rows.count, 1)
    XCTAssertEqual(timeline.rows.first?.identity, .durable(rowID: 99))
    XCTAssertEqual(
      mutation.durableVisibilities,
      [
        ViewerExplorerDurableVisibility(
          key: observation.key,
          observationID: observation.observationID,
          durableRowID: 99
        )
      ]
    )
  }

  func testTimelineDoesNotBridgeAmbiguousPeerEventUUID() throws {
    let runtimeLogicalID = UUID()
    let eventID = EventID()

    func transient(connectionID: UUID, sequence: UInt64, time: UInt64) throws
      -> ViewerExplorerTransientEventRow
    {
      let context = try makeObservationContext(
        connectionID: connectionID,
        displayName: "Ambiguous Event"
      )
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: runtimeLogicalID,
        context: context,
        nickname: nil,
        envelope: makeObservationEnvelope(
          id: eventID,
          content: .object(["value": .integer(1)]),
          createdAt: Date(timeIntervalSince1970: 1),
          sessionEpoch: SessionEpoch(),
          sequence: sequence
        ),
        viewerWallMilliseconds: Int64(time),
        viewerMonotonicNanoseconds: time,
        deterministicEventBytes: 128,
        initialDisposition: .buffered
      )
      return ViewerExplorerTransientEventRow(
        ViewerLiveEventSnapshot(
          observation: observation,
          laterDisposition: nil,
          durableState: .acceptedAwaitingVisibility,
          hasPresentationConflict: false,
          hasGap: false,
          hasDrop: false,
          sessionEnded: false
        )
      )
    }

    let first = try transient(connectionID: UUID(), sequence: 7, time: 1_000)
    let second = try transient(connectionID: UUID(), sequence: 8, time: 1_001)
    let durable = ViewerStoredEventRow(
      rowID: 99,
      deviceSessionID: 10,
      direction: first.key.direction.rawValue,
      wireSequence: Int64(first.key.wireSequence),
      eventUUID: eventID.rawValue,
      eventType: first.eventType,
      contentByteCount: Int64(first.contentByteCount),
      createdWallMilliseconds: first.createdWallMilliseconds,
      viewerWallMilliseconds: first.viewerWallMilliseconds,
      viewerMonotonicNanoseconds: Int64(first.viewerMonotonicNanoseconds),
      priority: first.priority,
      recordingRevision: 1,
      deviceRevision: 1,
      resolvedDisposition: "buffered"
    )
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    var timeline = ViewerExplorerTimelineWindow(capacity: 10)
    XCTAssertNotNil(timeline.applyLiveRows([first, second], autoFollow: true))
    let mutation = try XCTUnwrap(
      timeline.applyDurablePage(
        ViewerEventPage(rows: [durable], nextCursor: nil, previousCursor: nil),
        placement: .replace,
        scope: try ViewerExplorerScope(source: source, filter: ViewerExplorerFilter()),
        materialization: try ViewerExplorerMaterializationSnapshot(
          source: source,
          generation: 1,
          recordingID: 1,
          deviceSessionIDsByLogicalID: [:]
        )
      )
    )
    XCTAssertEqual(timeline.rows.count, 3)
    XCTAssertTrue(mutation.durableVisibilities.isEmpty)
  }

  @MainActor
  func testOrdinaryRefreshPreparationRetainsTimelineUntilSuccessorReplacement() throws {
    let runtimeLogicalID = UUID()
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let model = ViewerEventExplorerModel(runtimeLogicalID: runtimeLogicalID)
    let scope = try ViewerExplorerScope(source: source, filter: ViewerExplorerFilter())
    let materialization = try ViewerExplorerMaterializationSnapshot(
      source: source,
      generation: 1,
      recordingID: 1,
      deviceSessionIDsByLogicalID: [:]
    )
    let token = try model.replaceScope(scope, materialization: materialization)
    let row = ViewerStoredEventRow(
      rowID: 1,
      deviceSessionID: 1,
      direction: "appToViewer",
      wireSequence: 1,
      eventUUID: "retained-event",
      eventType: "test.refresh",
      contentByteCount: 1,
      createdWallMilliseconds: 1,
      viewerWallMilliseconds: 1,
      viewerMonotonicNanoseconds: 1,
      priority: "normal",
      recordingRevision: 1,
      deviceRevision: 1,
      resolvedDisposition: "buffered"
    )
    XCTAssertNotNil(
      model.applyTimelinePage(
        ViewerEventPage(rows: [row], nextCursor: nil, previousCursor: nil),
        placement: .replace,
        token: token
      )
    )
    let retainedRows = model.timelineRows

    let refreshToken = model.beginTimelineReplacement(retainingPresentation: true)
    XCTAssertTrue(
      model.prepareFreshTraversal(
        token: refreshToken,
        jumpsToLatest: false,
        retainingPresentation: true
      )
    )
    XCTAssertEqual(model.timelineRows, retainedRows)
    XCTAssertTrue(
      model.clearAbsentRefreshLanes(
        hasDurableLane: true,
        hasLiveLane: false,
        token: refreshToken
      )
    )
    XCTAssertEqual(model.timelineRows, retainedRows)

    let emptyModel = ViewerEventExplorerModel(runtimeLogicalID: runtimeLogicalID)
    _ = try emptyModel.replaceScope(scope, materialization: materialization)
    let emptyRefreshToken = emptyModel.beginTimelineReplacement(retainingPresentation: true)
    XCTAssertTrue(
      emptyModel.clearAbsentRefreshLanes(
        hasDurableLane: false,
        hasLiveLane: false,
        token: emptyRefreshToken
      )
    )
    XCTAssertTrue(emptyModel.timelineRows.isEmpty)
  }

  @MainActor
  func testRefreshFailureRestartsPendingDetailAndClearsRemovedInspectorContent() async throws {
    let runtimeLogicalID = UUID()
    let detailCompletions = FoundationDetailCompletionBox()
    let gateway = ViewerStoreExplorerGateway()
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      ),
      contentDriver: ViewerExplorerContentDriver(
        gateway: gateway,
        loadDetail: { _, completion in
          let operationID = UUID()
          detailCompletions.append(completion)
          return ViewerStoreExplorerOperationToken(
            coordinatorGeneration: 0,
            operationID: operationID
          )
        }
      )
    )
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let token = try controller.model.replaceScope(
      ViewerExplorerScope(source: source, filter: ViewerExplorerFilter()),
      materialization: ViewerExplorerMaterializationSnapshot(
        source: source,
        generation: 1,
        recordingID: 1,
        deviceSessionIDsByLogicalID: [:]
      )
    )
    let row = ViewerStoredEventRow(
      rowID: 1,
      deviceSessionID: 1,
      direction: "appToViewer",
      wireSequence: 1,
      eventUUID: "refresh-detail-event",
      eventType: "test.refresh.detail",
      contentByteCount: 27,
      createdWallMilliseconds: 1,
      viewerWallMilliseconds: 1,
      viewerMonotonicNanoseconds: 1,
      priority: "normal",
      recordingRevision: 1,
      deviceRevision: 1,
      resolvedDisposition: "buffered"
    )
    XCTAssertNotNil(
      controller.model.applyTimelinePage(
        ViewerEventPage(rows: [row], nextCursor: nil, previousCursor: nil),
        placement: .replace,
        token: token
      )
    )
    controller.coordinatorPresentationChanged()
    controller.selectEvent(.durable(rowID: row.rowID))
    XCTAssertEqual(controller.inspectorState, .loading)
    XCTAssertEqual(detailCompletions.count, 1)

    let refreshToken = controller.model.beginTimelineReplacement(retainingPresentation: true)
    controller.coordinatorPresentationChanged()
    XCTAssertTrue(controller.model.selectedEventNeedsReload)
    XCTAssertEqual(controller.inspectorState, .loading)

    XCTAssertTrue(controller.model.finishRetainedRefreshFailure(token: refreshToken))
    controller.coordinatorPresentationChanged()
    XCTAssertFalse(controller.model.selectedEventNeedsReload)
    XCTAssertEqual(detailCompletions.count, 2)

    let detail = makeRendererDetail(
      rowID: row.rowID,
      eventType: row.eventType,
      content: Data(#"{"secret":"refresh-detail"}"#.utf8)
    )
    detailCompletions.complete(at: 0, with: .success(detail))
    detailCompletions.complete(at: 1, with: .success(detail))
    for _ in 0..<2_000 where controller.inspectorState != .ready {
      await Task.yield()
    }
    XCTAssertEqual(controller.inspectorState, .ready)
    XCTAssertEqual(controller.inspectorMetadata?.eventType, row.eventType)

    let successorToken = controller.model.beginTimelineReplacement(retainingPresentation: true)
    controller.coordinatorPresentationChanged()
    XCTAssertNotNil(
      controller.model.applyTimelinePage(
        ViewerEventPage(rows: [row], nextCursor: nil, previousCursor: nil),
        placement: .replace,
        token: successorToken
      )
    )
    controller.coordinatorPresentationChanged()
    XCTAssertFalse(controller.model.selectedEventNeedsReload)
    XCTAssertEqual(detailCompletions.count, 2)
    XCTAssertEqual(controller.inspectorState, .ready)
    XCTAssertEqual(controller.inspectorMetadata?.eventType, row.eventType)

    let removalToken = controller.model.beginTimelineReplacement(retainingPresentation: true)
    controller.coordinatorPresentationChanged()
    XCTAssertTrue(
      controller.model.clearAbsentRefreshLanes(
        hasDurableLane: false,
        hasLiveLane: false,
        token: removalToken
      )
    )
    controller.model.finishFreshTraversal(token: removalToken)
    controller.coordinatorPresentationChanged()

    XCTAssertNil(controller.selectedEventID)
    XCTAssertEqual(controller.inspectorState, .empty)
    XCTAssertNil(controller.inspector.canonicalBuffer)
    XCTAssertNil(controller.rendererPreparation)
    await controller.sealAndClear().value
  }

  @MainActor
  func testRetainedRefreshFailuresRestoreSelectionReloadState() async throws {
    let runtimeLogicalID = UUID()
    let source = ViewerExplorerSource.historical(
      recordingID: 1,
      recordingLogicalID: UUID()
    )
    let materialization = try ViewerExplorerMaterializationSnapshot(
      source: source,
      generation: 1,
      recordingID: 1,
      deviceSessionIDsByLogicalID: [:]
    )
    let live = ExplorerLiveObservationSpy(
      snapshot: ViewerLiveProjectionSnapshot(
        runtimeLogicalID: runtimeLogicalID,
        generation: 1,
        events: [],
        sessions: [],
        gaps: ViewerLiveGapSnapshot(
          ingressOverflowCount: 0,
          windowOverflowCount: 0,
          residentConflictCount: 0,
          diagnosticLossCount: 0,
          storeUnavailableCount: 0,
          storeRecoveryCount: 0,
          storeUnavailable: false
        ),
        accountedEventBytes: 0
      )
    )
    let store = ExplorerStoreDriverSpy()
    let model = ViewerEventExplorerModel(runtimeLogicalID: runtimeLogicalID)
    let coordinator = ViewerEventExplorerCoordinator(
      model: model,
      store: store.driver,
      live: live
    )
    let token = try model.replaceScope(
      ViewerExplorerScope(source: source, filter: ViewerExplorerFilter()),
      materialization: materialization
    )
    let row = ViewerStoredEventRow(
      rowID: 1,
      deviceSessionID: 1,
      direction: "appToViewer",
      wireSequence: 1,
      eventUUID: "retained-refresh-failure",
      eventType: "test.refresh.failure",
      contentByteCount: 1,
      createdWallMilliseconds: 1,
      viewerWallMilliseconds: 1,
      viewerMonotonicNanoseconds: 1,
      priority: "normal",
      recordingRevision: 1,
      deviceRevision: 1,
      resolvedDisposition: "buffered"
    )
    XCTAssertNotNil(
      model.applyTimelinePage(
        ViewerEventPage(rows: [row], nextCursor: nil, previousCursor: nil),
        placement: .replace,
        token: token
      )
    )
    XCTAssertTrue(model.selectEvent(.durable(rowID: row.rowID)))

    _ = coordinator.refresh()
    XCTAssertTrue(model.selectedEventNeedsReload)
    store.completeNextRelease(.failure(.unavailable))
    await waitUntilExplorer { coordinator.state == .failed(.unavailable) }
    XCTAssertFalse(model.selectedEventNeedsReload)
    XCTAssertEqual(model.selectedEventIdentity, .durable(rowID: row.rowID))
    XCTAssertEqual(model.timelineRows.count, 1)

    _ = coordinator.refresh()
    XCTAssertTrue(model.selectedEventNeedsReload)
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 1 }
    store.completeNextQuery(.failure(.busy))
    await waitUntilExplorer { coordinator.state == .failed(.busy) }
    XCTAssertFalse(model.selectedEventNeedsReload)
    XCTAssertEqual(model.selectedEventIdentity, .durable(rowID: row.rowID))
    XCTAssertEqual(model.timelineRows.count, 1)

    XCTAssertTrue(
      model.applySelectedDetail(
        makeRendererDetail(
          rowID: row.rowID,
          eventType: row.eventType,
          content: Data(#"{"retained":true}"#.utf8)
        ),
        identity: .durable(rowID: row.rowID),
        token: model.currentToken
      )
    )
    XCTAssertNotNil(model.selectedEventDetail)

    _ = coordinator.refresh()
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 2 }
    store.completeNextQuery(
      .success(
        ViewerQuerySnapshot(
          eventUpperRowID: 1,
          recordingVersionUpperRowID: 1,
          deviceVersionUpperRowID: 1,
          dispositionUpperRowID: 1,
          gapUpperRowID: 1,
          dropUpperRowID: 1
        )
      )
    )
    await waitUntilExplorer { store.pageRequestCount == 1 && store.gapRequestCount == 1 }
    store.completeNextPage(
      .success(ViewerEventPage(rows: [], nextCursor: nil, previousCursor: nil))
    )
    store.completeNextGaps(.failure(.unavailable))
    await waitUntilExplorer { coordinator.state == .failed(.unavailable) }
    XCTAssertNil(model.selectedEventIdentity)
    XCTAssertNil(model.selectedEventDetail)
    XCTAssertFalse(model.selectedEventNeedsReload)
    XCTAssertTrue(model.timelineRows.isEmpty)
    await coordinator.waitForIdle().value
  }

  @MainActor
  func testExplorerCoalescesRepeatedBoundaryRequestsWhileEachLaneIsActive() async throws {
    let runtimeLogicalID = UUID()
    let gateway = ViewerStoreExplorerGateway()
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      )
    )
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let token = try controller.model.replaceScope(
      ViewerExplorerScope(source: source, filter: ViewerExplorerFilter()),
      materialization: ViewerExplorerMaterializationSnapshot(
        source: source,
        generation: 1,
        recordingID: 1,
        deviceSessionIDsByLogicalID: [:]
      )
    )
    let snapshot = ViewerQuerySnapshot(
      eventUpperRowID: 1,
      recordingVersionUpperRowID: 1,
      deviceVersionUpperRowID: 1,
      dispositionUpperRowID: 1,
      gapUpperRowID: 1,
      dropUpperRowID: 1
    )
    let eventCursor = ViewerEventCursor(
      recordingID: 1,
      queryFingerprint: "single-flight-event",
      snapshot: snapshot,
      leaseID: UUID(),
      leaseExpiresAt: .now + .seconds(60),
      direction: .backward,
      viewerMonotonicNanoseconds: 1,
      rowID: 1
    )
    let event = ViewerStoredEventRow(
      rowID: 1,
      deviceSessionID: 1,
      direction: "appToViewer",
      wireSequence: 1,
      eventUUID: "single-flight-event",
      eventType: "test.single-flight",
      contentByteCount: 1,
      createdWallMilliseconds: 1,
      viewerWallMilliseconds: 1,
      viewerMonotonicNanoseconds: 1,
      priority: "normal",
      recordingRevision: 1,
      deviceRevision: 1,
      resolvedDisposition: "buffered"
    )
    XCTAssertNotNil(
      controller.model.applyTimelinePage(
        ViewerEventPage(rows: [event], nextCursor: nil, previousCursor: eventCursor),
        placement: .replace,
        token: token
      )
    )
    let gapCursor = ViewerGapCursor(
      recordingID: 1,
      queryFingerprint: "single-flight-gap",
      deviceSessionIDs: [],
      gapUpperRowID: 1,
      leaseID: UUID(),
      leaseExpiresAt: .now + .seconds(60),
      direction: .backward,
      lastViewerWallMilliseconds: 1,
      rowID: 1
    )
    XCTAssertTrue(
      controller.model.applyGapPage(
        ViewerGapPage(
          rows: [
            ViewerGapRow(
              rowID: 1,
              recordingID: 1,
              deviceSessionID: nil,
              sequence: 1,
              namespace: "single-flight",
              revision: 1,
              reason: "test",
              firstViewerWallMilliseconds: 1,
              lastViewerWallMilliseconds: 1,
              directions: "appToViewer",
              firstWireSequence: 1,
              lastWireSequence: 1,
              count: 1
            )
          ],
          nextCursor: nil,
          previousCursor: gapCursor
        ),
        placement: .replace,
        token: token
      )
    )

    controller.loadOlderEvents()
    controller.loadOlderEvents()
    controller.loadOlderGaps()
    controller.loadOlderGaps()

    XCTAssertEqual(controller.eventPageRequestCountForTesting, 1)
    XCTAssertEqual(controller.gapPageRequestCountForTesting, 1)
    await controller.sealAndClear().value
  }

  @MainActor
  func testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity()
    async throws
  {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Explorer App"
    )
    let exactObservation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .string("exact-secret")]),
        createdAt: Date(timeIntervalSince1970: 1),
        sessionEpoch: SessionEpoch(),
        sequence: 7
      ),
      viewerWallMilliseconds: 1_000,
      viewerMonotonicNanoseconds: 1_000,
      deterministicEventBytes: 128,
      initialDisposition: .buffered
    )
    let transientOnlyObservation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["value": .string("transient-secret")]),
        createdAt: Date(timeIntervalSince1970: 2),
        sessionEpoch: SessionEpoch(),
        sequence: 8
      ),
      viewerWallMilliseconds: 1_001,
      viewerMonotonicNanoseconds: 1_001,
      deterministicEventBytes: 128,
      initialDisposition: .buffered
    )
    let liveSnapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 1,
      events: [exactObservation, transientOnlyObservation].map {
        ViewerLiveEventSnapshot(
          observation: $0,
          laterDisposition: nil,
          durableState: .acceptedAwaitingVisibility,
          hasPresentationConflict: false,
          hasGap: true,
          hasDrop: false,
          sessionEnded: false
        )
      },
      sessions: [],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 1,
        residentConflictCount: 0,
        diagnosticLossCount: 0,
        storeUnavailableCount: 0,
        storeRecoveryCount: 0,
        storeUnavailable: false
      ),
      accountedEventBytes: 2 * (ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 128)
    )
    let live = ExplorerLiveObservationSpy(snapshot: liveSnapshot)
    let store = ExplorerStoreDriverSpy()
    let model = ViewerEventExplorerModel(runtimeLogicalID: runtimeLogicalID)
    let coordinator = ViewerEventExplorerCoordinator(
      model: model,
      store: store.driver,
      live: live
    )
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let scope = try ViewerExplorerScope(
      source: source,
      devices: ViewerExplorerDeviceScope(selectedLogicalIDs: [connectionID]),
      filter: ViewerExplorerFilter()
    )
    let materialization = try ViewerExplorerMaterializationSnapshot(
      source: source,
      generation: 1,
      recordingID: 1,
      deviceSessionIDsByLogicalID: [connectionID: 10]
    )

    let scopeToken = try coordinator.replaceScope(scope, materialization: materialization)
    XCTAssertEqual(store.releaseRequestCount, 1)
    XCTAssertEqual(coordinator.state, .releasing(.scopeReplacement))
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 1 && model.timelineRows.count == 2 }
    XCTAssertEqual(live.snapshotRequestCount, 1)
    XCTAssertEqual(model.timelineRows.count, 2)
    XCTAssertTrue(model.selectEvent(.transient(exactObservation.key), scrollToSelection: true))

    let querySnapshot = ViewerQuerySnapshot(
      eventUpperRowID: 100,
      recordingVersionUpperRowID: 100,
      deviceVersionUpperRowID: 100,
      dispositionUpperRowID: 100,
      gapUpperRowID: 100,
      dropUpperRowID: 100
    )
    let durableRow = ViewerStoredEventRow(
      rowID: 99,
      deviceSessionID: 10,
      direction: "appToViewer",
      wireSequence: 7,
      eventUUID: exactObservation.envelope.id.rawValue,
      eventType: exactObservation.envelope.type.rawValue,
      contentByteCount: Int64(exactObservation.durableProjection.canonicalContent.count),
      createdWallMilliseconds: exactObservation.durableProjection.createdWallMilliseconds,
      viewerWallMilliseconds: exactObservation.viewerWallMilliseconds,
      viewerMonotonicNanoseconds: 1_000,
      priority: "normal",
      recordingRevision: 1,
      deviceRevision: 1,
      resolvedDisposition: "buffered"
    )
    let durableGap = ViewerGapRow(
      rowID: 1,
      recordingID: 1,
      deviceSessionID: 10,
      sequence: 1,
      namespace: "store",
      revision: 1,
      reason: "test",
      firstViewerWallMilliseconds: 1_000,
      lastViewerWallMilliseconds: 1_001,
      directions: "appToViewer",
      firstWireSequence: 7,
      lastWireSequence: 8,
      count: 1
    )
    store.completeNextQuery(.success(querySnapshot))
    await waitUntilExplorer { store.pageRequestCount == 1 && store.gapRequestCount == 1 }
    store.completeNextPage(
      .success(ViewerEventPage(rows: [durableRow], nextCursor: nil, previousCursor: nil))
    )
    store.completeNextGaps(
      .success(ViewerGapPage(rows: [durableGap], nextCursor: nil, previousCursor: nil))
    )
    await waitUntilExplorer { coordinator.state == .ready(.scopeReplacement) }

    XCTAssertEqual(model.timelineRows.count, 2)
    XCTAssertEqual(model.eventRows.map(\.rowID), [99])
    XCTAssertFalse(model.timelineRows.contains { $0.identity == .transient(exactObservation.key) })
    XCTAssertTrue(
      model.timelineRows.contains { $0.identity == .transient(transientOnlyObservation.key) }
    )
    XCTAssertEqual(model.selectedEventIdentity, .durable(rowID: 99))
    XCTAssertEqual(live.visibleValues.count, 1)
    XCTAssertEqual(live.visibleValues.first?.key, exactObservation.key)
    XCTAssertEqual(model.gapRows, [durableGap])
    XCTAssertEqual(model.liveGapLane?.gaps.windowOverflowCount, 1)
    XCTAssertTrue(model.liveGapLane?.hasDiagnostic == true)
    XCTAssertEqual(model.timelineRows.count + model.gapRows.count, 3)
    let inspector = ViewerEventInspectorModel(runtimeLogicalID: runtimeLogicalID)
    let transientIdentity = ViewerExplorerEventIdentity.transient(transientOnlyObservation.key)
    let transientRequest = try inspector.select(
      liveEvent: liveSnapshot.events[1],
      identity: transientIdentity
    )
    XCTAssertEqual(inspector.canonicalBuffer?.metadata.isRecorded, false)
    XCTAssertEqual(inspector.canonicalBuffer?.metadata.hasGap, true)
    XCTAssertEqual(inspector.canonicalBuffer?.metadata.deviceLogicalID, connectionID)
    XCTAssertTrue(inspector.apply(ViewerRendererPreparer().prepare(transientRequest)))
    XCTAssertEqual(inspector.preparation?.presentedKind, .genericJSON)

    coordinator.noteManualScroll(.durable(rowID: 99))
    XCTAssertFalse(model.autoFollow)
    let pausedRows = model.timelineRows
    let pausedToken = coordinator.pause()
    XCTAssertNotEqual(pausedToken, scopeToken)
    XCTAssertTrue(model.isPaused)
    XCTAssertEqual(live.pausedValues.last, true)
    XCTAssertEqual(model.timelineRows, pausedRows)
    XCTAssertTrue(model.selectEvent(.durable(rowID: 99)))
    XCTAssertTrue(
      model.applySelectedDetail(
        makeRendererDetail(
          rowID: 99,
          eventType: "test.observation",
          content: Data("{\"value\":1}".utf8)
        ),
        identity: .durable(rowID: 99),
        token: pausedToken
      )
    )
    XCTAssertFalse(
      model.applyEventPage(
        ViewerEventPage(rows: [durableRow], nextCursor: nil, previousCursor: nil),
        placement: .replace,
        token: scopeToken
      )
    )
    XCTAssertTrue(
      model.noteRefresh(
        changeToken: "paused-latest",
        durableUpperRowID: 100,
        transientChangeIncrement: UInt64.max,
        transientGapIncrement: UInt64.max
      )
    )
    XCTAssertEqual(model.pendingRefreshSignal?.transientChangeCount, UInt64.max)
    XCTAssertEqual(model.pendingRefreshSignal?.transientGapCount, UInt64.max)

    _ = coordinator.resume()
    XCTAssertEqual(store.releaseRequestCount, 2)
    let jumpToken = coordinator.jumpToLatest()
    XCTAssertTrue(model.autoFollow)
    XCTAssertEqual(store.releaseRequestCount, 3)
    store.completeNextRelease(.success(()))
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(store.queryRequestCount, 1)
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 2 && live.snapshotRequestCount == 2 }
    store.completeNextQuery(.success(querySnapshot))
    await waitUntilExplorer { store.pageRequestCount == 2 && store.gapRequestCount == 2 }
    store.completeNextPage(
      .success(ViewerEventPage(rows: [durableRow], nextCursor: nil, previousCursor: nil))
    )
    store.completeNextGaps(
      .success(ViewerGapPage(rows: [durableGap], nextCursor: nil, previousCursor: nil))
    )
    await waitUntilExplorer { coordinator.state == .ready(.jumpToLatest) }
    XCTAssertEqual(model.currentToken, jumpToken)
    XCTAssertEqual(model.scrollAnchor, .transient(transientOnlyObservation.key))
    XCTAssertEqual(coordinator.diagnostics.requestCount, 3)
    XCTAssertEqual(coordinator.diagnostics.releaseRequestCount, 3)
    XCTAssertEqual(coordinator.diagnostics.releaseCompletionCount, 3)
    XCTAssertEqual(coordinator.diagnostics.durableQueryCount, 2)
    XCTAssertEqual(coordinator.diagnostics.liveSnapshotCount, 2)
    XCTAssertEqual(live.pausedValues, [true, false])
    let diagnosticText = [
      String(describing: coordinator),
      String(reflecting: model.timelineRows.first as Any),
    ].joined()
    XCTAssertFalse(diagnosticText.contains("exact-secret"))
    XCTAssertFalse(diagnosticText.contains("transient-secret"))
  }

  @MainActor
  func testExplorerAnalysisDeactivationJoinsTraversalBeforeReactivation() async throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let live = ExplorerLiveObservationSpy(
      snapshot: ViewerLiveProjectionSnapshot(
        runtimeLogicalID: runtimeLogicalID,
        generation: 1,
        events: [],
        sessions: [],
        gaps: ViewerLiveGapSnapshot(
          ingressOverflowCount: 0,
          windowOverflowCount: 0,
          residentConflictCount: 0,
          diagnosticLossCount: 0,
          storeUnavailableCount: 0,
          storeRecoveryCount: 0,
          storeUnavailable: false
        ),
        accountedEventBytes: 0
      )
    )
    let store = ExplorerStoreDriverSpy()
    let model = ViewerEventExplorerModel(runtimeLogicalID: runtimeLogicalID)
    let coordinator = ViewerEventExplorerCoordinator(
      model: model,
      store: store.driver,
      live: live
    )
    let scope = try ViewerExplorerScope(
      source: source,
      devices: ViewerExplorerDeviceScope(selectedLogicalIDs: [connectionID]),
      filter: ViewerExplorerFilter()
    )
    let materialization = try ViewerExplorerMaterializationSnapshot(
      source: source,
      generation: 1,
      recordingID: 1,
      deviceSessionIDsByLogicalID: [connectionID: 10]
    )

    _ = try coordinator.replaceScope(scope, materialization: materialization)
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 1 }

    let deactivation = coordinator.deactivateAndReleaseTraversal()
    XCTAssertFalse(coordinator.isAnalysisActive)
    XCTAssertEqual(coordinator.state, .releasing(.analysisModeSwitch))
    XCTAssertEqual(store.releaseRequestCount, 2)
    store.completeNextQuery(.failure(.cancelled))
    store.completeNextRelease(.success(()))
    await deactivation.value
    XCTAssertEqual(coordinator.state, .idle)
    XCTAssertEqual(store.pageRequestCount, 0)
    XCTAssertEqual(store.gapRequestCount, 0)

    let activation = coordinator.activateAndRefresh()
    XCTAssertTrue(coordinator.isAnalysisActive)
    XCTAssertEqual(store.queryRequestCount, 1)
    XCTAssertEqual(store.releaseRequestCount, 3)
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 2 }
    store.completeNextQuery(
      .success(
        ViewerQuerySnapshot(
          eventUpperRowID: 0,
          recordingVersionUpperRowID: 0,
          deviceVersionUpperRowID: 0,
          dispositionUpperRowID: 0,
          gapUpperRowID: 0,
          dropUpperRowID: 0
        )
      )
    )
    await waitUntilExplorer { store.pageRequestCount == 1 && store.gapRequestCount == 1 }
    store.completeNextPage(
      .success(ViewerEventPage(rows: [], nextCursor: nil, previousCursor: nil))
    )
    store.completeNextGaps(.success(ViewerGapPage(rows: [], nextCursor: nil, previousCursor: nil)))
    await activation.value
    XCTAssertEqual(coordinator.state, .ready(.analysisModeSwitch))

    let cleanup = coordinator.deactivateAndReleaseTraversal()
    XCTAssertEqual(store.releaseRequestCount, 4)
    store.completeNextRelease(.success(()))
    await cleanup.value
    XCTAssertEqual(coordinator.pendingWorkCount, 0)
  }

  @MainActor
  func testExplorerCoordinatorPauseBeforeCompletionAndRapidGenerationsPublishOnlyLatest()
    async throws
  {
    let runtimeLogicalID = UUID()
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let materialization = try ViewerExplorerMaterializationSnapshot(
      source: source,
      generation: 1,
      recordingID: nil,
      deviceSessionIDsByLogicalID: [:]
    )
    let live = ExplorerLiveObservationSpy(
      snapshot: ViewerLiveProjectionSnapshot(
        runtimeLogicalID: runtimeLogicalID,
        generation: 1,
        events: [],
        sessions: [],
        gaps: ViewerLiveGapSnapshot(
          ingressOverflowCount: 0,
          windowOverflowCount: 0,
          residentConflictCount: 0,
          diagnosticLossCount: 0,
          storeUnavailableCount: 0,
          storeRecoveryCount: 0,
          storeUnavailable: false
        ),
        accountedEventBytes: 0
      )
    )
    let store = ExplorerStoreDriverSpy()
    let evaluationQueue = DispatchQueue(
      label: "ViewerFoundationTests.explorer-rapid-generations"
    )
    let evaluationGate = DispatchSemaphore(value: 0)
    evaluationQueue.async { evaluationGate.wait() }
    let model = ViewerEventExplorerModel(runtimeLogicalID: runtimeLogicalID)
    let coordinator = ViewerEventExplorerCoordinator(
      model: model,
      store: store.driver,
      live: live,
      evaluationQueue: evaluationQueue,
      evaluator: ViewerLiveEventEvaluator(nowNanoseconds: { 0 })
    )
    let initialScope = try ViewerExplorerScope(
      source: source,
      devices: .all,
      filter: ViewerExplorerFilter()
    )

    let initialToken = try coordinator.replaceScope(
      initialScope,
      materialization: materialization
    )
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { live.snapshotRequestCount == 1 }
    XCTAssertEqual(coordinator.state, .loading(.scopeReplacement))

    let pausedToken = coordinator.pause()
    XCTAssertNotEqual(pausedToken, initialToken)
    XCTAssertEqual(coordinator.state, .paused)
    evaluationGate.signal()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertTrue(model.timelineRows.isEmpty)

    let resumeToken = coordinator.resume()
    let jumpToken = coordinator.jumpToLatest()
    let finalScope = try ViewerExplorerScope(
      source: source,
      devices: .all,
      filter: ViewerExplorerFilter(predicates: [.eventTypeEquals("final.filter")])
    )
    let finalToken = try coordinator.replaceScope(finalScope, materialization: materialization)
    XCTAssertNotEqual(resumeToken, pausedToken)
    XCTAssertNotEqual(jumpToken, resumeToken)
    XCTAssertNotEqual(finalToken, jumpToken)
    XCTAssertEqual(store.releaseRequestCount, 4)

    store.completeNextRelease(.success(()))
    store.completeNextRelease(.success(()))
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(live.snapshotRequestCount, 1)
    XCTAssertEqual(store.queryRequestCount, 0)

    store.completeNextRelease(.success(()))
    await waitUntilExplorer { coordinator.state == .ready(.scopeReplacement) }
    XCTAssertEqual(model.currentToken, finalToken)
    XCTAssertEqual(model.compiledInputs?.scope.filter, finalScope.filter)
    XCTAssertTrue(model.timelineRows.isEmpty)
    XCTAssertEqual(live.snapshotRequestCount, 2)
    XCTAssertEqual(live.pausedValues, [true, false])
    XCTAssertEqual(store.queryRequestCount, 0)
    XCTAssertEqual(store.pageRequestCount, 0)
    XCTAssertEqual(store.gapRequestCount, 0)
    XCTAssertEqual(
      coordinator.diagnostics,
      ViewerExplorerTraversalDiagnostics(
        requestCount: 4,
        releaseRequestCount: 4,
        releaseCompletionCount: 4,
        durableQueryCount: 0,
        liveSnapshotCount: 2
      )
    )
  }

  @MainActor
  func testExplorerCoordinatorRejectsInvalidStoreTokenAtEveryTraversalStage() async throws {
    let runtimeLogicalID = UUID()
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let live = ExplorerLiveObservationSpy(
      snapshot: ViewerLiveProjectionSnapshot(
        runtimeLogicalID: runtimeLogicalID,
        generation: 1,
        events: [],
        sessions: [],
        gaps: ViewerLiveGapSnapshot(
          ingressOverflowCount: 0,
          windowOverflowCount: 0,
          residentConflictCount: 0,
          diagnosticLossCount: 0,
          storeUnavailableCount: 0,
          storeRecoveryCount: 0,
          storeUnavailable: false
        ),
        accountedEventBytes: 0
      )
    )
    let store = ExplorerStoreDriverSpy()
    let model = ViewerEventExplorerModel(runtimeLogicalID: runtimeLogicalID)
    let coordinator = ViewerEventExplorerCoordinator(
      model: model,
      store: store.driver,
      live: live
    )
    let querySnapshot = ViewerQuerySnapshot(
      eventUpperRowID: 100,
      recordingVersionUpperRowID: 100,
      deviceVersionUpperRowID: 100,
      dispositionUpperRowID: 100,
      gapUpperRowID: 100,
      dropUpperRowID: 100
    )
    let sentinelEvent = ViewerStoredEventRow(
      rowID: 41,
      deviceSessionID: 1,
      direction: "appToViewer",
      wireSequence: 1,
      eventUUID: UUID().uuidString.lowercased(),
      eventType: "test.invalid-page",
      contentByteCount: 1,
      createdWallMilliseconds: 1_000,
      viewerWallMilliseconds: 1_000,
      viewerMonotonicNanoseconds: 1_000,
      priority: "normal",
      recordingRevision: 1,
      deviceRevision: 1,
      resolvedDisposition: "buffered"
    )
    let sentinelGap = ViewerGapRow(
      rowID: 42,
      recordingID: 1,
      deviceSessionID: nil,
      sequence: 1,
      namespace: "test",
      revision: 1,
      reason: "invalid-gap",
      firstViewerWallMilliseconds: 1_000,
      lastViewerWallMilliseconds: 1_000,
      directions: "appToViewer",
      firstWireSequence: 1,
      lastWireSequence: 1,
      count: 1
    )
    _ = try coordinator.replaceScope(
      ViewerExplorerScope(
        source: source,
        devices: .all,
        filter: ViewerExplorerFilter()
      ),
      materialization: ViewerExplorerMaterializationSnapshot(
        source: source,
        generation: 1,
        recordingID: 1,
        deviceSessionIDsByLogicalID: [:]
      )
    )

    store.invalidateNextRelease()
    store.completeNextRelease(.success(()))
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(store.queryRequestCount, 0)
    XCTAssertEqual(store.pageRequestCount, 0)
    XCTAssertEqual(store.gapRequestCount, 0)
    XCTAssertEqual(live.snapshotRequestCount, 0)

    _ = coordinator.refresh()
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 1 }
    store.invalidateNextQuery()
    store.completeNextQuery(.success(querySnapshot))
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(store.pageRequestCount, 0)
    XCTAssertEqual(store.gapRequestCount, 0)

    _ = coordinator.refresh()
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 2 }
    store.completeNextQuery(.success(querySnapshot))
    await waitUntilExplorer { store.pageRequestCount == 1 && store.gapRequestCount == 1 }
    store.invalidateNextPage()
    store.completeNextPage(
      .success(ViewerEventPage(rows: [sentinelEvent], nextCursor: nil, previousCursor: nil))
    )
    store.completeNextGaps(
      .success(ViewerGapPage(rows: [], nextCursor: nil, previousCursor: nil))
    )
    for _ in 0..<100 { await Task.yield() }
    XCTAssertTrue(model.timelineRows.isEmpty)
    XCTAssertTrue(model.gapRows.isEmpty)
    XCTAssertEqual(coordinator.state, .loading(.refresh))
    await coordinator.waitForIdle().value
    XCTAssertEqual(coordinator.pendingWorkCount, 0)

    _ = coordinator.refresh()
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 3 }
    store.completeNextQuery(.success(querySnapshot))
    await waitUntilExplorer { store.pageRequestCount == 2 && store.gapRequestCount == 2 }
    store.invalidateNextGaps()
    store.completeNextPage(
      .success(ViewerEventPage(rows: [], nextCursor: nil, previousCursor: nil))
    )
    store.completeNextGaps(
      .success(ViewerGapPage(rows: [sentinelGap], nextCursor: nil, previousCursor: nil))
    )
    for _ in 0..<100 { await Task.yield() }
    XCTAssertTrue(model.timelineRows.isEmpty)
    XCTAssertTrue(model.gapRows.isEmpty)
    XCTAssertEqual(coordinator.state, .loading(.refresh))
    await coordinator.waitForIdle().value
    XCTAssertEqual(coordinator.pendingWorkCount, 0)

    _ = coordinator.refresh()
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 4 }
    store.completeNextQuery(.success(querySnapshot))
    await waitUntilExplorer { store.pageRequestCount == 3 && store.gapRequestCount == 3 }
    store.completeNextPage(
      .success(ViewerEventPage(rows: [], nextCursor: nil, previousCursor: nil))
    )
    store.completeNextGaps(
      .success(ViewerGapPage(rows: [], nextCursor: nil, previousCursor: nil))
    )
    await waitUntilExplorer { coordinator.state == .ready(.refresh) }
    await coordinator.waitForIdle().value
    XCTAssertEqual(coordinator.pendingWorkCount, 0)
  }

  @MainActor
  func testExplorerCoordinatorDiscardsSynchronouslyRejectedTraversalSuccessors() async throws {
    let runtimeLogicalID = UUID()
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let live = ExplorerLiveObservationSpy(
      snapshot: ViewerLiveProjectionSnapshot(
        runtimeLogicalID: runtimeLogicalID,
        generation: 1,
        events: [],
        sessions: [],
        gaps: ViewerLiveGapSnapshot(
          ingressOverflowCount: 0,
          windowOverflowCount: 0,
          residentConflictCount: 0,
          diagnosticLossCount: 0,
          storeUnavailableCount: 0,
          storeRecoveryCount: 0,
          storeUnavailable: false
        ),
        accountedEventBytes: 0
      )
    )
    let store = ExplorerStoreDriverSpy()
    let model = ViewerEventExplorerModel(runtimeLogicalID: runtimeLogicalID)
    let coordinator = ViewerEventExplorerCoordinator(
      model: model,
      store: store.driver,
      live: live
    )
    let querySnapshot = ViewerQuerySnapshot(
      eventUpperRowID: 0,
      recordingVersionUpperRowID: 0,
      deviceVersionUpperRowID: 0,
      dispositionUpperRowID: 0,
      gapUpperRowID: 0,
      dropUpperRowID: 0
    )
    _ = try coordinator.replaceScope(
      ViewerExplorerScope(
        source: source,
        devices: .all,
        filter: ViewerExplorerFilter()
      ),
      materialization: ViewerExplorerMaterializationSnapshot(
        source: source,
        generation: 1,
        recordingID: 1,
        deviceSessionIDsByLogicalID: [:]
      )
    )

    store.rejectNextQuerySynchronously()
    store.completeNextRelease(.success(()))
    await waitUntilExplorer {
      store.queryRequestCount == 1 && coordinator.pendingWorkCount == 0
    }
    XCTAssertEqual(coordinator.state, .loading(.scopeReplacement))
    XCTAssertEqual(store.pageRequestCount, 0)
    XCTAssertEqual(store.gapRequestCount, 0)
    XCTAssertTrue(model.timelineRows.isEmpty)
    XCTAssertTrue(model.gapRows.isEmpty)

    _ = coordinator.refresh()
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 2 }
    store.rejectNextPageSynchronously()
    store.rejectNextGapsSynchronously()
    store.completeNextQuery(.success(querySnapshot))
    await waitUntilExplorer {
      store.pageRequestCount == 1 && store.gapRequestCount == 1
        && coordinator.pendingWorkCount == 0
    }
    XCTAssertEqual(coordinator.state, .loading(.refresh))
    XCTAssertTrue(model.timelineRows.isEmpty)
    XCTAssertTrue(model.gapRows.isEmpty)

    _ = coordinator.refresh()
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { store.queryRequestCount == 3 }
    store.completeNextQuery(.success(querySnapshot))
    await waitUntilExplorer { store.pageRequestCount == 2 && store.gapRequestCount == 2 }
    store.completeNextPage(
      .success(ViewerEventPage(rows: [], nextCursor: nil, previousCursor: nil))
    )
    store.completeNextGaps(
      .success(ViewerGapPage(rows: [], nextCursor: nil, previousCursor: nil))
    )
    await waitUntilExplorer { coordinator.state == .ready(.refresh) }
    await coordinator.waitForIdle().value
    XCTAssertEqual(coordinator.pendingWorkCount, 0)
  }

  @MainActor
  func testBlockedLiveEvaluationJoinsAfterSealWithoutLatePresentation() async throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let source = ViewerExplorerSource.current(runtimeLogicalID: runtimeLogicalID)
    let context = try makeObservationContext(
      connectionID: connectionID,
      displayName: "Cancellation App"
    )
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: makeObservationEnvelope(
        content: .object(["message": .string("cancel-live-secret")]),
        createdAt: Date(timeIntervalSince1970: 1),
        sessionEpoch: SessionEpoch(),
        sequence: 1
      ),
      viewerWallMilliseconds: 1_000,
      viewerMonotonicNanoseconds: 1_000,
      deterministicEventBytes: 128,
      initialDisposition: .buffered
    )
    let live = ExplorerLiveObservationSpy(
      snapshot: ViewerLiveProjectionSnapshot(
        runtimeLogicalID: runtimeLogicalID,
        generation: 1,
        events: [
          ViewerLiveEventSnapshot(
            observation: observation,
            laterDisposition: nil,
            durableState: .pending,
            hasPresentationConflict: false,
            hasGap: false,
            hasDrop: false,
            sessionEnded: false
          )
        ],
        sessions: [],
        gaps: ViewerLiveGapSnapshot(
          ingressOverflowCount: 0,
          windowOverflowCount: 0,
          residentConflictCount: 0,
          diagnosticLossCount: 0,
          storeUnavailableCount: 0,
          storeRecoveryCount: 0,
          storeUnavailable: false
        ),
        accountedEventBytes: ViewerLiveProjectionLimits.fixedEntryOverheadBytes + 128
      )
    )
    let store = ExplorerStoreDriverSpy()
    let evaluationQueue = DispatchQueue(label: "ViewerFoundationTests.blocked-live-cleanup")
    let evaluationClock = BlockingViewerMonotonicClock()
    let model = ViewerEventExplorerModel(runtimeLogicalID: runtimeLogicalID)
    let coordinator = ViewerEventExplorerCoordinator(
      model: model,
      store: store.driver,
      live: live,
      evaluationQueue: evaluationQueue,
      evaluator: ViewerLiveEventEvaluator(nowNanoseconds: { evaluationClock.now() })
    )
    let presentationCount = LockedTestCounter()
    coordinator.setPresentationHandler { presentationCount.increment() }

    _ = try coordinator.replaceScope(
      ViewerExplorerScope(
        source: source,
        devices: .all,
        filter: ViewerExplorerFilter()
      ),
      materialization: ViewerExplorerMaterializationSnapshot(
        source: source,
        generation: 1,
        recordingID: nil,
        deviceSessionIDsByLogicalID: [:]
      )
    )
    store.completeNextRelease(.success(()))
    await waitUntilExplorer { evaluationClock.isBlocked }
    XCTAssertEqual(live.snapshotRequestCount, 1)
    XCTAssertEqual(coordinator.pendingWorkCount, 1)

    coordinator.setPresentationHandler {}
    model.setRefreshHandler { _, _ in }
    model.sealAndClear()
    coordinator.cancelActiveWork()
    let presentationCountAtSeal = presentationCount.value
    let cleanup = coordinator.waitForIdle()
    XCTAssertEqual(coordinator.pendingWorkCount, 1)
    evaluationClock.release()
    await cleanup.value

    XCTAssertEqual(coordinator.pendingWorkCount, 0)
    XCTAssertEqual(presentationCount.value, presentationCountAtSeal)
    XCTAssertTrue(model.timelineRows.isEmpty)
    XCTAssertTrue(model.recordingRows.isEmpty)
    XCTAssertNil(model.pendingRefreshSignal)
    XCTAssertFalse(String(reflecting: coordinator).contains("blocked-live-cleanup"))
  }

  @MainActor
  func testRendererRegistryPreparesBoundedRawTreeLogTableAndNumericFallbacks() throws {
    var genericObject: [String: Any] = [:]
    for index in 0..<129 { genericObject[String(format: "key-%03d", index)] = index }
    genericObject["payload"] = String(repeating: "é", count: 33_000)
    let genericData = try JSONSerialization.data(
      withJSONObject: genericObject,
      options: [.sortedKeys]
    )
    let genericDetail = makeRendererDetail(
      rowID: 1,
      eventType: "custom.generic",
      content: genericData
    )
    let model = ViewerEventInspectorModel(runtimeLogicalID: UUID())
    let genericRequest = try model.select(
      detail: genericDetail,
      identity: .durable(rowID: 1)
    )
    XCTAssertEqual(genericRequest.rendererKind, .genericJSON)
    let genericResult = ViewerRendererPreparer().prepare(genericRequest)
    XCTAssertTrue(model.apply(genericResult))
    XCTAssertEqual(genericResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(genericResult.preparation.generic.prettyState, .prepared)
    XCTAssertLessThanOrEqual(
      genericResult.preparation.generic.prettyText?.utf8.count ?? .max,
      ViewerJSONInspectionLimits.maximumPrettyOutputBytes
    )
    XCTAssertGreaterThan(genericResult.preparation.generic.rawChunkCount, 1)
    var reconstructed = Data()
    for index in 0..<genericResult.preparation.generic.rawChunkCount {
      let chunk = try model.rawChunk(at: index)
      XCTAssertLessThanOrEqual(chunk.byteRange.count, ViewerJSONInspectionLimits.rawChunkBytes)
      reconstructed.append(Data(chunk.text.utf8))
      XCTAssertLessThanOrEqual(
        chunk.focusedAccessibilityText.utf8.count,
        ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
      )
    }
    XCTAssertEqual(reconstructed, genericData)

    var tree = try XCTUnwrap(genericResult.preparation.generic.treeState)
    let firstChildren = try tree.expand(nodeID: 0, offset: 0, data: genericData)
    XCTAssertEqual(firstChildren.count, ViewerJSONInspectionLimits.maximumTreeChildrenPerExpansion)
    XCTAssertEqual(tree.nodes.first?.nextChildOffset, 128)
    let remainingChildren = try tree.expand(nodeID: 0, offset: 128, data: genericData)
    XCTAssertEqual(remainingChildren.count, 2)
    XCTAssertEqual(tree.nodes.count, 131)
    XCTAssertLessThanOrEqual(tree.nodes.count, ViewerJSONInspectionLimits.maximumTreeNodes)
    XCTAssertLessThanOrEqual(
      tree.derivedTextBytes,
      ViewerJSONInspectionLimits.maximumTreeDerivedTextBytes
    )
    XCTAssertTrue(
      tree.nodes.allSatisfy {
        $0.preview.utf8.count <= ViewerJSONInspectionLimits.maximumTreePreviewBytes
          && $0.valueRange.upperBound <= genericData.count
      }
    )
    XCTAssertLessThanOrEqual(
      try tree.focusedAccessibilityText(nodeID: 1, data: genericData).utf8.count,
      ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
    )

    let unsafeMessage = "line\n\u{202E}unsafe " + String(repeating: "x", count: 70_000)
    let logData = try JSONSerialization.data(
      withJSONObject: ["message": unsafeMessage],
      options: [.sortedKeys]
    )
    let logRequest = try model.select(
      detail: makeRendererDetail(rowID: 2, eventType: "log.network", content: logData),
      identity: .durable(rowID: 2)
    )
    XCTAssertEqual(logRequest.rendererKind, .log)
    let logResult = ViewerRendererPreparer().prepare(logRequest)
    guard case .log(let log)? = logResult.preparation.specialized else {
      return XCTFail("Expected bounded log preparation")
    }
    let logText = log.chunks.joined()
    XCTAssertEqual(logResult.preparation.presentedKind, .log)
    XCTAssertTrue(logText.contains("<U+000A>"))
    XCTAssertTrue(logText.contains("<U+202E>"))
    XCTAssertTrue(logText.hasPrefix("⟦"))
    XCTAssertTrue(logText.hasSuffix("…⟧"))
    XCTAssertTrue(log.chunks.allSatisfy { $0.utf8.count <= ViewerLogPreparation.chunkBytes })
    XCTAssertLessThanOrEqual(log.derivedTextBytes, ViewerLogPreparation.maximumOutputBytes)
    XCTAssertLessThanOrEqual(
      log.focusedAccessibilityText.utf8.count,
      ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
    )

    var tableObject: [String: Any] = [
      "boolean": true,
      "control": "line\n\u{202E}value",
      "null": NSNull(),
      "real": 1.5,
      "string": "value",
    ]
    for index in 0..<129 { tableObject[String(format: "field-%03d", index)] = index }
    let tableData = try JSONSerialization.data(
      withJSONObject: tableObject,
      options: [.sortedKeys]
    )
    let tableRequest = try model.select(
      detail: makeRendererDetail(rowID: 3, eventType: "table.metrics", content: tableData),
      identity: .durable(rowID: 3)
    )
    let tableResult = ViewerRendererPreparer().prepare(tableRequest)
    guard case .table(let table)? = tableResult.preparation.specialized else {
      return XCTFail("Expected bounded table preparation")
    }
    XCTAssertEqual(table.rows.count, ViewerTablePreparation.maximumRetainedRows)
    XCTAssertEqual(try table.page(offset: 0).count, ViewerTablePreparation.pageRows)
    XCTAssertEqual(try table.page(offset: 64).count, ViewerTablePreparation.pageRows)
    XCTAssertTrue(table.hasMore)
    XCTAssertEqual(table.scannedEntryCount, 134)
    XCTAssertLessThanOrEqual(
      table.derivedTextBytes,
      ViewerTablePreparation.maximumDerivedTextBytes
    )
    XCTAssertTrue(
      table.rows.allSatisfy {
        $0.keyPreview.utf8.count <= ViewerTablePreparation.maximumKeyPreviewBytes
          && $0.valuePreview.utf8.count <= ViewerTablePreparation.maximumValuePreviewBytes
          && $0.focusedAccessibilityText.utf8.count
            <= ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
      }
    )
    XCTAssertTrue(table.rows.map(\.valuePreview).joined().contains("<U+202E>"))

    let numericObject = Dictionary(uniqueKeysWithValues: (0..<8).map { ("v\($0)", $0) })
    let numericData = try JSONSerialization.data(
      withJSONObject: Array(repeating: numericObject, count: 201),
      options: [.sortedKeys]
    )
    let numericRequest = try model.select(
      detail: makeRendererDetail(rowID: 4, eventType: "chart.metrics", content: numericData),
      identity: .durable(rowID: 4)
    )
    let numericResult = ViewerRendererPreparer().prepare(numericRequest)
    guard case .numeric(let numeric)? = numericResult.preparation.specialized else {
      return XCTFail("Expected bounded numeric preparation")
    }
    XCTAssertLessThanOrEqual(numeric.fields.count, ViewerNumericPreparation.maximumFields)
    XCTAssertEqual(numeric.points.count, ViewerNumericPreparation.maximumPoints)
    XCTAssertEqual(numeric.scannedRowCount, ViewerNumericPreparation.maximumRows)
    XCTAssertTrue(numeric.hasMore)
    XCTAssertTrue(numeric.points.allSatisfy { $0.value.isFinite })

    let timelineRequest = try model.select(
      detail: makeRendererDetail(
        rowID: 7,
        eventType: "timeline.state",
        content: Data("{\"state\":true}".utf8)
      ),
      identity: .durable(rowID: 7)
    )
    let timelineResult = ViewerRendererPreparer().prepare(timelineRequest)
    guard case .timeline(let timeline)? = timelineResult.preparation.specialized else {
      return XCTFail("Expected metadata-only timeline preparation")
    }
    XCTAssertEqual(timeline.eventType, "timeline.state")
    XCTAssertEqual(timeline.direction, "appToViewer")
    XCTAssertEqual(timeline.disposition, "buffered")

    let incompatibleData = try JSONSerialization.data(withJSONObject: ["value": 1])
    let incompatibleRequest = try model.select(
      detail: makeRendererDetail(
        rowID: 5,
        eventType: "log.incompatible",
        content: incompatibleData
      ),
      identity: .durable(rowID: 5)
    )
    let incompatibleResult = ViewerRendererPreparer().prepare(incompatibleRequest)
    XCTAssertEqual(incompatibleResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(incompatibleResult.preparation.fallbackReason, .incompatibleShape)
    XCTAssertEqual(
      incompatibleResult.preparation.fallbackGuidance,
      ViewerRendererFallbackReason.guidance
    )

    let cancelledResult = ViewerRendererPreparer().prepare(logRequest, isCancelled: { true })
    XCTAssertEqual(cancelledResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(cancelledResult.preparation.fallbackReason, .cancelled)
    let cancelledTableResult = ViewerRendererPreparer().prepare(
      tableRequest,
      isCancelled: { true }
    )
    XCTAssertEqual(cancelledTableResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(cancelledTableResult.preparation.fallbackReason, .cancelled)
    let deadlineClock = SteppingNanosecondClock(
      values: [0, 100_000_000, 200_000_000, 300_000_000, 400_000_000, 500_000_000]
    )
    let deadlineResult = ViewerRendererPreparer(
      nowNanoseconds: { deadlineClock.now() }
    ).prepare(logRequest)
    XCTAssertEqual(deadlineResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(deadlineResult.preparation.fallbackReason, .refineRequired)
    let tableDeadlineClock = SteppingNanosecondClock(
      values: [
        0, ViewerJSONInspectionLimits.deadlineNanoseconds,
        0, ViewerJSONInspectionLimits.deadlineNanoseconds,
        0, ViewerJSONInspectionLimits.deadlineNanoseconds,
      ]
    )
    let tableDeadlineResult = ViewerRendererPreparer(
      nowNanoseconds: { tableDeadlineClock.now() }
    ).prepare(tableRequest)
    XCTAssertEqual(tableDeadlineResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(tableDeadlineResult.preparation.fallbackReason, .refineRequired)

    let oversizedLogData = try JSONSerialization.data(
      withJSONObject: String(repeating: "x", count: ViewerLogPreparation.maximumInputBytes + 1),
      options: [.fragmentsAllowed]
    )
    let oversizedLogRequest = try model.select(
      detail: makeRendererDetail(
        rowID: 6,
        eventType: "log.oversized",
        content: oversizedLogData
      ),
      identity: .durable(rowID: 6)
    )
    let oversizedLogResult = ViewerRendererPreparer().prepare(oversizedLogRequest)
    XCTAssertEqual(oversizedLogResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(oversizedLogResult.preparation.fallbackReason, .inputTooLarge)
    XCTAssertEqual(oversizedLogResult.preparation.generic.prettyState, .chunkedRawOnly)
    let diagnostics = [
      String(describing: genericRequest),
      String(reflecting: logResult.preparation),
      String(describing: log),
      String(reflecting: table),
      String(describing: numeric),
      String(reflecting: model),
    ].joined()
    XCTAssertFalse(diagnostics.contains("unsafe"))
    XCTAssertFalse(diagnostics.contains("payload"))
    XCTAssertTrue(Mirror(reflecting: model).children.isEmpty)
  }

  @MainActor
  func testRendererExtremeValidatedShapesRemainBounded() throws {
    let model = ViewerEventInspectorModel(runtimeLogicalID: UUID())
    let preparer = ViewerRendererPreparer(nowNanoseconds: { 0 })

    let depth = 128
    let depthData = Data(
      (String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth))
        .utf8
    )
    let depthRequest = try model.select(
      detail: makeRendererDetail(rowID: 20, eventType: "custom.depth", content: depthData),
      identity: .durable(rowID: 20)
    )
    let depthResult = preparer.prepare(depthRequest)
    XCTAssertEqual(depthResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(depthResult.preparation.generic.prettyState, .prepared)
    XCTAssertEqual(depthResult.preparation.generic.treeState?.nodes.count, 1)

    let repeatedEntry = Array("\"a\":0".utf8)
    var hundredThousandEntries = Data()
    hundredThousandEntries.reserveCapacity(600_001)
    hundredThousandEntries.append(0x7B)
    for index in 0..<100_000 {
      if index > 0 { hundredThousandEntries.append(0x2C) }
      hundredThousandEntries.append(contentsOf: repeatedEntry)
    }
    hundredThousandEntries.append(0x7D)
    let entryRequest = try model.select(
      detail: makeRendererDetail(
        rowID: 21,
        eventType: "table.maximum-entries",
        content: hundredThousandEntries
      ),
      identity: .durable(rowID: 21)
    )
    let entryResult = preparer.prepare(entryRequest)
    guard case .table(let entryTable)? = entryResult.preparation.specialized else {
      return XCTFail("Expected bounded table preparation for the 100,000-entry fixture")
    }
    XCTAssertEqual(entryTable.rows.count, ViewerTablePreparation.maximumRetainedRows)
    XCTAssertEqual(entryTable.scannedEntryCount, 4_096)
    XCTAssertTrue(entryTable.hasMore)
    XCTAssertLessThanOrEqual(
      entryTable.derivedTextBytes,
      ViewerTablePreparation.maximumDerivedTextBytes
    )

    let oneMiB = 1 * 1_024 * 1_024
    var maximumKeyData = Data("{\"".utf8)
    maximumKeyData.append(Data(repeating: 0x61, count: oneMiB))
    maximumKeyData.append(Data("\":0}".utf8))
    let keyRequest = try model.select(
      detail: makeRendererDetail(
        rowID: 22,
        eventType: "table.maximum-key",
        content: maximumKeyData
      ),
      identity: .durable(rowID: 22)
    )
    let keyResult = preparer.prepare(keyRequest)
    XCTAssertEqual(keyResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(keyResult.preparation.fallbackReason, .inputTooLarge)
    var keyTree = try XCTUnwrap(keyResult.preparation.generic.treeState)
    let keyNodes = try keyTree.expand(nodeID: 0, offset: 0, data: maximumKeyData)
    let keyNode = try XCTUnwrap(keyNodes.first)
    XCTAssertEqual(keyNode.keyRange?.count, oneMiB + 2)
    XCTAssertLessThanOrEqual(
      try keyTree.focusedAccessibilityText(nodeID: keyNode.id, data: maximumKeyData).utf8.count,
      ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
    )

    var maximumMessageData = Data("{\"message\":\"".utf8)
    maximumMessageData.append(Data(repeating: 0x78, count: oneMiB))
    maximumMessageData.append(Data("\"}".utf8))
    let messageRequest = try model.select(
      detail: makeRendererDetail(
        rowID: 23,
        eventType: "log.maximum-message",
        content: maximumMessageData
      ),
      identity: .durable(rowID: 23)
    )
    let messageResult = preparer.prepare(messageRequest)
    XCTAssertEqual(messageResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(messageResult.preparation.fallbackReason, .inputTooLarge)
    XCTAssertEqual(messageResult.preparation.generic.prettyState, .chunkedRawOnly)

    let maximumEventBytes = ViewerJSONInspectionLimits.maximumCanonicalBytes
    var maximumEventData = Data([0x22])
    maximumEventData.reserveCapacity(maximumEventBytes)
    maximumEventData.append(Data(repeating: 0x78, count: maximumEventBytes - 2))
    maximumEventData.append(0x22)
    let maximumRequest = try model.select(
      detail: makeRendererDetail(
        rowID: 24,
        eventType: "custom.maximum-event",
        content: maximumEventData
      ),
      identity: .durable(rowID: 24)
    )
    let maximumResult = preparer.prepare(maximumRequest)
    XCTAssertTrue(model.apply(maximumResult))
    XCTAssertEqual(model.canonicalBuffer?.contentByteCount, maximumEventBytes)
    XCTAssertEqual(maximumResult.preparation.presentedKind, .genericJSON)
    XCTAssertEqual(maximumResult.preparation.generic.prettyState, .chunkedRawOnly)
    XCTAssertEqual(maximumResult.preparation.generic.rawChunkCount, 256)
    XCTAssertEqual(maximumResult.preparation.generic.treeState?.nodes.count, 1)
    XCTAssertEqual(try model.rawChunk(at: 0).byteRange.count, 64 * 1_024)
    XCTAssertEqual(try model.rawChunk(at: 255).byteRange.count, 64 * 1_024)
    XCTAssertLessThanOrEqual(
      try model.rawChunk(at: 255).focusedAccessibilityText.utf8.count,
      ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
    )

    let diagnostics = [
      String(reflecting: depthResult.preparation),
      String(reflecting: entryTable),
      String(reflecting: keyResult.preparation),
      String(reflecting: messageResult.preparation),
      String(reflecting: maximumResult.preparation),
    ].joined()
    XCTAssertFalse(diagnostics.contains(String(repeating: "x", count: 32)))
    XCTAssertTrue(Mirror(reflecting: maximumResult.preparation).children.isEmpty)
  }

  @MainActor
  func testInspectorPreparationCancelsReplacedGenerationAndClearsCanonicalBuffer() async throws {
    let runtimeLogicalID = UUID()
    let model = ViewerEventInspectorModel(runtimeLogicalID: runtimeLogicalID)
    let queue = DispatchQueue(label: "com.nearwire.viewer.tests.renderer-replacement")
    let gate = DispatchSemaphore(value: 0)
    queue.async { gate.wait() }
    let service = ViewerRendererPreparationService(queue: queue)
    let results = LockedRendererResultCollection()
    let completed = expectation(description: "All rapid renderer generations completed")
    completed.expectedFulfillmentCount = 64
    var requests: [(request: ViewerRendererPreparationRequest, data: Data)] = []
    for index in 0..<64 {
      let data = try JSONSerialization.data(
        withJSONObject: ["message": "selection-\(index)-secret"]
      )
      let rowID = Int64(index + 10)
      let request = try model.select(
        detail: makeRendererDetail(
          rowID: rowID,
          eventType: "log.selection",
          content: data
        ),
        identity: .durable(rowID: rowID)
      )
      requests.append((request, data))
      service.submit(request) { result in
        results.append(result)
        completed.fulfill()
      }
    }
    XCTAssertEqual(results.values.count, 63)
    XCTAssertEqual(service.pendingWorkCount, 1)
    XCTAssertEqual(service.retainedRequestLimit, 2)
    XCTAssertEqual(service.retainedRequestCountForTesting, 1)
    gate.signal()
    await fulfillment(of: [completed], timeout: 2)

    XCTAssertEqual(results.values.count, 64)
    for prior in requests.dropLast() {
      let result = try XCTUnwrap(results.values.first { $0.token == prior.request.token })
      XCTAssertEqual(result.preparation.fallbackReason, .cancelled)
      XCTAssertFalse(model.apply(result))
    }
    let latest = try XCTUnwrap(requests.last)
    let latestResult = try XCTUnwrap(
      results.values.first { $0.token == latest.request.token }
    )
    XCTAssertTrue(model.apply(latestResult))
    XCTAssertEqual(model.canonicalBuffer?.content, latest.data)
    XCTAssertEqual(model.selectedIdentity, latest.request.token.eventIdentity)
    XCTAssertEqual(model.preparation?.presentedKind, .log)
    XCTAssertLessThanOrEqual(
      model.preparation?.generic.rawChunkCount ?? .max,
      1
    )
    model.clear()
    XCTAssertNil(model.canonicalBuffer)
    XCTAssertNil(model.preparation)
    XCTAssertNil(model.selectedIdentity)
    XCTAssertFalse(model.apply(latestResult))
  }

  @MainActor
  func testExplorerHundredThousandRendererReplacementsCancelBeforeDeliveryClaim() async throws {
    let queue = DispatchQueue(label: "ViewerFoundationTests.renderer-controller-replacements")
    let workerEntered = DispatchSemaphore(value: 0)
    let workerRelease = DispatchSemaphore(value: 0)
    queue.async {
      workerEntered.signal()
      workerRelease.wait()
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 1), .success)

    let runtimeLogicalID = UUID()
    let rendererService = ViewerRendererPreparationService(queue: queue)
    let deliveryClaims = LockedTestCounter()
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: ViewerStoreExplorerGateway(),
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      ),
      rendererService: rendererService,
      rendererDeliveryClaimed: { deliveryClaims.increment() }
    )
    let request = try controller.inspector.select(
      detail: makeRendererDetail(
        rowID: 640,
        eventType: "log.replacement",
        content: Data(#"{"message":"renderer-replacement-secret"}"#.utf8)
      ),
      identity: .durable(rowID: 640)
    )

    for _ in 0..<100_000 { controller.submitRendererForTesting(request) }

    XCTAssertEqual(deliveryClaims.value, 0)
    XCTAssertEqual(rendererService.retainedRequestCountForTesting, 1)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 1)
    let cleanup = controller.sealAndClear()
    let cleanupCompletions = LockedTestCounter()
    Task {
      await cleanup.value
      cleanupCompletions.increment()
    }
    await Task.yield()
    XCTAssertEqual(cleanupCompletions.value, 0)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 1)

    workerRelease.signal()
    await cleanup.value
    for _ in 0..<100 where cleanupCompletions.value == 0 { await Task.yield() }
    XCTAssertEqual(cleanupCompletions.value, 1)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(deliveryClaims.value, 0)
    XCTAssertEqual(rendererService.retainedRequestCountForTesting, 0)
    XCTAssertNil(controller.inspector.canonicalBuffer)
    XCTAssertNil(controller.inspector.preparation)
  }

  @MainActor
  func testExplorerBlockedMainActorRetainsBoundedClaimedRendererResults() async throws {
    let runtimeLogicalID = UUID()
    let deliveryClaims = LockedTestCounter()
    let deliveryClaimed = DispatchSemaphore(value: 0)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: ViewerStoreExplorerGateway(),
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      ),
      rendererService: ViewerRendererPreparationService(
        queue: DispatchQueue(label: "ViewerFoundationTests.renderer-blocked-main-actor")
      ),
      rendererDeliveryClaimed: {
        deliveryClaims.increment()
        deliveryClaimed.signal()
      }
    )
    let smallContent = Data(#"{"message":"bounded"}"#.utf8)

    for index in 0..<255 {
      let rowID = Int64(700 + index)
      let request = try controller.inspector.select(
        detail: makeRendererDetail(
          rowID: rowID,
          eventType: "log.blocked-main-actor",
          content: smallContent
        ),
        identity: .durable(rowID: rowID)
      )
      controller.submitRendererForTesting(request)
      XCTAssertEqual(deliveryClaimed.wait(timeout: .now() + 2), .success)
      XCTAssertLessThanOrEqual(
        controller.rendererDeliveryRetainedResultCountForTesting,
        controller.rendererDeliveryMaximumRetainedResultCountForTesting
      )
      XCTAssertLessThanOrEqual(controller.pendingCleanupWorkCount, 2)
    }

    let maximumEventBytes = ViewerJSONInspectionLimits.maximumCanonicalBytes
    var maximumContent = Data([0x22])
    maximumContent.reserveCapacity(maximumEventBytes)
    maximumContent.append(Data(repeating: 0x78, count: maximumEventBytes - 2))
    maximumContent.append(0x22)
    let maximumRowID: Int64 = 955
    let maximumRequest = try controller.inspector.select(
      detail: makeRendererDetail(
        rowID: maximumRowID,
        eventType: "custom.blocked-main-actor-maximum",
        content: maximumContent
      ),
      identity: .durable(rowID: maximumRowID)
    )
    controller.submitRendererForTesting(maximumRequest)
    XCTAssertEqual(deliveryClaimed.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(deliveryClaims.value, 256)
    XCTAssertEqual(controller.rendererDeliveryMaximumRetainedResultCountForTesting, 2)
    XCTAssertLessThanOrEqual(controller.rendererDeliveryRetainedResultCountForTesting, 2)
    XCTAssertLessThanOrEqual(controller.pendingCleanupWorkCount, 2)

    for _ in 0..<1_000 where controller.pendingCleanupWorkCount != 0 { await Task.yield() }
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(controller.inspector.canonicalBuffer?.contentByteCount, maximumEventBytes)
    XCTAssertNotNil(controller.inspector.preparation)

    await controller.sealAndClear().value
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(controller.rendererDeliveryRetainedResultCountForTesting, 0)
    XCTAssertNil(controller.inspector.canonicalBuffer)
    XCTAssertNil(controller.inspector.preparation)
  }

  @MainActor
  func testExplorerCleanupJoinsClaimedContentBearingRendererDelivery() async throws {
    let runtimeLogicalID = UUID()
    let deliveryGate = BlockingViewerOperationGate()
    let rendererService = ViewerRendererPreparationService(
      queue: DispatchQueue(label: "ViewerFoundationTests.renderer-claimed-delivery")
    )
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: ViewerStoreExplorerGateway(),
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      ),
      rendererService: rendererService,
      rendererDeliveryClaimed: { deliveryGate.run() }
    )
    let request = try controller.inspector.select(
      detail: makeRendererDetail(
        rowID: 641,
        eventType: "log.claimed",
        content: Data(#"{"message":"claimed-renderer-secret"}"#.utf8)
      ),
      identity: .durable(rowID: 641)
    )

    controller.submitRendererForTesting(request)
    XCTAssertEqual(deliveryGate.waitUntilEntered(), .success)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 2)
    let cleanup = controller.sealAndClear()
    let cleanupCompletions = LockedTestCounter()
    Task {
      await cleanup.value
      cleanupCompletions.increment()
    }
    await Task.yield()
    XCTAssertEqual(cleanupCompletions.value, 0)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 1)
    XCTAssertNil(controller.inspector.canonicalBuffer)
    XCTAssertNil(controller.inspector.preparation)

    deliveryGate.release()
    await cleanup.value
    for _ in 0..<100 where cleanupCompletions.value == 0 { await Task.yield() }
    XCTAssertEqual(cleanupCompletions.value, 1)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(rendererService.retainedRequestCountForTesting, 0)
    XCTAssertNil(controller.inspector.canonicalBuffer)
    XCTAssertNil(controller.inspector.preparation)
  }

  @MainActor
  func testBlockedRendererAndComposerCleanupJoinsAndReleasesAllContent() async throws {
    let rendererQueue = DispatchQueue(label: "ViewerFoundationTests.blocked-renderer-cleanup")
    let rendererEntered = DispatchSemaphore(value: 0)
    let rendererGate = DispatchSemaphore(value: 0)
    rendererQueue.async {
      rendererEntered.signal()
      rendererGate.wait()
    }
    XCTAssertEqual(rendererEntered.wait(timeout: .now() + 1), .success)

    let inspector = ViewerEventInspectorModel(runtimeLogicalID: UUID())
    let rendererRequest = try inspector.select(
      detail: makeRendererDetail(
        rowID: 700,
        eventType: "log.cleanup",
        content: Data(#"{"message":"blocked-renderer-secret"}"#.utf8)
      ),
      identity: .durable(rowID: 700)
    )
    let rendererService = ViewerRendererPreparationService(queue: rendererQueue)
    let rendererResults = LockedRendererResultCollection()
    let rendererFinished = expectation(description: "Cancelled renderer completed")
    rendererService.submit(rendererRequest) { result in
      rendererResults.append(result)
      rendererFinished.fulfill()
    }
    XCTAssertEqual(rendererService.pendingWorkCount, 1)
    let rendererCleanup = rendererService.cancelAndWait()

    let composerQueue = DispatchQueue(label: "ViewerFoundationTests.blocked-composer-cleanup")
    let composerEntered = DispatchSemaphore(value: 0)
    let composerGate = DispatchSemaphore(value: 0)
    composerQueue.async {
      composerEntered.signal()
      composerGate.wait()
    }
    XCTAssertEqual(composerEntered.wait(timeout: .now() + 1), .success)

    let composer = try ViewerControlComposerModel(
      runtimeLogicalID: UUID(),
      activeLimits: .default
    )
    XCTAssertEqual(
      composer.replaceCharacters(
        field: .eventType,
        range: NSRange(location: 0, length: 0),
        replacement: "control.cleanup"
      ),
      .applied
    )
    XCTAssertEqual(
      composer.replaceCharacters(
        field: .content,
        range: NSRange(location: 0, length: 0),
        replacement: #"{"message":"blocked-composer-secret"}"#
      ),
      .applied
    )
    XCTAssertEqual(
      composer.replaceCharacters(
        field: .ttl,
        range: NSRange(location: 0, length: 0),
        replacement: "60000"
      ),
      .applied
    )
    let composerRequest = composer.makePreparationRequest()
    let composerService = ViewerComposerPreparationService(queue: composerQueue)
    let composerResults = LockedComposerResultCollection()
    let composerFinished = expectation(description: "Cancelled composer completed")
    composerService.submit(composerRequest) { result in
      composerResults.append(result)
      composerFinished.fulfill()
    }
    XCTAssertEqual(composerService.pendingWorkCount, 1)
    let composerCleanup = composerService.cancelAndWait()

    rendererGate.signal()
    composerGate.signal()
    async let rendererJoined: Void = rendererCleanup.value
    async let composerJoined: Void = composerCleanup.value
    _ = await (rendererJoined, composerJoined)
    await fulfillment(of: [rendererFinished, composerFinished], timeout: 1)

    XCTAssertEqual(rendererService.pendingWorkCount, 0)
    XCTAssertEqual(composerService.pendingWorkCount, 0)
    let rendererResult = try XCTUnwrap(rendererResults.values.first)
    XCTAssertEqual(rendererResult.preparation.fallbackReason, .cancelled)
    guard
      case .failure(let composerFailure, let diagnostics) =
        try XCTUnwrap(composerResults.values.first).outcome
    else { return XCTFail("Expected cancelled composer preparation") }
    XCTAssertEqual(composerFailure, .cancelled)
    XCTAssertEqual(diagnostics, ViewerComposerPreparationDiagnostics())

    inspector.clear()
    composer.clear()
    XCTAssertNil(inspector.canonicalBuffer)
    XCTAssertNil(inspector.preparation)
    XCTAssertThrowsError(try inspector.rawChunk(at: 0))
    XCTAssertEqual(composer.eventType.value, "")
    XCTAssertEqual(composer.content.value, "")
    XCTAssertEqual(composer.ttl.value, "")
    XCTAssertNil(composer.preparedEvent)
    XCTAssertFalse(inspector.apply(rendererResult))
    XCTAssertFalse(composer.apply(try XCTUnwrap(composerResults.values.first)))
    let diagnosticsText = [
      String(reflecting: rendererResult),
      String(reflecting: composerResults.values.first as Any),
      String(reflecting: ViewerAsyncWorkTracker()),
    ].joined()
    XCTAssertFalse(diagnosticsText.contains("blocked-renderer-secret"))
    XCTAssertFalse(diagnosticsText.contains("blocked-composer-secret"))
  }

  func testIncrementalTextBuffersEnforceEveryOperatorCapWithoutFullValueRescans() throws {
    var multibyte = ViewerIncrementalTextBuffer(
      maximumUTF8Bytes: 8,
      maximumUnicodeScalars: 4
    )
    XCTAssertEqual(
      multibyte.replaceCharacters(in: NSRange(location: 0, length: 0), with: "é🙂"),
      .applied
    )
    XCTAssertEqual(multibyte.utf8ByteCount, 6)
    XCTAssertEqual(multibyte.unicodeScalarCount, 2)
    XCTAssertEqual(multibyte.utf16Count, 3)
    XCTAssertEqual(
      multibyte.replaceCharacters(in: NSRange(location: 1, length: 2), with: "ab"),
      .applied
    )
    XCTAssertEqual(multibyte.value, "éab")
    XCTAssertEqual(multibyte.utf8ByteCount, 4)
    XCTAssertEqual(multibyte.unicodeScalarCount, 3)
    XCTAssertEqual(
      multibyte.replaceCharacters(in: NSRange(location: 3, length: 0), with: "🙂"),
      .applied
    )
    XCTAssertEqual(multibyte.utf8ByteCount, 8)
    XCTAssertEqual(multibyte.unicodeScalarCount, 4)
    let acceptedValue = multibyte.value
    XCTAssertEqual(
      multibyte.replaceCharacters(in: NSRange(location: 5, length: 0), with: "x"),
      .rejected(.byteLimit)
    )
    XCTAssertEqual(multibyte.value, acceptedValue)
    XCTAssertEqual(multibyte.diagnostics.appliedEditCount, 3)
    XCTAssertEqual(multibyte.diagnostics.rejectedEditCount, 1)
    XCTAssertEqual(multibyte.diagnostics.storageCopyCount, 3)
    XCTAssertEqual(multibyte.diagnostics.fullValueRescanCount, 0)

    var rapid = ViewerIncrementalTextBuffer(maximumUTF8Bytes: 1)
    for index in 0..<10_000 {
      let range = NSRange(location: 0, length: rapid.utf16Count)
      XCTAssertEqual(
        rapid.replaceCharacters(in: range, with: index.isMultiple(of: 2) ? "a" : "b"),
        .applied
      )
    }
    XCTAssertEqual(rapid.utf8ByteCount, 1)
    XCTAssertEqual(rapid.diagnostics.appliedEditCount, 10_000)
    XCTAssertEqual(rapid.diagnostics.storageCopyCount, 10_000)
    XCTAssertEqual(rapid.diagnostics.fullValueRescanCount, 0)

    let expandedLimits = try EventValidationLimits(
      maximumEncodedContentBytes: 4_194_304,
      maximumEncodedModelBytes: 16_842_752,
      maximumTTLMilliseconds: 604_800_000
    )
    let composerLimits = try ViewerComposerTextLimits(activeLimits: expandedLimits)
    XCTAssertEqual(composerLimits.eventTypeBytes, 128)
    XCTAssertEqual(composerLimits.contentBytes, 4_177_920)
    XCTAssertEqual(composerLimits.ttlBytes, 9)
    let contentLimited = try ViewerComposerTextLimits(
      activeLimits: EventValidationLimits(
        maximumEncodedContentBytes: 1_048_576,
        maximumEncodedModelBytes: 134_217_728
      )
    )
    XCTAssertEqual(contentLimited.contentBytes, 1_048_576)
    let hardCapped = try ViewerComposerTextLimits(
      activeLimits: EventValidationLimits(
        maximumEncodedContentBytes: 16_777_216,
        maximumEncodedModelBytes: 134_217_728
      )
    )
    XCTAssertEqual(
      hardCapped.contentBytes,
      (ViewerComposerTextLimits.hardModelBytes - ViewerComposerTextLimits.modelReserveBytes) / 4
    )

    var ttl = ViewerIncrementalTextBuffer(
      maximumUTF8Bytes: 9,
      characterPolicy: .asciiDigits
    )
    XCTAssertEqual(
      ttl.replaceCharacters(in: NSRange(location: 0, length: 0), with: "604800000"),
      .applied
    )
    XCTAssertEqual(
      try ViewerTTLTextParser.parse(
        ttl.value,
        maximumMilliseconds: expandedLimits.maximumTTLMilliseconds
      ),
      604_800_000
    )
    XCTAssertEqual(
      ttl.replaceCharacters(in: NSRange(location: 9, length: 0), with: "+"),
      .rejected(.unsupportedCharacter)
    )
    XCTAssertThrowsError(
      try ViewerTTLTextParser.parse(" 1", maximumMilliseconds: 604_800_000)
    ) { error in
      XCTAssertEqual(error as? ViewerTTLValidationError, .invalidSyntax)
    }
    for invalidSyntax in ["", "+1", "-1", "1 ", "18446744073709551616"] {
      XCTAssertThrowsError(
        try ViewerTTLTextParser.parse(
          invalidSyntax,
          maximumMilliseconds: 604_800_000
        )
      ) { error in
        XCTAssertEqual(error as? ViewerTTLValidationError, .invalidSyntax)
      }
    }
    XCTAssertThrowsError(
      try ViewerTTLTextParser.parse("0", maximumMilliseconds: 604_800_000)
    ) { error in
      XCTAssertEqual(error as? ViewerTTLValidationError, .outOfRange)
    }
    XCTAssertEqual(
      try ViewerTTLTextParser.parse("1", maximumMilliseconds: 604_800_000),
      1
    )
    XCTAssertThrowsError(
      try ViewerTTLTextParser.parse("1234567890", maximumMilliseconds: 604_800_000)
    ) { error in
      XCTAssertEqual(error as? ViewerTTLValidationError, .invalidSyntax)
    }
    XCTAssertThrowsError(
      try ViewerTTLTextParser.parse("604800001", maximumMilliseconds: 604_800_000)
    ) { error in
      XCTAssertEqual(error as? ViewerTTLValidationError, .outOfRange)
    }

    var operators = ViewerExplorerOperatorTextBuffers()
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .search,
        range: NSRange(location: 0, length: 0),
        replacement: String(repeating: "s", count: 512)
      ),
      .applied
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .search,
        range: NSRange(location: 512, length: 0),
        replacement: "x"
      ),
      .rejected(.byteLimit)
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .jsonPath,
        range: NSRange(location: 0, length: 0),
        replacement: String(repeating: "p", count: 256)
      ),
      .applied
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .jsonComparison,
        range: NSRange(location: 0, length: 0),
        replacement: String(repeating: "v", count: 16 * 1_024)
      ),
      .applied
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .name,
        range: NSRange(location: 0, length: 0),
        replacement: String(repeating: "n", count: 80)
      ),
      .applied
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .name,
        range: NSRange(location: 80, length: 0),
        replacement: "x"
      ),
      .rejected(.scalarLimit)
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .name,
        range: NSRange(location: 0, length: 80),
        replacement: String(repeating: "é", count: 60)
      ),
      .applied
    )
    XCTAssertEqual(operators.name.utf8ByteCount, 120)
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .name,
        range: NSRange(location: 60, length: 0),
        replacement: "x"
      ),
      .rejected(.byteLimit)
    )
    XCTAssertEqual(
      operators.replaceCharacters(
        field: .note,
        range: NSRange(location: 0, length: 0),
        replacement: String(repeating: "🙂", count: 4_096)
      ),
      .applied
    )
    XCTAssertEqual(operators.note.utf8ByteCount, 16 * 1_024)
    XCTAssertEqual(operators.note.unicodeScalarCount, 4_096)
    XCTAssertEqual(operators.annotation.maximumUTF8Bytes, 16 * 1_024)
    XCTAssertEqual(operators.annotation.maximumUnicodeScalars, 4_096)
    XCTAssertEqual(operators.search.diagnostics.fullValueRescanCount, 0)
    XCTAssertEqual(operators.note.diagnostics.fullValueRescanCount, 0)
    XCTAssertTrue(Mirror(reflecting: operators).children.isEmpty)
  }

  func testComposerPreparerReportsBoundedFailuresWithoutEncodingInvalidInput() throws {
    let runtimeLogicalID = UUID()
    let limits = EventValidationLimits.default
    func request(
      generation: UInt64,
      type: String,
      content: String,
      ttl: String
    ) -> ViewerComposerPreparationRequest {
      ViewerComposerPreparationRequest(
        token: ViewerComposerGenerationToken(
          runtimeLogicalID: runtimeLogicalID,
          generation: generation
        ),
        input: ViewerComposerInputSnapshot(
          eventType: type,
          contentJSON: content,
          ttlText: ttl,
          priority: .normal,
          policy: .normal,
          activeLimits: limits
        )
      )
    }
    let preparer = ViewerComposerPreparer()

    let invalidJSON = preparer.prepare(
      request(generation: 1, type: "control.test", content: "{", ttl: "60000")
    )
    guard case .failure(let invalidJSONError, let invalidJSONDiagnostics) = invalidJSON.outcome
    else { return XCTFail("Expected invalid JSON") }
    XCTAssertEqual(invalidJSONError, .invalidContent)
    XCTAssertEqual(invalidJSONDiagnostics.inputCopyCount, 1)
    XCTAssertEqual(invalidJSONDiagnostics.contentTraversalCount, 1)
    XCTAssertEqual(invalidJSONDiagnostics.draftValidationCount, 0)
    XCTAssertEqual(invalidJSONDiagnostics.encodeCount, 0)

    let reserved = preparer.prepare(
      request(
        generation: 2,
        type: "nearwire.control",
        content: #"{"value":1}"#,
        ttl: "60000"
      )
    )
    guard case .failure(let reservedError, let reservedDiagnostics) = reserved.outcome else {
      return XCTFail("Expected reserved Event type rejection")
    }
    XCTAssertEqual(reservedError, .invalidEventType)
    XCTAssertEqual(reservedDiagnostics.contentTraversalCount, 1)
    XCTAssertEqual(reservedDiagnostics.draftValidationCount, 0)
    XCTAssertEqual(reservedDiagnostics.encodeCount, 0)

    let invalidTTL = preparer.prepare(
      request(generation: 3, type: "control.test", content: #"{"value":1}"#, ttl: "0")
    )
    guard case .failure(let ttlError, let ttlDiagnostics) = invalidTTL.outcome else {
      return XCTFail("Expected TTL rejection")
    }
    XCTAssertEqual(ttlError, .invalidTTL)
    XCTAssertEqual(ttlDiagnostics.contentTraversalCount, 1)
    XCTAssertEqual(ttlDiagnostics.draftValidationCount, 0)
    XCTAssertEqual(ttlDiagnostics.encodeCount, 0)

    let cancelled = preparer.prepare(
      request(generation: 4, type: "control.test", content: #"{"value":1}"#, ttl: "1"),
      isCancelled: { true }
    )
    guard case .failure(let cancellationError, let cancellationDiagnostics) = cancelled.outcome
    else { return XCTFail("Expected cancellation") }
    XCTAssertEqual(cancellationError, .cancelled)
    XCTAssertEqual(cancellationDiagnostics, ViewerComposerPreparationDiagnostics())
  }

  @MainActor
  func testComposerPreparationReplacesOneGenerationAndCountsOneSuccessfulPipeline()
    async throws
  {
    let model = try ViewerControlComposerModel(
      runtimeLogicalID: UUID(),
      activeLimits: .default
    )
    XCTAssertEqual(
      model.replaceCharacters(
        field: .eventType,
        range: NSRange(location: 0, length: 0),
        replacement: "control.test"
      ),
      .applied
    )
    XCTAssertEqual(
      model.replaceCharacters(
        field: .content,
        range: NSRange(location: 0, length: 0),
        replacement: #"{"secret":"first-composer-secret"}"#
      ),
      .applied
    )
    XCTAssertEqual(
      model.replaceCharacters(
        field: .ttl,
        range: NSRange(location: 0, length: 0),
        replacement: "60000"
      ),
      .applied
    )
    model.setPriority(.high)
    model.setPolicy(.keepLatest)
    let firstRequest = model.makePreparationRequest()

    let queue = DispatchQueue(label: "com.nearwire.viewer.tests.composer-replacement")
    let gate = DispatchSemaphore(value: 0)
    queue.async { gate.wait() }
    let service = ViewerComposerPreparationService(queue: queue)
    let results = LockedComposerResultCollection()
    let completed = expectation(description: "Both composer generations completed")
    completed.expectedFulfillmentCount = 2
    service.submit(firstRequest) { result in
      results.append(result)
      completed.fulfill()
    }

    XCTAssertEqual(
      model.replaceCharacters(
        field: .content,
        range: NSRange(location: 0, length: model.content.utf16Count),
        replacement: #"{"secret":"second-composer-secret"}"#
      ),
      .applied
    )
    let secondRequest = model.makePreparationRequest()
    service.submit(secondRequest) { result in
      results.append(result)
      completed.fulfill()
    }
    XCTAssertEqual(results.values.count, 1)
    XCTAssertEqual(service.pendingWorkCount, 1)
    XCTAssertEqual(service.retainedRequestLimit, 2)
    XCTAssertEqual(service.retainedRequestCountForTesting, 1)
    gate.signal()
    await fulfillment(of: [completed], timeout: 2)

    let firstResult = try XCTUnwrap(results.values.first { $0.token == firstRequest.token })
    let secondResult = try XCTUnwrap(results.values.first { $0.token == secondRequest.token })
    guard case .failure(let firstError, let firstDiagnostics) = firstResult.outcome else {
      return XCTFail("Expected replaced generation to cancel")
    }
    XCTAssertEqual(firstError, .cancelled)
    XCTAssertEqual(firstDiagnostics, ViewerComposerPreparationDiagnostics())
    XCTAssertFalse(model.apply(firstResult))

    guard case .success(let prepared, let diagnostics) = secondResult.outcome else {
      return XCTFail("Expected latest composer generation to succeed")
    }
    XCTAssertEqual(diagnostics.inputCopyCount, 1)
    XCTAssertEqual(diagnostics.contentTraversalCount, 1)
    XCTAssertEqual(diagnostics.draftValidationCount, 1)
    XCTAssertEqual(diagnostics.encodeCount, 1)
    XCTAssertEqual(prepared.draft.type.rawValue, "control.test")
    XCTAssertEqual(prepared.draft.priority, .high)
    XCTAssertEqual(prepared.draft.ttl.milliseconds, 60_000)
    XCTAssertEqual(prepared.policy, .keepLatest)
    XCTAssertEqual(
      String(describing: prepared.queuePolicy), "EventQueuePolicy.keepLatest(redacted)")
    XCTAssertLessThanOrEqual(
      prepared.deterministicEncodedByteCount,
      ViewerPreparedControlEvent.maximumEncodedBytes
    )
    XCTAssertTrue(model.apply(secondResult))
    XCTAssertEqual(
      model.preparedEvent?.deterministicEncodedByteCount, prepared.deterministicEncodedByteCount)

    let redacted = [
      String(describing: model),
      String(reflecting: firstRequest),
      String(reflecting: secondRequest.input),
      String(reflecting: secondResult),
      String(reflecting: prepared),
    ].joined()
    XCTAssertFalse(redacted.contains("first-composer-secret"))
    XCTAssertFalse(redacted.contains("second-composer-secret"))
    XCTAssertTrue(Mirror(reflecting: secondResult).children.isEmpty)

    model.clear()
    XCTAssertEqual(model.eventType.value, "")
    XCTAssertEqual(model.content.value, "")
    XCTAssertEqual(model.ttl.value, "")
    XCTAssertNil(model.preparedEvent)
    XCTAssertNil(model.preparationFailure)
    XCTAssertFalse(model.apply(secondResult))
  }

  @MainActor
  func testApplicationCreatesOneRuntimeBundlePerStartAndCleansFailedRuntimeBeforeRetry()
    async throws
  {
    let created = expectation(description: "A fresh runtime bundle was created")
    created.expectedFulfillmentCount = 2
    let capture = LockedRuntimeComponentCapture()
    let generations = ViewerManagerGenerationSource()
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: ViewerRuntimeDependencies(
        loadIdentity: { throw ViewerPairingCodeGenerationError() },
        resetTLSIdentity: {},
        resetAllIdentity: {},
        generatePairingCode: { try PairingCode("ABCDEF") },
        makeRuntimeComponents: { runtimeLogicalID in
          let components = ViewerRuntimeComponents.make(
            runtimeLogicalID: runtimeLogicalID,
            managerGeneration: generations.next()
          )
          capture.append(components)
          created.fulfill()
          return components
        }
      )
    )

    model.openWindow()
    await waitForStatus(.failed(.identityUnavailable), in: model)
    await waitUntilRuntimeCapture({ capture.count == 1 && capture.allLiveWindowsCleared })

    model.retry()
    await fulfillment(of: [created], timeout: 1)
    await waitForStatus(.failed(.identityUnavailable), in: model)
    await waitUntilRuntimeCapture({ capture.count == 2 && capture.allLiveWindowsCleared })

    XCTAssertEqual(capture.managerGenerations, [1, 2])
    XCTAssertEqual(Set(capture.runtimeLogicalIDs).count, 2)
    _ = await model.prepareForTermination()
    XCTAssertEqual(model.status, .stopped)
  }

  @MainActor
  func testTerminationJoinsBlockedExplorerCleanupAndFreshRuntimeHasNoPriorContent()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NearWire-presentation-cleanup-\(UUID().uuidString)",
      isDirectory: true
    )
    let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
    let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
    let firstCoordinator = try ViewerStoreCoordinator(
      paths: ViewerStorePaths(
        directory: firstDirectory,
        database: firstDirectory.appendingPathComponent("NearWire.sqlite")
      )
    )
    let secondCoordinator = try ViewerStoreCoordinator(
      paths: ViewerStorePaths(
        directory: secondDirectory,
        database: secondDirectory.appendingPathComponent("NearWire.sqlite")
      )
    )
    let blockedOperation = BlockingViewerOperationGate()
    let firstGateway = ViewerStoreExplorerGateway(
      operationExecutionGate: { blockedOperation.run() }
    )
    let secondGateway = ViewerStoreExplorerGateway()
    firstGateway.install(firstCoordinator)
    secondGateway.install(secondCoordinator)
    defer {
      blockedOperation.release()
      firstGateway.sealAndWait(originatingFrom: firstCoordinator)
      secondGateway.sealAndWait(originatingFrom: secondCoordinator)
      firstCoordinator.closeStorage()
      secondCoordinator.closeStorage()
      try? FileManager.default.removeItem(at: root)
    }

    let listeners = LockedListenerFactory([
      FakeViewerSecureListener(
        eventsOnStart: [.ready(port: 49_152), .serviceRegistered(exact: true)]
      ),
      FakeViewerSecureListener(
        eventsOnStart: [.ready(port: 49_153), .serviceRegistered(exact: true)]
      ),
    ])
    let pairingCodes = LockedPairingCodeSequence(["ABCDEF", "MNPQRS"])
    let generations = ViewerManagerGenerationSource()
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: ViewerRuntimeDependencies(
        loadIdentity: {
          ViewerPreparedIdentity(
            installationID: try EndpointID(rawValue: "viewer-test"),
            makeListener: { advertisement in try listeners.next(advertisement) }
          )
        },
        resetTLSIdentity: {},
        resetAllIdentity: {},
        generatePairingCode: { try pairingCodes.next() },
        makeRuntimeComponents: { runtimeLogicalID in
          let generation = generations.next()
          return ViewerRuntimeComponents.make(
            runtimeLogicalID: runtimeLogicalID,
            managerGeneration: generation,
            storeGateway: generation == 1 ? firstGateway : secondGateway
          )
        }
      )
    )

    model.openWindow()
    await waitForStatus(.listening(code: "ABCDEF", paused: false), in: model)
    XCTAssertEqual(blockedOperation.waitUntilEntered(), .success)
    let firstExplorer = try XCTUnwrap(model.explorerController)
    let firstComposer = try XCTUnwrap(model.composerController)
    XCTAssertTrue(firstExplorer.replaceFilterText(.search, with: "prior-filter-secret"))
    XCTAssertFalse(
      firstExplorer.replaceFilterText(.search, with: String(repeating: "x", count: 513))
    )
    XCTAssertNotNil(firstExplorer.filterValidationMessage)
    let retainedRendererRequest = try firstExplorer.inspector.select(
      detail: makeRendererDetail(
        rowID: 701,
        eventType: "custom.cleanup",
        content: Data(#"{"payload":{"message":"prior-inspector-secret"}}"#.utf8)
      ),
      identity: .durable(rowID: 701)
    )
    let retainedRendererResult = ViewerRendererPreparer().prepare(retainedRendererRequest)
    XCTAssertTrue(firstExplorer.inspector.apply(retainedRendererResult))
    XCTAssertNotNil(firstExplorer.inspector.canonicalBuffer)
    XCTAssertNotNil(firstExplorer.inspector.preparation?.generic.treeState)
    XCTAssertFalse(try firstExplorer.inspector.rawChunk(at: 0).text.isEmpty)
    XCTAssertTrue(firstComposer.replaceWhole(.content, with: #"{"prior":"composer-secret"}"#))

    let completionCount = LockedTestCounter()
    let termination = Task { @MainActor in
      let outcome = await model.prepareForTermination()
      completionCount.increment()
      return outcome
    }
    await Task.yield()
    XCTAssertEqual(model.status, .stopping)
    XCTAssertGreaterThan(firstExplorer.pendingCleanupWorkCount, 0)
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(completionCount.value, 0)

    blockedOperation.release()
    let terminationOutcome = await termination.value
    XCTAssertEqual(terminationOutcome, .completed)
    XCTAssertEqual(completionCount.value, 1)
    XCTAssertEqual(model.status, .stopped)
    XCTAssertNil(model.explorerController)
    XCTAssertNil(model.composerController)
    XCTAssertEqual(firstExplorer.pendingCleanupWorkCount, 0)
    XCTAssertEqual(firstComposer.pendingCleanupWorkCount, 0)
    XCTAssertEqual(firstExplorer.filterDraft.searchText, "")
    XCTAssertNil(firstExplorer.filterValidationMessage)
    XCTAssertTrue(firstExplorer.model.timelineRows.isEmpty)
    XCTAssertTrue(firstExplorer.model.recordingRows.isEmpty)
    XCTAssertTrue(firstExplorer.model.deviceRows.isEmpty)
    XCTAssertTrue(firstExplorer.model.gapRows.isEmpty)
    XCTAssertNil(firstExplorer.model.pendingRefreshSignal)
    XCTAssertNil(firstExplorer.inspector.canonicalBuffer)
    XCTAssertNil(firstExplorer.inspector.preparation)
    XCTAssertNil(firstExplorer.rawChunk)
    XCTAssertNil(firstExplorer.inspectorTreeState)
    XCTAssertFalse(firstExplorer.inspector.apply(retainedRendererResult))
    XCTAssertEqual(firstComposer.eventType, "")
    XCTAssertEqual(firstComposer.contentJSON, "")
    XCTAssertEqual(firstComposer.ttlText, "")
    let oldDiagnostics = [
      String(reflecting: firstExplorer),
      String(reflecting: firstComposer),
    ].joined()
    XCTAssertFalse(oldDiagnostics.contains("prior-filter-secret"))
    XCTAssertFalse(oldDiagnostics.contains("composer-secret"))

    model.openWindow()
    await waitForStatus(.listening(code: "MNPQRS", paused: false), in: model)
    let freshExplorer = try XCTUnwrap(model.explorerController)
    let freshComposer = try XCTUnwrap(model.composerController)
    XCTAssertFalse(freshExplorer === firstExplorer)
    XCTAssertFalse(freshComposer === firstComposer)
    XCTAssertEqual(freshExplorer.filterDraft.searchText, "")
    XCTAssertTrue(freshExplorer.model.timelineRows.isEmpty)
    XCTAssertEqual(freshComposer.contentJSON, "")
    let freshTerminationOutcome = await model.prepareForTermination()
    XCTAssertEqual(freshTerminationOutcome, .completed)
  }

  @MainActor
  func testSynchronousLocalNetworkListenerFailureKeepsRecoverableCategory() async throws {
    let listenerAttempted = expectation(description: "Listener creation attempted")
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: ViewerRuntimeDependencies(
        loadIdentity: {
          ViewerPreparedIdentity(
            installationID: try EndpointID(rawValue: "viewer-test"),
            makeListener: { _ in
              listenerAttempted.fulfill()
              throw SecureTransportError(
                code: .localNetworkUnavailable,
                message: "Raw construction detail"
              )
            }
          )
        },
        resetTLSIdentity: {},
        resetAllIdentity: {},
        generatePairingCode: { try PairingCode("ABCDEF") }
      )
    )

    model.openWindow()
    await fulfillment(of: [listenerAttempted], timeout: 1)
    await Task.yield()
    XCTAssertEqual(model.status, .failed(.localNetworkUnavailable))
  }

  func testInjectedIdentityLifecycleCreatesReloadsRepairsAndResetsExactItems() throws {
    let persistence = FakeIdentityPersistence()
    let builder = makeDeterministicCertificateBuilder(year: 2039)
    let store = ViewerIdentityStore(
      names: .isolated(),
      certificateBuilder: builder,
      persistence: persistence
    )

    let first = try store.loadOrCreateMaterial()
    let firstCertificate = SecCertificateCopyData(first.certificate) as Data
    let second = try store.loadOrCreateMaterial()
    XCTAssertEqual(first.installationID, second.installationID)
    XCTAssertEqual(firstCertificate, SecCertificateCopyData(second.certificate) as Data)
    XCTAssertEqual(persistence.callCount(.createPrivateKey), 1)
    XCTAssertEqual(persistence.certificateCount, 1)

    persistence.corruptTLSMetadata()
    let repaired = try store.loadOrCreateMaterial()
    XCTAssertEqual(first.installationID, repaired.installationID)
    XCTAssertNotEqual(firstCertificate, SecCertificateCopyData(repaired.certificate) as Data)
    XCTAssertEqual(persistence.callCount(.createPrivateKey), 2)
    XCTAssertEqual(persistence.certificateCount, 2)

    try store.resetTLSIdentity()
    XCTAssertTrue(persistence.hasGenericPassword("installation-id"))
    XCTAssertFalse(persistence.hasGenericPassword("tls-metadata"))
    XCTAssertFalse(persistence.hasPrivateKey)
    XCTAssertEqual(persistence.certificateCount, 1)

    let afterTLSReset = try store.loadOrCreateMaterial()
    XCTAssertEqual(first.installationID, afterTLSReset.installationID)
    try store.resetAllIdentity()
    XCTAssertFalse(persistence.hasGenericPassword("installation-id"))
    XCTAssertFalse(persistence.hasGenericPassword("tls-metadata"))
    XCTAssertFalse(persistence.hasPrivateKey)

    let afterFullReset = try store.loadOrCreateMaterial()
    XCTAssertNotEqual(first.installationID, afterFullReset.installationID)
  }

  func testIdentityAssemblyFailsClosedWhenExactPersistenceLookupFails() {
    let persistence = FakeIdentityPersistence()
    let store = ViewerIdentityStore(
      names: .isolated(),
      certificateBuilder: makeDeterministicCertificateBuilder(year: 2039),
      persistence: persistence
    )

    XCTAssertThrowsError(try store.loadOrCreate())
    XCTAssertEqual(persistence.callCount(.copyIdentity), 1)
  }

  func testExplicitIdentityResetRequiresCompleteOwnedTupleAndPreservesForeignCertificate() throws {
    let builder = makeDeterministicCertificateBuilder(year: 2039)

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      persistence.removePrivateKey()

      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 1)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
      XCTAssertEqual(persistence.callCount(.deleteCertificate), 0)
    }

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      persistence.replacePrivateKey(try builder.createEphemeralPrivateKey())

      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 1)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
      XCTAssertEqual(persistence.callCount(.deleteCertificate), 0)
    }

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      let foreignKey = try builder.createEphemeralPrivateKey()
      let foreign = try builder.build(privateKey: foreignKey)
      let label = "NearWire Viewer Foreign Fixture"
      let reference = try persistence.addForeignCertificate(foreign.certificate, label: label)
      let foreignPublicKey = try XCTUnwrap(SecCertificateCopyKey(foreign.certificate))
      try persistence.pointMetadata(
        to: reference,
        certificate: foreign.certificate,
        label: label,
        publicKey: foreignPublicKey
      )
      let deleteCount = persistence.callCount(.deleteCertificate)

      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 2)
      XCTAssertEqual(persistence.callCount(.deleteCertificate), deleteCount)
      XCTAssertTrue(persistence.hasPrivateKey)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
    }
  }

  func testExplicitIdentityResetReportsEveryPartialDeleteFailure() throws {
    let builder = makeDeterministicCertificateBuilder(year: 2039)

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      persistence.failNext(.deleteCertificate)
      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 1)
      XCTAssertTrue(persistence.hasPrivateKey)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
    }

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      persistence.failNext(.deletePrivateKey)
      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 0)
      XCTAssertTrue(persistence.hasPrivateKey)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
    }

    do {
      let persistence = FakeIdentityPersistence()
      let store = ViewerIdentityStore(
        names: .isolated(),
        certificateBuilder: builder,
        persistence: persistence
      )
      _ = try store.loadOrCreateMaterial()
      persistence.failNext(.deleteGenericPassword)
      XCTAssertThrowsError(try store.resetTLSIdentity())
      XCTAssertEqual(persistence.certificateCount, 0)
      XCTAssertFalse(persistence.hasPrivateKey)
      XCTAssertTrue(persistence.hasGenericPassword("tls-metadata"))
    }
  }

  func testCertificateBuilderSupportsUTCAndGeneralizedTimeValidityWindows() throws {
    let beforeTransition = makeDeterministicCertificateBuilder(year: 2039)
    let afterTransition = makeDeterministicCertificateBuilder(year: 2041)
    let firstKey = try beforeTransition.createEphemeralPrivateKey()
    let secondKey = try afterTransition.createEphemeralPrivateKey()

    let first = try beforeTransition.build(privateKey: firstKey)
    let second = try afterTransition.build(privateKey: secondKey)
    let firstProfile = try beforeTransition.validate(
      certificate: first.certificate,
      privateKey: firstKey,
      at: beforeTransition.now(),
      requireRenewalHeadroom: false
    )
    let secondProfile = try afterTransition.validate(
      certificate: second.certificate,
      privateKey: secondKey,
      at: afterTransition.now(),
      requireRenewalHeadroom: false
    )

    XCTAssertEqual(calendarYear(firstProfile.notAfter), 2048)
    XCTAssertEqual(calendarYear(secondProfile.notAfter), 2050)
    XCTAssertTrue(first.der.contains(0x17))
    XCTAssertTrue(second.der.contains(0x18))
  }

  func testDERTimeUsesCanonicalTransitionAndRejectsEarlyGeneralizedTime() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let lastUTC = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2049, month: 12, day: 31))
    )
    let firstGeneralized = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2050, month: 1, day: 1))
    )

    let utc = try ViewerDER.time(lastUTC)
    let generalized = try ViewerDER.time(firstGeneralized)
    XCTAssertEqual(utc.first, 0x17)
    XCTAssertEqual(generalized.first, 0x18)
    XCTAssertEqual(calendarYear(try ViewerDER.parseTime(utc)), 2049)
    XCTAssertEqual(calendarYear(try ViewerDER.parseTime(generalized)), 2050)

    let noncanonical2049 = ViewerDER.tagged(0x18, Data("20491231235959Z".utf8))
    let noncanonical1949 = ViewerDER.tagged(0x18, Data("19491231235959Z".utf8))
    XCTAssertThrowsError(try ViewerDER.parseTime(noncanonical2049))
    XCTAssertThrowsError(try ViewerDER.parseTime(noncanonical1949))
  }

  func testLoadedPrivateKeyValidationRequiresP256AndNonexportability() {
    let valid: [CFString: Any] = [kSecAttrKeySizeInBits: 256]
    XCTAssertTrue(
      ViewerIdentityStore.hasRequiredLoadedPrivateKeyProperties(
        valid,
        isExternallyRepresentable: false
      )
    )
    XCTAssertFalse(
      ViewerIdentityStore.hasRequiredLoadedPrivateKeyProperties(
        [:],
        isExternallyRepresentable: false
      )
    )
    XCTAssertFalse(
      ViewerIdentityStore.hasRequiredLoadedPrivateKeyProperties(
        valid,
        isExternallyRepresentable: true
      )
    )
  }

  private func makeAppHelloFrame(installationID: String) throws -> Data {
    let hello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: EndpointID(rawValue: installationID),
      displayName: "Demo App"
    )
    return try WirePreHandshakeCodec().encode(hello)
  }

  private func assertPrivateKeyCanSign(_ privateKey: SecKey) throws {
    var error: Unmanaged<CFError>?
    let signature = SecKeyCreateSignature(
      privateKey,
      .ecdsaSignatureMessageX962SHA256,
      Data("NearWire stable signer update probe".utf8) as CFData,
      &error
    )
    if let error { throw error.takeRetainedValue() }
    XCTAssertNotNil(signature)
  }

  private func makeDeterministicCertificateBuilder(year: Int) -> ViewerCertificateBuilder {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(from: DateComponents(year: year, month: 1, day: 2))!
    return ViewerCertificateBuilder(
      randomBytes: { count in Array((1...count).map(UInt8.init)) },
      now: { date }
    )
  }

  private func makeObservationContext(
    connectionID: UUID,
    displayName: String
  ) throws -> ViewerAdmissionSessionContext {
    let appID = try EndpointID(rawValue: "observation-app")
    let viewerID = try EndpointID(rawValue: "observation-viewer")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0.0"),
      role: .app,
      installationID: appID,
      displayName: displayName,
      applicationIdentifier: "com.nearwire.observation",
      applicationVersion: "1.0"
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("1.0.0"),
      role: .viewer,
      installationID: viewerID
    )
    return ViewerAdmissionSessionContext(
      connectionID: connectionID,
      appHello: appHello,
      viewerHello: viewerHello,
      negotiation: try WireNegotiator.negotiate(local: viewerHello, remote: appHello),
      receiveChunkBytes: 64 * 1_024
    )
  }

  private func makeObservationEnvelope(
    id: EventID = EventID(),
    typeRawValue: String = "test.observation",
    eventType: EventType? = nil,
    content: JSONValue,
    createdAt: Date,
    monotonicTimestampNanoseconds: UInt64 = 500,
    sessionEpoch: SessionEpoch,
    sequence: UInt64 = 0,
    priority: EventPriority = .normal,
    ttl: EventTTL = .default,
    causality: EventCausality = EventCausality(),
    schemaVersion: EventSchemaVersion = .current
  ) throws -> EventEnvelope {
    let appID = try EndpointID(rawValue: "observation-app")
    let viewerID = try EndpointID(rawValue: "observation-viewer")
    return try EventEnvelope(
      id: id,
      type: eventType ?? EventType.user(typeRawValue),
      content: content,
      createdAt: createdAt,
      monotonicTimestampNanoseconds: monotonicTimestampNanoseconds,
      source: EventEndpoint(role: .app, id: appID),
      target: EventEndpoint(role: .viewer, id: viewerID),
      direction: .appToViewer,
      sessionEpoch: sessionEpoch,
      sequence: EventSequence(sequence),
      priority: priority,
      ttl: ttl,
      causality: causality,
      schemaVersion: schemaVersion
    )
  }

  private func makeRendererDetail(
    rowID: Int64,
    eventType: String,
    content: Data
  ) -> ViewerStoredEventDetail {
    ViewerStoredEventDetail(
      summary: ViewerStoredEventRow(
        rowID: rowID,
        deviceSessionID: 1,
        direction: "appToViewer",
        wireSequence: rowID,
        eventUUID: "renderer-event-\(rowID)",
        eventType: eventType,
        contentByteCount: Int64(content.count),
        createdWallMilliseconds: rowID,
        viewerWallMilliseconds: rowID,
        viewerMonotonicNanoseconds: rowID,
        priority: "normal",
        recordingRevision: 1,
        deviceRevision: 1,
        resolvedDisposition: "buffered"
      ),
      contentJSON: content,
      deviceLogicalID: UUID(),
      installationAlias: "App 00000001",
      connectionAlias: "connection-1",
      originMonotonicNanoseconds: rowID,
      ttlMilliseconds: 60_000,
      schemaVersion: 1,
      correlationEventUUID: nil,
      replyToEventUUID: nil
    )
  }

  private func calendarYear(_ date: Date) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.component(.year, from: date)
  }

  @MainActor
  private func waitForStatus(
    _ expected: ViewerApplicationModel.Status,
    in model: ViewerApplicationModel,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    if model.status == expected { return }
    let reached = expectation(description: "Application model reached expected status")
    let observation = model.$status.sink { status in
      if status == expected { reached.fulfill() }
    }
    await fulfillment(of: [reached], timeout: 1)
    withExtendedLifetime(observation) {}
    XCTAssertEqual(model.status, expected, file: file, line: line)
  }

  @MainActor
  private func waitUntilRuntimeCapture(
    _ condition: @escaping () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<1_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  @MainActor
  private func waitUntilExplorer(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<1_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for Explorer state", file: file, line: line)
  }

  private func waitForAdmissionOccupancy(
    _ expectedCount: Int,
    in manager: ViewerAdmissionManager,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<1_000 {
      if manager.occupiedCount == expectedCount { return }
      await Task.yield()
    }
    XCTAssertEqual(manager.occupiedCount, expectedCount, file: file, line: line)
  }

  @MainActor
  private func makeApplicationModel(
    listenerFactory: LockedListenerFactory,
    pairingCodes: LockedPairingCodeSequence
  ) -> ViewerApplicationModel {
    ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: ViewerRuntimeDependencies(
        loadIdentity: {
          ViewerPreparedIdentity(
            installationID: try EndpointID(rawValue: "viewer-test"),
            makeListener: { advertisement in try listenerFactory.next(advertisement) }
          )
        },
        resetTLSIdentity: {},
        resetAllIdentity: {},
        generatePairingCode: { try pairingCodes.next() }
      )
    )
  }
}

@MainActor
private func descendantViews<ViewType: NSView>(
  of type: ViewType.Type,
  in root: NSView
) -> [ViewType] {
  root.subviews.flatMap { child in
    var matches = descendantViews(of: type, in: child)
    if let match = child as? ViewType { matches.insert(match, at: 0) }
    return matches
  }
}

@MainActor
private func renderedPNGData(of view: NSView) -> Data? {
  guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
    return nil
  }
  view.cacheDisplay(in: view.bounds, to: representation)
  return representation.representation(using: .png, properties: [:])
}

private final class FoundationDetailCompletionBox: @unchecked Sendable {
  typealias Completion = ViewerExplorerContentDriver.DetailCompletion

  private let lock = NSLock()
  private var completions: [Completion] = []

  func append(_ completion: @escaping Completion) {
    lock.lock()
    completions.append(completion)
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return completions.count
  }

  func complete(
    at index: Int,
    with result: Result<ViewerStoredEventDetail?, ViewerStoreExplorerFailure>
  ) {
    lock.lock()
    let completion = completions[index]
    lock.unlock()
    completion(result)
  }
}

private final class LockedTestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  func increment() {
    lock.lock()
    storage += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class BlockingViewerOperationGate: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var shouldBlock = true

  func run() {
    lock.lock()
    let blocks = shouldBlock
    shouldBlock = false
    lock.unlock()
    guard blocks else { return }
    entered.signal()
    _ = resume.wait(timeout: .now() + 5)
  }

  func waitUntilEntered() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() {
    resume.signal()
  }
}

private final class BlockingViewerMonotonicClock: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var callCount = 0
  private var blocked = false

  var isBlocked: Bool {
    lock.lock()
    defer { lock.unlock() }
    return blocked
  }

  func now() -> UInt64 {
    lock.lock()
    callCount += 1
    let shouldBlock = callCount == 2
    if shouldBlock { blocked = true }
    lock.unlock()
    if shouldBlock {
      entered.signal()
      resume.wait()
    }
    return 0
  }

  func waitUntilBlocked() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

extension ViewerPendingAppSummary {
  fileprivate static func fixture(name: String) -> ViewerPendingAppSummary {
    ViewerPendingAppSummary(
      id: UUID(),
      displayName: name,
      applicationIdentifier: nil,
      applicationVersion: nil,
      installationAlias: "App fixture",
      compatibilityStatus: "Compatible"
    )
  }
}

private final class LockedCoalescerBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: ViewerPendingCoalescer?

  func set(_ value: ViewerPendingCoalescer) {
    lock.lock()
    storage = value
    lock.unlock()
  }

  var value: ViewerPendingCoalescer? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class ExplorerLiveObservationSpy: ViewerLiveObservationProviding, @unchecked Sendable
{
  let runtimeLogicalID: UUID

  private let lock = NSLock()
  private var storedSnapshot: ViewerLiveProjectionSnapshot
  private var storedPausedValues: [Bool] = []
  private var storedVisibleValues: [ViewerExplorerDurableVisibility] = []
  private var storedPerformanceLocators: [ViewerEventJournalKey: ViewerPerformanceEventLocator] =
    [:]
  private var snapshotRequests = 0

  init(snapshot: ViewerLiveProjectionSnapshot) {
    runtimeLogicalID = snapshot.runtimeLogicalID
    storedSnapshot = snapshot
  }

  func snapshot() -> ViewerLiveProjectionSnapshot {
    lock.lock()
    snapshotRequests += 1
    let snapshot = storedSnapshot
    lock.unlock()
    return snapshot
  }

  func freezePerformance(connectionID: UUID) throws -> ViewerPerformanceLiveSlice {
    throw ViewerPerformanceStoreFailure.unavailable
  }

  func performanceEventLocator(for key: ViewerEventJournalKey) -> ViewerPerformanceEventLocator? {
    lock.lock()
    defer { lock.unlock() }
    return storedPerformanceLocators[key]
  }

  func setPerformanceEventLocator(
    _ locator: ViewerPerformanceEventLocator?,
    for key: ViewerEventJournalKey
  ) {
    lock.lock()
    storedPerformanceLocators[key] = locator
    lock.unlock()
  }

  func setRefreshHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}

  func storeStateChanged(_ state: ViewerStoreStatus.State) {}

  func setPresentationPaused(_ paused: Bool) {
    lock.lock()
    storedPausedValues.append(paused)
    lock.unlock()
  }

  func durableRowBecameVisible(key: ViewerEventJournalKey, observationID: UUID) {
    lock.lock()
    storedVisibleValues.append(
      ViewerExplorerDurableVisibility(
        key: key,
        observationID: observationID,
        durableRowID: 0
      )
    )
    lock.unlock()
  }

  var snapshotRequestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return snapshotRequests
  }

  var pausedValues: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return storedPausedValues
  }

  var visibleValues: [ViewerExplorerDurableVisibility] {
    lock.lock()
    defer { lock.unlock() }
    return storedVisibleValues
  }
}

private final class ExplorerStoreDriverSpy: @unchecked Sendable {
  private struct Pending<Completion> {
    let completion: Completion
    let validity: ExplorerStoreDriverValidity
  }

  private let lock = NSLock()
  private var releases: [Pending<ViewerExplorerStoreDriver.VoidCompletion>] = []
  private var queries: [Pending<ViewerExplorerStoreDriver.QueryCompletion>] = []
  private var pages: [Pending<ViewerExplorerStoreDriver.PageCompletion>] = []
  private var gaps: [Pending<ViewerExplorerStoreDriver.GapCompletion>] = []
  private var releaseRequests = 0
  private var queryRequests = 0
  private var pageRequests = 0
  private var gapRequests = 0
  private var rejectsNextQuerySynchronously = false
  private var rejectsNextPageSynchronously = false
  private var rejectsNextGapsSynchronously = false

  lazy var driver = ViewerExplorerStoreDriver(
    endTraversal: { [weak self] completion in
      self?.appendRelease(completion)
        ?? ViewerExplorerStoreOperationToken(deliveryIsValid: { false })
    },
    replaceQuery: { [weak self] _, _, completion in
      self?.appendQuery(completion)
        ?? ViewerExplorerStoreOperationToken(deliveryIsValid: { false })
    },
    loadTailPage: { [weak self] _, completion in
      self?.appendPage(completion)
        ?? ViewerExplorerStoreOperationToken(deliveryIsValid: { false })
    },
    loadTailGaps: { [weak self] _, _, completion in
      self?.appendGaps(completion)
        ?? ViewerExplorerStoreOperationToken(deliveryIsValid: { false })
    }
  )

  var releaseRequestCount: Int { locked { releaseRequests } }
  var queryRequestCount: Int { locked { queryRequests } }
  var pageRequestCount: Int { locked { pageRequests } }
  var gapRequestCount: Int { locked { gapRequests } }

  func completeNextRelease(_ result: Result<Void, ViewerStoreExplorerFailure>) {
    let pending = locked { releases.isEmpty ? nil : releases.removeFirst() }
    pending?.completion(result)
  }

  func completeNextQuery(_ result: Result<ViewerQuerySnapshot, ViewerStoreExplorerFailure>) {
    let pending = locked { queries.isEmpty ? nil : queries.removeFirst() }
    pending?.completion(result)
  }

  func completeNextPage(_ result: Result<ViewerEventPage, ViewerStoreExplorerFailure>) {
    let pending = locked { pages.isEmpty ? nil : pages.removeFirst() }
    pending?.completion(result)
  }

  func completeNextGaps(_ result: Result<ViewerGapPage, ViewerStoreExplorerFailure>) {
    let pending = locked { gaps.isEmpty ? nil : gaps.removeFirst() }
    pending?.completion(result)
  }

  func invalidateNextRelease() { locked { releases.first?.validity.invalidate() } }
  func invalidateNextQuery() { locked { queries.first?.validity.invalidate() } }
  func invalidateNextPage() { locked { pages.first?.validity.invalidate() } }
  func invalidateNextGaps() { locked { gaps.first?.validity.invalidate() } }
  func rejectNextQuerySynchronously() { locked { rejectsNextQuerySynchronously = true } }
  func rejectNextPageSynchronously() { locked { rejectsNextPageSynchronously = true } }
  func rejectNextGapsSynchronously() { locked { rejectsNextGapsSynchronously = true } }

  private func appendRelease(
    _ completion: @escaping ViewerExplorerStoreDriver.VoidCompletion
  ) -> ViewerExplorerStoreOperationToken {
    let validity = ExplorerStoreDriverValidity()
    lock.lock()
    releaseRequests += 1
    releases.append(Pending(completion: completion, validity: validity))
    lock.unlock()
    return ViewerExplorerStoreOperationToken(deliveryIsValid: { validity.isValid })
  }

  private func appendQuery(
    _ completion: @escaping ViewerExplorerStoreDriver.QueryCompletion
  ) -> ViewerExplorerStoreOperationToken {
    let validity = ExplorerStoreDriverValidity()
    lock.lock()
    queryRequests += 1
    let rejectsSynchronously = rejectsNextQuerySynchronously
    rejectsNextQuerySynchronously = false
    if rejectsSynchronously {
      lock.unlock()
      validity.invalidate()
      completion(.failure(.storeReplaced))
      return ViewerExplorerStoreOperationToken(deliveryIsValid: { validity.isValid })
    }
    queries.append(Pending(completion: completion, validity: validity))
    lock.unlock()
    return ViewerExplorerStoreOperationToken(deliveryIsValid: { validity.isValid })
  }

  private func appendPage(
    _ completion: @escaping ViewerExplorerStoreDriver.PageCompletion
  ) -> ViewerExplorerStoreOperationToken {
    let validity = ExplorerStoreDriverValidity()
    lock.lock()
    pageRequests += 1
    let rejectsSynchronously = rejectsNextPageSynchronously
    rejectsNextPageSynchronously = false
    if rejectsSynchronously {
      lock.unlock()
      validity.invalidate()
      completion(.failure(.storeReplaced))
      return ViewerExplorerStoreOperationToken(deliveryIsValid: { validity.isValid })
    }
    pages.append(Pending(completion: completion, validity: validity))
    lock.unlock()
    return ViewerExplorerStoreOperationToken(deliveryIsValid: { validity.isValid })
  }

  private func appendGaps(
    _ completion: @escaping ViewerExplorerStoreDriver.GapCompletion
  ) -> ViewerExplorerStoreOperationToken {
    let validity = ExplorerStoreDriverValidity()
    lock.lock()
    gapRequests += 1
    let rejectsSynchronously = rejectsNextGapsSynchronously
    rejectsNextGapsSynchronously = false
    if rejectsSynchronously {
      lock.unlock()
      validity.invalidate()
      completion(.failure(.storeReplaced))
      return ViewerExplorerStoreOperationToken(deliveryIsValid: { validity.isValid })
    }
    gaps.append(Pending(completion: completion, validity: validity))
    lock.unlock()
    return ViewerExplorerStoreOperationToken(deliveryIsValid: { validity.isValid })
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private final class ExplorerStoreDriverValidity: @unchecked Sendable {
  private let lock = NSLock()
  private var valid = true

  func invalidate() {
    lock.lock()
    valid = false
    lock.unlock()
  }

  var isValid: Bool {
    lock.lock()
    defer { lock.unlock() }
    return valid
  }
}

private final class LockedRendererResultCollection: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [ViewerRendererPreparationResult] = []

  func append(_ value: ViewerRendererPreparationResult) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [ViewerRendererPreparationResult] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

private final class LockedComposerResultCollection: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [ViewerComposerPreparationResult] = []

  func append(_ value: ViewerComposerPreparationResult) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [ViewerComposerPreparationResult] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

private final class LockedStringSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ value: String) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class FakeViewerSecureListener: ViewerSecureListener, @unchecked Sendable {
  private let lock = NSLock()
  private let eventsOnStart: [SecureViewerListenerEvent]
  private let onCancel: @Sendable () -> Void
  private let onStart: @Sendable () -> Void
  private var eventHandler: SecureViewerListener.EventHandler?
  private var cancellations = 0

  init(
    eventsOnStart: [SecureViewerListenerEvent] = [],
    onCancel: @escaping @Sendable () -> Void = {},
    onStart: @escaping @Sendable () -> Void = {}
  ) {
    self.eventsOnStart = eventsOnStart
    self.onCancel = onCancel
    self.onStart = onStart
  }

  func start(
    queue: DispatchQueue,
    eventHandler: @escaping SecureViewerListener.EventHandler
  ) throws {
    lock.lock()
    self.eventHandler = eventHandler
    let events = eventsOnStart
    lock.unlock()
    onStart()
    for event in events { eventHandler(event) }
  }

  func cancel() {
    lock.lock()
    cancellations += 1
    lock.unlock()
    onCancel()
  }

  func emit(_ event: SecureViewerListenerEvent) {
    lock.lock()
    let eventHandler = eventHandler
    lock.unlock()
    eventHandler?(event)
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancellations
  }
}

private final class LockedListenerFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var listeners: [FakeViewerSecureListener]
  private var storedAdvertisements: [SecureViewerServiceAdvertisement] = []

  init(_ listeners: [FakeViewerSecureListener]) {
    self.listeners = listeners
  }

  func next(_ advertisement: SecureViewerServiceAdvertisement) throws -> any ViewerSecureListener {
    lock.lock()
    defer { lock.unlock() }
    guard !listeners.isEmpty else { throw ViewerTestError.exhausted }
    storedAdvertisements.append(advertisement)
    return listeners.removeFirst()
  }

  var advertisements: [SecureViewerServiceAdvertisement] {
    lock.lock()
    defer { lock.unlock() }
    return storedAdvertisements
  }
}

private final class LockedPairingCodeSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String]
  private var requests = 0

  init(_ values: [String]) {
    self.values = values
  }

  func next() throws -> PairingCode {
    lock.lock()
    defer { lock.unlock() }
    requests += 1
    guard !values.isEmpty else { throw ViewerPairingCodeGenerationError() }
    return try PairingCode(values.removeFirst())
  }

  var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

private enum ViewerTestError: Error {
  case exhausted
  case invalidProbeConfiguration
  case signingMetadataUnavailable
}

private enum StableSignerProbePhase: String {
  case create
  case deny
  case verify
}

private struct StableSignerProbeFingerprint: Codable, Equatable {
  let teamIdentifier: String
  let certificateHash: Data
  let designatedRequirement: String
}

private struct StableSignerProbeRecord: Codable {
  let installationID: String
  let certificateHash: Data
  let certificatePersistentReference: Data
  let signer: StableSignerProbeFingerprint
  let codeDirectoryHash: Data
  let bundleVersion: String
  let buildID: String
  let productPath: String
}

private final class FakeAdmissionChannel: ViewerAdmissionChannel, @unchecked Sendable {
  private let lock = NSLock()
  private let supportsReceivePause: Bool
  private let onSend: @Sendable (Data) -> Void
  private let onStart: @Sendable () -> Void
  private let onCancel: @Sendable () -> Void
  private let cancelOperation: @Sendable () async -> Void
  private var payloads: [Data] = []
  private var starts = 0
  private var cancellations = 0

  init(
    supportsReceivePause: Bool = true,
    onSend: @escaping @Sendable (Data) -> Void = { _ in },
    onStart: @escaping @Sendable () -> Void = {},
    onCancel: @escaping @Sendable () -> Void = {},
    cancelOperation: @escaping @Sendable () async -> Void = {}
  ) {
    self.supportsReceivePause = supportsReceivePause
    self.onSend = onSend
    self.onStart = onStart
    self.onCancel = onCancel
    self.cancelOperation = cancelOperation
  }

  func admitSend(_ data: Data) throws {
    lock.lock()
    payloads.append(data)
    lock.unlock()
    onSend(data)
  }

  func claimReceivePause() -> SecureReceivePauseToken? {
    guard supportsReceivePause else { return nil }
    return SecureReceivePauseToken { _ in }
  }

  func start() async throws {
    recordStart()
    onStart()
  }

  func cancel() async {
    await cancelOperation()
    recordCancellation()
    onCancel()
  }

  private func recordStart() {
    lock.lock()
    starts += 1
    lock.unlock()
  }

  private func recordCancellation() {
    lock.lock()
    cancellations += 1
    lock.unlock()
  }

  var sentPayloads: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return payloads
  }

  var startCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return starts
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancellations
  }
}

private final class FakeIncomingConnection: ViewerIncomingConnection, @unchecked Sendable {
  let channel: FakeAdmissionChannel
  private let lock = NSLock()
  private var handler: SecureByteChannel.EventHandler?
  private var claims = 0
  private var rejections = 0
  private let beforeClaim: @Sendable () -> Void

  init(
    channel: FakeAdmissionChannel,
    beforeClaim: @escaping @Sendable () -> Void = {}
  ) {
    self.channel = channel
    self.beforeClaim = beforeClaim
  }

  func makeAdmissionChannel(
    queue: DispatchQueue,
    eventHandler: @escaping SecureByteChannel.EventHandler
  ) throws -> any ViewerAdmissionChannel {
    beforeClaim()
    lock.lock()
    claims += 1
    handler = eventHandler
    lock.unlock()
    return channel
  }

  func reject() {
    lock.lock()
    rejections += 1
    lock.unlock()
  }

  func emit(_ event: SecureByteChannelEvent) {
    lock.lock()
    let handler = handler
    lock.unlock()
    handler?(event)
  }

  var claimCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return claims
  }

  var rejectionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return rejections
  }
}

private final class AsyncTestGate: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private var isOpen = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    entered.signal()
    await withCheckedContinuation { continuation in
      lock.lock()
      if isOpen {
        lock.unlock()
        continuation.resume()
      } else {
        continuations.append(continuation)
        lock.unlock()
      }
    }
  }

  func waitUntilEntered() {
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
  }

  func waitUntilEntered(count: Int) {
    for _ in 0..<count { waitUntilEntered() }
  }

  func open() {
    lock.lock()
    guard !isOpen else {
      lock.unlock()
      return
    }
    isOpen = true
    let continuations = continuations
    self.continuations.removeAll()
    lock.unlock()
    for continuation in continuations { continuation.resume() }
  }
}

private final class RuntimeComponentJournalSpy: ViewerSessionJournaling, @unchecked Sendable {
  private let lock = NSLock()
  private let endGate: AsyncTestGate
  private var started: [UUID] = []
  private var ended: [UUID] = []

  init(endGate: AsyncTestGate) { self.endGate = endGate }

  var startedRuntimeIDs: [UUID] {
    lock.lock()
    defer { lock.unlock() }
    return started
  }

  var endedRuntimeIDs: [UUID] {
    lock.lock()
    defer { lock.unlock() }
    return ended
  }

  func runtimeStarted(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {
    lock.lock()
    started.append(logicalID)
    lock.unlock()
  }

  func sessionStarted(runtimeLogicalID: UUID, _ context: ViewerAdmissionSessionContext) {}
  func eventCommitted(
    _ observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) { outcome(.accepted) }
  func uplinkTerminated(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    direction: EventDirection,
    wireSequence: UInt64,
    disposition: ViewerStoredDisposition,
    monotonicNanoseconds: UInt64
  ) {}
  func policyChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    policy: ViewerRatePolicy,
    monotonicNanoseconds: UInt64
  ) {}
  func dropsChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    samples: [ViewerDropJournalSample],
    monotonicNanoseconds: UInt64
  ) {}
  func sessionEnded(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {}
  func retryStorage() {}

  func runtimeEnded(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) async {
    await endGate.wait()
    appendEnded(logicalID)
  }

  private func appendEnded(_ logicalID: UUID) {
    lock.lock()
    ended.append(logicalID)
    lock.unlock()
  }
}

private final class CommittedObservationJournalSpy: ViewerSessionJournaling, @unchecked Sendable {
  private let lock = NSLock()
  private var storedObservations: [ViewerCommittedEventObservation] = []
  private var projections: [ViewerEventJournalKey: ViewerDurableEventProjection] = [:]

  var observations: [ViewerCommittedEventObservation] {
    lock.lock()
    defer { lock.unlock() }
    return storedObservations
  }

  var commitCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedObservations.count
  }

  func runtimeStarted(logicalID: UUID, wallMilliseconds: Int64, monotonicNanoseconds: UInt64) {}
  func sessionStarted(runtimeLogicalID: UUID, _ context: ViewerAdmissionSessionContext) {}
  func eventCommitted(
    _ observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) {
    lock.lock()
    storedObservations.append(observation)
    let result: ViewerEventJournalOutcome
    if let existing = projections[observation.key] {
      result =
        existing == observation.durableProjection
        ? .identical : .journalConflict
    } else {
      projections[observation.key] = observation.durableProjection
      result = .accepted
    }
    lock.unlock()
    outcome(result)
  }
  func uplinkTerminated(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    direction: EventDirection,
    wireSequence: UInt64,
    disposition: ViewerStoredDisposition,
    monotonicNanoseconds: UInt64
  ) {}
  func policyChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    policy: ViewerRatePolicy,
    monotonicNanoseconds: UInt64
  ) {}
  func dropsChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    samples: [ViewerDropJournalSample],
    monotonicNanoseconds: UInt64
  ) {}
  func sessionEnded(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {}
  func retryStorage() {}
  func runtimeEnded(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) async {}
}

private final class LockedJournalOutcomeCollection: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [ViewerEventJournalOutcome] = []

  func append(_ value: ViewerEventJournalOutcome) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [ViewerEventJournalOutcome] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

private final class LockedUInt64Collection: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [UInt64] = []

  func append(_ value: UInt64) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [UInt64] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

private final class ManualLiveRefreshScheduler: @unchecked Sendable {
  private struct Job {
    let delay: UInt64
    let action: @Sendable () -> Void
  }

  private let lock = NSLock()
  private var currentNanoseconds: UInt64 = 0
  private var jobs: [Job] = []

  var value: ViewerLiveRefreshScheduler {
    ViewerLiveRefreshScheduler(
      now: { [weak self] in self?.now() ?? 0 },
      scheduleOnMain: { [weak self] delay, action in self?.schedule(delay: delay, action: action) }
    )
  }

  var explorerValue: ViewerExplorerRefreshScheduler {
    ViewerExplorerRefreshScheduler(
      now: { [weak self] in self?.now() ?? 0 },
      scheduleOnMain: { [weak self] delay, action in self?.schedule(delay: delay, action: action) }
    )
  }

  var pendingCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return jobs.count
  }

  var nextDelay: UInt64? {
    lock.lock()
    defer { lock.unlock() }
    return jobs.first?.delay
  }

  func runNext() {
    let job: Job?
    lock.lock()
    if jobs.isEmpty {
      job = nil
    } else {
      job = jobs.removeFirst()
      if let job {
        let (advanced, overflow) = currentNanoseconds.addingReportingOverflow(job.delay)
        currentNanoseconds = overflow ? UInt64.max : advanced
      }
    }
    lock.unlock()
    job?.action()
  }

  private func now() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return currentNanoseconds
  }

  private func schedule(delay: UInt64, action: @escaping @Sendable () -> Void) {
    lock.lock()
    jobs.append(Job(delay: delay, action: action))
    lock.unlock()
  }
}

@MainActor
private final class ExplorerRefreshCapture {
  private(set) var tokens: [ViewerExplorerPresentationToken] = []
  private(set) var signals: [ViewerExplorerRefreshSignal] = []

  func append(token: ViewerExplorerPresentationToken, signal: ViewerExplorerRefreshSignal) {
    tokens.append(token)
    signals.append(signal)
  }

  var count: Int { signals.count }
}

private final class SteppingNanosecondClock: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UInt64]
  private var last: UInt64

  init(values: [UInt64]) {
    self.values = values
    last = values.last ?? 0
  }

  func now() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    guard !values.isEmpty else { return last }
    let value = values.removeFirst()
    last = value
    return value
  }
}

private final class LockedRuntimeComponentCapture: @unchecked Sendable {
  private struct Entry {
    let runtimeLogicalID: UUID
    let managerGeneration: UInt64
    let liveWindow: ViewerLiveEventWindow
  }

  private let lock = NSLock()
  private var entries: [Entry] = []

  func append(_ components: ViewerRuntimeComponents) {
    guard let liveWindow = components.liveObservations as? ViewerLiveEventWindow else { return }
    lock.lock()
    entries.append(
      Entry(
        runtimeLogicalID: components.runtimeLogicalID,
        managerGeneration: components.managerGeneration,
        liveWindow: liveWindow
      )
    )
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }

  var runtimeLogicalIDs: [UUID] {
    lock.lock()
    defer { lock.unlock() }
    return entries.map(\.runtimeLogicalID)
  }

  var managerGenerations: [UInt64] {
    lock.lock()
    defer { lock.unlock() }
    return entries.map(\.managerGeneration)
  }

  var allLiveWindowsCleared: Bool {
    lock.lock()
    let windows = entries.map(\.liveWindow)
    lock.unlock()
    return windows.allSatisfy(\.isCleared)
  }
}

private final class ManualAdmissionScheduler: @unchecked Sendable {
  private struct Waiter {
    let id: UUID
    let deadline: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private let scheduled = DispatchSemaphore(value: 0)
  private var current: UInt64 = 1
  private var waiters: [Waiter] = []
  private var cancelled: Set<UUID> = []

  var scheduler: ViewerAdmissionScheduler {
    ViewerAdmissionScheduler(
      now: { [weak self] in self?.now ?? 0 },
      sleep: { [weak self] duration in
        guard let self else { throw CancellationError() }
        try await self.sleep(duration)
      }
    )
  }

  var now: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func advance(by duration: UInt64) {
    lock.lock()
    current &+= duration
    let ready = waiters.filter { $0.deadline <= current }
    waiters.removeAll { $0.deadline <= current }
    lock.unlock()
    for waiter in ready { waiter.continuation.resume() }
  }

  func waitUntilScheduled() {
    XCTAssertEqual(scheduled.wait(timeout: .now() + 1), .success)
  }

  private func sleep(_ duration: UInt64) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        if cancelled.remove(id) != nil || Task.isCancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        let deadline = current &+ duration
        waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
        lock.unlock()
        scheduled.signal()
      }
    } onCancel: {
      lock.lock()
      if let index = waiters.firstIndex(where: { $0.id == id }) {
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
      } else {
        cancelled.insert(id)
        lock.unlock()
      }
    }
  }
}

private final class LockedHandleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: ViewerAdmissionHandle?

  func set(_ value: ViewerAdmissionHandle) {
    lock.lock()
    storage = value
    lock.unlock()
  }

  var value: ViewerAdmissionHandle? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class LockedHandleCollection: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ViewerAdmissionHandle] = []

  @discardableResult
  func append(_ value: ViewerAdmissionHandle) -> Int {
    lock.lock()
    storage.append(value)
    let count = storage.count
    lock.unlock()
    return count
  }

  var values: [ViewerAdmissionHandle] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class FakeAdmissionHandoffOwner: ViewerAdmissionHandoffOwning,
  ViewerSessionControlling, @unchecked Sendable
{
  let runtimeLogicalID: UUID
  let managerGeneration: UInt64
  private let lock = NSLock()
  private let onTransfer: @Sendable (ViewerAdmissionHandle) -> Void
  private let shutdownOperation: @Sendable () async -> Void
  private var handles: [ViewerAdmissionHandle] = []
  private var shuttingDown = false
  private var shutdownTask: Task<Void, Never>?

  init(
    runtimeLogicalID: UUID = UUID(),
    managerGeneration: UInt64 = 1,
    onTransfer: @escaping @Sendable (ViewerAdmissionHandle) -> Void = { _ in },
    shutdownOperation: @escaping @Sendable () async -> Void = {}
  ) {
    self.runtimeLogicalID = runtimeLogicalID
    self.managerGeneration = managerGeneration
    self.onTransfer = onTransfer
    self.shutdownOperation = shutdownOperation
  }

  func setSnapshotHandler(_ handler: @escaping @Sendable ([ViewerSessionSnapshot]) -> Void) {
    handler([])
  }

  func disconnect(connectionID: UUID) {}
  func updatePolicy(connectionID: UUID, policy: ViewerRatePolicy) {}
  func controlTargets() -> [ViewerControlTarget] { [] }
  func send(
    _ prepared: ViewerPreparedControlEvent,
    to capabilities: [ViewerControlTargetCapability]
  ) throws -> [ViewerControlTargetResult] { [] }
  func setNickname(_ nickname: String?, route: ViewerLogicalRoute) -> Bool { false }

  func transfer(_ handle: ViewerAdmissionHandle) -> Bool {
    lock.lock()
    guard !shuttingDown else {
      lock.unlock()
      return false
    }
    handles.append(handle)
    lock.unlock()
    onTransfer(handle)
    return true
  }

  func beginShutdown() -> Task<Void, Never> {
    lock.lock()
    if let shutdownTask {
      lock.unlock()
      return shutdownTask
    }
    shuttingDown = true
    let handles = self.handles
    self.handles.removeAll()
    let shutdownOperation = self.shutdownOperation
    let task = Task {
      await shutdownOperation()
      for handle in handles { await handle.cancelAndWait() }
    }
    shutdownTask = task
    lock.unlock()
    return task
  }
}

private final class LockedSummaryBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: ViewerPendingAppSummary?

  func set(_ value: ViewerPendingAppSummary) {
    lock.lock()
    storage = value
    lock.unlock()
  }

  var value: ViewerPendingAppSummary? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class FakeIdentityPersistence: ViewerIdentityPersistence, @unchecked Sendable {
  enum Operation: String, Hashable {
    case copyGenericPassword
    case addGenericPassword
    case deleteGenericPassword
    case createPrivateKey
    case copyPrivateKey
    case deletePrivateKey
    case addCertificate
    case copyCertificate
    case deleteCertificate
    case copyIdentity
  }

  private struct CertificateRecord {
    let certificate: SecCertificate
    let label: String
  }

  private let lock = NSLock()
  private var genericPasswords: [String: Data] = [:]
  private var privateKey: SecKey?
  private var certificates: [Data: CertificateRecord] = [:]
  private var nextReference = 1
  private var failures: [Operation: Int] = [:]
  private var calls: [Operation: Int] = [:]

  func failNext(_ operation: Operation) {
    lock.lock()
    failures[operation, default: 0] += 1
    lock.unlock()
  }

  func copyGenericPassword(account: String) throws -> Data {
    try begin(.copyGenericPassword)
    lock.lock()
    defer { lock.unlock() }
    guard let value = genericPasswords[account] else {
      throw ViewerIdentityPersistenceError.missing
    }
    return value
  }

  func addGenericPassword(account: String, value: Data) throws {
    try begin(.addGenericPassword)
    lock.lock()
    defer { lock.unlock() }
    guard genericPasswords[account] == nil else {
      throw ViewerIdentityPersistenceError.operation
    }
    genericPasswords[account] = value
  }

  func deleteGenericPassword(account: String, requirePresent: Bool) throws {
    try begin(.deleteGenericPassword)
    lock.lock()
    defer { lock.unlock() }
    let removed = genericPasswords.removeValue(forKey: account)
    if requirePresent, removed == nil { throw ViewerIdentityPersistenceError.missing }
  }

  func createPrivateKey(builder: ViewerCertificateBuilder) throws -> SecKey {
    try begin(.createPrivateKey)
    let key = try builder.createEphemeralPrivateKey()
    lock.lock()
    privateKey = key
    lock.unlock()
    return key
  }

  func copyPrivateKey() throws -> SecKey {
    try begin(.copyPrivateKey)
    lock.lock()
    defer { lock.unlock() }
    guard let privateKey else { throw ViewerIdentityPersistenceError.missing }
    return privateKey
  }

  func deletePrivateKey(requirePresent: Bool) throws {
    try begin(.deletePrivateKey)
    lock.lock()
    defer { lock.unlock() }
    if requirePresent, privateKey == nil { throw ViewerIdentityPersistenceError.missing }
    privateKey = nil
  }

  func privateKeyItemExists() throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return privateKey != nil
  }

  func addCertificate(_ certificate: SecCertificate, label: String) throws -> Data {
    try begin(.addCertificate)
    lock.lock()
    defer { lock.unlock() }
    let reference = Data("certificate-\(nextReference)".utf8)
    nextReference += 1
    certificates[reference] = CertificateRecord(certificate: certificate, label: label)
    return reference
  }

  func copyCertificate(persistentReference: Data) throws -> SecCertificate {
    try begin(.copyCertificate)
    lock.lock()
    defer { lock.unlock() }
    guard let record = certificates[persistentReference] else {
      throw ViewerIdentityPersistenceError.missing
    }
    return record.certificate
  }

  func deleteCertificate(persistentReference: Data, requirePresent: Bool) throws {
    try begin(.deleteCertificate)
    lock.lock()
    defer { lock.unlock() }
    let removed = certificates.removeValue(forKey: persistentReference)
    if requirePresent, removed == nil { throw ViewerIdentityPersistenceError.missing }
  }

  func copyIdentity(certificate: SecCertificate, privateKey: SecKey) throws -> SecIdentity {
    try begin(.copyIdentity)
    throw ViewerIdentityPersistenceError.invalid
  }

  func corruptTLSMetadata() {
    lock.lock()
    genericPasswords["tls-metadata"] = Data("invalid".utf8)
    lock.unlock()
  }

  func removePrivateKey() {
    lock.lock()
    privateKey = nil
    lock.unlock()
  }

  func replacePrivateKey(_ key: SecKey) {
    lock.lock()
    privateKey = key
    lock.unlock()
  }

  func addForeignCertificate(_ certificate: SecCertificate, label: String) throws -> Data {
    try addCertificate(certificate, label: label)
  }

  func pointMetadata(
    to reference: Data,
    certificate: SecCertificate,
    label: String,
    publicKey: SecKey
  ) throws {
    guard let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
      let serial = SecCertificateCopySerialNumberData(certificate, nil) as Data?
    else {
      throw ViewerTestError.exhausted
    }
    lock.lock()
    defer { lock.unlock() }
    guard let metadata = genericPasswords["tls-metadata"],
      var object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
    else {
      throw ViewerTestError.exhausted
    }
    object["certificatePersistentReference"] = reference.base64EncodedString()
    object["certificateLabel"] = label
    object["serial"] = serial.base64EncodedString()
    object["publicKeyHash"] = Data(SHA256.hash(data: publicBytes)).base64EncodedString()
    object["certificateHash"] = Data(
      SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
    ).base64EncodedString()
    genericPasswords["tls-metadata"] = try JSONSerialization.data(withJSONObject: object)
  }

  var certificateCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return certificates.count
  }

  var hasPrivateKey: Bool {
    lock.lock()
    defer { lock.unlock() }
    return privateKey != nil
  }

  func hasGenericPassword(_ account: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return genericPasswords[account] != nil
  }

  func callCount(_ operation: Operation) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return calls[operation, default: 0]
  }

  private func begin(_ operation: Operation) throws {
    lock.lock()
    calls[operation, default: 0] += 1
    if failures[operation, default: 0] > 0 {
      failures[operation, default: 0] -= 1
      lock.unlock()
      throw ViewerIdentityPersistenceError.operation
    }
    lock.unlock()
  }
}

private func currentFoundationProcessPhysicalFootprintBytes() -> UInt64? {
  var information = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
  )
  let result = withUnsafeMutablePointer(to: &information) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
      task_info(
        mach_task_self_,
        task_flavor_t(TASK_VM_INFO),
        rebound,
        &count
      )
    }
  }
  return result == KERN_SUCCESS ? information.phys_footprint : nil
}
