import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

enum ViewerPerformanceLimits {
  static let maximumRowContentBytes = 65_536
  static let maximumCopiedContentBytes = 4_194_304
  static let maximumEmittedEvents = 512
  static let maximumExaminedEvents = 4_096
  static let eventCarrierBytes = 512
  static let eventPageWrapperBytes = 4_096
  static let maximumEventPageBytes = 4_460_544
  static let maximumLiveGaps = 128
  static let maximumProjectionGaps = 128
  static let gapCarrierBytes = 256
  static let gapPageWrapperBytes = 512
  static let maximumGapPageEvents = 32
  static let maximumGapPageBytes = 8_704
  static let maximumLiveSliceBytes = 4_493_312
  static let decoderBufferBytes = 65_536
}

enum ViewerPerformanceStoreFailure: Error, Equatable, Sendable {
  case invalidScope
  case invalidContinuation
  case invalidCarrier
  case limitExceeded
  case workLimitExceeded
  case cancelled
  case storeReplaced
  case unavailable
}

enum ViewerPerformanceSource: Equatable, Hashable, Sendable {
  case current(runtimeLogicalID: UUID, connectionID: UUID)
  case historical(
    recordingID: Int64,
    deviceSessionID: Int64,
    recordingLogicalID: UUID,
    deviceLogicalID: UUID
  )

  static func makeHistorical(
    recordingID: Int64,
    deviceSessionID: Int64,
    recordingLogicalID: UUID,
    deviceLogicalID: UUID
  ) throws -> ViewerPerformanceSource {
    guard recordingID > 0, deviceSessionID > 0 else {
      throw ViewerPerformanceStoreFailure.invalidScope
    }
    return .historical(
      recordingID: recordingID,
      deviceSessionID: deviceSessionID,
      recordingLogicalID: recordingLogicalID,
      deviceLogicalID: deviceLogicalID
    )
  }
}

struct ViewerPerformanceStoreScope: Equatable, Hashable, Sendable {
  let storeGeneration: UInt64
  let recordingID: Int64
  let deviceSessionID: Int64
  let lowerMonotonicNanoseconds: Int64
  let upperMonotonicNanoseconds: Int64
  let eventUpperRowID: Int64
  let gapUpperRowID: Int64

  init(
    storeGeneration: UInt64,
    recordingID: Int64,
    deviceSessionID: Int64,
    lowerMonotonicNanoseconds: Int64,
    upperMonotonicNanoseconds: Int64,
    eventUpperRowID: Int64,
    gapUpperRowID: Int64
  ) throws {
    guard storeGeneration > 0, recordingID > 0, deviceSessionID > 0,
      lowerMonotonicNanoseconds >= 0,
      upperMonotonicNanoseconds >= lowerMonotonicNanoseconds,
      eventUpperRowID >= 0, gapUpperRowID >= 0
    else { throw ViewerPerformanceStoreFailure.invalidScope }
    self.storeGeneration = storeGeneration
    self.recordingID = recordingID
    self.deviceSessionID = deviceSessionID
    self.lowerMonotonicNanoseconds = lowerMonotonicNanoseconds
    self.upperMonotonicNanoseconds = upperMonotonicNanoseconds
    self.eventUpperRowID = eventUpperRowID
    self.gapUpperRowID = gapUpperRowID
  }
}

struct ViewerPerformanceContinuation: Equatable, Sendable {
  let scope: ViewerPerformanceStoreScope
  let lastExaminedMonotonicNanoseconds: Int64?
  let lastExaminedRowID: Int64?

  static func initial(scope: ViewerPerformanceStoreScope) -> ViewerPerformanceContinuation {
    ViewerPerformanceContinuation(
      scope: scope,
      lastExaminedMonotonicNanoseconds: nil,
      lastExaminedRowID: nil
    )
  }

  init(
    scope: ViewerPerformanceStoreScope,
    lastExaminedMonotonicNanoseconds: Int64?,
    lastExaminedRowID: Int64?
  ) {
    precondition((lastExaminedMonotonicNanoseconds == nil) == (lastExaminedRowID == nil))
    precondition(lastExaminedMonotonicNanoseconds.map { $0 >= 0 } ?? true)
    precondition(lastExaminedRowID.map { $0 > 0 } ?? true)
    self.scope = scope
    self.lastExaminedMonotonicNanoseconds = lastExaminedMonotonicNanoseconds
    self.lastExaminedRowID = lastExaminedRowID
  }
}

enum ViewerPerformanceEventLocator: Equatable, Hashable, Sendable {
  case durable(rowID: Int64, deviceSessionID: Int64)
  case transient(observationID: UUID)
}

enum ViewerPerformanceEventContent: Equatable, Sendable {
  case canonical(Data)
  case oversized(byteCount: Int64)

  var copiedByteCount: Int {
    switch self {
    case .canonical(let data): return data.count
    case .oversized: return 0
    }
  }

  var declaredByteCount: Int64 {
    switch self {
    case .canonical(let data): return Int64(data.count)
    case .oversized(let byteCount): return byteCount
    }
  }
}

struct ViewerPerformanceEventCarrier: Equatable, Sendable {
  let locator: ViewerPerformanceEventLocator
  let key: ViewerEventJournalKey
  let viewerWallMilliseconds: Int64
  let viewerMonotonicNanoseconds: Int64
  let content: ViewerPerformanceEventContent

  init(
    locator: ViewerPerformanceEventLocator,
    key: ViewerEventJournalKey,
    viewerWallMilliseconds: Int64,
    viewerMonotonicNanoseconds: Int64,
    content: ViewerPerformanceEventContent
  ) throws {
    switch locator {
    case .durable(let rowID, let deviceSessionID):
      guard rowID > 0, deviceSessionID > 0 else {
        throw ViewerPerformanceStoreFailure.invalidCarrier
      }
    case .transient:
      break
    }
    guard viewerMonotonicNanoseconds >= 0 else {
      throw ViewerPerformanceStoreFailure.invalidCarrier
    }
    switch content {
    case .canonical(let data):
      guard data.count <= ViewerPerformanceLimits.maximumRowContentBytes else {
        throw ViewerPerformanceStoreFailure.limitExceeded
      }
    case .oversized(let byteCount):
      guard byteCount > Int64(ViewerPerformanceLimits.maximumRowContentBytes) else {
        throw ViewerPerformanceStoreFailure.invalidCarrier
      }
    }
    self.locator = locator
    self.key = key
    self.viewerWallMilliseconds = viewerWallMilliseconds
    self.viewerMonotonicNanoseconds = viewerMonotonicNanoseconds
    self.content = content
  }

