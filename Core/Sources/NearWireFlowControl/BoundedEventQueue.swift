import Foundation

#if SWIFT_PACKAGE
  import NearWireCore
#endif

public struct EventQueueStatistics: Equatable, Sendable {
  public internal(set) var enqueued: UInt64 = 0
  public internal(set) var dequeued: UInt64 = 0
  public internal(set) var overflowDropped: UInt64 = 0
  public internal(set) var expired: UInt64 = 0
  public internal(set) var coalesced: UInt64 = 0
  public internal(set) var clearedOwnerRequested: UInt64 = 0
  public internal(set) var clearedSessionEnded: UInt64 = 0
}

public struct EventPriorityCounts: Equatable, Sendable {
  public let low: Int
  public let normal: Int
  public let high: Int
  public let critical: Int
}

public struct EventQueueSnapshot: Equatable, Sendable {
  public let eventCount: Int
  public let accountedByteCount: Int
  public let priorityCounts: EventPriorityCounts
  public let oldestWaitNanoseconds: UInt64?
  public let expiredEventIDs: [EventID]
  public let statistics: EventQueueStatistics
}

public struct EventEnqueueResult: Equatable, Sendable {
  public let eventID: EventID
  public let isBuffered: Bool
  public let coalescedEventID: EventID?
  public let overflowDroppedEventIDs: [EventID]
  public let expiredEventIDs: [EventID]
}

public struct EventDequeueResult<Value: Sendable>: Sendable {
  public let events: [PendingEvent<Value>]
  public let accountedByteCount: Int
  public let expiredEventIDs: [EventID]
}

extension EventDequeueResult: Equatable where Value: Equatable {}

public enum EventQueueClearReason: Sendable {
  case ownerRequested
  case sessionEnded
}

public struct EventQueueClearResult: Equatable, Sendable {
  public let reason: EventQueueClearReason
  public let removedEventIDs: [EventID]
}

private struct FlowControlMinHeap<Element: Comparable & Sendable>: Sendable {
  private(set) var elements: [Element] = []

  var count: Int { elements.count }
  var minimum: Element? { elements.first }

  mutating func insert(_ element: Element) {
    elements.append(element)
    var child = elements.count - 1
    while child > 0 {
      let parent = (child - 1) / 2
      guard elements[child] < elements[parent] else { break }
      elements.swapAt(child, parent)
      child = parent
    }
  }

  @discardableResult
  mutating func popMinimum() -> Element? {
    guard !elements.isEmpty else { return nil }
    if elements.count == 1 { return elements.removeLast() }
    let result = elements[0]
    elements[0] = elements.removeLast()
    var parent = 0
    while true {
      let left = parent * 2 + 1
      guard left < elements.count else { break }
      let right = left + 1
      let child = right < elements.count && elements[right] < elements[left] ? right : left
      guard elements[child] < elements[parent] else { break }
      elements.swapAt(parent, child)
      parent = child
    }
    return result
  }
}

private struct PriorityHeapNode: Comparable, Sendable {
  let ordinal: UInt64
  let eventID: EventID

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.ordinal == rhs.ordinal
      ? lhs.eventID.rawValue < rhs.eventID.rawValue
      : lhs.ordinal < rhs.ordinal
  }
}

private struct DeadlineHeapNode: Comparable, Sendable {
  let deadlineNanoseconds: UInt64
  let ordinal: UInt64
  let eventID: EventID

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.deadlineNanoseconds != rhs.deadlineNanoseconds {
      return lhs.deadlineNanoseconds < rhs.deadlineNanoseconds
    }
    if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
    return lhs.eventID.rawValue < rhs.eventID.rawValue
  }
}

public struct BoundedEventQueue<Value: Sendable>: Sendable {
  public let limits: EventQueueLimits
  public private(set) var statistics = EventQueueStatistics()

  private struct StoredEvent: Sendable {
    let ordinal: UInt64
    let deadlineNanoseconds: UInt64
    let event: PendingEvent<Value>
  }

  private struct PriorityCredits: Sendable {
    var low = 1
    var normal = 2
    var high = 4
    var critical = 8

    mutating func reset() {
      low = 1
      normal = 2
      high = 4
      critical = 8
    }

