import Foundation
@_spi(NearWireInternal) import NearWireCore
import Network
import Security
import XCTest

@testable import NearWire
@_spi(NearWireInternal) @testable import NearWireTransport

final class SDKSessionAdmissionTests: XCTestCase {
  func testHappyPathPreservesCoalescedPolicyAcrossAttachment() async throws {
    let fixture = try SessionAdmissionFixture()
    let task = Task { try await fixture.admission.run() }

    await fixture.driver.waitUntilStarted()
    fixture.driver.emitState(.ready)
    await fixture.driver.waitForReceive()
    await sdkWaitUntil { fixture.driver.sentData.count == 1 }

    let remoteHelloBytes = try WirePreHandshakeCodec().encode(fixture.viewerHello)
    let split = remoteHelloBytes.index(
      remoteHelloBytes.startIndex,
      offsetBy: remoteHelloBytes.count / 2
    )
    fixture.driver.completeReceive(Data(remoteHelloBytes[..<split]))
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(Data(remoteHelloBytes[split...]))
    await fixture.driver.waitForReceive()

    let policy = try WireFlowPolicy(
      appUplinkEventsPerSecond: 40,
      appDownlinkEventsPerSecond: 20
    )
    let acknowledgement = try fixture.sessionCodec.encode(
      fixture.acknowledgement,
      phase: .awaitingApproval
    )
    let offer = try fixture.sessionCodec.encode(
      WireFlowPolicyOffer(policy: policy),
      phase: .negotiatingPolicy
    )
    fixture.driver.completeReceive(acknowledgement + offer)

    let admitted = try await task.value
    XCTAssertEqual(admitted.route.sessionEpoch, fixture.sessionUUID)
    XCTAssertEqual(admitted.route.viewerID, "viewer-installation")
    XCTAssertEqual(admitted.route.appID, "phone-installation")
    XCTAssertEqual(admitted.capabilities, fixture.negotiation.capabilities)
    XCTAssertEqual(admitted.sendPolicies, fixture.negotiation.sendPolicies)
    XCTAssertEqual(admitted.maximumEventBytes, fixture.negotiation.maximumEventBytes)
    XCTAssertEqual(fixture.driver.sentData, [try WirePreHandshakeCodec().encode(fixture.appHello)])

    let attachment = try await admitted.attachEventPump()
    let nextPolicy = try await attachment.nextPolicyMessage()
    XCTAssertEqual(nextPolicy, .offer(WireFlowPolicyOffer(policy: policy)))
    attachment.cancel()
  }

  func testLocalRoleAndOutboundCapacityFailBeforeDiscovery() async throws {
    let pairingCode = try PairingCode("ABC234")
    let viewerHello = try makeSessionHello(role: .viewer)
    let discovery = SessionTestDiscovery(result: try makeDiscoveredViewer(viewerHello: viewerHello))
    let counters = SessionDependencyCounters()
    let transportLimits = try SecureTransportLimits(
      receiveChunkBytes: 64,
      maximumPendingSendCount: 2,
      maximumPendingSendBytes: 64,
      maximumSingleSendBytes: 32,
      connectionTimeoutSeconds: 1
    )
    let dependencies = SDKSessionAdmissionDependencies(
      makeDiscovery: { _ in
        counters.recordDiscovery()
        return discovery
      },
      makeChannel: { _, _ in
        counters.recordChannel()
        return SecureByteChannel(driver: SessionSecureDriver()) { _ in }
      },
      sleep: sessionTestSleep
    )

    let wrongRole = SDKSessionAdmission(
      pairingCode: pairingCode,
      localHello: viewerHello,
      transportLimits: transportLimits,
      dependencies: dependencies
    )
    await assertAdmissionError(.invalidLocalConfiguration) {
      _ = try await wrongRole.run()
    }

    let undersized = SDKSessionAdmission(
      pairingCode: pairingCode,
      localHello: try makeSessionHello(role: .app),
      transportLimits: transportLimits,
      dependencies: dependencies
    )
    await assertAdmissionError(.invalidLocalConfiguration) {
      _ = try await undersized.run()
    }
    XCTAssertEqual(counters.discoveryCount, 0)
    XCTAssertEqual(counters.channelCount, 0)
  }

  func testCancelBeforeRunAndSecondRunAreDeterministic() async throws {
    let fixture = try SessionAdmissionFixture()
    await fixture.admission.cancel()
    await assertAdmissionError(.cancelled) {
      _ = try await fixture.admission.run()
    }
    await assertAdmissionError(.cancelled) {
      _ = try await fixture.admission.run()
    }
    XCTAssertFalse(fixture.driver.isStarted)
  }