  var accountedBytes: Int {
    ViewerPerformanceLimits.eventCarrierBytes + content.copiedByteCount
  }
}

enum ViewerPerformanceCanonicalOrder {
  static func eventPrecedes(
    _ lhs: ViewerPerformanceEventCarrier,
    _ rhs: ViewerPerformanceEventCarrier
  ) -> Bool {
    if lhs.viewerMonotonicNanoseconds != rhs.viewerMonotonicNanoseconds {
      return lhs.viewerMonotonicNanoseconds < rhs.viewerMonotonicNanoseconds
    }
    return keyPrecedes(lhs.key, rhs.key)
  }

  static func keyPrecedes(_ lhs: ViewerEventJournalKey, _ rhs: ViewerEventJournalKey) -> Bool {
    let runtimeComparison = compareUUID(lhs.runtimeLogicalID, rhs.runtimeLogicalID)
    if runtimeComparison != 0 { return runtimeComparison < 0 }
    let connectionComparison = compareUUID(lhs.connectionID, rhs.connectionID)
    if connectionComparison != 0 { return connectionComparison < 0 }
    let leftDirection = directionOrdinal(lhs.direction)
    let rightDirection = directionOrdinal(rhs.direction)
    if leftDirection != rightDirection { return leftDirection < rightDirection }
    return lhs.wireSequence < rhs.wireSequence
  }

  private static func directionOrdinal(_ direction: EventDirection) -> UInt8 {
    switch direction {
    case .appToViewer: return 0
    case .viewerToApp: return 1
    }
  }

  static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
    compareUUID(lhs, rhs) < 0
  }

  static func compareUUID(_ lhs: UUID, _ rhs: UUID) -> Int {
    var leftValue = lhs.uuid
    var rightValue = rhs.uuid
    return withUnsafeBytes(of: &leftValue) { leftBytes in
      withUnsafeBytes(of: &rightValue) { rightBytes in
        for index in 0..<leftBytes.count {
          if leftBytes[index] != rightBytes[index] {
            return leftBytes[index] < rightBytes[index] ? -1 : 1
          }
        }
        return 0
      }
    }
  }
}

struct ViewerPerformanceEventPage: Equatable, Sendable {
  let scope: ViewerPerformanceStoreScope
  let events: [ViewerPerformanceEventCarrier]
  let examinedCandidateCount: Int
  let continuation: ViewerPerformanceContinuation?
  let isComplete: Bool
  let copiedContentBytes: Int
  let accountedBytes: Int

  init(
    scope: ViewerPerformanceStoreScope,
    events: [ViewerPerformanceEventCarrier],
    examinedCandidateCount: Int,
    continuation: ViewerPerformanceContinuation?,
    isComplete: Bool
  ) throws {
    guard events.count <= ViewerPerformanceLimits.maximumEmittedEvents,
      (0...ViewerPerformanceLimits.maximumExaminedEvents).contains(examinedCandidateCount),
      continuation?.scope == scope || continuation == nil,
      isComplete ? continuation == nil : continuation != nil
    else { throw ViewerPerformanceStoreFailure.limitExceeded }
    let copiedContentBytes = try Self.checkedSum(events.map { $0.content.copiedByteCount })
    guard copiedContentBytes <= ViewerPerformanceLimits.maximumCopiedContentBytes else {
      throw ViewerPerformanceStoreFailure.limitExceeded
    }
    let carrierBytes = try Self.checkedMultiply(
      events.count,
      ViewerPerformanceLimits.eventCarrierBytes
    )
    let accountedBytes = try Self.checkedSum([
      ViewerPerformanceLimits.eventPageWrapperBytes,
      carrierBytes,
      copiedContentBytes,
    ])
    guard accountedBytes <= ViewerPerformanceLimits.maximumEventPageBytes else {
      throw ViewerPerformanceStoreFailure.limitExceeded
    }
    self.scope = scope
    self.events = events
    self.examinedCandidateCount = examinedCandidateCount
    self.continuation = continuation
    self.isComplete = isComplete
    self.copiedContentBytes = copiedContentBytes
    self.accountedBytes = accountedBytes
  }

  fileprivate static func checkedSum(_ values: [Int]) throws -> Int {
    var result = 0
    for value in values {
      let (next, overflow) = result.addingReportingOverflow(value)
      guard !overflow else { throw ViewerPerformanceStoreFailure.limitExceeded }
      result = next
    }
    return result
  }

  fileprivate static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw ViewerPerformanceStoreFailure.limitExceeded }
    return result
  }

  fileprivate static func isStrictlyCanonical(
    _ events: [ViewerPerformanceEventCarrier]
  ) -> Bool {
    guard events.count > 1 else { return true }
    for index in 1..<events.count {
      guard ViewerPerformanceCanonicalOrder.eventPrecedes(events[index - 1], events[index]) else {
        return false
      }
    }
    return true
  }
}

enum ViewerPerformanceGapKind: String, Equatable, Hashable, Sendable {
  case eventLoss
  case storageContinuity
  case controlContinuity
  case lifecycleContinuity
  case presentationLoss
  case unknown
}

enum ViewerPerformanceGapApplicability: String, Equatable, Hashable, Sendable {
  case performance
  case irrelevant
  case uncertain
}

struct ViewerPerformanceGapCarrier: Equatable, Sendable {
  let rowID: Int64?
  let recordingID: Int64?
  let deviceSessionID: Int64?
  let count: UInt64
  let firstViewerWallMilliseconds: Int64?
  let lastViewerWallMilliseconds: Int64?
  let kind: ViewerPerformanceGapKind
  let applicability: ViewerPerformanceGapApplicability

