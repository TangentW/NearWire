import Foundation
import SQLite3

enum ViewerTextRules {
  static func recordingName(_ value: String) throws -> String {
    try validate(value, maximumScalars: 80, maximumBytes: 120, allowsLineFeedAndTab: false)
  }

  static func noteOrAnnotation(_ value: String) throws -> String {
    try validate(value, maximumScalars: 4_096, maximumBytes: 16 * 1_024, allowsLineFeedAndTab: true)
  }

  private static func validate(
    _ value: String,
    maximumScalars: Int,
    maximumBytes: Int,
    allowsLineFeedAndTab: Bool
  ) throws -> String {
    guard value.unicodeScalars.count <= maximumScalars, value.utf8.count <= maximumBytes else {
      throw ViewerStoreError.invalidValue
    }
    for scalar in value.unicodeScalars {
      if scalar.value == 0 { throw ViewerStoreError.invalidValue }
      if CharacterSet.controlCharacters.contains(scalar) {
        let allowed = allowsLineFeedAndTab && (scalar.value == 9 || scalar.value == 10)
        if !allowed { throw ViewerStoreError.invalidValue }
      }
    }
    return value
  }
}

struct ViewerRecordingRevision: Equatable, Sendable {
  let recordingID: Int64
  let revision: Int64
}

struct ViewerDeleteConfirmation: Equatable, Sendable {
  fileprivate let id: UUID
  let recordingID: Int64
  fileprivate let recordingRevision: Int64
  fileprivate let annotationUpperRowID: Int64
  fileprivate let expiresAt: ContinuousClock.Instant
}

final class ViewerStoreLeaseRegistry: @unchecked Sendable {
  enum Kind: Sendable { case query, export }
  struct Lease: Equatable, Sendable {
    let id: UUID
    let recordingID: Int64?
    let createdAt: ContinuousClock.Instant
    let expiresAt: ContinuousClock.Instant
    let absoluteExpiry: ContinuousClock.Instant
  }

  private let lock = NSLock()
  private var queryLeases: [UUID: Lease] = [:]
  private var exportLease: Lease?

  func acquireQuery(recordingID: Int64, now: ContinuousClock.Instant = .now) throws -> Lease {
    lock.lock()
    defer { lock.unlock() }
    expireLocked(now: now)
    guard queryLeases.count < 8 else { throw ViewerStoreError.busy }
    let lease = Lease(
      id: UUID(),
      recordingID: recordingID,
      createdAt: now,
      expiresAt: now + .seconds(60),
      absoluteExpiry: now + .seconds(600)
    )
    queryLeases[lease.id] = lease
    return lease
  }

  func touchQuery(_ lease: Lease, now: ContinuousClock.Instant = .now) throws -> Lease {
    lock.lock()
    defer { lock.unlock() }
    expireLocked(now: now)
    guard queryLeases[lease.id] == lease, now < lease.absoluteExpiry else {
      throw ViewerStoreError.cancelled
    }
    let refreshed = Lease(
      id: lease.id,
      recordingID: lease.recordingID,
      createdAt: lease.createdAt,
      expiresAt: min(now + .seconds(60), lease.absoluteExpiry),
      absoluteExpiry: lease.absoluteExpiry
    )
    queryLeases[lease.id] = refreshed
    return refreshed
  }

  func validateQuery(_ lease: Lease, now: ContinuousClock.Instant = .now) throws {
    lock.lock()
    defer { lock.unlock() }
    expireLocked(now: now)
    guard queryLeases[lease.id] == lease, now < lease.absoluteExpiry else {
      throw ViewerStoreError.cancelled
    }
  }

  func acquireExport(
    recordingID: Int64,
    now: ContinuousClock.Instant = .now
  ) throws -> Lease {
    lock.lock()
    defer { lock.unlock() }
    expireLocked(now: now)
    guard exportLease == nil else { throw ViewerStoreError.busy }
    let lease = Lease(
      id: UUID(),
      recordingID: recordingID,
      createdAt: now,
      expiresAt: now + .seconds(3_600),
      absoluteExpiry: now + .seconds(3_600)
    )
    exportLease = lease
    return lease
  }

  func validateExport(_ lease: Lease, now: ContinuousClock.Instant = .now) throws {
    lock.lock()
    defer { lock.unlock() }
    expireLocked(now: now)
    guard exportLease == lease, now < lease.absoluteExpiry else {
      throw ViewerStoreError.cancelled
    }
  }

  func release(_ lease: Lease) {
    lock.lock()
    queryLeases.removeValue(forKey: lease.id)
    if exportLease?.id == lease.id { exportLease = nil }
    lock.unlock()
  }

  func protects(recordingID: Int64, now: ContinuousClock.Instant = .now) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    expireLocked(now: now)
    return queryLeases.values.contains { $0.recordingID == recordingID }
      || exportLease?.recordingID == recordingID
  }

  func withDeletionLock<T>(
    now: ContinuousClock.Instant = .now,
    _ body: (_ protectsRecording: (Int64) -> Bool) throws -> T
  ) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    expireLocked(now: now)
    return try body { recordingID in
      self.queryLeases.values.contains { $0.recordingID == recordingID }
        || self.exportLease?.recordingID == recordingID
    }
  }

  private func expireLocked(now: ContinuousClock.Instant) {
    queryLeases = queryLeases.filter { now < $0.value.expiresAt && now < $0.value.absoluteExpiry }
    if let exportLease, now >= exportLease.expiresAt { self.exportLease = nil }
  }
}

final class ViewerStoreMaintenance: @unchecked Sendable {
  enum MutationPhase: Equatable, Sendable {
    case beforeBegin
    case beforeBody
    case beforeCommit
  }

  enum Trigger: Equatable, Sendable {
    case startup, settingsChanged, sessionClosed, threshold, explicit
  }

  private static let maximumTurns = 8
  private static let tombstoneSelectionLimit = 32
  private static let normalReclaimRowLimit = 1_024
  private static let normalReclaimByteLimit: Int64 = 4 * 1_024 * 1_024
  private static let oversizeReclaimByteLimit: Int64 = 41 * 1_024 * 1_024

  private let pool: ViewerSQLitePool
  private let leases: ViewerStoreLeaseRegistry
  private let configuration: @Sendable () -> ViewerStorageConfiguration
  private let activeRecordingIDs: @Sendable () -> Set<Int64>
  private let statusMetadata: ViewerStoreStatusMetadataBox
  private let statusSignal: ViewerStoreStatusSignal
  private let storeStateReporter: @Sendable (ViewerStoreStatus.State) -> Void
  private let recoveryPermitProvider:
    @Sendable (ViewerStoreRecoveryAction) -> ViewerStoreStateRelay.RecoveryPermit?
  private let automaticAuthorizationProvider:
    @Sendable () throws -> ViewerStoreStateRelay.WriteAuthorization?
  private let authorizationValidator:
    @Sendable (ViewerStoreStateRelay.WriteAuthorization) throws -> Void
  private let recoveryValidator: @Sendable (ViewerStoreStateRelay.RecoveryPermit) throws -> Void
  private let recoveryCompleter: @Sendable (ViewerStoreStateRelay.RecoveryPermit) throws -> Void
  private let mutationGate: @Sendable (MutationPhase) throws -> Void
  private let confirmationLock = NSLock()
  private var deleteConfirmations: [UUID: ViewerDeleteConfirmation] = [:]

