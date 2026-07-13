import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport
import SQLite3

struct ViewerRecordingHandle: Equatable, Hashable, Sendable {
  let logicalID: UUID
  let rowID: Int64
}

struct ViewerDeviceSessionHandle: Equatable, Hashable, Sendable {
  let logicalID: UUID
  let rowID: Int64
  let recordingID: Int64
  let installationOrdinal: Int64
  let connectionOrdinal: Int64
}

enum ViewerStoredDisposition: String, Sendable {
  case buffered
  case transportAdmitted
  case consumerAccepted
  case expired
  case overflowDisplaced
  case sessionEnded
}

struct ViewerPreparedEventObservation: Sendable {
  let recording: ViewerRecordingHandle
  let device: ViewerDeviceSessionHandle
  let envelope: EventEnvelope
  let viewerMonotonicNanoseconds: UInt64
  let viewerWallMilliseconds: Int64
  let canonicalContent: Data
  let deterministicEventBytes: Int
  let quotaBytes: Int64
  let initialDisposition: ViewerStoredDisposition?

  init(
    recording: ViewerRecordingHandle,
    device: ViewerDeviceSessionHandle,
    event: WireReceivedEvent
  ) throws {
    self.recording = recording
    self.device = device
    envelope = event.envelope
    viewerMonotonicNanoseconds = event.receivedAtNanoseconds
    viewerWallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    canonicalContent = try event.envelope.content.deterministicData()
    deterministicEventBytes = event.deterministicEncodedByteCount
    quotaBytes = try ViewerStoreQuota.eventReservation(canonicalEventBytes: deterministicEventBytes)
    initialDisposition = .consumerAccepted
  }

  init(
    recording: ViewerRecordingHandle,
    device: ViewerDeviceSessionHandle,
    envelope: EventEnvelope,
    viewerMonotonicNanoseconds: UInt64,
    viewerWallMilliseconds: Int64? = nil,
    deterministicEventBytes: Int,
    initialDisposition: ViewerStoredDisposition?
  ) throws {
    self.recording = recording
    self.device = device
    self.envelope = envelope
    self.viewerMonotonicNanoseconds = viewerMonotonicNanoseconds
    self.viewerWallMilliseconds =
      viewerWallMilliseconds
      ?? Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    canonicalContent = try envelope.content.deterministicData()
    guard deterministicEventBytes >= 0 else { throw ViewerStoreError.invalidValue }
    self.deterministicEventBytes = deterministicEventBytes
    quotaBytes = try ViewerStoreQuota.eventReservation(canonicalEventBytes: deterministicEventBytes)
    self.initialDisposition = initialDisposition
  }
}

extension ViewerPreparedEventObservation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerPreparedEventObservation(redacted, bytes: \(deterministicEventBytes))"
  }

  var debugDescription: String { description }

  var customMirror: Mirror {
    Mirror(
      self,
      children: ["deterministicEventBytes": deterministicEventBytes],
      displayStyle: .struct
    )
  }
}

private enum ViewerDurableMetadataRules {
  static func installationID(_ value: String) throws -> String {
    try validate(value, maximumScalars: 256, maximumBytes: 512)
  }

  static func displayName(_ value: String) throws -> String {
    try validate(value, maximumScalars: 120, maximumBytes: 512)
  }

  static func applicationIdentifier(_ value: String) throws -> String {
    try validate(value, maximumScalars: 256, maximumBytes: 512)
  }

  static func applicationVersion(_ value: String) throws -> String {
    try validate(value, maximumScalars: 120, maximumBytes: 256)
  }

  private static func validate(
    _ value: String,
    maximumScalars: Int,
    maximumBytes: Int
  ) throws -> String {
    guard !value.isEmpty, value.unicodeScalars.count <= maximumScalars,
      value.utf8.count <= maximumBytes,
      value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { throw ViewerStoreError.invalidValue }
    return value
  }
}

enum ViewerStructuralObservation: Sendable {
  case closeDevice(ViewerDeviceSessionHandle, wallMilliseconds: Int64, monotonicNanoseconds: UInt64)
  case closeRecording(ViewerRecordingHandle, wallMilliseconds: Int64, monotonicNanoseconds: UInt64)
  case disposition(
    recording: ViewerRecordingHandle,
    device: ViewerDeviceSessionHandle,
    direction: EventDirection,
    wireSequence: UInt64,
    value: ViewerStoredDisposition,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  )
  case policy(
    device: ViewerDeviceSessionHandle,
    sequence: UInt64,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64,
    policyJSON: Data
  )
  case drop(
    device: ViewerDeviceSessionHandle,
    sequence: UInt64,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64,
    reason: String,
    count: Int64
  )
  case gap(
    recording: ViewerRecordingHandle,
    device: ViewerDeviceSessionHandle?,
    sequence: UInt64,
    reason: String,
    count: Int64,
    firstWallMilliseconds: Int64,
    lastWallMilliseconds: Int64,
    directions: String,
    firstWireSequence: UInt64?,
    lastWireSequence: UInt64?
  )
}

extension ViewerStructuralObservation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStructuralObservation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

struct ViewerStoreStatus: Equatable, Sendable {
  enum State: String, Equatable, Sendable {
    case available
    case writeFailed
    case capacityPaused
    case unavailable
  }

  let state: State
  let capacityBytes: Int64
  let logicalQuotaBytes: Int64
  let allocatedFootprintBytes: Int64
  let oldestHistoryMilliseconds: Int64?
  let pinnedQuotaBytes: Int64
  let estimatedRetainedDurationMilliseconds: Int64?
  let lastCleanupCategory: ViewerStoreCleanupCategory
}

enum ViewerStoreCleanupCategory: String, Equatable, Sendable {
  case none
  case noWork
  case logicalDeletion
  case physicalReclaim
  case checkpoint
  case freePageReclaim
  case failed
}

final class ViewerStoreStatusMetadataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var cleanupCategory: ViewerStoreCleanupCategory = .none

  func setCleanupCategory(_ value: ViewerStoreCleanupCategory) {
    lock.lock()
    cleanupCategory = value
    lock.unlock()
  }

  func loadCleanupCategory() -> ViewerStoreCleanupCategory {
    lock.lock()
    defer { lock.unlock() }
    return cleanupCategory
  }
}

struct ViewerStoreChangeSnapshot: Equatable, Sendable {
  let changedRecordingIDs: [Int64]
  let eventUpperRowID: Int64
  let status: ViewerStoreStatus
}

extension ViewerStoreChangeSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreChangeSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

final class ViewerStoreStatusSignal: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.nearwire.viewer.store-status")
  private var handler: (@Sendable (ViewerStoreChangeSnapshot) -> Void)?
  private var snapshotProvider: (@Sendable () -> ViewerStoreChangeSnapshot?)?
  private var scheduled = false
  private var pending: ViewerStoreChangeSnapshot?

  func setHandler(_ handler: @escaping @Sendable (ViewerStoreChangeSnapshot) -> Void) {
    lock.lock()
    self.handler = handler
    lock.unlock()
  }

  func setSnapshotProvider(
    _ provider: @escaping @Sendable () -> ViewerStoreChangeSnapshot?
  ) {
    lock.lock()
    snapshotProvider = provider
    lock.unlock()
  }

  func publish(changedRecordingIDs: Set<Int64> = []) {
    lock.lock()
    let provider = snapshotProvider
    lock.unlock()
    var snapshot =
      provider?()
      ?? ViewerStoreChangeSnapshot(
        changedRecordingIDs: [],
        eventUpperRowID: 0,
        status: ViewerStoreStatus(
          state: .unavailable,
          capacityBytes: 0,
          logicalQuotaBytes: 0,
          allocatedFootprintBytes: 0,
          oldestHistoryMilliseconds: nil,
          pinnedQuotaBytes: 0,
          estimatedRetainedDurationMilliseconds: nil,
          lastCleanupCategory: .none
        )
      )
    snapshot = ViewerStoreChangeSnapshot(
      changedRecordingIDs: Array(changedRecordingIDs).sorted().prefix(32).map { $0 },
      eventUpperRowID: snapshot.eventUpperRowID,
      status: snapshot.status
    )
    lock.lock()
    if let existing = pending {
      let mergedIDs = Set(existing.changedRecordingIDs).union(snapshot.changedRecordingIDs)
      snapshot = ViewerStoreChangeSnapshot(
        changedRecordingIDs: Array(mergedIDs).sorted().prefix(32).map { $0 },
        eventUpperRowID: max(existing.eventUpperRowID, snapshot.eventUpperRowID),
        status: snapshot.status
      )
    }
    pending = snapshot
    if scheduled {
      lock.unlock()
      return
    }
    scheduled = true
    lock.unlock()
    queue.async { [weak self] in self?.deliver() }
  }

  private func deliver() {
    lock.lock()
    let handler = handler
    let snapshot = pending
    pending = nil
    lock.unlock()
    if let snapshot { handler?(snapshot) }
    lock.lock()
    if pending != nil {
      lock.unlock()
      queue.async { [weak self] in self?.deliver() }
    } else {
      scheduled = false
      lock.unlock()
    }
  }
}

final class ViewerEventStore: @unchecked Sendable {
  private let pool: ViewerSQLitePool
  private let configuration: @Sendable () -> ViewerStorageConfiguration
  private let writeGate: @Sendable () throws -> Void
  private let automaticWriteAuthorizationObserver: @Sendable () -> Void
  let writeStateRelay: ViewerStoreStateRelay
  private let stateLock = NSLock()
  private var state: ViewerStoreStatus.State = .available
  private var stateTransitionSequence: UInt64 = 0
  private let recoveryLock = NSLock()
  private var capacityRecovery:
    (@Sendable (Int64, ViewerStoreStateRelay.RecoveryPermit) throws -> Void)?
  private let statusMetadata: ViewerStoreStatusMetadataBox
  private let statusSignal: ViewerStoreStatusSignal

