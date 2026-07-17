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
    disposition: ViewerEventDisposition,
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
  ) { outcome(.untracked) }
  func uplinkTerminated(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    direction: EventDirection,
    wireSequence: UInt64,
    disposition: ViewerEventDisposition,
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
  func runtimeEnded(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) async {}
}

protocol ViewerSessionControlling: AnyObject, Sendable {
  var runtimeLogicalID: UUID { get }
  var managerGeneration: UInt64 { get }
  var hasWorkspaceMutationBlockingSessions: Bool { get }

  func setSnapshotHandler(_ handler: @escaping @Sendable ([ViewerSessionSnapshot]) -> Void)
  func disconnect(connectionID: UUID)
  func updatePolicy(connectionID: UUID, policy: ViewerRatePolicy)
  func controlTargets() -> [ViewerControlTarget]
  func send(
    _ prepared: ViewerPreparedControlEvent,
    to capabilities: [ViewerControlTargetCapability]
  ) throws -> [ViewerControlTargetResult]

  @discardableResult
  func setNickname(_ nickname: String?, route: ViewerLogicalRoute) -> Bool
}

extension ViewerSessionControlling {
  var hasWorkspaceMutationBlockingSessions: Bool { false }
}

protocol ViewerLiveObservationProviding: AnyObject, Sendable {
  var runtimeLogicalID: UUID { get }
  func snapshot() -> ViewerLiveProjectionSnapshot
  func freezePerformance(connectionID: UUID) throws -> ViewerPerformanceLiveSlice
  func performanceEventLocator(for key: ViewerEventJournalKey) -> ViewerPerformanceEventLocator?
  func setRefreshHandler(_ handler: @escaping @Sendable (UInt64) -> Void)
  func setPresentationPaused(_ paused: Bool)
  func clearCurrentSession()
}

extension ViewerLiveObservationProviding {
  func performanceEventLocator(for key: ViewerEventJournalKey) -> ViewerPerformanceEventLocator? {
    nil
  }

  func clearCurrentSession() {}
}

enum ViewerWorkspaceMutationFailure: Error, Equatable, Sendable {
  case unavailable
  case busy
  case invalidFile
  case unsupportedFile
  case capacityExceeded
  case cancelled
}

enum ViewerWorkspaceMutationKind: Equatable, Sendable {
  case clearEvents
  case importSession
}

protocol ViewerWorkspaceSessionControlling: AnyObject, Sendable {
  func clearCurrentSession(
    afterCommit: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  )
  func importCurrentSession(
    from url: URL,
    afterCommit: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  )
  func cancelCurrentSessionImport()
}

extension ViewerWorkspaceSessionControlling {
  func clearCurrentSession(
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  ) {
    clearCurrentSession(afterCommit: {}, completion: completion)
  }

  func importCurrentSession(
    from url: URL,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  ) {
    importCurrentSession(from: url, afterCommit: {}, completion: completion)
  }
}

private final class ViewerUnavailableWorkspaceSessionControl: ViewerWorkspaceSessionControlling,
  @unchecked Sendable
{
  func clearCurrentSession(
    afterCommit: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  ) {
    completion(.failure(.unavailable))
  }

  func importCurrentSession(
    from url: URL,
    afterCommit: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  ) {
    completion(.failure(.unavailable))
  }

  func cancelCurrentSessionImport() {}
}

struct ViewerMemorySessionExportTicket: Equatable, Sendable {
  fileprivate let id: UUID
  let eventCount: Int64
  let disclosure: ViewerExportDisclosure
}

private struct ViewerMemorySessionExportDocument: Encodable {
  struct Session: Encodable {
    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64?
    let name: String?
    let note: String?
    let pinned: Bool
    let state: String
  }

  struct Device: Encodable {
    let device: String
    let connection: String
    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64?
    let partialHistory: Bool
    let state: String
    let applicationIdentifier: String?
    let applicationVersion: String?
    let displayName: String?
  }

  struct Causality: Encodable {
    let correlationID: String?
    let replyTo: String?
  }

  struct Event: Encodable {
    let device: String
    let connection: String
    let direction: EventDirection
    let wireSequence: UInt64
    let eventID: String
    let eventType: String
    let content: JSONValue
    let createdAtMilliseconds: Int64
    let viewerReceivedAtMilliseconds: Int64
    let viewerMonotonicNanoseconds: UInt64
    let priority: EventPriority
    let disposition: String?
    let originMonotonicNanoseconds: UInt64
    let ttlMilliseconds: UInt64
    let eventSchemaVersion: UInt16
    let causality: Causality?
  }

  struct Gap: Encodable {
    let createdAtMilliseconds: Int64
    let reason: String
    let count: Int64
    let firstViewerTimeMilliseconds: Int64
    let lastViewerTimeMilliseconds: Int64
    let directions: String
    let device: String?
    let connection: String?
    let firstWireSequence: UInt64?
    let lastWireSequence: UInt64?
  }

  struct Annotation: Encodable {
    let revision: Int64
    let createdAtMilliseconds: Int64
    let body: String
  }

  let schemaVersion = 1
  let scope = "completeSession"
  let disclosure = ViewerExportDisclosure.current
  let session: Session
  let devices: [Device]
  let events: [Event]
  let gaps: [Gap]
  let annotations: [Annotation]
}

