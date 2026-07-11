import XCTest

@testable import NearWire

final class NearWireConfigurationTests: XCTestCase {
  func testDefaultConfigurationIsBoundedAndDirectional() {
    let configuration = NearWireConfiguration.default
    XCTAssertEqual(configuration.maximumUplinkEventsPerSecond, 100)
    XCTAssertEqual(configuration.maximumDownlinkEventsPerSecond, 50)
    XCTAssertEqual(configuration.buffer.maximumEventCount, 1_000)
    XCTAssertEqual(configuration.buffer.maximumBytes, 4 * 1_024 * 1_024)
    XCTAssertEqual(configuration.buffer.maximumEventBytes, 256 * 1_024)
    XCTAssertEqual(configuration.buffer.defaultTTL, .seconds(60))
    XCTAssertEqual(configuration.eventStreamBufferCapacity, 256)
  }

  func testConfigurationRejectsInvalidRatesAndStreamCapacity() throws {
    for rate in [-1.0, .infinity, .nan, 100_001] {
      XCTAssertThrowsError(
        try NearWireConfiguration(maximumUplinkEventsPerSecond: rate)
      ) { error in
        assertNearWireError(error, code: .invalidConfiguration)
      }
    }

    XCTAssertThrowsError(
      try NearWireConfiguration(eventStreamBufferCapacity: 0)
    ) { error in
      assertNearWireError(error, code: .invalidConfiguration)
    }
  }

  func testBufferConfigurationRejectsIncoherentLimitsAndTTL() {
    XCTAssertThrowsError(
      try NearWireBufferConfiguration(maximumEventCount: 0)
    ) { error in
      assertNearWireError(error, code: .invalidConfiguration)
    }
    XCTAssertThrowsError(
      try NearWireBufferConfiguration(defaultTTL: .milliseconds(0))
    ) { error in
      assertNearWireError(error, code: .invalidEventOptions)
    }
    XCTAssertThrowsError(
      try NearWireBufferConfiguration(defaultTTL: .minutes(UInt64.max))
    ) { error in
      assertNearWireError(error, code: .invalidEventOptions)
    }
  }
}
