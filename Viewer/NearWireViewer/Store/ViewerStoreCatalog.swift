import CryptoKit
import Foundation

enum ViewerCatalogPageDirection: Equatable, Sendable {
  case older
  case newer
}

enum ViewerCatalogPlanKind: Equatable, Sendable {
  case recording
  case device
}

struct ViewerCatalogPlanObservation: Equatable, Sendable {
  let kind: ViewerCatalogPlanKind
  let details: [String]
}

struct ViewerCatalogDeviceHint: Equatable, Sendable {
  let installationAlias: String
  let connectionAlias: String
  let displayName: String?
  let applicationIdentifier: String?
  let applicationVersion: String?
}

struct ViewerRecordingCatalogRow: Equatable, Sendable {
  let rowID: Int64
  let logicalID: UUID
  let revision: Int64
  let name: String?
  let note: String?
  let pinned: Bool
  let state: String
  let startedWallMilliseconds: Int64
  let startedMonotonicNanoseconds: Int64
  let endedWallMilliseconds: Int64?
  let endedMonotonicNanoseconds: Int64?
  let deviceCount: Int64
  let latestDevice: ViewerCatalogDeviceHint?
  let hasGap: Bool
  let hasDrop: Bool
}

struct ViewerDeviceCatalogRow: Equatable, Sendable {
  let rowID: Int64
  let logicalID: UUID
  let recordingID: Int64
  let installationAlias: String
  let connectionAlias: String
  let connectionOrdinal: Int64
  let revision: Int64
  let displayName: String?
  let state: String
  let partialHistory: Bool
  let applicationIdentifier: String?
  let applicationVersion: String?
  let startedWallMilliseconds: Int64
  let startedMonotonicNanoseconds: Int64
  let endedWallMilliseconds: Int64?
  let endedMonotonicNanoseconds: Int64?
  let hasGap: Bool
  let hasDrop: Bool
}

struct ViewerRecordingCatalogSnapshot: Equatable, Sendable {
  let storeGeneration: UInt64
  let changeGeneration: String
  let recordingUpperRowID: Int64
  let recordingVersionUpperRowID: Int64
  let installationAliasUpperRowID: Int64
  let deviceSessionUpperRowID: Int64
  let deviceVersionUpperRowID: Int64
  let tombstoneUpperRowID: Int64
  let gapUpperRowID: Int64
  let dropUpperRowID: Int64
}

struct ViewerDeviceCatalogSnapshot: Equatable, Sendable {
  let storeGeneration: UInt64
  let recordingID: Int64
  let changeGeneration: String
  let recordingUpperRowID: Int64
  let recordingVersionUpperRowID: Int64
  let installationAliasUpperRowID: Int64
  let deviceSessionUpperRowID: Int64
  let deviceVersionUpperRowID: Int64
  let tombstoneUpperRowID: Int64
  let gapUpperRowID: Int64
  let dropUpperRowID: Int64
}

struct ViewerRecordingCatalogCursor: Equatable, Sendable {
  let queryFingerprint: String
  let snapshot: ViewerRecordingCatalogSnapshot
  let direction: ViewerCatalogPageDirection
  let rowID: Int64
}

struct ViewerDeviceCatalogCursor: Equatable, Sendable {
  let queryFingerprint: String
  let snapshot: ViewerDeviceCatalogSnapshot
  let direction: ViewerCatalogPageDirection
  let connectionOrdinal: Int64
  let rowID: Int64
}

struct ViewerRecordingCatalogPage: Equatable, Sendable {
  let snapshot: ViewerRecordingCatalogSnapshot
  let rows: [ViewerRecordingCatalogRow]
  let olderCursor: ViewerRecordingCatalogCursor?
  let newerCursor: ViewerRecordingCatalogCursor?
}

struct ViewerDeviceCatalogPage: Equatable, Sendable {
  let snapshot: ViewerDeviceCatalogSnapshot
  let rows: [ViewerDeviceCatalogRow]
  let olderCursor: ViewerDeviceCatalogCursor?
  let newerCursor: ViewerDeviceCatalogCursor?
}

