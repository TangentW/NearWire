@_spi(NearWireBuiltins) import NearWire
@_spi(NearWireInternal) import NearWireCore
import XCTest

@testable import NearWirePerformance

final class PerformanceStressTests: XCTestCase {
  func testTenThousandDeterministicProjectionsHaveExactWorkCount() throws {
    let configuration = NearWirePerformanceConfiguration.default
    let reading = PerformanceCollectedReading(
      process: PerformanceProcessReading(cpuPercent: 0, memoryFootprintBytes: 0),
      display: PerformanceDisplayReading(estimatedFramesPerSecond: 60),
      device: PerformanceDeviceReading(
        batteryLevel: 0.5,
        batteryState: .charging,
        thermalState: .nominal,
        lowPowerModeEnabled: false
      ),
      transport: PerformanceTransportReading(uplinkQueueDepth: 0, droppedEventCount: 0)
    )
    let started = ContinuousClock().now
    var completed = 0

    for index in 0..<10_000 {
      let snapshot = try PerformanceSnapshotProjection.makeSnapshot(
        configuration: configuration,
        sampledAt: Date(timeIntervalSince1970: Double(index)),
        intervalMilliseconds: 1_000,
        reading: reading
      )
      XCTAssertEqual(snapshot.schemaVersion, 1)
      completed += 1
    }

    let elapsed = started.duration(to: ContinuousClock().now)
    XCTAssertEqual(completed, 10_000)
    XCTAssertGreaterThanOrEqual(elapsed, .zero)
  }

  func testOneThousandStartStopCyclesReleaseExactLeaseAndTaskResources() async throws {
    let clock = PerformanceManualClock()
    let collector = PerformanceFakeCollector()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: clock,
        collector: collector,
        recorder: PerformanceSnapshotRecorder()
      )
    )

    for _ in 0..<1_000 {
      try await monitor.start()
      await monitor.stop()
    }

    let activationCount = await collector.activationCount
    let stopCount = await collector.stopCount
    let state = await monitor.currentState
    XCTAssertEqual(activationCount, 1_000)
    XCTAssertEqual(stopCount, 1_000)
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
    XCTAssertEqual(clock.waiterCount, 0)
  }

  func testDelayedWakeProducesOneSampleAndNoCatchUpBurst() async throws {
    let clock = PerformanceManualClock()
    let recorder = PerformanceSnapshotRecorder()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: clock,
        collector: PerformanceFakeCollector(),
        recorder: recorder
      )
    )

    try await monitor.start()
    try await waitUntil("delayed sleep") { clock.waiterCount == 1 }
    clock.advanceNext(by: .seconds(3))
    try await waitUntil("delayed snapshot") { await recorder.snapshots.count == 1 }
    let snapshot = await recorder.snapshots[0]
    XCTAssertEqual(snapshot.sampleIntervalMilliseconds, 3_000)
    try await waitUntil("successor sleep") { clock.waiterCount == 1 }
    let finalCount = await recorder.snapshots.count
    XCTAssertEqual(finalCount, 1)
    await monitor.stop()
  }

  func testTenThousandBuiltInSnapshotsCoalesceInOrdinaryNearWireQueue() async throws {
    let nearWire = NearWire()

    for sequence in 0..<10_000 {
      _ = try await nearWire.sendPlatformEvent(
        type: "nearwire.performance.snapshot",
        content: PerformanceStressContent(sequence: sequence),
        policy: .keepLatest(key: "nearwire.performance.snapshot")
      )
    }

    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 1)
    XCTAssertEqual(diagnostics.statistics.submitted, 10_000)
    XCTAssertEqual(diagnostics.statistics.coalesced, 9_999)
    XCTAssertEqual(diagnostics.statistics.overflowDropped, 0)
    XCTAssertEqual(diagnostics.statistics.expired, 0)
    XCTAssertEqual(diagnostics.statistics.routingDropped, 0)
  }
}

extension PerformanceStressTests: @unchecked Sendable {}

private struct PerformanceStressContent: Codable, Sendable {
  let sequence: Int
}
