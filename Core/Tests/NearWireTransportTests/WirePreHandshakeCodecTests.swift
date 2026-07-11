import Foundation
import XCTest

@_spi(NearWireInternal) @testable import NearWireCore
@_spi(NearWireInternal) @testable import NearWireTransport

final class WirePreHandshakeCodecTests: XCTestCase {
  func testClosedMessagesHaveDeterministicV1RoundTrips() throws {
    let codec = WirePreHandshakeCodec()
    let hello = try makeHello(role: .app, maximum: 3)
    let error = try WireErrorPayload(
      code: "invalid-message",
      message: "Message was rejected",
      isFatal: true,
      relatedType: .hello
    )
    let disconnect = try WireDisconnect(code: "viewer-closed", reason: "Window closed")

    let encodedHello = try codec.encode(hello)
    let encodedError = try codec.encode(error)
    let encodedDisconnect = try codec.encode(disconnect)

    XCTAssertEqual(encodedHello, try codec.encode(hello))
    XCTAssertEqual(encodedError, try codec.encode(error))
    XCTAssertEqual(encodedDisconnect, try codec.encode(disconnect))
    XCTAssertEqual(
      encodedHello,
      expectedControlFrame(
        #"{"body":{"applicationIdentifier":"com.example.demo","applicationVersion":"42","capabilities":["bidirectional-events","normal-queue"],"codecs":["json"],"displayName":"Demo App","installationID":"phone-installation","maximumEventBytes":262144,"maximumVersion":3,"minimumVersion":1,"productVersion":"1.2.0","role":"app","sendPolicies":["keep-latest","normal"]},"type":"hello","version":1}"#
      )
    )
    XCTAssertEqual(
      encodedError,
      expectedControlFrame(
        #"{"body":{"code":"invalid-message","fatal":true,"message":"Message was rejected","relatedType":"hello"},"type":"error","version":1}"#
      )
    )
    XCTAssertEqual(
      encodedDisconnect,
      expectedControlFrame(
        #"{"body":{"code":"viewer-closed","reason":"Window closed"},"type":"disconnect","version":1}"#
      )
    )

    XCTAssertEqual(try codec.decode(frame: frame(from: encodedHello)), .hello(hello))
    XCTAssertEqual(try codec.decode(frame: frame(from: encodedError)), .error(error))
    XCTAssertEqual(
      try codec.decode(frame: frame(from: encodedDisconnect)),
      .disconnect(disconnect)
    )
  }

