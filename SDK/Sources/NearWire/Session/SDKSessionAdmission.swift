import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireInternal) import NearWireTransport
#endif

actor SDKSessionAdmission {
  private var pairingCode: PairingCode?
  private var localHello: WireHello?
  private let wireLimits: WireProtocolLimits
  private let transportLimits: SecureTransportLimits
  private let admissionLimits: SDKSessionAdmissionLimits
  private let dependencies: SDKSessionAdmissionDependencies

  private var state: SDKSessionAdmissionState = .idle
  private var discovery: (any SDKSessionDiscoveryOperation)?
  private var discoveryDeadlineTask: Task<Void, Never>?
  private var discoveryDeadlineToken: SDKSessionDeadlineToken?
  private var discoveryTerminalOverride: SDKSessionAdmissionError?
  private var core: SDKSessionTransportCore?
  private var attemptToken: SDKSessionAttemptToken?

  init(
    pairingCode: PairingCode,
    localHello: WireHello,
    wireLimits: WireProtocolLimits = .default,
    transportLimits: SecureTransportLimits = .default,
    admissionLimits: SDKSessionAdmissionLimits = .default,
    dependencies: SDKSessionAdmissionDependencies
  ) {
    self.pairingCode = pairingCode
    self.localHello = localHello
    self.wireLimits = wireLimits
    self.transportLimits = transportLimits
    self.admissionLimits = admissionLimits
    self.dependencies = dependencies
  }

  init(
    pairingCode: PairingCode,
    localHello: WireHello,
    wireLimits: WireProtocolLimits = .default,
    transportLimits: SecureTransportLimits = .default,
    admissionLimits: SDKSessionAdmissionLimits = .default,
    connectionQueue: DispatchQueue,
    verificationQueue: DispatchQueue
  ) {
    self.init(
      pairingCode: pairingCode,
      localHello: localHello,
      wireLimits: wireLimits,
      transportLimits: transportLimits,
      admissionLimits: admissionLimits,
      dependencies: .live(
        connectionQueue: connectionQueue,
        verificationQueue: verificationQueue,
        transportLimits: transportLimits
      )
    )
  }

  func run() async throws -> SDKAdmittedSession {
    try await withTaskCancellationHandler {
      try await execute()
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  func cancel() async {
    switch state {
    case .idle:
      state = .cancelled
      pairingCode = nil
      localHello = nil
    case .discovering:
      guard discoveryTerminalOverride == nil else { return }
      discoveryTerminalOverride = SDKSessionAdmissionError(.cancelled)
      state = .cancelled
      cancelDiscoveryDeadline()
      let operation = discovery
      await operation?.cancel()
    case .transferred, .connecting, .exchangingHello, .awaitingApproval:
      if let core, let attemptToken {
        await core.cancelAttempt(attemptToken)
      }
    case .admitted, .bindingActiveOwner, .negotiatingPolicy, .active, .failed, .cancelled:
      break
    }
  }

  private func execute() async throws -> SDKAdmittedSession {
    guard state == .idle else {
      if state == .cancelled { throw SDKSessionAdmissionError(.cancelled) }
      throw SDKSessionAdmissionError(.alreadyStarted)
    }
    guard !Task.isCancelled else {
      state = .cancelled
      pairingCode = nil
      localHello = nil
      throw SDKSessionAdmissionError(.cancelled)
    }
    guard let pairingCode, let localHello, localHello.role == .app else {
      return try failLocalConfiguration()
    }

    let encodedHello: Data
    let encodedMaximumPong: Data
    do {
      encodedHello = try WirePreHandshakeCodec(limits: wireLimits).encode(localHello)
      encodedMaximumPong = try WireSessionCodec.encodeMaximumV1Pong(limits: wireLimits)
      try admissionLimits.validate(
        wireLimits: wireLimits,
        transportLimits: transportLimits,
        encodedHelloByteCount: encodedHello.count,
        encodedMaximumPongByteCount: encodedMaximumPong.count
      )
    } catch {
      return try failLocalConfiguration()
    }

    let discovery = dependencies.makeDiscovery(pairingCode)
    self.discovery = discovery
    self.pairingCode = nil
    state = .discovering
    startDiscoveryDeadline()

    var discovered: DiscoveredViewer?
    do {
      discovered = try await discovery.run()
    } catch {
      let mapped =
        discoveryTerminalOverride
        ?? (Task.isCancelled ? Self.mapTaskCancelledDiscovery(error) : nil)
        ?? Self.map(discoveryError: error)
      finishDiscoveryStage(state: mapped.code == .cancelled ? .cancelled : .failed)
      throw mapped
    }
    if let discoveryTerminalOverride {
      finishDiscoveryStage(
        state: discoveryTerminalOverride.code == .cancelled ? .cancelled : .failed)
      throw discoveryTerminalOverride
    }
    cancelDiscoveryDeadline()
    self.discovery = nil
    guard let discoveredDiscriminator = discovered?.identity.viewerDiscriminator else {
      state = .failed
      self.localHello = nil
      throw SDKSessionAdmissionError(.discoveryFailed)
    }

    let ingress = SDKSessionChannelIngress(
      maximumEvents: admissionLimits.maximumIngressEvents,
      maximumReceiveBytes: admissionLimits.maximumIngressBytes
    )
    let token = SDKSessionAttemptToken()
    let transportCore = SDKSessionTransportCore(
      ingress: ingress,
      localHello: localHello,
      localHelloBytes: encodedHello,
      discoveredDiscriminator: discoveredDiscriminator,
      attemptToken: token,
      wireLimits: wireLimits,
      admissionLimits: admissionLimits,
      sleep: dependencies.sleep
    )
    core = transportCore
    attemptToken = token
    state = .transferred
    self.localHello = nil
    let channel = dependencies.makeChannel(discovered!) { event in
      ingress.submit(.channel(event))
    }
    discovered = nil
    await dependencies.beforeBind()
    do {
      try await transportCore.bind(channel: channel)
    } catch let error as SDKSessionAdmissionError {
      state = error.code == .cancelled ? .cancelled : .failed
      core = nil
      attemptToken = nil
      throw error
    } catch {
      state = .failed
      core = nil
      attemptToken = nil
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
    ingress.installDrain { [weak transportCore] in
      Task { await transportCore?.drainIngress() }
    }

    do {
      let session = try await transportCore.run(attemptToken: token)
      state = .admitted
      core = nil
      attemptToken = nil
      return session
    } catch let error as SDKSessionAdmissionError {
      state = error.code == .cancelled ? .cancelled : .failed
      core = nil
      attemptToken = nil
      throw error
    } catch {
      state = .failed
      core = nil
      attemptToken = nil
      throw SDKSessionAdmissionError(.transportFailed)
    }
  }

  private func failLocalConfiguration<T>() throws -> T {
    state = .failed
    pairingCode = nil
    localHello = nil
    throw SDKSessionAdmissionError(.invalidLocalConfiguration)
  }

  private func startDiscoveryDeadline() {
    cancelDiscoveryDeadline()
    let token = SDKSessionDeadlineToken()
    discoveryDeadlineToken = token
    let sleep = dependencies.sleep
    let seconds = admissionLimits.discoveryTimeoutSeconds
    discoveryDeadlineTask = Task { [weak self] in
      do {
        try await sleep(seconds)
      } catch {
        return
      }
      await self?.discoveryDeadlineFired(token: token)
    }
  }

  private func discoveryDeadlineFired(token: SDKSessionDeadlineToken) async {
    guard state == .discovering, discoveryDeadlineToken === token,
      discoveryTerminalOverride == nil
    else {
      return
    }
    discoveryTerminalOverride = SDKSessionAdmissionError(.discoveryTimedOut)
    state = .failed
    cancelDiscoveryDeadline()
    let operation = discovery
    await operation?.cancel()
  }

  private func cancelDiscoveryDeadline() {
    discoveryDeadlineToken = nil
    discoveryDeadlineTask?.cancel()
    discoveryDeadlineTask = nil
  }

  private func finishDiscoveryStage(state: SDKSessionAdmissionState) {
    cancelDiscoveryDeadline()
    discovery = nil
    pairingCode = nil
    localHello = nil
    self.state = state
  }

  private static func map(discoveryError error: Error) -> SDKSessionAdmissionError {
    guard let error = error as? ViewerDiscoveryError else {
      return SDKSessionAdmissionError(.discoveryFailed)
    }
    switch error.code {
    case .permissionOrPolicyDenied:
      return SDKSessionAdmissionError(.discoveryDenied)
    case .unavailableNetwork:
      return SDKSessionAdmissionError(.discoveryUnavailable)
    case .ambiguous:
      return SDKSessionAdmissionError(.discoveryAmbiguous)
    case .cancelled:
      return SDKSessionAdmissionError(.discoveryFailed)
    case .alreadyStarted, .resultLimitExceeded, .browserFailure:
      return SDKSessionAdmissionError(.discoveryFailed)
    }
  }

  private static func mapTaskCancelledDiscovery(_ error: Error) -> SDKSessionAdmissionError? {
    guard let discoveryError = error as? ViewerDiscoveryError,
      discoveryError.code == .cancelled
    else {
      return nil
    }
    return SDKSessionAdmissionError(.cancelled)
  }
}
