import CryptoKit
import Foundation
import SQLite3

enum ViewerQueryScalar: Equatable, Sendable {
  case string(String)
  case integer(Int64)
  case real(Double)
  case boolean(Bool)
  case null
}

enum ViewerEventPredicate: Equatable, Sendable {
  case eventTypeEquals(String)
  case eventTypeEqualsAny([String])
  case eventTypePrefix(String)
  case contentContains(String)
  case fullText(String)
  case applicationIdentifiers([String])
  case applicationVersions([String])
  case direction(String)
  case directions([String])
  case priority(String)
  case priorities([String])
  case deviceSessionIDs([Int64])
  case wallTime(from: Int64?, through: Int64?)
  case json(path: String, equals: ViewerQueryScalar)
  case jsonAny(path: String, equalsAny: [ViewerQueryScalar])
  case jsonExists(path: String)
  case jsonStringContains(path: String, value: String)
  case hasGap
  case hasDrop
  case hasTerminalDisposition
}

struct ViewerEventQuery: Equatable, Sendable {
  let recordingID: Int64
  let predicates: [ViewerEventPredicate]

  init(recordingID: Int64, predicates: [ViewerEventPredicate]) throws {
    guard recordingID > 0, predicates.count <= 32 else { throw ViewerStoreError.invalidValue }
    self.recordingID = recordingID
    self.predicates = predicates
  }
}

enum ViewerQueryBinding: Equatable, Sendable {
  case integer(Int64)
  case real(Double)
  case text(String)
  case gapSnapshotUpperBound
  case dropSnapshotUpperBound
  case dispositionSnapshotUpperBound
}

struct ViewerCompiledQuery: Equatable, Sendable {
  let predicateSQL: String
  let bindings: [ViewerQueryBinding]
  let fingerprint: String
}

