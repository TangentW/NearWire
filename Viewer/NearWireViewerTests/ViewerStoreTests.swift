import Combine
import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport
import SQLite3
import XCTest

@testable import NearWireViewer

final class ViewerStoreTests: XCTestCase {
  func testStoreCoordinatorAndRuntimeRootsHaveClosedReflection() throws {
    let paths = try makePaths()
    let markers = [
      "store-root-installation-secret",
      "Store Root Display Secret",
      "com.example.store.root.secret",
      "88.store-root-secret",
    ]
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: try EndpointID(rawValue: markers[0]),
      displayName: markers[1],
      applicationIdentifier: markers[2],
      applicationVersion: markers[3]
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .viewer,
      installationID: try EndpointID(rawValue: "store-root-viewer")
    )
    let context = ViewerAdmissionSessionContext(
      connectionID: UUID(),
      appHello: appHello,
      viewerHello: viewerHello,
      negotiation: try WireNegotiator.negotiate(local: appHello, remote: viewerHello),
      receiveChunkBytes: 64 * 1_024
    )
    let runtime = ViewerStoreRuntime(paths: paths)
    let logicalID = UUID()
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000
    )
    runtime.sessionStarted(runtimeLogicalID: logicalID, context)
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())

    let operationalRoots: [Any] = [
      context,
      runtime,
      coordinator,
      coordinator.services,
      coordinator.services.eventStore,
      coordinator.services.maintenance,
      coordinator.services.query,
      coordinator.services.export,
      coordinator.services.preferences,
      coordinator.services.statusSignal,
      paths,
    ]
    for value in operationalRoots {
      let surfaces = [String(describing: value), String(reflecting: value), "\(value)"]
      for marker in markers {
        XCTAssertFalse(surfaces.contains { $0.contains(marker) })
      }
      XCTAssertTrue(Mirror(reflecting: value).children.isEmpty)
    }

    runtime.closeStorage()
    coordinator.closeStorage()
  }

  func testRelayObserversRejectReorderedTransitions() async throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let relay = ViewerStoreStateRelay()
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      writeStateRelay: relay
    )
    let ingress = ViewerStoreIngress(store: store)

    relay.reportFailure(.writeFailed)
    store.noteAuthoritativeWriteState(.init(sequence: 0, state: .available))
    ingress.noteAuthoritativeStoreState(.init(sequence: 0, state: .available))
    XCTAssertEqual(relay.currentState, .writeFailed)
    XCTAssertEqual(store.status().state, .writeFailed)
    let failedFlush = await ingress.flush()
    XCTAssertEqual(failedFlush, .writeFailed)

    let permit = relay.prepareRecovery(.explicitRetry)
    try relay.completeRecovery(permit)
    store.noteAuthoritativeWriteState(.init(sequence: 1, state: .capacityPaused))
    ingress.noteAuthoritativeStoreState(.init(sequence: 1, state: .capacityPaused))
    XCTAssertEqual(relay.currentState, .available)
    XCTAssertEqual(store.status().state, .available)
    let recoveredFlush = await ingress.flush()
    XCTAssertEqual(recoveredFlush, .drained)
    XCTAssertNoThrow(try relay.issueAutomaticTicket())
    pool.close()
  }

  private var temporaryDirectories: [URL] = []

  override func tearDownWithError() throws {
    for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
    temporaryDirectories.removeAll()
  }

  func testStoreCreatesThreeRolesAndVersionOneSchemaWithOwnerOnlyPermissions() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)

    XCTAssertEqual(pool.writer.role, .writer)
    XCTAssertEqual(pool.queryReader.role, .queryReader)
    XCTAssertEqual(pool.exportReader.role, .exportReader)
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64("PRAGMA user_version", database: $0)
      },
      1
    )
    XCTAssertEqual(try permissions(paths.directory), 0o700)
    XCTAssertEqual(try permissions(paths.database), 0o600)
    XCTAssertEqual(try permissions(paths.wal), 0o600)
    XCTAssertEqual(try permissions(paths.sharedMemory), 0o600)
    XCTAssertTrue(try isRegularFileWithoutFollowingLinks(paths.wal))
    XCTAssertTrue(try isRegularFileWithoutFollowingLinks(paths.sharedMemory))
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64("PRAGMA secure_delete", database: $0)
      },
      1
    )
    let hardening = try pool.writer.hardeningConfiguration()
    XCTAssertTrue(hardening.defensive)
    XCTAssertFalse(hardening.trustedSchema)
  }

  func testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection() throws {
    let paths = try makePaths()
    let firstEvents = LockedViewerPoolConstructionEvents()
    let first = try ViewerSQLitePool(
      migrating: paths,
      constructionObserver: { firstEvents.append($0) }
    )
    XCTAssertEqual(
      firstEvents.value,
      [.writerOpened, .schemaAccepted, .queryReaderOpened, .exportReaderOpened]
    )
    first.close()

    let reopenEvents = LockedViewerPoolConstructionEvents()
    let reopened = try ViewerSQLitePool(
      migrating: paths,
      constructionObserver: { reopenEvents.append($0) }
    )
    XCTAssertEqual(
      reopenEvents.value,
      [.writerOpened, .schemaAccepted, .queryReaderOpened, .exportReaderOpened]
    )
    reopened.close()

    let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    try raw.execute("PRAGMA user_version=99")
    raw.close()
    let rejectedEvents = LockedViewerPoolConstructionEvents()
    XCTAssertThrowsError(
      try ViewerSQLitePool(
        migrating: paths,
        constructionObserver: { rejectedEvents.append($0) }
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .unsupportedSchema)
    }
    XCTAssertEqual(rejectedEvents.value, [.writerOpened])

    let migrationFailurePaths = try makePaths()
    try ViewerStoreFileSecurity.prepareDirectory(
      migrationFailurePaths.directory,
      fileManager: .default
    )
    let invalid = try ViewerSQLiteConnection(
      role: .writer,
      path: migrationFailurePaths.database.path
    )
    try invalid.execute("CREATE TABLE Unexpected(value INTEGER)")
    invalid.close()
    let migrationFailureEvents = LockedViewerPoolConstructionEvents()
    XCTAssertThrowsError(
      try ViewerSQLitePool(
        migrating: migrationFailurePaths,
        constructionObserver: { migrationFailureEvents.append($0) }
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    XCTAssertEqual(migrationFailureEvents.value, [.writerOpened])
  }

  func testOptInLiveApplicationSupportArtifactsWhileViewerStoreIsOpen() throws {
    guard
      FileManager.default.fileExists(
        atPath: "/tmp/nearwire-live-container-audit.enabled"
      )
    else {
      throw XCTSkip(
        "Create the explicit local-container audit marker before this machine-local gate.")
    }
    let paths = try ViewerStorePaths.applicationSupport()
    XCTAssertNotEqual(ViewerRuntimeDependencies.live.loadStoreStatus().state, .unavailable)
    XCTAssertEqual(try permissions(paths.directory), 0o700)
    for url in [paths.database, paths.wal, paths.sharedMemory] {
      XCTAssertEqual(try permissions(url), 0o600)
      XCTAssertTrue(try isRegularFileWithoutFollowingLinks(url))
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
      print(
        "NearWire live container active artifact: \(url.path), mode=0600, size=\(values.fileSize ?? 0), allocated=\(values.fileAllocatedSize ?? 0)"
      )
    }
    print("NearWire live container directory: \(paths.directory.path), mode=0700")
  }

  func testStoreReopensAndRejectsUnknownSchema() throws {
    let paths = try makePaths()
    _ = try ViewerSQLitePool(migrating: paths)
    _ = try ViewerSQLitePool(migrating: paths)

    let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    try raw.execute("PRAGMA user_version=99")
    XCTAssertThrowsError(try ViewerSQLitePool(migrating: paths)) { error in
      XCTAssertEqual(error as? ViewerStoreError, .unsupportedSchema)
    }
  }

  func testStoreRejectsIncompleteVersionOneSchemaWithoutDeletingData() throws {
    let paths = try makePaths()
    do {
      let pool = try ViewerSQLitePool(migrating: paths)
      try pool.writer.run { database in
        try ViewerSQLiteConnection.execute(
          "INSERT INTO Recordings(logicalID, startedWallMs, startedMonotonicNs, durableStartReason, quotaBytes, liveQuotaBytes) VALUES('preserve-me', 1, 1, 'test', 0, 0)",
          on: database
        )
      }
    }
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("ALTER TABLE Recordings DROP COLUMN liveQuotaBytes")
    }

    XCTAssertThrowsError(try ViewerSQLitePool(migrating: paths)) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    XCTAssertEqual(
      try raw.run {
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings WHERE logicalID='preserve-me'",
          database: $0
        )
      },
      1
    )
  }

  func testSchemaRoundTripsCheckedBindingsAndRollsBackFailure() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
      do {
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql:
            "INSERT INTO Recordings(logicalID, startedWallMs, startedMonotonicNs, durableStartReason, quotaBytes, liveQuotaBytes) VALUES(?1, ?2, ?3, ?4, ?5, ?5)"
        )
        try insert.bind("recording-one", at: 1)
        try insert.bind(Int64(1_000), at: 2)
        try insert.bind(Int64(2_000), at: 3)
        try insert.bind("liveStart", at: 4)
        try insert.bind(Int64(512), at: 5)
        XCTAssertFalse(try insert.step())
        try ViewerSQLiteConnection.execute("COMMIT", on: database)
      } catch {
        try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
        throw error
      }
    }
    XCTAssertThrowsError(
      try pool.writer.run { database in
        try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
        defer { try? ViewerSQLiteConnection.execute("ROLLBACK", on: database) }
        try ViewerSQLiteConnection.execute(
          "INSERT INTO Recordings(logicalID, startedWallMs, startedMonotonicNs, durableStartReason, quotaBytes, liveQuotaBytes) VALUES('recording-one', 1, 1, 'duplicate', 0, 0)",
          on: database
        )
      }
    )
    let count = try pool.queryReader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Recordings", database: $0)
    }
    XCTAssertEqual(count, 1)
  }

  func testSymlinkDatabaseAndDirectoryAreRejected() throws {
    let base = try makeTemporaryDirectory()
    let real = base.appendingPathComponent("real.sqlite")
    XCTAssertTrue(FileManager.default.createFile(atPath: real.path, contents: Data()))
    let directory = base.appendingPathComponent("Store", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let linked = directory.appendingPathComponent("NearWire.sqlite")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
    XCTAssertThrowsError(
      try ViewerSQLitePool(
        migrating: ViewerStorePaths(directory: directory, database: linked)
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidPath)
    }
  }

  func testPreferencesUseDefaultsAndRecoverFromCorruption() throws {
    let suite = "ViewerStoreTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("Missing defaults") }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ViewerStoragePreferences(defaults: defaults)

    XCTAssertEqual(preferences.load(), .default)
    let custom = try ViewerStorageConfiguration(
      capacityBytes: 512 * 1_024 * 1_024,
      historyRetentionDays: 30
    )
    preferences.save(custom)
    XCTAssertEqual(preferences.load(), custom)
    defaults.set(-1, forKey: "nearwire.storage.capacityBytes")
    XCTAssertEqual(preferences.load(), .default)
    defaults.set(true, forKey: "nearwire.storage.capacityBytes")
    XCTAssertEqual(preferences.load(), .default)
    defaults.set(
      ViewerStorageConfiguration.defaultCapacityBytes,
      forKey: "nearwire.storage.capacityBytes"
    )
    defaults.set(3.5, forKey: "nearwire.storage.historyRetentionDays")
    XCTAssertEqual(preferences.load(), .default)
  }

  func testConfigurationRejectsOutOfRangeValues() {
    XCTAssertThrowsError(
      try ViewerStorageConfiguration(capacityBytes: 1, historyRetentionDays: 7)
    )
    XCTAssertThrowsError(
      try ViewerStorageConfiguration(
        capacityBytes: ViewerStorageConfiguration.defaultCapacityBytes,
        historyRetentionDays: 0
      )
    )
  }

  func testEventStorePersistsIdempotentEventAndSearchesFrozenKeysetPage() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device-private-identifier",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Test App"
    )
    let first = try makeObservation(
      recording: recording, device: device, sequence: 1, value: "alpha % _")
    let second = try makeObservation(
      recording: recording, device: device, sequence: 2, value: "beta")
    let firstID = try store.appendEvent(first)
    XCTAssertEqual(try store.appendEvent(first), firstID)
    _ = try store.appendEvent(second)

    let leases = ViewerStoreLeaseRegistry()
    let service = ViewerStoreQueryService(pool: pool, leases: leases)
    let query = try ViewerEventQuery(
      recordingID: recording.rowID,
      predicates: [.eventTypePrefix("test."), .contentContains("% _")]
    )
    let traversal = try service.begin(query: query)
    let (page, _) = try service.page(
      traversal: traversal,
      cursor: nil,
      direction: .forward,
      limit: 100
    )
    XCTAssertEqual(page.rows.map(\.rowID), [firstID])
    XCTAssertEqual(page.rows.first?.eventType, "test.metric")
  }

  func testAppendOnlyDispositionPolicyAndDropSamplesAreIdempotentAndDetectConflicts() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    let buffered = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "buffered",
      initialDisposition: .buffered
    )
    _ = try store.appendEvent(buffered)
    let conflictingInitial = try ViewerPreparedEventObservation(
      recording: recording,
      device: device,
      envelope: buffered.envelope,
      viewerMonotonicNanoseconds: buffered.viewerMonotonicNanoseconds,
      viewerWallMilliseconds: buffered.viewerWallMilliseconds,
      deterministicEventBytes: buffered.deterministicEventBytes,
      initialDisposition: .transportAdmitted
    )
    XCTAssertThrowsError(try store.appendEvent(conflictingInitial)) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    try store.retry()
    let terminal = ViewerStructuralObservation.disposition(
      recording: recording,
      device: device,
      direction: .appToViewer,
      wireSequence: 1,
      value: .consumerAccepted,
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100
    )
    try store.appendStructural(terminal)
    try store.appendStructural(terminal)
    XCTAssertThrowsError(
      try store.appendStructural(
        .disposition(
          recording: recording,
          device: device,
          direction: .appToViewer,
          wireSequence: 1,
          value: .expired,
          wallMilliseconds: 1_200,
          monotonicNanoseconds: 2_200
        )
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    try store.retry()

    let policyJSON = try ViewerCanonicalJSON.encode(ViewerRatePolicy.default)
    let policy = ViewerStructuralObservation.policy(
      device: device,
      sequence: 1,
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      policyJSON: policyJSON
    )
    try store.appendStructural(policy)
    try store.appendStructural(policy)
    XCTAssertThrowsError(
      try store.appendStructural(
        .policy(
          device: device,
          sequence: 1,
          wallMilliseconds: 1_200,
          monotonicNanoseconds: 2_200,
          policyJSON: Data("{}".utf8)
        )
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    try store.retry()

    let drop = ViewerStructuralObservation.drop(
      device: device,
      sequence: 1,
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
      count: 2
    )
    try store.appendStructural(drop)
    try store.appendStructural(drop)
    XCTAssertThrowsError(
      try store.appendStructural(
        .drop(
          device: device,
          sequence: 1,
          wallMilliseconds: 1_200,
          monotonicNanoseconds: 2_200,
          reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
          count: 3
        )
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    try store.retry()
    try store.appendStructural(
      .drop(
        device: device,
        sequence: 2,
        wallMilliseconds: 1_300,
        monotonicNanoseconds: 2_300,
        reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
        count: 5
      )
    )
    XCTAssertThrowsError(
      try store.appendStructural(
        .drop(
          device: device,
          sequence: 3,
          wallMilliseconds: 1_400,
          monotonicNanoseconds: 2_400,
          reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
          count: 4
        )
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .staleObservation)
    }

    let recordingGap = ViewerStructuralObservation.gap(
      recording: recording,
      device: nil,
      sequence: 9,
      reason: "storageUnavailable",
      count: 2,
      firstWallMilliseconds: 1_100,
      lastWallMilliseconds: 1_100,
      directions: "unknown",
      firstWireSequence: nil,
      lastWireSequence: nil
    )
    try store.appendStructural(recordingGap)
    try store.appendStructural(recordingGap)
    XCTAssertThrowsError(
      try store.appendStructural(
        .gap(
          recording: recording,
          device: nil,
          sequence: 9,
          reason: "differentReason",
          count: 1,
          firstWallMilliseconds: 1_200,
          lastWallMilliseconds: 1_200,
          directions: "unknown",
          firstWireSequence: nil,
          lastWireSequence: nil
        )
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }

    let counts = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM EventDispositionVersions",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM PolicyVersions", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM DropVersions", database: database),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM GapVersions WHERE deviceSessionID IS NULL",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64(
          "SELECT count FROM GapVersions WHERE deviceSessionID IS NULL",
          database: database
        )
      )
    }
    XCTAssertEqual(counts.0, 2)
    XCTAssertEqual(counts.1, 1)
    XCTAssertEqual(counts.2, 2)
    XCTAssertEqual(counts.3, 1)
    XCTAssertEqual(counts.4, 2)
  }

  func testRejectedCumulativeDropSampleCreatesGapBeforeLaterSample() throws {
    let paths = try makePaths()
    let fault = CountingViewerStoreFault()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { try fault.check() })
    let logicalID = UUID()
    let context = try makeAdmissionContext(suffix: "drop-gap")
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    XCTAssertTrue(coordinator.sessionStarted(context))
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths)) == 1
    }

    fault.failEveryAttempt()
    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .localOverflow, count: 2)],
      monotonicNanoseconds: 3_000
    )
    waitUntil { coordinator.services.eventStore.status().state == .writeFailed }

    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .localOverflow, count: 5)],
      monotonicNanoseconds: 3_100
    )
    fault.succeedEveryAttempt()
    XCTAssertTrue(coordinator.retryStorage())
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM DropVersions", at: paths)) == 1
        && (try? self.scalar(
          "SELECT COUNT(*) FROM GapVersions WHERE reason='dropJournalFull'",
          at: paths
        )) == 1
    }

    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .localOverflow, count: 7)],
      monotonicNanoseconds: 3_200
    )
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM DropVersions", at: paths)) == 2
    }
    XCTAssertEqual(
      try scalar("SELECT MIN(count) FROM DropVersions", at: paths),
      2
    )
    XCTAssertEqual(
      try scalar("SELECT MAX(count) FROM DropVersions", at: paths),
      7
    )
    coordinator.closeStorage()
  }

  func testDropPlanningRejectsNonIncreasingCountsBeforeCapacityRecovery() throws {
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 7
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "drop-planning"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "drop-planning-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    try store.appendStructural(
      .drop(
        device: device,
        sequence: 1,
        wallMilliseconds: 1_100,
        monotonicNanoseconds: 2_100,
        reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
        count: 5
      )
    )
    let eligible = try store.beginRecording(
      wallMilliseconds: 500,
      monotonicNanoseconds: 600,
      reason: "eligible"
    )
    try store.appendStructural(
      .closeRecording(eligible, wallMilliseconds: 700, monotonicNanoseconds: 800)
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=\(configuration.capacityBytes) WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    let recoveryCount = LockedCounter()
    store.setCapacityRecovery { _, _ in recoveryCount.increment() }

    try store.appendStructural(
      .drop(
        device: device,
        sequence: 2,
        wallMilliseconds: 1_200,
        monotonicNanoseconds: 2_200,
        reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
        count: 5
      )
    )
    XCTAssertThrowsError(
      try store.appendStructural(
        .drop(
          device: device,
          sequence: 3,
          wallMilliseconds: 1_300,
          monotonicNanoseconds: 2_300,
          reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
          count: 4
        )
      )
    ) {
      XCTAssertEqual($0 as? ViewerStoreError, .staleObservation)
    }
    let result = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM DropVersions", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: database),
        try ViewerStoreSchema.scalarInt64(
          "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
          database: database
        )
      )
    }
    XCTAssertEqual(result.0, 1)
    XCTAssertEqual(result.1, 0)
    XCTAssertEqual(result.2, configuration.capacityBytes)
    XCTAssertEqual(recoveryCount.value, 0)
    XCTAssertEqual(store.status().state, .available)
    pool.close()
  }

  func testCoordinatorSaturatesDropProjectionAndGapsARealDecrease() throws {
    let paths = try makePaths()
    let coordinator = try ViewerStoreCoordinator(paths: paths)
    let logicalID = UUID()
    let context = try makeAdmissionContext(suffix: "drop-saturation")
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    XCTAssertTrue(coordinator.sessionStarted(context))
    waitUntil { (try? self.scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths)) == 1 }

    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .remoteOverflow, count: UInt64(Int64.max))],
      monotonicNanoseconds: 3_000
    )
    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .remoteOverflow, count: UInt64(Int64.max) + 1)],
      monotonicNanoseconds: 3_100
    )
    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .remoteOverflow, count: UInt64.max)],
      monotonicNanoseconds: 3_200
    )
    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .remoteOverflow, count: UInt64(Int64.max - 1))],
      monotonicNanoseconds: 3_300
    )
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM DropVersions", at: paths)) == 1
        && (try? self.scalar(
          "SELECT COUNT(*) FROM GapVersions WHERE reason='dropJournalNonIncreasing'",
          at: paths
        )) == 1
    }
    XCTAssertEqual(
      try scalar("SELECT count FROM DropVersions", at: paths),
      Int64.max
    )
    XCTAssertEqual(coordinator.services.eventStore.status().state, .available)
    coordinator.closeStorage()
  }

  func testDurableMetadataAndSensitiveReflectionAreBoundedAndRedacted() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    XCTAssertThrowsError(
      try store.beginDeviceSession(
        recording: recording,
        installationID: String(repeating: "x", count: 513),
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000,
        partialHistory: false,
        displayName: nil
      )
    )
    XCTAssertThrowsError(
      try store.beginDeviceSession(
        recording: recording,
        installationID: "device",
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000,
        partialHistory: false,
        displayName: "secret\nname"
      )
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    let observation = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "reflection-secret"
    )
    XCTAssertFalse(String(reflecting: observation).contains("reflection-secret"))
    XCTAssertFalse(String(describing: observation).contains("reflection-secret"))

    let received = try WireEventRecord(
      envelope: observation.envelope,
      remainingTTLNanoseconds: 1_000_000
    ).receiverEvent(receivedAtNanoseconds: 9_000)
    let downlink = ViewerDownlinkJournalEvent(
      envelope: observation.envelope,
      deterministicEncodedByteCount: received.deterministicEncodedByteCount
    )
    let structural: [ViewerStructuralObservation] = [
      .policy(
        device: device,
        sequence: 1,
        wallMilliseconds: 1,
        monotonicNanoseconds: 1,
        policyJSON: Data("reflection-secret".utf8)
      ),
      .drop(
        device: device,
        sequence: 1,
        wallMilliseconds: 1,
        monotonicNanoseconds: 1,
        reason: "reflection-secret",
        count: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "reflection-secret",
        count: 1,
        firstWallMilliseconds: 1,
        lastWallMilliseconds: 1,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      ),
    ]
    let carriers: [Any] = [received, downlink] + structural.map { $0 as Any }
    for carrier in carriers {
      XCTAssertFalse(String(describing: carrier).contains("reflection-secret"))
      XCTAssertFalse(String(reflecting: carrier).contains("reflection-secret"))
      XCTAssertFalse(
        Mirror(reflecting: carrier).children.contains {
          String(reflecting: $0.value).contains("reflection-secret")
        }
      )
      XCTAssertFalse("diagnostic=\(carrier)".contains("reflection-secret"))
    }
  }

  func testQueryCompilerTreatsOperatorsAndWildcardsAsLiteralBindings() throws {
    let query = try ViewerEventQuery(
      recordingID: 1,
      predicates: [
        .fullText("one OR two %_\\\""),
        .json(path: "$.payload[0].value", equals: .string("x' --")),
      ]
    )
    XCTAssertNoThrow(try ViewerEventQueryCompiler.compile(query))
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(
          recordingID: 1,
          predicates: [.json(path: "$['open']", equals: .null)]
        )
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(
          recordingID: 1,
          predicates: [.fullText(Array(repeating: "term", count: 33).joined(separator: " "))]
        )
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(
          recordingID: 1,
          predicates: [.fullText(String(repeating: "x", count: 513))]
        )
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.contentContains("bad\u{0}value")])
      )
    )
  }

  func testQueryCompilerRejectsImpossibleEventTypesAndNonASCIIJSONIndexes() throws {
    for value in ["1leading", "empty..segment", "trailing.", "unicode.é", ".leading"] {
      XCTAssertThrowsError(
        try ViewerEventQueryCompiler.compile(
          ViewerEventQuery(recordingID: 1, predicates: [.eventTypeEquals(value)])
        )
      )
    }
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(
          recordingID: 1,
          predicates: [.eventTypeEquals("a" + String(repeating: "b", count: 128))]
        )
      )
    )
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix("valid.")])
      )
    )
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix("valid.part")])
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix("invalid..")])
      )
    )
    let segment126 = "a" + String(repeating: "b", count: 125)
    let segment127 = "a" + String(repeating: "b", count: 126)
    let segment128 = "a" + String(repeating: "b", count: 127)
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix(segment126 + ".")])
      )
    )
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix(segment127)])
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix(segment127 + ".")])
      )
    )
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix(segment128)])
      )
    )
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.jsonExists(path: "$.items[12]")])
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.jsonExists(path: "$.items[١]")])
      )
    )
  }

  func testSensitiveQueryAndSummaryModelsHaveClosedRedactedReflection() throws {
    let secret = "secret.event.value"
    let query = try ViewerEventQuery(
      recordingID: 1,
      predicates: [.eventTypeEquals(secret), .fullText(secret)]
    )
    let compiled = try ViewerEventQueryCompiler.compile(query)
    let row = ViewerStoredEventRow(
      rowID: 1,
      deviceSessionID: 2,
      direction: "appToViewer",
      wireSequence: 3,
      eventUUID: secret,
      eventType: secret,
      contentByteCount: 4,
      createdWallMilliseconds: 5,
      viewerWallMilliseconds: 6,
      viewerMonotonicNanoseconds: 7,
      priority: "normal",
      recordingRevision: 1,
      deviceRevision: 1,
      resolvedDisposition: "buffered"
    )
    let values: [Any] = [
      ViewerQueryScalar.string(secret),
      ViewerEventPredicate.fullText(secret),
      query,
      ViewerQueryBinding.text(secret),
      compiled,
      row,
      ViewerEventPage(rows: [row], nextCursor: nil, previousCursor: nil),
    ]
    for value in values {
      XCTAssertFalse(String(describing: value).contains(secret))
      XCTAssertFalse(String(reflecting: value).contains(secret))
      XCTAssertFalse(
        Mirror(reflecting: value).children.contains {
          String(reflecting: $0.value).contains(secret)
        }
      )
    }
  }

  func testSQLiteProgressBudgetReportsWorkLimitInsteadOfCancellation() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let connection = pool.queryReader
    XCTAssertThrowsError(
      try connection.run(
        budget: ViewerSQLiteBudget(
          maximumVirtualMachineSteps: 1_000,
          deadline: .now + .seconds(1)
        )
      ) { database in
        try ViewerStoreSchema.scalarInt64(
          "WITH RECURSIVE valueset(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM valueset WHERE value<1000000) SELECT SUM(value) FROM valueset",
          database: database
        )
      }
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .workLimitExceeded)
    }
    pool.close()
  }

  func testUnavailableRuntimeReopensAfterExplicitRetry() async throws {
    let paths = try makePaths()
    do { _ = try ViewerSQLitePool(migrating: paths) }
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=99")
    }
    let fault = OneShotViewerStoreFault()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: { try fault.check() }
    )
    XCTAssertEqual(runtime.status().state, .unavailable)
    let logicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=1")
    }

    fault.failNext()
    runtime.retryStorage()
    waitUntil { fault.failureCount == 1 && !runtime.isRecoveryInFlight }
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: logicalID
        )) == 1)
    }
    XCTAssertEqual(runtime.status().state, .available)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 0)
    XCTAssertEqual(
      try scalar(
        "SELECT COUNT(*) FROM Recordings WHERE durableStartReason='midRuntimeRetry'",
        at: paths
      ),
      1
    )

    let laterRetryFinished = expectation(description: "Later retry finished")
    runtime.retryStorage()
    runtime.afterCurrentJournalPrefix { laterRetryFinished.fulfill() }
    await fulfillment(of: [laterRetryFinished], timeout: 2)
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: logicalID),
      1
    )

    await runtime.runtimeEnded(
      logicalID: logicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 5_000
    )
    let raw = try ViewerSQLiteConnection(
      role: .queryReader, path: paths.database.path, readOnly: true)
    let recovered = try raw.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COALESCE(MAX(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
          database: database
        )
      )
    }
    XCTAssertEqual(recovered.0, 1)
    XCTAssertEqual(recovered.1, 1)
    raw.close()
    runtime.closeStorage()
  }

  func testFailedInitialExplicitRetryDoesNotAuthorizeLaterRuntime() async throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    pool.close()
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=99")
      raw.close()
    }
    let runtime = ViewerStoreRuntime(paths: paths)
    let firstLogicalID = UUID()
    let laterLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )

    runtime.retryStorage()
    let failedRetryFinished = expectation(description: "Failed explicit retry finished")
    runtime.afterCurrentReopenPrefix { failedRetryFinished.fulfill() }
    await fulfillment(of: [failedRetryFinished], timeout: 2)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=1")
      raw.close()
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )
    runtime.runtimeStarted(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    let automaticPrefixFinished = expectation(description: "Unauthorized automatic prefix")
    runtime.afterCurrentReopenPrefix { automaticPrefixFinished.fulfill() }
    await fulfillment(of: [automaticPrefixFinished], timeout: 2)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: laterLogicalID,
          state: "active"
        )) == 1)
    }
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: laterLogicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )
  }

  func testCancelledInitialExplicitRetryDoesNotAuthorizeLaterRuntime() async throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    pool.close()
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=99")
      raw.close()
    }
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let laterLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=1")
      raw.close()
    }

    reopenGate.arm()
    runtime.retryStorage()
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    let ended = LockedViewerCounter()
    let endTask = Task {
      await runtime.runtimeEnded(
        logicalID: firstLogicalID,
        wallMilliseconds: wallMilliseconds + 1_000,
        monotonicNanoseconds: 4_000
      )
      ended.increment()
    }
    waitUntil { resourceEvents.value.contains(.runtimeEndWaiting) }
    XCTAssertEqual(ended.value, 0)
    reopenGate.release()
    await endTask.value
    XCTAssertEqual(ended.value, 1)
    XCTAssertEqual(
      resourceEvents.value,
      [.runtimeEndWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )

    runtime.runtimeStarted(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    let automaticPrefixFinished = expectation(description: "Cancelled explicit automatic prefix")
    runtime.afterCurrentReopenPrefix { automaticPrefixFinished.fulfill() }
    await fulfillment(of: [automaticPrefixFinished], timeout: 2)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: laterLogicalID,
          state: "active"
        )) == 1)
    }
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: laterLogicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )
  }

  func testRepeatedRuntimeStartPreservesOriginalContextAndRecoveryOwnership() async throws {
    let paths = try makePaths()
    do { _ = try ViewerSQLitePool(migrating: paths) }
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=99")
      raw.close()
    }
    let fault = OneShotViewerStoreFault()
    let reopenGate = ArmableViewerExecutionGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: { try fault.check() },
      reopenExecutionGate: { reopenGate.run() }
    )
    let logicalID = UUID()
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000
    )
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 10_000,
      monotonicNanoseconds: 20_000
    )
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=1")
      raw.close()
    }

    reopenGate.arm()
    runtime.retryStorage()
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 30_000,
      monotonicNanoseconds: 40_000
    )
    fault.failNext()
    reopenGate.release()
    waitUntil { fault.failureCount == 1 && !runtime.isRecoveryInFlight }
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 50_000,
      monotonicNanoseconds: 60_000
    )
    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: logicalID
        )) == 1)
    }
    let start = try recordingStart(at: paths, logicalID: logicalID)
    XCTAssertEqual(start.wallMilliseconds, 1_000)
    XCTAssertEqual(start.monotonicNanoseconds, 2_000)
    XCTAssertEqual(start.reason, "midRuntimeRetry")
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 0)

    let laterRetryFinished = expectation(description: "Repeated-start later retry finished")
    runtime.retryStorage()
    runtime.afterCurrentJournalPrefix { laterRetryFinished.fulfill() }
    await fulfillment(of: [laterRetryFinished], timeout: 2)
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: logicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: logicalID,
      wallMilliseconds: 70_000,
      monotonicNanoseconds: 80_000
    )
  }

  func testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes() async throws {
    let paths = try makePaths()
    do { _ = try ViewerSQLitePool(migrating: paths) }
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=99")
      raw.close()
    }
    let fault = OneShotViewerStoreFault()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: { try fault.check() }
    )
    let logicalID = UUID()
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000
    )
    runtime.policyChanged(
      runtimeLogicalID: logicalID,
      connectionID: UUID(),
      policy: .default,
      monotonicNanoseconds: 3_000
    )
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=1")
      raw.close()
    }

    fault.failNext()
    runtime.retryStorage()
    waitUntil { fault.failureCount == 1 && !runtime.isRecoveryInFlight }
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.policyChanged(
      runtimeLogicalID: logicalID,
      connectionID: UUID(),
      policy: .default,
      monotonicNanoseconds: 4_000
    )
    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && !runtime.isRecoveryInFlight
        && ((try? self.scalar(
          "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
          at: paths
        )) == 3)
    }
    XCTAssertEqual(
      try scalar(
        "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
        at: paths
      ),
      3
    )
    await runtime.runtimeEnded(
      logicalID: logicalID,
      wallMilliseconds: 5_000,
      monotonicNanoseconds: 6_000
    )
  }

  func testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork() async throws {
    let paths = try makePaths()
    let initialFailure = BlockingViewerStoreFailureGate()
    let retryFailure = BlockingViewerStoreFailureGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: {
        try initialFailure.check()
        try retryFailure.check()
      }
    )
    let logicalID = UUID()
    initialFailure.arm()
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000
    )
    XCTAssertEqual(initialFailure.waitUntilEntered(), .success)
    let context = try makeAdmissionContext(suffix: "runtime-recovery")
    for _ in 0..<40 {
      runtime.sessionStarted(runtimeLogicalID: logicalID, context)
    }
    let prefixCompleted = expectation(description: "Accepted lifecycle prefix completed")
    runtime.afterCurrentJournalPrefix { prefixCompleted.fulfill() }
    initialFailure.release()
    await fulfillment(of: [prefixCompleted], timeout: 5)
    XCTAssertEqual(runtime.status().state, .unavailable)

    retryFailure.arm()
    runtime.retryStorage()
    XCTAssertEqual(retryFailure.waitUntilEntered(), .success)
    XCTAssertTrue(runtime.isRecoveryInFlight)
    retryFailure.release()
    waitUntil(timeout: 5) { !runtime.isRecoveryInFlight }
    XCTAssertEqual(retryFailure.armedCheckCount, 1)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && !runtime.isRecoveryInFlight
        && ((try? self.scalar(
          "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
          at: paths
        )) == 6)
        && ((try? self.scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths)) == 1)
    }
    XCTAssertEqual(
      try scalar(
        "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
        at: paths
      ),
      6
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 1)
    await runtime.runtimeEnded(
      logicalID: logicalID,
      wallMilliseconds: 5_000,
      monotonicNanoseconds: 6_000
    )
  }

  func testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime() async throws {
    let paths = try makePaths()
    let fault = OneShotViewerStoreFault()
    let reopenGate = ArmableViewerExecutionGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: { try fault.check() },
      reopenExecutionGate: { reopenGate.run() }
    )
    let oldLogicalID = UUID()
    let newLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: oldLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: oldLogicalID,
        state: "active"
      )) == 1
    }

    runtime.runtimeStarted(
      logicalID: newLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 4_000
    )
    XCTAssertEqual(runtime.status().state, .unavailable)

    reopenGate.arm()
    await runtime.runtimeEnded(
      logicalID: oldLogicalID,
      wallMilliseconds: wallMilliseconds + 5_000,
      monotonicNanoseconds: 7_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    fault.failNext()
    reopenGate.release()
    waitUntil { fault.failureCount == 1 && !runtime.isRecoveryInFlight }
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: newLogicalID, state: "active"),
      0
    )

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: newLogicalID,
          state: "active"
        )) == 1)
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: newLogicalID
        )) == 1)
    }
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: newLogicalID),
      1
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 0)

    let laterRetryFinished = expectation(description: "Later replacement retry finished")
    runtime.retryStorage()
    runtime.afterCurrentJournalPrefix { laterRetryFinished.fulfill() }
    await fulfillment(of: [laterRetryFinished], timeout: 2)
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: newLogicalID),
      1
    )

    await runtime.runtimeEnded(
      logicalID: oldLogicalID,
      wallMilliseconds: wallMilliseconds + 7_000,
      monotonicNanoseconds: 9_000
    )
    XCTAssertEqual(runtime.status().state, .available)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: newLogicalID, state: "active"),
      1
    )

    await runtime.runtimeEnded(
      logicalID: newLogicalID,
      wallMilliseconds: wallMilliseconds + 9_000,
      monotonicNanoseconds: 11_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: newLogicalID,
        state: "closed"
      )) == 1
    }
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: newLogicalID, state: "closed"),
      1
    )
  }

  func testSequentialRuntimeAutomaticallyReopensAfterCompletedShutdown() async throws {
    let paths = try makePaths()
    let runtime = ViewerStoreRuntime(paths: paths)
    let firstLogicalID = UUID()
    let secondLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: firstLogicalID, state: "closed"),
      1
    )

    runtime.runtimeStarted(
      logicalID: secondLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: secondLogicalID,
          state: "active"
        )) == 1)
    }
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: firstLogicalID, state: "closed"),
      1
    )
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: secondLogicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: secondLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )
  }

  func testFailedAutomaticSequentialReopenRetainsMarkerForExplicitRetry() async throws {
    let paths = try makePaths()
    let fault = OneShotViewerStoreFault()
    let reopenGate = ArmableViewerExecutionGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: { try fault.check() },
      reopenExecutionGate: { reopenGate.run() }
    )
    let firstLogicalID = UUID()
    let secondLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: secondLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    fault.failNext()
    reopenGate.release()
    waitUntil { fault.failureCount == 1 && !runtime.isRecoveryInFlight }
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: secondLogicalID, state: "active"),
      0
    )

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: secondLogicalID,
          state: "active"
        )) == 1)
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: secondLogicalID
        )) == 1)
    }
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: firstLogicalID, state: "closed"),
      1
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 0)
    await runtime.runtimeEnded(
      logicalID: secondLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )
  }

  func testEndedRuntimeCancelsPausedAutomaticReopenAndPreservesNextAttempt() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let cancelledLogicalID = UUID()
    let laterLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: cancelledLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    let ended = LockedViewerCounter()
    let endTask = Task {
      await runtime.runtimeEnded(
        logicalID: cancelledLogicalID,
        wallMilliseconds: wallMilliseconds + 3_000,
        monotonicNanoseconds: 8_000
      )
      ended.increment()
    }
    waitUntil { resourceEvents.value.contains(.runtimeEndWaiting) }
    XCTAssertEqual(ended.value, 0)
    reopenGate.release()
    await endTask.value
    XCTAssertEqual(ended.value, 1)
    let cancelledPrefixFinished = expectation(description: "Cancelled reopen prefix finished")
    runtime.afterCurrentReopenPrefix { cancelledPrefixFinished.fulfill() }
    await fulfillment(of: [cancelledPrefixFinished], timeout: 2)
    XCTAssertEqual(
      resourceEvents.value,
      [.runtimeEndWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: cancelledLogicalID,
        state: "active"
      ),
      0
    )

    runtime.runtimeStarted(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 4_000,
      monotonicNanoseconds: 10_000
    )
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: laterLogicalID,
          state: "active"
        )) == 1)
    }
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: laterLogicalID),
      1
    )
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: firstLogicalID, state: "closed"),
      1
    )
    await runtime.runtimeEnded(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 5_000,
      monotonicNanoseconds: 12_000
    )
  }

  func testTerminalCloseCancelsPausedAutomaticReopen() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let cancelledLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: cancelledLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    let closed = LockedViewerCounter()
    let closeTask = Task.detached {
      runtime.closeStorage()
      closed.increment()
    }
    waitUntil { resourceEvents.value.contains(.terminalCloseWaiting) }
    XCTAssertEqual(closed.value, 0)
    reopenGate.release()
    await closeTask.value
    XCTAssertEqual(closed.value, 1)
    let cancelledPrefixFinished = expectation(description: "Terminal reopen prefix finished")
    runtime.afterCurrentReopenPrefix { cancelledPrefixFinished.fulfill() }
    await fulfillment(of: [cancelledPrefixFinished], timeout: 2)
    XCTAssertEqual(
      resourceEvents.value,
      [.terminalCloseWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: cancelledLogicalID,
        state: "active"
      ),
      0
    )
  }

  func testNewerRuntimeSupersedesPausedAutomaticReopen() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let supersededLogicalID = UUID()
    let currentLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: supersededLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    runtime.runtimeStarted(
      logicalID: currentLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )
    let supersededEnded = LockedViewerCounter()
    let supersededEndTask = Task {
      await runtime.runtimeEnded(
        logicalID: supersededLogicalID,
        wallMilliseconds: wallMilliseconds + 4_000,
        monotonicNanoseconds: 10_000
      )
      supersededEnded.increment()
    }
    waitUntil { resourceEvents.value.contains(.runtimeEndWaiting) }
    XCTAssertEqual(supersededEnded.value, 0)
    reopenGate.release()
    await supersededEndTask.value
    XCTAssertEqual(supersededEnded.value, 1)
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: currentLogicalID,
          state: "active"
        )) == 1)
    }
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: supersededLogicalID,
        state: "active"
      ),
      0
    )
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: currentLogicalID),
      1
    )
    XCTAssertEqual(
      Array(resourceEvents.value.prefix(3)),
      [.runtimeEndWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )

    await runtime.runtimeEnded(
      logicalID: supersededLogicalID,
      wallMilliseconds: wallMilliseconds + 4_500,
      monotonicNanoseconds: 11_000
    )
    XCTAssertEqual(runtime.status().state, .available)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: currentLogicalID,
        state: "active"
      ),
      1
    )
    await runtime.runtimeEnded(
      logicalID: currentLogicalID,
      wallMilliseconds: wallMilliseconds + 5_000,
      monotonicNanoseconds: 12_000
    )
  }

  func testFinalCurrentRuntimeWaitsForSupersededReopenConstruction() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let supersededLogicalID = UUID()
    let finalLogicalID = UUID()
    let laterLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: supersededLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    runtime.runtimeStarted(
      logicalID: finalLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )

    let finalEnded = LockedViewerCounter()
    let finalEndTask = Task {
      await runtime.runtimeEnded(
        logicalID: finalLogicalID,
        wallMilliseconds: wallMilliseconds + 4_000,
        monotonicNanoseconds: 10_000
      )
      finalEnded.increment()
    }
    waitUntil { resourceEvents.value.contains(.runtimeEndWaiting) }
    XCTAssertEqual(finalEnded.value, 0)
    reopenGate.release()
    await finalEndTask.value
    XCTAssertEqual(finalEnded.value, 1)
    let cancelledPrefixFinished = expectation(description: "Final runtime cancellation finished")
    runtime.afterCurrentReopenPrefix { cancelledPrefixFinished.fulfill() }
    await fulfillment(of: [cancelledPrefixFinished], timeout: 2)

    XCTAssertEqual(
      resourceEvents.value,
      [.runtimeEndWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 1)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: supersededLogicalID,
        state: "active"
      ),
      0
    )
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: finalLogicalID, state: "active"),
      0
    )

    await runtime.runtimeEnded(
      logicalID: supersededLogicalID,
      wallMilliseconds: wallMilliseconds + 4_500,
      monotonicNanoseconds: 11_000
    )
    runtime.runtimeStarted(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 5_000,
      monotonicNanoseconds: 12_000
    )
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: laterLogicalID,
          state: "active"
        )) == 1)
    }
    XCTAssertEqual(reopenGate.value, 2)
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: laterLogicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 6_000,
      monotonicNanoseconds: 14_000
    )
  }

  func testRepeatedRuntimeSupersessionCoalescesOneReopenSuccessor() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() }
    )
    let firstLogicalID = UUID()
    let blockedLogicalID = UUID()
    let supersedingLogicalIDs = (0..<64).map { _ in UUID() }
    let latestLogicalID = try XCTUnwrap(supersedingLogicalIDs.last)
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: blockedLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    for (index, logicalID) in supersedingLogicalIDs.enumerated() {
      runtime.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: wallMilliseconds + 3_000 + Int64(index),
        monotonicNanoseconds: 8_000 + UInt64(index)
      )
    }
    reopenGate.release()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: latestLogicalID,
          state: "active"
        )) == 1)
    }

    XCTAssertEqual(reopenGate.value, 2)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 2)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: blockedLogicalID, state: "active"),
      0
    )
    for logicalID in supersedingLogicalIDs.dropLast() {
      XCTAssertEqual(
        try latestRecordingStateCount(at: paths, logicalID: logicalID, state: "active"),
        0
      )
    }
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: latestLogicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: latestLogicalID,
      wallMilliseconds: wallMilliseconds + 5_000,
      monotonicNanoseconds: 12_000
    )
  }

  func testTerminalCloseDiscardsCoalescedReopenSuccessor() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let blockedLogicalID = UUID()
    let supersedingLogicalIDs = (0..<64).map { _ in UUID() }
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: blockedLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    for (index, logicalID) in supersedingLogicalIDs.enumerated() {
      runtime.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: wallMilliseconds + 3_000 + Int64(index),
        monotonicNanoseconds: 8_000 + UInt64(index)
      )
    }

    let closed = LockedViewerCounter()
    let closeTask = Task.detached {
      runtime.closeStorage()
      closed.increment()
    }
    waitUntil { resourceEvents.value.contains(.terminalCloseWaiting) }
    XCTAssertEqual(closed.value, 0)
    reopenGate.release()
    await closeTask.value
    XCTAssertEqual(closed.value, 1)
    let reopenPrefixFinished = expectation(description: "Coalesced terminal prefix finished")
    runtime.afterCurrentReopenPrefix { reopenPrefixFinished.fulfill() }
    await fulfillment(of: [reopenPrefixFinished], timeout: 2)

    XCTAssertEqual(reopenGate.value, 1)
    XCTAssertEqual(
      resourceEvents.value,
      [.terminalCloseWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 1)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: blockedLogicalID, state: "active"),
      0
    )
    for logicalID in supersedingLogicalIDs {
      XCTAssertEqual(
        try latestRecordingStateCount(at: paths, logicalID: logicalID, state: "active"),
        0
      )
    }
  }

  func testMidRuntimeNondurableDeviceObservationsBecomeRecordingGapAfterRetry() async throws {
    let paths = try makePaths()
    let fault = OneShotViewerStoreFault()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { try fault.check() })
    let logicalID = UUID()
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    waitUntil {
      coordinator.services.eventStore.status().logicalQuotaBytes > 0
    }

    let appID = try EndpointID(rawValue: "nondurable-app")
    let viewerID = try EndpointID(rawValue: "nondurable-viewer")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.example.nondurable"
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .viewer,
      installationID: viewerID
    )
    let connectionID = UUID()
    let context = ViewerAdmissionSessionContext(
      connectionID: connectionID,
      appHello: appHello,
      viewerHello: viewerHello,
      negotiation: try WireNegotiator.negotiate(local: appHello, remote: viewerHello),
      receiveChunkBytes: 64 * 1_024
    )
    fault.failNext()
    XCTAssertTrue(coordinator.sessionStarted(context))
    waitUntil { coordinator.services.eventStore.status().state == .writeFailed }

    let envelope = try EventEnvelope(
      id: EventID(),
      type: EventType.user("test.nondurable"),
      content: .object(["value": .integer(1)]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      monotonicTimestampNanoseconds: 3_000,
      source: EventEndpoint(role: .app, id: appID),
      target: EventEndpoint(role: .viewer, id: viewerID),
      direction: .appToViewer,
      sessionEpoch: SessionEpoch(),
      sequence: EventSequence(0),
      priority: .normal,
      ttl: .default,
      causality: EventCausality()
    )
    let received = try WireEventRecord(
      envelope: envelope,
      remainingTTLNanoseconds: 10_000_000_000
    ).receiverEvent(receivedAtNanoseconds: 4_000)
    coordinator.uplinkCommitted(
      connectionID: connectionID,
      event: received,
      initialDisposition: .buffered
    )
    XCTAssertTrue(
      coordinator.sessionEnded(
        connectionID: connectionID,
        wallMilliseconds: 2_000,
        monotonicNanoseconds: 5_000
      )
    )
    XCTAssertTrue(coordinator.retryStorage())
    waitUntil {
      coordinator.services.eventStore.status().state == .available
        && ((try? self.sumStorageUnavailableGaps(at: paths)) ?? 0) == 2
    }
    XCTAssertEqual(try sumStorageUnavailableGaps(at: paths), 2)

    await coordinator.runtimeEnded(wallMilliseconds: 3_000, monotonicNanoseconds: 6_000)
  }

  func testSameCoordinatorRecoveryDoesNotDuplicateDurableLiveDevices() async throws {
    let paths = try makePaths()
    let fault = OneShotViewerStoreFault()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { try fault.check() })
    let logicalID = UUID()
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    let durable = try makeAdmissionContext(suffix: "durable")
    let initiallyNondurable = try makeAdmissionContext(suffix: "retry")
    XCTAssertTrue(coordinator.sessionStarted(durable))
    waitUntil {
      (try? self.scalar(
        "SELECT COUNT(*) FROM DeviceSessions",
        at: paths
      )) == 1
    }

    fault.failNext()
    XCTAssertTrue(coordinator.sessionStarted(initiallyNondurable))
    waitUntil { coordinator.services.eventStore.status().state == .writeFailed }
    XCTAssertTrue(coordinator.retryStorage())
    XCTAssertTrue(
      coordinator.recoverRuntime(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000,
        missedObservationCount: 1
      )
    )
    for _ in 0..<2 {
      XCTAssertTrue(coordinator.recoverSession(durable))
      XCTAssertTrue(coordinator.recoverSession(initiallyNondurable))
    }
    waitUntil {
      coordinator.services.eventStore.status().state == .available
        && ((try? self.scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths)) == 2)
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 2)

    await coordinator.runtimeEnded(wallMilliseconds: 3_000, monotonicNanoseconds: 4_000)
    coordinator.closeStorage()
    let verification = try ViewerSQLitePool(migrating: paths)
    let counts = try verification.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM DeviceSessions", database: database),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM DeviceSessionVersions WHERE state='closed'",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM DeviceSessionVersions WHERE state='active'",
          database: database
        )
      )
    }
    XCTAssertEqual(counts.0, 2)
    XCTAssertEqual(counts.1, 2)
    XCTAssertEqual(counts.2, 2)
    XCTAssertEqual(
      try verification.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM DeviceSessionVersions v WHERE v.state='closed' AND v.rowID=(SELECT MAX(v2.rowID) FROM DeviceSessionVersions v2 WHERE v2.deviceSessionID=v.deviceSessionID)",
          database: $0
        )
      },
      2
    )
    verification.close()
  }

  func testMaintenanceOwnerRunsAtThresholdAndPeriodicWakeCanBeCancelled() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let scheduler = ManualViewerStoreScheduler()
    let statusSignal = ViewerStoreStatusSignal()
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      statusSignal: statusSignal
    )
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: scheduler.value
    )

    let thresholdRun = expectation(description: "Threshold maintenance")
    thresholdRun.assertForOverFulfill = false
    statusSignal.setHandler { _ in thresholdRun.fulfill() }
    owner.noteCommittedBytes(8 * 1_024 * 1_024, wallMilliseconds: 1_000)
    wait(for: [thresholdRun], timeout: 2)

    let sleepScheduled = expectation(description: "Periodic sleep scheduled")
    sleepScheduled.assertForOverFulfill = false
    scheduler.onSleep { sleepScheduled.fulfill() }
    owner.runtimeStarted()
    wait(for: [sleepScheduled], timeout: 2)

    let periodicRun = expectation(description: "Periodic maintenance")
    periodicRun.assertForOverFulfill = false
    statusSignal.setHandler { _ in periodicRun.fulfill() }
    scheduler.advance(by: 15 * 60 * 1_000_000_000)
    wait(for: [periodicRun], timeout: 2)

    let cancelledRun = expectation(description: "Cancelled periodic maintenance")
    cancelledRun.isInverted = true
    cancelledRun.assertForOverFulfill = false
    statusSignal.setHandler { _ in cancelledRun.fulfill() }
    owner.runtimeEnded()
    scheduler.advance(by: 15 * 60 * 1_000_000_000)
    wait(for: [cancelledRun], timeout: 0.2)
    statusSignal.setHandler { _ in }
  }

  func testLatestOnlyChangeSignalCarriesSafeRecordingAndUpperRowSnapshot() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let signal = ViewerStoreStatusSignal()
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      statusSignal: signal
    )
    let observed = LockedViewerStoreChange()
    let committed = expectation(description: "Event commit notification")
    committed.assertForOverFulfill = false
    signal.setHandler { snapshot in
      observed.set(snapshot)
      if snapshot.eventUpperRowID >= 1 { committed.fulfill() }
    }
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "change-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "secret")
    )
    wait(for: [committed], timeout: 2)
    let snapshot = try XCTUnwrap(observed.value)
    XCTAssertEqual(snapshot.changedRecordingIDs, [recording.rowID])
    XCTAssertEqual(snapshot.eventUpperRowID, 1)
    XCTAssertEqual(snapshot.status.state, .available)
    let forbiddenDiagnostics = [
      "secret", String(recording.rowID), String(snapshot.eventUpperRowID),
    ]
    let diagnostics = [
      String(describing: snapshot),
      snapshot.debugDescription,
      String(reflecting: snapshot),
      "\(snapshot)",
    ]
    for diagnostic in diagnostics {
      for forbidden in forbiddenDiagnostics {
        XCTAssertFalse(diagnostic.contains(forbidden))
      }
    }
    XCTAssertTrue(Mirror(reflecting: snapshot).children.isEmpty)
  }

  func testExportUsesAliasesAndDisclosureWithoutRawInstallationIdentifier() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "raw-installation-must-not-export",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: nil
    )
    let correlationID = EventID()
    let replyTo = EventID()
    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "exported",
        causality: EventCausality(correlationID: correlationID, replyTo: replyTo)
      )
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "testGap",
        count: 2,
        firstWallMilliseconds: 1_100,
        lastWallMilliseconds: 1_100,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 2
      )
    )
    let leases = ViewerStoreLeaseRegistry()
    let maintenance = ViewerStoreMaintenance(
      pool: pool, leases: leases, configuration: { .default })
    _ = try maintenance.appendAnnotation(
      recordingID: recording.rowID,
      body: "annotation",
      wallMilliseconds: 1_200
    )
    let exporter = ViewerStoreExportService(pool: pool, leases: leases)
    let destination = paths.directory.appendingPathComponent("out.json")
    try Data("old-destination".utf8).write(to: destination)
    let preflight = try exporter.preflight(recordingID: recording.rowID)
    XCTAssertEqual(preflight.eventCount, 1)
    XCTAssertTrue(preflight.disclosure.unencrypted)
    try exporter.export(recordingID: recording.rowID, to: destination)
    let data = try Data(contentsOf: destination)
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(text.contains("device-1"))
    XCTAssertTrue(text.contains("connection-1"))
    XCTAssertTrue(text.contains("aliasesArePseudonymsNotRedaction"))
    XCTAssertFalse(text.contains("raw-installation-must-not-export"))
    XCTAssertFalse(text.contains("sessionEpoch"))
    XCTAssertFalse(text.contains("pairingCode"))
    XCTAssertFalse(text.contains("certificate"))
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertEqual(
      Set(root.keys),
      Set(["schemaVersion", "disclosure", "session", "devices", "events", "gaps", "annotations"])
    )
    XCTAssertEqual((root["events"] as? [[String: Any]])?.count, 1)
    let exportedCausality =
      (root["events"] as? [[String: Any]])?.first?["causality"]
      as? [String: String]
    XCTAssertEqual(exportedCausality?["correlationID"], correlationID.rawValue)
    XCTAssertEqual(exportedCausality?["replyTo"], replyTo.rawValue)
    XCTAssertEqual((root["gaps"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual((root["annotations"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual(try permissions(destination), 0o600)
  }

  func testExportCommitBoundaryPreservesDestinationAcrossInjectedFailuresAndCancellation() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "export")
    )
    let leases = ViewerStoreLeaseRegistry()
    let destination = paths.directory.appendingPathComponent("atomic-export.json")
    let old = Data("old-destination".utf8)
    let precommitPhases: [ViewerExportFilePhase] = [
      .temporaryCreated,
      .beforeOpen,
      .beforeWrite,
      .afterWrite,
      .beforeFileSync,
      .afterFileSync,
      .beforeClose,
      .afterClose,
      .beforeCommitSeal,
      .beforeDirectoryOpen,
      .beforeRename,
    ]

    for phase in precommitPhases {
      try old.write(to: destination)
      let exporter = ViewerStoreExportService(
        pool: pool,
        leases: leases,
        filePhases: ViewerExportFilePhaseObserver { reached in
          if reached == phase { throw ViewerStoreError.invalidPath }
        }
      )
      XCTAssertThrowsError(
        try exporter.export(recordingID: recording.rowID, to: destination),
        "Expected injected failure at \(phase)."
      ) { error in
        XCTAssertEqual(error as? ViewerStoreError, .invalidPath)
      }
      XCTAssertEqual(try Data(contentsOf: destination), old)
    }

    let cancellationBox = ViewerExportCancellationBox()
    try old.write(to: destination)
    let cancelledExporter = ViewerStoreExportService(
      pool: pool,
      leases: leases,
      filePhases: ViewerExportFilePhaseObserver { phase in
        if phase == .beforeCommitSeal { cancellationBox.cancel() }
      }
    )
    cancellationBox.exporter = cancelledExporter
    XCTAssertThrowsError(
      try cancelledExporter.export(recordingID: recording.rowID, to: destination)
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
    XCTAssertEqual(try Data(contentsOf: destination), old)

    for phase in [ViewerExportFilePhase.afterRename, .directorySync] {
      try old.write(to: destination)
      let committedExporter = ViewerStoreExportService(
        pool: pool,
        leases: leases,
        filePhases: ViewerExportFilePhaseObserver { reached in
          if reached == phase { throw ViewerStoreError.invalidPath }
        }
      )
      try committedExporter.export(recordingID: recording.rowID, to: destination)
      XCTAssertNotEqual(try Data(contentsOf: destination), old)
    }

    try old.write(to: destination)
    let duringCommitBox = ViewerExportCancellationBox()
    let commitExporter = ViewerStoreExportService(
      pool: pool,
      leases: leases,
      filePhases: ViewerExportFilePhaseObserver { phase in
        if phase == .beforeRename { duringCommitBox.cancel() }
      }
    )
    duringCommitBox.exporter = commitExporter
    try commitExporter.export(recordingID: recording.rowID, to: destination)
    XCTAssertNotEqual(try Data(contentsOf: destination), old)
  }

  func testExportRejectsTemporaryLeafHardLinkAndParentSubstitution() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "export")
    )
    let leases = ViewerStoreLeaseRegistry()
    let old = Data("old-destination".utf8)

    for usesHardLink in [false, true] {
      let name = usesHardLink ? "hard-link.json" : "regular-substitution.json"
      let destination = paths.directory.appendingPathComponent(name)
      try old.write(to: destination)
      let unrelated = paths.directory.appendingPathComponent("unrelated-\(name)")
      let unrelatedData = Data("unrelated-marker".utf8)
      try unrelatedData.write(to: unrelated)
      let exporter = ViewerStoreExportService(
        pool: pool,
        leases: leases,
        filePhases: ViewerExportFilePhaseObserver { phase in
          guard phase == .afterWrite else { return }
          let temporary = try FileManager.default.contentsOfDirectory(
            at: paths.directory,
            includingPropertiesForKeys: nil
          ).first {
            $0.lastPathComponent.hasPrefix(".\(name).") && $0.pathExtension == "tmp"
          }
          guard let temporary else { throw ViewerStoreError.invalidPath }
          try FileManager.default.removeItem(at: temporary)
          if usesHardLink {
            guard link(unrelated.path, temporary.path) == 0 else {
              throw ViewerStoreError.invalidPath
            }
          } else {
            guard
              FileManager.default.createFile(
                atPath: temporary.path,
                contents: Data("substitute".utf8)
              )
            else { throw ViewerStoreError.invalidPath }
          }
        }
      )
      XCTAssertThrowsError(
        try exporter.export(recordingID: recording.rowID, to: destination)
      ) { XCTAssertEqual($0 as? ViewerStoreError, .invalidPath) }
      XCTAssertEqual(try Data(contentsOf: destination), old)
      XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedData)
    }

    let parent = paths.directory.appendingPathComponent("export-parent", isDirectory: true)
    let movedParent = paths.directory.appendingPathComponent("moved-parent", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let destination = parent.appendingPathComponent("parent.json")
    try old.write(to: destination)
    let exporter = ViewerStoreExportService(
      pool: pool,
      leases: leases,
      filePhases: ViewerExportFilePhaseObserver { phase in
        guard phase == .beforeRename else { return }
        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try old.write(to: destination)
      }
    )
    XCTAssertThrowsError(
      try exporter.export(recordingID: recording.rowID, to: destination)
    ) { XCTAssertEqual($0 as? ViewerStoreError, .invalidPath) }
    XCTAssertEqual(try Data(contentsOf: destination), old)
  }

  func testFrozenQueryExportExcludesLaterEventsAndRejectsMixedCursor() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "alpha")
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 2, value: "beta")
    )
    let leases = ViewerStoreLeaseRegistry()
    let queryService = ViewerStoreQueryService(pool: pool, leases: leases)
    let alphaQuery = try ViewerEventQuery(
      recordingID: recording.rowID,
      predicates: [.json(path: "$.message", equals: .string("alpha"))]
    )
    let alphaTraversal = try queryService.begin(query: alphaQuery)
    let (alphaPage, refreshedAlphaTraversal) = try queryService.page(
      traversal: alphaTraversal,
      cursor: nil,
      direction: .forward,
      limit: 1
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 3, value: "alpha")
    )
    let betaTraversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [.json(path: "$.message", equals: .string("beta"))]
      )
    )
    XCTAssertThrowsError(
      try queryService.page(
        traversal: betaTraversal,
        cursor: alphaPage.nextCursor,
        direction: .forward,
        limit: 1
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidValue)
    }

    let exporter = ViewerStoreExportService(pool: pool, leases: leases)
    XCTAssertEqual(try exporter.preflight(traversal: refreshedAlphaTraversal).eventCount, 1)
    let destination = paths.directory.appendingPathComponent("query.json")
    try exporter.export(traversal: refreshedAlphaTraversal, to: destination)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    let events = try XCTUnwrap(root["events"] as? [[String: Any]])
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual((events[0]["content"] as? [String: Any])?["message"] as? String, "alpha")
  }

  func testQueryUsesDimensionAndValueOrWithStableBidirectionalKeysets() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1.0"
    )
    let firstID = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "first",
        viewerMonotonicNanoseconds: 10_000
      )
    )
    let secondID = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "second",
        direction: .viewerToApp,
        viewerMonotonicNanoseconds: 10_000
      )
    )
    let thirdID = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 2,
        value: "third",
        viewerMonotonicNanoseconds: 10_000
      )
    )
    let service = ViewerStoreQueryService(pool: pool, leases: ViewerStoreLeaseRegistry())
    let query = try ViewerEventQuery(
      recordingID: recording.rowID,
      predicates: [
        .eventTypeEqualsAny(["test.metric", "test.other"]),
        .applicationIdentifiers(["com.invalid", "com.example.app"]),
        .applicationVersions(["1.0", "2.0"]),
        .directions(["appToViewer", "viewerToApp"]),
        .priorities(["normal", "high"]),
      ]
    )
    let traversal = try service.begin(query: query)
    let (firstPage, secondTraversal) = try service.page(
      traversal: traversal,
      cursor: nil,
      direction: .forward,
      limit: 2
    )
    XCTAssertEqual(firstPage.rows.map(\.rowID), [firstID, secondID])
    let (secondPage, thirdTraversal) = try service.page(
      traversal: secondTraversal,
      cursor: firstPage.nextCursor,
      direction: .forward,
      limit: 2
    )
    XCTAssertEqual(secondPage.rows.map(\.rowID), [thirdID])
    let (previousPage, _) = try service.page(
      traversal: thirdTraversal,
      cursor: secondPage.previousCursor,
      direction: .backward,
      limit: 2
    )
    XCTAssertEqual(previousPage.rows.map(\.rowID), [firstID, secondID])
  }

  func testQueryLeaseExpiresAndCannotBeRefreshed() throws {
    let registry = ViewerStoreLeaseRegistry()
    let start = ContinuousClock.now
    let lease = try registry.acquireQuery(recordingID: 1, now: start)
    XCTAssertThrowsError(try registry.validateQuery(lease, now: start + .seconds(61))) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
    XCTAssertThrowsError(try registry.touchQuery(lease, now: start + .seconds(61))) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
  }

  func testExportLeaseExpiresAtExactAbsoluteBoundary() throws {
    let leases = ViewerStoreLeaseRegistry()
    let now = ContinuousClock.now
    let lease = try leases.acquireExport(recordingID: 1, now: now)
    XCTAssertNoThrow(try leases.validateExport(lease, now: now + .seconds(3_599)))
    XCTAssertThrowsError(try leases.validateExport(lease, now: now + .seconds(3_600))) {
      XCTAssertEqual($0 as? ViewerStoreError, .cancelled)
    }
    XCTAssertNoThrow(try leases.acquireExport(recordingID: 1, now: now + .seconds(3_600)))
  }

  func testSustainedBatchesKeepWALBoundedAndStoreArtifactsSecureThroughClose() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "sustained"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "sustained-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    for batch in 0..<10 {
      let observations = try (0..<100).map { offset in
        try makeObservation(
          recording: recording,
          device: device,
          sequence: UInt64(batch * 100 + offset + 1),
          value: "event-\(batch)-\(offset)"
        )
      }
      XCTAssertEqual(try store.appendEvents(observations).count, 100)
    }
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      1_000
    )
    let walBytes = Int64(
      (try paths.wal.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
    )
    print("NearWire sustained WAL allocated bytes: \(walBytes)")
    XCTAssertGreaterThan(walBytes, 0)
    XCTAssertLessThan(walBytes, 64 * 1_024 * 1_024)
    for url in [paths.database, paths.wal, paths.sharedMemory] {
      XCTAssertEqual(try permissions(url), 0o600)
      XCTAssertTrue(try isRegularFileWithoutFollowingLinks(url))
    }
    pool.close()
    XCTAssertEqual(try permissions(paths.directory), 0o700)
    for url in [
      paths.database, paths.wal, paths.sharedMemory, paths.journal, paths.exportTemporary,
    ]
    where FileManager.default.fileExists(atPath: url.path) {
      XCTAssertEqual(try permissions(url), 0o600)
      XCTAssertTrue(try isRegularFileWithoutFollowingLinks(url))
    }
  }

  func testNearMaximumPayloadUsesBoundedOversizeTransaction() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "maximum-payload"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "maximum-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    let segmentBytes = 64 * 1_024
    let segmentCount = 240
    let payloadBytes = segmentBytes * segmentCount
    let payload = Array(
      repeating: JSONValue.string(String(repeating: "x", count: segmentBytes)),
      count: segmentCount
    )
    let nearMaximumLimits = try EventValidationLimits(
      maximumEncodedContentBytes: 16 * 1_024 * 1_024,
      maximumEncodedModelBytes: 65 * 1_024 * 1_024
    )
    let observation = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "maximum",
      content: .object(["payload": .array(payload)]),
      validationLimits: nearMaximumLimits
    )
    XCTAssertLessThanOrEqual(observation.deterministicEventBytes, 20 * 1_024 * 1_024)
    XCTAssertGreaterThan(observation.deterministicEventBytes, 15 * 1_024 * 1_024)
    XCTAssertGreaterThan(try store.appendEvent(observation), 0)
    let storedContentBytes = try pool.queryReader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64("SELECT length(contentJSON) FROM Events", database: $0)
    }
    XCTAssertGreaterThan(storedContentBytes, Int64(payloadBytes))
    XCTAssertLessThan(storedContentBytes, Int64(payloadBytes + 1_024))
    print("NearWire near-maximum deterministic Event bytes: \(observation.deterministicEventBytes)")
  }

  func testRevisionBoundDeleteHonorsLeaseAndMaintenanceReclaimsSession() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let leases = ViewerStoreLeaseRegistry()
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: leases,
      configuration: { .default }
    )
    let lease = try leases.acquireQuery(recordingID: recording.rowID)
    let blockedConfirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    XCTAssertThrowsError(
      try maintenance.requestDelete(
        blockedConfirmation,
        wallMilliseconds: 3_000
      )
    )
    leases.release(lease)
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    try maintenance.requestDelete(
      confirmation,
      wallMilliseconds: 3_000
    )
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 4_000)
    let count = try pool.queryReader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Recordings", database: $0)
    }
    XCTAssertEqual(count, 0)
  }

  func testCapacityCleanupStartsAboveOneHundredPercentAndTargetsEightyFivePercent() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 3_650
    )
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    for index in 0..<7 {
      let recording = try store.beginRecording(
        wallMilliseconds: Int64(1_000 + index),
        monotonicNanoseconds: UInt64(2_000 + index),
        reason: "test"
      )
      try store.appendStructural(
        .closeRecording(
          recording,
          wallMilliseconds: Int64(3_000 + index),
          monotonicNanoseconds: UInt64(4_000 + index)
        )
      )
    }
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { configuration }
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=57*1024*1024 WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 5_000)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: $0)
      },
      0
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=64*1024*1024 WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 5_000)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: $0)
      },
      0
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=10*1024*1024",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=70*1024*1024 WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 5_000)
    let result = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings WHERE rowID NOT IN (SELECT recordingID FROM Tombstones)",
          database: database
        )
      )
    }
    XCTAssertEqual(result.0, 50 * 1_024 * 1_024)
    XCTAssertEqual(result.1, 5)
  }

  func testCapacityPauseRunsOneRecoveryAndExplicitProbeResumesAfterCapacityIncrease() throws {
    let configuration = LockedStorageConfiguration()
    configuration.set(
      try ViewerStorageConfiguration(capacityBytes: 64 * 1_024 * 1_024, historyRetentionDays: 7)
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { configuration.value! })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=64*1024*1024 WHERE rowID=\(recording.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=64*1024*1024 WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    let recoveryCount = LockedCounter()
    store.setCapacityRecovery { _, _ in recoveryCount.increment() }
    let observation = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "capacity"
    )
    XCTAssertThrowsError(try store.appendEvent(observation)) { error in
      XCTAssertEqual(error as? ViewerStoreError, .capacityExceeded)
    }
    XCTAssertEqual(recoveryCount.value, 1)
    XCTAssertEqual(store.status().state, .capacityPaused)

    configuration.set(
      try ViewerStorageConfiguration(capacityBytes: 128 * 1_024 * 1_024, historyRetentionDays: 7)
    )
    try store.retry()
    XCTAssertNoThrow(try store.appendEvent(observation))
    XCTAssertEqual(store.status().state, .available)
  }

  func testConcurrentMetadataAndEventCapacityAdmissionUsesWriterOrdering() throws {
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 3_650
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { configuration },
      storeStateReporter: { store.writeStateRelay.reportFailure($0) },
      recoveryPermitProvider: { store.writeStateRelay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        store.writeStateRelay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try store.writeStateRelay.validate($0) },
      recoveryValidator: { try store.writeStateRelay.validate($0) },
      recoveryCompleter: { try store.writeStateRelay.completeRecovery($0) }
    )
    store.setCapacityRecovery { pending, permit in
      try maintenance.run(
        trigger: .threshold,
        nowWallMilliseconds: 10_000,
        pendingReservationBytes: pending,
        recoveryPermit: permit
      )
    }
    let target = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "target"
    )
    let device = try store.beginDeviceSession(
      recording: target,
      installationID: "capacity-target",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Target"
    )

    func addEligible(_ suffix: Int) throws -> ViewerRecordingHandle {
      let recording = try store.beginRecording(
        wallMilliseconds: Int64(2_000 + suffix),
        monotonicNanoseconds: UInt64(3_000 + suffix),
        reason: "eligible"
      )
      try store.appendStructural(
        .closeRecording(
          recording,
          wallMilliseconds: Int64(4_000 + suffix),
          monotonicNanoseconds: UInt64(5_000 + suffix)
        )
      )
      try pool.writer.run { database in
        try ViewerSQLiteConnection.execute(
          "UPDATE Recordings SET liveQuotaBytes=4194304 WHERE rowID=\(recording.rowID)",
          on: database
        )
        try ViewerSQLiteConnection.execute(
          "UPDATE StoreMetadata SET integerValue=\(configuration.capacityBytes - 1) WHERE key='logicalQuotaBytes'",
          on: database
        )
      }
      return recording
    }

    func concurrently(
      _ first: @escaping @Sendable () throws -> Void,
      _ second: @escaping @Sendable () throws -> Void
    ) throws {
      let errors = LockedViewerStoreErrors()
      let group = DispatchGroup()
      for operation in [first, second] {
        group.enter()
        DispatchQueue.global().async {
          do { try operation() } catch { errors.append(error as? ViewerStoreError) }
          group.leave()
        }
      }
      XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
      XCTAssertTrue(
        errors.values.allSatisfy {
          $0 == .writeNotAuthorized || $0 == .capacityExceeded
        }
      )
      if store.status().state != .available { try store.retry() }
    }

    _ = try addEligible(1)
    try concurrently(
      {
        _ = try maintenance.appendAnnotation(
          recordingID: target.rowID,
          body: "first",
          wallMilliseconds: 6_001
        )
      },
      {
        _ = try maintenance.appendAnnotation(
          recordingID: target.rowID,
          body: "second",
          wallMilliseconds: 6_002
        )
      }
    )

    _ = try addEligible(2)
    let eventRace = try makeObservation(
      recording: target,
      device: device,
      sequence: 1,
      value: "race"
    )
    try concurrently(
      {
        _ = try maintenance.appendAnnotation(
          recordingID: target.rowID,
          body: "event-race",
          wallMilliseconds: 6_003
        )
      },
      { _ = try store.appendEvent(eventRace) }
    )

    _ = try addEligible(3)
    let metadataRace = try makeObservation(
      recording: target,
      device: device,
      sequence: 2,
      value: "metadata-race"
    )
    try concurrently(
      {
        _ = try maintenance.updateRecording(
          ViewerRecordingRevision(recordingID: target.rowID, revision: 1),
          name: "Updated",
          note: nil,
          pinned: false,
          wallMilliseconds: 6_004
        )
      },
      { _ = try store.appendEvent(metadataRace) }
    )

    XCTAssertEqual(store.status().state, .available)
    let annotationCount = try pool.queryReader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64(
        "SELECT COUNT(*) FROM AnnotationVersions WHERE recordingID=\(target.rowID)",
        database: $0
      )
    }
    XCTAssertGreaterThanOrEqual(annotationCount, 0)
    XCTAssertLessThanOrEqual(annotationCount, 3)

    let protected = try store.beginRecording(
      wallMilliseconds: 7_000,
      monotonicNanoseconds: 8_000,
      reason: "protected"
    )
    try store.appendStructural(
      .closeRecording(protected, wallMilliseconds: 7_100, monotonicNanoseconds: 8_100)
    )
    _ = try maintenance.updateRecording(
      ViewerRecordingRevision(recordingID: protected.rowID, revision: 2),
      name: nil,
      note: nil,
      pinned: true,
      wallMilliseconds: 7_200
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=4194304 WHERE rowID=\(protected.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=\(configuration.capacityBytes) WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    XCTAssertThrowsError(
      try maintenance.appendAnnotation(
        recordingID: target.rowID,
        body: "protected-capacity",
        wallMilliseconds: 7_300
      )
    ) { XCTAssertEqual($0 as? ViewerStoreError, .capacityExceeded) }
    XCTAssertEqual(store.status().state, .capacityPaused)
    pool.close()
  }

  func testProjectedReservationCrossingCapacityReclaimsEligibleHistoryThenAdmits() throws {
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 3_650
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    let old = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "old"
    )
    try store.appendStructural(
      .closeRecording(old, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let active = try store.beginRecording(
      wallMilliseconds: 3_000,
      monotonicNanoseconds: 4_000,
      reason: "active"
    )
    let device = try store.beginDeviceSession(
      recording: active,
      installationID: "active-device",
      wallMilliseconds: 3_000,
      monotonicNanoseconds: 4_000,
      partialHistory: false,
      displayName: "Active"
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=10*1024*1024 WHERE rowID=\(old.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=54*1024*1024-512 WHERE rowID=\(active.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=64*1024*1024-512 WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { configuration },
      activeRecordingIDs: { [active.rowID] }
    )
    store.setCapacityRecovery { pending, permit in
      try maintenance.run(
        trigger: .threshold,
        nowWallMilliseconds: 5_000,
        pendingReservationBytes: pending,
        recoveryPermit: permit
      )
    }
    _ = try store.appendEvent(
      makeObservation(recording: active, device: device, sequence: 1, value: "crossing")
    )
    let state = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings WHERE rowID=\(old.rowID) AND rowID NOT IN (SELECT recordingID FROM Tombstones)",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: database)
      )
    }
    XCTAssertEqual(state.0, 0)
    XCTAssertEqual(state.1, 1)
    XCTAssertEqual(store.status().state, .available)
  }

  func testWholeTransactionPlanIncludesInitialDispositionAndDuplicateIsZeroQuota() throws {
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 3_650
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    let old = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "old"
    )
    try store.appendStructural(
      .closeRecording(old, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let active = try store.beginRecording(
      wallMilliseconds: 3_000,
      monotonicNanoseconds: 4_000,
      reason: "active"
    )
    let device = try store.beginDeviceSession(
      recording: active,
      installationID: "active-device",
      wallMilliseconds: 3_000,
      monotonicNanoseconds: 4_000,
      partialHistory: false,
      displayName: "Active"
    )
    let observation = try makeObservation(
      recording: active,
      device: device,
      sequence: 1,
      value: "whole-transaction"
    )
    let oldQuota = Int64(10 * 1_024 * 1_024)
    let currentQuota = configuration.capacityBytes - observation.quotaBytes
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=\(oldQuota) WHERE rowID=\(old.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=\(currentQuota - oldQuota) WHERE rowID=\(active.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=\(currentQuota) WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { configuration },
      activeRecordingIDs: { [active.rowID] }
    )
    store.setCapacityRecovery { pending, permit in
      try maintenance.run(
        trigger: .threshold,
        nowWallMilliseconds: 5_000,
        pendingReservationBytes: pending,
        recoveryPermit: permit
      )
    }

    let eventID = try store.appendEvent(observation)
    XCTAssertGreaterThan(eventID, 0)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings WHERE rowID=\(old.rowID)",
          database: $0
        )
      },
      0
    )

    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=\(configuration.capacityBytes) WHERE rowID=\(active.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=\(configuration.capacityBytes) WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    XCTAssertEqual(try store.appendEvent(observation), eventID)
    XCTAssertEqual(store.status().state, .available)
  }

  func testIngressRetainsFailedPrefixUntilExplicitRetry() async throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let fault = OneShotViewerStoreFault()
    let signal = ViewerStoreStatusSignal()
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      writeGate: { try fault.check() },
      statusSignal: signal
    )
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    let ingress = ViewerStoreIngress(store: store)
    let failed = expectation(description: "Write failed")
    failed.assertForOverFulfill = false
    signal.setHandler { _ in
      if store.status().state == .writeFailed { failed.fulfill() }
    }
    fault.failNext()
    XCTAssertEqual(
      ingress.admit(
        try makeObservation(recording: recording, device: device, sequence: 1, value: "one")),
      .admitted
    )
    await fulfillment(of: [failed], timeout: 2)
    let failedFlush = await ingress.flush()
    XCTAssertEqual(failedFlush, .writeFailed)
    XCTAssertEqual(store.status().state, .writeFailed)
    let lifecycleBudget = ViewerJournalPipelineBudget()
    let closeReservation = try XCTUnwrap(
      lifecycleBudget.reserve(bytes: 0, kind: .lifecycle)
    )
    XCTAssertEqual(
      ingress.admit(
        .closeDevice(device, wallMilliseconds: 3_000, monotonicNanoseconds: 4_000),
        reservation: closeReservation
      ),
      .stopped
    )
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      0
    )

    let committed = expectation(description: "Retained prefix committed")
    committed.assertForOverFulfill = false
    signal.setHandler { _ in
      if store.status().state == .available { committed.fulfill() }
    }
    try store.retry()
    await fulfillment(of: [committed], timeout: 2)
    _ = await ingress.flush()
    signal.setHandler { _ in }
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      1
    )
    pool.close()
  }

  func testPhasedReclaimDeletesEveryRecordingOwnedTable() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "event")
    )
    try store.appendStructural(
      .policy(
        device: device,
        sequence: 1,
        wallMilliseconds: 1_100,
        monotonicNanoseconds: 2_100,
        policyJSON: ViewerCanonicalJSON.encode(ViewerRatePolicy.default)
      )
    )
    try store.appendStructural(
      .drop(
        device: device,
        sequence: 1,
        wallMilliseconds: 1_100,
        monotonicNanoseconds: 2_100,
        reason: "localOverflow",
        count: 1
      )
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "testGap",
        count: 1,
        firstWallMilliseconds: 1_100,
        lastWallMilliseconds: 1_100,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      )
    )
    try store.appendStructural(
      .closeDevice(device, wallMilliseconds: 1_200, monotonicNanoseconds: 2_200)
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 1_300, monotonicNanoseconds: 2_300)
    )
    let leases = ViewerStoreLeaseRegistry()
    let maintenance = ViewerStoreMaintenance(
      pool: pool, leases: leases, configuration: { .default })
    _ = try maintenance.appendAnnotation(
      recordingID: recording.rowID,
      body: "annotation",
      wallMilliseconds: 1_400
    )
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    try maintenance.requestDelete(
      confirmation,
      wallMilliseconds: 1_500
    )
    for _ in 0..<6 {
      try maintenance.run(trigger: .explicit, nowWallMilliseconds: 1_600)
    }
    let remaining = try pool.queryReader.run(budget: .query()) { database in
      try ViewerStoreSchema.scalarInt64(
        "SELECT (SELECT COUNT(*) FROM Recordings)+(SELECT COUNT(*) FROM RecordingVersions)+(SELECT COUNT(*) FROM InstallationAliases)+(SELECT COUNT(*) FROM DeviceSessions)+(SELECT COUNT(*) FROM DeviceSessionVersions)+(SELECT COUNT(*) FROM Events)+(SELECT COUNT(*) FROM EventDispositionVersions)+(SELECT COUNT(*) FROM PolicyVersions)+(SELECT COUNT(*) FROM DropVersions)+(SELECT COUNT(*) FROM GapVersions)+(SELECT COUNT(*) FROM AnnotationVersions)+(SELECT COUNT(*) FROM Tombstones)",
        database: database
      )
    }
    XCTAssertEqual(remaining, 0)
    XCTAssertEqual(store.status().logicalQuotaBytes, 0)
  }

  func testTextBoundsRejectControlsAndAllowMultilineNotes() throws {
    XCTAssertEqual(try ViewerTextRules.recordingName("A name"), "A name")
    XCTAssertThrowsError(try ViewerTextRules.recordingName("line\nbreak"))
    XCTAssertEqual(try ViewerTextRules.noteOrAnnotation("line\n\tnext"), "line\n\tnext")
    XCTAssertThrowsError(try ViewerTextRules.noteOrAnnotation("bad\u{0}value"))
  }

  func testInvalidStructuralObservationsCannotTriggerCapacityCleanup() throws {
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 3_650
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    let eligible = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "eligible"
    )
    try store.appendStructural(
      .closeRecording(eligible, wallMilliseconds: 1_100, monotonicNanoseconds: 2_100)
    )
    let recording = try store.beginRecording(
      wallMilliseconds: 1_200,
      monotonicNanoseconds: 2_200,
      reason: "active"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "invalid-structural",
      wallMilliseconds: 1_200,
      monotonicNanoseconds: 2_200,
      partialHistory: false,
      displayName: "Device"
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { configuration }
    )
    store.setCapacityRecovery { pending, permit in
      try maintenance.run(
        trigger: .threshold,
        nowWallMilliseconds: 2_000,
        pendingReservationBytes: pending,
        recoveryPermit: permit
      )
    }
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=1048576 WHERE rowID=\(eligible.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=\(configuration.capacityBytes) WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    let invalid: [ViewerStructuralObservation] = [
      .policy(
        device: device,
        sequence: 1,
        wallMilliseconds: 2_000,
        monotonicNanoseconds: 3_000,
        policyJSON: Data(repeating: 0x61, count: 4_097)
      ),
      .drop(
        device: device,
        sequence: 1,
        wallMilliseconds: 2_000,
        monotonicNanoseconds: 3_000,
        reason: "invalid",
        count: 0
      ),
      .drop(
        device: device,
        sequence: 2,
        wallMilliseconds: 2_000,
        monotonicNanoseconds: 3_000,
        reason: String(repeating: "x", count: 129),
        count: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "invalid",
        count: 0,
        firstWallMilliseconds: 2_000,
        lastWallMilliseconds: 2_000,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 2,
        reason: "invalid",
        count: 1,
        firstWallMilliseconds: 2_000,
        lastWallMilliseconds: 1_999,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 3,
        reason: "invalid",
        count: 1,
        firstWallMilliseconds: 2_000,
        lastWallMilliseconds: 2_000,
        directions: "invalid",
        firstWireSequence: 1,
        lastWireSequence: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 4,
        reason: "invalid",
        count: 1,
        firstWallMilliseconds: 2_000,
        lastWallMilliseconds: 2_000,
        directions: "appToViewer",
        firstWireSequence: 2,
        lastWireSequence: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 5,
        reason: String(repeating: "x", count: 129),
        count: 1,
        firstWallMilliseconds: 2_000,
        lastWallMilliseconds: 2_000,
        directions: "appToViewer",
        firstWireSequence: nil,
        lastWireSequence: 1
      ),
    ]
    for observation in invalid {
      XCTAssertThrowsError(try store.appendStructural(observation)) {
        XCTAssertEqual($0 as? ViewerStoreError, .invalidValue)
      }
    }
    let result = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: database),
        try ViewerStoreSchema.scalarInt64(
          "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
          database: database
        )
      )
    }
    XCTAssertEqual(result.0, 0)
    XCTAssertEqual(result.1, configuration.capacityBytes)
    pool.close()
  }

  func testPipelineBudgetIsSharedAcrossPreparationAndIngressOwnership() throws {
    let limits = ViewerStoreIngressLimits(maximumCount: 2, maximumBytes: 10)
    let budget = ViewerJournalPipelineBudget(limits: limits)
    var first: ViewerJournalPipelineBudget.Reservation? = budget.reserve(bytes: 6, kind: .event)
    var second: ViewerJournalPipelineBudget.Reservation? = budget.reserve(bytes: 4, kind: .event)
    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertNil(budget.reserve(bytes: 1, kind: .event))
    var snapshot = budget.snapshot()
    XCTAssertEqual(snapshot.eventCount, 2)
    XCTAssertEqual(snapshot.eventBytes, 10)
    first = nil
    XCTAssertNotNil(budget.reserve(bytes: 6, kind: .event))
    second = nil

    var structural: [ViewerJournalPipelineBudget.Reservation] = []
    for _ in 0..<18 {
      structural.append(try XCTUnwrap(budget.reserve(bytes: 0, kind: .structural)))
    }
    XCTAssertNil(budget.reserve(bytes: 0, kind: .structural))
    var lifecycle: [ViewerJournalPipelineBudget.Reservation] = []
    for _ in 0..<18 {
      lifecycle.append(try XCTUnwrap(budget.reserve(bytes: 0, kind: .lifecycle)))
    }
    XCTAssertNil(budget.reserve(bytes: 0, kind: .lifecycle))
    snapshot = budget.snapshot()
    XCTAssertEqual(snapshot.structuralCount, 36)
    structural.removeAll()
    XCTAssertEqual(budget.snapshot().structuralCount, 18)
    lifecycle.removeAll()
    XCTAssertEqual(budget.snapshot().structuralCount, 0)
  }

  func testMissingInitialTransitionBecomesIdempotentGapWithoutPoisoningWriter() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "installation",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1"
    )
    let transition = ViewerStructuralObservation.disposition(
      recording: recording,
      device: device,
      direction: .appToViewer,
      wireSequence: 7,
      value: .expired,
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100
    )
    try store.appendStructural(transition)
    try store.appendStructural(
      .disposition(
        recording: recording,
        device: device,
        direction: .appToViewer,
        wireSequence: 7,
        value: .expired,
        wallMilliseconds: 1_200,
        monotonicNanoseconds: 2_200
      )
    )
    XCTAssertThrowsError(
      try store.appendStructural(
        .disposition(
          recording: recording,
          device: device,
          direction: .appToViewer,
          wireSequence: 7,
          value: .consumerAccepted,
          wallMilliseconds: 1_100,
          monotonicNanoseconds: 2_100
        )
      )
    )
    try store.retry()
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 8, value: "ok"))
    let values = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM GapVersions WHERE namespace='transition' AND reason='missingInitialEvent.expired'",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: database)
      )
    }
    XCTAssertEqual(values.0, 1)
    XCTAssertEqual(values.1, 1)
    XCTAssertEqual(store.status().state, .available)
  }

  func testDeleteConfirmationIsSingleUseAndInvalidatedByAnnotation() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    let target = ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    let stale = try maintenance.prepareDelete(target)
    _ = try maintenance.appendAnnotation(
      recordingID: recording.rowID,
      body: "changed after confirmation",
      wallMilliseconds: 2_100
    )
    XCTAssertThrowsError(try maintenance.requestDelete(stale, wallMilliseconds: 2_200))
    XCTAssertThrowsError(try maintenance.requestDelete(stale, wallMilliseconds: 2_300))
    let current = try maintenance.prepareDelete(target)
    try maintenance.requestDelete(current, wallMilliseconds: 2_400)
    XCTAssertThrowsError(try maintenance.requestDelete(current, wallMilliseconds: 2_500))
  }

  func testQueryUsesViewerTimeTypedJSONScalarOrAndFrozenTerminalPresence() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "installation",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1"
    )
    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "integer",
        initialDisposition: .buffered,
        viewerWallMilliseconds: 5_000,
        content: .object(["message": .integer(42), "kind": .integer(1)])
      )
    )
    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 2,
        value: "string",
        viewerWallMilliseconds: 6_000,
        content: .object(["message": .string("42"), "kind": .bool(true)])
      )
    )
    let leases = ViewerStoreLeaseRegistry()
    let queryService = ViewerStoreQueryService(pool: pool, leases: leases)

    var traversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [
          .wallTime(from: 4_000, through: 6_000),
          .jsonStringContains(path: "$.message", value: "42"),
        ]
      )
    )
    var page = try queryService.page(traversal: traversal, cursor: nil, direction: .forward).0
    XCTAssertEqual(page.rows.map(\.wireSequence), [2])
    queryService.end(traversal)

    traversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [.jsonAny(path: "$.message", equalsAny: [.integer(42), .string("no")])]
      )
    )
    page = try queryService.page(traversal: traversal, cursor: nil, direction: .forward).0
    XCTAssertEqual(page.rows.map(\.wireSequence), [1])
    queryService.end(traversal)

    traversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [.json(path: "$.kind", equals: .integer(1))]
      )
    )
    page = try queryService.page(traversal: traversal, cursor: nil, direction: .forward).0
    XCTAssertEqual(page.rows.map(\.wireSequence), [1])
    queryService.end(traversal)

    traversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [.json(path: "$.kind", equals: .boolean(true))]
      )
    )
    page = try queryService.page(traversal: traversal, cursor: nil, direction: .forward).0
    XCTAssertEqual(page.rows.map(\.wireSequence), [2])
    queryService.end(traversal)

    traversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [.hasTerminalDisposition]
      )
    )
    try store.appendStructural(
      .disposition(
        recording: recording,
        device: device,
        direction: .appToViewer,
        wireSequence: 1,
        value: .expired,
        wallMilliseconds: 7_000,
        monotonicNanoseconds: 8_000
      )
    )
    page = try queryService.page(traversal: traversal, cursor: nil, direction: .forward).0
    XCTAssertEqual(page.rows.map(\.wireSequence), [2])
    XCTAssertEqual(page.rows.first?.resolvedDisposition, "consumerAccepted")
    XCTAssertEqual(page.rows.first?.recordingRevision, 1)
    XCTAssertEqual(page.rows.first?.deviceRevision, 1)
    queryService.end(traversal)
  }

  func testGapAggregateVersionsAreAppendOnlyAndFrozenExportUsesCapturedVersion() throws {
    let root = try makeTemporaryDirectory()
    let paths = ViewerStorePaths(
      directory: root.appendingPathComponent("Store", isDirectory: true),
      database: root.appendingPathComponent("Store/NearWire.sqlite")
    )
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "installation",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "one"))
    let first = ViewerStructuralObservation.gap(
      recording: recording,
      device: device,
      sequence: 1,
      reason: "storeIngressFull",
      count: 2,
      firstWallMilliseconds: 1_100,
      lastWallMilliseconds: 1_200,
      directions: "appToViewer",
      firstWireSequence: 1,
      lastWireSequence: 2
    )
    try store.appendStructural(first)
    try store.appendStructural(first)
    let leases = ViewerStoreLeaseRegistry()
    let queryService = ViewerStoreQueryService(pool: pool, leases: leases)
    let traversal = try queryService.begin(
      query: ViewerEventQuery(recordingID: recording.rowID, predicates: [])
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "storeIngressFull",
        count: 3,
        firstWallMilliseconds: 1_100,
        lastWallMilliseconds: 1_300,
        directions: "both",
        firstWireSequence: 1,
        lastWireSequence: 3
      )
    )
    let destination = root.appendingPathComponent("frozen.json")
    try ViewerStoreExportService(pool: pool, leases: leases).export(
      traversal: traversal,
      to: destination
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    let gaps = try XCTUnwrap(object["gaps"] as? [[String: Any]])
    XCTAssertEqual(gaps.count, 1)
    XCTAssertEqual(gaps[0]["count"] as? Int, 2)
    XCTAssertEqual(gaps[0]["lastViewerTimeMilliseconds"] as? Int, 1_200)
    let versions = try pool.queryReader.run(budget: .query()) { database in
      try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM GapVersions", database: database)
    }
    XCTAssertEqual(versions, 2)
    queryService.end(traversal)
  }

  func testDiskGuardFailsClosedBeforeBootstrapAndEveryMutationCategory() throws {
    let blockedPaths = try makePaths()
    let missing = ViewerStoreDiskGuard { _ in nil }
    XCTAssertThrowsError(try ViewerSQLitePool(migrating: blockedPaths, diskGuard: missing)) {
      XCTAssertEqual($0 as? ViewerStoreError, .capacityExceeded)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: blockedPaths.database.path))

    let capacity = LockedCapacity(Int64.max)
    let guardWithSeam = ViewerStoreDiskGuard { _ in capacity.value }
    let pool = try ViewerSQLitePool(migrating: makePaths(), diskGuard: guardWithSeam)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "installation",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1"
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    capacity.value = nil
    XCTAssertThrowsError(
      try store.appendEvent(
        makeObservation(recording: recording, device: device, sequence: 1, value: "blocked"))
    )
    XCTAssertThrowsError(
      try maintenance.updateRecording(
        ViewerRecordingRevision(recordingID: recording.rowID, revision: 2),
        name: "blocked",
        note: nil,
        pinned: false,
        wallMilliseconds: 2_100
      )
    )
    XCTAssertThrowsError(
      try maintenance.appendAnnotation(
        recordingID: recording.rowID,
        body: "blocked",
        wallMilliseconds: 2_100
      )
    )
    XCTAssertThrowsError(try maintenance.requestDelete(confirmation, wallMilliseconds: 2_200))
    let counts = try pool.queryReader.run(budget: .query()) { database in
      try ViewerStoreSchema.scalarInt64(
        "SELECT (SELECT COUNT(*) FROM Events)+(SELECT COUNT(*) FROM AnnotationVersions)+(SELECT COUNT(*) FROM Tombstones)",
        database: database
      )
    }
    XCTAssertEqual(counts, 0)
  }

  func testDiskGuardPreservesFloorAcrossNormalOversizeAndReclaimPlans() throws {
    let capacity = LockedCapacity(nil)
    let guardWithSeam = ViewerStoreDiskGuard { _ in capacity.value }
    let directory = try makeTemporaryDirectory()
    let plans: [Int64] = [
      4 * 1_024 * 1_024,
      try ViewerStoreQuota.eventReservation(canonicalEventBytes: 16 * 1_024 * 1_024),
      41 * 1_024 * 1_024,
    ]
    for plannedBytes in plans {
      capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes + plannedBytes
      XCTAssertNoThrow(
        try guardWithSeam.requireReserve(at: directory, plannedBytes: plannedBytes)
      )
      capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes + plannedBytes - 1
      XCTAssertThrowsError(
        try guardWithSeam.requireReserve(at: directory, plannedBytes: plannedBytes)
      )
    }
    capacity.value = Int64.max
    XCTAssertThrowsError(
      try guardWithSeam.requireReserve(at: directory, plannedBytes: Int64.max)
    )
    XCTAssertThrowsError(
      try guardWithSeam.requireReserve(at: directory, plannedBytes: -1)
    )
  }

  func testIncrementalVacuumUsesFloorOnlyAndMeasuresPhysicalReclaim() throws {
    let paths = try makePaths()
    let capacity = LockedCapacity(Int64.max)
    let pool = try ViewerSQLitePool(
      migrating: paths,
      diskGuard: ViewerStoreDiskGuard { _ in capacity.value }
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "CREATE TABLE VacuumFixture(rowID INTEGER PRIMARY KEY, payload BLOB NOT NULL)",
        on: database
      )
      try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
      do {
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql: "INSERT INTO VacuumFixture(payload) VALUES(zeroblob(16384))"
        )
        for _ in 0..<512 {
          _ = try insert.step()
          try insert.reset()
        }
        try ViewerSQLiteConnection.execute("COMMIT", on: database)
      } catch {
        try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
        throw error
      }
      try ViewerSQLiteConnection.execute("DELETE FROM VacuumFixture", on: database)
      try ViewerSQLiteConnection.execute("PRAGMA wal_checkpoint(TRUNCATE)", on: database)
    }
    let before = try pool.writer.run { database in
      (
        try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database),
        try ViewerStoreSchema.scalarInt64("PRAGMA page_count", database: database)
      )
    }
    let beforeMain = Int64(
      (try paths.database.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
    )
    let beforeMainSize = Int64(
      (try paths.database.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    )
    let beforeWAL = Int64(
      (try paths.wal.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
    )
    XCTAssertGreaterThan(before.0, 0)

    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes + 1
    XCTAssertTrue(try maintenance.reclaimFreePagesOneStep())
    XCTAssertTrue(try maintenance.checkpointOneStep())
    let after = try pool.writer.run { database in
      (
        try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database),
        try ViewerStoreSchema.scalarInt64("PRAGMA page_count", database: database)
      )
    }
    let afterMain = Int64(
      (try paths.database.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
    )
    let afterMainSize = Int64(
      (try paths.database.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    )
    let afterWAL = Int64(
      (try paths.wal.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
    )
    XCTAssertLessThan(after.0, before.0)
    XCTAssertLessThan(after.1, before.1)
    XCTAssertLessThanOrEqual(afterMain, beforeMain)

    capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes - 1
    let stable = after
    XCTAssertThrowsError(try maintenance.reclaimFreePagesOneStep()) {
      XCTAssertEqual($0 as? ViewerStoreError, .capacityExceeded)
    }
    XCTAssertEqual(
      try pool.writer.run { database in
        (
          try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database),
          try ViewerStoreSchema.scalarInt64("PRAGMA page_count", database: database)
        )
      }.0,
      stable.0
    )
    pool.close()
    let closedMainValues = try paths.database.resourceValues(
      forKeys: [.fileSizeKey, .fileAllocatedSizeKey]
    )
    let closedMainSize = Int64(closedMainValues.fileSize ?? 0)
    let closedMainAllocated = Int64(closedMainValues.fileAllocatedSize ?? 0)
    XCTAssertLessThanOrEqual(closedMainAllocated, beforeMain)
    print(
      "NearWire incremental vacuum: freelist \(before.0)->\(after.0), pages \(before.1)->\(after.1), main size \(beforeMainSize)->\(afterMainSize)->\(closedMainSize) after close, main allocated \(beforeMain)->\(afterMain)->\(closedMainAllocated), WAL allocated \(beforeWAL)->\(afterWAL)"
    )
  }

  func testMaintenanceRunBypassesBlockedReclaimForOneFloorOnlyAction() throws {
    let paths = try makePaths()
    let capacity = LockedCapacity(Int64.max)
    let pool = try ViewerSQLitePool(
      migrating: paths,
      diskGuard: ViewerStoreDiskGuard { _ in capacity.value }
    )
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "maintenance-fallback"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "maintenance-device",
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      partialHistory: false,
      displayName: "Device"
    )
    _ = try store.appendEvents([
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: String(repeating: "x", count: 4_096)
      )
    ])
    try store.appendStructural(
      .closeDevice(device, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    try maintenance.requestDelete(confirmation, wallMilliseconds: 2_100)

    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "CREATE TABLE MaintenanceVacuumFixture(rowID INTEGER PRIMARY KEY, payload BLOB NOT NULL)",
        on: database
      )
      try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
      do {
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql: "INSERT INTO MaintenanceVacuumFixture(payload) VALUES(zeroblob(16384))"
        )
        for _ in 0..<256 {
          _ = try insert.step()
          try insert.reset()
        }
        try ViewerSQLiteConnection.execute("COMMIT", on: database)
      } catch {
        try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
        throw error
      }
      try ViewerSQLiteConnection.execute("DELETE FROM MaintenanceVacuumFixture", on: database)
      try ViewerSQLiteConnection.execute("PRAGMA wal_checkpoint(TRUNCATE)", on: database)
    }
    let before = try pool.writer.run { database in
      (
        try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database),
        try ViewerStoreSchema.scalarInt64("PRAGMA page_count", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: database)
      )
    }
    XCTAssertGreaterThan(before.0, 0)
    XCTAssertEqual(before.2, 1)
    XCTAssertEqual(before.3, 1)

    capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes + 1
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 2_200)
    let after = try pool.writer.run { database in
      (
        try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database),
        try ViewerStoreSchema.scalarInt64("PRAGMA page_count", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: database)
      )
    }
    XCTAssertLessThan(after.0, before.0)
    XCTAssertLessThan(after.1, before.1)
    XCTAssertEqual(after.2, 1)
    XCTAssertEqual(after.3, 1)
    pool.close()
  }

  func testMaintenanceMutationFailuresReportAuthoritativeStateAndRollback() throws {
    for phase in [
      ViewerStoreMaintenance.MutationPhase.beforeBegin,
      .beforeBody,
      .beforeCommit,
    ] {
      let pool = try ViewerSQLitePool(migrating: makePaths())
      let signal = ViewerStoreStatusSignal()
      let store = ViewerEventStore(
        pool: pool,
        configuration: { .default },
        statusSignal: signal
      )
      let recording = try store.beginRecording(
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000,
        reason: "maintenance-failure"
      )
      let fault = ViewerMaintenanceMutationFault(phase)
      let maintenance = ViewerStoreMaintenance(
        pool: pool,
        leases: ViewerStoreLeaseRegistry(),
        configuration: { .default },
        statusSignal: signal,
        storeStateReporter: { store.writeStateRelay.reportFailure($0) },
        mutationGate: { try fault.check($0) }
      )
      XCTAssertThrowsError(
        try maintenance.updateRecording(
          ViewerRecordingRevision(recordingID: recording.rowID, revision: 1),
          name: "Name",
          note: nil,
          pinned: false,
          wallMilliseconds: 2_000
        )
      ) {
        XCTAssertEqual($0 as? ViewerStoreError, .unavailable)
      }
      XCTAssertEqual(store.status().state, .writeFailed)
      XCTAssertEqual(
        try pool.queryReader.run(budget: .query()) {
          try ViewerStoreSchema.scalarInt64(
            "SELECT COUNT(*) FROM RecordingVersions WHERE recordingID=\(recording.rowID)",
            database: $0
          )
        },
        1
      )
      pool.close()
    }

    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "stale-revision"
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { store.writeStateRelay.reportFailure($0) }
    )
    XCTAssertThrowsError(
      try maintenance.updateRecording(
        ViewerRecordingRevision(recordingID: recording.rowID, revision: 0),
        name: nil,
        note: nil,
        pinned: false,
        wallMilliseconds: 2_000
      )
    ) {
      XCTAssertEqual($0 as? ViewerStoreError, .busy)
    }
    XCTAssertEqual(store.status().state, .available)
    pool.close()
  }

  func testMaintenanceWriteFailureStopsIngressUntilExplicitRecovery() async throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let signal = ViewerStoreStatusSignal()
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      statusSignal: signal
    )
    let ingress = ViewerStoreIngress(store: store)
    let relay = store.writeStateRelay
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "maintenance-ingress-gate"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "maintenance-ingress-device",
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      partialHistory: false,
      displayName: "Device"
    )
    let fault = ViewerMaintenanceMutationFault(.beforeBegin)
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      statusSignal: signal,
      storeStateReporter: { relay.reportFailure($0) },
      mutationGate: { try fault.check($0) }
    )

    XCTAssertThrowsError(
      try maintenance.updateRecording(
        ViewerRecordingRevision(recordingID: recording.rowID, revision: 1),
        name: "Blocked",
        note: nil,
        pinned: false,
        wallMilliseconds: 2_000
      )
    ) {
      XCTAssertEqual($0 as? ViewerStoreError, .unavailable)
    }
    XCTAssertEqual(store.status().state, .writeFailed)
    XCTAssertEqual(
      try ingress.admit(
        makeObservation(recording: recording, device: device, sequence: 1, value: "blocked")
      ),
      .stopped
    )
    XCTAssertEqual(
      ingress.admit(
        .closeDevice(device, wallMilliseconds: 2_100, monotonicNanoseconds: 3_100)
      ),
      .stopped
    )

    try store.retry()
    XCTAssertEqual(
      try ingress.admit(
        makeObservation(recording: recording, device: device, sequence: 1, value: "admitted")
      ),
      .admitted
    )
    let flushOutcome = await ingress.flush()
    XCTAssertEqual(flushOutcome, .drained)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      1
    )
    pool.close()
  }

  func testWriterGenerationRejectsAPreselectedIngressPrefixAfterMaintenanceFailure()
    async throws
  {
    let maintenanceEntered = DispatchSemaphore(value: 0)
    let releaseMaintenance = DispatchSemaphore(value: 0)
    let queuedAuthorization = ArmedViewerStoreSignal()
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      automaticWriteAuthorizationObserver: { queuedAuthorization.observe() }
    )
    let ingress = ViewerStoreIngress(store: store)
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "generation-gate"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "generation-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { store.writeStateRelay.reportFailure($0) },
      mutationGate: { phase in
        guard phase == .beforeBody else { return }
        maintenanceEntered.signal()
        _ = releaseMaintenance.wait(timeout: .now() + 5)
        throw ViewerStoreError.unavailable
      }
    )
    let mutationErrors = LockedViewerStoreErrors()
    let mutationFinished = expectation(description: "Maintenance failed")
    DispatchQueue.global().async {
      do {
        _ = try maintenance.appendAnnotation(
          recordingID: recording.rowID,
          body: "blocked",
          wallMilliseconds: 2_000
        )
      } catch {
        mutationErrors.append(error as? ViewerStoreError)
      }
      mutationFinished.fulfill()
    }
    XCTAssertEqual(maintenanceEntered.wait(timeout: .now() + 2), .success)

    queuedAuthorization.arm()
    let secret = "nearwire-stale-ingress-secret"
    XCTAssertEqual(
      try ingress.admit(
        makeObservation(recording: recording, device: device, sequence: 1, value: secret)
      ),
      .admitted
    )
    XCTAssertEqual(queuedAuthorization.wait(timeout: .now() + 2), .success)
    XCTAssertFalse(String(describing: ingress).contains(secret))
    XCTAssertFalse(String(reflecting: ingress).contains(secret))
    XCTAssertTrue(Mirror(reflecting: ingress).children.isEmpty)
    releaseMaintenance.signal()
    await fulfillment(of: [mutationFinished], timeout: 2)
    XCTAssertEqual(mutationErrors.values, [.unavailable])
    let failedFlush = await ingress.flush()
    XCTAssertEqual(failedFlush, .writeFailed)
    XCTAssertEqual(store.status().state, .writeFailed)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      0
    )

    try store.retry()
    let recoveredFlush = await ingress.flush()
    XCTAssertEqual(recoveredFlush, .drained)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      1
    )
    pool.close()
  }

  func testDirectWriterFailurePublishesBeforeQueuedAutomaticWriterValidates() throws {
    let gate = BlockingViewerStoreFailureGate()
    let queuedAuthorization = ArmedViewerStoreSignal()
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      writeGate: { try gate.check() },
      automaticWriteAuthorizationObserver: { queuedAuthorization.observe() }
    )
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "direct-writer-failure"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "direct-writer-device",
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      partialHistory: false,
      displayName: "Device"
    )
    let first = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "first"
    )
    let second = try makeObservation(
      recording: recording,
      device: device,
      sequence: 2,
      value: "second"
    )
    gate.arm()
    let errors = LockedViewerStoreErrors()
    let finished = expectation(description: "Both direct writes completed")
    finished.expectedFulfillmentCount = 2
    DispatchQueue.global().async {
      do { _ = try store.appendEvents([first]) } catch {
        errors.append(error as? ViewerStoreError)
      }
      finished.fulfill()
    }
    XCTAssertEqual(gate.waitUntilEntered(), .success)
    queuedAuthorization.arm()
    DispatchQueue.global().async {
      do { _ = try store.appendEvents([second]) } catch {
        errors.append(error as? ViewerStoreError)
      }
      finished.fulfill()
    }
    XCTAssertEqual(queuedAuthorization.wait(timeout: .now() + 2), .success)
    gate.release()
    wait(for: [finished], timeout: 2)

    XCTAssertEqual(errors.values.count, 2)
    XCTAssertTrue(errors.values.contains(.unavailable))
    XCTAssertTrue(errors.values.contains(.writeNotAuthorized))
    XCTAssertEqual(gate.armedCheckCount, 1)
    XCTAssertEqual(store.status().state, .writeFailed)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      0
    )

    try store.retry()
    XCTAssertEqual(try store.appendEvents([second]).count, 1)
    XCTAssertEqual(store.status().state, .available)
    pool.close()
  }

  func testDirectMaterializationFailureAndFailedRetryCannotReopenIngress() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let fault = OneShotViewerStoreFault()
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      writeGate: { try fault.check() }
    )
    let ingress = ViewerStoreIngress(store: store)
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "existing"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "existing-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    fault.failNext()
    XCTAssertThrowsError(
      try store.beginRecording(
        wallMilliseconds: 3_000,
        monotonicNanoseconds: 4_000,
        reason: "direct-failure"
      )
    )
    XCTAssertEqual(store.status().state, .writeFailed)
    XCTAssertEqual(
      try ingress.admit(
        makeObservation(recording: recording, device: device, sequence: 1, value: "blocked")
      ),
      .stopped
    )
    pool.close()

    let paths = try makePaths()
    let repeatedFault = CountingViewerStoreFault()
    repeatedFault.failEveryAttempt()
    let coordinator = try ViewerStoreCoordinator(
      paths: paths,
      writeGate: { try repeatedFault.check() }
    )
    let logicalID = UUID()
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 5_000,
        monotonicNanoseconds: 6_000
      )
    )
    waitUntil {
      repeatedFault.failedAttemptCount >= 1
        && coordinator.services.eventStore.status().state == .writeFailed
    }
    XCTAssertEqual(coordinator.services.eventStore.status().state, .writeFailed)
    XCTAssertTrue(coordinator.retryStorage())
    waitUntil {
      repeatedFault.failedAttemptCount >= 2
        && coordinator.services.eventStore.status().state == .writeFailed
    }
    XCTAssertEqual(coordinator.services.eventStore.status().state, .writeFailed)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)
    repeatedFault.succeedEveryAttempt()
    XCTAssertTrue(coordinator.retryStorage())
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM Recordings", at: paths)) == 1
        && ((try? self.scalar(
          "SELECT COUNT(*) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
          at: paths
        )) == 1)
    }
    XCTAssertEqual(coordinator.services.eventStore.status().state, .available)
    XCTAssertEqual(
      try scalar(
        "SELECT COUNT(*) FROM Recordings WHERE durableStartReason='midRuntimeRetry'",
        at: paths
      ),
      1
    )
    XCTAssertEqual(
      try scalar(
        "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
        at: paths
      ),
      1
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 0)
    coordinator.closeStorage()
  }

  func testRecoveryMatrixAllowsOnlyApprovedSuccessfulActions() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { relay.reportFailure($0) },
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        relay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try relay.validate($0) },
      recoveryValidator: { try relay.validate($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "recovery-matrix"
    )
    var revision = try maintenance.updateRecording(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 1),
      name: nil,
      note: nil,
      pinned: true,
      wallMilliseconds: 1_100
    )

    for failedState in [
      ViewerStoreStatus.State.writeFailed,
      .capacityPaused,
    ] {
      relay.reportFailure(failedState)
      _ = try maintenance.appendAnnotation(
        recordingID: recording.rowID,
        body: "does not recover",
        wallMilliseconds: 1_200
      )
      XCTAssertEqual(store.status().state, failedState)
      revision = try maintenance.updateRecording(
        revision,
        name: "Rename only",
        note: nil,
        pinned: true,
        wallMilliseconds: 1_300
      )
      XCTAssertEqual(store.status().state, failedState)
      revision = try maintenance.updateRecording(
        revision,
        name: "Rename only",
        note: nil,
        pinned: false,
        wallMilliseconds: 1_400
      )
      XCTAssertEqual(store.status().state, .available)
      revision = try maintenance.updateRecording(
        revision,
        name: nil,
        note: nil,
        pinned: true,
        wallMilliseconds: 1_500
      )
    }

    let deletable = try store.beginRecording(
      wallMilliseconds: 2_000,
      monotonicNanoseconds: 3_000,
      reason: "manual-delete-recovery"
    )
    try store.appendStructural(
      .closeRecording(deletable, wallMilliseconds: 2_100, monotonicNanoseconds: 3_100)
    )
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: deletable.rowID, revision: 2)
    )
    relay.reportFailure(.writeFailed)
    try maintenance.requestDelete(confirmation, wallMilliseconds: 2_200)
    XCTAssertEqual(store.status().state, .available)

    relay.reportFailure(.capacityPaused)
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 3_000)
    XCTAssertEqual(store.status().state, .capacityPaused)
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 3_100,
      recoveryAction: .settingsChanged
    )
    waitUntil { store.status().state == .available }
    owner.close()
    pool.close()
  }

  func testApprovedRecoveryActionsCannotReopenANewerFailureGeneration() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay

    let unpinGate = ViewerRecoveryCompletionGate(relay: relay, action: .unpin)
    let unpinMaintenance = makeRecoveryAwareMaintenance(
      pool: pool,
      relay: relay,
      completionGate: unpinGate
    )
    let pinned = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "stale-unpin"
    )
    let pinnedRevision = try unpinMaintenance.updateRecording(
      ViewerRecordingRevision(recordingID: pinned.rowID, revision: 1),
      name: nil,
      note: nil,
      pinned: true,
      wallMilliseconds: 1_100
    )
    relay.reportFailure(.capacityPaused)
    let unpinFinished = expectation(description: "Unpin completed")
    DispatchQueue.global().async {
      _ = try? unpinMaintenance.updateRecording(
        pinnedRevision,
        name: nil,
        note: nil,
        pinned: false,
        wallMilliseconds: 1_200
      )
      unpinFinished.fulfill()
    }
    XCTAssertEqual(unpinGate.waitUntilEntered(), .success)
    relay.reportFailure(.writeFailed)
    unpinGate.release()
    wait(for: [unpinFinished], timeout: 2)
    XCTAssertEqual(relay.currentState, .writeFailed)
    try store.retry()

    let manualGate = ViewerRecoveryCompletionGate(relay: relay, action: .manualDelete)
    let manualMaintenance = makeRecoveryAwareMaintenance(
      pool: pool,
      relay: relay,
      completionGate: manualGate
    )
    let deletable = try store.beginRecording(
      wallMilliseconds: 2_000,
      monotonicNanoseconds: 3_000,
      reason: "stale-manual-delete"
    )
    try store.appendStructural(
      .closeRecording(deletable, wallMilliseconds: 2_100, monotonicNanoseconds: 3_100)
    )
    let confirmation = try manualMaintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: deletable.rowID, revision: 2)
    )
    relay.reportFailure(.writeFailed)
    let deleteFinished = expectation(description: "Manual delete completed")
    DispatchQueue.global().async {
      try? manualMaintenance.requestDelete(confirmation, wallMilliseconds: 2_200)
      deleteFinished.fulfill()
    }
    XCTAssertEqual(manualGate.waitUntilEntered(), .success)
    relay.reportFailure(.capacityPaused)
    manualGate.release()
    wait(for: [deleteFinished], timeout: 2)
    XCTAssertEqual(relay.currentState, .capacityPaused)
    try store.retry()

    let settingsCompletion = ViewerRecoveryCompletionGate(relay: relay, action: .unpin)
    let settingsPublication = ViewerRecoveryPublicationGate()
    let settingsMaintenance = makeRecoveryAwareMaintenance(
      pool: pool,
      relay: relay,
      completionGate: settingsCompletion
    )
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: settingsMaintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) },
      recoveryPublicationGate: { settingsPublication.block() }
    )
    relay.reportFailure(.capacityPaused)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 3_000,
      recoveryAction: .settingsChanged
    )
    XCTAssertEqual(settingsPublication.waitUntilEntered(), .success)
    relay.reportFailure(.writeFailed)
    settingsPublication.release()
    waitUntil { relay.currentState == .writeFailed }
    owner.close()
    XCTAssertEqual(relay.currentState, .writeFailed)
    pool.close()
  }

  func testRuntimeEndInvalidatesInFlightMaintenanceRecoveryBeforePublication() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { relay.reportFailure($0) },
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        relay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try relay.validate($0) },
      recoveryValidator: { try relay.validate($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )
    let publication = ViewerRecoveryPublicationGate()
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) },
      recoveryPublicationGate: { publication.block() }
    )
    relay.reportFailure(.capacityPaused)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 1_000,
      recoveryAction: .settingsChanged
    )
    XCTAssertEqual(publication.waitUntilEntered(), .success)
    owner.runtimeEnded()
    publication.release()
    owner.close()

    XCTAssertEqual(relay.currentState, .capacityPaused)
    XCTAssertEqual(store.status().state, .capacityPaused)
    XCTAssertThrowsError(try relay.issueAutomaticTicket()) {
      XCTAssertEqual($0 as? ViewerStoreError, .writeNotAuthorized)
    }
    pool.close()
  }

  func testRuntimeShutdownQuiescesMaintenanceBeforeOneTerminalFlush() async throws {
    let paths = try makePaths()
    let maintenanceGate = ArmableViewerExecutionGate()
    let writerTurns = LockedViewerCounter()
    let coordinator = try ViewerStoreCoordinator(
      paths: paths,
      writeGate: { writerTurns.increment() },
      maintenanceExecutionGate: { maintenanceGate.run() }
    )
    let logicalID = UUID()
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM Recordings", at: paths)) == 1
    }
    writerTurns.reset()
    maintenanceGate.arm()
    coordinator.requestMaintenance(.explicit)
    XCTAssertEqual(maintenanceGate.waitUntilBlocked(), .success)
    coordinator.requestMaintenance(.threshold)

    let shutdownFinished = expectation(description: "Runtime shutdown finished")
    Task {
      await coordinator.runtimeEnded(
        wallMilliseconds: 3_000,
        monotonicNanoseconds: 4_000
      )
      shutdownFinished.fulfill()
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(writerTurns.value, 0)
    XCTAssertEqual(maintenanceGate.value, 1)

    maintenanceGate.release()
    await fulfillment(of: [shutdownFinished], timeout: 2)
    XCTAssertEqual(maintenanceGate.value, 1)
    XCTAssertEqual(writerTurns.value, 1)
  }

  func testScheduledMaintenanceStorageFailureClosesAutomaticWrites() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "scheduled-maintenance-failure"
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 1_100, monotonicNanoseconds: 2_100)
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { relay.reportFailure($0) }
    )
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live
    )
    let externalWriter = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    try externalWriter.execute("BEGIN IMMEDIATE")
    owner.trigger(.explicit, wallMilliseconds: 10 * 86_400_000)
    waitUntil { relay.currentState == .writeFailed }
    XCTAssertEqual(store.status().state, .writeFailed)
    XCTAssertThrowsError(try relay.issueAutomaticTicket())
    owner.close()
    try externalWriter.execute("ROLLBACK")
    externalWriter.close()
    pool.close()
  }

  func testDirtySettingsRecoverySuccessorRetainsItsOriginalPermit() throws {
    let blocker = BlockingViewerDiskGuard()
    let pool = try ViewerSQLitePool(
      migrating: makePaths(),
      diskGuard: ViewerStoreDiskGuard { _ in blocker.availableCapacity() }
    )
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { relay.reportFailure($0) },
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        relay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try relay.validate($0) },
      recoveryValidator: { try relay.validate($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )
    blocker.arm()
    owner.trigger(.threshold, wallMilliseconds: 1_000)
    XCTAssertEqual(blocker.waitUntilBlocked(), .success)
    relay.reportFailure(.capacityPaused)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 2_000,
      recoveryAction: .settingsChanged
    )
    blocker.release()
    waitUntil { relay.currentState == .available }
    XCTAssertEqual(store.status().state, .available)
    XCTAssertNoThrow(try relay.issueAutomaticTicket())
    owner.close()
    pool.close()
  }

  func testQueuedSettingsRecoveryIsRevokedByANewerNonrecoveringRevision() throws {
    let blocker = BlockingViewerDiskGuard()
    let pool = try ViewerSQLitePool(
      migrating: makePaths(),
      diskGuard: ViewerStoreDiskGuard { _ in blocker.availableCapacity() }
    )
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay
    let maintenance = makeRecoveryAwareMaintenance(pool: pool, relay: relay)
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )

    blocker.arm()
    owner.trigger(.threshold, wallMilliseconds: 1_000)
    XCTAssertEqual(blocker.waitUntilBlocked(), .success)
    relay.reportFailure(.capacityPaused)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 2_000,
      recoveryAction: .settingsChanged,
      settingsRevision: 1
    )
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 3_000,
      settingsRevision: 2
    )
    blocker.release()
    owner.waitForQuiescence()

    XCTAssertEqual(relay.currentState, .capacityPaused)
    XCTAssertEqual(store.status().state, .capacityPaused)
    XCTAssertThrowsError(try relay.issueAutomaticTicket())

    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 4_000,
      recoveryAction: .settingsChanged,
      settingsRevision: 3
    )
    waitUntil { relay.currentState == .available }
    XCTAssertNoThrow(try relay.issueAutomaticTicket())
    owner.close()
    pool.close()
  }

  func testRunningSettingsRecoveryIsRevokedBeforePublicationByNewerRevision() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay
    let publication = ViewerRecoveryPublicationGate()
    let maintenance = makeRecoveryAwareMaintenance(pool: pool, relay: relay)
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) },
      recoveryPublicationGate: { publication.block() }
    )

    relay.reportFailure(.capacityPaused)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 1_000,
      recoveryAction: .settingsChanged,
      settingsRevision: 1
    )
    XCTAssertEqual(publication.waitUntilEntered(), .success)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 2_000,
      settingsRevision: 2
    )
    publication.release()
    owner.waitForQuiescence()

    XCTAssertEqual(relay.currentState, .capacityPaused)
    XCTAssertEqual(store.status().state, .capacityPaused)
    XCTAssertThrowsError(try relay.issueAutomaticTicket())

    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 3_000,
      recoveryAction: .settingsChanged,
      settingsRevision: 3
    )
    XCTAssertEqual(publication.waitUntilEntered(), .success)
    publication.release()
    waitUntil { relay.currentState == .available }
    XCTAssertNoThrow(try relay.issueAutomaticTicket())
    owner.close()
    pool.close()
  }

  func testSQLiteWriterLockReportsWriteFailedWhileStaleRevisionRemainsLocal() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "sqlite-lock"
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { store.writeStateRelay.reportFailure($0) }
    )
    let externalWriter = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    try externalWriter.execute("BEGIN IMMEDIATE")
    defer { try? externalWriter.execute("ROLLBACK") }

    XCTAssertThrowsError(
      try maintenance.updateRecording(
        ViewerRecordingRevision(recordingID: recording.rowID, revision: 1),
        name: "Locked",
        note: nil,
        pinned: false,
        wallMilliseconds: 2_000
      )
    ) {
      XCTAssertEqual($0 as? ViewerStoreError, .sqliteBusy)
    }
    XCTAssertEqual(store.status().state, .writeFailed)
    try externalWriter.execute("ROLLBACK")

    try store.retry()
    XCTAssertThrowsError(
      try maintenance.updateRecording(
        ViewerRecordingRevision(recordingID: recording.rowID, revision: 0),
        name: nil,
        note: nil,
        pinned: false,
        wallMilliseconds: 2_100
      )
    ) {
      XCTAssertEqual($0 as? ViewerStoreError, .busy)
    }
    XCTAssertEqual(store.status().state, .available)
    pool.close()
  }

  func testManualDeleteClassifiesStorageAndCapacityFailuresWithoutMutation() throws {
    for error in [
      ViewerStoreError.unavailable,
      .corruptStore,
      .capacityExceeded,
    ] {
      for phase in [
        ViewerStoreMaintenance.MutationPhase.beforeBegin,
        .beforeBody,
        .beforeCommit,
      ] {
        let pool = try ViewerSQLitePool(migrating: makePaths())
        let store = ViewerEventStore(pool: pool, configuration: { .default })
        let recording = try store.beginRecording(
          wallMilliseconds: 1_000,
          monotonicNanoseconds: 2_000,
          reason: "delete-failure"
        )
        try store.appendStructural(
          .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
        )
        let quotaBefore = store.status().logicalQuotaBytes
        let fault = ViewerMaintenanceMutationFault(phase, error: error)
        let maintenance = ViewerStoreMaintenance(
          pool: pool,
          leases: ViewerStoreLeaseRegistry(),
          configuration: { .default },
          storeStateReporter: { store.writeStateRelay.reportFailure($0) },
          mutationGate: { try fault.check($0) }
        )
        let confirmation = try maintenance.prepareDelete(
          ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
        )
        XCTAssertThrowsError(
          try maintenance.requestDelete(confirmation, wallMilliseconds: 3_000)
        ) {
          XCTAssertEqual($0 as? ViewerStoreError, error)
        }
        XCTAssertEqual(
          store.status().state,
          error == .capacityExceeded ? .capacityPaused : .writeFailed
        )
        let after = try pool.queryReader.run(budget: .query()) { database in
          (
            try ViewerStoreSchema.scalarInt64(
              "SELECT COUNT(*) FROM Tombstones", database: database),
            try ViewerStoreSchema.scalarInt64(
              "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
              database: database
            )
          )
        }
        XCTAssertEqual(after.0, 0)
        XCTAssertEqual(after.1, quotaBefore)
        pool.close()
      }
    }
  }

  func testManualDeleteReserveSharesWriterOrderingWithMetadataWrite() throws {
    let diskGate = BlockingViewerDiskGuard()
    let pool = try ViewerSQLitePool(
      migrating: makePaths(),
      diskGuard: ViewerStoreDiskGuard { _ in diskGate.availableCapacity() }
    )
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "delete-ordering"
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    diskGate.arm()
    let deleteFinished = expectation(description: "Manual delete finished")
    let annotationFinished = expectation(description: "Annotation finished")
    DispatchQueue.global().async {
      _ = try? maintenance.requestDelete(confirmation, wallMilliseconds: 3_000)
      deleteFinished.fulfill()
    }
    XCTAssertEqual(diskGate.waitUntilBlocked(), .success)
    DispatchQueue.global().async {
      _ = try? maintenance.appendAnnotation(
        recordingID: recording.rowID,
        body: "annotation",
        wallMilliseconds: 3_100
      )
      annotationFinished.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertEqual(diskGate.maximumConcurrentChecks, 1)
    diskGate.release()
    wait(for: [deleteFinished, annotationFinished], timeout: 2)
    XCTAssertEqual(diskGate.maximumConcurrentChecks, 1)
    pool.close()
  }

  func testCheckpointReserveSharesWriterOrderingWithEventWrite() throws {
    let diskGate = BlockingViewerDiskGuard()
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(
      migrating: paths,
      diskGuard: ViewerStoreDiskGuard { _ in diskGate.availableCapacity() }
    )
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    _ = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "checkpoint-ordering"
    )
    XCTAssertGreaterThan(
      (try? paths.wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
      32
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    diskGate.arm()
    let checkpointFinished = expectation(description: "Checkpoint finished")
    let writeFinished = expectation(description: "Event write finished")
    DispatchQueue.global().async {
      _ = try? maintenance.checkpointOneStep()
      checkpointFinished.fulfill()
    }
    XCTAssertEqual(diskGate.waitUntilBlocked(), .success)
    DispatchQueue.global().async {
      _ = try? store.beginRecording(
        wallMilliseconds: 1_100,
        monotonicNanoseconds: 2_100,
        reason: "ordered-write"
      )
      writeFinished.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertEqual(diskGate.maximumConcurrentChecks, 1)
    diskGate.release()
    wait(for: [checkpointFinished, writeFinished], timeout: 2)
    XCTAssertEqual(diskGate.maximumConcurrentChecks, 1)
    pool.close()
  }

  func testOrphanRecoveryChecksExactPhysicalPlanOnWriter() throws {
    let paths = try makePaths()
    let setupPool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: setupPool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "orphan-plan"
    )
    _ = try store.beginDeviceSession(
      recording: recording,
      installationID: "orphan-one",
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      partialHistory: false,
      displayName: "One"
    )
    _ = try store.beginDeviceSession(
      recording: recording,
      installationID: "orphan-two",
      wallMilliseconds: 1_200,
      monotonicNanoseconds: 2_200,
      partialHistory: false,
      displayName: "Two"
    )
    setupPool.close()

    let capacity = SequencedViewerCapacity([
      Int64.max,
      ViewerStoreDiskGuard.minimumAvailableBytes
        + 3 * ViewerStoreQuota.structuralReservation,
    ])
    let coordinator = try ViewerStoreCoordinator(
      paths: paths,
      diskGuard: ViewerStoreDiskGuard { _ in capacity.next() }
    )
    coordinator.closeStorage()
    XCTAssertGreaterThanOrEqual(capacity.callCount, 2)
  }

  func testShutdownUsesOneFailedFlushAndNextOpenReconcilesOrphan() async throws {
    let paths = try makePaths()
    let fault = CountingViewerStoreFault()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { try fault.check() })
    let logicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: wallMilliseconds,
        monotonicNanoseconds: 2_000
      )
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: logicalID,
        state: "active"
      )) == 1
    }
    fault.failEveryAttempt()
    await coordinator.runtimeEnded(
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 3_000
    )
    XCTAssertEqual(fault.failedAttemptCount, 1)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: logicalID, state: "closed"),
      0
    )

    let reopened = try ViewerStoreCoordinator(paths: paths)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: logicalID,
        state: "recoveredAfterInterruption"
      ),
      1
    )
    reopened.closeStorage()
  }

  func testShutdownDoesNotRetryPreexistingFailedPrefix() async throws {
    let paths = try makePaths()
    let fault = CountingViewerStoreFault()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { try fault.check() })
    let logicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: wallMilliseconds,
        monotonicNanoseconds: 2_000
      )
    )
    waitUntil { coordinator.services.eventStore.status().logicalQuotaBytes > 0 }
    let context = try makeAdmissionContext(suffix: "shutdown-prefix")
    let recordingOnlyQuota = coordinator.services.eventStore.status().logicalQuotaBytes
    XCTAssertTrue(coordinator.sessionStarted(context))
    waitUntil {
      coordinator.services.eventStore.status().logicalQuotaBytes > recordingOnlyQuota
    }
    fault.failEveryAttempt()
    coordinator.policyChanged(
      connectionID: context.connectionID,
      policy: .default,
      monotonicNanoseconds: 3_000
    )
    waitUntil { coordinator.services.eventStore.status().state == .writeFailed }
    XCTAssertEqual(fault.failedAttemptCount, 1)

    await coordinator.runtimeEnded(
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )
    XCTAssertEqual(fault.failedAttemptCount, 1)
    let reopened = try ViewerStoreCoordinator(paths: paths)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: logicalID,
        state: "recoveredAfterInterruption"
      ),
      1
    )
    reopened.closeStorage()
  }

  func testShutdownCapacityFailureIsFiniteAndReconcilesOnNextOpen() async throws {
    let paths = try makePaths()
    let capacity = LockedCapacity(Int64.max)
    let coordinator = try ViewerStoreCoordinator(
      paths: paths,
      diskGuard: ViewerStoreDiskGuard { _ in capacity.value }
    )
    let logicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: wallMilliseconds,
        monotonicNanoseconds: 2_000
      )
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: logicalID,
        state: "active"
      )) == 1
    }
    capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes - 1
    await coordinator.runtimeEnded(
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 3_000
    )
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: logicalID, state: "closed"),
      0
    )
    capacity.value = Int64.max
    let reopened = try ViewerStoreCoordinator(
      paths: paths,
      diskGuard: ViewerStoreDiskGuard { _ in capacity.value }
    )
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: logicalID,
        state: "recoveredAfterInterruption"
      ),
      1
    )
    reopened.closeStorage()
  }

  @MainActor
  func testApplicationRetryAndIdentityResetReuseOneStoreRuntimeAutomatically() async throws {
    let paths = try makePaths()
    let runtime = ViewerStoreRuntime(paths: paths)
    let identityLoads = LockedViewerCounter()
    let identityResets = LockedViewerCounter()
    let dependencies = ViewerRuntimeDependencies(
      loadIdentity: {
        identityLoads.increment()
        throw ViewerStoreError.unavailable
      },
      resetTLSIdentity: { identityResets.increment() },
      resetAllIdentity: {},
      generatePairingCode: { try PairingCode("ABCDEF") },
      makeHandoffOwner: {
        ViewerMultiDeviceSessionManager(journal: runtime)
      },
      loadStorageConfiguration: { runtime.loadConfiguration() },
      loadStoreStatus: { runtime.status() }
    )
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: dependencies
    )

    model.openWindow()
    await waitForApplicationStatus(.failed(.identityUnavailable), in: model)
    waitUntil {
      identityLoads.value == 1
        && ((try? self.scalar("SELECT COUNT(*) FROM Recordings", at: paths)) == 1)
        && ((try? self.latestRecordingStateCount(at: paths, state: "active")) == 1)
    }

    model.retry()
    await waitForApplicationStatus(.failed(.identityUnavailable), in: model)
    waitUntil {
      identityLoads.value == 2
        && ((try? self.scalar("SELECT COUNT(*) FROM Recordings", at: paths)) == 2)
        && ((try? self.latestRecordingStateCount(at: paths, state: "closed")) == 1)
        && ((try? self.latestRecordingStateCount(at: paths, state: "active")) == 1)
    }

    model.resetTLSIdentity()
    await waitForApplicationStatus(.failed(.identityUnavailable), in: model)
    waitUntil {
      identityResets.value == 1
        && identityLoads.value == 3
        && ((try? self.scalar("SELECT COUNT(*) FROM Recordings", at: paths)) == 3)
        && ((try? self.latestRecordingStateCount(at: paths, state: "closed")) == 2)
        && ((try? self.latestRecordingStateCount(at: paths, state: "active")) == 1)
    }

    _ = await model.prepareForTermination()
    waitUntil {
      (try? self.latestRecordingStateCount(at: paths, state: "closed")) == 3
    }
    runtime.closeStorage()
  }

  @MainActor
  func testApplicationRapidStopCancelsPausedAutomaticReopen() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() }
    )
    let identityLoads = LockedViewerCounter()
    let dependencies = ViewerRuntimeDependencies(
      loadIdentity: {
        identityLoads.increment()
        throw ViewerStoreError.unavailable
      },
      resetTLSIdentity: {},
      resetAllIdentity: {},
      generatePairingCode: { try PairingCode("ABCDEF") },
      makeHandoffOwner: {
        ViewerMultiDeviceSessionManager(journal: runtime)
      },
      loadStorageConfiguration: { runtime.loadConfiguration() },
      loadStoreStatus: { runtime.status() }
    )
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: dependencies
    )

    model.openWindow()
    await waitForApplicationStatus(.failed(.identityUnavailable), in: model)
    waitUntil {
      identityLoads.value == 1
        && ((try? self.scalar("SELECT COUNT(*) FROM Recordings", at: paths)) == 1)
        && ((try? self.latestRecordingStateCount(at: paths, state: "active")) == 1)
    }

    reopenGate.arm()
    model.retry()
    let reopenBlocked = await Task.detached {
      reopenGate.waitUntilBlocked()
    }.value
    XCTAssertEqual(reopenBlocked, .success)
    let terminationTask = Task { await model.prepareForTermination() }
    for _ in 0..<100 where model.status != .stopping { await Task.yield() }
    XCTAssertEqual(model.status, .stopping)
    reopenGate.release()
    _ = await terminationTask.value
    let cancelledPrefixFinished = expectation(description: "Application reopen prefix finished")
    runtime.afterCurrentReopenPrefix { cancelledPrefixFinished.fulfill() }
    await fulfillment(of: [cancelledPrefixFinished], timeout: 2)

    XCTAssertEqual(model.status, .stopped)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 1)
    XCTAssertEqual(try latestRecordingStateCount(at: paths, state: "closed"), 1)
    runtime.closeStorage()
  }

  @MainActor
  func testApplicationStorageSettingsValidatePersistAndRefreshSafeStatus() async throws {
    let saved = LockedStorageConfiguration()
    let expectedStatus = ViewerStoreStatus(
      state: .capacityPaused,
      capacityBytes: ViewerStorageConfiguration.defaultCapacityBytes,
      logicalQuotaBytes: 123,
      allocatedFootprintBytes: 456,
      oldestHistoryMilliseconds: nil,
      pinnedQuotaBytes: 12,
      estimatedRetainedDurationMilliseconds: nil,
      lastCleanupCategory: .none
    )
    let dependencies = ViewerRuntimeDependencies(
      loadIdentity: { throw ViewerStoreError.unavailable },
      resetTLSIdentity: {},
      resetAllIdentity: {},
      generatePairingCode: { throw ViewerStoreError.unavailable },
      saveStorageConfiguration: { saved.set($0) },
      loadStoreStatus: { expectedStatus }
    )
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: dependencies
    )
    XCTAssertTrue(model.updateStorage(capacityGiB: "4", historyRetentionDays: "30"))
    XCTAssertEqual(saved.value?.capacityBytes, 4 * 1_024 * 1_024 * 1_024)
    for _ in 0..<20 where model.storeStatus != expectedStatus { await Task.yield() }
    XCTAssertEqual(model.storeStatus, expectedStatus)
    XCTAssertFalse(model.updateStorage(capacityGiB: String(Int64.max), historyRetentionDays: "30"))
  }

  private func makePaths() throws -> ViewerStorePaths {
    let root = try makeTemporaryDirectory()
    let directory = root.appendingPathComponent("Store", isDirectory: true)
    return ViewerStorePaths(
      directory: directory,
      database: directory.appendingPathComponent("NearWire.sqlite")
    )
  }

  private func sumStorageUnavailableGaps(at paths: ViewerStorePaths) throws -> Int64 {
    let reader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { reader.close() }
    return try reader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64(
        "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE reason='storageUnavailable'",
        database: $0
      )
    }
  }

  private func recordingStorageUnavailableGapCount(
    at paths: ViewerStorePaths,
    logicalID: UUID
  ) throws -> Int64 {
    let reader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { reader.close() }
    return try reader.run(budget: .query()) { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: """
          SELECT COALESCE(SUM(gap.count), 0)
          FROM GapVersions gap
          JOIN Recordings recording ON recording.rowID=gap.recordingID
          WHERE recording.logicalID=?1
            AND gap.deviceSessionID IS NULL
            AND gap.reason='storageUnavailable'
          """
      )
      try statement.bind(logicalID.uuidString.lowercased(), at: 1)
      guard try statement.step() else { return 0 }
      return statement.int64(at: 0)
    }
  }

  private func recordingStart(
    at paths: ViewerStorePaths,
    logicalID: UUID
  ) throws -> (wallMilliseconds: Int64, monotonicNanoseconds: Int64, reason: String) {
    let reader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { reader.close() }
    return try reader.run(budget: .query()) { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: """
          SELECT startedWallMs, startedMonotonicNs, durableStartReason
          FROM Recordings
          WHERE logicalID=?1
          """
      )
      try statement.bind(logicalID.uuidString.lowercased(), at: 1)
      guard try statement.step() else { throw ViewerStoreError.unavailable }
      return (
        statement.int64(at: 0),
        statement.int64(at: 1),
        statement.string(at: 2)
      )
    }
  }

  private func latestRecordingStateCount(
    at paths: ViewerStorePaths,
    state: String
  ) throws -> Int64 {
    let reader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { reader.close() }
    return try reader.run(budget: .query()) { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: """
          SELECT COUNT(*)
          FROM RecordingVersions version
          WHERE version.state=?1
            AND NOT EXISTS(
              SELECT 1 FROM RecordingVersions later
              WHERE later.recordingID=version.recordingID AND later.revision>version.revision
            )
          """
      )
      try statement.bind(state, at: 1)
      guard try statement.step() else { return 0 }
      return statement.int64(at: 0)
    }
  }

  private func latestRecordingStateCount(
    at paths: ViewerStorePaths,
    logicalID: UUID,
    state: String
  ) throws -> Int64 {
    let reader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { reader.close() }
    return try reader.run(budget: .query()) { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: """
          SELECT COUNT(*)
          FROM Recordings recording
          JOIN RecordingVersions version ON version.recordingID=recording.rowID
          WHERE recording.logicalID=?1 AND version.state=?2
            AND NOT EXISTS(
              SELECT 1 FROM RecordingVersions later
              WHERE later.recordingID=version.recordingID AND later.revision>version.revision
            )
          """
      )
      try statement.bind(logicalID.uuidString.lowercased(), at: 1)
      try statement.bind(state, at: 2)
      guard try statement.step() else { return 0 }
      return statement.int64(at: 0)
    }
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping () -> Bool
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    XCTAssertTrue(condition())
  }

  @MainActor
  private func waitForApplicationStatus(
    _ expected: ViewerApplicationModel.Status,
    in model: ViewerApplicationModel
  ) async {
    if model.status == expected { return }
    let reached = expectation(description: "Application model reached expected status")
    let observation = model.$status.sink { status in
      if status == expected { reached.fulfill() }
    }
    await fulfillment(of: [reached], timeout: 2)
    withExtendedLifetime(observation) {}
    XCTAssertEqual(model.status, expected)
  }

  private func makeObservation(
    recording: ViewerRecordingHandle,
    device: ViewerDeviceSessionHandle,
    sequence: UInt64,
    value: String,
    initialDisposition: ViewerStoredDisposition? = .consumerAccepted,
    causality: EventCausality = EventCausality(),
    direction: EventDirection = .appToViewer,
    viewerMonotonicNanoseconds: UInt64? = nil,
    viewerWallMilliseconds: Int64? = nil,
    eventID: EventID = EventID(),
    content: JSONValue? = nil,
    validationLimits: EventValidationLimits = .default
  ) throws -> ViewerPreparedEventObservation {
    let app = try EndpointID(rawValue: "app")
    let viewer = try EndpointID(rawValue: "viewer")
    let source =
      direction == .appToViewer
      ? EventEndpoint(role: .app, id: app)
      : EventEndpoint(role: .viewer, id: viewer)
    let target =
      direction == .appToViewer
      ? EventEndpoint(role: .viewer, id: viewer)
      : EventEndpoint(role: .app, id: app)
    let envelope = try EventEnvelope(
      id: eventID,
      type: EventType.user("test.metric"),
      content: content
        ?? .object([
          "message": .string(value),
          "payload": .array([.object(["value": .string(value)])]),
        ]),
      createdAt: Date(timeIntervalSince1970: 1),
      monotonicTimestampNanoseconds: sequence * 1_000,
      source: source,
      target: target,
      direction: direction,
      sessionEpoch: SessionEpoch(),
      sequence: EventSequence(sequence),
      priority: .normal,
      ttl: EventTTL(milliseconds: 60_000),
      causality: causality,
      limits: validationLimits
    )
    let record = try WireEventRecord(envelope: envelope, remainingTTLNanoseconds: 30_000_000_000)
    let received = try record.receiverEvent(
      receivedAtNanoseconds: viewerMonotonicNanoseconds ?? sequence * 2_000
    )
    return try ViewerPreparedEventObservation(
      recording: recording,
      device: device,
      envelope: received.envelope,
      viewerMonotonicNanoseconds: received.receivedAtNanoseconds,
      viewerWallMilliseconds: viewerWallMilliseconds,
      deterministicEventBytes: received.deterministicEncodedByteCount,
      initialDisposition: initialDisposition
    )
  }

  private func makeAdmissionContext(suffix: String) throws -> ViewerAdmissionSessionContext {
    let appID = try EndpointID(rawValue: "app-\(suffix)")
    let viewerID = try EndpointID(rawValue: "viewer-\(suffix)")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.example.\(suffix)"
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .viewer,
      installationID: viewerID
    )
    return ViewerAdmissionSessionContext(
      connectionID: UUID(),
      appHello: appHello,
      viewerHello: viewerHello,
      negotiation: try WireNegotiator.negotiate(local: appHello, remote: viewerHello),
      receiveChunkBytes: 64 * 1_024
    )
  }

  private func makeRecoveryAwareMaintenance(
    pool: ViewerSQLitePool,
    relay: ViewerStoreStateRelay,
    completionGate: ViewerRecoveryCompletionGate? = nil
  ) -> ViewerStoreMaintenance {
    ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { relay.reportFailure($0) },
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        relay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try relay.validate($0) },
      recoveryValidator: { try relay.validate($0) },
      recoveryCompleter: {
        if let completionGate {
          try completionGate.complete($0)
        } else {
          try relay.completeRecovery($0)
        }
      }
    )
  }

  private func scalar(_ sql: String, at paths: ViewerStorePaths) throws -> Int64 {
    let connection = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { connection.close() }
    return try connection.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64(sql, database: $0)
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("NearWireStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    temporaryDirectories.append(url)
    return url
  }

  private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }

  private func isRegularFileWithoutFollowingLinks(_ url: URL) throws -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw ViewerStoreError.invalidPath }
    return (info.st_mode & S_IFMT) == S_IFREG
  }
}

