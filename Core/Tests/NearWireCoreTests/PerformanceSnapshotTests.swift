import Foundation
import XCTest

@testable import NearWireCore

final class PerformanceSnapshotTests: XCTestCase {
  func testCompleteSnapshotRoundTripsThroughContentCodec() throws {
    let snapshot = try PerformanceSnapshot(
      sampledAt: Date(timeIntervalSince1970: 1_700_000_000.125),
      sampleIntervalMilliseconds: 1_000,
      process: ProcessPerformanceMetrics(cpuPercent: 124.5, memoryFootprintBytes: 183_500_800),
      display: DisplayPerformanceMetrics(
        estimatedFramesPerSecond: 59.7,
        maximumFramesPerSecond: 120
      ),
      device: DevicePerformanceMetrics(
        batteryLevel: 0.72,
        batteryState: .unplugged,
        thermalState: .fair,
        lowPowerModeEnabled: false
      ),
      transport: TransportPerformanceMetrics(
        uplinkBytesPerSecond: 8_230,
        downlinkBytesPerSecond: 920,
        uplinkQueueDepth: 4,
        downlinkQueueDepth: 0,
        droppedEventCount: 0
      ),
      unavailable: [
        UnavailablePerformanceMetric(metric: "device.gpuUtilization", reason: .unsupported)
      ]
    )
    let codec = EventContentCodec()
    let content = try codec.encode(snapshot)

    XCTAssertEqual(try codec.decode(PerformanceSnapshot.self, from: content), snapshot)
    XCTAssertEqual(
      try EventType.platform("nearwire.performance.snapshot"),
      try PerformanceSnapshotSchema.eventType()
    )
    assertEventError(.reservedType) {
      _ = try EventType.user("nearwire.performance.snapshot")
    }
  }

  func testMetricBoundariesAndRealZeroArePreserved() throws {
    let snapshot = try PerformanceSnapshot(
      sampledAt: Date(timeIntervalSince1970: 0),
      sampleIntervalMilliseconds: 1,
      process: ProcessPerformanceMetrics(cpuPercent: 0, memoryFootprintBytes: 0),
      device: DevicePerformanceMetrics(batteryLevel: 1),
      transport: TransportPerformanceMetrics(droppedEventCount: 0)
    )
    let roundTrip = try EventContentCodec().decode(
      PerformanceSnapshot.self,
      from: EventContentCodec().encode(snapshot)
    )

    XCTAssertEqual(roundTrip.process?.cpuPercent, 0)
    XCTAssertEqual(roundTrip.process?.memoryFootprintBytes, 0)
    XCTAssertEqual(roundTrip.device?.batteryLevel, 1)
    XCTAssertEqual(roundTrip.transport?.droppedEventCount, 0)
  }

  func testMissingAndUnavailableMetricsRemainDistinct() throws {
    let snapshot = try PerformanceSnapshot(
      sampledAt: Date(timeIntervalSince1970: 0),
      sampleIntervalMilliseconds: 1_000,
      process: ProcessPerformanceMetrics(),
      unavailable: [
        UnavailablePerformanceMetric(metric: "process.cpuPercent", reason: .disabled)
      ]
    )

    XCTAssertNil(snapshot.process?.cpuPercent)
    XCTAssertEqual(snapshot.unavailable.first?.metric, "process.cpuPercent")
    XCTAssertEqual(snapshot.unavailable.first?.reason, .disabled)
  }

  func testInvalidSnapshotHeadersAndMetricsReportPaths() throws {
    assertEventError(.invalidSchemaVersion, expectedPath: "schemaVersion") {
      _ = try PerformanceSnapshot(
        schemaVersion: 2,
        sampledAt: Date(),
        sampleIntervalMilliseconds: 1
      )
    }
    assertEventError(.invalidMetric, expectedPath: "sampleIntervalMilliseconds") {
      _ = try PerformanceSnapshot(sampledAt: Date(), sampleIntervalMilliseconds: 0)
    }

    let invalidValues: [(String, () throws -> Void)] = [
      ("process.cpuPercent", { _ = try ProcessPerformanceMetrics(cpuPercent: -1) }),
      ("process.cpuPercent", { _ = try ProcessPerformanceMetrics(cpuPercent: .infinity) }),
      (
        "display.estimatedFramesPerSecond",
        { _ = try DisplayPerformanceMetrics(estimatedFramesPerSecond: 0) }
      ),
      (
        "display.maximumFramesPerSecond",
        { _ = try DisplayPerformanceMetrics(maximumFramesPerSecond: -.infinity) }
      ),
      ("device.batteryLevel", { _ = try DevicePerformanceMetrics(batteryLevel: 1.01) }),
    ]
    for (path, operation) in invalidValues {
      assertEventError(.invalidMetric, expectedPath: path, operation)
    }
    assertEventError(.invalidMetric, expectedPath: "unavailable.metric") {
      _ = try UnavailablePerformanceMetric(metric: "gpu value", reason: .unsupported)
    }
    assertEventError(.invalidMetric, expectedPath: "transport.droppedEventCount") {
      _ = try TransportPerformanceMetrics(droppedEventCount: UInt64(Int64.max) + 1)
    }
  }

  func testEveryRequiredSnapshotHeaderMustBePresent() throws {
    let snapshot = try PerformanceSnapshot(
      sampledAt: Date(timeIntervalSince1970: 0),
      sampleIntervalMilliseconds: 1_000
    )
    let codec = EventContentCodec()
    let content = try codec.encode(snapshot)
    guard case .object(let completeObject) = content else {
      return XCTFail("Expected snapshot content to be a JSON object.")
    }

    for requiredKey in ["schemaVersion", "sampledAt", "sampleIntervalMilliseconds"] {
      var incompleteObject = completeObject
      incompleteObject.removeValue(forKey: requiredKey)
      assertEventError(.contentDecodingFailed) {
        _ = try codec.decode(
          PerformanceSnapshot.self,
          from: .object(incompleteObject)
        )
      }
    }
  }

  func testFutureFieldsAndEnumValuesAreAccepted() throws {
    let json = Data(
      """
      {
        "schemaVersion": 1,
        "sampledAt": "2026-07-11T10:20:30.123Z",
        "sampleIntervalMilliseconds": 1000,
        "device": {
          "batteryState": "future-battery-state",
          "thermalState": "future-thermal-state",
          "futureMetric": 12
        },
        "futureGroup": {"value": 1}
      }
      """.utf8
    )
    let rawContent = try JSONValue.decodeJSON(from: json)
    let snapshot = try EventContentCodec().decode(PerformanceSnapshot.self, from: rawContent)

    XCTAssertEqual(snapshot.device?.batteryState, .unknown)
    XCTAssertEqual(snapshot.device?.thermalState, .unknown)
    guard case .object(let root) = rawContent,
      case .object(let futureGroup)? = root["futureGroup"]
    else {
      return XCTFail("Raw event content did not retain unknown fields.")
    }
    XCTAssertEqual(futureGroup["value"], .integer(1))
  }

  func testSchemaConstructionHasNoObservableSideEffects() throws {
    let snapshot = try PerformanceSnapshot(
      sampledAt: Date(timeIntervalSince1970: 0),
      sampleIntervalMilliseconds: 1_000
    )
    XCTAssertNil(snapshot.process)
    XCTAssertNil(snapshot.display)
    XCTAssertNil(snapshot.device)
    XCTAssertNil(snapshot.transport)
    XCTAssertTrue(snapshot.unavailable.isEmpty)
  }
}
