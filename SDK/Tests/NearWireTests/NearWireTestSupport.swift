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

let sdkTestSessionRoute = SDKSessionRoute(
  sessionEpoch: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
  viewerID: "viewer-one",
  appID: "app-one"
)

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