  init(
    pool: ViewerSQLitePool,
    leases: ViewerStoreLeaseRegistry,
    configuration: @escaping @Sendable () -> ViewerStorageConfiguration,
    activeRecordingIDs: @escaping @Sendable () -> Set<Int64> = { [] },
    statusMetadata: ViewerStoreStatusMetadataBox = ViewerStoreStatusMetadataBox(),
    statusSignal: ViewerStoreStatusSignal = ViewerStoreStatusSignal(),
    storeStateReporter: @escaping @Sendable (ViewerStoreStatus.State) -> Void = { _ in },
    recoveryPermitProvider:
      @escaping @Sendable (ViewerStoreRecoveryAction) -> ViewerStoreStateRelay.RecoveryPermit? = {
        _ in nil
      },
    automaticAuthorizationProvider:
      @escaping @Sendable () throws -> ViewerStoreStateRelay.WriteAuthorization? = { nil },
    authorizationValidator:
      @escaping @Sendable (ViewerStoreStateRelay.WriteAuthorization) throws -> Void = { _ in },
    recoveryValidator:
      @escaping @Sendable (ViewerStoreStateRelay.RecoveryPermit) throws -> Void = { _ in },
    recoveryCompleter:
      @escaping @Sendable (ViewerStoreStateRelay.RecoveryPermit) throws -> Void = { _ in },
    mutationGate: @escaping @Sendable (MutationPhase) throws -> Void = { _ in }
  ) {
    self.pool = pool
    self.leases = leases
    self.configuration = configuration
    self.activeRecordingIDs = activeRecordingIDs
    self.statusMetadata = statusMetadata
    self.statusSignal = statusSignal
    self.storeStateReporter = storeStateReporter
    self.recoveryPermitProvider = recoveryPermitProvider
    self.automaticAuthorizationProvider = automaticAuthorizationProvider
    self.authorizationValidator = authorizationValidator
    self.recoveryValidator = recoveryValidator
    self.recoveryCompleter = recoveryCompleter
    self.mutationGate = mutationGate
  }

  func run(
    trigger: Trigger,
    nowWallMilliseconds: Int64,
    pendingReservationBytes: Int64 = 0,
    recoveryPermit: ViewerStoreStateRelay.RecoveryPermit? = nil
  ) throws {
    _ = trigger
    let authorization =
      try recoveryPermit.map(ViewerStoreStateRelay.WriteAuthorization.recovery)
      ?? automaticAuthorizationProvider()
    var category: ViewerStoreCleanupCategory = .noWork
    var changedRecordingIDs: Set<Int64> = []
    do {
      for _ in 0..<Self.maximumTurns {
        let tombstoned: Set<Int64>
        do {
          tombstoned = try selectTombstones(
            nowWallMilliseconds: nowWallMilliseconds,
            pendingReservationBytes: pendingReservationBytes,
            authorization: authorization
          )
        } catch let error as ViewerStoreError where error == .capacityExceeded {
          guard recoveryPermit == nil,
            try recoverScheduledCapacity(category: &category)
          else { throw error }
          continue
        }
        if !tombstoned.isEmpty {
          changedRecordingIDs.formUnion(tombstoned)
          category = .logicalDeletion
          continue
        }
        do {
          if try reclaimOneBatch(authorization: authorization) {
            category = .physicalReclaim
            continue
          }
        } catch let error as ViewerStoreError where error == .capacityExceeded {
          guard recoveryPermit == nil,
            try recoverScheduledCapacity(category: &category)
          else { throw error }
          continue
        }
        if try checkpointOneStep(authorization: authorization) {
          category = .checkpoint
          continue
        }
        if try reclaimFreePagesOneStep(authorization: authorization) {
          category = .freePageReclaim
          continue
        }
        break
      }
      statusMetadata.setCleanupCategory(category)
      statusSignal.publish(changedRecordingIDs: changedRecordingIDs)
    } catch {
      statusMetadata.setCleanupCategory(.failed)
      statusSignal.publish()
      throw error
    }
  }

  private func performFloorOnlyRecovery(
    category: inout ViewerStoreCleanupCategory,
    authorization: ViewerStoreStateRelay.WriteAuthorization?
  ) throws -> Bool {
    if try checkpointOneStep(authorization: authorization) {
      category = .checkpoint
      return true
    }
    if try reclaimFreePagesOneStep(authorization: authorization) {
      category = .freePageReclaim
      return true
    }
    return false
  }

  private func recoverScheduledCapacity(
    category: inout ViewerStoreCleanupCategory
  ) throws -> Bool {
    let permit = recoveryPermitProvider(.automaticCapacityRecovery)
    let authorization = permit.map(ViewerStoreStateRelay.WriteAuthorization.recovery)
    guard try performFloorOnlyRecovery(category: &category, authorization: authorization) else {
      return false
    }
    if let permit { try recoveryCompleter(permit) }
    return true
  }

  func updateRecording(
    _ target: ViewerRecordingRevision,
    name: String?,
    note: String?,
    pinned: Bool,
    wallMilliseconds: Int64
  ) throws -> ViewerRecordingRevision {
    let validName = try name.map(ViewerTextRules.recordingName)
    let validNote = try note.map(ViewerTextRules.noteOrAnnotation)
    let recoveryPermit = pinned ? nil : recoveryPermitProvider(.unpin)
    let outcome = try capacityCheckedWrite(
      plannedReservation: ViewerStoreQuota.structuralReservation,
      wallMilliseconds: wallMilliseconds,
      changedRecordingIDs: [target.recordingID],
      recoveryPermit: recoveryPermit
    ) { database in
      let current = try latestRevision(recordingID: target.recordingID, database: database)
      guard current == target.revision else { throw ViewerStoreError.busy }
      let lifecycle = try latestRecordingLifecycle(
        recordingID: target.recordingID,
        database: database
      )
      let next = current + 1
      let quota = ViewerStoreQuota.structuralReservation
      try addQuota(quota, recordingID: target.recordingID, database: database)
      let insert = try ViewerSQLiteStatement(
        database: database,
        sql:
          "INSERT INTO RecordingVersions(recordingID, revision, createdWallMs, name, note, pinned, state, endedWallMs, endedMonotonicNs, quotaBytes) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)"
      )
      try insert.bind(target.recordingID, at: 1)
      try insert.bind(next, at: 2)
      try insert.bind(wallMilliseconds, at: 3)
      if let validName { try insert.bind(validName, at: 4) } else { try insert.bindNull(at: 4) }
      if let validNote { try insert.bind(validNote, at: 5) } else { try insert.bindNull(at: 5) }
      try insert.bind(Int64(pinned ? 1 : 0), at: 6)
      try insert.bind(lifecycle.state, at: 7)
      if let value = lifecycle.endedWallMilliseconds {
        try insert.bind(value, at: 8)
      } else {
        try insert.bindNull(at: 8)
      }
      if let value = lifecycle.endedMonotonicNanoseconds {
        try insert.bind(value, at: 9)
      } else {
        try insert.bindNull(at: 9)
      }
      try insert.bind(quota, at: 10)
      _ = try insert.step()
      return (
        revision: ViewerRecordingRevision(recordingID: target.recordingID, revision: next),
        didUnpin: lifecycle.pinned && !pinned
      )
    }
    if outcome.didUnpin, let recoveryPermit { try? recoveryCompleter(recoveryPermit) }
    return outcome.revision
  }

