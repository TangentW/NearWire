import Foundation

final class StateStreamHub: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var continuations: [UUID: AsyncStream<NearWireState>.Continuation] = [:]
  private var latest: NearWireState
  private var isFinished = false

  init(initial: NearWireState) {
    latest = initial
  }

  var subscriberCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return continuations.count
  }

  func makeStream() -> AsyncStream<NearWireState> {
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

  func publish(_ state: NearWireState) {
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

  func finish(with finalState: NearWireState) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    latest = finalState
    isFinished = true
    let active = Array(continuations.values)
    continuations.removeAll(keepingCapacity: false)
    for continuation in active {
      _ = continuation.yield(finalState)
      continuation.finish()
    }
    lock.unlock()
  }

  func finishWithoutChangingState() {
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
    lock.lock()
    continuations.removeValue(forKey: identifier)
    lock.unlock()
  }
}

final class EventStreamHub: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private let capacity: Int
  private var continuations: [UUID: AsyncThrowingStream<NearWireEvent, Error>.Continuation] = [:]
  private var isFinished = false

  init(capacity: Int) {
    self.capacity = capacity
  }

  var subscriberCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return continuations.count
  }

  func makeStream() -> AsyncThrowingStream<NearWireEvent, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(capacity)) { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      let identifier = UUID()
      continuation.onTermination = { [weak self] _ in
        self?.remove(identifier)
      }

      lock.lock()
      if isFinished {
        lock.unlock()
        continuation.finish()
        return
      }
      continuations[identifier] = continuation
      lock.unlock()
    }
  }

  func publish(_ event: NearWireEvent) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    var overflowed: [UUID] = []
    var terminated: [UUID] = []
    for (identifier, continuation) in continuations {
      switch continuation.yield(event) {
      case .enqueued:
        break
      case .dropped:
        overflowed.append(identifier)
      case .terminated:
        terminated.append(identifier)
      @unknown default:
        terminated.append(identifier)
      }
    }
    let overflowedContinuations = overflowed.compactMap {
      continuations.removeValue(forKey: $0)
    }
    for identifier in terminated {
      continuations.removeValue(forKey: identifier)
    }
    for continuation in overflowedContinuations {
      continuation.finish(throwing: NearWireError.streamOverflow)
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
    lock.lock()
    continuations.removeValue(forKey: identifier)
    lock.unlock()
  }
}

final class ConnectionStatusStreamHub: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var continuations: [UUID: AsyncStream<NearWireConnectionStatus>.Continuation] = [:]
  private var latest: NearWireConnectionStatus
  private var isFinished = false

  init(initial: NearWireConnectionStatus) {
    latest = initial
  }

  var subscriberCount: Int {
    lock.withLock { continuations.count }
  }

  func makeStream() -> AsyncStream<NearWireConnectionStatus> {
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

  func publish(_ status: NearWireConnectionStatus) {
    lock.lock()
    guard !isFinished, latest != status else {
      lock.unlock()
      return
    }
    latest = status
    var terminated: [UUID] = []
    for (identifier, continuation) in continuations {
      if continuation.yield(status).isTerminated {
        terminated.append(identifier)
      }
    }
    for identifier in terminated {
      continuations.removeValue(forKey: identifier)
    }
    lock.unlock()
  }

  func finish(with finalStatus: NearWireConnectionStatus) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    latest = finalStatus
    isFinished = true
    let active = Array(continuations.values)
    continuations.removeAll(keepingCapacity: false)
    for continuation in active {
      _ = continuation.yield(finalStatus)
      continuation.finish()
    }
    lock.unlock()
  }

  func finishWithoutChangingStatus() {
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
    _ = lock.withLock { continuations.removeValue(forKey: identifier) }
  }
}

extension AsyncStream<NearWireState>.Continuation.YieldResult {
  fileprivate var isTerminated: Bool {
    if case .terminated = self { return true }
    return false
  }
}

extension AsyncStream<NearWireConnectionStatus>.Continuation.YieldResult {
  fileprivate var isTerminated: Bool {
    if case .terminated = self { return true }
    return false
  }
}
