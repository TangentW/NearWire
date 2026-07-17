import Foundation

#if SWIFT_PACKAGE
  import NearWirePerformance
#endif

protocol NearWireUIPerformanceControlling: AnyObject, Sendable {
  var states: AsyncStream<NearWirePerformanceMonitorState> { get }
  func start() async throws
  func stop() async
}

extension NearWirePerformanceMonitor: NearWireUIPerformanceControlling {}

@MainActor
final class NearWireUIPerformanceModel: ObservableObject {
  enum Operation: Equatable {
    case idle
    case starting
    case stopping
  }

  @Published private(set) var state: NearWirePerformanceMonitorState = .stopped
  @Published private(set) var operation: Operation = .idle
  @Published private(set) var displayedErrorMessage: String?

  private let controller: any NearWireUIPerformanceControlling
  private var generation: UInt64 = 0
  private var observationTask: Task<Void, Never>?
  private var actionTask: Task<Void, Never>?

  init(controller: any NearWireUIPerformanceControlling) {
    self.controller = controller
  }

  deinit {
    observationTask?.cancel()
    actionTask?.cancel()
  }

  var isEnabled: Bool {
    switch operation {
    case .starting:
      return true
    case .stopping:
      return false
    case .idle:
      return state == .running
    }
  }

  var isOperationPending: Bool {
    operation != .idle
  }

  var stateLabel: String {
    switch operation {
    case .starting:
      return "Starting"
    case .stopping:
      return "Stopping"
    case .idle:
      switch state {
      case .stopped:
        return "Stopped"
      case .running:
        return "Running"
      case .failed:
        return "Failed"
      }
    }
  }

  func startObserving() {
    guard observationTask == nil else { return }
    generation &+= 1
    let currentGeneration = generation
    let states = controller.states
    observationTask = Task { [weak self] in
      for await state in states {
        guard !Task.isCancelled, let self else { return }
        self.apply(state, generation: currentGeneration)
      }
    }
  }

  func stopObserving() {
    generation &+= 1
    observationTask?.cancel()
    observationTask = nil
    actionTask?.cancel()
    actionTask = nil
    state = .stopped
    operation = .idle
    displayedErrorMessage = nil
  }

  func setEnabled(_ enabled: Bool) {
    guard operation == .idle else { return }
    if enabled {
      guard state != .running else { return }
      startPerformance()
    } else {
      guard state == .running || isFailed else { return }
      stopPerformance()
    }
  }

  private var isFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  private func startPerformance() {
    operation = .starting
    displayedErrorMessage = nil
    let currentGeneration = generation
    let controller = controller
    actionTask = Task { [weak self, controller] in
      let outcome: Result<Void, Error>
      do {
        try await controller.start()
        outcome = .success(())
      } catch {
        outcome = .failure(error)
      }
      guard !Task.isCancelled, let self else { return }
      self.finishStart(outcome, generation: currentGeneration)
    }
  }

  private func stopPerformance() {
    operation = .stopping
    displayedErrorMessage = nil
    let currentGeneration = generation
    let controller = controller
    actionTask = Task { [weak self, controller] in
      await controller.stop()
      guard !Task.isCancelled, let self else { return }
      self.finishStop(generation: currentGeneration)
    }
  }

  private func apply(
    _ state: NearWirePerformanceMonitorState,
    generation expectedGeneration: UInt64
  ) {
    guard generation == expectedGeneration else { return }
    self.state = state
    switch state {
    case .stopped, .running:
      displayedErrorMessage = nil
    case .failed(let error):
      displayedErrorMessage = error.message
    }
  }

  private func finishStart(
    _ outcome: Result<Void, Error>,
    generation expectedGeneration: UInt64
  ) {
    guard generation == expectedGeneration, operation == .starting else { return }
    actionTask = nil
    operation = .idle
    switch outcome {
    case .success:
      break
    case .failure(let error as NearWirePerformanceError):
      displayedErrorMessage = error.message
    case .failure:
      displayedErrorMessage = "Performance collection could not start."
    }
  }

  private func finishStop(generation expectedGeneration: UInt64) {
    guard generation == expectedGeneration, operation == .stopping else { return }
    actionTask = nil
    operation = .idle
  }
}
