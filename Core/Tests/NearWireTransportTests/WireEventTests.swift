import Foundation
import XCTest

@testable import NearWireCore
@testable import NearWireTransport

final class WireEventTests: XCTestCase {
  func testPlainJSONEventPreservesEveryContentCaseWithoutInternalTags() throws {
    let content = JSONValue.object([
      "array": .array([.null, .bool(true), .integer(Int64.min), .number(1.0)]),
      "object": .object(["text": .string("hello")]),
    ])
    let envelope = try makeWireTestEvent(content: content)
    let record = try WireEventRecord(
      envelope: envelope,
      nowOnOriginClockNanoseconds: 1_250_000_000
    )
    let framed = try WireMessageCodec.encode(WireEventPayload(record: record), version: .v1)

    var decoded: WireEventPayload?
    var decoder = WireFrameDecoder()
    try decoder.consume(framed) { frame in
      XCTAssertEqual(frame.lane, .event)
      let text = try XCTUnwrap(String(data: frame.payload, encoding: .utf8))
      XCTAssertTrue(text.contains("\"content\":{\"array\":[null,true,-9223372036854775808,1.0]"))
      XCTAssertFalse(text.contains("\"integer\""))
      decoded = try WireMessageCodec.decode(
        WireEventPayload.self,
        from: WireMessage.decode(from: frame)
      )
    }

    XCTAssertEqual(decoded?.record.envelope.content, content)
    XCTAssertEqual(decoded?.record.remainingTTLNanoseconds, 750_000_000)
    XCTAssertEqual(decoded?.record.envelope.sequence.rawValue, 0)
    XCTAssertEqual(decoded?.record.envelope.createdAt, envelope.createdAt)
  }

  func testSenderTTLAndReceiverLocalDeadline() throws {
    let envelope = try makeWireTestEvent(ttlMilliseconds: 1_000)
    let record = try WireEventRecord(
      envelope: envelope,
      nowOnOriginClockNanoseconds: 1_250_000_000
    )
    XCTAssertEqual(record.remainingTTLNanoseconds, 750_000_000)
    let received = try record.receiverEvent(receivedAtNanoseconds: 10_000_000_000)
    XCTAssertEqual(received.deadlineNanoseconds, 10_750_000_000)
    XCTAssertFalse(try received.isExpired(nowOnReceiverClockNanoseconds: 10_749_999_999))
    XCTAssertTrue(try received.isExpired(nowOnReceiverClockNanoseconds: 10_750_000_000))

    assertWireError(.eventExpired) {
      _ = try WireEventRecord(
        envelope: envelope,
        nowOnOriginClockNanoseconds: 2_000_000_000
      )
    }
    XCTAssertThrowsError(
      try WireEventRecord(
        envelope: envelope,
        nowOnOriginClockNanoseconds: 2_000_000_000
      )
    ) { error in
      XCTAssertEqual((error as? WireProtocolError)?.disposition, .operationRejected)
    }
    assertWireError(.invalidClock) {
      _ = try WireEventRecord(
        envelope: envelope,
        nowOnOriginClockNanoseconds: 999_999_999
      )
    }
    let overflowing = try WireEventRecord(
      envelope: envelope,
      remainingTTLNanoseconds: 1
    )
    assertWireError(.arithmeticOverflow) {
      _ = try overflowing.receiverEvent(receivedAtNanoseconds: UInt64.max)
    }
  }

  func testBatchRequiresOneEpochDirectionAndContiguousSequence() throws {
    let records = try (0..<3).map { sequence in
      try WireEventRecord(
        envelope: makeWireTestEvent(sequence: UInt64(sequence)),
        nowOnOriginClockNanoseconds: 1_100_000_000
      )
    }
    let batch = try WireEventBatchPayload(records: records)
    let framed = try WireMessageCodec.encode(batch, version: .v1)
    var decoded: WireEventBatchPayload?
    var decoder = WireFrameDecoder()
    try decoder.consume(framed) { frame in
      decoded = try WireMessageCodec.decode(
        WireEventBatchPayload.self,
        from: WireMessage.decode(from: frame)
      )
    }
    XCTAssertEqual(decoded, batch)

    assertWireError(.invalidBatch) {
      _ = try WireEventBatchPayload(records: [records[0], records[2]])
    }
    let opposite = try WireEventRecord(
      envelope: makeWireTestEvent(sequence: 1, direction: .viewerToApp),
      nowOnOriginClockNanoseconds: 1_100_000_000
    )
    assertWireError(.invalidBatch) {
      _ = try WireEventBatchPayload(records: [records[0], opposite])
    }
    let otherEpoch = try WireEventRecord(
      envelope: makeWireTestEvent(
        sequence: 1,
        sessionEpoch: "123e4567-e89b-12d3-a456-426614174001"
      ),
      nowOnOriginClockNanoseconds: 1_100_000_000
    )
    assertWireError(.invalidBatch) {
      _ = try WireEventBatchPayload(records: [records[0], otherEpoch])
    }
    assertWireError(.invalidBatch) {
      _ = try WireEventBatchPayload(records: [])
    }
  }