  init(
    rowID: Int64?,
    recordingID: Int64?,
    deviceSessionID: Int64?,
    count: UInt64,
    firstViewerWallMilliseconds: Int64?,
    lastViewerWallMilliseconds: Int64?,
    kind: ViewerPerformanceGapKind,
    applicability: ViewerPerformanceGapApplicability
  ) throws {
    guard count > 0, rowID.map({ $0 > 0 }) ?? true,
      recordingID.map({ $0 > 0 }) ?? true,
      deviceSessionID.map({ $0 > 0 }) ?? true,
      (firstViewerWallMilliseconds == nil) == (lastViewerWallMilliseconds == nil)
    else { throw ViewerPerformanceStoreFailure.invalidCarrier }
    self.rowID = rowID
    self.recordingID = recordingID
    self.deviceSessionID = deviceSessionID
    self.count = count
    self.firstViewerWallMilliseconds = firstViewerWallMilliseconds
    self.lastViewerWallMilliseconds = lastViewerWallMilliseconds
    self.kind = kind
    self.applicability = applicability
  }
}

struct ViewerPerformanceGapPage: Equatable, Sendable {
  let gaps: [ViewerPerformanceGapCarrier]
  let hasMoreRows: Bool
  let applicableOrUncertainCount: UInt64
  let hasMoreApplicableGaps: Bool
  let accountedBytes: Int

  init(
    gaps: [ViewerPerformanceGapCarrier],
    hasMoreRows: Bool,
    applicableOrUncertainCount: UInt64,
    hasMoreApplicableGaps: Bool
  ) throws {
    guard gaps.count <= ViewerPerformanceLimits.maximumGapPageEvents else {
      throw ViewerPerformanceStoreFailure.limitExceeded
    }
    let carrierBytes = try ViewerPerformanceEventPage.checkedMultiply(
      gaps.count,
      ViewerPerformanceLimits.gapCarrierBytes
    )
    let accountedBytes = try ViewerPerformanceEventPage.checkedSum([
      ViewerPerformanceLimits.gapPageWrapperBytes,
      carrierBytes,
    ])
    guard accountedBytes <= ViewerPerformanceLimits.maximumGapPageBytes else {
      throw ViewerPerformanceStoreFailure.limitExceeded
    }
    self.gaps = gaps
    self.hasMoreRows = hasMoreRows
    self.applicableOrUncertainCount = applicableOrUncertainCount
    self.hasMoreApplicableGaps = hasMoreApplicableGaps
    self.accountedBytes = accountedBytes
  }
}

struct ViewerPerformanceLiveSlice: Equatable, Sendable {
  let runtimeLogicalID: UUID
  let connectionID: UUID
  let liveGeneration: UInt64
  let revision: UInt64
  let anchorMonotonicNanoseconds: UInt64
  let events: [ViewerPerformanceEventCarrier]
  let gaps: [ViewerPerformanceGapCarrier]
  let applicableOrUncertainCount: UInt64
  let hasMoreApplicableGaps: Bool
  let copiedContentBytes: Int
  let accountedBytes: Int

  init(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    liveGeneration: UInt64,
    revision: UInt64,
    anchorMonotonicNanoseconds: UInt64,
    events: [ViewerPerformanceEventCarrier],
    gaps: [ViewerPerformanceGapCarrier],
    applicableOrUncertainCount: UInt64,
    hasMoreApplicableGaps: Bool
  ) throws {
    guard liveGeneration > 0, revision > 0,
      events.count <= ViewerPerformanceLimits.maximumEmittedEvents,
      gaps.count <= ViewerPerformanceLimits.maximumLiveGaps,
      ViewerPerformanceEventPage.isStrictlyCanonical(events),
      events.allSatisfy({
        $0.key.runtimeLogicalID == runtimeLogicalID && $0.key.connectionID == connectionID
          && UInt64($0.viewerMonotonicNanoseconds) <= anchorMonotonicNanoseconds
      })
    else { throw ViewerPerformanceStoreFailure.limitExceeded }
    let copiedContentBytes = try ViewerPerformanceEventPage.checkedSum(
      events.map { $0.content.copiedByteCount }
    )
    guard copiedContentBytes <= ViewerPerformanceLimits.maximumCopiedContentBytes else {
      throw ViewerPerformanceStoreFailure.limitExceeded
    }
    let eventBytes = try ViewerPerformanceEventPage.checkedMultiply(
      events.count,
      ViewerPerformanceLimits.eventCarrierBytes
    )
    let gapBytes = try ViewerPerformanceEventPage.checkedMultiply(
      gaps.count,
      ViewerPerformanceLimits.gapCarrierBytes
    )
    let accountedBytes = try ViewerPerformanceEventPage.checkedSum([
      ViewerPerformanceLimits.eventPageWrapperBytes,
      eventBytes,
      copiedContentBytes,
      gapBytes,
    ])
    guard accountedBytes <= ViewerPerformanceLimits.maximumLiveSliceBytes else {
      throw ViewerPerformanceStoreFailure.limitExceeded
    }
    self.runtimeLogicalID = runtimeLogicalID
    self.connectionID = connectionID
    self.liveGeneration = liveGeneration
    self.revision = revision
    self.anchorMonotonicNanoseconds = anchorMonotonicNanoseconds
    self.events = events
    self.gaps = gaps
    self.applicableOrUncertainCount = applicableOrUncertainCount
    self.hasMoreApplicableGaps = hasMoreApplicableGaps
    self.copiedContentBytes = copiedContentBytes
    self.accountedBytes = accountedBytes
  }
}

struct ViewerPerformanceFrozenReceipt: Equatable, Sendable {
  let source: ViewerPerformanceSource
  let storeScope: ViewerPerformanceStoreScope?
  let liveSlice: ViewerPerformanceLiveSlice?
}

private struct ViewerPerformanceGapContinuation: Equatable, Sendable {
  let scope: ViewerPerformanceStoreScope
  let lastViewerWallMilliseconds: Int64
  let rowID: Int64
}

