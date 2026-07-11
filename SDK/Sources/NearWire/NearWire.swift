import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireInternal) import NearWireFlowControl
  @_spi(NearWireInternal) import NearWireTransport
#endif

struct SDKQueuedEvent: Equatable, Sendable {
  let draft: EventDraft
  let createdAt: Date
  let replyAffinity: SDKReplyAffinity?
}

struct SDKReplyAffinity: Equatable, Sendable {
  let sessionEpoch: UUID
  let viewerID: String
  let appID: String
}

struct SDKSessionRoute: Equatable, Sendable {
  let sessionEpoch: UUID
  let viewerID: String
  let appID: String
}

struct SDKOutboundDrainResult: Equatable, Sendable {
  let acceptedEventIDs: [EventID]
  let rejectedEventIDs: [EventID]
  let notAttemptedEventIDs: [EventID]
  let routingDroppedEventIDs: [EventID]
  let expiredEventIDs: [EventID]
}

enum SDKOutboundAdmissionDecision: Equatable, Sendable {
  case accepted
  case transportRejected
  case notAttempted
}

private enum SDKEventNamespace {
  case user
  case platform
}

struct SDKRuntimeDependencies: Sendable {
  let wallClock: @Sendable () -> Date
  let monotonicClock: @Sendable () -> UInt64
  let identifierGenerator: @Sendable () -> UUID

  static let live = SDKRuntimeDependencies(
    wallClock: { Date() },
    monotonicClock: { DispatchTime.now().uptimeNanoseconds },
    identifierGenerator: { UUID() }
  )
}