final class ViewerMemorySessionTransferService: ViewerWorkspaceSessionControlling,
  @unchecked Sendable
{
  static let maximumFileBytes = 256 * 1_024 * 1_024

  private struct DeviceReference {
    let connectionID: UUID
    let metadata: ViewerFrozenSessionMetadata
    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64?
    let partialHistory: Bool
  }

  private let liveWindow: ViewerLiveEventWindow
  private let queue = DispatchQueue(label: "com.nearwire.viewer.memory-session-transfer")
  private let lock = NSLock()
  private var activeOperations: Set<UUID> = []
  private var cancelledOperations: Set<UUID> = []
  private var frozenExports: [UUID: Data] = [:]
  private var importCancellation: ViewerSessionImportCancellation?

  init(liveWindow: ViewerLiveEventWindow) {
    self.liveWindow = liveWindow
  }

  func prepareExport(
    completion: @escaping @Sendable (
      Result<ViewerMemorySessionExportTicket, ViewerExplorerFailure>
    ) -> Void
  ) -> ViewerOperationToken {
    let operationID = UUID()
    let token = ViewerOperationToken(operationID: operationID)
    beginOperation(operationID)
    queue.async { [weak self] in
      guard let self else {
        completion(.failure(.cancelled))
        return
      }
      defer { self.finishOperation(operationID) }
      guard !self.isCancelled(operationID) else {
        completion(.failure(.cancelled))
        return
      }
      do {
        let snapshot = self.liveWindow.snapshot()
        let document = try Self.makeExportDocument(snapshot)
        let data = try Self.encodeExportDocument(document)
        guard data.count <= Self.maximumFileBytes else {
          completion(.failure(.exportTooLarge))
          return
        }
        let ticketID = UUID()
        self.lock.lock()
        let cancelled = self.cancelledOperations.contains(operationID)
        if !cancelled { self.frozenExports[ticketID] = data }
        self.lock.unlock()
        guard !cancelled else {
          completion(.failure(.cancelled))
          return
        }
        completion(
          .success(
            ViewerMemorySessionExportTicket(
              id: ticketID,
              eventCount: Int64(document.events.count),
              disclosure: .current
            )
          )
        )
      } catch {
        completion(.failure(.invalidRequest))
      }
    }
    return token
  }

  func executeExport(
    _ ticket: ViewerMemorySessionExportTicket,
    to destination: URL,
    completion: @escaping @Sendable (Result<Void, ViewerExplorerFailure>) -> Void
  ) -> ViewerOperationToken {
    let operationID = UUID()
    let token = ViewerOperationToken(operationID: operationID)
    beginOperation(operationID)
    queue.async { [weak self] in
      guard let self else {
        completion(.failure(.cancelled))
        return
      }
      defer { self.finishOperation(operationID) }
      self.lock.lock()
      let cancelled = self.cancelledOperations.contains(operationID)
      let data = self.frozenExports.removeValue(forKey: ticket.id)
      self.lock.unlock()
      guard !cancelled else {
        completion(.failure(.cancelled))
        return
      }
      guard destination.isFileURL, let data else {
        completion(.failure(.invalidRequest))
        return
      }
      guard !self.isCancelled(operationID) else {
        completion(.failure(.cancelled))
        return
      }
      do {
        try data.write(to: destination, options: .atomic)
        completion(.success(()))
      } catch {
        completion(.failure(.unavailable))
      }
    }
    return token
  }

  func cancel(_ token: ViewerOperationToken) {
    lock.lock()
    if activeOperations.contains(token.operationID) {
      cancelledOperations.insert(token.operationID)
    }
    lock.unlock()
  }

  func discardExport(_ ticket: ViewerMemorySessionExportTicket) {
    lock.lock()
    frozenExports.removeValue(forKey: ticket.id)
    lock.unlock()
  }

  func clearCurrentSession(
    afterCommit: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  ) {
    liveWindow.clearCurrentSession()
    afterCommit()
    completion(.success(()))
  }

  func importCurrentSession(
    from url: URL,
    afterCommit: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  ) {
    let cancellation = ViewerSessionImportCancellation()
    lock.lock()
    guard importCancellation == nil else {
      lock.unlock()
      completion(.failure(.busy))
      return
    }
    importCancellation = cancellation
    lock.unlock()
    queue.async { [weak self] in
      guard let self else {
        completion(.failure(.cancelled))
        return
      }
      defer {
        self.lock.lock()
        if self.importCancellation === cancellation { self.importCancellation = nil }
        self.lock.unlock()
      }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "NearWire-Memory-Import-\(UUID().uuidString)",
        isDirectory: true
      )
      do {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let replacement = try self.makeReplacement(
          from: url,
          snapshotDirectory: directory,
          cancellation: cancellation
        )
        try cancellation.check()
        try self.liveWindow.replaceCurrentSession(replacement)
        afterCommit()
        completion(.success(()))
      } catch let failure as ViewerWorkspaceMutationFailure {
        completion(.failure(failure))
      } catch let error as ViewerSessionTransferError {
        completion(.failure(Self.workspaceFailure(error)))
      } catch {
        completion(.failure(.invalidFile))
      }
    }
  }

  func cancelCurrentSessionImport() {
    lock.lock()
    let cancellation = importCancellation
    lock.unlock()
    cancellation?.cancel()
  }

  private func makeReplacement(
    from url: URL,
    snapshotDirectory: URL,
    cancellation: ViewerSessionImportCancellation
  ) throws -> ViewerMemorySessionReplacement {
    let document = try ViewerSessionImportDocument.open(
      url,
      maximumFileBytes: Int64(Self.maximumFileBytes),
      snapshotDirectory: snapshotDirectory,
      cancellation: cancellation
    )
    var references: [String: DeviceReference] = [:]
    try document.forEachDevice { imported in
      try cancellation.check()
      guard references.count < ViewerLiveProjectionLimits.maximumSessions,
        references[imported.referenceKey] == nil
      else { throw ViewerSessionTransferError.capacityExceeded }
      let connectionID = UUID()
      let metadata = try ViewerFrozenSessionMetadata(
        installationID: "imported-\(UUID().uuidString)",
        installationAlias: imported.device,
        displayName: imported.displayName ?? imported.device,
        applicationIdentifier: imported.applicationIdentifier,
        applicationVersion: imported.applicationVersion
      )
      references[imported.referenceKey] = DeviceReference(
        connectionID: connectionID,
        metadata: metadata,
        startedAtMilliseconds: imported.startedAtMilliseconds,
        endedAtMilliseconds: imported.endedAtMilliseconds,
        partialHistory: imported.partialHistory
      )
    }
    var observations: [ViewerCommittedEventObservation] = []
    var keys: Set<ViewerEventJournalKey> = []
    var latestMonotonicByConnection: [UUID: UInt64] = [:]
    var accountedBytes = 0
    try document.forEachEvent { imported in
      try cancellation.check()
      guard observations.count < ViewerLiveProjectionLimits.maximumByteDerivedEventSlots,
        let reference = references[imported.deviceReferenceKey]
      else { throw ViewerSessionTransferError.capacityExceeded }
      let prepared = try Self.prepareImportedEvent(imported)
      let observation = try ViewerCommittedEventObservation(
        runtimeLogicalID: self.liveWindow.runtimeLogicalID,
        connectionID: reference.connectionID,
        session: reference.metadata,
        envelope: prepared.envelope,
        viewerWallMilliseconds: imported.viewerReceivedAtMilliseconds,
        viewerMonotonicNanoseconds: imported.viewerMonotonicNanoseconds,
        deterministicEventBytes: prepared.deterministicByteCount,
        initialDisposition: prepared.disposition
      )
      guard keys.insert(observation.key).inserted,
        let bytes = ViewerLiveProjectionLimits.accountedBytes(for: observation),
        bytes <= ViewerLiveProjectionLimits.retainedBytes - accountedBytes
      else { throw ViewerSessionTransferError.capacityExceeded }
      accountedBytes += bytes
      latestMonotonicByConnection[reference.connectionID] = max(
        latestMonotonicByConnection[reference.connectionID] ?? 0,
        imported.viewerMonotonicNanoseconds
      )
      observations.append(observation)
    }
    let hasPartialHistory = references.values.contains(where: \.partialHistory)
    var ingressOverflowCount: UInt64 = 0
    var windowOverflowCount: UInt64 = 0
    var residentConflictCount: UInt64 = 0
    var diagnosticLossCount: UInt64 = 0
    var dropCountByConnection: [UUID: UInt64] = [:]
    try document.forEachGap { gap in
      try cancellation.check()
      guard let count = UInt64(exactly: gap.count) else {
        throw ViewerSessionTransferError.invalidValue
      }
      switch gap.reason {
      case "nearwire.memory.ingressOverflow":
        ingressOverflowCount = Self.saturatingAdd(ingressOverflowCount, count)
      case "nearwire.memory.windowOverflow":
        windowOverflowCount = Self.saturatingAdd(windowOverflowCount, count)
      case "nearwire.memory.residentConflict":
        residentConflictCount = Self.saturatingAdd(residentConflictCount, count)
      case "nearwire.memory.drop":
        guard let key = gap.deviceReferenceKey, let reference = references[key] else {
          throw ViewerSessionTransferError.invalidValue
        }
        dropCountByConnection[reference.connectionID] = Self.saturatingAdd(
          dropCountByConnection[reference.connectionID] ?? 0,
          count
        )
      default:
        diagnosticLossCount = Self.saturatingAdd(diagnosticLossCount, count)
      }
    }
    if hasPartialHistory && windowOverflowCount == 0 {
      windowOverflowCount = 1
    }
    try document.forEachAnnotation { _ in try cancellation.check() }
    observations.sort {
      if $0.viewerMonotonicNanoseconds != $1.viewerMonotonicNanoseconds {
        return $0.viewerMonotonicNanoseconds < $1.viewerMonotonicNanoseconds
      }
      return $0.key.wireSequence < $1.key.wireSequence
    }
    let sessions = references.values.map { reference in
      ViewerLiveSessionSnapshot(
        connectionID: reference.connectionID,
        metadata: reference.metadata,
        isImported: true,
        positiveDropCount: dropCountByConnection[reference.connectionID] ?? 0,
        endedWallMilliseconds: reference.endedAtMilliseconds
          ?? document.session.endedAtMilliseconds
          ?? reference.startedAtMilliseconds,
        endedMonotonicNanoseconds: latestMonotonicByConnection[reference.connectionID] ?? 0
      )
    }
    return ViewerMemorySessionReplacement(
      sessions: sessions,
      events: observations,
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: ingressOverflowCount,
        windowOverflowCount: windowOverflowCount,
        residentConflictCount: residentConflictCount,
        diagnosticLossCount: diagnosticLossCount
      )
    )
  }

  private static func prepareImportedEvent(
    _ imported: ViewerSessionImportEvent
  ) throws -> (
    envelope: EventEnvelope,
    disposition: ViewerEventDisposition?,
    deterministicByteCount: Int
  ) {
    let type =
      imported.eventType == "nearwire" || imported.eventType.hasPrefix("nearwire.")
      ? try EventType.platform(imported.eventType)
      : try EventType.user(imported.eventType)
    let sourceRole: EndpointRole = imported.direction == .appToViewer ? .app : .viewer
    let targetRole: EndpointRole = imported.direction == .appToViewer ? .viewer : .app
    let envelope = try EventEnvelope(
      id: EventID(rawValue: imported.eventID),
      type: type,
      content: imported.content,
      createdAt: Date(timeIntervalSince1970: Double(imported.createdAtMilliseconds) / 1_000),
      monotonicTimestampNanoseconds: imported.originMonotonicNanoseconds,
      source: EventEndpoint(
        role: sourceRole,
        id: try EndpointID(rawValue: sourceRole == .app ? "imported-app" : "imported-viewer")
      ),
      target: EventEndpoint(
        role: targetRole,
        id: try EndpointID(rawValue: targetRole == .app ? "imported-app" : "imported-viewer")
      ),
      direction: imported.direction,
      sessionEpoch: SessionEpoch(),
      sequence: EventSequence(imported.wireSequence),
      priority: imported.priority,
      ttl: try EventTTL(milliseconds: imported.ttlMilliseconds),
      causality: EventCausality(
        correlationID: try imported.causality?.correlationID.map(EventID.init(rawValue:)),
        replyTo: try imported.causality?.replyTo.map(EventID.init(rawValue:))
      ),
      schemaVersion: try EventSchemaVersion(imported.eventSchemaVersion)
    )
    let (remainingTTL, overflow) = imported.ttlMilliseconds.multipliedReportingOverflow(
      by: 1_000_000
    )
    guard !overflow else { throw ViewerSessionTransferError.invalidValue }
    let record = try WireEventRecord(
      envelope: envelope,
      remainingTTLNanoseconds: remainingTTL
    )
    let byteCount = try record.deterministicEncodedByteCount()
    guard byteCount <= WireProtocolLimits.default.maximumEventBytes else {
      throw ViewerSessionTransferError.invalidValue
    }
    let disposition: ViewerEventDisposition?
    if let raw = imported.disposition {
      guard let value = ViewerEventDisposition(rawValue: raw) else {
        throw ViewerSessionTransferError.invalidValue
      }
      disposition = value
    } else {
      disposition = nil
    }
    return (envelope, disposition, byteCount)
  }

  private static func makeExportDocument(
    _ snapshot: ViewerLiveProjectionSnapshot
  ) throws -> ViewerMemorySessionExportDocument {
    let sessions = snapshot.sessions.sorted {
      $0.connectionID.uuidString < $1.connectionID.uuidString
    }
    let references = Dictionary(
      uniqueKeysWithValues: sessions.enumerated().map { index, session in
        (
          session.connectionID,
          (device: "App \(index + 1)", connection: "Connection \(index + 1)")
        )
      }
    )
    let eventTimes = snapshot.events.map(\.observation.viewerWallMilliseconds)
    let started = eventTimes.min()
      ?? Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    let ended = sessions.compactMap(\.endedWallMilliseconds).max()
    let devices = sessions.enumerated().map { index, value in
      ViewerMemorySessionExportDocument.Device(
        device: "App \(index + 1)",
        connection: "Connection \(index + 1)",
        startedAtMilliseconds: eventTimes.min() ?? started,
        endedAtMilliseconds: value.endedWallMilliseconds,
        partialHistory: snapshot.gaps.windowOverflowCount > 0,
        state: value.endedWallMilliseconds == nil ? "active" : "closed",
        applicationIdentifier: value.metadata.applicationIdentifier,
        applicationVersion: value.metadata.applicationVersion,
        displayName: value.metadata.displayName
      )
    }
    let events = try snapshot.events.map { value in
      guard let reference = references[value.observation.key.connectionID] else {
        throw ViewerSessionTransferError.invalidValue
      }
      let envelope = value.observation.envelope
      let resolvedDisposition = value.laterDisposition
        ?? value.observation.canonicalProjection.initialDisposition
      let causality: ViewerMemorySessionExportDocument.Causality?
      if envelope.causality.correlationID != nil || envelope.causality.replyTo != nil {
        causality = ViewerMemorySessionExportDocument.Causality(
          correlationID: envelope.causality.correlationID?.rawValue,
          replyTo: envelope.causality.replyTo?.rawValue
        )
      } else {
        causality = nil
      }
      return ViewerMemorySessionExportDocument.Event(
        device: reference.device,
        connection: reference.connection,
        direction: envelope.direction,
        wireSequence: envelope.sequence.rawValue,
        eventID: envelope.id.rawValue,
        eventType: envelope.type.rawValue,
        content: envelope.content,
        createdAtMilliseconds: value.observation.canonicalProjection.createdWallMilliseconds,
        viewerReceivedAtMilliseconds: value.observation.viewerWallMilliseconds,
        viewerMonotonicNanoseconds: value.observation.viewerMonotonicNanoseconds,
        priority: envelope.priority,
        disposition: resolvedDisposition?.rawValue,
        originMonotonicNanoseconds: envelope.monotonicTimestampNanoseconds,
        ttlMilliseconds: envelope.ttl.milliseconds,
        eventSchemaVersion: envelope.schemaVersion.rawValue,
        causality: causality
      )
    }
    let lastEventTime = eventTimes.max() ?? started
    let gapTime = ended ?? lastEventTime
    func gap(
      reason: String,
      count: UInt64,
      reference: (device: String, connection: String)? = nil
    ) -> ViewerMemorySessionExportDocument.Gap? {
      guard count > 0 else { return nil }
      return ViewerMemorySessionExportDocument.Gap(
        createdAtMilliseconds: gapTime,
        reason: reason,
        count: Int64(clamping: count),
        firstViewerTimeMilliseconds: started,
        lastViewerTimeMilliseconds: gapTime,
        directions: "both",
        device: reference?.device,
        connection: reference?.connection,
        firstWireSequence: nil,
        lastWireSequence: nil
      )
    }
    let globalGaps = [
      gap(reason: "nearwire.memory.ingressOverflow", count: snapshot.gaps.ingressOverflowCount),
      gap(reason: "nearwire.memory.windowOverflow", count: snapshot.gaps.windowOverflowCount),
      gap(reason: "nearwire.memory.residentConflict", count: snapshot.gaps.residentConflictCount),
      gap(reason: "nearwire.memory.diagnosticLoss", count: snapshot.gaps.diagnosticLossCount),
    ].compactMap { $0 }
    let deviceGaps: [ViewerMemorySessionExportDocument.Gap] = sessions.compactMap { session in
      guard let reference = references[session.connectionID] else { return nil }
      return gap(
        reason: "nearwire.memory.drop",
        count: session.positiveDropCount,
        reference: reference
      )
    }
    return ViewerMemorySessionExportDocument(
      session: ViewerMemorySessionExportDocument.Session(
        startedAtMilliseconds: started,
        endedAtMilliseconds: ended,
        name: nil,
        note: nil,
        pinned: false,
        state: ended == nil ? "active" : "closed"
      ),
      devices: devices,
      events: events,
      gaps: globalGaps + deviceGaps,
      annotations: []
    )
  }

  private static func encodeExportDocument(
    _ document: ViewerMemorySessionExportDocument
  ) throws -> Data {
    let disclosure = document.disclosure
    let session = document.session
    let devices: [[String: Any]] = document.devices.map { device in
      [
        "device": device.device,
        "connection": device.connection,
        "startedAtMilliseconds": device.startedAtMilliseconds,
        "endedAtMilliseconds": optionalFoundationValue(device.endedAtMilliseconds),
        "partialHistory": device.partialHistory,
        "state": device.state,
        "applicationIdentifier": optionalFoundationValue(device.applicationIdentifier),
        "applicationVersion": optionalFoundationValue(device.applicationVersion),
        "displayName": optionalFoundationValue(device.displayName),
      ]
    }
    let events: [[String: Any]] = document.events.map { event in
      var value: [String: Any] = [
        "device": event.device,
        "connection": event.connection,
        "direction": event.direction.rawValue,
        "wireSequence": event.wireSequence,
        "eventID": event.eventID,
        "eventType": event.eventType,
        "content": foundationJSONValue(event.content),
        "createdAtMilliseconds": event.createdAtMilliseconds,
        "viewerReceivedAtMilliseconds": event.viewerReceivedAtMilliseconds,
        "viewerMonotonicNanoseconds": event.viewerMonotonicNanoseconds,
        "priority": event.priority.rawValue,
        "originMonotonicNanoseconds": event.originMonotonicNanoseconds,
        "ttlMilliseconds": event.ttlMilliseconds,
        "eventSchemaVersion": event.eventSchemaVersion,
      ]
      if let disposition = event.disposition { value["disposition"] = disposition }
      if let causality = event.causality {
        value["causality"] = [
          "correlationID": optionalFoundationValue(causality.correlationID),
          "replyTo": optionalFoundationValue(causality.replyTo),
        ]
      }
      return value
    }
    let gaps: [[String: Any]] = document.gaps.map { gap in
      [
        "createdAtMilliseconds": gap.createdAtMilliseconds,
        "reason": gap.reason,
        "count": gap.count,
        "firstViewerTimeMilliseconds": gap.firstViewerTimeMilliseconds,
        "lastViewerTimeMilliseconds": gap.lastViewerTimeMilliseconds,
        "directions": gap.directions,
        "device": optionalFoundationValue(gap.device),
        "connection": optionalFoundationValue(gap.connection),
        "firstWireSequence": optionalFoundationValue(gap.firstWireSequence),
        "lastWireSequence": optionalFoundationValue(gap.lastWireSequence),
      ]
    }
    let value: [String: Any] = [
      "schemaVersion": document.schemaVersion,
      "scope": document.scope,
      "disclosure": [
        "format": disclosure.format,
        "version": disclosure.version,
        "warning": disclosure.warning,
        "aliasesArePseudonymsNotRedaction": disclosure.aliasesArePseudonymsNotRedaction,
        "unencrypted": disclosure.unencrypted,
        "outsideViewerQuotaAndRetention": disclosure.outsideViewerQuotaAndRetention,
        "mayBeSyncedOrBackedUpByDestinationProvider":
          disclosure.mayBeSyncedOrBackedUpByDestinationProvider,
      ],
      "session": [
        "startedAtMilliseconds": session.startedAtMilliseconds,
        "endedAtMilliseconds": optionalFoundationValue(session.endedAtMilliseconds),
        "name": optionalFoundationValue(session.name),
        "note": optionalFoundationValue(session.note),
        "pinned": session.pinned,
        "state": session.state,
      ],
      "devices": devices,
      "events": events,
      "gaps": gaps,
      "annotations": [],
    ]
    guard JSONSerialization.isValidJSONObject(value) else {
      throw ViewerSessionTransferError.invalidValue
    }
    return try JSONSerialization.data(
      withJSONObject: value,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  private static func optionalFoundationValue<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : value
  }

  private static func foundationJSONValue(_ value: JSONValue) -> Any {
    switch value {
    case .null: return NSNull()
    case .bool(let value): return value
    case .integer(let value): return value
    case .number(let value): return value
    case .string(let value): return value
    case .array(let values): return values.map(foundationJSONValue)
    case .object(let values): return values.mapValues(foundationJSONValue)
    }
  }

  private func isCancelled(_ id: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelledOperations.contains(id)
  }

  private func beginOperation(_ id: UUID) {
    lock.lock()
    activeOperations.insert(id)
    lock.unlock()
  }

  private func finishOperation(_ id: UUID) {
    lock.lock()
    activeOperations.remove(id)
    cancelledOperations.remove(id)
    lock.unlock()
  }

  private static func workspaceFailure(
    _ error: ViewerSessionTransferError
  ) -> ViewerWorkspaceMutationFailure {
    switch error {
    case .cancelled: return .cancelled
    case .capacityExceeded, .workLimitExceeded: return .capacityExceeded
    case .unsupportedSchema: return .unsupportedFile
    case .busy: return .busy
    default: return .invalidFile
    }
  }
}

