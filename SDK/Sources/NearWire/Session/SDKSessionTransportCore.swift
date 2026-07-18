import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireInternal) import NearWireFlowControl
  @_spi(NearWireInternal) import NearWireTransport
#endif

final class SDKSessionCancellationRelay: @unchecked Sendable {
  let core: SDKSessionTransportCore

  private let lock = NSLock()
  private var cancellationRequested = false

  init(core: SDKSessionTransportCore) {
    self.core = core
  }

  func requestCancellation() {
    lock.lock()
    guard !cancellationRequested else {
      lock.unlock()
      return
    }
    cancellationRequested = true
    lock.unlock()
    Task { [core] in await core.cancelFromExternalHandle() }
  }

  deinit {
    requestCancellation()
  }
}

final class SDKSessionLifetime: @unchecked Sendable {
  let relay: SDKSessionCancellationRelay
  let transitionGate: SDKSessionTransitionGate
  let termination: SDKActiveEventPumpTermination

  init(core: SDKSessionTransportCore, transitionGate: SDKSessionTransitionGate) {
    relay = SDKSessionCancellationRelay(core: core)
    self.transitionGate = transitionGate
    termination = SDKActiveEventPumpTermination(core: core)
  }
}

private final class SDKRetainedDiscovery: @unchecked Sendable {
  private let lock = NSLock()
  private var operation: (any SDKSessionDiscoveryOperation)?

  init(operation: any SDKSessionDiscoveryOperation) {
    self.operation = operation
  }

  func release() {
    lock.lock()
    let retained = operation
    operation = nil
    lock.unlock()
    guard let retained else { return }
    Task { await retained.cancel() }
  }

  deinit {
    release()
  }
}

final class SDKAdmittedSession: @unchecked Sendable {
  let route: SDKSessionRoute
  let capabilities: Set<WireCapability>
  let sendPolicies: Set<WireSendPolicy>
  let maximumEventBytes: Int

  let lifetime: SDKSessionLifetime

  init(
    route: SDKSessionRoute,
    capabilities: Set<WireCapability>,
    sendPolicies: Set<WireSendPolicy>,
    maximumEventBytes: Int,
    lifetime: SDKSessionLifetime
  ) {
    self.route = route
    self.capabilities = capabilities
    self.sendPolicies = sendPolicies
    self.maximumEventBytes = maximumEventBytes
    self.lifetime = lifetime
  }

  func attachEventPump() async throws -> SDKSessionPumpAttachment {
    try await lifetime.relay.core.attachEventPump(lifetime: lifetime)
  }

  func cancel() {
    lifetime.relay.requestCancellation()
  }
}

extension SDKAdmittedSession: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String { "<redacted-admitted-session>" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }
}

final class SDKSessionPumpAttachment: @unchecked Sendable {
  let lifetime: SDKSessionLifetime

  init(lifetime: SDKSessionLifetime) {
    self.lifetime = lifetime
  }

  func nextPolicyMessage() async throws -> SDKSessionPolicyMessage {
    let gate = SDKSessionPullCancellationGate()
    return try await withTaskCancellationHandler {
      try await lifetime.relay.core.nextPolicyMessage(cancellationGate: gate)
    } onCancel: {
      gate.cancel()
    }
  }

  func cancel() {
    lifetime.relay.requestCancellation()
  }

  var transportCore: SDKSessionTransportCore { lifetime.relay.core }
}

extension SDKSessionPumpAttachment: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String { "<redacted-session-pump-attachment>" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }
}