/// The instance-based NearWire SDK facade.
///
/// Construction performs no discovery, network, timer, persistence, Keychain, or UI work.
public actor NearWire {
  public nonisolated let configuration: NearWireConfiguration

  public nonisolated var states: AsyncStream<NearWireState> {
    stateHub.makeStream()
  }

  public nonisolated var events: AsyncThrowingStream<NearWireEvent, Error> {
    eventHub.makeStream()
  }

  public var currentState: NearWireState { state }

  internal nonisolated var streamSubscriberCounts: (states: Int, events: Int) {
    (stateHub.subscriberCount, eventHub.subscriberCount)
  }

  private nonisolated let stateHub: StateStreamHub
  private nonisolated let eventHub: EventStreamHub
  private let dependencies: SDKRuntimeDependencies
  private let instanceIdentifier: UUID
  private var state: NearWireState = .idle
  private var queue: BoundedEventQueue<SDKQueuedEvent>
  private var liveEventIDs = Set<EventID>()
  private var submittedCount: UInt64 = 0
  private var transportAcceptedCount: UInt64 = 0
  private var transportAdmissionRejectedCount: UInt64 = 0
  private var routingDroppedCount: UInt64 = 0

  public init(configuration: NearWireConfiguration = .default) {
    self.configuration = configuration
    stateHub = StateStreamHub(initial: .idle)
    eventHub = EventStreamHub(capacity: configuration.eventStreamBufferCapacity)
    dependencies = .live
    instanceIdentifier = UUID()
    queue = BoundedEventQueue(limits: SDKValidation.queueLimits(configuration.buffer))
  }

  internal init(
    configuration: NearWireConfiguration = .default,
    dependencies: SDKRuntimeDependencies,
    instanceIdentifier: UUID = UUID()
  ) {
    self.configuration = configuration
    stateHub = StateStreamHub(initial: .idle)
    eventHub = EventStreamHub(capacity: configuration.eventStreamBufferCapacity)
    self.dependencies = dependencies
    self.instanceIdentifier = instanceIdentifier
    queue = BoundedEventQueue(limits: SDKValidation.queueLimits(configuration.buffer))
  }

  deinit {
    stateHub.finishWithoutChangingState()
    eventHub.finish()
  }

  /// Encodes and admits an App-to-Viewer event to this instance's bounded memory queue.
  ///
  /// A successful result describes local queue effects only. It does not indicate delivery.
  public func send<Content: Encodable & Sendable>(
    type: String,
    content: Content,
    policy: NearWireSendPolicy = .normal,
    options: NearWireEventOptions = NearWireEventOptions()
  ) throws -> NearWireSendResult {
    try ensureActive()
    return try enqueue(
      type: type,
      content: content,
      policy: policy,
      options: options,
      causality: EventCausality(),
      namespace: .user,
      replyAffinity: nil
    )
  }

  /// Internal framework bridge for built-in `nearwire.*` events.
  @_spi(NearWireBuiltins)
  public func sendPlatformEvent<Content: Encodable & Sendable>(
    type: String,
    content: Content,
    policy: NearWireSendPolicy = .normal,
    options: NearWireEventOptions = NearWireEventOptions()
  ) throws -> NearWireSendResult {
    try ensureActive()
    return try enqueue(
      type: type,
      content: content,
      policy: policy,
      options: options,
      causality: EventCausality(),
      namespace: .platform,
      replyAffinity: nil
    )
  }

  /// Enqueues a causal reply to an incoming event.
  public func reply<Content: Encodable & Sendable>(
    to event: NearWireEvent,
    type: String,
    content: Content,
    policy: NearWireSendPolicy = .normal,
    options: NearWireEventOptions = NearWireEventOptions()
  ) throws -> NearWireSendResult {
    try ensureActive()
    guard event.originInstanceID == instanceIdentifier,
      event.direction == .viewerToApp,
      let session = event.session
    else {
      throw NearWireError(
        code: .invalidReply,
        field: "event",
        message: "Replies require an incoming event from this NearWire instance."
      )
    }
    let sourceID = try makeCoreEventID(event.id)
    return try enqueue(
      type: type,
      content: content,
      policy: policy,
      options: options,
      causality: EventCausality(correlationID: sourceID, replyTo: sourceID),
      namespace: .user,
      replyAffinity: SDKReplyAffinity(
        sessionEpoch: session.epoch,
        viewerID: session.sourceID,
        appID: session.targetID
      )
    )
  }

  /// Returns an expiration-aware snapshot of this instance's offline uplink buffer.
  public func bufferDiagnostics() throws -> NearWireBufferDiagnostics {
    let snapshot: EventQueueSnapshot
    do {
      snapshot = try queue.snapshot(
        nowOnQueueClockNanoseconds: dependencies.monotonicClock()
      )
    } catch {
      throw bufferFailure()
    }
    removeLiveEventIDs(snapshot.expiredEventIDs)
    let statistics = snapshot.statistics
    return NearWireBufferDiagnostics(
      eventCount: snapshot.eventCount,
      accountedByteCount: snapshot.accountedByteCount,
      oldestWait: snapshot.oldestWaitNanoseconds.map { .nanoseconds(Int64(clamping: $0)) },
      expiredEventIDs: snapshot.expiredEventIDs.map(\.sdkUUID),
      statistics: NearWireBufferStatistics(
        submitted: submittedCount,
        transportAccepted: transportAcceptedCount,
        transportAdmissionRejected: transportAdmissionRejectedCount,
        overflowDropped: statistics.overflowDropped,
        expired: statistics.expired,
        coalesced: statistics.coalesced,
        explicitlyCleared: statistics.clearedOwnerRequested,
        routingDropped: routingDroppedCount
      )
    )
  }

  /// Clears all App-originated events currently retained in memory.
  @discardableResult
  public func clearBufferedEvents() -> NearWireClearResult {
    let result = queue.clear(reason: .ownerRequested)
    removeLiveEventIDs(result.removedEventIDs)
    return NearWireClearResult(removedEventIDs: result.removedEventIDs.map(\.sdkUUID))
  }

  /// Permanently ends this instance and releases its in-memory work and observers.
  public func shutdown() {
    guard state != .shutdown else { return }
    _ = queue.clear(reason: .ownerRequested)
    liveEventIDs.removeAll(keepingCapacity: false)
    state = .shutdown
    stateHub.finish(with: .shutdown)
    eventHub.finish()
  }

  private func enqueue<Content: Encodable & Sendable>(
    type: String,
    content: Content,
    policy: NearWireSendPolicy,
    options: NearWireEventOptions,
    causality: EventCausality,
    namespace: SDKEventNamespace,
    replyAffinity: SDKReplyAffinity?
  ) throws -> NearWireSendResult {
    let coreType: EventType
    do {
      switch namespace {
      case .user:
        coreType = try .user(type)
      case .platform:
        coreType = try .platform(type)
      }
    } catch {
      let message: String
      switch namespace {
      case .user:
        message = "Event type must be a valid non-reserved user event type."
      case .platform:
        message = "Built-in event type must use the reserved nearwire namespace."
      }
      throw NearWireError(
        code: .invalidEventType,
        field: "type",
        message: message
      )
    }

    let coreContent = try SDKContentConversion.encode(content)
    let ttl = try SDKValidation.coreTTL(options.ttl ?? configuration.buffer.defaultTTL)
    let corePolicy = try makeCorePolicy(policy)
    let draft: EventDraft
    do {
      draft = try EventDraft(
        type: coreType,
        content: coreContent,
        priority: options.priority.coreValue,
        ttl: ttl,
        causality: causality
      )
    } catch {
      throw NearWireError(
        code: .invalidContent,
        field: "content",
        message: "Event content does not satisfy the active validation limits."
      )
    }

    let accountedByteCount = try accountedBytes(for: draft)
    guard accountedByteCount <= configuration.buffer.maximumEventBytes else {
      throw NearWireError(
        code: .eventTooLarge,
        field: "content",
        message: "The accounted event exceeds the configured single-event buffer limit."
      )
    }

    let (identifier, coreID) = try makeUniqueEventIdentifier()
    let monotonicNow = dependencies.monotonicClock()
    let wallNow = dependencies.wallClock()
    guard wallNow.timeIntervalSinceReferenceDate.isFinite else {
      throw bufferFailure()
    }

    let queued = SDKQueuedEvent(
      draft: draft,
      createdAt: wallNow,
      replyAffinity: replyAffinity
    )
    let pending: PendingEvent<SDKQueuedEvent>
    do {
      pending = try PendingEvent(
        id: coreID,
        value: queued,
        priority: draft.priority,
        ttl: draft.ttl,
        policy: corePolicy,
        accountedByteCount: accountedByteCount,
        enqueuedAtNanoseconds: monotonicNow
      )
    } catch {
      throw bufferFailure()
    }

    let result: EventEnqueueResult
    do {
      result = try queue.enqueue(
        pending,
        nowOnQueueClockNanoseconds: monotonicNow
      )
    } catch {
      throw bufferFailure()
    }

    removeLiveEventIDs(
      result.expiredEventIDs + result.overflowDroppedEventIDs
        + [result.coalescedEventID].compactMap { $0 }
    )
    if result.isBuffered {
      liveEventIDs.insert(coreID)
    }
    submittedCount = sdkSaturatedSum(submittedCount, 1)
    return NearWireSendResult(
      eventID: identifier,
      enqueuedAt: wallNow,
      isBuffered: result.isBuffered,
      coalescedEventID: result.coalescedEventID?.sdkUUID,
      expiredEventIDs: result.expiredEventIDs.map(\.sdkUUID),
      overflowDroppedEventIDs: result.overflowDroppedEventIDs.map(\.sdkUUID)
    )
  }

  private func makeCorePolicy(_ policy: NearWireSendPolicy) throws -> EventQueuePolicy {
    switch policy {
    case .normal:
      return .normal
    case .keepLatest(let key):
      do {
        return .keepLatest(try KeepLatestKey(key))
      } catch {
        throw NearWireError(
          code: .invalidEventOptions,
          field: "policy.key",
          message: "Keep-latest key must use 1 through 128 UTF-8 bytes without control characters."
        )
      }
    }
  }

  private func accountedBytes(for draft: EventDraft) throws -> Int {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return try encoder.encode(draft).count
    } catch {
      throw NearWireError(
        code: .contentEncodingFailed,
        field: "content",
        message: "Event content could not be encoded for buffer accounting."
      )
    }
  }

  private func makeCoreEventID(_ identifier: UUID) throws -> EventID {
    do {
      return try EventID(rawValue: identifier.nearWireCanonicalString)
    } catch {
      throw bufferFailure()
    }
  }

  private func makeUniqueEventIdentifier() throws -> (UUID, EventID) {
    for _ in 0..<8 {
      let identifier = dependencies.identifierGenerator()
      let coreID = try makeCoreEventID(identifier)
      if !liveEventIDs.contains(coreID) {
        return (identifier, coreID)
      }
    }
    throw NearWireError(
      code: .identifierGenerationFailed,
      field: "eventID",
      message: "A unique event identifier could not be generated."
    )
  }

  private func ensureActive() throws {
    guard state != .shutdown else { throw NearWireError.shutdown }
  }

  private func removeLiveEventIDs(_ eventIDs: [EventID]) {
    for eventID in eventIDs {
      liveEventIDs.remove(eventID)
    }
  }

  private func bufferFailure() -> NearWireError {
    NearWireError(
      code: .bufferOperationFailed,
      message: "The in-memory event buffer could not complete the operation."
    )
  }
}