  func appendAnnotation(
    recordingID: Int64,
    body: String,
    wallMilliseconds: Int64
  ) throws -> Int64 {
    try appendAnnotation(
      recordingID: recordingID,
      expectedRecordingRevision: nil,
      body: body,
      wallMilliseconds: wallMilliseconds
    )
  }

  func appendAnnotation(
    _ target: ViewerRecordingRevision,
    body: String,
    wallMilliseconds: Int64
  ) throws -> Int64 {
    try appendAnnotation(
      recordingID: target.recordingID,
      expectedRecordingRevision: target.revision,
      body: body,
      wallMilliseconds: wallMilliseconds
    )
  }

  private func appendAnnotation(
    recordingID: Int64,
    expectedRecordingRevision: Int64?,
    body: String,
    wallMilliseconds: Int64
  ) throws -> Int64 {
    let body = try ViewerTextRules.noteOrAnnotation(body)
    let plannedReservation = try ViewerStoreQuota.textReservation(body)
    return try capacityCheckedWrite(
      plannedReservation: plannedReservation,
      wallMilliseconds: wallMilliseconds,
      changedRecordingIDs: [recordingID]
    ) { database in
      if let expectedRecordingRevision {
        guard
          try latestRevision(recordingID: recordingID, database: database)
            == expectedRecordingRevision
        else { throw ViewerStoreError.busy }
      }
      let tombstone = try ViewerSQLiteStatement(
        database: database,
        sql: "SELECT 1 FROM Tombstones WHERE recordingID=?1 LIMIT 1"
      )
      try tombstone.bind(recordingID, at: 1)
      guard try tombstone.step() == false else { throw ViewerStoreError.busy }
      let revision = try nextRevision(
        table: "AnnotationVersions",
        ownerColumn: "recordingID",
        ownerID: recordingID,
        database: database
      )
      let quota = try ViewerStoreQuota.textReservation(body)
      try addQuota(quota, recordingID: recordingID, database: database)
      let insert = try ViewerSQLiteStatement(
        database: database,
        sql:
          "INSERT INTO AnnotationVersions(recordingID, revision, createdWallMs, body, quotaBytes) VALUES(?1, ?2, ?3, ?4, ?5)"
      )
      try insert.bind(recordingID, at: 1)
      try insert.bind(revision, at: 2)
      try insert.bind(wallMilliseconds, at: 3)
      try insert.bind(body, at: 4)
      try insert.bind(quota, at: 5)
      _ = try insert.step()
      return revision
    }
  }

