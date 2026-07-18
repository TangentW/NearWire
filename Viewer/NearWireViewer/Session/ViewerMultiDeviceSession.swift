import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireFlowControl
@_spi(NearWireInternal) import NearWireTransport

enum ViewerSessionState: String, Codable, Sendable {
  case provisional
  case negotiating
  case active
  case disconnecting
  case recent
}

enum ViewerSessionTerminalCategory: String, Codable, Sendable {
  case transportEnded
  case policyTimeout
  case protocolViolation
  case activeWorkLimitExceeded
  case localAdmissionFailure
  case replacedByReconnect
  case userDisconnected
  case viewerShutdown
}

struct ViewerSessionSnapshot: Identifiable, Equatable, Sendable {
  let id: UUID
  let connectionID: UUID?
  let route: ViewerLogicalRoute
  let displayName: String
  let applicationVersion: String?
  let installationAlias: String
  let nickname: String?
  let state: ViewerSessionState
  let requestedPolicy: ViewerRatePolicy
  let effectivePolicy: ViewerRatePolicy?
  let uplinkCount: Int
  let uplinkBytes: Int
  let uplinkOldestWaitNanoseconds: UInt64?
  let downlinkCount: Int
  let downlinkBytes: Int
  let downlinkOldestWaitNanoseconds: UInt64?
  let receivedEvents: UInt64
  let deliveredEvents: UInt64
  let sentEvents: UInt64
  let droppedEvents: UInt64
  let overflowDroppedEvents: UInt64
  let expiredEvents: UInt64
  let coalescedEvents: UInt64
  let routeDroppedEvents: UInt64
  let remoteDroppedEvents: UInt64
  let ingressEventsPerSecond: UInt64
  let egressEventsPerSecond: UInt64
  let terminalCategory: ViewerSessionTerminalCategory?

  var title: String { nickname ?? displayName }
}

extension ViewerSessionSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerSessionSnapshot(state: \(state.rawValue), terminal: \(terminalCategory?.rawValue ?? "none"))"
  }

  var debugDescription: String { description }

  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "state": state.rawValue,
        "terminal": terminalCategory?.rawValue ?? "none",
      ],
      displayStyle: .struct
    )
  }
}

enum ViewerDownlinkPolicy: Sendable {
  case normal
  case keepLatest(String)
}

extension ViewerDownlinkPolicy: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    switch self {
    case .normal: return "ViewerDownlinkPolicy.normal"
    case .keepLatest: return "ViewerDownlinkPolicy.keepLatest(redacted)"
    }
  }

  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .enum)
  }
}

struct ViewerDownlinkJournalEvent: Sendable {
  let envelope: EventEnvelope
  let deterministicEncodedByteCount: Int
  let canonicalContentData: Data
}

extension ViewerDownlinkJournalEvent: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerDownlinkJournalEvent(redacted, bytes: \(deterministicEncodedByteCount))"
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

struct ViewerDropJournalSample: Equatable, Sendable {
  enum Reason: String, Sendable {
    case localOverflow
    case localExpired
    case localCoalesced
    case localRoute
    case remoteOverflow
    case remoteExpired
    case remoteCoalesced
  }

  static let maximumBatchCount = 7

  let reason: Reason
  let count: UInt64
}

private enum ViewerSessionFailure: Error {
  case terminal(ViewerSessionTerminalCategory)
}

private struct ViewerLocalDropCounts: Sendable {
  var overflow: UInt64 = 0
  var expired: UInt64 = 0
  var coalesced: UInt64 = 0
  var route: UInt64 = 0

  var total: UInt64 {
    Self.saturatingAdd(
      Self.saturatingAdd(overflow, expired),
      Self.saturatingAdd(coalesced, route)
    )
  }

  mutating func add(
    overflow: Int = 0,
    expired: Int = 0,
    coalesced: Int = 0,
    route: Int = 0
  ) {
    self.overflow = Self.saturatingAdd(self.overflow, UInt64(max(0, overflow)))
    self.expired = Self.saturatingAdd(self.expired, UInt64(max(0, expired)))
    self.coalesced = Self.saturatingAdd(self.coalesced, UInt64(max(0, coalesced)))
    self.route = Self.saturatingAdd(self.route, UInt64(max(0, route)))
  }

  mutating func merge(_ other: Self) {
    overflow = Self.saturatingAdd(overflow, other.overflow)
    expired = Self.saturatingAdd(expired, other.expired)
    coalesced = Self.saturatingAdd(coalesced, other.coalesced)
    route = Self.saturatingAdd(route, other.route)
  }

  mutating func clear() { self = Self() }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : value
  }
}

private struct ViewerRemoteDropCounts: Sendable {
  var overflow: UInt64 = 0
  var expired: UInt64 = 0
  var coalesced: UInt64 = 0

  var total: UInt64 {
    Self.saturatingAdd(Self.saturatingAdd(overflow, expired), coalesced)
  }

  mutating func add(overflow: UInt64, expired: UInt64, coalesced: UInt64) {
    self.overflow = Self.saturatingAdd(self.overflow, overflow)
    self.expired = Self.saturatingAdd(self.expired, expired)
    self.coalesced = Self.saturatingAdd(self.coalesced, coalesced)
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : value
  }
}

