import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

final class ViewerMultiDeviceSessionManager: ViewerAdmissionHandoffOwning, @unchecked Sendable {
  typealias SnapshotHandler = @Sendable ([ViewerSessionSnapshot]) -> Void

  private struct Entry {
    let connectionID: UUID
    let route: ViewerLogicalRoute
    let session: ViewerDeviceSession
    var snapshot: ViewerSessionSnapshot
    var disconnectGeneration: UInt64
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

  private let lock = NSLock()
  private let scheduler: ViewerAdmissionScheduler
  private let preferences: ViewerDevicePreferences
  private var onSnapshots: SnapshotHandler
  private let uplinkSink: @Sendable (UUID, WireReceivedEvent) -> Void
  private var entries: [UUID: Entry] = [:]
  private var liveRoutes: [ViewerLogicalRoute: UUID] = [:]
  private var recentRows: [ViewerLogicalRoute: RecentRow] = [:]
  private var nextDisconnectGeneration: UInt64 = 0
  private var expiryGeneration: UInt64 = 0
  private var expiryWake: Task<Void, Never>?
  private var shuttingDown = false
  private var shutdownTask: Task<Void, Never>?
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    scheduler: ViewerAdmissionScheduler = .live,
    preferences: ViewerDevicePreferences = ViewerDevicePreferences(),
    onSnapshots: @escaping SnapshotHandler = { _ in },
    uplinkSink: @escaping @Sendable (UUID, WireReceivedEvent) -> Void = { _, _ in }
  ) {
    self.scheduler = scheduler
    self.preferences = preferences
    self.onSnapshots = onSnapshots
    self.uplinkSink = uplinkSink
  }

  func setSnapshotHandler(_ handler: @escaping SnapshotHandler) {
    lock.lock()
    onSnapshots = handler
    let snapshots = snapshotsLocked()
    lock.unlock()
    handler(snapshots)
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
        onSnapshot: { [weak self] snapshot in self?.update(snapshot) },
        onTerminal: { [weak self] id, category in self?.terminal(id, category: category) }
      )
    } catch { return false }

    lock.lock()
    guard !shuttingDown, entries.count < Self.maximumSessions, liveRoutes[route] == nil else {
      lock.unlock()
      return false
    }
    entries[context.connectionID] = Entry(
      connectionID: context.connectionID,
      route: route,
      session: session,
      snapshot: provisional,
      disconnectGeneration: 0
    )
    liveRoutes[route] = context.connectionID
    lock.unlock()

    do {
      try handle.connectionCore.attachSession(session)
    } catch {
      rollbackProvisional(connectionID: context.connectionID, route: route)
      return false
    }

    lock.lock()
    guard !shuttingDown, entries[context.connectionID]?.session === session else {
      if entries.removeValue(forKey: context.connectionID) != nil {
        liveRoutes.removeValue(forKey: route)
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
    recentRows.removeAll()
    expiryWake?.cancel()
    expiryWake = nil
    let sessions = entries.values.map(\.session)
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await self.waitForShutdown()
    }
    shutdownTask = task
    let snapshots = snapshotsLocked()
    let handler = onSnapshots
    finishShutdownIfPossibleLocked()
    lock.unlock()
    handler(snapshots)
    for session in sessions { session.disconnect(category: .viewerShutdown) }
    return task
  }

  func disconnect(connectionID: UUID) {
    lock.lock()
    let session = entries[connectionID]?.session
    lock.unlock()
    session?.disconnect(category: .userDisconnected)
  }

  func updatePolicy(connectionID: UUID, policy: ViewerRatePolicy) {
    lock.lock()
    let entry = entries[connectionID]
    lock.unlock()
    guard let entry else { return }
    if let bundle = entry.route.applicationIdentifier {
      preferences.setBundlePolicy(policy, bundleID: bundle)
    }
    entry.session.updateRequestedPolicy(policy)
  }

  @discardableResult
  func setNickname(_ nickname: String?, route: ViewerLogicalRoute) -> Bool {
    guard preferences.setNickname(nickname, for: route) else { return false }
    lock.lock()
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
    let session = entries[connectionID]?.session
    lock.unlock()
    return session?.enqueueDownlink(draft, policy: policy) ?? false
  }

  var ownedSessionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }

  var recentRowCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recentRows.count
  }

  private func rollbackProvisional(connectionID: UUID, route: ViewerLogicalRoute) {
    lock.lock()
    if entries.removeValue(forKey: connectionID) != nil { liveRoutes.removeValue(forKey: route) }
    let snapshots = snapshotsLocked()
    let handler = onSnapshots
    finishShutdownIfPossibleLocked()
    lock.unlock()
    handler(snapshots)
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
    entries[connectionID] = entry
    let generation = entry.disconnectGeneration
    let session = entry.session
    let snapshots = snapshotsLocked()
    let handler = onSnapshots
    lock.unlock()
    handler(snapshots)
    Task { [weak self] in
      await session.cancelAndWaitForCleanup()
      self?.cleanupCompleted(connectionID: connectionID, generation: generation)
    }
  }

  private func cleanupCompleted(connectionID: UUID, generation: UInt64) {
    lock.lock()
    guard let entry = entries[connectionID], entry.disconnectGeneration == generation else {
      lock.unlock()
      return
    }
    entries.removeValue(forKey: connectionID)
    liveRoutes.removeValue(forKey: entry.route)
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
      if entries.isEmpty {
        lock.unlock()
        continuation.resume()
      } else {
        shutdownWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

  private func finishShutdownIfPossibleLocked() {
    guard shuttingDown, entries.isEmpty else { return }
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
}
