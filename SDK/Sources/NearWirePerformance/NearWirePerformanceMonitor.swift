import Foundation

#if SWIFT_PACKAGE
  import NearWire
#endif

/// An explicit-lifecycle monitor that submits aggregate built-in performance events.
public actor NearWirePerformanceMonitor {
  public nonisolated var states: AsyncStream<NearWirePerformanceMonitorState> {
    stateHub.makeStream()
  }

  public var currentState: NearWirePerformanceMonitorState { state }

  private enum Phase {
    case idle
    case starting(PerformanceStartAttempt)
    case running(token: UUID, task: Task<Void, Never>)
    case stopping(PerformanceStopSlot)
  }

  private enum PerformanceStopBarrier {
    case attempt(PerformanceStartAttempt)
    case run(token: UUID, task: Task<Void, Never>)

    func wait() async {
      switch self {
      case .attempt(let attempt):
        _ = await attempt.wait()
      case .run(_, let task):
        await task.value
      }
    }

    func cancel() {
      switch self {
      case .attempt(let attempt):
        attempt.cancel()
      case .run(_, let task):
        task.cancel()
      }
    }
  }

  private struct PerformanceStopSlot {
    let token: UUID
    let barrier: PerformanceStopBarrier
    var target: NearWirePerformanceMonitorState
  }

  private nonisolated let stateHub: NearWirePerformanceStateHub
  private nonisolated let configuration: NearWirePerformanceConfiguration
  private nonisolated let runtime: PerformanceRuntime
  private nonisolated let weakMonitor: PerformanceWeakMonitor
  private var state: NearWirePerformanceMonitorState = .stopped
  private var phase: Phase = .idle

  public init(
    nearWire: NearWire,
    configuration: NearWirePerformanceConfiguration = .default
  ) {
    self.configuration = configuration
    stateHub = NearWirePerformanceStateHub(initial: .stopped)
    runtime = .live(nearWire: nearWire)
    let weakMonitor = PerformanceWeakMonitor()
    self.weakMonitor = weakMonitor
    weakMonitor.monitor = self
  }

  internal init(
    configuration: NearWirePerformanceConfiguration = .default,
    runtime: PerformanceRuntime
  ) {
    self.configuration = configuration
    stateHub = NearWirePerformanceStateHub(initial: .stopped)
    self.runtime = runtime
    let weakMonitor = PerformanceWeakMonitor()
    self.weakMonitor = weakMonitor
    weakMonitor.monitor = self
  }

  deinit {
    switch phase {
    case .idle:
      break
    case .starting(let attempt):
      attempt.cancel()
    case .running(_, let task):
      task.cancel()
    case .stopping(let slot):
      slot.barrier.cancel()
    }
    stateHub.finish()
  }

  public func start() async throws {
    while true {
      switch phase {
      case .idle:
        try Task.checkCancellation()
        let attempt = PerformanceStartAttempt(priorState: state)
        phase = .starting(attempt)
        let worker = PerformanceSetupWorker(
          configuration: configuration,
          runtime: runtime,
          attempt: attempt,
          weakMonitor: weakMonitor
        )
        let task = Task { await worker.run() }
        attempt.install(task: task)
        try await waitForStartAttempt(attempt)
        return
      case .starting(let attempt):
        try await waitForStartAttempt(attempt)
        return
      case .running:
        return
      case .stopping(let slot):
        await slot.barrier.wait()
        try Task.checkCancellation()
      }
    }
  }

  public func stop() async {
    switch phase {
    case .idle:
      transition(to: .stopped)
    case .starting(let attempt):
      let slot = PerformanceStopSlot(
        token: UUID(),
        barrier: .attempt(attempt),
        target: .stopped
      )
      phase = .stopping(slot)
      attempt.cancel()
      await slot.barrier.wait()
    case .running(let token, let task):
      let slot = PerformanceStopSlot(
        token: UUID(),
        barrier: .run(token: token, task: task),
        target: .stopped
      )
      phase = .stopping(slot)
      task.cancel()
      await task.value
    case .stopping(var slot):
      slot.target = .stopped
      phase = .stopping(slot)
      await slot.barrier.wait()
    }
  }

  internal nonisolated var stateSubscriberCount: Int {
    stateHub.subscriberCount
  }

  internal var startingWaiterCount: Int {
    guard case .starting(let attempt) = phase else { return 0 }
    return attempt.waiterCount
  }

  internal var isStoppingTowardStopped: Bool {
    guard case .stopping(let slot) = phase else { return false }
    return slot.target == .stopped
  }

  private func waitForStartAttempt(_ attempt: PerformanceStartAttempt) async throws {
    let outcome = await withTaskCancellationHandler {
      await attempt.wait()
    } onCancel: {
      attempt.cancel()
    }
    if case .failure(let failure) = outcome { try failure.throwValue() }
  }

  func authorizePreparedActivation(attempt: PerformanceStartAttempt) -> Bool {
    guard case .starting(let current) = phase, current === attempt else {
      return false
    }
    return attempt.authorizeActivation()
  }

  func commitActivatedStart(
    attempt: PerformanceStartAttempt,
    lease: PerformanceMonitorLease,
    collector: any PerformanceCollectorSession,
    initialBoundary: ContinuousClock.Instant
  ) -> Bool {
    guard case .starting(let current) = phase, current === attempt,
      attempt.commitActivation()
    else {
      return false
    }

    let token = UUID()
    let worker = PerformanceRunWorker(
      token: token,
      configuration: configuration,
      runtime: runtime,
      collector: collector,
      lease: lease,
      weakMonitor: weakMonitor,
      initialBoundary: initialBoundary
    )
    let task = Task { await worker.run() }
    phase = .running(token: token, task: task)
    transition(to: .running)
    attempt.resolve(.success)
    return true
  }

  func setupDidFail(
    attempt: PerformanceStartAttempt,
    failure: PerformanceStartFailure
  ) {
    finishStartAttempt(attempt, outcome: .failure(failure))
  }

  private func finishStartAttempt(
    _ attempt: PerformanceStartAttempt,
    outcome: PerformanceStartOutcome
  ) {
    switch phase {
    case .starting(let current) where current === attempt:
      phase = .idle
    case .stopping(let slot):
      if case .attempt(let current) = slot.barrier, current === attempt {
        phase = .idle
        transition(to: slot.target)
      }
    default:
      break
    }
    attempt.resolve(outcome)
  }

  func runWillStop(token: UUID, error: NearWirePerformanceError) {
    guard case .running(let currentToken, let task) = phase, currentToken == token else { return }
    phase = .stopping(
      PerformanceStopSlot(
        token: UUID(),
        barrier: .run(token: token, task: task),
        target: .failed(error)
      )
    )
  }

  func runDidFinish(token: UUID, error: NearWirePerformanceError?) {
    switch phase {
    case .running(let currentToken, _) where currentToken == token:
      phase = .idle
      transition(to: error.map(NearWirePerformanceMonitorState.failed) ?? .stopped)
    case .stopping(let slot):
      guard case .run(let currentToken, _) = slot.barrier, currentToken == token else { return }
      phase = .idle
      transition(to: slot.target)
    default:
      break
    }
  }

  private func transition(to newState: NearWirePerformanceMonitorState) {
    guard state != newState else { return }
    state = newState
    stateHub.publish(newState)
  }
}