    func value(for priority: EventPriority) -> Int {
      switch priority {
      case .low: low
      case .normal: normal
      case .high: high
      case .critical: critical
      }
    }

    mutating func consume(_ priority: EventPriority) {
      switch priority {
      case .low: low -= 1
      case .normal: normal -= 1
      case .high: high -= 1
      case .critical: critical -= 1
      }
    }
  }

  private var eventsByOrdinal: [UInt64: StoredEvent] = [:]
  private var ordinalsByID: [EventID: UInt64] = [:]
  private var ordinalsByKeepLatestKey: [KeepLatestKey: UInt64] = [:]
  private var lowHeap = FlowControlMinHeap<PriorityHeapNode>()
  private var normalHeap = FlowControlMinHeap<PriorityHeapNode>()
  private var highHeap = FlowControlMinHeap<PriorityHeapNode>()
  private var criticalHeap = FlowControlMinHeap<PriorityHeapNode>()
  private var deadlineHeap = FlowControlMinHeap<DeadlineHeapNode>()
  private var accountedBytes = 0
  private var nextOrdinal: UInt64 = 0
  private var lastObservedNanoseconds: UInt64?
  private var credits = PriorityCredits()

  public init(limits: EventQueueLimits = .default) {
    self.limits = limits
  }

  public var eventCount: Int { eventsByOrdinal.count }
  public var accountedByteCount: Int { accountedBytes }

  public mutating func enqueue(
    _ event: PendingEvent<Value>,
    nowOnQueueClockNanoseconds now: UInt64
  ) throws -> EventEnqueueResult {
    let incomingDeadline = try validate(event, now: now)
    try validateObservation(now)

    if let duplicateOrdinal = ordinalsByID[event.id],
      let duplicate = eventsByOrdinal[duplicateOrdinal],
      duplicate.deadlineNanoseconds > now
    {
      throw FlowControlError(
        code: .invalidEntry,
        path: "id",
        message: "Pending event IDs must be unique within a queue."
      )
    }

    if now >= incomingDeadline {
      recordObservation(now)
      let expiredIDs = expireInPlace(now: now)
      statistics.expired.saturatingIncrement()
      compactHeapsIfNeeded()
      return EventEnqueueResult(
        eventID: event.id,
        isBuffered: false,
        coalescedEventID: nil,
        overflowDroppedEventIDs: [],
        expiredEventIDs: expiredIDs + [event.id]
      )
    }

    let replacementOrdinal: UInt64?
    if case .keepLatest(let key) = event.policy,
      let ordinal = ordinalsByKeepLatestKey[key],
      let replacement = eventsByOrdinal[ordinal],
      replacement.deadlineNanoseconds > now
    {
      replacementOrdinal = ordinal
    } else {
      replacementOrdinal = nil
    }

    let assignedOrdinal: UInt64
    let nextOrdinalAfterAdmission: UInt64?
    if let replacementOrdinal {
      assignedOrdinal = replacementOrdinal
      nextOrdinalAfterAdmission = nil
    } else {
      assignedOrdinal = nextOrdinal
      let (next, overflow) = nextOrdinal.addingReportingOverflow(1)
      guard !overflow else {
        throw FlowControlError(
          code: .arithmeticOverflow,
          path: "queue.ordinal",
          message: "Queue insertion ordinal is exhausted."
        )
      }
      nextOrdinalAfterAdmission = next
    }

    let replacedBytes =
      replacementOrdinal.flatMap { eventsByOrdinal[$0] }?
      .event.accountedByteCount ?? 0
    let baseBytes = accountedBytes - replacedBytes
    let (_, byteOverflow) = baseBytes.addingReportingOverflow(event.accountedByteCount)
    guard !byteOverflow else {
      throw FlowControlError(
        code: .arithmeticOverflow,
        path: "queue.accountedBytes",
        message: "Queue byte accounting overflowed."
      )
    }

    recordObservation(now)
    let expiredIDs = expireInPlace(now: now)

    var replacedID: EventID?
    if let replacementOrdinal,
      let replacement = eventsByOrdinal[replacementOrdinal]
    {
      replacedID = replacement.event.id
      _ = removeStoredEvent(ordinal: replacementOrdinal)
      statistics.coalesced.saturatingIncrement()
    } else if let nextOrdinalAfterAdmission {
      nextOrdinal = nextOrdinalAfterAdmission
    }

    insertStoredEvent(
      StoredEvent(
        ordinal: assignedOrdinal,
        deadlineNanoseconds: incomingDeadline,
        event: event
      )
    )
    statistics.enqueued.saturatingIncrement()

    var droppedIDs: [EventID] = []
    while eventCount > limits.maximumEventCount
      || accountedBytes > limits.maximumTotalBytes
    {
      guard let candidate = oldestOverflowCandidate() else { break }
      popPriorityNode(candidate.event.priority)
      _ = removeStoredEvent(ordinal: candidate.ordinal)
      droppedIDs.append(candidate.event.id)
      statistics.overflowDropped.saturatingIncrement()
    }

    let remainsBuffered = ordinalsByID[event.id] != nil
    compactHeapsIfNeeded()
    return EventEnqueueResult(
      eventID: event.id,
      isBuffered: remainsBuffered,
      coalescedEventID: replacedID,
      overflowDroppedEventIDs: droppedIDs,
      expiredEventIDs: expiredIDs
    )
  }