  func testViewerIdentityMismatchFailsAndCancelsChannel() async throws {
    let fixture = try SessionAdmissionFixture(
      advertisedViewerID: "different-viewer-installation"
    )
    let task = Task { try await fixture.admission.run() }
    await fixture.driver.waitUntilStarted()
    fixture.driver.emitState(.ready)
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))

    await assertAdmissionError(.viewerIdentityMismatch) {
      _ = try await task.value
    }
    await sdkWaitUntil { fixture.driver.cancelCount == 1 }
    XCTAssertEqual(fixture.driver.cancelCount, 1)
  }

  func testIngressBoundsTerminalPriorityAndSingleDrain() {
    let callbacks = SessionDependencyCounters()
    let ingress = SDKSessionChannelIngress(maximumEvents: 2, maximumReceiveBytes: 4)
    ingress.installDrain { callbacks.recordDrain() }
    ingress.submit(.channel(.received(Data([1, 2, 3]))))
    ingress.submit(.channel(.received(Data([4, 5]))))
    ingress.submit(.channel(.stateChanged(.ready)))

    XCTAssertEqual(callbacks.drainCount, 1)
    XCTAssertEqual(ingress.retainedCounts, .init(events: 0, receiveBytes: 0))
    guard case .overflow? = ingress.latchedTerminal else {
      return XCTFail("Expected overflow terminal.")
    }

    let terminalIngress = SDKSessionChannelIngress(maximumEvents: 4, maximumReceiveBytes: 8)
    terminalIngress.submit(.channel(.received(Data([1, 2, 3]))))
    terminalIngress.submit(
      .channel(
        .terminated(
          SecureTransportError(
            code: .driverFailure,
            message: "private-network-text",
            disposition: .connectionTerminal
          )
        )
      )
    )
    let batch = terminalIngress.takeBatch(maximumItems: 8)
    XCTAssertEqual(batch?.count, 1)
    if case .channel(.terminated)? = batch?.first {
    } else {
      XCTFail("Expected terminal to replace queued bytes.")
    }
  }

  func testErrorCodesAndHandlesHaveClosedRedactedDiagnostics() async throws {
    let hostile = "ABC234 viewer-installation private-endpoint secret-content"
    for code in SDKSessionAdmissionError.Code.allCases {
      let error = SDKSessionAdmissionError(code)
      XCTAssertFalse(error.description.contains(hostile))
      XCTAssertEqual(error.customMirror.children.count, 1)
      XCTAssertEqual(error.code, code)
    }

    let fixture = try SessionAdmissionFixture()
    let task = Task { try await fixture.admission.run() }
    await fixture.driver.waitUntilStarted()
    fixture.driver.emitState(.ready)
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(fixture.acknowledgement, phase: .awaitingApproval)
    )
    let admitted = try await task.value
    XCTAssertEqual(admitted.description, "<redacted-admitted-session>")
    XCTAssertEqual(admitted.customMirror.children.count, 0)
    let attachment = try await admitted.attachEventPump()
    XCTAssertEqual(attachment.description, "<redacted-session-pump-attachment>")
    XCTAssertEqual(attachment.customMirror.children.count, 0)
    attachment.cancel()
  }

  func testPullCancellationGateLatchesBeforeAndAfterRegistration() {
    let first = SDKSessionPullCancellationGate()
    first.cancel()
    XCTAssertFalse(first.claim(notification: {}))

    let callbackCount = SessionDependencyCounters()
    let second = SDKSessionPullCancellationGate()
    XCTAssertTrue(second.claim { callbackCount.recordDrain() })
    second.cancel()
    second.cancel()
    XCTAssertEqual(callbackCount.drainCount, 1)
    second.close()
  }

  func testDiscoverySecureAndAttachmentDeadlinesMapExactly() async throws {
    let pairingCode = try PairingCode("ABC234")
    let appHello = try makeSessionHello(role: .app)
    let viewerHello = try makeSessionHello(role: .viewer)
    let discovered = try makeDiscoveredViewer(viewerHello: viewerHello)

    do {
      let clock = SessionDeadlineController()
      let discovery = SessionControlledDiscovery()
      let counters = SessionDependencyCounters()
      let dependencies = SDKSessionAdmissionDependencies(
        makeDiscovery: { _ in discovery },
        makeChannel: { _, _ in
          counters.recordChannel()
          return SecureByteChannel(driver: SessionSecureDriver()) { _ in }
        },
        sleep: { seconds in try await clock.sleep(seconds: seconds) }
      )
      let admission = SDKSessionAdmission(
        pairingCode: pairingCode,
        localHello: appHello,
        dependencies: dependencies
      )
      let task = Task { try await admission.run() }
      await discovery.waitUntilRunning()
      await clock.waitForRequest(seconds: 30)
      clock.fire(seconds: 30)
      await assertAdmissionError(.discoveryTimedOut) { _ = try await task.value }
      XCTAssertEqual(discovery.cancelCount, 1)
      XCTAssertEqual(counters.channelCount, 0)
    }

    do {
      let clock = SessionDeadlineController()
      let driver = SessionSecureDriver()
      let discovery = SessionTestDiscovery(result: discovered)
      let transportLimits = try SecureTransportLimits(connectionTimeoutSeconds: 1)
      let dependencies = SDKSessionAdmissionDependencies(
        makeDiscovery: { _ in discovery },
        makeChannel: { _, handler in
          SecureByteChannel(driver: driver, limits: transportLimits, eventHandler: handler)
        },
        sleep: { seconds in try await clock.sleep(seconds: seconds) }
      )
      let admission = SDKSessionAdmission(
        pairingCode: pairingCode,
        localHello: appHello,
        transportLimits: transportLimits,
        dependencies: dependencies
      )
      let task = Task { try await admission.run() }
      await driver.waitUntilStarted()
      await clock.waitForRequest(seconds: 15)
      clock.fire(seconds: 15)
      await assertAdmissionError(.secureAdmissionTimedOut) { _ = try await task.value }
      await sdkWaitUntil { driver.cancelCount == 1 }
      XCTAssertEqual(driver.cancelCount, 1)
    }

    do {
      let clock = SessionDeadlineController()
      let driver = SessionSecureDriver()
      let discovery = SessionTestDiscovery(result: discovered)
      let transportLimits = try SecureTransportLimits(connectionTimeoutSeconds: 1)
      let dependencies = SDKSessionAdmissionDependencies(
        makeDiscovery: { _ in discovery },
        makeChannel: { _, handler in
          SecureByteChannel(driver: driver, limits: transportLimits, eventHandler: handler)
        },
        sleep: { seconds in try await clock.sleep(seconds: seconds) }
      )
      let admission = SDKSessionAdmission(
        pairingCode: pairingCode,
        localHello: appHello,
        transportLimits: transportLimits,
        dependencies: dependencies
      )
      let task = Task { try await admission.run() }
      await driver.waitUntilStarted()
      driver.emitState(.ready)
      await driver.waitForReceive()
      driver.completeReceive(try WirePreHandshakeCodec().encode(viewerHello))
      await driver.waitForReceive()
      let negotiation = try WireNegotiator.negotiate(local: appHello, remote: viewerHello)
      let codec = try WireSessionCodec(negotiation: negotiation)
      let acknowledgement = try WireNegotiator.makeAcknowledgement(
        result: negotiation,
        sessionEpoch: SessionEpoch(rawValue: "123e4567-e89b-12d3-a456-426614174000")
      )
      driver.completeReceive(try codec.encode(acknowledgement, phase: .awaitingApproval))
      let admitted = try await task.value
      await clock.waitForRequest(seconds: 5)
      clock.fire(seconds: 5)
      await sdkWaitUntil { driver.cancelCount == 1 }
      await assertAdmissionError(.pumpAttachmentTimedOut) {
        _ = try await admitted.attachEventPump()
      }
      XCTAssertEqual(driver.cancelCount, 1)
    }
  }

  func testAwaitingApprovalPingAndTerminalSuffixBehaveExactly() async throws {
    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      let ping = try fixture.sessionCodec.encode(WirePing(nonce: 42), phase: .awaitingApproval)
      fixture.driver.completeReceive(ping)
      await sdkWaitUntil { fixture.driver.sentData.count == 2 }

      var decoder = WireFrameDecoder()
      var pongFrame: WireFrame?
      try decoder.consume(fixture.driver.sentData[1], onFrame: { pongFrame = $0 })
      let admittedPong = try fixture.sessionCodec.decode(
        frame: XCTUnwrap(pongFrame),
        phase: .awaitingApproval
      )
      XCTAssertEqual(
        try fixture.sessionCodec.decode(WirePong.self, from: admittedPong),
        WirePong(nonce: 42)
      )

      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(fixture.acknowledgement, phase: .awaitingApproval)
      )
      let admitted = try await task.value
      admitted.cancel()
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      let acknowledgement = try fixture.sessionCodec.encode(
        fixture.acknowledgement,
        phase: .awaitingApproval
      )
      let disconnect = try fixture.sessionCodec.encode(
        WireDisconnect(code: "viewer-closing", reason: "private hostile reason"),
        phase: .negotiatingPolicy
      )
      fixture.driver.completeReceive(acknowledgement + disconnect)
      await assertAdmissionError(.remoteClosed) { _ = try await task.value }
    }
  }

  func testRejectionEarlyEventAndMalformedFrameUseClosedErrors() async throws {
    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      let rejection = try fixture.sessionCodec.encode(
        WireConnectionRejected(code: "private-code", message: "hostile rejection text"),
        phase: .awaitingApproval
      )
      fixture.driver.completeReceive(rejection)
      await assertAdmissionError(.viewerRejected) { _ = try await task.value }
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      let eventHeader = Data([0, 0, 0, 10, WireLane.event.rawValue])
      fixture.driver.completeReceive(eventHeader)
      await assertAdmissionError(.protocolViolation) { _ = try await task.value }
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(Data([0, 0, 0, 1]))
      await assertAdmissionError(.protocolViolation) { _ = try await task.value }
    }
  }

  func testPolicyPullImmediatePendingConcurrentCancellationAndTerminalPrecedence() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let core = attachment.transportCore

    let pending = Task { try await attachment.nextPolicyMessage() }
    await sessionWaitUntil { await core.snapshot().hasPendingPolicyPull }
    await assertAdmissionError(.pullAlreadyPending) {
      _ = try await attachment.nextPolicyMessage()
    }

    let preCancelledGate = SDKSessionPullCancellationGate()
    preCancelledGate.cancel()
    await assertAdmissionError(.pullCancelled) {
      _ = try await core.nextPolicyMessage(cancellationGate: preCancelledGate)
    }
    let afterPreCancelled = await core.snapshot()
    XCTAssertTrue(afterPreCancelled.hasPendingPolicyPull)

    pending.cancel()
    await assertAdmissionError(.pullCancelled) { _ = try await pending.value }
    let afterPendingCancellation = await core.snapshot()
    XCTAssertFalse(afterPendingCancellation.hasPendingPolicyPull)

    await fixture.driver.waitForReceive()
    let policy = try WireFlowPolicy(
      appUplinkEventsPerSecond: 12,
      appDownlinkEventsPerSecond: 8
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(policy: policy),
        phase: .negotiatingPolicy
      )
    )
    await sessionWaitUntil { await core.snapshot().retainedPolicyMessages == 1 }

    let cancelledWithFIFO = SDKSessionPullCancellationGate()
    cancelledWithFIFO.cancel()
    await assertAdmissionError(.pullCancelled) {
      _ = try await core.nextPolicyMessage(cancellationGate: cancelledWithFIFO)
    }
    let afterCancelledFIFO = await core.snapshot()
    XCTAssertEqual(afterCancelledFIFO.retainedPolicyMessages, 1)
    let immediate = try await attachment.nextPolicyMessage()
    XCTAssertEqual(immediate, .offer(WireFlowPolicyOffer(policy: policy)))

    let terminalPending = Task { try await attachment.nextPolicyMessage() }
    await sessionWaitUntil { await core.snapshot().hasPendingPolicyPull }
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireDisconnect(code: "viewer-closed"),
        phase: .negotiatingPolicy
      )
    )
    await assertAdmissionError(.remoteClosed) { _ = try await terminalPending.value }
    let terminalSnapshot = await core.snapshot()
    XCTAssertEqual(terminalSnapshot.terminalCode, .remoteClosed)

    let cancelledWithTerminal = SDKSessionPullCancellationGate()
    cancelledWithTerminal.cancel()
    await assertAdmissionError(.pullCancelled) {
      _ = try await core.nextPolicyMessage(cancellationGate: cancelledWithTerminal)
    }
    await assertAdmissionError(.remoteClosed) {
      _ = try await attachment.nextPolicyMessage()
    }
  }

  func testAttachmentAndExternalHandleOwnershipCancelExactlyOnce() async throws {
    let fixture = try SessionAdmissionFixture()
    var admitted: SDKAdmittedSession? = try await fixture.admit()
    var attachment: SDKSessionPumpAttachment? = try await admitted?.attachEventPump()
    let weakCore = SessionWeakCore(attachment?.transportCore)

    await assertAdmissionError(.alreadyAttached) {
      _ = try await admitted?.attachEventPump()
    }
    admitted = nil
    XCTAssertNotNil(weakCore.value)
    XCTAssertEqual(fixture.driver.cancelCount, 0)
    attachment = nil
    await sdkWaitUntil { fixture.driver.cancelCount == 1 }
    XCTAssertEqual(fixture.driver.cancelCount, 1)
    await sdkWaitUntil { weakCore.value == nil }
    XCTAssertNil(weakCore.value)
  }

  func testHandshakeHandoffAndBacklogCumulativeLimitsAreTerminal() async throws {
    do {
      let limits = try SDKSessionAdmissionLimits(maximumHandshakeWorkItems: 2)
      let fixture = try SessionAdmissionFixture(admissionLimits: limits)
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(WirePing(nonce: 1), phase: .awaitingApproval)
      )
      await assertAdmissionError(.handshakeWorkLimitExceeded) { _ = try await task.value }
    }

    do {
      let limits = try SDKSessionAdmissionLimits(
        maximumHandoffWorkItems: 2,
        maximumHandoffMessages: 2
      )
      let fixture = try SessionAdmissionFixture(admissionLimits: limits)
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      let acknowledgement = try fixture.sessionCodec.encode(
        fixture.acknowledgement,
        phase: .awaitingApproval
      )
      let firstPing = try fixture.sessionCodec.encode(
        WirePing(nonce: 1),
        phase: .negotiatingPolicy
      )
      let secondPing = try fixture.sessionCodec.encode(
        WirePing(nonce: 2),
        phase: .negotiatingPolicy
      )
      fixture.driver.completeReceive(acknowledgement + firstPing + secondPing)
      await assertAdmissionError(.handoffWorkLimitExceeded) { _ = try await task.value }
    }

    do {
      let limits = try SDKSessionAdmissionLimits(
        maximumHandoffMessages: 1,
        maximumHandoffBytes: 256 * 1_024
      )
      let fixture = try SessionAdmissionFixture(admissionLimits: limits)
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      let policy = try WireFlowPolicy(
        appUplinkEventsPerSecond: 10,
        appDownlinkEventsPerSecond: 10
      )
      let acknowledgement = try fixture.sessionCodec.encode(
        fixture.acknowledgement,
        phase: .awaitingApproval
      )
      let offer = try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(policy: policy),
        phase: .negotiatingPolicy
      )
      fixture.driver.completeReceive(acknowledgement + offer + offer)
      await assertAdmissionError(.handoffBufferOverflow) { _ = try await task.value }
    }
  }

  func testLimitTableAndEveryCrossLimitRelationshipAreValidated() throws {
    let defaults = SDKSessionAdmissionLimits.default
    XCTAssertEqual(defaults.discoveryTimeoutSeconds, 30)
    XCTAssertEqual(defaults.secureAdmissionTimeoutSeconds, 15)
    XCTAssertEqual(defaults.pumpAttachmentTimeoutSeconds, 5)
    XCTAssertEqual(defaults.maximumIngressEvents, 64)
    XCTAssertEqual(defaults.maximumIngressBytes, 256 * 1_024)
    XCTAssertEqual(defaults.maximumHandshakeWorkItems, 32)
    XCTAssertEqual(defaults.maximumHandshakeWorkBytes, 256 * 1_024)
    XCTAssertEqual(defaults.maximumHandoffWorkItems, 64)
    XCTAssertEqual(defaults.maximumHandoffWorkBytes, 512 * 1_024)
    XCTAssertEqual(defaults.maximumHandoffMessages, 32)
    XCTAssertEqual(defaults.maximumHandoffBytes, 256 * 1_024)

    XCTAssertNoThrow(
      try SDKSessionAdmissionLimits(
        discoveryTimeoutSeconds: 120,
        secureAdmissionTimeoutSeconds: 120,
        pumpAttachmentTimeoutSeconds: 30,
        maximumIngressEvents: 256,
        maximumIngressBytes: 1_048_576,
        maximumHandshakeWorkItems: 128,
        maximumHandshakeWorkBytes: 1_048_576,
        maximumHandoffWorkItems: 256,
        maximumHandoffWorkBytes: 1_048_576,
        maximumHandoffMessages: 128,
        maximumHandoffBytes: 1_048_576
      )
    )
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(discoveryTimeoutSeconds: 0))
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(secureAdmissionTimeoutSeconds: 121))
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(pumpAttachmentTimeoutSeconds: 31))
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(maximumIngressEvents: 257))
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(maximumIngressBytes: 0))
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(maximumHandshakeWorkItems: 129))
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(maximumHandshakeWorkBytes: 0))
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(maximumHandoffWorkItems: 257))
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(maximumHandoffWorkBytes: 0))
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(maximumHandoffMessages: 129))
    XCTAssertThrowsError(try SDKSessionAdmissionLimits(maximumHandoffBytes: 0))
    XCTAssertThrowsError(
      try SDKSessionAdmissionLimits(
        maximumHandoffWorkItems: 1,
        maximumHandoffMessages: 2
      )
    )
    XCTAssertThrowsError(
      try SDKSessionAdmissionLimits(
        maximumHandoffWorkBytes: 1,
        maximumHandoffBytes: 2
      )
    )

    let wireLimits = WireProtocolLimits.default
    let helloBytes = try WirePreHandshakeCodec(limits: wireLimits).encode(
      makeSessionHello(role: .app)
    )
    let pongBytes = try WireSessionCodec.encodeMaximumV1Pong(limits: wireLimits)
    let validTransport = try SecureTransportLimits(connectionTimeoutSeconds: 10)
    XCTAssertNoThrow(
      try defaults.validate(
        wireLimits: wireLimits,
        transportLimits: validTransport,
        encodedHelloByteCount: helloBytes.count,
        encodedMaximumPongByteCount: pongBytes.count
      )
    )

    func rejects(
      _ limits: SDKSessionAdmissionLimits = .default,
      transport: SecureTransportLimits,
      hello: Int? = nil,
      pong: Int? = nil
    ) {
      XCTAssertThrowsError(
        try limits.validate(
          wireLimits: wireLimits,
          transportLimits: transport,
          encodedHelloByteCount: hello ?? helloBytes.count,
          encodedMaximumPongByteCount: pong ?? pongBytes.count
        )
      )
    }

    rejects(
      try SDKSessionAdmissionLimits(secureAdmissionTimeoutSeconds: 9),
      transport: validTransport
    )
    rejects(
      transport: try SecureTransportLimits(
        receiveChunkBytes: defaults.maximumIngressBytes + 1,
        connectionTimeoutSeconds: 10
      )
    )
    rejects(
      try SDKSessionAdmissionLimits(maximumHandshakeWorkBytes: 1),
      transport: validTransport
    )
    rejects(
      try SDKSessionAdmissionLimits(
        maximumHandoffWorkBytes: 1,
        maximumHandoffBytes: 1
      ),
      transport: validTransport
    )
    rejects(
      transport: try SecureTransportLimits(
        maximumPendingSendCount: 1,
        connectionTimeoutSeconds: 10
      )
    )
    rejects(
      transport: try SecureTransportLimits(
        maximumPendingSendBytes: helloBytes.count + pongBytes.count - 1,
        maximumSingleSendBytes: max(helloBytes.count, pongBytes.count),
        connectionTimeoutSeconds: 10
      )
    )
    rejects(transport: validTransport, hello: 0)
    rejects(
      transport: try SecureTransportLimits(
        maximumPendingSendBytes: 1_024,
        maximumSingleSendBytes: max(1, helloBytes.count - 1),
        connectionTimeoutSeconds: 10
      )
    )
  }

  func testWrongRoleAndAcknowledgementEscalationAreMappedWithoutPeerText() async throws {
    do {
      let appHello = try makeSessionHello(role: .app)
      let remoteAppHello = try makeSessionHello(
        role: .app,
        installationID: "remote-app-installation"
      )
      let driver = SessionSecureDriver()
      let discovery = SessionTestDiscovery(
        result: try makeDiscoveredViewer(viewerHello: remoteAppHello)
      )
      let transportLimits = try SecureTransportLimits(connectionTimeoutSeconds: 1)
      let admission = SDKSessionAdmission(
        pairingCode: try PairingCode("ABC234"),
        localHello: appHello,
        transportLimits: transportLimits,
        dependencies: SDKSessionAdmissionDependencies(
          makeDiscovery: { _ in discovery },
          makeChannel: { _, handler in
            SecureByteChannel(
              driver: driver,
              limits: transportLimits,
              eventHandler: handler
            )
          },
          sleep: sessionTestSleep
        )
      )
      let task = Task { try await admission.run() }
      await driver.waitUntilStarted()
      driver.emitState(.ready)
      await driver.waitForReceive()
      driver.completeReceive(try WirePreHandshakeCodec().encode(remoteAppHello))
      await assertAdmissionError(.incompatiblePeer) { _ = try await task.value }
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      let escalated = try WireHelloAcknowledgement(
        selectedVersion: fixture.negotiation.selectedVersion,
        selectedCodec: fixture.negotiation.selectedCodec,
        maximumEventBytes: fixture.negotiation.maximumEventBytes - 1,
        capabilities: fixture.negotiation.capabilities,
        sendPolicies: fixture.negotiation.sendPolicies,
        viewerInstallationID: fixture.negotiation.viewerInstallationID,
        sessionEpoch: SessionEpoch(rawValue: fixture.sessionUUID.uuidString.lowercased())
      )
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(escalated, phase: .awaitingApproval)
      )
      await assertAdmissionError(.protocolViolation) { _ = try await task.value }
    }
  }

  func testExhaustiveAcknowledgementAndMalformedControlMatrix() async throws {
    func assertApprovalFailure(
      frame: (SessionAdmissionFixture) throws -> Data
    ) async throws {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try frame(fixture))
      await assertAdmissionError(.protocolViolation) { _ = try await task.value }
    }

    let baseline = try SessionAdmissionFixture()
    let negotiation = baseline.negotiation
    let epoch = try SessionEpoch(rawValue: baseline.sessionUUID.uuidString.lowercased())
    let acknowledgementMutations = [
      try WireHelloAcknowledgement(
        selectedVersion: WireProtocolVersion(2),
        selectedCodec: negotiation.selectedCodec,
        maximumEventBytes: negotiation.maximumEventBytes,
        capabilities: negotiation.capabilities,
        sendPolicies: negotiation.sendPolicies,
        viewerInstallationID: negotiation.viewerInstallationID,
        sessionEpoch: epoch
      ),
      try WireHelloAcknowledgement(
        selectedVersion: negotiation.selectedVersion,
        selectedCodec: WireCodecIdentifier("cbor"),
        maximumEventBytes: negotiation.maximumEventBytes,
        capabilities: negotiation.capabilities,
        sendPolicies: negotiation.sendPolicies,
        viewerInstallationID: negotiation.viewerInstallationID,
        sessionEpoch: epoch
      ),
      try WireHelloAcknowledgement(
        selectedVersion: negotiation.selectedVersion,
        selectedCodec: negotiation.selectedCodec,
        maximumEventBytes: negotiation.maximumEventBytes - 1,
        capabilities: negotiation.capabilities,
        sendPolicies: negotiation.sendPolicies,
        viewerInstallationID: negotiation.viewerInstallationID,
        sessionEpoch: epoch
      ),
      try WireHelloAcknowledgement(
        selectedVersion: negotiation.selectedVersion,
        selectedCodec: negotiation.selectedCodec,
        maximumEventBytes: negotiation.maximumEventBytes,
        capabilities: Set(negotiation.capabilities.dropFirst()),
        sendPolicies: negotiation.sendPolicies,
        viewerInstallationID: negotiation.viewerInstallationID,
        sessionEpoch: epoch
      ),
      try WireHelloAcknowledgement(
        selectedVersion: negotiation.selectedVersion,
        selectedCodec: negotiation.selectedCodec,
        maximumEventBytes: negotiation.maximumEventBytes,
        capabilities: negotiation.capabilities,
        sendPolicies: [.normal],
        viewerInstallationID: negotiation.viewerInstallationID,
        sessionEpoch: epoch
      ),
      try WireHelloAcknowledgement(
        selectedVersion: negotiation.selectedVersion,
        selectedCodec: negotiation.selectedCodec,
        maximumEventBytes: negotiation.maximumEventBytes,
        capabilities: negotiation.capabilities,
        sendPolicies: negotiation.sendPolicies,
        viewerInstallationID: EndpointID(rawValue: "substituted-viewer"),
        sessionEpoch: epoch
      ),
    ]
    for acknowledgement in acknowledgementMutations {
      try await assertApprovalFailure { fixture in
        try fixture.sessionCodec.encode(acknowledgement, phase: .awaitingApproval)
      }
    }

    try await assertApprovalFailure { fixture in
      let valid = try fixture.sessionCodec.encode(
        fixture.acknowledgement,
        phase: .awaitingApproval
      )
      let original = Data(fixture.sessionUUID.uuidString.lowercased().utf8)
      let invalid = Data(String(repeating: "x", count: original.count).utf8)
      var mutated = valid
      let range = try XCTUnwrap(mutated.range(of: original))
      mutated.replaceSubrange(range, with: invalid)
      return mutated
    }
    try await assertApprovalFailure { _ in
      try WireFrameEncoder.encode(
        lane: .control,
        payload: Data(#"{"body":{},"type":"future.control","version":1}"#.utf8)
      )
    }
    try await assertApprovalFailure { _ in
      try WireFrameEncoder.encode(lane: .control, payload: Data("{".utf8))
    }
    try await assertApprovalFailure { _ in
      try WireFrameEncoder.encode(
        lane: .control,
        payload: Data(
          #"{"body":{"nonce":"hostile"},"type":"ping","version":1}"#.utf8
        )
      )
    }
    try await assertApprovalFailure { _ in
      Data([0, 1, 0, 2, WireLane.control.rawValue])
    }
  }

  func testGenuineSecondRunReturnsAlreadyStarted() async throws {
    let fixture = try SessionAdmissionFixture()
    let first = Task { try await fixture.admission.run() }
    await fixture.driver.waitUntilStarted()
    await assertAdmissionError(.alreadyStarted) {
      _ = try await fixture.admission.run()
    }
    first.cancel()
    await assertAdmissionError(.cancelled) { _ = try await first.value }
  }

  func testTaskCancellationBeforeRunDuringDiscoveryAndAfterTransferIsExact() async throws {
    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task<SDKAdmittedSession, Error> {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await fixture.admission.run()
      }
      await assertAdmissionError(.cancelled) { _ = try await task.value }
      XCTAssertFalse(fixture.driver.isStarted)
    }

    do {
      let discovery = SessionControlledDiscovery()
      let counters = SessionDependencyCounters()
      let admission = SDKSessionAdmission(
        pairingCode: try PairingCode("ABC234"),
        localHello: try makeSessionHello(role: .app),
        dependencies: SDKSessionAdmissionDependencies(
          makeDiscovery: { _ in discovery },
          makeChannel: { _, _ in
            counters.recordChannel()
            return SecureByteChannel(driver: SessionSecureDriver()) { _ in }
          },
          sleep: sessionTestSleep
        )
      )
      let task = Task { try await admission.run() }
      await discovery.waitUntilRunning()
      task.cancel()
      await assertAdmissionError(.cancelled) { _ = try await task.value }
      XCTAssertEqual(discovery.cancelCount, 1)
      XCTAssertEqual(counters.channelCount, 0)
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      task.cancel()
      await assertAdmissionError(.cancelled) { _ = try await task.value }
      await sdkWaitUntil { fixture.driver.cancelCount == 1 }
      XCTAssertEqual(fixture.driver.cancelCount, 1)
    }
  }

  func testAdmissionDoesNotClaimLeaseOrMutateNearWireFacadeState() async throws {
    let sdk = NearWire()
    let initialState = await sdk.currentState
    XCTAssertEqual(initialState, .idle)
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let finalState = await sdk.currentState
    XCTAssertEqual(finalState, .idle)

    let lease = try ProcessConnectionLeaseRegistry.claim()
    lease.release()
    admitted.cancel()
  }

  func testReleasingAdmissionActorAfterSuccessPreservesPermanentCallbackOwner() async throws {
    let appHello = try makeSessionHello(role: .app)
    let viewerHello = try makeSessionHello(role: .viewer)
    let negotiation = try WireNegotiator.negotiate(local: appHello, remote: viewerHello)
    let codec = try WireSessionCodec(negotiation: negotiation)
    let acknowledgement = try WireNegotiator.makeAcknowledgement(
      result: negotiation,
      sessionEpoch: SessionEpoch(rawValue: "123e4567-e89b-12d3-a456-426614174000")
    )
    let driver = SessionSecureDriver()
    let discovered = try makeDiscoveredViewer(viewerHello: viewerHello)
    let transportLimits = try SecureTransportLimits(connectionTimeoutSeconds: 1)
    var admission: SDKSessionAdmission? = SDKSessionAdmission(
      pairingCode: try PairingCode("ABC234"),
      localHello: appHello,
      transportLimits: transportLimits,
      dependencies: SDKSessionAdmissionDependencies(
        makeDiscovery: { _ in
          SessionTestDiscovery(result: discovered)
        },
        makeChannel: { _, handler in
          SecureByteChannel(
            driver: driver,
            limits: transportLimits,
            eventHandler: handler
          )
        },
        sleep: sessionTestSleep
      )
    )
    let task: Task<SDKAdmittedSession, Error>
    do {
      let runningAdmission = admission!
      task = Task { try await runningAdmission.run() }
    }
    await driver.waitUntilStarted()
    driver.emitState(.ready)
    await driver.waitForReceive()
    driver.completeReceive(try WirePreHandshakeCodec().encode(viewerHello))
    await driver.waitForReceive()
    driver.completeReceive(try codec.encode(acknowledgement, phase: .awaitingApproval))
    let admitted = try await task.value
    admission = nil

    let attachment = try await admitted.attachEventPump()
    await driver.waitForReceive()
    let policy = try WireFlowPolicy(
      appUplinkEventsPerSecond: 3,
      appDownlinkEventsPerSecond: 2
    )
    driver.completeReceive(
      try codec.encode(WireFlowPolicyAccepted(policy: policy), phase: .negotiatingPolicy)
    )
    let received = try await attachment.nextPolicyMessage()
    XCTAssertEqual(received, .accepted(WireFlowPolicyAccepted(policy: policy)))
    attachment.cancel()
  }

  func testLiveDependenciesConstructTheReviewedSecureAppChannel() async throws {
    let transportLimits = try SecureTransportLimits(
      receiveChunkBytes: 32 * 1_024,
      connectionTimeoutSeconds: 3
    )
    let dependencies = SDKSessionAdmissionDependencies.live(
      connectionQueue: DispatchQueue(label: "nearwire.tests.session.live-connection"),
      verificationQueue: DispatchQueue(label: "nearwire.tests.session.live-verification"),
      transportLimits: transportLimits
    )
    let discovered = try makeDiscoveredViewer(
      viewerHello: makeSessionHello(role: .viewer)
    )
    let channel = dependencies.makeChannel(discovered) { _ in }

    let state = await channel.state
    let installedLimits = await channel.limits
    XCTAssertEqual(state, .setup)
    XCTAssertEqual(installedLimits, transportLimits)
  }

  func testEveryDiscoveryCategoryAndUnexpectedTransportFailureMapSafely() async throws {
    let mappings: [(ViewerDiscoveryError.Code, SDKSessionAdmissionError.Code)] = [
      (.permissionOrPolicyDenied, .discoveryDenied),
      (.unavailableNetwork, .discoveryUnavailable),
      (.ambiguous, .discoveryAmbiguous),
      (.resultLimitExceeded, .discoveryFailed),
      (.browserFailure, .discoveryFailed),
      (.alreadyStarted, .discoveryFailed),
      (.cancelled, .discoveryFailed),
    ]
    for (source, expected) in mappings {
      let discovery = SessionTestDiscovery(error: ViewerDiscoveryError(source))
      let admission = SDKSessionAdmission(
        pairingCode: try PairingCode("ABC234"),
        localHello: try makeSessionHello(role: .app),
        dependencies: SDKSessionAdmissionDependencies(
          makeDiscovery: { _ in discovery },
          makeChannel: { _, _ in
            XCTFail("A failed discovery must not construct a channel.")
            return SecureByteChannel(driver: SessionSecureDriver()) { _ in }
          },
          sleep: sessionTestSleep
        )
      )
      await assertAdmissionError(expected) { _ = try await admission.run() }
    }

    let fixture = try SessionAdmissionFixture()
    let task = Task { try await fixture.admission.run() }
    await fixture.driver.waitUntilStarted()
    fixture.driver.emitState(.failed)
    await assertAdmissionError(.transportFailed) { _ = try await task.value }
    XCTAssertEqual(fixture.driver.cancelCount, 1)
  }

  func testRemoteErrorDuplicateHelloAndPolicyBeforeAcknowledgementAreTerminal() async throws {
    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(
        try WirePreHandshakeCodec().encode(
          WireErrorPayload(
            code: "private-error",
            message: "hostile private peer content",
            isFatal: false
          )
        )
      )
      await assertAdmissionError(.remoteClosed) { _ = try await task.value }
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      let hello = try WirePreHandshakeCodec().encode(fixture.viewerHello)
      fixture.driver.completeReceive(hello)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(hello)
      await assertAdmissionError(.protocolViolation) { _ = try await task.value }
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      let policy = try WireFlowPolicy(
        appUplinkEventsPerSecond: 1,
        appDownlinkEventsPerSecond: 1
      )
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(
          WireFlowPolicyOffer(policy: policy),
          phase: .negotiatingPolicy
        )
      )
      await assertAdmissionError(.protocolViolation) { _ = try await task.value }
    }
  }

  func testIngressOverflowAndStaleAttemptTokenCannotProducePartialOrLateFailure() async throws {
    do {
      let appHello = try makeSessionHello(role: .app)
      let viewerHello = try makeSessionHello(role: .viewer)
      let ingress = SDKSessionChannelIngress(maximumEvents: 1, maximumReceiveBytes: 1)
      let driver = SessionSecureDriver()
      let channel = SecureByteChannel(driver: driver) { event in
        ingress.submit(.channel(event))
      }
      let token = SDKSessionAttemptToken()
      let core = SDKSessionTransportCore(
        ingress: ingress,
        localHello: appHello,
        localHelloBytes: try WirePreHandshakeCodec().encode(appHello),
        discoveredDiscriminator: ViewerDiscoveryDiscriminator(
          viewerInstallationID: viewerHello.installationID
        ),
        attemptToken: token,
        wireLimits: .default,
        admissionLimits: .default,
        sleep: sessionTestSleep
      )
      try await core.bind(channel: channel)
      ingress.installDrain { [weak core] in Task { await core?.drainIngress() } }
      let task = Task { try await core.run(attemptToken: token) }
      await driver.waitUntilStarted()
      ingress.submit(.channel(.received(Data([1, 2]))))
      await assertAdmissionError(.ingressOverflow) { _ = try await task.value }
    }

    do {
      let appHello = try makeSessionHello(role: .app)
      let viewerHello = try makeSessionHello(role: .viewer)
      let ingress = SDKSessionChannelIngress(maximumEvents: 64, maximumReceiveBytes: 256 * 1_024)
      let driver = SessionSecureDriver()
      let channel = SecureByteChannel(driver: driver) { event in
        ingress.submit(.channel(event))
      }
      let token = SDKSessionAttemptToken()
      let core = SDKSessionTransportCore(
        ingress: ingress,
        localHello: appHello,
        localHelloBytes: try WirePreHandshakeCodec().encode(appHello),
        discoveredDiscriminator: ViewerDiscoveryDiscriminator(
          viewerInstallationID: viewerHello.installationID
        ),
        attemptToken: token,
        wireLimits: .default,
        admissionLimits: .default,
        sleep: sessionTestSleep
      )
      try await core.bind(channel: channel)
      ingress.installDrain { [weak core] in Task { await core?.drainIngress() } }
      let task = Task { try await core.run(attemptToken: token) }
      await driver.waitUntilStarted()
      driver.emitState(.ready)
      await driver.waitForReceive()
      driver.completeReceive(try WirePreHandshakeCodec().encode(viewerHello))
      await driver.waitForReceive()
      let negotiation = try WireNegotiator.negotiate(local: appHello, remote: viewerHello)
      let codec = try WireSessionCodec(negotiation: negotiation)
      let acknowledgement = try WireNegotiator.makeAcknowledgement(
        result: negotiation,
        sessionEpoch: SessionEpoch(rawValue: "123e4567-e89b-12d3-a456-426614174000")
      )
      driver.completeReceive(try codec.encode(acknowledgement, phase: .awaitingApproval))
      let admitted = try await task.value
      await core.cancelAttempt(token)
      let afterStaleToken = await core.snapshot()
      XCTAssertNil(afterStaleToken.terminalCode)
      XCTAssertEqual(driver.cancelCount, 0)
      admitted.cancel()
    }
  }

  func testCancellationPersistsAcrossTransferredButUnboundCore() async throws {
    let barrier = SessionAsyncBarrier()
    let driver = SessionSecureDriver()
    let viewerHello = try makeSessionHello(role: .viewer)
    let discovery = SessionTestDiscovery(
      result: try makeDiscoveredViewer(viewerHello: viewerHello)
    )
    let transportLimits = try SecureTransportLimits(connectionTimeoutSeconds: 1)
    let admission = SDKSessionAdmission(
      pairingCode: try PairingCode("ABC234"),
      localHello: try makeSessionHello(role: .app),
      transportLimits: transportLimits,
      dependencies: SDKSessionAdmissionDependencies(
        makeDiscovery: { _ in discovery },
        makeChannel: { _, handler in
          SecureByteChannel(
            driver: driver,
            limits: transportLimits,
            eventHandler: handler
          )
        },
        sleep: sessionTestSleep,
        beforeBind: { await barrier.wait() }
      )
    )
    let task = Task { try await admission.run() }
    await barrier.waitUntilEntered()
    await admission.cancel()
    barrier.release()

    await assertAdmissionError(.cancelled) { _ = try await task.value }
    XCTAssertFalse(driver.isStarted)
    XCTAssertEqual(driver.cancelCount, 0)
  }

  func testUniquePullIdentityIgnoresDelayedImmediateAndConcurrentCancellation() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let core = attachment.transportCore
    let policy = try WireFlowPolicy(
      appUplinkEventsPerSecond: 6,
      appDownlinkEventsPerSecond: 4
    )

    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(policy: policy),
        phase: .negotiatingPolicy
      )
    )
    await sessionWaitUntil { await core.snapshot().retainedPolicyMessages == 1 }

    let immediateNotifications = SessionDelayedNotifications()
    let immediateGateBox = SessionPullGateBox()
    let immediateGate = SDKSessionPullCancellationGate(
      notificationScheduler: { immediateNotifications.store($0) },
      claimDidRegister: { immediateGateBox.value?.cancel() }
    )
    immediateGateBox.value = immediateGate
    let immediate = try await core.nextPolicyMessage(cancellationGate: immediateGate)
    XCTAssertEqual(immediate, .offer(WireFlowPolicyOffer(policy: policy)))
    immediateGateBox.value = nil

    let newerPending = Task { try await attachment.nextPolicyMessage() }
    await sessionWaitUntil { await core.snapshot().hasPendingPolicyPull }
    immediateNotifications.fireAll()
    await Task.yield()
    let afterImmediateStaleCancellation = await core.snapshot()
    XCTAssertTrue(afterImmediateStaleCancellation.hasPendingPolicyPull)
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyAccepted(policy: policy),
        phase: .negotiatingPolicy
      )
    )
    let newerResult = try await newerPending.value
    XCTAssertEqual(newerResult, .accepted(WireFlowPolicyAccepted(policy: policy)))

    let originalPending = Task { try await attachment.nextPolicyMessage() }
    await sessionWaitUntil { await core.snapshot().hasPendingPolicyPull }
    let concurrentNotifications = SessionDelayedNotifications()
    let concurrentGateBox = SessionPullGateBox()
    let concurrentGate = SDKSessionPullCancellationGate(
      notificationScheduler: { concurrentNotifications.store($0) },
      claimDidRegister: { concurrentGateBox.value?.cancel() }
    )
    concurrentGateBox.value = concurrentGate
    await assertAdmissionError(.pullAlreadyPending) {
      _ = try await core.nextPolicyMessage(cancellationGate: concurrentGate)
    }
    concurrentGateBox.value = nil
    originalPending.cancel()
    await assertAdmissionError(.pullCancelled) { _ = try await originalPending.value }

    let finalPending = Task { try await attachment.nextPolicyMessage() }
    await sessionWaitUntil { await core.snapshot().hasPendingPolicyPull }
    concurrentNotifications.fireAll()
    await Task.yield()
    let afterConcurrentStaleCancellation = await core.snapshot()
    XCTAssertTrue(afterConcurrentStaleCancellation.hasPendingPolicyPull)
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(policy: policy),
        phase: .negotiatingPolicy
      )
    )
    let finalResult = try await finalPending.value
    XCTAssertEqual(finalResult, .offer(WireFlowPolicyOffer(policy: policy)))
    attachment.cancel()
  }

  func testIngressQuantumAllowsCancellationAndKeepsCombinedAccountingBounded() async throws {
    let appHello = try makeSessionHello(role: .app)
    let viewerHello = try makeSessionHello(role: .viewer)
    let ingress = SDKSessionChannelIngress(maximumEvents: 64, maximumReceiveBytes: 1_024)
    let driver = SessionSecureDriver()
    let channel = SecureByteChannel(driver: driver) { event in
      ingress.submit(.channel(event))
    }
    let token = SDKSessionAttemptToken()
    let core = SDKSessionTransportCore(
      ingress: ingress,
      localHello: appHello,
      localHelloBytes: try WirePreHandshakeCodec().encode(appHello),
      discoveredDiscriminator: ViewerDiscoveryDiscriminator(
        viewerInstallationID: viewerHello.installationID
      ),
      attemptToken: token,
      wireLimits: .default,
      admissionLimits: .default,
      sleep: sessionTestSleep
    )
    try await core.bind(channel: channel)
    ingress.installDrain { [weak core] in Task { await core?.drainIngress() } }
    let admission = Task { try await core.run(attemptToken: token) }
    await driver.waitUntilStarted()
    await sdkWaitUntil { ingress.retainedCounts.events == 0 }

    for _ in 0..<64 {
      ingress.submit(.channel(.stateChanged(.preparing)))
      XCTAssertLessThanOrEqual(ingress.retainedCounts.events, 64)
    }
    await core.cancelFromExternalHandle()
    await assertAdmissionError(.cancelled) { _ = try await admission.value }
    XCTAssertEqual(ingress.retainedCounts, .init(events: 0, receiveBytes: 0))
  }

  func testCompleteIncompatibilityEOFPongAndTerminalPriorityMatrix() async throws {
    let incompatibleViewerHellos = [
      try makeSessionHello(
        role: .viewer,
        versions: WireVersionRange(
          minimum: WireProtocolVersion(2),
          maximum: WireProtocolVersion(2)
        )
      ),
      try makeSessionHello(
        role: .viewer,
        codecs: [WireCodecIdentifier("cbor")]
      ),
      try makeSessionHello(
        role: .viewer,
        sendPolicies: [.keepLatest]
      ),
    ]
    for remoteHello in incompatibleViewerHellos {
      let driver = SessionSecureDriver()
      let transportLimits = try SecureTransportLimits(connectionTimeoutSeconds: 1)
      let discovery = SessionTestDiscovery(
        result: try makeDiscoveredViewer(viewerHello: remoteHello)
      )
      let admission = SDKSessionAdmission(
        pairingCode: try PairingCode("ABC234"),
        localHello: try makeSessionHello(role: .app),
        transportLimits: transportLimits,
        dependencies: SDKSessionAdmissionDependencies(
          makeDiscovery: { _ in discovery },
          makeChannel: { _, handler in
            SecureByteChannel(
              driver: driver,
              limits: transportLimits,
              eventHandler: handler
            )
          },
          sleep: sessionTestSleep
        )
      )
      let task = Task { try await admission.run() }
      await driver.waitUntilStarted()
      driver.emitState(.ready)
      await driver.waitForReceive()
      driver.completeReceive(try WirePreHandshakeCodec().encode(remoteHello))
      await assertAdmissionError(.incompatiblePeer) { _ = try await task.value }
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(Data([0, 0]), isComplete: true)
      await assertAdmissionError(.transportFailed) { _ = try await task.value }
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(WirePong(nonce: UInt64.max), phase: .awaitingApproval)
      )
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(fixture.acknowledgement, phase: .awaitingApproval)
      )
      let admitted = try await task.value
      admitted.cancel()
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let task = Task { try await fixture.admission.run() }
      await fixture.driver.waitUntilStarted()
      fixture.driver.emitState(.ready)
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(try WirePreHandshakeCodec().encode(fixture.viewerHello))
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(fixture.acknowledgement, phase: .awaitingApproval)
      )
      fixture.driver.emitState(.failed)
      await assertAdmissionError(.transportFailed) { _ = try await task.value }
    }
  }

  func testRealTLSProductionChannelCompletesAdmissionSequence() async throws {
    #if os(macOS)
      let appHello = try makeSessionHello(role: .app)
      let viewerHello = try makeSessionHello(role: .viewer)
      let negotiation = try WireNegotiator.negotiate(local: appHello, remote: viewerHello)
      let codec = try WireSessionCodec(negotiation: negotiation)
      let sessionEpoch = try SessionEpoch(
        rawValue: "123e4567-e89b-12d3-a456-426614174000"
      )
      let acknowledgement = try WireNegotiator.makeAcknowledgement(
        result: negotiation,
        sessionEpoch: sessionEpoch
      )
      let viewerBytes =
        try WirePreHandshakeCodec().encode(viewerHello)
        + codec.encode(acknowledgement, phase: .awaitingApproval)
      let expectedAppHello = try WirePreHandshakeCodec().encode(appHello)

      let securityIdentity = try makeSessionTLSViewerIdentity()
      guard try sessionSystemTrustEvaluationIsAvailable(identity: securityIdentity) else {
        throw XCTSkip("Security trust evaluation is unavailable in the restricted test sandbox.")
      }
      let viewerIdentity = try ViewerTransportIdentity(identity: securityIdentity)
      let listener = try SecureViewerTransport.makeListener(identity: viewerIdentity)
      let connectionQueue = DispatchQueue(label: "nearwire.tests.session.real-tls")
      let verificationQueue = DispatchQueue(label: "nearwire.tests.session.real-tls-verify")
      let listenerReady = expectation(description: "real TLS listener ready")
      let viewerReady = expectation(description: "real TLS Viewer channel ready")
      let appHelloReceived = expectation(description: "real TLS App hello received")
      let recorder = SessionTLSIntegrationRecorder(
        outboundBytes: viewerBytes,
        expectedAppHello: expectedAppHello,
        viewerReady: viewerReady,
        appHelloReceived: appHelloReceived
      )

      try listener.start(queue: connectionQueue) { event in
        switch event {
        case .ready(let port):
          recorder.setPort(port)
          listenerReady.fulfill()
        case .incoming(let incoming):
          do {
            let channel = try incoming.makeChannel(queue: connectionQueue) {
              [weak recorder] event in
              recorder?.receive(event)
            }
            recorder.setViewerChannel(channel)
            Task { try await channel.start() }
          } catch {
            recorder.recordFailure()
          }
        case .failed(let error):
          recorder.recordFailure(error.code)
          listenerReady.fulfill()
          viewerReady.fulfill()
          appHelloReceived.fulfill()
        case .cancelled:
          break
        }
      }

      await fulfillment(of: [listenerReady], timeout: 2)
      guard let port = recorder.port else {
        await fulfillment(of: [viewerReady, appHelloReceived], timeout: 1)
        listener.cancel()
        XCTFail("Real TLS listener failed with \(String(describing: recorder.failureCode)).")
        return
      }
      let endpointPort = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
      let identity = NearWireBonjourServiceIdentity(
        instanceName: "NearWire-ABC234",
        type: NearWireBonjour.serviceType,
        domain: NearWireBonjour.localDomain,
        viewerDiscriminator: ViewerDiscoveryDiscriminator(
          viewerInstallationID: viewerHello.installationID
        )
      )!
      let discovered = DiscoveredViewer(
        identity: identity,
        endpoint: .hostPort(host: "127.0.0.1", port: endpointPort)
      )
      let transportLimits = try SecureTransportLimits(connectionTimeoutSeconds: 3)
      let admission = SDKSessionAdmission(
        pairingCode: try PairingCode("ABC234"),
        localHello: appHello,
        transportLimits: transportLimits,
        dependencies: SDKSessionAdmissionDependencies(
          makeDiscovery: { _ in SessionTestDiscovery(result: discovered) },
          makeChannel: { discovered, handler in
            SecureAppTransport.makeChannel(
              endpoint: discovered.endpoint,
              connectionQueue: connectionQueue,
              verificationQueue: verificationQueue,
              limits: transportLimits,
              eventHandler: handler
            )
          },
          sleep: sessionTestSleep
        )
      )

      let admitted = try await admission.run()
      await fulfillment(of: [viewerReady, appHelloReceived], timeout: 3)
      XCTAssertEqual(admitted.route.sessionEpoch, UUID(uuidString: sessionEpoch.rawValue))
      XCTAssertEqual(admitted.route.viewerID, viewerHello.installationID.rawValue)
      XCTAssertEqual(recorder.receivedBytes, expectedAppHello)
      XCTAssertFalse(recorder.didFail)

      admitted.cancel()
      if let viewerChannel = recorder.viewerChannel {
        await viewerChannel.cancel()
      }
      listener.cancel()
    #else
      throw XCTSkip("The unrestricted real-TLS admission integration gate runs on macOS.")
    #endif
  }
}

