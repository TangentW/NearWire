import XCTest

@_spi(NearWireInternal) @testable import NearWireCore
@_spi(NearWireInternal) @testable import NearWireTransport

final class WireNegotiationTests: XCTestCase {
  func testHighestVersionConservativeLimitAndCapabilityIntersection() throws {
    let app = try makeHello(
      role: .app,
      minimum: 1,
      maximum: 2,
      maximumEventBytes: 256 * 1_024,
      capabilities: [.bidirectionalEvents, .normalQueue, .keepLatest]
    )
    let viewerLimits = try WireProtocolLimits(maximumEventBytes: 1_024 * 1_024)
    let viewer = try makeHello(
      role: .viewer,
      minimum: 1,
      maximum: 3,
      maximumEventBytes: 1_024 * 1_024,
      capabilities: [.bidirectionalEvents, .normalQueue, .batching],
      limits: viewerLimits
    )

    let result = try WireNegotiator.negotiate(local: app, remote: viewer)

    XCTAssertEqual(result.selectedVersion.rawValue, 2)
    XCTAssertEqual(result.selectedCodec, .json)
    XCTAssertEqual(result.maximumEventBytes, 256 * 1_024)
    XCTAssertEqual(result.capabilities, [.bidirectionalEvents, .normalQueue])
    XCTAssertEqual(result.sendPolicies, [.normal, .keepLatest])
  }

  func testProductVersionsAreDiagnosticAndUnknownCapabilitiesIntersectExactly() throws {
    let future = try WireCapability("future-observation")
    let local = try makeHello(
      role: .app,
      maximum: 2,
      capabilities: [.normalQueue, future],
      productVersion: "99.0"
    )
    let remote = try makeHello(
      role: .viewer,
      maximum: 3,
      capabilities: [.normalQueue, future],
      productVersion: "0.1"
    )

    let result = try WireNegotiator.negotiate(local: local, remote: remote)

    XCTAssertEqual(result.selectedVersion.rawValue, 2)
    XCTAssertEqual(result.capabilities, [.normalQueue, future])
  }

