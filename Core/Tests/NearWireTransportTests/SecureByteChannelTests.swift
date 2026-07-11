import Foundation
import XCTest

@testable import NearWireTransport

final class SecureByteChannelTests: XCTestCase {
  func testStartIsSingleShotAndCancelBeforeReadyIsTerminal() async throws {
    let driver = FakeSecureConnectionDriver()
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(
      driver: driver,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    await assertTransportError(.alreadyStarted) {
      try await channel.start()
    }
    await channel.cancel()
    await fulfillment(of: [terminal], timeout: 1)

    let state = await channel.state
    XCTAssertEqual(state, .cancelled)
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testReadyStartsOneReceiveAndDeliversSequentialChunks() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let first = expectation(description: "first receive")
    let second = expectation(description: "second receive")
    let recorder = ChannelEventRecorder { event in
      switch event {
      case .stateChanged(.ready): ready.fulfill()
      case .received(let data) where data == Data("one".utf8): first.fulfill()
      case .received(let data) where data == Data("two".utf8): second.fulfill()
      default: break
      }
    }
    let limits = try SecureTransportLimits(receiveChunkBytes: 8)
    let channel = SecureByteChannel(
      driver: driver,
      limits: limits,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    XCTAssertEqual(driver.receiveMaximumLengths, [8])

    driver.completeNextReceive(data: Data("one".utf8), isComplete: false, failed: false)
    await fulfillment(of: [first], timeout: 1)
    XCTAssertEqual(driver.receiveMaximumLengths, [8, 8])

    driver.completeNextReceive(data: Data("two".utf8), isComplete: false, failed: false)
    await fulfillment(of: [second], timeout: 1)
    XCTAssertEqual(driver.receiveMaximumLengths, [8, 8, 8])
    XCTAssertEqual(recorder.received, [Data("one".utf8), Data("two".utf8)])
  }

  func testSendsAreFIFOAndBackpressureIsAtomic() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let completed = expectation(description: "sends completed")
    completed.expectedFulfillmentCount = 2
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
      if case .sendCompleted = event { completed.fulfill() }
    }
    let limits = try SecureTransportLimits(
      maximumPendingSendCount: 2,
      maximumPendingSendBytes: 5,
      maximumSingleSendBytes: 3
    )
    let channel = SecureByteChannel(
      driver: driver,
      limits: limits,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    try await channel.send(Data("one".utf8))
    try await channel.send(Data("22".utf8))
    await assertTransportError(.backpressure) {
      try await channel.send(Data("x".utf8))
    }

    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    XCTAssertEqual(driver.sentData, [Data("one".utf8)])
    driver.completeNextSend(failed: false)
    await waitUntil { driver.sentData.count == 2 }
    XCTAssertEqual(driver.sentData, [Data("one".utf8), Data("22".utf8)])
    driver.completeNextSend(failed: false)
    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(recorder.completedByteCounts, [3, 2])
  }

  func testOversizedReceiveFailsOnceAndDoesNotReceiveAgain() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
      if case .terminated = event { terminal.fulfill() }
    }
    let limits = try SecureTransportLimits(receiveChunkBytes: 4)
    let channel = SecureByteChannel(
      driver: driver,
      limits: limits,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    driver.completeNextReceive(data: Data(repeating: 1, count: 5), isComplete: false, failed: false)
    await fulfillment(of: [terminal], timeout: 1)

    let failedState = await channel.state
    XCTAssertEqual(failedState, .failed)
    XCTAssertEqual(recorder.terminalCodes, [.invalidDelivery])
    XCTAssertEqual(driver.receiveMaximumLengths, [4])
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testCancellationIsIdempotentAndLateCallbacksAreIgnored() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(
      driver: driver,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    await channel.cancel()
    await channel.cancel()
    await fulfillment(of: [terminal], timeout: 1)

    driver.completeNextReceive(data: Data("late".utf8), isComplete: false, failed: false)
    driver.emitState(.failed)
    await Task.yield()
    await Task.yield()

    let cancelledState = await channel.state
    XCTAssertEqual(cancelledState, .cancelled)
    XCTAssertEqual(driver.cancelCount, 1)
    XCTAssertTrue(recorder.received.isEmpty)
    XCTAssertEqual(recorder.terminalCodes, [.cancelled])
  }

  func testSendFailureClearsQueueWithoutRetry() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(
      driver: driver,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    try await channel.send(Data("first".utf8))
    try await channel.send(Data("second".utf8))
    driver.completeNextSend(failed: true)
    await fulfillment(of: [terminal], timeout: 1)

    XCTAssertEqual(driver.sentData, [Data("first".utf8)])
    XCTAssertEqual(driver.cancelCount, 1)
    XCTAssertEqual(recorder.terminalCodes, [.driverFailure])
  }

  func testEmptyNonterminalReceiveFailsWithoutRequestingAgain() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(
      driver: driver,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    driver.completeNextReceive(data: nil, isComplete: false, failed: false)
    await fulfillment(of: [terminal], timeout: 1)

    XCTAssertEqual(recorder.terminalCodes, [.invalidDelivery])
    XCTAssertEqual(driver.receiveMaximumLengths.count, 1)
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testEOFDeliversFinalBytesThenTerminates() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let received = expectation(description: "received")
    let terminal = expectation(description: "terminal")
    let finalBytes = Data("final".utf8)
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
      if case .received(let data) = event, data == finalBytes { received.fulfill() }
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(
      driver: driver,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    driver.completeNextReceive(data: finalBytes, isComplete: true, failed: false)
    await fulfillment(of: [received, terminal], timeout: 1)

    XCTAssertEqual(recorder.received, [finalBytes])
    XCTAssertEqual(recorder.terminalCodes, [.endOfStream])
    XCTAssertEqual(driver.receiveMaximumLengths.count, 1)
  }

  func testDriverFailureIsTerminalAndLaterStateIsIgnored() async throws {
    let driver = FakeSecureConnectionDriver()
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(
      driver: driver,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    driver.emitState(.failed)
    await fulfillment(of: [terminal], timeout: 1)
    driver.emitState(.cancelled)
    driver.emitState(.ready)
    await Task.yield()
    await Task.yield()

    let state = await channel.state
    XCTAssertEqual(state, .failed)
    XCTAssertEqual(recorder.terminalCodes, [.driverFailure])
    XCTAssertEqual(driver.cancelCount, 1)
    XCTAssertTrue(driver.receiveMaximumLengths.isEmpty)
  }

  func testRepeatedPreparingAndReadyNotificationsDoNotDuplicateWork() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
    }
    let channel = SecureByteChannel(
      driver: driver,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    driver.emitState(.preparing)
    driver.emitState(.preparing)
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    driver.emitState(.preparing)
    driver.emitState(.ready)
    await Task.yield()
    await Task.yield()

    let state = await channel.state
    XCTAssertEqual(state, .ready)
    XCTAssertEqual(driver.receiveMaximumLengths.count, 1)
    XCTAssertTrue(recorder.terminalCodes.isEmpty)
  }

  func testSendAdmissionRejectsInvalidOperationsWithoutDriverWork() async throws {
    let driver = FakeSecureConnectionDriver()
    let limits = try SecureTransportLimits(maximumSingleSendBytes: 3)
    let channel = SecureByteChannel(driver: driver, limits: limits) { _ in }

    await assertTransportError(.invalidState) {
      try await channel.send(Data("one".utf8))
    }
    try await channel.start()
    await assertTransportError(.backpressure) {
      try await channel.send(Data())
    }
    await assertTransportError(.backpressure) {
      try await channel.send(Data("four".utf8))
    }

    XCTAssertTrue(driver.sentData.isEmpty)
  }

  func testSendByteAccountingRejectsOverflowAndBoundsAtomically() throws {
    XCTAssertEqual(
      try SecureSendAdmission.addedByteCount(current: 2, adding: 3, maximum: 5),
      5
    )
    XCTAssertThrowsError(
      try SecureSendAdmission.addedByteCount(current: Int.max, adding: 1, maximum: Int.max)
    ) { error in
      XCTAssertEqual((error as? SecureTransportError)?.code, .arithmeticOverflow)
    }
    XCTAssertThrowsError(
      try SecureSendAdmission.addedByteCount(current: 4, adding: 2, maximum: 5)
    ) { error in
      XCTAssertEqual((error as? SecureTransportError)?.code, .backpressure)
    }
  }

  func testConcurrentSendAdmissionRemainsBoundedAndSerial() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
    }
    let channel = SecureByteChannel(
      driver: driver,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for byte in UInt8(0)..<UInt8(32) {
        group.addTask {
          try await channel.send(Data([byte]))
        }
      }
      try await group.waitForAll()
    }

    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    for expectedCount in 1...32 {
      await waitUntil { driver.sentData.count == expectedCount }
      XCTAssertEqual(driver.sentData.count, expectedCount)
      driver.completeNextSend(failed: false)
    }
    await waitUntil { recorder.completedByteCounts.count == 32 }

    XCTAssertEqual(recorder.completedByteCounts.count, 32)
    XCTAssertEqual(Set(driver.sentData.compactMap(\.first)), Set(UInt8(0)..<UInt8(32)))
    XCTAssertTrue(recorder.terminalCodes.isEmpty)
    await channel.cancel()
  }