  public mutating func dequeue(
    maximumCount: Int,
    maximumBytes: Int,
    nowOnQueueClockNanoseconds now: UInt64
  ) throws -> EventDequeueResult<Value> {
    guard maximumCount > 0, maximumBytes > 0 else {
      throw FlowControlError(
        code: .invalidBatchConfiguration,
        path: "dequeue",
        message: "Dequeue count and byte limits must be positive."
      )
    }
    try validateObservation(now)

    recordObservation(now)
    let expiredIDs = expireInPlace(now: now)
    var events: [PendingEvent<Value>] = []
    var bytes = 0

    while events.count < maximumCount, let candidate = nextFairCandidate() {
      let candidateTotal = bytes + candidate.event.accountedByteCount
      if candidateTotal > maximumBytes { break }
      popPriorityNode(candidate.event.priority)
      credits.consume(candidate.event.priority)
      _ = removeStoredEvent(ordinal: candidate.ordinal)
      events.append(candidate.event)
      bytes = candidateTotal
    }

    statistics.dequeued.saturatingAdd(UInt64(events.count))
    compactHeapsIfNeeded()
    return EventDequeueResult(
      events: events,
      accountedByteCount: bytes,
      expiredEventIDs: expiredIDs
    )
  }

  public mutating func snapshot(
    nowOnQueueClockNanoseconds now: UInt64
  ) throws -> EventQueueSnapshot {
    try validateObservation(now)
    recordObservation(now)
    let expiredIDs = expireInPlace(now: now)
    var low = 0
    var normal = 0
    var high = 0
    var critical = 0
    var oldestEnqueue: UInt64?
    for stored in eventsByOrdinal.values {
      switch stored.event.priority {
      case .low: low += 1
      case .normal: normal += 1
      case .high: high += 1
      case .critical: critical += 1
      }
      oldestEnqueue = min(
        oldestEnqueue ?? stored.event.enqueuedAtNanoseconds,
        stored.event.enqueuedAtNanoseconds)
    }
    compactHeapsIfNeeded()
    return EventQueueSnapshot(
      eventCount: eventCount,
      accountedByteCount: accountedBytes,
      priorityCounts: EventPriorityCounts(
        low: low,
        normal: normal,
        high: high,
        critical: critical
      ),
      oldestWaitNanoseconds: oldestEnqueue.map { now - $0 },
      expiredEventIDs: expiredIDs,
      statistics: statistics
    )
  }

  mutating func expireDueEvents(
    nowOnQueueClockNanoseconds now: UInt64
  ) throws -> [EventID] {
    try validateObservation(now)
    recordObservation(now)
    let expiredIDs = expireInPlace(now: now)
    compactHeapsIfNeeded()
    return expiredIDs
  }

