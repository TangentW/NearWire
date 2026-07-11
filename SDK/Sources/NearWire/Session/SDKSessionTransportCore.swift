import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
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

final class SDKAdmittedSession: @unchecked Sendable {
  let route: SDKSessionRoute
  let capabilities: Set<WireCapability>
  let sendPolicies: Set<WireSendPolicy>
  let maximumEventBytes: Int

  private let relay: SDKSessionCancellationRelay

  init(
    route: SDKSessionRoute,
    capabilities: Set<WireCapability>,
    sendPolicies: Set<WireSendPolicy>,
    maximumEventBytes: Int,
    relay: SDKSessionCancellationRelay
  ) {
    self.route = route
    self.capabilities = capabilities
    self.sendPolicies = sendPolicies
    self.maximumEventBytes = maximumEventBytes
    self.relay = relay
  }

  func attachEventPump() async throws -> SDKSessionPumpAttachment {
    try await relay.core.attachEventPump(relay: relay)
  }

  func cancel() {
    relay.requestCancellation()
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
  private let relay: SDKSessionCancellationRelay

  init(relay: SDKSessionCancellationRelay) {
    self.relay = relay
  }

  func nextPolicyMessage() async throws -> SDKSessionPolicyMessage {
    let gate = SDKSessionPullCancellationGate()
    return try await withTaskCancellationHandler {
      try await relay.core.nextPolicyMessage(cancellationGate: gate)
    } onCancel: {
      gate.cancel()
    }
  }

  func cancel() {
    relay.requestCancellation()
  }

  var transportCore: SDKSessionTransportCore { relay.core }
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

  private let ingress: SDKSessionChannelIngress
  private var localHello: WireHello?
  private var localHelloBytes: Data?
  private var discoveredDiscriminator: ViewerDiscoveryDiscriminator?
  private let wireLimits: WireProtocolLimits
  private let admissionLimits: SDKSessionAdmissionLimits
  private let sleep: @Sendable (Int) async throws -> Void

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

  init(
    ingress: SDKSessionChannelIngress,
    localHello: WireHello,
    localHelloBytes: Data,
    discoveredDiscriminator: ViewerDiscoveryDiscriminator,
    attemptToken: SDKSessionAttemptToken,
    wireLimits: WireProtocolLimits,
    admissionLimits: SDKSessionAdmissionLimits,
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
    guard let batch = ingress.takeBatch(maximumItems: Self.ingressDrainQuantum) else { return }
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
    relay: SDKSessionCancellationRelay
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
    return SDKSessionPumpAttachment(relay: relay)
  }

  func nextPolicyMessage(
    cancellationGate gate: SDKSessionPullCancellationGate
  ) async throws -> SDKSessionPolicyMessage {
    try await withCheckedThrowingContinuation { continuation in
      registerPolicyPull(gate: gate, continuation: continuation)
    }
  }

  func snapshot() -> Snapshot {
    Snapshot(
      state: state,
      retainedPolicyMessages: policyFIFO.count,
      hasPendingPolicyPull: pendingPull != nil,
      terminalCode: terminalError?.code,
      pumpAttached: pumpAttached
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
      .stateChanged(.cancelled), .sendCompleted:
      break
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
    guard state == .exchangingHello || state == .awaitingApproval || state == .admitted else {
      finish(with: SDKSessionAdmissionError(.protocolViolation))
      return
    }
    var decoder = frameDecoder
    var mappedFailure: SDKSessionAdmissionError?
    do {
      try decoder.consume(
        data,
        preflightLane: { lane in
          if lane == .event {
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
    if provisionalAdmission != nil || state == .admitted {
      try chargeHandoff(items: 1, bytes: encodedByteCount)
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
    case .idle, .discovering, .transferred, .connecting, .admitted, .failed, .cancelled:
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
    let message = try codec.decode(frame: frame, phase: .negotiatingPolicy)
    switch message.type {
    case .flowPolicyOffer:
      let value = try codec.decode(WireFlowPolicyOffer.self, from: message)
      try deliverPolicy(.offer(value), encodedByteCount: encodedByteCount)
    case .flowPolicyAccepted:
      let value = try codec.decode(WireFlowPolicyAccepted.self, from: message)
      try deliverPolicy(.accepted(value), encodedByteCount: encodedByteCount)
    case .ping:
      let ping = try codec.decode(WirePing.self, from: message)
      let pong = try codec.encode(WirePong(nonce: ping.nonce), phase: .negotiatingPolicy)
      try chargeHandoff(items: 1, bytes: pong.count)
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

  private func deliverPolicy(
    _ message: SDKSessionPolicyMessage,
    encodedByteCount: Int
  ) throws {
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

  private func commitProvisionalAdmission() {
    guard terminalError == nil, let provisionalAdmission, let waiter = resultWaiter else { return }
    self.provisionalAdmission = nil
    resultWaiter = nil
    attemptToken = nil
    state = .admitted
    route = provisionalAdmission.route
    negotiation = nil
    cancelDeadline()
    startDeadline(
      seconds: admissionLimits.pumpAttachmentTimeoutSeconds,
      failure: .pumpAttachmentTimedOut
    )
    let relay = SDKSessionCancellationRelay(core: self)
    waiter.resume(
      returning: SDKAdmittedSession(
        route: provisionalAdmission.route,
        capabilities: provisionalAdmission.negotiation.capabilities,
        sendPolicies: provisionalAdmission.negotiation.sendPolicies,
        maximumEventBytes: provisionalAdmission.negotiation.maximumEventBytes,
        relay: relay
      )
    )
  }

  private func admitResponse(_ data: Data) throws {
    guard let channel else { throw SDKSessionAdmissionError(.transportFailed) }
    do {
      try channel.admitSend(data)
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

  private func startDeadline(seconds: Int, failure: SDKSessionAdmissionError.Code) {
    cancelDeadline()
    let token = SDKSessionDeadlineToken()
    deadlineToken = token
    let sleep = self.sleep
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
    cancelDeadline()
    ingress.stop()
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