  func testSynchronousDriverCallbacksRemainSerialized() async throws {
    let driver = ImmediateSecureConnectionDriver()
    let received = expectation(description: "received")
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .received(let data) = event, data == Data("immediate".utf8) {
        received.fulfill()
      }
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(
      driver: driver,
      eventHandler: { event in recorder.record(event) }
    )

    try await channel.start()
    await fulfillment(of: [received, terminal], timeout: 1)

    let state = await channel.state
    XCTAssertEqual(state, .failed)
    XCTAssertEqual(recorder.received, [Data("immediate".utf8)])
    XCTAssertEqual(recorder.terminalCodes, [.endOfStream])
    XCTAssertEqual(driver.receiveCount, 2)
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testSuccessfulSendReleasesCompletedPayloadBeforeQueueCompaction() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let completed = expectation(description: "completed")
    let channel = SecureByteChannel(driver: driver) { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
      if case .sendCompleted = event { completed.fulfill() }
    }

    try await channel.start()
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)

    try await channel.send(Data(repeating: 1, count: 1_024))
    let retainedBeforeCompletion = await channel.retainedSendPayloadBytes
    XCTAssertEqual(retainedBeforeCompletion, 1_024)

    driver.completeNextSend(failed: false)
    await fulfillment(of: [completed], timeout: 1)

