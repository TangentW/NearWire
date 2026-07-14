import CryptoKit
import Foundation

struct ViewerGapCursor: Equatable, Sendable {
  let recordingID: Int64
  let queryFingerprint: String
  let deviceSessionIDs: [Int64]
  let gapUpperRowID: Int64
  let leaseID: UUID
  let leaseExpiresAt: ContinuousClock.Instant
  let direction: ViewerStoreQueryService.Direction
  let lastViewerWallMilliseconds: Int64
  let rowID: Int64
}

struct ViewerGapRow: Equatable, Sendable {
  let rowID: Int64
  let recordingID: Int64
  let deviceSessionID: Int64?
  let sequence: Int64
  let namespace: String
  let revision: Int64
  let reason: String
  let firstViewerWallMilliseconds: Int64
  let lastViewerWallMilliseconds: Int64
  let directions: String
  let firstWireSequence: Int64?
  let lastWireSequence: Int64?
  let count: Int64
}

struct ViewerGapPage: Equatable, Sendable {
  let rows: [ViewerGapRow]
  let nextCursor: ViewerGapCursor?
  let previousCursor: ViewerGapCursor?

  func cursor(toward direction: ViewerStoreQueryService.Direction) -> ViewerGapCursor? {
    [previousCursor, nextCursor].compactMap { $0 }.first { $0.direction == direction }
  }
}

enum ViewerCausalityEdgeKind: Equatable, Sendable {
  case replyTo
  case correlation
}

struct ViewerCausalityNode: Equatable, Sendable {
  let rowID: Int64
  let deviceSessionID: Int64
  let eventUUID: String
  let eventType: String
  let direction: String
  let wireSequence: Int64
}

struct ViewerCausalityEdge: Equatable, Sendable {
  let sourceRowID: Int64
  let kind: ViewerCausalityEdgeKind
  let referencedEventUUID: String
  let candidateRowIDs: [Int64]
  let hasMore: Bool
  let cyclicCandidateRowIDs: [Int64]
}

struct ViewerCausalityGraph: Equatable, Sendable {
  let rootRowID: Int64
  let nodes: [ViewerCausalityNode]
  let edges: [ViewerCausalityEdge]
  let truncated: Bool
}

enum ViewerDiagnosticPlanKind: Equatable, Sendable {
  case gapAllDevices
  case gapDeviceLane
  case causality
}

struct ViewerDiagnosticPlanObservation: Equatable, Sendable {
  let kind: ViewerDiagnosticPlanKind
  let details: [String]
}

final class ViewerStoreDiagnosticService: @unchecked Sendable {
  private struct CausalityRecord {
    let node: ViewerCausalityNode
    let replyToEventUUID: String?
    let correlationEventUUID: String?
  }

  private let pool: ViewerSQLitePool
  private let leases: ViewerStoreLeaseRegistry
  private let planObserver: @Sendable (ViewerDiagnosticPlanObservation) -> Void

  init(
    pool: ViewerSQLitePool,
    leases: ViewerStoreLeaseRegistry,
    planObserver: @escaping @Sendable (ViewerDiagnosticPlanObservation) -> Void = { _ in }
  ) {
    self.pool = pool
    self.leases = leases
    self.planObserver = planObserver
  }

