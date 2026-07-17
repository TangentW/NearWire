import Foundation
import XCTest

@testable import NearWire
@testable import NearWirePerformance
@testable import NearWireUI

final class NearWireUIFakeController: NearWireUIConnectionControlling, @unchecked Sendable {
  private struct State {
    var status = NearWireConnectionStatus(state: .idle)
    var statusContinuations: [UUID: AsyncStream<NearWireConnectionStatus>.Continuation] = [:]
    var connectCodes: [String] = []
    var connectContinuations: [CheckedContinuation<Void, Error>] = []
    var disconnectContinuations: [CheckedContinuation<Void, Never>] = []
    var connectCancellationCount = 0
    var connectCancellationObserver: (@Sendable () -> Void)?
  }

  private let lock = NSLock()
  private var state = State()

  var connectionStatuses: AsyncStream<NearWireConnectionStatus> {
    let identifier = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let initial = withState { state -> NearWireConnectionStatus in
        state.statusContinuations[identifier] = continuation
        return state.status
      }
      continuation.yield(initial)
      continuation.onTermination = { [weak self] _ in
        _ = self?.withState { $0.statusContinuations.removeValue(forKey: identifier) }
      }
    }
  }

  func connect(code: String) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        withState {
          $0.connectCodes.append(code)
          $0.connectContinuations.append(continuation)
        }
      }
    } onCancel: { [weak self] in
      let observer = self?.withState { state -> (@Sendable () -> Void)? in
        state.connectCancellationCount += 1
        return state.connectCancellationObserver
      }
      observer?()
    }
  }

  func disconnect() async {
    await withCheckedContinuation { continuation in
      withState { $0.disconnectContinuations.append(continuation) }
    }
  }

  func sendStatus(_ status: NearWireConnectionStatus) {
    let continuations = withState { state -> [AsyncStream<NearWireConnectionStatus>.Continuation] in
      state.status = status
      return Array(state.statusContinuations.values)
    }
    for continuation in continuations { continuation.yield(status) }
  }

  func finishNextConnect(
    with result: Result<Void, Error> = .success(()),
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let continuation = withState {
      $0.connectContinuations.isEmpty ? nil : $0.connectContinuations.removeFirst()
    }
    guard let continuation else {
      XCTFail("No pending Connect continuation is available.", file: file, line: line)
      return
    }
    continuation.resume(with: result)
  }

  func finishNextDisconnect(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let continuation = withState {
      $0.disconnectContinuations.isEmpty ? nil : $0.disconnectContinuations.removeFirst()
    }
    guard let continuation else {
      XCTFail("No pending Disconnect continuation is available.", file: file, line: line)
      return
    }
    continuation.resume()
  }

  var recordedConnectCodes: [String] { withState { $0.connectCodes } }
  var pendingConnectCount: Int { withState { $0.connectContinuations.count } }
  var pendingDisconnectCount: Int { withState { $0.disconnectContinuations.count } }
  var cancellationCount: Int { withState { $0.connectCancellationCount } }
  var statusSubscriberCount: Int { withState { $0.statusContinuations.count } }

  func setConnectCancellationObserver(_ observer: (@Sendable () -> Void)?) {
    withState { $0.connectCancellationObserver = observer }
  }

  private func withState<T>(_ body: (inout State) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&state)
  }
}

