import XCTest

@testable import NearWireFlowControl

final class EventBatchSchedulerTests: XCTestCase {
  func testEarlyAndExactlyDueFlush() throws {
    let queueLimits = try EventQueueLimits(
      maximumEventCount: 10,
      maximumTotalBytes: 1_000,
      maximumSingleEventBytes: 100
    )
    let batchLimits = try EventBatchLimits(
      maximumEventCount: 2,
      maximumAccountedBytes: 100,
      flushIntervalNanoseconds: 500_000_000,
      queueLimits: queueLimits
    )
    var queue = BoundedEventQueue<String>(limits: queueLimits)
    _ = try queue.enqueue(makeTestEvent(1, bytes: 40), nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(makeTestEvent(2, bytes: 40), nowOnQueueClockNanoseconds: 0)
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 10),
      startNanoseconds: 0
    )
    var scheduler = try EventBatchScheduler(
      limits: batchLimits,
      queueLimits: queueLimits,
      startNanoseconds: 0
    )

    XCTAssertNil(
      try scheduler.drainIfDue(
        queue: &queue,
        tokenBucket: &bucket,
        nowNanoseconds: 499_999_999
      )
    )
    XCTAssertEqual(queue.eventCount, 2)
    let attempt = try scheduler.drainIfDue(
      queue: &queue,
      tokenBucket: &bucket,
      nowNanoseconds: 500_000_000
    )
    XCTAssertEqual(attempt?.batch?.events.count, 2)
    XCTAssertEqual(attempt?.batch?.accountedByteCount, 80)
    XCTAssertEqual(attempt?.expiredEventIDs, [])
    XCTAssertEqual(scheduler.nextFlushDeadlineNanoseconds, 1_000_000_000)
  }

  func testByteBoundConsumesOnlySelectedTokenAndPreservesNextEvent() throws {
    let queueLimits = try EventQueueLimits(
      maximumEventCount: 10,
      maximumTotalBytes: 1_000,
      maximumSingleEventBytes: 60
    )
    let batchLimits = try EventBatchLimits(
      maximumEventCount: 10,
      maximumAccountedBytes: 100,
      flushIntervalNanoseconds: 1_000_000,
      queueLimits: queueLimits
    )
    var queue = BoundedEventQueue<String>(limits: queueLimits)
    let first = try makeTestEvent(1, bytes: 60)
    let second = try makeTestEvent(2, bytes: 60)
    _ = try queue.enqueue(first, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(second, nowOnQueueClockNanoseconds: 0)
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 5),
      startNanoseconds: 0
    )
    var scheduler = try EventBatchScheduler(
      limits: batchLimits,
      queueLimits: queueLimits,
      startNanoseconds: 0
    )

    let attempt = try scheduler.drainIfDue(
      queue: &queue,
      tokenBucket: &bucket,
      nowNanoseconds: 1_000_000
    )
    XCTAssertEqual(attempt?.batch?.events.map(\.id), [first.id])
    XCTAssertEqual(bucket.availableTokens, 9)
    XCTAssertEqual(queue.eventCount, 1)

    let nextAttempt = try scheduler.drainIfDue(
      queue: &queue,
      tokenBucket: &bucket,
      nowNanoseconds: 2_000_000
    )
    XCTAssertEqual(nextAttempt?.batch?.events.map(\.id), [second.id])
  }

  func testPausedAndEmptyDueAttemptsAdvanceWithoutCatchUp() throws {
    let queueLimits = try EventQueueLimits(
      maximumEventCount: 10,
      maximumTotalBytes: 1_000,
      maximumSingleEventBytes: 100
    )
    let batchLimits = try EventBatchLimits(
      maximumEventCount: 10,
      maximumAccountedBytes: 100,
      flushIntervalNanoseconds: 100_000_000,
      queueLimits: queueLimits
    )
    var queue = BoundedEventQueue<String>(limits: queueLimits)
    _ = try queue.enqueue(makeTestEvent(1), nowOnQueueClockNanoseconds: 0)
    var paused = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 0),
      startNanoseconds: 0
    )
    var scheduler = try EventBatchScheduler(
      limits: batchLimits,
      queueLimits: queueLimits,
      startNanoseconds: 0
    )

    let pausedAttempt = try scheduler.drainIfDue(
      queue: &queue,
      tokenBucket: &paused,
      nowNanoseconds: 1_000_000_000
    )
    XCTAssertNotNil(pausedAttempt)
    XCTAssertNil(pausedAttempt?.batch)
    XCTAssertEqual(pausedAttempt?.expiredEventIDs, [])
    XCTAssertEqual(queue.eventCount, 1)
    XCTAssertEqual(scheduler.nextFlushDeadlineNanoseconds, 1_100_000_000)

    var emptyQueue = BoundedEventQueue<String>(limits: queueLimits)
    let emptyAttempt = try scheduler.drainIfDue(
      queue: &emptyQueue,
      tokenBucket: &paused,
      nowNanoseconds: 1_100_000_000
    )
    XCTAssertNotNil(emptyAttempt)
    XCTAssertNil(emptyAttempt?.batch)
    XCTAssertEqual(scheduler.nextFlushDeadlineNanoseconds, 1_200_000_000)
  }

  func testRuntimeQueueCompatibilityAndBackwardClockFailAtomically() throws {
    let queueLimits = try EventQueueLimits(
      maximumEventCount: 10,
      maximumTotalBytes: 1_000,
      maximumSingleEventBytes: 100
    )
    let incompatibleBatch = try EventBatchLimits(
      maximumEventCount: 10,
      maximumAccountedBytes: 50,
      flushIntervalNanoseconds: 1_000_000
    )
    var queue = BoundedEventQueue<String>(limits: queueLimits)
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 1),
      startNanoseconds: 0
    )
    assertFlowError(.invalidBatchConfiguration) {
      _ = try EventBatchScheduler(
        limits: incompatibleBatch,
        queueLimits: queueLimits,
        startNanoseconds: 0
      )
    }

    let configuredQueueLimits = try EventQueueLimits(
      maximumEventCount: 10,
      maximumTotalBytes: 1_000,
      maximumSingleEventBytes: 50
    )
    var scheduler = try EventBatchScheduler(
      limits: incompatibleBatch,
      queueLimits: configuredQueueLimits,
      startNanoseconds: 0
    )
    assertFlowError(.invalidBatchConfiguration) {
      _ = try scheduler.drainIfDue(
        queue: &queue,
        tokenBucket: &bucket,
        nowNanoseconds: 1_000_000
      )
    }

    let compatible = try EventBatchLimits(queueLimits: queueLimits)
    scheduler = try EventBatchScheduler(
      limits: compatible,
      queueLimits: queueLimits,
      startNanoseconds: 100
    )
    let before = scheduler
    assertFlowError(.invalidClock) {
      _ = try scheduler.drainIfDue(
        queue: &queue,
        tokenBucket: &bucket,
        nowNanoseconds: 99
      )
    }
    XCTAssertEqual(scheduler, before)
  }

  func testTokenAndBatchConfigurationBounds() throws {
    let queueLimits = try EventQueueLimits(
      maximumEventCount: 10,
      maximumTotalBytes: 1_000,
      maximumSingleEventBytes: 100
    )
    assertFlowError(.invalidBatchConfiguration) {
      _ = try EventBatchLimits(maximumEventCount: 0)
    }
    assertFlowError(.invalidBatchConfiguration) {
      _ = try EventBatchLimits(maximumAccountedBytes: 99, queueLimits: queueLimits)
    }

    var queue = BoundedEventQueue<String>(limits: queueLimits)
    _ = try queue.enqueue(makeTestEvent(1), nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(makeTestEvent(2), nowOnQueueClockNanoseconds: 0)
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 1),
      burstDurationSeconds: 1,
      startNanoseconds: 0
    )
    let limits = try EventBatchLimits(
      maximumEventCount: 10,
      maximumAccountedBytes: 100,
      flushIntervalNanoseconds: 1_000_000,
      queueLimits: queueLimits
    )
    var scheduler = try EventBatchScheduler(
      limits: limits,
      queueLimits: queueLimits,
      startNanoseconds: 0
    )
    let attempt = try scheduler.drainIfDue(
      queue: &queue,
      tokenBucket: &bucket,
      nowNanoseconds: 1_000_000
    )
    XCTAssertEqual(attempt?.batch?.events.count, 1)
    XCTAssertEqual(queue.eventCount, 1)
  }

  func testDueAttemptReportsExpiredIDsEvenWhenPaused() throws {
    let queueLimits = try EventQueueLimits(
      maximumEventCount: 10,
      maximumTotalBytes: 1_000,
      maximumSingleEventBytes: 100
    )
    let limits = try EventBatchLimits(
      maximumEventCount: 10,
      maximumAccountedBytes: 100,
      flushIntervalNanoseconds: 1_000_000,
      queueLimits: queueLimits
    )
    let expiring = try makeTestEvent(1, ttlMilliseconds: 1)
    var queue = BoundedEventQueue<String>(limits: queueLimits)
    _ = try queue.enqueue(expiring, nowOnQueueClockNanoseconds: 0)
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 0),
      startNanoseconds: 0
    )
    var scheduler = try EventBatchScheduler(
      limits: limits,
      queueLimits: queueLimits,
      startNanoseconds: 0
    )

    let attempt = try scheduler.drainIfDue(
      queue: &queue,
      tokenBucket: &bucket,
      nowNanoseconds: 1_000_000
    )

    XCTAssertNil(attempt?.batch)
    XCTAssertEqual(attempt?.expiredEventIDs, [expiring.id])
    XCTAssertEqual(queue.eventCount, 0)
    XCTAssertEqual(queue.statistics.expired, 1)
  }

  func testTokenBackedDueAttemptReportsExpirationAlongsideLiveBatch() throws {
    let queueLimits = try EventQueueLimits(
      maximumEventCount: 10,
      maximumTotalBytes: 1_000,
      maximumSingleEventBytes: 100
    )
    let limits = try EventBatchLimits(
      maximumEventCount: 10,
      maximumAccountedBytes: 100,
      flushIntervalNanoseconds: 1_000_000,
      queueLimits: queueLimits
    )
    let expired = try makeTestEvent(1, ttlMilliseconds: 1)
    let live = try makeTestEvent(2, ttlMilliseconds: 2)
    var queue = BoundedEventQueue<String>(limits: queueLimits)
    _ = try queue.enqueue(expired, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(live, nowOnQueueClockNanoseconds: 0)
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 1),
      startNanoseconds: 0
    )
    var scheduler = try EventBatchScheduler(
      limits: limits,
      queueLimits: queueLimits,
      startNanoseconds: 0
    )

    let attempt = try scheduler.drainIfDue(
      queue: &queue,
      tokenBucket: &bucket,
      nowNanoseconds: 1_000_000
    )

    XCTAssertEqual(attempt?.batch?.events.map(\.id), [live.id])
    XCTAssertEqual(attempt?.expiredEventIDs, [expired.id])
    XCTAssertEqual(queue.eventCount, 0)
    XCTAssertEqual(queue.statistics.expired, 1)
  }

  func testRepeatedSingleEventScheduledDrainsAtLargeDepth() throws {
    let queueLimits = try EventQueueLimits(
      maximumEventCount: 2_000,
      maximumTotalBytes: 2_000,
      maximumSingleEventBytes: 1
    )
    let limits = try EventBatchLimits(
      maximumEventCount: 1,
      maximumAccountedBytes: 1,
      flushIntervalNanoseconds: 1_000_000,
      queueLimits: queueLimits
    )
    var queue = BoundedEventQueue<String>(limits: queueLimits)
    for number in 1...2_000 {
      _ = try queue.enqueue(makeTestEvent(number), nowOnQueueClockNanoseconds: 0)
    }
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 100_000),
      startNanoseconds: 0
    )
    var scheduler = try EventBatchScheduler(
      limits: limits,
      queueLimits: queueLimits,
      startNanoseconds: 0
    )

    for number in 1...2_000 {
      let attempt = try scheduler.drainIfDue(
        queue: &queue,
        tokenBucket: &bucket,
        nowNanoseconds: UInt64(number) * 1_000_000
      )
      XCTAssertEqual(attempt?.batch?.events.first?.id, try makeTestEvent(number).id)
    }
    XCTAssertEqual(queue.eventCount, 0)
  }

  func testRepeatedPausedFlushesAtHardBoundUseExpirationIndex() throws {
    let queueLimits = try EventQueueLimits(
      maximumEventCount: 10_000,
      maximumTotalBytes: 10_000,
      maximumSingleEventBytes: 1
    )
    let limits = try EventBatchLimits(
      maximumEventCount: 1,
      maximumAccountedBytes: 1,
      flushIntervalNanoseconds: 1_000_000,
      queueLimits: queueLimits
    )
    var queue = BoundedEventQueue<String>(limits: queueLimits)
    for number in 1...10_000 {
      _ = try queue.enqueue(makeTestEvent(number), nowOnQueueClockNanoseconds: 0)
    }
    var bucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 0),
      startNanoseconds: 0
    )
    var scheduler = try EventBatchScheduler(
      limits: limits,
      queueLimits: queueLimits,
      startNanoseconds: 0
    )

    for number in 1...1_000 {
      let attempt = try scheduler.drainIfDue(
        queue: &queue,
        tokenBucket: &bucket,
        nowNanoseconds: UInt64(number) * 1_000_000
      )
      XCTAssertNotNil(attempt)
      XCTAssertNil(attempt?.batch)
      XCTAssertEqual(attempt?.expiredEventIDs, [])
    }
    XCTAssertEqual(queue.eventCount, 10_000)
  }
}
