import Foundation
import XCTest

@_spi(NearWireInternal) @testable import NearWireCore
@_spi(NearWireInternal) @testable import NearWireTransport

final class WireEventTests: XCTestCase {
  func testRecordPrecomputesCanonicalContentAndCarriesItToReceiverAdmission() throws {
    let content = JSONValue.object([
      "nested": .array([.string("precomputed-content"), .integer(42)])
    ])
    let record = try WireEventRecord(
      envelope: makeWireTestEvent(content: content),
      nowOnOriginClockNanoseconds: 1_250_000_000
    )
    let canonicalContent = try content.deterministicData()
    XCTAssertEqual(record.canonicalContentData, canonicalContent)
    XCTAssertEqual(
      record.precomputedDeterministicEncodedByteCount,
      try record.jsonValue().deterministicData().count
    )
    XCTAssertEqual(
      try record.deterministicEncodedByteCount(),
      record.precomputedDeterministicEncodedByteCount
    )

    let received = try record.receiverEvent(receivedAtNanoseconds: 2_000_000_000)
    XCTAssertEqual(received.canonicalContentData, canonicalContent)
    XCTAssertEqual(
      received.deterministicEncodedByteCount,
      record.precomputedDeterministicEncodedByteCount
    )
  }

  func testEventWireCarrierReflectionIsContentFree() throws {
    let secret = "nearwire-wire-secret"
    let envelope = try makeWireTestEvent(content: .object(["secret": .string(secret)]))
    let record = try WireEventRecord(
      envelope: envelope,
      nowOnOriginClockNanoseconds: 1_250_000_000
    )
    let payload = WireEventPayload(record: record)
    let batch = try WireEventBatchPayload(records: [record])
    let encoded = try WireMessageCodec.encode(payload, version: .v1)
    var frame: WireFrame?
    var decoder = WireFrameDecoder()
    try decoder.consume(encoded) { frame = $0 }
    let decodedFrame = try XCTUnwrap(frame)
    let message = try WireMessage.decode(from: decodedFrame)

    let app = try makeHello(role: .app)
    let viewer = try makeHello(role: .viewer)
    let codec = try WireSessionCodec(
      negotiation: WireNegotiator.negotiate(local: app, remote: viewer)
    )
    let admitted = try codec.decode(frame: decodedFrame, phase: .active)

    for value: Any in [record, payload, batch, decodedFrame, decoder, message, admitted] {
      XCTAssertFalse(String(describing: value).contains(secret))
      XCTAssertFalse(String(reflecting: value).contains(secret))
      XCTAssertFalse(
        Mirror(reflecting: value).children.contains {
          String(reflecting: $0.value).contains(secret)
        }
      )
    }
  }

  func testMaximumEventRecordBoundCoversAdversarialProductionEncodings() throws {
    let maximum = try WireEventRecord.maximumDeterministicEncodedByteCount()
    let values: [JSONValue] = [
      .null,
      .bool(true),
      .integer(Int64.min),
      .number(-Double.greatestFiniteMagnitude),
      .string(String(repeating: "\\\"/\u{0008}", count: 1_000)),
      .array((0..<4_096).map { .integer(Int64($0)) }),
      .object(
        Dictionary(
          uniqueKeysWithValues: (0..<4_096).map {
            ("key-\($0)", JSONValue.string("value-é-\($0)"))
          })
      ),
    ]

    for content in values {
      do {
        try content.validate()
      } catch {
        continue
      }
      let record = try maximumShapeRecord(content: content)
      XCTAssertLessThanOrEqual(try record.deterministicEncodedByteCount(), maximum)
    }

    let exactContent = maximumSizedContent()
    XCTAssertEqual(
      WireDateCodec.format(Date(timeIntervalSince1970: 0.123_456_789)),
      "1970-01-01T00:00:00.1234568Z"
    )
    try exactContent.validate()
    XCTAssertEqual(
      try exactContent.deterministicData().count,
      EventValidationLimits.default.maximumEncodedContentBytes
    )
    XCTAssertEqual(
      try maximumShapeRecord(content: exactContent).deterministicEncodedByteCount(),
      maximum
    )
  }