final class ViewerStoreCatalogService: @unchecked Sendable {
  private struct Bounds: Equatable {
    let recordingUpperRowID: Int64
    let recordingVersionUpperRowID: Int64
    let installationAliasUpperRowID: Int64
    let deviceSessionUpperRowID: Int64
    let deviceVersionUpperRowID: Int64
    let tombstoneUpperRowID: Int64
    let gapUpperRowID: Int64
    let dropUpperRowID: Int64

    var changeGeneration: String {
      ViewerStoreCatalogService.fingerprint([
        recordingUpperRowID,
        recordingVersionUpperRowID,
        installationAliasUpperRowID,
        deviceSessionUpperRowID,
        deviceVersionUpperRowID,
        tombstoneUpperRowID,
        gapUpperRowID,
        dropUpperRowID,
      ])
    }
  }

  private static let recordingFingerprint = fingerprint("recordings-v1")
  private let pool: ViewerSQLitePool
  private let planObserver: @Sendable (ViewerCatalogPlanObservation) -> Void

  init(
    pool: ViewerSQLitePool,
    planObserver: @escaping @Sendable (ViewerCatalogPlanObservation) -> Void = { _ in }
  ) {
    self.pool = pool
    self.planObserver = planObserver
  }

  func recordingPage(
    storeGeneration: UInt64,
    cursor: ViewerRecordingCatalogCursor?,
    direction: ViewerCatalogPageDirection = .older,
    limit: Int = 50,
    operationID: UUID? = nil
  ) throws -> ViewerRecordingCatalogPage {
    guard storeGeneration > 0, (1...100).contains(limit) else {
      throw ViewerStoreError.invalidValue
    }
    if let cursor {
      guard cursor.snapshot.storeGeneration == storeGeneration else {
        throw ViewerStoreExplorerFailure.storeReplaced
      }
      guard cursor.queryFingerprint == Self.recordingFingerprint,
        cursor.direction == direction,
        cursor.rowID > 0
      else { throw ViewerStoreError.invalidValue }
    } else if direction != .older {
      throw ViewerStoreError.invalidValue
    }

    return try pool.queryReader.run(operationID: operationID, budget: .query()) { database in
      try Self.withReadTransaction(database) {
        let bounds = try Self.globalBounds(database)
        let snapshot: ViewerRecordingCatalogSnapshot
        if let cursor {
          snapshot = cursor.snapshot
          guard Self.bounds(snapshot) == bounds else {
            throw ViewerStoreExplorerFailure.catalogChanged
          }
        } else {
          snapshot = ViewerRecordingCatalogSnapshot(
            storeGeneration: storeGeneration,
            changeGeneration: bounds.changeGeneration,
            recordingUpperRowID: bounds.recordingUpperRowID,
            recordingVersionUpperRowID: bounds.recordingVersionUpperRowID,
            installationAliasUpperRowID: bounds.installationAliasUpperRowID,
            deviceSessionUpperRowID: bounds.deviceSessionUpperRowID,
            deviceVersionUpperRowID: bounds.deviceVersionUpperRowID,
            tombstoneUpperRowID: bounds.tombstoneUpperRowID,
            gapUpperRowID: bounds.gapUpperRowID,
            dropUpperRowID: bounds.dropUpperRowID
          )
        }
        guard snapshot.changeGeneration == bounds.changeGeneration else {
          throw ViewerStoreExplorerFailure.catalogChanged
        }
        return try Self.queryRecordingPage(
          snapshot: snapshot,
          cursor: cursor,
          direction: direction,
          limit: limit,
          database: database,
          planObserver: planObserver
        )
      }
    }
  }

