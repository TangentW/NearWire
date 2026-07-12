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

private final class SDKPublicConnectionToken: @unchecked Sendable {}

private enum SDKPublicConnectionSlot {
  case attempt(SDKPublicConnectionToken, SDKSessionTransitionGate)
  case active(SDKPublicConnectionToken, SDKPublicConnectedOwner)
}

struct SDKRuntimeDependencies: Sendable {
  let wallClock: @Sendable () -> Date
  let monotonicClock: @Sendable () -> UInt64
  let identifierGenerator: @Sendable () -> UUID

  static let live = SDKRuntimeDependencies(
    wallClock: {
      let now = Date().timeIntervalSince1970
      return Date(timeIntervalSince1970: (now * 1_000).rounded() / 1_000)
    },
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
  private nonisolated let dependencies: SDKRuntimeDependencies
  private nonisolated let connectionDependencies: SDKPublicConnectionDependencies
  private let instanceIdentifier: UUID
  private var state: NearWireState = .idle
  private var connectionSlot: SDKPublicConnectionSlot?
  private var queue: BoundedEventQueue<SDKQueuedEvent>
  private var liveEventIDs = Set<EventID>()
  private var submittedCount: UInt64 = 0
  private var transportAcceptedCount: UInt64 = 0
  private var transportAdmissionRejectedCount: UInt64 = 0
  private var routingDroppedCount: UInt64 = 0
  private var outboundWakeRegistration: SDKOutboundWakeRegistration?

  public init(configuration: NearWireConfiguration = .default) {
    self.configuration = configuration
    stateHub = StateStreamHub(initial: .idle)
    eventHub = EventStreamHub(capacity: configuration.eventStreamBufferCapacity)
    dependencies = .live
    connectionDependencies = .live
    instanceIdentifier = UUID()
    queue = BoundedEventQueue(limits: SDKValidation.queueLimits(configuration.buffer))
  }

  internal init(
    configuration: NearWireConfiguration = .default,
    dependencies: SDKRuntimeDependencies,
    connectionDependencies: SDKPublicConnectionDependencies = .live,
    instanceIdentifier: UUID = UUID()
  ) {
    self.configuration = configuration
    stateHub = StateStreamHub(initial: .idle)
    eventHub = EventStreamHub(capacity: configuration.eventStreamBufferCapacity)
    self.dependencies = dependencies
    self.connectionDependencies = connectionDependencies
    self.instanceIdentifier = instanceIdentifier
    queue = BoundedEventQueue(limits: SDKValidation.queueLimits(configuration.buffer))
  }

  deinit {
    stateHub.finishWithoutChangingState()
    eventHub.finish()
  }

  /// Performs one explicit secure connection attempt to the Viewer advertising `code`.
  ///
  /// Success means the TLS session and its initial flow policy are active. It does not
  /// acknowledge delivery of any buffered Event.
  public func connect(code: String) async throws {
    let transitionGate = connectionDependencies.makeTransitionGate()
    try await withTaskCancellationHandler {
      try await performPublicConnect(code: code, transitionGate: transitionGate)
    } onCancel: {
      transitionGate.requestCancellation(.task)
    }
  }

  private func performPublicConnect(
    code: String,
    transitionGate: SDKSessionTransitionGate
  ) async throws {
    guard state != .shutdown else { throw NearWireError.shutdown }
    guard !Task.isCancelled else { throw NearWireError.connectionCancelled }
    if let connectionSlot {
      switch connectionSlot {
      case .attempt:
        throw SDKPublicConnectionErrorMapping.connectionInProgress()
      case .active:
        throw SDKPublicConnectionErrorMapping.alreadyConnected()
      }
    }

    let pairingTransfer: SDKPairingCodeTransfer
    do {
      pairingTransfer = try SDKPairingCodeTransfer(rawValue: code)
    } catch {
      throw SDKPublicConnectionErrorMapping.invalidPairingCode()
    }

    let plan: SDKPublicConnectionLimitPlan
    let productVersion: WireProductVersion
    do {
      plan = try SDKPublicConnectionLimitPlan.make(configuration: configuration)
      productVersion = try SDKProductVersion.wireValue()
    } catch {
      throw SDKPublicConnectionErrorMapping.invalidConnectionConfiguration(
        field: "buffer.maximumEventBytes"
      )
    }

    let token = SDKPublicConnectionToken()
    let priorState = state
    connectionSlot = .attempt(token, transitionGate)
    connectionDependencies.hooks.reachSynchronous(.beforeLeaseClaim)
    if let failure = transitionGate.currentFailure() {
      connectionSlot = nil
      throw publicConnectionError(gateFailure: failure, fallback: nil)
    }
    let claimedLease: SDKPublicConnectionLease
    do {
      claimedLease = try connectionDependencies.claimLease()
    } catch let error as ProcessConnectionLeaseError {
      connectionSlot = nil
      throw publicConnectionError(
        gateFailure: transitionGate.currentFailure(),
        fallback: SDKPublicConnectionErrorMapping.map(error)
      )
    } catch {
      connectionSlot = nil
      throw publicConnectionError(
        gateFailure: transitionGate.currentFailure(),
        fallback: NearWireError(
          code: .connectionOwnershipUnavailable,
          message: "NearWire process connection ownership is unavailable."
        )
      )
    }
    var lease: SDKPublicConnectionLease? = claimedLease
    var didBeginDiscovery = false
    connectionDependencies.hooks.reachSynchronous(.afterLeaseClaim)
    guard isCurrentPublicAttempt(token), transitionGate.isAuthorized(), !Task.isCancelled else {
      try await finishPublicAttemptWithoutLifetime(
        token: token,
        transitionGate: transitionGate,
        lease: lease,
        priorState: priorState,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError.connectionCancelled
      )
    }

    let identityTarget = SDKSessionTransitionTarget()
    guard transitionGate.installTarget(token: identityTarget, cancel: {}) else {
      try await finishPublicAttemptWithoutLifetime(
        token: token,
        transitionGate: transitionGate,
        lease: lease,
        priorState: priorState,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError.connectionCancelled
      )
    }

    let installationIdentity: String
    do {
      let value = try await connectionDependencies.loadInstallationIdentity()
      await connectionDependencies.hooks.reach(.beforeIdentityCompletion)
      installationIdentity = value
      await connectionDependencies.hooks.reach(.afterIdentityCompletion)
    } catch let error as SDKInstallationIdentityError {
      transitionGate.removeTarget(token: identityTarget)
      try await finishPublicAttemptWithoutLifetime(
        token: token,
        transitionGate: transitionGate,
        lease: lease,
        priorState: priorState,
        didBeginDiscovery: didBeginDiscovery,
        fallback: SDKPublicConnectionErrorMapping.map(error)
      )
    } catch {
      transitionGate.removeTarget(token: identityTarget)
      try await finishPublicAttemptWithoutLifetime(
        token: token,
        transitionGate: transitionGate,
        lease: lease,
        priorState: priorState,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError(
          code: .connectionInternalFailure,
          message: "NearWire could not prepare its local connection identity."
        )
      )
    }

    guard isCurrentPublicAttempt(token), transitionGate.isAuthorized(), !Task.isCancelled else {
      try await finishPublicAttemptWithoutLifetime(
        token: token,
        transitionGate: transitionGate,
        lease: lease,
        priorState: priorState,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError.connectionCancelled
      )
    }

    let metadata = SDKHostApplicationMetadata.resolve(connectionDependencies.bundleMetadata())
    let hello: WireHello
    do {
      hello = try WireHello(
        productVersion: productVersion,
        role: .app,
        installationID: EndpointID(rawValue: installationIdentity),
        maximumEventBytes: plan.maximumEventRecordBytes,
        displayName: metadata.displayName,
        applicationIdentifier: metadata.applicationIdentifier,
        applicationVersion: metadata.applicationVersion,
        limits: plan.wireLimits
      )
    } catch {
      try await finishPublicAttemptWithoutLifetime(
        token: token,
        transitionGate: transitionGate,
        lease: lease,
        priorState: priorState,
        didBeginDiscovery: didBeginDiscovery,
        fallback: SDKPublicConnectionErrorMapping.invalidConnectionConfiguration(
          field: "buffer.maximumEventBytes"
        )
      )
    }

    guard
      let admission = makePublicAdmission(
        consuming: pairingTransfer,
        hello: hello,
        plan: plan,
        transitionGate: transitionGate,
        token: token
      )
    else {
      try await finishPublicAttemptWithoutLifetime(
        token: token,
        transitionGate: transitionGate,
        lease: lease,
        priorState: priorState,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError(
          code: .connectionInternalFailure,
          message: "NearWire could not prepare its internal connection transition."
        )
      )
    }
    didBeginDiscovery = true
    updateSessionState(.discovering)

    await connectionDependencies.hooks.reach(.beforeAdmissionTarget)
    let admissionTarget = SDKSessionTransitionTarget()
    guard
      transitionGate.replaceTarget(
        expectedToken: identityTarget,
        newToken: admissionTarget,
        cancel: { Task { await admission.cancel() } })
    else {
      try await finishPublicAttemptWithoutLifetime(
        token: token,
        transitionGate: transitionGate,
        lease: lease,
        priorState: priorState,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError.connectionCancelled
      )
    }

    let admitted: SDKAdmittedSession
    let admittedTarget = SDKSessionTransitionTarget()
    do {
      admitted = try await admission.run()
      _ = transitionGate.replaceTarget(
        expectedToken: admissionTarget,
        newToken: admittedTarget,
        cancel: { admitted.cancel() }
      )
      await connectionDependencies.hooks.reach(.afterAdmissionResult)
    } catch let error as SDKSessionAdmissionError {
      transitionGate.removeTarget(token: admissionTarget)
      try await finishPublicAttemptWithoutLifetime(
        token: token,
        transitionGate: transitionGate,
        lease: lease,
        priorState: priorState,
        didBeginDiscovery: didBeginDiscovery,
        fallback: SDKPublicConnectionErrorMapping.map(error.code)
      )
    } catch {
      transitionGate.removeTarget(token: admissionTarget)
      try await finishPublicAttemptWithoutLifetime(
        token: token,
        transitionGate: transitionGate,
        lease: lease,
        priorState: priorState,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError(
          code: .connectionInternalFailure,
          message: "NearWire could not complete its internal connection transition."
        )
      )
    }

    guard let retainedLease = lease else {
      admittedTarget.requestCancellation()
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError(
          code: .connectionInternalFailure,
          message: "NearWire could not complete its internal connection transition."
        )
      )
    }
    guard transitionGate.claimCoordinatorLeaseOwnership() else {
      admittedTarget.requestCancellation()
      SDKPublicFailClosedLeaseVault.shared.retain(retainedLease)
      lease = nil
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError(
          code: .connectionInternalFailure,
          message: "NearWire could not transfer its internal connection ownership."
        )
      )
    }
    await connectionDependencies.hooks.reach(.beforeTerminalWaitRegistration)
    let coordinator: SDKPublicTerminalCoordinator
    do {
      coordinator = try SDKPublicTerminalCoordinator(
        lifetime: admitted.lifetime,
        lease: retainedLease,
        hooks: connectionDependencies.hooks,
        delivery: { [weak self] code in
          await self?.receivePublicTerminal(token: token, code: code)
        }
      )
    } catch {
      admittedTarget.requestCancellation()
      SDKPublicFailClosedLeaseVault.shared.retain(retainedLease)
      lease = nil
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError(
          code: .connectionInternalFailure,
          message: "NearWire could not register its terminal connection observer."
        )
      )
    }
    lease = nil
    await connectionDependencies.hooks.reach(.afterTerminalWaitRegistration)

    if let failure = transitionGate.currentFailure() {
      admittedTarget.requestCancellation()
      transitionGate.removeTarget(token: admittedTarget)
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        failure: failure
      )
    }

    let attachment: SDKSessionPumpAttachment
    let attachmentTarget = SDKSessionTransitionTarget()
    do {
      attachment = try await admitted.attachEventPump()
      _ = transitionGate.replaceTarget(
        expectedToken: admittedTarget,
        newToken: attachmentTarget,
        cancel: { attachment.cancel() }
      )
    } catch let error as SDKSessionAdmissionError {
      transitionGate.removeTarget(token: admittedTarget)
      admittedTarget.requestCancellation()
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        fallback: SDKPublicConnectionErrorMapping.map(error.code)
      )
    } catch {
      transitionGate.removeTarget(token: admittedTarget)
      admittedTarget.requestCancellation()
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError(
          code: .connectionInternalFailure,
          message: "NearWire could not attach its active Event pump."
        )
      )
    }

    await connectionDependencies.hooks.reach(.beforeActivationTarget)
    if let failure = transitionGate.currentFailure() {
      attachmentTarget.requestCancellation()
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        failure: failure
      )
    }

    let handle: SDKActiveEventPumpHandle
    let activeHandleTarget = SDKSessionTransitionTarget()
    do {
      handle = try await connectionDependencies.makePump(
        attachment,
        self,
        plan.activeLimits
      ).run()
      _ = transitionGate.replaceTarget(
        expectedToken: attachmentTarget,
        newToken: activeHandleTarget,
        cancel: { handle.cancel() }
      )
      await connectionDependencies.hooks.reach(.afterActivationResult)
    } catch let error as SDKSessionAdmissionError {
      transitionGate.removeTarget(token: attachmentTarget)
      attachmentTarget.requestCancellation()
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        fallback: SDKPublicConnectionErrorMapping.map(error.code)
      )
    } catch {
      transitionGate.removeTarget(token: attachmentTarget)
      attachmentTarget.requestCancellation()
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        fallback: NearWireError(
          code: .connectionInternalFailure,
          message: "NearWire could not activate its Event pump."
        )
      )
    }

    await connectionDependencies.hooks.reach(.beforeTransferClaim)
    switch transitionGate.claimActiveTransfer() {
    case .failure(let failure):
      activeHandleTarget.requestCancellation()
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        failure: failure
      )
    case .success:
      break
    }

    let handleTarget = SDKSessionTransitionTarget()
    guard
      transitionGate.installTarget(
        token: handleTarget,
        cancel: {
          handle.cancel()
        })
    else {
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        failure: transitionGate.currentFailure() ?? .shutdown
      )
    }
    await connectionDependencies.hooks.reach(.beforeActorCommit)
    let owner = SDKPublicConnectedOwner(handle: handle, coordinator: coordinator)
    do {
      try commitPublicConnected(token: token, gate: transitionGate, owner: owner)
    } catch let failure as SDKSessionTransitionFailure {
      handleTarget.requestCancellation()
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        failure: failure
      )
    } catch let error as NearWireError {
      handleTarget.requestCancellation()
      try finishPublicAttemptWithLifetime(
        token: token,
        didBeginDiscovery: didBeginDiscovery,
        fallback: error
      )
    }
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
    if !snapshot.expiredEventIDs.isEmpty { signalOutboundWork() }
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
    if !result.removedEventIDs.isEmpty { signalOutboundWork() }
    return NearWireClearResult(removedEventIDs: result.removedEventIDs.map(\.sdkUUID))
  }

  private func isCurrentPublicAttempt(_ token: SDKPublicConnectionToken) -> Bool {
    guard case .attempt(let current, _) = connectionSlot else { return false }
    return current === token
  }

  private func makePublicAdmission(
    consuming transfer: SDKPairingCodeTransfer,
    hello: WireHello,
    plan: SDKPublicConnectionLimitPlan,
    transitionGate: SDKSessionTransitionGate,
    token: SDKPublicConnectionToken
  ) -> SDKSessionAdmission? {
    guard let pairingCode = transfer.take() else { return nil }
    return connectionDependencies.makeAdmission(
      pairingCode,
      hello,
      plan,
      transitionGate,
      { [weak self] in
        guard let self else { return .cancelled }
        return await self.authorizePublicConnecting(token: token, gate: transitionGate)
      }
    )
  }

  private func authorizePublicConnecting(
    token: SDKPublicConnectionToken,
    gate: SDKSessionTransitionGate
  ) -> SDKSessionPhaseAuthorization {
    guard state != .shutdown, isCurrentPublicAttempt(token), gate.isAuthorized() else {
      return .cancelled
    }
    updateSessionState(.connecting)
    return .authorized
  }

  private func finishPublicAttemptWithoutLifetime(
    token: SDKPublicConnectionToken,
    transitionGate: SDKSessionTransitionGate,
    lease: SDKPublicConnectionLease?,
    priorState: NearWireState,
    didBeginDiscovery: Bool,
    fallback: NearWireError
  ) async throws -> Never {
    await connectionDependencies.hooks.reach(.beforeRelease)
    lease?.release()
    await connectionDependencies.hooks.reach(.afterRelease)

    let error = publicConnectionError(
      gateFailure: transitionGate.currentFailure(),
      fallback: fallback
    )
    if state != .shutdown, isCurrentPublicAttempt(token) {
      connectionSlot = nil
      if didBeginDiscovery {
        updateSessionState(.disconnected)
      } else if state != priorState {
        updateSessionState(priorState)
      }
    }
    throw state == .shutdown ? NearWireError.shutdown : error
  }

  private func finishPublicAttemptWithLifetime(
    token: SDKPublicConnectionToken,
    didBeginDiscovery: Bool,
    failure: SDKSessionTransitionFailure
  ) throws -> Never {
    try finishPublicAttemptWithLifetime(
      token: token,
      didBeginDiscovery: didBeginDiscovery,
      fallback: publicConnectionError(gateFailure: failure, fallback: nil)
    )
  }

  private func finishPublicAttemptWithLifetime(
    token: SDKPublicConnectionToken,
    didBeginDiscovery: Bool,
    fallback: NearWireError
  ) throws -> Never {
    if state != .shutdown, isCurrentPublicAttempt(token) {
      connectionSlot = nil
      if didBeginDiscovery { updateSessionState(.disconnected) }
    }
    throw state == .shutdown ? NearWireError.shutdown : fallback
  }

  private func publicConnectionError(
    gateFailure: SDKSessionTransitionFailure?,
    fallback: NearWireError?
  ) -> NearWireError {
    switch gateFailure {
    case .shutdown:
      return .shutdown
    case .cancelled:
      return .connectionCancelled
    case .terminal(let code):
      return SDKPublicConnectionErrorMapping.map(code)
    case .invalidState:
      return NearWireError(
        code: .connectionInternalFailure,
        message: "NearWire could not complete its internal connection transition."
      )
    case nil:
      return fallback
        ?? NearWireError(
          code: .connectionInternalFailure,
          message: "NearWire could not complete its internal connection transition."
        )
    }
  }

  private func commitPublicConnected(
    token: SDKPublicConnectionToken,
    gate: SDKSessionTransitionGate,
    owner: SDKPublicConnectedOwner
  ) throws {
    guard state != .shutdown else { throw NearWireError.shutdown }
    guard isCurrentPublicAttempt(token) else {
      throw SDKSessionTransitionFailure.invalidState
    }
    switch gate.claimConnectedCommit() {
    case .failure(let failure):
      throw failure
    case .success:
      connectionSlot = .active(token, owner)
      updateSessionState(.connected)
    }
  }

  private func receivePublicTerminal(
    token: SDKPublicConnectionToken,
    code _: SDKSessionAdmissionError.Code
  ) {
    guard case .active(let current, _) = connectionSlot, current === token else { return }
    connectionSlot = nil
    if state != .shutdown { updateSessionState(.disconnected) }
  }

  /// Permanently ends this instance and releases its in-memory work and observers.
  public func shutdown() {
    guard state != .shutdown else { return }
    if let connectionSlot {
      switch connectionSlot {
      case .attempt(_, let gate):
        gate.requestCancellation(.shutdown)
      case .active(_, let owner):
        owner.cancel()
      }
      self.connectionSlot = nil
    }
    _ = queue.clear(reason: .ownerRequested)
    liveEventIDs.removeAll(keepingCapacity: false)
    state = .shutdown
    signalOutboundWork()
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
    signalOutboundWork()
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

  private func signalOutboundWork() {
    outboundWakeRegistration?.callback()
  }
}

