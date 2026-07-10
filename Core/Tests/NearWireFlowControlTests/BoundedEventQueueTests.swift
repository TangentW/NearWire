import XCTest

@testable import NearWireCore
@testable import NearWireFlowControl

final class BoundedEventQueueTests: XCTestCase {
  func testDefaultAndInvalidConfiguration() throws {
    XCTAssertEqual(EventQueueLimits.default.maximumEventCount, 1_000)
    XCTAssertEqual(EventQueueLimits.default.maximumTotalBytes, 4 * 1_024 * 1_024)
    XCTAssertEqual(EventQueueLimits.default.maximumSingleEventBytes, 256 * 1_024)

    assertFlowError(.invalidQueueConfiguration) {
      _ = try EventQueueLimits(maximumEventCount: 0)
    }
    XCTAssertEqual(
      try EventQueueLimits(maximumEventCount: 10_000).maximumEventCount,
      10_000
    )
    assertFlowError(.invalidQueueConfiguration) {
      _ = try EventQueueLimits(maximumEventCount: 10_001)
    }
    assertFlowError(.invalidQueueConfiguration) {
      _ = try EventQueueLimits(maximumTotalBytes: 100, maximumSingleEventBytes: 101)
    }
    assertFlowError(.invalidKeepLatestKey) {
      _ = try KeepLatestKey("bad\nkey")
    }
    assertFlowError(.invalidKeepLatestKey) {
      _ = try KeepLatestKey("bad\u{0085}key")
    }
    for value in Array(0...0x1F) + Array(0x7F...0x9F) {
      guard let scalar = UnicodeScalar(value) else {
        return XCTFail("Expected a valid control scalar for \(value).")
      }
      assertFlowError(.invalidKeepLatestKey) {
        _ = try KeepLatestKey("bad\(scalar)key")
      }
    }
    assertFlowError(.invalidEntry) {
      _ = try makeTestEvent(1, bytes: 0)
    }
  }

  func testCriticalPriorityCodableRoundTrip() throws {
    let data = try JSONEncoder().encode(EventPriority.critical)
    XCTAssertEqual(try JSONDecoder().decode(EventPriority.self, from: data), .critical)
  }