  func devicePage(
    recordingID: Int64,
    storeGeneration: UInt64,
    cursor: ViewerDeviceCatalogCursor?,
    direction: ViewerCatalogPageDirection = .older,
    limit: Int = 100,
    operationID: UUID? = nil
  ) throws -> ViewerDeviceCatalogPage {
    guard recordingID > 0, storeGeneration > 0, (1...200).contains(limit) else {
      throw ViewerStoreError.invalidValue
    }
    let queryFingerprint = Self.fingerprint("devices-v1:\(recordingID)")
    if let cursor {
      guard cursor.snapshot.storeGeneration == storeGeneration else {
        throw ViewerStoreExplorerFailure.storeReplaced
      }
      guard cursor.queryFingerprint == queryFingerprint,
        cursor.snapshot.recordingID == recordingID,
        cursor.direction == direction,
        cursor.connectionOrdinal > 0,
        cursor.rowID > 0
      else { throw ViewerStoreError.invalidValue }
    } else if direction != .older {
      throw ViewerStoreError.invalidValue
    }

    return try pool.queryReader.run(operationID: operationID, budget: .query()) { database in
      try Self.withReadTransaction(database) {
        let bounds = try Self.deviceBounds(recordingID: recordingID, database: database)
        let snapshot: ViewerDeviceCatalogSnapshot
        if let cursor {
          snapshot = cursor.snapshot
          guard Self.bounds(snapshot) == bounds else {
            throw ViewerStoreExplorerFailure.catalogChanged
          }
        } else {
          snapshot = ViewerDeviceCatalogSnapshot(
            storeGeneration: storeGeneration,
            recordingID: recordingID,
            changeGeneration: bounds.changeGeneration,
            recordingUpperRowID: bounds.recordingUpperRowID,
            recordingVersionUpperRowID: bounds.recordingVersionUpperRowID,
            installationAliasUpperRowID: bounds.installationAliasUpperRowID,
            deviceSessionUpperRowID: bounds.deviceSessionUpperRowID,
            deviceVersionUpperRowID: bounds.deviceVersionUpperRowID,
            tombstoneUpperRowID: bounds.tombstoneUpperRowID,
            gapUpperRowID: bounds.gapUpperRowID,
            dropUpperRowID: bounds.dropUpperRowID
          )
        }
        guard snapshot.changeGeneration == bounds.changeGeneration else {
          throw ViewerStoreExplorerFailure.catalogChanged
        }
        try Self.requireVisibleRecording(snapshot: snapshot, database: database)
        return try Self.queryDevicePage(
          queryFingerprint: queryFingerprint,
          snapshot: snapshot,
          cursor: cursor,
          direction: direction,
          limit: limit,
          database: database,
          planObserver: planObserver
        )
      }
    }
  }

  func cancel(operationID: UUID) {
    pool.queryReader.cancel(operationID: operationID)
  }

  func clearCancellation(operationID: UUID) {
    pool.queryReader.clearCancellation(operationID: operationID)
  }

