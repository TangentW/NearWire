import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireBuiltins) import NearWire
#endif

struct PerformanceRuntime: Sendable {
  let isSupportedPlatform: Bool
  let clock: PerformanceClock
  let wallClock: @Sendable () -> Date
  let claimMonitorLease: @Sendable () throws -> PerformanceMonitorLease
  let makeCollector:
    @Sendable (
      _ configuration: NearWirePerformanceConfiguration,
      _ attempt: PerformanceStartAttempt
    ) async throws -> any PerformanceCollectorSession
  let beforeSetupCommit: @Sendable () async -> Void
  let sendSnapshot: @Sendable (_ snapshot: PerformanceSnapshot) async throws -> Void

  static func live(nearWire: NearWire) -> PerformanceRuntime {
    PerformanceRuntime(
      isSupportedPlatform: {
        #if os(iOS)
          true
        #else
          false
        #endif
      }(),
      clock: .live,
      wallClock: { Date() },
      claimMonitorLease: { try PerformanceMonitorLeaseRegistry.claim(nearWire) },
      makeCollector: { configuration, attempt in
        #if os(iOS)
          let platform: any PerformancePlatformSession
          if configuration.displayMetricsEnabled || configuration.deviceMetricsEnabled {
            platform = await LivePerformancePlatformSession.make(
              configuration: configuration,
              attempt: attempt
            )
          } else {
            platform = DisabledPerformancePlatformSession()
          }
          return LivePerformanceCollectorSession(
            configuration: configuration,
            platform: platform,
            readCPUSeconds: { PerformanceSystemReaders.processCPUSeconds() },
            readMemoryFootprint: { PerformanceSystemReaders.memoryFootprintBytes() },
            readTransport: {
              try? await nearWire.bufferDiagnostics()
            }
          )
        #else
          throw NearWirePerformanceError.unsupportedPlatform
        #endif
      },
      beforeSetupCommit: {},
      sendSnapshot: { snapshot in
        _ = try await nearWire.sendPlatformEvent(
          type: "nearwire.performance.snapshot",
          content: snapshot,
          policy: .keepLatest(key: "nearwire.performance.snapshot")
        )
      }
    )
  }
}

enum PerformanceStartOutcome: Sendable {
  case success
  case failure(PerformanceStartFailure)
}

enum PerformanceStartFailure: Sendable {
  case cancelled
  case performance(NearWirePerformanceError)

  func throwValue() throws {
    switch self {
    case .cancelled:
      throw CancellationError()
    case .performance(let error):
      throw error
    }
  }
}

final class PerformanceStartAttempt: @unchecked Sendable {
  let token = UUID()
  let priorState: NearWirePerformanceMonitorState

  private let lock = NSLock()
  private var isCancelledValue = false
  private var isActivationAuthorizedValue = false
  private var isCommittedValue = false
  private var setupTask: Task<Void, Never>?
  private var outcome: PerformanceStartOutcome?
  private var waiters: [UUID: CheckedContinuation<PerformanceStartOutcome, Never>] = [:]

  init(priorState: NearWirePerformanceMonitorState) {
    self.priorState = priorState
  }

  var isCancelled: Bool {
    lock.withLock { isCancelledValue }
  }

  var waiterCount: Int {
    lock.withLock { waiters.count }
  }

  func install(task: Task<Void, Never>) {
    let cancelImmediately = lock.withLock {
      setupTask = task
      return isCancelledValue
    }
    if cancelImmediately { task.cancel() }
  }

  func cancel() {
    let task = lock.withLock {
      if !isCommittedValue { isCancelledValue = true }
      return setupTask
    }
    task?.cancel()
  }

  func authorizeActivation() -> Bool {
    lock.withLock {
      guard !isCancelledValue, !isActivationAuthorizedValue, !isCommittedValue else {
        return false
      }
      isActivationAuthorizedValue = true
      return true
    }
  }

  func commitActivation() -> Bool {
    lock.withLock {
      guard isActivationAuthorizedValue, !isCancelledValue, !isCommittedValue else {
        return false
      }
      isCommittedValue = true
      return true
    }
  }

  func performAcquisition<Value>(_ body: () -> Value) -> Value? {
    lock.withLock {
      guard !isCancelledValue, !isActivationAuthorizedValue, !isCommittedValue else {
        return nil
      }
      return body()
    }
  }

  func wait() async -> PerformanceStartOutcome {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let outcome {
        lock.unlock()
        continuation.resume(returning: outcome)
        return
      }
      waiters[UUID()] = continuation
      lock.unlock()
    }
  }

  func resolve(_ outcome: PerformanceStartOutcome) {
    lock.lock()
    guard self.outcome == nil else {
      lock.unlock()
      return
    }
    self.outcome = outcome
    setupTask = nil
    let active = Array(waiters.values)
    waiters.removeAll(keepingCapacity: false)
    lock.unlock()
    for continuation in active {
      continuation.resume(returning: outcome)
    }
  }
}

