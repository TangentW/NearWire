import Darwin
import Foundation
import SQLite3

struct ViewerExportSnapshot: Equatable, Sendable {
  let eventUpperRowID: Int64
  let recordingUpperRowID: Int64
  let deviceSessionUpperRowID: Int64
  let installationAliasUpperRowID: Int64
  let recordingVersionUpperRowID: Int64
  let deviceVersionUpperRowID: Int64
  let dispositionUpperRowID: Int64
  let gapUpperRowID: Int64
  let dropUpperRowID: Int64
  let annotationUpperRowID: Int64
}

struct ViewerExportDisclosure: Codable, Equatable, Sendable {
  let format: String
  let version: Int
  let warning: String
  let aliasesArePseudonymsNotRedaction: Bool
  let unencrypted: Bool
  let outsideViewerQuotaAndRetention: Bool
  let mayBeSyncedOrBackedUpByDestinationProvider: Bool

  static let current = ViewerExportDisclosure(
    format: "NearWire JSON Export",
    version: 1,
    warning: "Event content can contain secrets, personal information, or identifying data.",
    aliasesArePseudonymsNotRedaction: true,
    unencrypted: true,
    outsideViewerQuotaAndRetention: true,
    mayBeSyncedOrBackedUpByDestinationProvider: true
  )
}

enum ViewerExportFilePhase: CaseIterable, Equatable, Sendable {
  case temporaryCreated
  case beforeOpen
  case beforeWrite
  case afterWrite
  case beforeFileSync
  case afterFileSync
  case beforeClose
  case afterClose
  case beforeCommitSeal
  case beforeDirectoryOpen
  case beforeRename
  case afterRename
  case directorySync
}

struct ViewerExportFilePhaseObserver: Sendable {
  static let live = ViewerExportFilePhaseObserver { _ in }

  let reach: @Sendable (ViewerExportFilePhase) throws -> Void

  init(_ reach: @escaping @Sendable (ViewerExportFilePhase) throws -> Void) {
    self.reach = reach
  }
}

private final class ViewerExportCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var nextGeneration: UInt64 = 1
  private var activeGeneration: UInt64?
  private var cancelledGeneration: UInt64?
  private var committingGeneration: UInt64?

  func begin() throws -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    guard activeGeneration == nil else { throw ViewerStoreError.busy }
    let generation = nextGeneration
    nextGeneration = nextGeneration == UInt64.max ? 1 : nextGeneration + 1
    activeGeneration = generation
    cancelledGeneration = nil
    return generation
  }

  func cancelActive() {
    lock.lock()
    if committingGeneration != activeGeneration {
      cancelledGeneration = activeGeneration
    }
    lock.unlock()
  }

  func beginCommit(
    _ generation: UInt64,
    validatingLease: () throws -> Void
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard activeGeneration == generation, cancelledGeneration != generation,
      committingGeneration == nil
    else { throw ViewerStoreError.cancelled }
    try validatingLease()
    committingGeneration = generation
  }

  func check(_ generation: UInt64) throws {
    lock.lock()
    let cancelled = cancelledGeneration == generation || activeGeneration != generation
    lock.unlock()
    if cancelled { throw ViewerStoreError.cancelled }
  }

  func finish(_ generation: UInt64) {
    lock.lock()
    if activeGeneration == generation { activeGeneration = nil }
    if cancelledGeneration == generation { cancelledGeneration = nil }
    if committingGeneration == generation { committingGeneration = nil }
    lock.unlock()
  }
}

final class ViewerStoreExportService: @unchecked Sendable {
  private static let pageSize = 200
  private static let maximumBufferBytes = 64 * 1_024

  private let pool: ViewerSQLitePool
  private let leases: ViewerStoreLeaseRegistry
  private let filePhases: ViewerExportFilePhaseObserver
  private let cancellation = ViewerExportCancellation()

  private struct SecureTemporary {
    let parentDescriptor: Int32
    let parentPath: String
    let fileDescriptor: Int32
    let temporaryLeaf: String
    let destinationLeaf: String
  }