  func testDropSummaryIsDiagnosticPlainData() throws {
    let summary = WireDropSummaryPayload(
      overflowDropped: UInt64.max,
      expired: 2,
      coalesced: 3
    )
    let framed = try WireMessageCodec.encode(summary, version: .v1)
    var decoded: WireDropSummaryPayload?
    var decoder = WireFrameDecoder()
    try decoder.consume(framed) { frame in
      decoded = try WireMessageCodec.decode(
        WireDropSummaryPayload.self,
        from: WireMessage.decode(from: frame)
      )
    }
    XCTAssertEqual(decoded, summary)
  }

  func testEventAndBatchLimitsAreEnforced() throws {
    let tightFrame = try WireFrameLimits(
      maximumControlPayloadBytes: 1_024,
      maximumEventPayloadBytes: 1_024
    )
    let tight = try WireProtocolLimits(
      frame: tightFrame,
      maximumEventBytes: 128,
      maximumBatchEventCount: 2
    )
    let largeContent = JSONValue.string(String(repeating: "x", count: 200))
    let record = try WireEventRecord(
      envelope: makeWireTestEvent(content: largeContent),
      nowOnOriginClockNanoseconds: 1_100_000_000
    )
    assertWireError(.frameTooLarge) {
      _ = try WireMessageCodec.encode(
        WireEventPayload(record: record),
        version: .v1,
        limits: tight
      )
    }

    let records = try (0..<3).map { sequence in
      try WireEventRecord(
        envelope: makeWireTestEvent(sequence: UInt64(sequence)),
        nowOnOriginClockNanoseconds: 1_100_000_000
      )
    }
    assertWireError(.invalidBatch) {
      _ = try WireEventBatchPayload(records: records, limits: tight)
    }
  }

  func testDecodedBatchCountIsRejectedBeforeElementConstruction() throws {
    let body = JSONValue.object([
      "events": .array(Array(repeating: .null, count: 257))
    ])
    let message = WireMessage(version: .v1, type: .eventBatch, body: body)
    assertWireError(.invalidBatch) {
      _ = try WireMessageCodec.decode(WireEventBatchPayload.self, from: message)
    }
  }

  func testV1BatchExactlyAtEventFrameBoundarySucceeds() throws {
    let records = try (0..<2).map { sequence in
      try WireEventRecord(
        envelope: makeWireTestEvent(sequence: UInt64(sequence)),
        nowOnOriginClockNanoseconds: 1_100_000_000
      )
    }
    let body = JSONValue.object([
      "events": .array(try records.map { try $0.jsonValue() })
    ])
    let exactPayloadBytes = try WireMessage(
      version: .v1,
      type: .eventBatch,
      body: body
    ).deterministicPayloadData().count
    let frameLimits = try WireFrameLimits(
      maximumControlPayloadBytes: 1_024,
      maximumEventPayloadBytes: exactPayloadBytes
    )
    let limits = try WireProtocolLimits(
      frame: frameLimits,
      maximumEventBytes: exactPayloadBytes
    )

    let batch = try WireEventBatchPayload(records: records, limits: limits)
    let framed = try WireMessageCodec.encode(batch, version: .v1, limits: limits)

    XCTAssertEqual(framed.count - 5, exactPayloadBytes)
  }

  func testDecodeUsesActiveEventModelLimitsAndNormalizesModelErrors() throws {
    let record = try WireEventRecord(
      envelope: makeWireTestEvent(),
      nowOnOriginClockNanoseconds: 1_100_000_000
    )
    let body = try record.jsonValue()
    let eventLimits = try EventValidationLimits(maximumTypeBytes: 4)
    let protocolLimits = try WireProtocolLimits(eventValidationLimits: eventLimits)
    let message = WireMessage(version: .v1, type: .event, body: body)

    XCTAssertThrowsError(
      try WireEventPayload(body: body, limits: protocolLimits)
    ) { error in
      XCTAssertEqual((error as? WireProtocolError)?.code, .invalidMessage)
    }
    assertWireError(.invalidMessage) {
      _ = try WireMessageCodec.decode(
        WireEventPayload.self,
        from: message,
        limits: protocolLimits
      )
    }
  }