enum ViewerEventQueryCompiler {
  static func compile(_ query: ViewerEventQuery) throws -> ViewerCompiledQuery {
    var clauses: [String] = []
    var bindings: [ViewerQueryBinding] = []
    for predicate in query.predicates {
      switch predicate {
      case .eventTypeEquals(let value):
        let value = try canonicalEventType(value)
        clauses.append("e.eventType=?")
        bindings.append(.text(value))
      case .eventTypeEqualsAny(let values):
        guard !values.isEmpty, values.count <= 16 else { throw ViewerStoreError.invalidValue }
        let values = try values.map(canonicalEventType)
        clauses.append(
          "e.eventType IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
        bindings.append(contentsOf: values.map(ViewerQueryBinding.text))
      case .eventTypePrefix(let value):
        let value = try canonicalEventTypePrefix(value)
        clauses.append("substr(e.eventType, 1, length(?))=?")
        bindings.append(.text(value))
        bindings.append(.text(value))
      case .contentContains(let value):
        let value = try normalizedSearchText(value, maximumBytes: 512)
        clauses.append("instr(CAST(e.contentJSON AS TEXT), ?)>0")
        bindings.append(.text(value))
      case .fullText(let searchText):
        let searchText = try normalizedSearchText(searchText, maximumBytes: 512)
        let terms = searchText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty, terms.count <= 32 else { throw ViewerStoreError.invalidValue }
        let expression = try terms.map { term -> String in
          let normalized = try normalizedSearchText(term, maximumBytes: 512)
          return "\"\(normalized.replacingOccurrences(of: "\"", with: "\"\""))\""
        }.joined(separator: " AND ")
        guard expression.utf8.count <= 4_096 else { throw ViewerStoreError.invalidValue }
        clauses.append("e.rowID IN (SELECT rowid FROM EventSearch WHERE EventSearch MATCH ?)")
        bindings.append(.text(expression))
      case .applicationIdentifiers(let values):
        try appendTextSelection(
          values,
          expression:
            "(SELECT applicationIdentifier FROM DeviceSessions WHERE rowID=e.deviceSessionID)",
          clauses: &clauses,
          bindings: &bindings
        )
      case .applicationVersions(let values):
        try appendTextSelection(
          values,
          expression:
            "(SELECT applicationVersion FROM DeviceSessions WHERE rowID=e.deviceSessionID)",
          clauses: &clauses,
          bindings: &bindings
        )
      case .direction(let value):
        guard value == "appToViewer" || value == "viewerToApp" else {
          throw ViewerStoreError.invalidValue
        }
        clauses.append("e.direction=?")
        bindings.append(.text(value))
      case .directions(let values):
        guard !values.isEmpty, values.count <= 2,
          values.allSatisfy({ $0 == "appToViewer" || $0 == "viewerToApp" })
        else { throw ViewerStoreError.invalidValue }
        clauses.append(
          "e.direction IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
        bindings.append(contentsOf: values.map(ViewerQueryBinding.text))
      case .priority(let value):
        guard ["low", "normal", "high", "critical"].contains(value) else {
          throw ViewerStoreError.invalidValue
        }
        clauses.append("e.priority=?")
        bindings.append(.text(value))
      case .priorities(let values):
        guard !values.isEmpty, values.count <= 4,
          values.allSatisfy({ ["low", "normal", "high", "critical"].contains($0) })
        else { throw ViewerStoreError.invalidValue }
        clauses.append(
          "e.priority IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
        bindings.append(contentsOf: values.map(ViewerQueryBinding.text))
      case .deviceSessionIDs(let values):
        guard !values.isEmpty, values.count <= 16, values.allSatisfy({ $0 > 0 }) else {
          throw ViewerStoreError.invalidValue
        }
        clauses.append(
          "e.deviceSessionID IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))"
        )
        bindings.append(contentsOf: values.map(ViewerQueryBinding.integer))
      case .wallTime(let from, let through):
        guard from != nil || through != nil else { throw ViewerStoreError.invalidValue }
        if let from {
          clauses.append("e.viewerWallMs>=?")
          bindings.append(.integer(from))
        }
        if let through {
          clauses.append("e.viewerWallMs<=?")
          bindings.append(.integer(through))
        }
      case .json(let path, let scalar):
        let path = try canonicalJSONPath(path)
        switch scalar {
        case .null:
          clauses.append("json_type(CAST(e.contentJSON AS TEXT), ?)= 'null'")
          bindings.append(.text(path))
        case .string(let value):
          let value = try normalizedSearchText(value, maximumBytes: 16 * 1_024)
          clauses.append(
            "(json_type(CAST(e.contentJSON AS TEXT), ?)='text' AND json_extract(CAST(e.contentJSON AS TEXT), ?)=?)"
          )
          bindings.append(.text(path))
          bindings.append(.text(path))
          bindings.append(.text(value))
        case .integer(let value):
          clauses.append(
            "(json_type(CAST(e.contentJSON AS TEXT), ?)='integer' AND json_extract(CAST(e.contentJSON AS TEXT), ?)=?)"
          )
          bindings.append(.text(path))
          bindings.append(.text(path))
          bindings.append(.integer(value))
        case .real(let value):
          guard value.isFinite else { throw ViewerStoreError.invalidValue }
          clauses.append(
            "(json_type(CAST(e.contentJSON AS TEXT), ?)='real' AND json_extract(CAST(e.contentJSON AS TEXT), ?)=?)"
          )
          bindings.append(.text(path))
          bindings.append(.text(path))
          bindings.append(.real(value))
        case .boolean(let value):
          clauses.append("json_type(CAST(e.contentJSON AS TEXT), ?)=?")
          bindings.append(.text(path))
          bindings.append(.text(value ? "true" : "false"))
        }
      case .jsonAny(let path, let scalars):
        guard !scalars.isEmpty, scalars.count <= 16 else { throw ViewerStoreError.invalidValue }
        let path = try canonicalJSONPath(path)
        var alternatives: [String] = []
        for scalar in scalars {
          switch scalar {
          case .null:
            alternatives.append("json_type(CAST(e.contentJSON AS TEXT), ?)= 'null'")
            bindings.append(.text(path))
          case .string(let value):
            alternatives.append(
              "(json_type(CAST(e.contentJSON AS TEXT), ?)='text' AND json_extract(CAST(e.contentJSON AS TEXT), ?)=?)"
            )
            bindings.append(.text(path))
            bindings.append(.text(path))
            bindings.append(.text(try normalizedSearchText(value, maximumBytes: 16 * 1_024)))
          case .integer(let value):
            alternatives.append(
              "(json_type(CAST(e.contentJSON AS TEXT), ?)='integer' AND json_extract(CAST(e.contentJSON AS TEXT), ?)=?)"
            )
            bindings.append(.text(path))
            bindings.append(.text(path))
            bindings.append(.integer(value))
          case .real(let value):
            guard value.isFinite else { throw ViewerStoreError.invalidValue }
            alternatives.append(
              "(json_type(CAST(e.contentJSON AS TEXT), ?)='real' AND json_extract(CAST(e.contentJSON AS TEXT), ?)=?)"
            )
            bindings.append(.text(path))
            bindings.append(.text(path))
            bindings.append(.real(value))
          case .boolean(let value):
            alternatives.append("json_type(CAST(e.contentJSON AS TEXT), ?)=?")
            bindings.append(.text(path))
            bindings.append(.text(value ? "true" : "false"))
          }
        }
        clauses.append("(" + alternatives.joined(separator: " OR ") + ")")
      case .jsonExists(let path):
        clauses.append("json_type(CAST(e.contentJSON AS TEXT), ?) IS NOT NULL")
        bindings.append(.text(try canonicalJSONPath(path)))
      case .jsonStringContains(let path, let value):
        let path = try canonicalJSONPath(path)
        let value = try normalizedSearchText(value, maximumBytes: 16 * 1_024)
        clauses.append(
          "(json_type(CAST(e.contentJSON AS TEXT), ?)='text' AND instr(json_extract(CAST(e.contentJSON AS TEXT), ?), ?)>0)"
        )
        bindings.append(.text(path))
        bindings.append(.text(path))
        bindings.append(.text(value))
      case .hasGap:
        clauses.append(
          "EXISTS(SELECT 1 FROM GapVersions g WHERE g.recordingID=e.recordingID AND (g.deviceSessionID IS NULL OR g.deviceSessionID=e.deviceSessionID) AND g.rowID<=?)"
        )
        bindings.append(.gapSnapshotUpperBound)
      case .hasDrop:
        clauses.append(
          "EXISTS(SELECT 1 FROM DropVersions d WHERE d.deviceSessionID=e.deviceSessionID AND d.rowID<=?)"
        )
        bindings.append(.dropSnapshotUpperBound)
      case .hasTerminalDisposition:
        clauses.append(
          "EXISTS(SELECT 1 FROM EventDispositionVersions x WHERE x.eventID=e.rowID AND x.rowID<=? AND x.disposition IN ('consumerAccepted','expired','overflowDisplaced','sessionEnded'))"
        )
        bindings.append(.dispositionSnapshotUpperBound)
      }
    }
    let sql = clauses.isEmpty ? "1" : "(" + clauses.joined(separator: " AND ") + ")"
    let canonical =
      "\(query.recordingID)|and|\(sql)|\(bindings.map(canonicalBinding).joined(separator: "|"))"
    let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    return ViewerCompiledQuery(predicateSQL: sql, bindings: bindings, fingerprint: digest)
  }

  private static func appendTextSelection(
    _ values: [String],
    expression: String,
    clauses: inout [String],
    bindings: inout [ViewerQueryBinding]
  ) throws {
    guard !values.isEmpty, values.count <= 16 else { throw ViewerStoreError.invalidValue }
    let normalized = try values.map { try normalizedSearchText($0, maximumBytes: 512) }
    clauses.append(
      "\(expression) IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
    bindings.append(contentsOf: normalized.map(ViewerQueryBinding.text))
  }

  static func canonicalJSONPath(_ value: String) throws -> String {
    do {
      return try ViewerJSONPath(value).rawValue
    } catch {
      throw ViewerStoreError.invalidValue
    }
  }

  private static func validateSearchText(_ value: String, maximumBytes: Int) throws {
    _ = try normalizedSearchText(value, maximumBytes: maximumBytes)
  }

  static func canonicalEventType(_ value: String) throws -> String {
    try validateEventTypeComponents(value, permitsTrailingDot: false)
  }

  static func canonicalEventTypePrefix(_ value: String) throws -> String {
    try validateEventTypeComponents(value, permitsTrailingDot: true)
  }

  private static func validateEventTypeComponents(
    _ value: String,
    permitsTrailingDot: Bool
  ) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 128,
      value.unicodeScalars.allSatisfy({ $0.isASCII })
    else { throw ViewerStoreError.invalidValue }
    let segments = value.split(separator: ".", omittingEmptySubsequences: false)
    for (index, segment) in segments.enumerated() {
      if segment.isEmpty {
        guard permitsTrailingDot, index == segments.count - 1, value.utf8.count < 128 else {
          throw ViewerStoreError.invalidValue
        }
        continue
      }
      guard let first = segment.utf8.first,
        (65...90).contains(first) || (97...122).contains(first),
        segment.utf8.dropFirst().allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            || $0 == 95 || $0 == 45
        })
      else { throw ViewerStoreError.invalidValue }
    }
    return value
  }

  static func normalizedSearchText(_ value: String, maximumBytes: Int) throws -> String {
    let normalized = value.precomposedStringWithCanonicalMapping
    guard !normalized.isEmpty, normalized.utf8.count <= maximumBytes else {
      throw ViewerStoreError.invalidValue
    }
    for scalar in normalized.unicodeScalars where CharacterSet.controlCharacters.contains(scalar) {
      throw ViewerStoreError.invalidValue
    }
    return normalized
  }

  private static func canonicalBinding(_ binding: ViewerQueryBinding) -> String {
    switch binding {
    case .integer(let value): return "i:\(value)"
    case .real(let value): return "r:\(value.bitPattern)"
    case .text(let value): return "t:\(Data(value.utf8).base64EncodedString())"
    case .gapSnapshotUpperBound: return "snapshot:gap"
    case .dropSnapshotUpperBound: return "snapshot:drop"
    case .dispositionSnapshotUpperBound: return "snapshot:disposition"
    }
  }
}