  func testMaximumEventRecordBoundCoversSeededGeneratedContentShapes() throws {
    let maximum = try WireEventRecord.maximumDeterministicEncodedByteCount()
    var generator = SeededJSONValueGenerator(seed: 0x4E65_6172_5769_7265)

    for _ in 0..<256 {
      let content = generator.next(depth: 3)
      try content.validate()
      let record = try maximumShapeRecord(content: content)
      XCTAssertLessThanOrEqual(try record.deterministicEncodedByteCount(), maximum)
    }
  }

  func testMaximumRecordTraversesProductionSessionCodecAtExactBoundary() throws {
    let maximumRecordBytes = try WireEventRecord.maximumDeterministicEncodedByteCount()
    let sizingFrameLimits = try WireFrameLimits(
      maximumControlPayloadBytes: WireFrameLimits.default.maximumControlPayloadBytes,
      maximumEventPayloadBytes: WireFrameLimits.hardMaximumPayloadBytes
    )
    let maximumFrameBytes = try WireSessionCodec.maximumEncodedV1SingleEventFrameBytes(
      maximumEventBytes: maximumRecordBytes,
      frameLimits: sizingFrameLimits
    )
    let exactFrameLimits = try WireFrameLimits(
      maximumControlPayloadBytes: WireFrameLimits.default.maximumControlPayloadBytes,
      maximumEventPayloadBytes: maximumFrameBytes - WireFrameLimits.encodedFrameOverheadBytes
    )
    let exactWireLimits = try WireProtocolLimits(
      frame: exactFrameLimits,
      maximumEventBytes: maximumRecordBytes
    )
    let app = try makeHello(
      role: .app,
      maximumEventBytes: maximumRecordBytes,
      limits: exactWireLimits
    )
    let viewer = try makeHello(
      role: .viewer,
      maximumEventBytes: maximumRecordBytes,
      limits: exactWireLimits
    )
    let codec = try WireSessionCodec(
      negotiation: WireNegotiator.negotiate(local: app, remote: viewer),
      baseLimits: exactWireLimits
    )
    let record = try maximumShapeRecord(content: maximumSizedContent())
    let encoded = try codec.encode(WireEventPayload(record: record), phase: .active)
    XCTAssertEqual(encoded.count, maximumFrameBytes)

    var decodedRecords = 0
    var decoder = WireFrameDecoder(limits: exactFrameLimits)
    try decoder.consume(encoded) { frame in
      let admitted = try codec.decode(frame: frame, phase: .active)
      let payload = try codec.decode(WireEventPayload.self, from: admitted)
      XCTAssertEqual(payload.record, record)
      decodedRecords += 1
    }
    XCTAssertEqual(decodedRecords, 1)

    let oneUnderWireLimits = try WireProtocolLimits(
      frame: exactFrameLimits,
      maximumEventBytes: maximumRecordBytes - 1
    )
    let oneUnderApp = try makeHello(
      role: .app,
      maximumEventBytes: maximumRecordBytes - 1,
      limits: oneUnderWireLimits
    )
    let oneUnderViewer = try makeHello(
      role: .viewer,
      maximumEventBytes: maximumRecordBytes - 1,
      limits: oneUnderWireLimits
    )
    let oneUnderCodec = try WireSessionCodec(
      negotiation: WireNegotiator.negotiate(local: oneUnderApp, remote: oneUnderViewer),
      baseLimits: oneUnderWireLimits
    )
    assertWireError(.frameTooLarge) {
      _ = try oneUnderCodec.encode(WireEventPayload(record: record), phase: .active)
    }

    let oneUnderFrameLimits = try WireFrameLimits(
      maximumControlPayloadBytes: WireFrameLimits.default.maximumControlPayloadBytes,
      maximumEventPayloadBytes: exactFrameLimits.maximumEventPayloadBytes - 1
    )
    assertWireError(.invalidConfiguration) {
      _ = try WireSessionCodec.maximumEncodedV1SingleEventFrameBytes(
        maximumEventBytes: maximumRecordBytes,
        frameLimits: oneUnderFrameLimits
      )
    }
  }