final class NearWireUIFakePerformanceController:
  NearWireUIPerformanceControlling, @unchecked Sendable
{
  private struct State {
    var current: NearWirePerformanceMonitorState = .stopped
    var continuations: [UUID: AsyncStream<NearWirePerformanceMonitorState>.Continuation] = [:]
    var startCalls = 0
    var stopCalls = 0
    var pendingStarts: [CheckedContinuation<Void, Error>] = []
    var startError: Error?
  }

  private let lock = NSLock()
  private var state = State()

  var states: AsyncStream<NearWirePerformanceMonitorState> {
    let identifier = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let initial = withState { state -> NearWirePerformanceMonitorState in
        state.continuations[identifier] = continuation
        return state.current
      }
      continuation.yield(initial)
      continuation.onTermination = { [weak self] _ in
        _ = self?.withState { $0.continuations.removeValue(forKey: identifier) }
      }
    }
  }

  func start() async throws {
    let error = withState { state -> Error? in
      state.startCalls += 1
      return state.startError
    }
    if let error { throw error }
    try await withCheckedThrowingContinuation { continuation in
      withState { $0.pendingStarts.append(continuation) }
    }
  }

  func stop() async {
    withState { $0.stopCalls += 1 }
    sendState(.stopped)
  }

  func finishNextStart(
    with result: Result<Void, Error> = .success(()),
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let continuation = withState {
      $0.pendingStarts.isEmpty ? nil : $0.pendingStarts.removeFirst()
    }
    guard let continuation else {
      XCTFail("No pending Performance start is available.", file: file, line: line)
      return
    }
    if case .success = result { sendState(.running) }
    continuation.resume(with: result)
  }

  func sendState(_ value: NearWirePerformanceMonitorState) {
    let continuations = withState {
      state -> [AsyncStream<NearWirePerformanceMonitorState>.Continuation] in
      state.current = value
      return Array(state.continuations.values)
    }
    for continuation in continuations { continuation.yield(value) }
  }

  func setStartError(_ error: Error?) {
    withState { $0.startError = error }
  }

  var startCallCount: Int { withState { $0.startCalls } }
  var stopCallCount: Int { withState { $0.stopCalls } }
  var pendingStartCount: Int { withState { $0.pendingStarts.count } }
  var subscriberCount: Int { withState { $0.continuations.count } }

  private func withState<T>(_ body: (inout State) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&state)
  }
}

final class NearWireUIFakeEventSource: NearWireUIEventProviding, @unchecked Sendable {
  private struct State {
    var continuations: [UUID: AsyncThrowingStream<NearWireEvent, Error>.Continuation] = [:]
  }

  private let lock = NSLock()
  private var state = State()

  var events: AsyncThrowingStream<NearWireEvent, Error> {
    let identifier = UUID()
    return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
      withState { $0.continuations[identifier] = continuation }
      continuation.onTermination = { [weak self] _ in
        _ = self?.withState { $0.continuations.removeValue(forKey: identifier) }
      }
    }
  }

  func send(_ event: NearWireEvent) {
    let continuations = withState { Array($0.continuations.values) }
    for continuation in continuations { continuation.yield(event) }
  }

  func finish(throwing error: Error? = nil) {
    let continuations = withState {
      state -> [AsyncThrowingStream<NearWireEvent, Error>.Continuation] in
      let values = Array(state.continuations.values)
      state.continuations.removeAll()
      return values
    }
    for continuation in continuations {
      if let error {
        continuation.finish(throwing: error)
      } else {
        continuation.finish()
      }
    }
  }

  var subscriberCount: Int { withState { $0.continuations.count } }

  private func withState<T>(_ body: (inout State) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&state)
  }
}

func makeNearWireUIEvent(
  type: String = "viewer.message",
  content: NearWireEventContent = .object(["message": .string("Hello")]),
  direction: NearWireEventDirection = .viewerToApp
) -> NearWireEvent {
  NearWireEvent(
    id: UUID(),
    type: type,
    content: content,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    priority: .normal,
    direction: direction
  )
}

enum NearWireUITestWait {
  @MainActor
  static func until(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @escaping () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
      await Task.yield()
    }
    XCTAssertTrue(predicate(), "Timed out waiting for condition.", file: file, line: line)
  }
}

final class NearWireUIBlockingDeliveryHook: @unchecked Sendable {
  private let lock = NSLock()
  private let blockedPhase: NearWireUIOperationPhase
  private let release = DispatchSemaphore(value: 0)
  private var hasBlocked = false

  init(blockedPhase: NearWireUIOperationPhase) {
    self.blockedPhase = blockedPhase
  }

  func callAsFunction(_ phase: NearWireUIOperationPhase) {
    let shouldBlock = withLock { () -> Bool in
      guard phase == blockedPhase, !hasBlocked else { return false }
      hasBlocked = true
      return true
    }
    guard shouldBlock else { return }
    _ = release.wait(timeout: .now() + 2)
  }

  var didReachBlockedPhase: Bool { withLock { hasBlocked } }

  func resume() {
    release.signal()
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
