import Foundation

/// The latest externally observable lifecycle state of a performance monitor.
public enum NearWirePerformanceMonitorState: Equatable, Sendable {
  case stopped
  case running
  case failed(NearWirePerformanceError)
}

final class NearWirePerformanceStateHub: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var continuations: [UUID: AsyncStream<NearWirePerformanceMonitorState>.Continuation] = [:]
  private var latest: NearWirePerformanceMonitorState
  private var isFinished = false

  init(initial: NearWirePerformanceMonitorState) {
    latest = initial
  }

  var subscriberCount: Int {
    lock.withLock { continuations.count }
  }

  func makeStream() -> AsyncStream<NearWirePerformanceMonitorState> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }

      let identifier = UUID()
      continuation.onTermination = { [weak self] _ in
        self?.remove(identifier)
      }

      lock.lock()
      let result = continuation.yield(latest)
      if isFinished || result.isTerminated {
        lock.unlock()
        continuation.finish()
        return
      }
      continuations[identifier] = continuation
      lock.unlock()
    }
  }

  func publish(_ state: NearWirePerformanceMonitorState) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }

    latest = state
    var terminated: [UUID] = []
    for (identifier, continuation) in continuations {
      if continuation.yield(state).isTerminated {
        terminated.append(identifier)
      }
    }
    for identifier in terminated {
      continuations.removeValue(forKey: identifier)
    }
    lock.unlock()
  }

  func finish() {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }

    isFinished = true
    let active = Array(continuations.values)
    continuations.removeAll(keepingCapacity: false)
    for continuation in active {
      continuation.finish()
    }
    lock.unlock()
  }

  private func remove(_ identifier: UUID) {
    _ = lock.withLock {
      continuations.removeValue(forKey: identifier)
    }
  }
}

extension AsyncStream<NearWirePerformanceMonitorState>.Continuation.YieldResult {
  fileprivate var isTerminated: Bool {
    if case .terminated = self { return true }
    return false
  }
}