extension NearWire {
  func updateSessionState(_ newState: NearWireState) {
    guard state != .shutdown, newState != .shutdown, newState != state else { return }
    state = newState
    stateHub.publish(newState)
  }

  @discardableResult
  func publishIncoming(_ envelope: EventEnvelope) -> Bool {
    guard state != .shutdown,
      envelope.direction == .viewerToApp,
      let identifier = UUID(uuidString: envelope.id.rawValue),
      let epoch = UUID(uuidString: envelope.sessionEpoch.rawValue)
    else {
      return false
    }
    let event = NearWireEvent(
      id: identifier,
      type: envelope.type.rawValue,
      content: NearWireEventContent(coreValue: envelope.content),
      createdAt: envelope.createdAt,
      priority: NearWireEventPriority(coreValue: envelope.priority),
      direction: NearWireEventDirection(coreValue: envelope.direction),
      correlationID: envelope.causality.correlationID.flatMap {
        UUID(uuidString: $0.rawValue)
      },
      replyToEventID: envelope.causality.replyTo.flatMap {
        UUID(uuidString: $0.rawValue)
      },
      session: NearWireSessionMetadata(
        epoch: epoch,
        sequence: envelope.sequence.rawValue,
        sourceID: envelope.source.id.rawValue,
        targetID: envelope.target.id.rawValue,
        schemaVersion: envelope.schemaVersion.rawValue
      ),
      originInstanceID: instanceIdentifier
    )
    eventHub.publish(event)
    return true
  }

