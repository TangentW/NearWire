import Foundation
import XCTest

@_spi(NearWireInternal) @testable import NearWireCore
@_spi(NearWireInternal) @testable import NearWireTransport

final class WireMessageTests: XCTestCase {
  private struct WrongLanePing: WireMessagePayload {
    static let messageType = WireMessageType.ping
    static let lane = WireLane.event

    init() {}
    init(body: JSONValue, limits: WireProtocolLimits) throws {}
    func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue { .object([:]) }
  }

  func testHelloMessageIsDeterministicAndTypedRoundTrips() throws {
    let hello = try makeHello(role: .app)
    let first = try WireMessageCodec.encode(hello, version: .v1)
    let second = try WireMessageCodec.encode(hello, version: .v1)
    XCTAssertEqual(first, second)

    var decoder = WireFrameDecoder()
    var decoded: WireHello?
    try decoder.consume(first) { frame in
      let message = try WireMessage.decode(from: frame)
      XCTAssertEqual(message.type, .hello)
      decoded = try WireMessageCodec.decode(WireHello.self, from: message)
    }
    XCTAssertEqual(decoded, hello)
  }

  func testUnknownEnvelopeFieldIsIgnoredButRequiredFieldsRemainRequired() throws {
    let body = try makeHello(role: .viewer).bodyJSON(limits: .default)
    let withUnknown = try JSONValue.object([
      "body": body,
      "future": .object(["enabled": .bool(true)]),
      "type": .string("hello"),
      "version": .integer(1),
    ]).deterministicData()
    let message = try WireMessage.decode(
      from: WireFrame(lane: .control, payload: withUnknown)
    )
    XCTAssertEqual(try WireMessageCodec.decode(WireHello.self, from: message).role, .viewer)

    let missingBody = try JSONValue.object([
      "type": .string("hello"),
      "version": .integer(1),
    ]).deterministicData()
    assertWireError(.invalidMessage) {
      _ = try WireMessage.decode(from: WireFrame(lane: .control, payload: missingBody))
    }
  }

  func testNoncanonicalAndDuplicateJSONAreRejected() throws {
    let noncanonicalPayloads = [
      #"{ "body":{},"type":"hello","version":1}"#,
      #"{"version":1,"type":"hello","body":{}}"#,
      #"{"body":{},"type":"hello","\u0074ype":"ping","version":1}"#,
    ]
    for payload in noncanonicalPayloads {
      assertWireError(.invalidJSON) {
        _ = try WireMessage.decode(
          from: WireFrame(lane: .control, payload: Data(payload.utf8))
        )
      }
    }
  }

  func testSessionCodecBindsVersionCapabilitiesAndTerminalDecodeErrors() throws {
    let local = try makeHello(role: .app, capabilities: [.normalQueue])
    let remote = try makeHello(role: .viewer, capabilities: [.normalQueue])
    let negotiation = try WireNegotiator.negotiate(local: local, remote: remote)
    let session = try WireSessionCodec(negotiation: negotiation)

    let wrongVersion = try WireMessageCodec.encode(
      WirePing(nonce: 1),
      version: WireProtocolVersion(2)
    )
    var wrongVersionDecoder = WireFrameDecoder()
    try wrongVersionDecoder.consume(wrongVersion) { frame in
      XCTAssertThrowsError(try session.decode(frame: frame, phase: .active)) { error in
        let wireError = error as? WireProtocolError
        XCTAssertEqual(wireError?.code, .incompatibleVersion)
        XCTAssertEqual(wireError?.disposition, .connectionTerminal)
      }
    }

    for type in [
      WireMessageType.event, .eventBatch, .eventDropSummary, .flowPolicyOffer,
    ] {
      let payload = try WireMessage(version: .v1, type: type, body: .object([:]))
        .deterministicPayloadData()
      let frame = WireFrame(
        lane: try XCTUnwrap(type.requiredLane),
        payload: payload
      )
      assertWireError(.unsupportedMessageType) {
        _ = try session.decode(frame: frame, phase: .active)
      }
    }
    let invalidLargeEvent = WireFrame(
      lane: .event,
      payload: Data(repeating: 0xFF, count: 1_024 * 1_024)
    )
    assertWireError(.unsupportedMessageType) {
      _ = try session.decode(frame: invalidLargeEvent, phase: .active)
    }

    let capableNegotiation = try WireNegotiator.negotiate(
      local: makeHello(role: .app),
      remote: makeHello(role: .viewer)
    )
    let capableSession = try WireSessionCodec(negotiation: capableNegotiation)
    let encoded = try capableSession.encode(WirePing(nonce: 42), phase: .active)
    var decoder = WireFrameDecoder()
    try decoder.consume(encoded) { frame in
      let message = try capableSession.decode(frame: frame, phase: .active)
      XCTAssertEqual(message.version, capableNegotiation.selectedVersion)
      XCTAssertEqual(
        try capableSession.decode(WirePing.self, from: message),
        WirePing(nonce: 42)
      )
    }

    assertWireError(.phaseViolation) {
      _ = try capableSession.decode(frame: invalidLargeEvent, phase: .preHandshake)
    }
  }

