import XCTest

@_spi(NearWireInternal) @testable import NearWireCore
@_spi(NearWireInternal) @testable import NearWireFlowControl

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

  func testActiveScheduleObservationReturnsFutureDeadlineAndStableFairID() throws {
    var queue = BoundedEventQueue<String>()
    let first = try makeTestEvent(1, ttlMilliseconds: 2)
    let second = try makeTestEvent(2, priority: .critical, ttlMilliseconds: 3)
    _ = try queue.enqueue(first, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(second, nowOnQueueClockNanoseconds: 0)

    let firstObservation = try queue.observeActiveSchedule(
      nowOnQueueClockNanoseconds: 0,
      maximumServiceUnits: 1,
      authorizeExpiration: { _, _ in
        XCTFail("No expiration should be offered.")
        return false
      }
    )
    let secondObservation = try queue.observeActiveSchedule(
      nowOnQueueClockNanoseconds: 0,
      maximumServiceUnits: 1,
      authorizeExpiration: { _, _ in
        XCTFail("No expiration should be offered.")
        return false
      }
    )

    XCTAssertEqual(firstObservation.expiredEventIDs, [])
    XCTAssertFalse(firstObservation.dueWorkRemains)
    XCTAssertEqual(firstObservation.nextExpirationDeadlineNanoseconds, 2_000_000)
    XCTAssertEqual(firstObservation.nextFairCandidateID, second.id)
    XCTAssertEqual(secondObservation.nextFairCandidateID, second.id)

    let dequeued = try queue.dequeue(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    )
    XCTAssertEqual(dequeued.events.map(\.id), [second.id])
  }

  func testActiveScheduleExpirationUsesQuantumAndReportsImmediateContinuation() throws {
    var queue = BoundedEventQueue<String>()
    let events = try (1...3).map { try makeTestEvent($0, ttlMilliseconds: 1) }
    for event in events {
      _ = try queue.enqueue(event, nowOnQueueClockNanoseconds: 0)
    }
    var committed: [EventID] = []

    let first = try queue.observeActiveSchedule(
      nowOnQueueClockNanoseconds: 1_000_000,
      maximumServiceUnits: 2,
      authorizeExpiration: { event, commit in
        commit()
        committed.append(event.id)
        return true
      }
    )
    XCTAssertEqual(first.expiredEventIDs, Array(events.prefix(2)).map(\.id))
    XCTAssertEqual(committed, first.expiredEventIDs)
    XCTAssertTrue(first.dueWorkRemains)
    XCTAssertNil(first.nextExpirationDeadlineNanoseconds)
    XCTAssertNil(first.nextFairCandidateID)
    XCTAssertEqual(queue.eventCount, 1)

    let second = try queue.observeActiveSchedule(
      nowOnQueueClockNanoseconds: 1_000_000,
      maximumServiceUnits: 2,
      authorizeExpiration: { _, commit in
        commit()
        return true
      }
    )
    XCTAssertEqual(second.expiredEventIDs, [events[2].id])
    XCTAssertFalse(second.dueWorkRemains)
    XCTAssertNil(second.nextExpirationDeadlineNanoseconds)
    XCTAssertEqual(queue.eventCount, 0)
    XCTAssertEqual(queue.statistics.expired, 3)
  }

  func testActiveSchedulePreviewReportsDueWorkWithoutMutation() throws {
    var queue = BoundedEventQueue<String>()
    let first = try makeTestEvent(1, ttlMilliseconds: 1)
    let second = try makeTestEvent(2, ttlMilliseconds: 1)
    _ = try queue.enqueue(first, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(second, nowOnQueueClockNanoseconds: 0)
    let beforeStatistics = queue.statistics

    let preview = try queue.previewActiveSchedule(
      nowOnQueueClockNanoseconds: 1_000_000,
      maximumServiceUnits: 2
    )

    XCTAssertEqual(preview.expiredEventIDs, [])
    XCTAssertTrue(preview.dueWorkRemains)
    XCTAssertNil(preview.nextExpirationDeadlineNanoseconds)
    XCTAssertNil(preview.nextFairCandidateID)
    XCTAssertFalse(preview.stoppedByAuthorization)
    XCTAssertEqual(queue.eventCount, 2)
    XCTAssertEqual(queue.statistics, beforeStatistics)
  }

  func testActiveScheduleTerminalFirstLeavesDueEventAndStatisticsUnchanged() throws {
    var queue = BoundedEventQueue<String>()
    let event = try makeTestEvent(1, ttlMilliseconds: 1)
    _ = try queue.enqueue(event, nowOnQueueClockNanoseconds: 0)
    let beforeStatistics = queue.statistics

    let result = try queue.observeActiveSchedule(
      nowOnQueueClockNanoseconds: 1_000_000,
      maximumServiceUnits: 1,
      authorizeExpiration: { _, _ in false }
    )

    XCTAssertTrue(result.stoppedByAuthorization)
    XCTAssertTrue(result.dueWorkRemains)
    XCTAssertEqual(result.expiredEventIDs, [])
    XCTAssertEqual(queue.eventCount, 1)
    XCTAssertEqual(queue.statistics, beforeStatistics)
  }

  func testActiveScheduleInvalidQuantumAndBackwardClockAreAtomic() throws {
    var queue = BoundedEventQueue<String>()
    let event = try makeTestEvent(1, ttlMilliseconds: 10)
    _ = try queue.enqueue(event, nowOnQueueClockNanoseconds: 5)

    assertFlowError(.invalidBatchConfiguration) {
      _ = try queue.observeActiveSchedule(
        nowOnQueueClockNanoseconds: 5,
        maximumServiceUnits: 0,
        authorizeExpiration: { _, _ in false }
      )
    }
    assertFlowError(.invalidClock) {
      _ = try queue.observeActiveSchedule(
        nowOnQueueClockNanoseconds: 4,
        maximumServiceUnits: 1,
        authorizeExpiration: { _, _ in false }
      )
    }
    XCTAssertEqual(queue.eventCount, 1)
    XCTAssertEqual(queue.accountedByteCount, event.accountedByteCount)
  }

  func testActiveOfferBoundsAcceptedPrefixSeparatelyFromMaintenance() throws {
    var queue = BoundedEventQueue<String>()
    let expired = try makeTestEvent(1, ttlMilliseconds: 1)
    let routed = try makeTestEvent(2, value: "route-drop", ttlMilliseconds: 10)
    let first = try makeTestEvent(3, value: "first", ttlMilliseconds: 10)
    let second = try makeTestEvent(4, value: "second", ttlMilliseconds: 10)
    for event in [expired, routed, first, second] {
      _ = try queue.enqueue(event, nowOnQueueClockNanoseconds: 0)
    }
    var accepted: [EventID] = []
    var routingDropped: [EventID] = []

    let result = try queue.offerActive(
      maximumServiceUnits: 4,
      maximumAcceptedEventCount: 1,
      maximumBytes: 10,
      nowOnQueueClockNanoseconds: 1_000_000,
      authorizeExpiration: { _, commit in
        commit()
        return true
      },
      preflight: { event, commit in
        guard event.value == "route-drop" else { return .eligible }
        commit()
        routingDropped.append(event.id)
        return .removeWithoutAccounting
      },
      decision: { event, commit in
        commit()
        accepted.append(event.id)
        return .remove
      }
    )

    XCTAssertEqual(result.expiredEventIDs, [expired.id])
    XCTAssertEqual(routingDropped, [routed.id])
    XCTAssertEqual(accepted, [first.id])
    XCTAssertEqual(result.acceptedEventCount, 1)
    XCTAssertEqual(result.serviceUnits, 3)
    XCTAssertTrue(result.stoppedOnCandidate)
    XCTAssertTrue(result.eligibleWorkRemains)
    XCTAssertEqual(result.nextFairCandidateID, second.id)
    XCTAssertEqual(queue.eventCount, 1)
  }

  func testActiveOfferTerminalFirstCandidatePreservesFairnessAndIdentity() throws {
    var queue = BoundedEventQueue<String>()
    let critical = try makeTestEvent(1, priority: .critical)
    let normal = try makeTestEvent(2, priority: .normal)
    _ = try queue.enqueue(critical, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(normal, nowOnQueueClockNanoseconds: 0)
    let beforeStatistics = queue.statistics

    let result = try queue.offerActive(
      maximumServiceUnits: 2,
      maximumAcceptedEventCount: 2,
      maximumBytes: 2,
      nowOnQueueClockNanoseconds: 0,
      authorizeExpiration: { _, _ in false },
      preflight: { _, _ in .eligible },
      decision: { _, _ in .stop }
    )
    XCTAssertTrue(result.stoppedOnCandidate)
    XCTAssertEqual(result.serviceUnits, 1)
    XCTAssertEqual(result.nextFairCandidateID, critical.id)
    XCTAssertEqual(queue.statistics, beforeStatistics)
    XCTAssertEqual(queue.eventCount, 2)

    let next = try queue.dequeue(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    )
    XCTAssertEqual(next.events.map(\.id), [critical.id])
  }

  func testActiveOfferByteBoundLeavesCandidateUnchangedWithoutDecision() throws {
    var queue = BoundedEventQueue<String>()
    let event = try makeTestEvent(1, bytes: 2)
    _ = try queue.enqueue(event, nowOnQueueClockNanoseconds: 0)
    var decisionCalls = 0

    let result = try queue.offerActive(
      maximumServiceUnits: 1,
      maximumAcceptedEventCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0,
      authorizeExpiration: { _, _ in false },
      preflight: { _, _ in .eligible },
      decision: { _, _ in
        decisionCalls += 1
        return .stop
      }
    )

    XCTAssertEqual(decisionCalls, 0)
    XCTAssertTrue(result.stoppedOnCandidate)
    XCTAssertEqual(result.serviceUnits, 0)
    XCTAssertEqual(result.nextFairCandidateID, event.id)
    XCTAssertEqual(queue.eventCount, 1)
    XCTAssertEqual(queue.accountedByteCount, 2)
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

  func testExactExpirationDeadlineOverridesMillisecondTTLWithoutExtension() throws {
    var queue = BoundedEventQueue<String>()
    let event = try makeTestEvent(
      1,
      ttlMilliseconds: 1,
      enqueuedAt: 1_000_000_000,
      expirationDeadline: 1_000_500_000
    )
    _ = try queue.enqueue(event, nowOnQueueClockNanoseconds: 1_000_000_000)

    XCTAssertEqual(
      try queue.snapshot(nowOnQueueClockNanoseconds: 1_000_499_999).eventCount,
      1
    )
    let expired = try queue.snapshot(nowOnQueueClockNanoseconds: 1_000_500_000)
    XCTAssertEqual(expired.eventCount, 0)
    XCTAssertEqual(expired.expiredEventIDs, [event.id])
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

  func testOfferStopPreservesFIFOAndCandidateIdentity() throws {
    var queue = BoundedEventQueue<String>()
    let events = try (1...3).map { try makeTestEvent($0) }
    for event in events {
      _ = try queue.enqueue(event, nowOnQueueClockNanoseconds: 0)
    }

    var offered: [EventID] = []
    let stopped = try queue.offer(
      maximumCount: 3,
      maximumBytes: 3,
      nowOnQueueClockNanoseconds: 0
    ) { event in
      offered.append(event.id)
      return .stop
    }
    let accepted = try queue.offer(
      maximumCount: 3,
      maximumBytes: 3,
      nowOnQueueClockNanoseconds: 0
    ) { _ in .remove }

    XCTAssertEqual(offered, [events[0].id])
    XCTAssertTrue(stopped.removedEvents.isEmpty)
    XCTAssertTrue(stopped.stoppedOnCandidate)
    XCTAssertEqual(accepted.removedEvents.map(\.id), events.map(\.id))
  }

  func testOfferRemovesAcceptedPrefixWithoutReorderingRejectedSuffix() throws {
    var queue = BoundedEventQueue<String>()
    let events = try (1...3).map { try makeTestEvent($0) }
    for event in events {
      _ = try queue.enqueue(event, nowOnQueueClockNanoseconds: 0)
    }

    let firstPass = try queue.offer(
      maximumCount: 3,
      maximumBytes: 3,
      nowOnQueueClockNanoseconds: 0
    ) { event in
      event.id == events[0].id ? .remove : .stop
    }
    let secondPass = try queue.offer(
      maximumCount: 3,
      maximumBytes: 3,
      nowOnQueueClockNanoseconds: 0
    ) { _ in .remove }

    XCTAssertEqual(firstPass.removedEvents.map(\.id), [events[0].id])
    XCTAssertEqual(secondPass.removedEvents.map(\.id), [events[1].id, events[2].id])
    XCTAssertEqual(queue.statistics.dequeued, 3)
  }

  func testOfferStopDoesNotConsumeWeightedSchedulerCredit() throws {
    var stoppedQueue = BoundedEventQueue<String>()
    var controlQueue = BoundedEventQueue<String>()
    let priorities: [EventPriority] = [
      .critical, .high, .normal, .low, .critical, .high, .normal, .critical,
    ]
    for (offset, priority) in priorities.enumerated() {
      let event = try makeTestEvent(offset + 1, priority: priority)
      _ = try stoppedQueue.enqueue(event, nowOnQueueClockNanoseconds: 0)
      _ = try controlQueue.enqueue(event, nowOnQueueClockNanoseconds: 0)
    }

    _ = try stoppedQueue.offer(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    ) { _ in .stop }
    let afterStop = try stoppedQueue.dequeue(
      maximumCount: priorities.count,
      maximumBytes: priorities.count,
      nowOnQueueClockNanoseconds: 0
    )
    let control = try controlQueue.dequeue(
      maximumCount: priorities.count,
      maximumBytes: priorities.count,
      nowOnQueueClockNanoseconds: 0
    )

    XCTAssertEqual(afterStop.events.map(\.id), control.events.map(\.id))
  }

  func testOfferStopRestoresCreditsWhenSelectionWouldResetWeightedCycle() throws {
    var stoppedQueue = BoundedEventQueue<String>()
    var controlQueue = BoundedEventQueue<String>()
    for number in 1...9 {
      let event = try makeTestEvent(number, priority: .critical)
      _ = try stoppedQueue.enqueue(event, nowOnQueueClockNanoseconds: 0)
      _ = try controlQueue.enqueue(event, nowOnQueueClockNanoseconds: 0)
    }
    _ = try stoppedQueue.dequeue(
      maximumCount: 8,
      maximumBytes: 8,
      nowOnQueueClockNanoseconds: 0
    )
    _ = try controlQueue.dequeue(
      maximumCount: 8,
      maximumBytes: 8,
      nowOnQueueClockNanoseconds: 0
    )

    _ = try stoppedQueue.offer(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    ) { _ in .stop }
    let high = try makeTestEvent(10, priority: .high)
    _ = try stoppedQueue.enqueue(high, nowOnQueueClockNanoseconds: 0)
    _ = try controlQueue.enqueue(high, nowOnQueueClockNanoseconds: 0)

    let afterStop = try stoppedQueue.dequeue(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    )
    let control = try controlQueue.dequeue(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    )

    XCTAssertEqual(afterStop.events.map(\.id), [high.id])
    XCTAssertEqual(afterStop.events.map(\.id), control.events.map(\.id))
  }

  func testByteBoundRestoresCreditsWhenSelectionWouldResetWeightedCycle() throws {
    var stoppedQueue = BoundedEventQueue<String>()
    var controlQueue = BoundedEventQueue<String>()
    for number in 1...9 {
      let bytes = number == 9 ? 2 : 1
      let event = try makeTestEvent(number, priority: .critical, bytes: bytes)
      _ = try stoppedQueue.enqueue(event, nowOnQueueClockNanoseconds: 0)
      _ = try controlQueue.enqueue(event, nowOnQueueClockNanoseconds: 0)
    }
    _ = try stoppedQueue.dequeue(
      maximumCount: 8,
      maximumBytes: 8,
      nowOnQueueClockNanoseconds: 0
    )
    _ = try controlQueue.dequeue(
      maximumCount: 8,
      maximumBytes: 8,
      nowOnQueueClockNanoseconds: 0
    )

    let stopped = try stoppedQueue.dequeue(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    )
    let high = try makeTestEvent(10, priority: .high)
    _ = try stoppedQueue.enqueue(high, nowOnQueueClockNanoseconds: 0)
    _ = try controlQueue.enqueue(high, nowOnQueueClockNanoseconds: 0)
    let afterStop = try stoppedQueue.dequeue(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    )
    let control = try controlQueue.dequeue(
      maximumCount: 1,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0
    )

    XCTAssertTrue(stopped.events.isEmpty)
    XCTAssertEqual(afterStop.events.map(\.id), [high.id])
    XCTAssertEqual(afterStop.events.map(\.id), control.events.map(\.id))
  }

  func testOfferValidationFailsBeforeCallingDecision() throws {
    var queue = BoundedEventQueue<String>()
    _ = try queue.enqueue(makeTestEvent(1), nowOnQueueClockNanoseconds: 10)
    var decisionCount = 0

    assertFlowError(.invalidBatchConfiguration) {
      _ = try queue.offer(
        maximumCount: 0,
        maximumBytes: 1,
        nowOnQueueClockNanoseconds: 10
      ) { _ in
        decisionCount += 1
        return .remove
      }
    }
    assertFlowError(.invalidClock) {
      _ = try queue.offer(
        maximumCount: 1,
        maximumBytes: 1,
        nowOnQueueClockNanoseconds: 9
      ) { _ in
        decisionCount += 1
        return .remove
      }
    }

    XCTAssertEqual(decisionCount, 0)
    XCTAssertEqual(queue.eventCount, 1)
  }

  func testOfferPreflightCanRemoveOversizedLocalWorkWithoutChargingBatchBytes() throws {
    var queue = BoundedEventQueue<String>()
    let stale = try makeTestEvent(1, bytes: 100)
    let eligible = try makeTestEvent(2, bytes: 1)
    _ = try queue.enqueue(stale, nowOnQueueClockNanoseconds: 0)
    _ = try queue.enqueue(eligible, nowOnQueueClockNanoseconds: 0)

    var admitted: [EventID] = []
    let result = try queue.offer(
      maximumCount: 2,
      maximumBytes: 1,
      nowOnQueueClockNanoseconds: 0,
      preflight: { event in
        event.id == stale.id ? .removeWithoutAccounting : .eligible
      },
      decision: { event in
        admitted.append(event.id)
        return .remove
      }
    )

    XCTAssertEqual(result.removedEvents.map(\.id), [stale.id, eligible.id])
    XCTAssertEqual(result.accountedByteCount, 1)
    XCTAssertEqual(admitted, [eligible.id])
    XCTAssertEqual(queue.eventCount, 0)
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

  func testOldestWaitUsesLiveEnqueueNodesAfterReplacementAndPriorityRemoval() throws {
    let key = try KeepLatestKey("latest")
    var queue = BoundedEventQueue<String>()
    _ = try queue.enqueue(
      makeTestEvent(
        1,
        priority: .normal,
        policy: .keepLatest(key),
        enqueuedAt: 10
      ),
      nowOnQueueClockNanoseconds: 10
    )
    let low = try makeTestEvent(2, priority: .low, enqueuedAt: 20)
    _ = try queue.enqueue(low, nowOnQueueClockNanoseconds: 20)
    let replacement = try makeTestEvent(
      3,
      priority: .critical,
      policy: .keepLatest(key),
      enqueuedAt: 30
    )
    _ = try queue.enqueue(replacement, nowOnQueueClockNanoseconds: 30)

    XCTAssertEqual(try queue.oldestWaitNanoseconds(atNanoseconds: 40), 20)
    let removed = try queue.dequeue(
      maximumCount: 1,
      maximumBytes: 10,
      nowOnQueueClockNanoseconds: 40
    )
    XCTAssertEqual(removed.events.map(\.id), [replacement.id])
    XCTAssertEqual(try queue.oldestWaitNanoseconds(atNanoseconds: 50), 30)

    _ = queue.clear(reason: .ownerRequested)
    XCTAssertNil(try queue.oldestWaitNanoseconds(atNanoseconds: 50))
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