final class ViewerCompositeSessionJournal: ViewerSessionJournaling,
  ViewerWorkspaceSessionControlling, @unchecked Sendable
{
  let runtimeLogicalID: UUID

  private let memorySessionTransfer: ViewerMemorySessionTransferService?
  private let liveWindow: ViewerLiveEventWindow
  private let workspaceMutationGate = DispatchSemaphore(value: 1)
  private let workspaceEpochLock = NSLock()
  private var workspaceEpoch: UInt64 = 0

  init(
    runtimeLogicalID: UUID,
    liveWindow: ViewerLiveEventWindow,
    memorySessionTransfer: ViewerMemorySessionTransferService? = nil
  ) {
    precondition(liveWindow.runtimeLogicalID == runtimeLogicalID)
    self.runtimeLogicalID = runtimeLogicalID
    self.memorySessionTransfer = memorySessionTransfer
    self.liveWindow = liveWindow
  }

  func runtimeStarted(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {
    guard logicalID == runtimeLogicalID else { return }
  }

  func sessionStarted(runtimeLogicalID: UUID, _ context: ViewerAdmissionSessionContext) {
    workspaceMutationGate.wait()
    defer { workspaceMutationGate.signal() }
    guard runtimeLogicalID == self.runtimeLogicalID else { return }
    if let metadata = try? ViewerFrozenSessionMetadata(context: context, nickname: nil) {
      liveWindow.sessionStarted(metadata, connectionID: context.connectionID)
    }
  }

  func eventCommitted(
    _ observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) {
    workspaceMutationGate.wait()
    defer { workspaceMutationGate.signal() }
    guard observation.key.runtimeLogicalID == runtimeLogicalID else {
      outcome(.sealed)
      return
    }
    let admittedEpoch = currentWorkspaceEpoch()
    let offer = liveWindow.offer(observation) { [weak self] decision in
      guard let self else {
        outcome(.sealed)
        return
      }
      self.resolveDeferredLiveDecision(
        decision,
        admittedEpoch: admittedEpoch,
        observation: observation,
        outcome: outcome
      )
    }
    resolveLiveDecision(offer, observation: observation, outcome: outcome)
  }

  func clearCurrentSession(
    afterCommit: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  ) {
    workspaceMutationGate.wait()
    liveWindow.flushIngressForWorkspaceMutation()
    let gate = workspaceMutationGate
    let advanceWorkspaceEpoch: @Sendable () -> Void = { [weak self] in
      self?.advanceWorkspaceEpoch()
    }
    advanceWorkspaceEpoch()
    liveWindow.clearCurrentSession()
    afterCommit()
    gate.signal()
    completion(.success(()))
  }

  func importCurrentSession(
    from url: URL,
    afterCommit: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Result<Void, ViewerWorkspaceMutationFailure>) -> Void
  ) {
    workspaceMutationGate.wait()
    liveWindow.flushIngressForWorkspaceMutation()
    let gate = workspaceMutationGate
    let advanceWorkspaceEpoch: @Sendable () -> Void = { [weak self] in
      self?.advanceWorkspaceEpoch()
    }
    guard let memorySessionTransfer else {
      gate.signal()
      completion(.failure(.unavailable))
      return
    }
    memorySessionTransfer.importCurrentSession(
      from: url,
      afterCommit: {
        advanceWorkspaceEpoch()
        afterCommit()
      },
      completion: { result in
        gate.signal()
        completion(result)
      }
    )
  }

  func cancelCurrentSessionImport() {
    memorySessionTransfer?.cancelCurrentSessionImport()
  }

  func cancelWorkspaceMutationAndWait() -> Task<Void, Never> {
    memorySessionTransfer?.cancelCurrentSessionImport()
    let gate = workspaceMutationGate
    return Task {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          gate.wait()
          gate.signal()
          continuation.resume()
        }
      }
    }
  }

  private func resolveLiveDecision(
    _ decision: ViewerLiveEventOfferOutcome,
    observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) {
    switch decision {
    case .accepted, .untracked:
      outcome(.untracked)
    case .deferred:
      break
    case .identical:
      outcome(.identical)
    case .presentationConflict:
      outcome(.presentationConflict)
    case .sealed:
      outcome(.sealed)
    }
  }

  private func resolveDeferredLiveDecision(
    _ decision: ViewerLiveEventOfferOutcome,
    admittedEpoch: UInt64,
    observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) {
    workspaceEpochLock.lock()
    guard workspaceEpoch == admittedEpoch else {
      workspaceEpochLock.unlock()
      outcome(.sealed)
      return
    }
    resolveLiveDecision(decision, observation: observation, outcome: outcome)
    workspaceEpochLock.unlock()
  }

  private func currentWorkspaceEpoch() -> UInt64 {
    workspaceEpochLock.lock()
    defer { workspaceEpochLock.unlock() }
    return workspaceEpoch
  }

  private func advanceWorkspaceEpoch() {
    workspaceEpochLock.lock()
    workspaceEpoch = workspaceEpoch == UInt64.max ? 0 : workspaceEpoch + 1
    workspaceEpochLock.unlock()
  }

  func uplinkTerminated(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    direction: EventDirection,
    wireSequence: UInt64,
    disposition: ViewerEventDisposition,
    monotonicNanoseconds: UInt64
  ) {
    workspaceMutationGate.wait()
    defer { workspaceMutationGate.signal() }
    guard runtimeLogicalID == self.runtimeLogicalID else { return }
    liveWindow.laterDisposition(
      key: ViewerEventJournalKey(
        runtimeLogicalID: runtimeLogicalID,
        connectionID: connectionID,
        direction: direction,
        wireSequence: wireSequence
      ),
      disposition: disposition
    )
  }

  func policyChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    policy: ViewerRatePolicy,
    monotonicNanoseconds: UInt64
  ) {
    workspaceMutationGate.wait()
    defer { workspaceMutationGate.signal() }
    guard runtimeLogicalID == self.runtimeLogicalID else { return }
  }

  func dropsChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    samples: [ViewerDropJournalSample],
    monotonicNanoseconds: UInt64
  ) {
    workspaceMutationGate.wait()
    defer { workspaceMutationGate.signal() }
    guard runtimeLogicalID == self.runtimeLogicalID else { return }
    liveWindow.dropsChanged(connectionID: connectionID, samples: samples)
  }

  func sessionEnded(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {
    workspaceMutationGate.wait()
    defer { workspaceMutationGate.signal() }
    guard runtimeLogicalID == self.runtimeLogicalID else { return }
    liveWindow.sessionEnded(
      connectionID: connectionID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: monotonicNanoseconds
    )
  }

  func runtimeEnded(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) async {
    await acquireWorkspaceMutationGate()
    defer { workspaceMutationGate.signal() }
    guard logicalID == runtimeLogicalID else { return }
    await liveWindow.finishIngress()
    await liveWindow.runtimeEnded()
  }

  private func acquireWorkspaceMutationGate() async {
    let gate = workspaceMutationGate
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        gate.wait()
        continuation.resume()
      }
    }
  }
}

