import Foundation
@_spi(NearWireInternal) import NearWireCore
import XCTest

@_spi(NearWireInternal) @testable import NearWireTransport

final class WireGoldenFixtureTests: XCTestCase {
  func testCanonicalFixtureBytesAndCheckedInFiles() throws {
    for fixture in try fixtures() {
      XCTAssertEqual(
        String(decoding: fixture.data.dropFirst(5), as: UTF8.self),
        fixture.json,
        fixture.name
      )
      XCTAssertEqual(
        fixture.data,
        expectedFrame(json: fixture.json, lane: fixture.lane),
        fixture.name
      )

      #if os(macOS)
        let fileJSON = try fixtureText(name: fixture.name, extension: "json")
        let fileHex = try fixtureText(name: fixture.name, extension: "hex")
        XCTAssertEqual(fileJSON, fixture.json, fixture.name)
        XCTAssertEqual(fileHex, fixture.data.hexString, fixture.name)
      #endif
    }
  }

  func testCanonicalFixturesDecode() throws {
    for fixture in try fixtures() {
      var decoder = WireFrameDecoder()
      var decodedFrames: [WireFrame] = []
      try decoder.consume(fixture.data) { decodedFrames.append($0) }
      let frame = try XCTUnwrap(decodedFrames.first)
      let message = try WireMessage.decode(from: frame)
      XCTAssertEqual(message.type, fixture.type, fixture.name)
      XCTAssertEqual(frame.lane, fixture.lane, fixture.name)
      switch fixture.type {
      case .hello:
        XCTAssertEqual(
          try WireMessageCodec.decode(WireHello.self, from: message).role,
          .app
        )
      case .error:
        XCTAssertEqual(
          try WireMessageCodec.decode(WireErrorPayload.self, from: message).code,
          "invalid-message"
        )
      case .event:
        XCTAssertEqual(
          try WireMessageCodec.decode(WireEventPayload.self, from: message)
            .record.envelope.sequence.rawValue,
          0
        )
      case .eventBatch:
        XCTAssertEqual(
          try WireMessageCodec.decode(WireEventBatchPayload.self, from: message).records.count,
          2
        )
      default:
        XCTFail("Unexpected golden fixture type \(fixture.type.rawValue).")
      }
    }
  }

  private func fixtures() throws -> [Fixture] {
    let hello = try WireMessageCodec.encode(makeHello(role: .app), version: .v1)
    let error = try WireMessageCodec.encode(
      WireErrorPayload(
        code: "invalid-message",
        message: "Message was rejected",
        isFatal: true,
        relatedType: .hello
      ),
      version: .v1
    )
    let eventRecord = try WireEventRecord(
      envelope: makeWireTestEvent(),
      nowOnOriginClockNanoseconds: 1_250_000_000
    )
    let event = try WireMessageCodec.encode(
      WireEventPayload(record: eventRecord),
      version: .v1
    )
    let batchRecords = try (0..<2).map { sequence in
      try WireEventRecord(
        envelope: makeWireTestEvent(sequence: UInt64(sequence)),
        nowOnOriginClockNanoseconds: 1_100_000_000
      )
    }
    let batch = try WireMessageCodec.encode(
      WireEventBatchPayload(records: batchRecords),
      version: .v1
    )

    return [
      Fixture(name: "hello", type: .hello, lane: .control, data: hello, json: Self.helloJSON),
      Fixture(name: "error", type: .error, lane: .control, data: error, json: Self.errorJSON),
      Fixture(name: "event", type: .event, lane: .event, data: event, json: Self.eventJSON),
      Fixture(
        name: "event-batch",
        type: .eventBatch,
        lane: .event,
        data: batch,
        json: Self.batchJSON
      ),
    ]
  }

  private func expectedFrame(json: String, lane: WireLane) -> Data {
    let payload = Data(json.utf8)
    let length = UInt32(payload.count + 1)
    return Data([
      UInt8((length >> 24) & 0xFF),
      UInt8((length >> 16) & 0xFF),
      UInt8((length >> 8) & 0xFF),
      UInt8(length & 0xFF),
      lane.rawValue,
    ]) + payload
  }

  #if os(macOS)
    private func fixtureText(name: String, extension fileExtension: String) throws -> String {
      let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let url =
        root
        .appendingPathComponent("IntegrationTests/Fixtures/Protocol/v1")
        .appendingPathComponent("\(name).\(fileExtension)")
      return try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  #endif

  private struct Fixture {
    let name: String
    let type: WireMessageType
    let lane: WireLane
    let data: Data
    let json: String
  }

  private static let helloJSON =
    #"{"body":{"applicationIdentifier":"com.example.demo","applicationVersion":"42","capabilities":["bidirectional-events","normal-queue"],"codecs":["json"],"displayName":"Demo App","installationID":"phone-installation","maximumEventBytes":262144,"maximumVersion":1,"minimumVersion":1,"productVersion":"1.2.0","role":"app","sendPolicies":["keep-latest","normal"]},"type":"hello","version":1}"#
  private static let errorJSON =
    #"{"body":{"code":"invalid-message","fatal":true,"message":"Message was rejected","relatedType":"hello"},"type":"error","version":1}"#
  private static let eventJSON =
    #"{"body":{"causality":{"correlationID":null,"replyTo":null},"content":{"value":1},"createdAt":"2023-11-14T22:13:20.123Z","direction":"appToViewer","id":"123e4567-e89b-12d3-a456-000000000000","monotonicTimestampNanoseconds":"1000000000","priority":"normal","remainingTTLNanoseconds":"750000000","schemaVersion":1,"sequence":"0","sessionEpoch":"123e4567-e89b-12d3-a456-426614174000","source":{"id":"phone-installation","role":"app"},"target":{"id":"viewer-installation","role":"viewer"},"ttlMilliseconds":"1000","type":"app.test.event"},"type":"event","version":1}"#
  private static let batchJSON =
    #"{"body":{"events":[{"causality":{"correlationID":null,"replyTo":null},"content":{"value":1},"createdAt":"2023-11-14T22:13:20.123Z","direction":"appToViewer","id":"123e4567-e89b-12d3-a456-000000000000","monotonicTimestampNanoseconds":"1000000000","priority":"normal","remainingTTLNanoseconds":"900000000","schemaVersion":1,"sequence":"0","sessionEpoch":"123e4567-e89b-12d3-a456-426614174000","source":{"id":"phone-installation","role":"app"},"target":{"id":"viewer-installation","role":"viewer"},"ttlMilliseconds":"1000","type":"app.test.event"},{"causality":{"correlationID":null,"replyTo":null},"content":{"value":1},"createdAt":"2023-11-14T22:13:20.123Z","direction":"appToViewer","id":"123e4567-e89b-12d3-a456-000000000001","monotonicTimestampNanoseconds":"1000000000","priority":"normal","remainingTTLNanoseconds":"900000000","schemaVersion":1,"sequence":"1","sessionEpoch":"123e4567-e89b-12d3-a456-426614174000","source":{"id":"phone-installation","role":"app"},"target":{"id":"viewer-installation","role":"viewer"},"ttlMilliseconds":"1000","type":"app.test.event"}]},"type":"event.batch","version":1}"#
}

extension Data {
  fileprivate var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