private final class LockedCapacity: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Int64?

  init(_ value: Int64?) { storage = value }

  var value: Int64? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
  }
}

private final class LockedViewerStoreErrors: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ViewerStoreError?] = []

  var values: [ViewerStoreError?] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ value: ViewerStoreError?) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }
}

private final class ArmedViewerStoreSignal: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var armed = false

  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  func observe() {
    lock.lock()
    let shouldSignal = armed
    armed = false
    lock.unlock()
    if shouldSignal { semaphore.signal() }
  }

  func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
  }
}

private final class LockedStorageConfiguration: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ViewerStorageConfiguration?

  var value: ViewerStorageConfiguration? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ value: ViewerStorageConfiguration) {
    lock.lock()
    stored = value
    lock.unlock()
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func increment() {
    lock.lock()
    stored += 1
    lock.unlock()
  }
}

private final class LockedViewerStoreChange: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ViewerStoreChangeSnapshot?

  var value: ViewerStoreChangeSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ value: ViewerStoreChangeSnapshot) {
    lock.lock()
    stored = value
    lock.unlock()
  }
}

private final class ManualViewerStoreScheduler: @unchecked Sendable {
  private struct Sleeper {
    let deadline: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var current: UInt64 = 0
  private var sleepers: [Sleeper] = []
  private var sleepHandler: (@Sendable () -> Void)?