struct ViewerRuntimeExplorerInputs: @unchecked Sendable {
  let runtimeLogicalID: UUID
  let liveObservations: any ViewerLiveObservationProviding
  let workspaceControl: any ViewerWorkspaceSessionControlling
  let memorySessionTransfer: ViewerMemorySessionTransferService?

  init(
    runtimeLogicalID: UUID,
    liveObservations: any ViewerLiveObservationProviding,
    workspaceControl: (any ViewerWorkspaceSessionControlling)? = nil,
    memorySessionTransfer: ViewerMemorySessionTransferService? = nil
  ) {
    precondition(liveObservations.runtimeLogicalID == runtimeLogicalID)
    self.runtimeLogicalID = runtimeLogicalID
    self.liveObservations = liveObservations
    self.workspaceControl = workspaceControl ?? ViewerUnavailableWorkspaceSessionControl()
    self.memorySessionTransfer = memorySessionTransfer
  }
}

final class ViewerOperationDeliveryGate: @unchecked Sendable {
  private enum State: Equatable {
    case waiting
    case deliveryClaimed
    case cancelled
  }

  private let lock = NSLock()
  private let deliveryClaimed: @Sendable () -> Void
  private var state = State.waiting

  init(deliveryClaimed: @escaping @Sendable () -> Void = {}) {
    self.deliveryClaimed = deliveryClaimed
  }