  public mutating func clear(reason: EventQueueClearReason) -> EventQueueClearResult {
    let ids = eventsByOrdinal.values.sorted { $0.ordinal < $1.ordinal }.map(\.event.id)
    let removedCount = UInt64(ids.count)
    switch reason {
    case .ownerRequested:
      statistics.clearedOwnerRequested.saturatingAdd(removedCount)
    case .sessionEnded:
      statistics.clearedSessionEnded.saturatingAdd(removedCount)
    }
    eventsByOrdinal.removeAll(keepingCapacity: true)
    ordinalsByID.removeAll(keepingCapacity: true)
    ordinalsByKeepLatestKey.removeAll(keepingCapacity: true)
    lowHeap = FlowControlMinHeap()
    normalHeap = FlowControlMinHeap()
    highHeap = FlowControlMinHeap()
    criticalHeap = FlowControlMinHeap()
    deadlineHeap = FlowControlMinHeap()
    accountedBytes = 0
    credits.reset()
    return EventQueueClearResult(reason: reason, removedEventIDs: ids)
  }

  private func validate(_ event: PendingEvent<Value>, now: UInt64) throws -> UInt64 {
    guard event.accountedByteCount <= limits.maximumSingleEventBytes,
      event.accountedByteCount <= limits.maximumTotalBytes
    else {
      throw FlowControlError(
        code: .invalidEntry,
        path: "accountedByteCount",
        message: "Event exceeds the active queue byte limits."
      )
    }
    guard now >= event.enqueuedAtNanoseconds else {
      throw FlowControlError(
        code: .invalidClock,
        path: "nowNanoseconds",
        message: "Queue clock cannot precede event enqueue time."
      )
    }
    return try Self.deadline(for: event)
  }

  private func validateObservation(_ now: UInt64) throws {
    guard lastObservedNanoseconds.map({ now >= $0 }) ?? true else {
      throw FlowControlError(
        code: .invalidClock,
        path: "nowNanoseconds",
        message: "Queue clock moved backward."
      )
    }
  }

  private mutating func recordObservation(_ now: UInt64) {
    lastObservedNanoseconds = now
  }

  private mutating func insertStoredEvent(_ stored: StoredEvent) {
    eventsByOrdinal[stored.ordinal] = stored
    ordinalsByID[stored.event.id] = stored.ordinal
    if case .keepLatest(let key) = stored.event.policy {
      ordinalsByKeepLatestKey[key] = stored.ordinal
    }
    accountedBytes += stored.event.accountedByteCount
    let priorityNode = PriorityHeapNode(
      ordinal: stored.ordinal,
      eventID: stored.event.id
    )
    pushPriorityNode(priorityNode, priority: stored.event.priority)
    deadlineHeap.insert(
      DeadlineHeapNode(
        deadlineNanoseconds: stored.deadlineNanoseconds,
        ordinal: stored.ordinal,
        eventID: stored.event.id
      )
    )
  }

  @discardableResult
  private mutating func removeStoredEvent(ordinal: UInt64) -> StoredEvent? {
    guard let removed = eventsByOrdinal.removeValue(forKey: ordinal) else { return nil }
    ordinalsByID.removeValue(forKey: removed.event.id)
    if case .keepLatest(let key) = removed.event.policy,
      ordinalsByKeepLatestKey[key] == ordinal
    {
      ordinalsByKeepLatestKey.removeValue(forKey: key)
    }
    accountedBytes -= removed.event.accountedByteCount
    return removed
  }

  private mutating func expireInPlace(now: UInt64) -> [EventID] {
    var expiredIDs: [EventID] = []
    while let node = deadlineHeap.minimum {
      guard let stored = eventsByOrdinal[node.ordinal],
        stored.event.id == node.eventID,
        stored.deadlineNanoseconds == node.deadlineNanoseconds
      else {
        _ = deadlineHeap.popMinimum()
        continue
      }
      guard node.deadlineNanoseconds <= now else { break }
      _ = deadlineHeap.popMinimum()
      _ = removeStoredEvent(ordinal: node.ordinal)
      expiredIDs.append(node.eventID)
      statistics.expired.saturatingIncrement()
    }
    return expiredIDs
  }

  private mutating func oldestOverflowCandidate() -> StoredEvent? {
    for priority in [EventPriority.low, .normal, .high, .critical] {
      if let node = validPriorityNode(priority),
        let stored = eventsByOrdinal[node.ordinal]
      {
        return stored
      }
    }
    return nil
  }

