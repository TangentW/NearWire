import XCTest

@testable import NearWireFlowControl

final class EventRateControlTests: XCTestCase {
  func testRateValidationAndConservativeNegotiation() throws {
    let viewer = DirectionalEventRates(
      appUplink: try EventRateLimit(eventsPerSecond: 100),
      appDownlink: try EventRateLimit(eventsPerSecond: 0)
    )
    let app = DirectionalEventRates(
      appUplink: try EventRateLimit(eventsPerSecond: 20),
      appDownlink: try EventRateLimit(eventsPerSecond: 10)
    )
    let effective = try DirectionalEventRates.effective(
      viewerRequested: viewer,
      appMaximum: app
    )

    XCTAssertEqual(effective.appUplink.eventsPerSecond, 20)
    XCTAssertEqual(effective.appDownlink.eventsPerSecond, 0)
    assertFlowError(.invalidRate) {
      _ = try EventRateLimit(eventsPerSecond: -.infinity)
    }
    assertFlowError(.invalidRate) {
      _ = try EventRateLimit(eventsPerSecond: 100_001)
    }
    assertFlowError(.invalidRate) {
      _ = try EventRateLimit(eventsPerSecond: 0.000_000_000_5)
    }
  }

  func testTokenBucketInitialBurstFractionalRefillAndDelay() throws {
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 2),
      startNanoseconds: 0
    )
    XCTAssertEqual(try bucket.availableWholeTokens(atNanoseconds: 0), 4)
    try bucket.consume(4, atNanoseconds: 0)
    XCTAssertEqual(try bucket.availableWholeTokens(atNanoseconds: 250_000_000), 0)
    XCTAssertEqual(
      try bucket.delayUntilNextTokenNanoseconds(atNanoseconds: 250_000_000),
      250_000_000
    )
    XCTAssertEqual(try bucket.availableWholeTokens(atNanoseconds: 500_000_000), 1)
  }

  func testConsumptionCannotExceedWholeTokens() throws {
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 1),
      burstDurationSeconds: 1,
      startNanoseconds: 0
    )
    try bucket.consume(1, atNanoseconds: 0)
    assertFlowError(.invalidTokenCount) {
      try bucket.consume(1, atNanoseconds: 500_000_000)
    }
    XCTAssertEqual(bucket.availableTokens, 0)
  }

  func testPauseResumeAndRateDecreaseDoNotCreateTokens() throws {
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 10),
      startNanoseconds: 0
    )
    try bucket.consume(15, atNanoseconds: 0)
    try bucket.reconfigure(
      rate: EventRateLimit(eventsPerSecond: 2),
      atNanoseconds: 500_000_000
    )
    XCTAssertLessThanOrEqual(bucket.availableTokens, 4)

    try bucket.reconfigure(
      rate: EventRateLimit(eventsPerSecond: 0),
      atNanoseconds: 500_000_000
    )
    XCTAssertEqual(bucket.availableTokens, 0)
    XCTAssertNil(try bucket.delayUntilNextTokenNanoseconds(atNanoseconds: 500_000_000))

    try bucket.reconfigure(
      rate: EventRateLimit(eventsPerSecond: 2),
      atNanoseconds: 500_000_000
    )
    XCTAssertEqual(bucket.availableTokens, 0)
    XCTAssertEqual(try bucket.availableWholeTokens(atNanoseconds: 1_000_000_000), 1)
  }

  func testBackwardClockIsAtomic() throws {
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 1),
      startNanoseconds: 100
    )
    let before = bucket
    assertFlowError(.invalidClock) {
      _ = try bucket.availableWholeTokens(atNanoseconds: 99)
    }
    XCTAssertEqual(bucket, before)
  }

  func testLargeElapsedTimeClampsToCapacity() throws {
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 100_000),
      burstDurationSeconds: 60,
      startNanoseconds: 0
    )
    try bucket.consume(6_000_000, atNanoseconds: 0)
    XCTAssertEqual(try bucket.availableWholeTokens(atNanoseconds: UInt64.max), 6_000_000)
    XCTAssertEqual(bucket.availableTokens, bucket.capacity)
  }

  func testSubOneRateCanAccumulateAndProduceWholeTokens() throws {
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 0.1),
      startNanoseconds: 0
    )
    XCTAssertEqual(bucket.capacity, 1)
    XCTAssertEqual(try bucket.availableWholeTokens(atNanoseconds: 0), 1)
    try bucket.consume(1, atNanoseconds: 0)
    XCTAssertEqual(try bucket.availableWholeTokens(atNanoseconds: 9_999_999_999), 0)
    let finalNanosecondDelay = try XCTUnwrap(
      bucket.delayUntilNextTokenNanoseconds(atNanoseconds: 9_999_999_999)
    )
    XCTAssertTrue((1...2).contains(finalNanosecondDelay))
    XCTAssertEqual(try bucket.availableWholeTokens(atNanoseconds: 10_000_000_000), 1)
  }

  func testResumeAtSubOneRateDoesNotManufactureToken() throws {
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 0),
      startNanoseconds: 0
    )
    try bucket.reconfigure(
      rate: EventRateLimit(eventsPerSecond: 0.1),
      atNanoseconds: 1_000
    )
    XCTAssertEqual(bucket.capacity, 1)
    XCTAssertEqual(bucket.availableTokens, 0)
    XCTAssertEqual(
      try bucket.availableWholeTokens(atNanoseconds: 10_000_001_000),
      1
    )
  }

  func testBurstReconfigurationClampsWithoutManufacturingTokens() throws {
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 10),
      burstDurationSeconds: 2,
      startNanoseconds: 0
    )
    try bucket.consume(5, atNanoseconds: 0)

    try bucket.reconfigure(
      rate: EventRateLimit(eventsPerSecond: 10),
      burstDurationSeconds: 1,
      atNanoseconds: 0
    )
    XCTAssertEqual(bucket.capacity, 10)
    XCTAssertEqual(bucket.availableTokens, 10)
    try bucket.consume(4, atNanoseconds: 0)

    try bucket.reconfigure(
      rate: EventRateLimit(eventsPerSecond: 10),
      burstDurationSeconds: 3,
      atNanoseconds: 0
    )
    XCTAssertEqual(bucket.capacity, 30)
    XCTAssertEqual(bucket.availableTokens, 6)
  }

  func testInvalidBurstReconfigurationIsAtomic() throws {
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 10),
      startNanoseconds: 100
    )
    let before = bucket

    assertFlowError(.invalidRate) {
      try bucket.reconfigure(
        rate: EventRateLimit(eventsPerSecond: 10),
        burstDurationSeconds: 0,
        atNanoseconds: 100
      )
    }
    XCTAssertEqual(bucket, before)
  }

  func testMinimumPositiveRateHasRepresentableNextTokenDelay() throws {
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: EventRateLimit.minimumPositiveEventsPerSecond),
      startNanoseconds: 0
    )
    try bucket.consume(1, atNanoseconds: 0)
    let delay = try XCTUnwrap(bucket.delayUntilNextTokenNanoseconds(atNanoseconds: 0))
    XCTAssertGreaterThan(delay, 0)
    XCTAssertLessThan(delay, UInt64.max)
    XCTAssertEqual(try bucket.availableWholeTokens(atNanoseconds: delay), 1)
  }
}
