import AppKit
import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

@MainActor
final class ViewerApplicationModel: ObservableObject {
  enum Status: Equatable {
    case stopped
    case starting
    case listening(code: String, paused: Bool)
    case stopping
    case failed(ViewerPresentationError)
  }

  @Published private(set) var status: Status = .stopped
  @Published private(set) var pendingApps: [ViewerPendingAppSummary] = []
  @Published private(set) var sessions: [ViewerSessionSnapshot] = []
  @Published private(set) var explorerController: ViewerEventExplorerController?
  @Published private(set) var analysisCoordinator: ViewerAnalysisModeCoordinator?
  @Published private(set) var composerController: ViewerControlComposerController?
  @Published var selectedRoute: ViewerLogicalRoute?
  @Published var showsFullIdentityResetConfirmation = false
  @Published private(set) var storageConfiguration: ViewerStorageConfiguration
  @Published private(set) var storeStatus: ViewerStoreStatus
  @Published var requiresApproval: Bool {
    didSet {
      preferences.setRequiresApproval(requiresApproval)
      admissionManager.setRequiresApproval(requiresApproval)
    }
  }

  private static let maximumCollisionAttempts = 3
  private let preferences: ViewerPreferences
  private let dependencies: ViewerRuntimeDependencies
  private let listenerQueue = DispatchQueue(label: "com.nearwire.viewer.listener")
  private var runtimeToken = UUID()
  private var startupTask: Task<Void, Never>?
  private var shutdownTask: Task<ViewerCleanupOutcome, Never>?
  private var preparedIdentity: ViewerPreparedIdentity?
  private var activeListener: ViewerListenerGeneration?
  private var preparingListener: ViewerListenerGeneration?
  private var isPaused = false
  private var pendingCoalescer: ViewerPendingCoalescer?
  private var sessionCoalescer: ViewerSessionSnapshotCoalescer?
  private var storeStatusRefreshCoordinator: ViewerStoreStatusRefreshCoordinator?
  private var runtimeComponents: ViewerRuntimeComponents?
  private var sessionControl: (any ViewerSessionControlling)?
  private lazy var admissionManager = ViewerAdmissionManager(onPending: { _ in })

  init(
    preferences: ViewerPreferences = .live,
    dependencies: ViewerRuntimeDependencies = .live
  ) {
    self.preferences = preferences
    self.dependencies = dependencies
    requiresApproval = preferences.requiresApproval()
    let storageConfiguration = dependencies.loadStorageConfiguration()
    self.storageConfiguration = storageConfiguration
    storeStatus = ViewerStoreStatus(
      state: .unavailable,
      capacityBytes: storageConfiguration.capacityBytes,
      logicalQuotaBytes: 0,
      allocatedFootprintBytes: 0,
      oldestHistoryMilliseconds: nil,
      pinnedQuotaBytes: 0,
      estimatedRetainedDurationMilliseconds: nil,
      lastCleanupCategory: .none
    )
    admissionManager.setRequiresApproval(requiresApproval)
    let storeStatusRefreshCoordinator = ViewerStoreStatusRefreshCoordinator(
      load: dependencies.loadStoreStatus
    ) { [weak self] value in
      guard let self else { return }
      let replacedStore = value.storeGeneration != self.storeStatus.storeGeneration
      self.storeStatus = value
      self.runtimeComponents?.liveObservations.storeStateChanged(value.state)
      if replacedStore {
        self.analysisCoordinator?.noteStoreReplaced()
      } else {
        self.explorerController?.noteStoreChanged()
        self.analysisCoordinator?.noteStoreChanged()
      }
    }
    self.storeStatusRefreshCoordinator = storeStatusRefreshCoordinator
    dependencies.observeStoreStatus { [weak storeStatusRefreshCoordinator] in
      storeStatusRefreshCoordinator?.request()
    }
    refreshStoreStatus()
  }

  func openWindow() {
    guard status == .stopped else { return }
    startRuntime()
  }

  func closeWindow() {
    guard status != .stopped else { return }
    startupTask?.cancel()
    let cleanup = beginStopRuntime()
    let token = runtimeToken
    startupTask = Task { [weak self] in
      _ = await cleanup.value
      guard let self, self.runtimeToken == token else { return }
      self.status = .stopped
    }
  }