  private mutating func nextFairCandidate() -> StoredEvent? {
    let order: [EventPriority] = [.critical, .high, .normal, .low]
    for _ in 0..<2 {
      for priority in order where credits.value(for: priority) > 0 {
        if let node = validPriorityNode(priority),
          let stored = eventsByOrdinal[node.ordinal]
        {
          return stored
        }
      }
      credits.reset()
    }
    return nil
  }

  private mutating func validPriorityNode(_ priority: EventPriority) -> PriorityHeapNode? {
    switch priority {
    case .low:
      return Self.cleanPriorityHeap(&lowHeap, priority: priority, events: eventsByOrdinal)
    case .normal:
      return Self.cleanPriorityHeap(&normalHeap, priority: priority, events: eventsByOrdinal)
    case .high:
      return Self.cleanPriorityHeap(&highHeap, priority: priority, events: eventsByOrdinal)
    case .critical:
      return Self.cleanPriorityHeap(&criticalHeap, priority: priority, events: eventsByOrdinal)
    }
  }

  private static func cleanPriorityHeap(
    _ heap: inout FlowControlMinHeap<PriorityHeapNode>,
    priority: EventPriority,
    events: [UInt64: StoredEvent]
  ) -> PriorityHeapNode? {
    while let node = heap.minimum {
      if let stored = events[node.ordinal],
        stored.event.id == node.eventID,
        stored.event.priority == priority
      {
        return node
      }
      _ = heap.popMinimum()
    }
    return nil
  }

  private mutating func pushPriorityNode(
    _ node: PriorityHeapNode,
    priority: EventPriority
  ) {
    switch priority {
    case .low: lowHeap.insert(node)
    case .normal: normalHeap.insert(node)
    case .high: highHeap.insert(node)
    case .critical: criticalHeap.insert(node)
    }
  }

  private mutating func popPriorityNode(_ priority: EventPriority) {
    switch priority {
    case .low: _ = lowHeap.popMinimum()
    case .normal: _ = normalHeap.popMinimum()
    case .high: _ = highHeap.popMinimum()
    case .critical: _ = criticalHeap.popMinimum()
    }
  }

  private mutating func compactHeapsIfNeeded() {
    let threshold = max(64, eventCount * 2 + 16)
    let priorityNodeCount = lowHeap.count + normalHeap.count + highHeap.count + criticalHeap.count
    guard deadlineHeap.count > threshold || priorityNodeCount > threshold else { return }
    rebuildHeaps()
  }

  private mutating func rebuildHeaps() {
    lowHeap = FlowControlMinHeap()
    normalHeap = FlowControlMinHeap()
    highHeap = FlowControlMinHeap()
    criticalHeap = FlowControlMinHeap()
    deadlineHeap = FlowControlMinHeap()
    for stored in eventsByOrdinal.values {
      pushPriorityNode(
        PriorityHeapNode(ordinal: stored.ordinal, eventID: stored.event.id),
        priority: stored.event.priority
      )
      deadlineHeap.insert(
        DeadlineHeapNode(
          deadlineNanoseconds: stored.deadlineNanoseconds,
          ordinal: stored.ordinal,
          eventID: stored.event.id
        )
      )
    }
  }

  private static func deadline(for event: PendingEvent<Value>) throws -> UInt64 {
    let (duration, multiplyOverflow) = event.ttl.milliseconds.multipliedReportingOverflow(
      by: 1_000_000)
    let (deadline, addOverflow) = event.enqueuedAtNanoseconds.addingReportingOverflow(duration)
    guard !multiplyOverflow, !addOverflow else {
      throw FlowControlError(
        code: .invalidClock,
        path: "ttl",
        message: "Pending event deadline overflows the monotonic clock."
      )
    }
    return deadline
  }
}

extension EventQueueClearReason: Equatable {}

extension UInt64 {
  fileprivate mutating func saturatingIncrement() {
    saturatingAdd(1)
  }

  fileprivate mutating func saturatingAdd(_ value: UInt64) {
    self = flowControlSaturatedSum(self, value)
  }
}

func flowControlSaturatedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
  let (result, overflow) = lhs.addingReportingOverflow(rhs)
  return overflow ? .max : result
}
