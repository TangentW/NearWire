import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireInternal) import NearWireFlowControl
  @_spi(NearWireInternal) import NearWireTransport
#endif

struct SDKActiveEventPumpDependencies: Sendable {
  let sleep: @Sendable (Int) async throws -> Void
  let sleepNanoseconds: @Sendable (UInt64) async throws -> Void
  let beforeWakeRegistration: @Sendable () async -> Void
  let beforeActivationCommit: @Sendable () -> Void
  let beforeActivationResume: @Sendable () -> Void
  let beforeOwnerRefreshCompletion: @Sendable () async -> Void
  let beforeOutboundTurnCompletion: @Sendable () async -> Void
  let afterOutboundTurnCompletion: @Sendable () async -> Void
  let beforeImmediateIncomingDecisionCompletion: @Sendable () async -> Void
  let beforeIncomingPublicationClaim: @Sendable () async -> Void
  let beforeIncomingPublicationCompletion: @Sendable () async -> Void
  let afterIncomingPublicationCompletion: @Sendable () async -> Void
  let operationGateHooks: SDKActiveOperationGateHooks
  let bindLiveOperations:
    @Sendable (NearWire, SecureByteChannel, SDKActiveOperationGate) -> SDKActiveLiveOperations

  init(
    sleep: @escaping @Sendable (Int) async throws -> Void,
    sleepNanoseconds: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
      try await Task.sleep(nanoseconds: nanoseconds)
    },
    beforeWakeRegistration: @escaping @Sendable () async -> Void,
    beforeActivationCommit: @escaping @Sendable () -> Void,
    beforeActivationResume: @escaping @Sendable () -> Void,
    beforeOwnerRefreshCompletion: @escaping @Sendable () async -> Void = {},
    beforeOutboundTurnCompletion: @escaping @Sendable () async -> Void = {},
    afterOutboundTurnCompletion: @escaping @Sendable () async -> Void = {},
    beforeImmediateIncomingDecisionCompletion: @escaping @Sendable () async -> Void = {},
    beforeIncomingPublicationClaim: @escaping @Sendable () async -> Void = {},
    beforeIncomingPublicationCompletion: @escaping @Sendable () async -> Void = {},
    afterIncomingPublicationCompletion: @escaping @Sendable () async -> Void = {},
    liveOperationHooks: SDKActiveLiveOperationHooks = .none,
    operationGateHooks: SDKActiveOperationGateHooks
  ) {
    self.sleep = sleep
    self.sleepNanoseconds = sleepNanoseconds
    self.beforeWakeRegistration = beforeWakeRegistration
    self.beforeActivationCommit = beforeActivationCommit
    self.beforeActivationResume = beforeActivationResume
    self.beforeOwnerRefreshCompletion = beforeOwnerRefreshCompletion
    self.beforeOutboundTurnCompletion = beforeOutboundTurnCompletion
    self.afterOutboundTurnCompletion = afterOutboundTurnCompletion
    self.beforeImmediateIncomingDecisionCompletion =
      beforeImmediateIncomingDecisionCompletion
    self.beforeIncomingPublicationClaim = beforeIncomingPublicationClaim
    self.beforeIncomingPublicationCompletion = beforeIncomingPublicationCompletion
    self.afterIncomingPublicationCompletion = afterIncomingPublicationCompletion
    self.operationGateHooks = operationGateHooks
    bindLiveOperations = { owner, channel, gate in
      SDKActiveLiveOperations(
        owner: owner,
        channel: channel,
        gate: gate,
        hooks: liveOperationHooks
      )
    }
  }

  static let live = SDKActiveEventPumpDependencies(
    sleep: { seconds in try await ContinuousClock().sleep(for: .seconds(seconds)) },
    beforeWakeRegistration: {},
    beforeActivationCommit: {},
    beforeActivationResume: {},
    operationGateHooks: .none
  )
}

struct SDKActiveLiveOperationHooks: Sendable {
  static let none = SDKActiveLiveOperationHooks()

  let beforeClock: @Sendable () -> Void
  let beforeWakeRegistration: @Sendable () async -> Void
  let beforeWakeRemoval: @Sendable () async -> Void
  let beforeScheduleObservation: @Sendable () async -> Void
  let beforeDrain: @Sendable () async -> Void
  let beforeMailboxCapacity: @Sendable () -> Void
  let beforeMailboxAdmission: @Sendable () -> Void
  let beforePublication: @Sendable () async -> Void
  let beforeExpirationClaim: @Sendable () -> Void
  let beforeRouteDropClaim: @Sendable () -> Void
  let beforeCandidateClaim: @Sendable () -> Void
  let afterCandidateClaim: @Sendable () -> Void
  let beforeEventMailboxAdmission: @Sendable () -> Void
  let beforeEventMailboxProgressSnapshot: @Sendable () -> Void
  let beforeMailboxCompletion: @Sendable () -> Void
  let beforeObserverCancellation: @Sendable () -> Void
  let beforeTerminalClose: @Sendable () -> Void

