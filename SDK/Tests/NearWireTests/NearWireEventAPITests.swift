import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireFlowControl
import XCTest

@_spi(NearWireBuiltins) @testable import NearWire
@_spi(NearWireInternal) @testable import NearWireTransport

final class NearWireEventAPITests: XCTestCase {
  private struct Payload: Codable, Equatable, Sendable {
    let name: String
    let createdAt: Date
    let bytes: Data
    let values: [Int]
  }

  private struct SecretEncodingError: Error, CustomStringConvertible {
    var description: String { "secret-token-must-not-escape" }
  }

  private struct FailingPayload: Encodable, Sendable {
    func encode(to encoder: Encoder) throws {
      throw SecretEncodingError()
    }
  }

  func testIncomingContentIsInspectableAndTypedDecodable() async throws {
    let payload = Payload(
      name: "sample",
      createdAt: Date(timeIntervalSince1970: 1_700_000_123.456),
      bytes: Data([0, 1, 2, 255]),
      values: [1, 2, 3]
    )
    let content = try EventContentCodec().encode(payload)
    let nearWire = NearWire()
    var iterator = nearWire.events.makeAsyncIterator()

    let published = await nearWire.publishIncoming(try makeIncomingEnvelope(content: content))
    XCTAssertTrue(published)
    let received = try await iterator.next()
    let event = try XCTUnwrap(received)
    XCTAssertEqual(event.id.uuidString.lowercased(), "10000000-0000-0000-0000-000000000001")
    XCTAssertEqual(event.type, "viewer.command")
    XCTAssertEqual(event.direction, .viewerToApp)
    XCTAssertEqual(event.session?.sequence, 1)
    XCTAssertEqual(event.session?.sourceID, "viewer-one")
    XCTAssertEqual(try event.decode(Payload.self), payload)

    guard case .object(let object) = event.content else {
      return XCTFail("Expected inspectable object content.")
    }
    XCTAssertEqual(object["name"], .string("sample"))
  }

  func testEncodingFailureDoesNotExposeUnderlyingDescription() async throws {
    let nearWire = NearWire()
    do {
      _ = try await nearWire.send(type: "test.failure", content: FailingPayload())
      XCTFail("Expected encoding failure.")
    } catch {
      assertNearWireError(error, code: .contentEncodingFailed)
      XCTAssertFalse(String(describing: error).contains("secret-token-must-not-escape"))
    }
  }

  func testNonFiniteContentAndReservedTypesFailSafely() async throws {
    let nearWire = NearWire()
    do {
      _ = try await nearWire.send(type: "test.number", content: Double.infinity)
      XCTFail("Expected non-finite content failure.")
    } catch {
      assertNearWireError(error, code: .contentEncodingFailed)
    }

    do {
      _ = try await nearWire.send(type: "nearwire.internal", content: 1)
      XCTFail("Expected reserved type failure.")
    } catch {
      assertNearWireError(error, code: .invalidEventType)
    }
  }

  func testDecodeFailureIsStableAndSafe() throws {
    let event = NearWireEvent(
      id: UUID(),
      type: "test.value",
      content: .string("not-an-integer"),
      createdAt: Date(),
      priority: .normal,
      direction: .viewerToApp
    )
    XCTAssertThrowsError(try event.decode(Int.self)) { error in
      assertNearWireError(error, code: .contentDecodingFailed)
    }
  }