extension NearWire {
  nonisolated func activeClockNanoseconds() -> UInt64 {
    dependencies.monotonicClock()
  }

  func registerOutboundWorkWake(
    token: SDKOutboundWakeToken,
    callback: @escaping @Sendable () -> Void,
    maximumServiceUnits: Int,
    gate: SDKActiveOperationGate,
    operationHooks: SDKActiveLiveOperationHooks = .none
  ) throws -> SDKOutboundWakeRegistrationResult {
    guard state != .shutdown else {
      return SDKOutboundWakeRegistrationResult(installed: false, schedule: .ownerUnavailable)
    }
    guard outboundWakeRegistration == nil else {
      throw SDKOutboundWakeRegistrationError.alreadyRegistered
    }
    var schedule = SDKOutboundScheduleResult.terminalFirst
    let installed = gate.withOpenClaim {
      outboundWakeRegistration = SDKOutboundWakeRegistration(token: token, callback: callback)
      do {
        schedule = .available(
          try queue.previewActiveSchedule(
            nowOnQueueClockNanoseconds: dependencies.monotonicClock(),
            maximumServiceUnits: maximumServiceUnits
          )
        )
      } catch {
        schedule = .clockFailed
      }
    }
    guard installed else {
      return SDKOutboundWakeRegistrationResult(installed: false, schedule: .terminalFirst)
    }
    return SDKOutboundWakeRegistrationResult(installed: true, schedule: schedule)
  }

