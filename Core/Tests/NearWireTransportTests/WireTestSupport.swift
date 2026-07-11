import Foundation
import XCTest

@testable import NearWireCore
@testable import NearWireTransport

func assertWireError(
  _ code: WireProtocolError.Code,
  file: StaticString = #filePath,
  line: UInt = #line,
  _ operation: () throws -> Void
) {
  XCTAssertThrowsError(try operation(), file: file, line: line) { error in
    guard let wireError = error as? WireProtocolError else {
      return XCTFail("Expected WireProtocolError, received \(error).", file: file, line: line)
    }
    XCTAssertEqual(wireError.code, code, file: file, line: line)
  }
}

func makeWireTestEvent(
  sequence: UInt64 = 0,
  direction: EventDirection = .appToViewer,
  sessionEpoch: String = "123e4567-e89b-12d3-a456-426614174000",
  content: JSONValue = .object(["value": .integer(1)]),
  ttlMilliseconds: UInt64 = 1_000,
  monotonicTimestampNanoseconds: UInt64 = 1_000_000_000,
  createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000.123)
) throws -> EventEnvelope {
  let app = EventEndpoint(
    role: .app,
    id: try EndpointID(rawValue: "phone-installation")
  )
  let viewer = EventEndpoint(
    role: .viewer,
    id: try EndpointID(rawValue: "viewer-installation")
  )
  let source = direction == .appToViewer ? app : viewer
  let target = direction == .appToViewer ? viewer : app
  let idSuffix = sequence % 1_000_000_000_000
  return try EventEnvelope(
    id: EventID(rawValue: String(format: "123e4567-e89b-12d3-a456-%012llu", idSuffix)),
    type: .user("app.test.event"),
    content: content,
    createdAt: createdAt,
    monotonicTimestampNanoseconds: monotonicTimestampNanoseconds,
    source: source,
    target: target,
    direction: direction,
    sessionEpoch: SessionEpoch(rawValue: sessionEpoch),
    sequence: EventSequence(sequence),
    priority: .normal,
    ttl: EventTTL(milliseconds: ttlMilliseconds),
    causality: EventCausality()
  )
}

func makeHello(
  role: EndpointRole,
  minimum: UInt16 = 1,
  maximum: UInt16 = 1,
  maximumEventBytes: Int = 256 * 1_024,
  codecs: Set<WireCodecIdentifier> = [.json],
  capabilities: Set<WireCapability> = [.bidirectionalEvents, .normalQueue],
  productVersion: String = "1.2.0",
  limits: WireProtocolLimits = .default
) throws -> WireHello {
  try WireHello(
    versions: WireVersionRange(
      minimum: WireProtocolVersion(minimum),
      maximum: WireProtocolVersion(maximum)
    ),
    productVersion: WireProductVersion(productVersion),
    role: role,
    installationID: EndpointID(
      rawValue: role == .app ? "phone-installation" : "viewer-installation"
    ),
    codecs: codecs,
    maximumEventBytes: maximumEventBytes,
    sendPolicies: [.normal, .keepLatest],
    capabilities: capabilities,
    displayName: role == .app ? "Demo App" : "NearWire Viewer",
    applicationIdentifier: role == .app ? "com.example.demo" : nil,
    applicationVersion: role == .app ? "42" : nil,
    limits: limits
  )
}