  init(
    pool: ViewerSQLitePool,
    configuration: @escaping @Sendable () -> ViewerStorageConfiguration,
    writeGate: @escaping @Sendable () throws -> Void = {},
    automaticWriteAuthorizationObserver: @escaping @Sendable () -> Void = {},
    writeStateRelay: ViewerStoreStateRelay = ViewerStoreStateRelay(),
    statusMetadata: ViewerStoreStatusMetadataBox = ViewerStoreStatusMetadataBox(),
    statusSignal: ViewerStoreStatusSignal = ViewerStoreStatusSignal()
  ) {
    self.pool = pool
    self.configuration = configuration
    self.writeGate = writeGate
    self.automaticWriteAuthorizationObserver = automaticWriteAuthorizationObserver
    self.writeStateRelay = writeStateRelay
    self.statusMetadata = statusMetadata
    self.statusSignal = statusSignal
    statusSignal.setSnapshotProvider { [weak self] in self?.changeSnapshot() }
    writeStateRelay.bind(eventStore: self)
  }

  func setCapacityRecovery(
    _ recovery: @escaping @Sendable (Int64, ViewerStoreStateRelay.RecoveryPermit) throws -> Void
  ) {
    recoveryLock.lock()
    capacityRecovery = recovery
    recoveryLock.unlock()
  }

  func beginRecording(
    logicalID: UUID = UUID(),
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64,
    reason: String,
    recoveryPermit: ViewerStoreStateRelay.RecoveryPermit? = nil
  ) throws -> ViewerRecordingHandle {
    return try writeTransaction(
      recoveryPermit: recoveryPermit,
      plan: { _ in 2 * ViewerStoreQuota.structuralReservation },
      changedRecordingIDs: { [$0.rowID] }
    ) { database in
      let insert = try ViewerSQLiteStatement(
        database: database,
        sql:
          "INSERT INTO Recordings(logicalID, startedWallMs, startedMonotonicNs, durableStartReason, quotaBytes, liveQuotaBytes) VALUES(?1, ?2, ?3, ?4, ?5, 0)"
      )
      let quota = ViewerStoreQuota.structuralReservation
      try insert.bind(logicalID.uuidString.lowercased(), at: 1)
      try insert.bind(wallMilliseconds, at: 2)
      try insert.bind(checkedInt64(monotonicNanoseconds), at: 3)
      try insert.bind(reason, at: 4)
      try insert.bind(quota, at: 5)
      _ = try insert.step()
      let rowID = sqlite3_last_insert_rowid(database)
      try reserveQuota(quota, recordingID: rowID, database: database)
      try insertRecordingVersion(
        recordingID: rowID,
        revision: 1,
        wallMilliseconds: wallMilliseconds,
        name: nil,
        note: nil,
        pinned: false,
        state: "active",
        endedWallMilliseconds: nil,
        endedMonotonicNanoseconds: nil,
        database: database
      )
      return ViewerRecordingHandle(logicalID: logicalID, rowID: rowID)
    }
  }

  func beginDeviceSession(
    recording: ViewerRecordingHandle,
    installationID: String,
    logicalID: UUID = UUID(),
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64,
    partialHistory: Bool,
    displayName: String?,
    applicationIdentifier: String? = nil,
    applicationVersion: String? = nil,
    recoveryPermit: ViewerStoreStateRelay.RecoveryPermit? = nil
  ) throws -> ViewerDeviceSessionHandle {
    let installationID = try ViewerDurableMetadataRules.installationID(installationID)
    let displayName = try displayName.map(ViewerDurableMetadataRules.displayName)
    let applicationIdentifier = try applicationIdentifier.map(
      ViewerDurableMetadataRules.applicationIdentifier
    )
    let applicationVersion = try applicationVersion.map(
      ViewerDurableMetadataRules.applicationVersion
    )
    return try writeTransaction(
      recoveryPermit: recoveryPermit,
      plan: { database in
        let existing = try ViewerSQLiteStatement(
          database: database,
          sql: "SELECT 1 FROM InstallationAliases WHERE recordingID=?1 AND installationID=?2"
        )
        try existing.bind(recording.rowID, at: 1)
        try existing.bind(installationID, at: 2)
        let aliasQuota = try existing.step() ? 0 : ViewerStoreQuota.textReservation(installationID)
        return try Self.checkedReservationSum(
          aliasQuota,
          2 * ViewerStoreQuota.structuralReservation
        )
      },
      changedRecordingIDs: { [$0.recordingID] }
    ) { database in
      let alias = try installationAlias(
        recordingID: recording.rowID,
        installationID: installationID,
        database: database
      )
      let ordinal = try nextInt64(
        "SELECT COALESCE(MAX(connectionOrdinal), 0) + 1 FROM DeviceSessions WHERE recordingID=?1",
        binding: recording.rowID,
        database: database
      )
      let quota = ViewerStoreQuota.structuralReservation
      try reserveQuota(quota, recordingID: recording.rowID, database: database)
      let insert = try ViewerSQLiteStatement(
        database: database,
        sql:
          "INSERT INTO DeviceSessions(logicalID, recordingID, installationAliasID, connectionOrdinal, applicationIdentifier, applicationVersion, startedWallMs, startedMonotonicNs, quotaBytes) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"
      )
      try insert.bind(logicalID.uuidString.lowercased(), at: 1)
      try insert.bind(recording.rowID, at: 2)
      try insert.bind(alias.rowID, at: 3)
      try insert.bind(ordinal, at: 4)
      if let applicationIdentifier {
        try insert.bind(applicationIdentifier, at: 5)
      } else {
        try insert.bindNull(at: 5)
      }
      if let applicationVersion {
        try insert.bind(applicationVersion, at: 6)
      } else {
        try insert.bindNull(at: 6)
      }
      try insert.bind(wallMilliseconds, at: 7)
      try insert.bind(checkedInt64(monotonicNanoseconds), at: 8)
      try insert.bind(quota, at: 9)
      _ = try insert.step()
      let rowID = sqlite3_last_insert_rowid(database)
      try insertDeviceVersion(
        deviceSessionID: rowID,
        recordingID: recording.rowID,
        revision: 1,
        wallMilliseconds: wallMilliseconds,
        displayName: displayName,
        state: "active",
        partialHistory: partialHistory,
        endedWallMilliseconds: nil,
        endedMonotonicNanoseconds: nil,
        database: database
      )
      return ViewerDeviceSessionHandle(
        logicalID: logicalID,
        rowID: rowID,
        recordingID: recording.rowID,
        installationOrdinal: alias.ordinal,
        connectionOrdinal: ordinal
      )
    }
  }

  @discardableResult
  func appendEvent(_ observation: ViewerPreparedEventObservation) throws -> Int64 {
    guard let result = try appendEvents([observation]).first else {
      throw ViewerStoreError.unavailable
    }
    return result
  }

  func appendEvents(_ observations: [ViewerPreparedEventObservation]) throws -> [Int64] {
    guard !observations.isEmpty, observations.count <= 256 else {
      throw ViewerStoreError.invalidValue
    }
    let changedRecordingIDs = Set(observations.map { $0.recording.rowID })
    return try writeTransaction(
      plan: { database in
        try observations.reduce(Int64(0)) { total, observation in
          try Self.checkedReservationSum(
            total,
            self.plannedEventReservation(observation, database: database)
          )
        }
      }, changedRecordingIDs: { _ in changedRecordingIDs }
    ) { database in
      try observations.map { try appendEvent($0, database: database) }
    }
  }

