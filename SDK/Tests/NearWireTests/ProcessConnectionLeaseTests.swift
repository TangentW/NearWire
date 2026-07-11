import Foundation
import ObjectiveC
import XCTest

@testable import NearWire

private final class ProcessLeaseTestGate: @unchecked Sendable {
  static let shared = ProcessLeaseTestGate()

  private let lock = NSLock()

  func run(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> Void
  ) throws {
    lock.lock()
    defer { lock.unlock() }

    let initial = try ProcessConnectionLeaseRegistry.claim()
    initial.release()
    defer {
      do {
        let final = try ProcessConnectionLeaseRegistry.claim()
        final.release()
      } catch {
        XCTFail(
          "The process lease was not claimable after the test: \(error)", file: file, line: line)
      }
    }
    try body()
  }
}

private final class ProcessLeaseRuntimeProbe: ProcessConnectionLeaseRuntimeOperations,
  @unchecked Sendable
{
  struct Snapshot: Equatable {
    let enters: Int
    let exits: Int
    let reads: Int
    let writes: Int
  }

  private let lock = NSLock()
  private let failEnter: Bool
  private let failExit: Bool
  private var enters = 0
  private var exits = 0
  private var reads = 0
  private var writes = 0
  private weak var firstWrittenObject: AnyObject?

  init(failEnter: Bool = false, failExit: Bool = false) {
    self.failEnter = failEnter
    self.failExit = failExit
  }

  func enter(_ object: AnyObject) -> Int32 {
    lock.lock()
    enters += 1
    lock.unlock()
    if failEnter {
      return -1
    }
    return objc_sync_enter(object)
  }

  func exit(_ object: AnyObject) -> Int32 {
    let actualStatus = objc_sync_exit(object)
    lock.lock()
    exits += 1
    lock.unlock()
    if failExit {
      return -1
    }
    return actualStatus
  }

  func associatedObject(_ object: AnyObject, key: UnsafeRawPointer) -> Any? {
    lock.lock()
    reads += 1
    lock.unlock()
    return objc_getAssociatedObject(object, key)
  }

  func setAssociatedObject(_ object: AnyObject, key: UnsafeRawPointer, value: AnyObject?) {
    lock.lock()
    writes += 1
    if firstWrittenObject == nil, let value {
      firstWrittenObject = value
    }
    lock.unlock()
    objc_setAssociatedObject(object, key, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }

  var snapshot: Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(enters: enters, exits: exits, reads: reads, writes: writes)
  }

  var firstWrittenObjectSnapshot: AnyObject? {
    lock.lock()
    defer { lock.unlock() }
    return firstWrittenObject
  }
}

private final class ProcessLeaseCallerData {}

private final class ProcessLeaseOutcomeCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var storedHandles: [ProcessConnectionLeaseHandle] = []
  private var storedErrors: [ProcessConnectionLeaseError.Code] = []

  func record(_ result: Result<ProcessConnectionLeaseHandle, Error>) {
    lock.lock()
    defer { lock.unlock() }
    switch result {
    case .success(let handle):
      storedHandles.append(handle)
    case .failure(let error):
      if let leaseError = error as? ProcessConnectionLeaseError {
        storedErrors.append(leaseError.code)
      }
    }
  }

  var handles: [ProcessConnectionLeaseHandle] {
    lock.lock()
    defer { lock.unlock() }
    return storedHandles
  }

  var errors: [ProcessConnectionLeaseError.Code] {
    lock.lock()
    defer { lock.unlock() }
    return storedErrors
  }
}

final class ProcessConnectionLeaseTests: XCTestCase {
  func testPermanentNamespacesAndBootstrapReuseOnePrivateMonitor() throws {
    try ProcessLeaseTestGate.shared.run {
      XCTAssertEqual(
        ProcessConnectionLeaseNamespace.monitorName,
        "com.nearwire.connection-lease.monitor"
      )
      XCTAssertEqual(
        ProcessConnectionLeaseNamespace.ownerName,
        "com.nearwire.connection-lease.owner"
      )
      let anchor = NSObject()
      let runtime = AppleProcessConnectionLeaseRuntime()
      let first = ProcessConnectionLeaseOperation.resolveRuntimeReference(
        anchor: anchor,
        runtime: runtime
      )
      let second = ProcessConnectionLeaseOperation.resolveRuntimeReference(
        anchor: anchor,
        runtime: runtime
      )
      XCTAssertNotNil(first.monitor)
      XCTAssertTrue(first.monitor === second.monitor)
      XCTAssertFalse(first.monitor === anchor)
    }
  }

