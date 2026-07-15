import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

enum ViewerLiveProjectionLimits {
  static let ingressCount = 64
  static let ingressBytes = 20 * 1_024 * 1_024
  static let retainedCount = 512
  static let retainedBytes = 32 * 1_024 * 1_024
  static let maximumSessions = 16
  // Deterministic accounting reserve for bounded metadata and fixed entry fields. This is not a
  // claim about Swift heap usage; process heap high-water remains a diagnostic measurement.
  static let fixedEntryOverheadBytes = 32 * 1_024
  static let refreshIntervalNanoseconds: UInt64 = 100_000_000

  static func accountedBytes(for observation: ViewerCommittedEventObservation) -> Int? {
    let (bytes, overflow) = observation.deterministicEventBytes.addingReportingOverflow(
      fixedEntryOverheadBytes
    )
    return overflow ? nil : bytes
  }
}

struct ViewerLiveEventSnapshot: Sendable {
  let observation: ViewerCommittedEventObservation
  let laterDisposition: ViewerEventDisposition?
  let hasPresentationConflict: Bool
  let hasGap: Bool
  let hasDrop: Bool
  let sessionEnded: Bool
}

struct ViewerLiveSessionSnapshot: Equatable, Sendable {
  let connectionID: UUID
  let metadata: ViewerFrozenSessionMetadata
  let isImported: Bool
  let positiveDropCount: UInt64
  let endedWallMilliseconds: Int64?
  let endedMonotonicNanoseconds: UInt64?
}

struct ViewerLiveGapSnapshot: Equatable, Sendable {
  let ingressOverflowCount: UInt64
  let windowOverflowCount: UInt64
  let residentConflictCount: UInt64
  let diagnosticLossCount: UInt64
}

struct ViewerLiveProjectionSnapshot: Sendable {
  let runtimeLogicalID: UUID
  let generation: UInt64
  let events: [ViewerLiveEventSnapshot]
  let sessions: [ViewerLiveSessionSnapshot]
  let gaps: ViewerLiveGapSnapshot
  let accountedEventBytes: Int
}

struct ViewerMemorySessionReplacement: Sendable {
  let sessions: [ViewerLiveSessionSnapshot]
  let events: [ViewerCommittedEventObservation]
  let gaps: ViewerLiveGapSnapshot
}

struct ViewerLiveProjectionDiagnostics: Equatable, Sendable {
  let ingressOfferCount: UInt64
  let drainScheduleCount: UInt64
  let dirtySuccessorCount: UInt64
  let drainRunCount: UInt64
  let maximumConcurrentDrainCount: UInt64
  let snapshotPublicationCount: UInt64
  let refreshScheduleCount: UInt64
  let refreshDeliveryCount: UInt64
}

struct ViewerLiveRefreshScheduler: Sendable {
  let now: @Sendable () -> UInt64
  let scheduleOnMain: @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void

  static let live = ViewerLiveRefreshScheduler(
    now: { DispatchTime.now().uptimeNanoseconds },
    scheduleOnMain: { delay, action in
      Task { @MainActor in
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        guard !Task.isCancelled else { return }
        action()
      }
    }
  )
}

private struct ViewerCanonicalProjectionHeader: Equatable, Sendable {
  let eventID: EventID
  let eventType: EventType
  let createdWallMilliseconds: Int64
  let originMonotonicNanoseconds: UInt64
  let priority: EventPriority
  let ttlMilliseconds: UInt64
  let schemaVersion: EventSchemaVersion
  let correlationID: EventID?
  let replyToID: EventID?
  let initialDisposition: ViewerEventDisposition?

  init(_ projection: ViewerCanonicalEventProjection) {
    eventID = projection.eventID
    eventType = projection.eventType
    createdWallMilliseconds = projection.createdWallMilliseconds
    originMonotonicNanoseconds = projection.originMonotonicNanoseconds
    priority = projection.priority
    ttlMilliseconds = projection.ttlMilliseconds
    schemaVersion = projection.schemaVersion
    correlationID = projection.correlationID
    replyToID = projection.replyToID
    initialDisposition = projection.initialDisposition
  }
}

private struct ViewerLiveIngressEntry: Sendable {
  enum Kind: Sendable {
    case newAuthority
    case deferredDuplicate
  }

  let kind: Kind
  let observation: ViewerCommittedEventObservation
  let accountedBytes: Int
  let deferredDecision: (@Sendable (ViewerLiveEventOfferOutcome) -> Void)?
}

private struct ViewerLiveAuthorityEntry: Sendable {
  var observationID: UUID
  var header: ViewerCanonicalProjectionHeader
  var hasCurrentValue: Bool
  var pendingDuplicateCount: Int
}

private struct ViewerPendingSessionTermination: Sendable {
  var metadata: ViewerFrozenSessionMetadata?
  let wallMilliseconds: Int64
  let monotonicNanoseconds: UInt64
}

private struct ViewerLiveWindowNode: Sendable {
  let observation: ViewerCommittedEventObservation
  let accountedBytes: Int
  var laterDisposition: ViewerEventDisposition?
  var hasPresentationConflict: Bool
  var previous: Int?
  var next: Int?
}

private struct ViewerLiveEventDeque: Sendable {
  private var slots = [ViewerLiveWindowNode?](
    repeating: nil,
    count: ViewerLiveProjectionLimits.retainedCount
  )
  private var freeSlots = Array((0..<ViewerLiveProjectionLimits.retainedCount).reversed())
  private var indices: [ViewerEventJournalKey: Int] = [:]
  private var head: Int?
  private var tail: Int?

  private(set) var count = 0
  private(set) var accountedBytes = 0

  func node(for key: ViewerEventJournalKey) -> ViewerLiveWindowNode? {
    guard let index = indices[key] else { return nil }
    return slots[index]
  }

  mutating func insert(
    _ observation: ViewerCommittedEventObservation,
    accountedBytes: Int
  ) -> [ViewerLiveWindowNode] {
    var displaced: [ViewerLiveWindowNode] = []
    while count >= ViewerLiveProjectionLimits.retainedCount
      || accountedBytes > ViewerLiveProjectionLimits.retainedBytes - self.accountedBytes
    {
      guard let removed = removeHead() else { break }
      displaced.append(removed)
    }
    guard accountedBytes <= ViewerLiveProjectionLimits.retainedBytes,
      let index = freeSlots.popLast()
    else { return displaced }
    let node = ViewerLiveWindowNode(
      observation: observation,
      accountedBytes: accountedBytes,
      laterDisposition: nil,
      hasPresentationConflict: false,
      previous: tail,
      next: nil
    )
    if let tail {
      var prior = slots[tail]
      prior?.next = index
      slots[tail] = prior
    } else {
      head = index
    }
    tail = index
    slots[index] = node
    indices[observation.key] = index
    count += 1
    self.accountedBytes += accountedBytes
    return displaced
  }

  mutating func markPresentationConflict(_ key: ViewerEventJournalKey) -> Bool {
    guard let index = indices[key], var node = slots[index] else { return false }
    guard !node.hasPresentationConflict else { return true }
    node.hasPresentationConflict = true
    slots[index] = node
    return true
  }

  mutating func setDisposition(
    _ disposition: ViewerEventDisposition,
    for key: ViewerEventJournalKey
  ) -> Bool {
    guard let index = indices[key], var node = slots[index] else { return false }
    node.laterDisposition = disposition
    slots[index] = node
    return true
  }

  mutating func remove(
    key: ViewerEventJournalKey,
    observationID: UUID? = nil
  ) -> ViewerLiveWindowNode? {
    guard let index = indices[key], let node = slots[index],
      observationID == nil || node.observation.observationID == observationID
    else { return nil }
    unlink(index: index, node: node)
    return node
  }

  mutating func removeHead() -> ViewerLiveWindowNode? {
    guard let head, let node = slots[head] else { return nil }
    unlink(index: head, node: node)
    return node
  }

  mutating func removeAll() -> [ViewerLiveWindowNode] {
    var removed: [ViewerLiveWindowNode] = []
    removed.reserveCapacity(count)
    while let node = removeHead() { removed.append(node) }
    return removed
  }