enum ViewerQueryPlanGate {
  static func validate(
    sql: String,
    database: OpaquePointer,
    bind: (ViewerSQLiteStatement) throws -> Void
  ) throws {
    let explain = try ViewerSQLiteStatement(database: database, sql: "EXPLAIN QUERY PLAN \(sql)")
    try bind(explain)
    var usesApprovedTimelineIndex = false
    while try explain.step() {
      let detail = explain.string(at: 3).uppercased()
      if detail.contains("USE TEMP B-TREE") {
        throw ViewerStoreError.workLimitExceeded
      }
      if detail.contains("EVENTTIMELINEFORWARD")
        || detail.contains("EVENTTIMELINEBYDEVICE")
        || detail.contains("EVENTTYPETIMELINE")
      {
        usesApprovedTimelineIndex = true
      }
    }
    guard usesApprovedTimelineIndex else { throw ViewerStoreError.workLimitExceeded }
  }
}

struct ViewerQuerySnapshot: Equatable, Sendable {
  let eventUpperRowID: Int64
  let recordingVersionUpperRowID: Int64
  let deviceVersionUpperRowID: Int64
  let dispositionUpperRowID: Int64
  let gapUpperRowID: Int64
  let dropUpperRowID: Int64
}

struct ViewerEventCursor: Equatable, Sendable {
  let recordingID: Int64
  let queryFingerprint: String
  let snapshot: ViewerQuerySnapshot
  let leaseID: UUID
  let leaseExpiresAt: ContinuousClock.Instant
  let direction: ViewerStoreQueryService.Direction
  let viewerMonotonicNanoseconds: Int64
  let rowID: Int64
}