  func testExpectedVersionGuardPrecedesV1EnvelopeSemantics() throws {
    let futureWithoutV1Fields = WireFrame(
      lane: .control,
      payload: try JSONValue.object(["version": .integer(2)]).deterministicData()
    )
    assertWireError(.incompatibleVersion) {
      _ = try WireMessage.decode(
        from: futureWithoutV1Fields,
        expectedVersion: .v1
      )
    }

    let futureEventOnControl = WireFrame(
      lane: .control,
      payload: try WireMessage(
        version: WireProtocolVersion(2),
        type: .event,
        body: .object([:])
      ).deterministicPayloadData()
    )
    assertWireError(.incompatibleVersion) {
      _ = try WireMessage.decode(
        from: futureEventOnControl,
        expectedVersion: .v1
      )
    }

    let rawFuturePing = WireFrame(
      lane: .control,
      payload: try WireMessage(
        version: WireProtocolVersion(2),
        type: .ping,
        body: .object([:])
      ).deterministicPayloadData()
    )
    let rawMessage = try WireMessage.decode(from: rawFuturePing)
    XCTAssertEqual(rawMessage.version, try WireProtocolVersion(2))
    XCTAssertEqual(rawMessage.type, .ping)

    let negotiation = try WireNegotiator.negotiate(
      local: makeHello(role: .app),
      remote: makeHello(role: .viewer)
    )
    let session = try WireSessionCodec(negotiation: negotiation)
    XCTAssertThrowsError(try session.decode(frame: futureEventOnControl, phase: .active)) { error in
      let wireError = error as? WireProtocolError
      XCTAssertEqual(wireError?.code, .incompatibleVersion)
      XCTAssertEqual(wireError?.disposition, .connectionTerminal)
    }
  }

  func testSessionCodecRejectsUnsupportedVersionAndLocalLimitWidening() throws {
    let future = try WireNegotiator.negotiate(
      local: makeHello(role: .app, maximum: 2),
      remote: makeHello(role: .viewer, maximum: 2)
    )
    assertWireError(.incompatibleVersion) {
      _ = try WireSessionCodec(negotiation: future)
    }
    assertWireError(.incompatibleVersion) {
      _ = try WireNegotiator.makeAcknowledgement(
        result: future,
        sessionEpoch: SessionEpoch(
          rawValue: "123e4567-e89b-12d3-a456-426614174000"
        )
      )
    }

    let v1 = try WireNegotiator.negotiate(
      local: makeHello(role: .app),
      remote: makeHello(role: .viewer)
    )
    let localLimits = try WireProtocolLimits(maximumEventBytes: 128)
    assertWireError(.invalidConfiguration) {
      _ = try WireSessionCodec(negotiation: v1, baseLimits: localLimits)
    }
  }

  func testWrongLaneAndPhaseAdmissionAreRejected() throws {
    let payload = try WireMessage(
      version: .v1,
      type: .event,
      body: .object([:])
    ).deterministicPayloadData()
    assertWireError(.invalidLane) {
      _ = try WireMessage.decode(from: WireFrame(lane: .control, payload: payload))
    }
    assertWireError(.phaseViolation) {
      try WireMessageAdmission.validate(
        lane: .event,
        type: .event,
        phase: .preHandshake,
        capabilities: [.bidirectionalEvents]
      )
    }
    XCTAssertNoThrow(
      try WireMessageAdmission.validate(
        lane: .event,
        type: .event,
        phase: .active,
        capabilities: [.bidirectionalEvents]
      )
    )
    assertWireError(.unsupportedMessageType) {
      try WireMessageAdmission.validate(
        lane: .control,
        type: WireMessageType("future.message"),
        phase: .active,
        capabilities: []
      )
    }
    assertWireError(.invalidLane) {
      _ = try WireMessageCodec.encode(WrongLanePing(), version: .v1)
    }
  }

  func testProtocolVersionCodableUsesValidatedScalarRepresentation() throws {
    let encoded = try JSONEncoder().encode(WireProtocolVersion.v1)
    XCTAssertEqual(String(data: encoded, encoding: .utf8), "1")
    XCTAssertEqual(try JSONDecoder().decode(WireProtocolVersion.self, from: encoded), .v1)
    XCTAssertThrowsError(
      try JSONDecoder().decode(WireProtocolVersion.self, from: Data("0".utf8))
    )
  }

