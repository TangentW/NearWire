import Foundation
import NearWire
@_spi(NearWireInternal) import NearWireCore
import XCTest

@testable import NearWirePerformance

final class PerformanceManualClock: @unchecked Sendable {
  private enum Outcome: Sendable {
    case elapsed
    case cancelled
  }

  private struct Waiter {
    let duration: Duration
    let continuation: CheckedContinuation<Outcome, Never>
  }

  private let lock = NSLock()
  private let origin = ContinuousClock().now
  private var offset: Duration = .zero
  private var order: [UUID] = []
  private var waiters: [UUID: Waiter] = [:]
  private var cancelled: Set<UUID> = []

  var clock: PerformanceClock {
    PerformanceClock(
      now: { [self] in lock.withLock { origin.advanced(by: offset) } },
      sleep: { [self] duration in try await sleep(for: duration) }
    )
  }

  var waiterCount: Int {
    lock.withLock { waiters.count }
  }

  func advanceNext(by override: Duration? = nil) {
    let continuation: CheckedContinuation<Outcome, Never>? = lock.withLock {
      guard let identifier = order.first else { return nil }
      order.removeFirst()
      guard let waiter = waiters.removeValue(forKey: identifier) else { return nil }
      offset += override ?? waiter.duration
      return waiter.continuation
    }
    continuation?.resume(returning: .elapsed)
  }

  func advance(by duration: Duration) {
    lock.withLock { offset += duration }
  }

  private func sleep(for duration: Duration) async throws {
    let identifier = UUID()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let wasCancelled = lock.withLock {
          if cancelled.remove(identifier) != nil { return true }
          order.append(identifier)
          waiters[identifier] = Waiter(duration: duration, continuation: continuation)
          return false
        }
        if wasCancelled { continuation.resume(returning: .cancelled) }
      }
    } onCancel: {
      let continuation: CheckedContinuation<Outcome, Never>? = self.lock.withLock {
        self.order.removeAll { $0 == identifier }
        if let continuation = self.waiters.removeValue(forKey: identifier)?.continuation {
          return continuation
        }
        self.cancelled.insert(identifier)
        return nil
      }
      continuation?.resume(returning: .cancelled)
    }
    if case .cancelled = outcome { throw CancellationError() }
  }
}

actor PerformanceFakeCollector: PerformanceCollectorSession {
  private(set) var activationCount = 0
  private(set) var activationInstant: ContinuousClock.Instant?
  private(set) var sampleCount = 0
  private(set) var stopStartedCount = 0
  private(set) var stopCount = 0
  var reading: PerformanceCollectedReading
  private let stopGate: PerformanceAsyncGate?
  private let onSample: (@Sendable () -> Void)?

  init(
    reading: PerformanceCollectedReading = PerformanceCollectedReading(),
    stopGate: PerformanceAsyncGate? = nil,
    onSample: (@Sendable () -> Void)? = nil
  ) {
    self.reading = reading
    self.stopGate = stopGate
    self.onSample = onSample
  }

  func activate(clock: PerformanceClock) -> ContinuousClock.Instant {
    let instant = clock.now()
    activationCount += 1
    activationInstant = instant
    return instant
  }

  func sample(at _: ContinuousClock.Instant) -> PerformanceCollectedReading {
    onSample?()
    sampleCount += 1
    return reading
  }

  func stop() async {
    stopStartedCount += 1
    await stopGate?.wait()
    stopCount += 1
  }
}

actor PerformanceSnapshotRecorder {
  private(set) var snapshots: [PerformanceSnapshot] = []
  private var failure: NearWirePerformanceError?

  func append(_ snapshot: PerformanceSnapshot) throws {
    if let failure { throw failure }
    snapshots.append(snapshot)
  }

  func fail(with error: NearWirePerformanceError) {
    failure = error
  }
}

actor PerformanceAsyncCounter {
  private(set) var value = 0

  func increment() {
    value += 1
  }
}

actor PerformanceAsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let active = waiters
    waiters.removeAll(keepingCapacity: false)
    for continuation in active { continuation.resume() }
  }
}

final class PerformanceLeaseAnchor: NSObject, @unchecked Sendable {}

final class PerformanceWeakBox<Value: AnyObject>: @unchecked Sendable {
  weak var value: Value?

  init(_ value: Value?) {
    self.value = value
  }
}

func makePerformanceRuntime(
  clock: PerformanceManualClock,
  collector: PerformanceFakeCollector,
  recorder: PerformanceSnapshotRecorder,
  anchor: PerformanceLeaseAnchor = PerformanceLeaseAnchor(),
  makeCollector: (
    @Sendable (
      NearWirePerformanceConfiguration,
      PerformanceStartAttempt
    ) async throws -> any PerformanceCollectorSession
  )? = nil,
  beforeSetupCommit: @escaping @Sendable () async -> Void = {},
  wallClock: @escaping @Sendable () -> Date = {
    Date(timeIntervalSince1970: 1_700_000_000)
  },
  sendSnapshot: (@Sendable (PerformanceSnapshot) async throws -> Void)? = nil
) -> PerformanceRuntime {
  let collectorFactory = makeCollector ?? { _, _ in collector }
  let snapshotSender = sendSnapshot ?? { snapshot in try await recorder.append(snapshot) }
  return PerformanceRuntime(
    isSupportedPlatform: true,
    clock: clock.clock,
    wallClock: wallClock,
    claimMonitorLease: { try PerformanceMonitorLeaseRegistry.claim(anchor) },
    makeCollector: collectorFactory,
    beforeSetupCommit: beforeSetupCommit,
    sendSnapshot: snapshotSender
  )
}

final class PerformanceLockedTrace: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String] = []

  var values: [String] { lock.withLock { entries } }

  func append(_ value: String) {
    lock.withLock { entries.append(value) }
  }
}

final class PerformanceLockedSequence<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Value]

  init(_ values: [Value]) {
    self.values = values
  }

  func next() -> Value {
    lock.withLock { values.removeFirst() }
  }
}

func waitUntil(
  _ description: String,
  iterations: Int = 2_000,
  condition: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<iterations {
    if await condition() { return }
    await Task.yield()
  }
  XCTFail("Timed out waiting for \(description).")
}