  func claimDelivery() -> Bool {
    lock.lock()
    guard state == .waiting else {
      lock.unlock()
      return false
    }
    state = .deliveryClaimed
    lock.unlock()
    deliveryClaimed()
    return true
  }

  /// Returns `true` when an already-claimed delivery still owns the tracked work.
  func cancel() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .waiting:
      state = .cancelled
      return false
    case .deliveryClaimed:
      state = .cancelled
      return true
    case .cancelled:
      return false
    }
  }
}

final class ViewerLatestMainActorDeliveryPump<Value: Sendable>: @unchecked Sendable {
  typealias Handler = @MainActor @Sendable (Value) -> Void

  private let lock = NSLock()
  private let workTracker = ViewerAsyncWorkTracker()
  private let handler: Handler
  private var pending: Value?
  private var drainID: UUID?
  private var processing = false
  private var sealed = false

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  @discardableResult
  func submit(_ value: Value) -> Bool {
    var displaced: Value?
    var shouldSchedule = false
    lock.lock()
    guard !sealed else {
      lock.unlock()
      return false
    }
    swap(&displaced, &pending)
    pending = value
    if drainID == nil {
      let id = UUID()
      drainID = id
      workTracker.begin(id: id)
      shouldSchedule = true
    }
    lock.unlock()
    withExtendedLifetime(displaced) {}
    if shouldSchedule { scheduleDrain() }
    return true
  }

