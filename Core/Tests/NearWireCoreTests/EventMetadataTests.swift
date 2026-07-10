import Foundation
import XCTest

@testable import NearWireCore

final class EventMetadataTests: XCTestCase {
  func testEventTypeNamespacesAndGrammar() throws {
    XCTAssertEqual(
      try EventType.user("business.order.stateChanged").rawValue,
      "business.order.stateChanged"
    )
    XCTAssertEqual(
      try EventType.platform("nearwire.performance.snapshot").rawValue,
      "nearwire.performance.snapshot"
    )

    for invalid in ["", ".event", "event.", "a..b", "1event", "a b", "évent", "a/b"] {
      assertEventError(.invalidType) {
        _ = try EventType.user(invalid)
      }
    }
    assertEventError(.invalidType) {
      _ = try EventType.user("a" + String(repeating: "b", count: 128))
    }
    assertEventError(.invalidLimits, expectedPath: "maximumTypeBytes") {
      _ = try EventValidationLimits(maximumTypeBytes: 129)
    }
    assertEventError(.reservedType) {
      _ = try EventType.user("nearwire.performance.snapshot")
    }
    assertEventError(.reservedType) {
      _ = try EventType.platform("business.event")
    }
  }

  func testCanonicalUUIDIdentifiers() throws {
    let value = "123e4567-e89b-12d3-a456-426614174000"
    XCTAssertEqual(try EventID(rawValue: value).rawValue, value)
    XCTAssertEqual(try SessionEpoch(rawValue: value).rawValue, value)
    let generatedEventID = EventID().rawValue
    XCTAssertEqual(generatedEventID, generatedEventID.lowercased())
    XCTAssertNotNil(UUID(uuidString: SessionEpoch().rawValue))

    for invalid in [value.uppercased(), "", "not-a-uuid", "{\(value)}"] {
      assertEventError(.invalidIdentifier) {
        _ = try EventID(rawValue: invalid)
      }
    }
  }

  func testEndpointIdentifiersAndDirectionRoles() throws {
    let app = try makeEndpoint(.app, id: "app.device-1")
    let viewer = try makeEndpoint(.viewer, id: "viewer_1")
    try EventDirection.appToViewer.validate(source: app, target: viewer)

    for invalid in ["", "with space", "slash/value", String(repeating: "a", count: 129)] {
      assertEventError(.invalidIdentifier) {
        _ = try EndpointID(rawValue: invalid)
      }
    }
    assertEventError(.invalidDirection) {
      try EventDirection.appToViewer.validate(source: viewer, target: app)
    }
    assertEventError(.invalidDirection) {
      try EventDirection.viewerToApp.validate(source: app, target: viewer)
    }
  }

  func testTTLDefaultsBoundsAndOverflowSafeExpiration() throws {
    XCTAssertEqual(EventTTL.default.milliseconds, 60_000)
    let ttl = try EventTTL(milliseconds: 2)
    XCTAssertFalse(
      try ttl.isExpired(
        createdAtNanoseconds: 10,
        nowOnCreationClockNanoseconds: 2_000_009
      )
    )
    XCTAssertTrue(
      try ttl.isExpired(
        createdAtNanoseconds: 10,
        nowOnCreationClockNanoseconds: 2_000_010
      )
    )

    assertEventError(.invalidTTL) {
      _ = try EventTTL(milliseconds: 0)
    }
    assertEventError(.invalidTTL) {
      _ = try EventTTL(milliseconds: EventValidationLimits.default.maximumTTLMilliseconds + 1)
    }
    assertEventError(.invalidTTL) {
      _ = try ttl.isExpired(
        createdAtNanoseconds: UInt64.max,
        nowOnCreationClockNanoseconds: UInt64.max
      )
    }
  }

  func testSchemaSequenceAndCausalityRoundTrip() throws {
    let correlation = try EventID(rawValue: "123e4567-e89b-12d3-a456-426614174000")
    let reply = try EventID(rawValue: "123e4567-e89b-12d3-a456-426614174001")
    let causality = EventCausality(correlationID: correlation, replyTo: reply)
    let encoded = try JSONEncoder().encode(causality)

    XCTAssertEqual(try JSONDecoder().decode(EventCausality.self, from: encoded), causality)
    XCTAssertEqual(EventSchemaVersion.current.rawValue, 1)
    XCTAssertEqual(EventSequence(UInt64.max).rawValue, UInt64.max)
    assertEventError(.invalidSchemaVersion) {
      _ = try EventSchemaVersion(0)
    }
    XCTAssertEqual(EventCausality(correlationID: correlation).correlationID, correlation)
    XCTAssertNil(EventCausality(correlationID: correlation).replyTo)
  }
}
