import Foundation
import XCTest

@_spi(NearWireInternal) @testable import NearWireCore

final class EventEnvelopeTests: XCTestCase {
  func testDraftCodableRoundTripUsesCompactContentAndCustomLimits() throws {
    let permissive = try EventValidationLimits(maximumTTLMilliseconds: 172_800_000)
    let correlation = try EventID(rawValue: "123e4567-e89b-12d3-a456-426614174000")
    let replyTo = try EventID(rawValue: "123e4567-e89b-12d3-a456-426614174001")
    let draft = try EventDraft(
      type: EventType.user("business.draft"),
      content: .object(["value": .number(1)]),
      priority: .high,
      ttl: EventTTL(milliseconds: 172_800_000, limits: permissive),
      causality: EventCausality(correlationID: correlation, replyTo: replyTo),
      limits: permissive
    )
    let data = try JSONEncoder().encode(draft)

    XCTAssertEqual(try EventDraft.decode(from: data, limits: permissive), draft)
    assertEventError(.invalidTTL) {
      _ = try EventDraft.decode(from: data)
    }
  }

  func testFactoryDeterministicallyEnrichesDraft() throws {
    let fixedID = try EventID(rawValue: "123e4567-e89b-12d3-a456-426614174000")
    let epoch = try SessionEpoch(rawValue: "123e4567-e89b-12d3-a456-426614174001")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let draft = try EventDraft(
      type: EventType.user("business.order.changed"),
      content: .object(["state": .string("paid")]),
      priority: .high,
      ttl: EventTTL(milliseconds: 5_000),
      causality: EventCausality(correlationID: fixedID)
    )
    let context = try EventEnvelopeContext(
      source: makeEndpoint(.app, id: "app-1"),
      target: makeEndpoint(.viewer, id: "viewer-1"),
      direction: .appToViewer,
      sessionEpoch: epoch,
      sequence: EventSequence(42)
    )
    let factory = EventEnvelopeFactory(
      wallClock: { date },
      monotonicClock: { 900 },
      identifierGenerator: { fixedID }
    )

    let envelope = try factory.makeEnvelope(from: draft, context: context)
    XCTAssertEqual(envelope.id, fixedID)
    XCTAssertEqual(envelope.type, draft.type)
    XCTAssertEqual(envelope.content, draft.content)
    XCTAssertEqual(envelope.priority, draft.priority)
    XCTAssertEqual(envelope.ttl, draft.ttl)
    XCTAssertEqual(envelope.causality, draft.causality)
    XCTAssertEqual(envelope.createdAt, date)
    XCTAssertEqual(envelope.monotonicTimestampNanoseconds, 900)
    XCTAssertEqual(envelope.sequence.rawValue, 42)
    XCTAssertEqual(envelope.schemaVersion, .current)
  }

