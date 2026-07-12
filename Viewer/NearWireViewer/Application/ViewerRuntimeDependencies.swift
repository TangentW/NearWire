import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

protocol ViewerSecureListener: AnyObject, Sendable {
  func start(
    queue: DispatchQueue,
    eventHandler: @escaping SecureViewerListener.EventHandler
  ) throws
  func cancel()
}

extension SecureViewerListener: ViewerSecureListener {}

struct ViewerPreparedIdentity: @unchecked Sendable {
  let installationID: EndpointID
  let makeListener: @Sendable (SecureViewerServiceAdvertisement) throws -> any ViewerSecureListener
}

struct ViewerRuntimeDependencies: @unchecked Sendable {
  static let live: ViewerRuntimeDependencies = {
    let store = ViewerIdentityStore.live
    return ViewerRuntimeDependencies(
      loadIdentity: {
        let identity = try store.loadOrCreate()
        return ViewerPreparedIdentity(
          installationID: identity.installationID,
          makeListener: { advertisement in
            try SecureViewerTransport.makeListener(
              identity: identity.transportIdentity,
              advertisement: advertisement
            )
          }
        )
      },
      resetTLSIdentity: { try store.resetTLSIdentity() },
      resetAllIdentity: { try store.resetAllIdentity() },
      generatePairingCode: { try ViewerPairingCodeGenerator.live.generate() },
      cleanupTimeoutNanoseconds: ViewerAdmissionManager.cleanupTimeoutNanoseconds,
      scheduler: .live,
      makeHandoffOwner: {
        ViewerMultiDeviceSessionManager(
          scheduler: .live,
          preferences: ViewerDevicePreferences()
        )
      }
    )
  }()

  let loadIdentity: @Sendable () throws -> ViewerPreparedIdentity
  let resetTLSIdentity: @Sendable () throws -> Void
  let resetAllIdentity: @Sendable () throws -> Void
  let generatePairingCode: @Sendable () throws -> PairingCode
  let cleanupTimeoutNanoseconds: UInt64
  let scheduler: ViewerAdmissionScheduler
  let makeHandoffOwner: @Sendable () -> any ViewerAdmissionHandoffOwning

  init(
    loadIdentity: @escaping @Sendable () throws -> ViewerPreparedIdentity,
    resetTLSIdentity: @escaping @Sendable () throws -> Void,
    resetAllIdentity: @escaping @Sendable () throws -> Void,
    generatePairingCode: @escaping @Sendable () throws -> PairingCode,
    cleanupTimeoutNanoseconds: UInt64 = ViewerAdmissionManager.cleanupTimeoutNanoseconds,
    scheduler: ViewerAdmissionScheduler = .live,
    makeHandoffOwner: @escaping @Sendable () -> any ViewerAdmissionHandoffOwning = {
      ViewerPlaceholderHandoffOwner()
    }
  ) {
    self.loadIdentity = loadIdentity
    self.resetTLSIdentity = resetTLSIdentity
    self.resetAllIdentity = resetAllIdentity
    self.generatePairingCode = generatePairingCode
    self.cleanupTimeoutNanoseconds = cleanupTimeoutNanoseconds
    self.scheduler = scheduler
    self.makeHandoffOwner = makeHandoffOwner
  }
}

@MainActor
final class ViewerListenerGeneration {
  let id: UUID
  let pairingCode: PairingCode
  let listener: any ViewerSecureListener
  let admissionIngress = ViewerListenerAdmissionIngress()
  let collisionAttempt: Int
  var isReady = false
  var isExactlyRegistered = false

  init(
    id: UUID = UUID(),
    pairingCode: PairingCode,
    listener: any ViewerSecureListener,
    collisionAttempt: Int
  ) {
    self.id = id
    self.pairingCode = pairingCode
    self.listener = listener
    self.collisionAttempt = collisionAttempt
  }
}

final class ViewerListenerAdmissionIngress: @unchecked Sendable {
  private struct Target {
    let manager: ViewerAdmissionManager
    let generation: UUID
    let viewerInstallationID: EndpointID
  }

  private let lock = NSLock()
  private var target: Target?

  func activate(
    manager: ViewerAdmissionManager,
    generation: UUID,
    viewerInstallationID: EndpointID
  ) {
    lock.lock()
    target = Target(
      manager: manager,
      generation: generation,
      viewerInstallationID: viewerInstallationID
    )
    lock.unlock()
  }

  func deactivate() {
    lock.lock()
    target = nil
    lock.unlock()
  }

  func receive(_ incoming: any ViewerIncomingConnection) {
    lock.lock()
    let target = target
    lock.unlock()
    guard let target else {
      incoming.reject()
      return
    }
    target.manager.admit(
      incoming,
      generation: target.generation,
      viewerInstallationID: target.viewerInstallationID
    )
  }
}

final class ViewerPendingCoalescer: @unchecked Sendable {
  typealias Delivery = @MainActor @Sendable ([ViewerPendingAppSummary]) -> Void

  private let lock = NSLock()
  private let delivery: Delivery
  private var latest: [ViewerPendingAppSummary]?
  private var taskScheduled = false
  private var active = true

  init(delivery: @escaping Delivery) {
    self.delivery = delivery
  }

  func submit(_ pending: [ViewerPendingAppSummary]) {
    lock.lock()
    guard active else {
      lock.unlock()
      return
    }
    latest = pending
    guard !taskScheduled else {
      lock.unlock()
      return
    }
    taskScheduled = true
    lock.unlock()
    scheduleDrain()
  }

  func deactivate() {
    lock.lock()
    active = false
    latest = nil
    lock.unlock()
  }

  @MainActor
  private func drainOne() {
    lock.lock()
    guard active, let pending = latest else {
      taskScheduled = false
      lock.unlock()
      return
    }
    latest = nil
    lock.unlock()
    delivery(pending)

    lock.lock()
    let shouldContinue = active && latest != nil
    if !shouldContinue { taskScheduled = false }
    lock.unlock()
    if shouldContinue { scheduleDrain() }
  }

  private func scheduleDrain() {
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.drainOne()
    }
  }
}

final class ViewerSessionSnapshotCoalescer: @unchecked Sendable {
  typealias Delivery = @MainActor @Sendable ([ViewerSessionSnapshot]) -> Void

  private let lock = NSLock()
  private let delivery: Delivery
  private var latest: [ViewerSessionSnapshot]?
  private var taskScheduled = false
  private var active = true

  init(delivery: @escaping Delivery) { self.delivery = delivery }

  func submit(_ snapshots: [ViewerSessionSnapshot]) {
    lock.lock()
    guard active else {
      lock.unlock()
      return
    }
    latest = snapshots
    guard !taskScheduled else {
      lock.unlock()
      return
    }
    taskScheduled = true
    lock.unlock()
    scheduleDrain()
  }

  func deactivate() {
    lock.lock()
    active = false
    latest = nil
    lock.unlock()
  }

  private func scheduleDrain() {
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.drainOne()
    }
  }

  @MainActor
  private func drainOne() {
    lock.lock()
    guard active, let snapshots = latest else {
      taskScheduled = false
      lock.unlock()
      return
    }
    latest = nil
    lock.unlock()
    delivery(snapshots)
    lock.lock()
    let continues = active && latest != nil
    if !continues { taskScheduled = false }
    lock.unlock()
    if continues { scheduleDrain() }
  }
}
