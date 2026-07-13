import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

protocol ViewerSessionJournaling: AnyObject, Sendable {
  func runtimeStarted(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  )
  func sessionStarted(runtimeLogicalID: UUID, _ context: ViewerAdmissionSessionContext)
  func eventCommitted(
    _ observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  )
  func uplinkTerminated(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    direction: EventDirection,
    wireSequence: UInt64,
    disposition: ViewerStoredDisposition,
    monotonicNanoseconds: UInt64
  )
  func policyChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    policy: ViewerRatePolicy,
    monotonicNanoseconds: UInt64
  )
  func dropsChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    samples: [ViewerDropJournalSample],
    monotonicNanoseconds: UInt64
  )
  func sessionEnded(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  )
  func retryStorage()
  func runtimeEnded(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) async
}

final class ViewerNoopSessionJournal: ViewerSessionJournaling, @unchecked Sendable {
  func runtimeStarted(logicalID: UUID, wallMilliseconds: Int64, monotonicNanoseconds: UInt64) {}
  func sessionStarted(runtimeLogicalID: UUID, _ context: ViewerAdmissionSessionContext) {}
  func eventCommitted(
    _ observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) { outcome(.unavailable) }
  func uplinkTerminated(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    direction: EventDirection,
    wireSequence: UInt64,
    disposition: ViewerStoredDisposition,
    monotonicNanoseconds: UInt64
  ) {}
  func policyChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    policy: ViewerRatePolicy,
    monotonicNanoseconds: UInt64
  ) {}
  func dropsChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    samples: [ViewerDropJournalSample],
    monotonicNanoseconds: UInt64
  ) {}
  func sessionEnded(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {}
  func retryStorage() {}
  func runtimeEnded(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) async {}
}