  mutating func removeAll(connectionID: UUID) -> [ViewerLiveWindowNode] {
    var removed: [ViewerLiveWindowNode] = []
    var index = head
    while let current = index, let node = slots[current] {
      index = node.next
      if node.observation.key.connectionID == connectionID {
        unlink(index: current, node: node)
        removed.append(node)
      }
    }
    return removed
  }

  func contains(connectionID: UUID) -> Bool {
    var index = head
    while let current = index, let node = slots[current] {
      if node.observation.key.connectionID == connectionID { return true }
      index = node.next
    }
    return false
  }

  func orderedNodes() -> [ViewerLiveWindowNode] {
    var values: [ViewerLiveWindowNode] = []
    values.reserveCapacity(count)
    var index = head
    while let current = index, let node = slots[current] {
      values.append(node)
      index = node.next
    }
    return values
  }

  private mutating func unlink(index: Int, node: ViewerLiveWindowNode) {
    if let previous = node.previous {
      var prior = slots[previous]
      prior?.next = node.next
      slots[previous] = prior
    } else {
      head = node.next
    }
    if let next = node.next {
      var successor = slots[next]
      successor?.previous = node.previous
      slots[next] = successor
    } else {
      tail = node.previous
    }
    indices.removeValue(forKey: node.observation.key)
    slots[index] = nil
    freeSlots.append(index)
    count -= 1
    accountedBytes -= node.accountedBytes
  }
}

private struct ViewerLiveConflictMarkers: Sendable {
  private var ring = [ViewerEventJournalKey?](
    repeating: nil,
    count: ViewerLiveProjectionLimits.retainedCount
  )
  private var keys: Set<ViewerEventJournalKey> = []
  private var head = 0
  private var tail = 0
  private(set) var count = 0

  mutating func insert(_ key: ViewerEventJournalKey) -> Bool {
    guard !keys.contains(key) else { return false }
    if count == ring.count, let removed = ring[head] {
      keys.remove(removed)
      ring[head] = nil
      head = (head + 1) % ring.count
      count -= 1
    }
    ring[tail] = key
    tail = (tail + 1) % ring.count
    keys.insert(key)
    count += 1
    return true
  }

  func contains(_ key: ViewerEventJournalKey) -> Bool { keys.contains(key) }

  @discardableResult
  mutating func remove(connectionIDs: Set<UUID>) -> Int {
    guard keys.contains(where: { connectionIDs.contains($0.connectionID) }) else { return 0 }
    let originalCount = count
    var retained: [ViewerEventJournalKey] = []
    retained.reserveCapacity(count)
    var index = head
    for _ in 0..<count {
      if let key = ring[index], !connectionIDs.contains(key.connectionID) {
        retained.append(key)
      }
      index = (index + 1) % ring.count
    }
    removeAll()
    for key in retained { _ = insert(key) }
    return originalCount - retained.count
  }

  mutating func removeAll() {
    ring = Array(repeating: nil, count: ViewerLiveProjectionLimits.retainedCount)
    keys.removeAll(keepingCapacity: false)
    head = 0
    tail = 0
    count = 0
  }
}

private struct ViewerLiveSessionState: Sendable {
  var metadata: ViewerFrozenSessionMetadata
  var dropCounts: [ViewerDropJournalSample.Reason: UInt64] = [:]
  var endedWallMilliseconds: Int64?
  var endedMonotonicNanoseconds: UInt64?

  var positiveDropCount: UInt64 {
    dropCounts.values.reduce(UInt64(0)) { total, value in
      let (sum, overflow) = total.addingReportingOverflow(value)
      return overflow ? UInt64.max : sum
    }
  }
}

final class ViewerLiveEventWindow: ViewerLiveObservationProviding, @unchecked Sendable {
  let runtimeLogicalID: UUID
  let liveGeneration: UInt64

  private let ingressLock = NSLock()
  private var ingress = [ViewerLiveIngressEntry?](
    repeating: nil,
    count: ViewerLiveProjectionLimits.ingressCount
  )
  private var ingressHead = 0
  private var ingressTail = 0
  private var ingressCount = 0
  private var ingressBytes = 0
  private var authority: [ViewerEventJournalKey: ViewerLiveAuthorityEntry] = [:]
  private var pendingDispositions: [ViewerEventJournalKey: ViewerEventDisposition] = [:]
  private var activeSessionMetadata: [UUID: ViewerFrozenSessionMetadata] = [:]
  private var pendingSessionTerminations: [UUID: ViewerPendingSessionTermination] = [:]
  private var projectedSessionIDs: Set<UUID> = []
  private var importedSessionIDs: Set<UUID> = []
  private var tracksSessionLifecycle = false
  private var sessionLifecycleTransitionPending = false
  private var sessionStateDirty = false
  private var pendingDropCounts: [UUID: [ViewerDropJournalSample.Reason: UInt64]] = [:]
  private var pendingConflictKeys: Set<ViewerEventJournalKey> = []
  private var pendingIngressOverflowCount: UInt64 = 0
  private var pendingDiagnosticLossCount: UInt64 = 0
  private var drainScheduled = false
  private var dirtySuccessor = false
  private var presentationSealed = false
  private var ingestionSealed = false
  private var cleared = false
  private var ingressOfferCount: UInt64 = 0
  private var drainScheduleCount: UInt64 = 0
  private var dirtySuccessorCount: UInt64 = 0

  private let projectionQueue: DispatchQueue
  private var window = ViewerLiveEventDeque()
  private var sessions: [UUID: ViewerLiveSessionState] = [:]
  private var conflictMarkers = ViewerLiveConflictMarkers()
  private var projectionGeneration: UInt64 = 0
  private var performanceSliceRevision: UInt64 = 0
  private var ingressOverflowCount: UInt64 = 0
  private var windowOverflowCount: UInt64 = 0
  private var diagnosticLossCount: UInt64 = 0
  private var drainRunCount: UInt64 = 0
  private var activeDrainCount: UInt64 = 0
  private var maximumConcurrentDrainCount: UInt64 = 0
  private var snapshotPublicationCount: UInt64 = 0

  private let snapshotLock = NSLock()
  private var publishedSnapshot: ViewerLiveProjectionSnapshot

  private let refreshLock = NSLock()
  private let refreshScheduler: ViewerLiveRefreshScheduler
  private var refreshHandler: (@Sendable (UInt64) -> Void)?
  private var presentationPaused = false
  private var refreshSealed = false
  private var refreshDirty = false
  private var wakeScheduled = false
  private var wakeToken: UInt64 = 0
  private var lastWakeNanoseconds: UInt64?
  private var latestSnapshotGeneration: UInt64 = 0
  private var refreshScheduleCount: UInt64 = 0
  private var refreshDeliveryCount: UInt64 = 0