struct ViewerEventTraversal: Equatable, Sendable {
  let query: ViewerEventQuery
  let snapshot: ViewerQuerySnapshot
  let lease: ViewerStoreLeaseRegistry.Lease
}

struct ViewerFilteredExportScope: Equatable, Sendable {
  let query: ViewerEventQuery
  let snapshot: ViewerQuerySnapshot
}

struct ViewerStoredEventRow: Equatable, Sendable {
  let rowID: Int64
  let deviceSessionID: Int64
  let direction: String
  let wireSequence: Int64
  let eventUUID: String
  let eventType: String
  let contentByteCount: Int64
  let createdWallMilliseconds: Int64
  let viewerWallMilliseconds: Int64
  let viewerMonotonicNanoseconds: Int64
  let priority: String
  let recordingRevision: Int64
  let deviceRevision: Int64
  let resolvedDisposition: String
}

struct ViewerStoredEventDetail: Equatable, Sendable {
  let summary: ViewerStoredEventRow
  let contentJSON: Data
  let deviceLogicalID: UUID
  let installationAlias: String
  let connectionAlias: String
  let originMonotonicNanoseconds: Int64
  let ttlMilliseconds: Int64
  let schemaVersion: Int64
  let correlationEventUUID: String?
  let replyToEventUUID: String?
}