  init(
    beforeClock: @escaping @Sendable () -> Void = {},
    beforeWakeRegistration: @escaping @Sendable () async -> Void = {},
    beforeWakeRemoval: @escaping @Sendable () async -> Void = {},
    beforeScheduleObservation: @escaping @Sendable () async -> Void = {},
    beforeDrain: @escaping @Sendable () async -> Void = {},
    beforeMailboxCapacity: @escaping @Sendable () -> Void = {},
    beforeMailboxAdmission: @escaping @Sendable () -> Void = {},
    beforePublication: @escaping @Sendable () async -> Void = {},
    beforeExpirationClaim: @escaping @Sendable () -> Void = {},
    beforeRouteDropClaim: @escaping @Sendable () -> Void = {},
    beforeCandidateClaim: @escaping @Sendable () -> Void = {},
    afterCandidateClaim: @escaping @Sendable () -> Void = {},
    beforeEventMailboxAdmission: @escaping @Sendable () -> Void = {},
    beforeEventMailboxProgressSnapshot: @escaping @Sendable () -> Void = {},
    beforeMailboxCompletion: @escaping @Sendable () -> Void = {},
    beforeObserverCancellation: @escaping @Sendable () -> Void = {},
    beforeTerminalClose: @escaping @Sendable () -> Void = {}
  ) {
    self.beforeClock = beforeClock
    self.beforeWakeRegistration = beforeWakeRegistration
    self.beforeWakeRemoval = beforeWakeRemoval
    self.beforeScheduleObservation = beforeScheduleObservation
    self.beforeDrain = beforeDrain
    self.beforeMailboxCapacity = beforeMailboxCapacity
    self.beforeMailboxAdmission = beforeMailboxAdmission
    self.beforePublication = beforePublication
    self.beforeExpirationClaim = beforeExpirationClaim
    self.beforeRouteDropClaim = beforeRouteDropClaim
    self.beforeCandidateClaim = beforeCandidateClaim
    self.afterCandidateClaim = afterCandidateClaim
    self.beforeEventMailboxAdmission = beforeEventMailboxAdmission
    self.beforeEventMailboxProgressSnapshot = beforeEventMailboxProgressSnapshot
    self.beforeMailboxCompletion = beforeMailboxCompletion
    self.beforeObserverCancellation = beforeObserverCancellation
    self.beforeTerminalClose = beforeTerminalClose
  }
}

struct SDKActiveLiveOperations: Sendable {
  let clockNanoseconds: @Sendable () -> UInt64
  let registerWake:
    @Sendable (SDKOutboundWakeToken, @escaping @Sendable () -> Void, Int) async throws
      -> SDKOutboundWakeRegistrationResult
  let removeWake: @Sendable (SDKOutboundWakeToken) async -> Void
  let observeSchedule: @Sendable (Int) async -> SDKOutboundScheduleResult
  let drain:
    @Sendable (SDKSessionRoute, WireSessionCodec, WireSequenceCounter, Int, Int, Int, Int, Int)
      async
      -> SDKActiveWireDrainResult
  let canAdmitSend: @Sendable (Int, Int, Int) -> Bool
  let admitSend: @Sendable (Data) throws -> Void
  let publishIncoming: @Sendable (WireReceivedEvent) async -> SDKActiveIncomingPublicationResult
  let mailboxCompletion: @Sendable () -> Void
  let observerCancellation: @Sendable () -> Void
  let terminalClose: @Sendable () -> Void

  init(
    owner: NearWire,
    channel: SecureByteChannel,
    gate: SDKActiveOperationGate,
    hooks: SDKActiveLiveOperationHooks
  ) {
    clockNanoseconds = {
      hooks.beforeClock()
      return owner.activeClockNanoseconds()
    }
    registerWake = { token, callback, maximumServiceUnits in
      await hooks.beforeWakeRegistration()
      return try await owner.registerOutboundWorkWake(
        token: token,
        callback: callback,
        maximumServiceUnits: maximumServiceUnits,
        gate: gate,
        operationHooks: hooks
      )
    }
    removeWake = { token in
      await hooks.beforeWakeRemoval()
      await owner.removeOutboundWorkWake(token: token)
    }
    observeSchedule = { maximumServiceUnits in
      await hooks.beforeScheduleObservation()
      return await owner.outboundSchedule(
        maximumServiceUnits: maximumServiceUnits,
        gate: gate,
        operationHooks: hooks
      )
    }
    drain = {
      route, codec, sequenceCounter, serviceUnits, acceptedCount, accountedBytes,
      reservedCount, reservedBytes in
      await hooks.beforeDrain()
      return await owner.drainActiveWire(
        for: route,
        codec: codec,
        sequenceCounter: sequenceCounter,
        maximumServiceUnits: serviceUnits,
        maximumAcceptedEventCount: acceptedCount,
        maximumAccountedBytes: accountedBytes,
        channel: channel,
        reservingPendingSendCount: reservedCount,
        reservingPendingSendBytes: reservedBytes,
        gate: gate,
        operationHooks: hooks
      )
    }
    canAdmitSend = { byteCount, reservedCount, reservedBytes in
      hooks.beforeMailboxCapacity()
      return channel.canAdmitSend(
        byteCount: byteCount,
        reservingPendingSendCount: reservedCount,
        reservingPendingSendBytes: reservedBytes
      )
    }
    admitSend = { data in
      hooks.beforeMailboxAdmission()
      try channel.admitSend(data)
    }
    publishIncoming = { received in
      await hooks.beforePublication()
      return await owner.publishIncomingActive(received, gate: gate)
    }
    mailboxCompletion = { hooks.beforeMailboxCompletion() }
    observerCancellation = { hooks.beforeObserverCancellation() }
    terminalClose = { hooks.beforeTerminalClose() }
  }
}

