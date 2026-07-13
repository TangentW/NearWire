import Foundation
@_spi(NearWireInternal) import NearWireCore
import SQLite3

enum ViewerStoreSchema {
  static let currentVersion: Int64 = 2

  static func migrate(
    _ connection: ViewerSQLiteConnection,
    control: ViewerStoreMigrationControl? = nil
  ) throws {
    let version = try connection.run { database in
      try scalarInt64("PRAGMA user_version", database: database)
    }
    guard version <= currentVersion else { throw ViewerStoreError.unsupportedSchema }
    guard version >= 0 else { throw ViewerStoreError.corruptStore }
    do {
      switch version {
      case 0:
        try connection.run { database in
          guard
            try scalarInt64(
              "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table','view','trigger') AND name NOT LIKE 'sqlite_%'",
              database: database
            ) == 0
          else { throw ViewerStoreError.corruptStore }
          try ViewerSQLiteConnection.execute("PRAGMA auto_vacuum=INCREMENTAL", on: database)
          try ViewerSQLiteConnection.execute("VACUUM", on: database)
          try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
          do {
            try ViewerSQLiteConnection.execute(schemaVersion1, on: database)
            for statement in schemaVersion2IndexStatements {
              try ViewerSQLiteConnection.execute(statement, on: database)
            }
            try ViewerSQLiteConnection.execute("PRAGMA user_version=2", on: database)
            try probe(
              database,
              requiredTemporaryStore: 1,
              requiredCacheSize: -32 * 1_024
            )
            try probeExplorerPlans(database)
            try ViewerSQLiteConnection.execute("COMMIT", on: database)
          } catch {
            try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
            throw error
          }
        }
      case 1:
        try control?.prepareForVersionOne()
        let progressCheck: () -> ViewerStoreError? = { control?.progressFailure() }
        try connection.run(
          progressInstructionInterval: ViewerStoreMigrationControl.progressInstructionInterval,
          progressCheck: progressCheck
        ) { database in
          try probe(
            database,
            requiresExplorerIndexes: false,
            requiredTemporaryStore: 1,
            requiredCacheSize: -32 * 1_024
          )
          try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
          do {
            for (offset, statement) in schemaVersion2IndexStatements.enumerated() {
              try control?.beforeIndex(offset + 1)
              try ViewerSQLiteConnection.execute(statement, on: database)
            }
            try control?.beforeValidation()
            try ViewerSQLiteConnection.execute("PRAGMA user_version=2", on: database)
            try probe(
              database,
              requiredTemporaryStore: 1,
              requiredCacheSize: -32 * 1_024
            )
            try probeExplorerPlans(database)
            try ViewerSQLiteConnection.execute("COMMIT", on: database)
          } catch {
            try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
            throw error
          }
        }
      case 2:
        try connection.run { database in
          try probe(
            database,
            requiredTemporaryStore: 1,
            requiredCacheSize: -32 * 1_024
          )
          try probeExplorerPlans(database)
        }
      default:
        throw ViewerStoreError.unsupportedSchema
      }
    } catch {
      control?.reportFailure(error)
      throw error
    }
  }