  private static func queryRecordingPage(
    snapshot: ViewerRecordingCatalogSnapshot,
    cursor: ViewerRecordingCatalogCursor?,
    direction: ViewerCatalogPageDirection,
    limit: Int,
    database: OpaquePointer,
    planObserver: @Sendable (ViewerCatalogPlanObservation) -> Void
  ) throws -> ViewerRecordingCatalogPage {
    let comparison = direction == .older ? "<" : ">"
    let order = direction == .older ? "DESC" : "ASC"
    let cursorClause = cursor == nil ? "" : " AND r.rowID \(comparison) ?9"
    let limitIndex = cursor == nil ? 9 : 10
    let sql = """
      SELECT r.rowID,r.logicalID,r.startedWallMs,r.startedMonotonicNs,
        v.revision,v.name,v.note,v.pinned,v.state,v.endedWallMs,v.endedMonotonicNs,
        (SELECT COUNT(*) FROM DeviceSessions dc INDEXED BY DeviceRecordingOrder
          WHERE dc.recordingID=r.rowID AND dc.rowID<=?4),
        (SELECT ia.ordinal FROM DeviceSessions ds INDEXED BY DeviceRecordingOrder
          JOIN InstallationAliases ia ON ia.rowID=ds.installationAliasID AND ia.rowID<=?3
          WHERE ds.recordingID=r.rowID AND ds.rowID<=?4 ORDER BY ds.rowID DESC LIMIT 1),
        (SELECT ds.connectionOrdinal FROM DeviceSessions ds INDEXED BY DeviceRecordingOrder
          WHERE ds.recordingID=r.rowID AND ds.rowID<=?4 ORDER BY ds.rowID DESC LIMIT 1),
        (SELECT dv.displayName FROM DeviceSessions ds INDEXED BY DeviceRecordingOrder
          JOIN DeviceSessionVersions dv ON dv.deviceSessionID=ds.rowID
          WHERE ds.recordingID=r.rowID AND ds.rowID<=?4
            AND dv.rowID=(SELECT MAX(dv2.rowID) FROM DeviceSessionVersions dv2
              WHERE dv2.deviceSessionID=ds.rowID AND dv2.rowID<=?5)
          ORDER BY ds.rowID DESC LIMIT 1),
        (SELECT ds.applicationIdentifier FROM DeviceSessions ds INDEXED BY DeviceRecordingOrder
          WHERE ds.recordingID=r.rowID AND ds.rowID<=?4 ORDER BY ds.rowID DESC LIMIT 1),
        (SELECT ds.applicationVersion FROM DeviceSessions ds INDEXED BY DeviceRecordingOrder
          WHERE ds.recordingID=r.rowID AND ds.rowID<=?4 ORDER BY ds.rowID DESC LIMIT 1),
        EXISTS(SELECT 1 FROM GapVersions g INDEXED BY GapTimelineAllDevices
          WHERE g.recordingID=r.rowID AND g.rowID<=?6 LIMIT 1),
        EXISTS(SELECT 1 FROM DeviceSessions dd INDEXED BY DeviceRecordingOrder
          WHERE dd.recordingID=r.rowID AND dd.rowID<=?4
            AND EXISTS(SELECT 1 FROM DropVersions d
              WHERE d.deviceSessionID=dd.rowID AND d.rowID<=?7 LIMIT 1) LIMIT 1)
      FROM Recordings r
      CROSS JOIN RecordingVersions v
      WHERE r.rowID<=?1
        AND v.recordingID=r.rowID
        AND v.rowID=(SELECT MAX(v2.rowID) FROM RecordingVersions v2
          WHERE v2.recordingID=r.rowID AND v2.rowID<=?2)
        AND NOT EXISTS(SELECT 1 FROM Tombstones t
          WHERE t.recordingID=r.rowID AND t.rowID<=?8)
        \(cursorClause)
      ORDER BY r.rowID \(order)
      LIMIT ?\(limitIndex)
      """
    let bind: (ViewerSQLiteStatement) throws -> Void = { statement in
      try statement.bind(snapshot.recordingUpperRowID, at: 1)
      try statement.bind(snapshot.recordingVersionUpperRowID, at: 2)
      try statement.bind(snapshot.installationAliasUpperRowID, at: 3)
      try statement.bind(snapshot.deviceSessionUpperRowID, at: 4)
      try statement.bind(snapshot.deviceVersionUpperRowID, at: 5)
      try statement.bind(snapshot.gapUpperRowID, at: 6)
      try statement.bind(snapshot.dropUpperRowID, at: 7)
      try statement.bind(snapshot.tombstoneUpperRowID, at: 8)
      if let cursor { try statement.bind(cursor.rowID, at: 9) }
      try statement.bind(Int64(limit), at: Int32(limitIndex))
    }
    let details = try ViewerCatalogPlanGate.validate(
      sql: sql,
      database: database,
      bind: bind,
      required: ["SEARCH R USING INTEGER PRIMARY KEY", "SEARCH V USING INTEGER PRIMARY KEY"]
    )
    planObserver(ViewerCatalogPlanObservation(kind: .recording, details: details))
    let statement = try ViewerSQLiteStatement(database: database, sql: sql)
    try bind(statement)
    var rows: [ViewerRecordingCatalogRow] = []
    while try statement.step() {
      rows.append(try recordingRow(statement))
    }
    if direction == .newer { rows.reverse() }
    return ViewerRecordingCatalogPage(
      snapshot: snapshot,
      rows: rows,
      olderCursor: rows.last.map {
        ViewerRecordingCatalogCursor(
          queryFingerprint: recordingFingerprint,
          snapshot: snapshot,
          direction: .older,
          rowID: $0.rowID
        )
      },
      newerCursor: rows.first.map {
        ViewerRecordingCatalogCursor(
          queryFingerprint: recordingFingerprint,
          snapshot: snapshot,
          direction: .newer,
          rowID: $0.rowID
        )
      }
    )
  }