final class SDKActiveEventPump: @unchecked Sendable {
  private let lock = NSLock()
  private var attachment: SDKSessionPumpAttachment?
  private let owner: NearWire
  private let limits: SDKActiveEventPumpLimits
  private let dependencies: SDKActiveEventPumpDependencies
  private var didStart = false

  init(
    attachment: SDKSessionPumpAttachment,
    owner: NearWire,
    limits: SDKActiveEventPumpLimits = .default,
    dependencies: SDKActiveEventPumpDependencies = .live
  ) {
    self.attachment = attachment
    self.owner = owner
    self.limits = limits
    self.dependencies = dependencies
  }

  func run() async throws -> SDKActiveEventPumpHandle {
    let attachment = try claimAttachment()
    defer { releaseAttachment() }

    let token = SDKActiveRunToken()
    let cancellationGate = SDKSessionPullCancellationGate()
    try await withTaskCancellationHandler {
      try await attachment.transportCore.startActivePump(
        token: token,
        cancellationGate: cancellationGate,
        owner: owner,
        limits: limits,
        dependencies: dependencies
      )
    } onCancel: {
      cancellationGate.cancel()
    }

    return SDKActiveEventPumpHandle(relay: attachment.activeRelay)
  }

  private func claimAttachment() throws -> SDKSessionPumpAttachment {
    lock.lock()
    defer { lock.unlock() }
    guard !didStart, let retainedAttachment = self.attachment else {
      throw SDKSessionAdmissionError(.alreadyStarted)
    }
    didStart = true
    return retainedAttachment
  }

  private func releaseAttachment() {
    lock.lock()
    self.attachment = nil
    lock.unlock()
  }
}

final class SDKActiveEventPumpHandle: @unchecked Sendable {
  private let relay: SDKSessionCancellationRelay
  let termination: SDKActiveEventPumpTermination

  init(relay: SDKSessionCancellationRelay) {
    self.relay = relay
    termination = SDKActiveEventPumpTermination(core: relay.core)
  }

  func cancel() {
    relay.requestCancellation()
  }

  deinit {
    relay.requestCancellation()
  }
}

extension SDKActiveEventPumpHandle: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String { "<redacted-active-event-pump-handle>" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }
}

final class SDKActiveEventPumpTermination: @unchecked Sendable {
  private let lock = NSLock()
  private let core: SDKSessionTransportCore
  private var didStart = false

  init(core: SDKSessionTransportCore) {
    self.core = core
  }

  func wait() async throws -> SDKSessionAdmissionError.Code {
    try claimWait()

    let token = SDKActiveTerminationToken()
    let cancellationGate = SDKSessionPullCancellationGate()
    return try await withTaskCancellationHandler {
      try await core.waitForActiveTermination(token: token, cancellationGate: cancellationGate)
    } onCancel: {
      cancellationGate.cancel()
    }
  }

  private func claimWait() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !didStart else {
      throw SDKSessionAdmissionError(.terminationWaitAlreadyStarted)
    }
    didStart = true
  }
}

extension SDKActiveEventPumpTermination: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String { "<redacted-active-event-pump-termination>" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }
}

final class SDKActiveRunToken: @unchecked Sendable {}
final class SDKActiveBindingToken: @unchecked Sendable {}
final class SDKActiveTerminationToken: @unchecked Sendable {}
final class SDKActiveOutboundDrainToken: @unchecked Sendable {}
final class SDKActiveOutboundDecisionToken: @unchecked Sendable {}
final class SDKActiveIncomingPublicationToken: @unchecked Sendable {}
final class SDKActiveIncomingDecisionToken: @unchecked Sendable {}
final class SDKActiveOwnerRefreshToken: @unchecked Sendable {}