  func prepareDelete(
    _ target: ViewerRecordingRevision,
    now: ContinuousClock.Instant = .now
  ) throws -> ViewerDeleteConfirmation {
    guard !activeRecordingIDs().contains(target.recordingID) else {
      throw ViewerStoreError.busy
    }
    let annotationUpperRowID = try pool.queryReader.run(budget: .query(now: now)) { database in
      guard
        try latestRevision(recordingID: target.recordingID, database: database)
          == target.revision,
        try latestRecordingLifecycle(recordingID: target.recordingID, database: database)
          .state != "active"
      else { throw ViewerStoreError.busy }
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: "SELECT COALESCE(MAX(rowID), 0) FROM AnnotationVersions WHERE recordingID=?1"
      )
      try statement.bind(target.recordingID, at: 1)
      guard try statement.step() else { throw ViewerStoreError.corruptStore }
      return statement.int64(at: 0)
    }
    let confirmation = ViewerDeleteConfirmation(
      id: UUID(),
      recordingID: target.recordingID,
      recordingRevision: target.revision,
      annotationUpperRowID: annotationUpperRowID,
      expiresAt: now + .seconds(60)
    )
    confirmationLock.lock()
    deleteConfirmations = deleteConfirmations.filter { now < $0.value.expiresAt }
    guard deleteConfirmations.count < 32 else {
      confirmationLock.unlock()
      throw ViewerStoreError.busy
    }
    deleteConfirmations[confirmation.id] = confirmation
    confirmationLock.unlock()
    return confirmation
  }

  func requestDelete(
    _ confirmation: ViewerDeleteConfirmation,
    now: ContinuousClock.Instant = .now,
    wallMilliseconds: Int64
  ) throws {
    let recoveryPermit = recoveryPermitProvider(.manualDelete)
    do {
      try consumeDeleteConfirmation(confirmation, now: now)
      guard !activeRecordingIDs().contains(confirmation.recordingID) else {
        throw ViewerStoreError.busy
      }
      try leases.withDeletionLock { protects in
        guard !protects(confirmation.recordingID) else { throw ViewerStoreError.busy }
        try pool.writer.run(
          failureHandler: { [self] error in
            reportInteractiveWriteFailure(error, includeCapacity: true)
          }
        ) { database in
          do {
            if let recoveryPermit { try recoveryValidator(recoveryPermit) }
            try pool.diskGuard.requireReserve(
              at: pool.paths.directory,
              plannedBytes: ViewerStoreQuota.structuralReservation
            )
            try mutationGate(.beforeBegin)
            try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
            do {
              try mutationGate(.beforeBody)
              guard
                try latestRevision(recordingID: confirmation.recordingID, database: database)
                  == confirmation.recordingRevision
              else { throw ViewerStoreError.busy }
              guard
                try latestRecordingLifecycle(
                  recordingID: confirmation.recordingID,
                  database: database
                ).state != "active"
              else { throw ViewerStoreError.busy }
              let annotation = try ViewerSQLiteStatement(
                database: database,
                sql: "SELECT COALESCE(MAX(rowID), 0) FROM AnnotationVersions WHERE recordingID=?1"
              )
              try annotation.bind(confirmation.recordingID, at: 1)
              guard try annotation.step() else { throw ViewerStoreError.corruptStore }
              let latestAnnotation = annotation.int64(at: 0)
              guard latestAnnotation == confirmation.annotationUpperRowID else {
                throw ViewerStoreError.busy
              }
              let statement = try ViewerSQLiteStatement(
                database: database,
                sql:
                  "INSERT INTO Tombstones(recordingID, createdWallMs, reason, expectedRevision, quotaBytes) VALUES(?1, ?2, 'manual', ?3, 0)"
              )
              try statement.bind(confirmation.recordingID, at: 1)
              try statement.bind(wallMilliseconds, at: 2)
              try statement.bind(confirmation.recordingRevision, at: 3)
              _ = try statement.step()
              try hideRecordingFromQuota(confirmation.recordingID, database: database)
              try mutationGate(.beforeCommit)
              try ViewerSQLiteConnection.execute("COMMIT", on: database)
            } catch {
              try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
              throw error
            }
          } catch { throw error }
        }
      }
    } catch {
      throw error
    }
    if let recoveryPermit { try? recoveryCompleter(recoveryPermit) }
    statusSignal.publish(changedRecordingIDs: [confirmation.recordingID])
  }

  private func consumeDeleteConfirmation(
    _ confirmation: ViewerDeleteConfirmation,
    now: ContinuousClock.Instant
  ) throws {
    confirmationLock.lock()
    defer { confirmationLock.unlock() }
    deleteConfirmations = deleteConfirmations.filter { now < $0.value.expiresAt }
    guard deleteConfirmations.removeValue(forKey: confirmation.id) == confirmation,
      now < confirmation.expiresAt
    else { throw ViewerStoreError.busy }
  }

  private func selectTombstones(
    nowWallMilliseconds: Int64,
    pendingReservationBytes: Int64,
    authorization: ViewerStoreStateRelay.WriteAuthorization?
  ) throws -> Set<Int64> {
    let config = configuration()
    let active = activeRecordingIDs()
    return try leases.withDeletionLock { protects in
      try scheduledWriterRun(authorization: authorization) { database in
        let quota = try ViewerStoreSchema.scalarInt64(
          "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
          database: database
        )
        let retentionCutoff = nowWallMilliseconds - Int64(config.historyRetentionDays) * 86_400_000
        var candidates: [(Int64, Int64)] = []
        let (projectedWithReservation, overflow) = quota.addingReportingOverflow(
          max(0, pendingReservationBytes)
        )
        var projectedQuota = overflow ? Int64.max : projectedWithReservation
        let capacityCleanupRequired = overflow || projectedQuota > config.capacityBytes
        let lowWater = config.capacityBytes * 85 / 100
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT r.rowID, r.liveQuotaBytes, v.endedWallMs FROM Recordings r JOIN RecordingVersions v ON v.recordingID=r.rowID WHERE v.state!='active' AND r.rowID NOT IN (SELECT recordingID FROM Tombstones) AND v.rowID=(SELECT MAX(v2.rowID) FROM RecordingVersions v2 WHERE v2.recordingID=r.rowID) AND v.pinned=0 AND (v.endedWallMs<=?1 OR ?2=1) ORDER BY CASE WHEN v.endedWallMs<=?1 THEN 0 ELSE 1 END, v.endedWallMs, r.rowID LIMIT ?3"
        )
        try statement.bind(retentionCutoff, at: 1)
        try statement.bind(Int64(capacityCleanupRequired ? 1 : 0), at: 2)
        try statement.bind(Int64(Self.tombstoneSelectionLimit), at: 3)
        while try statement.step() {
          let id = statement.int64(at: 0)
          let bytes = statement.int64(at: 1)
          let expired = !statement.isNull(at: 2) && statement.int64(at: 2) <= retentionCutoff
          if !active.contains(id), !protects(id),
            expired || (capacityCleanupRequired && projectedQuota > lowWater)
          {
            candidates.append((id, bytes))
            projectedQuota = max(0, projectedQuota - bytes)
          }
        }
        guard !candidates.isEmpty else { return [] }
        let (plannedBytes, planOverflow) = ViewerStoreQuota.structuralReservation
          .multipliedReportingOverflow(by: Int64(candidates.count))
        guard !planOverflow else { throw ViewerStoreError.capacityExceeded }
        try requireMaintenanceReserve(plannedBytes)
        try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
        do {
          let insert = try ViewerSQLiteStatement(
            database: database,
            sql:
              "INSERT OR IGNORE INTO Tombstones(recordingID, createdWallMs, reason, quotaBytes) VALUES(?1, ?2, ?3, 0)"
          )
          var hiddenQuota: Int64 = 0
          for (id, bytes) in candidates {
            try insert.bind(id, at: 1)
            try insert.bind(nowWallMilliseconds, at: 2)
            try insert.bind("maintenance", at: 3)
            _ = try insert.step()
            guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.busy }
            let (nextHidden, overflow) = hiddenQuota.addingReportingOverflow(bytes)
            guard !overflow else { throw ViewerStoreError.corruptStore }
            hiddenQuota = nextHidden
            let clear = try ViewerSQLiteStatement(
              database: database,
              sql: "UPDATE Recordings SET liveQuotaBytes=0 WHERE rowID=?1 AND liveQuotaBytes=?2"
            )
            try clear.bind(id, at: 1)
            try clear.bind(bytes, at: 2)
            _ = try clear.step()
            guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.busy }
            try insert.reset()
          }
          let updateQuota = try ViewerSQLiteStatement(
            database: database,
            sql:
              "UPDATE StoreMetadata SET integerValue=integerValue-?1 WHERE key='logicalQuotaBytes' AND integerValue>=?1"
          )
          try updateQuota.bind(hiddenQuota, at: 1)
          _ = try updateQuota.step()
          guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }
          try ViewerSQLiteConnection.execute("COMMIT", on: database)
          return Set(candidates.map(\.0))
        } catch {
          try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
          throw error
        }
      }
    }
  }

  private func reclaimOneBatch(
    authorization: ViewerStoreStateRelay.WriteAuthorization? = nil
  ) throws -> Bool {
    try scheduledWriterRun(authorization: authorization) { database in
      let head = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT recordingID, reclaimCursor FROM Tombstones WHERE reclaimCursor>=0 ORDER BY rowID LIMIT 1"
      )
      guard try head.step() else { return false }
      let recordingID = head.int64(at: 0)
      let phase = head.int64(at: 1)
      guard phase >= 0, phase <= 9 else {
        try requireMaintenanceReserve(ViewerStoreQuota.structuralReservation)
        try isolateImpossibleHead(recordingID: recordingID, database: database)
        return true
      }
      if phase > 0 {
        return try reclaimNonEventBatch(
          recordingID: recordingID,
          phase: phase,
          database: database
        )
      }
      let event = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT e.rowID,e.quotaBytes,COUNT(d.rowID),COALESCE(SUM(d.quotaBytes),0) FROM Events e LEFT JOIN EventDispositionVersions d ON d.eventID=e.rowID WHERE e.recordingID=?1 GROUP BY e.rowID ORDER BY e.rowID LIMIT ?2"
      )
      try event.bind(recordingID, at: 1)
      try event.bind(Int64(Self.normalReclaimRowLimit / 2 + 1), at: 2)
      var ids: [Int64] = []
      var quota: Int64 = 0
      var rowWork = 0
      while try event.step() {
        let dispositionCount = event.int64(at: 2)
        guard (0...2).contains(dispositionCount) else {
          try requireMaintenanceReserve(ViewerStoreQuota.structuralReservation)
          try isolateImpossibleHead(recordingID: recordingID, database: database)
          return true
        }
        let nextRowWork = 2 + Int(dispositionCount)  // Event, FTS trigger, and dispositions.
        let (nextQuota, quotaOverflow) = event.int64(at: 1).addingReportingOverflow(
          event.int64(at: 3)
        )
        guard !quotaOverflow, nextQuota >= 0 else { throw ViewerStoreError.corruptStore }
        if !ids.isEmpty,
          rowWork > Self.normalReclaimRowLimit - nextRowWork
            || quota > Self.normalReclaimByteLimit - nextQuota
        {
          break
        }
        if ids.isEmpty
          && (nextRowWork > Self.normalReclaimRowLimit
            || nextQuota > Self.normalReclaimByteLimit)
        {
          guard nextQuota <= Self.oversizeReclaimByteLimit else {
            try requireMaintenanceReserve(ViewerStoreQuota.structuralReservation)
            try isolateImpossibleHead(recordingID: recordingID, database: database)
            return true
          }
          ids = [event.int64(at: 0)]
          quota = nextQuota
          rowWork = nextRowWork
          break
        }
        ids.append(event.int64(at: 0))
        quota += nextQuota
        rowWork += nextRowWork
      }
      if !ids.isEmpty {
        try requireMaintenanceReserve(max(ViewerStoreQuota.structuralReservation, quota))
        try deleteEvents(ids: ids, database: database)
        return true
      }
      try requireMaintenanceReserve(ViewerStoreQuota.structuralReservation)
      try advanceToNextReclaimWork(recordingID: recordingID, from: 0, database: database)
      return true
    }
  }

  private func deleteEvents(ids: [Int64], database: OpaquePointer) throws {
    try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
    do {
      let placeholders = ids.map(String.init).joined(separator: ",")
      try ViewerSQLiteConnection.execute(
        "DELETE FROM EventDispositionVersions WHERE eventID IN (\(placeholders))",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "DELETE FROM Events WHERE rowID IN (\(placeholders))",
        on: database
      )
      try ViewerSQLiteConnection.execute("COMMIT", on: database)
    } catch {
      try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
      throw error
    }
  }

  private func reclaimNonEventBatch(
    recordingID: Int64,
    phase: Int64,
    database: OpaquePointer
  ) throws -> Bool {
    if phase == 9 {
      try requireMaintenanceReserve(ViewerStoreQuota.structuralReservation)
      try finalizeReclaim(recordingID: recordingID, database: database)
      return true
    }
    let source = try reclaimSource(phase: phase, recordingID: recordingID)

    let select = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT rowID, quotaBytes FROM \(source.table) WHERE \(source.predicate) ORDER BY rowID LIMIT ?1"
    )
    try select.bind(Int64(Self.normalReclaimRowLimit + 1), at: 1)
    var ids: [Int64] = []
    var bytes: Int64 = 0
    while try select.step(), ids.count < Self.normalReclaimRowLimit {
      let next = select.int64(at: 1)
      guard next >= 0 else { throw ViewerStoreError.corruptStore }
      if !ids.isEmpty && bytes > Self.normalReclaimByteLimit - next { break }
      guard next <= Self.normalReclaimByteLimit else {
        try requireMaintenanceReserve(ViewerStoreQuota.structuralReservation)
        try isolateImpossibleHead(recordingID: recordingID, database: database)
        return true
      }
      ids.append(select.int64(at: 0))
      bytes += next
    }
    guard !ids.isEmpty else {
      try requireMaintenanceReserve(ViewerStoreQuota.structuralReservation)
      try advanceToNextReclaimWork(
        recordingID: recordingID,
        from: phase,
        database: database
      )
      return true
    }
    try requireMaintenanceReserve(max(ViewerStoreQuota.structuralReservation, bytes))
    try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
    do {
      try ViewerSQLiteConnection.execute(
        "DELETE FROM \(source.table) WHERE rowID IN (\(ids.map(String.init).joined(separator: ",")))",
        on: database
      )
      guard sqlite3_changes(database) == ids.count else { throw ViewerStoreError.busy }
      try ViewerSQLiteConnection.execute("COMMIT", on: database)
      return true
    } catch {
      try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
      throw error
    }
  }

  private func advanceToNextReclaimWork(
    recordingID: Int64,
    from phase: Int64,
    database: OpaquePointer
  ) throws {
    var nextPhase = phase + 1
    while nextPhase < 9 {
      let source = try reclaimSource(phase: nextPhase, recordingID: recordingID)
      let exists = try ViewerStoreSchema.scalarInt64(
        "SELECT EXISTS(SELECT 1 FROM \(source.table) WHERE \(source.predicate) LIMIT 1)",
        database: database
      )
      if exists != 0 { break }
      nextPhase += 1
    }
    let update = try ViewerSQLiteStatement(
      database: database,
      sql: "UPDATE Tombstones SET reclaimCursor=?1 WHERE recordingID=?2 AND reclaimCursor=?3"
    )
    try update.bind(nextPhase, at: 1)
    try update.bind(recordingID, at: 2)
    try update.bind(phase, at: 3)
    _ = try update.step()
    guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.busy }
  }

  private func reclaimSource(
    phase: Int64,
    recordingID: Int64
  ) throws -> (table: String, predicate: String) {
    switch phase {
    case 1:
      return (
        "PolicyVersions",
        "deviceSessionID IN (SELECT rowID FROM DeviceSessions WHERE recordingID=\(recordingID))"
      )
    case 2:
      return (
        "DropVersions",
        "deviceSessionID IN (SELECT rowID FROM DeviceSessions WHERE recordingID=\(recordingID))"
      )
    case 3:
      return (
        "DeviceSessionVersions",
        "deviceSessionID IN (SELECT rowID FROM DeviceSessions WHERE recordingID=\(recordingID))"
      )
    case 4: return ("GapVersions", "recordingID=\(recordingID)")
    case 5: return ("AnnotationVersions", "recordingID=\(recordingID)")
    case 6: return ("RecordingVersions", "recordingID=\(recordingID)")
    case 7: return ("DeviceSessions", "recordingID=\(recordingID)")
    case 8: return ("InstallationAliases", "recordingID=\(recordingID)")
    default: throw ViewerStoreError.corruptStore
    }
  }

  private func finalizeReclaim(recordingID: Int64, database: OpaquePointer) throws {
    try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
    do {
      let childExists = try ViewerStoreSchema.scalarInt64(
        "SELECT EXISTS(SELECT 1 FROM Events WHERE recordingID=\(recordingID) LIMIT 1) + EXISTS(SELECT 1 FROM DeviceSessions WHERE recordingID=\(recordingID) LIMIT 1) + EXISTS(SELECT 1 FROM InstallationAliases WHERE recordingID=\(recordingID) LIMIT 1) + EXISTS(SELECT 1 FROM RecordingVersions WHERE recordingID=\(recordingID) LIMIT 1) + EXISTS(SELECT 1 FROM GapVersions WHERE recordingID=\(recordingID) LIMIT 1) + EXISTS(SELECT 1 FROM AnnotationVersions WHERE recordingID=\(recordingID) LIMIT 1)",
        database: database
      )
      guard childExists == 0 else { throw ViewerStoreError.corruptStore }
      try ViewerSQLiteConnection.execute(
        "DELETE FROM Tombstones WHERE recordingID=\(recordingID) AND reclaimCursor=9",
        on: database
      )
      guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.busy }
      try ViewerSQLiteConnection.execute(
        "DELETE FROM Recordings WHERE rowID=\(recordingID)", on: database)
      guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.busy }
      try ViewerSQLiteConnection.execute("COMMIT", on: database)
    } catch {
      try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
      throw error
    }
  }

  private func isolateImpossibleHead(recordingID: Int64, database: OpaquePointer) throws {
    let update = try ViewerSQLiteStatement(
      database: database,
      sql: "UPDATE Tombstones SET reclaimCursor=-1 WHERE recordingID=?1"
    )
    try update.bind(recordingID, at: 1)
    _ = try update.step()
  }

  func checkpointOneStep(
    authorization: ViewerStoreStateRelay.WriteAuthorization? = nil
  ) throws -> Bool {
    return try scheduledWriterRun(authorization: authorization) { database in
      let walSize = (try? pool.paths.wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      guard walSize > 32 else { return false }
      try requireMaintenanceReserve(0)
      var logFrames: Int32 = 0
      var checkpointed: Int32 = 0
      let result = sqlite3_wal_checkpoint_v2(
        database,
        nil,
        SQLITE_CHECKPOINT_PASSIVE,
        &logFrames,
        &checkpointed
      )
      guard result == SQLITE_OK || result == SQLITE_BUSY else {
        throw ViewerSQLiteConnection.map(result)
      }
      return result == SQLITE_OK && checkpointed > 0
    }
  }

  func reclaimFreePagesOneStep(
    authorization: ViewerStoreStateRelay.WriteAuthorization? = nil
  ) throws -> Bool {
    return try scheduledWriterRun(authorization: authorization) { database in
      let before = try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database)
      guard before > 0 else { return false }
      try requireMaintenanceReserve(0)
      try ViewerSQLiteConnection.execute("PRAGMA incremental_vacuum(64)", on: database)
      let after = try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database)
      guard after >= 0, after < before else { throw ViewerStoreError.unavailable }
      return true
    }
  }

  private func scheduledWriterRun<T>(
    authorization: ViewerStoreStateRelay.WriteAuthorization?,
    _ body: (OpaquePointer) throws -> T
  ) throws -> T {
    let failureHandler: (Error) -> Void = { [self] error in
      reportScheduledWriteFailureBeforeWriterRelease(error)
    }
    return try pool.writer.run(failureHandler: failureHandler) { database in
      if let authorization { try authorizationValidator(authorization) }
      return try body(database)
    }
  }

  private func reportScheduledWriteFailureBeforeWriterRelease(_ error: Error) {
    guard let storeError = error as? ViewerStoreError else {
      storeStateReporter(.writeFailed)
      return
    }
    switch ViewerStoreWriteFailureDisposition.classify(
      storeError,
      context: .interactiveMutation
    ) {
    case .capacityPaused:
      storeStateReporter(.capacityPaused)
    case .writeFailed:
      storeStateReporter(.writeFailed)
    case .operationLocal:
      break
    }
  }

  private func latestRevision(recordingID: Int64, database: OpaquePointer) throws -> Int64 {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: "SELECT MAX(revision) FROM RecordingVersions WHERE recordingID=?1"
    )
    try statement.bind(recordingID, at: 1)
    guard try statement.step(), !statement.isNull(at: 0) else {
      throw ViewerStoreError.invalidValue
    }
    return statement.int64(at: 0)
  }

  private func latestRecordingLifecycle(
    recordingID: Int64,
    database: OpaquePointer
  ) throws -> (
    state: String,
    pinned: Bool,
    endedWallMilliseconds: Int64?,
    endedMonotonicNanoseconds: Int64?
  ) {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT state, pinned, endedWallMs, endedMonotonicNs FROM RecordingVersions WHERE recordingID=?1 ORDER BY revision DESC LIMIT 1"
    )
    try statement.bind(recordingID, at: 1)
    guard try statement.step() else { throw ViewerStoreError.invalidValue }
    return (
      statement.string(at: 0),
      statement.int64(at: 1) != 0,
      statement.isNull(at: 2) ? nil : statement.int64(at: 2),
      statement.isNull(at: 3) ? nil : statement.int64(at: 3)
    )
  }

  private func nextRevision(
    table: String,
    ownerColumn: String,
    ownerID: Int64,
    database: OpaquePointer
  ) throws -> Int64 {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: "SELECT COALESCE(MAX(revision), 0) + 1 FROM \(table) WHERE \(ownerColumn)=?1"
    )
    try statement.bind(ownerID, at: 1)
    guard try statement.step() else { throw ViewerStoreError.corruptStore }
    return statement.int64(at: 0)
  }

  private func addQuota(
    _ bytes: Int64,
    recordingID: Int64,
    database: OpaquePointer
  ) throws {
    let config = configuration()
    let current = try ViewerStoreSchema.scalarInt64(
      "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
      database: database
    )
    let (next, overflow) = current.addingReportingOverflow(bytes)
    guard !overflow, next <= config.capacityBytes else { throw ViewerStoreError.capacityExceeded }
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: "UPDATE StoreMetadata SET integerValue=?1 WHERE key='logicalQuotaBytes'"
    )
    try statement.bind(next, at: 1)
    _ = try statement.step()
    let recording = try ViewerSQLiteStatement(
      database: database,
      sql:
        "UPDATE Recordings SET liveQuotaBytes=liveQuotaBytes+?1 WHERE rowID=?2 AND rowID NOT IN (SELECT recordingID FROM Tombstones)"
    )
    try recording.bind(bytes, at: 1)
    try recording.bind(recordingID, at: 2)
    _ = try recording.step()
    guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.busy }
  }

  private func capacityCheckedWrite<T>(
    plannedReservation: Int64,
    wallMilliseconds: Int64,
    changedRecordingIDs: Set<Int64>,
    recoveryPermit: ViewerStoreStateRelay.RecoveryPermit? = nil,
    _ body: (OpaquePointer) throws -> T
  ) throws -> T {
    var attemptedRecovery = false
    var authorization =
      try recoveryPermit.map(ViewerStoreStateRelay.WriteAuthorization.recovery)
      ?? automaticAuthorizationProvider()
    while true {
      do {
        let failureHandler: (Error) -> Void = { [self] error in
          reportInteractiveWriteFailure(error, includeCapacity: true)
        }
        let result = try pool.writer.run(failureHandler: failureHandler) { database in
          do {
            if let authorization { try authorizationValidator(authorization) }
            let current = try ViewerStoreSchema.scalarInt64(
              "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
              database: database
            )
            let (projected, overflow) = current.addingReportingOverflow(plannedReservation)
            guard plannedReservation >= 0, !overflow,
              projected <= configuration().capacityBytes
            else { throw ViewerStoreError.capacityExceeded }
            try pool.diskGuard.requireReserve(
              at: pool.paths.directory,
              plannedBytes: plannedReservation
            )
            try mutationGate(.beforeBegin)
            try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
            do {
              try mutationGate(.beforeBody)
              let result = try body(database)
              try mutationGate(.beforeCommit)
              try ViewerSQLiteConnection.execute("COMMIT", on: database)
              return result
            } catch {
              try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
              throw error
            }
          } catch { throw error }
        }
        statusSignal.publish(changedRecordingIDs: changedRecordingIDs)
        return result
      } catch let error as ViewerStoreError
        where error == .capacityExceeded
        && !attemptedRecovery
        && recoveryPermit == nil
      {
        attemptedRecovery = true
        let capacityPermit = recoveryPermitProvider(.automaticCapacityRecovery)
        do {
          try run(
            trigger: .threshold,
            nowWallMilliseconds: wallMilliseconds,
            pendingReservationBytes: plannedReservation,
            recoveryPermit: capacityPermit
          )
          if let capacityPermit { try recoveryCompleter(capacityPermit) }
          authorization = try automaticAuthorizationProvider()
        } catch {
          throw error
        }
      } catch let error as ViewerStoreError {
        throw error
      } catch {
        throw error
      }
    }
  }

  private func requireMaintenanceReserve(_ plannedBytes: Int64) throws {
    try pool.diskGuard.requireReserve(at: pool.paths.directory, plannedBytes: plannedBytes)
  }

  private func reportInteractiveWriteFailure(_ error: Error, includeCapacity: Bool) {
    guard let storeError = error as? ViewerStoreError else {
      storeStateReporter(.writeFailed)
      return
    }
    switch ViewerStoreWriteFailureDisposition.classify(
      storeError,
      context: .interactiveMutation
    ) {
    case .capacityPaused:
      if includeCapacity { storeStateReporter(.capacityPaused) }
    case .writeFailed:
      storeStateReporter(.writeFailed)
    case .operationLocal:
      break
    }
  }

  private func hideRecordingFromQuota(_ recordingID: Int64, database: OpaquePointer) throws {
    let read = try ViewerSQLiteStatement(
      database: database,
      sql: "SELECT liveQuotaBytes FROM Recordings WHERE rowID=?1"
    )
    try read.bind(recordingID, at: 1)
    guard try read.step() else { throw ViewerStoreError.invalidValue }
    let bytes = read.int64(at: 0)
    let clear = try ViewerSQLiteStatement(
      database: database,
      sql: "UPDATE Recordings SET liveQuotaBytes=0 WHERE rowID=?1 AND liveQuotaBytes=?2"
    )
    try clear.bind(recordingID, at: 1)
    try clear.bind(bytes, at: 2)
    _ = try clear.step()
    guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.busy }
    let total = try ViewerSQLiteStatement(
      database: database,
      sql:
        "UPDATE StoreMetadata SET integerValue=integerValue-?1 WHERE key='logicalQuotaBytes' AND integerValue>=?1"
    )
    try total.bind(bytes, at: 1)
    _ = try total.step()
    guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }
  }
}

