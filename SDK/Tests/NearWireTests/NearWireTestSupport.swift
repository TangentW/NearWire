import Foundation
@_spi(NearWireInternal) import NearWireCore
import XCTest

@testable import NearWire
@_spi(NearWireInternal) @testable import NearWireTransport

final class SDKTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var wallValue: Date
  private var monotonicValue: UInt64
  private var identifierValues: [UUID]

  init(
    wall: Date = Date(timeIntervalSince1970: 1_700_000_000),
    monotonic: UInt64 = 1_000_000_000,
    identifiers: [UUID] = [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!]
  ) {
    wallValue = wall
    monotonicValue = monotonic
    identifierValues = identifiers
  }

  var dependencies: SDKRuntimeDependencies {
    SDKRuntimeDependencies(
      wallClock: { [self] in readWall() },
      monotonicClock: { [self] in readMonotonic() },
      identifierGenerator: { [self] in nextIdentifier() }
    )
  }

  func advanceMonotonic(by nanoseconds: UInt64) {
    lock.lock()
    monotonicValue += nanoseconds
    lock.unlock()
  }

  func setMonotonic(_ value: UInt64) {
    lock.lock()
    monotonicValue = value
    lock.unlock()
  }

  func setWall(_ value: Date) {
    lock.lock()
    wallValue = value
    lock.unlock()
  }

  private func readWall() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return wallValue
  }

  private func readMonotonic() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return monotonicValue
  }

  private func nextIdentifier() -> UUID {
    lock.lock()
    defer { lock.unlock() }
    if !identifierValues.isEmpty {
      return identifierValues.removeFirst()
    }
    let suffix = String(format: "%012llx", monotonicValue & 0xFF_FFFF_FFFF)
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
  }
}

final class SDKLockedCapture<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Value] = []

  func append(_ value: Value) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  var snapshot: [Value] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

final class SDKSynchronousBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private var didReach = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func block() {
    lock.lock()
    didReach = true
    let continuations = waiters
    waiters.removeAll(keepingCapacity: false)
    lock.unlock()
    for continuation in continuations { continuation.resume() }
    releaseSemaphore.wait()
  }

  func waitUntilReached() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if didReach {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  func release() {
    releaseSemaphore.signal()
  }
}

final class SDKTargetSynchronousBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private let targetEntry: Int
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private var entryCount = 0
  private var didReachTarget = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(targetEntry: Int) {
    precondition(targetEntry > 0)
    self.targetEntry = targetEntry
  }

  func blockAtTarget() {
    let shouldBlock: Bool = lock.withLock {
      entryCount += 1
      guard entryCount == targetEntry else { return false }
      didReachTarget = true
      let current = waiters
      waiters.removeAll(keepingCapacity: false)
      for continuation in current { continuation.resume() }
      return true
    }
    if shouldBlock { releaseSemaphore.wait() }
  }

  func waitUntilReached() async {
    await withCheckedContinuation { continuation in
      let resumeImmediately: Bool = lock.withLock {
        if didReachTarget { return true }
        waiters.append(continuation)
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }

  func release() {
    releaseSemaphore.signal()
  }
}

let sdkTestSessionRoute = SDKSessionRoute(
  sessionEpoch: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
  viewerID: "viewer-one",
  appID: "app-one"
)

func makeSDKTestSessionCodec(maximumEventBytes: Int = 256 * 1_024) throws -> WireSessionCodec {
  let app = try WireHello(
    productVersion: WireProductVersion("1.0.0"),
    role: .app,
    installationID: EndpointID(rawValue: sdkTestSessionRoute.appID),
    maximumEventBytes: maximumEventBytes
  )
  let viewer = try WireHello(
    productVersion: WireProductVersion("1.0.0"),
    role: .viewer,
    installationID: EndpointID(rawValue: sdkTestSessionRoute.viewerID),
    maximumEventBytes: maximumEventBytes
  )
  return try WireSessionCodec(negotiation: WireNegotiator.negotiate(local: app, remote: viewer))
}

func makeSDKTestSequenceCounter(
  route: SDKSessionRoute = sdkTestSessionRoute
) throws -> WireSequenceCounter {
  WireSequenceCounter(
    sessionEpoch: try SessionEpoch(rawValue: route.sessionEpoch.uuidString.lowercased()),
    direction: .appToViewer
  )
}

func makeIncomingEnvelope(
  id: String = "10000000-0000-0000-0000-000000000001",
  sequence: UInt64 = 1,
  content: JSONValue = .object(["value": .integer(1)]),
  causality: EventCausality = EventCausality()
) throws -> EventEnvelope {
  try EventEnvelope(
    id: EventID(rawValue: id),
    type: .user("viewer.command"),
    content: content,
    createdAt: Date(timeIntervalSince1970: 1_700_000_001),
    monotonicTimestampNanoseconds: 2_000_000_000,
    source: EventEndpoint(
      role: .viewer,
      id: EndpointID(rawValue: "viewer-one")
    ),
    target: EventEndpoint(
      role: .app,
      id: EndpointID(rawValue: "app-one")
    ),
    direction: .viewerToApp,
    sessionEpoch: SessionEpoch(
      rawValue: "20000000-0000-0000-0000-000000000001"
    ),
    sequence: EventSequence(sequence),
    priority: .normal,
    ttl: .default,
    causality: causality
  )
}

func assertNearWireError(
  _ error: Error,
  code: NearWireError.Code,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  guard let sdkError = error as? NearWireError else {
    XCTFail("Expected NearWireError, received \(type(of: error)).", file: file, line: line)
    return
  }
  XCTAssertEqual(sdkError.code, code, file: file, line: line)
}

final class SDKSecureConnectionDriver: SecureConnectionDriving, @unchecked Sendable {
  private let lock = NSLock()
  private var stateHandler: (@Sendable (SecureDriverState) -> Void)?
  private var _sentData: [Data] = []

  func start(stateHandler: @escaping @Sendable (SecureDriverState) -> Void) {
    lock.lock()
    self.stateHandler = stateHandler
    lock.unlock()
  }

  func receive(
    maximumLength: Int,
    completion: @escaping @Sendable (Data?, Bool, Bool) -> Void
  ) {}

  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
    lock.lock()
    _sentData.append(data)
    lock.unlock()
  }

  func cancel() {}

  func emitState(_ state: SecureDriverState) {
    lock.lock()
    let handler = stateHandler
    lock.unlock()
    handler?(state)
  }

  var sentData: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return _sentData
  }
}

func sdkWaitUntil(
  timeoutNanoseconds: UInt64 = 1_000_000_000,
  condition: @escaping () -> Bool
) async {
  let start = DispatchTime.now().uptimeNanoseconds
  while !condition(), DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
    await Task.yield()
  }
}