extension ViewerStoredEventDetail: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerStoredEventDetail(redacted, contentBytes: \(contentJSON.count))"
  }

  var debugDescription: String { description }

  var customMirror: Mirror {
    Mirror(self, children: ["contentBytes": contentJSON.count], displayStyle: .struct)
  }
}

struct ViewerEventPage: Equatable, Sendable {
  let rows: [ViewerStoredEventRow]
  let nextCursor: ViewerEventCursor?
  let previousCursor: ViewerEventCursor?
}

extension ViewerQueryScalar: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerQueryScalar(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerEventPredicate: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerEventPredicate(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerEventQuery: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerEventQuery(redacted, predicates: \(predicates.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["predicateCount": predicates.count], displayStyle: .struct)
  }
}

extension ViewerQueryBinding: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerQueryBinding(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerCompiledQuery: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerCompiledQuery(redacted, bindings: \(bindings.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["bindingCount": bindings.count], displayStyle: .struct)
  }
}

extension ViewerEventCursor: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerEventCursor(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerEventTraversal: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerEventTraversal(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerFilteredExportScope: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerFilteredExportScope(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoredEventRow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoredEventRow(redacted, contentBytes: \(contentByteCount))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["contentBytes": contentByteCount], displayStyle: .struct)
  }
}

extension ViewerEventPage: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerEventPage(redacted, rows: \(rows.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["rowCount": rows.count], displayStyle: .struct)
  }
}

final class ViewerStoreQueryService: @unchecked Sendable {
  enum Direction: Equatable, Sendable { case forward, backward }

  private let pool: ViewerSQLitePool
  private let leases: ViewerStoreLeaseRegistry

  init(pool: ViewerSQLitePool, leases: ViewerStoreLeaseRegistry) {
    self.pool = pool
    self.leases = leases
  }