final class ViewerStoreMaintenanceOwner: @unchecked Sendable {
  private struct RecoveryRequest {
    let permit: ViewerStoreStateRelay.RecoveryPermit
    let settingsRevision: UInt64?
  }

  private static let committedByteThreshold: Int64 = 8 * 1_024 * 1_024
  private static let periodicIntervalNanoseconds: UInt64 = 15 * 60 * 1_000_000_000

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.nearwire.viewer.store-maintenance")
  private let maintenance: ViewerStoreMaintenance
  private let scheduler: ViewerAdmissionScheduler
  private let recoveryPermitProvider:
    @Sendable (ViewerStoreRecoveryAction) -> ViewerStoreStateRelay.RecoveryPermit?
  private let recoveryCompleter: @Sendable (ViewerStoreStateRelay.RecoveryPermit) throws -> Void
  private let recoveryPublicationGate: @Sendable () -> Void
  private let executionGate: @Sendable () -> Void
  private var committedBytes: Int64 = 0
  private var scheduled = false
  private var dirty = false
  private var pendingRecoveryRequest: RecoveryRequest?
  private var pendingTrigger: ViewerStoreMaintenance.Trigger?
  private var latestSettingsRevision: UInt64 = 0
  private var lifecycleGeneration: UInt64 = 0
  private var periodicGeneration: UInt64 = 0
  private var periodicWake: Task<Void, Never>?
  private var runtimeActive = false
  private var ending = false
  private var stopped = false