  func copyPairingCode() {
    guard case .listening(let code, _) = status else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
  }

  func refreshPairingCode() {
    guard case .listening = status, let identity = preparedIdentity else { return }
    preparingListener?.listener.cancel()
    preparingListener = nil
    do {
      try startListenerCandidate(identity: identity, collisionAttempt: 0)
    } catch {
      // A replacement failure deliberately leaves the registered listener and code active.
    }
  }

  func togglePaused() {
    guard case .listening(let code, let paused) = status else { return }
    isPaused = !paused
    admissionManager.setPaused(isPaused)
    status = .listening(code: code, paused: isPaused)
  }

  func accept(_ id: UUID) {
    admissionManager.accept(id)
  }

  func reject(_ id: UUID) {
    admissionManager.reject(id)
  }

  func disconnectSelectedDevice() {
    guard let id = selectedSession?.connectionID else { return }
    sessionControl?.disconnect(connectionID: id)
  }

  func updateSelectedRates(appUplink: String, appDownlink: String) -> Bool {
    guard let id = selectedSession?.connectionID,
      let uplink = Double(appUplink), let downlink = Double(appDownlink),
      let policy = try? ViewerRatePolicy(appUplink: uplink, appDownlink: downlink)
    else { return false }
    sessionControl?.updatePolicy(connectionID: id, policy: policy)
    return true
  }

  func updateSelectedNickname(_ nickname: String) -> Bool {
    guard let route = selectedRoute else { return false }
    return sessionControl?.setNickname(nickname.isEmpty ? nil : nickname, route: route) ?? false
  }

  func updateStorage(capacityGiB: String, historyRetentionDays: String) -> Bool {
    guard let gibibytes = Int64(capacityGiB), let days = Int(historyRetentionDays),
      gibibytes > 0
    else { return false }
    let (mebibytes, firstOverflow) = gibibytes.multipliedReportingOverflow(by: 1_024)
    let (kibibytes, secondOverflow) = mebibytes.multipliedReportingOverflow(by: 1_024)
    let (bytes, thirdOverflow) = kibibytes.multipliedReportingOverflow(by: 1_024)
    guard !firstOverflow, !secondOverflow, !thirdOverflow,
      let value = try? ViewerStorageConfiguration(
        capacityBytes: bytes,
        historyRetentionDays: days
      )
    else { return false }
    dependencies.saveStorageConfiguration(value)
    storageConfiguration = value
    refreshStoreStatus()
    return true
  }

  func cleanUpStorage() {
    dependencies.runStoreCleanup()
  }

  func retryStorage() {
    dependencies.retryStore()
    refreshStoreStatus()
  }

  func refreshStoreStatus() {
    storeStatusRefreshCoordinator?.request()
  }

  var selectedSession: ViewerSessionSnapshot? {
    guard let selectedRoute else { return nil }
    return sessions.first { $0.route == selectedRoute }
  }

  func retry() {
    guard case .failed = status else { return }
    let cleanup = beginStopRuntime()
    let token = runtimeToken
    startupTask = Task { [weak self] in
      _ = await cleanup.value
      guard let self, self.runtimeToken == token else { return }
      self.status = .stopped
      self.startRuntime()
    }
  }

  func resetTLSIdentity() {
    resetIdentity(using: dependencies.resetTLSIdentity)
  }

  func requestFullIdentityReset() {
    showsFullIdentityResetConfirmation = true
  }

  func cancelFullIdentityReset() {
    showsFullIdentityResetConfirmation = false
  }

  func confirmFullIdentityReset() {
    showsFullIdentityResetConfirmation = false
    resetIdentity(using: dependencies.resetAllIdentity)
  }

  func prepareForTermination() async -> ViewerCleanupOutcome {
    startupTask?.cancel()
    let storeStatusCleanup = storeStatusRefreshCoordinator?.deactivateAndWait()
    let outcome = await beginStopRuntime().value
    await storeStatusCleanup?.value
    status = .stopped
    return outcome
  }