  var value: ViewerAdmissionScheduler {
    ViewerAdmissionScheduler(
      now: { [weak self] in self?.now() ?? 0 },
      sleep: { [weak self] duration in
        guard let self else { throw CancellationError() }
        try await self.sleep(for: duration)
      }
    )
  }

  func onSleep(_ handler: @escaping @Sendable () -> Void) {
    lock.lock()
    sleepHandler = handler
    lock.unlock()
  }

  func advance(by duration: UInt64) {
    lock.lock()
    let (next, overflow) = current.addingReportingOverflow(duration)
    current = overflow ? UInt64.max : next
    let ready = sleepers.filter { $0.deadline <= current }
    sleepers.removeAll { $0.deadline <= current }
    lock.unlock()
    ready.forEach { $0.continuation.resume() }
  }

  private func now() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  private func sleep(for duration: UInt64) async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      let (deadline, overflow) = current.addingReportingOverflow(duration)
      sleepers.append(
        Sleeper(deadline: overflow ? UInt64.max : deadline, continuation: continuation))
      let handler = sleepHandler
      sleepHandler = nil
      lock.unlock()
      handler?()
    }
  }
}

private final class OneShotViewerStoreFault: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = false
  private var failures = 0

  var failureCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return failures
  }

  func failNext() {
    lock.lock()
    pending = true
    lock.unlock()
  }

  func check() throws {
    lock.lock()
    let shouldFail = pending
    pending = false
    if shouldFail { failures += 1 }
    lock.unlock()
    if shouldFail { throw ViewerStoreError.busy }
  }
}