  func testEventLanePreflightWinsBeforeJSONAndVersionParsing() {
    let codec = WirePreHandshakeCodec()
    assertTerminal(.phaseViolation) {
      _ = try codec.decode(frame: WireFrame(lane: .event, payload: Data("{bad".utf8)))
    }
    assertTerminal(.phaseViolation) {
      _ = try codec.decode(
        frame: WireFrame(
          lane: .event,
          payload: Data(#"{"body":{},"type":"event","version":2}"#.utf8)
        )
      )
    }
  }

  func testControlVersionPrecedesTypeLaneAndBodyInterpretation() throws {
    let codec = WirePreHandshakeCodec()
    assertTerminal(.invalidConfiguration) {
      _ = try codec.decode(frame: controlFrame(version: .integer(0)))
    }
    assertTerminal(.incompatibleVersion) {
      _ = try codec.decode(frame: controlFrame(version: .integer(2)))
    }
    assertTerminal(.incompatibleVersion) {
      _ = try codec.decode(
        frame: controlFrame(
          version: .integer(2),
          type: .integer(7),
          body: .string("not-a-v1-body")
        )
      )
    }
    assertTerminal(.incompatibleVersion) {
      _ = try codec.decode(
        frame: controlFrame(
          version: .integer(2),
          type: .string("event"),
          body: .object([:])
        )
      )
    }
    assertTerminal(.incompatibleVersion) {
      _ = try codec.decode(
        frame: controlFrame(
          version: .integer(2),
          type: .string("hello"),
          body: .object([:])
        )
      )
    }

    let futureWithoutV1Fields = try JSONValue.object(["version": .integer(2)])
      .deterministicData()
    assertTerminal(.incompatibleVersion) {
      _ = try codec.decode(
        frame: WireFrame(lane: .control, payload: futureWithoutV1Fields)
      )
    }
  }

  func testEveryKnownDisallowedTypeHasExactAdmissionCode() throws {
    let codec = WirePreHandshakeCodec()
    for type in [
      WireMessageType.helloAcknowledged,
      .connectionRejected,
      .ping,
      .pong,
    ] {
      assertTerminal(.phaseViolation, type.rawValue) {
        _ = try codec.decode(frame: canonicalFrame(type: type))
      }
    }
    for type in [WireMessageType.flowPolicyOffer, .flowPolicyAccepted] {
      assertTerminal(.unsupportedMessageType, type.rawValue) {
        _ = try codec.decode(frame: canonicalFrame(type: type))
      }
    }
    for type in [WireMessageType.event, .eventBatch, .eventDropSummary] {
      assertTerminal(.phaseViolation, type.rawValue) {
        _ = try codec.decode(frame: canonicalFrame(type: type))
      }
    }
    assertTerminal(.unsupportedMessageType, "future.control") {
      _ = try codec.decode(
        frame: controlFrame(
          version: .integer(1),
          type: .string("future.control"),
          body: .object([:])
        )
      )
    }
  }

  func testAllowedTypesValidateTheirPayloadBeforeReturningAValue() throws {
    let codec = WirePreHandshakeCodec()
    for type in [WireMessageType.hello, .error, .disconnect] {
      assertTerminal(.invalidMessage, type.rawValue) {
        _ = try codec.decode(frame: canonicalFrame(type: type))
      }
    }

    let tightLimits = try WireProtocolLimits(maximumControlTextBytes: 4)
    let tightCodec = WirePreHandshakeCodec(limits: tightLimits)
    let body = JSONValue.object([
      "code": .string("bad"),
      "fatal": .bool(true),
      "message": .string("too long"),
      "relatedType": .null,
    ])
    assertTerminal(.invalidText) {
      _ = try tightCodec.decode(
        frame: controlFrame(version: .integer(1), type: .string("error"), body: body)
      )
    }
    let disconnectBody = JSONValue.object([
      "code": .string("bad"),
      "reason": .string("too long"),
    ])
    assertTerminal(.invalidText) {
      _ = try tightCodec.decode(
        frame: controlFrame(
          version: .integer(1),
          type: .string("disconnect"),
          body: disconnectBody
        )
      )
    }
  }

  func testMalformedNoncanonicalDuplicateAndOversizedPayloadsAreTerminal() throws {
    let codec = WirePreHandshakeCodec()
    for payload in [
      #"{ "body":{},"type":"hello","version":1}"#,
      #"{"version":1,"type":"hello","body":{}}"#,
      #"{"body":{},"type":"hello","type":"ping","version":1}"#,
      #"{"body":{},"type":"hello","\u0074ype":"ping","version":1}"#,
      "{bad",
    ] {
      assertTerminal(.invalidJSON, payload) {
        _ = try codec.decode(
          frame: WireFrame(lane: .control, payload: Data(payload.utf8))
        )
      }
    }

    let frameLimits = try WireFrameLimits(
      maximumControlPayloadBytes: 128,
      maximumEventPayloadBytes: WireFrameLimits.default.maximumEventPayloadBytes
    )
    let boundedCodec = WirePreHandshakeCodec(
      limits: try WireProtocolLimits(frame: frameLimits)
    )
    assertTerminal(.frameTooLarge) {
      _ = try boundedCodec.decode(
        frame: WireFrame(lane: .control, payload: Data(repeating: 0x20, count: 129))
      )
    }
  }

  func testTighterCollectionLimitAndNegotiationHandoff() throws {
    let local = try makeHello(role: .app)
    let remote = try makeHello(role: .viewer)
    let tightLimits = try WireProtocolLimits(maximumCollectionCount: 1)
    let tightCodec = WirePreHandshakeCodec(limits: tightLimits)
    let encodedRemote = try WirePreHandshakeCodec().encode(remote)
    assertTerminal(.invalidMessage) {
      _ = try tightCodec.decode(frame: frame(from: encodedRemote))
    }

    let decodedRemote = try WirePreHandshakeCodec().decode(frame: frame(from: encodedRemote))
    guard case .hello(let remoteHello) = decodedRemote else {
      return XCTFail("Expected a typed remote hello.")
    }
    let result = try WireNegotiator.negotiate(local: local, remote: remoteHello)
    XCTAssertEqual(result.selectedVersion, .v1)
    XCTAssertNoThrow(try WireSessionCodec(negotiation: result))
  }

  func testWiderBootstrapIntervalsNegotiateHighestVersionBeforeCodecRegistration() throws {
    let codec = WirePreHandshakeCodec()
    let local = try makeHello(role: .app, minimum: 1, maximum: 2)
    let remote = try makeHello(role: .viewer, minimum: 1, maximum: 3)

    guard case .hello(let decodedLocal) = try codec.decode(frame: frame(from: codec.encode(local)))
    else {
      return XCTFail("Expected a typed local hello.")
    }
    guard
      case .hello(let decodedRemote) = try codec.decode(frame: frame(from: codec.encode(remote)))
    else {
      return XCTFail("Expected a typed remote hello.")
    }

    let result = try WireNegotiator.negotiate(local: decodedLocal, remote: decodedRemote)
    XCTAssertEqual(result.selectedVersion, try WireProtocolVersion(2))
    assertWireError(.incompatibleVersion) {
      _ = try WireSessionCodec(negotiation: result)
    }
  }

  func testCodecAndTypedResultAreSendableAndCodecRetainsOnlyLimits() throws {
    assertSendable(WirePreHandshakeCodec.self)
    assertSendable(WirePreHandshakeMessage.self)

    let limits = try WireProtocolLimits(maximumControlTextBytes: 64)
    let codec = WirePreHandshakeCodec(limits: limits)
    XCTAssertEqual(codec.limits, limits)
    let storedChildren = Array(Mirror(reflecting: codec).children)
    XCTAssertEqual(storedChildren.count, 1)
    XCTAssertEqual(storedChildren.first?.label, "limits")
  }

  private func canonicalFrame(type: WireMessageType) throws -> WireFrame {
    let lane = try XCTUnwrap(type.requiredLane)
    return WireFrame(
      lane: lane,
      payload: try WireMessage(version: .v1, type: type, body: .object([:]))
        .deterministicPayloadData()
    )
  }

  private func controlFrame(
    version: JSONValue,
    type: JSONValue? = nil,
    body: JSONValue? = nil
  ) throws -> WireFrame {
    var object = ["version": version]
    if let type { object["type"] = type }
    if let body { object["body"] = body }
    return WireFrame(
      lane: .control,
      payload: try JSONValue.object(object).deterministicData()
    )
  }

  private func frame(from encoded: Data) throws -> WireFrame {
    var decoder = WireFrameDecoder()
    var frames: [WireFrame] = []
    try decoder.consume(encoded) { frames.append($0) }
    XCTAssertTrue(decoder.isAtFrameBoundary)
    return try XCTUnwrap(frames.first)
  }

  private func expectedControlFrame(_ json: String) -> Data {
    let payload = Data(json.utf8)
    let length = UInt32(payload.count + 1)
    return Data([
      UInt8((length >> 24) & 0xFF),
      UInt8((length >> 16) & 0xFF),
      UInt8((length >> 8) & 0xFF),
      UInt8(length & 0xFF),
      WireLane.control.rawValue,
    ]) + payload
  }

  private func assertTerminal(
    _ code: WireProtocolError.Code,
    _ context: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> Void
  ) {
    XCTAssertThrowsError(try operation(), context, file: file, line: line) { error in
      guard let wireError = error as? WireProtocolError else {
        return XCTFail("Expected WireProtocolError, received \(error).", file: file, line: line)
      }
      XCTAssertEqual(wireError.code, code, context, file: file, line: line)
      XCTAssertEqual(
        wireError.disposition,
        .connectionTerminal,
        context,
        file: file,
        line: line
      )
    }
  }

  private func assertSendable<Value: Sendable>(_ type: Value.Type) {}
}
