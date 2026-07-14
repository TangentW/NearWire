import Foundation
@_spi(NearWireInternal) import NearWireCore
import Network
import Security
import XCTest

@testable import NearWire
@_spi(NearWireInternal) @testable import NearWireTransport

final class SDKSessionAdmissionTests: XCTestCase {
  func testActivePumpActivatesConservativePolicyAndObservesTermination() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let pump = SDKActiveEventPump(attachment: attachment, owner: NearWire())

    await fixture.driver.waitForReceive()
    let run = Task { try await pump.run() }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    let offer = try WireFlowPolicy(
      appUplinkEventsPerSecond: 1_000,
      appDownlinkEventsPerSecond: 500
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(policy: offer),
        phase: .negotiatingPolicy
      )
    )

    let handle = try await run.value
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.state, .active)
    XCTAssertEqual(snapshot.effectiveUplinkRate, 100)
    XCTAssertEqual(snapshot.effectiveDownlinkRate, 50)
    XCTAssertEqual(handle.description, "<redacted-active-event-pump-handle>")

    await sdkWaitUntil { fixture.driver.sentData.count == 2 }
    let accepted = try decodeAcceptedPolicy(
      fixture.driver.sentData[1],
      codec: fixture.sessionCodec,
      phase: .negotiatingPolicy
    )
    XCTAssertEqual(accepted.policy.appUplinkEventsPerSecond, 100)
    XCTAssertEqual(accepted.policy.appDownlinkEventsPerSecond, 50)

    let observer = handle.termination
    let wait = Task { try await observer.wait() }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().hasPendingTerminationObservation
    }
    handle.cancel()
    let terminalCode = try await wait.value
    XCTAssertEqual(terminalCode, .cancelled)
    await assertAdmissionError(.terminationWaitAlreadyStarted) {
      _ = try await observer.wait()
    }
  }

  func testDynamicPolicyUsesFreshConservativeBoundary() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let clock = SessionMonotonicSequence(values: [50, 100, 200])
    let owner = NearWire(
      dependencies: SDKRuntimeDependencies(
        wallClock: { Date(timeIntervalSince1970: 0) },
        monotonicClock: { clock.next() },
        identifierGenerator: { UUID() }
      )
    )
    let run = Task {
      try await SDKActiveEventPump(attachment: attachment, owner: owner).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 80,
            appDownlinkEventsPerSecond: 40
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1_000,
            appDownlinkEventsPerSecond: 0
          )
        ),
        phase: .active
      )
    )
    await sessionWaitUntil { fixture.driver.sentData.count == 3 }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.effectiveUplinkRate, 100)
    XCTAssertEqual(snapshot.effectiveDownlinkRate, 0)
    let accepted = try decodeAcceptedPolicy(
      fixture.driver.sentData[2],
      codec: fixture.sessionCodec,
      phase: .active
    )
    XCTAssertEqual(accepted.policy.appUplinkEventsPerSecond, 100)
    XCTAssertEqual(accepted.policy.appDownlinkEventsPerSecond, 0)
    handle.cancel()
  }

  func testIngressPauseParksNonterminalAndLetsTerminalBypass() {
    let callbacks = SessionDependencyCounters()
    let ingress = SDKSessionChannelIngress(maximumEvents: 8, maximumReceiveBytes: 64)
    ingress.installDrain { callbacks.recordDrain() }
    ingress.submit(.channel(.received(Data([1]))))
    XCTAssertEqual(callbacks.drainCount, 1)

    ingress.pauseNonterminalDrain()
    guard case .parked = ingress.takeBatch(maximumItems: 8) else {
      return XCTFail("Expected scheduled nonterminal drain to park.")
    }
    ingress.submit(.channel(.received(Data([2]))))
    XCTAssertEqual(callbacks.drainCount, 1)
    XCTAssertEqual(ingress.retainedCounts, .init(events: 2, receiveBytes: 2))

    ingress.submit(
      .channel(
        .terminated(
          SecureTransportError(
            code: .endOfStream,
            message: "private",
            disposition: .connectionTerminal
          )
        )
      )
    )
    XCTAssertEqual(callbacks.drainCount, 2)
    guard case .batch(let terminal) = ingress.takeBatch(maximumItems: 8) else {
      return XCTFail("Expected terminal bypass batch.")
    }
    XCTAssertEqual(terminal.count, 1)
    ingress.stop()
    ingress.resumeNonterminalDrain()
    XCTAssertEqual(ingress.currentMode, .stopped)
  }

  func testActiveLimitsRejectEveryZeroAndHardMaximumOverflow() throws {
    XCTAssertNoThrow(try SDKActiveEventPumpLimits())
    XCTAssertEqual(
      SDKActiveEventPumpLimits.default.maximumOutboundAccountedBytesPerTurn,
      NearWireBufferConfiguration.default.maximumEventBytes
    )
    XCTAssertThrowsError(try SDKActiveEventPumpLimits(initialPolicyTimeoutSeconds: 0))
    XCTAssertThrowsError(
      try SDKActiveEventPumpLimits(maximumIncomingEvents: 10_001)
    )
    XCTAssertThrowsError(
      try SDKActiveEventPumpLimits(maximumIncomingEncodedBytes: 0)
    )
    XCTAssertThrowsError(
      try SDKActiveEventPumpLimits(maximumCompletedFramesPerReceive: 1_025)
    )
    XCTAssertThrowsError(
      try SDKActiveEventPumpLimits(maximumOutboundServiceUnitsPerTurn: 0)
    )
    XCTAssertThrowsError(
      try SDKActiveEventPumpLimits(maximumOutboundAccountedBytesPerTurn: 0)
    )
    XCTAssertThrowsError(
      try SDKActiveEventPumpLimits(maximumIncomingPublicationsPerTurn: 257)
    )
    XCTAssertThrowsError(
      try SDKActiveEventPumpLimits(maximumDeferredPolicyTransactions: 129)
    )
  }

  func testActiveRunCancellationDuringBindingWinsWithoutWakeInstallation() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let binding = SessionAsyncBarrier()
    let pump = SDKActiveEventPump(
      attachment: attachment,
      owner: NearWire(),
      dependencies: SDKActiveEventPumpDependencies(
        sleep: sessionTestSleep,
        beforeWakeRegistration: { await binding.wait() },
        beforeActivationCommit: {},
        beforeActivationResume: {},
        operationGateHooks: .none
      )
    )
    let run = Task { try await pump.run() }
    await binding.waitUntilEntered()
    run.cancel()
    await assertAdmissionError(.cancelled) {
      _ = try await run.value
    }
    binding.release()
    await sessionWaitUntil { fixture.driver.cancelCount == 1 }
    let terminal = await attachment.transportCore.snapshot().terminalCode
    XCTAssertEqual(terminal, .cancelled)
  }

  func testPolicyDeadlineCoversSuspendedOwnerBinding() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let binding = SessionAsyncBarrier()
    let deadline = SessionAsyncBarrier()
    let pump = SDKActiveEventPump(
      attachment: attachment,
      owner: NearWire(),
      dependencies: SDKActiveEventPumpDependencies(
        sleep: { _ in await deadline.wait() },
        beforeWakeRegistration: { await binding.wait() },
        beforeActivationCommit: {},
        beforeActivationResume: {},
        operationGateHooks: .none
      )
    )
    let run = Task { try await pump.run() }
    await binding.waitUntilEntered()
    await deadline.waitUntilEntered()
    deadline.release()
    await assertAdmissionError(.policyNegotiationTimedOut) {
      _ = try await run.value
    }
    binding.release()
    await sessionWaitUntil { fixture.driver.cancelCount == 1 }
    let terminal = await attachment.transportCore.snapshot().terminalCode
    XCTAssertEqual(terminal, .policyNegotiationTimedOut)
  }

  func testPolicyDeadlineAfterSuccessfulRegistrationWithNoOffer() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let deadline = SessionDeadlineController()
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: NearWire(),
        dependencies: SDKActiveEventPumpDependencies(
          sleep: { try await deadline.sleep(seconds: $0) },
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          operationGateHooks: .none
        )
      ).run()
    }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    await deadline.waitForRequest(seconds: 10)
    XCTAssertEqual(fixture.driver.sentData.count, 1)
    deadline.fire(seconds: 10)
    await assertAdmissionError(.policyNegotiationTimedOut) { _ = try await run.value }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .policyNegotiationTimedOut)
    XCTAssertFalse(snapshot.hasOwnerRefresh)
    XCTAssertEqual(fixture.driver.sentData.count, 1)
  }

  func testPolicyPullAndActiveRunnerOwnershipAreIrreversible() async throws {
    do {
      let fixture = try SessionAdmissionFixture()
      let admitted = try await fixture.admit()
      let attachment = try await admitted.attachEventPump()
      let pendingPull = Task { try await attachment.nextPolicyMessage() }
      await sessionWaitUntil { await attachment.transportCore.snapshot().hasPendingPolicyPull }
      let pump = SDKActiveEventPump(attachment: attachment, owner: NearWire())
      await assertAdmissionError(.policyConsumerClaimed) {
        _ = try await pump.run()
      }
      pendingPull.cancel()
      await assertAdmissionError(.pullCancelled) {
        _ = try await pendingPull.value
      }
      admitted.cancel()
    }

    do {
      let fixture = try SessionAdmissionFixture()
      let admitted = try await fixture.admit()
      let attachment = try await admitted.attachEventPump()
      let binding = SessionAsyncBarrier()
      let pump = SDKActiveEventPump(
        attachment: attachment,
        owner: NearWire(),
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: { await binding.wait() },
          beforeActivationCommit: {},
          beforeActivationResume: {},
          operationGateHooks: .none
        )
      )
      let run = Task { try await pump.run() }
      await binding.waitUntilEntered()
      await assertAdmissionError(.policyConsumerClaimed) {
        _ = try await attachment.nextPolicyMessage()
      }
      run.cancel()
      binding.release()
      await assertAdmissionError(.cancelled) {
        _ = try await run.value
      }
    }
  }

  func testTerminationObserverDoesNotRetainFinalHandle() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    defer { withExtendedLifetime(owner) {} }
    var handle: SDKActiveEventPumpHandle?
    var run: Task<SDKActiveEventPumpHandle, Error>? = Task {
      try await SDKActiveEventPump(attachment: attachment, owner: owner).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    handle = try await run?.value
    run = nil
    let observer = try XCTUnwrap(handle?.termination)
    let wait = Task { try await observer.wait() }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().hasPendingTerminationObservation
    }
    handle = nil
    let terminalCode = try await wait.value
    XCTAssertEqual(terminalCode, .cancelled)
  }

  func testActiveUplinkSendsContiguousWireEventsWithinTokenAllowance() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    for value in 1...3 {
      _ = try await owner.send(type: "test.uplink", content: ["value": value])
    }
    let pump = SDKActiveEventPump(
      attachment: attachment,
      owner: owner,
      dependencies: SDKActiveEventPumpDependencies(
        sleep: sessionTestSleep,
        sleepNanoseconds: { _ in throw CancellationError() },
        beforeWakeRegistration: {},
        beforeActivationCommit: {},
        beforeActivationResume: {},
        operationGateHooks: .none
      )
    )
    let run = Task { try await pump.run() }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await sdkWaitUntil { fixture.driver.sentData.count >= 4 }
    let sent = fixture.driver.sentData
    guard sent.count >= 4 else {
      let snapshot = await attachment.transportCore.snapshot()
      let diagnostics = try await owner.bufferDiagnostics()
      handle.cancel()
      return XCTFail(
        "Expected two active Events; sent=\(sent.count), terminal=\(String(describing: snapshot.terminalCode)), queued=\(diagnostics.eventCount)."
      )
    }

    let first = try decodeEventPayload(sent[2], codec: fixture.sessionCodec)
    let second = try decodeEventPayload(sent[3], codec: fixture.sessionCodec)
    XCTAssertEqual(first.record.envelope.sequence.rawValue, 0)
    XCTAssertEqual(second.record.envelope.sequence.rawValue, 1)
    XCTAssertEqual(first.record.envelope.direction, .appToViewer)
    XCTAssertEqual(
      first.record.envelope.sessionEpoch.rawValue, fixture.sessionUUID.nearWireCanonicalString)
    let diagnostics = try await owner.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 1)
    handle.cancel()
  }

  func testActiveDownlinkValidatesAndPublishesViewerEvent() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let run = Task { try await SDKActiveEventPump(attachment: attachment, owner: owner).run() }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 10,
            appDownlinkEventsPerSecond: 10
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value

    let eventTask = Task { () throws -> NearWireEvent? in
      var iterator = owner.events.makeAsyncIterator()
      return try await iterator.next()
    }
    await sdkWaitUntil { owner.streamSubscriberCounts.events == 1 }
    await fixture.driver.waitForReceive()
    let record = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 0,
      id: "30000000-0000-0000-0000-000000000001"
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(WireEventPayload(record: record), phase: .active)
    )

    let published = try await eventTask.value
    let received = try XCTUnwrap(published)
    XCTAssertEqual(received.id.uuidString.lowercased(), record.envelope.id.rawValue)
    XCTAssertEqual(received.type, "viewer.command")
    XCTAssertEqual(received.direction, .viewerToApp)
    let metadata = try XCTUnwrap(received.session)
    XCTAssertEqual(metadata.sequence, 0)
    XCTAssertEqual(metadata.sourceID, admitted.route.viewerID)
    XCTAssertEqual(metadata.targetID, admitted.route.appID)
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.retainedIncomingEvents, 0)
    XCTAssertEqual(snapshot.retainedIncomingEncodedBytes, 0)
    handle.cancel()
  }

  func testTerminalFirstDownlinkPublicationRetainsChargeUntilGateResolution() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let beforeClaim = SessionOneShotAsyncBarrier()
    let beforeCompletion = SessionOneShotAsyncBarrier()
    let capture = SDKLockedCapture<NearWireEvent>()
    let consumer = Task {
      do {
        for try await event in owner.events { capture.append(event) }
      } catch {}
    }
    await sdkWaitUntil { owner.streamSubscriberCounts.events == 1 }
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeIncomingPublicationClaim: { await beforeClaim.waitOnce() },
          beforeIncomingPublicationCompletion: { await beforeCompletion.waitOnce() },
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    let record = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 0,
      id: "30000000-0000-0000-0000-000000000081"
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(WireEventPayload(record: record), phase: .active)
    )
    await beforeClaim.waitUntilEntered()
    let suspended = await attachment.transportCore.snapshot()
    XCTAssertEqual(suspended.retainedIncomingEvents, 1)
    XCTAssertGreaterThan(suspended.retainedIncomingEncodedBytes, 0)

    handle.cancel()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().terminalCode == .cancelled
    }
    beforeClaim.release()
    await beforeCompletion.waitUntilEntered()
    XCTAssertTrue(capture.snapshot.isEmpty)
    let terminal = await attachment.transportCore.snapshot()
    XCTAssertEqual(terminal.retainedIncomingEvents, 0)
    XCTAssertEqual(terminal.retainedIncomingEncodedBytes, 0)
    beforeCompletion.release()
    await sessionWaitUntil { fixture.driver.cancelCount == 1 }
    XCTAssertEqual(fixture.driver.cancelCount, 1)
    consumer.cancel()
  }

  func testPublicationDefersPoliciesAndCommitsInOrder() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let beforeCompletion = SessionOneShotAsyncBarrier()
    let capture = SDKLockedCapture<NearWireEvent>()
    let consumer = Task {
      do {
        for try await event in owner.events { capture.append(event) }
      } catch {}
    }
    await sdkWaitUntil { owner.streamSubscriberCounts.events == 1 }
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeIncomingPublicationCompletion: { await beforeCompletion.waitOnce() },
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 10,
            appDownlinkEventsPerSecond: 10
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    let record = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 0,
      id: "30000000-0000-0000-0000-000000000082"
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(WireEventPayload(record: record), phase: .active)
    )
    await beforeCompletion.waitUntilEntered()
    await sdkWaitUntil { capture.snapshot.count == 1 }
    let suspended = await attachment.transportCore.snapshot()
    XCTAssertEqual(suspended.retainedIncomingEvents, 1)
    XCTAssertGreaterThan(suspended.retainedIncomingEncodedBytes, 0)
    XCTAssertEqual(
      capture.snapshot.map { $0.id.uuidString.lowercased() },
      [record.envelope.id.rawValue]
    )

    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 7,
            appDownlinkEventsPerSecond: 6
          )
        ),
        phase: .active
      )
    )
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().deferredPolicyCount == 1
    }
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 5,
            appDownlinkEventsPerSecond: 4
          )
        ),
        phase: .active
      )
    )
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().deferredPolicyCount == 2
    }
    beforeCompletion.release()
    await sessionWaitUntil {
      let snapshot = await attachment.transportCore.snapshot()
      return snapshot.deferredPolicyCount == 0 && snapshot.effectiveDownlinkRate == 4
    }
    let completed = await attachment.transportCore.snapshot()
    XCTAssertEqual(completed.retainedIncomingEvents, 0)
    XCTAssertEqual(completed.effectiveUplinkRate, 5)
    XCTAssertEqual(completed.effectiveDownlinkRate, 4)
    XCTAssertEqual(capture.snapshot.count, 1)
    handle.cancel()
    consumer.cancel()
  }

  func testPublicationFirstTerminalRaceRejectsStaleCoreResult() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let beforeCompletion = SessionOneShotAsyncBarrier()
    let afterCompletion = SessionOneShotAsyncBarrier()
    let capture = SDKLockedCapture<NearWireEvent>()
    let consumer = Task {
      do {
        for try await event in owner.events { capture.append(event) }
      } catch {}
    }
    await sdkWaitUntil { owner.streamSubscriberCounts.events == 1 }
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeIncomingPublicationCompletion: { await beforeCompletion.waitOnce() },
          afterIncomingPublicationCompletion: { await afterCompletion.waitOnce() },
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 10,
            appDownlinkEventsPerSecond: 10
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    let record = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 0,
      id: "30000000-0000-0000-0000-000000000092"
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(WireEventPayload(record: record), phase: .active)
    )
    await beforeCompletion.waitUntilEntered()
    await sdkWaitUntil { capture.snapshot.count == 1 }
    let committed = await attachment.transportCore.snapshot()
    XCTAssertEqual(committed.retainedIncomingEvents, 1)
    XCTAssertGreaterThan(committed.retainedIncomingEncodedBytes, 0)
    XCTAssertEqual(committed.effectiveDownlinkRate, 10)

    handle.cancel()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().terminalCode == .cancelled
    }
    let terminal = await attachment.transportCore.snapshot()
    XCTAssertEqual(terminal.retainedIncomingEvents, 0)
    XCTAssertEqual(terminal.retainedIncomingEncodedBytes, 0)
    XCTAssertEqual(terminal.deferredPolicyCount, 0)
    XCTAssertNil(terminal.effectiveUplinkRate)
    XCTAssertNil(terminal.effectiveDownlinkRate)
    XCTAssertEqual(capture.snapshot.count, 1)

    beforeCompletion.release()
    await afterCompletion.waitUntilEntered()
    let afterStaleResult = await attachment.transportCore.snapshot()
    XCTAssertEqual(afterStaleResult, terminal)
    XCTAssertEqual(capture.snapshot.count, 1)
    await sessionWaitUntil { fixture.driver.cancelCount == 1 }
    XCTAssertEqual(fixture.driver.cancelCount, 1)
    afterCompletion.release()
    consumer.cancel()
  }

  func testTerminalAfterCommittedUplinkPrefixRejectsStaleDrainResult() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let sent = try await owner.send(type: "test.committed-prefix", content: 1)
    let beforeCompletion = SessionOneShotAsyncBarrier()
    let afterCompletion = SessionOneShotAsyncBarrier()
    let sentBeforePump = fixture.driver.sentData.count
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeOutboundTurnCompletion: { await beforeCompletion.waitOnce() },
          afterOutboundTurnCompletion: { await afterCompletion.waitOnce() },
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await beforeCompletion.waitUntilEntered()
    let committedDiagnostics = try await owner.bufferDiagnostics()
    let awaitingResult = await attachment.transportCore.snapshot()
    XCTAssertEqual(committedDiagnostics.eventCount, 0)
    XCTAssertEqual(committedDiagnostics.statistics.transportAccepted, 1)
    XCTAssertEqual(awaitingResult.outboundNextSequence, 0)
    XCTAssertEqual(awaitingResult.uplinkAvailableTokens, 2)
    XCTAssertTrue(awaitingResult.hasOutboundDrain)
    XCTAssertGreaterThanOrEqual(fixture.driver.sentData.count, sentBeforePump + 2)
    XCTAssertTrue(committedDiagnostics.statistics.transportAccepted > 0)
    XCTAssertTrue(sent.isBuffered)

    handle.cancel()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().terminalCode == .cancelled
    }
    let terminal = await attachment.transportCore.snapshot()
    XCTAssertNil(terminal.outboundNextSequence)
    XCTAssertNil(terminal.uplinkAvailableTokens)
    XCTAssertFalse(terminal.hasOutboundDrain)
    let transportCountBeforeStaleResult = fixture.driver.sentData.count
    beforeCompletion.release()
    await afterCompletion.waitUntilEntered()
    let afterStaleResult = await attachment.transportCore.snapshot()
    XCTAssertEqual(afterStaleResult, terminal)
    XCTAssertEqual(fixture.driver.sentData.count, transportCountBeforeStaleResult)
    let finalDiagnostics = try await owner.bufferDiagnostics()
    XCTAssertEqual(finalDiagnostics.eventCount, 0)
    XCTAssertEqual(finalDiagnostics.statistics.transportAccepted, 1)
    await sessionWaitUntil { fixture.driver.cancelCount == 1 }
    XCTAssertEqual(fixture.driver.cancelCount, 1)
    afterCompletion.release()
  }

  func testDeferredPolicyOverflowDuringPublicationFailsClosed() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let beforeCompletion = SessionOneShotAsyncBarrier()
    let limits = try SDKActiveEventPumpLimits(maximumDeferredPolicyTransactions: 1)
    let owner = NearWire()
    defer { withExtendedLifetime(owner) {} }
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        limits: limits,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeIncomingPublicationCompletion: { await beforeCompletion.waitOnce() },
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 10,
            appDownlinkEventsPerSecond: 10
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    let record = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 0,
      id: "30000000-0000-0000-0000-000000000083"
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(WireEventPayload(record: record), phase: .active)
    )
    await beforeCompletion.waitUntilEntered()
    for expectedCount in 1...2 {
      await fixture.driver.waitForReceive()
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(
          WireFlowPolicyOffer(
            policy: try WireFlowPolicy(
              appUplinkEventsPerSecond: Double(10 - expectedCount),
              appDownlinkEventsPerSecond: Double(10 - expectedCount)
            )
          ),
          phase: .active
        )
      )
      if expectedCount == 1 {
        await sessionWaitUntil {
          await attachment.transportCore.snapshot().deferredPolicyCount == 1
        }
      }
    }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().terminalCode == .activeWorkLimitExceeded
    }
    let terminal = await attachment.transportCore.snapshot()
    XCTAssertEqual(terminal.terminalCode, .activeWorkLimitExceeded)
    XCTAssertEqual(terminal.retainedIncomingEvents, 0)
    XCTAssertEqual(terminal.deferredPolicyCount, 0)
    beforeCompletion.release()
    handle.cancel()
  }

  func testActiveDownlinkSlowSubscriberDoesNotBlockFastSubscriber() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire(
      configuration: try NearWireConfiguration(eventStreamBufferCapacity: 1)
    )
    var slow = owner.events.makeAsyncIterator()
    var fast = owner.events.makeAsyncIterator()
    let run = Task { try await SDKActiveEventPump(attachment: attachment, owner: owner).run() }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 10,
            appDownlinkEventsPerSecond: 10
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    for sequence in 0..<2 {
      await fixture.driver.waitForReceive()
      let record = try makeSessionIncomingRecord(
        route: admitted.route,
        sequence: UInt64(sequence),
        id: String(format: "30000000-0000-0000-0000-%012d", 90 + sequence)
      )
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(WireEventPayload(record: record), phase: .active)
      )
      let fastEvent = try await fast.next()
      XCTAssertEqual(fastEvent?.session?.sequence, UInt64(sequence))
    }
    let slowFirst = try await slow.next()
    XCTAssertEqual(slowFirst?.session?.sequence, 0)
    do {
      _ = try await slow.next()
      XCTFail("Expected isolated slow-subscriber overflow.")
    } catch {
      assertNearWireError(error, code: .streamOverflow)
    }
    handle.cancel()
  }

  func testTransportBlockWithWholeTokensDoesNotPollUntilCapacityProgress() async throws {
    let transportLimits = try SecureTransportLimits(
      maximumPendingSendCount: 3,
      maximumPendingSendBytes: 4 * 1_024 * 1_024,
      maximumSingleSendBytes: WireFrameLimits.default.maximumEncodedFrameBytes(for: .event),
      connectionTimeoutSeconds: 1
    )
    let fixture = try SessionAdmissionFixture(
      transportLimits: transportLimits,
      autoCompleteSends: false
    )
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    _ = try await owner.send(type: "test.blocked", content: 1)
    let operationEntries = SDKLockedCapture<String>()
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          liveOperationHooks: SDKActiveLiveOperationHooks(
            beforeScheduleObservation: { operationEntries.append("schedule") },
            beforeDrain: { operationEntries.append("drain") }
          ),
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 100,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().isOutboundTransportBlocked
    }
    let blockedTurns = await attachment.transportCore.snapshot().outboundTurnStarts
    let blockedEntries = operationEntries.snapshot.count
    _ = try await owner.bufferDiagnostics()
    _ = await attachment.transportCore.snapshot()
    let stableBlockedSnapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(stableBlockedSnapshot.outboundTurnStarts, blockedTurns)
    XCTAssertEqual(operationEntries.snapshot.count, blockedEntries)
    XCTAssertTrue(stableBlockedSnapshot.hasOutboundDecision)

    fixture.driver.completeNextSend()
    await sessionWaitUntil {
      let snapshot = await attachment.transportCore.snapshot()
      return snapshot.outboundTurnStarts > blockedTurns
        && snapshot.isOutboundTransportBlocked
        && !snapshot.hasOutboundDrain
    }
    let stillBlockedTurns = await attachment.transportCore.snapshot().outboundTurnStarts
    let stillBlockedEntries = operationEntries.snapshot.count
    _ = try await owner.bufferDiagnostics()
    _ = await attachment.transportCore.snapshot()
    let secondStableBlockedSnapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(secondStableBlockedSnapshot.outboundTurnStarts, stillBlockedTurns)
    XCTAssertEqual(operationEntries.snapshot.count, stillBlockedEntries)

    fixture.driver.completeNextSend()
    await sessionWaitUntil { (try? await owner.bufferDiagnostics().eventCount) == 0 }
    let diagnostics = try await owner.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 0)
    handle.cancel()
  }

  func testPermanentCoreCapturesZeroFractionalOneAndBurstTokenAllowances() async throws {
    struct Case {
      let name: String
      let rate: Double
      let expectedAccepted: Int
      let expectedRemainingTokens: Double
      let exercisesFractionalRefill: Bool
    }
    let cases = [
      Case(
        name: "zero", rate: 0, expectedAccepted: 0, expectedRemainingTokens: 0,
        exercisesFractionalRefill: false),
      Case(
        name: "fractional", rate: 0.5, expectedAccepted: 1, expectedRemainingTokens: 0.5,
        exercisesFractionalRefill: true),
      Case(
        name: "one", rate: 0.5, expectedAccepted: 1, expectedRemainingTokens: 0,
        exercisesFractionalRefill: false),
      Case(
        name: "burst", rate: 2, expectedAccepted: 4, expectedRemainingTokens: 0,
        exercisesFractionalRefill: false),
    ]

    for value in cases {
      let fixture = try SessionAdmissionFixture()
      let admitted = try await fixture.admit()
      let attachment = try await admitted.attachEventPump()
      let clock = SDKTestClock(
        monotonic: 1_000_000_000,
        identifiers: (0..<5).map { _ in UUID() }
      )
      let owner = NearWire(
        configuration: try NearWireConfiguration(
          maximumUplinkEventsPerSecond: value.rate,
          maximumDownlinkEventsPerSecond: 1
        ),
        dependencies: clock.dependencies
      )
      for index in 0..<5 {
        _ = try await owner.send(type: "test.token-state.\(value.name)", content: index)
      }
      let run = Task {
        try await SDKActiveEventPump(
          attachment: attachment,
          owner: owner,
          dependencies: SDKActiveEventPumpDependencies(
            sleep: sessionTestSleep,
            sleepNanoseconds: { _ in throw CancellationError() },
            beforeWakeRegistration: {},
            beforeActivationCommit: {},
            beforeActivationResume: {},
            operationGateHooks: .none
          )
        ).run()
      }
      await fixture.driver.waitForReceive()
      await sessionWaitUntil {
        await attachment.transportCore.snapshot().state == .negotiatingPolicy
      }
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(
          WireFlowPolicyOffer(
            policy: try WireFlowPolicy(
              appUplinkEventsPerSecond: value.rate,
              appDownlinkEventsPerSecond: 1
            )
          ),
          phase: .negotiatingPolicy
        )
      )
      let handle = try await run.value
      if value.exercisesFractionalRefill {
        await sessionWaitUntil {
          let snapshot = await attachment.transportCore.snapshot()
          let diagnostics = try? await owner.bufferDiagnostics()
          return !snapshot.hasOutboundDrain && diagnostics?.eventCount == 4
        }
        let completedTurns = await attachment.transportCore.snapshot().outboundTurnStarts
        clock.advanceMonotonic(by: 1_000_000_000)
        _ = try await owner.send(type: "test.token-state.fractional-trigger", content: 5)
        await sessionWaitUntil {
          let snapshot = await attachment.transportCore.snapshot()
          return !snapshot.hasOutboundDrain && snapshot.outboundTurnStarts > completedTurns
        }
      }
      let expectedRemainingEvents =
        5 - value.expectedAccepted + (value.exercisesFractionalRefill ? 1 : 0)
      await sessionWaitUntil {
        let snapshot = await attachment.transportCore.snapshot()
        let diagnostics = try? await owner.bufferDiagnostics()
        return !snapshot.hasOutboundDrain
          && diagnostics?.eventCount == expectedRemainingEvents
      }
      let snapshot = await attachment.transportCore.snapshot()
      let diagnostics = try await owner.bufferDiagnostics()
      XCTAssertEqual(snapshot.outboundNextSequence, UInt64(value.expectedAccepted), value.name)
      XCTAssertEqual(
        try XCTUnwrap(snapshot.uplinkAvailableTokens),
        value.expectedRemainingTokens,
        accuracy: 0.000_000_001,
        value.name
      )
      XCTAssertEqual(diagnostics.eventCount, expectedRemainingEvents, value.name)
      XCTAssertEqual(
        diagnostics.statistics.transportAccepted,
        UInt64(value.expectedAccepted),
        value.name
      )
      handle.cancel()
      await sessionWaitUntil { fixture.driver.cancelCount == 1 }
    }
  }

  func testCapacityCompletionBeforeBlockedResultRetriesAcceptedCandidate() async throws {
    let transportLimits = try SecureTransportLimits(
      maximumPendingSendCount: 3,
      maximumPendingSendBytes: 4 * 1_024 * 1_024,
      maximumSingleSendBytes: WireFrameLimits.default.maximumEncodedFrameBytes(for: .event),
      connectionTimeoutSeconds: 1
    )
    let fixture = try SessionAdmissionFixture(
      transportLimits: transportLimits,
      autoCompleteSends: false
    )
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    _ = try await owner.send(type: "test.completion-before-result", content: 1)
    let secondTurn = SessionNthAsyncBarrier(targetEntry: 2)
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeOutboundTurnCompletion: { await secondTurn.waitAtTarget() },
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 100,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().isOutboundTransportBlocked
    }

    fixture.driver.completeNextSend()
    await secondTurn.waitUntilTargetEntered()
    fixture.driver.completeNextSend()
    secondTurn.release()
    await sessionWaitUntil { (try? await owner.bufferDiagnostics().eventCount) == 0 }
    let diagnostics = try await owner.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 0)
    XCTAssertGreaterThanOrEqual(fixture.driver.sentData.count, 3)
    handle.cancel()
  }

  func testActiveFrameQuantumFailsClosedWithoutContinuationChain() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let limits = try SDKActiveEventPumpLimits(maximumCompletedFramesPerReceive: 2)
    let owner = NearWire()
    defer { withExtendedLifetime(owner) {} }
    let run = Task {
      try await SDKActiveEventPump(attachment: attachment, owner: owner, limits: limits).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    let ping = try fixture.sessionCodec.encode(WirePing(nonce: 1), phase: .active)
    fixture.driver.completeReceive(ping + ping)
    await fixture.driver.waitForReceive()
    let withinQuantumSnapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(withinQuantumSnapshot.state, .active)

    let split = ping.index(ping.startIndex, offsetBy: ping.count / 2)
    fixture.driver.completeReceive(ping + ping + ping[..<split])
    await fixture.driver.waitForReceive()
    let fragmentedSnapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(fragmentedSnapshot.state, .active)
    fixture.driver.completeReceive(Data(ping[split...]))
    await fixture.driver.waitForReceive()
    let completedFragmentSnapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(completedFragmentSnapshot.state, .active)

    fixture.driver.completeReceive(ping + ping + ping)
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().terminalCode == .activeWorkLimitExceeded
    }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .activeWorkLimitExceeded)
    XCTAssertEqual(snapshot.retainedIncomingEvents, 0)
    handle.cancel()
  }

  func testOwnerShutdownSignalDuringRefreshSchedulesOneSuccessor() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let barrier = SessionOneShotAsyncBarrier()
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeOwnerRefreshCompletion: { await barrier.waitOnce() },
          operationGateHooks: .none
        )
      ).run()
    }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    _ = try await owner.send(type: "test.refresh-race", content: 1)
    await barrier.waitUntilEntered()
    await owner.shutdown()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().hasPendingOutboundWork
    }
    barrier.release()
    await assertAdmissionError(.ownerUnavailable) { _ = try await run.value }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .ownerUnavailable)
    XCTAssertFalse(snapshot.hasOwnerRefresh)
    XCTAssertFalse(snapshot.hasPendingOutboundWork)
  }

  func testCapturedOwnerUnavailablePrecedesInitialPolicyActivation() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let barrier = SessionOneShotAsyncBarrier()
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeOwnerRefreshCompletion: { await barrier.waitOnce() },
          operationGateHooks: .none
        )
      ).run()
    }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    await owner.shutdown()
    await barrier.waitUntilEntered()
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().deferredPolicyCount == 1
    }
    let held = await attachment.transportCore.snapshot()
    XCTAssertEqual(held.state, .negotiatingPolicy)
    XCTAssertEqual(fixture.driver.sentData.count, 1)
    barrier.release()
    await assertAdmissionError(.ownerUnavailable) { _ = try await run.value }
    let terminal = await attachment.transportCore.snapshot()
    XCTAssertEqual(terminal.terminalCode, .ownerUnavailable)
    XCTAssertEqual(fixture.driver.sentData.count, 1)
  }

  func testCapturedLiveOwnerResultAllowsDeferredInitialPolicy() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let barrier = SessionOneShotAsyncBarrier()
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeOwnerRefreshCompletion: { await barrier.waitOnce() },
          operationGateHooks: .none
        )
      ).run()
    }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    _ = try await owner.send(type: "test.live-refresh", content: 1)
    await barrier.waitUntilEntered()
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().deferredPolicyCount == 1
    }
    barrier.release()
    let handle = try await run.value
    let active = await attachment.transportCore.snapshot()
    XCTAssertEqual(active.state, .active)
    XCTAssertEqual(active.deferredPolicyCount, 0)
    XCTAssertEqual(active.effectiveUplinkRate, 1)
    handle.cancel()
  }

  func testInitialPolicyOutranksRelatchedOwnerSignalStorm() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let refresh = SessionOneShotAsyncBarrier()
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeOwnerRefreshCompletion: { await refresh.waitOnce() },
          operationGateHooks: .none
        )
      ).run()
    }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    _ = try await owner.send(type: "test.signal-storm.seed", content: 0)
    await refresh.waitUntilEntered()
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 100,
            appDownlinkEventsPerSecond: 100
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    for index in 1...64 {
      _ = try await owner.send(type: "test.signal-storm", content: index)
    }
    await sessionWaitUntil {
      let snapshot = await attachment.transportCore.snapshot()
      return snapshot.deferredPolicyCount == 1 && snapshot.hasPendingOutboundWork
    }

    refresh.release()
    let handle = try await run.value
    let active = await attachment.transportCore.snapshot()
    XCTAssertEqual(active.state, .active)
    XCTAssertEqual(active.deferredPolicyCount, 0)
    XCTAssertEqual(active.effectiveUplinkRate, 100)
    handle.cancel()
  }

  func testDynamicPolicyClockReversalFailsBeforeAcceptanceOrBucketInstall() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let clock = SDKTestClock(monotonic: 2_000_000_000)
    let owner = NearWire(dependencies: clock.dependencies)
    let run = Task {
      try await SDKActiveEventPump(attachment: attachment, owner: owner).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 10,
            appDownlinkEventsPerSecond: 10
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await sessionWaitUntil {
      !(await attachment.transportCore.snapshot().hasOutboundDrain)
    }
    let acceptedSendCount = fixture.driver.sentData.count
    clock.setMonotonic(1_000_000_000)
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 5,
            appDownlinkEventsPerSecond: 4
          )
        ),
        phase: .active
      )
    )
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().terminalCode == .clockFailed
    }
    let terminal = await attachment.transportCore.snapshot()
    XCTAssertNil(terminal.effectiveUplinkRate)
    XCTAssertNil(terminal.effectiveDownlinkRate)
    XCTAssertNil(terminal.uplinkAvailableTokens)
    XCTAssertEqual(fixture.driver.sentData.count, acceptedSendCount)
    await sessionWaitUntil { fixture.driver.cancelCount == 1 }
    XCTAssertEqual(fixture.driver.cancelCount, 1)
    handle.cancel()
  }

  func testDeferredPolicyCommitsAfterBlockedOutboundResult() async throws {
    let transportLimits = try SecureTransportLimits(
      maximumPendingSendCount: 3,
      maximumPendingSendBytes: 4 * 1_024 * 1_024,
      maximumSingleSendBytes: WireFrameLimits.default.maximumEncodedFrameBytes(for: .event),
      connectionTimeoutSeconds: 1
    )
    let fixture = try SessionAdmissionFixture(
      transportLimits: transportLimits,
      autoCompleteSends: false
    )
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    _ = try await owner.send(type: "test.blocked-policy", content: 1)
    let barrier = SessionOneShotAsyncBarrier()
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeOutboundTurnCompletion: { await barrier.waitOnce() },
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 100,
            appDownlinkEventsPerSecond: 100
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await barrier.waitUntilEntered()
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 7,
            appDownlinkEventsPerSecond: 6
          )
        ),
        phase: .active
      )
    )
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().deferredPolicyCount == 1
    }
    barrier.release()
    await sessionWaitUntil {
      let snapshot = await attachment.transportCore.snapshot()
      return snapshot.deferredPolicyCount == 0 && snapshot.effectiveUplinkRate == 7
    }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.effectiveUplinkRate, 7)
    XCTAssertEqual(snapshot.effectiveDownlinkRate, 6)
    XCTAssertEqual(snapshot.deferredPolicyCount, 0)
    handle.cancel()
  }

  func testTerminationObservationCancellationWinnerSurvivesTerminalCleanup() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    defer { withExtendedLifetime(owner) {} }
    let run = Task {
      try await SDKActiveEventPump(attachment: attachment, owner: owner).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    let delayed = SessionDelayedNotifications()
    let gate = SDKSessionPullCancellationGate(notificationScheduler: { delayed.store($0) })
    let wait = Task {
      try await attachment.transportCore.waitForActiveTermination(
        token: SDKActiveTerminationToken(),
        cancellationGate: gate
      )
    }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().hasPendingTerminationObservation
    }
    gate.cancel()
    handle.cancel()
    await assertAdmissionError(.terminationWaitCancelled) { _ = try await wait.value }
    delayed.fireAll()
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .cancelled)
    XCTAssertFalse(snapshot.hasPendingTerminationObservation)
  }

  func testLiveOperationHooksTargetCompletionObserverAndTerminalBoundaries() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let entries = SDKLockedCapture<String>()
    let owner = NearWire()
    defer { withExtendedLifetime(owner) {} }
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          liveOperationHooks: SDKActiveLiveOperationHooks(
            beforeMailboxCompletion: { entries.append("mailbox-completion") },
            beforeObserverCancellation: { entries.append("observer-cancellation") },
            beforeTerminalClose: { entries.append("terminal-close") }
          ),
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await sdkWaitUntil { entries.snapshot.contains("mailbox-completion") }

    let observer = Task { try await handle.termination.wait() }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().hasPendingTerminationObservation
    }
    observer.cancel()
    do {
      _ = try await observer.value
      XCTFail("Expected observer-local cancellation.")
    } catch {
      XCTAssertEqual(
        (error as? SDKSessionAdmissionError)?.code,
        .terminationWaitCancelled
      )
    }
    await sdkWaitUntil { entries.snapshot.contains("observer-cancellation") }

    handle.cancel()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().terminalCode == .cancelled
    }
    XCTAssertTrue(entries.snapshot.contains("terminal-close"))
    XCTAssertEqual(entries.snapshot.filter { $0 == "observer-cancellation" }.count, 1)
    XCTAssertEqual(entries.snapshot.filter { $0 == "terminal-close" }.count, 1)
  }

  func testRemoteDropDiagnosticsAccumulateWithSaturation() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    defer { withExtendedLifetime(owner) {} }
    let run = Task {
      try await SDKActiveEventPump(attachment: attachment, owner: owner).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    let maximum = try fixture.sessionCodec.encode(
      WireDropSummaryPayload(
        overflowDropped: UInt64.max,
        expired: UInt64.max,
        coalesced: UInt64.max
      ),
      phase: .active
    )
    let additional = try fixture.sessionCodec.encode(
      WireDropSummaryPayload(overflowDropped: 1, expired: 1, coalesced: 1),
      phase: .active
    )
    fixture.driver.completeReceive(maximum + additional)
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().remoteOverflowDropped == UInt64.max
    }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.remoteOverflowDropped, UInt64.max)
    XCTAssertEqual(snapshot.remoteExpired, UInt64.max)
    XCTAssertEqual(snapshot.remoteCoalesced, UInt64.max)
    handle.cancel()
  }

  func testZeroRateDownlinkExpiryIncrementsLocalDiagnostic() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let clock = SDKTestClock()
    let owner = NearWire(dependencies: clock.dependencies)
    let sleeper = SessionNanosecondSleepController()
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          sleepNanoseconds: { try await sleeper.sleep(nanoseconds: $0) },
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 0
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    let record = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 0,
      id: "30000000-0000-0000-0000-000000000031",
      remainingTTLNanoseconds: 10
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(WireEventPayload(record: record), phase: .active)
    )
    await sleeper.waitForRequest(nanoseconds: 10)
    clock.advanceMonotonic(by: 10)
    sleeper.fire(nanoseconds: 10)
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().localIncomingExpired == 1
    }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.localIncomingExpired, 1)
    XCTAssertEqual(snapshot.retainedIncomingEvents, 0)
    XCTAssertEqual(snapshot.retainedIncomingEncodedBytes, 0)
    handle.cancel()
  }

  func testIncomingTurnQuantumDoesNotPublishAfterConsumingExpiryAllowance() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let clock = SDKTestClock()
    let owner = NearWire(dependencies: clock.dependencies)
    let sleeper = SessionNanosecondSleepController()
    let immediateContinuation = SessionOneShotAsyncBarrier()
    let limits = try SDKActiveEventPumpLimits(maximumIncomingPublicationsPerTurn: 1)
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        limits: limits,
        dependencies: SDKActiveEventPumpDependencies(
          sleep: sessionTestSleep,
          sleepNanoseconds: { try await sleeper.sleep(nanoseconds: $0) },
          beforeWakeRegistration: {},
          beforeActivationCommit: {},
          beforeActivationResume: {},
          beforeImmediateIncomingDecisionCompletion: {
            await immediateContinuation.waitOnce()
          },
          operationGateHooks: .none
        )
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 0
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    let expiring = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 0,
      id: "30000000-0000-0000-0000-000000000071",
      remainingTTLNanoseconds: 500_000_000
    )
    let live = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 1,
      id: "30000000-0000-0000-0000-000000000072",
      remainingTTLNanoseconds: 2_000_000_000
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireEventBatchPayload(records: [expiring, live]),
        phase: .active
      )
    )
    await sleeper.waitForRequest(nanoseconds: 500_000_000)
    await fixture.driver.waitForReceive()
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .active
      )
    )
    clock.advanceMonotonic(by: 1_000_000_000)
    sleeper.fire(nanoseconds: 500_000_000)
    await immediateContinuation.waitUntilEntered()
    let afterExpiry = await attachment.transportCore.snapshot()
    XCTAssertEqual(afterExpiry.localIncomingExpired, 1)
    XCTAssertEqual(afterExpiry.retainedIncomingEvents, 1)
    XCTAssertTrue(afterExpiry.hasIncomingDecision)
    immediateContinuation.release()
    handle.cancel()
  }

  func testOwnerShutdownDuringPolicyNegotiationIsLevelTriggered() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let run = Task { try await SDKActiveEventPump(attachment: attachment, owner: owner).run() }
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    await owner.shutdown()
    await assertAdmissionError(.ownerUnavailable) { _ = try await run.value }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .ownerUnavailable)
    XCTAssertFalse(snapshot.hasOwnerRefresh)
    await sessionWaitUntil { fixture.driver.cancelCount == 1 }
  }

  func testOwnerShutdownTerminatesActiveEmptyAndZeroRateSessions() async throws {
    for rate in [1.0, 0.0] {
      let fixture = try SessionAdmissionFixture()
      let admitted = try await fixture.admit()
      let attachment = try await admitted.attachEventPump()
      let owner = NearWire()
      let run = Task {
        try await SDKActiveEventPump(attachment: attachment, owner: owner).run()
      }
      await fixture.driver.waitForReceive()
      await sessionWaitUntil {
        await attachment.transportCore.snapshot().state == .negotiatingPolicy
      }
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(
          WireFlowPolicyOffer(
            policy: try WireFlowPolicy(
              appUplinkEventsPerSecond: rate,
              appDownlinkEventsPerSecond: rate
            )
          ),
          phase: .negotiatingPolicy
        )
      )
      let handle = try await run.value
      await owner.shutdown()
      await sessionWaitUntil {
        await attachment.transportCore.snapshot().terminalCode == .ownerUnavailable
      }
      let terminal = await attachment.transportCore.snapshot()
      XCTAssertEqual(terminal.terminalCode, .ownerUnavailable)
      XCTAssertFalse(terminal.hasOutboundDecision)
      XCTAssertFalse(terminal.hasIncomingDecision)
      handle.cancel()
    }
  }

  func testPrecancelledRunnerWinsOverExistingPolicyPullOwnership() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let pull = Task { try await attachment.nextPolicyMessage() }
    await sessionWaitUntil { await attachment.transportCore.snapshot().hasPendingPolicyPull }
    let gate = SDKSessionPullCancellationGate()
    gate.cancel()
    await assertAdmissionError(.cancelled) {
      try await attachment.transportCore.startActivePump(
        token: SDKActiveRunToken(),
        cancellationGate: gate,
        owner: NearWire(),
        limits: .default,
        dependencies: .live
      )
    }
    await assertAdmissionError(.cancelled) { _ = try await pull.value }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .cancelled)
  }

  func testCancellationLatchedAtActivationCommitReturnsNoHandle() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let barrier = SDKSynchronousBarrier()
    let pump = SDKActiveEventPump(
      attachment: attachment,
      owner: NearWire(),
      dependencies: SDKActiveEventPumpDependencies(
        sleep: sessionTestSleep,
        beforeWakeRegistration: {},
        beforeActivationCommit: { barrier.block() },
        beforeActivationResume: {},
        operationGateHooks: .none
      )
    )
    let run = Task { try await pump.run() }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    await barrier.waitUntilReached()
    run.cancel()
    barrier.release()
    await assertAdmissionError(.cancelled) { _ = try await run.value }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .cancelled)
  }

  func testActiveDownlinkRouteMismatchFailsBeforePublication() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    let run = Task { try await SDKActiveEventPump(attachment: attachment, owner: owner).run() }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    var wrong = admitted.route
    wrong = SDKSessionRoute(
      sessionEpoch: wrong.sessionEpoch,
      viewerID: wrong.viewerID,
      appID: "wrong-app"
    )
    let record = try makeSessionIncomingRecord(
      route: wrong,
      sequence: 0,
      id: "30000000-0000-0000-0000-000000000011"
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(WireEventPayload(record: record), phase: .active)
    )
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().terminalCode == .routeMismatch
    }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .routeMismatch)
    XCTAssertEqual(snapshot.retainedIncomingEvents, 0)
    XCTAssertEqual(owner.streamSubscriberCounts.events, 0)
    handle.cancel()
  }

  func testActiveDownlinkWrongDirectionMapsSequenceViolation() async throws {
    let fixture = try SessionAdmissionFixture()
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let owner = NearWire()
    defer { withExtendedLifetime(owner) {} }
    let run = Task {
      try await SDKActiveEventPump(attachment: attachment, owner: owner).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 1
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    let wrongDirection = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 0,
      id: "30000000-0000-0000-0000-000000000051",
      direction: .appToViewer
    )
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireEventPayload(record: wrongDirection),
        phase: .active
      )
    )
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().terminalCode == .sequenceViolation
    }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .sequenceViolation)
    handle.cancel()
  }

  func testHeterogeneousBatchUsesExactPerRecordRetentionBytes() async throws {
    let fixture = try SessionAdmissionFixture(maximumEventBytes: 1_024)
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    let limits = try SDKActiveEventPumpLimits(maximumIncomingEncodedBytes: 1_024)
    let owner = NearWire()
    defer { withExtendedLifetime(owner) {} }
    let run = Task {
      try await SDKActiveEventPump(
        attachment: attachment,
        owner: owner,
        limits: limits
      ).run()
    }
    await fixture.driver.waitForReceive()
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().state == .negotiatingPolicy
    }
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 1,
            appDownlinkEventsPerSecond: 0
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    let handle = try await run.value
    await fixture.driver.waitForReceive()
    let first = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 0,
      id: "30000000-0000-0000-0000-000000000061",
      content: .string(String(repeating: "a", count: 450))
    )
    let second = try makeSessionIncomingRecord(
      route: admitted.route,
      sequence: 1,
      id: "30000000-0000-0000-0000-000000000062",
      content: .string(String(repeating: "b", count: 450))
    )
    let firstBytes = try first.deterministicEncodedByteCount()
    let secondBytes = try second.deterministicEncodedByteCount()
    XCTAssertLessThanOrEqual(firstBytes, 1_024)
    XCTAssertLessThanOrEqual(secondBytes, 1_024)
    XCTAssertGreaterThan(firstBytes + secondBytes, 1_024)
    fixture.driver.completeReceive(
      try fixture.sessionCodec.encode(
        WireEventBatchPayload(records: [first, second], limits: fixture.sessionCodec.limits),
        phase: .active
      )
    )
    await sessionWaitUntil {
      await attachment.transportCore.snapshot().terminalCode == .activeIngressOverflow
    }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .activeIngressOverflow)
    XCTAssertEqual(snapshot.retainedIncomingEvents, 0)
    XCTAssertEqual(snapshot.retainedIncomingEncodedBytes, 0)
    handle.cancel()
  }

  func testIncomingInFlightContributesToCombinedCountAndByteLimits() async throws {
    func exercise(
      maximumEventBytes: Int,
      limits: SDKActiveEventPumpLimits,
      content: JSONValue
    ) async throws {
      let fixture = try SessionAdmissionFixture(maximumEventBytes: maximumEventBytes)
      let admitted = try await fixture.admit()
      let attachment = try await admitted.attachEventPump()
      let beforeCompletion = SessionOneShotAsyncBarrier()
      let owner = NearWire()
      defer { withExtendedLifetime(owner) {} }
      let run = Task {
        try await SDKActiveEventPump(
          attachment: attachment,
          owner: owner,
          limits: limits,
          dependencies: SDKActiveEventPumpDependencies(
            sleep: sessionTestSleep,
            beforeWakeRegistration: {},
            beforeActivationCommit: {},
            beforeActivationResume: {},
            beforeIncomingPublicationCompletion: { await beforeCompletion.waitOnce() },
            operationGateHooks: .none
          )
        ).run()
      }
      await fixture.driver.waitForReceive()
      await sessionWaitUntil {
        await attachment.transportCore.snapshot().state == .negotiatingPolicy
      }
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(
          WireFlowPolicyOffer(
            policy: try WireFlowPolicy(
              appUplinkEventsPerSecond: 1,
              appDownlinkEventsPerSecond: 10
            )
          ),
          phase: .negotiatingPolicy
        )
      )
      let handle = try await run.value
      await fixture.driver.waitForReceive()
      let first = try makeSessionIncomingRecord(
        route: admitted.route,
        sequence: 0,
        id: "30000000-0000-0000-0000-000000000101",
        content: content
      )
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(WireEventPayload(record: first), phase: .active)
      )
      await beforeCompletion.waitUntilEntered()
      let inFlight = await attachment.transportCore.snapshot()
      XCTAssertEqual(inFlight.retainedIncomingEvents, 1)
      XCTAssertEqual(
        inFlight.retainedIncomingEncodedBytes,
        try first.deterministicEncodedByteCount()
      )

      await fixture.driver.waitForReceive()
      let second = try makeSessionIncomingRecord(
        route: admitted.route,
        sequence: 1,
        id: "30000000-0000-0000-0000-000000000102",
        content: content
      )
      fixture.driver.completeReceive(
        try fixture.sessionCodec.encode(WireEventPayload(record: second), phase: .active)
      )
      await sessionWaitUntil {
        await attachment.transportCore.snapshot().terminalCode == .activeIngressOverflow
      }
      let terminal = await attachment.transportCore.snapshot()
      XCTAssertEqual(terminal.terminalCode, .activeIngressOverflow)
      XCTAssertEqual(terminal.retainedIncomingEvents, 0)
      XCTAssertEqual(terminal.retainedIncomingEncodedBytes, 0)
      beforeCompletion.release()
      handle.cancel()
    }

    try await exercise(
      maximumEventBytes: 1_024,
      limits: SDKActiveEventPumpLimits(
        maximumIncomingEvents: 1,
        maximumIncomingEncodedBytes: 8 * 1_024 * 1_024
      ),
      content: .integer(1)
    )
    try await exercise(
      maximumEventBytes: 1_024,
      limits: SDKActiveEventPumpLimits(
        maximumIncomingEvents: 2,
        maximumIncomingEncodedBytes: 1_024
      ),
      content: .string(String(repeating: "x", count: 450))
    )
  }

  func testTransportCrossLimitIncludesCompleteEventWrapper() async throws {
    let codec = try makeSDKTestSessionCodec(maximumEventBytes: 1_024)
    let maximumFrameBytes = try codec.maximumEncodedSingleEventFrameBytes()
    let transportLimits = try SecureTransportLimits(
      maximumPendingSendBytes: 4 * 1_024 * 1_024,
      maximumSingleSendBytes: maximumFrameBytes - 1,
      connectionTimeoutSeconds: 1
    )
    let fixture = try SessionAdmissionFixture(
      maximumEventBytes: 1_024,
      transportLimits: transportLimits
    )
    let admitted = try await fixture.admit()
    let attachment = try await admitted.attachEventPump()
    await assertAdmissionError(.invalidLocalConfiguration) {
      _ = try await SDKActiveEventPump(attachment: attachment, owner: NearWire()).run()
    }
    let snapshot = await attachment.transportCore.snapshot()
    XCTAssertEqual(snapshot.terminalCode, .invalidLocalConfiguration)
  }

  func testIncomingQueueKeepsExactFIFOAndOneDeadlineNodePerItem() throws {
    let route = SDKSessionRoute(
      sessionEpoch: UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!,
      viewerID: "viewer-installation",
      appID: "phone-installation"
    )
    func item(_ suffix: String, sequence: UInt64, ttl: UInt64, bytes: Int) throws
      -> SDKIncomingEventItem
    {
      let record = try makeSessionIncomingRecord(
        route: route,
        sequence: sequence,
        id: "30000000-0000-0000-0000-\(suffix)",
        remainingTTLNanoseconds: ttl
      )
      return SDKIncomingEventItem(
        received: try record.receiverEvent(receivedAtNanoseconds: 100),
        encodedByteCount: bytes
      )
    }

    let first = try item("000000000021", sequence: 0, ttl: 30, bytes: 11)
    let second = try item("000000000022", sequence: 1, ttl: 10, bytes: 12)
    let third = try item("000000000023", sequence: 2, ttl: 20, bytes: 13)
    var queue = SDKIncomingEventQueue(maximumCount: 3, maximumEncodedBytes: 64)
    try queue.appendAtomically([first, second, third])
    XCTAssertEqual(
      queue.snapshot,
      .init(count: 3, encodedBytes: 36, heapNodeCount: 3, nextDeadlineNanoseconds: 110)
    )

    XCTAssertEqual(
      try queue.removeExpired(nowNanoseconds: 115, maximumCount: 1),
      [
        second.received.envelope.id
      ])
    XCTAssertEqual(queue.snapshot.count, 2)
    XCTAssertEqual(queue.snapshot.heapNodeCount, 2)
    XCTAssertEqual(queue.popHead(), first)
    XCTAssertEqual(queue.popHead(), third)
    XCTAssertEqual(queue.snapshot.count, 0)
    XCTAssertEqual(queue.snapshot.heapNodeCount, 0)

    var atomic = SDKIncomingEventQueue(maximumCount: 2, maximumEncodedBytes: 64)
    XCTAssertThrowsError(try atomic.appendAtomically([first, second, third]))
    XCTAssertEqual(atomic.snapshot.count, 0)
    XCTAssertEqual(atomic.snapshot.heapNodeCount, 0)
    XCTAssertEqual(atomic.snapshot.encodedBytes, 0)
  }

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
    guard case .batch(let batch) = terminalIngress.takeBatch(maximumItems: 8) else {
      return XCTFail("Expected terminal to replace queued bytes.")
    }
    XCTAssertEqual(batch.count, 1)
    if case .channel(.terminated) = batch.first {
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
      await sdkWaitUntil { discovery.cancelCount == 1 }
      XCTAssertEqual(discovery.cancelCount, 1)
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
      await sdkWaitUntil { discovery.cancelCount == 1 }
      XCTAssertEqual(discovery.cancelCount, 1)
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
    XCTAssertEqual(fixture.discovery.cancelCount, 0)
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
    await sdkWaitUntil { fixture.discovery.cancelCount == 1 }
    XCTAssertEqual(fixture.discovery.cancelCount, 1)
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
      await sdkWaitUntil { fixture.discovery.cancelCount == 1 }
      XCTAssertEqual(fixture.discovery.cancelCount, 1)
    }

    do {
      let barrier = SessionAsyncBarrier()
      let counters = SessionDependencyCounters()
      let viewerHello = try makeSessionHello(role: .viewer)
      let discovery = SessionTestDiscovery(
        result: try makeDiscoveredViewer(viewerHello: viewerHello)
      )
      let admission = SDKSessionAdmission(
        pairingCode: try PairingCode("ABC234"),
        localHello: try makeSessionHello(role: .app),
        phaseObserver: {
          await barrier.wait()
          return .authorized
        },
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
      await barrier.waitUntilEntered()
      await admission.cancel()
      barrier.release()

      await assertAdmissionError(.cancelled) { _ = try await task.value }
      XCTAssertEqual(discovery.cancelCount, 1)
      XCTAssertEqual(counters.channelCount, 0)
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
    let installedLimits = channel.limits
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
    await sdkWaitUntil { fixture.discovery.cancelCount == 1 }
    XCTAssertEqual(fixture.discovery.cancelCount, 1)
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
    await sdkWaitUntil { discovery.cancelCount == 1 }
    XCTAssertEqual(discovery.cancelCount, 1)
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
        case .serviceRegistered, .serviceRemoved:
          break
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

      let attachment = try await admitted.attachEventPump()
      let owner = NearWire()
      _ = try await owner.send(type: "integration.uplink", content: ["value": 1])
      let activeRun = Task {
        try await SDKActiveEventPump(attachment: attachment, owner: owner).run()
      }
      await sessionWaitUntil {
        await attachment.transportCore.snapshot().state == .negotiatingPolicy
      }
      let viewerChannel = try XCTUnwrap(recorder.viewerChannel)
      try await viewerChannel.send(
        try codec.encode(
          WireFlowPolicyOffer(
            policy: try WireFlowPolicy(
              appUplinkEventsPerSecond: 10,
              appDownlinkEventsPerSecond: 10
            )
          ),
          phase: .negotiatingPolicy
        )
      )
      let activeHandle = try await activeRun.value

      let eventTask = Task { () throws -> NearWireEvent? in
        var iterator = owner.events.makeAsyncIterator()
        return try await iterator.next()
      }
      await sdkWaitUntil { owner.streamSubscriberCounts.events == 1 }
      let downlinkRecord = try makeSessionIncomingRecord(
        route: admitted.route,
        sequence: 0,
        id: "30000000-0000-0000-0000-000000000041"
      )
      try await viewerChannel.send(
        try codec.encode(WireEventPayload(record: downlinkRecord), phase: .active)
      )
      let receivedEvent = try await eventTask.value
      let published = try XCTUnwrap(receivedEvent)
      XCTAssertEqual(published.id.uuidString.lowercased(), downlinkRecord.envelope.id.rawValue)

      await sdkWaitUntil {
        sessionFrameCount(in: Data(recorder.receivedBytes.dropFirst(expectedAppHello.count))) >= 2
      }
      let activeAppBytes = Data(recorder.receivedBytes.dropFirst(expectedAppHello.count))
      let messageTypes = try decodeSessionMessageTypes(activeAppBytes, codec: codec)
      XCTAssertEqual(Array(messageTypes.prefix(2)), [.flowPolicyAccepted, .event])
      let diagnostics = try await owner.bufferDiagnostics()
      XCTAssertEqual(diagnostics.eventCount, 0)
      XCTAssertFalse(recorder.didFail)

      activeHandle.cancel()
      await viewerChannel.cancel()
      listener.cancel()
    #else
      throw XCTSkip("The unrestricted real-TLS admission integration gate runs on macOS.")
    #endif
  }

  func testPublicConnectUsesProductionTLSBidirectionalEventsAndRealProcessLease() async throws {
    #if os(macOS)
      let configuration = try NearWireConfiguration()
      let plan = try SDKPublicConnectionLimitPlan.make(configuration: configuration)
      let appInstallationID = "123e4567-e89b-42d3-a456-426614174001"
      let appHello = try WireHello(
        productVersion: SDKProductVersion.wireValue(),
        role: .app,
        installationID: EndpointID(rawValue: appInstallationID),
        maximumEventBytes: plan.maximumEventRecordBytes,
        limits: plan.wireLimits
      )
      let viewerHello = try WireHello(
        productVersion: WireProductVersion("1.0.0"),
        role: .viewer,
        installationID: EndpointID(rawValue: "viewer-installation"),
        maximumEventBytes: plan.maximumEventRecordBytes,
        limits: plan.wireLimits
      )
      let negotiation = try WireNegotiator.negotiate(local: appHello, remote: viewerHello)
      let codec = try WireSessionCodec(negotiation: negotiation, baseLimits: plan.wireLimits)
      let sessionEpoch = try SessionEpoch(
        rawValue: "123e4567-e89b-12d3-a456-426614174000"
      )
      let acknowledgement = try WireNegotiator.makeAcknowledgement(
        result: negotiation,
        sessionEpoch: sessionEpoch,
        limits: plan.wireLimits
      )
      let expectedAppHello = try WirePreHandshakeCodec(limits: plan.wireLimits).encode(appHello)
      let viewerAdmissionBytes =
        try WirePreHandshakeCodec(limits: plan.wireLimits).encode(viewerHello)
        + codec.encode(acknowledgement, phase: .awaitingApproval)

      let securityIdentity = try makeSessionTLSViewerIdentity()
      guard try sessionSystemTrustEvaluationIsAvailable(identity: securityIdentity) else {
        throw XCTSkip("Security trust evaluation is unavailable in the restricted test sandbox.")
      }
      let listener = try SecureViewerTransport.makeListener(
        identity: ViewerTransportIdentity(identity: securityIdentity),
        limits: plan.transportLimits
      )
      let connectionQueue = DispatchQueue(label: "nearwire.tests.public-connect.real-tls")
      let verificationQueue = DispatchQueue(
        label: "nearwire.tests.public-connect.real-tls-verify"
      )
      let listenerReady = expectation(description: "public-connect TLS listener ready")
      let viewerReady = expectation(description: "public-connect TLS Viewer ready")
      let appHelloReceived = expectation(description: "public-connect App hello received")
      let recorder = SessionTLSIntegrationRecorder(
        outboundBytes: viewerAdmissionBytes,
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
        case .serviceRegistered, .serviceRemoved:
          break
        case .cancelled:
          break
        }
      }

      await fulfillment(of: [listenerReady], timeout: 2)
      let port = try XCTUnwrap(recorder.port)
      let endpointPort = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
      let identity = try XCTUnwrap(
        NearWireBonjourServiceIdentity(
          instanceName: "NearWire-ABC234",
          type: NearWireBonjour.serviceType,
          domain: NearWireBonjour.localDomain,
          viewerDiscriminator: ViewerDiscoveryDiscriminator(
            viewerInstallationID: viewerHello.installationID
          )
        )
      )
      let discovered = DiscoveredViewer(
        identity: identity,
        endpoint: .hostPort(host: "127.0.0.1", port: endpointPort)
      )
      let connectionDependencies = SDKPublicConnectionDependencies(
        makeTransitionGate: { SDKSessionTransitionGate() },
        claimLease: {
          SDKPublicConnectionLease(handle: try ProcessConnectionLeaseRegistry.claim())
        },
        loadInstallationIdentity: { appInstallationID },
        bundleMetadata: {
          SDKBundleMetadataInput(
            applicationIdentifier: nil,
            shortVersion: nil,
            buildVersion: nil,
            displayName: nil,
            bundleName: nil
          )
        },
        makeAdmission: { pairingCode, hello, activePlan, gate, phaseObserver in
          SDKSessionAdmission(
            pairingCode: pairingCode,
            localHello: hello,
            wireLimits: activePlan.wireLimits,
            transportLimits: activePlan.transportLimits,
            admissionLimits: activePlan.admissionLimits,
            transitionGate: gate,
            phaseObserver: phaseObserver,
            dependencies: SDKSessionAdmissionDependencies(
              makeDiscovery: { _ in SessionTestDiscovery(result: discovered) },
              makeChannel: { discovered, handler in
                SecureAppTransport.makeChannel(
                  endpoint: discovered.endpoint,
                  connectionQueue: connectionQueue,
                  verificationQueue: verificationQueue,
                  limits: activePlan.transportLimits,
                  eventHandler: handler
                )
              },
              sleep: sessionTestSleep
            )
          )
        },
        makePump: { attachment, owner, limits in
          SDKActiveEventPump(attachment: attachment, owner: owner, limits: limits)
        },
        hooks: .none
      )
      let owner = NearWire(
        configuration: configuration,
        dependencies: .live,
        connectionDependencies: connectionDependencies
      )
      _ = try await owner.send(type: "integration.uplink", content: ["value": 1])
      let connectTask = Task { try await owner.connect(code: "ABC234") }

      await fulfillment(of: [viewerReady, appHelloReceived], timeout: 3)
      let competitorIdentityLoads = SDKLockedCapture<Void>()
      let competitor = NearWire(
        dependencies: .live,
        connectionDependencies: SDKPublicConnectionDependencies(
          makeTransitionGate: { SDKSessionTransitionGate() },
          claimLease: {
            SDKPublicConnectionLease(handle: try ProcessConnectionLeaseRegistry.claim())
          },
          loadInstallationIdentity: {
            competitorIdentityLoads.append(())
            return appInstallationID
          },
          bundleMetadata: {
            SDKBundleMetadataInput(
              applicationIdentifier: nil,
              shortVersion: nil,
              buildVersion: nil,
              displayName: nil,
              bundleName: nil
            )
          },
          makeAdmission: { _, _, _, _, _ in
            fatalError("A contended public connection must not create admission.")
          },
          makePump: { _, _, _ in
            fatalError("A contended public connection must not create a pump.")
          },
          hooks: .none
        )
      )
      do {
        try await competitor.connect(code: "ABC234")
        XCTFail("A second public connection unexpectedly acquired the process lease.")
      } catch {
        assertNearWireError(error, code: .anotherConnectionIsActive)
      }
      XCTAssertTrue(competitorIdentityLoads.snapshot.isEmpty)

      let viewerChannel = try XCTUnwrap(recorder.viewerChannel)
      try await viewerChannel.send(
        try codec.encode(
          WireFlowPolicyOffer(
            policy: try WireFlowPolicy(
              appUplinkEventsPerSecond: 10,
              appDownlinkEventsPerSecond: 10
            )
          ),
          phase: .negotiatingPolicy
        )
      )
      try await connectTask.value
      let connectedState = await owner.currentState
      XCTAssertEqual(connectedState, .connected)

      let eventTask = Task { () throws -> NearWireEvent? in
        var iterator = owner.events.makeAsyncIterator()
        return try await iterator.next()
      }
      await sdkWaitUntil { owner.streamSubscriberCounts.events == 1 }
      let route = SDKSessionRoute(
        sessionEpoch: UUID(uuidString: sessionEpoch.rawValue)!,
        viewerID: viewerHello.installationID.rawValue,
        appID: appInstallationID
      )
      let downlinkRecord = try makeSessionIncomingRecord(
        route: route,
        sequence: 0,
        id: "30000000-0000-0000-0000-000000000042"
      )
      try await viewerChannel.send(
        try codec.encode(WireEventPayload(record: downlinkRecord), phase: .active)
      )
      let receivedEvent = try await eventTask.value
      let published = try XCTUnwrap(receivedEvent)
      XCTAssertEqual(published.id.uuidString.lowercased(), downlinkRecord.envelope.id.rawValue)

      await sdkWaitUntil {
        sessionFrameCount(in: Data(recorder.receivedBytes.dropFirst(expectedAppHello.count))) >= 2
      }
      let activeAppBytes = Data(recorder.receivedBytes.dropFirst(expectedAppHello.count))
      XCTAssertEqual(
        Array(try decodeSessionMessageTypes(activeAppBytes, codec: codec).prefix(2)),
        [.flowPolicyAccepted, .event]
      )
      let diagnostics = try await owner.bufferDiagnostics()
      XCTAssertEqual(diagnostics.eventCount, 0)
      XCTAssertFalse(recorder.didFail)

      await viewerChannel.cancel()
      await sessionWaitUntil { await owner.currentState == .disconnected }
      let reacquired = try ProcessConnectionLeaseRegistry.claim()
      reacquired.release()
      listener.cancel()
    #else
      throw XCTSkip("The unrestricted public-connect TLS integration gate runs on macOS.")
    #endif
  }

  func testPublicAdmissionCancellationOwnerIsCalledOnceWhenOuterHandlerWins() async throws {
    try await assertPublicAdmissionCancellationIsOneShot(outerHandlerWins: true)
  }

  func testPublicAdmissionCancellationOwnerIsCalledOnceWhenNestedHandlerWins() async throws {
    try await assertPublicAdmissionCancellationIsOneShot(outerHandlerWins: false)
  }

  private func assertPublicAdmissionCancellationIsOneShot(
    outerHandlerWins: Bool
  ) async throws {
    let gate = SDKSessionTransitionGate()
    let discovery = SessionControlledDiscovery()
    let cancellationEntries = SDKLockedCapture<Void>()
    let admission = SDKSessionAdmission(
      pairingCode: try PairingCode("ABC234"),
      localHello: try makeSessionHello(role: .app),
      transitionGate: gate,
      cancellationObserver: { cancellationEntries.append(()) },
      dependencies: SDKSessionAdmissionDependencies(
        makeDiscovery: { _ in discovery },
        makeChannel: { _, _ in
          fatalError("Cancellation during discovery must not construct a channel.")
        },
        sleep: sessionTestSleep
      )
    )
    let target = SDKSessionTransitionTarget()
    XCTAssertTrue(
      gate.installTarget(token: target) {
        Task { await admission.cancel() }
      }
    )
    let run = Task { try await admission.run() }
    await discovery.waitUntilRunning()
    let retainsPairingCode = await admission.retainsPairingCode()
    XCTAssertFalse(retainsPairingCode)

    if outerHandlerWins {
      XCTAssertTrue(gate.requestCancellation(.task))
      run.cancel()
    } else {
      run.cancel()
      await sdkWaitUntil { cancellationEntries.snapshot.count == 1 }
      XCTAssertTrue(gate.requestCancellation(.task))
    }

    await assertAdmissionError(.cancelled) { _ = try await run.value }
    await sdkWaitUntil { cancellationEntries.snapshot.count == 1 }
    XCTAssertEqual(cancellationEntries.snapshot.count, 1)
    XCTAssertEqual(discovery.cancelCount, 1)
  }
}