private struct SessionAdmissionFixture {
  let admission: SDKSessionAdmission
  let driver: SessionSecureDriver
  let appHello: WireHello
  let viewerHello: WireHello
  let negotiation: WireNegotiationResult
  let sessionCodec: WireSessionCodec
  let acknowledgement: WireHelloAcknowledgement
  let sessionUUID: UUID

  init(
    advertisedViewerID: String = "viewer-installation",
    admissionLimits: SDKSessionAdmissionLimits = .default
  ) throws {
    appHello = try makeSessionHello(role: .app)
    viewerHello = try makeSessionHello(role: .viewer)
    negotiation = try WireNegotiator.negotiate(local: appHello, remote: viewerHello)
    sessionCodec = try WireSessionCodec(negotiation: negotiation)
    sessionUUID = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!
    acknowledgement = try WireNegotiator.makeAcknowledgement(
      result: negotiation,
      sessionEpoch: SessionEpoch(rawValue: sessionUUID.uuidString.lowercased())
    )
    let sessionDriver = SessionSecureDriver()
    driver = sessionDriver
    let advertisedHello = try makeSessionHello(role: .viewer, installationID: advertisedViewerID)
    let discovered = try makeDiscoveredViewer(viewerHello: advertisedHello)
    let discovery = SessionTestDiscovery(result: discovered)
    let transportLimits = try SecureTransportLimits(connectionTimeoutSeconds: 1)
    let dependencies = SDKSessionAdmissionDependencies(
      makeDiscovery: { _ in discovery },
      makeChannel: { _, handler in
        SecureByteChannel(driver: sessionDriver, limits: transportLimits, eventHandler: handler)
      },
      sleep: sessionTestSleep
    )
    admission = SDKSessionAdmission(
      pairingCode: try PairingCode("ABC234"),
      localHello: appHello,
      transportLimits: transportLimits,
      admissionLimits: admissionLimits,
      dependencies: dependencies
    )
  }