  func testMalformedEventDateAndAggregateBatchFrameLimitAreRejected() throws {
    let record = try WireEventRecord(
      envelope: makeWireTestEvent(content: .string(String(repeating: "x", count: 120))),
      nowOnOriginClockNanoseconds: 1_100_000_000
    )
    guard case .object(var malformed) = try record.jsonValue() else {
      return XCTFail("Expected an event object.")
    }
    malformed["createdAt"] = .string("not-a-date")
    let invalidDate = WireMessage(
      version: .v1,
      type: .event,
      body: .object(malformed)
    )
    assertWireError(.invalidMessage) {
      _ = try WireMessageCodec.decode(WireEventPayload.self, from: invalidDate)
    }

    let second = try WireEventRecord(
      envelope: makeWireTestEvent(
        sequence: 1,
        content: .string(String(repeating: "y", count: 120))
      ),
      nowOnOriginClockNanoseconds: 1_100_000_000
    )
    let frameLimits = try WireFrameLimits(
      maximumControlPayloadBytes: 1_024,
      maximumEventPayloadBytes: 1_000
    )
    let protocolLimits = try WireProtocolLimits(
      frame: frameLimits,
      maximumEventBytes: 900
    )
    assertWireError(.frameTooLarge) {
      _ = try WireEventBatchPayload(records: [record, second], limits: protocolLimits)
    }
  }

  func testOriginDeadlineOverflowAndCanonicalDateRules() throws {
    let record = try WireEventRecord(
      envelope: makeWireTestEvent(),
      nowOnOriginClockNanoseconds: 1_100_000_000
    )
    guard case .object(var body) = try record.jsonValue() else {
      return XCTFail("Expected an event object.")
    }
    body["monotonicTimestampNanoseconds"] = .string(String(UInt64.max))
    assertWireError(.arithmeticOverflow) {
      _ = try WireMessageCodec.decode(
        WireEventPayload.self,
        from: WireMessage(version: .v1, type: .event, body: .object(body))
      )
    }

    for invalidDate in [
      "2023-11-14T22:13:20Z",
      "2023-11-14T23:13:20.123+01:00",
      "2023-11-14T22:13:20.1230Z",
    ] {
      var invalidBody = body
      invalidBody["monotonicTimestampNanoseconds"] = .string("1000000000")
      invalidBody["createdAt"] = .string(invalidDate)
      assertWireError(.invalidMessage) {
        _ = try WireMessageCodec.decode(
          WireEventPayload.self,
          from: WireMessage(version: .v1, type: .event, body: .object(invalidBody))
        )
      }
    }

    let submillisecond = try makeWireTestEvent(
      createdAt: Date(timeIntervalSince1970: 1_700_000_000.123_456)
    )
    let preciseRecord = try WireEventRecord(
      envelope: submillisecond,
      nowOnOriginClockNanoseconds: 1_100_000_000
    )
    guard case .object(let preciseBody) = try preciseRecord.jsonValue() else {
      return XCTFail("Expected an event object.")
    }
    XCTAssertEqual(preciseBody["createdAt"], .string("2023-11-14T22:13:20.123456Z"))
    let preciseDecoded = try WireMessageCodec.decode(
      WireEventPayload.self,
      from: WireMessage(version: .v1, type: .event, body: .object(preciseBody))
    )
    XCTAssertEqual(preciseDecoded.record.envelope.createdAt, submillisecond.createdAt)
  }

  func testBatchSequenceOverflowIsRejectedBeforeEncoding() throws {
    let records = try [UInt64.max - 1, UInt64.max].map { sequence in
      try WireEventRecord(
        envelope: makeWireTestEvent(sequence: sequence),
        nowOnOriginClockNanoseconds: 1_100_000_000
      )
    }
    XCTAssertNoThrow(try WireEventBatchPayload(records: records))

    let overflowing = try WireEventRecord(
      envelope: makeWireTestEvent(sequence: 0),
      nowOnOriginClockNanoseconds: 1_100_000_000
    )
    assertWireError(.arithmeticOverflow) {
      _ = try WireEventBatchPayload(records: records + [overflowing])
    }
  }
}