final class ViewerDeviceSession: ViewerAdmissionSessionReceiving, @unchecked Sendable,
  CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible
{
  static let policyDeadlineNanoseconds: UInt64 = 10_000_000_000
  static let uplinkQueueMaximumCount = 10_000
  static let uplinkQueueMaximumBytes = 64 * 1_024 * 1_024
  static let downlinkQueueMaximumCount = 5_000
  static let downlinkQueueMaximumBytes = 16 * 1_024 * 1_024
  static let businessEventBurstDurationSeconds = 0.25
  static let controlReservedCount = 1
  static let controlReservedBytes = 64 * 1_024
  static let serviceSlice = 32

  let ingressLimits: ViewerSessionIngressLimits
  let connectionID: UUID
  let route: ViewerLogicalRoute

  private let handle: ViewerAdmissionHandle
  private let core: ViewerAdmissionConnectionCore
  private let context: ViewerAdmissionSessionContext
  private let scheduler: ViewerAdmissionScheduler
  private let requestedAtAttachment: ViewerRatePolicy
  private let nicknameAtAttachment: String?
  private let onSnapshot: @Sendable (ViewerSessionSnapshot) -> Void
  private let onTerminal: @Sendable (UUID, ViewerSessionTerminalCategory) -> Void
  private let uplinkSink: @Sendable (WireReceivedEvent) -> Void
  private let uplinkJournal: @Sendable (WireReceivedEvent, ViewerEventDisposition) -> Void
  private let uplinkDispositionJournal:
    @Sendable (EventDirection, UInt64, ViewerEventDisposition, UInt64) -> Void
  private let downlinkJournal: @Sendable ([ViewerDownlinkJournalEvent], UInt64) -> Void
  private let policyJournal: @Sendable (ViewerRatePolicy, UInt64) -> Void
  private let dropJournal: @Sendable ([ViewerDropJournalSample], UInt64) -> Void
  private let uplinkHandoff = ViewerUplinkHandoff()

  private var state: ViewerSessionState = .provisional
  private var codec: WireSessionCodec
  private let sessionEpoch = SessionEpoch()
  private var requestedPolicy: ViewerRatePolicy
  private var desiredPolicy: ViewerRatePolicy
  private var effectivePolicy: ViewerRatePolicy?
  private var pendingOffer: ViewerRatePolicy?
  private var policyDeadline: UInt64?
  private var deadlineElapsed = false
  private var ownedSuffixReceipt: UInt64?
  private var inputSequence: WireSequenceValidator
  private var outputSequence: WireSequenceCounter
  private var ingressContractBucket: EventTokenBucket?
  private var uplinkDeliveryBucket: EventTokenBucket?
  private var downlinkSendBucket: EventTokenBucket?
  private var uplinkQueue: BoundedEventQueue<WireReceivedEvent>
  private var uplinkJournalSequences: [EventID: UInt64] = [:]
  private var downlinkQueue: BoundedEventQueue<EventDraft>
  private var batchScheduler: EventBatchScheduler
  private var serviceWake: Task<Void, Never>?
  private var serviceWakeDeadline: UInt64?
  private var serviceWakeGeneration: UInt64 = 0
  private var downlinkMailboxBlocked = false
  private var terminalCategory: ViewerSessionTerminalCategory?
  private var terminalNotified = false
  private var turnRecordCount = 0
  private var turnSystemCount = 0
  private var systemBucket: EventTokenBucket
  private var receivedEvents: UInt64 = 0
  private var deliveredEvents: UInt64 = 0
  private var sentEvents: UInt64 = 0
  private var localDrops = ViewerLocalDropCounts()
  private var remoteDrops = ViewerRemoteDropCounts()
  private var remoteDroppedEvents: UInt64 = 0
  private var pendingLocalDropSummary = ViewerLocalDropCounts()
  private var localDropSummaryInFlight = false
  private var throughputSecond: UInt64 = 0
  private var ingressThisSecond: UInt64 = 0
  private var egressThisSecond: UInt64 = 0

  init(
    handle: ViewerAdmissionHandle,
    context: ViewerAdmissionSessionContext,
    requestedPolicy: ViewerRatePolicy,
    nickname: String?,
    scheduler: ViewerAdmissionScheduler,
    uplinkSink: @escaping @Sendable (WireReceivedEvent) -> Void,
    uplinkJournal: @escaping @Sendable (WireReceivedEvent, ViewerEventDisposition) -> Void = {
      _, _ in
    },
    uplinkDispositionJournal:
      @escaping @Sendable (
        EventDirection,
        UInt64,
        ViewerEventDisposition,
        UInt64
      ) -> Void = { _, _, _, _ in },
    downlinkJournal: @escaping @Sendable ([ViewerDownlinkJournalEvent], UInt64) -> Void = { _, _ in
    },
    policyJournal: @escaping @Sendable (ViewerRatePolicy, UInt64) -> Void = { _, _ in },
    dropJournal: @escaping @Sendable ([ViewerDropJournalSample], UInt64) -> Void = { _, _ in },
    onSnapshot: @escaping @Sendable (ViewerSessionSnapshot) -> Void,
    onTerminal: @escaping @Sendable (UUID, ViewerSessionTerminalCategory) -> Void
  ) throws {
    self.handle = handle
    core = handle.connectionCore
    self.context = context
    self.scheduler = scheduler
    requestedAtAttachment = requestedPolicy
    self.requestedPolicy = requestedPolicy
    desiredPolicy = requestedPolicy
    nicknameAtAttachment = nickname
    self.uplinkSink = uplinkSink
    self.uplinkJournal = uplinkJournal
    self.uplinkDispositionJournal = uplinkDispositionJournal
    self.downlinkJournal = downlinkJournal
    self.policyJournal = policyJournal
    self.dropJournal = dropJournal
    self.onSnapshot = onSnapshot
    self.onTerminal = onTerminal
    connectionID = context.connectionID
    route = ViewerLogicalRoute(
      installationID: context.appHello.installationID,
      applicationIdentifier: context.appHello.applicationIdentifier
    )
    codec = try WireSessionCodec(negotiation: context.negotiation)
    let maximumFrameBytes = codec.limits.frame.maximumEncodedFrameBytes(for: .event)
    let (twoChunks, chunkOverflow) = context.receiveChunkBytes.multipliedReportingOverflow(by: 2)
    let (retainedInputBytes, totalOverflow) = maximumFrameBytes.addingReportingOverflow(twoChunks)
    guard context.receiveChunkBytes > 0, !chunkOverflow, !totalOverflow,
      retainedInputBytes <= ViewerSessionIngressLimits.maximumRetainedInputBytes
    else { throw ViewerSessionFailure.terminal(.localAdmissionFailure) }
    ingressLimits = ViewerSessionIngressLimits(
      maximumFramesPerTurn: ViewerSessionIngressLimits.maximumFramesPerTurn,
      maximumRetainedInputBytes: max(
        ViewerSessionIngressLimits.default.maximumRetainedInputBytes,
        retainedInputBytes
      )
    )
    inputSequence = WireSequenceValidator(
      sessionEpoch: sessionEpoch,
      direction: .appToViewer
    )
    outputSequence = WireSequenceCounter(
      sessionEpoch: sessionEpoch,
      direction: .viewerToApp
    )
    let uplinkLimits = try EventQueueLimits(
      maximumEventCount: Self.uplinkQueueMaximumCount,
      maximumTotalBytes: Self.uplinkQueueMaximumBytes,
      maximumSingleEventBytes: context.negotiation.maximumEventBytes
    )
    let downlinkLimits = try EventQueueLimits(
      maximumEventCount: Self.downlinkQueueMaximumCount,
      maximumTotalBytes: Self.downlinkQueueMaximumBytes,
      maximumSingleEventBytes: context.negotiation.maximumEventBytes
    )
    uplinkQueue = BoundedEventQueue(limits: uplinkLimits)
    downlinkQueue = BoundedEventQueue(limits: downlinkLimits)
    batchScheduler = try EventBatchScheduler(
      limits: EventBatchLimits(
        maximumEventCount: min(Self.serviceSlice, codec.limits.maximumBatchEventCount),
        maximumAccountedBytes: max(context.negotiation.maximumEventBytes, 512 * 1_024),
        flushIntervalNanoseconds: 500_000_000,
        queueLimits: downlinkLimits
      ),
      queueLimits: downlinkLimits,
      startNanoseconds: scheduler.now()
    )
    systemBucket = try EventTokenBucket(
      rate: EventRateLimit(eventsPerSecond: 64),
      startNanoseconds: scheduler.now()
    )
  }

  func start() {
    do {
      try core.performSynchronousSessionOperation { [self] in
        state = .negotiating
        let started = scheduler.now()
        let acknowledgement = try WireNegotiator.makeAcknowledgement(
          result: context.negotiation,
          sessionEpoch: sessionEpoch
        )
        let acknowledgementFrame = try codec.encode(
          acknowledgement,
          phase: .awaitingApproval
        )
        try core.admitSessionSend(acknowledgementFrame)
        try beginPolicyOffer(requestedPolicy, startedAt: started)
        publishSnapshot(now: started)
      }
      core.continueAttachedInput()
    } catch let failure as ViewerSessionFailure {
      fail(failure)
    } catch {
      fail(.terminal(.localAdmissionFailure))
    }
  }

  func beginIngressTurn(receiptNanoseconds: UInt64) {
    turnRecordCount = 0
    turnSystemCount = 0
    rollThroughputWindow(now: receiptNanoseconds)
  }

  func receiveSessionFrame(
    _ frame: WireFrame,
    receiptNanoseconds: UInt64
  ) throws -> WireFrameDeliveryDecision {
    do {
      let decision: WireFrameDeliveryDecision
      switch state {
      case .negotiating:
        try receiveNegotiating(frame, receipt: receiptNanoseconds)
        decision = .consume
      case .active:
        decision = try receiveActive(frame, receipt: receiptNanoseconds)
      default:
        throw ViewerSessionFailure.terminal(.protocolViolation)
      }
      if decision == .consume { publishSnapshot(now: receiptNanoseconds) }
      return decision
    } catch let failure as ViewerSessionFailure {
      fail(failure)
      throw failure
    } catch {
      let failure = ViewerSessionFailure.terminal(.protocolViolation)
      fail(failure)
      throw failure
    }
  }

  func decoderDidProgress(
    _ progress: WireFrameDecoderProgress,
    receiptNanoseconds: UInt64
  ) -> ViewerDecoderProgressDisposition {
    switch progress {
    case .pausedOnCompleteFrame:
      ownedSuffixReceipt = receiptNanoseconds
      return .continueReceiving
    case .needsMoreBytes, .drained:
      let releasedSuffix = ownedSuffixReceipt != nil
      ownedSuffixReceipt = nil
      if deadlineElapsed, pendingOffer != nil {
        fail(.terminal(.policyTimeout))
        return .terminalWithoutResume
      }
      if releasedSuffix { scheduleServiceWake(now: scheduler.now()) }
      return .continueReceiving
    }
  }

  func sessionTransportTerminated() {
    completeTerminal(terminalCategory ?? .transportEnded)
  }

  func sessionMailboxMadeProgress(completed: ViewerSessionSendCompletionKind) {
    if completed == .localDropSummary { localDropSummaryInFlight = false }
    downlinkMailboxBlocked = false
    flushLocalDropSummary()
    scheduleServiceWake(now: scheduler.now())
  }

  func updateRequestedPolicy(_ policy: ViewerRatePolicy) {
    core.performSessionOperation { [weak self] in
      guard let self, self.state == .active || self.state == .negotiating else { return }
      self.desiredPolicy = policy
      self.requestedPolicy = policy
      do {
        if self.pendingOffer == nil, self.effectivePolicy != policy {
          try self.beginPolicyOffer(policy, startedAt: self.scheduler.now())
        }
        let now = self.scheduler.now()
        self.scheduleServiceWake(now: now)
        self.publishSnapshot(now: now)
      } catch let failure as ViewerSessionFailure {
        self.fail(failure)
      } catch {
        self.fail(.terminal(.localAdmissionFailure))
      }
    }
  }

  @discardableResult
  func enqueueDownlink(_ draft: EventDraft, policy: ViewerDownlinkPolicy) -> Bool {
    (try? core.performSynchronousSessionOperation { [self] in
      guard state == .active else { return false }
      do {
        let now = scheduler.now()
        let encodedBytes = try JSONEncoder().encode(draft).count
        let queuePolicy: EventQueuePolicy
        switch policy {
        case .normal:
          queuePolicy = .normal
        case .keepLatest(let key):
          queuePolicy = .keepLatest(try KeepLatestKey(key))
        }
        let pending = try PendingEvent(
          id: EventID(),
          value: draft,
          priority: draft.priority,
          ttl: draft.ttl,
          policy: queuePolicy,
          accountedByteCount: encodedBytes,
          enqueuedAtNanoseconds: now
        )
        let result = try downlinkQueue.enqueue(
          pending,
          nowOnQueueClockNanoseconds: now
        )
        addLocalDrops(
          overflow: result.overflowDroppedEventIDs.count,
          expired: result.expiredEventIDs.count,
          coalesced: result.coalescedEventID == nil ? 0 : 1
        )
        scheduleServiceWake(now: now)
        publishSnapshot(now: now)
        return result.isBuffered
      } catch {
        return false
      }
    }) ?? false
  }

  func enqueuePreparedControl(
    _ prepared: ViewerPreparedControlEvent
  ) -> ViewerControlTargetOutcome {
    (try? core.performSynchronousSessionOperation { [self] in
      guard state == .active else { return .notActive }
      do {
        let now = scheduler.now()
        let pending = try PendingEvent(
          id: EventID(),
          value: prepared.draft,
          priority: prepared.draft.priority,
          ttl: prepared.draft.ttl,
          policy: prepared.queuePolicy,
          accountedByteCount: prepared.deterministicEncodedByteCount,
          enqueuedAtNanoseconds: now
        )
        let result = try downlinkQueue.enqueue(
          pending,
          nowOnQueueClockNanoseconds: now
        )
        addLocalDrops(
          overflow: result.overflowDroppedEventIDs.count,
          expired: result.expiredEventIDs.count,
          coalesced: result.coalescedEventID == nil ? 0 : 1
        )
        scheduleServiceWake(now: now)
        publishSnapshot(now: now)
        return result.isBuffered ? .queued : .queueRejected
      } catch {
        return .queueRejected
      }
    }) ?? .notActive
  }

  func disconnect(category: ViewerSessionTerminalCategory) {
    core.performSessionOperation { [weak self] in
      guard let self else { return }
      self.terminalCategory = category
      self.state = .disconnecting
      self.cancelServiceWake()
      let cancelledHandoff = self.uplinkHandoff.cancel()
      let uplink = self.uplinkQueue.clear(reason: .sessionEnded)
      let downlink = self.downlinkQueue.clear(reason: .sessionEnded)
      self.addLocalDrops(route: uplink.removedEventIDs.count + downlink.removedEventIDs.count)
      let now = self.scheduler.now()
      if let cancelledHandoff {
        self.journalUplinkTerminals(
          [cancelledHandoff.queueID],
          disposition: .sessionEnded,
          now: now
        )
      }
      self.journalUplinkTerminals(uplink.removedEventIDs, disposition: .sessionEnded, now: now)
      self.publishSnapshot(now: self.scheduler.now())
      self.core.closeSession()
    }
  }

  func cancelAndWaitForCleanup() async {
    await handle.cancelAndWait()
  }

  private func receiveNegotiating(_ frame: WireFrame, receipt: UInt64) throws {
    let message = try codec.decode(frame: frame, phase: .negotiatingPolicy)
    guard message.type == .flowPolicyAccepted else {
      throw ViewerSessionFailure.terminal(.protocolViolation)
    }
    let accepted = try codec.decode(WireFlowPolicyAccepted.self, from: message)
    try acceptPolicy(accepted.policy, receipt: receipt)
  }

  private func receiveActive(
    _ frame: WireFrame,
    receipt: UInt64
  ) throws -> WireFrameDeliveryDecision {
    let message = try codec.decode(frame: frame, phase: .active)
    switch message.type {
    case .flowPolicyAccepted:
      let accepted = try codec.decode(WireFlowPolicyAccepted.self, from: message)
      try acceptPolicy(accepted.policy, receipt: receipt)
      return .consume
    case .event:
      let payload = try codec.decode(WireEventPayload.self, from: message)
      guard turnRecordCount + 1 <= 512 else { return .pause }
      try admitIncoming([payload.record], receipt: receipt)
      return .consume
    case .eventBatch:
      let payload = try codec.decode(WireEventBatchPayload.self, from: message)
      guard turnRecordCount + payload.records.count <= 512 else { return .pause }
      try admitIncoming(payload.records, receipt: receipt)
      return .consume
    case .eventDropSummary:
      guard turnSystemCount < 32 else { return .pause }
      try accountSystemMessage(receipt: receipt)
      let summary = try codec.decode(WireDropSummaryPayload.self, from: message)
      let previous = remoteDrops
      remoteDrops.add(
        overflow: summary.overflowDropped,
        expired: summary.expired,
        coalesced: summary.coalesced
      )
      remoteDroppedEvents = remoteDrops.total
      var samples: [ViewerDropJournalSample] = []
      if remoteDrops.overflow != previous.overflow {
        samples.append(.init(reason: .remoteOverflow, count: remoteDrops.overflow))
      }
      if remoteDrops.expired != previous.expired {
        samples.append(.init(reason: .remoteExpired, count: remoteDrops.expired))
      }
      if remoteDrops.coalesced != previous.coalesced {
        samples.append(.init(reason: .remoteCoalesced, count: remoteDrops.coalesced))
      }
      if !samples.isEmpty { dropJournal(samples, receipt) }
      return .consume
    case .ping:
      guard turnSystemCount < 32 else { return .pause }
      try accountSystemMessage(receipt: receipt)
      let ping = try codec.decode(WirePing.self, from: message)
      let pong = try codec.encode(WirePong(nonce: ping.nonce), phase: .active)
      try core.admitSessionSend(pong)
      return .consume
    case .disconnect:
      terminalCategory = .transportEnded
      throw ViewerSessionFailure.terminal(.transportEnded)
    default:
      throw ViewerSessionFailure.terminal(.protocolViolation)
    }
  }

  private func beginPolicyOffer(
    _ policy: ViewerRatePolicy,
    startedAt: UInt64
  ) throws {
    guard pendingOffer == nil else { return }
    let (deadline, overflow) = startedAt.addingReportingOverflow(Self.policyDeadlineNanoseconds)
    guard !overflow else { throw ViewerSessionFailure.terminal(.localAdmissionFailure) }
    let wirePolicy = try WireFlowPolicy(
      appUplinkEventsPerSecond: policy.appUplink,
      appDownlinkEventsPerSecond: policy.appDownlink
    )
    let frame = try codec.encode(
      WireFlowPolicyOffer(policy: wirePolicy),
      phase: state == .active ? .active : .negotiatingPolicy
    )
    try core.admitSessionSend(frame)
    pendingOffer = policy
    policyDeadline = deadline
    deadlineElapsed = false
    scheduleServiceWake(now: scheduler.now())
  }

  private func acceptPolicy(_ accepted: WireFlowPolicy, receipt: UInt64) throws {
    guard let offered = pendingOffer, let deadline = policyDeadline else {
      throw ViewerSessionFailure.terminal(.protocolViolation)
    }
    guard receipt < deadline else {
      throw ViewerSessionFailure.terminal(.policyTimeout)
    }
    guard accepted.appUplinkEventsPerSecond <= offered.appUplink,
      accepted.appDownlinkEventsPerSecond <= offered.appDownlink
    else { throw ViewerSessionFailure.terminal(.protocolViolation) }
    let effective = try ViewerRatePolicy(
      appUplink: accepted.appUplinkEventsPerSecond,
      appDownlink: accepted.appDownlinkEventsPerSecond
    )
    let uplinkRate = try EventRateLimit(eventsPerSecond: effective.appUplink)
    let downlinkRate = try EventRateLimit(eventsPerSecond: effective.appDownlink)
    ingressContractBucket = try EventTokenBucket(
      rate: uplinkRate,
      burstDurationSeconds: Self.businessEventBurstDurationSeconds,
      startNanoseconds: receipt
    )
    uplinkDeliveryBucket = try EventTokenBucket(
      rate: uplinkRate,
      burstDurationSeconds: Self.businessEventBurstDurationSeconds,
      startNanoseconds: receipt
    )
    downlinkSendBucket = try EventTokenBucket(
      rate: downlinkRate,
      burstDurationSeconds: Self.businessEventBurstDurationSeconds,
      startNanoseconds: receipt
    )
    let policyChanged = effectivePolicy != effective
    effectivePolicy = effective
    pendingOffer = nil
    policyDeadline = nil
    deadlineElapsed = false
    ownedSuffixReceipt = nil
    state = .active
    if policyChanged { policyJournal(effective, receipt) }
    flushLocalDropSummary()
    if desiredPolicy != offered {
      try beginPolicyOffer(desiredPolicy, startedAt: scheduler.now())
    }
    scheduleServiceWake(now: receipt)
  }

  private func policyTimedOut() {
    guard pendingOffer != nil, let deadline = policyDeadline,
      scheduler.now() >= deadline
    else { return }
    if let receipt = ownedSuffixReceipt, receipt < deadline {
      deadlineElapsed = true
      return
    }
    fail(.terminal(.policyTimeout))
  }

  private func admitIncoming(_ records: [WireEventRecord], receipt: UInt64) throws {
    guard !records.isEmpty, records.count <= codec.limits.maximumBatchEventCount,
      var plannedContract = ingressContractBucket
    else { throw ViewerSessionFailure.terminal(.activeWorkLimitExceeded) }
    do {
      try plannedContract.consume(records.count, atNanoseconds: receipt)
    } catch {
      throw ViewerSessionFailure.terminal(.activeWorkLimitExceeded)
    }
    var plannedSequence = inputSequence
    var plannedQueue = uplinkQueue
    var plannedJournalSequences = uplinkJournalSequences
    var plannedDrops = ViewerLocalDropCounts()
    var journalCommits: [(WireReceivedEvent, ViewerEventDisposition)] = []
    var journalTerminals: [(UInt64, ViewerEventDisposition)] = []
    for record in records {
      let envelope = record.envelope
      let queueID = EventID()
      guard envelope.source == EventEndpoint(role: .app, id: context.appHello.installationID),
        envelope.target
          == EventEndpoint(role: .viewer, id: context.negotiation.viewerInstallationID)
      else { throw ViewerSessionFailure.terminal(.protocolViolation) }
      try plannedSequence.validate(envelope)
      let received = try record.receiverEvent(receivedAtNanoseconds: receipt)
      let milliseconds = max(1, record.remainingTTLNanoseconds / 1_000_000)
      let pending = try PendingEvent(
        id: queueID,
        value: received,
        priority: envelope.priority,
        ttl: EventTTL(milliseconds: milliseconds, limits: codec.limits.eventValidationLimits),
        accountedByteCount: received.deterministicEncodedByteCount,
        enqueuedAtNanoseconds: receipt,
        expirationDeadlineNanoseconds: received.deadlineNanoseconds
      )
      let result = try plannedQueue.enqueue(pending, nowOnQueueClockNanoseconds: receipt)
      let wireSequence = envelope.sequence.rawValue
      plannedJournalSequences[queueID] = wireSequence
      let immediatelyExpired = result.expiredEventIDs.contains(queueID)
      let immediatelyDisplaced = result.overflowDroppedEventIDs.contains(queueID)
      let initialDisposition: ViewerEventDisposition =
        immediatelyExpired ? .expired : (immediatelyDisplaced ? .overflowDisplaced : .buffered)
      journalCommits.append((received, initialDisposition))
      for expiredID in result.expiredEventIDs where expiredID != queueID {
        if let sequence = plannedJournalSequences.removeValue(forKey: expiredID) {
          journalTerminals.append((sequence, .expired))
        }
      }
      for displacedID in result.overflowDroppedEventIDs where displacedID != queueID {
        if let sequence = plannedJournalSequences.removeValue(forKey: displacedID) {
          journalTerminals.append((sequence, .overflowDisplaced))
        }
      }
      if !result.isBuffered { plannedJournalSequences.removeValue(forKey: queueID) }
      plannedDrops.add(
        overflow: result.overflowDroppedEventIDs.count,
        expired: result.expiredEventIDs.count
      )
    }
    ingressContractBucket = plannedContract
    inputSequence = plannedSequence
    uplinkQueue = plannedQueue
    uplinkJournalSequences = plannedJournalSequences
    turnRecordCount += records.count
    receivedEvents = Self.saturatingAdd(receivedEvents, UInt64(records.count))
    ingressThisSecond = Self.saturatingAdd(ingressThisSecond, UInt64(records.count))
    addLocalDrops(plannedDrops)
    for (event, disposition) in journalCommits { uplinkJournal(event, disposition) }
    for (sequence, disposition) in journalTerminals {
      uplinkDispositionJournal(.appToViewer, sequence, disposition, receipt)
    }
    deliverUplink(now: receipt)
    scheduleServiceWake(now: receipt)
  }

  private func deliverUplink(now: UInt64) {
    guard var bucket = uplinkDeliveryBucket, uplinkHandoff.isAvailable else { return }
    do {
      let available = min(1, try bucket.availableWholeTokens(atNanoseconds: now))
      guard available > 0 else {
        uplinkDeliveryBucket = bucket
        return
      }
      var plannedQueue = uplinkQueue
      let drained = try plannedQueue.dequeue(
        maximumCount: available,
        maximumBytes: Self.uplinkQueueMaximumBytes,
        nowOnQueueClockNanoseconds: now
      )
      guard !drained.events.isEmpty else {
        uplinkQueue = plannedQueue
        addLocalDrops(expired: drained.expiredEventIDs.count)
        journalUplinkTerminals(drained.expiredEventIDs, disposition: .expired, now: now)
        return
      }
      try bucket.consume(drained.events.count, atNanoseconds: now)
      let queueID = drained.events[0].id
      let value = drained.events[0].value
      guard
        uplinkHandoff.offer(
          queueID: queueID,
          value,
          sink: uplinkSink,
          accepted: { [uplinkDispositionJournal] event in
            uplinkDispositionJournal(
              .appToViewer,
              event.envelope.sequence.rawValue,
              .consumerAccepted,
              event.receivedAtNanoseconds
            )
          },
          completion: { [weak self] in
            guard let self else { return }
            self.core.performSessionOperation { [weak self] in
              guard let self else { return }
              self.uplinkJournalSequences.removeValue(forKey: queueID)
              let now = self.scheduler.now()
              self.scheduleServiceWake(now: now)
              self.publishSnapshot(now: now)
            }
          }
        )
      else { return }
      uplinkQueue = plannedQueue
      uplinkDeliveryBucket = bucket
      addLocalDrops(expired: drained.expiredEventIDs.count)
      journalUplinkTerminals(drained.expiredEventIDs, disposition: .expired, now: now)
      deliveredEvents = Self.saturatingAdd(deliveredEvents, UInt64(drained.events.count))
    } catch {
      fail(.terminal(.activeWorkLimitExceeded))
    }
  }

  private func scheduleServiceWake(now: UInt64) {
    let deadline = nextServiceDeadline(now: now)
    if deadline == serviceWakeDeadline, serviceWake != nil { return }
    serviceWake?.cancel()
    serviceWake = nil
    serviceWakeDeadline = deadline
    guard let deadline else { return }
    serviceWakeGeneration = serviceWakeGeneration == UInt64.max ? 1 : serviceWakeGeneration + 1
    let generation = serviceWakeGeneration
    serviceWake = Task { [weak self, scheduler] in
      do { try await scheduler.sleep(untilNanoseconds: deadline) } catch { return }
      guard !Task.isCancelled, let self else { return }
      self.core.performSessionOperation { [weak self] in
        guard let self, self.serviceWakeGeneration == generation else { return }
        self.serviceWake = nil
        self.serviceWakeDeadline = nil
        self.serviceSession(now: self.scheduler.now())
      }
    }
  }

  private func cancelServiceWake() {
    serviceWakeGeneration = serviceWakeGeneration == UInt64.max ? 1 : serviceWakeGeneration + 1
    serviceWake?.cancel()
    serviceWake = nil
    serviceWakeDeadline = nil
  }

  private func serviceSession(now: UInt64) {
    if !deadlineElapsed, let deadline = policyDeadline, now >= deadline {
      policyTimedOut()
      guard state != .disconnecting else { return }
    }
    // A retained complete frame belongs to its original receipt-time domain. Deadline
    // arbitration may record elapsed state, but queue, token, batch, and throughput clocks
    // must not advance until that suffix drains at the preserved receipt sample.
    guard ownedSuffixReceipt == nil else { return }
    guard state == .active else {
      scheduleServiceWake(now: now)
      return
    }
    serviceQueueExpirations(now: now)
    guard state == .active else { return }
    deliverUplink(now: now)
    drainDownlink(now: now)
    flushLocalDropSummary()
    publishSnapshot(now: now)
    scheduleServiceWake(now: now)
  }

  private func nextServiceDeadline(now: UInt64) -> UInt64? {
    guard state == .negotiating || state == .active else { return nil }
    var candidates: [UInt64] = []
    if !deadlineElapsed, let policyDeadline { candidates.append(policyDeadline) }
    guard state == .active else { return candidates.min() }

    appendQueueExpirationDeadline(for: uplinkQueue, now: now, to: &candidates)
    appendQueueExpirationDeadline(for: downlinkQueue, now: now, to: &candidates)

    if uplinkHandoff.isAvailable, uplinkQueue.eventCount > 0,
      var bucket = uplinkDeliveryBucket
    {
      if (try? bucket.availableWholeTokens(atNanoseconds: now)) ?? 0 > 0 {
        candidates.append(now)
      } else if let deadline = Self.nextTokenDeadline(bucket: &bucket, now: now) {
        candidates.append(deadline)
      }
    }

    if !downlinkMailboxBlocked, downlinkQueue.eventCount > 0,
      var bucket = downlinkSendBucket, bucket.rate.eventsPerSecond > 0
    {
      let batchDeadline = batchScheduler.nextFlushDeadlineNanoseconds
      if batchDeadline > now {
        candidates.append(batchDeadline)
      } else if (try? bucket.availableWholeTokens(atNanoseconds: now)) ?? 0 > 0 {
        candidates.append(now)
      } else if let deadline = Self.nextTokenDeadline(bucket: &bucket, now: now) {
        candidates.append(deadline)
      }
    }
    return candidates.min()
  }

  private func appendQueueExpirationDeadline<Value: Sendable>(
    for queue: BoundedEventQueue<Value>,
    now: UInt64,
    to candidates: inout [UInt64]
  ) {
    guard queue.eventCount > 0,
      let observation = try? queue.previewActiveSchedule(
        nowOnQueueClockNanoseconds: now,
        maximumServiceUnits: Self.serviceSlice
      )
    else { return }
    if observation.dueWorkRemains {
      candidates.append(now)
    } else if let deadline = observation.nextExpirationDeadlineNanoseconds {
      candidates.append(deadline)
    }
  }

  private func serviceQueueExpirations(now: UInt64) {
    do {
      let uplink = try uplinkQueue.observeActiveSchedule(
        nowOnQueueClockNanoseconds: now,
        maximumServiceUnits: Self.serviceSlice,
        authorizeExpiration: { _, commit in
          commit()
          return true
        }
      )
      let downlink = try downlinkQueue.observeActiveSchedule(
        nowOnQueueClockNanoseconds: now,
        maximumServiceUnits: Self.serviceSlice,
        authorizeExpiration: { _, commit in
          commit()
          return true
        }
      )
      addLocalDrops(
        expired: uplink.expiredEventIDs.count + downlink.expiredEventIDs.count
      )
      journalUplinkTerminals(uplink.expiredEventIDs, disposition: .expired, now: now)
    } catch {
      fail(.terminal(.localAdmissionFailure))
    }
  }

  private func drainDownlink(now: UInt64) {
    guard state == .active, var bucket = downlinkSendBucket else { return }
    do {
      var plannedQueue = downlinkQueue
      var plannedScheduler = batchScheduler
      guard
        let attempt = try plannedScheduler.drainIfDue(
          queue: &plannedQueue,
          tokenBucket: &bucket,
          nowNanoseconds: now
        )
      else {
        return
      }
      guard let batch = attempt.batch else {
        return
      }
      var plannedSequence = outputSequence
      var records: [WireEventRecord] = []
      var journalEvents: [ViewerDownlinkJournalEvent] = []
      records.reserveCapacity(batch.events.count)
      journalEvents.reserveCapacity(batch.events.count)
      for pending in batch.events {
        let sequence = try plannedSequence.allocate()
        let envelope = try EventEnvelope(
          id: pending.id,
          type: pending.value.type,
          content: pending.value.content,
          createdAt: Self.canonicalCreatedAt(Date()),
          monotonicTimestampNanoseconds: now,
          source: EventEndpoint(role: .viewer, id: context.negotiation.viewerInstallationID),
          target: EventEndpoint(role: .app, id: context.appHello.installationID),
          direction: .viewerToApp,
          sessionEpoch: sessionEpoch,
          sequence: sequence,
          priority: pending.value.priority,
          ttl: pending.value.ttl,
          causality: pending.value.causality,
          limits: codec.limits.eventValidationLimits
        )
        let record = try WireEventRecord(envelope: envelope, nowOnOriginClockNanoseconds: now)
        records.append(record)
        journalEvents.append(
          ViewerDownlinkJournalEvent(
            envelope: envelope,
            deterministicEncodedByteCount: try record.deterministicEncodedByteCount(),
            canonicalContentData: record.canonicalContentData
          )
        )
      }
      let data: Data
      if records.count == 1 {
        data = try codec.encode(WireEventPayload(record: records[0]), phase: .active)
      } else {
        data = try codec.encode(
          WireEventBatchPayload(records: records, limits: codec.limits),
          phase: .active
        )
      }
      guard
        core.canAdmitSessionSend(
          byteCount: data.count,
          reservingPendingSendCount: Self.controlReservedCount,
          reservingPendingSendBytes: Self.controlReservedBytes
        )
      else {
        downlinkMailboxBlocked = true
        return
      }
      try core.admitSessionSend(
        data,
        reservingPendingSendCount: Self.controlReservedCount,
        reservingPendingSendBytes: Self.controlReservedBytes
      )
      downlinkQueue = plannedQueue
      batchScheduler = plannedScheduler
      downlinkSendBucket = bucket
      outputSequence = plannedSequence
      downlinkMailboxBlocked = false
      sentEvents = Self.saturatingAdd(sentEvents, UInt64(records.count))
      rollThroughputWindow(now: now)
      egressThisSecond = Self.saturatingAdd(egressThisSecond, UInt64(records.count))
      downlinkJournal(journalEvents, now)
      publishSnapshot(now: now)
    } catch let error as SecureTransportError where error.code == .backpressure {
      downlinkMailboxBlocked = true
    } catch {
      fail(.terminal(.localAdmissionFailure))
    }
  }

  private func accountSystemMessage(receipt: UInt64) throws {
    do {
      try systemBucket.consume(1, atNanoseconds: receipt)
    } catch {
      throw ViewerSessionFailure.terminal(.activeWorkLimitExceeded)
    }
    turnSystemCount += 1
  }

  private func journalUplinkTerminals(
    _ eventIDs: [EventID],
    disposition: ViewerEventDisposition,
    now: UInt64
  ) {
    for eventID in eventIDs {
      guard let sequence = uplinkJournalSequences.removeValue(forKey: eventID) else { continue }
      uplinkDispositionJournal(.appToViewer, sequence, disposition, now)
    }
  }

  private func fail(_ failure: ViewerSessionFailure) {
    guard case .terminal(let category) = failure else { return }
    guard terminalCategory == nil else { return }
    terminalCategory = category
    state = .disconnecting
    cancelServiceWake()
    let cancelledHandoff = uplinkHandoff.cancel()
    let uplink = uplinkQueue.clear(reason: .sessionEnded)
    let downlink = downlinkQueue.clear(reason: .sessionEnded)
    addLocalDrops(route: uplink.removedEventIDs.count + downlink.removedEventIDs.count)
    if let cancelledHandoff {
      journalUplinkTerminals(
        [cancelledHandoff.queueID],
        disposition: .sessionEnded,
        now: scheduler.now()
      )
    }
    journalUplinkTerminals(uplink.removedEventIDs, disposition: .sessionEnded, now: scheduler.now())
    localDropSummaryInFlight = false
    publishSnapshot(now: scheduler.now())
    core.closeSession()
  }

  private func completeTerminal(_ category: ViewerSessionTerminalCategory) {
    guard !terminalNotified else { return }
    terminalNotified = true
    terminalCategory = terminalCategory ?? category
    state = .disconnecting
    cancelServiceWake()
    let cancelledHandoff = uplinkHandoff.cancel()
    let uplink = uplinkQueue.clear(reason: .sessionEnded)
    let downlink = downlinkQueue.clear(reason: .sessionEnded)
    addLocalDrops(route: uplink.removedEventIDs.count + downlink.removedEventIDs.count)
    if let cancelledHandoff {
      journalUplinkTerminals(
        [cancelledHandoff.queueID],
        disposition: .sessionEnded,
        now: scheduler.now()
      )
    }
    journalUplinkTerminals(uplink.removedEventIDs, disposition: .sessionEnded, now: scheduler.now())
    localDropSummaryInFlight = false
    onTerminal(connectionID, terminalCategory!)
  }

  private func publishSnapshot(now: UInt64) {
    rollThroughputWindow(now: now)
    onSnapshot(
      ViewerSessionSnapshot(
        id: connectionID,
        connectionID: connectionID,
        route: route,
        displayName: context.appHello.displayName ?? context.appHello.applicationIdentifier
          ?? "Unnamed App",
        applicationVersion: context.appHello.applicationVersion,
        installationAlias: Self.installationAlias(context.appHello.installationID),
        nickname: nicknameAtAttachment,
        state: state,
        requestedPolicy: requestedPolicy,
        effectivePolicy: effectivePolicy,
        uplinkCount: uplinkQueue.eventCount,
        uplinkBytes: uplinkQueue.accountedByteCount,
        uplinkOldestWaitNanoseconds: try? uplinkQueue.oldestWaitNanoseconds(
          atNanoseconds: now
        ),
        downlinkCount: downlinkQueue.eventCount,
        downlinkBytes: downlinkQueue.accountedByteCount,
        downlinkOldestWaitNanoseconds: try? downlinkQueue.oldestWaitNanoseconds(
          atNanoseconds: now
        ),
        receivedEvents: receivedEvents,
        deliveredEvents: deliveredEvents,
        sentEvents: sentEvents,
        droppedEvents: localDrops.total,
        overflowDroppedEvents: localDrops.overflow,
        expiredEvents: localDrops.expired,
        coalescedEvents: localDrops.coalesced,
        routeDroppedEvents: localDrops.route,
        remoteDroppedEvents: remoteDroppedEvents,
        ingressEventsPerSecond: ingressThisSecond,
        egressEventsPerSecond: egressThisSecond,
        terminalCategory: terminalCategory
      )
    )
  }

  private func rollThroughputWindow(now: UInt64) {
    let second = now / 1_000_000_000
    guard second > throughputSecond else { return }
    throughputSecond = second
    ingressThisSecond = 0
    egressThisSecond = 0
  }

  private func addLocalDrops(
    overflow: Int = 0,
    expired: Int = 0,
    coalesced: Int = 0,
    route: Int = 0
  ) {
    var added = ViewerLocalDropCounts()
    added.add(
      overflow: overflow,
      expired: expired,
      coalesced: coalesced,
      route: route
    )
    addLocalDrops(added)
  }

  private func addLocalDrops(_ added: ViewerLocalDropCounts) {
    guard added.total > 0 else { return }
    let previous = localDrops
    localDrops.merge(added)
    pendingLocalDropSummary.merge(added)
    var samples: [ViewerDropJournalSample] = []
    if localDrops.overflow != previous.overflow {
      samples.append(.init(reason: .localOverflow, count: localDrops.overflow))
    }
    if localDrops.expired != previous.expired {
      samples.append(.init(reason: .localExpired, count: localDrops.expired))
    }
    if localDrops.coalesced != previous.coalesced {
      samples.append(.init(reason: .localCoalesced, count: localDrops.coalesced))
    }
    if localDrops.route != previous.route {
      samples.append(.init(reason: .localRoute, count: localDrops.route))
    }
    if !samples.isEmpty { dropJournal(samples, scheduler.now()) }
    flushLocalDropSummary()
  }

  private func flushLocalDropSummary() {
    guard state == .active, pendingLocalDropSummary.total > 0, !localDropSummaryInFlight else {
      return
    }
    do {
      let frame = try codec.encode(
        WireDropSummaryPayload(
          overflowDropped: Self.saturatingAdd(
            pendingLocalDropSummary.overflow,
            pendingLocalDropSummary.route
          ),
          expired: pendingLocalDropSummary.expired,
          coalesced: pendingLocalDropSummary.coalesced
        ),
        phase: .active
      )
      guard
        core.canAdmitSessionSend(
          byteCount: frame.count,
          reservingPendingSendCount: Self.controlReservedCount,
          reservingPendingSendBytes: Self.controlReservedBytes
        )
      else { return }
      try core.admitSessionSend(
        frame,
        reservingPendingSendCount: Self.controlReservedCount,
        reservingPendingSendBytes: Self.controlReservedBytes,
        completionKind: .localDropSummary
      )
      pendingLocalDropSummary.clear()
      localDropSummaryInFlight = true
    } catch {
      // A coalesced summary remains pending until mailbox progress or later activity.
    }
  }

  private static func installationAlias(_ id: EndpointID) -> String {
    let suffix = String(id.rawValue.suffix(8))
    return "App \(suffix)"
  }

  private static func canonicalCreatedAt(_ date: Date) -> Date {
    let interval = date.timeIntervalSince1970
    guard interval.isFinite else { return date }
    let wholeSeconds = floor(interval)
    let milliseconds = floor((interval - wholeSeconds) * 1_000)
    return Date(timeIntervalSince1970: wholeSeconds + milliseconds / 1_000)
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : value
  }

  private static func deadline(after delay: UInt64, from now: UInt64) -> UInt64 {
    let (deadline, overflow) = now.addingReportingOverflow(delay)
    return overflow ? UInt64.max : deadline
  }

  private static func nextTokenDeadline(
    bucket: inout EventTokenBucket,
    now: UInt64
  ) -> UInt64? {
    do {
      guard let delay = try bucket.delayUntilNextTokenNanoseconds(atNanoseconds: now) else {
        return nil
      }
      return deadline(after: delay, from: now)
    } catch {
      return nil
    }
  }

  var description: String { "ViewerDeviceSession(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

final class ViewerUplinkHandoff: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  struct Item: Sendable, CustomReflectable, CustomStringConvertible,
    CustomDebugStringConvertible
  {
    let queueID: EventID
    let event: WireReceivedEvent

    var description: String { "ViewerUplinkHandoff.Item(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
  }

  private static let workerQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.nearwire.viewer.uplink-delivery"
    queue.maxConcurrentOperationCount = ViewerMultiDeviceSessionManager.maximumSessions
    queue.qualityOfService = .userInitiated
    return queue
  }()

  private let lock = NSLock()
  private var inFlight = false
  private var cancelled = false
  private var operation: BlockOperation?
  private var payload: ViewerUplinkPayload?

  var isAvailable: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !cancelled && !inFlight
  }

  func offer(
    queueID: EventID,
    _ event: WireReceivedEvent,
    sink: @escaping @Sendable (WireReceivedEvent) -> Void,
    accepted: @escaping @Sendable (WireReceivedEvent) -> Void,
    completion: @escaping @Sendable () -> Void
  ) -> Bool {
    lock.lock()
    guard !cancelled, !inFlight else {
      lock.unlock()
      return false
    }
    let payload = ViewerUplinkPayload(Item(queueID: queueID, event: event))
    let operation = BlockOperation { [weak self, payload] in
      guard let item = payload.take() else { return }
      // The current value transfers to the consumer here. No queued batch remains retained.
      accepted(item.event)
      sink(item.event)
      self?.finish(completion: completion)
    }
    inFlight = true
    self.payload = payload
    self.operation = operation
    lock.unlock()
    Self.workerQueue.addOperation(operation)
    return true
  }

  func cancel() -> Item? {
    lock.lock()
    cancelled = true
    inFlight = false
    let operation = self.operation
    let payload = self.payload
    self.operation = nil
    self.payload = nil
    lock.unlock()
    let event = payload?.take()
    operation?.cancel()
    return event
  }

  private func finish(completion: @escaping @Sendable () -> Void) {
    lock.lock()
    inFlight = false
    operation = nil
    payload = nil
    let shouldComplete = !cancelled
    lock.unlock()
    if shouldComplete { completion() }
  }

  var description: String { "ViewerUplinkHandoff(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

final class ViewerUplinkPayload: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let lock = NSLock()
  private var item: ViewerUplinkHandoff.Item?

  init(_ item: ViewerUplinkHandoff.Item) { self.item = item }

  func take() -> ViewerUplinkHandoff.Item? {
    lock.lock()
    let item = self.item
    self.item = nil
    lock.unlock()
    return item
  }

  var description: String { "ViewerUplinkPayload(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }

}