  func appendStructural(_ observation: ViewerStructuralObservation) throws {
    try validateStructuralObservation(observation)
    let changedRecordingID = recordingID(of: observation)
    try writeTransaction(
      plan: { database in
        try self.plannedStructuralReservation(observation, database: database)
      }, changedRecordingIDs: { _ in [changedRecordingID] }
    ) { database in
      switch observation {
      case .closeDevice(let device, let wall, let monotonic):
        guard
          try latestState(
            table: "DeviceSessionVersions",
            ownerColumn: "deviceSessionID",
            ownerID: device.rowID,
            database: database
          ) == "active"
        else { return }
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql:
            "INSERT INTO DeviceSessionVersions(deviceSessionID, revision, createdWallMs, displayName, state, partialHistory, endedWallMs, endedMonotonicNs, quotaBytes) SELECT ?1, COALESCE(MAX(revision),0)+1, ?2, (SELECT displayName FROM DeviceSessionVersions WHERE deviceSessionID=?1 ORDER BY revision DESC LIMIT 1), 'closed', (SELECT partialHistory FROM DeviceSessionVersions WHERE deviceSessionID=?1 ORDER BY revision DESC LIMIT 1), ?2, ?3, ?4 FROM DeviceSessionVersions WHERE deviceSessionID=?1 HAVING (SELECT state FROM DeviceSessionVersions WHERE deviceSessionID=?1 ORDER BY revision DESC LIMIT 1)='active'"
        )
        let quota = ViewerStoreQuota.structuralReservation
        try reserveQuota(quota, recordingID: device.recordingID, database: database)
        try insert.bind(device.rowID, at: 1)
        try insert.bind(wall, at: 2)
        try insert.bind(checkedInt64(monotonic), at: 3)
        try insert.bind(quota, at: 4)
        _ = try insert.step()
        guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }
      case .closeRecording(let recording, let wall, let monotonic):
        guard
          try latestState(
            table: "RecordingVersions",
            ownerColumn: "recordingID",
            ownerID: recording.rowID,
            database: database
          ) == "active"
        else { return }
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql:
            "INSERT INTO RecordingVersions(recordingID, revision, createdWallMs, name, note, pinned, state, endedWallMs, endedMonotonicNs, quotaBytes) SELECT ?1, COALESCE(MAX(revision),0)+1, ?2, (SELECT name FROM RecordingVersions WHERE recordingID=?1 ORDER BY revision DESC LIMIT 1), (SELECT note FROM RecordingVersions WHERE recordingID=?1 ORDER BY revision DESC LIMIT 1), (SELECT pinned FROM RecordingVersions WHERE recordingID=?1 ORDER BY revision DESC LIMIT 1), 'closed', ?2, ?3, ?4 FROM RecordingVersions WHERE recordingID=?1 HAVING (SELECT state FROM RecordingVersions WHERE recordingID=?1 ORDER BY revision DESC LIMIT 1)='active'"
        )
        let quota = ViewerStoreQuota.structuralReservation
        try reserveQuota(quota, recordingID: recording.rowID, database: database)
        try insert.bind(recording.rowID, at: 1)
        try insert.bind(wall, at: 2)
        try insert.bind(checkedInt64(monotonic), at: 3)
        try insert.bind(quota, at: 4)
        _ = try insert.step()
        guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }
      case .disposition(
        let recording,
        let device,
        let direction,
        let wireSequence,
        let value,
        let wall,
        let monotonic
      ):
        let event = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT rowID FROM Events WHERE recordingID=?1 AND deviceSessionID=?2 AND direction=?3 AND wireSequence=?4"
        )
        try event.bind(recording.rowID, at: 1)
        try event.bind(device.rowID, at: 2)
        try event.bind(direction.rawValue, at: 3)
        try event.bind(checkedInt64(wireSequence), at: 4)
        guard try event.step() else {
          try appendGapVersion(
            recording: recording,
            device: device,
            sequence: wireSequence,
            namespace: "transition",
            reason: "missingInitialEvent.\(value.rawValue)",
            count: 1,
            firstWallMilliseconds: wall,
            lastWallMilliseconds: wall,
            directions: direction.rawValue,
            firstWireSequence: wireSequence,
            lastWireSequence: wireSequence,
            database: database
          )
          return
        }
        let eventID = event.int64(at: 0)
        let existingTerminal = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT disposition FROM EventDispositionVersions WHERE eventID=?1 AND disposition IN ('consumerAccepted','expired','overflowDisplaced','sessionEnded') LIMIT 1"
        )
        try existingTerminal.bind(eventID, at: 1)
        if try existingTerminal.step() {
          guard existingTerminal.string(at: 0) == value.rawValue else {
            throw ViewerStoreError.corruptStore
          }
          return
        }
        let quota = ViewerStoreQuota.structuralReservation
        try reserveQuota(quota, recordingID: recording.rowID, database: database)
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql:
            "INSERT INTO EventDispositionVersions(eventID, sequence, disposition, createdWallMs, viewerMonotonicNs, quotaBytes) SELECT ?1, COALESCE(MAX(sequence),0)+1, ?2, ?3, ?4, ?5 FROM EventDispositionVersions WHERE eventID=?1"
        )
        try insert.bind(eventID, at: 1)
        try insert.bind(value.rawValue, at: 2)
        try insert.bind(wall, at: 3)
        try insert.bind(checkedInt64(monotonic), at: 4)
        try insert.bind(quota, at: 5)
        _ = try insert.step()
        guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }
      case .policy(let device, let sequence, let wall, _, let policyJSON):
        guard policyJSON.count <= 4_096 else { throw ViewerStoreError.invalidValue }
        let existing = try ViewerSQLiteStatement(
          database: database,
          sql: "SELECT policyJSON FROM PolicyVersions WHERE deviceSessionID=?1 AND sequence=?2"
        )
        try existing.bind(device.rowID, at: 1)
        try existing.bind(checkedInt64(sequence), at: 2)
        if try existing.step() {
          guard existing.data(at: 0) == policyJSON else { throw ViewerStoreError.corruptStore }
          return
        }
        let quota = ViewerStoreQuota.structuralReservation
        try reserveQuota(quota, recordingID: device.recordingID, database: database)
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql:
            "INSERT INTO PolicyVersions(deviceSessionID, sequence, createdWallMs, policyJSON, quotaBytes) VALUES(?1, ?2, ?3, ?4, ?5)"
        )
        try insert.bind(device.rowID, at: 1)
        try insert.bind(checkedInt64(sequence), at: 2)
        try insert.bind(wall, at: 3)
        try insert.bind(policyJSON, at: 4)
        try insert.bind(quota, at: 5)
        _ = try insert.step()
      case .drop(let device, let sequence, let wall, _, let reason, let count):
        guard count > 0, !reason.isEmpty, reason.utf8.count <= 128 else {
          throw ViewerStoreError.invalidValue
        }
        let existing = try ViewerSQLiteStatement(
          database: database,
          sql: "SELECT reason,count FROM DropVersions WHERE deviceSessionID=?1 AND sequence=?2"
        )
        try existing.bind(device.rowID, at: 1)
        try existing.bind(checkedInt64(sequence), at: 2)
        if try existing.step() {
          guard existing.string(at: 0) == reason, existing.int64(at: 1) == count else {
            throw ViewerStoreError.corruptStore
          }
          return
        }
        let latest = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT count FROM DropVersions WHERE deviceSessionID=?1 AND reason=?2 ORDER BY sequence DESC LIMIT 1"
        )
        try latest.bind(device.rowID, at: 1)
        try latest.bind(reason, at: 2)
        if try latest.step() {
          let priorCount = latest.int64(at: 0)
          if priorCount > count { throw ViewerStoreError.staleObservation }
          if priorCount == count { return }
        }
        let quota = ViewerStoreQuota.structuralReservation
        try reserveQuota(quota, recordingID: device.recordingID, database: database)
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql:
            "INSERT INTO DropVersions(deviceSessionID, sequence, createdWallMs, reason, count, quotaBytes) VALUES(?1, ?2, ?3, ?4, ?5, ?6)"
        )
        try insert.bind(device.rowID, at: 1)
        try insert.bind(checkedInt64(sequence), at: 2)
        try insert.bind(wall, at: 3)
        try insert.bind(reason, at: 4)
        try insert.bind(count, at: 5)
        try insert.bind(quota, at: 6)
        _ = try insert.step()
      case .gap(
        let recording, let device, let sequence, let reason, let count,
        let firstWall, let lastWall, let directions, let firstWire, let lastWire
      ):
        try appendGapVersion(
          recording: recording,
          device: device,
          sequence: sequence,
          namespace: "coordinator",
          reason: reason,
          count: count,
          firstWallMilliseconds: firstWall,
          lastWallMilliseconds: lastWall,
          directions: directions,
          firstWireSequence: firstWire,
          lastWireSequence: lastWire,
          database: database
        )
      }
    }
  }

  private func plannedStructuralReservation(
    _ observation: ViewerStructuralObservation,
    database: OpaquePointer
  ) throws -> Int64 {
    switch observation {
    case .closeDevice(let device, _, _):
      return try latestState(
        table: "DeviceSessionVersions",
        ownerColumn: "deviceSessionID",
        ownerID: device.rowID,
        database: database
      ) == "active" ? ViewerStoreQuota.structuralReservation : 0
    case .closeRecording(let recording, _, _):
      return try latestState(
        table: "RecordingVersions",
        ownerColumn: "recordingID",
        ownerID: recording.rowID,
        database: database
      ) == "active" ? ViewerStoreQuota.structuralReservation : 0
    case .disposition(
      let recording,
      let device,
      let direction,
      let wireSequence,
      let value,
      let wall,
      _
    ):
      let event = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT rowID FROM Events WHERE recordingID=?1 AND deviceSessionID=?2 AND direction=?3 AND wireSequence=?4"
      )
      try event.bind(recording.rowID, at: 1)
      try event.bind(device.rowID, at: 2)
      try event.bind(direction.rawValue, at: 3)
      try event.bind(checkedInt64(wireSequence), at: 4)
      guard try event.step() else {
        return try plannedGapReservation(
          recording: recording,
          device: device,
          sequence: wireSequence,
          namespace: "transition",
          reason: "missingInitialEvent.\(value.rawValue)",
          count: 1,
          firstWallMilliseconds: wall,
          lastWallMilliseconds: wall,
          directions: direction.rawValue,
          firstWireSequence: wireSequence,
          lastWireSequence: wireSequence,
          database: database
        )
      }
      let existing = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT disposition FROM EventDispositionVersions WHERE eventID=?1 AND disposition IN ('consumerAccepted','expired','overflowDisplaced','sessionEnded') LIMIT 1"
      )
      try existing.bind(event.int64(at: 0), at: 1)
      guard try existing.step() else { return ViewerStoreQuota.structuralReservation }
      guard existing.string(at: 0) == value.rawValue else { throw ViewerStoreError.corruptStore }
      return 0
    case .policy(let device, let sequence, _, _, let policyJSON):
      let existing = try ViewerSQLiteStatement(
        database: database,
        sql: "SELECT policyJSON FROM PolicyVersions WHERE deviceSessionID=?1 AND sequence=?2"
      )
      try existing.bind(device.rowID, at: 1)
      try existing.bind(checkedInt64(sequence), at: 2)
      guard try existing.step() else { return ViewerStoreQuota.structuralReservation }
      guard existing.data(at: 0) == policyJSON else { throw ViewerStoreError.corruptStore }
      return 0
    case .drop(let device, let sequence, _, _, let reason, let count):
      let existing = try ViewerSQLiteStatement(
        database: database,
        sql: "SELECT reason,count FROM DropVersions WHERE deviceSessionID=?1 AND sequence=?2"
      )
      try existing.bind(device.rowID, at: 1)
      try existing.bind(checkedInt64(sequence), at: 2)
      if try existing.step() {
        guard existing.string(at: 0) == reason, existing.int64(at: 1) == count else {
          throw ViewerStoreError.corruptStore
        }
        return 0
      }
      let latest = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT count FROM DropVersions WHERE deviceSessionID=?1 AND reason=?2 ORDER BY sequence DESC LIMIT 1"
      )
      try latest.bind(device.rowID, at: 1)
      try latest.bind(reason, at: 2)
      if try latest.step() {
        let priorCount = latest.int64(at: 0)
        if priorCount > count { throw ViewerStoreError.staleObservation }
        if priorCount == count { return 0 }
      }
      return ViewerStoreQuota.structuralReservation
    case .gap(
      let recording, let device, let sequence, let reason, let count,
      let firstWall, let lastWall, let directions, let firstWire, let lastWire
    ):
      return try plannedGapReservation(
        recording: recording,
        device: device,
        sequence: sequence,
        namespace: "coordinator",
        reason: reason,
        count: count,
        firstWallMilliseconds: firstWall,
        lastWallMilliseconds: lastWall,
        directions: directions,
        firstWireSequence: firstWire,
        lastWireSequence: lastWire,
        database: database
      )
    }
  }

  private func validateStructuralObservation(_ observation: ViewerStructuralObservation) throws {
    switch observation {
    case .closeDevice(_, _, let monotonic), .closeRecording(_, _, let monotonic):
      _ = try checkedInt64(monotonic)
    case .disposition(_, _, _, let wireSequence, _, _, let monotonic):
      _ = try checkedInt64(wireSequence)
      _ = try checkedInt64(monotonic)
    case .policy(_, let sequence, _, let monotonic, let policyJSON):
      _ = try checkedInt64(sequence)
      _ = try checkedInt64(monotonic)
      guard policyJSON.count <= 4_096 else { throw ViewerStoreError.invalidValue }
    case .drop(_, let sequence, _, let monotonic, let reason, let count):
      _ = try checkedInt64(sequence)
      _ = try checkedInt64(monotonic)
      guard count > 0, !reason.isEmpty, reason.utf8.count <= 128 else {
        throw ViewerStoreError.invalidValue
      }
    case .gap(
      _, _, let sequence, let reason, let count, let firstWall, let lastWall,
      let directions, let firstWire, let lastWire
    ):
      _ = try checkedInt64(sequence)
      if let firstWire { _ = try checkedInt64(firstWire) }
      if let lastWire { _ = try checkedInt64(lastWire) }
      let wireRangeIsValid: Bool
      if let firstWire, let lastWire {
        wireRangeIsValid = firstWire <= lastWire
      } else {
        wireRangeIsValid = firstWire == nil && lastWire == nil
      }
      guard count > 0, !reason.isEmpty, reason.utf8.count <= 128,
        firstWall <= lastWall,
        ["unknown", "appToViewer", "viewerToApp", "both"].contains(directions),
        wireRangeIsValid
      else { throw ViewerStoreError.invalidValue }
    }
  }

  private func latestState(
    table: String,
    ownerColumn: String,
    ownerID: Int64,
    database: OpaquePointer
  ) throws -> String {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql: "SELECT state FROM \(table) WHERE \(ownerColumn)=?1 ORDER BY revision DESC LIMIT 1"
    )
    try statement.bind(ownerID, at: 1)
    guard try statement.step() else { throw ViewerStoreError.corruptStore }
    return statement.string(at: 0)
  }

  private func plannedGapReservation(
    recording: ViewerRecordingHandle,
    device: ViewerDeviceSessionHandle?,
    sequence: UInt64,
    namespace: String,
    reason: String,
    count: Int64,
    firstWallMilliseconds: Int64,
    lastWallMilliseconds: Int64,
    directions: String,
    firstWireSequence: UInt64?,
    lastWireSequence: UInt64?,
    database: OpaquePointer
  ) throws -> Int64 {
    let existing = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT reason,count,firstViewerWallMs,lastViewerWallMs,directions,firstWireSequence,lastWireSequence FROM GapVersions WHERE recordingID=?1 AND deviceSessionID IS ?2 AND sequence=?3 AND namespace=?4 ORDER BY revision DESC LIMIT 1"
    )
    try existing.bind(recording.rowID, at: 1)
    if let device { try existing.bind(device.rowID, at: 2) } else { try existing.bindNull(at: 2) }
    try existing.bind(checkedInt64(sequence), at: 3)
    try existing.bind(namespace, at: 4)
    guard try existing.step() else { return try ViewerStoreQuota.textReservation(reason) }
    guard existing.string(at: 0) == reason else { throw ViewerStoreError.corruptStore }
    let sameWireRange: Bool = {
      if existing.isNull(at: 5) || existing.isNull(at: 6) {
        return firstWireSequence == nil && lastWireSequence == nil
      }
      guard let firstWireSequence, let lastWireSequence,
        let first = try? checkedInt64(firstWireSequence),
        let last = try? checkedInt64(lastWireSequence)
      else { return false }
      return existing.int64(at: 5) == first && existing.int64(at: 6) == last
    }()
    if namespace == "transition", existing.int64(at: 1) == count,
      existing.string(at: 4) == directions, sameWireRange
    {
      return 0
    }
    let identical =
      existing.int64(at: 1) == count
      && existing.int64(at: 2) == firstWallMilliseconds
      && existing.int64(at: 3) == lastWallMilliseconds
      && existing.string(at: 4) == directions && sameWireRange
    if identical { return 0 }
    guard count > existing.int64(at: 1) else { throw ViewerStoreError.corruptStore }
    return try ViewerStoreQuota.textReservation(reason)
  }

  private func appendGapVersion(
    recording: ViewerRecordingHandle,
    device: ViewerDeviceSessionHandle?,
    sequence: UInt64,
    namespace: String,
    reason: String,
    count: Int64,
    firstWallMilliseconds: Int64,
    lastWallMilliseconds: Int64,
    directions: String,
    firstWireSequence: UInt64?,
    lastWireSequence: UInt64?,
    database: OpaquePointer
  ) throws {
    let wireRangeIsValid: Bool
    if let firstWireSequence, let lastWireSequence {
      wireRangeIsValid = firstWireSequence <= lastWireSequence
    } else {
      wireRangeIsValid = firstWireSequence == nil && lastWireSequence == nil
    }
    guard count > 0, ["coordinator", "transition"].contains(namespace),
      !reason.isEmpty, reason.utf8.count <= 128,
      firstWallMilliseconds <= lastWallMilliseconds,
      ["unknown", "appToViewer", "viewerToApp", "both"].contains(directions),
      wireRangeIsValid
    else { throw ViewerStoreError.invalidValue }

    let existing = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT revision,reason,count,firstViewerWallMs,lastViewerWallMs,directions,firstWireSequence,lastWireSequence FROM GapVersions WHERE recordingID=?1 AND deviceSessionID IS ?2 AND sequence=?3 AND namespace=?4 ORDER BY revision DESC LIMIT 1"
    )
    try existing.bind(recording.rowID, at: 1)
    if let device { try existing.bind(device.rowID, at: 2) } else { try existing.bindNull(at: 2) }
    try existing.bind(checkedInt64(sequence), at: 3)
    try existing.bind(namespace, at: 4)
    var revision: Int64 = 1
    if try existing.step() {
      let sameWireRange: Bool = {
        if existing.isNull(at: 6) || existing.isNull(at: 7) {
          return firstWireSequence == nil && lastWireSequence == nil
        }
        guard let firstWireSequence, let lastWireSequence,
          let checkedFirst = try? checkedInt64(firstWireSequence),
          let checkedLast = try? checkedInt64(lastWireSequence)
        else { return false }
        return existing.int64(at: 6) == checkedFirst && existing.int64(at: 7) == checkedLast
      }()
      guard existing.string(at: 1) == reason else { throw ViewerStoreError.corruptStore }
      if namespace == "transition", existing.int64(at: 2) == count,
        existing.string(at: 5) == directions, sameWireRange
      {
        return
      }
      let identical =
        existing.int64(at: 2) == count
        && existing.int64(at: 3) == firstWallMilliseconds
        && existing.int64(at: 4) == lastWallMilliseconds
        && existing.string(at: 5) == directions
        && sameWireRange
      if identical { return }
      guard count > existing.int64(at: 2) else { throw ViewerStoreError.corruptStore }
      revision = existing.int64(at: 0) + 1
    }

    let quota = try ViewerStoreQuota.textReservation(reason)
    try reserveQuota(quota, recordingID: recording.rowID, database: database)
    let insert = try ViewerSQLiteStatement(
      database: database,
      sql:
        "INSERT INTO GapVersions(recordingID,deviceSessionID,sequence,namespace,revision,createdWallMs,reason,firstViewerWallMs,lastViewerWallMs,directions,firstWireSequence,lastWireSequence,count,quotaBytes) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)"
    )
    try insert.bind(recording.rowID, at: 1)
    if let device { try insert.bind(device.rowID, at: 2) } else { try insert.bindNull(at: 2) }
    try insert.bind(checkedInt64(sequence), at: 3)
    try insert.bind(namespace, at: 4)
    try insert.bind(revision, at: 5)
    try insert.bind(lastWallMilliseconds, at: 6)
    try insert.bind(reason, at: 7)
    try insert.bind(firstWallMilliseconds, at: 8)
    try insert.bind(lastWallMilliseconds, at: 9)
    try insert.bind(directions, at: 10)
    if let firstWireSequence {
      try insert.bind(checkedInt64(firstWireSequence), at: 11)
    } else {
      try insert.bindNull(at: 11)
    }
    if let lastWireSequence {
      try insert.bind(checkedInt64(lastWireSequence), at: 12)
    } else {
      try insert.bindNull(at: 12)
    }
    try insert.bind(count, at: 13)
    try insert.bind(quota, at: 14)
    _ = try insert.step()
  }

  func status() -> ViewerStoreStatus {
    let currentState: ViewerStoreStatus.State = {
      stateLock.lock()
      defer { stateLock.unlock() }
      return state
    }()
    do {
      let values = try pool.queryReader.run(budget: .query()) {
        database -> (Int64, Int64?, Int64) in
        let quota = try ViewerStoreSchema.scalarInt64(
          "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
          database: database
        )
        let oldestStatement = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT MIN(viewerWallMs) FROM Events WHERE recordingID NOT IN (SELECT recordingID FROM Tombstones)"
        )
        _ = try oldestStatement.step()
        let oldest = oldestStatement.isNull(at: 0) ? nil : oldestStatement.int64(at: 0)
        let pinned = try ViewerStoreSchema.scalarInt64(
          "SELECT COALESCE(SUM(r.liveQuotaBytes), 0) FROM Recordings r JOIN RecordingVersions v ON v.recordingID=r.rowID WHERE v.rowID=(SELECT MAX(v2.rowID) FROM RecordingVersions v2 WHERE v2.recordingID=r.rowID) AND v.pinned=1 AND r.rowID NOT IN (SELECT recordingID FROM Tombstones)",
          database: database
        )
        return (quota, oldest, pinned)
      }
      return ViewerStoreStatus(
        state: currentState,
        capacityBytes: configuration().capacityBytes,
        logicalQuotaBytes: values.0,
        allocatedFootprintBytes: allocatedFootprint(),
        oldestHistoryMilliseconds: values.1,
        pinnedQuotaBytes: values.2,
        estimatedRetainedDurationMilliseconds: values.1.map {
          max(0, Int64((Date().timeIntervalSince1970 * 1_000).rounded()) - $0)
        },
        lastCleanupCategory: statusMetadata.loadCleanupCategory()
      )
    } catch {
      return ViewerStoreStatus(
        state: .unavailable,
        capacityBytes: configuration().capacityBytes,
        logicalQuotaBytes: 0,
        allocatedFootprintBytes: allocatedFootprint(),
        oldestHistoryMilliseconds: nil,
        pinnedQuotaBytes: 0,
        estimatedRetainedDurationMilliseconds: nil,
        lastCleanupCategory: statusMetadata.loadCleanupCategory()
      )
    }
  }

  func currentChangeSnapshot() -> ViewerStoreChangeSnapshot {
    let upperRowID =
      (try? pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64(
          "SELECT COALESCE(MAX(rowID), 0) FROM Events", database: $0)
      }) ?? 0
    return ViewerStoreChangeSnapshot(
      changedRecordingIDs: [],
      eventUpperRowID: upperRowID,
      status: status()
    )
  }

  private func changeSnapshot() -> ViewerStoreChangeSnapshot { currentChangeSnapshot() }

  func prepareExplicitRecovery() throws -> ViewerStoreStateRelay.RecoveryPermit {
    let permit = writeStateRelay.prepareRecovery(.explicitRetry)
    do {
      try pool.diskGuard.requireReserve(at: pool.paths.directory, plannedBytes: 0)
      for connection in [pool.writer, pool.queryReader, pool.exportReader] {
        try connection.run(budget: .query()) { database in
          try self.writeStateRelay.validate(permit)
          try ViewerStoreSchema.probe(database)
          guard
            try ViewerStoreSchema.scalarString("PRAGMA quick_check(1)", database: database)
              == "ok"
          else { throw ViewerStoreError.corruptStore }
        }
      }
      return permit
    } catch {
      writeStateRelay.reportFailure(.writeFailed)
      throw error
    }
  }

  func retry() throws {
    let permit = try prepareExplicitRecovery()
    try writeStateRelay.completeRecovery(permit)
  }

  private struct InstallationAlias {
    let rowID: Int64
    let ordinal: Int64
  }

  private func installationAlias(
    recordingID: Int64,
    installationID: String,
    database: OpaquePointer
  ) throws -> InstallationAlias {
    let select = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT rowID, ordinal FROM InstallationAliases WHERE recordingID=?1 AND installationID=?2"
    )
    try select.bind(recordingID, at: 1)
    try select.bind(installationID, at: 2)
    if try select.step() {
      return InstallationAlias(rowID: select.int64(at: 0), ordinal: select.int64(at: 1))
    }
    let ordinal = try nextInt64(
      "SELECT COALESCE(MAX(ordinal), 0) + 1 FROM InstallationAliases WHERE recordingID=?1",
      binding: recordingID,
      database: database
    )
    let quota = try ViewerStoreQuota.textReservation(installationID)
    try reserveQuota(quota, recordingID: recordingID, database: database)
    let insert = try ViewerSQLiteStatement(
      database: database,
      sql:
        "INSERT INTO InstallationAliases(recordingID, installationID, ordinal, quotaBytes) VALUES(?1, ?2, ?3, ?4)"
    )
    try insert.bind(recordingID, at: 1)
    try insert.bind(installationID, at: 2)
    try insert.bind(ordinal, at: 3)
    try insert.bind(quota, at: 4)
    _ = try insert.step()
    return InstallationAlias(rowID: sqlite3_last_insert_rowid(database), ordinal: ordinal)
  }

  private func insertRecordingVersion(
    recordingID: Int64,
    revision: Int64,
    wallMilliseconds: Int64,
    name: String?,
    note: String?,
    pinned: Bool,
    state: String,
    endedWallMilliseconds: Int64?,
    endedMonotonicNanoseconds: UInt64?,
    database: OpaquePointer
  ) throws {
    let quota = ViewerStoreQuota.structuralReservation
    try reserveQuota(quota, recordingID: recordingID, database: database)
    let insert = try ViewerSQLiteStatement(
      database: database,
      sql:
        "INSERT INTO RecordingVersions(recordingID, revision, createdWallMs, name, note, pinned, state, endedWallMs, endedMonotonicNs, quotaBytes) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)"
    )
    try insert.bind(recordingID, at: 1)
    try insert.bind(revision, at: 2)
    try insert.bind(wallMilliseconds, at: 3)
    if let name { try insert.bind(name, at: 4) } else { try insert.bindNull(at: 4) }
    if let note { try insert.bind(note, at: 5) } else { try insert.bindNull(at: 5) }
    try insert.bind(Int64(pinned ? 1 : 0), at: 6)
    try insert.bind(state, at: 7)
    if let endedWallMilliseconds {
      try insert.bind(endedWallMilliseconds, at: 8)
    } else {
      try insert.bindNull(at: 8)
    }
    if let endedMonotonicNanoseconds {
      try insert.bind(checkedInt64(endedMonotonicNanoseconds), at: 9)
    } else {
      try insert.bindNull(at: 9)
    }
    try insert.bind(quota, at: 10)
    _ = try insert.step()
  }

  private func insertDeviceVersion(
    deviceSessionID: Int64,
    recordingID: Int64,
    revision: Int64,
    wallMilliseconds: Int64,
    displayName: String?,
    state: String,
    partialHistory: Bool,
    endedWallMilliseconds: Int64?,
    endedMonotonicNanoseconds: UInt64?,
    database: OpaquePointer
  ) throws {
    let quota = ViewerStoreQuota.structuralReservation
    try reserveQuota(quota, recordingID: recordingID, database: database)
    let insert = try ViewerSQLiteStatement(
      database: database,
      sql:
        "INSERT INTO DeviceSessionVersions(deviceSessionID, revision, createdWallMs, displayName, state, partialHistory, endedWallMs, endedMonotonicNs, quotaBytes) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"
    )
    try insert.bind(deviceSessionID, at: 1)
    try insert.bind(revision, at: 2)
    try insert.bind(wallMilliseconds, at: 3)
    if let displayName { try insert.bind(displayName, at: 4) } else { try insert.bindNull(at: 4) }
    try insert.bind(state, at: 5)
    try insert.bind(Int64(partialHistory ? 1 : 0), at: 6)
    if let endedWallMilliseconds {
      try insert.bind(endedWallMilliseconds, at: 7)
    } else {
      try insert.bindNull(at: 7)
    }
    if let endedMonotonicNanoseconds {
      try insert.bind(checkedInt64(endedMonotonicNanoseconds), at: 8)
    } else {
      try insert.bindNull(at: 8)
    }
    try insert.bind(quota, at: 9)
    _ = try insert.step()
  }

  private func reserveQuota(
    _ bytes: Int64,
    recordingID: Int64,
    database: OpaquePointer
  ) throws {
    guard bytes >= 0 else { throw ViewerStoreError.invalidValue }
    let current = try ViewerStoreSchema.scalarInt64(
      "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
      database: database
    )
    let (next, overflow) = current.addingReportingOverflow(bytes)
    guard !overflow, next <= configuration().capacityBytes else {
      throw ViewerStoreError.capacityExceeded
    }
    let update = try ViewerSQLiteStatement(
      database: database,
      sql: "UPDATE StoreMetadata SET integerValue=?1 WHERE key='logicalQuotaBytes'"
    )
    try update.bind(next, at: 1)
    _ = try update.step()
    let recordingUpdate = try ViewerSQLiteStatement(
      database: database,
      sql: "UPDATE Recordings SET liveQuotaBytes=liveQuotaBytes+?1 WHERE rowID=?2"
    )
    try recordingUpdate.bind(bytes, at: 1)
    try recordingUpdate.bind(recordingID, at: 2)
    _ = try recordingUpdate.step()
    guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }
  }

  private func existingEventID(
    _ observation: ViewerPreparedEventObservation,
    database: OpaquePointer
  ) throws -> Int64 {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT rowID,eventUUID,eventType,contentJSON,createdWallMs,viewerWallMs,originMonotonicNs,viewerMonotonicNs,priority,ttlMs,schemaVersion,deterministicBytes,correlationEventUUID,replyToEventUUID FROM Events WHERE recordingID=?1 AND deviceSessionID=?2 AND direction=?3 AND wireSequence=?4"
    )
    try statement.bind(observation.recording.rowID, at: 1)
    try statement.bind(observation.device.rowID, at: 2)
    try statement.bind(observation.envelope.direction.rawValue, at: 3)
    try statement.bind(checkedInt64(observation.envelope.sequence.rawValue), at: 4)
    let envelope = observation.envelope
    let originMonotonic = try checkedInt64(envelope.monotonicTimestampNanoseconds)
    let viewerMonotonic = try checkedInt64(observation.viewerMonotonicNanoseconds)
    let ttlMilliseconds = try checkedInt64(envelope.ttl.milliseconds)
    guard try statement.step(),
      statement.string(at: 1) == envelope.id.rawValue,
      statement.string(at: 2) == envelope.type.rawValue,
      statement.data(at: 3) == observation.canonicalContent,
      statement.int64(at: 4) == Int64((envelope.createdAt.timeIntervalSince1970 * 1_000).rounded()),
      statement.int64(at: 5) == observation.viewerWallMilliseconds,
      statement.int64(at: 6) == originMonotonic,
      statement.int64(at: 7) == viewerMonotonic,
      statement.string(at: 8) == envelope.priority.rawValue,
      statement.int64(at: 9) == ttlMilliseconds,
      statement.int64(at: 10) == Int64(envelope.schemaVersion.rawValue),
      statement.int64(at: 11) == Int64(observation.deterministicEventBytes),
      optionalString(statement, at: 12) == envelope.causality.correlationID?.rawValue,
      optionalString(statement, at: 13) == envelope.causality.replyTo?.rawValue
    else { throw ViewerStoreError.corruptStore }
    return statement.int64(at: 0)
  }

  private func appendEvent(
    _ observation: ViewerPreparedEventObservation,
    database: OpaquePointer
  ) throws -> Int64 {
    if let eventID = try eventRowID(observation, database: database) {
      _ = try existingEventID(observation, database: database)
      if let initial = observation.initialDisposition {
        try insertInitialDisposition(
          eventID: eventID,
          disposition: initial,
          wallMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
          monotonicNanoseconds: observation.viewerMonotonicNanoseconds,
          recordingID: observation.recording.rowID,
          database: database
        )
      }
      return eventID
    }
    try reserveQuota(
      observation.quotaBytes,
      recordingID: observation.recording.rowID,
      database: database
    )
    let envelope = observation.envelope
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql:
        "INSERT INTO Events(recordingID, deviceSessionID, direction, wireSequence, eventUUID, eventType, contentJSON, createdWallMs, viewerWallMs, originMonotonicNs, viewerMonotonicNs, priority, ttlMs, schemaVersion, deterministicBytes, correlationEventUUID, replyToEventUUID, quotaBytes) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18) ON CONFLICT(recordingID, deviceSessionID, direction, wireSequence) DO NOTHING"
    )
    try statement.bind(observation.recording.rowID, at: 1)
    try statement.bind(observation.device.rowID, at: 2)
    try statement.bind(envelope.direction.rawValue, at: 3)
    try statement.bind(checkedInt64(envelope.sequence.rawValue), at: 4)
    try statement.bind(envelope.id.rawValue, at: 5)
    try statement.bind(envelope.type.rawValue, at: 6)
    try statement.bind(observation.canonicalContent, at: 7)
    try statement.bind(Int64((envelope.createdAt.timeIntervalSince1970 * 1_000).rounded()), at: 8)
    try statement.bind(observation.viewerWallMilliseconds, at: 9)
    try statement.bind(checkedInt64(envelope.monotonicTimestampNanoseconds), at: 10)
    try statement.bind(checkedInt64(observation.viewerMonotonicNanoseconds), at: 11)
    try statement.bind(envelope.priority.rawValue, at: 12)
    try statement.bind(checkedInt64(envelope.ttl.milliseconds), at: 13)
    try statement.bind(Int64(envelope.schemaVersion.rawValue), at: 14)
    try statement.bind(Int64(observation.deterministicEventBytes), at: 15)
    if let correlationID = envelope.causality.correlationID {
      try statement.bind(correlationID.rawValue, at: 16)
    } else {
      try statement.bindNull(at: 16)
    }
    if let replyTo = envelope.causality.replyTo {
      try statement.bind(replyTo.rawValue, at: 17)
    } else {
      try statement.bindNull(at: 17)
    }
    try statement.bind(observation.quotaBytes, at: 18)
    _ = try statement.step()
    let eventID: Int64
    guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }
    eventID = sqlite3_last_insert_rowid(database)
    if let initial = observation.initialDisposition {
      try insertInitialDisposition(
        eventID: eventID,
        disposition: initial,
        wallMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
        monotonicNanoseconds: observation.viewerMonotonicNanoseconds,
        recordingID: observation.recording.rowID,
        database: database
      )
    }
    return eventID
  }

  private func insertInitialDisposition(
    eventID: Int64,
    disposition: ViewerStoredDisposition,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64,
    recordingID: Int64,
    database: OpaquePointer
  ) throws {
    let existing = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT disposition,viewerMonotonicNs FROM EventDispositionVersions WHERE eventID=?1 AND sequence=0"
    )
    try existing.bind(eventID, at: 1)
    if try existing.step() {
      let checkedMonotonicNanoseconds = try checkedInt64(monotonicNanoseconds)
      guard existing.string(at: 0) == disposition.rawValue,
        existing.int64(at: 1) == checkedMonotonicNanoseconds
      else { throw ViewerStoreError.corruptStore }
      return
    }
    let quota = ViewerStoreQuota.structuralReservation
    try reserveQuota(quota, recordingID: recordingID, database: database)
    let insert = try ViewerSQLiteStatement(
      database: database,
      sql:
        "INSERT INTO EventDispositionVersions(eventID, sequence, disposition, createdWallMs, viewerMonotonicNs, quotaBytes) VALUES(?1, 0, ?2, ?3, ?4, ?5) ON CONFLICT(eventID, sequence) DO NOTHING"
    )
    try insert.bind(eventID, at: 1)
    try insert.bind(disposition.rawValue, at: 2)
    try insert.bind(wallMilliseconds, at: 3)
    try insert.bind(checkedInt64(monotonicNanoseconds), at: 4)
    try insert.bind(quota, at: 5)
    _ = try insert.step()
    guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }
  }

  private func eventRowID(
    _ observation: ViewerPreparedEventObservation,
    database: OpaquePointer
  ) throws -> Int64? {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT rowID FROM Events WHERE recordingID=?1 AND deviceSessionID=?2 AND direction=?3 AND wireSequence=?4"
    )
    try statement.bind(observation.recording.rowID, at: 1)
    try statement.bind(observation.device.rowID, at: 2)
    try statement.bind(observation.envelope.direction.rawValue, at: 3)
    try statement.bind(checkedInt64(observation.envelope.sequence.rawValue), at: 4)
    return try statement.step() ? statement.int64(at: 0) : nil
  }

  private func plannedEventReservation(
    _ observation: ViewerPreparedEventObservation,
    database: OpaquePointer
  ) throws -> Int64 {
    guard let eventID = try eventRowID(observation, database: database) else {
      return try Self.checkedReservationSum(
        observation.quotaBytes,
        observation.initialDisposition == nil ? 0 : ViewerStoreQuota.structuralReservation
      )
    }
    _ = try existingEventID(observation, database: database)
    guard let initial = observation.initialDisposition else { return 0 }
    let existing = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT disposition,viewerMonotonicNs FROM EventDispositionVersions WHERE eventID=?1 AND sequence=0"
    )
    try existing.bind(eventID, at: 1)
    guard try existing.step() else { return ViewerStoreQuota.structuralReservation }
    let expectedMonotonic = try checkedInt64(observation.viewerMonotonicNanoseconds)
    guard existing.string(at: 0) == initial.rawValue,
      existing.int64(at: 1) == expectedMonotonic
    else { throw ViewerStoreError.corruptStore }
    return 0
  }

  private func nextInt64(
    _ sql: String,
    binding: Int64,
    database: OpaquePointer
  ) throws -> Int64 {
    let statement = try ViewerSQLiteStatement(database: database, sql: sql)
    try statement.bind(binding, at: 1)
    guard try statement.step() else { throw ViewerStoreError.corruptStore }
    return statement.int64(at: 0)
  }

  private func writeTransaction<T>(
    recoveryPermit: ViewerStoreStateRelay.RecoveryPermit? = nil,
    plan: (OpaquePointer) throws -> Int64 = { _ in 0 },
    changedRecordingIDs: (T) -> Set<Int64> = { _ in [] },
    _ body: (OpaquePointer) throws -> T
  ) throws -> T {
    var authorization: ViewerStoreStateRelay.WriteAuthorization
    if let recoveryPermit {
      authorization = .recovery(recoveryPermit)
    } else {
      authorization = .automatic(try writeStateRelay.issueAutomaticTicket())
      automaticWriteAuthorizationObserver()
    }
    var attemptedCapacityRecovery = false
    while true {
      var plannedReservation: Int64 = 0
      var capacityRecoveryPermit: ViewerStoreStateRelay.RecoveryPermit?
      do {
        let result = try pool.writer.run(
          failureHandler: { error in
            if recoveryPermit == nil, !attemptedCapacityRecovery,
              error as? ViewerStoreError == .capacityExceeded
            {
              self.writeStateRelay.reportFailure(.capacityPaused)
              capacityRecoveryPermit = self.writeStateRelay.prepareRecovery(
                .automaticCapacityRecovery
              )
            } else {
              self.reportWriteFailureBeforeWriterRelease(error)
            }
          }
        ) { database in
          try self.writeStateRelay.validate(authorization)
          try self.writeGate()
          plannedReservation = try plan(database)
          guard plannedReservation >= 0 else { throw ViewerStoreError.invalidValue }
          let currentQuota = try ViewerStoreSchema.scalarInt64(
            "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
            database: database
          )
          let (projectedQuota, overflow) = currentQuota.addingReportingOverflow(plannedReservation)
          guard !overflow, projectedQuota <= configuration().capacityBytes else {
            throw ViewerStoreError.capacityExceeded
          }
          try pool.diskGuard.requireReserve(
            at: pool.paths.directory,
            plannedBytes: plannedReservation
          )
          try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
          do {
            let result = try body(database)
            try ViewerSQLiteConnection.execute("COMMIT", on: database)
            return result
          } catch {
            try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
            throw error
          }
        }
        statusSignal.publish(changedRecordingIDs: changedRecordingIDs(result))
        return result
      } catch let error as ViewerStoreError
        where error == .capacityExceeded
        && !attemptedCapacityRecovery
      {
        attemptedCapacityRecovery = true
        recoveryLock.lock()
        let recovery = capacityRecovery
        recoveryLock.unlock()
        guard let recovery, let permit = capacityRecoveryPermit else { throw error }
        do {
          try recovery(plannedReservation, permit)
          try writeStateRelay.completeRecovery(permit)
          authorization = .automatic(try writeStateRelay.issueAutomaticTicket())
          automaticWriteAuthorizationObserver()
        } catch {
          writeStateRelay.reportFailure(.capacityPaused, ifCurrent: permit)
          throw error
        }
      } catch let error as ViewerStoreError {
        throw error
      } catch {
        throw error
      }
    }
  }

  private func reportWriteFailureBeforeWriterRelease(_ error: Error) {
    guard let storeError = error as? ViewerStoreError else {
      writeStateRelay.reportFailure(.writeFailed)
      return
    }
    switch ViewerStoreWriteFailureDisposition.classify(storeError, context: .eventIngress) {
    case .capacityPaused:
      writeStateRelay.reportFailure(.capacityPaused)
    case .writeFailed:
      writeStateRelay.reportFailure(.writeFailed)
    case .operationLocal:
      break
    }
  }

  private static func checkedReservationSum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    guard lhs >= 0, rhs >= 0, !overflow else { throw ViewerStoreError.capacityExceeded }
    return sum
  }

  private func recordingID(of observation: ViewerStructuralObservation) -> Int64 {
    switch observation {
    case .closeDevice(let device, _, _): return device.recordingID
    case .closeRecording(let recording, _, _): return recording.rowID
    case .disposition(let recording, _, _, _, _, _, _): return recording.rowID
    case .policy(let device, _, _, _, _): return device.recordingID
    case .drop(let device, _, _, _, _, _): return device.recordingID
    case .gap(let recording, _, _, _, _, _, _, _, _, _): return recording.rowID
    }
  }

  private func setState(_ transition: ViewerStoreStateRelay.Transition) {
    stateLock.lock()
    guard transition.sequence >= stateTransitionSequence else {
      stateLock.unlock()
      return
    }
    let changed = state != transition.state
    state = transition.state
    stateTransitionSequence = transition.sequence
    stateLock.unlock()
    if changed { statusSignal.publish() }
  }

  func noteAuthoritativeWriteState(_ transition: ViewerStoreStateRelay.Transition) {
    setState(transition)
  }

  private func allocatedFootprint() -> Int64 {
    [pool.paths.database, pool.paths.wal, pool.paths.sharedMemory].reduce(0) { total, url in
      let size = (try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
      return total + Int64(size)
    }
  }

  private func checkedInt64(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw ViewerStoreError.invalidValue }
    return Int64(value)
  }

  private func optionalString(_ statement: ViewerSQLiteStatement, at index: Int32) -> String? {
    statement.isNull(at: index) ? nil : statement.string(at: index)
  }
}