  init(
    maintenance: ViewerStoreMaintenance,
    scheduler: ViewerAdmissionScheduler,
    recoveryPermitProvider:
      @escaping @Sendable (ViewerStoreRecoveryAction) -> ViewerStoreStateRelay.RecoveryPermit? = {
        _ in nil
      },
    recoveryCompleter:
      @escaping @Sendable (ViewerStoreStateRelay.RecoveryPermit) throws -> Void = { _ in },
    recoveryPublicationGate: @escaping @Sendable () -> Void = {},
    executionGate: @escaping @Sendable () -> Void = {}
  ) {
    self.maintenance = maintenance
    self.scheduler = scheduler
    self.recoveryPermitProvider = recoveryPermitProvider
    self.recoveryCompleter = recoveryCompleter
    self.recoveryPublicationGate = recoveryPublicationGate
    self.executionGate = executionGate
  }

  func trigger(
    _ trigger: ViewerStoreMaintenance.Trigger,
    wallMilliseconds: Int64,
    recoveryAction: ViewerStoreRecoveryAction? = nil,
    settingsRevision: UInt64? = nil
  ) {
    let recoveryPermit = recoveryAction.flatMap(recoveryPermitProvider)
    lock.lock()
    guard !stopped, !ending else {
      lock.unlock()
      return
    }
    let effectiveSettingsRevision: UInt64?
    if trigger == .settingsChanged {
      if let settingsRevision {
        guard settingsRevision >= latestSettingsRevision else {
          lock.unlock()
          return
        }
        latestSettingsRevision = settingsRevision
      } else {
        latestSettingsRevision =
          latestSettingsRevision == UInt64.max ? 1 : latestSettingsRevision + 1
      }
      effectiveSettingsRevision = latestSettingsRevision
    } else {
      effectiveSettingsRevision = nil
    }
    let recoveryRequest = recoveryPermit.map {
      RecoveryRequest(permit: $0, settingsRevision: effectiveSettingsRevision)
    }
    if scheduled {
      dirty = true
      if trigger == .settingsChanged {
        pendingTrigger = .settingsChanged
        pendingRecoveryRequest = recoveryRequest
      } else {
        if pendingTrigger == nil { pendingTrigger = trigger }
        if let recoveryRequest { pendingRecoveryRequest = recoveryRequest }
      }
      lock.unlock()
      return
    }
    scheduled = true
    let generation = lifecycleGeneration
    lock.unlock()
    queue.async { [weak self] in
      self?.run(
        trigger: trigger,
        wallMilliseconds: wallMilliseconds,
        recoveryRequest: recoveryRequest,
        lifecycleGeneration: generation
      )
    }
  }