  func gapPage(
    traversal: ViewerEventTraversal,
    deviceSessionIDs: [Int64],
    cursor: ViewerGapCursor?,
    direction: ViewerStoreQueryService.Direction,
    limit: Int = 32,
    operationID: UUID? = nil
  ) throws -> (ViewerGapPage, ViewerEventTraversal) {
    let devices = Array(Set(deviceSessionIDs)).sorted()
    guard devices == deviceSessionIDs.sorted(), devices.count <= 16,
      devices.allSatisfy({ $0 > 0 }), (1...32).contains(limit)
    else { throw ViewerStoreError.invalidValue }
    let queryFingerprint = try Self.gapFingerprint(
      query: traversal.query,
      deviceSessionIDs: devices
    )
    if let cursor {
      guard cursor.recordingID == traversal.query.recordingID,
        cursor.queryFingerprint == queryFingerprint,
        cursor.deviceSessionIDs == devices,
        cursor.gapUpperRowID == traversal.snapshot.gapUpperRowID,
        cursor.leaseID == traversal.lease.id,
        cursor.leaseExpiresAt <= traversal.lease.expiresAt,
        cursor.direction == direction,
        cursor.rowID > 0
      else { throw ViewerStoreError.invalidValue }
    }
    let refreshed = try leases.touchQuery(traversal.lease)
    let rows = try pool.queryReader.run(operationID: operationID, budget: .query()) { database in
      try Self.validateDevices(
        devices,
        recordingID: traversal.query.recordingID,
        database: database
      )
      if devices.isEmpty {
        return try Self.queryGapLane(
          recordingID: traversal.query.recordingID,
          deviceSessionID: nil,
          includesAllDevices: true,
          gapUpperRowID: traversal.snapshot.gapUpperRowID,
          cursor: cursor,
          direction: direction,
          limit: limit,
          database: database,
          planObserver: planObserver
        )
      }
      var lanes: [[ViewerGapRow]] = []
      for deviceSessionID in [nil] + devices.map(Optional.some) {
        lanes.append(
          try Self.queryGapLane(
            recordingID: traversal.query.recordingID,
            deviceSessionID: deviceSessionID,
            includesAllDevices: false,
            gapUpperRowID: traversal.snapshot.gapUpperRowID,
            cursor: cursor,
            direction: direction,
            limit: limit,
            database: database,
            planObserver: planObserver
          )
        )
      }
      return Self.mergeGapLanes(lanes, direction: direction, limit: limit)
    }
    let page = Self.gapPage(
      rows: rows,
      recordingID: traversal.query.recordingID,
      queryFingerprint: queryFingerprint,
      deviceSessionIDs: devices,
      gapUpperRowID: traversal.snapshot.gapUpperRowID,
      lease: refreshed,
      direction: direction
    )
    return (
      page,
      ViewerEventTraversal(
        query: traversal.query,
        snapshot: traversal.snapshot,
        lease: refreshed
      )
    )
  }

  func causality(
    traversal: ViewerEventTraversal,
    rootRowID: Int64,
    operationID: UUID? = nil
  ) throws -> (ViewerCausalityGraph, ViewerEventTraversal) {
    guard rootRowID > 0 else { throw ViewerStoreError.invalidValue }
    let refreshed = try leases.touchQuery(traversal.lease)
    let graph = try pool.queryReader.run(operationID: operationID, budget: .query()) { database in
      guard
        let root = try Self.causalityRecord(
          rowID: rootRowID,
          recordingID: traversal.query.recordingID,
          eventUpperRowID: traversal.snapshot.eventUpperRowID,
          database: database
        )
      else { throw ViewerStoreError.invalidValue }
      return try Self.expandCausality(
        root: root,
        recordingID: traversal.query.recordingID,
        eventUpperRowID: traversal.snapshot.eventUpperRowID,
        database: database,
        planObserver: planObserver
      )
    }
    return (
      graph,
      ViewerEventTraversal(
        query: traversal.query,
        snapshot: traversal.snapshot,
        lease: refreshed
      )
    )
  }

  func cancel() { pool.queryReader.cancelCurrentOperation() }

  func cancel(operationID: UUID) { pool.queryReader.cancel(operationID: operationID) }

  func clearCancellation(operationID: UUID) {
    pool.queryReader.clearCancellation(operationID: operationID)
  }