final class ViewerStoreCoordinator: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  struct Services: @unchecked Sendable {
    let eventStore: ViewerEventStore
    let maintenance: ViewerStoreMaintenance
    let catalog: ViewerStoreCatalogService
    let diagnostics: ViewerStoreDiagnosticService
    let query: ViewerStoreQueryService
    let export: ViewerStoreExportService
    let preferences: ViewerStoragePreferences
    let statusSignal: ViewerStoreStatusSignal
  }

  private struct DeviceContext {
    let recording: ViewerRecordingHandle
    let device: ViewerDeviceSessionHandle
    var nextPolicySequence: UInt64 = 1
    var nextDropSequence: UInt64 = 1
    var projectedDropCounts: [String: Int64] = [:]
  }

  private struct GapKey: Hashable {
    let recording: ViewerRecordingHandle
    let device: ViewerDeviceSessionHandle?
    let reason: String
  }

  private struct PendingGap {
    let sequence: UInt64
    var count: Int64
    var firstWallMilliseconds: Int64
    var lastWallMilliseconds: Int64
    var directions: String
    var firstWireSequence: UInt64?
    var lastWireSequence: UInt64?
  }

  private enum RuntimeEndState {
    case idle
    case ending
    case ended
  }

  private let pool: ViewerSQLitePool
  private let preferences: ViewerStoragePreferences
  private let eventStore: ViewerEventStore
  private let ingress: ViewerStoreIngress
  private let leases: ViewerStoreLeaseRegistry
  private let maintenance: ViewerStoreMaintenance
  private let maintenanceOwner: ViewerStoreMaintenanceOwner
  private let pipelineBudget: ViewerJournalPipelineBudget
  private let preparationQueue: ViewerJournalPreparationQueue
  private let activeRecordings: ViewerActiveRecordingBox
  private let statusSignal: ViewerStoreStatusSignal
  private var runtimeLogicalID: UUID?
  private var runtimeStartedWallMilliseconds: Int64?
  private var runtimeStartedMonotonicNanoseconds: UInt64?
  private var currentRecording: ViewerRecordingHandle?
  private var devices: [UUID: DeviceContext] = [:]
  private var nondurableConnections: [UUID: ViewerAdmissionSessionContext] = [:]
  private var nextGapSequence: UInt64 = 1
  private var pendingGaps: [GapKey: PendingGap] = [:]
  private var nondurableUnavailableCount: Int64 = 0
  private var nondurableUnavailableFirstWallMilliseconds: Int64?
  private var nondurableUnavailableLastWallMilliseconds: Int64?
  private let preparationDropLock = NSLock()
  private let storageCloseLock = NSLock()
  private let storageCloseGroup = DispatchGroup()
  private let runtimeEndLock = NSLock()
  private var storageCloseStarted = false
  private var runtimeEndState = RuntimeEndState.idle
  private var runtimeEndWaiters: [CheckedContinuation<Bool, Never>] = []
  private var preparationDrops: [UUID: Int64] = [:]
  private var unattributedPreparationDrops: Int64 = 0

  init(
    paths: ViewerStorePaths,
    preferences: ViewerStoragePreferences = ViewerStoragePreferences(),
    scheduler: ViewerAdmissionScheduler = .live,
    diskGuard: ViewerStoreDiskGuard = .live,
    migrationControl: ViewerStoreMigrationControl? = nil,
    writeGate: @escaping @Sendable () throws -> Void = {},
    maintenanceExecutionGate: @escaping @Sendable () -> Void = {}
  ) throws {
    self.preferences = preferences
    let pipelineBudget = ViewerJournalPipelineBudget()
    self.pipelineBudget = pipelineBudget
    preparationQueue = ViewerJournalPreparationQueue(budget: pipelineBudget)
    pool = try ViewerSQLitePool(
      migrating: paths,
      diskGuard: diskGuard,
      migrationControl: migrationControl
    )
    let preferenceBox = ViewerStoragePreferenceBox(preferences)
    let statusMetadata = ViewerStoreStatusMetadataBox()
    let statusSignal = ViewerStoreStatusSignal()
    self.statusSignal = statusSignal
    eventStore = ViewerEventStore(
      pool: pool,
      configuration: { preferenceBox.load() },
      writeGate: writeGate,
      statusMetadata: statusMetadata,
      statusSignal: statusSignal
    )
    let storeStateRelay = eventStore.writeStateRelay
    leases = ViewerStoreLeaseRegistry()
    let activeRecordings = ViewerActiveRecordingBox()
    self.activeRecordings = activeRecordings
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: leases,
      configuration: { preferenceBox.load() },
      activeRecordingIDs: { activeRecordings.snapshot() },
      statusMetadata: statusMetadata,
      statusSignal: statusSignal,
      storeStateReporter: { storeStateRelay.reportFailure($0) },
      recoveryPermitProvider: { storeStateRelay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        storeStateRelay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try storeStateRelay.validate($0) },
      recoveryValidator: { try storeStateRelay.validate($0) },
      recoveryCompleter: { try storeStateRelay.completeRecovery($0) }
    )
    self.maintenance = maintenance
    eventStore.setCapacityRecovery { pendingReservationBytes, permit in
      try maintenance.run(
        trigger: .threshold,
        nowWallMilliseconds: Self.wallMilliseconds(),
        pendingReservationBytes: pendingReservationBytes,
        recoveryPermit: permit
      )
    }
    let maintenanceOwner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: scheduler,
      recoveryPermitProvider: { storeStateRelay.prepareRecovery($0) },
      recoveryCompleter: { try storeStateRelay.completeRecovery($0) },
      executionGate: maintenanceExecutionGate
    )
    self.maintenanceOwner = maintenanceOwner
    ingress = ViewerStoreIngress(store: eventStore) { bytes in
      maintenanceOwner.noteCommittedBytes(bytes, wallMilliseconds: Self.wallMilliseconds())
    }
    ingress.setRejectedStructuralHandler { [weak self] observation, error in
      self?.handleRejectedStructural(observation, error: error)
    }
    try reconcileOrphans()
    maintenanceOwner.trigger(.startup, wallMilliseconds: Self.wallMilliseconds())
  }

  func runtimeStarted(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) -> Bool {
    preparationQueue.offer(bytes: ViewerStoreQuota.structuralReservation, kind: .lifecycle) {
      [weak self] _ in
      guard let self, self.runtimeLogicalID == nil else { return }
      self.runtimeLogicalID = logicalID
      self.runtimeStartedWallMilliseconds = wallMilliseconds
      self.runtimeStartedMonotonicNanoseconds = monotonicNanoseconds
      do {
        _ = try self.ensureRecording(partial: false)
      } catch {
        self.recordNondurableUnavailable(count: 1, wallMilliseconds: wallMilliseconds)
      }
      self.maintenanceOwner.runtimeStarted()
    }
  }

  func afterCurrentPreparationPrefix(_ handler: @escaping @Sendable () -> Void) {
    preparationQueue.afterCurrentPrefix(handler)
  }

  var services: Services {
    Services(
      eventStore: eventStore,
      maintenance: maintenance,
      catalog: ViewerStoreCatalogService(pool: pool),
      diagnostics: ViewerStoreDiagnosticService(pool: pool, leases: leases),
      query: ViewerStoreQueryService(pool: pool, leases: leases),
      export: ViewerStoreExportService(pool: pool, leases: leases),
      preferences: preferences,
      statusSignal: statusSignal
    )
  }

  func sessionStarted(_ context: ViewerAdmissionSessionContext) -> Bool {
    preparationQueue.offer(bytes: ViewerStoreQuota.structuralReservation, kind: .lifecycle) {
      [weak self] _ in
      guard let self else { return }
      do {
        _ = try self.materializeSession(context, partial: false)
      } catch {
        self.nondurableConnections[context.connectionID] = context
      }
    }
  }

  func recoverRuntime(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64,
    missedObservationCount: Int64
  ) -> Bool {
    preparationQueue.offer(
      bytes: ViewerStoreQuota.structuralReservation,
      kind: .lifecycle
    ) { [weak self] _ in
      guard let self else { return }
      if self.runtimeLogicalID == nil {
        self.runtimeLogicalID = logicalID
        self.runtimeStartedWallMilliseconds = wallMilliseconds
        self.runtimeStartedMonotonicNanoseconds = monotonicNanoseconds
      }
      do {
        let recording = try self.ensureRecording(partial: true)
        if missedObservationCount > 0 {
          self.recordGap(
            recording: recording,
            device: nil,
            reason: "storageUnavailable",
            count: missedObservationCount
          )
        }
      } catch {}
      self.maintenanceOwner.runtimeStarted()
    }
  }

  func recoverSession(_ context: ViewerAdmissionSessionContext) -> Bool {
    preparationQueue.offer(
      bytes: ViewerStoreQuota.structuralReservation,
      kind: .lifecycle
    ) { [weak self] _ in
      guard let self else { return }
      do {
        if self.devices[context.connectionID] != nil {
          self.nondurableConnections.removeValue(forKey: context.connectionID)
          return
        }
        let stored = try self.materializeSession(context, partial: true)
        self.recordGap(context: stored, reason: "storageUnavailable", count: 1)
      } catch {
        self.nondurableConnections[context.connectionID] = context
      }
    }
  }

  func recoverRuntimeAndSessions(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64,
    missedObservationCount: Int64,
    sessions: [ViewerAdmissionSessionContext],
    completion: @escaping @Sendable (Bool) -> Void
  ) -> Bool {
    preparationQueue.offer(
      bytes: ViewerStoreQuota.structuralReservation,
      kind: .lifecycle
    ) { [weak self] _ in
      guard let self else {
        completion(false)
        return
      }
      var succeeded = false
      defer { completion(succeeded) }
      do {
        guard self.runtimeLogicalID == nil || self.runtimeLogicalID == logicalID else {
          throw ViewerStoreError.writeNotAuthorized
        }
        if self.runtimeLogicalID == nil {
          self.runtimeLogicalID = logicalID
          self.runtimeStartedWallMilliseconds = wallMilliseconds
          self.runtimeStartedMonotonicNanoseconds = monotonicNanoseconds
        }
        let recording = try self.ensureRecording(partial: true)
        for context in sessions {
          let wasDurable = self.devices[context.connectionID] != nil
          let stored = try self.materializeSession(context, partial: true)
          if !wasDurable {
            self.recordGap(context: stored, reason: "storageUnavailable", count: 1)
          }
        }
        if missedObservationCount > 0 {
          self.recordGap(
            recording: recording,
            device: nil,
            reason: "storageUnavailable",
            count: missedObservationCount
          )
        }
        self.maintenanceOwner.runtimeStarted()
        succeeded = true
      } catch {}
    }
  }

  func eventCommitted(
    _ observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) {
    let connectionID = observation.key.connectionID
    guard
      let pipelineBytes = try? ViewerStoreQuota.eventPipelineReservation(
        canonicalEventBytes: observation.deterministicEventBytes
      )
    else {
      recordPreparationDrop(connectionID: connectionID)
      outcome(.unavailable)
      return
    }
    let accepted = preparationQueue.offer(bytes: Int64(pipelineBytes)) {
      [weak self] reservation in
      guard let self else {
        outcome(.unavailable)
        return
      }
      guard let context = self.devices[connectionID] else {
        self.recordNondurableUnavailableIfTracked(connectionID: connectionID, count: 1)
        outcome(.unavailable)
        return
      }
      self.flushPreparationDrops(connectionID: connectionID, context: context)
      do {
        let prepared = try ViewerPreparedEventObservation(
          recording: context.recording,
          device: context.device,
          committed: observation
        )
        if self.ingress.admit(
          prepared,
          reservation: reservation,
          outcome: outcome
        ) != .admitted {
          self.recordGap(
            context: context,
            reason: "storeIngressFull",
            count: 1,
            direction: observation.key.direction,
            wireSequence: observation.key.wireSequence
          )
          outcome(.unavailable)
        }
      } catch {
        self.recordGap(
          context: context,
          reason: "storePreparationFailed",
          count: 1,
          direction: observation.key.direction,
          wireSequence: observation.key.wireSequence
        )
        outcome(.unavailable)
      }
    }
    if !accepted {
      recordPreparationDrop(connectionID: connectionID)
      outcome(.unavailable)
    }
  }

  func uplinkTerminated(
    connectionID: UUID,
    direction: EventDirection,
    wireSequence: UInt64,
    disposition: ViewerStoredDisposition,
    monotonicNanoseconds: UInt64
  ) {
    let accepted = preparationQueue.offer(
      bytes: ViewerStoreQuota.structuralReservation, kind: .structural
    ) { [weak self] reservation in
      guard let self else { return }
      guard let context = self.devices[connectionID] else {
        self.recordNondurableUnavailableIfTracked(connectionID: connectionID, count: 1)
        return
      }
      self.flushPreparationDrops(connectionID: connectionID, context: context)
      let admission = self.ingress.admit(
        .disposition(
          recording: context.recording,
          device: context.device,
          direction: direction,
          wireSequence: wireSequence,
          value: disposition,
          wallMilliseconds: Self.wallMilliseconds(),
          monotonicNanoseconds: monotonicNanoseconds
        ),
        reservation: reservation
      )
      if admission != .admitted {
        self.recordGap(
          context: context,
          reason: "uplinkDispositionJournalFull",
          count: 1,
          direction: direction,
          wireSequence: wireSequence
        )
      }
    }
    if !accepted { recordPreparationDrop(connectionID: connectionID) }
  }

  func sessionEnded(
    connectionID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) -> Bool {
    let accepted = preparationQueue.offer(
      bytes: ViewerStoreQuota.structuralReservation, kind: .lifecycle
    ) { [weak self] reservation in
      guard let self else { return }
      let endedNondurable = self.nondurableConnections.removeValue(forKey: connectionID) != nil
      guard let context = self.devices.removeValue(forKey: connectionID) else {
        if endedNondurable {
          self.recordNondurableEnded(wallMilliseconds: wallMilliseconds)
        }
        self.discardPreparationDrops(connectionID: connectionID)
        return
      }
      self.flushPreparationDrops(connectionID: connectionID, context: context)
      let admission = self.ingress.admit(
        .closeDevice(
          context.device,
          wallMilliseconds: wallMilliseconds,
          monotonicNanoseconds: monotonicNanoseconds
        ),
        reservation: reservation
      )
      if admission != .admitted {
        self.recordGap(
          context: context,
          reason: "deviceCloseJournalRejected",
          count: 1
        )
      }
    }
    if !accepted { orphanPreparationDrops(connectionID: connectionID, additional: 1) }
    return accepted
  }

  func policyChanged(
    connectionID: UUID,
    policy: ViewerRatePolicy,
    monotonicNanoseconds: UInt64
  ) {
    let accepted = preparationQueue.offer(
      bytes: ViewerStoreQuota.structuralReservation,
      kind: .structural
    ) { [weak self] reservation in
      guard let self else { return }
      guard var context = self.devices[connectionID] else {
        self.recordNondurableUnavailableIfTracked(connectionID: connectionID, count: 1)
        return
      }
      do {
        guard context.nextPolicySequence < UInt64.max else {
          self.recordGap(context: context, reason: "policyJournalSequenceExhausted", count: 1)
          return
        }
        let sequence = context.nextPolicySequence
        context.nextPolicySequence += 1
        self.devices[connectionID] = context
        let policyJSON = try ViewerCanonicalJSON.encode(policy)
        let admission = self.ingress.admit(
          .policy(
            device: context.device,
            sequence: sequence,
            wallMilliseconds: Self.wallMilliseconds(),
            monotonicNanoseconds: monotonicNanoseconds,
            policyJSON: policyJSON
          ),
          reservation: reservation
        )
        if admission != .admitted {
          self.recordGap(context: context, reason: "policyJournalFull", count: 1)
        }
      } catch {
        self.recordGap(context: context, reason: "policyJournalPreparationFailed", count: 1)
      }
    }
    if !accepted { recordPreparationDrop(connectionID: connectionID) }
  }

  func dropsChanged(
    connectionID: UUID,
    samples: [ViewerDropJournalSample],
    monotonicNanoseconds: UInt64
  ) {
    guard !samples.isEmpty, samples.count <= ViewerDropJournalSample.maximumBatchCount else {
      return
    }
    let accepted = preparationQueue.offer(
      bytes: ViewerStoreQuota.structuralReservation,
      kind: .structural
    ) { [weak self] _ in
      guard let self else { return }
      guard var context = self.devices[connectionID] else {
        self.recordNondurableUnavailableIfTracked(
          connectionID: connectionID,
          count: Int64(samples.count)
        )
        return
      }
      for sample in samples where sample.count > 0 {
        let reason = sample.reason.rawValue
        let count = Int64(min(sample.count, UInt64(Int64.max)))
        if let prior = context.projectedDropCounts[reason] {
          if count < prior {
            self.recordGap(context: context, reason: "dropJournalNonIncreasing", count: 1)
            continue
          }
          if count == prior { continue }
        }
        guard context.nextDropSequence < UInt64.max else {
          self.recordGap(context: context, reason: "dropJournalSequenceExhausted", count: 1)
          break
        }
        let sequence = context.nextDropSequence
        context.nextDropSequence += 1
        self.devices[connectionID] = context
        guard let reservation = self.pipelineBudget.reserve(bytes: 0, kind: .structural) else {
          self.recordGap(context: context, reason: "dropJournalFull", count: 1)
          continue
        }
        let admission = self.ingress.admit(
          .drop(
            device: context.device,
            sequence: sequence,
            wallMilliseconds: Self.wallMilliseconds(),
            monotonicNanoseconds: monotonicNanoseconds,
            reason: reason,
            count: count
          ),
          reservation: reservation
        )
        if admission != .admitted {
          self.recordGap(context: context, reason: "dropJournalFull", count: 1)
        } else {
          context.projectedDropCounts[reason] = count
        }
        self.devices[connectionID] = context
      }
    }
    if !accepted { recordPreparationDrop(connectionID: connectionID) }
  }

  func retryStorage() -> Bool {
    preparationQueue.offer(bytes: ViewerStoreQuota.structuralReservation, kind: .lifecycle) {
      [weak self] _ in
      guard let self else { return }
      do {
        let permit = try self.eventStore.prepareExplicitRecovery()
        _ = try self.ensureRecording(partial: true, recoveryPermit: permit)
        for (connectionID, context) in self.nondurableConnections {
          try self.recoverDevice(
            connectionID: connectionID,
            context: context,
            recoveryPermit: permit
          )
        }
        try self.eventStore.writeStateRelay.completeRecovery(permit)
        self.flushPendingGaps()
      } catch {}
    }
  }

  func requestMaintenance(
    _ trigger: ViewerStoreMaintenance.Trigger,
    recoveryAction: ViewerStoreRecoveryAction? = nil,
    settingsRevision: UInt64? = nil
  ) {
    maintenanceOwner.trigger(
      trigger,
      wallMilliseconds: Self.wallMilliseconds(),
      recoveryAction: recoveryAction,
      settingsRevision: settingsRevision
    )
  }

  func closeStorage() {
    closeOwnedStorage()
  }

  func runtimeEnded(wallMilliseconds: Int64, monotonicNanoseconds: UInt64) async {
    guard await claimRuntimeEndOwnership() else { return }
    maintenanceOwner.runtimeEnded()
    maintenanceOwner.waitForQuiescence()
    await withCheckedContinuation { continuation in
      let accepted = preparationQueue.finish { [weak self] in
        guard let self else {
          continuation.resume()
          return
        }
        self.nondurableConnections.removeAll()
        for (_, context) in self.devices {
          guard let reservation = self.pipelineBudget.reserve(bytes: 0, kind: .lifecycle) else {
            self.recordGap(context: context, reason: "shutdownStructuralFull", count: 1)
            continue
          }
          let admission = self.ingress.admit(
            .closeDevice(
              context.device,
              wallMilliseconds: wallMilliseconds,
              monotonicNanoseconds: monotonicNanoseconds
            ),
            reservation: reservation
          )
          if admission != .admitted {
            self.recordGap(context: context, reason: "shutdownStructuralRejected", count: 1)
          }
        }
        self.devices.removeAll()
        if let recording = self.currentRecording {
          if let reservation = self.pipelineBudget.reserve(bytes: 0, kind: .lifecycle) {
            let admission = self.ingress.admit(
              .closeRecording(
                recording,
                wallMilliseconds: wallMilliseconds,
                monotonicNanoseconds: monotonicNanoseconds
              ),
              reservation: reservation
            )
            _ = admission
          } else {
            self.recordGap(
              recording: recording,
              device: nil,
              reason: "shutdownStructuralFull",
              count: 1,
              wallMilliseconds: wallMilliseconds
            )
          }
        }
        self.flushPendingGaps()
        Task { [weak self] in
          guard let self else {
            continuation.resume()
            return
          }
          _ = await self.ingress.flush()
          self.activeRecordings.replace([])
          self.currentRecording = nil
          self.runtimeLogicalID = nil
          self.runtimeStartedWallMilliseconds = nil
          self.runtimeStartedMonotonicNanoseconds = nil
          self.closeOwnedStorage()
          continuation.resume()
        }
      }
      if !accepted {
        self.closeOwnedStorage()
        continuation.resume()
      }
    }
    finishRuntimeEndOwnership()
  }

  private func claimRuntimeEndOwnership() async -> Bool {
    await withCheckedContinuation { continuation in
      runtimeEndLock.lock()
      switch runtimeEndState {
      case .idle:
        runtimeEndState = .ending
        runtimeEndLock.unlock()
        continuation.resume(returning: true)
      case .ending:
        runtimeEndWaiters.append(continuation)
        runtimeEndLock.unlock()
      case .ended:
        runtimeEndLock.unlock()
        continuation.resume(returning: false)
      }
    }
  }

  private func finishRuntimeEndOwnership() {
    runtimeEndLock.lock()
    runtimeEndState = .ended
    let waiters = runtimeEndWaiters
    runtimeEndWaiters.removeAll(keepingCapacity: false)
    runtimeEndLock.unlock()
    for waiter in waiters { waiter.resume(returning: false) }
  }

  private func closeOwnedStorage() {
    storageCloseLock.lock()
    if storageCloseStarted {
      storageCloseLock.unlock()
      storageCloseGroup.wait()
      return
    }
    storageCloseStarted = true
    storageCloseGroup.enter()
    storageCloseLock.unlock()

    maintenanceOwner.close()
    statusSignal.deactivateAndWait()
    pool.close()
    storageCloseGroup.leave()
  }

  private func recordPreparationDrop(connectionID: UUID) {
    preparationDropLock.lock()
    if let current = preparationDrops[connectionID] {
      preparationDrops[connectionID] = current == Int64.max ? Int64.max : current + 1
    } else if preparationDrops.count < ViewerMultiDeviceSessionManager.maximumSessions {
      preparationDrops[connectionID] = 1
    } else if unattributedPreparationDrops < Int64.max {
      unattributedPreparationDrops += 1
    }
    preparationDropLock.unlock()
  }

  private func handleRejectedStructural(
    _ observation: ViewerStructuralObservation,
    error: ViewerStoreError
  ) {
    guard error == .staleObservation,
      case .drop(let device, _, _, _, _, _) = observation
    else { return }
    let accepted = preparationQueue.offer(
      bytes: ViewerStoreQuota.structuralReservation,
      kind: .structural
    ) { [weak self] _ in
      guard let self,
        let context = self.devices.values.first(where: { $0.device.rowID == device.rowID })
      else { return }
      self.recordGap(context: context, reason: "dropJournalNonIncreasing", count: 1)
    }
    if !accepted {
      preparationDropLock.lock()
      if unattributedPreparationDrops < Int64.max { unattributedPreparationDrops += 1 }
      preparationDropLock.unlock()
    }
  }

  private func flushPreparationDrops(connectionID: UUID, context: DeviceContext) {
    preparationDropLock.lock()
    let count = preparationDrops.removeValue(forKey: connectionID) ?? 0
    let unattributed = unattributedPreparationDrops
    unattributedPreparationDrops = 0
    preparationDropLock.unlock()
    if count > 0 {
      recordGap(context: context, reason: "storePreparationQueueFull", count: count)
    }
    if unattributed > 0 {
      recordGap(
        recording: context.recording,
        device: nil,
        reason: "storePreparationQueueFullUnattributed",
        count: unattributed
      )
    }
  }

  private func discardPreparationDrops(connectionID: UUID) {
    preparationDropLock.lock()
    preparationDrops.removeValue(forKey: connectionID)
    preparationDropLock.unlock()
  }

  private func orphanPreparationDrops(connectionID: UUID, additional: Int64) {
    preparationDropLock.lock()
    let existing = preparationDrops.removeValue(forKey: connectionID) ?? 0
    let (subtotal, firstOverflow) = existing.addingReportingOverflow(additional)
    let safeSubtotal = firstOverflow ? Int64.max : subtotal
    let (total, secondOverflow) = unattributedPreparationDrops.addingReportingOverflow(
      safeSubtotal
    )
    unattributedPreparationDrops = secondOverflow ? Int64.max : total
    preparationDropLock.unlock()
  }

  private func ensureRecording(
    partial: Bool,
    recoveryPermit: ViewerStoreStateRelay.RecoveryPermit? = nil
  ) throws -> ViewerRecordingHandle {
    if let currentRecording { return currentRecording }
    guard let logicalID = runtimeLogicalID,
      let wallMilliseconds = runtimeStartedWallMilliseconds,
      let monotonicNanoseconds = runtimeStartedMonotonicNanoseconds
    else { throw ViewerStoreError.unavailable }
    let recording = try eventStore.beginRecording(
      logicalID: logicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: monotonicNanoseconds,
      reason: partial ? "midRuntimeRetry" : "liveStart",
      recoveryPermit: recoveryPermit
    )
    currentRecording = recording
    activeRecordings.replace([recording.rowID])
    if nondurableUnavailableCount > 0 {
      recordGap(
        recording: recording,
        device: nil,
        reason: "storageUnavailable",
        count: nondurableUnavailableCount,
        firstWallMilliseconds: nondurableUnavailableFirstWallMilliseconds,
        wallMilliseconds: nondurableUnavailableLastWallMilliseconds ?? wallMilliseconds
      )
      nondurableUnavailableCount = 0
      nondurableUnavailableFirstWallMilliseconds = nil
      nondurableUnavailableLastWallMilliseconds = nil
    }
    return recording
  }

  @discardableResult
  private func materializeSession(
    _ context: ViewerAdmissionSessionContext,
    partial: Bool,
    recoveryPermit: ViewerStoreStateRelay.RecoveryPermit? = nil
  ) throws -> DeviceContext {
    if let existing = devices[context.connectionID] {
      nondurableConnections.removeValue(forKey: context.connectionID)
      return existing
    }
    let recording = try ensureRecording(partial: partial, recoveryPermit: recoveryPermit)
    let device = try eventStore.beginDeviceSession(
      recording: recording,
      installationID: context.appHello.installationID.rawValue,
      logicalID: context.connectionID,
      wallMilliseconds: Self.wallMilliseconds(),
      monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
      partialHistory: partial,
      displayName: context.appHello.displayName ?? context.appHello.applicationIdentifier,
      applicationIdentifier: context.appHello.applicationIdentifier,
      applicationVersion: context.appHello.applicationVersion,
      recoveryPermit: recoveryPermit
    )
    let stored = DeviceContext(recording: recording, device: device)
    devices[context.connectionID] = stored
    nondurableConnections.removeValue(forKey: context.connectionID)
    return stored
  }

  private func recoverDevice(
    connectionID: UUID,
    context: ViewerAdmissionSessionContext,
    recoveryPermit: ViewerStoreStateRelay.RecoveryPermit
  ) throws {
    guard nondurableConnections[connectionID] != nil else { return }
    let stored = try materializeSession(
      context,
      partial: true,
      recoveryPermit: recoveryPermit
    )
    recordGap(context: stored, reason: "storageUnavailable", count: 1)
  }

  private func recordNondurableEnded(wallMilliseconds: Int64) {
    recordNondurableUnavailable(count: 1, wallMilliseconds: wallMilliseconds)
  }

  private func recordNondurableUnavailableIfTracked(
    connectionID: UUID,
    count: Int64
  ) {
    guard nondurableConnections[connectionID] != nil else { return }
    recordNondurableUnavailable(count: count)
  }

  private func recordNondurableUnavailable(
    count: Int64,
    wallMilliseconds: Int64 = ViewerStoreCoordinator.wallMilliseconds()
  ) {
    guard count > 0 else { return }
    if let recording = currentRecording {
      recordGap(
        recording: recording,
        device: nil,
        reason: "storageUnavailable",
        count: count,
        wallMilliseconds: wallMilliseconds
      )
      return
    }
    let (next, overflow) = nondurableUnavailableCount.addingReportingOverflow(count)
    nondurableUnavailableCount = overflow ? Int64.max : next
    nondurableUnavailableFirstWallMilliseconds = min(
      nondurableUnavailableFirstWallMilliseconds ?? wallMilliseconds,
      wallMilliseconds
    )
    nondurableUnavailableLastWallMilliseconds = max(
      nondurableUnavailableLastWallMilliseconds ?? wallMilliseconds,
      wallMilliseconds
    )
  }

  private func recordGap(
    context: DeviceContext,
    reason: String,
    count: Int64,
    direction: EventDirection? = nil,
    wireSequence: UInt64? = nil
  ) {
    recordGap(
      recording: context.recording,
      device: context.device,
      reason: reason,
      count: count,
      direction: direction,
      wireSequence: wireSequence
    )
  }

  private func recordGap(
    recording: ViewerRecordingHandle,
    device: ViewerDeviceSessionHandle?,
    reason: String,
    count: Int64,
    direction: EventDirection? = nil,
    wireSequence: UInt64? = nil,
    firstWallMilliseconds: Int64? = nil,
    wallMilliseconds: Int64 = ViewerStoreCoordinator.wallMilliseconds()
  ) {
    let proposedKey = GapKey(recording: recording, device: device, reason: reason)
    let key: GapKey
    if pendingGaps[proposedKey] != nil || pendingGaps.count < 63 {
      key = proposedKey
    } else {
      key = GapKey(recording: recording, device: nil, reason: "coalescedOverflow")
    }
    if var pending = pendingGaps[key] {
      let (sum, overflow) = pending.count.addingReportingOverflow(count)
      pending.count = overflow ? Int64.max : sum
      pending.firstWallMilliseconds = min(
        pending.firstWallMilliseconds,
        firstWallMilliseconds ?? wallMilliseconds
      )
      pending.lastWallMilliseconds = max(pending.lastWallMilliseconds, wallMilliseconds)
      pending.directions = Self.mergedDirections(pending.directions, direction?.rawValue)
      if let wireSequence {
        pending.firstWireSequence = min(pending.firstWireSequence ?? wireSequence, wireSequence)
        pending.lastWireSequence = max(pending.lastWireSequence ?? wireSequence, wireSequence)
      }
      pendingGaps[key] = pending
    } else {
      let sequence = nextGapSequence
      nextGapSequence = nextGapSequence == UInt64.max ? 1 : nextGapSequence + 1
      pendingGaps[key] = PendingGap(
        sequence: sequence,
        count: max(1, count),
        firstWallMilliseconds: firstWallMilliseconds ?? wallMilliseconds,
        lastWallMilliseconds: wallMilliseconds,
        directions: direction?.rawValue ?? "unknown",
        firstWireSequence: wireSequence,
        lastWireSequence: wireSequence
      )
    }
    flushPendingGaps()
  }

  private func flushPendingGaps() {
    for key in Array(pendingGaps.keys) {
      guard let pending = pendingGaps[key] else { continue }
      guard let reservation = pipelineBudget.reserve(bytes: 0, kind: .structural) else {
        return
      }
      let admission = ingress.admit(
        .gap(
          recording: key.recording,
          device: key.device,
          sequence: pending.sequence,
          reason: key.reason,
          count: pending.count,
          firstWallMilliseconds: pending.firstWallMilliseconds,
          lastWallMilliseconds: pending.lastWallMilliseconds,
          directions: pending.directions,
          firstWireSequence: pending.firstWireSequence,
          lastWireSequence: pending.lastWireSequence
        ),
        reservation: reservation
      )
      if admission == .admitted { pendingGaps.removeValue(forKey: key) }
    }
  }

  private static func mergedDirections(_ existing: String, _ incoming: String?) -> String {
    guard let incoming else { return existing }
    if existing == "unknown" { return incoming }
    if existing == incoming || existing == "both" { return existing }
    return "both"
  }

  private func reconcileOrphans() throws {
    for _ in 0..<8 {
      let changed = try pool.writer.run { database -> Bool in
        let group = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT r.rowID FROM Recordings r JOIN RecordingVersions v ON v.recordingID=r.rowID WHERE v.rowID=(SELECT MAX(v2.rowID) FROM RecordingVersions v2 WHERE v2.recordingID=r.rowID) AND v.state='active' ORDER BY r.rowID LIMIT 1"
        )
        guard try group.step() else { return false }
        let recordingID = group.int64(at: 0)
        let nowWall = Self.wallMilliseconds()
        let nowMono = Int64(min(DispatchTime.now().uptimeNanoseconds, UInt64(Int64.max)))
        let children = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT d.rowID FROM DeviceSessions d JOIN DeviceSessionVersions v ON v.deviceSessionID=d.rowID WHERE d.recordingID=?1 AND v.rowID=(SELECT MAX(v2.rowID) FROM DeviceSessionVersions v2 WHERE v2.deviceSessionID=d.rowID) AND v.state='active' ORDER BY d.rowID LIMIT 17"
        )
        try children.bind(recordingID, at: 1)
        var childIDs: [Int64] = []
        while try children.step() { childIDs.append(children.int64(at: 0)) }
        guard childIDs.count <= 16 else { throw ViewerStoreError.corruptStore }

        let newVersionCount = Int64(childIDs.count + 1)
        let (quota, quotaOverflow) = newVersionCount.multipliedReportingOverflow(
          by: ViewerStoreQuota.structuralReservation
        )
        guard !quotaOverflow else { throw ViewerStoreError.capacityExceeded }
        let currentQuota = try ViewerStoreSchema.scalarInt64(
          "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
          database: database
        )
        let (nextQuota, quotaAdditionOverflow) = currentQuota.addingReportingOverflow(quota)
        guard !quotaAdditionOverflow,
          nextQuota <= preferences.load().capacityBytes
        else { throw ViewerStoreError.capacityExceeded }
        try pool.diskGuard.requireReserve(
          at: pool.paths.directory,
          plannedBytes: quota
        )
        try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
        do {

          for childID in childIDs {
            let closeChild = try ViewerSQLiteStatement(
              database: database,
              sql:
                "INSERT INTO DeviceSessionVersions(deviceSessionID, revision, createdWallMs, displayName, state, partialHistory, endedWallMs, endedMonotonicNs, quotaBytes) SELECT ?1, revision+1, ?2, displayName, 'recoveredAfterInterruption', partialHistory, ?2, ?3, ?4 FROM DeviceSessionVersions WHERE deviceSessionID=?1 ORDER BY revision DESC LIMIT 1"
            )
            try closeChild.bind(childID, at: 1)
            try closeChild.bind(nowWall, at: 2)
            try closeChild.bind(nowMono, at: 3)
            try closeChild.bind(ViewerStoreQuota.structuralReservation, at: 4)
            _ = try closeChild.step()
            guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }
          }

          let closeParent = try ViewerSQLiteStatement(
            database: database,
            sql:
              "INSERT INTO RecordingVersions(recordingID, revision, createdWallMs, name, note, pinned, state, endedWallMs, endedMonotonicNs, quotaBytes) SELECT ?1, revision+1, ?2, name, note, pinned, 'recoveredAfterInterruption', ?2, ?3, ?4 FROM RecordingVersions WHERE recordingID=?1 ORDER BY revision DESC LIMIT 1"
          )
          try closeParent.bind(recordingID, at: 1)
          try closeParent.bind(nowWall, at: 2)
          try closeParent.bind(nowMono, at: 3)
          try closeParent.bind(ViewerStoreQuota.structuralReservation, at: 4)
          _ = try closeParent.step()
          guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }

          let updateQuota = try ViewerSQLiteStatement(
            database: database,
            sql: "UPDATE StoreMetadata SET integerValue=?1 WHERE key='logicalQuotaBytes'"
          )
          try updateQuota.bind(nextQuota, at: 1)
          _ = try updateQuota.step()
          let updateRecordingQuota = try ViewerSQLiteStatement(
            database: database,
            sql: "UPDATE Recordings SET liveQuotaBytes=liveQuotaBytes+?1 WHERE rowID=?2"
          )
          try updateRecordingQuota.bind(quota, at: 1)
          try updateRecordingQuota.bind(recordingID, at: 2)
          _ = try updateRecordingQuota.step()
          guard sqlite3_changes(database) == 1 else { throw ViewerStoreError.corruptStore }
          try ViewerSQLiteConnection.execute("COMMIT", on: database)
          return true
        } catch {
          try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
          throw error
        }
      }
      if !changed { return }
    }
    let remaining = try pool.queryReader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64(
        "SELECT COUNT(*) FROM Recordings r JOIN RecordingVersions v ON v.recordingID=r.rowID WHERE v.rowID=(SELECT MAX(v2.rowID) FROM RecordingVersions v2 WHERE v2.recordingID=r.rowID) AND v.state='active'",
        database: $0
      )
    }
    guard remaining == 0 else { throw ViewerStoreError.busy }
  }

  private static func wallMilliseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded())
  }

  var description: String { "ViewerStoreCoordinator(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

private final class ViewerJournalPreparationQueue: @unchecked Sendable {
  private struct Item {
    let operation: @Sendable () -> Void
  }

  private let budget: ViewerJournalPipelineBudget
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.nearwire.viewer.store-preparation")
  private var items: [UInt64: Item] = [:]
  private var nextOffer: UInt64 = 1
  private var nextDrain: UInt64 = 1
  private var scheduled = false
  private var stopped = false

  init(budget: ViewerJournalPipelineBudget) { self.budget = budget }

  func offer(
    bytes: Int64,
    kind: ViewerJournalPipelineBudget.Kind = .event,
    operation: @escaping @Sendable (ViewerJournalPipelineBudget.Reservation) -> Void
  ) -> Bool {
    guard bytes >= 0, bytes <= Int64(Int.max),
      let reservation = budget.reserve(
        bytes: Int(bytes),
        kind: kind
      )
    else { return false }
    lock.lock()
    guard !stopped, nextOffer < UInt64.max else {
      lock.unlock()
      return false
    }
    items[nextOffer] = Item { operation(reservation) }
    nextOffer &+= 1
    if !scheduled {
      scheduled = true
      queue.async { [weak self] in self?.drain() }
    }
    lock.unlock()
    return true
  }

  func finish(operation: @escaping @Sendable () -> Void) -> Bool {
    lock.lock()
    guard !stopped, nextOffer < UInt64.max else {
      lock.unlock()
      return false
    }
    stopped = true
    items[nextOffer] = Item(operation: operation)
    nextOffer &+= 1
    if !scheduled {
      scheduled = true
      queue.async { [weak self] in self?.drain() }
    }
    lock.unlock()
    return true
  }

  func afterCurrentPrefix(_ handler: @escaping @Sendable () -> Void) {
    queue.async(execute: handler)
  }

  private func drain() {
    while true {
      let item: Item
      lock.lock()
      if let next = items.removeValue(forKey: nextDrain) {
        item = next
        nextDrain &+= 1
      } else {
        scheduled = false
        lock.unlock()
        return
      }
      lock.unlock()

      item.operation()

      lock.lock()
      if items.isEmpty {
        nextOffer = 1
        nextDrain = 1
      }
      lock.unlock()
    }
  }
}

private final class ViewerStoragePreferenceBox: @unchecked Sendable {
  private let preferences: ViewerStoragePreferences
  init(_ preferences: ViewerStoragePreferences) { self.preferences = preferences }
  func load() -> ViewerStorageConfiguration { preferences.load() }
}

private final class ViewerActiveRecordingBox: @unchecked Sendable {
  private let lock = NSLock()
  private var ids: Set<Int64> = []

  func replace(_ ids: Set<Int64>) {
    lock.lock()
    self.ids = ids
    lock.unlock()
  }

  func snapshot() -> Set<Int64> {
    lock.lock()
    defer { lock.unlock() }
    return ids
  }
}

enum ViewerStoreReopenResourceEvent: Equatable, Sendable {
  case coordinatorConstructed
  case runtimeEndWaiting
  case staleCoordinatorClosed
  case terminalCloseWaiting
}

enum ViewerStoreStartupMode: Equatable, Sendable {
  case synchronous
  case asynchronous
}

private final class ViewerStoreReopenConstructionLease: @unchecked Sendable {
  private let completion = DispatchGroup()

  init() {
    completion.enter()
  }

  func finish() {
    completion.leave()
  }

  func waitSynchronously() {
    completion.wait()
  }

  func waitUntilFinished() async {
    await withCheckedContinuation { continuation in
      completion.notify(queue: .global(qos: .utility)) {
        continuation.resume()
      }
    }
  }
}

final class ViewerStoreRuntime: ViewerSessionJournaling, @unchecked Sendable,
  CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible
{
  private struct RuntimeContext {
    let logicalID: UUID
    let wallMilliseconds: Int64
    let monotonicNanoseconds: UInt64
  }

  private enum ReopenRequest: Equatable {
    case automatic(runtimeLogicalID: UUID?)
    case explicit(runtimeLogicalID: UUID?)
  }

  private struct ReopenConstruction {
    let request: ReopenRequest
    let generation: UInt64
    let lease: ViewerStoreReopenConstructionLease
    let migrationToken: ViewerStoreMigrationToken
  }

  private let lock = NSLock()
  private let reopenQueue = DispatchQueue(label: "com.nearwire.viewer.store-reopen")
  private let preferences: ViewerStoragePreferences
  private let scheduler: ViewerAdmissionScheduler
  private let paths: ViewerStorePaths?
  private let diskGuard: ViewerStoreDiskGuard
  private let migrationTemporaryDirectory: URL
  private let automaticMigrationAuthorization: @Sendable (URL) -> Bool
  private let migrationPhaseGate: @Sendable (ViewerStoreMigrationPhase) throws -> Void
  private let coordinatorWriteGate: @Sendable () throws -> Void
  private let reopenExecutionGate: @Sendable () -> Void
  private let reopenResourceObserver: @Sendable (ViewerStoreReopenResourceEvent) -> Void
  private let outwardStatusSignal = ViewerStoreStatusSignal()
  let explorerGateway: ViewerStoreExplorerGateway
  private var coordinator: ViewerStoreCoordinator?
  private var coordinatorRuntimeLogicalID: UUID?
  private var runtimeContext: RuntimeContext?
  private var activeSessions: [UUID: ViewerAdmissionSessionContext] = [:]
  private var missedObservationCount: Int64 = 0
  private var reopenScheduled = false
  private var reopenWorkerScheduled = false
  private var reopenRequest: ReopenRequest?
  private var reopenAttemptGeneration: UInt64 = 0
  private var reopenConstruction: ReopenConstruction?
  private var migrationStatus: ViewerStoreMigrationStatus?
  private var needsRuntimeReopen = false
  private var coordinatorNeedsRecovery = false
  private var settingsRevision: UInt64 = 0
  private var recoveryAttemptGeneration: UInt64 = 0
  private var recoveryInFlight = false
  private var recoveryClaimedMissedCount: Int64 = 0

  init(
    preferences: ViewerStoragePreferences = ViewerStoragePreferences(),
    scheduler: ViewerAdmissionScheduler = .live,
    paths: ViewerStorePaths? = try? ViewerStorePaths.applicationSupport(),
    startupMode: ViewerStoreStartupMode = .synchronous,
    diskGuard: ViewerStoreDiskGuard = .live,
    migrationTemporaryDirectory: URL = FileManager.default.temporaryDirectory,
    automaticMigrationAuthorization: @escaping @Sendable (URL) -> Bool = {
      ViewerStoreAutomaticMigrationGate.shared.claim($0)
    },
    migrationPhaseGate: @escaping @Sendable (ViewerStoreMigrationPhase) throws -> Void = { _ in },
    explorerOperationExecutionGate: @escaping @Sendable () -> Void = {},
    coordinatorWriteGate: @escaping @Sendable () throws -> Void = {},
    reopenExecutionGate: @escaping @Sendable () -> Void = {},
    reopenResourceObserver: @escaping @Sendable (ViewerStoreReopenResourceEvent) -> Void = { _ in }
  ) {
    self.preferences = preferences
    self.scheduler = scheduler
    self.paths = paths
    self.diskGuard = diskGuard
    self.migrationTemporaryDirectory = migrationTemporaryDirectory
    self.automaticMigrationAuthorization = automaticMigrationAuthorization
    self.migrationPhaseGate = migrationPhaseGate
    explorerGateway = ViewerStoreExplorerGateway(
      operationExecutionGate: explorerOperationExecutionGate
    )
    self.coordinatorWriteGate = coordinatorWriteGate
    self.reopenExecutionGate = reopenExecutionGate
    self.reopenResourceObserver = reopenResourceObserver
    switch startupMode {
    case .synchronous:
      coordinator = paths.flatMap {
        try? ViewerStoreCoordinator(
          paths: $0,
          preferences: preferences,
          scheduler: scheduler,
          diskGuard: diskGuard,
          writeGate: coordinatorWriteGate
        )
      }
    case .asynchronous:
      coordinator = nil
      needsRuntimeReopen = true
    }
    outwardStatusSignal.setSnapshotProvider { [weak self] in
      guard let self else { return nil }
      let base = self.coordinatorSnapshot()?.services.eventStore.currentChangeSnapshot()
      return ViewerStoreChangeSnapshot(
        changedRecordingIDs: [],
        eventUpperRowID: base?.eventUpperRowID ?? 0,
        status: self.status()
      )
    }
    let signal = outwardStatusSignal
    coordinator?.services.statusSignal.setHandler { [weak signal] snapshot in
      signal?.publish(changedRecordingIDs: Set(snapshot.changedRecordingIDs))
    }
    if let coordinator { explorerGateway.install(coordinator) }
    if startupMode == .asynchronous, paths != nil {
      scheduleReopen(.automatic(runtimeLogicalID: nil))
    }
  }

  func loadConfiguration() -> ViewerStorageConfiguration { preferences.load() }

  func saveConfiguration(_ value: ViewerStorageConfiguration) {
    lock.lock()
    let previous = preferences.load()
    preferences.save(value)
    settingsRevision = settingsRevision == UInt64.max ? 1 : settingsRevision + 1
    let revision = settingsRevision
    let coordinator = coordinator
    lock.unlock()
    let canRecover =
      value.capacityBytes > previous.capacityBytes
      || value.historyRetentionDays < previous.historyRetentionDays
    coordinator?.requestMaintenance(
      .settingsChanged,
      recoveryAction: canRecover ? .settingsChanged : nil,
      settingsRevision: revision
    )
    outwardStatusSignal.publish()
  }

  func status() -> ViewerStoreStatus {
    lock.lock()
    let coordinator = coordinator
    let needsRecovery = coordinatorNeedsRecovery
    let migrationStatus = migrationStatus
    lock.unlock()
    let current = coordinator?.services.eventStore.status()
    if needsRecovery, let current {
      return ViewerStoreStatus(
        state: .unavailable,
        migration: migrationStatus,
        capacityBytes: current.capacityBytes,
        logicalQuotaBytes: current.logicalQuotaBytes,
        allocatedFootprintBytes: current.allocatedFootprintBytes,
        oldestHistoryMilliseconds: current.oldestHistoryMilliseconds,
        pinnedQuotaBytes: current.pinnedQuotaBytes,
        estimatedRetainedDurationMilliseconds: current.estimatedRetainedDurationMilliseconds,
        lastCleanupCategory: current.lastCleanupCategory
      )
    }
    return current
      ?? ViewerStoreStatus(
        state: .unavailable,
        migration: migrationStatus,
        capacityBytes: preferences.load().capacityBytes,
        logicalQuotaBytes: 0,
        allocatedFootprintBytes: 0,
        oldestHistoryMilliseconds: nil,
        pinnedQuotaBytes: 0,
        estimatedRetainedDurationMilliseconds: nil,
        lastCleanupCategory: .none
      )
  }

  func observeStatus(_ handler: @escaping @Sendable () -> Void) {
    outwardStatusSignal.setHandler { _ in handler() }
  }

  var isRecoveryInFlight: Bool {
    lock.lock()
    defer { lock.unlock() }
    return recoveryInFlight
  }

  func afterCurrentJournalPrefix(_ handler: @escaping @Sendable () -> Void) {
    guard let coordinator = coordinatorSnapshot() else {
      handler()
      return
    }
    coordinator.afterCurrentPreparationPrefix(handler)
  }

  func afterCurrentReopenPrefix(_ handler: @escaping @Sendable () -> Void) {
    reopenQueue.async(execute: handler)
  }

  func runCleanup() {
    coordinatorSnapshot()?.requestMaintenance(.explicit)
  }

  func closeStorage() {
    lock.lock()
    let coordinator = coordinator
    let reopenConstructionLease = reopenConstruction?.lease
    self.coordinator = nil
    coordinatorRuntimeLogicalID = nil
    runtimeContext = nil
    activeSessions.removeAll(keepingCapacity: false)
    missedObservationCount = 0
    invalidateRecoveryAttemptLocked()
    invalidateReopenAttemptLocked()
    needsRuntimeReopen = false
    coordinatorNeedsRecovery = false
    lock.unlock()
    if reopenConstructionLease != nil { reopenResourceObserver(.terminalCloseWaiting) }
    reopenConstructionLease?.waitSynchronously()
    if let coordinator { explorerGateway.sealAndWait(originatingFrom: coordinator) }
    coordinator?.closeStorage()
  }

  func runtimeStarted(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {
    lock.lock()
    let previousRuntimeID = runtimeContext?.logicalID
    guard previousRuntimeID != logicalID else {
      lock.unlock()
      return
    }
    invalidateRecoveryAttemptLocked()
    if reopenRequest != .automatic(runtimeLogicalID: nil) {
      invalidateReopenAttemptLocked()
    }
    runtimeContext = RuntimeContext(
      logicalID: logicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: monotonicNanoseconds
    )
    activeSessions.removeAll(keepingCapacity: true)
    missedObservationCount = 0
    let coordinator = coordinator
    let coordinatorGeneration = coordinatorRuntimeLogicalID
    let coordinatorIsAttachable =
      coordinator != nil && (coordinatorGeneration == nil || coordinatorGeneration == logicalID)
    if !coordinatorIsAttachable {
      coordinatorNeedsRecovery = true
      addMissedLocked(1)
    }
    let shouldReopen = coordinator == nil && needsRuntimeReopen
    lock.unlock()
    if shouldReopen {
      scheduleReopen(.automatic(runtimeLogicalID: logicalID))
      return
    }
    guard coordinatorIsAttachable, let coordinator else {
      outwardStatusSignal.publish()
      return
    }
    if coordinatorGeneration == nil {
      lock.lock()
      if self.coordinator === coordinator, coordinatorRuntimeLogicalID == nil {
        coordinatorRuntimeLogicalID = logicalID
      }
      lock.unlock()
    }
    if coordinator.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: monotonicNanoseconds
    ) {
      lock.lock()
      if self.coordinator === coordinator, runtimeContext?.logicalID == logicalID {
        coordinatorRuntimeLogicalID = logicalID
        coordinatorNeedsRecovery = false
      }
      lock.unlock()
    } else {
      recordRecoveryNeeded(from: coordinator, runtimeLogicalID: logicalID, missed: 1)
    }
  }

  func sessionStarted(runtimeLogicalID: UUID, _ context: ViewerAdmissionSessionContext) {
    lock.lock()
    guard runtimeContext?.logicalID == runtimeLogicalID else {
      lock.unlock()
      return
    }
    if activeSessions[context.connectionID] != nil
      || activeSessions.count < ViewerMultiDeviceSessionManager.maximumSessions
    {
      activeSessions[context.connectionID] = context
    }
    let coordinator =
      coordinatorNeedsRecovery || coordinatorRuntimeLogicalID != runtimeLogicalID
      ? nil : coordinator
    if coordinator == nil { addMissedLocked(1) }
    lock.unlock()
    if let coordinator, !coordinator.sessionStarted(context) {
      recordRecoveryNeeded(from: coordinator, runtimeLogicalID: runtimeLogicalID, missed: 1)
    }
  }

  func eventCommitted(
    _ observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) {
    let runtimeLogicalID = observation.key.runtimeLogicalID
    lock.lock()
    guard runtimeContext?.logicalID == runtimeLogicalID else {
      lock.unlock()
      outcome(.unavailable)
      return
    }
    let coordinator =
      coordinatorNeedsRecovery || coordinatorRuntimeLogicalID != runtimeLogicalID
      ? nil : coordinator
    if coordinator == nil { addMissedLocked(1) }
    lock.unlock()
    guard let coordinator else {
      outcome(.unavailable)
      return
    }
    coordinator.eventCommitted(observation, outcome: outcome)
  }

  func uplinkTerminated(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    direction: EventDirection,
    wireSequence: UInt64,
    disposition: ViewerStoredDisposition,
    monotonicNanoseconds: UInt64
  ) {
    lock.lock()
    guard runtimeContext?.logicalID == runtimeLogicalID else {
      lock.unlock()
      return
    }
    let coordinator =
      coordinatorNeedsRecovery || coordinatorRuntimeLogicalID != runtimeLogicalID
      ? nil : coordinator
    if coordinator == nil { addMissedLocked(1) }
    lock.unlock()
    coordinator?.uplinkTerminated(
      connectionID: connectionID,
      direction: direction,
      wireSequence: wireSequence,
      disposition: disposition,
      monotonicNanoseconds: monotonicNanoseconds
    )
  }

  func policyChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    policy: ViewerRatePolicy,
    monotonicNanoseconds: UInt64
  ) {
    lock.lock()
    guard runtimeContext?.logicalID == runtimeLogicalID else {
      lock.unlock()
      return
    }
    let coordinator =
      coordinatorNeedsRecovery || coordinatorRuntimeLogicalID != runtimeLogicalID
      ? nil : coordinator
    if coordinator == nil { addMissedLocked(1) }
    lock.unlock()
    coordinator?.policyChanged(
      connectionID: connectionID,
      policy: policy,
      monotonicNanoseconds: monotonicNanoseconds
    )
  }

  func dropsChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    samples: [ViewerDropJournalSample],
    monotonicNanoseconds: UInt64
  ) {
    lock.lock()
    guard runtimeContext?.logicalID == runtimeLogicalID else {
      lock.unlock()
      return
    }
    let coordinator =
      coordinatorNeedsRecovery || coordinatorRuntimeLogicalID != runtimeLogicalID
      ? nil : coordinator
    if coordinator == nil { addMissedLocked(Int64(samples.count)) }
    lock.unlock()
    coordinator?.dropsChanged(
      connectionID: connectionID,
      samples: samples,
      monotonicNanoseconds: monotonicNanoseconds
    )
  }

  func sessionEnded(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {
    lock.lock()
    guard runtimeContext?.logicalID == runtimeLogicalID else {
      lock.unlock()
      return
    }
    activeSessions.removeValue(forKey: connectionID)
    let coordinator =
      coordinatorNeedsRecovery || coordinatorRuntimeLogicalID != runtimeLogicalID
      ? nil : coordinator
    if coordinator == nil { addMissedLocked(1) }
    lock.unlock()
    if let coordinator,
      !coordinator.sessionEnded(
        connectionID: connectionID,
        wallMilliseconds: wallMilliseconds,
        monotonicNanoseconds: monotonicNanoseconds
      )
    {
      recordRecoveryNeeded(from: coordinator, runtimeLogicalID: runtimeLogicalID, missed: 1)
    }
  }

  func retryStorage() {
    lock.lock()
    if let coordinator {
      guard let runtimeLogicalID = runtimeContext?.logicalID,
        coordinatorRuntimeLogicalID == runtimeLogicalID,
        !recoveryInFlight
      else {
        lock.unlock()
        return
      }
      let needsRecovery = coordinatorNeedsRecovery
      let runtimeContext = runtimeContext
      let sessions = activeSessions.values.sorted {
        $0.connectionID.uuidString < $1.connectionID.uuidString
      }
      let recoveryAttempt = needsRecovery ? beginRecoveryAttemptLocked() : nil
      lock.unlock()
      guard coordinator.retryStorage() else {
        if let recoveryAttempt {
          completeRecoveryAttempt(
            generation: recoveryAttempt.generation,
            coordinator: coordinator,
            runtimeLogicalID: runtimeLogicalID,
            succeeded: false
          )
        } else {
          recordRecoveryNeeded(
            from: coordinator,
            runtimeLogicalID: runtimeLogicalID,
            missed: 0
          )
        }
        return
      }
      guard let recoveryAttempt, let runtimeContext else { return }
      let accepted = coordinator.recoverRuntimeAndSessions(
        logicalID: runtimeContext.logicalID,
        wallMilliseconds: runtimeContext.wallMilliseconds,
        monotonicNanoseconds: runtimeContext.monotonicNanoseconds,
        missedObservationCount: recoveryAttempt.claimedMissedCount,
        sessions: sessions
      ) { [weak self, weak coordinator] succeeded in
        guard let self, let coordinator else { return }
        self.completeRecoveryAttempt(
          generation: recoveryAttempt.generation,
          coordinator: coordinator,
          runtimeLogicalID: runtimeLogicalID,
          succeeded: succeeded
        )
      }
      if !accepted {
        completeRecoveryAttempt(
          generation: recoveryAttempt.generation,
          coordinator: coordinator,
          runtimeLogicalID: runtimeLogicalID,
          succeeded: false
        )
      }
      return
    }
    let request = ReopenRequest.explicit(runtimeLogicalID: runtimeContext?.logicalID)
    guard beginReopenRequestLocked(request) != nil else {
      lock.unlock()
      return
    }
    let shouldEnqueueWorker = beginReopenWorkerLocked()
    lock.unlock()
    if shouldEnqueueWorker { enqueueReopenWorker() }
  }

  func runtimeEnded(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) async {
    let (coordinator, successorRuntimeLogicalID, reopenConstructionLease) =
      detachRuntime(logicalID: logicalID)
    if let reopenConstructionLease {
      reopenResourceObserver(.runtimeEndWaiting)
      await reopenConstructionLease.waitUntilFinished()
    }
    if let coordinator { explorerGateway.sealAndWait(originatingFrom: coordinator) }
    await coordinator?.runtimeEnded(
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: monotonicNanoseconds
    )
    if let successorRuntimeLogicalID {
      scheduleReopen(.automatic(runtimeLogicalID: successorRuntimeLogicalID))
    }
  }

  private func detachRuntime(
    logicalID: UUID
  ) -> (
    coordinator: ViewerStoreCoordinator?, successorRuntimeLogicalID: UUID?,
    reopenConstructionLease: ViewerStoreReopenConstructionLease?
  ) {
    lock.lock()
    let matchesCurrentRuntime = runtimeContext?.logicalID == logicalID
    let reopenConstructionLease =
      matchesCurrentRuntime
      ? reopenConstruction?.lease : reopenConstructionLeaseLocked(for: logicalID)
    if matchesCurrentRuntime {
      invalidateReopenAttemptLocked()
      runtimeContext = nil
      activeSessions.removeAll(keepingCapacity: false)
      missedObservationCount = 0
      invalidateRecoveryAttemptLocked()
      coordinatorNeedsRecovery = false
    }
    guard coordinatorRuntimeLogicalID == logicalID else {
      lock.unlock()
      return (nil, nil, reopenConstructionLease)
    }
    let coordinator = coordinator
    self.coordinator = nil
    coordinatorRuntimeLogicalID = nil
    let successorRuntimeLogicalID = runtimeContext?.logicalID
    needsRuntimeReopen = true
    if successorRuntimeLogicalID != nil { coordinatorNeedsRecovery = true }
    lock.unlock()
    return (coordinator, successorRuntimeLogicalID, reopenConstructionLease)
  }

  private func scheduleReopen(_ request: ReopenRequest) {
    lock.lock()
    guard beginReopenRequestLocked(request) != nil else {
      lock.unlock()
      return
    }
    let shouldEnqueueWorker = beginReopenWorkerLocked()
    lock.unlock()
    if shouldEnqueueWorker { enqueueReopenWorker() }
  }

  private func enqueueReopenWorker() {
    reopenQueue.async { [weak self] in
      self?.processReopenWorkerTurn()
    }
  }

  private func processReopenWorkerTurn() {
    lock.lock()
    guard reopenWorkerScheduled, reopenScheduled, let request = reopenRequest else {
      reopenWorkerScheduled = false
      lock.unlock()
      return
    }
    let generation = reopenAttemptGeneration
    lock.unlock()

    attemptReopen(request, generation: generation)

    lock.lock()
    let shouldRunSuccessor = reopenScheduled
    if !shouldRunSuccessor { reopenWorkerScheduled = false }
    lock.unlock()
    if shouldRunSuccessor { enqueueReopenWorker() }
  }

  private func attemptReopen(_ request: ReopenRequest, generation: UInt64) {
    lock.lock()
    guard isCurrentReopenRequestLocked(request, generation: generation) else {
      lock.unlock()
      return
    }
    let constructionLease = ViewerStoreReopenConstructionLease()
    let migrationToken = ViewerStoreMigrationToken()
    reopenConstruction = ReopenConstruction(
      request: request,
      generation: generation,
      lease: constructionLease,
      migrationToken: migrationToken
    )
    lock.unlock()
    defer {
      finishReopenConstruction(
        request: request,
        generation: generation,
        lease: constructionLease
      )
    }

    reopenExecutionGate()
    let isAutomatic: Bool
    switch request {
    case .automatic: isAutomatic = true
    case .explicit: isAutomatic = false
    }
    guard let paths,
      let replacement = try? ViewerStoreCoordinator(
        paths: paths,
        preferences: preferences,
        scheduler: scheduler,
        diskGuard: diskGuard,
        migrationControl: ViewerStoreMigrationControl(
          paths: paths,
          temporaryDirectory: migrationTemporaryDirectory,
          diskGuard: diskGuard,
          authorizeAttempt: { [automaticMigrationAuthorization] in
            !isAutomatic || automaticMigrationAuthorization(paths.database)
          },
          isCancelled: { migrationToken.isCancelled },
          phaseObserver: { [weak self, weak migrationToken] phase in
            guard let migrationToken else { return }
            self?.migrationPhaseChanged(phase, token: migrationToken)
          },
          phaseGate: migrationPhaseGate
        ),
        writeGate: coordinatorWriteGate
      )
    else {
      lock.lock()
      let isCurrent = isCurrentReopenRequestLocked(request, generation: generation)
      if isCurrent { clearReopenRequestLocked() }
      lock.unlock()
      if isCurrent { outwardStatusSignal.publish() }
      return
    }
    reopenResourceObserver(.coordinatorConstructed)
    let signal = outwardStatusSignal
    replacement.services.statusSignal.setHandler { [weak signal] snapshot in
      signal?.publish(changedRecordingIDs: Set(snapshot.changedRecordingIDs))
    }
    lock.lock()
    guard isCurrentReopenRequestLocked(request, generation: generation) else {
      lock.unlock()
      replacement.closeStorage()
      reopenResourceObserver(.staleCoordinatorClosed)
      return
    }
    explorerGateway.install(replacement)
    let runtimeContext = runtimeContext
    let sessions = activeSessions.values.sorted {
      $0.connectionID.uuidString < $1.connectionID.uuidString
    }
    coordinator = replacement
    coordinatorRuntimeLogicalID = runtimeContext?.logicalID
    needsRuntimeReopen = false
    coordinatorNeedsRecovery = runtimeContext != nil
    let recoveryAttempt = runtimeContext.map { _ in beginRecoveryAttemptLocked() }
    clearReopenRequestLocked()
    lock.unlock()
    clearMigrationStatus(token: migrationToken)
    outwardStatusSignal.publish()
    guard let runtimeContext, let recoveryAttempt else { return }
    let accepted = replacement.recoverRuntimeAndSessions(
      logicalID: runtimeContext.logicalID,
      wallMilliseconds: runtimeContext.wallMilliseconds,
      monotonicNanoseconds: runtimeContext.monotonicNanoseconds,
      missedObservationCount: recoveryAttempt.claimedMissedCount,
      sessions: sessions
    ) { [weak self, weak replacement] succeeded in
      guard let self, let replacement else { return }
      self.completeRecoveryAttempt(
        generation: recoveryAttempt.generation,
        coordinator: replacement,
        runtimeLogicalID: runtimeContext.logicalID,
        succeeded: succeeded
      )
    }
    if !accepted {
      completeRecoveryAttempt(
        generation: recoveryAttempt.generation,
        coordinator: replacement,
        runtimeLogicalID: runtimeContext.logicalID,
        succeeded: false
      )
    }
  }

  private func coordinatorSnapshot() -> ViewerStoreCoordinator? {
    lock.lock()
    defer { lock.unlock() }
    return coordinator
  }

  private func beginReopenRequestLocked(_ request: ReopenRequest) -> UInt64? {
    guard coordinator == nil, !reopenScheduled,
      reopenRequestMatchesCurrentRuntimeLocked(request)
    else { return nil }
    reopenAttemptGeneration =
      reopenAttemptGeneration == UInt64.max ? 1 : reopenAttemptGeneration + 1
    reopenScheduled = true
    reopenRequest = request
    return reopenAttemptGeneration
  }

  private func beginReopenWorkerLocked() -> Bool {
    guard !reopenWorkerScheduled else { return false }
    reopenWorkerScheduled = true
    return true
  }

  private func reopenConstructionLeaseLocked(
    for runtimeLogicalID: UUID
  ) -> ViewerStoreReopenConstructionLease? {
    guard let construction = reopenConstruction else { return nil }
    switch construction.request {
    case .automatic(.some(let requestRuntimeLogicalID)),
      .explicit(.some(let requestRuntimeLogicalID)):
      return requestRuntimeLogicalID == runtimeLogicalID ? construction.lease : nil
    case .automatic(.none), .explicit(.none):
      return nil
    }
  }

  private func isCurrentReopenRequestLocked(
    _ request: ReopenRequest,
    generation: UInt64
  ) -> Bool {
    guard reopenScheduled, reopenAttemptGeneration == generation,
      reopenRequest == request, coordinator == nil
    else { return false }
    return reopenRequestMatchesCurrentRuntimeLocked(request)
  }

  private func reopenRequestMatchesCurrentRuntimeLocked(_ request: ReopenRequest) -> Bool {
    switch request {
    case .automatic(.some(let runtimeLogicalID)), .explicit(.some(let runtimeLogicalID)):
      return runtimeContext?.logicalID == runtimeLogicalID
    case .automatic(.none):
      return true
    case .explicit(.none):
      return runtimeContext == nil
    }
  }

  private func clearReopenRequestLocked() {
    reopenScheduled = false
    reopenRequest = nil
  }

  private func invalidateReopenAttemptLocked() {
    reopenConstruction?.migrationToken.cancel()
    reopenAttemptGeneration =
      reopenAttemptGeneration == UInt64.max ? 1 : reopenAttemptGeneration + 1
    clearReopenRequestLocked()
  }

  private func finishReopenConstruction(
    request: ReopenRequest,
    generation: UInt64,
    lease: ViewerStoreReopenConstructionLease
  ) {
    lock.lock()
    if let construction = reopenConstruction,
      construction.request == request,
      construction.generation == generation,
      construction.lease === lease
    {
      reopenConstruction = nil
    }
    lock.unlock()
    lease.finish()
  }

  private func migrationPhaseChanged(
    _ phase: ViewerStoreMigrationPhase,
    token: ViewerStoreMigrationToken
  ) {
    lock.lock()
    guard reopenConstruction?.migrationToken === token else {
      lock.unlock()
      return
    }
    migrationStatus = ViewerStoreMigrationStatus(phase)
    lock.unlock()
    outwardStatusSignal.publish()
  }

  private func clearMigrationStatus(token: ViewerStoreMigrationToken) {
    lock.lock()
    guard reopenConstruction?.migrationToken === token else {
      lock.unlock()
      return
    }
    migrationStatus = nil
    lock.unlock()
  }

  private func beginRecoveryAttemptLocked() -> (
    generation: UInt64,
    claimedMissedCount: Int64
  ) {
    recoveryAttemptGeneration =
      recoveryAttemptGeneration == UInt64.max ? 1 : recoveryAttemptGeneration + 1
    recoveryInFlight = true
    recoveryClaimedMissedCount = missedObservationCount
    missedObservationCount = 0
    return (recoveryAttemptGeneration, recoveryClaimedMissedCount)
  }

  private func completeRecoveryAttempt(
    generation: UInt64,
    coordinator: ViewerStoreCoordinator,
    runtimeLogicalID: UUID,
    succeeded: Bool
  ) {
    lock.lock()
    guard recoveryInFlight, recoveryAttemptGeneration == generation,
      self.coordinator === coordinator,
      runtimeContext?.logicalID == runtimeLogicalID,
      coordinatorRuntimeLogicalID == runtimeLogicalID
    else {
      lock.unlock()
      return
    }
    let claimed = recoveryClaimedMissedCount
    recoveryClaimedMissedCount = 0
    recoveryInFlight = false
    if succeeded {
      coordinatorNeedsRecovery = missedObservationCount > 0
    } else {
      let (sum, overflow) = missedObservationCount.addingReportingOverflow(claimed)
      missedObservationCount = overflow ? Int64.max : sum
      coordinatorNeedsRecovery = true
    }
    lock.unlock()
    outwardStatusSignal.publish()
  }

  private func invalidateRecoveryAttemptLocked() {
    recoveryAttemptGeneration =
      recoveryAttemptGeneration == UInt64.max ? 1 : recoveryAttemptGeneration + 1
    recoveryInFlight = false
    recoveryClaimedMissedCount = 0
  }

  private func addMissedLocked(_ count: Int64) {
    guard count > 0 else { return }
    let (sum, overflow) = missedObservationCount.addingReportingOverflow(count)
    missedObservationCount = overflow ? Int64.max : sum
  }

  private func recordRecoveryNeeded(
    from coordinator: ViewerStoreCoordinator,
    runtimeLogicalID: UUID,
    missed: Int64
  ) {
    lock.lock()
    if self.coordinator === coordinator,
      runtimeContext?.logicalID == runtimeLogicalID,
      coordinatorRuntimeLogicalID == runtimeLogicalID
    {
      coordinatorNeedsRecovery = true
      addMissedLocked(missed)
    }
    lock.unlock()
    outwardStatusSignal.publish()
  }

  private static func wallMilliseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded())
  }

  var description: String { "ViewerStoreRuntime(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerStoreCoordinator.Services: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreServices(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