  private func startRuntime() {
    runtimeToken = UUID()
    let token = runtimeToken
    preparedIdentity = nil
    activeListener = nil
    preparingListener = nil
    pendingApps = []
    sessions = []
    explorerController = nil
    analysisCoordinator = nil
    composerController = nil
    selectedRoute = nil
    isPaused = false
    shutdownTask = nil
    status = .starting
    pendingCoalescer?.deactivate()
    sessionCoalescer?.deactivate()
    let pendingCoalescer = ViewerPendingCoalescer { [weak self] pending in
      guard let self, self.runtimeToken == token, self.pendingApps != pending else { return }
      self.pendingApps = pending
    }
    self.pendingCoalescer = pendingCoalescer
    let sessionCoalescer = ViewerSessionSnapshotCoalescer { [weak self] snapshots in
      guard let self, self.runtimeToken == token else { return }
      self.sessions = snapshots
      self.explorerController?.updateSessionSnapshots(snapshots)
      self.composerController?.updateSessionSnapshots(snapshots)
      if let selected = self.selectedRoute, snapshots.contains(where: { $0.route == selected }) {
        return
      }
      self.selectedRoute = snapshots.first?.route
    }
    self.sessionCoalescer = sessionCoalescer
    let runtimeLogicalID = UUID()
    let components = dependencies.makeRuntimeComponents(runtimeLogicalID)
    runtimeComponents = components
    let explorerController = ViewerEventExplorerController(inputs: components.explorerInputs)
    self.explorerController = explorerController
    explorerController.start()
    let performanceController = ViewerPerformanceDashboardController(
      driver: ViewerPerformanceProjectionDriver(
        live: components.liveObservations,
        storeGateway: components.explorerInputs.storeGateway
      ),
      analysisActive: false
    )
    let rawResolver = ViewerPerformanceRawEventResolver(
      store: ViewerPerformanceRawEventStoreDriver(
        gateway: components.explorerInputs.storeGateway
      ),
      live: components.liveObservations
    )
    analysisCoordinator = ViewerAnalysisModeCoordinator(
      eventController: explorerController,
      performanceController: performanceController,
      rawResolver: rawResolver
    )
    composerController = try? ViewerControlComposerController(
      runtimeLogicalID: runtimeLogicalID,
      sessionControl: components.sessionControl
    )
    refreshStoreStatus()
    sessionControl = components.sessionControl
    components.sessionControl.setSnapshotHandler { snapshots in
      sessionCoalescer.submit(snapshots)
    }
    admissionManager = makeAdmissionManager(
      pendingCoalescer: pendingCoalescer,
      handoffOwner: components.handoffOwner
    )
    admissionManager.setRequiresApproval(requiresApproval)

    let loadIdentity = dependencies.loadIdentity
    startupTask = Task { [weak self] in
      let identity: ViewerPreparedIdentity
      do {
        identity = try await Task.detached(operation: loadIdentity).value
        try Task.checkCancellation()
      } catch is CancellationError {
        return
      } catch {
        guard let self, self.runtimeToken == token else { return }
        self.failRuntime(.identityUnavailable)
        return
      }

      guard let self, self.runtimeToken == token else { return }
      self.preparedIdentity = identity
      do {
        try self.startListenerCandidate(identity: identity, collisionAttempt: 0)
      } catch let error as ViewerPresentationError {
        self.failRuntime(error)
      } catch {
        self.failRuntime(.listenerUnavailable)
      }
    }
  }

