import NearWire
import XCTest

@testable import NearWirePerformance

#if os(iOS)
  import UIKit
#endif

final class NearWirePerformanceModuleSmokeTests: XCTestCase {
  func testDefaultConfigurationIsAvailable() {
    XCTAssertEqual(NearWirePerformanceConfiguration.default.sampleInterval, .seconds(1))
  }

  func testPrivacyManifestsDeclareOnlyTheirOwnedCollectionType() throws {
    let sdkRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    try assertPrivacyManifest(
      at: sdkRoot.appendingPathComponent("Sources/NearWire/PrivacyInfo.xcprivacy"),
      collectedType: "NSPrivacyCollectedDataTypeDeviceID"
    )
    try assertPrivacyManifest(
      at: sdkRoot.appendingPathComponent("Sources/NearWirePerformance/PrivacyInfo.xcprivacy"),
      collectedType: "NSPrivacyCollectedDataTypePerformanceData"
    )
  }

  #if os(iOS)
    func testLiveIOSCollectorsCanSampleAndStopWithoutDeviceSpecificAssumptions() async {
      let configuration = NearWirePerformanceConfiguration.default
      let attempt = PerformanceStartAttempt(priorState: .stopped)
      let platform = await LivePerformancePlatformSession.make(
        configuration: configuration,
        attempt: attempt
      )
      let collector = LivePerformanceCollectorSession(
        configuration: configuration,
        platform: platform,
        readCPUSeconds: { PerformanceSystemReaders.processCPUSeconds() },
        readMemoryFootprint: { PerformanceSystemReaders.memoryFootprintBytes() },
        readTransport: { nil }
      )
      let initialInstant = await collector.activate(clock: .live)

      let reading = await collector.sample(at: initialInstant.advanced(by: .seconds(1)))

      XCTAssertNotNil(reading.process)
      XCTAssertNotNil(reading.display)
      XCTAssertNotNil(reading.device)
      XCTAssertNotNil(reading.transport)
      if let memoryFootprintBytes = reading.process?.memoryFootprintBytes {
        XCTAssertGreaterThan(memoryFootprintBytes, 0)
      }
      if let batteryLevel = reading.device?.batteryLevel {
        XCTAssertTrue((0...1).contains(batteryLevel))
      }

      await collector.stop()
      let readingAfterStop = await collector.sample(
        at: initialInstant.advanced(by: .seconds(2))
      )
      XCTAssertNil(readingAfterStop.process)
      XCTAssertNil(readingAfterStop.display)
      XCTAssertNil(readingAfterStop.device)
      XCTAssertNil(readingAfterStop.transport)
    }

    func testLiveIOSUnmanagedBatteryModeNeverChangesHostSwitch() async throws {
      let initialValue = await MainActor.run { UIDevice.current.isBatteryMonitoringEnabled }
      let configuration = try NearWirePerformanceConfiguration(
        processMetricsEnabled: false,
        displayMetricsEnabled: false,
        deviceMetricsEnabled: true,
        transportMetricsEnabled: false,
        managesBatteryMonitoring: false
      )
      let platform = await LivePerformancePlatformSession.make(
        configuration: configuration,
        attempt: PerformanceStartAttempt(priorState: .stopped)
      )

      _ = await platform.sample()
      await platform.stop()

      let finalValue = await MainActor.run { UIDevice.current.isBatteryMonitoringEnabled }
      XCTAssertEqual(finalValue, initialValue)
    }
  #endif

  #if os(macOS)
    func testStartIsUnsupportedWithoutChangingStoppedState() async throws {
      let monitor = NearWirePerformanceMonitor(nearWire: NearWire())

      do {
        try await monitor.start()
        XCTFail("Expected unsupported platform failure.")
      } catch let error as NearWirePerformanceError {
        XCTAssertEqual(error.code, .unsupportedPlatform)
      }
      let state = await monitor.currentState
      XCTAssertEqual(state, .stopped)
    }
  #endif

  private func assertPrivacyManifest(at url: URL, collectedType: String) throws {
    let data = try Data(contentsOf: url)
    let root = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    let collected = try XCTUnwrap(root["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    let record = try XCTUnwrap(collected.first)

    XCTAssertEqual(collected.count, 1)
    XCTAssertEqual(record["NSPrivacyCollectedDataType"] as? String, collectedType)
    XCTAssertEqual(record["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
    XCTAssertEqual(record["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
    XCTAssertEqual(
      record["NSPrivacyCollectedDataTypePurposes"] as? [String],
      ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
    )
    XCTAssertEqual(root["NSPrivacyTracking"] as? Bool, false)
    XCTAssertNil(root["NSPrivacyTrackingDomains"])
    XCTAssertNil(root["NSPrivacyAccessedAPITypes"])
  }
}

extension NearWirePerformanceModuleSmokeTests: @unchecked Sendable {}
