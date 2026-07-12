import XCTest

@testable import NearWirePerformance

final class PerformanceConfigurationTests: XCTestCase {
  func testDefaultAndBoundaryIntervalsArePreserved() throws {
    XCTAssertEqual(NearWirePerformanceConfiguration.default.sampleInterval, .seconds(1))
    XCTAssertEqual(
      try NearWirePerformanceConfiguration(sampleInterval: .milliseconds(100))
        .sampleIntervalNanoseconds,
      100_000_000
    )
    XCTAssertEqual(
      try NearWirePerformanceConfiguration(sampleInterval: .seconds(60))
        .sampleIntervalNanoseconds,
      60_000_000_000
    )

    let custom = try NearWirePerformanceConfiguration(
      sampleInterval: .milliseconds(250),
      processMetricsEnabled: false,
      displayMetricsEnabled: true,
      deviceMetricsEnabled: false,
      transportMetricsEnabled: false,
      managesBatteryMonitoring: false
    )
    XCTAssertEqual(custom.sampleInterval, .milliseconds(250))
    XCTAssertFalse(custom.processMetricsEnabled)
    XCTAssertTrue(custom.displayMetricsEnabled)
    XCTAssertFalse(custom.deviceMetricsEnabled)
    XCTAssertFalse(custom.transportMetricsEnabled)
    XCTAssertFalse(custom.managesBatteryMonitoring)
  }

  func testInvalidIntervalsAndAllDisabledReportStableFields() {
    let invalid: [Duration] = [
      .zero,
      .milliseconds(99),
      .seconds(61),
      .seconds(-1),
      .seconds(Int64.max),
      Duration(secondsComponent: 1, attosecondsComponent: 1),
    ]
    for duration in invalid {
      XCTAssertThrowsError(try NearWirePerformanceConfiguration(sampleInterval: duration)) {
        error in
        XCTAssertEqual((error as? NearWirePerformanceError)?.code, .invalidConfiguration)
        XCTAssertEqual((error as? NearWirePerformanceError)?.field, "sampleInterval")
      }
    }

    XCTAssertThrowsError(
      try NearWirePerformanceConfiguration(
        processMetricsEnabled: false,
        displayMetricsEnabled: false,
        deviceMetricsEnabled: false,
        transportMetricsEnabled: false
      )
    ) { error in
      XCTAssertEqual((error as? NearWirePerformanceError)?.field, "metricGroups")
    }
  }

  func testMillisecondRoundingIsHalfUpAndClampedPositive() {
    XCTAssertEqual(
      PerformanceDurationConversion.positiveRoundedMilliseconds(.microseconds(499)),
      1
    )
    XCTAssertEqual(
      PerformanceDurationConversion.positiveRoundedMilliseconds(.microseconds(1_499)),
      1
    )
    XCTAssertEqual(
      PerformanceDurationConversion.positiveRoundedMilliseconds(.microseconds(1_500)),
      2
    )
    XCTAssertEqual(
      PerformanceDurationConversion.positiveRoundedMilliseconds(.seconds(-1)),
      1
    )
    XCTAssertEqual(
      PerformanceDurationConversion.positiveRoundedMilliseconds(.seconds(Int64.max)),
      UInt64(Int64.max)
    )
  }
}