  init(
    pool: ViewerSQLitePool,
    leases: ViewerStoreLeaseRegistry,
    filePhases: ViewerExportFilePhaseObserver = .live
  ) {
    self.pool = pool
    self.leases = leases
    self.filePhases = filePhases
  }

  func preflight(recordingID: Int64) throws -> (
    eventCount: Int64, disclosure: ViewerExportDisclosure
  ) {
    let recordingID = try validated(recordingID)
    let count = try pool.exportReader.run(budget: .export()) { database in
      try requireVisibleRecording(recordingID, database: database)
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT COUNT(*) FROM Events WHERE recordingID=?1 AND recordingID NOT IN (SELECT recordingID FROM Tombstones)"
      )
      try statement.bind(recordingID, at: 1)
      guard try statement.step() else { throw ViewerStoreError.corruptStore }
      return statement.int64(at: 0)
    }
    return (count, .current)
  }

  func preflight(
    traversal: ViewerEventTraversal
  ) throws -> (eventCount: Int64, disclosure: ViewerExportDisclosure) {
    try leases.validateQuery(traversal.lease)
    let compiled = try ViewerEventQueryCompiler.compile(traversal.query)
    let count = try pool.exportReader.run(budget: .export()) { database in
      try requireVisibleRecording(traversal.query.recordingID, database: database)
      let sql =
        "SELECT COUNT(*) FROM Events e WHERE e.recordingID=? AND e.rowID<=? AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones) AND \(compiled.predicateSQL)"
      let bindStatement: (ViewerSQLiteStatement) throws -> Void = { statement in
        try self.bindQuery(
          recordingID: traversal.query.recordingID,
          eventUpperRowID: traversal.snapshot.eventUpperRowID,
          compiled: compiled,
          querySnapshot: traversal.snapshot,
          to: statement,
          startingAt: 1
        )
      }
      try ViewerQueryPlanGate.validate(sql: sql, database: database, bind: bindStatement)
      let statement = try ViewerSQLiteStatement(database: database, sql: sql)
      try bindStatement(statement)
      guard try statement.step() else { throw ViewerStoreError.corruptStore }
      return statement.int64(at: 0)
    }
    return (count, .current)
  }

  func export(recordingID: Int64, to destination: URL) throws {
    try export(
      recordingID: validated(recordingID),
      compiledQuery: nil,
      querySnapshot: nil,
      to: destination
    )
  }

  func export(traversal: ViewerEventTraversal, to destination: URL) throws {
    try leases.validateQuery(traversal.lease)
    try export(
      recordingID: traversal.query.recordingID,
      compiledQuery: ViewerEventQueryCompiler.compile(traversal.query),
      querySnapshot: traversal.snapshot,
      to: destination
    )
  }

  private func export(
    recordingID: Int64,
    compiledQuery: ViewerCompiledQuery?,
    querySnapshot: ViewerQuerySnapshot?,
    to destination: URL
  ) throws {
    let generation = try cancellation.begin()
    defer { cancellation.finish(generation) }
    let lease = try leases.acquireExport(recordingID: recordingID)
    defer { leases.release(lease) }
    let snapshot = try captureSnapshot(querySnapshot: querySnapshot)
    try validate(lease: lease, generation: generation)
    let temporary = try secureTemporarySibling(for: destination)
    var committed = false
    defer {
      if !committed {
        _ = temporary.temporaryLeaf.withCString {
          unlinkat(temporary.parentDescriptor, $0, 0)
        }
      }

      _ = close(temporary.fileDescriptor)
      _ = close(temporary.parentDescriptor)
    }
    try filePhases.reach(.temporaryCreated)
    try filePhases.reach(.beforeOpen)
    let writeDescriptor = dup(temporary.fileDescriptor)
    guard writeDescriptor >= 0 else { throw ViewerStoreError.invalidPath }
    let handle = FileHandle(fileDescriptor: writeDescriptor, closeOnDealloc: true)
    do {
      try filePhases.reach(.beforeWrite)
      try writeExport(
        recordingID: recordingID,
        snapshot: snapshot,
        compiledQuery: compiledQuery,
        querySnapshot: querySnapshot,
        lease: lease,
        generation: generation,
        handle: handle
      )
      try filePhases.reach(.afterWrite)
      try validate(lease: lease, generation: generation)
      try filePhases.reach(.beforeFileSync)
      try handle.synchronize()
      try filePhases.reach(.afterFileSync)
      try validate(lease: lease, generation: generation)
      try filePhases.reach(.beforeClose)
      try handle.close()
      try filePhases.reach(.afterClose)
      try validateTemporary(temporary)
      try validate(lease: lease, generation: generation)
      try filePhases.reach(.beforeCommitSeal)
      try cancellation.beginCommit(generation) {
        try leases.validateExport(lease)
      }
      try atomicReplace(temporary)
      committed = true
    } catch {
      try? handle.close()
      throw error
    }
  }

  func cancel() {
    cancellation.cancelActive()
    pool.exportReader.cancelCurrentOperation()
  }

  private func writeExport(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    compiledQuery: ViewerCompiledQuery?,
    querySnapshot: ViewerQuerySnapshot?,
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64,
    handle: FileHandle
  ) throws {
    let disclosure = try ViewerCanonicalJSON.encode(ViewerExportDisclosure.current)
    try write(Data("{\"schemaVersion\":1,\"disclosure\":".utf8), to: handle, generation: generation)
    try write(disclosure, to: handle, generation: generation)
    try write(Data(",\"session\":".utf8), to: handle, generation: generation)
    try writeSession(
      recordingID: recordingID, snapshot: snapshot, handle: handle, generation: generation)
    try write(Data(",\"devices\":[".utf8), to: handle, generation: generation)
    try writeDevices(
      recordingID: recordingID, snapshot: snapshot, handle: handle, lease: lease,
      generation: generation)
    try write(Data("],\"events\":[".utf8), to: handle, generation: generation)
    try writeEvents(
      recordingID: recordingID,
      snapshot: snapshot,
      compiledQuery: compiledQuery,
      querySnapshot: querySnapshot,
      handle: handle,
      lease: lease,
      generation: generation
    )
    try write(Data("],\"gaps\":[".utf8), to: handle, generation: generation)
    try writeGaps(
      recordingID: recordingID, snapshot: snapshot, handle: handle, lease: lease,
      generation: generation)
    try write(Data("],\"annotations\":[".utf8), to: handle, generation: generation)
    try writeAnnotations(
      recordingID: recordingID, snapshot: snapshot, handle: handle, lease: lease,
      generation: generation)
    try write(Data("]}".utf8), to: handle, generation: generation)
  }

  private func writeDevices(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    handle: FileHandle,
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64
  ) throws {
    var cursor: Int64 = 0
    var first = true
    while true {
      try validate(lease: lease, generation: generation)
      let rows: [Data] = try pool.exportReader.run(budget: .export()) { database in
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT d.rowID,a.ordinal,d.connectionOrdinal,d.startedWallMs,v.endedWallMs,v.partialHistory,d.applicationIdentifier,d.applicationVersion,v.displayName,v.state FROM DeviceSessions d JOIN InstallationAliases a ON a.rowID=d.installationAliasID JOIN DeviceSessionVersions v ON v.deviceSessionID=d.rowID WHERE d.recordingID=?1 AND d.recordingID<=?2 AND d.rowID>?3 AND d.rowID<=?4 AND a.rowID<=?5 AND v.rowID=(SELECT MAX(v2.rowID) FROM DeviceSessionVersions v2 WHERE v2.deviceSessionID=d.rowID AND v2.rowID<=?6) AND d.recordingID NOT IN (SELECT recordingID FROM Tombstones) ORDER BY d.rowID LIMIT ?7"
        )
        try statement.bind(recordingID, at: 1)
        try statement.bind(snapshot.recordingUpperRowID, at: 2)
        try statement.bind(cursor, at: 3)
        try statement.bind(snapshot.deviceSessionUpperRowID, at: 4)
        try statement.bind(snapshot.installationAliasUpperRowID, at: 5)
        try statement.bind(snapshot.deviceVersionUpperRowID, at: 6)
        try statement.bind(Int64(Self.pageSize), at: 7)
        var page: [Data] = []
        while try statement.step() {
          var object: [String: Any] = [
            "device": "device-\(statement.int64(at: 1))",
            "connection": "connection-\(statement.int64(at: 2))",
            "startedAtMilliseconds": statement.int64(at: 3),
            "partialHistory": statement.int64(at: 5) != 0,
            "state": statement.string(at: 9),
          ]
          if !statement.isNull(at: 4) { object["endedAtMilliseconds"] = statement.int64(at: 4) }
          if !statement.isNull(at: 6) { object["applicationIdentifier"] = statement.string(at: 6) }
          if !statement.isNull(at: 7) { object["applicationVersion"] = statement.string(at: 7) }
          if !statement.isNull(at: 8) { object["displayName"] = statement.string(at: 8) }
          page.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
          cursor = statement.int64(at: 0)
        }
        return page
      }
      guard !rows.isEmpty else { break }
      for row in rows {
        if !first { try write(Data(",".utf8), to: handle, generation: generation) }
        try write(row, to: handle, generation: generation)
        first = false
      }
    }
  }

  private func writeEvents(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    compiledQuery: ViewerCompiledQuery?,
    querySnapshot: ViewerQuerySnapshot?,
    handle: FileHandle,
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64
  ) throws {
    var cursorMonotonic: Int64 = -1
    var cursorRowID: Int64 = 0
    var first = true
    while true {
      try validate(lease: lease, generation: generation)
      let rows: [(Int64, Int64, Data)] = try pool.exportReader.run(budget: .export()) { database in
        let predicateSQL = compiledQuery.map { " AND \($0.predicateSQL)" } ?? ""
        let sql =
          "SELECT e.rowID,a.ordinal,d.connectionOrdinal,e.direction,e.wireSequence,e.eventUUID,e.eventType,e.contentJSON,e.createdWallMs,e.viewerWallMs,e.viewerMonotonicNs,e.priority,(SELECT disposition FROM EventDispositionVersions x WHERE x.eventID=e.rowID AND x.rowID<=? ORDER BY x.rowID DESC LIMIT 1),e.originMonotonicNs,e.ttlMs,e.schemaVersion,e.correlationEventUUID,e.replyToEventUUID FROM Events e JOIN DeviceSessions d ON d.rowID=e.deviceSessionID JOIN InstallationAliases a ON a.rowID=d.installationAliasID WHERE e.recordingID=? AND e.recordingID<=? AND e.rowID<=? AND d.rowID<=? AND a.rowID<=?\(predicateSQL) AND (e.viewerMonotonicNs>? OR (e.viewerMonotonicNs=? AND e.rowID>?)) AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones) ORDER BY e.viewerMonotonicNs,e.rowID LIMIT 1"
        let bindStatement: (ViewerSQLiteStatement) throws -> Void = { statement in
          var index: Int32 = 1
          try statement.bind(snapshot.dispositionUpperRowID, at: index)
          index += 1
          try statement.bind(recordingID, at: index)
          index += 1
          try statement.bind(snapshot.recordingUpperRowID, at: index)
          index += 1
          try statement.bind(snapshot.eventUpperRowID, at: index)
          index += 1
          try statement.bind(snapshot.deviceSessionUpperRowID, at: index)
          index += 1
          try statement.bind(snapshot.installationAliasUpperRowID, at: index)
          index += 1
          if let compiledQuery, let querySnapshot {
            index = try self.bindCompiledQuery(
              compiledQuery,
              querySnapshot: querySnapshot,
              to: statement,
              startingAt: index
            )
          }
          try statement.bind(cursorMonotonic, at: index)
          index += 1
          try statement.bind(cursorMonotonic, at: index)
          index += 1
          try statement.bind(cursorRowID, at: index)
        }
        try ViewerQueryPlanGate.validate(sql: sql, database: database, bind: bindStatement)
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql: sql
        )
        try bindStatement(statement)
        var page: [(Int64, Int64, Data)] = []
        while try statement.step() {
          let prefixObject: [String: Any] = [
            "device": "device-\(statement.int64(at: 1))",
            "connection": "connection-\(statement.int64(at: 2))",
            "direction": statement.string(at: 3),
            "wireSequence": statement.int64(at: 4),
            "eventID": statement.string(at: 5),
            "eventType": statement.string(at: 6),
            "createdAtMilliseconds": statement.int64(at: 8),
            "viewerReceivedAtMilliseconds": statement.int64(at: 9),
            "viewerMonotonicNanoseconds": statement.int64(at: 10),
            "priority": statement.string(at: 11),
            "originMonotonicNanoseconds": statement.int64(at: 13),
            "ttlMilliseconds": statement.int64(at: 14),
            "eventSchemaVersion": statement.int64(at: 15),
          ]
          var object = prefixObject
          if !statement.isNull(at: 12) { object["disposition"] = statement.string(at: 12) }
          var causality: [String: String] = [:]
          if !statement.isNull(at: 16) { causality["correlationID"] = statement.string(at: 16) }
          if !statement.isNull(at: 17) { causality["replyTo"] = statement.string(at: 17) }
          if !causality.isEmpty { object["causality"] = causality }
          var prefix = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
          guard prefix.last == UInt8(ascii: "}") else { throw ViewerStoreError.corruptStore }
          prefix.removeLast()
          prefix.append(contentsOf: Data(",\"content\":".utf8))
          prefix.append(statement.data(at: 7))
          prefix.append(UInt8(ascii: "}"))
          guard prefix.count <= 20 * 1_024 * 1_024 else { throw ViewerStoreError.invalidValue }
          page.append((statement.int64(at: 0), statement.int64(at: 10), prefix))
        }
        return page
      }
      guard !rows.isEmpty else { break }
      for (rowID, monotonic, row) in rows {
        if !first { try write(Data(",".utf8), to: handle, generation: generation) }
        try write(row, to: handle, generation: generation)
        first = false
        cursorRowID = rowID
        cursorMonotonic = monotonic
      }
    }
  }

  private func writeSession(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    handle: FileHandle,
    generation: UInt64
  ) throws {
    let row: Data = try pool.exportReader.run(budget: .export()) { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT r.startedWallMs,v.endedWallMs,v.name,v.note,v.pinned,v.state FROM Recordings r JOIN RecordingVersions v ON v.recordingID=r.rowID WHERE r.rowID=?1 AND r.rowID<=?2 AND v.rowID=(SELECT MAX(v2.rowID) FROM RecordingVersions v2 WHERE v2.recordingID=r.rowID AND v2.rowID<=?3) AND r.rowID NOT IN (SELECT recordingID FROM Tombstones)"
      )
      try statement.bind(recordingID, at: 1)
      try statement.bind(snapshot.recordingUpperRowID, at: 2)
      try statement.bind(snapshot.recordingVersionUpperRowID, at: 3)
      guard try statement.step() else { throw ViewerStoreError.invalidValue }
      var object: [String: Any] = [
        "startedAtMilliseconds": statement.int64(at: 0),
        "pinned": statement.int64(at: 4) != 0,
        "state": statement.string(at: 5),
      ]
      if !statement.isNull(at: 1) { object["endedAtMilliseconds"] = statement.int64(at: 1) }
      if !statement.isNull(at: 2) { object["name"] = statement.string(at: 2) }
      if !statement.isNull(at: 3) { object["note"] = statement.string(at: 3) }
      return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    try write(row, to: handle, generation: generation)
  }

  private func writeGaps(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    handle: FileHandle,
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64
  ) throws {
    var cursor: Int64 = 0
    var first = true
    while true {
      try validate(lease: lease, generation: generation)
      let rows: [(Int64, Data)] = try pool.exportReader.run(budget: .export()) { database in
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT g.rowID,g.createdWallMs,g.reason,g.count,d.connectionOrdinal,a.ordinal,g.firstViewerWallMs,g.lastViewerWallMs,g.directions,g.firstWireSequence,g.lastWireSequence FROM GapVersions g LEFT JOIN DeviceSessions d ON d.rowID=g.deviceSessionID AND d.rowID<=?1 LEFT JOIN InstallationAliases a ON a.rowID=d.installationAliasID AND a.rowID<=?2 WHERE g.recordingID=?3 AND g.rowID>?4 AND g.rowID<=?5 AND g.rowID=(SELECT MAX(g2.rowID) FROM GapVersions g2 WHERE g2.recordingID=g.recordingID AND g2.deviceSessionID IS g.deviceSessionID AND g2.sequence=g.sequence AND g2.namespace=g.namespace AND g2.rowID<=?5) ORDER BY g.rowID LIMIT ?6"
        )
        try statement.bind(snapshot.deviceSessionUpperRowID, at: 1)
        try statement.bind(snapshot.installationAliasUpperRowID, at: 2)
        try statement.bind(recordingID, at: 3)
        try statement.bind(cursor, at: 4)
        try statement.bind(snapshot.gapUpperRowID, at: 5)
        try statement.bind(Int64(Self.pageSize), at: 6)
        var page: [(Int64, Data)] = []
        while try statement.step() {
          var object: [String: Any] = [
            "createdAtMilliseconds": statement.int64(at: 1),
            "reason": statement.string(at: 2),
            "count": statement.int64(at: 3),
            "firstViewerTimeMilliseconds": statement.int64(at: 6),
            "lastViewerTimeMilliseconds": statement.int64(at: 7),
            "directions": statement.string(at: 8),
          ]
          if !statement.isNull(at: 4) {
            object["connection"] = "connection-\(statement.int64(at: 4))"
          }
          if !statement.isNull(at: 5) { object["device"] = "device-\(statement.int64(at: 5))" }
          if !statement.isNull(at: 9) { object["firstWireSequence"] = statement.int64(at: 9) }
          if !statement.isNull(at: 10) { object["lastWireSequence"] = statement.int64(at: 10) }
          page.append(
            (
              statement.int64(at: 0),
              try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            ))
        }
        return page
      }
      guard !rows.isEmpty else { break }
      for (rowID, row) in rows {
        if !first { try write(Data(",".utf8), to: handle, generation: generation) }
        try write(row, to: handle, generation: generation)
        first = false
        cursor = rowID
      }
    }
  }

  private func writeAnnotations(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    handle: FileHandle,
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64
  ) throws {
    var cursor: Int64 = 0
    var first = true
    while true {
      try validate(lease: lease, generation: generation)
      let rows: [(Int64, Data)] = try pool.exportReader.run(budget: .export()) { database in
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT rowID,revision,createdWallMs,body FROM AnnotationVersions WHERE recordingID=?1 AND rowID>?2 AND rowID<=?3 ORDER BY rowID LIMIT ?4"
        )
        try statement.bind(recordingID, at: 1)
        try statement.bind(cursor, at: 2)
        try statement.bind(snapshot.annotationUpperRowID, at: 3)
        try statement.bind(Int64(Self.pageSize), at: 4)
        var page: [(Int64, Data)] = []
        while try statement.step() {
          let object: [String: Any] = [
            "revision": statement.int64(at: 1),
            "createdAtMilliseconds": statement.int64(at: 2),
            "body": statement.string(at: 3),
          ]
          page.append(
            (
              statement.int64(at: 0),
              try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            ))
        }
        return page
      }
      guard !rows.isEmpty else { break }
      for (rowID, row) in rows {
        if !first { try write(Data(",".utf8), to: handle, generation: generation) }
        try write(row, to: handle, generation: generation)
        first = false
        cursor = rowID
      }
    }
  }

  private func captureSnapshot(
    querySnapshot: ViewerQuerySnapshot?
  ) throws -> ViewerExportSnapshot {
    try pool.exportReader.run(budget: .export()) { database in
      try ViewerSQLiteConnection.execute("BEGIN", on: database)
      defer { try? ViewerSQLiteConnection.execute("COMMIT", on: database) }
      return ViewerExportSnapshot(
        eventUpperRowID: min(
          try maximum("Events", database: database),
          querySnapshot?.eventUpperRowID ?? Int64.max
        ),
        recordingUpperRowID: try maximum("Recordings", database: database),
        deviceSessionUpperRowID: try maximum("DeviceSessions", database: database),
        installationAliasUpperRowID: try maximum("InstallationAliases", database: database),
        recordingVersionUpperRowID: min(
          try maximum("RecordingVersions", database: database),
          querySnapshot?.recordingVersionUpperRowID ?? Int64.max
        ),
        deviceVersionUpperRowID: min(
          try maximum("DeviceSessionVersions", database: database),
          querySnapshot?.deviceVersionUpperRowID ?? Int64.max
        ),
        dispositionUpperRowID: min(
          try maximum("EventDispositionVersions", database: database),
          querySnapshot?.dispositionUpperRowID ?? Int64.max
        ),
        gapUpperRowID: min(
          try maximum("GapVersions", database: database),
          querySnapshot?.gapUpperRowID ?? Int64.max
        ),
        dropUpperRowID: min(
          try maximum("DropVersions", database: database),
          querySnapshot?.dropUpperRowID ?? Int64.max
        ),
        annotationUpperRowID: try maximum("AnnotationVersions", database: database)
      )
    }
  }

  private func maximum(_ table: String, database: OpaquePointer) throws -> Int64 {
    try ViewerStoreSchema.scalarInt64(
      "SELECT COALESCE(MAX(rowID),0) FROM \(table)", database: database)
  }

  private func validated(_ recordingID: Int64) throws -> Int64 {
    guard recordingID > 0 else { throw ViewerStoreError.invalidValue }
    return recordingID
  }

  private func requireVisibleRecording(
    _ recordingID: Int64,
    database: OpaquePointer
  ) throws {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT 1 FROM Recordings WHERE rowID=?1 AND rowID NOT IN (SELECT recordingID FROM Tombstones)"
    )
    try statement.bind(recordingID, at: 1)
    guard try statement.step() else { throw ViewerStoreError.invalidValue }
  }

  private func bindQuery(
    recordingID: Int64,
    eventUpperRowID: Int64,
    compiled: ViewerCompiledQuery,
    querySnapshot: ViewerQuerySnapshot,
    to statement: ViewerSQLiteStatement,
    startingAt index: Int32
  ) throws {
    var index = index
    try statement.bind(recordingID, at: index)
    index += 1
    try statement.bind(eventUpperRowID, at: index)
    index += 1
    _ = try bindCompiledQuery(
      compiled,
      querySnapshot: querySnapshot,
      to: statement,
      startingAt: index
    )
  }

  private func bindCompiledQuery(
    _ compiled: ViewerCompiledQuery,
    querySnapshot: ViewerQuerySnapshot,
    to statement: ViewerSQLiteStatement,
    startingAt start: Int32
  ) throws -> Int32 {
    var index = start
    for binding in compiled.bindings {
      switch binding {
      case .integer(let value): try statement.bind(value, at: index)
      case .real(let value): try statement.bind(value, at: index)
      case .text(let value): try statement.bind(value, at: index)
      case .gapSnapshotUpperBound:
        try statement.bind(querySnapshot.gapUpperRowID, at: index)
      case .dropSnapshotUpperBound:
        try statement.bind(querySnapshot.dropUpperRowID, at: index)
      case .dispositionSnapshotUpperBound:
        try statement.bind(querySnapshot.dispositionUpperRowID, at: index)
      }
      index += 1
    }
    return index
  }

  private func validate(
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64
  ) throws {
    try cancellation.check(generation)
    try leases.validateExport(lease)
  }

  private func secureTemporarySibling(for destination: URL) throws -> SecureTemporary {
    let parent = destination.deletingLastPathComponent()
    let destinationLeaf = destination.lastPathComponent
    guard destinationLeaf != ".", destinationLeaf != "..", !destinationLeaf.contains("/") else {
      throw ViewerStoreError.invalidPath
    }
    let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard parentDescriptor >= 0 else { throw ViewerStoreError.invalidPath }
    var parentInfo = stat()
    guard fstat(parentDescriptor, &parentInfo) == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
      _ = close(parentDescriptor)
      throw ViewerStoreError.invalidPath
    }
    var destinationInfo = stat()
    let destinationStatus = destinationLeaf.withCString {
      fstatat(parentDescriptor, $0, &destinationInfo, AT_SYMLINK_NOFOLLOW)
    }
    if destinationStatus == 0, (destinationInfo.st_mode & S_IFMT) == S_IFLNK {
      _ = close(parentDescriptor)
      throw ViewerStoreError.invalidPath
    }
    let temporaryLeaf = ".\(destinationLeaf).\(UUID().uuidString).tmp"
    let fileDescriptor = temporaryLeaf.withCString {
      openat(parentDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    }
    guard fileDescriptor >= 0, fchmod(fileDescriptor, 0o600) == 0 else {
      if fileDescriptor >= 0 { _ = close(fileDescriptor) }
      _ = close(parentDescriptor)
      throw ViewerStoreError.invalidPath
    }
    return SecureTemporary(
      parentDescriptor: parentDescriptor,
      parentPath: parent.path,
      fileDescriptor: fileDescriptor,
      temporaryLeaf: temporaryLeaf,
      destinationLeaf: destinationLeaf
    )
  }

  private func validateTemporary(_ temporary: SecureTemporary) throws {
    var descriptorInfo = stat()
    var leafInfo = stat()
    let leafStatus = temporary.temporaryLeaf.withCString {
      fstatat(temporary.parentDescriptor, $0, &leafInfo, AT_SYMLINK_NOFOLLOW)
    }
    guard fstat(temporary.fileDescriptor, &descriptorInfo) == 0, leafStatus == 0,
      (descriptorInfo.st_mode & S_IFMT) == S_IFREG,
      (leafInfo.st_mode & S_IFMT) == S_IFREG,
      descriptorInfo.st_dev == leafInfo.st_dev,
      descriptorInfo.st_ino == leafInfo.st_ino,
      descriptorInfo.st_uid == getuid(), descriptorInfo.st_nlink == 1,
      leafInfo.st_nlink == 1, (descriptorInfo.st_mode & 0o777) == 0o600
    else { throw ViewerStoreError.invalidPath }
  }

  private func validateParent(_ temporary: SecureTemporary) throws {
    var descriptorInfo = stat()
    var pathInfo = stat()
    guard fstat(temporary.parentDescriptor, &descriptorInfo) == 0,
      lstat(temporary.parentPath, &pathInfo) == 0,
      (pathInfo.st_mode & S_IFMT) == S_IFDIR,
      descriptorInfo.st_dev == pathInfo.st_dev,
      descriptorInfo.st_ino == pathInfo.st_ino
    else { throw ViewerStoreError.invalidPath }
  }

  private func atomicReplace(_ temporary: SecureTemporary) throws {
    try filePhases.reach(.beforeDirectoryOpen)
    try validateParent(temporary)
    try validateTemporary(temporary)
    // rename(2) is the only irreversible commit point. Before it succeeds, an existing
    // destination is untouched. After it succeeds, directory synchronization is best effort
    // and cannot turn an already committed replacement into a reported pre-commit failure.
    try filePhases.reach(.beforeRename)
    try validateParent(temporary)
    try validateTemporary(temporary)
    let result = temporary.temporaryLeaf.withCString { source in
      temporary.destinationLeaf.withCString { destination in
        renameat(
          temporary.parentDescriptor,
          source,
          temporary.parentDescriptor,
          destination
        )
      }
    }
    guard result == 0 else {
      throw ViewerStoreError.invalidPath
    }
    try? filePhases.reach(.afterRename)
    try? filePhases.reach(.directorySync)
    _ = fsync(temporary.parentDescriptor)
  }

  private func write(
    _ data: Data,
    to handle: FileHandle,
    generation: UInt64
  ) throws {
    var offset = 0
    while offset < data.count {
      try cancellation.check(generation)
      let end = min(data.count, offset + Self.maximumBufferBytes)
      try handle.write(contentsOf: data[offset..<end])
      offset = end
    }
  }

}

extension ViewerExportSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExportSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExportFilePhaseObserver: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExportFilePhaseObserver(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExportCancellation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExportCancellation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerStoreExportService: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreExportService(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