    let retainedAfterCompletion = await channel.retainedSendPayloadBytes
    XCTAssertEqual(retainedAfterCompletion, 0)
    await channel.cancel()
  }

  func testDuplicateOldReceiveCallbackCannotStartConcurrentReceive() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let first = expectation(description: "first")
    let second = expectation(description: "second")
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
      if case .received(let data) = event, data == Data("first".utf8) { first.fulfill() }
      if case .received(let data) = event, data == Data("second".utf8) { second.fulfill() }
    }
    let channel = SecureByteChannel(driver: driver) { event in recorder.record(event) }

    try await channel.start()
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    driver.completeNextReceive(data: Data("first".utf8), isComplete: false, failed: false)
    await fulfillment(of: [first], timeout: 1)
    XCTAssertEqual(driver.receiveMaximumLengths.count, 2)

    driver.replayLastReceive(data: Data("duplicate".utf8), isComplete: false, failed: false)
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(driver.receiveMaximumLengths.count, 2)
    XCTAssertEqual(recorder.received, [Data("first".utf8)])

    driver.completeNextReceive(data: Data("second".utf8), isComplete: false, failed: false)
    await fulfillment(of: [second], timeout: 1)
    XCTAssertEqual(driver.receiveMaximumLengths.count, 3)
    XCTAssertEqual(recorder.received, [Data("first".utf8), Data("second".utf8)])
    await channel.cancel()
  }

  func testReceiveFailureTerminatesWithoutRetry() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(driver: driver) { event in recorder.record(event) }

    try await channel.start()
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    driver.completeNextReceive(data: nil, isComplete: false, failed: true)
    await fulfillment(of: [terminal], timeout: 1)

    XCTAssertEqual(recorder.terminalCodes, [.driverFailure])
    XCTAssertEqual(driver.receiveMaximumLengths.count, 1)
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testLateSendCallbacksAfterCancellationAreIgnored() async throws {
    let driver = FakeSecureConnectionDriver()
    let ready = expectation(description: "ready")
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .stateChanged(.ready) = event { ready.fulfill() }
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(driver: driver) { event in recorder.record(event) }

    try await channel.start()
    driver.emitState(.ready)
    await fulfillment(of: [ready], timeout: 1)
    try await channel.send(Data("pending".utf8))
    await channel.cancel()
    await fulfillment(of: [terminal], timeout: 1)

    driver.completeNextSend(failed: false)
    driver.replayLastSend(failed: true)
    await Task.yield()
    await Task.yield()

    XCTAssertTrue(recorder.completedByteCounts.isEmpty)
    XCTAssertEqual(recorder.terminalCodes, [.cancelled])
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testDriverCancellationProducesOneTerminalOutcome() async throws {
    let driver = FakeSecureConnectionDriver()
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(driver: driver) { event in recorder.record(event) }

    try await channel.start()
    driver.emitState(.cancelled)
    await fulfillment(of: [terminal], timeout: 1)
    driver.emitState(.cancelled)
    await Task.yield()

    let state = await channel.state
    XCTAssertEqual(state, .cancelled)
    XCTAssertEqual(recorder.terminalCodes, [.cancelled])
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testSynchronousStateCallbacksPreserveDriverOrder() async throws {
    let driver = SynchronousStateSequenceDriver(states: [.ready, .failed])
    let terminal = expectation(description: "terminal")
    let recorder = ChannelEventRecorder { event in
      if case .terminated = event { terminal.fulfill() }
    }
    let channel = SecureByteChannel(driver: driver) { event in recorder.record(event) }

    try await channel.start()
    await fulfillment(of: [terminal], timeout: 1)

    XCTAssertEqual(recorder.states, [.preparing, .ready, .failed])
    XCTAssertEqual(recorder.terminalCodes, [.driverFailure])
    XCTAssertEqual(driver.receiveCount, 1)
  }

  func testExactDefaultAndHardWireFramesAreAdmittedAsSingleSends() async throws {
    try await assertExactFrameIsAdmitted(
      payloadBytes: WireFrameLimits.default.maximumEventPayloadBytes,
      frameLimits: .default,
      transportLimits: .default
    )

    let hardFrameLimits = try WireFrameLimits(
      maximumControlPayloadBytes: WireFrameLimits.hardMaximumPayloadBytes,
      maximumEventPayloadBytes: WireFrameLimits.hardMaximumPayloadBytes
    )
    let hardTransportLimits = try SecureTransportLimits(
      maximumPendingSendBytes: SecureTransportLimits.hardMaximumPendingSendBytes,
      maximumSingleSendBytes: SecureTransportLimits.hardMaximumSingleSendBytes
    )
    try await assertExactFrameIsAdmitted(
      payloadBytes: WireFrameLimits.hardMaximumPayloadBytes,
      frameLimits: hardFrameLimits,
      transportLimits: hardTransportLimits
    )
  }

  private func assertTransportError(
    _ code: SecureTransportError.Code,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected SecureTransportError.")
    } catch let error as SecureTransportError {
      XCTAssertEqual(error.code, code)
    } catch {
      XCTFail("Expected SecureTransportError, received \(error).")
    }
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping () -> Bool
  ) async {
    let start = DispatchTime.now().uptimeNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
      await Task.yield()
    }
  }

  private func assertExactFrameIsAdmitted(
    payloadBytes: Int,
    frameLimits: WireFrameLimits,
    transportLimits: SecureTransportLimits
  ) async throws {
    let frame = try WireFrameEncoder.encode(
      lane: .event,
      payload: Data(repeating: 1, count: payloadBytes),
      limits: frameLimits
    )
    let driver = FakeSecureConnectionDriver()
    let channel = SecureByteChannel(driver: driver, limits: transportLimits) { _ in }

    try await channel.start()
    try await channel.send(frame)
    driver.emitState(.ready)
    await waitUntil { driver.sentData.count == 1 }

    XCTAssertEqual(driver.sentData.first?.count, payloadBytes + 5)
    await channel.cancel()
  }
}