  func testReplyFillsCorrelationAndReplyToIdentity() async throws {
    let clock = SDKTestClock()
    let nearWire = NearWire(
      dependencies: clock.dependencies,
      instanceIdentifier: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    )
    var iterator = nearWire.events.makeAsyncIterator()
    let published = await nearWire.publishIncoming(try makeIncomingEnvelope())
    let received = try await iterator.next()
    let source = try XCTUnwrap(received)
    XCTAssertTrue(published)

    let result = try await nearWire.reply(
      to: source,
      type: "app.response",
      content: ["ok": true]
    )
    let capture = SDKLockedCapture<PendingEvent<SDKQueuedEvent>>()
    let drain = try await nearWire.drainOutbound(
      for: sdkTestSessionRoute,
      maximumCount: 1,
      maximumBytes: 1_024 * 1_024
    ) { event in
      capture.append(event)
      return .accepted
    }
    let pending = capture.snapshot
    let diagnostics = try await nearWire.bufferDiagnostics()

    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(drain.acceptedEventIDs, [pending[0].id])
    XCTAssertEqual(diagnostics.statistics.transportAccepted, 1)
    XCTAssertEqual(UUID(uuidString: pending[0].id.rawValue), result.eventID)
    XCTAssertEqual(
      pending[0].value.draft.causality.correlationID.flatMap { UUID(uuidString: $0.rawValue) },
      source.id
    )
    XCTAssertEqual(
      pending[0].value.draft.causality.replyTo.flatMap { UUID(uuidString: $0.rawValue) },
      source.id
    )
  }

  func testReplyRejectsAnEventFromAnotherInstance() async throws {
    let first = NearWire()
    let second = NearWire()
    var iterator = first.events.makeAsyncIterator()
    let published = await first.publishIncoming(try makeIncomingEnvelope())
    let received = try await iterator.next()
    let event = try XCTUnwrap(received)
    XCTAssertTrue(published)

    do {
      _ = try await second.reply(to: event, type: "app.response", content: 1)
      XCTFail("Expected cross-instance reply rejection.")
    } catch {
      assertNearWireError(error, code: .invalidReply)
    }
  }

  func testReplyIsDroppedInsteadOfCrossingSessionRoute() async throws {
    let nearWire = NearWire()
    var iterator = nearWire.events.makeAsyncIterator()
    _ = await nearWire.publishIncoming(try makeIncomingEnvelope())
    let received = try await iterator.next()
    let event = try XCTUnwrap(received)
    let reply = try await nearWire.reply(
      to: event,
      type: "app.response",
      content: ["ok": true]
    )
    let attempts = SDKLockedCapture<EventID>()
    let otherRoute = SDKSessionRoute(
      sessionEpoch: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
      viewerID: "viewer-two",
      appID: "app-one"
    )

    let drain = try await nearWire.drainOutbound(
      for: otherRoute,
      maximumCount: 1,
      maximumBytes: 1_024 * 1_024
    ) { queued in
      attempts.append(queued.id)
      return .accepted
    }
    let diagnostics = try await nearWire.bufferDiagnostics()

    XCTAssertTrue(attempts.snapshot.isEmpty)
    XCTAssertEqual(
      drain.routingDroppedEventIDs.compactMap { UUID(uuidString: $0.rawValue) },
      [reply.eventID]
    )
    XCTAssertEqual(diagnostics.eventCount, 0)
    XCTAssertEqual(diagnostics.statistics.routingDropped, 1)
  }

  func testOversizedRouteMismatchIsDroppedBeforeTransportByteBudget() async throws {
    let nearWire = NearWire()
    var iterator = nearWire.events.makeAsyncIterator()
    _ = await nearWire.publishIncoming(try makeIncomingEnvelope())
    let received = try await iterator.next()
    let source = try XCTUnwrap(received)
    let staleReply = try await nearWire.reply(
      to: source,
      type: "app.large-response",
      content: String(repeating: "x", count: 2_048)
    )
    let eligible = try await nearWire.send(type: "app.small", content: 1)
    let attempts = SDKLockedCapture<EventID>()
    let otherRoute = SDKSessionRoute(
      sessionEpoch: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
      viewerID: "viewer-two",
      appID: "app-one"
    )

    let drain = try await nearWire.drainOutbound(
      for: otherRoute,
      maximumCount: 2,
      maximumBytes: 512
    ) { event in
      attempts.append(event.id)
      return .accepted
    }
    let diagnostics = try await nearWire.bufferDiagnostics()

    XCTAssertEqual(
      drain.routingDroppedEventIDs.compactMap { UUID(uuidString: $0.rawValue) },
      [staleReply.eventID]
    )
    XCTAssertEqual(
      drain.acceptedEventIDs.compactMap { UUID(uuidString: $0.rawValue) },
      [eligible.eventID]
    )
    XCTAssertEqual(attempts.snapshot, drain.acceptedEventIDs)
    XCTAssertEqual(diagnostics.eventCount, 0)
    XCTAssertEqual(diagnostics.statistics.routingDropped, 1)
  }