private struct ViewerPerformanceGapClassification: Equatable, Sendable {
  let applicableOrUncertainCount: UInt64
  let hasMoreApplicableGaps: Bool
}

struct ViewerPerformanceTraversal: Equatable, Sendable {
  let scope: ViewerPerformanceStoreScope
  fileprivate let lease: ViewerStoreLeaseRegistry.Lease
  fileprivate let gapContinuation: ViewerPerformanceGapContinuation?
  fileprivate let gapClassification: ViewerPerformanceGapClassification?
}

struct ViewerPerformanceTurnClock: Sendable {
  static let live = ViewerPerformanceTurnClock {
    DispatchTime.now().uptimeNanoseconds
  }

  private let read: @Sendable () -> UInt64

  init(read: @escaping @Sendable () -> UInt64) {
    self.read = read
  }

  func now() -> UInt64 { read() }
}

final class ViewerPerformanceStoreService: @unchecked Sendable {
  private struct ScanState {
    var events: [ViewerPerformanceEventCarrier] = []
    var examinedCandidateCount = 0
    var copiedContentBytes = 0
    var lastExaminedMonotonicNanoseconds: Int64?
    var lastExaminedRowID: Int64?
    var reachedEnd = false

    mutating func advance(monotonicNanoseconds: Int64, rowID: Int64) {
      examinedCandidateCount += 1
      lastExaminedMonotonicNanoseconds = monotonicNanoseconds
      lastExaminedRowID = rowID
    }
  }

  static let maximumTurnNanoseconds: UInt64 = 50_000_000
  static let maximumClassificationNanoseconds: UInt64 = 250_000_000
  private static let initialCandidateSQL = """
    SELECT
      e.rowID,
      e.direction,
      e.wireSequence,
      e.eventType,
      length(e.contentJSON),
      e.viewerWallMs,
      e.viewerMonotonicNs,
      (SELECT logicalID FROM Recordings WHERE rowID=e.recordingID),
      (SELECT logicalID FROM DeviceSessions WHERE rowID=e.deviceSessionID)
    FROM Events e INDEXED BY EventTimelineByDevice
    WHERE e.recordingID=?1
      AND e.deviceSessionID=?2
      AND e.viewerMonotonicNs>=?3
      AND e.viewerMonotonicNs<=?4
      AND e.rowID<=?5
      AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones)
    ORDER BY e.viewerMonotonicNs ASC, e.rowID ASC
    """
  private static let continuedCandidateSQL = """
    SELECT
      e.rowID,
      e.direction,
      e.wireSequence,
      e.eventType,
      length(e.contentJSON),
      e.viewerWallMs,
      e.viewerMonotonicNs,
      (SELECT logicalID FROM Recordings WHERE rowID=e.recordingID),
      (SELECT logicalID FROM DeviceSessions WHERE rowID=e.deviceSessionID)
    FROM Events e INDEXED BY EventTimelineByDevice
    WHERE e.recordingID=?1
      AND e.deviceSessionID=?2
      AND e.viewerMonotonicNs>=?3
      AND e.viewerMonotonicNs<=?4
      AND e.rowID<=?5
      AND (
        e.viewerMonotonicNs>?6
        OR (e.viewerMonotonicNs=?6 AND e.rowID>?7)
      )
      AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones)
    ORDER BY e.viewerMonotonicNs ASC, e.rowID ASC
    """
  private static let contentSQL = "SELECT contentJSON FROM Events WHERE rowID=?1"
  private static let exactJournalLocatorSQL = """
    SELECT e.rowID
    FROM Events e
    JOIN Recordings r ON r.rowID=e.recordingID
    JOIN DeviceSessions d ON d.rowID=e.deviceSessionID
    WHERE e.recordingID=?1
      AND e.deviceSessionID=?2
      AND e.direction=?3
      AND e.wireSequence=?4
      AND r.logicalID=?5
      AND d.logicalID=?6
      AND e.eventType=?7
      AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones)
    LIMIT 1
    """

  private static let initialGapSQL = """
    SELECT
      g.rowID,
      g.recordingID,
      g.deviceSessionID,
      g.reason,
      g.firstViewerWallMs,
      g.lastViewerWallMs,
      g.directions,
      g.count
    FROM GapVersions g INDEXED BY GapTimelineAllDevices
    WHERE g.recordingID=?1
      AND g.rowID<=?2
      AND (g.deviceSessionID IS NULL OR g.deviceSessionID=?3)
      AND g.rowID=(
        SELECT MAX(g2.rowID)
        FROM GapVersions g2
        WHERE g2.recordingID=g.recordingID
          AND g2.deviceSessionID IS g.deviceSessionID
          AND g2.sequence=g.sequence
          AND g2.namespace=g.namespace
          AND g2.rowID<=?2
      )
    ORDER BY g.lastViewerWallMs ASC, g.rowID ASC
    """
  private static let continuedGapSQL = """
    SELECT
      g.rowID,
      g.recordingID,
      g.deviceSessionID,
      g.reason,
      g.firstViewerWallMs,
      g.lastViewerWallMs,
      g.directions,
      g.count
    FROM GapVersions g INDEXED BY GapTimelineAllDevices
    WHERE g.recordingID=?1
      AND g.rowID<=?2
      AND (g.deviceSessionID IS NULL OR g.deviceSessionID=?3)
      AND g.rowID=(
        SELECT MAX(g2.rowID)
        FROM GapVersions g2
        WHERE g2.recordingID=g.recordingID
          AND g2.deviceSessionID IS g.deviceSessionID
          AND g2.sequence=g.sequence
          AND g2.namespace=g.namespace
          AND g2.rowID<=?2
      )
      AND (
        g.lastViewerWallMs>?4
        OR (g.lastViewerWallMs=?4 AND g.rowID>?5)
      )
    ORDER BY g.lastViewerWallMs ASC, g.rowID ASC
    """

  private let pool: ViewerSQLitePool
  private let leases: ViewerStoreLeaseRegistry
  private let clock: ViewerPerformanceTurnClock
  private let classificationCountLock = NSLock()
  private var storedClassificationInvocationCount: UInt64 = 0