  private func beginStopRuntime() -> Task<ViewerCleanupOutcome, Never> {
    if let shutdownTask { return shutdownTask }
    runtimeToken = UUID()
    let token = runtimeToken
    startupTask?.cancel()
    startupTask = nil
    status = .stopping
    pendingCoalescer?.deactivate()
    pendingCoalescer = nil
    sessionCoalescer?.deactivate()
    sessionCoalescer = nil
    let analysisCleanup = analysisCoordinator?.sealAndWait() ?? Task {}
    analysisCoordinator = nil
    let explorerCleanup = explorerController?.sealAndClear() ?? Task {}
    explorerController = nil
    let composerCleanup = composerController?.sealAndClear() ?? Task {}
    composerController = nil
    let componentCleanup = runtimeComponents?.cleanupReceipt.begin() ?? Task {}
    let presentationCleanup = Task {
      async let explorer: Void = explorerCleanup.value
      async let analysis: Void = analysisCleanup.value
      async let composer: Void = composerCleanup.value
      _ = await (explorer, analysis, composer)
    }
    let receipt = admissionManager.stop().joining(componentCleanup).joining(presentationCleanup)
    preparingListener?.admissionIngress.deactivate()
    activeListener?.admissionIngress.deactivate()
    preparingListener?.listener.cancel()
    activeListener?.listener.cancel()
    preparingListener = nil
    activeListener = nil
    preparedIdentity = nil
    pendingApps = []
    sessions = []
    selectedRoute = nil
    sessionControl = nil
    runtimeComponents = nil
    isPaused = false
    let timeout = dependencies.cleanupTimeoutNanoseconds
    let scheduler = dependencies.scheduler
    let task = Task { [weak self] in
      let outcome = await receipt.wait(
        timeoutNanoseconds: timeout,
        scheduler: scheduler
      )
      guard let self, self.runtimeToken == token else { return outcome }
      return outcome
    }
    shutdownTask = task
    return task
  }

  private func failRuntime(_ error: ViewerPresentationError) {
    _ = beginStopRuntime()
    status = .failed(error)
  }

  private func resetIdentity(using operation: @escaping @Sendable () throws -> Void) {
    let cleanup = beginStopRuntime()
    let token = runtimeToken
    startupTask = Task { [weak self] in
      do {
        _ = await cleanup.value
        try Task.checkCancellation()
        guard let self, self.runtimeToken == token else { return }
        self.status = .starting
        try await Task.detached(operation: operation).value
        try Task.checkCancellation()
        guard self.runtimeToken == token else { return }
        self.status = .stopped
        self.startRuntime()
      } catch is CancellationError {
      } catch {
        guard let self, self.runtimeToken == token else { return }
        self.status = .failed(.identityUnavailable)
      }
    }
  }

  private func startListenerCandidate(
    identity: ViewerPreparedIdentity,
    collisionAttempt: Int
  ) throws {
    let pairingCode: PairingCode
    do {
      pairingCode = try dependencies.generatePairingCode()
    } catch {
      throw ViewerPresentationError.pairingUnavailable
    }
    let instanceName = NearWireBonjour.instanceName(for: pairingCode)
    let discriminator = ViewerDiscoveryDiscriminator(
      viewerInstallationID: identity.installationID
    )
    guard
      let serviceIdentity = NearWireBonjourServiceIdentity(
        instanceName: instanceName,
        type: NearWireBonjour.serviceType,
        domain: NearWireBonjour.localDomain,
        viewerDiscriminator: discriminator
      )
    else {
      throw ViewerPresentationError.listenerUnavailable
    }
    let listener: any ViewerSecureListener
    do {
      listener = try identity.makeListener(
        SecureViewerServiceAdvertisement(identity: serviceIdentity)
      )
    } catch let error as SecureTransportError
      where error.code == .localNetworkUnavailable
    {
      throw ViewerPresentationError.localNetworkUnavailable
    } catch {
      throw ViewerPresentationError.listenerUnavailable
    }
    let candidate = ViewerListenerGeneration(
      pairingCode: pairingCode,
      listener: listener,
      collisionAttempt: collisionAttempt
    )
    preparingListener = candidate
    let generationID = candidate.id
    let admissionIngress = candidate.admissionIngress
    do {
      try listener.start(queue: listenerQueue) { [weak self, admissionIngress] event in
        if case .incoming(let incoming) = event {
          admissionIngress.receive(incoming)
          return
        }
        Task { @MainActor [weak self] in
          self?.handleListenerEvent(event, generationID: generationID)
        }
      }
    } catch {
      if preparingListener?.id == candidate.id { preparingListener = nil }
      throw ViewerPresentationError.listenerUnavailable
    }
  }

  private func makeAdmissionManager(
    pendingCoalescer: ViewerPendingCoalescer,
    handoffOwner: any ViewerAdmissionHandoffOwning
  ) -> ViewerAdmissionManager {
    ViewerAdmissionManager(
      onPending: { pending in pendingCoalescer.submit(pending) },
      handoffOwner: handoffOwner,
      scheduler: dependencies.scheduler
    )
  }

