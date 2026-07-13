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
    let storeRuntime = ViewerStoreRuntime(startupMode: .asynchronous)
    let managerGenerations = ViewerManagerGenerationSource()
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
      makeRuntimeComponents: { runtimeLogicalID in
        ViewerRuntimeComponents.make(
          runtimeLogicalID: runtimeLogicalID,
          managerGeneration: managerGenerations.next(),
          scheduler: .live,
          preferences: ViewerDevicePreferences(),
          uplinkSink: { _, _ in },
          durableJournal: storeRuntime,
          storeGateway: storeRuntime.explorerGateway
        )
      },
      loadStorageConfiguration: {
        storeRuntime.loadConfiguration()
      },
      saveStorageConfiguration: { value in
        storeRuntime.saveConfiguration(value)
      },
      loadStoreStatus: {
        storeRuntime.status()
      },
      observeStoreStatus: { handler in
        storeRuntime.observeStatus(handler)
      },
      runStoreCleanup: {
        storeRuntime.runCleanup()
      },
      retryStore: { storeRuntime.retryStorage() }
    )
  }()

  let loadIdentity: @Sendable () throws -> ViewerPreparedIdentity
  let resetTLSIdentity: @Sendable () throws -> Void
  let resetAllIdentity: @Sendable () throws -> Void
  let generatePairingCode: @Sendable () throws -> PairingCode
  let cleanupTimeoutNanoseconds: UInt64
  let scheduler: ViewerAdmissionScheduler
  let makeRuntimeComponents: @Sendable (UUID) -> ViewerRuntimeComponents
  let loadStorageConfiguration: @Sendable () -> ViewerStorageConfiguration
  let saveStorageConfiguration: @Sendable (ViewerStorageConfiguration) -> Void
  let loadStoreStatus: @Sendable () -> ViewerStoreStatus
  let observeStoreStatus: @Sendable (@escaping @Sendable () -> Void) -> Void
  let runStoreCleanup: @Sendable () -> Void
  let retryStore: @Sendable () -> Void

  init(
    loadIdentity: @escaping @Sendable () throws -> ViewerPreparedIdentity,
    resetTLSIdentity: @escaping @Sendable () throws -> Void,
    resetAllIdentity: @escaping @Sendable () throws -> Void,
    generatePairingCode: @escaping @Sendable () throws -> PairingCode,
    cleanupTimeoutNanoseconds: UInt64 = ViewerAdmissionManager.cleanupTimeoutNanoseconds,
    scheduler: ViewerAdmissionScheduler = .live,
    makeRuntimeComponents: (@Sendable (UUID) -> ViewerRuntimeComponents)? = nil,
    loadStorageConfiguration: @escaping @Sendable () -> ViewerStorageConfiguration = { .default },
    saveStorageConfiguration: @escaping @Sendable (ViewerStorageConfiguration) -> Void = { _ in },
    loadStoreStatus: @escaping @Sendable () -> ViewerStoreStatus = {
      ViewerStoreStatus(
        state: .unavailable,
        capacityBytes: ViewerStorageConfiguration.defaultCapacityBytes,
        logicalQuotaBytes: 0,
        allocatedFootprintBytes: 0,
        oldestHistoryMilliseconds: nil,
        pinnedQuotaBytes: 0,
        estimatedRetainedDurationMilliseconds: nil,
        lastCleanupCategory: .none
      )
    },
    observeStoreStatus: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { _ in },
    runStoreCleanup: @escaping @Sendable () -> Void = {},
    retryStore: @escaping @Sendable () -> Void = {}
  ) {
    self.loadIdentity = loadIdentity
    self.resetTLSIdentity = resetTLSIdentity
    self.resetAllIdentity = resetAllIdentity
    self.generatePairingCode = generatePairingCode
    self.cleanupTimeoutNanoseconds = cleanupTimeoutNanoseconds
    self.scheduler = scheduler
    if let makeRuntimeComponents {
      self.makeRuntimeComponents = makeRuntimeComponents
    } else {
      let managerGenerations = ViewerManagerGenerationSource()
      self.makeRuntimeComponents = { runtimeLogicalID in
        ViewerRuntimeComponents.make(
          runtimeLogicalID: runtimeLogicalID,
          managerGeneration: managerGenerations.next()
        )
      }
    }
    self.loadStorageConfiguration = loadStorageConfiguration
    self.saveStorageConfiguration = saveStorageConfiguration
    self.loadStoreStatus = loadStoreStatus
    self.observeStoreStatus = observeStoreStatus
    self.runStoreCleanup = runStoreCleanup
    self.retryStore = retryStore
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

final class ViewerStoreStatusRefreshCoordinator: @unchecked Sendable {
  typealias Load = @Sendable () -> ViewerStoreStatus
  typealias Delivery = @MainActor @Sendable (ViewerStoreStatus) -> Void

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.nearwire.viewer.store-status-refresh")
  private let completionGroup = DispatchGroup()
  private let load: Load
  private let delivery: Delivery
  private var active = true
  private var running = false
  private var dirty = false

  init(load: @escaping Load, delivery: @escaping Delivery) {
    self.load = load
    self.delivery = delivery
  }

  func request() {
    lock.lock()
    guard active else {
      lock.unlock()
      return
    }
    guard !running else {
      dirty = true
      lock.unlock()
      return
    }
    running = true
    completionGroup.enter()
    lock.unlock()
    scheduleLoad()
  }

  func deactivateAndWait() -> Task<Void, Never> {
    lock.lock()
    active = false
    dirty = false
    lock.unlock()
    let group = completionGroup
    return Task {
      await withCheckedContinuation { continuation in
        group.notify(queue: .global(qos: .utility)) { continuation.resume() }
      }
    }
  }

  var pendingWorkCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return running ? 1 : 0
  }

  var hasDirtySuccessorForTesting: Bool {
    lock.lock()
    defer { lock.unlock() }
    return dirty
  }

  private func scheduleLoad() {
    queue.async { [self] in
      let value = load()
      Task { @MainActor [self] in self.deliverAndContinue(value) }
    }
  }

  @MainActor
  private func deliverAndContinue(_ value: ViewerStoreStatus) {
    lock.lock()
    let shouldDeliver = active
    lock.unlock()
    if shouldDeliver { delivery(value) }

    lock.lock()
    if active, dirty {
      dirty = false
      lock.unlock()
      scheduleLoad()
    } else {
      running = false
      lock.unlock()
      completionGroup.leave()
    }
  }
}