  func testEnvelopeRoundTripAndUnknownFieldCompatibility() throws {
    let envelope = try makeEnvelope()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let original = try encoder.encode(envelope)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: original) as? [String: Any]
    )
    object["futureField"] = ["enabled": true]
    let withUnknownField = try JSONSerialization.data(withJSONObject: object)

    XCTAssertEqual(try JSONDecoder().decode(EventEnvelope.self, from: original), envelope)
    XCTAssertEqual(try JSONDecoder().decode(EventEnvelope.self, from: withUnknownField), envelope)
  }

  func testMissingRequiredFieldFailsWithTypedEnvelopeError() throws {
    let data = try JSONEncoder().encode(makeEnvelope())
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "source")
    let incomplete = try JSONSerialization.data(withJSONObject: object)

    assertEventError(.invalidEnvelope) {
      _ = try JSONDecoder().decode(EventEnvelope.self, from: incomplete)
    }
  }

  func testAggregateDecodeAppliesOneCustomLimitSet() throws {
    let permissive = try EventValidationLimits(maximumTTLMilliseconds: 172_800_000)
    let envelope = try makeEnvelope(ttlMilliseconds: 172_800_000, limits: permissive)
    let data = try JSONEncoder().encode(envelope)

    XCTAssertEqual(try EventEnvelope.decode(from: data, limits: permissive), envelope)
    assertEventError(.invalidTTL) {
      _ = try EventEnvelope.decode(from: data)
    }

    let strictType = try EventValidationLimits(maximumTypeBytes: 8)
    assertEventError(.invalidType) {
      _ = try EventEnvelope.decode(from: data, limits: strictType)
    }
  }

  func testAggregateDecodeBoundsUnknownBytesAndTaggedDepthBeforeMaterialization() throws {
    let envelope = try makeEnvelope()
    let encoded = try JSONEncoder().encode(envelope)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["ignored"] = String(repeating: "x", count: 150_000)
    let oversized = try JSONSerialization.data(withJSONObject: object)
    let smallModel = try EventValidationLimits(
      maximumEncodedContentBytes: 1_024,
      maximumEncodedModelBytes: 131_072
    )
    assertEventError(.encodedContentTooLarge) {
      _ = try EventEnvelope.decode(from: oversized, limits: smallModel)
    }

    var nested: Any = ["kind": "integer", "value": 1]
    for _ in 0..<20 {
      nested = ["kind": "array", "value": [nested]]
    }
    object.removeValue(forKey: "ignored")
    object["content"] = nested
    let excessiveDepth = try JSONSerialization.data(withJSONObject: object)
    let shallow = try EventValidationLimits(maximumContentDepth: 2)
    assertEventError(.structuralLimitExceeded) {
      _ = try EventEnvelope.decode(from: excessiveDepth, limits: shallow)
    }
  }

  func testNearContentLimitCompactTaggedEnvelopeRoundTrips() throws {
    let inner = JSONValue.array(Array(repeating: .integer(0), count: 4_096))
    let content = JSONValue.array(Array(repeating: inner, count: 31))
    let plainByteCount = try content.deterministicData().count
    XCTAssertEqual(plainByteCount, 254_015)

    let envelope = try makeEnvelope(content: content)
    let encoded = try JSONEncoder().encode(envelope)
    XCTAssertLessThanOrEqual(encoded.count, EventValidationLimits.default.maximumEncodedModelBytes)
    XCTAssertEqual(try EventEnvelope.decode(from: encoded), envelope)
  }

  func testEnvelopeRejectsDirectionAndTimestampInvariants() throws {
    let valid = try makeEnvelope()
    assertEventError(.invalidDirection) {
      _ = try EventEnvelope(
        id: valid.id,
        type: valid.type,
        content: valid.content,
        createdAt: valid.createdAt,
        monotonicTimestampNanoseconds: 0,
        source: valid.target,
        target: valid.source,
        direction: .appToViewer,
        sessionEpoch: valid.sessionEpoch,
        sequence: valid.sequence,
        priority: valid.priority,
        ttl: valid.ttl,
        causality: valid.causality
      )
    }
    assertEventError(.invalidTimestamp) {
      _ = try EventEnvelope(
        id: valid.id,
        type: valid.type,
        content: valid.content,
        createdAt: Date(timeIntervalSinceReferenceDate: .infinity),
        monotonicTimestampNanoseconds: 0,
        source: valid.source,
        target: valid.target,
        direction: valid.direction,
        sessionEpoch: valid.sessionEpoch,
        sequence: valid.sequence,
        priority: valid.priority,
        ttl: valid.ttl,
        causality: valid.causality
      )
    }
  }

  private func makeEnvelope(
    monotonicTimestampNanoseconds: UInt64 = 100,
    ttlMilliseconds: UInt64 = 60_000,
    limits: EventValidationLimits = .default,
    content: JSONValue = .object(["value": .number(1)])
  ) throws -> EventEnvelope {
    try EventEnvelope(
      id: EventID(rawValue: "123e4567-e89b-12d3-a456-426614174000"),
      type: EventType.user("business.event"),
      content: content,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      monotonicTimestampNanoseconds: monotonicTimestampNanoseconds,
      source: makeEndpoint(.app, id: "app-1"),
      target: makeEndpoint(.viewer, id: "viewer-1"),
      direction: .appToViewer,
      sessionEpoch: SessionEpoch(rawValue: "123e4567-e89b-12d3-a456-426614174001"),
      sequence: EventSequence(1),
      priority: .normal,
      ttl: EventTTL(milliseconds: ttlMilliseconds, limits: limits),
      causality: EventCausality(),
      limits: limits
    )
  }
}