  func cancelPending() {
    var displaced: Value?
    lock.lock()
    swap(&displaced, &pending)
    lock.unlock()
    withExtendedLifetime(displaced) {}
  }

  func sealAndWait() -> Task<Void, Never> {
    var displaced: Value?
    lock.lock()
    sealed = true
    swap(&displaced, &pending)
    lock.unlock()
    withExtendedLifetime(displaced) {}
    return workTracker.waitTask()
  }

  func waitForIdle() -> Task<Void, Never> {
    workTracker.waitTask()
  }

  var pendingWorkCount: Int { workTracker.activeCount }
  var maximumRetainedValueCount: Int { 2 }

  var retainedValueCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return (pending == nil ? 0 : 1) + (processing ? 1 : 0)
  }

  private func scheduleDrain() {
    Task { @MainActor [self] in drainOne() }
  }

  @MainActor
  private func drainOne() {
    let value: Value?
    var completionID: UUID?
    lock.lock()
    if sealed || pending == nil {
      value = nil
      completionID = drainID
      drainID = nil
    } else {
      value = pending
      pending = nil
      processing = true
    }
    lock.unlock()

    guard let value else {
      if let completionID { workTracker.complete(completionID) }
      return
    }

    handler(value)

    var displaced: Value?
    var shouldSchedule = false
    lock.lock()
    processing = false
    if sealed {
      swap(&displaced, &pending)
      completionID = drainID
      drainID = nil
    } else if pending != nil {
      shouldSchedule = true
    } else {
      completionID = drainID
      drainID = nil
    }
    lock.unlock()
    withExtendedLifetime(displaced) {}
    if let completionID { workTracker.complete(completionID) }
    if shouldSchedule { scheduleDrain() }
  }
}