  func testSequentialClaimContentionReleaseAndReacquisition() throws {
    try ProcessLeaseTestGate.shared.run {
      let first = try ProcessConnectionLeaseRegistry.claim()
      assertClaimError(.anotherConnectionIsActive)
      assertClaimError(.anotherConnectionIsActive)

      first.release()
      first.release()

      let second = try ProcessConnectionLeaseRegistry.claim()
      second.release()
    }
  }

  func testStaleHandleCannotClearNewerOwner() throws {
    try ProcessLeaseTestGate.shared.run {
      let stale = try ProcessConnectionLeaseRegistry.claim()
      stale.release()

      let current = try ProcessConnectionLeaseRegistry.claim()
      stale.release()
      assertClaimError(.anotherConnectionIsActive)
      current.release()
    }
  }

  func testDeinitializationReleasesTheCurrentToken() throws {
    try ProcessLeaseTestGate.shared.run {
      weak var weakHandle: ProcessConnectionLeaseHandle?
      do {
        let handle = try ProcessConnectionLeaseRegistry.claim()
        weakHandle = handle
      }
      XCTAssertNil(weakHandle)

      let later = try ProcessConnectionLeaseRegistry.claim()
      later.release()
    }
  }

  func testEmptyAndStaleFixtureReleaseAreNoOps() throws {
    try ProcessLeaseTestGate.shared.run {
      let runtime = AppleProcessConnectionLeaseRuntime()
      let monitor = NSObject()
      let stale = NSObject()

      ProcessConnectionLeaseOperation.release(
        monitor: monitor,
        token: stale,
        runtime: runtime
      )
      XCTAssertNil(objc_getAssociatedObject(monitor, ProcessConnectionLeaseNamespace.ownerKey))

      let current = NSObject()
      objc_setAssociatedObject(
        monitor,
        ProcessConnectionLeaseNamespace.ownerKey,
        current,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
      ProcessConnectionLeaseOperation.release(
        monitor: monitor,
        token: stale,
        runtime: runtime
      )
      XCTAssertTrue(
        objc_getAssociatedObject(monitor, ProcessConnectionLeaseNamespace.ownerKey)
          as AnyObject? === current
      )
    }
  }

  func testConcurrentFirstClaimsHaveExactlyOneRetainedWinner() throws {
    try ProcessLeaseTestGate.shared.run {
      let count = 32
      let start = DispatchSemaphore(value: 0)
      let group = DispatchGroup()
      let capture = ProcessLeaseOutcomeCapture()

      for _ in 0..<count {
        group.enter()
        DispatchQueue.global().async {
          start.wait()
          capture.record(Result { try ProcessConnectionLeaseRegistry.claim() })
          group.leave()
        }
      }
      for _ in 0..<count {
        start.signal()
      }

      guard waitForCompletion(group) else { return }
      XCTAssertEqual(capture.handles.count, 1)
      XCTAssertEqual(capture.errors.count, count - 1)
      XCTAssertTrue(capture.errors.allSatisfy { $0 == .anotherConnectionIsActive })
      for handle in capture.handles {
        handle.release()
      }
    }
  }

  func testClaimReleaseRaceHasAConsistentRetainedWinnerOracle() throws {
    try ProcessLeaseTestGate.shared.run {
      let initial = try ProcessConnectionLeaseRegistry.claim()
      let claimantCount = 31
      let start = DispatchSemaphore(value: 0)
      let group = DispatchGroup()
      let capture = ProcessLeaseOutcomeCapture()

      group.enter()
      DispatchQueue.global().async {
        start.wait()
        initial.release()
        group.leave()
      }
      for _ in 0..<claimantCount {
        group.enter()
        DispatchQueue.global().async {
          start.wait()
          capture.record(Result { try ProcessConnectionLeaseRegistry.claim() })
          group.leave()
        }
      }
      for _ in 0...claimantCount {
        start.signal()
      }

      guard waitForCompletion(group) else { return }
      XCTAssertLessThanOrEqual(capture.handles.count, 1)
      XCTAssertEqual(capture.handles.count + capture.errors.count, claimantCount)
      XCTAssertTrue(capture.errors.allSatisfy { $0 == .anotherConnectionIsActive })

      if let winner = capture.handles.first {
        assertClaimError(.anotherConnectionIsActive)
        winner.release()
      } else {
        let probe = try ProcessConnectionLeaseRegistry.claim()
        probe.release()
      }

      let final = try ProcessConnectionLeaseRegistry.claim()
      final.release()
    }
  }

  func testConcurrentRepeatedReleasePermitsOneLaterClaim() throws {
    try ProcessLeaseTestGate.shared.run {
      let handle = try ProcessConnectionLeaseRegistry.claim()
      let count = 32
      let start = DispatchSemaphore(value: 0)
      let group = DispatchGroup()

      for _ in 0..<count {
        group.enter()
        DispatchQueue.global().async {
          start.wait()
          handle.release()
          group.leave()
        }
      }
      for _ in 0..<count {
        start.signal()
      }

      guard waitForCompletion(group) else { return }
      let later = try ProcessConnectionLeaseRegistry.claim()
      later.release()
    }
  }

  func testConcurrentStaleReleaseCannotClearCurrentOwner() throws {
    try ProcessLeaseTestGate.shared.run {
      let stale = try ProcessConnectionLeaseRegistry.claim()
      stale.release()
      let current = try ProcessConnectionLeaseRegistry.claim()

      let count = 32
      let start = DispatchSemaphore(value: 0)
      let group = DispatchGroup()
      for _ in 0..<count {
        group.enter()
        DispatchQueue.global().async {
          start.wait()
          stale.release()
          group.leave()
        }
      }
      for _ in 0..<count {
        start.signal()
      }

      guard waitForCompletion(group) else { return }
      assertClaimError(.anotherConnectionIsActive)
      current.release()
    }
  }

  func testBootstrapEnterFailureDoesNotAccessTheAssociation() throws {
    try ProcessLeaseTestGate.shared.run {
      let runtime = ProcessLeaseRuntimeProbe(failEnter: true)
      let reference = ProcessConnectionLeaseOperation.resolveRuntimeReference(
        anchor: NSObject(),
        runtime: runtime
      )
      XCTAssertNil(reference.monitor)
      XCTAssertEqual(runtime.snapshot, .init(enters: 1, exits: 0, reads: 0, writes: 0))
      assertOperationClaimError(.runtimeUnavailable, reference: reference, runtime: runtime)
    }
  }

  func testBootstrapExitFailureLeavesInstalledAssociationWithoutReturningMonitor() throws {
    try ProcessLeaseTestGate.shared.run {
      let anchor = NSObject()
      let runtime = ProcessLeaseRuntimeProbe(failExit: true)
      let reference = ProcessConnectionLeaseOperation.resolveRuntimeReference(
        anchor: anchor,
        runtime: runtime
      )
      XCTAssertNil(reference.monitor)
      XCTAssertNotNil(
        objc_getAssociatedObject(anchor, ProcessConnectionLeaseNamespace.monitorKey)
      )
      XCTAssertEqual(runtime.snapshot, .init(enters: 1, exits: 1, reads: 1, writes: 1))
    }
  }

  func testClaimEnterFailureDoesNotAccessTheOwnerSlot() throws {
    try ProcessLeaseTestGate.shared.run {
      let monitor = NSObject()
      let reference = ProcessConnectionLeaseRuntimeReference(monitor: monitor)
      let runtime = ProcessLeaseRuntimeProbe(failEnter: true)
      assertOperationClaimError(.runtimeUnavailable, reference: reference, runtime: runtime)
      XCTAssertEqual(runtime.snapshot, .init(enters: 1, exits: 0, reads: 0, writes: 0))
      XCTAssertNil(objc_getAssociatedObject(monitor, ProcessConnectionLeaseNamespace.ownerKey))
    }
  }

  func testClaimExitFailureAfterStoreReturnsNoHandle() throws {
    try ProcessLeaseTestGate.shared.run {
      let monitor = NSObject()
      let reference = ProcessConnectionLeaseRuntimeReference(monitor: monitor)
      let runtime = ProcessLeaseRuntimeProbe(failExit: true)
      assertOperationClaimError(.runtimeUnavailable, reference: reference, runtime: runtime)
      XCTAssertNotNil(objc_getAssociatedObject(monitor, ProcessConnectionLeaseNamespace.ownerKey))
      XCTAssertEqual(runtime.snapshot, .init(enters: 1, exits: 1, reads: 1, writes: 1))
    }
  }

  func testClaimExitFailureTakesPrecedenceOverOccupiedSlot() throws {
    try ProcessLeaseTestGate.shared.run {
      let monitor = NSObject()
      let owner = NSObject()
      objc_setAssociatedObject(
        monitor,
        ProcessConnectionLeaseNamespace.ownerKey,
        owner,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
      let reference = ProcessConnectionLeaseRuntimeReference(monitor: monitor)
      let runtime = ProcessLeaseRuntimeProbe(failExit: true)

      assertOperationClaimError(.runtimeUnavailable, reference: reference, runtime: runtime)
      XCTAssertTrue(
        objc_getAssociatedObject(monitor, ProcessConnectionLeaseNamespace.ownerKey)
          as AnyObject? === owner
      )
      XCTAssertEqual(runtime.snapshot, .init(enters: 1, exits: 1, reads: 1, writes: 0))
    }
  }

  func testReleaseEnterFailureLeavesOwnerUntouched() throws {
    try ProcessLeaseTestGate.shared.run {
      let monitor = NSObject()
      let token = NSObject()
      objc_setAssociatedObject(
        monitor,
        ProcessConnectionLeaseNamespace.ownerKey,
        token,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
      let runtime = ProcessLeaseRuntimeProbe(failEnter: true)

      ProcessConnectionLeaseOperation.release(
        monitor: monitor,
        token: token,
        runtime: runtime
      )
      XCTAssertTrue(
        objc_getAssociatedObject(monitor, ProcessConnectionLeaseNamespace.ownerKey)
          as AnyObject? === token
      )
      XCTAssertEqual(runtime.snapshot, .init(enters: 1, exits: 0, reads: 0, writes: 0))
    }
  }

  func testReleaseExitFailureMayFollowExactTokenClear() throws {
    try ProcessLeaseTestGate.shared.run {
      let monitor = NSObject()
      let token = NSObject()
      objc_setAssociatedObject(
        monitor,
        ProcessConnectionLeaseNamespace.ownerKey,
        token,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
      let runtime = ProcessLeaseRuntimeProbe(failExit: true)

      ProcessConnectionLeaseOperation.release(
        monitor: monitor,
        token: token,
        runtime: runtime
      )
      XCTAssertNil(objc_getAssociatedObject(monitor, ProcessConnectionLeaseNamespace.ownerKey))
      XCTAssertEqual(runtime.snapshot, .init(enters: 1, exits: 1, reads: 1, writes: 1))
    }
  }

  func testHandleAndErrorsHaveFixedContentSafeDiagnostics() throws {
    try ProcessLeaseTestGate.shared.run {
      let handle = try ProcessConnectionLeaseRegistry.claim()
      defer { handle.release() }

      XCTAssertEqual(String(describing: handle), "NearWire connection lease")
      XCTAssertEqual(String(reflecting: handle), "NearWire connection lease")
      XCTAssertEqual(handle.debugDescription, "NearWire connection lease")
      XCTAssertEqual("\(handle)", "NearWire connection lease")
      XCTAssertEqual(
        Mirror(reflecting: handle).children.map(\.label),
        ["description"]
      )

      let contention = ProcessConnectionLeaseError.anotherConnectionIsActive
      let unavailable = ProcessConnectionLeaseError.runtimeUnavailable
      XCTAssertEqual(
        String(describing: contention),
        "anotherConnectionIsActive: Another NearWire connection is already active."
      )
      XCTAssertEqual(String(reflecting: contention), String(describing: contention))
      XCTAssertEqual(
        String(describing: unavailable),
        "runtimeUnavailable: NearWire connection ownership is unavailable."
      )

      for rendered in [
        String(describing: handle),
        String(reflecting: handle),
        String(describing: contention),
        String(reflecting: unavailable),
      ] {
        XCTAssertFalse(rendered.contains("0x"))
        XCTAssertFalse(rendered.contains(ProcessConnectionLeaseNamespace.monitorName))
        XCTAssertFalse(rendered.contains(ProcessConnectionLeaseNamespace.ownerName))
      }
    }
  }

  func testHandleAndRuntimeReferenceMeetSendableBoundary() throws {
    try ProcessLeaseTestGate.shared.run {
      requireSendable(ProcessConnectionLeaseHandle.self)
      requireSendable(ProcessConnectionLeaseRuntimeReference.self)
    }
  }

  func testHandleRetainsOnlyItsTokenAndDoesNotRetainCallerData() throws {
    try ProcessLeaseTestGate.shared.run {
      var caller: ProcessLeaseCallerData? = ProcessLeaseCallerData()
      weak let weakCaller = caller
      let processHandle = try claimFromCaller(caller!)
      caller = nil
      XCTAssertNil(weakCaller)
      processHandle.release()

      let monitor = NSObject()
      let reference = ProcessConnectionLeaseRuntimeReference(monitor: monitor)
      let runtime = ProcessLeaseRuntimeProbe()
      var fixtureHandle: ProcessConnectionLeaseHandle? = try ProcessConnectionLeaseOperation.claim(
        reference: reference,
        runtime: runtime
      )
      weak let weakToken = runtime.firstWrittenObjectSnapshot
      XCTAssertNotNil(weakToken)
      fixtureHandle?.release()
      XCTAssertNotNil(weakToken)
      fixtureHandle = nil
      XCTAssertNil(weakToken)
    }
  }

  func testIdleInstanceWorkAndShutdownCannotReleaseInternalOwner() throws {
    try ProcessLeaseTestGate.shared.run {
      let owner = try ProcessConnectionLeaseRegistry.claim()
      defer { owner.release() }
      let first = NearWire()
      let second = NearWire()
      let finished = DispatchSemaphore(value: 0)
      let results = SDKLockedCapture<Bool>()

      Task {
        do {
          _ = try await first.send(type: "test.first", content: ["value": 1])
          _ = try await second.send(type: "test.second", content: ["value": 2])
          let before = try await second.bufferDiagnostics()
          await first.shutdown()
          let after = try await second.bufferDiagnostics()
          results.append(before.eventCount == 1 && after.eventCount == 1)
        } catch {
          results.append(false)
        }
        finished.signal()
      }

      guard waitForCompletion(finished) else { return }
      XCTAssertEqual(results.snapshot, [true])
      assertClaimError(.anotherConnectionIsActive)
    }
  }

  private func assertClaimError(
    _ expectedCode: ProcessConnectionLeaseError.Code,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try ProcessConnectionLeaseRegistry.claim(), file: file, line: line) {
      error in
      XCTAssertEqual(
        (error as? ProcessConnectionLeaseError)?.code, expectedCode, file: file, line: line)
    }
  }

  private func assertOperationClaimError(
    _ expectedCode: ProcessConnectionLeaseError.Code,
    reference: ProcessConnectionLeaseRuntimeReference,
    runtime: any ProcessConnectionLeaseRuntimeOperations,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try ProcessConnectionLeaseOperation.claim(reference: reference, runtime: runtime),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        (error as? ProcessConnectionLeaseError)?.code, expectedCode, file: file, line: line)
    }
  }

  private func requireSendable<Value: Sendable>(_: Value.Type) {}

  private func waitForCompletion(
    _ group: DispatchGroup,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    guard group.wait(timeout: .now() + 5) == .success else {
      XCTFail("Concurrent lease work exceeded the test deadline.", file: file, line: line)
      group.wait()
      return false
    }
    return true
  }

  private func waitForCompletion(
    _ semaphore: DispatchSemaphore,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    guard semaphore.wait(timeout: .now() + 5) == .success else {
      XCTFail("Asynchronous lease work exceeded the test deadline.", file: file, line: line)
      semaphore.wait()
      return false
    }
    return true
  }

  private func claimFromCaller(
    _ caller: ProcessLeaseCallerData
  ) throws -> ProcessConnectionLeaseHandle {
    withExtendedLifetime(caller) {}
    return try ProcessConnectionLeaseRegistry.claim()
  }
}