struct ViewerStoreIngressLimits: Equatable, Sendable {
  static let hardMaximumCount = 8_192
  static let hardMaximumBytes = 64 * 1_024 * 1_024
  static let `default` = ViewerStoreIngressLimits(
    maximumCount: 4_096, maximumBytes: 32 * 1_024 * 1_024)

  let maximumCount: Int
  let maximumBytes: Int

  init(maximumCount: Int, maximumBytes: Int) {
    precondition((1...Self.hardMaximumCount).contains(maximumCount))
    precondition((1...Self.hardMaximumBytes).contains(maximumBytes))
    self.maximumCount = maximumCount
    self.maximumBytes = maximumBytes
  }
}

final class ViewerJournalPipelineBudget: @unchecked Sendable {
  enum Kind: Sendable { case event, structural, lifecycle }

  final class Reservation: @unchecked Sendable {
    fileprivate let owner: ViewerJournalPipelineBudget
    let kind: Kind
    fileprivate let bytes: Int

    fileprivate init(owner: ViewerJournalPipelineBudget, kind: Kind, bytes: Int) {
      self.owner = owner
      self.kind = kind
      self.bytes = bytes
    }

    deinit { owner.release(kind: kind, bytes: bytes) }
  }

  private static let structuralMaximumCount = 36
  private static let observationalStructuralMaximumCount = 18
  private let lock = NSLock()
  private let limits: ViewerStoreIngressLimits
  private var eventCount = 0
  private var eventBytes = 0
  private var structuralCount = 0
  private var observationalStructuralCount = 0