  private static func queryDevicePage(
    queryFingerprint: String,
    snapshot: ViewerDeviceCatalogSnapshot,
    cursor: ViewerDeviceCatalogCursor?,
    direction: ViewerCatalogPageDirection,
    limit: Int,
    database: OpaquePointer,
    planObserver: @Sendable (ViewerCatalogPlanObservation) -> Void
  ) throws -> ViewerDeviceCatalogPage {
    let comparison = direction == .older ? "<" : ">"
    let order = direction == .older ? "DESC" : "ASC"
    let cursorClause =
      cursor == nil
      ? ""
      : " AND (ds.connectionOrdinal,ds.rowID) \(comparison) (?9,?10)"
    let limitIndex = cursor == nil ? 9 : 11
    let sql = """
      SELECT ds.rowID,ds.logicalID,ia.ordinal,ds.connectionOrdinal,
        ds.applicationIdentifier,ds.applicationVersion,ds.startedWallMs,ds.startedMonotonicNs,
        dv.revision,dv.displayName,dv.state,dv.partialHistory,dv.endedWallMs,dv.endedMonotonicNs,
        EXISTS(SELECT 1 FROM GapVersions g INDEXED BY GapTimelineByDevice
          WHERE g.recordingID=?1 AND g.deviceSessionID=ds.rowID AND g.rowID<=?7 LIMIT 1),
        EXISTS(SELECT 1 FROM DropVersions d
          WHERE d.deviceSessionID=ds.rowID AND d.rowID<=?8 LIMIT 1)
      FROM DeviceSessions ds INDEXED BY sqlite_autoindex_DeviceSessions_2
      CROSS JOIN InstallationAliases ia
      CROSS JOIN DeviceSessionVersions dv
      WHERE ds.recordingID=?1 AND ds.rowID<=?4
        AND ia.rowID=ds.installationAliasID AND ia.rowID<=?3
        AND dv.deviceSessionID=ds.rowID
        AND dv.rowID=(SELECT MAX(dv2.rowID) FROM DeviceSessionVersions dv2
          WHERE dv2.deviceSessionID=ds.rowID AND dv2.rowID<=?5)
        AND NOT EXISTS(SELECT 1 FROM Tombstones t
          WHERE t.recordingID=?1 AND t.rowID<=?6)
        \(cursorClause)
      ORDER BY ds.connectionOrdinal \(order),ds.rowID \(order)
      LIMIT ?\(limitIndex)
      """
    let bind: (ViewerSQLiteStatement) throws -> Void = { statement in
      try statement.bind(snapshot.recordingID, at: 1)
      try statement.bind(snapshot.recordingUpperRowID, at: 2)
      try statement.bind(snapshot.installationAliasUpperRowID, at: 3)
      try statement.bind(snapshot.deviceSessionUpperRowID, at: 4)
      try statement.bind(snapshot.deviceVersionUpperRowID, at: 5)
      try statement.bind(snapshot.tombstoneUpperRowID, at: 6)
      try statement.bind(snapshot.gapUpperRowID, at: 7)
      try statement.bind(snapshot.dropUpperRowID, at: 8)
      if let cursor {
        try statement.bind(cursor.connectionOrdinal, at: 9)
        try statement.bind(cursor.rowID, at: 10)
      }
      try statement.bind(Int64(limit), at: Int32(limitIndex))
    }
    let details = try ViewerCatalogPlanGate.validate(
      sql: sql,
      database: database,
      bind: bind,
      required: [
        "USING INDEX SQLITE_AUTOINDEX_DEVICESESSIONS_2",
        "SEARCH IA USING INTEGER PRIMARY KEY",
        "SEARCH DV USING INTEGER PRIMARY KEY",
      ]
    )
    planObserver(ViewerCatalogPlanObservation(kind: .device, details: details))
    let statement = try ViewerSQLiteStatement(database: database, sql: sql)
    try bind(statement)
    var rows: [ViewerDeviceCatalogRow] = []
    while try statement.step() {
      rows.append(try deviceRow(statement, recordingID: snapshot.recordingID))
    }
    if direction == .newer { rows.reverse() }
    return ViewerDeviceCatalogPage(
      snapshot: snapshot,
      rows: rows,
      olderCursor: rows.last.map {
        ViewerDeviceCatalogCursor(
          queryFingerprint: queryFingerprint,
          snapshot: snapshot,
          direction: .older,
          connectionOrdinal: $0.connectionOrdinal,
          rowID: $0.rowID
        )
      },
      newerCursor: rows.first.map {
        ViewerDeviceCatalogCursor(
          queryFingerprint: queryFingerprint,
          snapshot: snapshot,
          direction: .newer,
          connectionOrdinal: $0.connectionOrdinal,
          rowID: $0.rowID
        )
      }
    )
  }