  func drainOutbound(
    for route: SDKSessionRoute,
    maximumCount: Int,
    maximumBytes: Int,
    admitting: (PendingEvent<SDKQueuedEvent>) -> SDKOutboundAdmissionDecision
  ) throws -> SDKOutboundDrainResult {
    guard state != .shutdown else {
      return SDKOutboundDrainResult(
        acceptedEventIDs: [],
        rejectedEventIDs: [],
        notAttemptedEventIDs: [],
        routingDroppedEventIDs: [],
        expiredEventIDs: []
      )
    }
    let now = dependencies.monotonicClock()
    var accepted: [EventID] = []
    var rejected: [EventID] = []
    var notAttempted: [EventID] = []
    var routingDropped: [EventID] = []
    let result = try queue.offer(
      maximumCount: maximumCount,
      maximumBytes: maximumBytes,
      nowOnQueueClockNanoseconds: now,
      preflight: { event in
        if let affinity = event.value.replyAffinity,
          affinity
            != SDKReplyAffinity(
              sessionEpoch: route.sessionEpoch,
              viewerID: route.viewerID,
              appID: route.appID
            )
        {
          routingDropped.append(event.id)
          liveEventIDs.remove(event.id)
          routingDroppedCount = sdkSaturatedSum(routingDroppedCount, 1)
          return .removeWithoutAccounting
        }
        return .eligible
      },
      decision: { event in
        switch admitting(event) {
        case .transportRejected:
          rejected.append(event.id)
          transportAdmissionRejectedCount = sdkSaturatedSum(
            transportAdmissionRejectedCount,
            1
          )
          return .stop
        case .notAttempted:
          notAttempted.append(event.id)
          return .stop
        case .accepted:
          accepted.append(event.id)
          liveEventIDs.remove(event.id)
          transportAcceptedCount = sdkSaturatedSum(transportAcceptedCount, 1)
          return .remove
        }
      }
    )
    removeLiveEventIDs(result.expiredEventIDs)

    return SDKOutboundDrainResult(
      acceptedEventIDs: accepted,
      rejectedEventIDs: rejected,
      notAttemptedEventIDs: notAttempted,
      routingDroppedEventIDs: routingDropped,
      expiredEventIDs: result.expiredEventIDs
    )
  }

  func drainOutbound(
    for route: SDKSessionRoute,
    maximumCount: Int,
    maximumBytes: Int,
    channel: SecureByteChannel,
    encode: (PendingEvent<SDKQueuedEvent>) -> Data?
  ) throws -> SDKOutboundDrainResult {
    try drainOutbound(
      for: route,
      maximumCount: maximumCount,
      maximumBytes: maximumBytes
    ) { event in
      guard let bytes = encode(event) else { return .notAttempted }
      do {
        try channel.admitSend(bytes)
        return .accepted
      } catch {
        return .transportRejected
      }
    }
  }
}

private func sdkSaturatedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
  let (result, overflow) = lhs.addingReportingOverflow(rhs)
  return overflow ? .max : result
}