  func noteCommittedBytes(_ bytes: Int64, wallMilliseconds: Int64) {
    guard bytes > 0 else { return }
    lock.lock()
    let (sum, overflow) = committedBytes.addingReportingOverflow(bytes)
    committedBytes = overflow ? Int64.max : sum
    let crossed = committedBytes >= Self.committedByteThreshold
    if crossed { committedBytes = 0 }
    lock.unlock()
    if crossed { trigger(.threshold, wallMilliseconds: wallMilliseconds) }
  }

  func runtimeStarted() {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    ending = false
    runtimeActive = true
    periodicGeneration = periodicGeneration == UInt64.max ? 1 : periodicGeneration + 1
    let generation = periodicGeneration
    periodicWake?.cancel()
    periodicWake = makePeriodicWake(generation: generation)
    lock.unlock()
  }

  func runtimeEnded() {
    lock.lock()
    runtimeActive = false
    ending = true
    lifecycleGeneration = lifecycleGeneration == UInt64.max ? 1 : lifecycleGeneration + 1
    periodicGeneration = periodicGeneration == UInt64.max ? 1 : periodicGeneration + 1
    periodicWake?.cancel()
    periodicWake = nil
    dirty = false
    pendingRecoveryRequest = nil
    pendingTrigger = nil
    lock.unlock()
  }

