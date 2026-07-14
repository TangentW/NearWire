import Foundation
import NearWire
@_spi(NearWireInternal) import NearWireCore
import XCTest

@testable import NearWirePerformance

final class PerformanceSamplerProjectionTests: XCTestCase {
  func testProjectionConsumesCoreMetricInventory() {
    XCTAssertEqual(
      PerformanceMetricGroup.allCases.flatMap(\.keys),
      PerformanceMetricKey.allCases
    )
    XCTAssertEqual(Set(PerformanceMetricKey.allCases.map(\.rawValue)).count, 16)
    XCTAssertEqual(
      PerformanceMetricKey.allCases.map(\.group),
      PerformanceMetricGroup.allCases.flatMap { group in group.keys.map { _ in group } }
    )
    XCTAssertEqual(
      PerformanceMetricKey.allCases.map(\.kind),
      [
        .numeric, .numeric, .numeric, .numeric,
        .numeric, .categorical, .categorical, .categorical,
        .unavailableOnly, .unavailableOnly, .unavailableOnly,
        .numeric, .numeric, .numeric, .numeric, .numeric,
      ]
    )
  }

  func testCPUSamplerHandlesInitialFailureRecoveryAndMultiCoreValues() {
    let values = LockedValues<Double?>([nil, nil, 1, 3, 3])
    var sampler = PerformanceCPUSampler { values.next() }
    let origin = ContinuousClock().now

    sampler.prime(at: origin)
    XCTAssertNil(sampler.sample(at: origin.advanced(by: .seconds(1))))
    XCTAssertNil(sampler.sample(at: origin.advanced(by: .seconds(2))))
    XCTAssertEqual(sampler.sample(at: origin.advanced(by: .seconds(3))), 200)
    XCTAssertEqual(sampler.sample(at: origin.advanced(by: .seconds(4))), 0)
  }

  func testCPUSamplerPreservesBaselineAcrossReadFailureAndRebaselinesRegression() {
    let values = LockedValues<Double?>([1, nil, 5, 4, 6])
    var sampler = PerformanceCPUSampler { values.next() }
    let origin = ContinuousClock().now

    sampler.prime(at: origin)
    XCTAssertNil(sampler.sample(at: origin.advanced(by: .seconds(1))))
    XCTAssertEqual(sampler.sample(at: origin.advanced(by: .seconds(2))), 200)
    XCTAssertNil(sampler.sample(at: origin.advanced(by: .seconds(3))))
    XCTAssertEqual(sampler.sample(at: origin.advanced(by: .seconds(4))), 200)
  }

  func testCPUSamplerRejectsInvalidValuesAndNonfinitePercentagesThenRecovers() {
    let values = LockedValues<Double?>([0, .nan, Double.greatestFiniteMagnitude, 4, 6])
    var sampler = PerformanceCPUSampler { values.next() }
    let origin = ContinuousClock().now

    sampler.prime(at: origin)
    XCTAssertNil(sampler.sample(at: origin.advanced(by: .seconds(1))))
    XCTAssertNil(sampler.sample(at: origin.advanced(by: .nanoseconds(1))))
    XCTAssertNil(sampler.sample(at: origin.advanced(by: .seconds(2))))
    XCTAssertEqual(sampler.sample(at: origin.advanced(by: .seconds(3))), 200)
  }

  func testDisplayAccumulatorUsesExactCallbackCadenceAndResets() {
    var accumulator = PerformanceDisplayAccumulator()
    XCTAssertNil(accumulator.consumeEstimatedFramesPerSecond())
    accumulator.record(timestamp: 10)
    XCTAssertNil(accumulator.consumeEstimatedFramesPerSecond())

    for index in 0...60 {
      accumulator.record(timestamp: 20 + Double(index) / 60)
    }
    XCTAssertEqual(accumulator.consumeEstimatedFramesPerSecond() ?? 0, 60, accuracy: 0.000_001)
    XCTAssertNil(accumulator.consumeEstimatedFramesPerSecond())
  }