private struct SessionAdmissionFixture {
  let admission: SDKSessionAdmission
  let driver: SessionSecureDriver
  let discovery: SessionTestDiscovery
  let appHello: WireHello
  let viewerHello: WireHello
  let negotiation: WireNegotiationResult
  let sessionCodec: WireSessionCodec
  let acknowledgement: WireHelloAcknowledgement
  let sessionUUID: UUID

  init(
    advertisedViewerID: String = "viewer-installation",
    admissionLimits: SDKSessionAdmissionLimits = .default,
    maximumEventBytes: Int = 256 * 1_024,
    transportLimits providedTransportLimits: SecureTransportLimits? = nil,
    autoCompleteSends: Bool = true
  ) throws {
    appHello = try makeSessionHello(role: .app, maximumEventBytes: maximumEventBytes)
    viewerHello = try makeSessionHello(role: .viewer, maximumEventBytes: maximumEventBytes)
    negotiation = try WireNegotiator.negotiate(local: appHello, remote: viewerHello)
    sessionCodec = try WireSessionCodec(negotiation: negotiation)
    sessionUUID = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!
    acknowledgement = try WireNegotiator.makeAcknowledgement(
      result: negotiation,
      sessionEpoch: SessionEpoch(rawValue: sessionUUID.uuidString.lowercased())
    )
    let sessionDriver = SessionSecureDriver(autoCompleteSends: autoCompleteSends)
    driver = sessionDriver
    let advertisedHello = try makeSessionHello(role: .viewer, installationID: advertisedViewerID)
    let discovered = try makeDiscoveredViewer(viewerHello: advertisedHello)
    let sessionDiscovery = SessionTestDiscovery(result: discovered)
    discovery = sessionDiscovery
    let transportLimits =
      try providedTransportLimits
      ?? SecureTransportLimits(connectionTimeoutSeconds: 1)
    let dependencies = SDKSessionAdmissionDependencies(
      makeDiscovery: { _ in sessionDiscovery },
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

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _cancelCount
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

private final class SessionNanosecondSleepController: @unchecked Sendable {
  private struct Request {
    let id: UUID
    let nanoseconds: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var requests: [Request] = []
  private var cancelled = Set<UUID>()

  func sleep(nanoseconds: UInt64) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        register(id: id, nanoseconds: nanoseconds, continuation: continuation)
      }
    } onCancel: {
      self.cancel(id: id)
    }
  }

  func fire(nanoseconds: UInt64) {
    let waiter: CheckedContinuation<Void, Error>?
    lock.lock()
    if let index = requests.firstIndex(where: { $0.nanoseconds == nanoseconds }) {
      waiter = requests.remove(at: index).continuation
    } else {
      waiter = nil
    }
    lock.unlock()
    waiter?.resume()
  }

  func waitForRequest(nanoseconds: UInt64) async {
    await sdkWaitUntil {
      self.lock.lock()
      defer { self.lock.unlock() }
      return self.requests.contains(where: { $0.nanoseconds == nanoseconds })
    }
  }

  private func register(
    id: UUID,
    nanoseconds: UInt64,
    continuation: CheckedContinuation<Void, Error>
  ) {
    lock.lock()
    if cancelled.remove(id) != nil {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    requests.append(Request(id: id, nanoseconds: nanoseconds, continuation: continuation))
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
  private var sendCompletions: [@Sendable (Bool) -> Void] = []
  private let autoCompleteSends: Bool

  init(autoCompleteSends: Bool = true) {
    self.autoCompleteSends = autoCompleteSends
  }

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
    if !autoCompleteSends { sendCompletions.append(completion) }
    lock.unlock()
    if autoCompleteSends { completion(false) }
  }

  func completeNextSend(failed: Bool = false) {
    lock.lock()
    let completion = sendCompletions.isEmpty ? nil : sendCompletions.removeFirst()
    lock.unlock()
    completion?(failed)
  }

  func cancel() {
    lock.lock()
    _cancelCount += 1
    receiveCompletion = nil
    sendCompletions.removeAll(keepingCapacity: false)
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

private final class SessionOneShotAsyncBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private var didEnter = false
  private var didRelease = false
  private var continuation: CheckedContinuation<Void, Never>?

  func waitOnce() async {
    let shouldWait: Bool = lock.withLock {
      guard !didEnter else { return false }
      didEnter = true
      return !didRelease
    }
    guard shouldWait else { return }
    await withCheckedContinuation { continuation in
      let resumeImmediately: Bool = lock.withLock {
        if didRelease { return true }
        self.continuation = continuation
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }

  func waitUntilEntered() async {
    await sdkWaitUntil { self.lock.withLock { self.didEnter } }
  }

  func release() {
    let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
      didRelease = true
      let waiter = continuation
      continuation = nil
      return waiter
    }
    waiter?.resume()
  }
}

private final class SessionNthAsyncBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private let targetEntry: Int
  private var entryCount = 0
  private var didEnterTarget = false
  private var didRelease = false
  private var continuation: CheckedContinuation<Void, Never>?

  init(targetEntry: Int) {
    precondition(targetEntry > 0)
    self.targetEntry = targetEntry
  }

  func waitAtTarget() async {
    let shouldWait: Bool = lock.withLock {
      entryCount += 1
      guard entryCount == targetEntry else { return false }
      didEnterTarget = true
      return !didRelease
    }
    guard shouldWait else { return }
    await withCheckedContinuation { continuation in
      let resumeImmediately: Bool = lock.withLock {
        if didRelease { return true }
        self.continuation = continuation
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }

  func waitUntilTargetEntered() async {
    await sdkWaitUntil { self.lock.withLock { self.didEnterTarget } }
  }

  func release() {
    let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
      didRelease = true
      let waiter = continuation
      continuation = nil
      return waiter
    }
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
  sendPolicies: Set<WireSendPolicy> = [.normal, .keepLatest],
  maximumEventBytes: Int = 256 * 1_024
) throws -> WireHello {
  try WireHello(
    versions: versions,
    productVersion: WireProductVersion("1.0.0"),
    role: role,
    installationID: EndpointID(
      rawValue: installationID ?? (role == .app ? "phone-installation" : "viewer-installation")
    ),
    codecs: codecs,
    maximumEventBytes: maximumEventBytes,
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

private func decodeAcceptedPolicy(
  _ data: Data,
  codec: WireSessionCodec,
  phase: WireSessionPhase
) throws -> WireFlowPolicyAccepted {
  var decoder = WireFrameDecoder()
  var decoded: WireFlowPolicyAccepted?
  try decoder.consume(data) { frame in
    let message = try codec.decode(frame: frame, phase: phase)
    decoded = try codec.decode(WireFlowPolicyAccepted.self, from: message)
  }
  return try XCTUnwrap(decoded)
}

private func decodeEventPayload(
  _ data: Data,
  codec: WireSessionCodec
) throws -> WireEventPayload {
  var decoder = WireFrameDecoder()
  var decoded: WireEventPayload?
  try decoder.consume(data) { frame in
    let message = try codec.decode(frame: frame, phase: .active)
    decoded = try codec.decode(WireEventPayload.self, from: message)
  }
  return try XCTUnwrap(decoded)
}

private func sessionFrameCount(in data: Data) -> Int {
  var decoder = WireFrameDecoder()
  var count = 0
  do {
    try decoder.consume(data) { _ in count += 1 }
  } catch {
    return 0
  }
  return count
}

private func decodeSessionMessageTypes(
  _ data: Data,
  codec: WireSessionCodec
) throws -> [WireMessageType] {
  var decoder = WireFrameDecoder()
  var types: [WireMessageType] = []
  try decoder.consume(data) { frame in
    types.append(try codec.decode(frame: frame, phase: .active).type)
  }
  return types
}

private func makeSessionIncomingRecord(
  route: SDKSessionRoute,
  sequence: UInt64,
  id: String,
  remainingTTLNanoseconds: UInt64 = 60_000_000_000,
  content: JSONValue = .object(["value": .integer(1)]),
  direction: EventDirection = .viewerToApp
) throws -> WireEventRecord {
  let source =
    direction == .viewerToApp
    ? EventEndpoint(role: .viewer, id: try EndpointID(rawValue: route.viewerID))
    : EventEndpoint(role: .app, id: try EndpointID(rawValue: route.appID))
  let target =
    direction == .viewerToApp
    ? EventEndpoint(role: .app, id: try EndpointID(rawValue: route.appID))
    : EventEndpoint(role: .viewer, id: try EndpointID(rawValue: route.viewerID))
  let envelope = try EventEnvelope(
    id: EventID(rawValue: id),
    type: .user("viewer.command"),
    content: content,
    createdAt: Date(timeIntervalSince1970: 1_700_000_001),
    monotonicTimestampNanoseconds: 1_000_000_000,
    source: source,
    target: target,
    direction: direction,
    sessionEpoch: SessionEpoch(rawValue: route.sessionEpoch.nearWireCanonicalString),
    sequence: EventSequence(sequence),
    priority: .normal,
    ttl: .default,
    causality: EventCausality()
  )
  return try WireEventRecord(
    envelope: envelope,
    remainingTTLNanoseconds: remainingTTLNanoseconds
  )
}

private final class SessionMonotonicSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UInt64]

  init(values: [UInt64]) {
    self.values = values
  }

  func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    if values.count > 1 { return values.removeFirst() }
    return values.first ?? 0
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