  func admit() async throws -> SDKAdmittedSession {
    let task = Task { try await admission.run() }
    await driver.waitUntilStarted()
    driver.emitState(.ready)
    await driver.waitForReceive()
    driver.completeReceive(try WirePreHandshakeCodec().encode(viewerHello))
    await driver.waitForReceive()
    driver.completeReceive(
      try sessionCodec.encode(acknowledgement, phase: .awaitingApproval)
    )
    return try await task.value
  }
}

private final class SessionTestDiscovery: SDKSessionDiscoveryOperation, @unchecked Sendable {
  private let result: Result<DiscoveredViewer, Error>
  private let lock = NSLock()
  private var _cancelCount = 0

  init(result: DiscoveredViewer) {
    self.result = .success(result)
  }

  init(error: Error) {
    result = .failure(error)
  }

  func run() async throws -> DiscoveredViewer { try result.get() }

  func cancel() async {
    recordCancel()
  }

  private func recordCancel() {
    lock.lock()
    _cancelCount += 1
    lock.unlock()
  }
}

private final class SessionControlledDiscovery: SDKSessionDiscoveryOperation, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<DiscoveredViewer, Error>?
  private var _cancelCount = 0
  private var running = false

  func run() async throws -> DiscoveredViewer {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      running = true
      self.continuation = continuation
      lock.unlock()
    }
  }

  func cancel() async {
    cancelSynchronously()
  }

  private func cancelSynchronously() {
    lock.lock()
    _cancelCount += 1
    let waiter = continuation
    continuation = nil
    lock.unlock()
    waiter?.resume(throwing: ViewerDiscoveryError(.cancelled))
  }

  func waitUntilRunning() async {
    await sdkWaitUntil {
      self.lock.lock()
      defer { self.lock.unlock() }
      return self.running
    }
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _cancelCount
  }
}