  func testDisplayAccumulatorRejectsEqualRegressingAndNonfiniteTimestamps() {
    let invalidSequences: [[Double]] = [
      [1, 1],
      [2, 1],
      [1, .infinity],
    ]
    for sequence in invalidSequences {
      var accumulator = PerformanceDisplayAccumulator()
      for timestamp in sequence { accumulator.record(timestamp: timestamp) }
      XCTAssertNil(accumulator.consumeEstimatedFramesPerSecond())
    }
  }

  func testDisplayAccumulatorReportsExactHighAndDelayedCadence() {
    var accumulator = PerformanceDisplayAccumulator()
    accumulator.record(timestamp: 1)
    accumulator.record(timestamp: 1 + 1.0 / 120.0)
    XCTAssertEqual(accumulator.consumeEstimatedFramesPerSecond() ?? 0, 120, accuracy: 0.000_001)

    accumulator.record(timestamp: 10)
    accumulator.record(timestamp: 10.5)
    XCTAssertEqual(accumulator.consumeEstimatedFramesPerSecond(), 2)
  }

  func testManagedBatteryOwnershipRestoresOnlyWithoutConflict() {
    var ownership = PerformanceBatteryOwnership()
    XCTAssertEqual(ownership.claim(currentValue: false), true)
    XCTAssertNil(ownership.claim(currentValue: true))
    XCTAssertTrue(ownership.observe(currentValue: true))
    XCTAssertNil(ownership.release(currentValue: true))
    XCTAssertEqual(ownership.release(currentValue: true), false)
    XCTAssertEqual(ownership.claimCount, 0)

    XCTAssertEqual(ownership.claim(currentValue: false), true)
    XCTAssertFalse(ownership.observe(currentValue: false))
    XCTAssertNil(ownership.release(currentValue: false))
    XCTAssertEqual(ownership.claimCount, 0)
  }

  func testCancelledOrAuthorizedStartAttemptRejectsLaterResourceAcquisition() {
    let cancelledCounter = LockedCounter()
    let cancelled = PerformanceStartAttempt(priorState: .stopped)
    cancelled.cancel()
    let cancelledValue = cancelled.performAcquisition {
      cancelledCounter.increment()
      return 1
    }
    XCTAssertNil(cancelledValue)
    XCTAssertEqual(cancelledCounter.value, 0)

    let authorizedCounter = LockedCounter()
    let authorized = PerformanceStartAttempt(priorState: .stopped)
    XCTAssertTrue(authorized.authorizeActivation())
    let authorizedValue = authorized.performAcquisition {
      authorizedCounter.increment()
      return 1
    }
    XCTAssertNil(authorizedValue)
    XCTAssertEqual(authorizedCounter.value, 0)

    authorized.cancel()
    XCTAssertFalse(authorized.commitActivation())
  }

  func testProjectionProducesExactSortedUnavailableInventory() throws {
    let configuration = try NearWirePerformanceConfiguration(
      processMetricsEnabled: false,
      displayMetricsEnabled: true,
      deviceMetricsEnabled: false,
      transportMetricsEnabled: true
    )
    let snapshot = try PerformanceSnapshotProjection.makeSnapshot(
      configuration: configuration,
      sampledAt: Date(timeIntervalSince1970: 0),
      intervalMilliseconds: 1_000,
      reading: PerformanceCollectedReading(
        display: PerformanceDisplayReading(estimatedFramesPerSecond: 60),
        transport: PerformanceTransportReading(uplinkQueueDepth: 0, droppedEventCount: 0)
      )
    )

    XCTAssertEqual(snapshot.display?.estimatedFramesPerSecond, 60)
    XCTAssertEqual(snapshot.transport?.uplinkQueueDepth, 0)
    XCTAssertEqual(snapshot.transport?.droppedEventCount, 0)
    let keys = snapshot.unavailable.map(\.metric)
    XCTAssertEqual(keys, keys.sorted())
    XCTAssertEqual(Set(keys).count, keys.count)
    XCTAssertEqual(reason("display.maximumFramesPerSecond", in: snapshot), .unsupported)
    XCTAssertEqual(reason("device.gpuUtilization", in: snapshot), .disabled)
    XCTAssertEqual(reason("process.cpuPercent", in: snapshot), .disabled)
    XCTAssertEqual(reason("transport.downlinkQueueDepth", in: snapshot), .unsupported)
  }