  init(
    runtimeLogicalID: UUID,
    liveGeneration: UInt64 = 1,
    projectionQueue: DispatchQueue? = nil,
    refreshScheduler: ViewerLiveRefreshScheduler = .live
  ) {
    precondition(liveGeneration > 0)
    self.runtimeLogicalID = runtimeLogicalID
    self.liveGeneration = liveGeneration
    self.projectionQueue =
      projectionQueue
      ?? DispatchQueue(label: "com.nearwire.viewer.live-projection.\(runtimeLogicalID.uuidString)")
    self.refreshScheduler = refreshScheduler
    publishedSnapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 0,
      events: [],
      sessions: [],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 0,
        residentConflictCount: 0,
        diagnosticLossCount: 0
      ),
      accountedEventBytes: 0
    )
  }

  func offer(
    _ observation: ViewerCommittedEventObservation,
    deferredDecision: @escaping @Sendable (ViewerLiveEventOfferOutcome) -> Void = { _ in }
  ) -> ViewerLiveEventOfferOutcome {
    guard observation.key.runtimeLogicalID == runtimeLogicalID,
      let accountedBytes = ViewerLiveProjectionLimits.accountedBytes(for: observation)
    else { return .sealed }
    let header = ViewerCanonicalProjectionHeader(observation.canonicalProjection)
    var shouldSchedule = false
    let result: ViewerLiveEventOfferOutcome
    ingressLock.lock()
    ingressOfferCount = Self.saturatingIncrement(ingressOfferCount)
    if ingestionSealed || cleared {
      result = .sealed
    } else if let existing = authority[observation.key] {
      if existing.header != header {
        if pendingConflictKeys.contains(observation.key)
          || pendingConflictKeys.count < ViewerLiveProjectionLimits.retainedCount
        {
          pendingConflictKeys.insert(observation.key)
        } else {
          pendingDiagnosticLossCount = Self.saturatingIncrement(pendingDiagnosticLossCount)
        }
        shouldSchedule = markDirtyLocked()
        result = .presentationConflict
      } else if admitIngressLocked(
        ViewerLiveIngressEntry(
          kind: .deferredDuplicate,
          observation: observation,
          accountedBytes: accountedBytes,
          deferredDecision: deferredDecision
        )
      ) {
        var updated = existing
        updated.pendingDuplicateCount += 1
        authority[observation.key] = updated
        shouldSchedule = markDirtyLocked()
        result = .deferred
      } else {
        pendingIngressOverflowCount = Self.saturatingIncrement(pendingIngressOverflowCount)
        shouldSchedule = markDirtyLocked()
        result = .untracked
      }
    } else if authority.count < ViewerLiveProjectionLimits.retainedCount
      + ViewerLiveProjectionLimits.ingressCount,
      admitIngressLocked(
        ViewerLiveIngressEntry(
          kind: .newAuthority,
          observation: observation,
          accountedBytes: accountedBytes,
          deferredDecision: nil
        )
      )
    {
      authority[observation.key] = ViewerLiveAuthorityEntry(
        observationID: observation.observationID,
        header: header,
        hasCurrentValue: true,
        pendingDuplicateCount: 0
      )
      shouldSchedule = markDirtyLocked()
      result = .accepted
    } else {
      pendingIngressOverflowCount = Self.saturatingIncrement(pendingIngressOverflowCount)
      shouldSchedule = markDirtyLocked()
      result = .untracked
    }
    ingressLock.unlock()
    if shouldSchedule { scheduleDrain() }
    return result
  }

  func sessionStarted(_ metadata: ViewerFrozenSessionMetadata, connectionID: UUID) {
    var shouldSchedule = false
    ingressLock.lock()
    if !cleared {
      beginSessionLifecycleLocked()
      if activeSessionMetadata[connectionID] != nil {
        activeSessionMetadata[connectionID] = metadata
      } else {
        releaseTerminalMetadataForActiveSessionLocked()
        if frozenSessionMetadataCountLocked < ViewerLiveProjectionLimits.maximumSessions {
          activeSessionMetadata[connectionID] = metadata
        } else {
          pendingDiagnosticLossCount = Self.saturatingIncrement(pendingDiagnosticLossCount)
        }
      }
      sessionStateDirty = true
      shouldSchedule = markDirtyLocked()
    }
    ingressLock.unlock()
    if shouldSchedule { scheduleDrain() }
  }

  func laterDisposition(
    key: ViewerEventJournalKey,
    disposition: ViewerEventDisposition
  ) {
    var shouldSchedule = false
    ingressLock.lock()
    if !cleared, authority[key] != nil {
      if pendingDispositions[key] != nil
        || pendingDispositions.count < ViewerLiveProjectionLimits.retainedCount
      {
        pendingDispositions[key] = disposition
      } else {
        pendingDiagnosticLossCount = Self.saturatingIncrement(pendingDiagnosticLossCount)
      }
      shouldSchedule = markDirtyLocked()
    }
    ingressLock.unlock()
    if shouldSchedule { scheduleDrain() }
  }

  func dropsChanged(connectionID: UUID, samples: [ViewerDropJournalSample]) {
    var shouldSchedule = false
    ingressLock.lock()
    if !cleared {
      var counts = pendingDropCounts[connectionID] ?? [:]
      for sample in samples where sample.count > 0 { counts[sample.reason] = sample.count }
      if pendingDropCounts[connectionID] != nil
        || pendingDropCounts.count < ViewerLiveProjectionLimits.maximumSessions
      {
        pendingDropCounts[connectionID] = counts
      } else {
        pendingDiagnosticLossCount = Self.saturatingIncrement(pendingDiagnosticLossCount)
      }
      shouldSchedule = markDirtyLocked()
    }
    ingressLock.unlock()
    if shouldSchedule { scheduleDrain() }
  }

  func sessionEnded(
    connectionID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {
    var shouldSchedule = false
    ingressLock.lock()
    if !cleared {
      beginSessionLifecycleLocked()
      let metadata = activeSessionMetadata.removeValue(forKey: connectionID)
      let existingTermination = pendingSessionTerminations[connectionID]
      let termination = ViewerPendingSessionTermination(
        metadata: projectedSessionIDs.contains(connectionID)
          ? nil : (metadata ?? existingTermination?.metadata),
        wallMilliseconds: wallMilliseconds,
        monotonicNanoseconds: monotonicNanoseconds
      )
      if pendingSessionTerminations[connectionID] != nil
        || pendingSessionTerminations.count < ViewerLiveProjectionLimits.maximumSessions
      {
        pendingSessionTerminations[connectionID] = termination
      } else if projectedSessionIDs.contains(connectionID),
        let replaceableID = pendingSessionTerminations.keys
          .filter({ !projectedSessionIDs.contains($0) })
          .min(by: { $0.uuidString < $1.uuidString })
      {
        pendingSessionTerminations.removeValue(forKey: replaceableID)
        pendingSessionTerminations[connectionID] = termination
        pendingDiagnosticLossCount = Self.saturatingIncrement(pendingDiagnosticLossCount)
      } else {
        pendingDiagnosticLossCount = Self.saturatingIncrement(pendingDiagnosticLossCount)
      }
      sessionStateDirty = true
      shouldSchedule = markDirtyLocked()
    }
    ingressLock.unlock()
    if shouldSchedule { scheduleDrain() }
  }

  func setRefreshHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
    refreshLock.lock()
    refreshHandler = handler
    refreshLock.unlock()
  }

  func setPresentationPaused(_ paused: Bool) {
    var request: (UInt64, UInt64)?
    refreshLock.lock()
    presentationPaused = paused
    if !paused { request = makeWakeRequestLocked() }
    refreshLock.unlock()
    if let request { scheduleWake(token: request.0, delay: request.1) }
  }

  func clearCurrentSession() {
    let completion = DispatchGroup()
    completion.enter()
    var deferred: [ViewerLiveIngressEntry] = []

    ingressLock.lock()
    while ingressCount > 0 {
      if let entry = ingress[ingressHead] { deferred.append(entry) }
      ingress[ingressHead] = nil
      ingressHead = (ingressHead + 1) % ingress.count
      ingressCount -= 1
    }
    ingressBytes = 0
    let preservedActiveSessionIDs = Set(activeSessionMetadata.keys)
    authority.removeAll(keepingCapacity: true)
    pendingDispositions.removeAll(keepingCapacity: true)
    pendingSessionTerminations.removeAll(keepingCapacity: true)
    projectedSessionIDs.formIntersection(preservedActiveSessionIDs)
    importedSessionIDs.removeAll(keepingCapacity: true)
    sessionLifecycleTransitionPending = false
    sessionStateDirty = false
    pendingDropCounts.removeAll(keepingCapacity: true)
    pendingConflictKeys.removeAll(keepingCapacity: true)
    pendingIngressOverflowCount = 0
    pendingDiagnosticLossCount = 0
    projectionQueue.async { [self] in
      let removed = window.removeAll()
      for key in Array(sessions.keys) {
        if preservedActiveSessionIDs.contains(key) {
          sessions[key]?.dropCounts.removeAll(keepingCapacity: true)
        } else {
          sessions.removeValue(forKey: key)
        }
      }
      conflictMarkers.removeAll()
      ingressOverflowCount = 0
      windowOverflowCount = 0
      diagnosticLossCount = 0
      performanceSliceRevision = 0
      publishSnapshot()
      withExtendedLifetime(removed) {}
      completion.leave()
    }
    ingressLock.unlock()

    for entry in deferred where entry.kind == .deferredDuplicate {
      entry.deferredDecision?(.sealed)
    }
    withExtendedLifetime(deferred) {}
    completion.wait()
  }

  func replaceCurrentSession(_ replacement: ViewerMemorySessionReplacement) throws {
    let sessionIDs = replacement.sessions.map(\.connectionID)
    guard replacement.sessions.count <= ViewerLiveProjectionLimits.maximumSessions,
      Set(sessionIDs).count == sessionIDs.count,
      replacement.events.count <= ViewerLiveProjectionLimits.retainedCount,
      replacement.events.allSatisfy({
        $0.key.runtimeLogicalID == runtimeLogicalID && Set(sessionIDs).contains($0.key.connectionID)
      })
    else { throw ViewerWorkspaceMutationFailure.capacityExceeded }
    var accountedBytes = 0
    for event in replacement.events {
      guard let bytes = ViewerLiveProjectionLimits.accountedBytes(for: event),
        bytes <= ViewerLiveProjectionLimits.retainedBytes - accountedBytes
      else { throw ViewerWorkspaceMutationFailure.capacityExceeded }
      accountedBytes += bytes
    }

    flushIngressForWorkspaceMutation()
    var deferred: [ViewerLiveIngressEntry] = []
    ingressLock.lock()
    while ingressCount > 0 {
      if let entry = ingress[ingressHead] { deferred.append(entry) }
      ingress[ingressHead] = nil
      ingressHead = (ingressHead + 1) % ingress.count
      ingressCount -= 1
    }
    ingressBytes = 0
    authority.removeAll(keepingCapacity: false)
    pendingDispositions.removeAll(keepingCapacity: false)
    activeSessionMetadata.removeAll(keepingCapacity: false)
    pendingSessionTerminations.removeAll(keepingCapacity: false)
    projectedSessionIDs = Set(sessionIDs)
    importedSessionIDs = Set(sessionIDs)
    tracksSessionLifecycle = true
    sessionLifecycleTransitionPending = false
    sessionStateDirty = false
    pendingDropCounts.removeAll(keepingCapacity: false)
    pendingConflictKeys.removeAll(keepingCapacity: false)
    pendingIngressOverflowCount = 0
    pendingDiagnosticLossCount = 0
    ingressLock.unlock()

    projectionQueue.sync {
      let removed = window.removeAll()
      sessions = Dictionary(
        uniqueKeysWithValues: replacement.sessions.map { session in
          (
            session.connectionID,
            ViewerLiveSessionState(
              metadata: session.metadata,
              dropCounts:
                session.positiveDropCount > 0
                ? [.remoteOverflow: session.positiveDropCount] : [:],
              endedWallMilliseconds: session.endedWallMilliseconds,
              endedMonotonicNanoseconds: session.endedMonotonicNanoseconds
            )
          )
        }
      )
      for event in replacement.events {
        guard let bytes = ViewerLiveProjectionLimits.accountedBytes(for: event) else { continue }
        _ = window.insert(event, accountedBytes: bytes)
      }
      conflictMarkers.removeAll()
      ingressOverflowCount = replacement.gaps.ingressOverflowCount
      windowOverflowCount = replacement.gaps.windowOverflowCount
      diagnosticLossCount = Self.saturatingAdd(
        replacement.gaps.diagnosticLossCount,
        replacement.gaps.residentConflictCount
      )
      performanceSliceRevision = 0
      publishSnapshot()
      withExtendedLifetime(removed) {}
    }
    for entry in deferred where entry.kind == .deferredDuplicate {
      entry.deferredDecision?(.sealed)
    }
    withExtendedLifetime(deferred) {}
  }

  func flushIngressForWorkspaceMutation() {
    projectionQueue.sync {
      ingressLock.lock()
      guard !cleared, !ingestionSealed else {
        ingressLock.unlock()
        return
      }
      let work = takePendingWorkLocked()
      ingressLock.unlock()
      if applyPendingWork(work) { publishSnapshot() }
    }
  }

  func sealPresentation() -> Task<Void, Never> {
    ingressLock.lock()
    presentationSealed = true
    ingressLock.unlock()
    refreshLock.lock()
    refreshSealed = true
    refreshDirty = false
    wakeScheduled = false
    wakeToken = Self.saturatingIncrement(wakeToken)
    refreshLock.unlock()
    return Task {}
  }

  func finishIngress() async {
    let shouldSchedule = beginFinishingIngress()
    if shouldSchedule { scheduleDrain() }
    await withCheckedContinuation { continuation in
      projectionQueue.async { continuation.resume() }
    }
  }

  func runtimeEnded() async {
    await finishIngress()
    await withCheckedContinuation { continuation in
      projectionQueue.async { [self] in
        clearProjection()
        continuation.resume()
      }
    }
  }

  func snapshot() -> ViewerLiveProjectionSnapshot {
    snapshotLock.lock()
    defer { snapshotLock.unlock() }
    return publishedSnapshot
  }

  func freezePerformance(connectionID: UUID) throws -> ViewerPerformanceLiveSlice {
    try projectionQueue.sync {
      ingressLock.lock()
      guard !cleared, !ingestionSealed else {
        ingressLock.unlock()
        throw ViewerPerformanceFailure.unavailable
      }
      let work = takePendingWorkLocked()
      ingressLock.unlock()

      if applyPendingWork(work) { publishSnapshot() }
      guard sessions[connectionID] != nil || window.contains(connectionID: connectionID) else {
        throw ViewerPerformanceFailure.invalidScope
      }
      let anchor: UInt64
      if importedSessionIDs.contains(connectionID) {
        let eventUpper = window.orderedNodes().lazy
          .filter { $0.observation.key.connectionID == connectionID }
          .map { $0.observation.viewerMonotonicNanoseconds }
          .max()
        anchor = max(
          sessions[connectionID]?.endedMonotonicNanoseconds ?? 0,
          eventUpper ?? 0
        )
      } else {
        anchor = refreshScheduler.now()
      }
      guard performanceSliceRevision < UInt64.max else {
        throw ViewerPerformanceFailure.limitExceeded
      }
      performanceSliceRevision += 1
      return try makePerformanceSlice(
        connectionID: connectionID,
        revision: performanceSliceRevision,
        anchorMonotonicNanoseconds: anchor
      )
    }
  }

  func performanceEventLocator(for key: ViewerEventJournalKey) -> ViewerPerformanceEventLocator? {
    projectionQueue.sync {
      guard !cleared, key.runtimeLogicalID == runtimeLogicalID,
        let node = window.node(for: key),
        node.observation.envelope.type.rawValue == PerformanceSnapshotSchema.eventTypeRawValue
      else { return nil }
      return .memory(observationID: node.observation.observationID)
    }
  }

  @discardableResult
  func evict(_ key: ViewerEventJournalKey) -> ViewerCommittedEventObservation? {
    let removed = projectionQueue.sync { () -> ViewerLiveWindowNode? in
      let removed = window.remove(key: key)
      if let removed {
        releaseAuthority(for: removed.observation)
        windowOverflowCount = Self.saturatingIncrement(windowOverflowCount)
        publishSnapshot()
      }
      return removed
    }
    return removed?.observation
  }

  func waitForProjectionForTesting() { projectionQueue.sync {} }

  func diagnosticsForTesting() -> ViewerLiveProjectionDiagnostics {
    let projection: (UInt64, UInt64, UInt64)
    projection = projectionQueue.sync {
      (drainRunCount, maximumConcurrentDrainCount, snapshotPublicationCount)
    }
    ingressLock.lock()
    let ingress = (ingressOfferCount, drainScheduleCount, dirtySuccessorCount)
    ingressLock.unlock()
    refreshLock.lock()
    let refresh = (refreshScheduleCount, refreshDeliveryCount)
    refreshLock.unlock()
    return ViewerLiveProjectionDiagnostics(
      ingressOfferCount: ingress.0,
      drainScheduleCount: ingress.1,
      dirtySuccessorCount: ingress.2,
      drainRunCount: projection.0,
      maximumConcurrentDrainCount: projection.1,
      snapshotPublicationCount: projection.2,
      refreshScheduleCount: refresh.0,
      refreshDeliveryCount: refresh.1
    )
  }

  var isPresentationSealed: Bool {
    ingressLock.lock()
    defer { ingressLock.unlock() }
    return presentationSealed
  }

  var isCleared: Bool {
    ingressLock.lock()
    defer { ingressLock.unlock() }
    return cleared
  }

  var retainedObservationCount: Int { snapshot().events.count }
  var retainedObservationBytes: Int { snapshot().accountedEventBytes }

  var activeSessionMetadataCountForTesting: Int {
    ingressLock.lock()
    defer { ingressLock.unlock() }
    return activeSessionMetadata.count
  }

  var pendingSessionTerminationCountForTesting: Int {
    ingressLock.lock()
    defer { ingressLock.unlock() }
    return pendingSessionTerminations.count
  }

  var authorityCountForTesting: Int {
    ingressLock.lock()
    defer { ingressLock.unlock() }
    return authority.count
  }

  var ownerlessAuthorityCountForTesting: Int {
    ingressLock.lock()
    defer { ingressLock.unlock() }
    return authority.values.filter { !$0.hasCurrentValue && $0.pendingDuplicateCount == 0 }.count
  }
  var conflictCount: UInt64 { snapshot().gaps.residentConflictCount }

  var lostHorizonCount: UInt64 {
    let gaps = snapshot().gaps
    return Self.saturatingSum(
      gaps.ingressOverflowCount,
      gaps.windowOverflowCount,
      gaps.diagnosticLossCount
    )
  }

  private func admitIngressLocked(_ entry: ViewerLiveIngressEntry) -> Bool {
    guard ingressCount < ViewerLiveProjectionLimits.ingressCount,
      entry.accountedBytes <= ViewerLiveProjectionLimits.ingressBytes - ingressBytes
    else { return false }
    ingress[ingressTail] = entry
    ingressTail = (ingressTail + 1) % ingress.count
    ingressCount += 1
    ingressBytes += entry.accountedBytes
    return true
  }

  private func beginFinishingIngress() -> Bool {
    ingressLock.lock()
    guard !ingestionSealed else {
      ingressLock.unlock()
      return false
    }
    ingestionSealed = true
    let shouldSchedule = markDirtyLocked()
    ingressLock.unlock()
    return shouldSchedule
  }

  private func markDirtyLocked() -> Bool {
    if drainScheduled {
      if !dirtySuccessor {
        dirtySuccessorCount = Self.saturatingIncrement(dirtySuccessorCount)
      }
      dirtySuccessor = true
      return false
    }
    drainScheduled = true
    drainScheduleCount = Self.saturatingIncrement(drainScheduleCount)
    dirtySuccessor = false
    return true
  }

  private func beginSessionLifecycleLocked() {
    guard !tracksSessionLifecycle else { return }
    tracksSessionLifecycle = true
    sessionLifecycleTransitionPending = true
  }

  private var frozenSessionMetadataCountLocked: Int {
    activeSessionMetadata.count
      + pendingSessionTerminations.values.reduce(into: 0) { count, termination in
        if termination.metadata != nil { count += 1 }
      }
  }

  private func releaseTerminalMetadataForActiveSessionLocked() {
    guard frozenSessionMetadataCountLocked >= ViewerLiveProjectionLimits.maximumSessions else {
      return
    }
    let candidate = pendingSessionTerminations.compactMap {
      connectionID, termination -> (UUID, ViewerPendingSessionTermination)? in
      guard termination.metadata != nil else { return nil }
      return (connectionID, termination)
    }.min {
      let leftIsProjected = projectedSessionIDs.contains($0.0)
      let rightIsProjected = projectedSessionIDs.contains($1.0)
      if leftIsProjected != rightIsProjected { return leftIsProjected }
      if $0.1.monotonicNanoseconds != $1.1.monotonicNanoseconds {
        return $0.1.monotonicNanoseconds < $1.1.monotonicNanoseconds
      }
      return $0.0.uuidString < $1.0.uuidString
    }
    guard let candidate else { return }
    if projectedSessionIDs.contains(candidate.0) {
      var termination = candidate.1
      termination.metadata = nil
      pendingSessionTerminations[candidate.0] = termination
    } else {
      pendingSessionTerminations.removeValue(forKey: candidate.0)
      pendingDiagnosticLossCount = Self.saturatingIncrement(pendingDiagnosticLossCount)
    }
  }

  private func scheduleDrain() {
    projectionQueue.async { [weak self] in self?.drain() }
  }

  private func drain() {
    drainRunCount = Self.saturatingIncrement(drainRunCount)
    activeDrainCount = Self.saturatingIncrement(activeDrainCount)
    maximumConcurrentDrainCount = max(maximumConcurrentDrainCount, activeDrainCount)
    defer { activeDrainCount -= 1 }
    while true {
      let work = takePendingWork()
      if applyPendingWork(work) { publishSnapshot() }

      ingressLock.lock()
      let hasMoreWork = hasPendingWorkLocked()
      if hasMoreWork {
        dirtySuccessor = false
        ingressLock.unlock()
        continue
      }
      drainScheduled = false
      dirtySuccessor = false
      ingressLock.unlock()
      return
    }
  }

  private struct PendingWork {
    let entries: [ViewerLiveIngressEntry]
    let dispositions: [ViewerEventJournalKey: ViewerEventDisposition]
    let activeSessions: [UUID: ViewerFrozenSessionMetadata]
    let tracksSessionLifecycle: Bool
    let sessionLifecycleTransition: Bool
    let sessionTerminations: [UUID: ViewerPendingSessionTermination]
    let dropCounts: [UUID: [ViewerDropJournalSample.Reason: UInt64]]
    let conflictKeys: Set<ViewerEventJournalKey>
    let ingressOverflowCount: UInt64
    let diagnosticLossCount: UInt64
  }

  private func takePendingWork() -> PendingWork {
    ingressLock.lock()
    let work = takePendingWorkLocked()
    ingressLock.unlock()
    return work
  }

  private func takePendingWorkLocked() -> PendingWork {
    var entries: [ViewerLiveIngressEntry] = []
    entries.reserveCapacity(ingressCount)
    while ingressCount > 0 {
      if let entry = ingress[ingressHead] {
        entries.append(entry)
        ingressBytes -= entry.accountedBytes
      }
      ingress[ingressHead] = nil
      ingressHead = (ingressHead + 1) % ingress.count
      ingressCount -= 1
    }
    let dispositions = pendingDispositions
    let activeSessions = activeSessionMetadata
    let tracksSessionLifecycle = self.tracksSessionLifecycle
    let sessionLifecycleTransition = sessionLifecycleTransitionPending
    let sessionTerminations = pendingSessionTerminations
    let dropCounts = pendingDropCounts
    let conflictKeys = pendingConflictKeys
    let ingressOverflow = pendingIngressOverflowCount
    let diagnosticLoss = pendingDiagnosticLossCount
    pendingDispositions.removeAll(keepingCapacity: true)
    pendingSessionTerminations.removeAll(keepingCapacity: true)
    sessionStateDirty = false
    sessionLifecycleTransitionPending = false
    pendingDropCounts.removeAll(keepingCapacity: true)
    pendingConflictKeys.removeAll(keepingCapacity: true)
    pendingIngressOverflowCount = 0
    pendingDiagnosticLossCount = 0
    return PendingWork(
      entries: entries,
      dispositions: dispositions,
      activeSessions: activeSessions,
      tracksSessionLifecycle: tracksSessionLifecycle,
      sessionLifecycleTransition: sessionLifecycleTransition,
      sessionTerminations: sessionTerminations,
      dropCounts: dropCounts,
      conflictKeys: conflictKeys,
      ingressOverflowCount: ingressOverflow,
      diagnosticLossCount: diagnosticLoss
    )
  }

  private func applyPendingWork(_ work: PendingWork) -> Bool {
    var changed = work.ingressOverflowCount > 0 || work.diagnosticLossCount > 0
    ingressOverflowCount = Self.saturatingAdd(
      ingressOverflowCount,
      work.ingressOverflowCount
    )
    diagnosticLossCount = Self.saturatingAdd(
      diagnosticLossCount,
      work.diagnosticLossCount
    )
    if work.sessionLifecycleTransition {
      changed =
        reconcileDirectObservationSessions(
          activeSessions: work.activeSessions,
          terminatingSessions: Set(work.sessionTerminations.keys)
        ) || changed
    }
    for (connectionID, termination) in work.sessionTerminations.sorted(by: {
      $0.key.uuidString < $1.key.uuidString
    }) {
      if applySessionTermination(connectionID: connectionID, termination: termination) {
        changed = true
      } else {
        diagnosticLossCount = Self.saturatingIncrement(diagnosticLossCount)
        changed = true
      }
    }
    for (connectionID, metadata) in work.activeSessions.sorted(by: {
      $0.key.uuidString < $1.key.uuidString
    }) {
      changed = applyActiveSession(connectionID: connectionID, metadata: metadata) || changed
    }
    let frozenActiveConnectionIDs: Set<UUID>? =
      work.tracksSessionLifecycle
      ? Set(work.activeSessions.keys) : nil
    for entry in work.entries {
      changed = true
      let connectionID = entry.observation.key.connectionID
      if !work.tracksSessionLifecycle || work.activeSessions[connectionID] != nil
        || sessions[connectionID] != nil
      {
        process(entry, frozenActiveConnectionIDs: frozenActiveConnectionIDs)
      } else {
        discardForSessionChurn(entry)
      }
    }
    for (connectionID, counts) in work.dropCounts {
      guard var session = sessions[connectionID] else {
        diagnosticLossCount = Self.saturatingIncrement(diagnosticLossCount)
        changed = true
        continue
      }
      for (reason, count) in counts { session.dropCounts[reason] = count }
      sessions[connectionID] = session
      changed = true
    }
    for (key, disposition) in work.dispositions {
      if window.setDisposition(disposition, for: key) { changed = true }
    }
    for key in work.conflictKeys {
      if !window.markPresentationConflict(key) {
        diagnosticLossCount = Self.saturatingIncrement(diagnosticLossCount)
      }
      changed = true
    }
    changed = reclaimUnreferencedEndedSessions() || changed
    return changed
  }

  private func hasPendingWorkLocked() -> Bool {
    ingressCount > 0 || !pendingDispositions.isEmpty
      || sessionStateDirty || !pendingSessionTerminations.isEmpty
      || !pendingDropCounts.isEmpty
      || !pendingConflictKeys.isEmpty || pendingIngressOverflowCount > 0
      || pendingDiagnosticLossCount > 0 || dirtySuccessor
  }

  private func process(
    _ entry: ViewerLiveIngressEntry,
    frozenActiveConnectionIDs: Set<UUID>?
  ) {
    switch entry.kind {
    case .newAuthority:
      insertNewAuthority(
        entry.observation,
        accountedBytes: entry.accountedBytes,
        frozenActiveConnectionIDs: frozenActiveConnectionIDs
      )
    case .deferredDuplicate:
      if let existing = window.node(for: entry.observation.key) {
        completePendingDuplicate(for: entry.observation.key)
        if existing.observation.canonicalProjection == entry.observation.canonicalProjection {
          entry.deferredDecision?(.identical)
        } else {
          _ = window.markPresentationConflict(entry.observation.key)
          entry.deferredDecision?(.presentationConflict)
        }
      } else if claimMissingAuthority(entry.observation) {
        insertNewAuthority(
          entry.observation,
          accountedBytes: entry.accountedBytes,
          frozenActiveConnectionIDs: frozenActiveConnectionIDs
        )
        entry.deferredDecision?(.accepted)
      } else {
        diagnosticLossCount = Self.saturatingIncrement(diagnosticLossCount)
        entry.deferredDecision?(.untracked)
      }
    }
  }

  private func discardForSessionChurn(_ entry: ViewerLiveIngressEntry) {
    switch entry.kind {
    case .newAuthority:
      releaseAuthority(for: entry.observation)
    case .deferredDuplicate:
      completePendingDuplicate(for: entry.observation.key)
      entry.deferredDecision?(.untracked)
    }
    windowOverflowCount = Self.saturatingIncrement(windowOverflowCount)
  }

  private func insertNewAuthority(
    _ observation: ViewerCommittedEventObservation,
    accountedBytes: Int,
    frozenActiveConnectionIDs: Set<UUID>?
  ) {
    if sessions[observation.key.connectionID] == nil {
      if makeRoomForSession(observation.key.connectionID) {
        guard
          reserveProjectedSessionIDIfActive(
            observation.key.connectionID,
            frozenActiveConnectionIDs: frozenActiveConnectionIDs
          )
        else {
          releaseAuthority(for: observation)
          windowOverflowCount = Self.saturatingIncrement(windowOverflowCount)
          return
        }
        sessions[observation.key.connectionID] = ViewerLiveSessionState(
          metadata: observation.session
        )
      } else {
        diagnosticLossCount = Self.saturatingIncrement(diagnosticLossCount)
      }
    } else if var session = sessions[observation.key.connectionID] {
      session.metadata = observation.session
      sessions[observation.key.connectionID] = session
    }
    let displaced = window.insert(observation, accountedBytes: accountedBytes)
    if window.node(for: observation.key) == nil {
      releaseAuthority(for: observation)
      ingressOverflowCount = Self.saturatingIncrement(ingressOverflowCount)
    }
    for node in displaced {
      releaseAuthority(for: node.observation)
      windowOverflowCount = Self.saturatingIncrement(windowOverflowCount)
    }
    withExtendedLifetime(displaced) {}
  }

  private func completePendingDuplicate(for key: ViewerEventJournalKey) {
    ingressLock.lock()
    if var entry = authority[key] {
      entry.pendingDuplicateCount = max(0, entry.pendingDuplicateCount - 1)
      if entry.pendingDuplicateCount == 0, !entry.hasCurrentValue {
        authority.removeValue(forKey: key)
      } else {
        authority[key] = entry
      }
    }
    ingressLock.unlock()
  }

  private func claimMissingAuthority(_ observation: ViewerCommittedEventObservation) -> Bool {
    ingressLock.lock()
    defer { ingressLock.unlock() }
    guard var entry = authority[observation.key], !entry.hasCurrentValue,
      entry.pendingDuplicateCount > 0
    else { return false }
    entry.pendingDuplicateCount -= 1
    entry.observationID = observation.observationID
    entry.header = ViewerCanonicalProjectionHeader(observation.canonicalProjection)
    entry.hasCurrentValue = true
    authority[observation.key] = entry
    return true
  }

  private func releaseAuthority(for observation: ViewerCommittedEventObservation) {
    ingressLock.lock()
    if var entry = authority[observation.key],
      entry.observationID == observation.observationID
    {
      if entry.pendingDuplicateCount > 0 {
        entry.hasCurrentValue = false
        authority[observation.key] = entry
      } else {
        authority.removeValue(forKey: observation.key)
      }
    }
    ingressLock.unlock()
  }

  private func reconcileDirectObservationSessions(
    activeSessions: [UUID: ViewerFrozenSessionMetadata],
    terminatingSessions: Set<UUID>
  ) -> Bool {
    let obsoleteConnectionIDs = sessions.keys.filter {
      activeSessions[$0] == nil && !terminatingSessions.contains($0)
        && !importedSessionIDs.contains($0)
    }
    guard !obsoleteConnectionIDs.isEmpty else { return false }
    let obsoleteConnectionIDSet = Set(obsoleteConnectionIDs)
    for connectionID in obsoleteConnectionIDs {
      let displaced = window.removeAll(connectionID: connectionID)
      sessions.removeValue(forKey: connectionID)
      importedSessionIDs.remove(connectionID)
      releaseProjectedSessionID(connectionID)
      for node in displaced {
        releaseAuthority(for: node.observation)
        windowOverflowCount = Self.saturatingIncrement(windowOverflowCount)
      }
      withExtendedLifetime(displaced) {}
    }
    let removedConflictCount = conflictMarkers.remove(connectionIDs: obsoleteConnectionIDSet)
    diagnosticLossCount = Self.saturatingAdd(
      diagnosticLossCount,
      UInt64(removedConflictCount)
    )
    return true
  }

  private func applyActiveSession(
    connectionID: UUID,
    metadata: ViewerFrozenSessionMetadata
  ) -> Bool {
    if var session = sessions[connectionID] {
      guard session.metadata != metadata || session.endedMonotonicNanoseconds != nil else {
        return false
      }
      session.metadata = metadata
      session.endedWallMilliseconds = nil
      session.endedMonotonicNanoseconds = nil
      sessions[connectionID] = session
      return true
    }
    guard makeRoomForSession(connectionID) else {
      diagnosticLossCount = Self.saturatingIncrement(diagnosticLossCount)
      return true
    }
    guard
      reserveProjectedSessionIDIfActive(
        connectionID,
        frozenActiveConnectionIDs: Set([connectionID])
      )
    else { return false }
    sessions[connectionID] = ViewerLiveSessionState(
      metadata: metadata,
      endedWallMilliseconds: nil,
      endedMonotonicNanoseconds: nil
    )
    return true
  }

  private func applySessionTermination(
    connectionID: UUID,
    termination: ViewerPendingSessionTermination
  ) -> Bool {
    if sessions[connectionID] == nil {
      guard let metadata = termination.metadata, makeRoomForSession(connectionID) else {
        return false
      }
      reserveProjectedSessionIDForTermination(connectionID)
      sessions[connectionID] = ViewerLiveSessionState(metadata: metadata)
    }
    guard var session = sessions[connectionID] else { return false }
    session.endedWallMilliseconds = termination.wallMilliseconds
    session.endedMonotonicNanoseconds = termination.monotonicNanoseconds
    sessions[connectionID] = session
    return true
  }

  private func reclaimUnreferencedEndedSessions() -> Bool {
    let removable = sessions.compactMap { connectionID, session -> UUID? in
      guard session.endedMonotonicNanoseconds != nil,
        !window.contains(connectionID: connectionID)
      else { return nil }
      return connectionID
    }
    for connectionID in removable {
      sessions.removeValue(forKey: connectionID)
      releaseProjectedSessionID(connectionID)
    }
    let removedConflictCount = conflictMarkers.remove(connectionIDs: Set(removable))
    diagnosticLossCount = Self.saturatingAdd(
      diagnosticLossCount,
      UInt64(removedConflictCount)
    )
    return !removable.isEmpty
  }

  private func makeRoomForSession(_ connectionID: UUID) -> Bool {
    if sessions[connectionID] != nil { return true }
    _ = reclaimUnreferencedEndedSessions()
    if sessions.count < ViewerLiveProjectionLimits.maximumSessions { return true }
    let terminal = sessions.compactMap { candidateID, session -> (UUID, UInt64)? in
      guard let ended = session.endedMonotonicNanoseconds else { return nil }
      return (candidateID, ended)
    }.min {
      $0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1 < $1.1
    }
    guard let terminal else { return false }
    let displaced = window.removeAll(connectionID: terminal.0)
    sessions.removeValue(forKey: terminal.0)
    importedSessionIDs.remove(terminal.0)
    releaseProjectedSessionID(terminal.0)
    let removedConflictCount = conflictMarkers.remove(connectionIDs: Set([terminal.0]))
    diagnosticLossCount = Self.saturatingAdd(
      diagnosticLossCount,
      UInt64(removedConflictCount)
    )
    for node in displaced {
      releaseAuthority(for: node.observation)
      windowOverflowCount = Self.saturatingIncrement(windowOverflowCount)
    }
    if displaced.isEmpty {
      diagnosticLossCount = Self.saturatingIncrement(diagnosticLossCount)
    }
    withExtendedLifetime(displaced) {}
    return true
  }

  private func reserveProjectedSessionIDIfActive(
    _ connectionID: UUID,
    frozenActiveConnectionIDs: Set<UUID>?
  ) -> Bool {
    ingressLock.lock()
    let isActive =
      frozenActiveConnectionIDs?.contains(connectionID)
      ?? (!tracksSessionLifecycle || activeSessionMetadata[connectionID] != nil)
    guard isActive else {
      ingressLock.unlock()
      return false
    }
    projectedSessionIDs.insert(connectionID)
    ingressLock.unlock()
    return true
  }

  private func reserveProjectedSessionIDForTermination(_ connectionID: UUID) {
    ingressLock.lock()
    projectedSessionIDs.insert(connectionID)
    ingressLock.unlock()
  }

  private func releaseProjectedSessionID(_ connectionID: UUID) {
    ingressLock.lock()
    projectedSessionIDs.remove(connectionID)
    ingressLock.unlock()
  }

  private func makePerformanceSlice(
    connectionID: UUID,
    revision: UInt64,
    anchorMonotonicNanoseconds: UInt64
  ) throws -> ViewerPerformanceLiveSlice {
    let candidates = window.orderedNodes().compactMap { node -> ViewerCommittedEventObservation? in
      let observation = node.observation
      guard observation.key.connectionID == connectionID,
        observation.canonicalProjection.eventType.rawValue
          == PerformanceSnapshotSchema.eventTypeRawValue,
        observation.viewerMonotonicNanoseconds <= anchorMonotonicNanoseconds
      else { return nil }
      return observation
    }.sorted { lhs, rhs in
      if lhs.viewerMonotonicNanoseconds != rhs.viewerMonotonicNanoseconds {
        return lhs.viewerMonotonicNanoseconds < rhs.viewerMonotonicNanoseconds
      }
      return ViewerPerformanceCanonicalOrder.keyPrecedes(lhs.key, rhs.key)
    }

    var events: [ViewerPerformanceEventCarrier] = []
    events.reserveCapacity(min(candidates.count, ViewerPerformanceLimits.maximumEmittedEvents))
    var copiedContentBytes = 0
    var omittedEventCount: UInt64 = 0
    for (index, observation) in candidates.enumerated() {
      guard events.count < ViewerPerformanceLimits.maximumEmittedEvents,
        let viewerMonotonic = Int64(exactly: observation.viewerMonotonicNanoseconds)
      else {
        omittedEventCount = Self.saturatingAdd(
          omittedEventCount,
          UInt64(candidates.count - index)
        )
        break
      }
      let canonical = observation.canonicalProjection.canonicalContent
      let content: ViewerPerformanceEventContent
      if canonical.count > ViewerPerformanceLimits.maximumRowContentBytes {
        content = .oversized(byteCount: Int64(canonical.count))
      } else {
        let (nextBytes, overflow) = copiedContentBytes.addingReportingOverflow(canonical.count)
        guard !overflow, nextBytes <= ViewerPerformanceLimits.maximumCopiedContentBytes else {
          omittedEventCount = Self.saturatingAdd(
            omittedEventCount,
            UInt64(candidates.count - index)
          )
          break
        }
        copiedContentBytes = nextBytes
        content = .canonical(canonical)
      }
      events.append(
        try ViewerPerformanceEventCarrier(
          locator: .memory(observationID: observation.observationID),
          key: observation.key,
          viewerWallMilliseconds: observation.viewerWallMilliseconds,
          viewerMonotonicNanoseconds: viewerMonotonic,
          content: content
        )
      )
    }

    let snapshot = snapshot().gaps
    let eventLossCount = Self.saturatingSum(
      snapshot.ingressOverflowCount,
      snapshot.windowOverflowCount,
      omittedEventCount
    )
    let gapValues: [(UInt64, ViewerPerformanceGapKind)] = [
      (eventLossCount, .eventLoss),
      (snapshot.residentConflictCount, .presentationLoss),
      (snapshot.diagnosticLossCount, .unknown),
    ]
    var gaps: [ViewerPerformanceGapCarrier] = []
    gaps.reserveCapacity(gapValues.count)
    var applicableOrUncertainCount: UInt64 = 0
    var hasMoreApplicableGaps = false
    for (count, kind) in gapValues where count > 0 {
      applicableOrUncertainCount = Self.saturatingAdd(applicableOrUncertainCount, count)
      guard gaps.count < ViewerPerformanceLimits.maximumLiveGaps else {
        hasMoreApplicableGaps = true
        continue
      }
      gaps.append(
        try ViewerPerformanceGapCarrier(
          count: count,
          firstViewerWallMilliseconds: nil,
          lastViewerWallMilliseconds: nil,
          kind: kind,
          applicability: .uncertain
        )
      )
    }
    if applicableOrUncertainCount > UInt64(ViewerPerformanceLimits.maximumLiveGaps) {
      hasMoreApplicableGaps = true
    }
    return try ViewerPerformanceLiveSlice(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      liveGeneration: liveGeneration,
      revision: revision,
      anchorMonotonicNanoseconds: anchorMonotonicNanoseconds,
      events: events,
      gaps: gaps,
      applicableOrUncertainCount: applicableOrUncertainCount,
      hasMoreApplicableGaps: hasMoreApplicableGaps
    )
  }

  private func publishSnapshot() {
    snapshotPublicationCount = Self.saturatingIncrement(snapshotPublicationCount)
    projectionGeneration = Self.saturatingIncrement(projectionGeneration)
    let nodes = window.orderedNodes()
    let runtimeHasGap =
      ingressOverflowCount > 0 || windowOverflowCount > 0
      || diagnosticLossCount > 0
    var residentPresentationConflicts: UInt64 = 0
    let eventSnapshots = nodes.map { node in
      let session = sessions[node.observation.key.connectionID]
      if node.hasPresentationConflict {
        residentPresentationConflicts = Self.saturatingIncrement(residentPresentationConflicts)
      }
      return ViewerLiveEventSnapshot(
        observation: node.observation,
        laterDisposition: node.laterDisposition,
        hasPresentationConflict: node.hasPresentationConflict,
        hasGap: runtimeHasGap || node.hasPresentationConflict
          || conflictMarkers.contains(node.observation.key),
        hasDrop: (session?.positiveDropCount ?? 0) > 0,
        sessionEnded: session?.endedWallMilliseconds != nil
      )
    }
    let sessionSnapshots = sessions.map { connectionID, value in
      ViewerLiveSessionSnapshot(
        connectionID: connectionID,
        metadata: value.metadata,
        isImported: importedSessionIDs.contains(connectionID),
        positiveDropCount: value.positiveDropCount,
        endedWallMilliseconds: value.endedWallMilliseconds,
        endedMonotonicNanoseconds: value.endedMonotonicNanoseconds
      )
    }.sorted { $0.connectionID.uuidString < $1.connectionID.uuidString }
    let residentConflictCount = Self.saturatingAdd(
      residentPresentationConflicts,
      UInt64(conflictMarkers.count)
    )
    let snapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: projectionGeneration,
      events: eventSnapshots,
      sessions: sessionSnapshots,
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: ingressOverflowCount,
        windowOverflowCount: windowOverflowCount,
        residentConflictCount: residentConflictCount,
        diagnosticLossCount: diagnosticLossCount
      ),
      accountedEventBytes: window.accountedBytes
    )
    snapshotLock.lock()
    publishedSnapshot = snapshot
    snapshotLock.unlock()
    requestRefresh(generation: snapshot.generation)
  }

  private func requestRefresh(generation: UInt64) {
    var request: (UInt64, UInt64)?
    refreshLock.lock()
    latestSnapshotGeneration = generation
    refreshDirty = true
    request = makeWakeRequestLocked()
    refreshLock.unlock()
    if let request { scheduleWake(token: request.0, delay: request.1) }
  }

  private func makeWakeRequestLocked() -> (UInt64, UInt64)? {
    guard refreshDirty, !presentationPaused, !refreshSealed, !wakeScheduled else { return nil }
    let now = refreshScheduler.now()
    let delay: UInt64
    if let lastWakeNanoseconds {
      let (deadline, overflow) = lastWakeNanoseconds.addingReportingOverflow(
        ViewerLiveProjectionLimits.refreshIntervalNanoseconds
      )
      delay = overflow || deadline <= now ? 0 : deadline - now
    } else {
      delay = 0
    }
    wakeToken = Self.saturatingIncrement(wakeToken)
    wakeScheduled = true
    return (wakeToken, delay)
  }

  private func scheduleWake(token: UInt64, delay: UInt64) {
    refreshLock.lock()
    guard wakeScheduled, token == wakeToken, !presentationPaused, !refreshSealed else {
      refreshLock.unlock()
      return
    }
    refreshScheduleCount = Self.saturatingIncrement(refreshScheduleCount)
    refreshLock.unlock()
    refreshScheduler.scheduleOnMain(delay) { [weak self] in self?.deliverWake(token: token) }
  }

  private func deliverWake(token: UInt64) {
    let handler: (@Sendable (UInt64) -> Void)?
    let generation: UInt64
    refreshLock.lock()
    guard wakeScheduled, token == wakeToken else {
      refreshLock.unlock()
      return
    }
    wakeScheduled = false
    guard !presentationPaused, !refreshSealed, refreshDirty else {
      refreshLock.unlock()
      return
    }
    refreshDirty = false
    refreshDeliveryCount = Self.saturatingIncrement(refreshDeliveryCount)
    lastWakeNanoseconds = refreshScheduler.now()
    handler = refreshHandler
    generation = latestSnapshotGeneration
    refreshLock.unlock()
    handler?(generation)
  }

  private func clearProjection() {
    let removed = window.removeAll()
    sessions.removeAll(keepingCapacity: false)
    conflictMarkers.removeAll()
    ingressOverflowCount = 0
    windowOverflowCount = 0
    diagnosticLossCount = 0

    var deferred: [ViewerLiveIngressEntry] = []
    ingressLock.lock()
    while ingressCount > 0 {
      if let entry = ingress[ingressHead] { deferred.append(entry) }
      ingress[ingressHead] = nil
      ingressHead = (ingressHead + 1) % ingress.count
      ingressCount -= 1
    }
    ingressBytes = 0
    authority.removeAll(keepingCapacity: false)
    pendingDispositions.removeAll(keepingCapacity: false)
    activeSessionMetadata.removeAll(keepingCapacity: false)
    pendingSessionTerminations.removeAll(keepingCapacity: false)
    projectedSessionIDs.removeAll(keepingCapacity: false)
    importedSessionIDs.removeAll(keepingCapacity: false)
    tracksSessionLifecycle = false
    sessionLifecycleTransitionPending = false
    sessionStateDirty = false
    pendingDropCounts.removeAll(keepingCapacity: false)
    pendingConflictKeys.removeAll(keepingCapacity: false)
    pendingIngressOverflowCount = 0
    pendingDiagnosticLossCount = 0
    drainScheduled = false
    dirtySuccessor = false
    presentationSealed = true
    ingestionSealed = true
    cleared = true
    ingressLock.unlock()

    projectionGeneration = Self.saturatingIncrement(projectionGeneration)
    let empty = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: projectionGeneration,
      events: [],
      sessions: [],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 0,
        residentConflictCount: 0,
        diagnosticLossCount: 0
      ),
      accountedEventBytes: 0
    )
    snapshotLock.lock()
    publishedSnapshot = empty
    snapshotLock.unlock()
    refreshLock.lock()
    refreshSealed = true
    refreshDirty = false
    wakeScheduled = false
    wakeToken = Self.saturatingIncrement(wakeToken)
    refreshHandler = nil
    refreshLock.unlock()
    for entry in deferred where entry.kind == .deferredDuplicate {
      entry.deferredDecision?(.sealed)
    }
    withExtendedLifetime(removed) {}
    withExtendedLifetime(deferred) {}
  }

  private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? value : value + 1
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : sum
  }

  private static func saturatingSum(_ values: UInt64...) -> UInt64 {
    values.reduce(UInt64(0), saturatingAdd)
  }
}

extension ViewerLiveEventSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerLiveEventSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerLiveSessionSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerLiveSessionSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerLiveGapSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerLiveGapSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerLiveProjectionSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerLiveProjectionSnapshot(events: \(events.count), sessions: \(sessions.count), redacted)"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["eventCount": events.count, "sessionCount": sessions.count],
      displayStyle: .struct
    )
  }
}

extension ViewerLiveEventWindow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerLiveEventWindow(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