  func removeOutboundWorkWake(token: SDKOutboundWakeToken) {
    guard outboundWakeRegistration?.token === token else { return }
    outboundWakeRegistration = nil
  }

  func outboundSchedule(
    maximumServiceUnits: Int,
    gate: SDKActiveOperationGate,
    operationHooks: SDKActiveLiveOperationHooks = .none
  ) -> SDKOutboundScheduleResult {
    guard state != .shutdown else { return .ownerUnavailable }
    do {
      let observation = try queue.observeActiveSchedule(
        nowOnQueueClockNanoseconds: dependencies.monotonicClock(),
        maximumServiceUnits: maximumServiceUnits,
        authorizeExpiration: { event, commit in
          operationHooks.beforeExpirationClaim()
          return gate.withOpenClaim {
            commit()
            liveEventIDs.remove(event.id)
          }
        }
      )
      guard !observation.stoppedByAuthorization else { return .terminalFirst }
      if !observation.expiredEventIDs.isEmpty { signalOutboundWork() }
      return .available(observation)
    } catch {
      return .clockFailed
    }
  }

  func drainActiveWire(
    for route: SDKSessionRoute,
    codec: WireSessionCodec,
    sequenceCounter: WireSequenceCounter,
    maximumServiceUnits: Int,
    maximumAcceptedEventCount: Int,
    maximumAccountedBytes: Int,
    channel: SecureByteChannel,
    reservingPendingSendCount: Int,
    reservingPendingSendBytes: Int,
    gate: SDKActiveOperationGate,
    operationHooks: SDKActiveLiveOperationHooks = .none
  ) -> SDKActiveWireDrainResult {
    guard state != .shutdown else {
      return emptyActiveWireDrain(
        ownerAvailable: false,
        stoppedByTerminal: false,
        failure: nil,
        sequenceCounter: sequenceCounter
      )
    }

    let now = dependencies.monotonicClock()
    var plannedCounter = sequenceCounter
    var acceptedEventIDs: [EventID] = []
    var rejectedEventIDs: [EventID] = []
    var notAttemptedEventIDs: [EventID] = []
    var routingDroppedEventIDs: [EventID] = []
    var acceptedEncodedByteCount = 0
    var transportBlock: SDKActiveWireTransportBlock?
    var failure: SDKActiveWireDrainFailure?
    var stoppedByTerminal = false

    let sessionEpoch: SessionEpoch
    let source: EventEndpoint
    let target: EventEndpoint
    do {
      sessionEpoch = try SessionEpoch(rawValue: route.sessionEpoch.nearWireCanonicalString)
      source = EventEndpoint(role: .app, id: try EndpointID(rawValue: route.appID))
      target = EventEndpoint(role: .viewer, id: try EndpointID(rawValue: route.viewerID))
    } catch {
      return emptyActiveWireDrain(
        ownerAvailable: true,
        stoppedByTerminal: false,
        failure: .encodingFailed,
        sequenceCounter: sequenceCounter
      )
    }
    guard sequenceCounter.sessionEpoch == sessionEpoch,
      sequenceCounter.direction == .appToViewer
    else {
      return emptyActiveWireDrain(
        ownerAvailable: true,
        stoppedByTerminal: false,
        failure: .sequenceFailed,
        sequenceCounter: sequenceCounter
      )
    }

    do {
      let queueResult = try queue.offerActive(
        maximumServiceUnits: maximumServiceUnits,
        maximumAcceptedEventCount: maximumAcceptedEventCount,
        maximumBytes: maximumAccountedBytes,
        nowOnQueueClockNanoseconds: now,
        authorizeExpiration: { event, commit in
          operationHooks.beforeExpirationClaim()
          return gate.withOpenClaim {
            commit()
            liveEventIDs.remove(event.id)
          }
        },
        preflight: { event, commitRemoval in
          if let affinity = event.value.replyAffinity,
            affinity
              != SDKReplyAffinity(
                sessionEpoch: route.sessionEpoch,
                viewerID: route.viewerID,
                appID: route.appID
              )
          {
            operationHooks.beforeRouteDropClaim()
            let committed = gate.withOpenClaim {
              commitRemoval()
              liveEventIDs.remove(event.id)
              routingDroppedCount = sdkSaturatedSum(routingDroppedCount, 1)
            }
            if committed {
              routingDroppedEventIDs.append(event.id)
              return .removeWithoutAccounting
            }
            stoppedByTerminal = true
            return .stop
          }
          return .eligible
        },
        decision: { event, commitRemoval in
          var candidateCounter = plannedCounter
          let sequence: EventSequence
          do {
            sequence = try candidateCounter.allocate()
          } catch {
            failure = .sequenceFailed
            notAttemptedEventIDs.append(event.id)
            return .stop
          }

          let encoded: Data
          do {
            let envelope = try EventEnvelope(
              id: event.id,
              type: event.value.draft.type,
              content: event.value.draft.content,
              createdAt: event.value.createdAt,
              monotonicTimestampNanoseconds: event.enqueuedAtNanoseconds,
              source: source,
              target: target,
              direction: .appToViewer,
              sessionEpoch: sessionEpoch,
              sequence: sequence,
              priority: event.priority,
              ttl: event.ttl,
              causality: event.value.draft.causality,
              limits: codec.limits.eventValidationLimits
            )
            let record = try WireEventRecord(
              envelope: envelope,
              nowOnOriginClockNanoseconds: now
            )
            encoded = try codec.encode(WireEventPayload(record: record), phase: .active)
          } catch let wireError as WireProtocolError {
            switch wireError.code {
            case .invalidClock, .eventExpired, .arithmeticOverflow:
              failure = .clockFailed
            default:
              failure = .encodingFailed
            }
            notAttemptedEventIDs.append(event.id)
            return .stop
          } catch {
            failure = .encodingFailed
            notAttemptedEventIDs.append(event.id)
            return .stop
          }

          let (encodedTotal, encodedOverflow) = acceptedEncodedByteCount.addingReportingOverflow(
            encoded.count
          )
          guard !encodedOverflow else {
            failure = .encodingFailed
            notAttemptedEventIDs.append(event.id)
            return .stop
          }

          enum AdmissionOutcome {
            case accepted
            case backpressure
            case failed
            case terminalFirst
          }
          var admissionOutcome = AdmissionOutcome.terminalFirst
          operationHooks.beforeCandidateClaim()
          let claimed = gate.withOpenClaim {
            do {
              operationHooks.beforeEventMailboxAdmission()
              try channel.admitSend(
                encoded,
                reservingPendingSendCount: reservingPendingSendCount,
                reservingPendingSendBytes: reservingPendingSendBytes
              )
              commitRemoval()
              liveEventIDs.remove(event.id)
              transportAcceptedCount = sdkSaturatedSum(transportAcceptedCount, 1)
              plannedCounter = candidateCounter
              acceptedEncodedByteCount = encodedTotal
              admissionOutcome = .accepted
            } catch let transportError as SecureTransportError
              where transportError.code == .backpressure
            {
              transportAdmissionRejectedCount = sdkSaturatedSum(
                transportAdmissionRejectedCount,
                1
              )
              admissionOutcome = .backpressure
            } catch {
              admissionOutcome = .failed
            }
          }
          operationHooks.afterCandidateClaim()
          guard claimed else {
            stoppedByTerminal = true
            return .stop
          }
          switch admissionOutcome {
          case .accepted:
            acceptedEventIDs.append(event.id)
            return .remove
          case .backpressure:
            rejectedEventIDs.append(event.id)
            operationHooks.beforeEventMailboxProgressSnapshot()
            let snapshot = channel.sendCapacitySnapshot
            transportBlock = SDKActiveWireTransportBlock(
              candidateID: event.id,
              encodedByteCount: encoded.count,
              reservedPendingSendCount: reservingPendingSendCount,
              reservedPendingSendBytes: reservingPendingSendBytes,
              progressGeneration: snapshot.progressGeneration
            )
            return .stop
          case .failed:
            failure = .transportFailed
            notAttemptedEventIDs.append(event.id)
            return .stop
          case .terminalFirst:
            stoppedByTerminal = true
            return .stop
          }
        }
      )

      if !queueResult.expiredEventIDs.isEmpty || !acceptedEventIDs.isEmpty
        || !routingDroppedEventIDs.isEmpty
      {
        signalOutboundWork()
      }
      return SDKActiveWireDrainResult(
        ownerAvailable: true,
        stoppedByTerminal: stoppedByTerminal,
        failure: failure,
        acceptedEventIDs: acceptedEventIDs,
        rejectedEventIDs: rejectedEventIDs,
        notAttemptedEventIDs: notAttemptedEventIDs,
        routingDroppedEventIDs: routingDroppedEventIDs,
        expiredEventIDs: queueResult.expiredEventIDs,
        plannedSequenceCounter: plannedCounter,
        acceptedEncodedByteCount: acceptedEncodedByteCount,
        acceptedAccountedByteCount: queueResult.acceptedAccountedByteCount,
        serviceUnits: queueResult.serviceUnits,
        dueWorkRemains: queueResult.dueWorkRemains,
        eligibleWorkRemains: queueResult.eligibleWorkRemains,
        nextExpirationDeadlineNanoseconds: queueResult.nextExpirationDeadlineNanoseconds,
        nextFairCandidateID: queueResult.nextFairCandidateID,
        transportBlock: transportBlock
      )
    } catch let flowError as FlowControlError {
      return emptyActiveWireDrain(
        ownerAvailable: true,
        stoppedByTerminal: false,
        failure: flowError.code == .invalidClock ? .clockFailed : .invalidLimits,
        sequenceCounter: sequenceCounter
      )
    } catch {
      return emptyActiveWireDrain(
        ownerAvailable: true,
        stoppedByTerminal: false,
        failure: .invalidLimits,
        sequenceCounter: sequenceCounter
      )
    }
  }

