import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

@_spi(NearWireInternal) public struct EventBatchLimits: Equatable, Sendable {
  public static let `default` = EventBatchLimits(
    uncheckedMaximumEventCount: 256,
    maximumAccountedBytes: 512 * 1_024,
    flushIntervalNanoseconds: 500_000_000
  )

  public let maximumEventCount: Int
  public let maximumAccountedBytes: Int
  public let flushIntervalNanoseconds: UInt64

  public init(
    maximumEventCount: Int = 256,
    maximumAccountedBytes: Int = 512 * 1_024,
    flushIntervalNanoseconds: UInt64 = 500_000_000,
    queueLimits: EventQueueLimits? = nil
  ) throws {
    guard (1...10_000).contains(maximumEventCount) else {
      throw FlowControlError(
        code: .invalidBatchConfiguration,
        path: "maximumEventCount",
        message: "Batch event limit must be between 1 and 10,000."
      )
    }
    guard (1...67_108_864).contains(maximumAccountedBytes) else {
      throw FlowControlError(
        code: .invalidBatchConfiguration,
        path: "maximumAccountedBytes",
        message: "Batch byte limit must be between 1 and 64 MiB."
      )
    }
    guard (1_000_000...60_000_000_000).contains(flushIntervalNanoseconds) else {
      throw FlowControlError(
        code: .invalidBatchConfiguration,
        path: "flushIntervalNanoseconds",
        message: "Flush interval must be between 1 millisecond and 60 seconds."
      )
    }
    if let queueLimits,
      maximumAccountedBytes < queueLimits.maximumSingleEventBytes
    {
      throw FlowControlError(
        code: .invalidBatchConfiguration,
        path: "maximumAccountedBytes",
        message: "Batch byte limit must fit every valid queue event."
      )
    }
    self.init(
      uncheckedMaximumEventCount: maximumEventCount,
      maximumAccountedBytes: maximumAccountedBytes,
      flushIntervalNanoseconds: flushIntervalNanoseconds
    )
  }

  private init(
    uncheckedMaximumEventCount: Int,
    maximumAccountedBytes: Int,
    flushIntervalNanoseconds: UInt64
  ) {
    maximumEventCount = uncheckedMaximumEventCount
    self.maximumAccountedBytes = maximumAccountedBytes
    self.flushIntervalNanoseconds = flushIntervalNanoseconds
  }
}

@_spi(NearWireInternal) public struct EventBatch<Value: Sendable>: Sendable {
  public let events: [PendingEvent<Value>]
  public let accountedByteCount: Int

  init(events: [PendingEvent<Value>], accountedByteCount: Int) {
    precondition(!events.isEmpty)
    self.events = events
    self.accountedByteCount = accountedByteCount
  }
}

extension EventBatch: Equatable where Value: Equatable {}

extension EventBatch: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var description: String {
    "EventBatch(count: \(events.count), bytes: \(accountedByteCount), redacted)"
  }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(
      self,
      children: ["eventCount": events.count, "accountedByteCount": accountedByteCount],
      displayStyle: .struct
    )
  }
}

@_spi(NearWireInternal) public struct EventBatchAttempt<Value: Sendable>: Sendable {
  public let batch: EventBatch<Value>?
  public let expiredEventIDs: [EventID]
}

extension EventBatchAttempt: Equatable where Value: Equatable {}

extension EventBatchAttempt: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var description: String {
    "EventBatchAttempt(count: \(batch?.events.count ?? 0), redacted)"
  }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(
      self,
      children: ["eventCount": batch?.events.count ?? 0],
      displayStyle: .struct
    )
  }
}

@_spi(NearWireInternal) public struct EventBatchScheduler: Equatable, Sendable {
  public let limits: EventBatchLimits
  public let queueLimits: EventQueueLimits
  public private(set) var nextFlushDeadlineNanoseconds: UInt64
  public private(set) var lastObservedNanoseconds: UInt64

  public init(
    limits: EventBatchLimits = .default,
    queueLimits: EventQueueLimits,
    startNanoseconds: UInt64
  ) throws {
    guard limits.maximumAccountedBytes >= queueLimits.maximumSingleEventBytes else {
      throw FlowControlError(
        code: .invalidBatchConfiguration,
        path: "maximumAccountedBytes",
        message: "Batch cannot fit every valid queue event."
      )
    }
    let (deadline, overflow) = startNanoseconds.addingReportingOverflow(
      limits.flushIntervalNanoseconds)
    guard !overflow else {
      throw FlowControlError(
        code: .arithmeticOverflow,
        path: "nextFlushDeadlineNanoseconds",
        message: "Initial flush deadline overflows the monotonic clock."
      )
    }
    self.limits = limits
    self.queueLimits = queueLimits
    nextFlushDeadlineNanoseconds = deadline
    lastObservedNanoseconds = startNanoseconds
  }

  public mutating func drainIfDue<Value: Sendable>(
    queue: inout BoundedEventQueue<Value>,
    tokenBucket: inout EventTokenBucket,
    nowNanoseconds: UInt64
  ) throws -> EventBatchAttempt<Value>? {
    guard nowNanoseconds >= lastObservedNanoseconds else {
      throw FlowControlError(
        code: .invalidClock,
        path: "nowNanoseconds",
        message: "Batch scheduler clock moved backward."
      )
    }
    guard queue.limits == queueLimits else {
      throw FlowControlError(
        code: .invalidBatchConfiguration,
        path: "queue.limits",
        message: "Scheduler and queue limits must match."
      )
    }
    guard nowNanoseconds >= nextFlushDeadlineNanoseconds else {
      lastObservedNanoseconds = nowNanoseconds
      return nil
    }

    var plannedBucket = tokenBucket
    var plannedScheduler = self
    let (nextDeadline, overflow) = nowNanoseconds.addingReportingOverflow(
      limits.flushIntervalNanoseconds)
    guard !overflow else {
      throw FlowControlError(
        code: .arithmeticOverflow,
        path: "nextFlushDeadlineNanoseconds",
        message: "Next flush deadline overflows the monotonic clock."
      )
    }
    plannedScheduler.lastObservedNanoseconds = nowNanoseconds
    plannedScheduler.nextFlushDeadlineNanoseconds = nextDeadline

    let available = try plannedBucket.availableWholeTokens(atNanoseconds: nowNanoseconds)
    let allowance = min(available, limits.maximumEventCount)
    let drained: EventDequeueResult<Value>
    if allowance > 0 {
      drained = try queue.dequeue(
        maximumCount: allowance,
        maximumBytes: limits.maximumAccountedBytes,
        nowOnQueueClockNanoseconds: nowNanoseconds
      )
      plannedBucket.consumePrevalidated(drained.events.count)
    } else {
      let expiredEventIDs = try queue.expireDueEvents(
        nowOnQueueClockNanoseconds: nowNanoseconds
      )
      drained = EventDequeueResult(
        events: [],
        accountedByteCount: 0,
        expiredEventIDs: expiredEventIDs
      )
    }

    tokenBucket = plannedBucket
    self = plannedScheduler
    let batch =
      drained.events.isEmpty
      ? nil
      : EventBatch(
        events: drained.events,
        accountedByteCount: drained.accountedByteCount
      )
    return EventBatchAttempt(
      batch: batch,
      expiredEventIDs: drained.expiredEventIDs
    )
  }
}