private final class SessionDeadlineController: @unchecked Sendable {
  private struct Request {
    let id: UUID
    let seconds: Int
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var requests: [Request] = []
  private var cancelled = Set<UUID>()

  func sleep(seconds: Int) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        register(id: id, seconds: seconds, continuation: continuation)
      }
    } onCancel: {
      self.cancel(id: id)
    }
  }

  func fire(seconds: Int) {
    let waiter: CheckedContinuation<Void, Error>?
    lock.lock()
    if let index = requests.firstIndex(where: { $0.seconds == seconds }) {
      waiter = requests.remove(at: index).continuation
    } else {
      waiter = nil
    }
    lock.unlock()
    waiter?.resume()
  }

  func waitForRequest(seconds: Int) async {
    await sdkWaitUntil {
      self.lock.lock()
      defer { self.lock.unlock() }
      return self.requests.contains(where: { $0.seconds == seconds })
    }
  }

  private func register(
    id: UUID,
    seconds: Int,
    continuation: CheckedContinuation<Void, Error>
  ) {
    lock.lock()
    if cancelled.remove(id) != nil {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    requests.append(Request(id: id, seconds: seconds, continuation: continuation))
    lock.unlock()
  }

  private func cancel(id: UUID) {
    let waiter: CheckedContinuation<Void, Error>?
    lock.lock()
    if let index = requests.firstIndex(where: { $0.id == id }) {
      waiter = requests.remove(at: index).continuation
    } else {
      cancelled.insert(id)
      waiter = nil
    }
    lock.unlock()
    waiter?.resume(throwing: CancellationError())
  }
}