  func testProjectionRoundTripsPresentZeroUnknownAndStableUnsupportedValues() throws {
    let configuration = NearWirePerformanceConfiguration.default
    let snapshot = try PerformanceSnapshotProjection.makeSnapshot(
      configuration: configuration,
      sampledAt: Date(timeIntervalSince1970: 1_700_000_000),
      intervalMilliseconds: 1_000,
      reading: PerformanceCollectedReading(
        process: PerformanceProcessReading(cpuPercent: 0, memoryFootprintBytes: 0),
        display: PerformanceDisplayReading(estimatedFramesPerSecond: 120),
        device: PerformanceDeviceReading(
          batteryLevel: 0,
          batteryState: .unknown,
          thermalState: .unknown,
          lowPowerModeEnabled: false
        ),
        transport: PerformanceTransportReading(uplinkQueueDepth: 0, droppedEventCount: 0)
      )
    )

    XCTAssertEqual(snapshot.process?.cpuPercent, 0)
    XCTAssertEqual(snapshot.process?.memoryFootprintBytes, 0)
    XCTAssertEqual(snapshot.device?.batteryState, .unknown)
    XCTAssertEqual(snapshot.device?.thermalState, .unknown)
    XCTAssertEqual(
      snapshot.unavailable.map(\.metric),
      [
        "device.gpuUtilization",
        "device.powerWatts",
        "device.temperatureCelsius",
        "display.maximumFramesPerSecond",
        "transport.downlinkBytesPerSecond",
        "transport.downlinkQueueDepth",
        "transport.uplinkBytesPerSecond",
      ])

    let encoded = try JSONEncoder().encode(snapshot)
    XCTAssertEqual(try JSONDecoder().decode(PerformanceSnapshot.self, from: encoded), snapshot)
  }

  func testProjectionDistinguishesPermissionTemporaryDisabledAndPresentValues() throws {
    let configuration = try NearWirePerformanceConfiguration(
      displayMetricsEnabled: false,
      deviceMetricsEnabled: false,
      transportMetricsEnabled: false
    )
    let snapshot = try PerformanceSnapshotProjection.makeSnapshot(
      configuration: configuration,
      sampledAt: Date(timeIntervalSince1970: 0),
      intervalMilliseconds: 1,
      reading: PerformanceCollectedReading(
        process: PerformanceProcessReading(cpuPercent: 0, memoryFootprintBytes: nil),
        unavailableReasons: [.processMemoryFootprintBytes: .permissionDenied]
      )
    )

    XCTAssertEqual(snapshot.process?.cpuPercent, 0)
    XCTAssertNil(snapshot.process?.memoryFootprintBytes)
    XCTAssertEqual(reason("process.memoryFootprintBytes", in: snapshot), .permissionDenied)
    XCTAssertEqual(reason("display.maximumFramesPerSecond", in: snapshot), .disabled)
    XCTAssertEqual(reason("device.gpuUtilization", in: snapshot), .disabled)
    XCTAssertEqual(reason("transport.uplinkQueueDepth", in: snapshot), .disabled)
    XCTAssertEqual(snapshot.unavailable.map(\.metric), snapshot.unavailable.map(\.metric).sorted())
    XCTAssertEqual(Set(snapshot.unavailable.map(\.metric)).count, snapshot.unavailable.count)
  }

  func testInstallationCorrelatedEnvelopeFixtureDecodesPerformanceContent() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("IntegrationTests")
      .appendingPathComponent("Fixtures")
      .appendingPathComponent("Performance")
      .appendingPathComponent("InstallationCorrelatedEnvelope.json")
    let data = try Data(contentsOf: fixtureURL)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let body = try XCTUnwrap(root["body"] as? [String: Any])
    let source = try XCTUnwrap(body["source"] as? [String: Any])
    let content = try XCTUnwrap(body["content"])
    let contentData = try JSONSerialization.data(withJSONObject: content)
    let rawContent = try JSONValue.decodeJSON(from: contentData)
    let snapshot = try EventContentCodec().decode(PerformanceSnapshot.self, from: rawContent)