  init(limits: ViewerStoreIngressLimits = .default) { self.limits = limits }

  func reserve(bytes: Int, kind: Kind) -> Reservation? {
    guard bytes >= 0 else { return nil }
    lock.lock()
    defer { lock.unlock() }
    switch kind {
    case .event:
      guard eventCount < limits.maximumCount, eventBytes <= limits.maximumBytes - bytes else {
        return nil
      }
      eventCount += 1
      eventBytes += bytes
    case .structural:
      guard observationalStructuralCount < Self.observationalStructuralMaximumCount,
        structuralCount < Self.structuralMaximumCount
      else { return nil }
      observationalStructuralCount += 1
      structuralCount += 1
    case .lifecycle:
      guard structuralCount < Self.structuralMaximumCount else { return nil }
      structuralCount += 1
    }
    return Reservation(owner: self, kind: kind, bytes: bytes)
  }

  func snapshot() -> (eventCount: Int, eventBytes: Int, structuralCount: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (eventCount, eventBytes, structuralCount)
  }

  private func release(kind: Kind, bytes: Int) {
    lock.lock()
    switch kind {
    case .event:
      eventCount = max(0, eventCount - 1)
      eventBytes = max(0, eventBytes - bytes)
    case .structural:
      structuralCount = max(0, structuralCount - 1)
      observationalStructuralCount = max(0, observationalStructuralCount - 1)
    case .lifecycle:
      structuralCount = max(0, structuralCount - 1)
    }
    lock.unlock()
  }
}