  init(
    pool: ViewerSQLitePool,
    leases: ViewerStoreLeaseRegistry = ViewerStoreLeaseRegistry(),
    clock: ViewerPerformanceTurnClock = .live
  ) {
    self.pool = pool
    self.leases = leases
    self.clock = clock
  }

  func begin(
    storeGeneration: UInt64,
    recordingID: Int64,
    deviceSessionID: Int64,
    lowerMonotonicNanoseconds: Int64,
    upperMonotonicNanoseconds: Int64,
    operationID: UUID? = nil
  ) throws -> ViewerPerformanceTraversal {
    guard storeGeneration > 0, recordingID > 0, deviceSessionID > 0,
      lowerMonotonicNanoseconds >= 0,
      upperMonotonicNanoseconds >= lowerMonotonicNanoseconds
    else { throw ViewerPerformanceStoreFailure.invalidScope }
    let lease: ViewerStoreLeaseRegistry.Lease
    do {
      lease = try leases.acquireQuery(recordingID: recordingID)
    } catch {
      throw Self.map(error)
    }
    do {
      let uppers = try pool.queryReader.run(operationID: operationID, budget: .query()) {
        database -> (event: Int64, gap: Int64) in
        let visible = try ViewerSQLiteStatement(
          database: database,
          sql: """
            SELECT 1
            FROM DeviceSessions d
            JOIN Recordings r ON r.rowID=d.recordingID
            WHERE r.rowID=?1 AND d.rowID=?2
              AND r.rowID NOT IN (SELECT recordingID FROM Tombstones)
            """
        )
        try visible.bind(recordingID, at: 1)
        try visible.bind(deviceSessionID, at: 2)
        guard try visible.step() else { throw ViewerPerformanceStoreFailure.invalidScope }
        return (
          try ViewerStoreSchema.scalarInt64(
            "SELECT COALESCE(MAX(rowID),0) FROM Events",
            database: database
          ),
          try ViewerStoreSchema.scalarInt64(
            "SELECT COALESCE(MAX(rowID),0) FROM GapVersions",
            database: database
          )
        )
      }
      let scope = try ViewerPerformanceStoreScope(
        storeGeneration: storeGeneration,
        recordingID: recordingID,
        deviceSessionID: deviceSessionID,
        lowerMonotonicNanoseconds: lowerMonotonicNanoseconds,
        upperMonotonicNanoseconds: upperMonotonicNanoseconds,
        eventUpperRowID: uppers.event,
        gapUpperRowID: uppers.gap
      )
      return ViewerPerformanceTraversal(
        scope: scope,
        lease: lease,
        gapContinuation: nil,
        gapClassification: nil
      )
    } catch {
      leases.release(lease)
      if let failure = error as? ViewerPerformanceStoreFailure { throw failure }
      throw Self.map(error)
    }
  }

  func eventPage(
    traversal: ViewerPerformanceTraversal,
    continuation: ViewerPerformanceContinuation?,
    operationID: UUID? = nil
  ) throws -> (ViewerPerformanceEventPage, ViewerPerformanceTraversal) {
    if let continuation, continuation.scope != traversal.scope {
      throw ViewerPerformanceStoreFailure.invalidContinuation
    }
    let refreshed: ViewerStoreLeaseRegistry.Lease
    do {
      refreshed = try leases.touchQuery(traversal.lease)
    } catch {
      throw Self.map(error)
    }
    let page = try eventPage(
      scope: traversal.scope,
      continuation: continuation,
      operationID: operationID
    )
    return (
      page,
      ViewerPerformanceTraversal(
        scope: traversal.scope,
        lease: refreshed,
        gapContinuation: traversal.gapContinuation,
        gapClassification: traversal.gapClassification
      )
    )
  }

  func gapPage(
    traversal: ViewerPerformanceTraversal,
    operationID: UUID? = nil
  ) throws -> (ViewerPerformanceGapPage, ViewerPerformanceTraversal) {
    let refreshed: ViewerStoreLeaseRegistry.Lease
    do {
      refreshed = try leases.touchQuery(traversal.lease)
    } catch {
      throw Self.map(error)
    }
    let sql = traversal.gapContinuation == nil ? Self.initialGapSQL : Self.continuedGapSQL
    let bindGap: (ViewerSQLiteStatement) throws -> Void = { statement in
      try self.bindGap(traversal: traversal, to: statement)
    }
    let limitedSQL = sql + " LIMIT 33"
    let retainedRows: [ViewerPerformanceGapCarrier]
    do {
      retainedRows = try pool.queryReader.run(operationID: operationID, budget: .query()) {
        database in
        try ViewerPerformancePlanGate.validate(
          sql: limitedSQL,
          database: database,
          bind: bindGap,
          requiredIndex: "GAPTIMELINEALLDEVICES"
        )
        let statement = try ViewerSQLiteStatement(database: database, sql: limitedSQL)
        try bindGap(statement)
        var rows: [ViewerPerformanceGapCarrier] = []
        rows.reserveCapacity(ViewerPerformanceLimits.maximumGapPageEvents + 1)
        while rows.count <= ViewerPerformanceLimits.maximumGapPageEvents,
          try statement.step()
        {
          rows.append(try Self.gapCarrier(statement))
        }
        return rows
      }
    } catch {
      if let failure = error as? ViewerPerformanceStoreFailure { throw failure }
      throw Self.map(error)
    }
    let hasMoreRows = retainedRows.count > ViewerPerformanceLimits.maximumGapPageEvents
    let pageRows = Array(retainedRows.prefix(ViewerPerformanceLimits.maximumGapPageEvents))
    let retainedBoundary = pageRows.last.map {
      (wall: $0.lastViewerWallMilliseconds ?? Int64.min, rowID: $0.rowID ?? 0)
    }
    let classification: ViewerPerformanceGapClassification
    if let frozen = traversal.gapClassification {
      classification = frozen
    } else {
      classification = try classifyGaps(
        traversal: traversal,
        operationID: operationID
      )
    }
    let page = try ViewerPerformanceGapPage(
      gaps: pageRows,
      hasMoreRows: hasMoreRows,
      applicableOrUncertainCount: classification.applicableOrUncertainCount,
      hasMoreApplicableGaps: classification.hasMoreApplicableGaps
    )
    let nextGapContinuation: ViewerPerformanceGapContinuation?
    if hasMoreRows, let boundary = retainedBoundary {
      nextGapContinuation = ViewerPerformanceGapContinuation(
        scope: traversal.scope,
        lastViewerWallMilliseconds: boundary.wall,
        rowID: boundary.rowID
      )
    } else {
      nextGapContinuation = nil
    }
    return (
      page,
      ViewerPerformanceTraversal(
        scope: traversal.scope,
        lease: refreshed,
        gapContinuation: nextGapContinuation,
        gapClassification: classification
      )
    )
  }