  private static func queryGapLane(
    recordingID: Int64,
    deviceSessionID: Int64?,
    includesAllDevices: Bool,
    gapUpperRowID: Int64,
    cursor: ViewerGapCursor?,
    direction: ViewerStoreQueryService.Direction,
    limit: Int,
    database: OpaquePointer,
    planObserver: @Sendable (ViewerDiagnosticPlanObservation) -> Void
  ) throws -> [ViewerGapRow] {
    let comparison = direction == .forward ? ">" : "<"
    let order = direction == .forward ? "ASC" : "DESC"
    let index = includesAllDevices ? "GapTimelineAllDevices" : "GapTimelineByDevice"
    let deviceClause = includesAllDevices ? "" : " AND g.deviceSessionID IS ?3"
    let cursorClause =
      cursor == nil
      ? ""
      : " AND (g.lastViewerWallMs \(comparison) ?4 OR (g.lastViewerWallMs=?4 AND g.rowID \(comparison) ?5))"
    let limitIndex = cursor == nil ? 4 : 6
    let sql = """
      SELECT g.rowID,g.recordingID,g.deviceSessionID,g.sequence,g.namespace,g.revision,g.reason,
        g.firstViewerWallMs,g.lastViewerWallMs,g.directions,g.firstWireSequence,
        g.lastWireSequence,g.count
      FROM GapVersions g INDEXED BY \(index)
      WHERE g.recordingID=?1 AND g.rowID<=?2\(deviceClause)
        AND g.rowID=(SELECT MAX(g2.rowID) FROM GapVersions g2
          WHERE g2.recordingID=g.recordingID
            AND g2.deviceSessionID IS g.deviceSessionID
            AND g2.sequence=g.sequence AND g2.namespace=g.namespace AND g2.rowID<=?2)
        \(cursorClause)
      ORDER BY g.lastViewerWallMs \(order),g.rowID \(order)
      LIMIT ?\(limitIndex)
      """
    let bind: (ViewerSQLiteStatement) throws -> Void = { statement in
      try statement.bind(recordingID, at: 1)
      try statement.bind(gapUpperRowID, at: 2)
      if !includesAllDevices {
        if let deviceSessionID {
          try statement.bind(deviceSessionID, at: 3)
        } else {
          try statement.bindNull(at: 3)
        }
      }
      if let cursor {
        try statement.bind(cursor.lastViewerWallMilliseconds, at: 4)
        try statement.bind(cursor.rowID, at: 5)
      }
      try statement.bind(Int64(limit), at: Int32(limitIndex))
    }
    let details = try ViewerDiagnosticPlanGate.validate(
      sql: sql,
      database: database,
      bind: bind,
      required: [index.uppercased()]
    )
    planObserver(
      ViewerDiagnosticPlanObservation(
        kind: includesAllDevices ? .gapAllDevices : .gapDeviceLane,
        details: details
      )
    )
    let statement = try ViewerSQLiteStatement(database: database, sql: sql)
    try bind(statement)
    var rows: [ViewerGapRow] = []
    while try statement.step() {
      rows.append(try gapRow(statement))
    }
    if direction == .backward { rows.reverse() }
    return rows
  }

  private static func mergeGapLanes(
    _ lanes: [[ViewerGapRow]],
    direction: ViewerStoreQueryService.Direction,
    limit: Int
  ) -> [ViewerGapRow] {
    let merged = lanes.flatMap { $0 }.sorted { lhs, rhs in
      if lhs.lastViewerWallMilliseconds != rhs.lastViewerWallMilliseconds {
        return lhs.lastViewerWallMilliseconds < rhs.lastViewerWallMilliseconds
      }
      return lhs.rowID < rhs.rowID
    }
    if direction == .forward { return Array(merged.prefix(limit)) }
    return Array(merged.suffix(limit))
  }

  private static func gapPage(
    rows: [ViewerGapRow],
    recordingID: Int64,
    queryFingerprint: String,
    deviceSessionIDs: [Int64],
    gapUpperRowID: Int64,
    lease: ViewerStoreLeaseRegistry.Lease,
    direction: ViewerStoreQueryService.Direction
  ) -> ViewerGapPage {
    let reverseBoundary = (direction == .forward ? rows.first : rows.last).map {
      ViewerGapCursor(
        recordingID: recordingID,
        queryFingerprint: queryFingerprint,
        deviceSessionIDs: deviceSessionIDs,
        gapUpperRowID: gapUpperRowID,
        leaseID: lease.id,
        leaseExpiresAt: lease.expiresAt,
        direction: direction == .forward ? .backward : .forward,
        lastViewerWallMilliseconds: $0.lastViewerWallMilliseconds,
        rowID: $0.rowID
      )
    }
    let continuationBoundary = (direction == .forward ? rows.last : rows.first).map {
      ViewerGapCursor(
        recordingID: recordingID,
        queryFingerprint: queryFingerprint,
        deviceSessionIDs: deviceSessionIDs,
        gapUpperRowID: gapUpperRowID,
        leaseID: lease.id,
        leaseExpiresAt: lease.expiresAt,
        direction: direction,
        lastViewerWallMilliseconds: $0.lastViewerWallMilliseconds,
        rowID: $0.rowID
      )
    }
    return ViewerGapPage(
      rows: rows,
      nextCursor: continuationBoundary,
      previousCursor: reverseBoundary
    )
  }