private final class BlockingViewerStoreFailureGate: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var armed = false
  private var checks = 0

  var armedCheckCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return checks
  }

  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  func check() throws {
    lock.lock()
    guard armed else {
      lock.unlock()
      return
    }
    checks += 1
    let shouldBlock = checks == 1
    lock.unlock()
    guard shouldBlock else { return }
    entered.signal()
    _ = resume.wait(timeout: .now() + 5)
    throw ViewerStoreError.unavailable
  }

  func waitUntilEntered() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class ViewerRecoveryCompletionGate: @unchecked Sendable {
  private let relay: ViewerStoreStateRelay
  private let action: ViewerStoreRecoveryAction
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)

  init(relay: ViewerStoreStateRelay, action: ViewerStoreRecoveryAction) {
    self.relay = relay
    self.action = action
  }

  func complete(_ permit: ViewerStoreStateRelay.RecoveryPermit) throws {
    if permit.action == action {
      entered.signal()
      _ = resume.wait(timeout: .now() + 5)
    }
    try relay.completeRecovery(permit)
  }

  func waitUntilEntered() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class ViewerRecoveryPublicationGate: @unchecked Sendable {
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)

  func block() {
    entered.signal()
    _ = resume.wait(timeout: .now() + 5)
  }

  func waitUntilEntered() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class LockedViewerPoolConstructionEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [ViewerSQLitePool.ConstructionEvent] = []

  var value: [ViewerSQLitePool.ConstructionEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }

  func append(_ event: ViewerSQLitePool.ConstructionEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }
}

private final class LockedViewerReopenResourceEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [ViewerStoreReopenResourceEvent] = []

  var value: [ViewerStoreReopenResourceEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }

  func append(_ event: ViewerStoreReopenResourceEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }
}

private final class LockedViewerCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func reset() {
    lock.lock()
    count = 0
    lock.unlock()
  }
}

private final class ArmableViewerExecutionGate: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var armed = false
  private var calls = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  func arm() {
    lock.lock()
    armed = true
    calls = 0
    lock.unlock()
  }

  func run() {
    lock.lock()
    guard armed else {
      lock.unlock()
      return
    }
    calls += 1
    let shouldBlock = calls == 1
    lock.unlock()
    if shouldBlock {
      entered.signal()
      _ = resume.wait(timeout: .now() + 5)
    }
  }

  func waitUntilBlocked() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class CountingViewerStoreFault: @unchecked Sendable {
  private let lock = NSLock()
  private var failing = false
  private var failures = 0

  var failedAttemptCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return failures
  }

  func failEveryAttempt() {
    lock.lock()
    failing = true
    failures = 0
    lock.unlock()
  }

  func succeedEveryAttempt() {
    lock.lock()
    failing = false
    lock.unlock()
  }

  func check() throws {
    lock.lock()
    let shouldFail = failing
    if shouldFail { failures += 1 }
    lock.unlock()
    if shouldFail { throw ViewerStoreError.busy }
  }
}