  func testTokenValidationUsesDomainSpecificErrors() throws {
    assertWireError(.invalidCodec) { _ = try WireCodecIdentifier("JSON") }
    assertWireError(.invalidCapability) { _ = try WireCapability("Invalid") }
    assertWireError(.invalidText) {
      _ = try WireConnectionRejected(code: "Not_Allowed")
    }
  }

  func testDirectPublicPayloadDecodeNormalizesCoreModelErrors() throws {
    guard case .object(var body) = try makeHello(role: .app).bodyJSON(limits: .default) else {
      return XCTFail("Expected a hello object.")
    }
    body["installationID"] = .string("")
    XCTAssertThrowsError(try WireHello(body: .object(body), limits: .default)) { error in
      XCTAssertEqual((error as? WireProtocolError)?.code, .invalidMessage)
    }
  }

  func testPrimitiveConfigurationBoundariesAndSendability() throws {
    XCTAssertThrowsError(try WireProtocolVersion(0)) { error in
      let wireError = error as? WireProtocolError
      XCTAssertEqual(wireError?.code, .invalidConfiguration)
      XCTAssertEqual(wireError?.disposition, .operationRejected)
    }
    assertWireError(.invalidConfiguration) {
      _ = try WireVersionRange(minimum: WireProtocolVersion(2), maximum: .v1)
    }
    assertWireError(.invalidMessageType) { _ = try WireMessageType("Invalid.Type") }
    assertWireError(.invalidConfiguration) {
      _ = try WireFrameLimits(maximumControlPayloadBytes: 0)
    }
    let smallFrame = try WireFrameLimits(
      maximumControlPayloadBytes: 64,
      maximumEventPayloadBytes: 64
    )
    assertWireError(.invalidConfiguration) {
      _ = try WireProtocolLimits(frame: smallFrame, maximumEventBytes: 65)
    }

    assertSendable(WireProtocolLimits.self)
    assertSendable(WireFrameDecoder.self)
    assertSendable(WireMessage.self)
    assertSendable(WireEventPayload.self)
  }

  func testControlPayloadsRoundTripAndTextBounds() throws {
    let policy = try WireFlowPolicy(
      appUplinkEventsPerSecond: 20,
      appDownlinkEventsPerSecond: 10
    )
    try assertRoundTrip(WireFlowPolicyOffer(policy: policy))
    try assertRoundTrip(WireFlowPolicyAccepted(policy: policy))
    try assertRoundTrip(WirePing(nonce: UInt64.max))
    try assertRoundTrip(WirePong(nonce: UInt64.max))
    try assertRoundTrip(WireConnectionRejected(code: "not-approved", message: "Rejected"))
    try assertRoundTrip(WireDisconnect(code: "viewer-closed", reason: "Window closed"))
    try assertRoundTrip(
      WireErrorPayload(
        code: "invalid-message",
        message: "Message was rejected",
        isFatal: true,
        relatedType: .hello
      )
    )

    assertWireError(.invalidText) {
      _ = try WireErrorPayload(
        code: "invalid-message",
        message: String(repeating: "x", count: 513),
        isFatal: true
      )
    }
    assertWireError(.invalidText) {
      _ = try WireDisconnect(code: "closed", reason: "bad\nreason")
    }
  }

  func testInvalidJSONAndTaggedUInt64AreRejected() throws {
    assertWireError(.invalidJSON) {
      _ = try WireMessage.decode(
        from: WireFrame(lane: .control, payload: Data("{bad".utf8))
      )
    }
    let badNonce = WireMessage(
      version: .v1,
      type: .ping,
      body: .object(["nonce": .string("0001")])
    )
    assertWireError(.invalidMessage) {
      _ = try WireMessageCodec.decode(WirePing.self, from: badNonce)
    }
    assertWireError(.invalidJSON) {
      _ = try WireMessage.decode(
        from: WireFrame(lane: .control, payload: Data([0x7B, 0xFF, 0x7D]))
      )
    }
  }

  private func assertRoundTrip<Payload: WireMessagePayload & Equatable>(
    _ payload: Payload,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let framed = try WireMessageCodec.encode(payload, version: .v1)
    var decoder = WireFrameDecoder()
    var result: Payload?
    try decoder.consume(framed) { frame in
      result = try WireMessageCodec.decode(
        Payload.self,
        from: WireMessage.decode(from: frame)
      )
    }
    XCTAssertEqual(result, payload, file: file, line: line)
  }

  private func assertSendable<Value: Sendable>(_ type: Value.Type) {}
}