final class PerformanceWeakMonitor: @unchecked Sendable {
  weak var monitor: NearWirePerformanceMonitor?
}

final class PerformanceSetupWorker: @unchecked Sendable {
  private let configuration: NearWirePerformanceConfiguration
  private let runtime: PerformanceRuntime
  private let attempt: PerformanceStartAttempt
  private let weakMonitor: PerformanceWeakMonitor

  init(
    configuration: NearWirePerformanceConfiguration,
    runtime: PerformanceRuntime,
    attempt: PerformanceStartAttempt,
    weakMonitor: PerformanceWeakMonitor
  ) {
    self.configuration = configuration
    self.runtime = runtime
    self.attempt = attempt
    self.weakMonitor = weakMonitor
  }

  func run() async {
    var lease: PerformanceMonitorLease?
    var collector: (any PerformanceCollectorSession)?
    do {
      try checkCancellation()
      guard runtime.isSupportedPlatform else {
        throw NearWirePerformanceError.unsupportedPlatform
      }

      lease = try runtime.claimMonitorLease()
      try checkCancellation()
      collector = try await runtime.makeCollector(configuration, attempt)
      try checkCancellation()
      guard let preparedCollector = collector, let preparedLease = lease else {
        throw NearWirePerformanceError.collectorSetupFailed
      }

      guard let monitor = weakMonitor.monitor else { throw CancellationError() }
      guard
        await monitor.authorizePreparedActivation(
          attempt: attempt
        )
      else {
        throw CancellationError()
      }

      await runtime.beforeSetupCommit()
      try checkCancellation()
      let initialBoundary = await preparedCollector.activate(clock: runtime.clock)
      try checkCancellation()
      guard
        await monitor.commitActivatedStart(
          attempt: attempt,
          lease: preparedLease,
          collector: preparedCollector,
          initialBoundary: initialBoundary
        )
      else {
        throw CancellationError()
      }

      lease = nil
      collector = nil
      return
    } catch {
      if let collector { await collector.stop() }
      lease?.release()
      let failure = startFailure(for: error)
      if let monitor = weakMonitor.monitor {
        await monitor.setupDidFail(attempt: attempt, failure: failure)
      } else {
        attempt.resolve(.failure(failure))
      }
    }
  }

  private func checkCancellation() throws {
    try Task.checkCancellation()
    guard !attempt.isCancelled else { throw CancellationError() }
  }

  private func startFailure(for error: Error) -> PerformanceStartFailure {
    if Task.isCancelled || attempt.isCancelled || error is CancellationError {
      return .cancelled
    }
    if let error = error as? NearWirePerformanceError { return .performance(error) }
    return .performance(.collectorSetupFailed)
  }
}

final class PerformanceRunWorker: @unchecked Sendable {
  let token: UUID

  private let configuration: NearWirePerformanceConfiguration
  private let runtime: PerformanceRuntime
  private let collector: any PerformanceCollectorSession
  private let lease: PerformanceMonitorLease
  private let weakMonitor: PerformanceWeakMonitor
  private var previousBoundary: ContinuousClock.Instant

  init(
    token: UUID,
    configuration: NearWirePerformanceConfiguration,
    runtime: PerformanceRuntime,
    collector: any PerformanceCollectorSession,
    lease: PerformanceMonitorLease,
    weakMonitor: PerformanceWeakMonitor,
    initialBoundary: ContinuousClock.Instant
  ) {
    self.token = token
    self.configuration = configuration
    self.runtime = runtime
    self.collector = collector
    self.lease = lease
    self.weakMonitor = weakMonitor
    previousBoundary = initialBoundary
  }

  func run() async {
    var terminalError: NearWirePerformanceError?
    do {
      while true {
        try await runtime.clock.sleep(configuration.sampleInterval)
        try Task.checkCancellation()
        let boundary = runtime.clock.now()
        let sampledAt = runtime.wallClock()
        let interval = PerformanceDurationConversion.positiveRoundedMilliseconds(
          previousBoundary.duration(to: boundary)
        )
        previousBoundary = boundary
        let reading = await collector.sample(at: boundary)
        let snapshot = try PerformanceSnapshotProjection.makeSnapshot(
          configuration: configuration,
          sampledAt: sampledAt,
          intervalMilliseconds: interval,
          reading: reading
        )
        try await runtime.sendSnapshot(snapshot)
      }
    } catch is CancellationError {
      terminalError = nil
    } catch {
      terminalError = .eventSubmissionFailed
      await weakMonitor.monitor?.runWillStop(token: token, error: .eventSubmissionFailed)
    }

    await collector.stop()
    lease.release()
    await weakMonitor.monitor?.runDidFinish(token: token, error: terminalError)
  }
}