  private static func recordingRow(
    _ statement: ViewerSQLiteStatement
  ) throws -> ViewerRecordingCatalogRow {
    guard let logicalID = UUID(uuidString: statement.string(at: 1)) else {
      throw ViewerStoreError.corruptStore
    }
    let rowID = statement.int64(at: 0)
    let revision = statement.int64(at: 4)
    let deviceCount = statement.int64(at: 11)
    guard rowID > 0, revision > 0, deviceCount >= 0 else {
      throw ViewerStoreError.corruptStore
    }
    let installationOrdinal = optionalInt64(statement, at: 12)
    let connectionOrdinal = optionalInt64(statement, at: 13)
    let latestDevice: ViewerCatalogDeviceHint?
    switch (installationOrdinal, connectionOrdinal) {
    case (.none, .none):
      latestDevice = nil
    case (.some(let installation), .some(let connection)) where installation > 0 && connection > 0:
      latestDevice = ViewerCatalogDeviceHint(
        installationAlias: "device-\(installation)",
        connectionAlias: "connection-\(connection)",
        displayName: optionalString(statement, at: 14),
        applicationIdentifier: optionalString(statement, at: 15),
        applicationVersion: optionalString(statement, at: 16)
      )
    default:
      throw ViewerStoreError.corruptStore
    }
    return ViewerRecordingCatalogRow(
      rowID: rowID,
      logicalID: logicalID,
      revision: revision,
      name: optionalString(statement, at: 5),
      note: optionalString(statement, at: 6),
      pinned: statement.int64(at: 7) == 1,
      state: statement.string(at: 8),
      startedWallMilliseconds: statement.int64(at: 2),
      startedMonotonicNanoseconds: statement.int64(at: 3),
      endedWallMilliseconds: optionalInt64(statement, at: 9),
      endedMonotonicNanoseconds: optionalInt64(statement, at: 10),
      deviceCount: deviceCount,
      latestDevice: latestDevice,
      hasGap: statement.int64(at: 17) == 1,
      hasDrop: statement.int64(at: 18) == 1
    )
  }

  private static func deviceRow(
    _ statement: ViewerSQLiteStatement,
    recordingID: Int64
  ) throws -> ViewerDeviceCatalogRow {
    guard let logicalID = UUID(uuidString: statement.string(at: 1)) else {
      throw ViewerStoreError.corruptStore
    }
    let rowID = statement.int64(at: 0)
    let installationOrdinal = statement.int64(at: 2)
    let connectionOrdinal = statement.int64(at: 3)
    let revision = statement.int64(at: 8)
    guard rowID > 0, recordingID > 0, installationOrdinal > 0, connectionOrdinal > 0,
      revision > 0
    else { throw ViewerStoreError.corruptStore }
    return ViewerDeviceCatalogRow(
      rowID: rowID,
      logicalID: logicalID,
      recordingID: recordingID,
      installationAlias: "device-\(installationOrdinal)",
      connectionAlias: "connection-\(connectionOrdinal)",
      connectionOrdinal: connectionOrdinal,
      revision: revision,
      displayName: optionalString(statement, at: 9),
      state: statement.string(at: 10),
      partialHistory: statement.int64(at: 11) == 1,
      applicationIdentifier: optionalString(statement, at: 4),
      applicationVersion: optionalString(statement, at: 5),
      startedWallMilliseconds: statement.int64(at: 6),
      startedMonotonicNanoseconds: statement.int64(at: 7),
      endedWallMilliseconds: optionalInt64(statement, at: 12),
      endedMonotonicNanoseconds: optionalInt64(statement, at: 13),
      hasGap: statement.int64(at: 14) == 1,
      hasDrop: statement.int64(at: 15) == 1
    )
  }