private final class ViewerMaintenanceMutationFault: @unchecked Sendable {
  private let phase: ViewerStoreMaintenance.MutationPhase
  private let error: ViewerStoreError

  init(
    _ phase: ViewerStoreMaintenance.MutationPhase,
    error: ViewerStoreError = .unavailable
  ) {
    self.phase = phase
    self.error = error
  }

  func check(_ candidate: ViewerStoreMaintenance.MutationPhase) throws {
    if candidate == phase { throw error }
  }
}

private final class BlockingViewerDiskGuard: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var armed = false
  private var blockedFirst = false
  private var concurrent = 0
  private var maximumConcurrent = 0

  var maximumConcurrentChecks: Int {
    lock.lock()
    defer { lock.unlock() }
    return maximumConcurrent
  }

  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  func availableCapacity() -> Int64? {
    lock.lock()
    guard armed else {
      lock.unlock()
      return Int64.max
    }
    concurrent += 1
    maximumConcurrent = max(maximumConcurrent, concurrent)
    let shouldBlock = !blockedFirst
    if shouldBlock { blockedFirst = true }
    lock.unlock()
    if shouldBlock {
      entered.signal()
      _ = resume.wait(timeout: .now() + 2)
    }
    lock.lock()
    concurrent -= 1
    lock.unlock()
    return Int64.max
  }

  func waitUntilBlocked() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class SequencedViewerCapacity: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int64]
  private var calls = 0

  init(_ values: [Int64]) { self.values = values }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  func next() -> Int64? {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    return values.isEmpty ? Int64.max : values.removeFirst()
  }
}

private final class ViewerExportCancellationBox: @unchecked Sendable {
  weak var exporter: ViewerStoreExportService?

  func cancel() { exporter?.cancel() }
}