final class ViewerAsyncWorkTracker: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let lock = NSLock()
  private let group = DispatchGroup()
  private var activeIDs: Set<UUID> = []

  @discardableResult
  func begin(id: UUID = UUID()) -> UUID {
    lock.lock()
    precondition(activeIDs.insert(id).inserted)
    group.enter()
    lock.unlock()
    return id
  }

  func complete(_ id: UUID) {
    lock.lock()
    let removed = activeIDs.remove(id) != nil
    lock.unlock()
    if removed { group.leave() }
  }

  var activeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return activeIDs.count
  }

  func waitTask() -> Task<Void, Never> {
    let group = group
    return Task {
      await withCheckedContinuation { continuation in
        group.notify(queue: .global(qos: .utility)) {
          continuation.resume()
        }
      }
    }
  }

  var description: String { "ViewerAsyncWorkTracker(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

final class ViewerRuntimeCleanupReceipt: @unchecked Sendable {
  private let lock = NSLock()
  private let start: @Sendable () -> Task<Void, Never>
  private var task: Task<Void, Never>?

  init(start: @escaping @Sendable () -> Task<Void, Never>) {
    self.start = start
  }

  func begin() -> Task<Void, Never> {
    lock.lock()
    if let task {
      lock.unlock()
      return task
    }
    let task = start()
    self.task = task
    lock.unlock()
    return task
  }
}

final class ViewerManagerGenerationSource: @unchecked Sendable {
  private let lock = NSLock()
  private var nextGeneration: UInt64 = 1

  func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let generation = nextGeneration
    nextGeneration = nextGeneration == UInt64.max ? 1 : nextGeneration + 1
    return generation
  }
}

