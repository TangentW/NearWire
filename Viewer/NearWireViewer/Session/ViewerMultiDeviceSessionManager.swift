import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireFlowControl
@_spi(NearWireInternal) import NearWireTransport

struct ViewerControlTargetCapability: Equatable, Hashable, Sendable {
  fileprivate let tokenUUID: UUID
  fileprivate let runtimeLogicalID: UUID
  fileprivate let managerGeneration: UInt64
  fileprivate let connectionID: UUID

}

struct ViewerControlTarget: Sendable {
  let connectionID: UUID
  let capability: ViewerControlTargetCapability
}

enum ViewerControlDraftPolicy: Equatable, Sendable {
  case normal
  case keepLatest
}

enum ViewerPreparedControlEventError: Error, Equatable, Sendable {
  case invalidEncodedSize
  case encodingFailed
  case invalidPolicy
}

struct ViewerPreparedControlEvent: Sendable {
  static let maximumEncodedBytes = 16 * 1_024 * 1_024

  let draft: EventDraft
  let deterministicEncodedByteCount: Int
  let policy: ViewerControlDraftPolicy
  let queuePolicy: EventQueuePolicy

  init(
    draft: EventDraft,
    policy: ViewerControlDraftPolicy
  ) throws {
    try self.init(draft: draft, policy: policy) { draft in
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(draft)
    }
  }

  init(
    draft: EventDraft,
    policy: ViewerControlDraftPolicy,
    encode: @escaping @Sendable (EventDraft) throws -> Data
  ) throws {
    let data: Data
    do { data = try encode(draft) } catch { throw ViewerPreparedControlEventError.encodingFailed }
    guard (1...Self.maximumEncodedBytes).contains(data.count) else {
      throw ViewerPreparedControlEventError.invalidEncodedSize
    }
    self.draft = draft
    deterministicEncodedByteCount = data.count
    self.policy = policy
    switch policy {
    case .normal:
      queuePolicy = .normal
    case .keepLatest:
      do {
        queuePolicy = .keepLatest(try KeepLatestKey(draft.type.rawValue))
      } catch {
        throw ViewerPreparedControlEventError.invalidPolicy
      }
    }
  }

}

enum ViewerControlTargetOutcome: String, Equatable, Sendable {
  case queued
  case invalidTarget
  case noLongerConnected
  case notActive
  case queueRejected
}

struct ViewerControlTargetResult: Equatable, Sendable {
  let inputIndex: Int
  let outcome: ViewerControlTargetOutcome

  var statusText: String {
    switch outcome {
    case .queued: return "Queued locally"
    case .invalidTarget: return "Invalid target"
    case .noLongerConnected: return "No longer connected"
    case .notActive: return "Not active"
    case .queueRejected: return "Queue rejected"
    }
  }
}

enum ViewerControlSendError: Error, Equatable, Sendable {
  case invalidTargetCount
}

extension ViewerControlTargetCapability: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerControlTargetCapability(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerControlTarget: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerControlTarget(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPreparedControlEvent: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerPreparedControlEvent(bytes: \(deterministicEncodedByteCount), redacted)"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["deterministicEncodedByteCount": deterministicEncodedByteCount],
      displayStyle: .struct
    )
  }
}

extension ViewerControlTargetResult: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerControlTargetResult(outcome: \(outcome.rawValue))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["inputIndex": inputIndex, "outcome": outcome.rawValue],
      displayStyle: .struct
    )
  }
}