private final class SessionSecureDriver: SecureConnectionDriving, @unchecked Sendable {
  private let lock = NSLock()
  private var stateHandler: (@Sendable (SecureDriverState) -> Void)?
  private var receiveCompletion: (@Sendable (Data?, Bool, Bool) -> Void)?
  private var _sentData: [Data] = []
  private var _cancelCount = 0

  func start(stateHandler: @escaping @Sendable (SecureDriverState) -> Void) {
    lock.lock()
    self.stateHandler = stateHandler
    lock.unlock()
  }

  func receive(
    maximumLength: Int,
    completion: @escaping @Sendable (Data?, Bool, Bool) -> Void
  ) {
    lock.lock()
    receiveCompletion = completion
    lock.unlock()
  }

  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
    lock.lock()
    _sentData.append(data)
    lock.unlock()
    completion(false)
  }

  func cancel() {
    lock.lock()
    _cancelCount += 1
    receiveCompletion = nil
    lock.unlock()
  }

  func emitState(_ state: SecureDriverState) {
    lock.lock()
    let callback = stateHandler
    lock.unlock()
    callback?(state)
  }

  func completeReceive(_ data: Data, isComplete: Bool = false, failed: Bool = false) {
    lock.lock()
    let callback = receiveCompletion
    receiveCompletion = nil
    lock.unlock()
    callback?(data, isComplete, failed)
  }

  func waitUntilStarted() async {
    await sdkWaitUntil { self.isStarted }
  }

  func waitForReceive() async {
    await sdkWaitUntil {
      self.lock.lock()
      defer { self.lock.unlock() }
      return self.receiveCompletion != nil
    }
  }

  var isStarted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stateHandler != nil
  }

  var sentData: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return _sentData
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _cancelCount
  }
}

