import XCTest

@testable import NearWire

final class NearWireStreamLifecycleTests: XCTestCase {
  func testStateSubscribersReceiveCurrentAndTerminalState() async throws {
    let nearWire = NearWire()
    var first = nearWire.states.makeAsyncIterator()
    let initial = await first.next()
    XCTAssertEqual(initial, .idle)

    await nearWire.updateSessionState(.connecting)
    let connecting = await first.next()
    XCTAssertEqual(connecting, .connecting)

    var late = nearWire.states.makeAsyncIterator()
    let lateInitial = await late.next()
    XCTAssertEqual(lateInitial, .connecting)

    await nearWire.shutdown()
    let firstShutdown = await first.next()
    let firstFinished = await first.next()
    let lateShutdown = await late.next()
    let lateFinished = await late.next()
    XCTAssertEqual(firstShutdown, .shutdown)
    XCTAssertNil(firstFinished)
    XCTAssertEqual(lateShutdown, .shutdown)
    XCTAssertNil(lateFinished)

    var afterShutdown = nearWire.states.makeAsyncIterator()
    let terminalInitial = await afterShutdown.next()
    let terminalFinished = await afterShutdown.next()
    XCTAssertEqual(terminalInitial, .shutdown)
    XCTAssertNil(terminalFinished)
  }

  func testSlowEventSubscriberFailsWithoutAffectingActiveSubscriber() async throws {
    let configuration = try NearWireConfiguration(eventStreamBufferCapacity: 1)
    let nearWire = NearWire(configuration: configuration)
    var slow = nearWire.events.makeAsyncIterator()
    var active = nearWire.events.makeAsyncIterator()

    let publishedFirst = await nearWire.publishIncoming(try makeIncomingEnvelope(sequence: 1))
    let activeFirst = try await active.next()
    XCTAssertTrue(publishedFirst)
    XCTAssertEqual(activeFirst?.session?.sequence, 1)

    let publishedSecond = await nearWire.publishIncoming(
      try makeIncomingEnvelope(
        id: "10000000-0000-0000-0000-000000000002",
        sequence: 2
      )
    )
    let activeSecond = try await active.next()
    XCTAssertTrue(publishedSecond)
    XCTAssertEqual(activeSecond?.session?.sequence, 2)

    let publishedThird = await nearWire.publishIncoming(
      try makeIncomingEnvelope(
        id: "10000000-0000-0000-0000-000000000003",
        sequence: 3
      )
    )
    let activeThird = try await active.next()
    XCTAssertTrue(publishedThird)
    XCTAssertEqual(activeThird?.session?.sequence, 3)

    let slowFirst = try await slow.next()
    XCTAssertEqual(slowFirst?.session?.sequence, 1)
    do {
      _ = try await slow.next()
      XCTFail("Expected slow-consumer stream failure.")
    } catch {
      assertNearWireError(error, code: .streamOverflow)
    }
  }

  func testShutdownClearsBufferFinishesEventsAndRejectsMutation() async throws {
    let nearWire = NearWire()
    _ = try await nearWire.send(type: "test.pending", content: 1)
    var events = nearWire.events.makeAsyncIterator()

    await nearWire.shutdown()
    await nearWire.shutdown()

    let eventAfterShutdown = try await events.next()
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertNil(eventAfterShutdown)
    XCTAssertEqual(diagnostics.eventCount, 0)
    do {
      _ = try await nearWire.send(type: "test.late", content: 2)
      XCTFail("Expected terminal shutdown error.")
    } catch {
      assertNearWireError(error, code: .shutdown)
    }
    let latePublish = await nearWire.publishIncoming(try makeIncomingEnvelope())
    XCTAssertFalse(latePublish)
  }

  func testCancelledSubscriberDoesNotEndInstance() async throws {
    let nearWire = NearWire()
    let stream = nearWire.states
    let task = Task {
      for await _ in stream {
        if Task.isCancelled { break }
      }
    }
    XCTAssertEqual(nearWire.streamSubscriberCounts.states, 1)
    task.cancel()
    _ = await task.result

    let state = await nearWire.currentState
    _ = try await nearWire.send(type: "test.after-cancel", content: 1)
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(nearWire.streamSubscriberCounts.states, 0)
    XCTAssertEqual(state, .idle)
    XCTAssertEqual(diagnostics.eventCount, 1)
  }

  func testConcurrentStateSubscriptionAndFinishRetainsNoContinuations() {
    let hub = StateStreamHub(initial: .idle)
    let streams = SDKLockedCapture<AsyncStream<NearWireState>>()

    DispatchQueue.concurrentPerform(iterations: 128) { index in
      if index == 64 {
        hub.finish(with: .shutdown)
      } else {
        streams.append(hub.makeStream())
      }
    }

    XCTAssertEqual(streams.snapshot.count, 127)
    XCTAssertEqual(hub.subscriberCount, 0)
  }

  func testConcurrentEventOverflowAndFinishRetainsNoContinuations() {
    let hub = EventStreamHub(capacity: 1)
    let streams = SDKLockedCapture<AsyncThrowingStream<NearWireEvent, Error>>()
    for _ in 0..<64 {
      streams.append(hub.makeStream())
    }
    let event = NearWireEvent(
      id: UUID(),
      type: "test.event",
      content: .null,
      createdAt: Date(),
      priority: .normal,
      direction: .viewerToApp
    )

    DispatchQueue.concurrentPerform(iterations: 128) { index in
      if index == 64 {
        hub.finish()
      } else {
        hub.publish(event)
      }
    }

    XCTAssertEqual(hub.subscriberCount, 0)
  }
}
