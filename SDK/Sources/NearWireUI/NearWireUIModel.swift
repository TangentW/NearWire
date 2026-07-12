import SwiftUI

#if SWIFT_PACKAGE
  import NearWire
#endif

@MainActor
final class NearWireUIConnectionModel: ObservableObject {
  @Published private(set) var pairingCode = ""
  @Published private(set) var status: NearWireConnectionStatus?
  @Published private(set) var operationPhase: NearWireUIOperationPhase = .idle
  @Published private(set) var actionError: NearWireUIActionError?

  private let controller: any NearWireUIConnectionControlling
  private let coordinator: NearWireUIOperationCoordinator
  private var statusTask: Task<Void, Never>?
  private var phaseTask: Task<Void, Never>?
  private var registration: NearWireUIPhaseRegistration?
  private var activeOperationToken: NearWireUIOperationToken?
  private var statusGeneration: UInt64 = 0
  private var phaseGeneration: UInt64 = 0
  private var actionGeneration: UInt64 = 0
  private(set) var isPresented = false

  init(
    controller: any NearWireUIConnectionControlling
  ) {
    self.controller = controller
    coordinator = .shared
  }

  init(
    controller: any NearWireUIConnectionControlling,
    coordinator: NearWireUIOperationCoordinator
  ) {
    self.controller = controller
    self.coordinator = coordinator
  }

  deinit {
    coordinator.releaseModel(
      controller: controller,
      registrationToken: registration?.token,
      operationToken: activeOperationToken
    )
    statusTask?.cancel()
    phaseTask?.cancel()
  }

  func start() {
    guard !isPresented else { return }
    isPresented = true

    phaseGeneration &+= 1
    let currentPhaseGeneration = phaseGeneration
    let registration = coordinator.subscribe(controller: controller)
    self.registration = registration
    operationPhase = registration.initialPhase
    phaseTask = Task { [weak self, stream = registration.stream] in
      for await phase in stream {
        guard !Task.isCancelled else { return }
        self?.receivePhase(phase, generation: currentPhaseGeneration)
      }
    }

    statusGeneration &+= 1
    let currentStatusGeneration = statusGeneration
    let stream = controller.connectionStatuses
    statusTask = Task { [weak self, stream] in
      for await status in stream {
        guard !Task.isCancelled else { return }
        self?.receiveStatus(status, generation: currentStatusGeneration)
      }
    }
  }

  func stop() {
    guard isPresented else { return }
    isPresented = false
    statusGeneration &+= 1
    phaseGeneration &+= 1
    actionGeneration &+= 1

    if let activeOperationToken {
      coordinator.cancelConnectForDisappearance(
        controller: controller,
        token: activeOperationToken
      )
    }
    if let registration {
      coordinator.unsubscribe(controller: controller, token: registration.token)
    }
    statusTask?.cancel()
    phaseTask?.cancel()
    statusTask = nil
    phaseTask = nil
    registration = nil
    activeOperationToken = nil
    pairingCode = ""
    status = nil
    operationPhase = .idle
    actionError = nil
  }

  func updatePairingCode(_ value: String) {
    pairingCode = NearWireUIInputLimiter.limit(value)
  }

  func performPrimaryAction() {
    switch actionPresentation {
    case .connect:
      connect()
    case .cancel, .disconnect:
      disconnect()
    case .cancelling, .disconnecting, .none:
      return
    }
  }

  func resetConnection() {
    guard actionPresentation.showsReset else { return }
    disconnect()
  }

  var actionPresentation: NearWireUIActionPresentation {
    guard isPresented, let status else { return .none }
    if status.state == .shutdown { return .none }
    switch operationPhase {
    case .connecting:
      return .cancel
    case .cancelling:
      return .cancelling
    case .disconnecting:
      return .disconnecting
    case .idle:
      break
    }

    if status.isSuspended { return .disconnect }
    switch status.state {
    case .discovering, .connecting, .connected, .reconnecting:
      return .disconnect
    case .disconnected:
      return .connect(showsReset: status.lastError != nil || actionError?.offersReset == true)
    case .idle:
      return .connect(showsReset: actionError?.offersReset == true)
    case .shutdown:
      return .none
    }
  }

  var displayedErrorMessage: String? {
    actionError?.message ?? status?.lastError?.message
  }

  var canSubmitPairingCode: Bool {
    guard case .connect = actionPresentation else { return false }
    return !pairingCode.isEmpty
  }

  private func connect() {
    guard isPresented, operationPhase == .idle, activeOperationToken == nil,
      !pairingCode.isEmpty
    else { return }
    actionGeneration &+= 1
    let generation = actionGeneration
    actionError = nil
    let code = pairingCode
    activeOperationToken = coordinator.connect(
      controller: controller,
      code: code
    ) { [weak self] token, outcome in
      self?.receiveConnectOutcome(outcome, token: token, generation: generation)
    }
  }

  private func disconnect() {
    guard isPresented else { return }
    actionGeneration &+= 1
    activeOperationToken = nil
    pairingCode = ""
    actionError = nil
    coordinator.disconnect(controller: controller)
  }

  private func receiveStatus(_ status: NearWireConnectionStatus, generation: UInt64) {
    guard isPresented, statusGeneration == generation else { return }
    self.status = status
  }

  private func receivePhase(_ phase: NearWireUIOperationPhase, generation: UInt64) {
    guard isPresented, phaseGeneration == generation else { return }
    guard let activeOperationToken else {
      operationPhase = phase
      return
    }
    let retainsOrigin = coordinator.retainsOrigin(
      controller: controller,
      token: activeOperationToken
    )
    applyObservedPhase(phase, retainsOrigin: retainsOrigin)
  }

  func applyObservedPhase(
    _ phase: NearWireUIOperationPhase,
    retainsOrigin: Bool
  ) {
    operationPhase = phase
    guard activeOperationToken != nil, !retainsOrigin else { return }
    self.activeOperationToken = nil
    actionGeneration &+= 1
    pairingCode = ""
    actionError = nil
  }

  private func receiveConnectOutcome(
    _ outcome: NearWireUIConnectOutcome,
    token: NearWireUIOperationToken,
    generation: UInt64
  ) {
    guard isPresented, actionGeneration == generation, activeOperationToken === token else {
      return
    }
    activeOperationToken = nil
    switch outcome {
    case .success:
      pairingCode = ""
      actionError = nil
    case .cancelled:
      break
    case .failure(let error):
      actionError = error
    }
  }
}
