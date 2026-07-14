import XCTest

@testable import NearWire

final class NearWireConfigurationTests: XCTestCase {
  func testDefaultConfigurationIsBoundedAndDirectional() {
    let configuration = NearWireConfiguration.default
    XCTAssertEqual(configuration.maximumUplinkEventsPerSecond, 100)
    XCTAssertEqual(configuration.maximumDownlinkEventsPerSecond, 50)
    XCTAssertEqual(configuration.buffer.maximumEventCount, 1_000)
    XCTAssertEqual(configuration.buffer.maximumBytes, 16 * 1_024 * 1_024)
    XCTAssertEqual(configuration.buffer.maximumEventBytes, 4_259_840)
    XCTAssertEqual(configuration.buffer.defaultTTL, .seconds(60))
    XCTAssertEqual(configuration.eventStreamBufferCapacity, 256)
    XCTAssertEqual(configuration.reconnectionPolicy, .disabled)
    XCTAssertFalse(configuration.reconnectionPolicy.isEnabled)
  }

  func testReconnectionPolicyValidatesExactBoundsAndDelayCapping() throws {
    let policy = try NearWireReconnectionPolicy(
      maximumAttempts: 20,
      initialDelay: .milliseconds(100),
      maximumDelay: .seconds(1)
    )
    XCTAssertTrue(policy.isEnabled)
    XCTAssertEqual(policy.maximumAttempts, 20)
    XCTAssertEqual(SDKValidation.reconnectionDelay(policy: policy, attempt: 1), .milliseconds(100))
    XCTAssertEqual(SDKValidation.reconnectionDelay(policy: policy, attempt: 2), .milliseconds(200))
    XCTAssertEqual(SDKValidation.reconnectionDelay(policy: policy, attempt: 5), .seconds(1))
    XCTAssertNil(SDKValidation.reconnectionDelay(policy: policy, attempt: 21))
  }

  func testReconnectionPolicyRejectsInvalidValuesAtFixedFields() {
    assertInvalidReconnectionPolicy(field: "reconnectionPolicy.maximumAttempts") {
      _ = try NearWireReconnectionPolicy(maximumAttempts: 0)
    }
    assertInvalidReconnectionPolicy(field: "reconnectionPolicy.initialDelay") {
      _ = try NearWireReconnectionPolicy(
        maximumAttempts: 1,
        initialDelay: .milliseconds(99)
      )
    }
    assertInvalidReconnectionPolicy(field: "reconnectionPolicy.maximumDelay") {
      _ = try NearWireReconnectionPolicy(
        maximumAttempts: 1,
        initialDelay: .seconds(2),
        maximumDelay: .seconds(1)
      )
    }
    assertInvalidReconnectionPolicy(field: "reconnectionPolicy.initialDelay") {
      _ = try NearWireReconnectionPolicy(
        maximumAttempts: 1,
        initialDelay: Duration(secondsComponent: 1, attosecondsComponent: 1)
      )
    }
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

  func testExplicitSmallerBufferTotalClampsOmittedSingleEventLimit() throws {
    let fourMiB = 4 * 1_024 * 1_024
    let configuration = try NearWireBufferConfiguration(maximumBytes: fourMiB)

    XCTAssertEqual(configuration.maximumBytes, fourMiB)
    XCTAssertEqual(configuration.maximumEventBytes, fourMiB)
    XCTAssertThrowsError(
      try NearWireBufferConfiguration(
        maximumBytes: fourMiB,
        maximumEventBytes: 4_259_840
      )
    ) { error in
      assertNearWireError(error, code: .invalidConfiguration)
    }
  }

  private func assertInvalidReconnectionPolicy(
    field: String,
    operation: () throws -> Void
  ) {
    XCTAssertThrowsError(try operation()) { error in
      guard let error = error as? NearWireError else {
        return XCTFail("Expected NearWireError, got \(error).")
      }
      XCTAssertEqual(error.code, .invalidConfiguration)
      XCTAssertEqual(error.field, field)
    }
  }
}