  private func handleListenerEvent(
    _ event: SecureViewerListenerEvent,
    generationID: UUID
  ) {
    guard let candidate = listenerGeneration(id: generationID) else { return }
    switch event {
    case .ready:
      candidate.isReady = true
      commitIfRegistered(candidate)
    case .serviceRegistered(let exact):
      guard exact else {
        handleRegistrationCollision(candidate)
        return
      }
      candidate.isExactlyRegistered = true
      commitIfRegistered(candidate)
    case .serviceRemoved:
      handleRegistrationCollision(candidate)
    case .incoming(let incoming):
      // Incoming events are admitted synchronously at the listener callback edge.
      incoming.reject()
    case .failed(let transportError):
      let error: ViewerPresentationError =
        transportError.code == .localNetworkUnavailable
        ? .localNetworkUnavailable : .listenerUnavailable
      handleListenerFailure(candidate, error: error)
    case .cancelled:
      break
    }
  }

  private func commitIfRegistered(_ candidate: ViewerListenerGeneration) {
    guard preparingListener?.id == candidate.id,
      candidate.isReady,
      candidate.isExactlyRegistered
    else { return }

    guard let identity = preparedIdentity else { return }
    let oldListener = activeListener
    admissionManager.activateGeneration(candidate.id)
    candidate.admissionIngress.activate(
      manager: admissionManager,
      generation: candidate.id,
      viewerInstallationID: identity.installationID
    )
    activeListener = candidate
    preparingListener = nil
    if let oldListener {
      oldListener.admissionIngress.deactivate()
      admissionManager.cancelGeneration(oldListener.id)
      oldListener.listener.cancel()
    }
    admissionManager.setPaused(isPaused)
    status = .listening(
      code: candidate.pairingCode.canonicalValue,
      paused: isPaused
    )
  }

  private func handleRegistrationCollision(_ candidate: ViewerListenerGeneration) {
    let wasPreparing = preparingListener?.id == candidate.id
    let wasActive = activeListener?.id == candidate.id
    guard wasPreparing || wasActive else { return }
    if wasPreparing {
      candidate.admissionIngress.deactivate()
      preparingListener = nil
    } else {
      candidate.admissionIngress.deactivate()
      activeListener = nil
      admissionManager.cancelGeneration(candidate.id)
      status = .starting
    }
    candidate.listener.cancel()
    guard candidate.collisionAttempt + 1 < Self.maximumCollisionAttempts,
      let identity = preparedIdentity
    else {
      if activeListener == nil { failRuntime(.listenerUnavailable) }
      return
    }
    do {
      try startListenerCandidate(
        identity: identity,
        collisionAttempt: candidate.collisionAttempt + 1
      )
    } catch let error as ViewerPresentationError {
      if activeListener == nil { failRuntime(error) }
    } catch {
      if activeListener == nil { failRuntime(.listenerUnavailable) }
    }
  }

  private func handleListenerFailure(
    _ candidate: ViewerListenerGeneration,
    error: ViewerPresentationError
  ) {
    if preparingListener?.id == candidate.id {
      candidate.admissionIngress.deactivate()
      preparingListener = nil
      candidate.listener.cancel()
      if activeListener == nil { failRuntime(error) }
      return
    }
    guard activeListener?.id == candidate.id else { return }
    candidate.admissionIngress.deactivate()
    admissionManager.cancelGeneration(candidate.id)
    activeListener = nil
    candidate.listener.cancel()
    failRuntime(error)
  }

  private func listenerGeneration(id: UUID) -> ViewerListenerGeneration? {
    if preparingListener?.id == id { return preparingListener }
    if activeListener?.id == id { return activeListener }
    return nil
  }
}

struct ViewerPreferences: Sendable {
  static let live = ViewerPreferences(
    requiresApproval: {
      UserDefaults.standard.bool(forKey: "viewer.requiresNewDeviceApproval")
    },
    setRequiresApproval: { value in
      UserDefaults.standard.set(value, forKey: "viewer.requiresNewDeviceApproval")
    }
  )

  let requiresApproval: @Sendable () -> Bool
  let setRequiresApproval: @Sendable (Bool) -> Void
}