  func begin(
    query: ViewerEventQuery,
    operationID: UUID? = nil
  ) throws -> ViewerEventTraversal {
    let lease = try leases.acquireQuery(recordingID: query.recordingID)
    do {
      let snapshot = try pool.queryReader.run(operationID: operationID, budget: .query()) {
        database in
        try ViewerSQLiteConnection.execute("BEGIN", on: database)
        defer { try? ViewerSQLiteConnection.execute("COMMIT", on: database) }
        let visible = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT 1 FROM Recordings WHERE rowID=?1 AND rowID NOT IN (SELECT recordingID FROM Tombstones)"
        )
        try visible.bind(query.recordingID, at: 1)
        guard try visible.step() else { throw ViewerStoreError.invalidValue }
        return ViewerQuerySnapshot(
          eventUpperRowID: try maximumRowID("Events", database: database),
          recordingVersionUpperRowID: try maximumRowID("RecordingVersions", database: database),
          deviceVersionUpperRowID: try maximumRowID("DeviceSessionVersions", database: database),
          dispositionUpperRowID: try maximumRowID("EventDispositionVersions", database: database),
          gapUpperRowID: try maximumRowID("GapVersions", database: database),
          dropUpperRowID: try maximumRowID("DropVersions", database: database)
        )
      }
      return ViewerEventTraversal(query: query, snapshot: snapshot, lease: lease)
    } catch {
      leases.release(lease)
      throw error
    }
  }

  func page(
    traversal: ViewerEventTraversal,
    cursor: ViewerEventCursor?,
    direction: Direction,
    limit: Int = 100,
    operationID: UUID? = nil
  ) throws -> (ViewerEventPage, ViewerEventTraversal) {
    let query = traversal.query
    let snapshot = traversal.snapshot
    let lease = traversal.lease
    guard (1...200).contains(limit), lease.recordingID == query.recordingID else {
      throw ViewerStoreError.invalidValue
    }
    let compiled = try ViewerEventQueryCompiler.compile(query)
    if let cursor {
      guard cursor.recordingID == query.recordingID,
        cursor.queryFingerprint == compiled.fingerprint,
        cursor.snapshot == snapshot,
        cursor.leaseID == lease.id,
        cursor.leaseExpiresAt == lease.expiresAt,
        cursor.direction == direction
      else { throw ViewerStoreError.invalidValue }
    }
    let refreshed = try leases.touchQuery(lease)
    let comparison = direction == .forward ? ">" : "<"
    let order = direction == .forward ? "ASC" : "DESC"
    let cursorSQL =
      cursor == nil
      ? ""
      : " AND (e.viewerMonotonicNs \(comparison) ? OR (e.viewerMonotonicNs=? AND e.rowID \(comparison) ?))"
    let sql =
      "SELECT e.rowID,e.deviceSessionID,e.direction,e.wireSequence,e.eventUUID,e.eventType,length(e.contentJSON),e.createdWallMs,e.viewerWallMs,e.viewerMonotonicNs,e.priority,(SELECT revision FROM RecordingVersions rv WHERE rv.rowID=(SELECT MAX(rv2.rowID) FROM RecordingVersions rv2 WHERE rv2.recordingID=e.recordingID AND rv2.rowID<=?)),(SELECT revision FROM DeviceSessionVersions dv WHERE dv.rowID=(SELECT MAX(dv2.rowID) FROM DeviceSessionVersions dv2 WHERE dv2.deviceSessionID=e.deviceSessionID AND dv2.rowID<=?)),(SELECT disposition FROM EventDispositionVersions dx WHERE dx.rowID=(SELECT MAX(dx2.rowID) FROM EventDispositionVersions dx2 WHERE dx2.eventID=e.rowID AND dx2.rowID<=?)) FROM Events e WHERE e.recordingID=? AND e.rowID<=? AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones) AND \(compiled.predicateSQL)\(cursorSQL) ORDER BY e.viewerMonotonicNs \(order), e.rowID \(order) LIMIT ?"
    let rows = try pool.queryReader.run(operationID: operationID, budget: .query()) { database in
      let bindings = baseBindings(query, compiled, snapshot, cursor, limit)
      try ViewerQueryPlanGate.validate(sql: sql, database: database) {
        try bind(bindings, to: $0)
      }
      let statement = try ViewerSQLiteStatement(database: database, sql: sql)
      try bind(bindings, to: statement)
      var result: [ViewerStoredEventRow] = []
      while try statement.step() {
        result.append(
          ViewerStoredEventRow(
            rowID: statement.int64(at: 0),
            deviceSessionID: statement.int64(at: 1),
            direction: statement.string(at: 2),
            wireSequence: statement.int64(at: 3),
            eventUUID: statement.string(at: 4),
            eventType: statement.string(at: 5),
            contentByteCount: statement.int64(at: 6),
            createdWallMilliseconds: statement.int64(at: 7),
            viewerWallMilliseconds: statement.int64(at: 8),
            viewerMonotonicNanoseconds: statement.int64(at: 9),
            priority: statement.string(at: 10),
            recordingRevision: statement.int64(at: 11),
            deviceRevision: statement.int64(at: 12),
            resolvedDisposition: statement.string(at: 13)
          )
        )
      }
      return direction == .forward ? result : result.reversed()
    }
    let first = rows.first.map {
      ViewerEventCursor(
        recordingID: query.recordingID, queryFingerprint: compiled.fingerprint,
        snapshot: snapshot, leaseID: refreshed.id,
        leaseExpiresAt: refreshed.expiresAt,
        direction: direction == .forward ? .backward : .forward,
        viewerMonotonicNanoseconds: $0.viewerMonotonicNanoseconds, rowID: $0.rowID
      )
    }
    let last = rows.last.map {
      ViewerEventCursor(
        recordingID: query.recordingID, queryFingerprint: compiled.fingerprint,
        snapshot: snapshot, leaseID: refreshed.id,
        leaseExpiresAt: refreshed.expiresAt, direction: direction,
        viewerMonotonicNanoseconds: $0.viewerMonotonicNanoseconds, rowID: $0.rowID
      )
    }
    return (
      ViewerEventPage(rows: rows, nextCursor: last, previousCursor: first),
      ViewerEventTraversal(query: query, snapshot: snapshot, lease: refreshed)
    )
  }

  func detail(
    traversal: ViewerEventTraversal,
    rowID: Int64,
    operationID: UUID? = nil
  ) throws -> (ViewerStoredEventDetail?, ViewerEventTraversal) {
    let recordingID = traversal.query.recordingID
    let snapshot = traversal.snapshot
    guard recordingID > 0, rowID > 0 else { throw ViewerStoreError.invalidValue }
    let refreshed = try leases.touchQuery(traversal.lease)
    let detail = try pool.queryReader.run(operationID: operationID, budget: .query()) {
      database -> ViewerStoredEventDetail? in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT e.rowID,e.deviceSessionID,e.direction,e.wireSequence,e.eventUUID,e.eventType,e.contentJSON,e.createdWallMs,e.viewerWallMs,e.viewerMonotonicNs,e.priority,(SELECT revision FROM RecordingVersions rv WHERE rv.rowID=(SELECT MAX(rv2.rowID) FROM RecordingVersions rv2 WHERE rv2.recordingID=e.recordingID AND rv2.rowID<=?4)),(SELECT revision FROM DeviceSessionVersions dv WHERE dv.rowID=(SELECT MAX(dv2.rowID) FROM DeviceSessionVersions dv2 WHERE dv2.deviceSessionID=e.deviceSessionID AND dv2.rowID<=?5)),(SELECT disposition FROM EventDispositionVersions dx WHERE dx.rowID=(SELECT MAX(dx2.rowID) FROM EventDispositionVersions dx2 WHERE dx2.eventID=e.rowID AND dx2.rowID<=?6)),ds.logicalID,ia.ordinal,ds.connectionOrdinal,e.originMonotonicNs,e.ttlMs,e.schemaVersion,e.correlationEventUUID,e.replyToEventUUID FROM Events e JOIN DeviceSessions ds ON ds.rowID=e.deviceSessionID JOIN InstallationAliases ia ON ia.rowID=ds.installationAliasID WHERE e.recordingID=?1 AND e.rowID=?2 AND e.rowID<=?3 AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones)"
      )
      try statement.bind(recordingID, at: 1)
      try statement.bind(rowID, at: 2)
      try statement.bind(snapshot.eventUpperRowID, at: 3)
      try statement.bind(snapshot.recordingVersionUpperRowID, at: 4)
      try statement.bind(snapshot.deviceVersionUpperRowID, at: 5)
      try statement.bind(snapshot.dispositionUpperRowID, at: 6)
      guard try statement.step() else { return nil }
      let content = statement.data(at: 6)
      guard let deviceLogicalID = UUID(uuidString: statement.string(at: 14)) else {
        throw ViewerStoreError.corruptStore
      }
      let installationOrdinal = statement.int64(at: 15)
      let connectionOrdinal = statement.int64(at: 16)
      let ttlMilliseconds = statement.int64(at: 18)
      let schemaVersion = statement.int64(at: 19)
      guard installationOrdinal > 0, connectionOrdinal > 0, ttlMilliseconds > 0,
        schemaVersion > 0
      else { throw ViewerStoreError.corruptStore }
      let summary = ViewerStoredEventRow(
        rowID: statement.int64(at: 0), deviceSessionID: statement.int64(at: 1),
        direction: statement.string(at: 2), wireSequence: statement.int64(at: 3),
        eventUUID: statement.string(at: 4), eventType: statement.string(at: 5),
        contentByteCount: Int64(content.count), createdWallMilliseconds: statement.int64(at: 7),
        viewerWallMilliseconds: statement.int64(at: 8),
        viewerMonotonicNanoseconds: statement.int64(at: 9),
        priority: statement.string(at: 10),
        recordingRevision: statement.int64(at: 11),
        deviceRevision: statement.int64(at: 12),
        resolvedDisposition: statement.string(at: 13)
      )
      return ViewerStoredEventDetail(
        summary: summary,
        contentJSON: content,
        deviceLogicalID: deviceLogicalID,
        installationAlias: "device-\(installationOrdinal)",
        connectionAlias: "connection-\(connectionOrdinal)",
        originMonotonicNanoseconds: statement.int64(at: 17),
        ttlMilliseconds: ttlMilliseconds,
        schemaVersion: schemaVersion,
        correlationEventUUID: statement.isNull(at: 20) ? nil : statement.string(at: 20),
        replyToEventUUID: statement.isNull(at: 21) ? nil : statement.string(at: 21)
      )
    }
    return (
      detail,
      ViewerEventTraversal(query: traversal.query, snapshot: snapshot, lease: refreshed)
    )
  }

  func refresh(_ traversal: ViewerEventTraversal) throws -> ViewerEventTraversal {
    let refreshed = try leases.touchQuery(traversal.lease)
    return ViewerEventTraversal(
      query: traversal.query,
      snapshot: traversal.snapshot,
      lease: refreshed
    )
  }

  func cancel() { pool.queryReader.cancelCurrentOperation() }

  func cancel(operationID: UUID) { pool.queryReader.cancel(operationID: operationID) }

  func clearCancellation(operationID: UUID) {
    pool.queryReader.clearCancellation(operationID: operationID)
  }

  var cancelledOperationCountForTesting: Int {
    pool.queryReader.cancelledOperationCountForTesting
  }

  func end(_ traversal: ViewerEventTraversal) { leases.release(traversal.lease) }

  private func baseBindings(
    _ query: ViewerEventQuery,
    _ compiled: ViewerCompiledQuery,
    _ snapshot: ViewerQuerySnapshot,
    _ cursor: ViewerEventCursor?,
    _ limit: Int
  ) -> [ViewerQueryBinding] {
    var values: [ViewerQueryBinding] = [
      .integer(snapshot.recordingVersionUpperRowID),
      .integer(snapshot.deviceVersionUpperRowID),
      .integer(snapshot.dispositionUpperRowID),
      .integer(query.recordingID),
      .integer(snapshot.eventUpperRowID),
    ]
    for binding in compiled.bindings {
      switch binding {
      case .gapSnapshotUpperBound: values.append(.integer(snapshot.gapUpperRowID))
      case .dropSnapshotUpperBound: values.append(.integer(snapshot.dropUpperRowID))
      case .dispositionSnapshotUpperBound:
        values.append(.integer(snapshot.dispositionUpperRowID))
      default: values.append(binding)
      }
    }
    if let cursor {
      values.append(.integer(cursor.viewerMonotonicNanoseconds))
      values.append(.integer(cursor.viewerMonotonicNanoseconds))
      values.append(.integer(cursor.rowID))
    }
    values.append(.integer(Int64(limit)))
    return values
  }

  private func bind(_ values: [ViewerQueryBinding], to statement: ViewerSQLiteStatement) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .integer(let value): try statement.bind(value, at: index)
      case .real(let value): try statement.bind(value, at: index)
      case .text(let value): try statement.bind(value, at: index)
      case .gapSnapshotUpperBound, .dropSnapshotUpperBound, .dispositionSnapshotUpperBound:
        throw ViewerStoreError.invalidValue
      }
    }
  }

  private func maximumRowID(_ table: String, database: OpaquePointer) throws -> Int64 {
    try ViewerStoreSchema.scalarInt64(
      "SELECT COALESCE(MAX(rowID),0) FROM \(table)", database: database)
  }
}

extension ViewerQuerySnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerQuerySnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoreQueryService: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreQueryService(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