  static func probe(
    _ database: OpaquePointer,
    requiresExplorerIndexes: Bool = true,
    requiredTemporaryStore: Int64 = 2,
    requiredCacheSize: Int64 = -8 * 1_024
  ) throws {
    guard try scalarInt64("PRAGMA foreign_keys", database: database) == 1,
      try scalarInt64("PRAGMA secure_delete", database: database) == 1,
      try scalarInt64("PRAGMA temp_store", database: database) == requiredTemporaryStore,
      try scalarInt64("PRAGMA cache_size", database: database) == requiredCacheSize,
      try scalarInt64("PRAGMA auto_vacuum", database: database) == 2
    else { throw ViewerStoreError.unavailable }
    var required = [
      "Recordings", "RecordingVersions", "DeviceSessions", "DeviceSessionVersions",
      "InstallationAliases", "Events", "EventDispositionVersions", "PolicyVersions",
      "DropVersions", "GapVersions", "AnnotationVersions", "StoreMetadata", "Tombstones",
      "EventSearch",
    ]
    if requiresExplorerIndexes {
      required.append(contentsOf: [
        "EventCausalityLookup", "GapTimelineAllDevices", "GapTimelineByDevice",
      ])
    }
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: "SELECT 1 FROM sqlite_master WHERE name=?1 LIMIT 1"
    )
    for name in required {
      try statement.bind(name, at: 1)
      guard try statement.step() else { throw ViewerStoreError.corruptStore }
      try statement.reset()
    }
    let requiredColumns: [String: Set<String>] = [
      "Recordings": [
        "rowID", "logicalID", "startedWallMs", "startedMonotonicNs", "durableStartReason",
        "quotaBytes", "liveQuotaBytes",
      ],
      "RecordingVersions": [
        "rowID", "recordingID", "revision", "createdWallMs", "name", "note", "pinned",
        "state", "endedWallMs", "endedMonotonicNs", "quotaBytes",
      ],
      "InstallationAliases": [
        "rowID", "recordingID", "installationID", "ordinal", "quotaBytes",
      ],
      "DeviceSessions": [
        "rowID", "logicalID", "recordingID", "installationAliasID", "connectionOrdinal",
        "applicationIdentifier", "applicationVersion", "startedWallMs", "startedMonotonicNs",
        "quotaBytes",
      ],
      "DeviceSessionVersions": [
        "rowID", "deviceSessionID", "revision", "createdWallMs", "displayName", "state",
        "partialHistory", "endedWallMs", "endedMonotonicNs", "quotaBytes",
      ],
      "Events": [
        "rowID", "recordingID", "deviceSessionID", "direction", "wireSequence", "eventUUID",
        "eventType", "contentJSON", "createdWallMs", "viewerWallMs", "originMonotonicNs",
        "viewerMonotonicNs", "priority", "ttlMs", "schemaVersion", "deterministicBytes",
        "correlationEventUUID", "replyToEventUUID", "quotaBytes",
      ],
      "Tombstones": [
        "rowID", "recordingID", "createdWallMs", "reason", "expectedRevision",
        "reclaimCursor", "quotaBytes",
      ],
    ]
    for (table, expected) in requiredColumns {
      let columns = try tableColumns(table, database: database)
      guard expected.isSubset(of: columns) else { throw ViewerStoreError.corruptStore }
    }
    let jsonProbe = try ViewerSQLiteStatement(
      database: database,
      sql: "SELECT json_valid('{\"nearwire\":true}')"
    )
    guard try jsonProbe.step(), jsonProbe.int64(at: 0) == 1 else {
      throw ViewerStoreError.unavailable
    }
    let ftsProbe = try ViewerSQLiteStatement(
      database: database,
      sql: "SELECT COUNT(*) FROM EventSearch WHERE EventSearch MATCH ?1"
    )
    try ftsProbe.bind("\"nearwire-feature-probe\"", at: 1)
    guard try ftsProbe.step() else { throw ViewerStoreError.unavailable }
  }

  static func probeExplorerPlans(_ database: OpaquePointer) throws {
    let requiredPlans = [
      (
        "SELECT e.rowID FROM Events e WHERE e.recordingID=1 AND e.deviceSessionID=1 AND e.eventUUID='00000000-0000-0000-0000-000000000000' AND e.rowID<=9223372036854775807 ORDER BY e.rowID LIMIT 9",
        "EventCausalityLookup"
      ),
      (
        "SELECT g.rowID FROM GapVersions g WHERE g.recordingID=1 AND g.rowID<=9223372036854775807 ORDER BY g.lastViewerWallMs,g.rowID LIMIT 32",
        "GapTimelineAllDevices"
      ),
      (
        "SELECT g.rowID FROM GapVersions g WHERE g.recordingID=1 AND g.deviceSessionID=1 AND g.rowID<=9223372036854775807 ORDER BY g.lastViewerWallMs,g.rowID LIMIT 32",
        "GapTimelineByDevice"
      ),
    ]
    for (query, expectedIndex) in requiredPlans {
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: "EXPLAIN QUERY PLAN \(query)"
      )
      var details: [String] = []
      while try statement.step() { details.append(statement.string(at: 3)) }
      guard details.contains(where: { $0.contains(expectedIndex) }),
        !details.contains(where: { $0.contains("USE TEMP B-TREE") })
      else { throw ViewerStoreError.unavailable }
    }
  }

  static func scalarInt64(_ sql: String, database: OpaquePointer) throws -> Int64 {
    let statement = try ViewerSQLiteStatement(database: database, sql: sql)
    guard try statement.step() else { throw ViewerStoreError.corruptStore }
    return statement.int64(at: 0)
  }

  static func scalarString(_ sql: String, database: OpaquePointer) throws -> String {
    let statement = try ViewerSQLiteStatement(database: database, sql: sql)
    guard try statement.step() else { throw ViewerStoreError.corruptStore }
    return statement.string(at: 0)
  }

  private static func tableColumns(_ table: String, database: OpaquePointer) throws -> Set<String> {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: "PRAGMA table_info(\"\(table)\")"
    )
    var columns: Set<String> = []
    while try statement.step() { columns.insert(statement.string(at: 1)) }
    return columns
  }

  private static let schemaVersion1 = """
    CREATE TABLE StoreMetadata(
      key TEXT PRIMARY KEY NOT NULL,
      integerValue INTEGER,
      textValue TEXT,
      blobValue BLOB,
      CHECK ((integerValue IS NOT NULL) + (textValue IS NOT NULL) + (blobValue IS NOT NULL) = 1)
    ) STRICT;

    CREATE TABLE Recordings(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      logicalID TEXT NOT NULL UNIQUE,
      startedWallMs INTEGER NOT NULL,
      startedMonotonicNs INTEGER NOT NULL,
      durableStartReason TEXT NOT NULL,
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0),
      liveQuotaBytes INTEGER NOT NULL CHECK(liveQuotaBytes >= 0)
    ) STRICT;

    CREATE TABLE RecordingVersions(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      recordingID INTEGER NOT NULL REFERENCES Recordings(rowID),
      revision INTEGER NOT NULL CHECK(revision > 0),
      createdWallMs INTEGER NOT NULL,
      name TEXT,
      note TEXT,
      pinned INTEGER NOT NULL CHECK(pinned IN (0, 1)),
      state TEXT NOT NULL CHECK(state IN ('active', 'closed', 'recoveredAfterInterruption')),
      endedWallMs INTEGER,
      endedMonotonicNs INTEGER,
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0),
      UNIQUE(recordingID, revision)
    ) STRICT;

    CREATE TABLE InstallationAliases(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      recordingID INTEGER NOT NULL REFERENCES Recordings(rowID),
      installationID TEXT NOT NULL,
      ordinal INTEGER NOT NULL CHECK(ordinal > 0),
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0)
      ,UNIQUE(recordingID, installationID)
      ,UNIQUE(recordingID, ordinal)
    ) STRICT;

    CREATE TABLE DeviceSessions(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      logicalID TEXT NOT NULL UNIQUE,
      recordingID INTEGER NOT NULL REFERENCES Recordings(rowID),
      installationAliasID INTEGER NOT NULL REFERENCES InstallationAliases(rowID),
      connectionOrdinal INTEGER NOT NULL CHECK(connectionOrdinal > 0),
      applicationIdentifier TEXT,
      applicationVersion TEXT,
      startedWallMs INTEGER NOT NULL,
      startedMonotonicNs INTEGER NOT NULL,
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0),
      UNIQUE(recordingID, connectionOrdinal)
    ) STRICT;

    CREATE TABLE DeviceSessionVersions(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      deviceSessionID INTEGER NOT NULL REFERENCES DeviceSessions(rowID),
      revision INTEGER NOT NULL CHECK(revision > 0),
      createdWallMs INTEGER NOT NULL,
      displayName TEXT,
      state TEXT NOT NULL CHECK(state IN ('active', 'closed', 'recoveredAfterInterruption')),
      partialHistory INTEGER NOT NULL CHECK(partialHistory IN (0, 1)),
      endedWallMs INTEGER,
      endedMonotonicNs INTEGER,
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0),
      UNIQUE(deviceSessionID, revision)
    ) STRICT;

    CREATE TABLE Events(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      recordingID INTEGER NOT NULL REFERENCES Recordings(rowID),
      deviceSessionID INTEGER NOT NULL REFERENCES DeviceSessions(rowID),
      direction TEXT NOT NULL CHECK(direction IN ('appToViewer', 'viewerToApp')),
      wireSequence INTEGER NOT NULL CHECK(wireSequence >= 0),
      eventUUID TEXT NOT NULL,
      eventType TEXT NOT NULL,
      contentJSON BLOB NOT NULL,
      createdWallMs INTEGER NOT NULL,
      viewerWallMs INTEGER NOT NULL,
      originMonotonicNs INTEGER NOT NULL CHECK(originMonotonicNs >= 0),
      viewerMonotonicNs INTEGER NOT NULL CHECK(viewerMonotonicNs >= 0),
      priority TEXT NOT NULL,
      ttlMs INTEGER NOT NULL CHECK(ttlMs > 0),
      schemaVersion INTEGER NOT NULL CHECK(schemaVersion > 0),
      deterministicBytes INTEGER NOT NULL CHECK(deterministicBytes >= 0),
      correlationEventUUID TEXT,
      replyToEventUUID TEXT,
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0),
      UNIQUE(recordingID, deviceSessionID, direction, wireSequence)
    ) STRICT;

    CREATE TABLE EventDispositionVersions(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      eventID INTEGER NOT NULL REFERENCES Events(rowID),
      sequence INTEGER NOT NULL CHECK(sequence IN (0, 1)),
      disposition TEXT NOT NULL CHECK(disposition IN ('buffered','transportAdmitted','consumerAccepted','expired','overflowDisplaced','sessionEnded')),
      createdWallMs INTEGER NOT NULL,
      viewerMonotonicNs INTEGER NOT NULL,
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0),
      UNIQUE(eventID, sequence)
    ) STRICT;

    CREATE UNIQUE INDEX EventTerminalDisposition
      ON EventDispositionVersions(eventID)
      WHERE disposition IN ('consumerAccepted', 'expired', 'overflowDisplaced', 'sessionEnded');

    CREATE TABLE PolicyVersions(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      deviceSessionID INTEGER NOT NULL REFERENCES DeviceSessions(rowID),
      sequence INTEGER NOT NULL,
      createdWallMs INTEGER NOT NULL,
      policyJSON BLOB NOT NULL,
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0),
      UNIQUE(deviceSessionID, sequence)
    ) STRICT;

    CREATE TABLE DropVersions(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      deviceSessionID INTEGER NOT NULL REFERENCES DeviceSessions(rowID),
      sequence INTEGER NOT NULL,
      createdWallMs INTEGER NOT NULL,
      reason TEXT NOT NULL,
      count INTEGER NOT NULL CHECK(count > 0),
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0),
      UNIQUE(deviceSessionID, sequence)
    ) STRICT;

    CREATE TABLE GapVersions(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      recordingID INTEGER NOT NULL REFERENCES Recordings(rowID),
      deviceSessionID INTEGER REFERENCES DeviceSessions(rowID),
      sequence INTEGER NOT NULL,
      namespace TEXT NOT NULL CHECK(namespace IN ('coordinator','transition')),
      revision INTEGER NOT NULL CHECK(revision > 0),
      createdWallMs INTEGER NOT NULL,
      reason TEXT NOT NULL,
      firstViewerWallMs INTEGER NOT NULL,
      lastViewerWallMs INTEGER NOT NULL,
      directions TEXT NOT NULL CHECK(directions IN ('unknown','appToViewer','viewerToApp','both')),
      firstWireSequence INTEGER,
      lastWireSequence INTEGER,
      count INTEGER NOT NULL CHECK(count > 0),
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0),
      UNIQUE(recordingID, deviceSessionID, sequence, namespace, revision)
    ) STRICT;

    CREATE TABLE AnnotationVersions(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      recordingID INTEGER NOT NULL REFERENCES Recordings(rowID),
      revision INTEGER NOT NULL CHECK(revision > 0),
      createdWallMs INTEGER NOT NULL,
      body TEXT NOT NULL,
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0),
      UNIQUE(recordingID, revision)
    ) STRICT;

    CREATE TABLE Tombstones(
      rowID INTEGER PRIMARY KEY AUTOINCREMENT,
      recordingID INTEGER NOT NULL UNIQUE REFERENCES Recordings(rowID),
      createdWallMs INTEGER NOT NULL,
      reason TEXT NOT NULL,
      expectedRevision INTEGER,
      reclaimCursor INTEGER NOT NULL DEFAULT 0,
      quotaBytes INTEGER NOT NULL CHECK(quotaBytes >= 0)
    ) STRICT;

    CREATE VIRTUAL TABLE EventSearch USING fts5(
      eventType,
      contentJSON,
      content='Events',
      content_rowid='rowID',
      tokenize='unicode61 remove_diacritics 0'
    );

    CREATE TRIGGER EventSearchInsert AFTER INSERT ON Events BEGIN
      INSERT INTO EventSearch(rowid, eventType, contentJSON)
      VALUES (new.rowID, new.eventType, CAST(new.contentJSON AS TEXT));
    END;

    CREATE TRIGGER EventSearchDelete BEFORE DELETE ON Events BEGIN
      INSERT INTO EventSearch(EventSearch, rowid, eventType, contentJSON)
      VALUES ('delete', old.rowID, old.eventType, CAST(old.contentJSON AS TEXT));
    END;

    CREATE INDEX EventTimelineForward
      ON Events(recordingID, viewerMonotonicNs, rowID);
    CREATE INDEX EventTimelineByDevice
      ON Events(recordingID, deviceSessionID, viewerMonotonicNs, rowID);
    CREATE INDEX EventTypeTimeline
      ON Events(recordingID, eventType, viewerMonotonicNs, rowID);
    CREATE INDEX RecordingStartOrder ON Recordings(startedWallMs, rowID);
    CREATE INDEX DeviceRecordingOrder ON DeviceSessions(recordingID, rowID);
    CREATE INDEX DispositionEventOrder ON EventDispositionVersions(eventID, rowID);
    CREATE INDEX TombstoneReclaimOrder ON Tombstones(rowID, recordingID);

    INSERT INTO StoreMetadata(key, integerValue) VALUES ('logicalQuotaBytes', 0);
    """

  static let schemaVersion2IndexStatements = [
    "CREATE INDEX EventCausalityLookup ON Events(recordingID, deviceSessionID, eventUUID, rowID)",
    "CREATE INDEX GapTimelineAllDevices ON GapVersions(recordingID, lastViewerWallMs, rowID)",
    "CREATE INDEX GapTimelineByDevice ON GapVersions(recordingID, deviceSessionID, lastViewerWallMs, rowID)",
  ]
}