  private static func globalBounds(_ database: OpaquePointer) throws -> Bounds {
    try Bounds(
      recordingUpperRowID: maximumRowID("Recordings", database: database),
      recordingVersionUpperRowID: maximumRowID("RecordingVersions", database: database),
      installationAliasUpperRowID: maximumRowID("InstallationAliases", database: database),
      deviceSessionUpperRowID: maximumRowID("DeviceSessions", database: database),
      deviceVersionUpperRowID: maximumRowID("DeviceSessionVersions", database: database),
      tombstoneUpperRowID: maximumRowID("Tombstones", database: database),
      gapUpperRowID: maximumRowID("GapVersions", database: database),
      dropUpperRowID: maximumRowID("DropVersions", database: database)
    )
  }

  private static func deviceBounds(
    recordingID: Int64,
    database: OpaquePointer
  ) throws -> Bounds {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: """
        SELECT
          COALESCE((SELECT MAX(rowID) FROM Recordings WHERE rowID=?1),0),
          COALESCE((SELECT MAX(rowID) FROM RecordingVersions WHERE recordingID=?1),0),
          COALESCE((SELECT MAX(rowID) FROM InstallationAliases WHERE recordingID=?1),0),
          COALESCE((SELECT MAX(rowID) FROM DeviceSessions WHERE recordingID=?1),0),
          COALESCE((SELECT MAX(dv.rowID) FROM DeviceSessions ds
            JOIN DeviceSessionVersions dv ON dv.deviceSessionID=ds.rowID
            WHERE ds.recordingID=?1),0),
          COALESCE((SELECT MAX(rowID) FROM Tombstones WHERE recordingID=?1),0),
          COALESCE((SELECT MAX(rowID) FROM GapVersions WHERE recordingID=?1),0),
          COALESCE((SELECT MAX(d.rowID) FROM DeviceSessions ds
            JOIN DropVersions d ON d.deviceSessionID=ds.rowID
            WHERE ds.recordingID=?1),0)
        """
    )
    try statement.bind(recordingID, at: 1)
    guard try statement.step() else { throw ViewerStoreError.corruptStore }
    return Bounds(
      recordingUpperRowID: statement.int64(at: 0),
      recordingVersionUpperRowID: statement.int64(at: 1),
      installationAliasUpperRowID: statement.int64(at: 2),
      deviceSessionUpperRowID: statement.int64(at: 3),
      deviceVersionUpperRowID: statement.int64(at: 4),
      tombstoneUpperRowID: statement.int64(at: 5),
      gapUpperRowID: statement.int64(at: 6),
      dropUpperRowID: statement.int64(at: 7)
    )
  }

  private static func requireVisibleRecording(
    snapshot: ViewerDeviceCatalogSnapshot,
    database: OpaquePointer
  ) throws {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: """
        SELECT 1 FROM Recordings r
        WHERE r.rowID=?1 AND r.rowID<=?2
          AND EXISTS(SELECT 1 FROM RecordingVersions v
            WHERE v.recordingID=r.rowID AND v.rowID<=?3)
          AND NOT EXISTS(SELECT 1 FROM Tombstones t
            WHERE t.recordingID=r.rowID AND t.rowID<=?4)
        """
    )
    try statement.bind(snapshot.recordingID, at: 1)
    try statement.bind(snapshot.recordingUpperRowID, at: 2)
    try statement.bind(snapshot.recordingVersionUpperRowID, at: 3)
    try statement.bind(snapshot.tombstoneUpperRowID, at: 4)
    guard try statement.step() else { throw ViewerStoreError.invalidValue }
  }

  private static func maximumRowID(
    _ table: String,
    database: OpaquePointer
  ) throws -> Int64 {
    try ViewerStoreSchema.scalarInt64(
      "SELECT COALESCE(MAX(rowID),0) FROM \(table)",
      database: database
    )
  }

  private static func bounds(_ snapshot: ViewerRecordingCatalogSnapshot) -> Bounds {
    Bounds(
      recordingUpperRowID: snapshot.recordingUpperRowID,
      recordingVersionUpperRowID: snapshot.recordingVersionUpperRowID,
      installationAliasUpperRowID: snapshot.installationAliasUpperRowID,
      deviceSessionUpperRowID: snapshot.deviceSessionUpperRowID,
      deviceVersionUpperRowID: snapshot.deviceVersionUpperRowID,
      tombstoneUpperRowID: snapshot.tombstoneUpperRowID,
      gapUpperRowID: snapshot.gapUpperRowID,
      dropUpperRowID: snapshot.dropUpperRowID
    )
  }

  private static func bounds(_ snapshot: ViewerDeviceCatalogSnapshot) -> Bounds {
    Bounds(
      recordingUpperRowID: snapshot.recordingUpperRowID,
      recordingVersionUpperRowID: snapshot.recordingVersionUpperRowID,
      installationAliasUpperRowID: snapshot.installationAliasUpperRowID,
      deviceSessionUpperRowID: snapshot.deviceSessionUpperRowID,
      deviceVersionUpperRowID: snapshot.deviceVersionUpperRowID,
      tombstoneUpperRowID: snapshot.tombstoneUpperRowID,
      gapUpperRowID: snapshot.gapUpperRowID,
      dropUpperRowID: snapshot.dropUpperRowID
    )
  }

  private static func withReadTransaction<Value>(
    _ database: OpaquePointer,
    _ body: () throws -> Value
  ) throws -> Value {
    try ViewerSQLiteConnection.execute("BEGIN", on: database)
    do {
      let value = try body()
      try ViewerSQLiteConnection.execute("COMMIT", on: database)
      return value
    } catch {
      try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
      throw error
    }
  }

  private static func optionalString(
    _ statement: ViewerSQLiteStatement,
    at index: Int32
  ) -> String? {
    statement.isNull(at: index) ? nil : statement.string(at: index)
  }

  private static func optionalInt64(
    _ statement: ViewerSQLiteStatement,
    at index: Int32
  ) -> Int64? {
    statement.isNull(at: index) ? nil : statement.int64(at: index)
  }

  private static func fingerprint(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func fingerprint(_ values: [Int64]) -> String {
    fingerprint(values.map(String.init).joined(separator: ":"))
  }
}

private enum ViewerCatalogPlanGate {
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

extension ViewerCatalogPageDirection: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerCatalogPageDirection(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerCatalogPlanObservation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerCatalogPlanObservation(redacted, steps: \(details.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["stepCount": details.count], displayStyle: .struct)
  }
}

extension ViewerCatalogDeviceHint: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerCatalogDeviceHint(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerRecordingCatalogRow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRecordingCatalogRow(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerDeviceCatalogRow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerDeviceCatalogRow(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerRecordingCatalogSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRecordingCatalogSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerDeviceCatalogSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerDeviceCatalogSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerRecordingCatalogCursor: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRecordingCatalogCursor(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerDeviceCatalogCursor: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerDeviceCatalogCursor(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerRecordingCatalogPage: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRecordingCatalogPage(redacted, rows: \(rows.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["rowCount": rows.count], displayStyle: .struct)
  }
}

extension ViewerDeviceCatalogPage: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerDeviceCatalogPage(redacted, rows: \(rows.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["rowCount": rows.count], displayStyle: .struct)
  }
}

extension ViewerStoreCatalogService: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreCatalogService(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