  private static func gapRow(_ statement: ViewerSQLiteStatement) throws -> ViewerGapRow {
    let rowID = statement.int64(at: 0)
    let recordingID = statement.int64(at: 1)
    let sequence = statement.int64(at: 3)
    let revision = statement.int64(at: 5)
    let count = statement.int64(at: 12)
    guard rowID > 0, recordingID > 0, sequence >= 0, revision > 0, count > 0 else {
      throw ViewerStoreError.corruptStore
    }
    return ViewerGapRow(
      rowID: rowID,
      recordingID: recordingID,
      deviceSessionID: statement.isNull(at: 2) ? nil : statement.int64(at: 2),
      sequence: sequence,
      namespace: statement.string(at: 4),
      revision: revision,
      reason: statement.string(at: 6),
      firstViewerWallMilliseconds: statement.int64(at: 7),
      lastViewerWallMilliseconds: statement.int64(at: 8),
      directions: statement.string(at: 9),
      firstWireSequence: statement.isNull(at: 10) ? nil : statement.int64(at: 10),
      lastWireSequence: statement.isNull(at: 11) ? nil : statement.int64(at: 11),
      count: count
    )
  }

  private static func validateDevices(
    _ deviceSessionIDs: [Int64],
    recordingID: Int64,
    database: OpaquePointer
  ) throws {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: "SELECT 1 FROM DeviceSessions WHERE rowID=?1 AND recordingID=?2"
    )
    for deviceSessionID in deviceSessionIDs {
      try statement.bind(deviceSessionID, at: 1)
      try statement.bind(recordingID, at: 2)
      guard try statement.step() else { throw ViewerStoreError.invalidValue }
      try statement.reset()
    }
  }

  private static func expandCausality(
    root: CausalityRecord,
    recordingID: Int64,
    eventUpperRowID: Int64,
    database: OpaquePointer,
    planObserver: @Sendable (ViewerDiagnosticPlanObservation) -> Void
  ) throws -> ViewerCausalityGraph {
    var queue: [CausalityRecord] = [root]
    var visited: Set<Int64> = [root.node.rowID]
    var nodes: [ViewerCausalityNode] = [root.node]
    var edges: [ViewerCausalityEdge] = []
    var index = 0
    var truncated = false
    while index < queue.count {
      let source = queue[index]
      index += 1
      let references: [(ViewerCausalityEdgeKind, String?)] = [
        (.replyTo, source.replyToEventUUID),
        (.correlation, source.correlationEventUUID),
      ]
      for (kind, reference) in references {
        guard let reference else { continue }
        let candidates = try causalityCandidates(
          eventUUID: reference,
          recordingID: recordingID,
          deviceSessionID: root.node.deviceSessionID,
          eventUpperRowID: eventUpperRowID,
          database: database,
          planObserver: planObserver
        )
        let visible = Array(candidates.prefix(8))
        var cyclic: [Int64] = []
        for candidate in visible {
          if visited.contains(candidate.node.rowID) {
            cyclic.append(candidate.node.rowID)
          } else if visited.count < 32 {
            visited.insert(candidate.node.rowID)
            nodes.append(candidate.node)
            queue.append(candidate)
          } else {
            truncated = true
          }
        }
        let hasMore = candidates.count > 8
        if hasMore { truncated = true }
        edges.append(
          ViewerCausalityEdge(
            sourceRowID: source.node.rowID,
            kind: kind,
            referencedEventUUID: reference,
            candidateRowIDs: visible.map(\.node.rowID),
            hasMore: hasMore,
            cyclicCandidateRowIDs: cyclic
          )
        )
      }
    }
    return ViewerCausalityGraph(
      rootRowID: root.node.rowID,
      nodes: nodes,
      edges: edges,
      truncated: truncated
    )
  }

  private static func causalityCandidates(
    eventUUID: String,
    recordingID: Int64,
    deviceSessionID: Int64,
    eventUpperRowID: Int64,
    database: OpaquePointer,
    planObserver: @Sendable (ViewerDiagnosticPlanObservation) -> Void
  ) throws -> [CausalityRecord] {
    let sql = """
      SELECT e.rowID,e.deviceSessionID,e.eventUUID,e.eventType,e.direction,e.wireSequence,
        e.replyToEventUUID,e.correlationEventUUID
      FROM Events e INDEXED BY EventCausalityLookup
      WHERE e.recordingID=?1 AND e.deviceSessionID=?2 AND e.eventUUID=?3 AND e.rowID<=?4
      ORDER BY e.rowID ASC LIMIT 9
      """
    let bind: (ViewerSQLiteStatement) throws -> Void = { statement in
      try statement.bind(recordingID, at: 1)
      try statement.bind(deviceSessionID, at: 2)
      try statement.bind(eventUUID, at: 3)
      try statement.bind(eventUpperRowID, at: 4)
    }
    let details = try ViewerDiagnosticPlanGate.validate(
      sql: sql,
      database: database,
      bind: bind,
      required: ["EVENTCAUSALITYLOOKUP"]
    )
    planObserver(ViewerDiagnosticPlanObservation(kind: .causality, details: details))
    let statement = try ViewerSQLiteStatement(database: database, sql: sql)
    try bind(statement)
    var candidates: [CausalityRecord] = []
    while try statement.step() {
      candidates.append(causalityRecord(statement))
    }
    return candidates
  }

  private static func causalityRecord(
    rowID: Int64,
    recordingID: Int64,
    eventUpperRowID: Int64,
    database: OpaquePointer
  ) throws -> CausalityRecord? {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: """
        SELECT e.rowID,e.deviceSessionID,e.eventUUID,e.eventType,e.direction,e.wireSequence,
          e.replyToEventUUID,e.correlationEventUUID
        FROM Events e
        WHERE e.recordingID=?1 AND e.rowID=?2 AND e.rowID<=?3
          AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones)
        """
    )
    try statement.bind(recordingID, at: 1)
    try statement.bind(rowID, at: 2)
    try statement.bind(eventUpperRowID, at: 3)
    guard try statement.step() else { return nil }
    return causalityRecord(statement)
  }

  private static func causalityRecord(
    _ statement: ViewerSQLiteStatement
  ) -> CausalityRecord {
    CausalityRecord(
      node: ViewerCausalityNode(
        rowID: statement.int64(at: 0),
        deviceSessionID: statement.int64(at: 1),
        eventUUID: statement.string(at: 2),
        eventType: statement.string(at: 3),
        direction: statement.string(at: 4),
        wireSequence: statement.int64(at: 5)
      ),
      replyToEventUUID: statement.isNull(at: 6) ? nil : statement.string(at: 6),
      correlationEventUUID: statement.isNull(at: 7) ? nil : statement.string(at: 7)
    )
  }

  private static func gapFingerprint(
    query: ViewerEventQuery,
    deviceSessionIDs: [Int64]
  ) throws -> String {
    let compiled = try ViewerEventQueryCompiler.compile(query)
    let value =
      compiled.fingerprint + ":" + deviceSessionIDs.map(String.init).joined(separator: ",")
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

private enum ViewerDiagnosticPlanGate {
  static func validate(
    sql: String,
    database: OpaquePointer,
    bind: (ViewerSQLiteStatement) throws -> Void,
    required: [String]
  ) throws -> [String] {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: "EXPLAIN QUERY PLAN \(sql)"
    )
    try bind(statement)
    var details: [String] = []
    while try statement.step() {
      let detail = statement.string(at: 3).uppercased()
      if detail.contains("USE TEMP B-TREE") || detail.hasPrefix("SCAN ") {
        throw ViewerStoreError.workLimitExceeded
      }
      details.append(detail)
    }
    for fragment in required where !details.contains(where: { $0.contains(fragment) }) {
      throw ViewerStoreError.workLimitExceeded
    }
    return details
  }
}

extension ViewerGapCursor: CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible
{
  var description: String { "ViewerGapCursor(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerGapRow: CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { "ViewerGapRow(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerGapPage: CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { "ViewerGapPage(redacted, rows: \(rows.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["rowCount": rows.count], displayStyle: .struct)
  }
}

extension ViewerCausalityNode: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerCausalityNode(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerCausalityEdge: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerCausalityEdge(redacted, candidates: \(candidateRowIDs.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["candidateCount": candidateRowIDs.count], displayStyle: .struct)
  }
}

extension ViewerCausalityGraph: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerCausalityGraph(redacted, nodes: \(nodes.count), edges: \(edges.count))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["nodeCount": nodes.count, "edgeCount": edges.count],
      displayStyle: .struct
    )
  }
}

extension ViewerStoreDiagnosticService: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreDiagnosticService(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