private final class ChannelEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private let observer: @Sendable (SecureByteChannelEvent) -> Void
  private var events: [SecureByteChannelEvent] = []

  init(observer: @escaping @Sendable (SecureByteChannelEvent) -> Void) {
    self.observer = observer
  }

  func record(_ event: SecureByteChannelEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
    observer(event)
  }

  var received: [Data] {
    snapshot().compactMap { event in
      guard case .received(let data) = event else { return nil }
      return data
    }
  }

  var completedByteCounts: [Int] {
    snapshot().compactMap { event in
      guard case .sendCompleted(let count) = event else { return nil }
      return count
    }
  }

  var terminalCodes: [SecureTransportError.Code] {
    snapshot().compactMap { event in
      guard case .terminated(let error) = event else { return nil }
      return error.code
    }
  }

  var states: [SecureTransportState] {
    snapshot().compactMap { event in
      guard case .stateChanged(let state) = event else { return nil }
      return state
    }
  }

  private func snapshot() -> [SecureByteChannelEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}

private final class FakeSecureConnectionDriver: SecureConnectionDriving, @unchecked Sendable {
  private let lock = NSLock()
  private var stateHandler: (@Sendable (SecureDriverState) -> Void)?
  private var receiveCompletions: [@Sendable (Data?, Bool, Bool) -> Void] = []
  private var sendCompletions: [@Sendable (Bool) -> Void] = []
  private var lastReceiveCompletion: (@Sendable (Data?, Bool, Bool) -> Void)?
  private var lastSendCompletion: (@Sendable (Bool) -> Void)?
  private var _receiveMaximumLengths: [Int] = []
  private var _sentData: [Data] = []
  private var _cancelCount = 0