    XCTAssertEqual(body["type"] as? String, "nearwire.performance.snapshot")
    XCTAssertEqual(source["role"] as? String, "app")
    XCTAssertFalse(try XCTUnwrap(source["id"] as? String).isEmpty)
    XCTAssertEqual(snapshot.schemaVersion, 1)
    XCTAssertEqual(snapshot.process?.cpuPercent, 0)
  }

  func testDisabledCollectorGroupsPerformNoReads() async throws {
    let processReads = LockedCounter()
    let memoryReads = LockedCounter()
    let transportReads = LockedCounter()
    let platform = PerformanceCountingPlatform()
    let configuration = try NearWirePerformanceConfiguration(
      processMetricsEnabled: false,
      displayMetricsEnabled: false,
      deviceMetricsEnabled: false,
      transportMetricsEnabled: true
    )
    let collector = LivePerformanceCollectorSession(
      configuration: configuration,
      platform: platform,
      readCPUSeconds: {
        processReads.increment()
        return 0
      },
      readMemoryFootprint: {
        memoryReads.increment()
        return 0
      },
      readTransport: {
        transportReads.increment()
        return nil
      }
    )

    _ = await collector.activate(clock: .live)
    let reading = await collector.sample(at: ContinuousClock().now)
    XCTAssertNil(reading.process)
    XCTAssertNil(reading.display)
    XCTAssertNil(reading.device)
    XCTAssertNotNil(reading.transport)
    XCTAssertEqual(processReads.value, 0)
    XCTAssertEqual(memoryReads.value, 0)
    XCTAssertEqual(transportReads.value, 1)
    let platformActivationCount = await platform.activationCount
    let platformSampleCount = await platform.sampleCount
    XCTAssertEqual(platformActivationCount, 1)
    XCTAssertEqual(platformSampleCount, 0)

    await collector.stop()
    let platformStopCount = await platform.stopCount
    XCTAssertEqual(platformStopCount, 1)
  }

  func testDropProjectionUsesOnlyTerminalRemovalCountersAndSaturates() {
    XCTAssertEqual(
      PerformanceSnapshotProjection.droppedEventCount(
        overflowDropped: 3,
        expired: 5,
        routingDropped: 7
      ),
      15
    )
    XCTAssertEqual(
      PerformanceSnapshotProjection.droppedEventCount(
        overflowDropped: UInt64.max,
        expired: 5,
        routingDropped: 7
      ),
      UInt64(Int64.max)
    )
  }

  func testDropProjectionIgnoresExcludedCountersByConstruction() {
    let included = PerformanceSnapshotProjection.droppedEventCount(
      overflowDropped: 3,
      expired: 5,
      routingDropped: 7
    )
    XCTAssertEqual(included, 15)
  }

  private func reason(
    _ key: String,
    in snapshot: PerformanceSnapshot
  ) -> UnavailablePerformanceMetricReason? {
    snapshot.unavailable.first { $0.metric == key }?.reason
  }
}

private final class LockedValues<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Value]

  init(_ values: [Value]) {
    self.values = values
  }

  func next() -> Value {
    lock.withLock { values.removeFirst() }
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }

  func increment() {
    lock.withLock { count += 1 }
  }
}

private actor PerformanceCountingPlatform: PerformancePlatformSession {
  private(set) var activationCount = 0
  private(set) var sampleCount = 0
  private(set) var stopCount = 0

  func activate() {
    activationCount += 1
  }

  func sample() -> (display: PerformanceDisplayReading?, device: PerformanceDeviceReading?) {
    sampleCount += 1
    return (display: nil, device: nil)
  }

  func stop() {
    stopCount += 1
  }
}