  func waitForQuiescence() {
    queue.sync {}
  }

  func close() {
    lock.lock()
    stopped = true
    runtimeActive = false
    ending = true
    lifecycleGeneration = lifecycleGeneration == UInt64.max ? 1 : lifecycleGeneration + 1
    periodicGeneration = periodicGeneration == UInt64.max ? 1 : periodicGeneration + 1
    periodicWake?.cancel()
    periodicWake = nil
    dirty = false
    pendingRecoveryRequest = nil
    pendingTrigger = nil
    lock.unlock()
    queue.sync {}
  }

  private func makePeriodicWake(generation: UInt64) -> Task<Void, Never> {
    Task { [weak self, scheduler] in
      let now = scheduler.now()
      let (deadline, overflow) = now.addingReportingOverflow(
        Self.periodicIntervalNanoseconds
      )
      guard !overflow else { return }
      do { try await scheduler.sleep(untilNanoseconds: deadline) } catch { return }
      guard !Task.isCancelled, let self else { return }
      self.periodicFired(generation: generation)
    }
  }

  private func periodicFired(generation: UInt64) {
    lock.lock()
    guard runtimeActive, periodicGeneration == generation else {
      lock.unlock()
      return
    }
    periodicGeneration = periodicGeneration == UInt64.max ? 1 : periodicGeneration + 1
    let nextGeneration = periodicGeneration
    periodicWake = makePeriodicWake(generation: nextGeneration)
    lock.unlock()
    trigger(
      .threshold,
      wallMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    )
  }

  private func run(
    trigger: ViewerStoreMaintenance.Trigger,
    wallMilliseconds: Int64,
    recoveryRequest: RecoveryRequest?,
    lifecycleGeneration: UInt64
  ) {
    lock.lock()
    guard !stopped, !ending, self.lifecycleGeneration == lifecycleGeneration else {
      scheduled = false
      dirty = false
      pendingRecoveryRequest = nil
      pendingTrigger = nil
      lock.unlock()
      return
    }
    lock.unlock()
    executionGate()
    let succeeded: Bool
    do {
      try maintenance.run(
        trigger: trigger,
        nowWallMilliseconds: wallMilliseconds,
        recoveryPermit: recoveryRequest?.permit
      )
      succeeded = true
    } catch {
      succeeded = false
    }
    lock.lock()
    if stopped || ending || self.lifecycleGeneration != lifecycleGeneration {
      scheduled = false
      dirty = false
      pendingRecoveryRequest = nil
      pendingTrigger = nil
      lock.unlock()
      return
    }
    let recoveryIsCurrent =
      recoveryRequest?.settingsRevision.map {
        $0 == latestSettingsRevision
      } ?? true
    if succeeded, recoveryIsCurrent, let recoveryRequest {
      lock.unlock()
      recoveryPublicationGate()
      lock.lock()
      let recoveryStillCurrent =
        recoveryRequest.settingsRevision.map {
          $0 == latestSettingsRevision
        } ?? true
      guard !stopped, !ending, self.lifecycleGeneration == lifecycleGeneration else {
        scheduled = false
        dirty = false
        pendingRecoveryRequest = nil
        pendingTrigger = nil
        lock.unlock()
        return
      }
      if recoveryStillCurrent { try? recoveryCompleter(recoveryRequest.permit) }
    }
    if dirty {
      dirty = false
      let nextRecoveryRequest = pendingRecoveryRequest
      let nextTrigger = pendingTrigger ?? .threshold
      pendingRecoveryRequest = nil
      pendingTrigger = nil
      lock.unlock()
      queue.async { [weak self] in
        self?.run(
          trigger: nextTrigger,
          wallMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
          recoveryRequest: nextRecoveryRequest,
          lifecycleGeneration: lifecycleGeneration
        )
      }
      return
    }
    scheduled = false
    lock.unlock()
  }
}

extension ViewerRecordingRevision: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRecordingRevision(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerDeleteConfirmation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerDeleteConfirmation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoreLeaseRegistry: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreLeaseRegistry(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerStoreLeaseRegistry.Lease: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreLease(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoreMaintenance: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreMaintenance(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerStoreMaintenanceOwner: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreMaintenanceOwner(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