  func start(stateHandler: @escaping @Sendable (SecureDriverState) -> Void) {
    lock.lock()
    self.stateHandler = stateHandler
    lock.unlock()
  }

  func receive(
    maximumLength: Int,
    completion: @escaping @Sendable (Data?, Bool, Bool) -> Void
  ) {
    lock.lock()
    _receiveMaximumLengths.append(maximumLength)
    receiveCompletions.append(completion)
    lock.unlock()
  }

  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
    lock.lock()
    _sentData.append(data)
    sendCompletions.append(completion)
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    _cancelCount += 1
    lock.unlock()
  }

  func emitState(_ state: SecureDriverState) {
    lock.lock()
    let callback = stateHandler
    lock.unlock()
    callback?(state)
  }

  func completeNextReceive(data: Data?, isComplete: Bool, failed: Bool) {
    lock.lock()
    let callback = receiveCompletions.removeFirst()
    lastReceiveCompletion = callback
    lock.unlock()
    callback(data, isComplete, failed)
  }

  func replayLastReceive(data: Data?, isComplete: Bool, failed: Bool) {
    lock.lock()
    let callback = lastReceiveCompletion
    lock.unlock()
    callback?(data, isComplete, failed)
  }

  func completeNextSend(failed: Bool) {
    lock.lock()
    let callback = sendCompletions.removeFirst()
    lastSendCompletion = callback
    lock.unlock()
    callback(failed)
  }

  func replayLastSend(failed: Bool) {
    lock.lock()
    let callback = lastSendCompletion
    lock.unlock()
    callback?(failed)
  }

  var receiveMaximumLengths: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return _receiveMaximumLengths
  }

  var sentData: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return _sentData
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _cancelCount
  }
}

private final class SynchronousStateSequenceDriver: SecureConnectionDriving, @unchecked Sendable {
  private let lock = NSLock()
  private let states: [SecureDriverState]
  private var _receiveCount = 0

  init(states: [SecureDriverState]) {
    self.states = states
  }

  func start(stateHandler: @escaping @Sendable (SecureDriverState) -> Void) {
    for state in states {
      stateHandler(state)
    }
  }

  func receive(
    maximumLength: Int,
    completion: @escaping @Sendable (Data?, Bool, Bool) -> Void
  ) {
    lock.lock()
    _receiveCount += 1
    lock.unlock()
  }

  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {}

  func cancel() {}

  var receiveCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _receiveCount
  }
}

private final class ImmediateSecureConnectionDriver: SecureConnectionDriving, @unchecked Sendable {
  private let lock = NSLock()
  private var _receiveCount = 0
  private var _cancelCount = 0

  func start(stateHandler: @escaping @Sendable (SecureDriverState) -> Void) {
    stateHandler(.preparing)
    stateHandler(.ready)
  }

  func receive(
    maximumLength: Int,
    completion: @escaping @Sendable (Data?, Bool, Bool) -> Void
  ) {
    lock.lock()
    _receiveCount += 1
    let count = _receiveCount
    lock.unlock()
    if count == 1 {
      completion(Data("immediate".utf8), false, false)
    } else {
      completion(nil, true, false)
    }
  }

  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
    completion(false)
  }

  func cancel() {
    lock.lock()
    _cancelCount += 1
    lock.unlock()
  }

  var receiveCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _receiveCount
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _cancelCount
  }
}