private final class SessionDependencyCounters: @unchecked Sendable {
  private let lock = NSLock()
  private var values = (discovery: 0, channel: 0, drain: 0)

  func recordDiscovery() {
    lock.lock()
    values.discovery += 1
    lock.unlock()
  }

  func recordChannel() {
    lock.lock()
    values.channel += 1
    lock.unlock()
  }

  func recordDrain() {
    lock.lock()
    values.drain += 1
    lock.unlock()
  }

  var discoveryCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.discovery
  }

  var channelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.channel
  }

  var drainCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.drain
  }
}

private final class SessionWeakCore: @unchecked Sendable {
  weak var value: SDKSessionTransportCore?

  init(_ value: SDKSessionTransportCore?) {
    self.value = value
  }
}

private final class SessionPullGateBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: SDKSessionPullCancellationGate?

  var value: SDKSessionPullCancellationGate? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedValue
    }
    set {
      lock.lock()
      storedValue = newValue
      lock.unlock()
    }
  }
}

private final class SessionDelayedNotifications: @unchecked Sendable {
  private let lock = NSLock()
  private var callbacks: [@Sendable () -> Void] = []

  func store(_ callback: @escaping @Sendable () -> Void) {
    lock.lock()
    callbacks.append(callback)
    lock.unlock()
  }