  func testNormalEventsRemainDistinctAndCountOverflowEvictsOldestLowPriority() throws {
    let limits = try EventQueueLimits(
      maximumEventCount: 2,
      maximumTotalBytes: 100,
      maximumSingleEventBytes: 100
    )
    var queue = BoundedEventQueue<String>(limits: limits)
    let first = try makeTestEvent(1, priority: .low)
    let second = try makeTestEvent(2, priority: .normal)
    let third = try makeTestEvent(3, priority: .critical)
    _ = try queue.enqueue(first, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(second, nowOnQueueClockNanoseconds: 0)
    let result = try queue.enqueue(third, nowOnQueueClockNanoseconds: 0)

    XCTAssertEqual(result.overflowDroppedEventIDs, [first.id])
    XCTAssertTrue(result.isBuffered)
    XCTAssertEqual(queue.eventCount, 2)
  }

  func testIncomingLowPriorityCanBeDroppedToProtectCriticalWork() throws {
    let limits = try EventQueueLimits(
      maximumEventCount: 2,
      maximumTotalBytes: 100,
      maximumSingleEventBytes: 100
    )
    var queue = BoundedEventQueue<String>(limits: limits)
    _ = try queue.enqueue(makeTestEvent(1, priority: .critical), nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(makeTestEvent(2, priority: .critical), nowOnQueueClockNanoseconds: 0)
    let incoming = try makeTestEvent(3, priority: .low)
    let result = try queue.enqueue(incoming, nowOnQueueClockNanoseconds: 0)

    XCTAssertFalse(result.isBuffered)
    XCTAssertEqual(result.overflowDroppedEventIDs, [incoming.id])
    XCTAssertEqual(try queue.snapshot(nowOnQueueClockNanoseconds: 0).priorityCounts.critical, 2)
  }

  func testByteOverflowCanRequireMultipleEvictions() throws {
    let limits = try EventQueueLimits(
      maximumEventCount: 10,
      maximumTotalBytes: 100,
      maximumSingleEventBytes: 70
    )
    var queue = BoundedEventQueue<String>(limits: limits)
    let first = try makeTestEvent(1, priority: .low, bytes: 20)
    let second = try makeTestEvent(2, priority: .low, bytes: 20)
    _ = try queue.enqueue(first, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(second, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(
      makeTestEvent(3, priority: .normal, bytes: 20), nowOnQueueClockNanoseconds: 0)
    let result = try queue.enqueue(
      makeTestEvent(4, priority: .critical, bytes: 70),
      nowOnQueueClockNanoseconds: 0
    )

    XCTAssertEqual(result.overflowDroppedEventIDs, [first.id, second.id])
    XCTAssertEqual(queue.accountedByteCount, 90)
  }

  func testKeepLatestReplacesMetadataAndRetainsLogicalOrdinal() throws {
    let key = try KeepLatestKey("route")
    var queue = BoundedEventQueue<String>()
    let old = try makeTestEvent(1, value: "old", priority: .low, policy: .keepLatest(key))
    let later = try makeTestEvent(2, value: "later", priority: .low)
    let replacement = try makeTestEvent(
      3,
      value: "new",
      priority: .low,
      ttlMilliseconds: 1_000,
      policy: .keepLatest(key),
      bytes: 2,
      enqueuedAt: 100
    )
    _ = try queue.enqueue(old, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(later, nowOnQueueClockNanoseconds: 0)
    let result = try queue.enqueue(replacement, nowOnQueueClockNanoseconds: 100)
    let drained = try queue.dequeue(
      maximumCount: 2,
      maximumBytes: 10,
      nowOnQueueClockNanoseconds: 100
    )

    XCTAssertEqual(result.coalescedEventID, old.id)
    XCTAssertEqual(drained.events.map(\.id), [replacement.id, later.id])
    XCTAssertEqual(drained.events.first?.value, "new")
    XCTAssertEqual(drained.events.first?.accountedByteCount, 2)
  }

  func testGrowingReplacementCoalescesBeforeOverflow() throws {
    let limits = try EventQueueLimits(
      maximumEventCount: 3,
      maximumTotalBytes: 10,
      maximumSingleEventBytes: 10
    )
    let key = try KeepLatestKey("state")
    var queue = BoundedEventQueue<String>(limits: limits)
    let old = try makeTestEvent(1, priority: .low, policy: .keepLatest(key), bytes: 2)
    let other = try makeTestEvent(2, priority: .normal, bytes: 5)
    _ = try queue.enqueue(old, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(other, nowOnQueueClockNanoseconds: 0)
    let replacement = try makeTestEvent(
      3,
      priority: .critical,
      policy: .keepLatest(key),
      bytes: 8
    )
    let result = try queue.enqueue(replacement, nowOnQueueClockNanoseconds: 0)

    XCTAssertEqual(result.coalescedEventID, old.id)
    XCTAssertEqual(result.overflowDroppedEventIDs, [other.id])
    XCTAssertTrue(result.isBuffered)
    XCTAssertEqual(queue.accountedByteCount, 8)
  }

  func testExpirationAndReplacementTTLUseQueueClock() throws {
    let key = try KeepLatestKey("state")
    var queue = BoundedEventQueue<String>()
    let old = try makeTestEvent(
      1,
      ttlMilliseconds: 1,
      policy: .keepLatest(key),
      enqueuedAt: 0
    )
    _ = try queue.enqueue(old, nowOnQueueClockNanoseconds: 0)
    let replacement = try makeTestEvent(
      2,
      ttlMilliseconds: 1,
      policy: .keepLatest(key),
      enqueuedAt: 900_000
    )
    _ = try queue.enqueue(replacement, nowOnQueueClockNanoseconds: 900_000)

    XCTAssertEqual(try queue.snapshot(nowOnQueueClockNanoseconds: 1_000_000).eventCount, 1)
    let expired = try queue.snapshot(nowOnQueueClockNanoseconds: 1_900_000)
    XCTAssertEqual(expired.eventCount, 0)
    XCTAssertEqual(expired.statistics.expired, 1)
    XCTAssertEqual(expired.expiredEventIDs, [replacement.id])
  }

  func testAlreadyExpiredIncomingEventIsReportedWithoutBufferingOrOverflow() throws {
    var queue = BoundedEventQueue<String>()
    let stale = try makeTestEvent(1, ttlMilliseconds: 1)

    let result = try queue.enqueue(stale, nowOnQueueClockNanoseconds: 1_000_000)

    XCTAssertFalse(result.isBuffered)
    XCTAssertEqual(result.expiredEventIDs, [stale.id])
    XCTAssertEqual(result.overflowDroppedEventIDs, [])
    XCTAssertEqual(queue.eventCount, 0)
    XCTAssertEqual(queue.statistics.enqueued, 0)
    XCTAssertEqual(queue.statistics.expired, 1)
  }

  func testExpiredKeepLatestAdmissionDoesNotReplaceLiveStateOrEvictUrgentWork() throws {
    let limits = try EventQueueLimits(
      maximumEventCount: 2,
      maximumTotalBytes: 10,
      maximumSingleEventBytes: 10
    )
    let key = try KeepLatestKey("state")
    let live = try makeTestEvent(
      1,
      value: "live",
      priority: .critical,
      ttlMilliseconds: 10,
      policy: .keepLatest(key)
    )
    let urgent = try makeTestEvent(2, value: "urgent", priority: .critical)
    let staleReplacement = try makeTestEvent(
      3,
      value: "stale",
      priority: .low,
      ttlMilliseconds: 1,
      policy: .keepLatest(key)
    )
    var queue = BoundedEventQueue<String>(limits: limits)
    _ = try queue.enqueue(live, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(urgent, nowOnQueueClockNanoseconds: 0)

    let result = try queue.enqueue(
      staleReplacement,
      nowOnQueueClockNanoseconds: 1_000_000
    )

    XCTAssertFalse(result.isBuffered)
    XCTAssertNil(result.coalescedEventID)
    XCTAssertEqual(result.overflowDroppedEventIDs, [])
    XCTAssertEqual(result.expiredEventIDs, [staleReplacement.id])
    let drained = try queue.dequeue(
      maximumCount: 2,
      maximumBytes: 10,
      nowOnQueueClockNanoseconds: 1_000_000
    )
    XCTAssertEqual(Set(drained.events.map(\.id)), Set([live.id, urgent.id]))
    XCTAssertEqual(drained.events.first { $0.id == live.id }?.value, "live")
  }

  func testDuplicatePendingIDIsRejectedAtomically() throws {
    var queue = BoundedEventQueue<String>()
    let original = try makeTestEvent(1, value: "original")
    let duplicate = try makeTestEvent(1, value: "duplicate", priority: .critical)
    _ = try queue.enqueue(original, nowOnQueueClockNanoseconds: 0)
    let before = try queue.snapshot(nowOnQueueClockNanoseconds: 0)

    assertFlowError(.invalidEntry) {
      _ = try queue.enqueue(duplicate, nowOnQueueClockNanoseconds: 0)
    }

    let after = try queue.snapshot(nowOnQueueClockNanoseconds: 0)
    XCTAssertEqual(after, before)
    let drained = try queue.dequeue(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    )
    XCTAssertEqual(drained.events.map(\.value), ["original"])
  }

  func testDuplicatePendingIDCannotEnterThroughKeepLatestReplacement() throws {
    let firstKey = try KeepLatestKey("first")
    let secondKey = try KeepLatestKey("second")
    var queue = BoundedEventQueue<String>()
    let original = try makeTestEvent(1, policy: .keepLatest(firstKey))
    let duplicate = try makeTestEvent(1, policy: .keepLatest(secondKey))
    _ = try queue.enqueue(original, nowOnQueueClockNanoseconds: 0)

    assertFlowError(.invalidEntry) {
      _ = try queue.enqueue(duplicate, nowOnQueueClockNanoseconds: 0)
    }

    let drained = try queue.dequeue(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    )
    XCTAssertEqual(drained.events.map(\.policy), [.keepLatest(firstKey)])
  }

  func testBackwardClockFailureIsAtomic() throws {
    var queue = BoundedEventQueue<String>()
    _ = try queue.enqueue(
      makeTestEvent(1, enqueuedAt: 100),
      nowOnQueueClockNanoseconds: 100
    )
    assertFlowError(.invalidClock) {
      _ = try queue.snapshot(nowOnQueueClockNanoseconds: 99)
    }
    XCTAssertEqual(queue.eventCount, 1)
  }

  func testEmptyQueueStillRejectsClockReversal() throws {
    var queue = BoundedEventQueue<String>()
    _ = try queue.snapshot(nowOnQueueClockNanoseconds: 100)
    assertFlowError(.invalidClock) {
      _ = try queue.snapshot(nowOnQueueClockNanoseconds: 99)
    }
    XCTAssertEqual(queue.eventCount, 0)
  }

  func testDeadlineOverflowFailsBeforeMutation() throws {
    var queue = BoundedEventQueue<String>()
    let event = try makeTestEvent(1, enqueuedAt: UInt64.max)
    assertFlowError(.invalidClock) {
      _ = try queue.enqueue(event, nowOnQueueClockNanoseconds: UInt64.max)
    }
    XCTAssertEqual(queue.eventCount, 0)
  }

  func testWeightedCycleAndFIFOWithinPriority() throws {
    var queue = BoundedEventQueue<String>()
    var number = 1
    for (priority, count) in [
      (EventPriority.critical, 8),
      (.high, 4),
      (.normal, 2),
      (.low, 2),
    ] {
      for _ in 0..<count {
        _ = try queue.enqueue(
          makeTestEvent(number, value: "\(priority.rawValue)-\(number)", priority: priority),
          nowOnQueueClockNanoseconds: 0
        )
        number += 1
      }
    }

    let cycle = try queue.dequeue(
      maximumCount: 15,
      maximumBytes: 100,
      nowOnQueueClockNanoseconds: 0
    )
    XCTAssertEqual(cycle.events.filter { $0.priority == .critical }.count, 8)
    XCTAssertEqual(cycle.events.filter { $0.priority == .high }.count, 4)
    XCTAssertEqual(cycle.events.filter { $0.priority == .normal }.count, 2)
    XCTAssertEqual(cycle.events.filter { $0.priority == .low }.count, 1)
    XCTAssertEqual(queue.eventCount, 1)
    XCTAssertEqual(
      try queue.dequeue(maximumCount: 1, maximumBytes: 1, nowOnQueueClockNanoseconds: 0)
        .events.first?.priority,
      .low
    )
  }

  func testWeightedFairnessPersistsAcrossSingleEventDequeueCalls() throws {
    var queue = BoundedEventQueue<String>()
    var number = 1
    for (priority, count) in [
      (EventPriority.critical, 16),
      (.high, 8),
      (.normal, 4),
      (.low, 2),
    ] {
      for _ in 0..<count {
        _ = try queue.enqueue(
          makeTestEvent(number, priority: priority),
          nowOnQueueClockNanoseconds: 0
        )
        number += 1
      }
    }

    var priorities: [EventPriority] = []
    for _ in 0..<30 {
      let result = try queue.dequeue(
        maximumCount: 1,
        maximumBytes: 1,
        nowOnQueueClockNanoseconds: 0
      )
      priorities.append(contentsOf: result.events.map(\.priority))
    }

    XCTAssertEqual(priorities.prefix(15).filter { $0 == .critical }.count, 8)
    XCTAssertEqual(priorities.prefix(15).filter { $0 == .high }.count, 4)
    XCTAssertEqual(priorities.prefix(15).filter { $0 == .normal }.count, 2)
    XCTAssertEqual(priorities.prefix(15).filter { $0 == .low }.count, 1)
    XCTAssertEqual(priorities.suffix(15).filter { $0 == .critical }.count, 8)
    XCTAssertEqual(priorities.suffix(15).filter { $0 == .high }.count, 4)
    XCTAssertEqual(priorities.suffix(15).filter { $0 == .normal }.count, 2)
    XCTAssertEqual(priorities.suffix(15).filter { $0 == .low }.count, 1)
  }

  func testByteBoundStopsWithoutRemovingNextFairEvent() throws {
    var queue = BoundedEventQueue<String>()
    let first = try makeTestEvent(1, bytes: 60)
    let second = try makeTestEvent(2, bytes: 60)
    _ = try queue.enqueue(first, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(second, nowOnQueueClockNanoseconds: 0)

    let batch = try queue.dequeue(
      maximumCount: 2,
      maximumBytes: 100,
      nowOnQueueClockNanoseconds: 0
    )
    XCTAssertEqual(batch.events.map(\.id), [first.id])
    XCTAssertEqual(queue.eventCount, 1)
    XCTAssertEqual(
      try queue.dequeue(maximumCount: 1, maximumBytes: 100, nowOnQueueClockNanoseconds: 0)
        .events.map(\.id),
      [second.id]
    )
  }

  func testKeepLatestPromotionAndDemotionPreserveOrdinalWithinNewLane() throws {
    let promotedKey = try KeepLatestKey("promoted")
    let demotedKey = try KeepLatestKey("demoted")
    var queue = BoundedEventQueue<String>()
    _ = try queue.enqueue(
      makeTestEvent(1, priority: .low, policy: .keepLatest(promotedKey)),
      nowOnQueueClockNanoseconds: 0
    )
    _ = try queue.enqueue(
      makeTestEvent(2, priority: .critical, policy: .keepLatest(demotedKey)),
      nowOnQueueClockNanoseconds: 0
    )
    let laterLow = try makeTestEvent(3, priority: .low)
    _ = try queue.enqueue(laterLow, nowOnQueueClockNanoseconds: 0)
    let promoted = try makeTestEvent(
      4,
      priority: .critical,
      policy: .keepLatest(promotedKey)
    )
    let demoted = try makeTestEvent(5, priority: .low, policy: .keepLatest(demotedKey))
    _ = try queue.enqueue(promoted, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(demoted, nowOnQueueClockNanoseconds: 0)

    let critical = try queue.dequeue(
      maximumCount: 1,
      maximumBytes: 10,
      nowOnQueueClockNanoseconds: 0
    )
    XCTAssertEqual(critical.events.map(\.id), [promoted.id])
    let low = try queue.dequeue(
      maximumCount: 2,
      maximumBytes: 10,
      nowOnQueueClockNanoseconds: 0
    )
    XCTAssertEqual(low.events.map(\.id), [demoted.id, laterLow.id])
  }

  func testSnapshotAndClearAreExact() throws {
    var queue = BoundedEventQueue<String>()
    let low = try makeTestEvent(1, priority: .low, bytes: 3, enqueuedAt: 10)
    let high = try makeTestEvent(2, priority: .high, bytes: 5, enqueuedAt: 20)
    _ = try queue.enqueue(low, nowOnQueueClockNanoseconds: 10)
    _ = try queue.enqueue(high, nowOnQueueClockNanoseconds: 20)
    let snapshot = try queue.snapshot(nowOnQueueClockNanoseconds: 30)
    let cleared = queue.clear(reason: .sessionEnded)

    XCTAssertEqual(snapshot.eventCount, 2)
    XCTAssertEqual(snapshot.accountedByteCount, 8)
    XCTAssertEqual(snapshot.oldestWaitNanoseconds, 20)
    XCTAssertEqual(snapshot.priorityCounts.low, 1)
    XCTAssertEqual(snapshot.priorityCounts.high, 1)
    XCTAssertEqual(cleared.removedEventIDs, [low.id, high.id])
    XCTAssertEqual(queue.statistics.clearedSessionEnded, 2)
    XCTAssertEqual(queue.eventCount, 0)
    XCTAssertEqual(flowControlSaturatedSum(UInt64.max, 1), UInt64.max)
  }

  func testHardBoundFillAndSingleEventDrainRemainFIFO() throws {
    let limits = try EventQueueLimits(
      maximumEventCount: 10_000,
      maximumTotalBytes: 10_000,
      maximumSingleEventBytes: 1
    )
    var queue = BoundedEventQueue<String>(limits: limits)
    for number in 1...10_000 {
      _ = try queue.enqueue(
        makeTestEvent(number),
        nowOnQueueClockNanoseconds: 0
      )
    }

    for number in 1...10_000 {
      let result = try queue.dequeue(
        maximumCount: 1,
        maximumBytes: 1,
        nowOnQueueClockNanoseconds: 0
      )
      XCTAssertEqual(result.events.first?.id, try makeTestEvent(number).id)
    }
    XCTAssertEqual(queue.eventCount, 0)
    XCTAssertEqual(queue.statistics.dequeued, 10_000)
  }

  func testRepeatedKeepLatestReplacementCompactsStaleHeapNodes() throws {
    let key = try KeepLatestKey("state")
    var queue = BoundedEventQueue<String>()
    for number in 1...256 {
      let priority: EventPriority = number.isMultiple(of: 2) ? .critical : .low
      _ = try queue.enqueue(
        makeTestEvent(number, priority: priority, policy: .keepLatest(key)),
        nowOnQueueClockNanoseconds: 0
      )
    }

    let result = try queue.dequeue(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    )
    XCTAssertEqual(result.events.map(\.id), [try makeTestEvent(256).id])
    XCTAssertEqual(result.events.map(\.priority), [.critical])
    XCTAssertEqual(queue.eventCount, 0)
    XCTAssertEqual(queue.statistics.coalesced, 255)
  }
}