  func testIncompatibleVersionRoleCodecAndPolicyFail() throws {
    let appV1 = try makeHello(role: .app)
    let viewerV2 = try makeHello(role: .viewer, minimum: 2, maximum: 2)
    assertWireError(.incompatibleVersion) {
      _ = try WireNegotiator.negotiate(local: appV1, remote: viewerV2)
    }
    assertWireError(.invalidRole) {
      _ = try WireNegotiator.negotiate(local: appV1, remote: appV1)
    }

    let otherCodec = try WireCodecIdentifier("future")
    let viewerWithoutJSON = try makeHello(role: .viewer, codecs: [otherCodec])
    assertWireError(.noCommonCodec) {
      _ = try WireNegotiator.negotiate(local: appV1, remote: viewerWithoutJSON)
    }

    let noNormal = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .viewer,
      installationID: EndpointID(rawValue: "viewer"),
      sendPolicies: [.keepLatest]
    )
    assertWireError(.invalidPolicy) {
      _ = try WireNegotiator.negotiate(local: appV1, remote: noNormal)
    }
  }

  func testAcknowledgementCannotEscalateNegotiatedValues() throws {
    let result = try WireNegotiator.negotiate(
      local: makeHello(role: .app),
      remote: makeHello(role: .viewer)
    )
    let viewerID = try EndpointID(rawValue: "viewer-installation")
    let epoch = try SessionEpoch(rawValue: "123e4567-e89b-12d3-a456-426614174000")
    let valid = try WireNegotiator.makeAcknowledgement(
      result: result,
      sessionEpoch: epoch
    )
    XCTAssertNoThrow(try WireNegotiator.validate(acknowledgement: valid, against: result))

    let escalated = try WireHelloAcknowledgement(
      selectedVersion: result.selectedVersion,
      selectedCodec: result.selectedCodec,
      maximumEventBytes: result.maximumEventBytes,
      capabilities: result.capabilities.union([.batching]),
      sendPolicies: result.sendPolicies,
      viewerInstallationID: viewerID,
      sessionEpoch: epoch
    )
    assertWireError(.acknowledgementEscalation) {
      try WireNegotiator.validate(acknowledgement: escalated, against: result)
    }

    let wrongViewer = try WireHelloAcknowledgement(
      selectedVersion: result.selectedVersion,
      selectedCodec: result.selectedCodec,
      maximumEventBytes: result.maximumEventBytes,
      capabilities: result.capabilities,
      sendPolicies: result.sendPolicies,
      viewerInstallationID: EndpointID(rawValue: "different-viewer"),
      sessionEpoch: epoch
    )
    assertWireError(.acknowledgementEscalation) {
      try WireNegotiator.validate(acknowledgement: wrongViewer, against: result)
    }

    let changedVersion = try WireHelloAcknowledgement(
      selectedVersion: WireProtocolVersion(2),
      selectedCodec: result.selectedCodec,
      maximumEventBytes: result.maximumEventBytes,
      capabilities: result.capabilities,
      sendPolicies: result.sendPolicies,
      viewerInstallationID: viewerID,
      sessionEpoch: epoch
    )
    let changedCodec = try WireHelloAcknowledgement(
      selectedVersion: result.selectedVersion,
      selectedCodec: WireCodecIdentifier("future"),
      maximumEventBytes: result.maximumEventBytes,
      capabilities: result.capabilities,
      sendPolicies: result.sendPolicies,
      viewerInstallationID: viewerID,
      sessionEpoch: epoch
    )
    let changedSize = try WireHelloAcknowledgement(
      selectedVersion: result.selectedVersion,
      selectedCodec: result.selectedCodec,
      maximumEventBytes: result.maximumEventBytes - 1,
      capabilities: result.capabilities,
      sendPolicies: result.sendPolicies,
      viewerInstallationID: viewerID,
      sessionEpoch: epoch
    )
    let changedPolicies = try WireHelloAcknowledgement(
      selectedVersion: result.selectedVersion,
      selectedCodec: result.selectedCodec,
      maximumEventBytes: result.maximumEventBytes,
      capabilities: result.capabilities,
      sendPolicies: [.normal],
      viewerInstallationID: viewerID,
      sessionEpoch: epoch
    )
    for acknowledgement in [changedVersion, changedCodec, changedSize, changedPolicies] {
      assertWireError(.acknowledgementEscalation) {
        try WireNegotiator.validate(acknowledgement: acknowledgement, against: result)
      }
    }
  }

  func testSequenceCounterValidatorGapDuplicateDirectionAndEpoch() throws {
    let epoch = try SessionEpoch(rawValue: "123e4567-e89b-12d3-a456-426614174000")
    var counter = WireSequenceCounter(sessionEpoch: epoch, direction: .appToViewer)
    XCTAssertEqual(try counter.allocate().rawValue, 0)
    XCTAssertEqual(try counter.allocate().rawValue, 1)

    var validator = WireSequenceValidator(sessionEpoch: epoch, direction: .appToViewer)
    try validator.validate(makeWireTestEvent(sequence: 0))
    assertWireError(.invalidSequence) {
      try validator.validate(makeWireTestEvent(sequence: 0))
    }
    assertWireError(.invalidSequence) {
      try validator.validate(makeWireTestEvent(sequence: 2))
    }
    assertWireError(.invalidSequence) {
      try validator.validate(makeWireTestEvent(sequence: 1, direction: .viewerToApp))
    }
    assertWireError(.invalidSequence) {
      try validator.validate(
        makeWireTestEvent(
          sequence: 1,
          sessionEpoch: "123e4567-e89b-12d3-a456-426614174001"
        )
      )
    }
    try validator.validate(makeWireTestEvent(sequence: 1))

    let newEpoch = try SessionEpoch(rawValue: "123e4567-e89b-12d3-a456-426614174001")
    var reconnected = WireSequenceValidator(
      sessionEpoch: newEpoch,
      direction: .appToViewer
    )
    XCTAssertNoThrow(
      try reconnected.validate(
        makeWireTestEvent(sequence: 0, sessionEpoch: newEpoch.rawValue)
      )
    )
  }

  func testSequenceMaximumCanBeAllocatedAndValidatedOnce() throws {
    let epoch = try SessionEpoch(rawValue: "123e4567-e89b-12d3-a456-426614174000")
    var counter = WireSequenceCounter(
      sessionEpoch: epoch,
      direction: .appToViewer,
      uncheckedStartingAt: UInt64.max
    )
    XCTAssertEqual(try counter.allocate().rawValue, UInt64.max)
    assertWireError(.arithmeticOverflow) { _ = try counter.allocate() }

    var validator = WireSequenceValidator(
      sessionEpoch: epoch,
      direction: .appToViewer,
      uncheckedStartingAt: UInt64.max
    )
    try validator.validate(makeWireTestEvent(sequence: UInt64.max))
    assertWireError(.arithmeticOverflow) {
      try validator.validate(makeWireTestEvent(sequence: UInt64.max))
    }
  }
}