  private func emptyActiveWireDrain(
    ownerAvailable: Bool,
    stoppedByTerminal: Bool,
    failure: SDKActiveWireDrainFailure?,
    sequenceCounter: WireSequenceCounter
  ) -> SDKActiveWireDrainResult {
    SDKActiveWireDrainResult(
      ownerAvailable: ownerAvailable,
      stoppedByTerminal: stoppedByTerminal,
      failure: failure,
      acceptedEventIDs: [],
      rejectedEventIDs: [],
      notAttemptedEventIDs: [],
      routingDroppedEventIDs: [],
      expiredEventIDs: [],
      plannedSequenceCounter: sequenceCounter,
      acceptedEncodedByteCount: 0,
      acceptedAccountedByteCount: 0,
      serviceUnits: 0,
      dueWorkRemains: false,
      eligibleWorkRemains: false,
      nextExpirationDeadlineNanoseconds: nil,
      nextFairCandidateID: nil,
      transportBlock: nil
    )
  }

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

  func publishIncomingActive(
    _ received: WireReceivedEvent,
    gate: SDKActiveOperationGate
  ) -> SDKActiveIncomingPublicationResult {
    guard state != .shutdown else { return .ownerUnavailable }
    do {
      if try received.isExpired(nowOnReceiverClockNanoseconds: dependencies.monotonicClock()) {
        return .expired
      }
    } catch {
      return .clockFailed
    }
    var didPublish = false
    let claimed = gate.withOpenClaim {
      didPublish = publishIncoming(received.envelope)
    }
    guard claimed else { return .terminalFirst }
    return didPublish ? .published : .ownerUnavailable
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

    if !result.expiredEventIDs.isEmpty || !accepted.isEmpty || !routingDropped.isEmpty {
      signalOutboundWork()
    }

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