struct ViewerRuntimeComponents: @unchecked Sendable {
  let runtimeLogicalID: UUID
  let managerGeneration: UInt64
  let handoffOwner: any ViewerAdmissionHandoffOwning
  let sessionControl: any ViewerSessionControlling
  let liveObservations: any ViewerLiveObservationProviding
  let workspaceControl: any ViewerWorkspaceSessionControlling
  let compositeJournal: ViewerCompositeSessionJournal
  let explorerInputs: ViewerRuntimeExplorerInputs
  let cleanupReceipt: ViewerRuntimeCleanupReceipt
  let memorySessionTransfer: ViewerMemorySessionTransferService?

  init(
    runtimeLogicalID: UUID,
    managerGeneration: UInt64,
    handoffOwner: any ViewerAdmissionHandoffOwning,
    sessionControl: any ViewerSessionControlling,
    liveObservations: any ViewerLiveObservationProviding,
    workspaceControl: (any ViewerWorkspaceSessionControlling)? = nil,
    compositeJournal: ViewerCompositeSessionJournal,
    explorerInputs: ViewerRuntimeExplorerInputs,
    cleanupReceipt: ViewerRuntimeCleanupReceipt,
    memorySessionTransfer: ViewerMemorySessionTransferService? = nil
  ) {
    precondition(managerGeneration > 0)
    precondition((handoffOwner as AnyObject) === (sessionControl as AnyObject))
    precondition(sessionControl.runtimeLogicalID == runtimeLogicalID)
    precondition(sessionControl.managerGeneration == managerGeneration)
    precondition(liveObservations.runtimeLogicalID == runtimeLogicalID)
    precondition(compositeJournal.runtimeLogicalID == runtimeLogicalID)
    precondition(explorerInputs.runtimeLogicalID == runtimeLogicalID)
    self.runtimeLogicalID = runtimeLogicalID
    self.managerGeneration = managerGeneration
    self.handoffOwner = handoffOwner
    self.sessionControl = sessionControl
    self.liveObservations = liveObservations
    self.workspaceControl = workspaceControl ?? compositeJournal
    self.compositeJournal = compositeJournal
    self.explorerInputs = explorerInputs
    self.cleanupReceipt = cleanupReceipt
    self.memorySessionTransfer = memorySessionTransfer
  }

  static func make(
    runtimeLogicalID: UUID,
    managerGeneration: UInt64,
    scheduler: ViewerAdmissionScheduler = .live,
    preferences: ViewerDevicePreferences = ViewerDevicePreferences(),
    uplinkSink: @escaping @Sendable (UUID, WireReceivedEvent) -> Void = { _, _ in },
    eventWallMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
  ) -> ViewerRuntimeComponents {
    let liveWindow = ViewerLiveEventWindow(
      runtimeLogicalID: runtimeLogicalID,
      liveGeneration: managerGeneration
    )
    let memorySessionTransfer = ViewerMemorySessionTransferService(liveWindow: liveWindow)
    let compositeJournal = ViewerCompositeSessionJournal(
      runtimeLogicalID: runtimeLogicalID,
      liveWindow: liveWindow,
      memorySessionTransfer: memorySessionTransfer
    )
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: runtimeLogicalID,
      managerGeneration: managerGeneration,
      scheduler: scheduler,
      preferences: preferences,
      uplinkSink: uplinkSink,
      eventWallMilliseconds: eventWallMilliseconds,
      journal: compositeJournal
    )
    let explorerInputs = ViewerRuntimeExplorerInputs(
      runtimeLogicalID: runtimeLogicalID,
      liveObservations: liveWindow,
      workspaceControl: compositeJournal,
      memorySessionTransfer: memorySessionTransfer
    )
    let cleanupReceipt = ViewerRuntimeCleanupReceipt {
      manager.sealControlAdmission()
      let presentation = liveWindow.sealPresentation()
      let mutation = compositeJournal.cancelWorkspaceMutationAndWait()
      return Task {
        async let presentationDone: Void = presentation.value
        async let mutationDone: Void = mutation.value
        _ = await (presentationDone, mutationDone)
      }
    }
    return ViewerRuntimeComponents(
      runtimeLogicalID: runtimeLogicalID,
      managerGeneration: managerGeneration,
      handoffOwner: manager,
      sessionControl: manager,
      liveObservations: liveWindow,
      workspaceControl: compositeJournal,
      compositeJournal: compositeJournal,
      explorerInputs: explorerInputs,
      cleanupReceipt: cleanupReceipt,
      memorySessionTransfer: memorySessionTransfer
    )
  }
}

extension ViewerCompositeSessionJournal: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerCompositeSessionJournal(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerRuntimeExplorerInputs: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRuntimeExplorerInputs(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerRuntimeCleanupReceipt: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRuntimeCleanupReceipt(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerRuntimeComponents: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRuntimeComponents(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