actor SDKSessionTransportCore {
  private static let ingressDrainQuantum = 8
  struct Snapshot: Equatable, Sendable {
    let state: SDKSessionAdmissionState
    let retainedPolicyMessages: Int
    let hasPendingPolicyPull: Bool
    let terminalCode: SDKSessionAdmissionError.Code?
    let pumpAttached: Bool
    let hasPendingTerminationObservation: Bool
    let effectiveUplinkRate: Double?
    let effectiveDownlinkRate: Double?
    let retainedIncomingEvents: Int
    let retainedIncomingEncodedBytes: Int
    let remoteOverflowDropped: UInt64
    let remoteExpired: UInt64
    let remoteCoalesced: UInt64
    let localIncomingExpired: UInt64
    let outboundTurnStarts: UInt64
    let isOutboundTransportBlocked: Bool
    let hasOutboundDecision: Bool
    let hasOwnerRefresh: Bool
    let hasPendingOutboundWork: Bool
    let deferredPolicyCount: Int
    let hasIncomingDecision: Bool
    let hasOutboundDrain: Bool
    let outboundNextSequence: UInt64?
    let uplinkAvailableTokens: Double?
  }
  private struct ProvisionalAdmission {
    let route: SDKSessionRoute
    let negotiation: WireNegotiationResult
  }

  private struct PendingPull {
    let token: SDKSessionPullToken
    let gate: SDKSessionPullCancellationGate
    let continuation: CheckedContinuation<SDKSessionPolicyMessage, Error>
  }

  private struct PendingActivation {
    let token: SDKActiveRunToken
    let gate: SDKSessionPullCancellationGate
    let continuation: CheckedContinuation<Void, Error>
  }

  private struct PendingTerminationObservation {
    let token: SDKActiveTerminationToken
    let gate: SDKSessionPullCancellationGate
    let continuation: CheckedContinuation<SDKSessionAdmissionError.Code, Error>
  }

  private enum PolicyConsumerOwner {
    case unclaimed
    case attachmentPull
    case activeRunner
  }

  private enum OutboundTurnResult: Sendable {
    case drained(SDKActiveWireDrainResult, refreshedBucket: EventTokenBucket)
    case blocked(SDKOutboundScheduleResult)
  }

  private let ingress: SDKSessionChannelIngress
  private var localHello: WireHello?
  private var localHelloBytes: Data?
  private let transitionGate: SDKSessionTransitionGate
  private var discoveredDiscriminator: ViewerDiscoveryDiscriminator?
  private let wireLimits: WireProtocolLimits
  private let admissionLimits: SDKSessionAdmissionLimits
  private let sleep: @Sendable (Int) async throws -> Void
  private var retainedDiscovery: SDKRetainedDiscovery?

  private var channel: SecureByteChannel?
  private var state: SDKSessionAdmissionState = .transferred
  private var frameDecoder: WireFrameDecoder
  private var preHandshakeCodec: WirePreHandshakeCodec
  private var sessionCodec: WireSessionCodec?
  private var negotiation: WireNegotiationResult?
  private var route: SDKSessionRoute?
  private var provisionalAdmission: ProvisionalAdmission?
  private var attemptToken: SDKSessionAttemptToken?
  private var resultWaiter: CheckedContinuation<SDKAdmittedSession, Error>?
  private var deadlineTask: Task<Void, Never>?
  private var deadlineToken: SDKSessionDeadlineToken?
  private var terminalError: SDKSessionAdmissionError?
  private var channelCancellationRequested = false
  private var helloSent = false
  private var pumpAttached = false
  private var handshakeWorkItems = 0
  private var handshakeWorkBytes = 0
  private var handoffWorkItems = 0
  private var handoffWorkBytes = 0
  private var policyFIFO: [SDKBufferedPolicyMessage] = []
  private var policyFIFOBytes = 0
  private var pendingPull: PendingPull?
  private var policyConsumerOwner: PolicyConsumerOwner = .unclaimed
  private var admittedCapabilities: Set<WireCapability> = []
  private var admittedMaximumEventBytes = 0
  private var activeAppMaximumRates: DirectionalEventRates?
  private var activeLimits: SDKActiveEventPumpLimits?
  private var activeDependencies: SDKActiveEventPumpDependencies?
  private var activeLiveOperations: SDKActiveLiveOperations?
  private var activeOperationGate: SDKActiveOperationGate?
  private var activeWakeToken: SDKOutboundWakeToken?
  private var activeBindingToken: SDKActiveBindingToken?
  private var activeSignalIngress: SDKOutboundSignalIngress?
  private var pendingActivation: PendingActivation?
  private var pendingTerminationObservation: PendingTerminationObservation?
  private var uplinkBucket: EventTokenBucket?
  private var downlinkBucket: EventTokenBucket?
  private var outboundSequenceCounter: WireSequenceCounter?
  private var outboundDrainTask: Task<Void, Never>?
  private var outboundDrainToken: SDKActiveOutboundDrainToken?
  private var outboundDecisionTask: Task<Void, Never>?
  private var outboundDecisionToken: SDKActiveOutboundDecisionToken?
  private var outboundWorkRequested = false
  private var outboundTransportBlock: SDKActiveWireTransportBlock?
  private var deferredPolicyOffers: [WireFlowPolicyOffer] = []
  private var ownerRefreshTask: Task<Void, Never>?
  private var ownerRefreshToken: SDKActiveOwnerRefreshToken?
  private var incomingQueue: SDKIncomingEventQueue?
  private var incomingSequenceValidator: WireSequenceValidator?
  private var incomingInFlight: SDKIncomingEventItem?
  private var incomingPublicationTask: Task<Void, Never>?
  private var incomingPublicationToken: SDKActiveIncomingPublicationToken?
  private var incomingDecisionTask: Task<Void, Never>?
  private var incomingDecisionToken: SDKActiveIncomingDecisionToken?
  private var remoteOverflowDropped: UInt64 = 0
  private var remoteExpired: UInt64 = 0
  private var remoteCoalesced: UInt64 = 0
  private var localIncomingExpired: UInt64 = 0
  private var outboundTurnStarts: UInt64 = 0

  init(
    ingress: SDKSessionChannelIngress,
    localHello: WireHello,
    localHelloBytes: Data,
    discoveredDiscriminator: ViewerDiscoveryDiscriminator,
    attemptToken: SDKSessionAttemptToken,
    wireLimits: WireProtocolLimits,
    admissionLimits: SDKSessionAdmissionLimits,
    transitionGate: SDKSessionTransitionGate = SDKSessionTransitionGate(),
    retainedDiscovery: (any SDKSessionDiscoveryOperation)? = nil,
    sleep: @escaping @Sendable (Int) async throws -> Void
  ) {
    self.ingress = ingress
    self.localHello = localHello
    self.localHelloBytes = localHelloBytes
    self.discoveredDiscriminator = discoveredDiscriminator
    self.attemptToken = attemptToken
    self.wireLimits = wireLimits
    self.admissionLimits = admissionLimits
    self.sleep = sleep
    self.transitionGate = transitionGate
    self.retainedDiscovery = retainedDiscovery.map(SDKRetainedDiscovery.init(operation:))
    frameDecoder = WireFrameDecoder(limits: wireLimits.frame)
    preHandshakeCodec = WirePreHandshakeCodec(limits: wireLimits)
  }

  func bind(channel: SecureByteChannel) throws {
    if let terminalError { throw terminalError }
    guard self.channel == nil, state == .transferred else {
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
    self.channel = channel
  }

  func run(attemptToken: SDKSessionAttemptToken) async throws -> SDKAdmittedSession {
    if let terminalError { throw terminalError }
    guard state == .transferred, channel != nil, self.attemptToken === attemptToken else {
      throw SDKSessionAdmissionError(.alreadyStarted)
    }
    state = .connecting
    return try await withCheckedThrowingContinuation { continuation in
      resultWaiter = continuation
      startDeadline(
        seconds: admissionLimits.secureAdmissionTimeoutSeconds,
        failure: .secureAdmissionTimedOut
      )
      Task { [weak self] in await self?.startChannel() }
    }
  }

  func cancelAttempt(_ token: SDKSessionAttemptToken) {
    guard attemptToken === token else { return }
    finish(with: SDKSessionAdmissionError(.cancelled))
  }

  func cancelFromExternalHandle() {
    guard terminalError == nil else { return }
    finish(with: SDKSessionAdmissionError(.cancelled))
  }

  func drainIngress() {
    let batch: [SDKSessionChannelIngress.Item]
    switch ingress.takeBatch(maximumItems: Self.ingressDrainQuantum) {
    case .batch(let items):
      batch = items
    case .parked, .empty:
      return
    }
    defer {
      ingress.completeBatch(batch)
      ingress.finishDrainTurn()
    }
    guard terminalError == nil else { return }
    for item in batch {
      guard terminalError == nil else { return }
      if let terminal = ingress.latchedTerminal {
        receiveLatchedTerminal(terminal)
        return
      }
      switch item {
      case .overflow:
        finish(with: SDKSessionAdmissionError(.ingressOverflow))
      case .channel(let event):
        receiveChannelEvent(event)
      }
    }
  }

  func attachEventPump(
    lifetime: SDKSessionLifetime
  ) throws -> SDKSessionPumpAttachment {
    if let terminalError { throw terminalError }
    guard state == .admitted else {
      throw SDKSessionAdmissionError(.protocolViolation)
    }
    guard !pumpAttached else {
      throw SDKSessionAdmissionError(.alreadyAttached)
    }
    pumpAttached = true
    cancelDeadline()
    return SDKSessionPumpAttachment(lifetime: lifetime)
  }

  func nextPolicyMessage(
    cancellationGate gate: SDKSessionPullCancellationGate
  ) async throws -> SDKSessionPolicyMessage {
    try await withCheckedThrowingContinuation { continuation in
      registerPolicyPull(gate: gate, continuation: continuation)
    }
  }

  func startActivePump(
    token: SDKActiveRunToken,
    cancellationGate: SDKSessionPullCancellationGate,
    owner: NearWire,
    limits: SDKActiveEventPumpLimits,
    dependencies: SDKActiveEventPumpDependencies
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      registerActiveRunner(
        token: token,
        cancellationGate: cancellationGate,
        owner: owner,
        limits: limits,
        dependencies: dependencies,
        continuation: continuation
      )
    }
  }

  func waitForActiveTermination(
    token: SDKActiveTerminationToken,
    cancellationGate: SDKSessionPullCancellationGate
  ) async throws -> SDKSessionAdmissionError.Code {
    try await withCheckedThrowingContinuation { continuation in
      registerTerminationObservation(
        token: token,
        cancellationGate: cancellationGate,
        continuation: continuation
      )
    }
  }

  func snapshot() -> Snapshot {
    Snapshot(
      state: state,
      retainedPolicyMessages: policyFIFO.count,
      hasPendingPolicyPull: pendingPull != nil,
      terminalCode: terminalError?.code,
      pumpAttached: pumpAttached,
      hasPendingTerminationObservation: pendingTerminationObservation != nil,
      effectiveUplinkRate: uplinkBucket?.rate.eventsPerSecond,
      effectiveDownlinkRate: downlinkBucket?.rate.eventsPerSecond,
      retainedIncomingEvents: (incomingQueue?.snapshot.count ?? 0)
        + (incomingInFlight == nil ? 0 : 1),
      retainedIncomingEncodedBytes: (incomingQueue?.snapshot.encodedBytes ?? 0)
        + (incomingInFlight?.encodedByteCount ?? 0),
      remoteOverflowDropped: remoteOverflowDropped,
      remoteExpired: remoteExpired,
      remoteCoalesced: remoteCoalesced,
      localIncomingExpired: localIncomingExpired,
      outboundTurnStarts: outboundTurnStarts,
      isOutboundTransportBlocked: outboundTransportBlock != nil,
      hasOutboundDecision: outboundDecisionTask != nil,
      hasOwnerRefresh: ownerRefreshTask != nil,
      hasPendingOutboundWork: outboundWorkRequested,
      deferredPolicyCount: deferredPolicyOffers.count,
      hasIncomingDecision: incomingDecisionTask != nil,
      hasOutboundDrain: outboundDrainTask != nil,
      outboundNextSequence: outboundSequenceCounter?.nextRawValue,
      uplinkAvailableTokens: uplinkBucket?.availableTokens
    )
  }

  private func registerPolicyPull(
    gate: SDKSessionPullCancellationGate,
    continuation: CheckedContinuation<SDKSessionPolicyMessage, Error>
  ) {
    let token = SDKSessionPullToken()
    let claimed = gate.claim { [weak self] in
      Task { await self?.cancelPolicyPull(token: token) }
    }
    guard claimed else {
      gate.close()
      continuation.resume(throwing: SDKSessionAdmissionError(.pullCancelled))
      return
    }
    if let terminalError {
      gate.close()
      continuation.resume(throwing: terminalError)
      return
    }
    if policyConsumerOwner == .activeRunner {
      gate.close()
      continuation.resume(throwing: SDKSessionAdmissionError(.policyConsumerClaimed))
      return
    }
    if policyConsumerOwner == .unclaimed {
      policyConsumerOwner = .attachmentPull
    }
    if pendingPull != nil {
      gate.close()
      continuation.resume(throwing: SDKSessionAdmissionError(.pullAlreadyPending))
      return
    }
    if !policyFIFO.isEmpty {
      let item = policyFIFO.removeFirst()
      policyFIFOBytes -= item.encodedByteCount
      gate.close()
      continuation.resume(returning: item.message)
      return
    }
    pendingPull = PendingPull(token: token, gate: gate, continuation: continuation)
  }

  private func registerActiveRunner(
    token: SDKActiveRunToken,
    cancellationGate gate: SDKSessionPullCancellationGate,
    owner: NearWire,
    limits: SDKActiveEventPumpLimits,
    dependencies: SDKActiveEventPumpDependencies,
    continuation: CheckedContinuation<Void, Error>
  ) {
    if let terminalError {
      gate.close()
      continuation.resume(throwing: terminalError)
      return
    }
    guard state == .admitted, pendingActivation == nil else {
      gate.close()
      continuation.resume(throwing: SDKSessionAdmissionError(.alreadyStarted))
      return
    }
    let claimed = gate.claim { [weak self] in
      Task { await self?.cancelActiveRun(token: token) }
    }
    guard claimed else {
      finish(with: SDKSessionAdmissionError(.cancelled))
      continuation.resume(throwing: SDKSessionAdmissionError(.cancelled))
      return
    }
    guard policyConsumerOwner == .unclaimed else {
      gate.close()
      continuation.resume(throwing: SDKSessionAdmissionError(.policyConsumerClaimed))
      return
    }
    let controlFrameBytes = wireLimits.frame.maximumEncodedFrameBytes(for: .control)
    let (reservedControlBytes, reservationOverflow) =
      controlFrameBytes
      .multipliedReportingOverflow(by: 2)
    let maximumEventSendBytes: Int
    do {
      guard let sessionCodec else {
        throw SDKSessionAdmissionError(.invalidLocalConfiguration)
      }
      maximumEventSendBytes = try sessionCodec.maximumEncodedSingleEventFrameBytes()
    } catch {
      gate.close()
      finish(with: SDKSessionAdmissionError(.invalidLocalConfiguration))
      continuation.resume(throwing: SDKSessionAdmissionError(.invalidLocalConfiguration))
      return
    }
    let (requiredPendingBytes, pendingOverflow) = reservedControlBytes.addingReportingOverflow(
      maximumEventSendBytes
    )
    let appMaximumRates: DirectionalEventRates
    do {
      appMaximumRates = DirectionalEventRates(
        appUplink: try EventRateLimit(
          eventsPerSecond: owner.configuration.maximumUplinkEventsPerSecond
        ),
        appDownlink: try EventRateLimit(
          eventsPerSecond: owner.configuration.maximumDownlinkEventsPerSecond
        )
      )
    } catch {
      gate.close()
      finish(with: SDKSessionAdmissionError(.invalidLocalConfiguration))
      continuation.resume(throwing: SDKSessionAdmissionError(.invalidLocalConfiguration))
      return
    }
    guard admittedCapabilities.contains(.bidirectionalEvents),
      admittedCapabilities.contains(.flowPolicy)
    else {
      gate.close()
      finish(with: SDKSessionAdmissionError(.incompatiblePeer))
      continuation.resume(throwing: SDKSessionAdmissionError(.incompatiblePeer))
      return
    }
    guard limits.maximumIncomingEncodedBytes >= admittedMaximumEventBytes,
      limits.maximumOutboundAccountedBytesPerTurn >= owner.configuration.buffer.maximumEventBytes,
      !reservationOverflow, !pendingOverflow,
      let channel,
      channel.limits.maximumPendingSendCount >= 3,
      channel.limits.maximumPendingSendBytes >= requiredPendingBytes,
      channel.limits.maximumSingleSendBytes >= maximumEventSendBytes,
      channel.limits.maximumSingleSendBytes >= controlFrameBytes
    else {
      gate.close()
      finish(with: SDKSessionAdmissionError(.invalidLocalConfiguration))
      continuation.resume(throwing: SDKSessionAdmissionError(.invalidLocalConfiguration))
      return
    }

    policyConsumerOwner = .activeRunner
    pendingActivation = PendingActivation(token: token, gate: gate, continuation: continuation)
    let operationGate = SDKActiveOperationGate(hooks: dependencies.operationGateHooks)
    let liveOperations = dependencies.bindLiveOperations(owner, channel, operationGate)
    activeAppMaximumRates = appMaximumRates
    activeLimits = limits
    activeDependencies = dependencies
    activeLiveOperations = liveOperations
    activeOperationGate = operationGate
    let wakeToken = SDKOutboundWakeToken()
    activeWakeToken = wakeToken
    let bindingToken = SDKActiveBindingToken()
    activeBindingToken = bindingToken
    let signalIngress = SDKOutboundSignalIngress { [weak self] in
      Task { await self?.receiveOutboundSignal(bindingToken: bindingToken) }
    }
    activeSignalIngress = signalIngress
    state = .bindingActiveOwner
    startDeadline(
      seconds: limits.initialPolicyTimeoutSeconds,
      failure: .policyNegotiationTimedOut,
      sleep: dependencies.sleep
    )
    ingress.pauseNonterminalDrain()

    Task { [weak self] in
      await dependencies.beforeWakeRegistration()
      let result: Result<SDKOutboundWakeRegistrationResult, Error>
      do {
        result = .success(
          try await liveOperations.registerWake(
            wakeToken,
            { signalIngress.signal() },
            limits.maximumOutboundServiceUnitsPerTurn
          )
        )
      } catch {
        result = .failure(error)
      }
      await self?.completeActiveOwnerBinding(
        token: bindingToken,
        wakeToken: wakeToken,
        liveOperations: liveOperations,
        result: result
      )
    }
  }

  private func completeActiveOwnerBinding(
    token: SDKActiveBindingToken,
    wakeToken: SDKOutboundWakeToken,
    liveOperations: SDKActiveLiveOperations,
    result: Result<SDKOutboundWakeRegistrationResult, Error>
  ) {
    guard activeBindingToken === token, terminalError == nil else {
      if case .success(let value) = result, value.installed {
        Task { await liveOperations.removeWake(wakeToken) }
      }
      return
    }
    activeBindingToken = nil
    switch result {
    case .failure:
      finish(with: SDKSessionAdmissionError(.invalidLocalConfiguration))
    case .success(let registration):
      guard registration.installed else {
        let code: SDKSessionAdmissionError.Code =
          registration.schedule == .ownerUnavailable ? .ownerUnavailable : .cancelled
        finish(with: SDKSessionAdmissionError(code))
        return
      }
      switch registration.schedule {
      case .ownerUnavailable:
        finish(with: SDKSessionAdmissionError(.ownerUnavailable))
      case .clockFailed:
        finish(with: SDKSessionAdmissionError(.clockFailed))
      case .terminalFirst:
        finish(with: SDKSessionAdmissionError(.cancelled))
      case .available(let observation):
        state = .negotiatingPolicy
        outboundWorkRequested = outboundWorkRequested || observation.dueWorkRemains
        ingress.resumeNonterminalDrain()
        consumeBufferedRunnerPolicies()
        if state == .negotiatingPolicy, outboundWorkRequested {
          scheduleOwnerAvailabilityRefreshIfNeeded()
        }
      }
    }
  }

  private func receiveOutboundSignal(bindingToken: SDKActiveBindingToken) {
    defer { activeSignalIngress?.finishRoutingTurn() }
    guard terminalError == nil else { return }
    if activeBindingToken != nil, activeBindingToken !== bindingToken { return }
    outboundWorkRequested = true
    if state == .negotiatingPolicy {
      scheduleOwnerAvailabilityRefreshIfNeeded()
    } else if state == .active {
      scheduleOutboundDrainIfNeeded()
    }
  }

  private func scheduleOwnerAvailabilityRefreshIfNeeded() {
    guard state == .negotiatingPolicy, terminalError == nil, ownerRefreshTask == nil,
      outboundWorkRequested, let activeLimits, let liveOperations = activeLiveOperations,
      let dependencies = activeDependencies
    else { return }
    outboundWorkRequested = false
    outboundTurnStarts = Self.saturatedSum(outboundTurnStarts, 1)
    let token = SDKActiveOwnerRefreshToken()
    ownerRefreshToken = token
    ownerRefreshTask = Task { [weak self] in
      let schedule = await liveOperations.observeSchedule(
        activeLimits.maximumOutboundServiceUnitsPerTurn
      )
      await dependencies.beforeOwnerRefreshCompletion()
      await self?.completeOwnerAvailabilityRefresh(token: token, schedule: schedule)
    }
  }

  private func completeOwnerAvailabilityRefresh(
    token: SDKActiveOwnerRefreshToken,
    schedule: SDKOutboundScheduleResult
  ) {
    guard ownerRefreshToken === token else { return }
    ownerRefreshToken = nil
    ownerRefreshTask = nil
    guard terminalError == nil else { return }
    switch schedule {
    case .ownerUnavailable:
      finish(with: SDKSessionAdmissionError(.ownerUnavailable))
    case .clockFailed:
      finish(with: SDKSessionAdmissionError(.clockFailed))
    case .terminalFirst:
      break
    case .available(let observation):
      if state == .negotiatingPolicy, !deferredPolicyOffers.isEmpty {
        outboundWorkRequested = outboundWorkRequested || observation.dueWorkRemains
        let initialOffer = deferredPolicyOffers.removeFirst()
        do {
          try activateInitialPolicy(initialOffer)
          try applyDeferredPoliciesIfIdle()
        } catch let error as SDKSessionAdmissionError {
          finish(with: error)
        } catch {
          finish(with: SDKSessionAdmissionError(.protocolViolation))
        }
      } else if state == .negotiatingPolicy,
        outboundWorkRequested || observation.dueWorkRemains
      {
        outboundWorkRequested = true
        scheduleOwnerAvailabilityRefreshIfNeeded()
      } else if state == .active {
        outboundWorkRequested = true
        scheduleOutboundDrainIfNeeded()
      }
    }
  }

  private func cancelActiveRun(token: SDKActiveRunToken) {
    guard pendingActivation?.token === token else { return }
    finish(with: SDKSessionAdmissionError(.cancelled))
  }

  private func registerTerminationObservation(
    token: SDKActiveTerminationToken,
    cancellationGate gate: SDKSessionPullCancellationGate,
    continuation: CheckedContinuation<SDKSessionAdmissionError.Code, Error>
  ) {
    let claimed = gate.claim { [weak self] in
      Task { await self?.cancelTerminationObservation(token: token) }
    }
    guard claimed else {
      gate.close()
      continuation.resume(throwing: SDKSessionAdmissionError(.terminationWaitCancelled))
      return
    }
    if let terminalError {
      gate.close()
      continuation.resume(returning: terminalError.code)
      return
    }
    guard pendingTerminationObservation == nil else {
      gate.close()
      continuation.resume(throwing: SDKSessionAdmissionError(.terminationWaitAlreadyStarted))
      return
    }
    pendingTerminationObservation = PendingTerminationObservation(
      token: token,
      gate: gate,
      continuation: continuation
    )
  }

  private func cancelTerminationObservation(token: SDKActiveTerminationToken) {
    guard let pendingTerminationObservation,
      pendingTerminationObservation.token === token
    else { return }
    activeLiveOperations?.observerCancellation()
    self.pendingTerminationObservation = nil
    pendingTerminationObservation.gate.close()
    pendingTerminationObservation.continuation.resume(
      throwing: SDKSessionAdmissionError(.terminationWaitCancelled)
    )
  }

  private func cancelPolicyPull(token: SDKSessionPullToken) {
    guard let pendingPull, pendingPull.token === token else { return }
    self.pendingPull = nil
    pendingPull.gate.close()
    pendingPull.continuation.resume(throwing: SDKSessionAdmissionError(.pullCancelled))
  }

  private func startChannel() async {
    guard terminalError == nil, let channel else { return }
    do {
      try await channel.start()
    } catch {
      finish(with: SDKSessionAdmissionError(.transportFailed))
    }
  }

  private func receiveChannelEvent(_ event: SecureByteChannelEvent) {
    switch event {
    case .stateChanged(.ready):
      guard state == .connecting, !helloSent, let channel, let localHelloBytes else {
        finish(with: SDKSessionAdmissionError(.protocolViolation))
        return
      }
      do {
        try channel.admitSend(localHelloBytes)
        helloSent = true
        self.localHelloBytes = nil
        state = .exchangingHello
      } catch {
        finish(with: SDKSessionAdmissionError(.transportFailed))
      }
    case .stateChanged(.setup):
      finish(with: SDKSessionAdmissionError(.protocolViolation))
    case .stateChanged(.preparing), .stateChanged(.closing), .stateChanged(.failed),
      .stateChanged(.cancelled):
      break
    case .sendCompleted:
      activeLiveOperations?.mailboxCompletion()
      activeSignalIngress?.signal()
    case .received(let data):
      receiveBytes(data)
    case .terminated(let transportError):
      let code: SDKSessionAdmissionError.Code =
        transportError.code == .cancelled && channelCancellationRequested
        ? .cancelled : .transportFailed
      finish(with: SDKSessionAdmissionError(code), cancelChannel: false)
    }
  }

  private func receiveBytes(_ data: Data) {
    guard
      state == .exchangingHello || state == .awaitingApproval || state == .admitted
        || state == .negotiatingPolicy || state == .active
    else {
      finish(with: SDKSessionAdmissionError(.protocolViolation))
      return
    }
    consumeSessionBytes(data)
  }

  private func consumeSessionBytes(_ data: Data) {
    var decoder = frameDecoder
    var mappedFailure: SDKSessionAdmissionError?
    do {
      let maximumFrames = activeLimits?.maximumCompletedFramesPerReceive ?? Int.max
      let exceededFrameLimit = try decoder.consumeBounded(
        data,
        maximumCompletedFrames: maximumFrames,
        preflightLane: { lane in
          if lane == .event, self.state != .active {
            throw WireProtocolError(
              code: .phaseViolation,
              path: "lane",
              message: "Event lane is unavailable before the active event pump."
            )
          }
        },
        onFrame: { [self] frame in
          do {
            try process(frame: frame)
          } catch let error as SDKSessionAdmissionError {
            mappedFailure = error
            throw error
          } catch let error as WireProtocolError {
            let mapped = SDKSessionAdmissionError(Self.map(wireError: error))
            mappedFailure = mapped
            throw error
          } catch {
            let mapped = SDKSessionAdmissionError(.protocolViolation)
            mappedFailure = mapped
            throw error
          }
        }
      )
      frameDecoder = decoder
      if exceededFrameLimit {
        finish(with: SDKSessionAdmissionError(.activeWorkLimitExceeded))
        return
      }
      if let terminal = ingress.latchedTerminal {
        receiveLatchedTerminal(terminal)
      } else if provisionalAdmission != nil {
        commitProvisionalAdmission()
      }
    } catch let wireError as WireProtocolError {
      frameDecoder = decoder
      finish(with: mappedFailure ?? SDKSessionAdmissionError(Self.map(wireError: wireError)))
    } catch {
      frameDecoder = decoder
      finish(with: mappedFailure ?? SDKSessionAdmissionError(.protocolViolation))
    }
  }

  private func receiveLatchedTerminal(_ item: SDKSessionChannelIngress.Item) {
    switch item {
    case .overflow:
      finish(with: SDKSessionAdmissionError(.ingressOverflow))
    case .channel(.terminated(let transportError)):
      let code: SDKSessionAdmissionError.Code =
        transportError.code == .cancelled && channelCancellationRequested
        ? .cancelled : .transportFailed
      finish(with: SDKSessionAdmissionError(code), cancelChannel: false)
    case .channel(.stateChanged), .channel(.received), .channel(.sendCompleted):
      break
    }
  }

  private func process(frame: WireFrame) throws {
    let encodedByteCount = try Self.encodedByteCount(for: frame)
    if provisionalAdmission != nil || state == .admitted || state == .negotiatingPolicy
      || state == .active
    {
      if state != .active { try chargeHandoff(items: 1, bytes: encodedByteCount) }
      try processHandoffFrame(frame, encodedByteCount: encodedByteCount)
      return
    }

    try chargeHandshake(items: 1, bytes: encodedByteCount)
    switch state {
    case .exchangingHello:
      let message = try preHandshakeCodec.decode(frame: frame)
      switch message {
      case .hello(let remoteHello):
        guard remoteHello.role == .viewer else {
          throw SDKSessionAdmissionError(.incompatiblePeer)
        }
        let remoteDiscriminator = ViewerDiscoveryDiscriminator(
          viewerInstallationID: remoteHello.installationID
        )
        guard remoteDiscriminator == discoveredDiscriminator else {
          throw SDKSessionAdmissionError(.viewerIdentityMismatch)
        }
        discoveredDiscriminator = nil
        guard let localHello else {
          throw SDKSessionAdmissionError(.protocolViolation)
        }
        let result = try WireNegotiator.negotiate(local: localHello, remote: remoteHello)
        let codec = try WireSessionCodec(negotiation: result, baseLimits: wireLimits)
        negotiation = result
        sessionCodec = codec
        state = .awaitingApproval
      case .error, .disconnect:
        throw SDKSessionAdmissionError(.remoteClosed)
      }
    case .awaitingApproval:
      try processApprovalFrame(frame)
    case .idle, .discovering, .transferred, .connecting, .admitted, .bindingActiveOwner,
      .negotiatingPolicy, .active, .failed, .cancelled:
      throw SDKSessionAdmissionError(.protocolViolation)
    }
  }

  private func processApprovalFrame(_ frame: WireFrame) throws {
    guard let codec = sessionCodec, let negotiation, let localHello else {
      throw SDKSessionAdmissionError(.protocolViolation)
    }
    let message = try codec.decode(frame: frame, phase: .awaitingApproval)
    switch message.type {
    case .helloAcknowledged:
      let acknowledgement = try codec.decode(WireHelloAcknowledgement.self, from: message)
      try WireNegotiator.validate(acknowledgement: acknowledgement, against: negotiation)
      guard let epoch = UUID(uuidString: acknowledgement.sessionEpoch.rawValue) else {
        throw SDKSessionAdmissionError(.protocolViolation)
      }
      provisionalAdmission = ProvisionalAdmission(
        route: SDKSessionRoute(
          sessionEpoch: epoch,
          viewerID: negotiation.viewerInstallationID.rawValue,
          appID: localHello.installationID.rawValue
        ),
        negotiation: negotiation
      )
      self.localHello = nil
    case .connectionRejected:
      _ = try codec.decode(WireConnectionRejected.self, from: message)
      throw SDKSessionAdmissionError(.viewerRejected)
    case .ping:
      let ping = try codec.decode(WirePing.self, from: message)
      let pong = try codec.encode(WirePong(nonce: ping.nonce), phase: .awaitingApproval)
      try chargeHandshake(items: 1, bytes: pong.count)
      try admitResponse(pong)
    case .pong:
      _ = try codec.decode(WirePong.self, from: message)
    case .error:
      _ = try codec.decode(WireErrorPayload.self, from: message)
      throw SDKSessionAdmissionError(.remoteClosed)
    case .disconnect:
      _ = try codec.decode(WireDisconnect.self, from: message)
      throw SDKSessionAdmissionError(.remoteClosed)
    default:
      throw SDKSessionAdmissionError(.protocolViolation)
    }
  }

  private func processHandoffFrame(
    _ frame: WireFrame,
    encodedByteCount: Int
  ) throws {
    guard let codec = sessionCodec else {
      throw SDKSessionAdmissionError(.protocolViolation)
    }
    let phase: WireSessionPhase = state == .active ? .active : .negotiatingPolicy
    let message = try codec.decode(frame: frame, phase: phase)
    switch message.type {
    case .flowPolicyOffer:
      let value = try codec.decode(WireFlowPolicyOffer.self, from: message)
      try deliverPolicy(.offer(value), encodedByteCount: encodedByteCount)
    case .flowPolicyAccepted:
      let value = try codec.decode(WireFlowPolicyAccepted.self, from: message)
      try deliverPolicy(.accepted(value), encodedByteCount: encodedByteCount)
    case .event:
      guard state == .active else { throw SDKSessionAdmissionError(.protocolViolation) }
      let payload = try codec.decode(WireEventPayload.self, from: message)
      try admitIncomingRecords([payload.record])
    case .eventBatch:
      guard state == .active else { throw SDKSessionAdmissionError(.protocolViolation) }
      let payload = try codec.decode(WireEventBatchPayload.self, from: message)
      try admitIncomingRecords(payload.records)
    case .eventDropSummary:
      guard state == .active else { throw SDKSessionAdmissionError(.protocolViolation) }
      let summary = try codec.decode(WireDropSummaryPayload.self, from: message)
      remoteOverflowDropped = Self.saturatedSum(remoteOverflowDropped, summary.overflowDropped)
      remoteExpired = Self.saturatedSum(remoteExpired, summary.expired)
      remoteCoalesced = Self.saturatedSum(remoteCoalesced, summary.coalesced)
    case .ping:
      let ping = try codec.decode(WirePing.self, from: message)
      let pong = try codec.encode(WirePong(nonce: ping.nonce), phase: phase)
      if state != .active { try chargeHandoff(items: 1, bytes: pong.count) }
      try admitResponse(pong)
    case .pong:
      _ = try codec.decode(WirePong.self, from: message)
    case .error:
      _ = try codec.decode(WireErrorPayload.self, from: message)
      throw SDKSessionAdmissionError(.remoteClosed)
    case .disconnect:
      _ = try codec.decode(WireDisconnect.self, from: message)
      throw SDKSessionAdmissionError(.remoteClosed)
    default:
      throw SDKSessionAdmissionError(.protocolViolation)
    }
  }

  private func admitIncomingRecords(_ records: [WireEventRecord]) throws {
    guard !records.isEmpty, let liveOperations = activeLiveOperations, let route,
      var validator = incomingSequenceValidator, var queue = incomingQueue,
      let activeLimits
    else { throw SDKSessionAdmissionError(.invalidLocalConfiguration) }
    let epoch = try SessionEpoch(rawValue: route.sessionEpoch.nearWireCanonicalString)
    let source = EventEndpoint(role: .viewer, id: try EndpointID(rawValue: route.viewerID))
    let target = EventEndpoint(role: .app, id: try EndpointID(rawValue: route.appID))
    guard let receivedAt = liveOperations.clockNanoseconds() else {
      throw SDKSessionAdmissionError(.ownerUnavailable)
    }
    var items: [SDKIncomingEventItem] = []
    items.reserveCapacity(records.count)
    for record in records {
      let envelope = record.envelope
      guard envelope.sessionEpoch == epoch else {
        throw SDKSessionAdmissionError(.routeMismatch)
      }
      guard envelope.direction == .viewerToApp else {
        throw SDKSessionAdmissionError(.sequenceViolation)
      }
      guard envelope.source == source, envelope.target == target else {
        throw SDKSessionAdmissionError(.routeMismatch)
      }
      do {
        try validator.validate(envelope)
      } catch {
        throw SDKSessionAdmissionError(.sequenceViolation)
      }
      let received: WireReceivedEvent
      do {
        received = try record.receiverEvent(receivedAtNanoseconds: receivedAt)
      } catch {
        throw SDKSessionAdmissionError(.clockFailed)
      }
      let charge: Int
      do {
        charge = try record.deterministicEncodedByteCount()
      } catch {
        throw SDKSessionAdmissionError(.protocolViolation)
      }
      items.append(SDKIncomingEventItem(received: received, encodedByteCount: charge))
    }
    let existingCount = queue.snapshot.count + (incomingInFlight == nil ? 0 : 1)
    let existingBytes = queue.snapshot.encodedBytes + (incomingInFlight?.encodedByteCount ?? 0)
    var incomingBytes = 0
    for item in items {
      let (sum, overflow) = incomingBytes.addingReportingOverflow(item.encodedByteCount)
      guard !overflow else { throw SDKSessionAdmissionError(.activeIngressOverflow) }
      incomingBytes = sum
    }
    let (combinedCount, countOverflow) = existingCount.addingReportingOverflow(items.count)
    let (combinedBytes, byteOverflow) = existingBytes.addingReportingOverflow(incomingBytes)
    guard !countOverflow, !byteOverflow, combinedCount <= activeLimits.maximumIncomingEvents,
      combinedBytes <= activeLimits.maximumIncomingEncodedBytes
    else { throw SDKSessionAdmissionError(.activeIngressOverflow) }
    try queue.appendAtomically(items)
    incomingQueue = queue
    incomingSequenceValidator = validator
    scheduleIncomingWorkIfNeeded()
  }

  private func deliverPolicy(
    _ message: SDKSessionPolicyMessage,
    encodedByteCount: Int
  ) throws {
    if policyConsumerOwner == .activeRunner {
      try receiveRunnerPolicy(message)
      return
    }
    if let pendingPull {
      self.pendingPull = nil
      pendingPull.gate.close()
      pendingPull.continuation.resume(returning: message)
      return
    }
    let (newCount, countOverflow) = policyFIFO.count.addingReportingOverflow(1)
    let (newBytes, byteOverflow) = policyFIFOBytes.addingReportingOverflow(encodedByteCount)
    guard !countOverflow, !byteOverflow,
      newCount <= admissionLimits.maximumHandoffMessages,
      newBytes <= admissionLimits.maximumHandoffBytes
    else {
      throw SDKSessionAdmissionError(.handoffBufferOverflow)
    }
    policyFIFO.append(
      SDKBufferedPolicyMessage(message: message, encodedByteCount: encodedByteCount)
    )
    policyFIFOBytes = newBytes
  }

  private func consumeBufferedRunnerPolicies() {
    while terminalError == nil, !policyFIFO.isEmpty {
      let item = policyFIFO.removeFirst()
      policyFIFOBytes -= item.encodedByteCount
      do {
        try receiveRunnerPolicy(item.message)
      } catch let error as SDKSessionAdmissionError {
        finish(with: error)
      } catch {
        finish(with: SDKSessionAdmissionError(.protocolViolation))
      }
    }
  }

  private func receiveRunnerPolicy(_ message: SDKSessionPolicyMessage) throws {
    guard state == .negotiatingPolicy || state == .active else {
      throw SDKSessionAdmissionError(.protocolViolation)
    }
    guard case .offer(let offer) = message else {
      throw SDKSessionAdmissionError(.protocolViolation)
    }
    if state == .active {
      guard let activeLimits else {
        throw SDKSessionAdmissionError(.invalidLocalConfiguration)
      }
      if outboundDrainTask != nil || incomingPublicationTask != nil {
        guard deferredPolicyOffers.count < activeLimits.maximumDeferredPolicyTransactions else {
          throw SDKSessionAdmissionError(.activeWorkLimitExceeded)
        }
        deferredPolicyOffers.append(offer)
      } else {
        cancelOutboundDecision()
        try applyDynamicPolicy(offer)
        outboundTransportBlock = nil
        outboundWorkRequested = true
        scheduleOutboundDrainIfNeeded()
        scheduleIncomingWorkIfNeeded()
      }
      return
    }
    if ownerRefreshTask != nil || outboundWorkRequested {
      guard let activeLimits,
        deferredPolicyOffers.count < activeLimits.maximumDeferredPolicyTransactions
      else {
        throw SDKSessionAdmissionError(.activeWorkLimitExceeded)
      }
      deferredPolicyOffers.append(offer)
    } else {
      try activateInitialPolicy(offer)
    }
  }

  private func activateInitialPolicy(_ offer: WireFlowPolicyOffer) throws {
    guard let appMaximumRates = activeAppMaximumRates, let codec = sessionCodec,
      let dependencies = activeDependencies, let pendingActivation
    else {
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
    let viewerRates = DirectionalEventRates(
      appUplink: try EventRateLimit(
        eventsPerSecond: offer.policy.appUplinkEventsPerSecond
      ),
      appDownlink: try EventRateLimit(
        eventsPerSecond: offer.policy.appDownlinkEventsPerSecond
      )
    )
    let effective = try DirectionalEventRates.effective(
      viewerRequested: viewerRates,
      appMaximum: appMaximumRates
    )
    let acceptedPolicy = try WireFlowPolicy(
      appUplinkEventsPerSecond: effective.appUplink.eventsPerSecond,
      appDownlinkEventsPerSecond: effective.appDownlink.eventsPerSecond
    )
    let acceptedBytes = try codec.encode(
      WireFlowPolicyAccepted(policy: acceptedPolicy),
      phase: .negotiatingPolicy
    )
    guard let liveOperations = activeLiveOperations else {
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
    guard let now = liveOperations.clockNanoseconds() else {
      throw SDKSessionAdmissionError(.ownerUnavailable)
    }
    let plannedUplink = try EventTokenBucket(
      rate: effective.appUplink,
      burstDurationSeconds: 0.25,
      startNanoseconds: now
    )
    let plannedDownlink = try EventTokenBucket(
      rate: effective.appDownlink,
      burstDurationSeconds: 0.25,
      startNanoseconds: now
    )
    dependencies.beforeActivationCommit()
    guard pendingActivation.gate.closeRegisteredClaim() else {
      finish(with: SDKSessionAdmissionError(.cancelled))
      throw SDKSessionAdmissionError(.cancelled)
    }
    do {
      try liveOperations.admitSend(acceptedBytes)
    } catch {
      throw SDKSessionAdmissionError(.transportFailed)
    }
    uplinkBucket = plannedUplink
    downlinkBucket = plannedDownlink
    guard let route,
      let epoch = try? SessionEpoch(rawValue: route.sessionEpoch.nearWireCanonicalString)
    else {
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
    outboundSequenceCounter = WireSequenceCounter(
      sessionEpoch: epoch,
      direction: .appToViewer
    )
    incomingSequenceValidator = WireSequenceValidator(
      sessionEpoch: epoch,
      direction: .viewerToApp
    )
    guard let activeLimits else {
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
    incomingQueue = SDKIncomingEventQueue(
      maximumCount: activeLimits.maximumIncomingEvents,
      maximumEncodedBytes: activeLimits.maximumIncomingEncodedBytes
    )
    state = .active
    cancelDeadline()
    self.pendingActivation = nil
    dependencies.beforeActivationResume()
    pendingActivation.continuation.resume()
    outboundWorkRequested = true
    scheduleOutboundDrainIfNeeded()
    scheduleIncomingWorkIfNeeded()
  }

  private func applyDynamicPolicy(_ offer: WireFlowPolicyOffer) throws {
    guard let appMaximumRates = activeAppMaximumRates, let codec = sessionCodec,
      var plannedUplink = uplinkBucket, var plannedDownlink = downlinkBucket
    else {
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
    let effective: DirectionalEventRates
    do {
      effective = try DirectionalEventRates.effective(
        viewerRequested: DirectionalEventRates(
          appUplink: try EventRateLimit(
            eventsPerSecond: offer.policy.appUplinkEventsPerSecond
          ),
          appDownlink: try EventRateLimit(
            eventsPerSecond: offer.policy.appDownlinkEventsPerSecond
          )
        ),
        appMaximum: appMaximumRates
      )
    } catch {
      throw SDKSessionAdmissionError(.protocolViolation)
    }
    let accepted: Data
    do {
      accepted = try codec.encode(
        WireFlowPolicyAccepted(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: effective.appUplink.eventsPerSecond,
            appDownlinkEventsPerSecond: effective.appDownlink.eventsPerSecond
          )
        ),
        phase: .active
      )
    } catch {
      throw SDKSessionAdmissionError(.protocolViolation)
    }
    guard let liveOperations = activeLiveOperations else {
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
    guard let commitTime = liveOperations.clockNanoseconds() else {
      throw SDKSessionAdmissionError(.ownerUnavailable)
    }
    do {
      try plannedUplink.reconfigure(rate: effective.appUplink, atNanoseconds: commitTime)
      try plannedDownlink.reconfigure(rate: effective.appDownlink, atNanoseconds: commitTime)
    } catch {
      throw SDKSessionAdmissionError(.clockFailed)
    }
    do {
      try liveOperations.admitSend(accepted)
    } catch {
      throw SDKSessionAdmissionError(.transportFailed)
    }
    uplinkBucket = plannedUplink
    downlinkBucket = plannedDownlink
  }

  private func scheduleOutboundDrainIfNeeded() {
    guard state == .active, terminalError == nil, outboundDrainTask == nil,
      ownerRefreshTask == nil,
      deferredPolicyOffers.isEmpty, outboundWorkRequested,
      let activeLimits, let liveOperations = activeLiveOperations,
      let route, let codec = sessionCodec, let bucket = uplinkBucket,
      let sequenceCounter = outboundSequenceCounter, let dependencies = activeDependencies
    else { return }
    outboundWorkRequested = false
    outboundTurnStarts = Self.saturatedSum(outboundTurnStarts, 1)
    cancelOutboundDecision()
    let token = SDKActiveOutboundDrainToken()
    outboundDrainToken = token
    let blocked = outboundTransportBlock
    let controlFrameBytes = wireLimits.frame.maximumEncodedFrameBytes(for: .control)
    let (reservedBytes, reservationOverflow) = controlFrameBytes.multipliedReportingOverflow(by: 2)
    guard !reservationOverflow else {
      finish(with: SDKSessionAdmissionError(.invalidLocalConfiguration))
      return
    }
    outboundDrainTask = Task { [weak self] in
      let result: Result<OutboundTurnResult, SDKSessionAdmissionError>
      do {
        var refreshedBucket = bucket
        guard let now = liveOperations.clockNanoseconds() else {
          throw SDKSessionAdmissionError(.ownerUnavailable)
        }
        let allowance: Int
        do {
          allowance = try refreshedBucket.availableWholeTokens(atNanoseconds: now)
        } catch {
          throw SDKSessionAdmissionError(.clockFailed)
        }

        if let blocked,
          !liveOperations.canAdmitSend(
            blocked.encodedByteCount,
            blocked.reservedPendingSendCount,
            blocked.reservedPendingSendBytes
          )
        {
          result = .success(
            .blocked(
              await liveOperations.observeSchedule(
                activeLimits.maximumOutboundServiceUnitsPerTurn
              )
            )
          )
        } else {
          guard
            let drain = await liveOperations.drain(
              route,
              codec,
              sequenceCounter,
              activeLimits.maximumOutboundServiceUnitsPerTurn,
              allowance,
              activeLimits.maximumOutboundAccountedBytesPerTurn,
              2,
              reservedBytes
            )
          else {
            throw SDKSessionAdmissionError(.ownerUnavailable)
          }
          result = .success(.drained(drain, refreshedBucket: refreshedBucket))
        }
      } catch let error as SDKSessionAdmissionError {
        result = .failure(error)
      } catch {
        result = .failure(SDKSessionAdmissionError(.invalidLocalConfiguration))
      }
      await dependencies.beforeOutboundTurnCompletion()
      await self?.completeOutboundTurn(token: token, result: result)
      await dependencies.afterOutboundTurnCompletion()
    }
  }

  private func completeOutboundTurn(
    token: SDKActiveOutboundDrainToken,
    result: Result<OutboundTurnResult, SDKSessionAdmissionError>
  ) {
    guard outboundDrainToken === token else { return }
    outboundDrainToken = nil
    outboundDrainTask = nil
    guard terminalError == nil, state == .active else { return }

    switch result {
    case .failure(let error):
      finish(with: error)
    case .success(.blocked(let schedule)):
      do {
        try applyDeferredPoliciesIfIdle()
      } catch let error as SDKSessionAdmissionError {
        finish(with: error)
        return
      } catch {
        finish(with: SDKSessionAdmissionError(.protocolViolation))
        return
      }
      guard terminalError == nil else { return }
      completeBlockedSchedule(schedule)
    case .success(.drained(let drain, var refreshedBucket)):
      guard drain.ownerAvailable else {
        finish(with: SDKSessionAdmissionError(.ownerUnavailable))
        return
      }
      if drain.stoppedByTerminal { return }
      if let failure = drain.failure {
        finish(with: SDKSessionAdmissionError(map(activeDrainFailure: failure)))
        return
      }
      refreshedBucket.consumePrevalidated(drain.acceptedEventIDs.count)
      uplinkBucket = refreshedBucket
      outboundSequenceCounter = drain.plannedSequenceCounter
      outboundTransportBlock = drain.transportBlock

      do {
        try applyDeferredPoliciesIfIdle()
      } catch let error as SDKSessionAdmissionError {
        finish(with: error)
        return
      } catch {
        finish(with: SDKSessionAdmissionError(.protocolViolation))
        return
      }
      guard terminalError == nil else { return }

      if let block = outboundTransportBlock, let liveOperations = activeLiveOperations,
        liveOperations.canAdmitSend(
          block.encodedByteCount,
          block.reservedPendingSendCount,
          block.reservedPendingSendBytes
        )
      {
        outboundTransportBlock = nil
        outboundWorkRequested = true
      } else if drain.dueWorkRemains {
        outboundWorkRequested = true
      }
      if outboundWorkRequested {
        scheduleOutboundDrainIfNeeded()
      } else if outboundTransportBlock != nil {
        scheduleOutboundBlockedDecision(
          nextExpirationDeadlineNanoseconds: drain.nextExpirationDeadlineNanoseconds
        )
      } else {
        scheduleOutboundDecision(
          eligibleWorkRemains: drain.eligibleWorkRemains,
          nextExpirationDeadlineNanoseconds: drain.nextExpirationDeadlineNanoseconds
        )
      }
      scheduleIncomingWorkIfNeeded()
    }
  }

  private func completeBlockedSchedule(_ schedule: SDKOutboundScheduleResult) {
    switch schedule {
    case .ownerUnavailable:
      finish(with: SDKSessionAdmissionError(.ownerUnavailable))
    case .clockFailed:
      finish(with: SDKSessionAdmissionError(.clockFailed))
    case .terminalFirst:
      break
    case .available(let observation):
      guard let block = outboundTransportBlock else {
        outboundWorkRequested = true
        scheduleOutboundDrainIfNeeded()
        return
      }
      let capacityAvailable =
        activeLiveOperations?.canAdmitSend(
          block.encodedByteCount,
          block.reservedPendingSendCount,
          block.reservedPendingSendBytes
        ) == true
      if capacityAvailable || observation.nextFairCandidateID != block.candidateID {
        outboundTransportBlock = nil
        outboundWorkRequested = true
        scheduleOutboundDrainIfNeeded()
      } else {
        scheduleOutboundBlockedDecision(
          nextExpirationDeadlineNanoseconds: observation.nextExpirationDeadlineNanoseconds
        )
      }
    }
  }

  private func applyDeferredPolicies() throws {
    while !deferredPolicyOffers.isEmpty {
      let offer = deferredPolicyOffers.removeFirst()
      try applyDynamicPolicy(offer)
      outboundTransportBlock = nil
    }
  }

  private func scheduleOutboundDecision(
    eligibleWorkRemains: Bool,
    nextExpirationDeadlineNanoseconds: UInt64?
  ) {
    guard let liveOperations = activeLiveOperations, var bucket = uplinkBucket,
      let dependencies = activeDependencies
    else { return }
    guard let now = liveOperations.clockNanoseconds() else {
      finish(with: SDKSessionAdmissionError(.ownerUnavailable))
      return
    }
    let tokenDelay: UInt64?
    do {
      tokenDelay =
        eligibleWorkRemains
        ? try bucket.delayUntilNextTokenNanoseconds(atNanoseconds: now) : nil
    } catch {
      finish(with: SDKSessionAdmissionError(.clockFailed))
      return
    }
    uplinkBucket = bucket
    let expirationDelay = nextExpirationDeadlineNanoseconds.map {
      $0 > now ? $0 - now : 0
    }
    let delay: UInt64?
    switch (tokenDelay, expirationDelay) {
    case (let token?, let expiration?): delay = min(token, expiration)
    case (let token?, nil): delay = token
    case (nil, let expiration?): delay = expiration
    case (nil, nil): delay = nil
    }
    guard let delay else { return }
    if delay == 0 {
      outboundWorkRequested = true
      scheduleOutboundDrainIfNeeded()
      return
    }
    cancelOutboundDecision()
    let token = SDKActiveOutboundDecisionToken()
    outboundDecisionToken = token
    outboundDecisionTask = Task { [weak self] in
      do {
        try await dependencies.sleepNanoseconds(delay)
      } catch {
        return
      }
      await self?.outboundDecisionFired(token: token)
    }
  }

  private func scheduleOutboundBlockedDecision(
    nextExpirationDeadlineNanoseconds: UInt64?
  ) {
    guard let deadline = nextExpirationDeadlineNanoseconds,
      let liveOperations = activeLiveOperations,
      let dependencies = activeDependencies
    else {
      cancelOutboundDecision()
      return
    }
    guard let now = liveOperations.clockNanoseconds() else {
      finish(with: SDKSessionAdmissionError(.ownerUnavailable))
      return
    }
    let delay = deadline > now ? deadline - now : 0
    if delay == 0 {
      outboundWorkRequested = true
      scheduleOutboundDrainIfNeeded()
      return
    }
    cancelOutboundDecision()
    let token = SDKActiveOutboundDecisionToken()
    outboundDecisionToken = token
    outboundDecisionTask = Task { [weak self] in
      do {
        try await dependencies.sleepNanoseconds(delay)
      } catch {
        return
      }
      await self?.outboundDecisionFired(token: token)
    }
  }

  private func outboundDecisionFired(token: SDKActiveOutboundDecisionToken) {
    guard outboundDecisionToken === token, terminalError == nil else { return }
    outboundDecisionToken = nil
    outboundDecisionTask = nil
    outboundWorkRequested = true
    scheduleOutboundDrainIfNeeded()
  }

  private func cancelOutboundDecision() {
    outboundDecisionToken = nil
    outboundDecisionTask?.cancel()
    outboundDecisionTask = nil
  }

  private func map(
    activeDrainFailure: SDKActiveWireDrainFailure
  ) -> SDKSessionAdmissionError.Code {
    switch activeDrainFailure {
    case .clockFailed: return .clockFailed
    case .encodingFailed: return .outboundEncodingFailed
    case .invalidLimits: return .invalidLocalConfiguration
    case .sequenceFailed: return .sequenceViolation
    case .transportFailed: return .transportFailed
    }
  }

  private func scheduleIncomingWorkIfNeeded() {
    guard state == .active, terminalError == nil, incomingPublicationTask == nil,
      deferredPolicyOffers.isEmpty, let activeLimits,
      var queue = incomingQueue, var bucket = downlinkBucket,
      let liveOperations = activeLiveOperations, let dependencies = activeDependencies
    else { return }
    cancelIncomingDecision()
    guard let now = liveOperations.clockNanoseconds() else {
      finish(with: SDKSessionAdmissionError(.ownerUnavailable))
      return
    }
    let expiredCount: Int
    do {
      let expiredIDs = try queue.removeExpired(
        nowNanoseconds: now,
        maximumCount: activeLimits.maximumIncomingPublicationsPerTurn
      )
      expiredCount = expiredIDs.count
      localIncomingExpired = Self.saturatedSum(localIncomingExpired, UInt64(expiredIDs.count))
    } catch let error as SDKSessionAdmissionError {
      finish(with: error)
      return
    } catch {
      finish(with: SDKSessionAdmissionError(.clockFailed))
      return
    }
    incomingQueue = queue
    if expiredCount == activeLimits.maximumIncomingPublicationsPerTurn, queue.first != nil {
      scheduleIncomingDecision(delayNanoseconds: 0, dependencies: dependencies)
      return
    }
    if let deadline = queue.snapshot.nextDeadlineNanoseconds, deadline <= now {
      scheduleIncomingDecision(delayNanoseconds: 0, dependencies: dependencies)
      return
    }
    guard queue.first != nil else { return }

    let available: Int
    do {
      available = try bucket.availableWholeTokens(atNanoseconds: now)
    } catch {
      finish(with: SDKSessionAdmissionError(.clockFailed))
      return
    }
    downlinkBucket = bucket
    guard available > 0 else {
      scheduleIncomingTokenOrTTLDecision(
        now: now,
        queue: queue,
        bucket: bucket,
        dependencies: dependencies
      )
      return
    }
    guard let item = queue.popHead() else { return }
    incomingQueue = queue
    incomingInFlight = item
    let token = SDKActiveIncomingPublicationToken()
    incomingPublicationToken = token
    incomingPublicationTask = Task { [weak self] in
      await dependencies.beforeIncomingPublicationClaim()
      let result = await liveOperations.publishIncoming(item.received)
      await dependencies.beforeIncomingPublicationCompletion()
      await self?.completeIncomingPublication(
        token: token,
        selectedBucket: bucket,
        result: result
      )
      await dependencies.afterIncomingPublicationCompletion()
    }
  }

  private func completeIncomingPublication(
    token: SDKActiveIncomingPublicationToken,
    selectedBucket: EventTokenBucket,
    result: SDKActiveIncomingPublicationResult
  ) {
    guard incomingPublicationToken === token else { return }
    incomingPublicationToken = nil
    incomingPublicationTask = nil
    incomingInFlight = nil
    guard terminalError == nil, state == .active else { return }
    switch result {
    case .published:
      var committedBucket = selectedBucket
      committedBucket.consumePrevalidated(1)
      downlinkBucket = committedBucket
    case .expired:
      break
    case .ownerUnavailable:
      finish(with: SDKSessionAdmissionError(.ownerUnavailable))
      return
    case .terminalFirst:
      return
    case .clockFailed:
      finish(with: SDKSessionAdmissionError(.clockFailed))
      return
    }
    do {
      try applyDeferredPoliciesIfIdle()
    } catch let error as SDKSessionAdmissionError {
      finish(with: error)
      return
    } catch {
      finish(with: SDKSessionAdmissionError(.protocolViolation))
      return
    }
    scheduleIncomingWorkIfNeeded()
    outboundWorkRequested = true
    scheduleOutboundDrainIfNeeded()
  }

  private func scheduleIncomingTokenOrTTLDecision(
    now: UInt64,
    queue: SDKIncomingEventQueue,
    bucket: EventTokenBucket,
    dependencies: SDKActiveEventPumpDependencies
  ) {
    var planned = bucket
    let tokenDelay: UInt64?
    do {
      tokenDelay = try planned.delayUntilNextTokenNanoseconds(atNanoseconds: now)
    } catch {
      finish(with: SDKSessionAdmissionError(.clockFailed))
      return
    }
    downlinkBucket = planned
    let expiryDelay = queue.snapshot.nextDeadlineNanoseconds.map { $0 > now ? $0 - now : 0 }
    let delay: UInt64?
    switch (tokenDelay, expiryDelay) {
    case (let token?, let expiry?): delay = min(token, expiry)
    case (let token?, nil): delay = token
    case (nil, let expiry?): delay = expiry
    case (nil, nil): delay = nil
    }
    guard let delay else { return }
    scheduleIncomingDecision(delayNanoseconds: delay, dependencies: dependencies)
  }

  private func scheduleIncomingDecision(
    delayNanoseconds: UInt64,
    dependencies: SDKActiveEventPumpDependencies
  ) {
    cancelIncomingDecision()
    let token = SDKActiveIncomingDecisionToken()
    incomingDecisionToken = token
    incomingDecisionTask = Task { [weak self] in
      if delayNanoseconds > 0 {
        do {
          try await dependencies.sleepNanoseconds(delayNanoseconds)
        } catch {
          return
        }
      } else {
        await dependencies.beforeImmediateIncomingDecisionCompletion()
      }
      await self?.incomingDecisionFired(token: token)
    }
  }

  private func incomingDecisionFired(token: SDKActiveIncomingDecisionToken) {
    guard incomingDecisionToken === token, terminalError == nil else { return }
    incomingDecisionToken = nil
    incomingDecisionTask = nil
    scheduleIncomingWorkIfNeeded()
  }

  private func cancelIncomingDecision() {
    incomingDecisionToken = nil
    incomingDecisionTask?.cancel()
    incomingDecisionTask = nil
  }

  private func applyDeferredPoliciesIfIdle() throws {
    guard outboundDrainTask == nil, incomingPublicationTask == nil else { return }
    try applyDeferredPolicies()
  }

  private func commitProvisionalAdmission() {
    guard terminalError == nil, let provisionalAdmission, let waiter = resultWaiter else { return }
    self.provisionalAdmission = nil
    resultWaiter = nil
    attemptToken = nil
    state = .admitted
    route = provisionalAdmission.route
    admittedCapabilities = provisionalAdmission.negotiation.capabilities
    admittedMaximumEventBytes = provisionalAdmission.negotiation.maximumEventBytes
    negotiation = nil
    cancelDeadline()
    startDeadline(
      seconds: admissionLimits.pumpAttachmentTimeoutSeconds,
      failure: .pumpAttachmentTimedOut
    )
    let lifetime = SDKSessionLifetime(core: self, transitionGate: transitionGate)
    waiter.resume(
      returning: SDKAdmittedSession(
        route: provisionalAdmission.route,
        capabilities: provisionalAdmission.negotiation.capabilities,
        sendPolicies: provisionalAdmission.negotiation.sendPolicies,
        maximumEventBytes: provisionalAdmission.negotiation.maximumEventBytes,
        lifetime: lifetime
      )
    )
  }

  private func admitResponse(_ data: Data) throws {
    guard let channel else { throw SDKSessionAdmissionError(.transportFailed) }
    do {
      if let activeLiveOperations {
        try activeLiveOperations.admitSend(data)
      } else {
        try channel.admitSend(data)
      }
    } catch {
      throw SDKSessionAdmissionError(.transportFailed)
    }
  }

  private func chargeHandshake(items: Int, bytes: Int) throws {
    let (newItems, itemOverflow) = handshakeWorkItems.addingReportingOverflow(items)
    let (newBytes, byteOverflow) = handshakeWorkBytes.addingReportingOverflow(bytes)
    guard !itemOverflow, !byteOverflow,
      newItems <= admissionLimits.maximumHandshakeWorkItems,
      newBytes <= admissionLimits.maximumHandshakeWorkBytes
    else {
      throw SDKSessionAdmissionError(.handshakeWorkLimitExceeded)
    }
    handshakeWorkItems = newItems
    handshakeWorkBytes = newBytes
  }

  private func chargeHandoff(items: Int, bytes: Int) throws {
    let (newItems, itemOverflow) = handoffWorkItems.addingReportingOverflow(items)
    let (newBytes, byteOverflow) = handoffWorkBytes.addingReportingOverflow(bytes)
    guard !itemOverflow, !byteOverflow,
      newItems <= admissionLimits.maximumHandoffWorkItems,
      newBytes <= admissionLimits.maximumHandoffWorkBytes
    else {
      throw SDKSessionAdmissionError(.handoffWorkLimitExceeded)
    }
    handoffWorkItems = newItems
    handoffWorkBytes = newBytes
  }

  private func startDeadline(
    seconds: Int,
    failure: SDKSessionAdmissionError.Code,
    sleep deadlineSleep: (@Sendable (Int) async throws -> Void)? = nil
  ) {
    cancelDeadline()
    let token = SDKSessionDeadlineToken()
    deadlineToken = token
    let sleep = deadlineSleep ?? self.sleep
    deadlineTask = Task { [weak self] in
      do {
        try await sleep(seconds)
      } catch {
        return
      }
      await self?.deadlineFired(token: token, failure: failure)
    }
  }

  private func deadlineFired(
    token: SDKSessionDeadlineToken,
    failure: SDKSessionAdmissionError.Code
  ) {
    guard deadlineToken === token else { return }
    finish(with: SDKSessionAdmissionError(failure))
  }

  private func cancelDeadline() {
    deadlineToken = nil
    deadlineTask?.cancel()
    deadlineTask = nil
  }

  private func finish(
    with error: SDKSessionAdmissionError,
    cancelChannel: Bool = true
  ) {
    guard terminalError == nil else { return }
    _ = transitionGate.markTerminal(error.code)
    activeLiveOperations?.terminalClose()
    activeOperationGate?.close()
    terminalError = error
    state = error.code == .cancelled ? .cancelled : .failed
    attemptToken = nil
    provisionalAdmission = nil
    negotiation = nil
    route = nil
    sessionCodec = nil
    localHello = nil
    localHelloBytes = nil
    discoveredDiscriminator = nil
    let discovery = retainedDiscovery
    retainedDiscovery = nil
    discovery?.release()
    admittedCapabilities.removeAll(keepingCapacity: false)
    admittedMaximumEventBytes = 0
    cancelDeadline()
    ingress.stop()
    activeSignalIngress?.stop()
    activeSignalIngress = nil
    let wakeOperations = activeLiveOperations
    let wakeToken = activeWakeToken
    activeWakeToken = nil
    activeBindingToken = nil
    activeAppMaximumRates = nil
    activeLimits = nil
    activeDependencies = nil
    activeLiveOperations = nil
    activeOperationGate = nil
    uplinkBucket = nil
    downlinkBucket = nil
    outboundSequenceCounter = nil
    outboundDrainToken = nil
    outboundDrainTask?.cancel()
    outboundDrainTask = nil
    cancelOutboundDecision()
    outboundWorkRequested = false
    outboundTransportBlock = nil
    deferredPolicyOffers.removeAll(keepingCapacity: false)
    ownerRefreshToken = nil
    ownerRefreshTask?.cancel()
    ownerRefreshTask = nil
    incomingQueue?.removeAll()
    incomingQueue = nil
    incomingSequenceValidator = nil
    incomingInFlight = nil
    incomingPublicationToken = nil
    incomingPublicationTask?.cancel()
    incomingPublicationTask = nil
    cancelIncomingDecision()
    frameDecoder = WireFrameDecoder(limits: wireLimits.frame)
    preHandshakeCodec = WirePreHandshakeCodec(limits: wireLimits)
    policyFIFO.removeAll(keepingCapacity: false)
    policyFIFOBytes = 0

    if let waiter = resultWaiter {
      resultWaiter = nil
      waiter.resume(throwing: error)
    }
    if let pendingPull {
      self.pendingPull = nil
      pendingPull.gate.close()
      pendingPull.continuation.resume(throwing: error)
    }
    if let pendingActivation {
      self.pendingActivation = nil
      pendingActivation.gate.close()
      pendingActivation.continuation.resume(throwing: error)
    }
    if let pendingTerminationObservation {
      self.pendingTerminationObservation = nil
      if pendingTerminationObservation.gate.closeRegisteredClaim() {
        pendingTerminationObservation.continuation.resume(returning: error.code)
      } else {
        pendingTerminationObservation.continuation.resume(
          throwing: SDKSessionAdmissionError(.terminationWaitCancelled)
        )
      }
    }
    if let wakeOperations, let wakeToken {
      Task { await wakeOperations.removeWake(wakeToken) }
    }
    if cancelChannel, !channelCancellationRequested, let channel {
      channelCancellationRequested = true
      Task { await channel.cancel() }
    }
    self.channel = nil
  }

  private static func encodedByteCount(for frame: WireFrame) throws -> Int {
    let (count, overflow) = frame.payload.count.addingReportingOverflow(
      WireFrameLimits.encodedFrameOverheadBytes
    )
    guard !overflow else { throw SDKSessionAdmissionError(.protocolViolation) }
    return count
  }

  private static func saturatedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : sum
  }

  private static func map(wireError: WireProtocolError) -> SDKSessionAdmissionError.Code {
    switch wireError.code {
    case .incompatibleVersion, .invalidCodec, .invalidPolicy, .invalidRole, .noCommonCodec:
      return .incompatiblePeer
    case .acknowledgementEscalation, .arithmeticOverflow, .callbackFailed, .decoderFailed,
      .eventExpired, .frameTooLarge, .invalidBatch, .invalidCapability, .invalidClock,
      .invalidConfiguration, .invalidFrameLength, .invalidJSON, .invalidLane, .invalidMessage,
      .invalidMessageType, .invalidRate, .invalidSequence, .invalidText, .phaseViolation,
      .unsupportedMessageType:
      return .protocolViolation
    }
  }
}