  func end(_ traversal: ViewerPerformanceTraversal) {
    leases.release(traversal.lease)
  }

  func resolveEventLocator(
    recordingID: Int64,
    deviceSessionID: Int64,
    key: ViewerEventJournalKey,
    operationID: UUID? = nil
  ) throws -> ViewerPerformanceEventLocator? {
    guard recordingID > 0, deviceSessionID > 0,
      let wireSequence = Int64(exactly: key.wireSequence)
    else { throw ViewerPerformanceStoreFailure.invalidScope }
    do {
      return try pool.queryReader.run(operationID: operationID, budget: .query()) { database in
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql: Self.exactJournalLocatorSQL
        )
        try statement.bind(recordingID, at: 1)
        try statement.bind(deviceSessionID, at: 2)
        try statement.bind(key.direction.rawValue, at: 3)
        try statement.bind(wireSequence, at: 4)
        try statement.bind(key.runtimeLogicalID.uuidString.lowercased(), at: 5)
        try statement.bind(key.connectionID.uuidString.lowercased(), at: 6)
        try statement.bind(PerformanceSnapshotSchema.eventTypeRawValue, at: 7)
        guard try statement.step() else { return nil }
        let rowID = statement.int64(at: 0)
        guard rowID > 0 else { throw ViewerStoreError.corruptStore }
        return .durable(rowID: rowID, deviceSessionID: deviceSessionID)
      }
    } catch {
      if let failure = error as? ViewerPerformanceStoreFailure { throw failure }
      throw Self.map(error)
    }
  }

  var activeLeaseCountForTesting: Int {
    leases.queryLeaseCountForTesting
  }

  var classificationInvocationCountForTesting: UInt64 {
    classificationCountLock.lock()
    defer { classificationCountLock.unlock() }
    return storedClassificationInvocationCount
  }

  func eventPage(
    scope: ViewerPerformanceStoreScope,
    continuation: ViewerPerformanceContinuation? = nil,
    operationID: UUID? = nil
  ) throws -> ViewerPerformanceEventPage {
    try validate(continuation: continuation, for: scope)
    let startedAt = clock.now()
    var state = ScanState()

    do {
      try pool.queryReader.run(
        operationID: operationID,
        budget: .performance(),
        progressInstructionInterval: 1_000
      ) { database in
        let sql = continuation == nil ? Self.initialCandidateSQL : Self.continuedCandidateSQL
        let bindCandidate: (ViewerSQLiteStatement) throws -> Void = { statement in
          try self.bind(scope: scope, continuation: continuation, to: statement)
        }
        try ViewerQueryPlanGate.validate(
          sql: sql,
          database: database,
          bind: bindCandidate
        )
        let candidate = try ViewerSQLiteStatement(database: database, sql: sql)
        try bindCandidate(candidate)
        let content = try ViewerSQLiteStatement(database: database, sql: Self.contentSQL)

        while true {
          if try self.turnExpired(since: startedAt) {
            if state.examinedCandidateCount == 0 {
              throw ViewerPerformanceStoreFailure.workLimitExceeded
            }
            break
          }
          guard try candidate.step() else {
            state.reachedEnd = true
            break
          }

          let rowID = candidate.int64(at: 0)
          let directionRawValue = candidate.string(at: 1)
          let wireSequenceValue = candidate.int64(at: 2)
          let eventType = candidate.string(at: 3)
          let contentByteCount = candidate.int64(at: 4)
          let viewerWallMilliseconds = candidate.int64(at: 5)
          let viewerMonotonicNanoseconds = candidate.int64(at: 6)
          let runtimeLogicalIDRawValue = candidate.string(at: 7)
          let connectionIDRawValue = candidate.string(at: 8)
          guard rowID > 0, wireSequenceValue >= 0, contentByteCount >= 0,
            viewerMonotonicNanoseconds >= 0,
            let direction = EventDirection(rawValue: directionRawValue),
            let runtimeLogicalID = UUID(uuidString: runtimeLogicalIDRawValue),
            let connectionID = UUID(uuidString: connectionIDRawValue)
          else { throw ViewerStoreError.corruptStore }

          if eventType == PerformanceSnapshotSchema.eventTypeRawValue {
            let eventContent: ViewerPerformanceEventContent
            if contentByteCount > Int64(ViewerPerformanceLimits.maximumRowContentBytes) {
              eventContent = .oversized(byteCount: contentByteCount)
            } else {
              guard let eligibleByteCount = Int(exactly: contentByteCount) else {
                throw ViewerStoreError.corruptStore
              }
              let (nextCopiedBytes, overflow) = state.copiedContentBytes.addingReportingOverflow(
                eligibleByteCount
              )
              if overflow || nextCopiedBytes > ViewerPerformanceLimits.maximumCopiedContentBytes {
                break
              }
              try content.bind(rowID, at: 1)
              guard try content.step() else { throw ViewerStoreError.corruptStore }
              let canonical = content.data(at: 0)
              guard canonical.count == eligibleByteCount else {
                throw ViewerStoreError.corruptStore
              }
              try content.reset()
              state.copiedContentBytes = nextCopiedBytes
              eventContent = .canonical(canonical)
            }
            let carrier = try ViewerPerformanceEventCarrier(
              locator: .durable(rowID: rowID, deviceSessionID: scope.deviceSessionID),
              key: ViewerEventJournalKey(
                runtimeLogicalID: runtimeLogicalID,
                connectionID: connectionID,
                direction: direction,
                wireSequence: UInt64(wireSequenceValue)
              ),
              viewerWallMilliseconds: viewerWallMilliseconds,
              viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
              content: eventContent
            )
            state.events.append(carrier)
          }

          state.advance(
            monotonicNanoseconds: viewerMonotonicNanoseconds,
            rowID: rowID
          )
          if try self.turnExpired(since: startedAt)
            || state.examinedCandidateCount == ViewerPerformanceLimits.maximumExaminedEvents
            || state.events.count == ViewerPerformanceLimits.maximumEmittedEvents
          {
            break
          }
        }
      }
    } catch {
      if let failure = error as? ViewerPerformanceStoreFailure {
        throw failure
      }
      if error as? ViewerStoreError == .workLimitExceeded,
        state.examinedCandidateCount > 0
      {
        return try makePage(scope: scope, state: state, isComplete: false)
      }
      throw Self.map(error)
    }

    if !state.reachedEnd, state.examinedCandidateCount == 0 {
      throw ViewerPerformanceStoreFailure.workLimitExceeded
    }
    return try makePage(scope: scope, state: state, isComplete: state.reachedEnd)
  }

  func cancel(operationID: UUID) {
    pool.queryReader.cancel(operationID: operationID)
  }

  func clearCancellation(operationID: UUID) {
    pool.queryReader.clearCancellation(operationID: operationID)
  }

  private func bindGap(
    traversal: ViewerPerformanceTraversal,
    to statement: ViewerSQLiteStatement
  ) throws {
    let scope = traversal.scope
    try statement.bind(scope.recordingID, at: 1)
    try statement.bind(scope.gapUpperRowID, at: 2)
    try statement.bind(scope.deviceSessionID, at: 3)
    if let continuation = traversal.gapContinuation {
      guard continuation.scope == scope else {
        throw ViewerPerformanceStoreFailure.invalidContinuation
      }
      try statement.bind(continuation.lastViewerWallMilliseconds, at: 4)
      try statement.bind(continuation.rowID, at: 5)
    }
  }

  private func classifyGaps(
    traversal: ViewerPerformanceTraversal,
    operationID: UUID?
  ) throws -> ViewerPerformanceGapClassification {
    classificationCountLock.lock()
    storedClassificationInvocationCount =
      storedClassificationInvocationCount == UInt64.max
      ? UInt64.max : storedClassificationInvocationCount + 1
    classificationCountLock.unlock()
    let startedAt = clock.now()
    var count: UInt64 = 0
    var hiddenApplicable = false
    var rowCount = 0
    let completeTraversal = ViewerPerformanceTraversal(
      scope: traversal.scope,
      lease: traversal.lease,
      gapContinuation: nil,
      gapClassification: nil
    )
    let bind: (ViewerSQLiteStatement) throws -> Void = { statement in
      try self.bindGap(traversal: completeTraversal, to: statement)
    }
    do {
      try pool.queryReader.run(
        operationID: operationID,
        budget: .performanceClassification(),
        progressInstructionInterval: 1_000
      ) { database in
        try ViewerPerformancePlanGate.validate(
          sql: Self.initialGapSQL,
          database: database,
          bind: bind,
          requiredIndex: "GAPTIMELINEALLDEVICES"
        )
        let statement = try ViewerSQLiteStatement(database: database, sql: Self.initialGapSQL)
        try bind(statement)
        while true {
          if try self.classificationExpired(since: startedAt) {
            throw ViewerStoreError.workLimitExceeded
          }
          guard try statement.step() else { break }
          let rowID = statement.int64(at: 0)
          let applicability = Self.gapApplicability(statement.string(at: 6))
          let rawCount = statement.int64(at: 7)
          guard rowID > 0, rawCount > 0 else { throw ViewerStoreError.corruptStore }
          rowCount += 1
          if applicability != .irrelevant {
            let value = UInt64(rawCount)
            let (sum, overflow) = count.addingReportingOverflow(value)
            count = overflow ? UInt64.max : sum
            if rowCount > ViewerPerformanceLimits.maximumProjectionGaps {
              hiddenApplicable = true
            }
          }
          if try self.classificationExpired(since: startedAt) {
            throw ViewerStoreError.workLimitExceeded
          }
        }
      }
      return ViewerPerformanceGapClassification(
        applicableOrUncertainCount: count,
        hasMoreApplicableGaps: hiddenApplicable
      )
    } catch let error as ViewerStoreError where error == .workLimitExceeded {
      return ViewerPerformanceGapClassification(
        applicableOrUncertainCount: count,
        hasMoreApplicableGaps: true
      )
    } catch let error as ViewerPerformanceStoreFailure where error == .workLimitExceeded {
      return ViewerPerformanceGapClassification(
        applicableOrUncertainCount: count,
        hasMoreApplicableGaps: true
      )
    } catch {
      if let failure = error as? ViewerPerformanceStoreFailure { throw failure }
      throw Self.map(error)
    }
  }

  private func classificationExpired(since startedAt: UInt64) throws -> Bool {
    let current = clock.now()
    guard current >= startedAt else {
      throw ViewerPerformanceStoreFailure.workLimitExceeded
    }
    return current - startedAt >= Self.maximumClassificationNanoseconds
  }

  private static func gapCarrier(
    _ statement: ViewerSQLiteStatement
  ) throws -> ViewerPerformanceGapCarrier {
    let rowID = statement.int64(at: 0)
    let recordingID = statement.int64(at: 1)
    let deviceSessionID = statement.isNull(at: 2) ? nil : statement.int64(at: 2)
    let reason = statement.string(at: 3)
    let firstWall = statement.int64(at: 4)
    let lastWall = statement.int64(at: 5)
    let directions = statement.string(at: 6)
    let count = statement.int64(at: 7)
    guard rowID > 0, recordingID > 0, count > 0,
      deviceSessionID.map({ $0 > 0 }) ?? true
    else { throw ViewerStoreError.corruptStore }
    return try ViewerPerformanceGapCarrier(
      rowID: rowID,
      recordingID: recordingID,
      deviceSessionID: deviceSessionID,
      count: UInt64(count),
      firstViewerWallMilliseconds: firstWall,
      lastViewerWallMilliseconds: lastWall,
      kind: gapKind(reason),
      applicability: gapApplicability(directions)
    )
  }

  private static func gapKind(_ reason: String) -> ViewerPerformanceGapKind {
    if reason.hasPrefix("missingInitialEvent.") { return .eventLoss }
    if reason == "storageUnavailable" || reason == "midRuntimeRetry" || reason == "liveStart"
      || reason.hasPrefix("store")
    {
      return .storageContinuity
    }
    if reason.hasPrefix("uplinkDisposition") || reason.hasPrefix("dropJournal")
      || reason.hasPrefix("policyJournal")
    {
      return .controlContinuity
    }
    if reason.hasPrefix("deviceClose") || reason.hasPrefix("shutdownStructural") {
      return .lifecycleContinuity
    }
    return .unknown
  }

  private static func gapApplicability(
    _ directions: String
  ) -> ViewerPerformanceGapApplicability {
    switch directions {
    case "appToViewer", "both": return .performance
    case "viewerToApp": return .irrelevant
    default: return .uncertain
    }
  }

  private func bind(
    scope: ViewerPerformanceStoreScope,
    continuation: ViewerPerformanceContinuation?,
    to statement: ViewerSQLiteStatement
  ) throws {
    try statement.bind(scope.recordingID, at: 1)
    try statement.bind(scope.deviceSessionID, at: 2)
    try statement.bind(scope.lowerMonotonicNanoseconds, at: 3)
    try statement.bind(scope.upperMonotonicNanoseconds, at: 4)
    try statement.bind(scope.eventUpperRowID, at: 5)
    if let continuation {
      guard let monotonicNanoseconds = continuation.lastExaminedMonotonicNanoseconds,
        let rowID = continuation.lastExaminedRowID
      else { throw ViewerPerformanceStoreFailure.invalidContinuation }
      try statement.bind(monotonicNanoseconds, at: 6)
      try statement.bind(rowID, at: 7)
    }
  }

  private func validate(
    continuation: ViewerPerformanceContinuation?,
    for scope: ViewerPerformanceStoreScope
  ) throws {
    guard let continuation else { return }
    guard continuation.scope == scope,
      let monotonicNanoseconds = continuation.lastExaminedMonotonicNanoseconds,
      let rowID = continuation.lastExaminedRowID,
      monotonicNanoseconds >= scope.lowerMonotonicNanoseconds,
      monotonicNanoseconds <= scope.upperMonotonicNanoseconds,
      rowID <= scope.eventUpperRowID
    else { throw ViewerPerformanceStoreFailure.invalidContinuation }
  }

  private func turnExpired(since startedAt: UInt64) throws -> Bool {
    let current = clock.now()
    guard current >= startedAt else {
      throw ViewerPerformanceStoreFailure.workLimitExceeded
    }
    return current - startedAt >= Self.maximumTurnNanoseconds
  }

  private func makePage(
    scope: ViewerPerformanceStoreScope,
    state: ScanState,
    isComplete: Bool
  ) throws -> ViewerPerformanceEventPage {
    let continuation: ViewerPerformanceContinuation?
    if isComplete {
      continuation = nil
    } else {
      guard let monotonicNanoseconds = state.lastExaminedMonotonicNanoseconds,
        let rowID = state.lastExaminedRowID
      else { throw ViewerPerformanceStoreFailure.workLimitExceeded }
      continuation = ViewerPerformanceContinuation(
        scope: scope,
        lastExaminedMonotonicNanoseconds: monotonicNanoseconds,
        lastExaminedRowID: rowID
      )
    }
    return try ViewerPerformanceEventPage(
      scope: scope,
      events: state.events,
      examinedCandidateCount: state.examinedCandidateCount,
      continuation: continuation,
      isComplete: isComplete
    )
  }

  private static func map(_ error: Error) -> ViewerPerformanceStoreFailure {
    guard let error = error as? ViewerStoreError else { return .unavailable }
    switch error {
    case .cancelled: return .cancelled
    case .workLimitExceeded: return .workLimitExceeded
    case .invalidValue: return .invalidContinuation
    case .invalidPath, .unsupportedSchema, .corruptStore, .busy, .sqliteBusy,
      .capacityExceeded, .staleObservation, .writeNotAuthorized, .unavailable:
      return .unavailable
    }
  }
}

