import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireInternal) import NearWireTransport
#endif

enum SDKPublicConnectionBarrier: String, Sendable {
  case beforeLeaseClaim
  case afterLeaseClaim
  case beforeIdentityCompletion
  case afterIdentityCompletion
  case beforeAdmissionTarget
  case afterAdmissionResult
  case beforeActivationTarget
  case afterActivationResult
  case beforeTerminalWaitRegistration
  case afterTerminalWaitRegistration
  case beforeTransferClaim
  case beforeActorCommit
  case beforeTerminalDelivery
  case beforeRelease
  case afterRelease
}

final class SDKPairingCodeTransfer: @unchecked Sendable {
  private let lock = NSLock()
  private var pairingCode: PairingCode?

  init(rawValue: String) throws {
    pairingCode = try PairingCode(rawValue)
  }

  init(pairingCode: PairingCode) {
    self.pairingCode = pairingCode
  }

  func take() -> PairingCode? {
    lock.withLock {
      defer { pairingCode = nil }
      return pairingCode
    }
  }

  var isEmpty: Bool {
    lock.withLock { pairingCode == nil }
  }
}

struct SDKPublicConnectionHooks: Sendable {
  let reachSynchronous: @Sendable (SDKPublicConnectionBarrier) -> Void
  let reach: @Sendable (SDKPublicConnectionBarrier) async -> Void

  static let none = SDKPublicConnectionHooks(
    reachSynchronous: { _ in },
    reach: { _ in }
  )
}

final class SDKPublicConnectionLease: @unchecked Sendable {
  private let lock = NSLock()
  private var releaseOperation: (@Sendable () -> Void)?

  init(handle: ProcessConnectionLeaseHandle) {
    releaseOperation = { handle.release() }
  }

  init(release: @escaping @Sendable () -> Void) {
    releaseOperation = release
  }

  func release() {
    let retained: (@Sendable () -> Void)?
    lock.lock()
    retained = releaseOperation
    releaseOperation = nil
    lock.unlock()
    retained?()
  }

  deinit {
    release()
  }
}

/// Retains ownership permanently when an internal invariant prevents terminal observation.
/// Releasing in that state could allow two live sessions, so the safe failure mode is process-local
/// contention until process exit.
final class SDKPublicFailClosedLeaseVault: @unchecked Sendable {
  static let shared = SDKPublicFailClosedLeaseVault()

  private let lock = NSLock()
  private var leases: [SDKPublicConnectionLease] = []

  private init() {}

  func retain(_ lease: SDKPublicConnectionLease) {
    lock.withLock { leases.append(lease) }
  }

  var retainedLeaseCount: Int {
    lock.withLock { leases.count }
  }
}

struct SDKPublicConnectionDependencies: Sendable {
  let makeTransitionGate: @Sendable () -> SDKSessionTransitionGate
  let claimLease: @Sendable () throws -> SDKPublicConnectionLease
  let loadInstallationIdentity: @Sendable () async throws -> String
  let bundleMetadata: @Sendable () -> SDKBundleMetadataInput
  let makeAdmission:
    @Sendable (
      PairingCode,
      WireHello,
      SDKPublicConnectionLimitPlan,
      SDKSessionTransitionGate,
      @escaping @Sendable () async -> SDKSessionPhaseAuthorization
    ) -> SDKSessionAdmission
  let makePump:
    @Sendable (SDKSessionPumpAttachment, NearWire, SDKActiveEventPumpLimits)
      -> SDKActiveEventPump
  let hooks: SDKPublicConnectionHooks

  static let live = SDKPublicConnectionDependencies(
    makeTransitionGate: { SDKSessionTransitionGate() },
    claimLease: {
      SDKPublicConnectionLease(handle: try ProcessConnectionLeaseRegistry.claim())
    },
    loadInstallationIdentity: {
      try await SDKInstallationIdentityStore().load()
    },
    bundleMetadata: { SDKBundleMetadataInput.live() },
    makeAdmission: { pairingCode, hello, plan, transitionGate, phaseObserver in
      SDKSessionAdmission(
        pairingCode: pairingCode,
        localHello: hello,
        wireLimits: plan.wireLimits,
        transportLimits: plan.transportLimits,
        admissionLimits: plan.admissionLimits,
        transitionGate: transitionGate,
        phaseObserver: phaseObserver,
        connectionQueue: DispatchQueue(label: "com.nearwire.sdk.connection"),
        verificationQueue: DispatchQueue(label: "com.nearwire.sdk.verification")
      )
    },
    makePump: { attachment, owner, limits in
      SDKActiveEventPump(attachment: attachment, owner: owner, limits: limits)
    },
    hooks: .none
  )
}

final class SDKPublicTerminalCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var lease: SDKPublicConnectionLease?
  private var task: Task<Void, Never>?

  init(
    lifetime: SDKSessionLifetime,
    lease: SDKPublicConnectionLease,
    hooks: SDKPublicConnectionHooks,
    delivery: @escaping @Sendable (SDKSessionAdmissionError.Code) async -> Void
  ) throws {
    let registration = try lifetime.termination.registerWait()
    self.lease = lease
    start(hooks: hooks, delivery: delivery) {
      try await registration.wait()
    }
  }

  init(
    lease: SDKPublicConnectionLease,
    hooks: SDKPublicConnectionHooks,
    wait: @escaping @Sendable () async throws -> SDKSessionAdmissionError.Code,
    delivery: @escaping @Sendable (SDKSessionAdmissionError.Code) async -> Void
  ) {
    self.lease = lease
    start(hooks: hooks, delivery: delivery, wait: wait)
  }

  private func start(
    hooks: SDKPublicConnectionHooks,
    delivery: @escaping @Sendable (SDKSessionAdmissionError.Code) async -> Void,
    wait: @escaping @Sendable () async throws -> SDKSessionAdmissionError.Code
  ) {
    task = Task { [self] in
      let code: SDKSessionAdmissionError.Code
      do {
        code = try await wait()
      } catch {
        failClosed()
        clearTask()
        return
      }
      await hooks.reach(.beforeRelease)
      releaseLease()
      await hooks.reach(.afterRelease)
      await hooks.reach(.beforeTerminalDelivery)
      await delivery(code)
      clearTask()
    }
  }

  private func failClosed() {
    let retained: SDKPublicConnectionLease?
    lock.lock()
    retained = lease
    lease = nil
    lock.unlock()
    if let retained { SDKPublicFailClosedLeaseVault.shared.retain(retained) }
  }

  private func releaseLease() {
    let retained: SDKPublicConnectionLease?
    lock.lock()
    retained = lease
    lease = nil
    lock.unlock()
    retained?.release()
  }

  private func clearTask() {
    lock.lock()
    task = nil
    lock.unlock()
  }
}

final class SDKPublicConnectedOwner: @unchecked Sendable {
  let handle: SDKActiveEventPumpHandle
  let coordinator: SDKPublicTerminalCoordinator

  init(handle: SDKActiveEventPumpHandle, coordinator: SDKPublicTerminalCoordinator) {
    self.handle = handle
    self.coordinator = coordinator
  }

  func cancel() {
    handle.cancel()
  }

  deinit {
    handle.cancel()
  }
}