final class ViewerMultiDeviceSessionManager: ViewerAdmissionHandoffOwning, ViewerSessionControlling,
  @unchecked Sendable, CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible
{
  typealias SnapshotHandler = @Sendable ([ViewerSessionSnapshot]) -> Void

  private struct Entry {
    let connectionID: UUID
    let route: ViewerLogicalRoute
    let session: ViewerDeviceSession
    var controlCapability: ViewerControlTargetCapability?
    var snapshot: ViewerSessionSnapshot
    var disconnectGeneration: UInt64
  }

  private struct DisplacedEntry {
    let connectionID: UUID
    let route: ViewerLogicalRoute
    let session: ViewerDeviceSession
    let disconnectGeneration: UInt64
  }

  private struct DisplacementWork {
    let connectionID: UUID
    let session: ViewerDeviceSession
    let disconnectGeneration: UInt64
  }

  private struct TerminalControlTarget {
    let capability: ViewerControlTargetCapability
    let terminalAt: UInt64
  }

  private struct RecentRow {
    let route: ViewerLogicalRoute
    let snapshot: ViewerSessionSnapshot
    let disconnectedAt: UInt64
    let deadline: UInt64
    let generation: UInt64
  }

  static let maximumSessions = 16
  static let maximumRecentRows = 64
  static let recentTTLNanoseconds: UInt64 = 30_000_000_000
  static let maximumTerminalControlTargets = 64
  static let terminalControlTargetTTLNanoseconds: UInt64 = 30_000_000_000

  private let lock = NSLock()
  private let controlSendLock = NSLock()
  private let scheduler: ViewerAdmissionScheduler
  private let preferences: ViewerDevicePreferences
  private var onSnapshots: SnapshotHandler
  private let uplinkSink: @Sendable (UUID, WireReceivedEvent) -> Void
  private let eventWallMilliseconds: @Sendable () -> Int64
  private let controlTokenUUID: @Sendable () -> UUID
  private let journal: any ViewerSessionJournaling
  private let sessionAttacher:
    @Sendable (ViewerAdmissionConnectionCore, any ViewerAdmissionSessionReceiving) throws -> Void
  let runtimeLogicalID: UUID
  let managerGeneration: UInt64
  private var entries: [UUID: Entry] = [:]
  private var liveRoutes: [ViewerLogicalRoute: UUID] = [:]
  private var displacedEntries: [UUID: DisplacedEntry] = [:]
  private var displacedRoutes: [ViewerLogicalRoute: UUID] = [:]
  private var recentRows: [ViewerLogicalRoute: RecentRow] = [:]
  private var terminalControlTargets: [UUID: TerminalControlTarget] = [:]
  private var issuedControlTokenUUIDs: Set<UUID> = []
  private var terminalControlExpiryGeneration: UInt64 = 0
  private var terminalControlExpiryWake: Task<Void, Never>?
  private var nextDisconnectGeneration: UInt64 = 0
  private var expiryGeneration: UInt64 = 0
  private var expiryWake: Task<Void, Never>?
  private var shuttingDown = false
  private var shutdownTask: Task<Void, Never>?
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
  private var controlAdmissionSealed = false

  init(
    runtimeLogicalID: UUID,
    managerGeneration: UInt64,
    scheduler: ViewerAdmissionScheduler = .live,
    preferences: ViewerDevicePreferences = ViewerDevicePreferences(),
    onSnapshots: @escaping SnapshotHandler = { _ in },
    uplinkSink: @escaping @Sendable (UUID, WireReceivedEvent) -> Void = { _, _ in },
    eventWallMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    },
    controlTokenUUID: @escaping @Sendable () -> UUID = { UUID() },
    journal: any ViewerSessionJournaling = ViewerNoopSessionJournal(),
    sessionAttacher:
      @escaping @Sendable (
        ViewerAdmissionConnectionCore, any ViewerAdmissionSessionReceiving
      ) throws -> Void = { core, receiver in
        try core.attachSession(receiver)
      }
  ) {
    precondition(managerGeneration > 0)
    self.runtimeLogicalID = runtimeLogicalID
    self.managerGeneration = managerGeneration
    self.scheduler = scheduler
    self.preferences = preferences
    self.onSnapshots = onSnapshots
    self.uplinkSink = uplinkSink
    self.eventWallMilliseconds = eventWallMilliseconds
    self.controlTokenUUID = controlTokenUUID
    self.journal = journal
    self.sessionAttacher = sessionAttacher
    journal.runtimeStarted(
      logicalID: runtimeLogicalID,
      wallMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
      monotonicNanoseconds: scheduler.now()
    )
  }

  func setSnapshotHandler(_ handler: @escaping SnapshotHandler) {
    lock.lock()
    guard !controlAdmissionSealed else {
      lock.unlock()
      handler([])
      return
    }
    onSnapshots = handler
    let snapshots = snapshotsLocked()
    lock.unlock()
    handler(snapshots)
  }

  func sealControlAdmission() {
    lock.lock()
    controlAdmissionSealed = true
    onSnapshots = { _ in }
    lock.unlock()
  }

  func transfer(_ handle: ViewerAdmissionHandle) -> Bool {
    let context: ViewerAdmissionSessionContext
    do { context = try handle.connectionCore.pendingSessionContext() } catch { return false }
    let route = ViewerLogicalRoute(
      installationID: context.appHello.installationID,
      applicationIdentifier: context.appHello.applicationIdentifier
    )
    let requested = preferences.requestedPolicy(for: route)
    let nickname = preferences.nickname(for: route)
    let runtimeLogicalID = self.runtimeLogicalID
    let provisional = Self.provisionalSnapshot(
      context: context,
      route: route,
      requested: requested,
      nickname: nickname
    )
    let session: ViewerDeviceSession
    do {
      session = try ViewerDeviceSession(
        handle: handle,
        context: context,
        requestedPolicy: requested,
        nickname: nickname,
        scheduler: scheduler,
        uplinkSink: { [weak self] event in
          self?.uplinkSink(context.connectionID, event)
        },
        uplinkJournal: { [journal, eventWallMilliseconds] event, disposition in
          guard
            let observation = try? ViewerCommittedEventObservation(
              runtimeLogicalID: runtimeLogicalID,
              context: context,
              nickname: nickname,
              envelope: event.envelope,
              viewerWallMilliseconds: eventWallMilliseconds(),
              viewerMonotonicNanoseconds: event.receivedAtNanoseconds,
              deterministicEventBytes: event.deterministicEncodedByteCount,
              canonicalContent: event.canonicalContentData,
              initialDisposition: disposition
            )
          else { return }
          journal.eventCommitted(observation) { _ in }
        },
        uplinkDispositionJournal: { [journal] direction, wireSequence, disposition, monotonic in
          journal.uplinkTerminated(
            runtimeLogicalID: runtimeLogicalID,
            connectionID: context.connectionID,
            direction: direction,
            wireSequence: wireSequence,
            disposition: disposition,
            monotonicNanoseconds: monotonic
          )
        },
        downlinkJournal: { [journal, eventWallMilliseconds] events, monotonicNanoseconds in
          for event in events {
            guard
              let observation = try? ViewerCommittedEventObservation(
                runtimeLogicalID: runtimeLogicalID,
                context: context,
                nickname: nickname,
                envelope: event.envelope,
                viewerWallMilliseconds: eventWallMilliseconds(),
                viewerMonotonicNanoseconds: monotonicNanoseconds,
                deterministicEventBytes: event.deterministicEncodedByteCount,
                canonicalContent: event.canonicalContentData,
                initialDisposition: .transportAdmitted
              )
            else { continue }
            journal.eventCommitted(observation) { _ in }
          }
        },
        policyJournal: { [journal] policy, monotonicNanoseconds in
          journal.policyChanged(
            runtimeLogicalID: runtimeLogicalID,
            connectionID: context.connectionID,
            policy: policy,
            monotonicNanoseconds: monotonicNanoseconds
          )
        },
        dropJournal: { [journal] samples, monotonicNanoseconds in
          journal.dropsChanged(
            runtimeLogicalID: runtimeLogicalID,
            connectionID: context.connectionID,
            samples: samples,
            monotonicNanoseconds: monotonicNanoseconds
          )
        },
        onSnapshot: { [weak self] snapshot in self?.update(snapshot) },
        onTerminal: { [weak self] id, category in self?.terminal(id, category: category) }
      )
    } catch { return false }

    do {
      try sessionAttacher(handle.connectionCore, session)
    } catch {
      return false
    }

    lock.lock()
    guard !shuttingDown,
      entries[context.connectionID] == nil,
      displacedEntries[context.connectionID] == nil,
      terminalControlTargets[context.connectionID] == nil
    else {
      lock.unlock()
      return false
    }
    let replacedEntry: Entry?
    if let replacedConnectionID = liveRoutes[route] {
      guard displacedRoutes[route] == nil,
        let existing = entries[replacedConnectionID],
        displacedEntries.count < Self.maximumSessions
      else {
        lock.unlock()
        return false
      }
      replacedEntry = existing
    } else {
      guard entries.count < Self.maximumSessions else {
        lock.unlock()
        return false
      }
      replacedEntry = nil
    }
    guard let controlCapability = issueControlCapabilityLocked(connectionID: context.connectionID)
    else {
      lock.unlock()
      return false
    }
    var displacementWork: DisplacementWork?
    if var replacedEntry {
      entries.removeValue(forKey: replacedEntry.connectionID)
      let disconnectGeneration: UInt64
      if replacedEntry.disconnectGeneration == 0 {
        nextDisconnectGeneration =
          nextDisconnectGeneration == UInt64.max ? 1 : nextDisconnectGeneration + 1
        disconnectGeneration = nextDisconnectGeneration
        replacedEntry.disconnectGeneration = disconnectGeneration
        replacedEntry.snapshot = Self.terminalSnapshot(
          replacedEntry.snapshot,
          category: .replacedByReconnect
        )
        retireControlCapabilityLocked(&replacedEntry, terminalAt: scheduler.now())
        displacementWork = DisplacementWork(
          connectionID: replacedEntry.connectionID,
          session: replacedEntry.session,
          disconnectGeneration: disconnectGeneration
        )
      } else {
        disconnectGeneration = replacedEntry.disconnectGeneration
      }
      displacedEntries[replacedEntry.connectionID] = DisplacedEntry(
        connectionID: replacedEntry.connectionID,
        route: replacedEntry.route,
        session: replacedEntry.session,
        disconnectGeneration: disconnectGeneration
      )
      displacedRoutes[route] = replacedEntry.connectionID
    }
    entries[context.connectionID] = Entry(
      connectionID: context.connectionID,
      route: route,
      session: session,
      controlCapability: controlCapability,
      snapshot: provisional,
      disconnectGeneration: 0
    )
    liveRoutes[route] = context.connectionID
    lock.unlock()

    if let displacementWork {
      journal.sessionEnded(
        runtimeLogicalID: runtimeLogicalID,
        connectionID: displacementWork.connectionID,
        wallMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
        monotonicNanoseconds: scheduler.now()
      )
      displacementWork.session.disconnect(category: .replacedByReconnect)
      Task { [weak self] in
        await displacementWork.session.cancelAndWaitForCleanup()
        self?.cleanupCompleted(
          connectionID: displacementWork.connectionID,
          generation: displacementWork.disconnectGeneration
        )
      }
    }

    lock.lock()
    guard !shuttingDown, entries[context.connectionID]?.session === session else {
      if entries.removeValue(forKey: context.connectionID) != nil {
        if liveRoutes[route] == context.connectionID {
          liveRoutes.removeValue(forKey: route)
        }
        issuedControlTokenUUIDs.remove(controlCapability.tokenUUID)
      }
      let snapshots = snapshotsLocked()
      let handler = onSnapshots
      finishShutdownIfPossibleLocked()
      lock.unlock()
      handler(snapshots)
      return false
    }
    recentRows.removeValue(forKey: route)
    scheduleExpiryLocked(now: scheduler.now())
    let snapshots = snapshotsLocked()
    let handler = onSnapshots
    lock.unlock()
    handler(snapshots)
    journal.sessionStarted(runtimeLogicalID: runtimeLogicalID, context)
    session.start()
    return true
  }

  func beginShutdown() -> Task<Void, Never> {
    lock.lock()
    if let shutdownTask {
      lock.unlock()
      return shutdownTask
    }
    shuttingDown = true
    controlAdmissionSealed = true
    let snapshotHandler = onSnapshots
    onSnapshots = { _ in }
    recentRows.removeAll()
    terminalControlTargets.removeAll()
    issuedControlTokenUUIDs.removeAll()
    terminalControlExpiryWake?.cancel()
    terminalControlExpiryWake = nil
    for connectionID in entries.keys {
      entries[connectionID]?.controlCapability = nil
    }
    expiryWake?.cancel()
    expiryWake = nil
    let sessions = entries.values.map(\.session)
    let journal = journal
    let runtimeLogicalID = self.runtimeLogicalID
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await self.waitForShutdown()
      await journal.runtimeEnded(
        logicalID: runtimeLogicalID,
        wallMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
        monotonicNanoseconds: scheduler.now()
      )
    }
    shutdownTask = task
    finishShutdownIfPossibleLocked()
    lock.unlock()
    snapshotHandler([])
    for session in sessions { session.disconnect(category: .viewerShutdown) }
    return task
  }

  func disconnect(connectionID: UUID) {
    lock.lock()
    let session = controlAdmissionSealed ? nil : entries[connectionID]?.session
    lock.unlock()
    session?.disconnect(category: .userDisconnected)
  }

  func updatePolicy(connectionID: UUID, policy: ViewerRatePolicy) {
    lock.lock()
    let entry = controlAdmissionSealed ? nil : entries[connectionID]
    lock.unlock()
    guard let entry else { return }
    if let bundle = entry.route.applicationIdentifier {
      preferences.setBundlePolicy(policy, bundleID: bundle)
    }
    entry.session.updateRequestedPolicy(policy)
  }

  func controlTargets() -> [ViewerControlTarget] {
    lock.lock()
    defer { lock.unlock() }
    guard !controlAdmissionSealed else { return [] }
    return entries.values.compactMap { entry in
      guard let capability = entry.controlCapability else { return nil }
      return ViewerControlTarget(connectionID: entry.connectionID, capability: capability)
    }.sorted { $0.connectionID.uuidString < $1.connectionID.uuidString }
  }

  func send(
    _ prepared: ViewerPreparedControlEvent,
    to capabilities: [ViewerControlTargetCapability]
  ) throws -> [ViewerControlTargetResult] {
    guard (1...Self.maximumSessions).contains(capabilities.count) else {
      throw ViewerControlSendError.invalidTargetCount
    }

    controlSendLock.lock()
    defer { controlSendLock.unlock() }
    var counts: [UUID: Int] = [:]
    counts.reserveCapacity(capabilities.count)
    for capability in capabilities {
      counts[capability.tokenUUID, default: 0] += 1
    }

    return capabilities.enumerated().map { index, capability in
      let outcome: ViewerControlTargetOutcome
      if counts[capability.tokenUUID] != 1 {
        outcome = .invalidTarget
      } else {
        outcome = classifyAndEnqueue(prepared, capability: capability)
      }
      return ViewerControlTargetResult(inputIndex: index, outcome: outcome)
    }
  }

  @discardableResult
  func setNickname(_ nickname: String?, route: ViewerLogicalRoute) -> Bool {
    lock.lock()
    guard !controlAdmissionSealed else {
      lock.unlock()
      return false
    }
    guard preferences.setNickname(nickname, for: route) else {
      lock.unlock()
      return false
    }
    if let id = liveRoutes[route], var entry = entries[id] {
      entry.snapshot = Self.replacingNickname(entry.snapshot, nickname: nickname)
      entries[id] = entry
    }
    if let recent = recentRows[route] {
      recentRows[route] = RecentRow(
        route: route,
        snapshot: Self.replacingNickname(recent.snapshot, nickname: nickname),
        disconnectedAt: recent.disconnectedAt,
        deadline: recent.deadline,
        generation: recent.generation
      )
    }
    let snapshots = snapshotsLocked()
    let handler = onSnapshots
    lock.unlock()
    handler(snapshots)
    return true
  }

  @discardableResult
  func send(
    _ draft: EventDraft,
    to connectionID: UUID,
    policy: ViewerDownlinkPolicy = .normal
  ) -> Bool {
    lock.lock()
    let session = controlAdmissionSealed ? nil : entries[connectionID]?.session
    lock.unlock()
    return session?.enqueueDownlink(draft, policy: policy) ?? false
  }

  var ownedSessionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }

  var hasWorkspaceMutationBlockingSessions: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !entries.isEmpty || !displacedEntries.isEmpty
  }

  var displacedSessionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return displacedEntries.count
  }

  var recentRowCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recentRows.count
  }

  var terminalControlTargetCount: Int {
    lock.lock()
    let now = scheduler.now()
    let didPurge = purgeExpiredTerminalControlTargetsLocked(now: now)
    if didPurge { scheduleTerminalControlExpiryLocked(now: now) }
    let count = terminalControlTargets.count
    lock.unlock()
    return count
  }

  private func update(_ snapshot: ViewerSessionSnapshot) {
    let nickname = preferences.nickname(for: snapshot.route)
    let authoritativeSnapshot = Self.replacingNickname(snapshot, nickname: nickname)
    lock.lock()
    guard var entry = entries[authoritativeSnapshot.id],
      entry.connectionID == authoritativeSnapshot.connectionID
    else {
      lock.unlock()
      return
    }
    entry.snapshot = authoritativeSnapshot
    entries[authoritativeSnapshot.id] = entry
    let snapshots = snapshotsLocked()
    let handler = onSnapshots
    lock.unlock()
    handler(snapshots)
  }

  private func terminal(_ connectionID: UUID, category: ViewerSessionTerminalCategory) {
    lock.lock()
    guard var entry = entries[connectionID], entry.disconnectGeneration == 0 else {
      lock.unlock()
      return
    }
    nextDisconnectGeneration =
      nextDisconnectGeneration == UInt64.max
      ? 1 : nextDisconnectGeneration + 1
    entry.disconnectGeneration = nextDisconnectGeneration
    entry.snapshot = Self.terminalSnapshot(entry.snapshot, category: category)
    retireControlCapabilityLocked(&entry, terminalAt: scheduler.now())
    entries[connectionID] = entry
    let generation = entry.disconnectGeneration
    let session = entry.session
    let snapshots = snapshotsLocked()
    let handler = onSnapshots
    lock.unlock()
    handler(snapshots)
    journal.sessionEnded(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      wallMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
      monotonicNanoseconds: scheduler.now()
    )
    Task { [weak self] in
      await session.cancelAndWaitForCleanup()
      self?.cleanupCompleted(connectionID: connectionID, generation: generation)
    }
  }

  private func cleanupCompleted(connectionID: UUID, generation: UInt64) {
    lock.lock()
    if let displaced = displacedEntries[connectionID],
      displaced.disconnectGeneration == generation
    {
      displacedEntries.removeValue(forKey: connectionID)
      if displacedRoutes[displaced.route] == connectionID {
        displacedRoutes.removeValue(forKey: displaced.route)
      }
      finishShutdownIfPossibleLocked()
      lock.unlock()
      return
    }
    guard let entry = entries[connectionID], entry.disconnectGeneration == generation else {
      lock.unlock()
      return
    }
    entries.removeValue(forKey: connectionID)
    if liveRoutes[entry.route] == connectionID {
      liveRoutes.removeValue(forKey: entry.route)
    }
    let now = scheduler.now()
    if !shuttingDown {
      let (deadline, overflow) = now.addingReportingOverflow(Self.recentTTLNanoseconds)
      if !overflow {
        recentRows[entry.route] = RecentRow(
          route: entry.route,
          snapshot: Self.recentSnapshot(entry.snapshot),
          disconnectedAt: now,
          deadline: deadline,
          generation: generation
        )
        evictRecentLocked()
        scheduleExpiryLocked(now: now)
      }
    }
    let snapshots = snapshotsLocked()
    let handler = onSnapshots
    finishShutdownIfPossibleLocked()
    lock.unlock()
    handler(snapshots)
  }

  private func scheduleExpiryLocked(now: UInt64) {
    expiryGeneration = expiryGeneration == UInt64.max ? 1 : expiryGeneration + 1
    let generation = expiryGeneration
    expiryWake?.cancel()
    guard !shuttingDown, let deadline = recentRows.values.map(\.deadline).min() else {
      expiryWake = nil
      return
    }
    expiryWake = Task { [weak self, scheduler] in
      do { try await scheduler.sleep(untilNanoseconds: deadline) } catch { return }
      guard !Task.isCancelled else { return }
      self?.expireRecent(generation: generation)
    }
  }

  private func expireRecent(generation: UInt64) {
    lock.lock()
    guard generation == expiryGeneration, !shuttingDown else {
      lock.unlock()
      return
    }
    let now = scheduler.now()
    let due = recentRows.values
      .filter { $0.deadline <= now }
      .sorted { lhs, rhs in
        lhs.deadline == rhs.deadline
          ? lhs.route.storageKey < rhs.route.storageKey
          : lhs.deadline < rhs.deadline
      }
      .prefix(Self.maximumRecentRows)
    for row in due where recentRows[row.route]?.generation == row.generation {
      recentRows.removeValue(forKey: row.route)
    }
    scheduleExpiryLocked(now: now)
    let snapshots = snapshotsLocked()
    let handler = onSnapshots
    lock.unlock()
    handler(snapshots)
  }

  private func evictRecentLocked() {
    while recentRows.count > Self.maximumRecentRows {
      guard
        let victim = recentRows.values.min(by: { lhs, rhs in
          lhs.disconnectedAt == rhs.disconnectedAt
            ? lhs.route.storageKey < rhs.route.storageKey
            : lhs.disconnectedAt < rhs.disconnectedAt
        })
      else { return }
      recentRows.removeValue(forKey: victim.route)
    }
  }

  private func issueControlCapabilityLocked(connectionID: UUID)
    -> ViewerControlTargetCapability?
  {
    for _ in 0..<8 {
      let tokenUUID = controlTokenUUID()
      guard issuedControlTokenUUIDs.insert(tokenUUID).inserted else { continue }
      return ViewerControlTargetCapability(
        tokenUUID: tokenUUID,
        runtimeLogicalID: runtimeLogicalID,
        managerGeneration: managerGeneration,
        connectionID: connectionID
      )
    }
    return nil
  }

  private func retireControlCapabilityLocked(_ entry: inout Entry, terminalAt: UInt64) {
    guard let capability = entry.controlCapability else { return }
    entry.controlCapability = nil
    guard !shuttingDown else {
      issuedControlTokenUUIDs.remove(capability.tokenUUID)
      return
    }
    terminalControlTargets[entry.connectionID] = TerminalControlTarget(
      capability: capability,
      terminalAt: terminalAt
    )
    purgeExpiredTerminalControlTargetsLocked(now: terminalAt)
    evictTerminalControlTargetsLocked()
    scheduleTerminalControlExpiryLocked(now: terminalAt)
  }

  private func classifyAndEnqueue(
    _ prepared: ViewerPreparedControlEvent,
    capability: ViewerControlTargetCapability
  ) -> ViewerControlTargetOutcome {
    guard capability.runtimeLogicalID == runtimeLogicalID,
      capability.managerGeneration == managerGeneration
    else { return .invalidTarget }

    lock.lock()
    let now = scheduler.now()
    if purgeExpiredTerminalControlTargetsLocked(now: now) {
      scheduleTerminalControlExpiryLocked(now: now)
    }
    if terminalControlTargets[capability.connectionID]?.capability == capability {
      lock.unlock()
      return .noLongerConnected
    }
    guard !controlAdmissionSealed,
      let entry = entries[capability.connectionID],
      entry.controlCapability == capability
    else {
      lock.unlock()
      return .invalidTarget
    }
    let session = entry.session
    lock.unlock()
    return session.enqueuePreparedControl(prepared)
  }

  @discardableResult
  private func purgeExpiredTerminalControlTargetsLocked(now: UInt64) -> Bool {
    let expired = terminalControlTargets.compactMap { connectionID, terminal -> UUID? in
      let elapsed = now >= terminal.terminalAt ? now - terminal.terminalAt : UInt64.max
      return elapsed >= Self.terminalControlTargetTTLNanoseconds ? connectionID : nil
    }
    for connectionID in expired {
      guard let terminal = terminalControlTargets.removeValue(forKey: connectionID) else {
        continue
      }
      issuedControlTokenUUIDs.remove(terminal.capability.tokenUUID)
    }
    return !expired.isEmpty
  }

  private func evictTerminalControlTargetsLocked() {
    while terminalControlTargets.count > Self.maximumTerminalControlTargets {
      guard
        let victim = terminalControlTargets.min(by: { lhs, rhs in
          if lhs.value.terminalAt != rhs.value.terminalAt {
            return lhs.value.terminalAt < rhs.value.terminalAt
          }
          return lhs.value.capability.tokenUUID.uuidString
            < rhs.value.capability.tokenUUID.uuidString
        })
      else { return }
      terminalControlTargets.removeValue(forKey: victim.key)
      issuedControlTokenUUIDs.remove(victim.value.capability.tokenUUID)
    }
  }

  private func scheduleTerminalControlExpiryLocked(now: UInt64) {
    terminalControlExpiryGeneration =
      terminalControlExpiryGeneration == UInt64.max
      ? 1 : terminalControlExpiryGeneration + 1
    let generation = terminalControlExpiryGeneration
    terminalControlExpiryWake?.cancel()
    guard !shuttingDown,
      let terminalAt = terminalControlTargets.values.map(\.terminalAt).min()
    else {
      terminalControlExpiryWake = nil
      return
    }
    let (candidateDeadline, overflow) = terminalAt.addingReportingOverflow(
      Self.terminalControlTargetTTLNanoseconds
    )
    let deadline = overflow ? UInt64.max : candidateDeadline
    guard deadline > now else {
      terminalControlExpiryWake = nil
      return
    }
    terminalControlExpiryWake = Task { [weak self, scheduler] in
      do { try await scheduler.sleep(untilNanoseconds: deadline) } catch { return }
      guard !Task.isCancelled else { return }
      self?.expireTerminalControlTargets(generation: generation)
    }
  }

  private func expireTerminalControlTargets(generation: UInt64) {
    lock.lock()
    guard generation == terminalControlExpiryGeneration, !shuttingDown else {
      lock.unlock()
      return
    }
    let now = scheduler.now()
    purgeExpiredTerminalControlTargetsLocked(now: now)
    scheduleTerminalControlExpiryLocked(now: now)
    lock.unlock()
  }

  private func snapshotsLocked() -> [ViewerSessionSnapshot] {
    let live = entries.values.map(\.snapshot)
    let recent = recentRows.values.map(\.snapshot)
    return (live + recent).sorted { lhs, rhs in
      if lhs.state != rhs.state { return lhs.state.rawValue < rhs.state.rawValue }
      if lhs.title != rhs.title {
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
      }
      return lhs.route.storageKey < rhs.route.storageKey
    }
  }

  private func waitForShutdown() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if entries.isEmpty, displacedEntries.isEmpty {
        lock.unlock()
        continuation.resume()
      } else {
        shutdownWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

  private func finishShutdownIfPossibleLocked() {
    guard shuttingDown, entries.isEmpty, displacedEntries.isEmpty else { return }
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private static func provisionalSnapshot(
    context: ViewerAdmissionSessionContext,
    route: ViewerLogicalRoute,
    requested: ViewerRatePolicy,
    nickname: String?
  ) -> ViewerSessionSnapshot {
    ViewerSessionSnapshot(
      id: context.connectionID,
      connectionID: context.connectionID,
      route: route,
      displayName: context.appHello.displayName ?? context.appHello.applicationIdentifier
        ?? "Unnamed App",
      applicationVersion: context.appHello.applicationVersion,
      installationAlias: "App \(context.appHello.installationID.rawValue.suffix(8))",
      nickname: nickname,
      state: .provisional,
      requestedPolicy: requested,
      effectivePolicy: nil,
      uplinkCount: 0,
      uplinkBytes: 0,
      uplinkOldestWaitNanoseconds: nil,
      downlinkCount: 0,
      downlinkBytes: 0,
      downlinkOldestWaitNanoseconds: nil,
      receivedEvents: 0,
      deliveredEvents: 0,
      sentEvents: 0,
      droppedEvents: 0,
      overflowDroppedEvents: 0,
      expiredEvents: 0,
      coalescedEvents: 0,
      routeDroppedEvents: 0,
      remoteDroppedEvents: 0,
      ingressEventsPerSecond: 0,
      egressEventsPerSecond: 0,
      terminalCategory: nil
    )
  }

  private static func replacingNickname(
    _ snapshot: ViewerSessionSnapshot,
    nickname: String?
  ) -> ViewerSessionSnapshot {
    copy(snapshot, nickname: nickname)
  }

  private static func terminalSnapshot(
    _ snapshot: ViewerSessionSnapshot,
    category: ViewerSessionTerminalCategory
  ) -> ViewerSessionSnapshot {
    copy(snapshot, state: .disconnecting, terminal: category)
  }

  private static func recentSnapshot(_ snapshot: ViewerSessionSnapshot) -> ViewerSessionSnapshot {
    copy(snapshot, connectionID: .some(nil), state: .recent, clearEffective: true)
  }

  private static func copy(
    _ value: ViewerSessionSnapshot,
    connectionID: UUID?? = nil,
    nickname: String?? = nil,
    state: ViewerSessionState? = nil,
    terminal: ViewerSessionTerminalCategory?? = nil,
    clearEffective: Bool = false
  ) -> ViewerSessionSnapshot {
    ViewerSessionSnapshot(
      id: value.id,
      connectionID: connectionID ?? value.connectionID,
      route: value.route,
      displayName: value.displayName,
      applicationVersion: value.applicationVersion,
      installationAlias: value.installationAlias,
      nickname: nickname ?? value.nickname,
      state: state ?? value.state,
      requestedPolicy: value.requestedPolicy,
      effectivePolicy: clearEffective ? nil : value.effectivePolicy,
      uplinkCount: clearEffective ? 0 : value.uplinkCount,
      uplinkBytes: clearEffective ? 0 : value.uplinkBytes,
      uplinkOldestWaitNanoseconds: clearEffective ? nil : value.uplinkOldestWaitNanoseconds,
      downlinkCount: clearEffective ? 0 : value.downlinkCount,
      downlinkBytes: clearEffective ? 0 : value.downlinkBytes,
      downlinkOldestWaitNanoseconds: clearEffective ? nil : value.downlinkOldestWaitNanoseconds,
      receivedEvents: value.receivedEvents,
      deliveredEvents: value.deliveredEvents,
      sentEvents: value.sentEvents,
      droppedEvents: value.droppedEvents,
      overflowDroppedEvents: value.overflowDroppedEvents,
      expiredEvents: value.expiredEvents,
      coalescedEvents: value.coalescedEvents,
      routeDroppedEvents: value.routeDroppedEvents,
      remoteDroppedEvents: value.remoteDroppedEvents,
      ingressEventsPerSecond: clearEffective ? 0 : value.ingressEventsPerSecond,
      egressEventsPerSecond: clearEffective ? 0 : value.egressEventsPerSecond,
      terminalCategory: terminal ?? value.terminalCategory
    )
  }

  var description: String { "ViewerMultiDeviceSessionManager(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