private enum ViewerPerformancePlanGate {
  static func validate(
    sql: String,
    database: OpaquePointer,
    bind: (ViewerSQLiteStatement) throws -> Void,
    requiredIndex: String
  ) throws {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: "EXPLAIN QUERY PLAN \(sql)"
    )
    try bind(statement)
    var usesRequiredIndex = false
    while try statement.step() {
      let detail = statement.string(at: 3).uppercased()
      if detail.contains("USE TEMP B-TREE") { throw ViewerStoreError.workLimitExceeded }
      if detail.contains(requiredIndex) { usesRequiredIndex = true }
    }
    guard usesRequiredIndex else { throw ViewerStoreError.workLimitExceeded }
  }
}

extension ViewerPerformanceEventCarrier: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerPerformanceEventCarrier(redacted, contentBytes: \(content.declaredByteCount))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["contentBytes": content.declaredByteCount], displayStyle: .struct)
  }
}

extension ViewerPerformanceEventPage: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerPerformanceEventPage(redacted, events: \(events.count), examined: \(examinedCandidateCount))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["eventCount": events.count, "examinedCount": examinedCandidateCount],
      displayStyle: .struct
    )
  }
}

extension ViewerPerformanceGapCarrier: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceGapCarrier(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceGapPage: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceGapPage(redacted, gaps: \(gaps.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["gapCount": gaps.count], displayStyle: .struct)
  }
}

extension ViewerPerformanceLiveSlice: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerPerformanceLiveSlice(redacted, events: \(events.count), gaps: \(gaps.count))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["eventCount": events.count, "gapCount": gaps.count],
      displayStyle: .struct
    )
  }
}