  func testMaximumSingleEventFrameIncludesMessageAndFrameWrappers() throws {
    let maximumEventBytes = 1_024
    let app = try makeHello(role: .app, maximumEventBytes: maximumEventBytes)
    let viewer = try makeHello(role: .viewer, maximumEventBytes: maximumEventBytes)
    let codec = try WireSessionCodec(
      negotiation: WireNegotiator.negotiate(local: app, remote: viewer)
    )
    let record = try WireEventRecord(
      envelope: makeWireTestEvent(),
      nowOnOriginClockNanoseconds: 1_250_000_000
    )
    let recordBytes = try record.deterministicEncodedByteCount()
    let actualFrameBytes = try codec.encode(WireEventPayload(record: record), phase: .active).count
    let wrapperBytes = actualFrameBytes - recordBytes

    XCTAssertGreaterThan(wrapperBytes, WireFrameLimits.encodedFrameOverheadBytes)
    XCTAssertEqual(
      try codec.maximumEncodedSingleEventFrameBytes(),
      maximumEventBytes + wrapperBytes
    )
  }

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

private struct SeededJSONValueGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next(depth: Int) -> JSONValue {
    let kind = depth == 0 ? Int(draw() % 5) : Int(draw() % 7)
    switch kind {
    case 0:
      return .null
    case 1:
      return .bool(draw() & 1 == 0)
    case 2:
      return .integer(Int64(bitPattern: draw()))
    case 3:
      let sign = draw() & 1 == 0 ? 1.0 : -1.0
      return .number(sign * Double(draw() % 1_000_000) / 100.0)
    case 4:
      let fragments = [
        "plain", "\\\"escaped", "é", "combining-e\u{301}", "\n", "emoji-🙂",
      ]
      return .string(fragments[Int(draw() % UInt64(fragments.count))])
    case 5:
      return .array((0..<Int(draw() % 7)).map { _ in next(depth: depth - 1) })
    default:
      let count = Int(draw() % 7)
      return .object(
        Dictionary(
          uniqueKeysWithValues: (0..<count).map { index in
            ("key-\(index)-\(draw() % 17)", next(depth: depth - 1))
          }
        )
      )
    }
  }

  private mutating func draw() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

private func maximumSizedContent() -> JSONValue {
  .array([
    .string(String(repeating: "x", count: 65_536)),
    .string(String(repeating: "y", count: 65_536)),
    .string(String(repeating: "z", count: 65_536)),
    .string(String(repeating: "w", count: 65_523)),
  ])
}

private func maximumShapeRecord(content: JSONValue) throws -> WireEventRecord {
  let maximumUUID = "ffffffff-ffff-4fff-bfff-ffffffffffff"
  let endpoint = EventEndpoint(
    role: .app,
    id: try EndpointID(rawValue: String(repeating: "z", count: 128))
  )
  let target = EventEndpoint(
    role: .viewer,
    id: try EndpointID(rawValue: String(repeating: "z", count: 128))
  )
  let limits = EventValidationLimits.default
  let ttl = try EventTTL(milliseconds: limits.maximumTTLMilliseconds)
  let envelope = try EventEnvelope(
    id: try EventID(rawValue: maximumUUID),
    type: try EventType.user(String(repeating: "a", count: limits.maximumTypeBytes)),
    content: content,
    createdAt: Date(timeIntervalSince1970: 0.123_456_789),
    monotonicTimestampNanoseconds: UInt64.max - ttl.milliseconds * 1_000_000,
    source: endpoint,
    target: target,
    direction: .appToViewer,
    sessionEpoch: try SessionEpoch(rawValue: maximumUUID),
    sequence: EventSequence(UInt64.max),
    priority: .critical,
    ttl: ttl,
    causality: EventCausality(
      correlationID: try EventID(rawValue: maximumUUID),
      replyTo: try EventID(rawValue: maximumUUID)
    ),
    schemaVersion: try EventSchemaVersion(UInt16.max)
  )
  return try WireEventRecord(
    envelope: envelope,
    remainingTTLNanoseconds: ttl.milliseconds * 1_000_000
  )
}