  func testFrameworkSPIUsesReservedNamespaceThroughTheSameQueue() async throws {
    let nearWire = NearWire()
    let result = try await nearWire.sendPlatformEvent(
      type: "nearwire.performance.snapshot",
      content: ["sample": 1],
      policy: .keepLatest(key: "performance")
    )
    let capture = SDKLockedCapture<PendingEvent<SDKQueuedEvent>>()
    _ = try await nearWire.drainOutbound(
      for: sdkTestSessionRoute,
      maximumCount: 1,
      maximumBytes: 1_024 * 1_024
    ) { event in
      capture.append(event)
      return .accepted
    }

    XCTAssertEqual(
      capture.snapshot.first.flatMap { UUID(uuidString: $0.id.rawValue) }, result.eventID)
    XCTAssertEqual(
      capture.snapshot.first?.value.draft.type.rawValue, "nearwire.performance.snapshot")
  }

  func testDrainUsesRealChannelMailboxAdmissionWithoutDequeuingRejectedEvent() async throws {
    let nearWire = NearWire()
    _ = try await nearWire.send(type: "test.first", content: 1)
    _ = try await nearWire.send(type: "test.second", content: 2)
    let driver = SDKSecureConnectionDriver()
    let limits = try SecureTransportLimits(
      maximumPendingSendCount: 1,
      maximumPendingSendBytes: 16,
      maximumSingleSendBytes: 16
    )
    let channel = SecureByteChannel(driver: driver, limits: limits) { _ in }
    try await channel.start()

    let drain = try await nearWire.drainOutbound(
      for: sdkTestSessionRoute,
      maximumCount: 2,
      maximumBytes: 1_024 * 1_024,
      channel: channel
    ) { _ in Data([1]) }
    let diagnostics = try await nearWire.bufferDiagnostics()

    XCTAssertEqual(drain.acceptedEventIDs.count, 1)
    XCTAssertEqual(drain.rejectedEventIDs.count, 1)
    XCTAssertEqual(diagnostics.eventCount, 1)
    XCTAssertEqual(diagnostics.statistics.transportAccepted, 1)
    XCTAssertEqual(diagnostics.statistics.transportAdmissionRejected, 1)

    driver.emitState(.ready)
    await sdkWaitUntil { driver.sentData == [Data([1])] }
    await channel.cancel()
  }

  func testEncodingDeferralIsNotReportedAsTransportRejection() async throws {
    let nearWire = NearWire()
    _ = try await nearWire.send(type: "test.unencoded", content: 1)
    let driver = SDKSecureConnectionDriver()
    let channel = SecureByteChannel(driver: driver) { _ in }
    try await channel.start()

    let drain = try await nearWire.drainOutbound(
      for: sdkTestSessionRoute,
      maximumCount: 1,
      maximumBytes: 1_024 * 1_024,
      channel: channel
    ) { _ in nil }
    let diagnostics = try await nearWire.bufferDiagnostics()

    XCTAssertTrue(drain.acceptedEventIDs.isEmpty)
    XCTAssertTrue(drain.rejectedEventIDs.isEmpty)
    XCTAssertEqual(drain.notAttemptedEventIDs.count, 1)
    XCTAssertEqual(diagnostics.eventCount, 1)
    XCTAssertEqual(diagnostics.statistics.transportAdmissionRejected, 0)
    XCTAssertEqual(diagnostics.statistics.transportAccepted, 0)
    XCTAssertTrue(driver.sentData.isEmpty)
    await channel.cancel()
  }
}