final class ViewerStoreIngress: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  enum Admission: Equatable, Sendable { case admitted, full, oversize, stopped }
  enum FlushOutcome: Equatable, Sendable { case drained, writeFailed }

  private static let structuralMaximumCount = 36
  private static let batchMaximumCount = 256
  private static let batchMaximumBytes = 4 * 1_024 * 1_024
  private static let oversizeMaximumBytes = 20 * 1_024 * 1_024

  private let lock = NSLock()
  private let limits: ViewerStoreIngressLimits
  private let store: ViewerEventStore
  private let writeStateRelay: ViewerStoreStateRelay
  private let onCommittedBytes: @Sendable (Int64) -> Void
  private var onRejectedStructural:
    @Sendable (ViewerStructuralObservation, ViewerStoreError) -> Void = { _, _ in }
  private let queue = DispatchQueue(label: "com.nearwire.viewer.store-ingress")
  private struct EventEntry {
    let observation: ViewerPreparedEventObservation
    let ownershipBytes: Int
    let reservation: ViewerJournalPipelineBudget.Reservation?
  }
  private struct StructuralEntry {
    let observation: ViewerStructuralObservation
    let reservation: ViewerJournalPipelineBudget.Reservation?
  }
  private var events: [UInt64: EventEntry] = [:]
  private var eventHead: UInt64 = 1
  private var eventTail: UInt64 = 1
  private var structural: [UInt64: StructuralEntry] = [:]
  private var structuralHead: UInt64 = 1
  private var structuralTail: UInt64 = 1
  private var eventBytes = 0
  private var drainScheduled = false
  private var drainDirty = false
  private var stateTransitionSequence: UInt64 = 0
  private var flushWaiters: [CheckedContinuation<FlushOutcome, Never>] = []

  init(
    store: ViewerEventStore,
    limits: ViewerStoreIngressLimits = .default,
    onCommittedBytes: @escaping @Sendable (Int64) -> Void = { _ in }
  ) {
    self.store = store
    writeStateRelay = store.writeStateRelay
    self.limits = limits
    self.onCommittedBytes = onCommittedBytes
    writeStateRelay.bind(ingress: self)
  }

  func setRejectedStructuralHandler(
    _ handler: @escaping @Sendable (ViewerStructuralObservation, ViewerStoreError) -> Void
  ) {
    lock.lock()
    onRejectedStructural = handler
    lock.unlock()
  }

  func admit(
    _ event: ViewerPreparedEventObservation,
    reservation: ViewerJournalPipelineBudget.Reservation? = nil
  ) -> Admission {
    guard event.deterministicEventBytes <= Self.oversizeMaximumBytes else { return .oversize }
    guard
      let ownershipBytes = try? ViewerStoreQuota.eventPipelineReservation(
        canonicalEventBytes: event.deterministicEventBytes
      )
    else { return .oversize }
    guard reservation?.kind == nil || reservation?.kind == .event else { return .full }
    lock.lock()
    defer { lock.unlock() }
    guard writeStateRelay.isAutomaticWriteAvailable else { return .stopped }
    guard events.count < limits.maximumCount,
      eventBytes <= limits.maximumBytes - ownershipBytes,
      eventTail < UInt64.max
    else { return .full }
    events[eventTail] = EventEntry(
      observation: event,
      ownershipBytes: ownershipBytes,
      reservation: reservation
    )
    eventTail += 1
    eventBytes += ownershipBytes
    scheduleDrainLocked()
    return .admitted
  }

  func admit(
    _ value: ViewerStructuralObservation,
    reservation: ViewerJournalPipelineBudget.Reservation? = nil
  ) -> Admission {
    guard reservation?.kind != .event else { return .full }
    lock.lock()
    defer { lock.unlock() }
    guard writeStateRelay.isAutomaticWriteAvailable else { return .stopped }
    let isLifecycle: Bool
    switch value {
    case .closeDevice, .closeRecording:
      isLifecycle = true
    default:
      isLifecycle = false
    }
    guard
      reservation?.kind == nil
        || (isLifecycle && reservation?.kind == .lifecycle)
        || (!isLifecycle && reservation?.kind == .structural)
    else { return .full }
    let limit = isLifecycle ? Self.structuralMaximumCount : Self.structuralMaximumCount - 18
    guard structural.count < limit, structuralTail < UInt64.max else { return .full }
    structural[structuralTail] = StructuralEntry(observation: value, reservation: reservation)
    structuralTail += 1
    scheduleDrainLocked()
    return .admitted
  }

  func noteAuthoritativeStoreState(_ transition: ViewerStoreStateRelay.Transition) {
    lock.lock()
    guard transition.sequence >= stateTransitionSequence else {
      lock.unlock()
      return
    }
    stateTransitionSequence = transition.sequence
    switch transition.state {
    case .available:
      if !events.isEmpty || !structural.isEmpty { scheduleDrainLocked() }
    case .writeFailed, .capacityPaused, .unavailable:
      drainDirty = false
    }
    lock.unlock()
  }

  func flush() async -> FlushOutcome {
    await withCheckedContinuation { continuation in
      lock.lock()
      if !writeStateRelay.isAutomaticWriteAvailable {
        lock.unlock()
        continuation.resume(returning: .writeFailed)
        return
      }
      if events.isEmpty && structural.isEmpty && !drainScheduled {
        lock.unlock()
        continuation.resume(returning: .drained)
        return
      }
      flushWaiters.append(continuation)
      scheduleDrainLocked()
      lock.unlock()
    }
  }

  private func scheduleDrainLocked() {
    if drainScheduled {
      drainDirty = true
      return
    }
    drainScheduled = true
    queue.async { [weak self] in self?.drain() }
  }

  private func drain() {
    while true {
      let eventBatch: [(UInt64, ViewerPreparedEventObservation, Int)]
      let structuralEntry: (UInt64, ViewerStructuralObservation)?
      lock.lock()
      if !writeStateRelay.isAutomaticWriteAvailable {
        drainScheduled = false
        drainDirty = false
        let waiters = flushWaiters
        flushWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: .writeFailed) }
        return
      }
      let pendingDispositionNeedsEventCommit: Bool
      if let first = structural[structuralHead], case .disposition = first.observation {
        pendingDispositionNeedsEventCommit = !events.isEmpty
      } else {
        pendingDispositionNeedsEventCommit = false
      }
      if pendingDispositionNeedsEventCommit {
        structuralEntry = nil
      } else if let value = structural[structuralHead] {
        structuralEntry = (structuralHead, value.observation)
      } else {
        structuralEntry = nil
      }
      if structuralEntry == nil {
        var key = eventHead
        var bytes = 0
        var selected: [(UInt64, ViewerPreparedEventObservation, Int)] = []
        selected.reserveCapacity(min(events.count, Self.batchMaximumCount))
        while selected.count < Self.batchMaximumCount, let nextEntry = events[key] {
          let nextEvent = nextEntry.observation
          let next = nextEvent.deterministicEventBytes
          if !selected.isEmpty && bytes > Self.batchMaximumBytes - next { break }
          selected.append((key, nextEvent, nextEntry.ownershipBytes))
          if selected.count == 1 && next > Self.batchMaximumBytes {
            break
          }
          bytes += next
          key += 1
        }
        eventBatch = selected
      } else {
        eventBatch = []
      }
      lock.unlock()

      do {
        if let structuralEntry { try store.appendStructural(structuralEntry.1) }
        if !eventBatch.isEmpty { _ = try store.appendEvents(eventBatch.map(\.1)) }
      } catch let error as ViewerStoreError
        where error == .staleObservation && structuralEntry != nil
      {
        lock.lock()
        let rejected = structural.removeValue(forKey: structuralEntry!.0)
        structuralHead = structuralEntry!.0 + 1
        let rejectionHandler = onRejectedStructural
        lock.unlock()
        if let rejected { rejectionHandler(rejected.observation, error) }
        continue
      } catch {
        lock.lock()
        drainScheduled = false
        drainDirty = false
        if writeStateRelay.isAutomaticWriteAvailable,
          !events.isEmpty || !structural.isEmpty
        {
          scheduleDrainLocked()
          lock.unlock()
          return
        }
        let waiters = flushWaiters
        flushWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: .writeFailed) }
        return
      }

      lock.lock()
      if let structuralEntry {
        structural.removeValue(forKey: structuralEntry.0)
        structuralHead = structuralEntry.0 + 1
      } else if !eventBatch.isEmpty {
        let committedBytes = eventBatch.reduce(0) { $0 + $1.1.deterministicEventBytes }
        let ownedBytes = eventBatch.reduce(0) { $0 + $1.2 }
        for entry in eventBatch { events.removeValue(forKey: entry.0) }
        eventHead = eventBatch[eventBatch.count - 1].0 + 1
        eventBytes -= ownedBytes
        onCommittedBytes(Int64(committedBytes))
      }
      let empty = structural.isEmpty && events.isEmpty
      if empty {
        eventHead = 1
        eventTail = 1
        structuralHead = 1
        structuralTail = 1
        drainScheduled = false
        drainDirty = false
        let waiters = flushWaiters
        flushWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: .drained) }
        return
      }
      drainDirty = false
      lock.unlock()
    }
  }

  var description: String { "ViewerStoreIngress(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

enum ViewerStoreRecoveryAction: Equatable, Sendable {
  case automaticCapacityRecovery
  case explicitRetry
  case nonRecoveringMutation
  case settingsChanged
  case unpin
  case manualDelete
}

final class ViewerStoreStateRelay: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  struct Transition: Equatable, Sendable {
    let sequence: UInt64
    let state: ViewerStoreStatus.State
  }

  struct AutomaticTicket: Equatable, Sendable {
    fileprivate let generation: UUID
  }

  struct RecoveryPermit: Equatable, Sendable {
    fileprivate let generation: UUID
    let action: ViewerStoreRecoveryAction
  }

  enum WriteAuthorization: Sendable {
    case automatic(AutomaticTicket)
    case recovery(RecoveryPermit)
  }

  private let lock = NSLock()
  private let publicationLock = NSLock()
  private var state: ViewerStoreStatus.State = .available
  private var generation = UUID()
  private var transitionSequence: UInt64 = 0
  private weak var eventStore: ViewerEventStore?
  private weak var ingress: ViewerStoreIngress?

  func bind(eventStore: ViewerEventStore) {
    publicationLock.lock()
    lock.lock()
    self.eventStore = eventStore
    let transition = currentTransitionLocked()
    lock.unlock()
    eventStore.noteAuthoritativeWriteState(transition)
    publicationLock.unlock()
  }

  func bind(ingress: ViewerStoreIngress) {
    publicationLock.lock()
    lock.lock()
    self.ingress = ingress
    let transition = currentTransitionLocked()
    lock.unlock()
    ingress.noteAuthoritativeStoreState(transition)
    publicationLock.unlock()
  }

  var currentState: ViewerStoreStatus.State {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  var isAutomaticWriteAvailable: Bool { currentState == .available }

  func issueAutomaticTicket() throws -> AutomaticTicket {
    lock.lock()
    defer { lock.unlock() }
    guard state == .available else { throw ViewerStoreError.writeNotAuthorized }
    return AutomaticTicket(generation: generation)
  }

  func issueMaintenanceAuthorization() -> WriteAuthorization {
    lock.lock()
    defer { lock.unlock() }
    if state == .available {
      return .automatic(AutomaticTicket(generation: generation))
    }
    return .recovery(
      RecoveryPermit(generation: generation, action: .nonRecoveringMutation)
    )
  }

  func prepareRecovery(_ action: ViewerStoreRecoveryAction) -> RecoveryPermit {
    lock.lock()
    defer { lock.unlock() }
    return RecoveryPermit(generation: generation, action: action)
  }

  func validate(_ authorization: WriteAuthorization) throws {
    switch authorization {
    case .automatic(let ticket):
      lock.lock()
      let valid = state == .available && generation == ticket.generation
      lock.unlock()
      guard valid else { throw ViewerStoreError.writeNotAuthorized }
    case .recovery(let permit):
      try validate(permit)
    }
  }

  func validate(_ permit: RecoveryPermit) throws {
    lock.lock()
    let valid = generation == permit.generation
    lock.unlock()
    guard valid else { throw ViewerStoreError.writeNotAuthorized }
  }

  func completeRecovery(_ permit: RecoveryPermit) throws {
    publicationLock.lock()
    defer { publicationLock.unlock() }
    lock.lock()
    guard generation == permit.generation else {
      lock.unlock()
      throw ViewerStoreError.writeNotAuthorized
    }
    guard state != .available else {
      lock.unlock()
      return
    }
    state = .available
    generation = UUID()
    let transition = advanceTransitionLocked()
    let eventStore = eventStore
    let ingress = ingress
    lock.unlock()
    eventStore?.noteAuthoritativeWriteState(transition)
    ingress?.noteAuthoritativeStoreState(transition)
  }

  func reportFailure(_ state: ViewerStoreStatus.State) {
    precondition(state != .available)
    publicationLock.lock()
    defer { publicationLock.unlock() }
    lock.lock()
    self.state = state
    generation = UUID()
    let transition = advanceTransitionLocked()
    let eventStore = eventStore
    let ingress = ingress
    lock.unlock()
    eventStore?.noteAuthoritativeWriteState(transition)
    ingress?.noteAuthoritativeStoreState(transition)
  }

  @discardableResult
  func reportFailure(
    _ state: ViewerStoreStatus.State,
    ifCurrent permit: RecoveryPermit
  ) -> Bool {
    precondition(state != .available)
    publicationLock.lock()
    defer { publicationLock.unlock() }
    lock.lock()
    guard generation == permit.generation else {
      lock.unlock()
      return false
    }
    self.state = state
    generation = UUID()
    let transition = advanceTransitionLocked()
    let eventStore = eventStore
    let ingress = ingress
    lock.unlock()
    eventStore?.noteAuthoritativeWriteState(transition)
    ingress?.noteAuthoritativeStoreState(transition)
    return true
  }

  private func currentTransitionLocked() -> Transition {
    Transition(sequence: transitionSequence, state: state)
  }

  private func advanceTransitionLocked() -> Transition {
    precondition(transitionSequence < UInt64.max, "Store transition sequence exhausted.")
    transitionSequence += 1
    return currentTransitionLocked()
  }

  var description: String { "ViewerStoreStateRelay(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerStoreStateRelay.AutomaticTicket: CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  var description: String { "ViewerStoreAutomaticTicket(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoreStateRelay.RecoveryPermit: CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  var description: String { "ViewerStoreRecoveryPermit(\(action))" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoreStateRelay.WriteAuthorization: CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  var description: String {
    switch self {
    case .automatic: return "ViewerStoreWriteAuthorization.automatic"
    case .recovery: return "ViewerStoreWriteAuthorization.recovery"
    }
  }

  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerStoreStatusMetadataBox: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreStatusMetadata(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerStoreStatusSignal: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreStatusSignal(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerEventStore: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerEventStore(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerJournalPipelineBudget: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerJournalPipelineBudget(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerRecordingHandle: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRecordingHandle(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerDeviceSessionHandle: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerDeviceSessionHandle(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerJournalPipelineBudget.Reservation: CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  var description: String { "ViewerJournalPipelineReservation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