  func fireAll() {
    lock.lock()
    let current = callbacks
    callbacks.removeAll()
    lock.unlock()
    for callback in current {
      callback()
    }
  }
}

private final class SessionAsyncBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private var entered = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      entered = true
      self.continuation = continuation
      lock.unlock()
    }
  }

  func waitUntilEntered() async {
    await sdkWaitUntil {
      self.lock.lock()
      defer { self.lock.unlock() }
      return self.entered
    }
  }

  func release() {
    lock.lock()
    let waiter = continuation
    continuation = nil
    lock.unlock()
    waiter?.resume()
  }
}

private final class SessionTLSIntegrationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private let outboundBytes: Data
  private let expectedAppHello: Data
  private let viewerReady: XCTestExpectation
  private let appHelloReceived: XCTestExpectation
  private var storedPort: UInt16?
  private var storedViewerChannel: SecureByteChannel?
  private var storedReceivedBytes = Data()
  private var storedDidFail = false
  private var storedFailureCode: SecureTransportError.Code?

  init(
    outboundBytes: Data,
    expectedAppHello: Data,
    viewerReady: XCTestExpectation,
    appHelloReceived: XCTestExpectation
  ) {
    self.outboundBytes = outboundBytes
    self.expectedAppHello = expectedAppHello
    self.viewerReady = viewerReady
    self.appHelloReceived = appHelloReceived
  }

  func setPort(_ port: UInt16) {
    lock.lock()
    storedPort = port
    lock.unlock()
  }

  func setViewerChannel(_ channel: SecureByteChannel) {
    lock.lock()
    storedViewerChannel = channel
    lock.unlock()
  }

  func receive(_ event: SecureByteChannelEvent) {
    switch event {
    case .stateChanged(.ready):
      lock.lock()
      let channel = storedViewerChannel
      lock.unlock()
      viewerReady.fulfill()
      if let channel {
        Task {
          do {
            try await channel.send(outboundBytes)
          } catch {
            self.recordFailure()
          }
        }
      } else {
        recordFailure()
      }
    case .received(let data):
      lock.lock()
      storedReceivedBytes.append(data)
      let complete = storedReceivedBytes == expectedAppHello
      lock.unlock()
      if complete { appHelloReceived.fulfill() }
    case .terminated:
      break
    case .stateChanged, .sendCompleted:
      break
    }
  }

  func recordFailure() {
    lock.lock()
    storedDidFail = true
    lock.unlock()
  }

  func recordFailure(_ code: SecureTransportError.Code) {
    lock.lock()
    storedDidFail = true
    storedFailureCode = code
    lock.unlock()
  }

  var port: UInt16? {
    lock.lock()
    defer { lock.unlock() }
    return storedPort
  }

  var viewerChannel: SecureByteChannel? {
    lock.lock()
    defer { lock.unlock() }
    return storedViewerChannel
  }

  var receivedBytes: Data {
    lock.lock()
    defer { lock.unlock() }
    return storedReceivedBytes
  }

  var didFail: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storedDidFail
  }

  var failureCode: SecureTransportError.Code? {
    lock.lock()
    defer { lock.unlock() }
    return storedFailureCode
  }
}

#if os(macOS)
  private func makeSessionTLSViewerIdentity() throws -> SecIdentity {
    let currentFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot =
      currentFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let transportTests = repositoryRoot.appendingPathComponent(
      "Core/Tests/NearWireTransportTests/SecureTransportTests.swift"
    )
    let source = try String(contentsOf: transportTests, encoding: .utf8)
    let expression = try NSRegularExpression(
      pattern: #"viewerIdentityPKCS12Base64\s*=\s*\n?\s*"([^"]+)""#
    )
    let range = NSRange(source.startIndex..., in: source)
    let match = try XCTUnwrap(expression.firstMatch(in: source, range: range))
    let valueRange = try XCTUnwrap(Range(match.range(at: 1), in: source))
    let archive = try XCTUnwrap(Data(base64Encoded: String(source[valueRange])))
    var importedItems: CFArray?
    var options: [String: Any] = [
      kSecImportExportPassphrase as String: "nearwire-test"
    ]
    if #available(macOS 15.0, *) {
      options[kSecImportToMemoryOnly as String] = true
    }
    XCTAssertEqual(
      SecPKCS12Import(archive as CFData, options as CFDictionary, &importedItems),
      errSecSuccess
    )
    let items = try XCTUnwrap(importedItems as? [[String: Any]])
    let first = try XCTUnwrap(items.first)
    return try XCTUnwrap(first[kSecImportItemIdentity as String] as! SecIdentity?)
  }

  private func sessionSystemTrustEvaluationIsAvailable(identity: SecIdentity) throws -> Bool {
    var certificate: SecCertificate?
    XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
    let leaf = try XCTUnwrap(certificate)
    var trust: SecTrust?
    XCTAssertEqual(
      SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &trust),
      errSecSuccess
    )
    let resolvedTrust = try XCTUnwrap(trust)
    XCTAssertEqual(SecTrustSetPolicies(resolvedTrust, SecPolicyCreateBasicX509()), errSecSuccess)
    XCTAssertEqual(
      SecTrustSetAnchorCertificates(resolvedTrust, [leaf] as CFArray),
      errSecSuccess
    )
    XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(resolvedTrust, true), errSecSuccess)
    var error: CFError?
    return SecTrustEvaluateWithError(resolvedTrust, &error)
  }
#endif

private func makeSessionHello(
  role: EndpointRole,
  installationID: String? = nil,
  versions: WireVersionRange = .v1,
  codecs: Set<WireCodecIdentifier> = [.json],
  sendPolicies: Set<WireSendPolicy> = [.normal, .keepLatest]
) throws -> WireHello {
  try WireHello(
    versions: versions,
    productVersion: WireProductVersion("1.0.0"),
    role: role,
    installationID: EndpointID(
      rawValue: installationID ?? (role == .app ? "phone-installation" : "viewer-installation")
    ),
    codecs: codecs,
    sendPolicies: sendPolicies
  )
}

private func makeDiscoveredViewer(viewerHello: WireHello) throws -> DiscoveredViewer {
  let identity = NearWireBonjourServiceIdentity(
    instanceName: "NearWire-ABC234",
    type: NearWireBonjour.serviceType,
    domain: NearWireBonjour.localDomain,
    viewerDiscriminator: ViewerDiscoveryDiscriminator(
      viewerInstallationID: viewerHello.installationID
    )
  )!
  return DiscoveredViewer(
    identity: identity,
    endpoint: NWEndpoint.hostPort(host: "127.0.0.1", port: 49_999)
  )
}

private let sessionTestSleep: @Sendable (Int) async throws -> Void = { seconds in
  try await ContinuousClock().sleep(for: .seconds(seconds))
}

private func assertAdmissionError(
  _ code: SDKSessionAdmissionError.Code,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    XCTFail("Expected SDKSessionAdmissionError.\(code.rawValue).")
  } catch let error as SDKSessionAdmissionError {
    XCTAssertEqual(error.code, code)
  } catch {
    XCTFail("Expected SDKSessionAdmissionError, received \(type(of: error)).")
  }
}

private func sessionWaitUntil(
  timeoutNanoseconds: UInt64 = 1_000_000_000,
  condition: @escaping () async -> Bool
) async {
  let start = DispatchTime.now().uptimeNanoseconds
  while !(await condition()), DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
    await Task.yield()
  }
}