enum ViewerCanonicalJSON {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try encoder.encode(value)
  }
}

enum ViewerStoreQuota {
  static let eventMetadataReservation: Int64 = 1_024
  static let structuralReservation: Int64 = 512

  static func eventPipelineReservation(canonicalEventBytes: Int) throws -> Int {
    guard canonicalEventBytes >= 0, eventMetadataReservation <= Int64(Int.max) else {
      throw ViewerStoreError.invalidValue
    }
    let (total, overflow) = canonicalEventBytes.addingReportingOverflow(
      Int(eventMetadataReservation)
    )
    guard !overflow else { throw ViewerStoreError.invalidValue }
    return total
  }

  static func eventReservation(canonicalEventBytes: Int) throws -> Int64 {
    let bytes = Int64(canonicalEventBytes)
    let (doubled, overflow) = bytes.multipliedReportingOverflow(by: 2)
    let (total, additionOverflow) = doubled.addingReportingOverflow(eventMetadataReservation)
    guard !overflow, !additionOverflow, total >= 0 else { throw ViewerStoreError.invalidValue }
    return total
  }

  static func textReservation(_ value: String) throws -> Int64 {
    let bytes = Int64(value.utf8.count)
    let (total, overflow) = bytes.addingReportingOverflow(structuralReservation)
    guard !overflow else { throw ViewerStoreError.invalidValue }
    return total
  }
}
