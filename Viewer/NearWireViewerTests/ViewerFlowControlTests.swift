import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport
import XCTest

@testable import NearWireViewer

final class ViewerFlowControlTests: XCTestCase {
  func testPreferencesApplyPrecedenceBoundsAndCorruptionRecovery() throws {
    let suite = "ViewerFlowControlTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let preferences = ViewerDevicePreferences(
      defaults: defaults, now: { Date(timeIntervalSince1970: 5) })
    let route = ViewerLogicalRoute(
      installationID: try EndpointID(rawValue: "installation-a"),
      applicationIdentifier: "com.example.app"
    )
    let bundlePolicy = try ViewerRatePolicy(appUplink: 12, appDownlink: 8)
    preferences.setBundlePolicy(bundlePolicy, bundleID: "com.example.app")
    XCTAssertEqual(preferences.requestedPolicy(for: route), bundlePolicy)

    let override = try ViewerRatePolicy(appUplink: 3, appDownlink: 2)
    XCTAssertEqual(preferences.requestedPolicy(for: route, sessionOverride: override), override)
    let missingBundle = ViewerLogicalRoute(
      installationID: try EndpointID(rawValue: "installation-a"),
      applicationIdentifier: nil
    )
    XCTAssertEqual(preferences.requestedPolicy(for: missingBundle), .default)

    for index in 0...ViewerDevicePreferences.maximumBundlePolicies {
      let key = String(format: "com.example.%03d", index)
      preferences.setBundlePolicy(bundlePolicy, bundleID: key)
    }
    let evicted = ViewerLogicalRoute(
      installationID: try EndpointID(rawValue: "installation-b"),
      applicationIdentifier: "com.example.000"
    )
    XCTAssertEqual(preferences.requestedPolicy(for: evicted), .default)

    defaults.set(Data("not-json".utf8), forKey: ViewerDevicePreferences.storageKey)
    let recovered = ViewerDevicePreferences(defaults: defaults)
    XCTAssertEqual(recovered.globalPolicy(), .default)
  }

  func testNicknameValidationIsBoundedAndRouteSpecific() throws {
    let suite = "ViewerFlowControlTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let preferences = ViewerDevicePreferences(defaults: defaults)
    let installation = try EndpointID(rawValue: "shared-installation")
    let first = ViewerLogicalRoute(
      installationID: installation,
      applicationIdentifier: "com.example.first"
    )
    let second = ViewerLogicalRoute(
      installationID: installation,
      applicationIdentifier: "com.example.second"
    )
    let missing = ViewerLogicalRoute(installationID: installation, applicationIdentifier: nil)

    XCTAssertTrue(preferences.setNickname("  Test Phone  ", for: first))
    XCTAssertEqual(preferences.nickname(for: first), "Test Phone")
    XCTAssertNil(preferences.nickname(for: second))
    XCTAssertNil(preferences.nickname(for: missing))
    XCTAssertFalse(preferences.setNickname(String(repeating: "x", count: 81), for: first))
    XCTAssertFalse(preferences.setNickname("bad\nname", for: first))
  }

  func testManagerEnforcesSixteenOwnedSessionsAndRejectsLiveDuplicate() throws {
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      preferences: try isolatedPreferences(),
      onSnapshots: { snapshots.set($0) }
    )
    let admission = ViewerAdmissionManager(onPending: { _ in }, handoffOwner: manager)
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-capacity")
    admission.activateGeneration(generation)
    var incoming: [FlowIncomingConnection] = []

    for index in 0..<17 {
      let connection = FlowIncomingConnection()
      incoming.append(connection)
      admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
      connection.emit(.stateChanged(.ready))
      connection.emit(.received(try appHelloFrame(id: "app-\(index)")))
    }

    waitUntil { manager.ownedSessionCount == 16 && incoming[16].channel.cancelCount == 1 }
    XCTAssertEqual(manager.ownedSessionCount, 16)
    XCTAssertEqual(incoming[0..<16].filter { $0.channel.sentPayloads.count >= 3 }.count, 16)

    let duplicate = FlowIncomingConnection()
    admission.admit(duplicate, generation: generation, viewerInstallationID: viewerID)
    duplicate.emit(.stateChanged(.ready))
    duplicate.emit(.received(try appHelloFrame(id: "app-0")))
    waitUntil { duplicate.channel.cancelCount == 1 }
    XCTAssertEqual(manager.ownedSessionCount, 16)

    let receipt = admission.stop()
    let outcome = expectation(description: "Cleanup")
    Task {
      _ = await receipt.wait(timeoutNanoseconds: 2_000_000_000)
      outcome.fulfill()
    }
    wait(for: [outcome], timeout: 3)
    XCTAssertEqual(manager.ownedSessionCount, 0)
    XCTAssertTrue(snapshots.value.isEmpty)
  }

  func testInitialPolicyUsesConservativeAcceptanceAndRepeatClosesSession() throws {
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      preferences: try isolatedPreferences(),
      onSnapshots: { snapshots.set($0) }
    )
    let admission = ViewerAdmissionManager(onPending: { _ in }, handoffOwner: manager)
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-policy")
    let appID = try EndpointID(rawValue: "app-policy")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.example.policy"
    )
    let connection = FlowIncomingConnection()
    admission.activateGeneration(generation)
    admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
    connection.emit(.stateChanged(.ready))
    connection.emit(.received(try WirePreHandshakeCodec().encode(appHello)))
    waitUntil { connection.channel.sentPayloads.count >= 3 }

    let viewerHello = try WireHello(
      productVersion: WireProductVersion("0.1.0"),
      role: .viewer,
      installationID: viewerID
    )
    let negotiation = try WireNegotiator.negotiate(local: appHello, remote: viewerHello)
    let codec = try WireSessionCodec(negotiation: negotiation)
    let accepted = try WireFlowPolicy(
      appUplinkEventsPerSecond: 7,
      appDownlinkEventsPerSecond: 4
    )
    let frame = try codec.encode(
      WireFlowPolicyAccepted(policy: accepted),
      phase: .negotiatingPolicy
    )
    connection.emit(.received(frame))
    waitUntil { snapshots.value.first?.state == .active }
    XCTAssertEqual(
      snapshots.value.first?.effectivePolicy, try ViewerRatePolicy(appUplink: 7, appDownlink: 4))

    connection.emit(
      .received(try codec.encode(WireFlowPolicyAccepted(policy: accepted), phase: .active)))
    waitUntil { connection.channel.cancelCount == 1 }
    XCTAssertEqual(snapshots.value.first?.terminalCategory, .protocolViolation)
    _ = admission.stop()
  }

  func testSameInstallationRouteVariantsRemainSeparateAndExactDuplicateIsRejected() throws {
    let manager = ViewerMultiDeviceSessionManager(preferences: try isolatedPreferences())
    let admission = ViewerAdmissionManager(onPending: { _ in }, handoffOwner: manager)
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-routes")
    admission.activateGeneration(generation)

    func connect(bundle: String?) throws -> FlowIncomingConnection {
      let connection = FlowIncomingConnection()
      admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
      connection.emit(.stateChanged(.ready))
      let hello = try WireHello(
        productVersion: WireProductVersion("1.0"),
        role: .app,
        installationID: EndpointID(rawValue: "same-installation"),
        applicationIdentifier: bundle
      )
      connection.emit(.received(try WirePreHandshakeCodec().encode(hello)))
      return connection
    }

    let first = try connect(bundle: "com.example.first")
    waitUntil { first.channel.sentPayloads.count >= 3 }
    let duplicate = try connect(bundle: "com.example.first")
    waitUntil { duplicate.channel.cancelCount == 1 }
    let second = try connect(bundle: "com.example.second")
    let missing = try connect(bundle: nil)
    waitUntil { manager.ownedSessionCount == 3 }

    XCTAssertEqual(manager.ownedSessionCount, 3)
    XCTAssertEqual(second.channel.cancelCount, 0)
    XCTAssertEqual(missing.channel.cancelCount, 0)
    _ = admission.stop()
  }

  func testApprovalPreservesCoalescedSessionSuffixUntilSameCoreAttachment() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let pending = FlowPendingBox()
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      scheduler: clock.scheduler,
      preferences: try isolatedPreferences(),
      onSnapshots: { snapshots.set($0) }
    )
    let admission = ViewerAdmissionManager(
      onPending: { pending.set($0) },
      handoffOwner: manager,
      scheduler: clock.scheduler
    )
    admission.setRequiresApproval(true)
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-approval-suffix")
    let appID = try EndpointID(rawValue: "app-approval-suffix")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.example.approval-suffix"
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("0.1.0"),
      role: .viewer,
      installationID: viewerID
    )
    let codec = try WireSessionCodec(
      negotiation: WireNegotiator.negotiate(local: appHello, remote: viewerHello)
    )
    let accepted = try WireFlowPolicy(
      appUplinkEventsPerSecond: 20,
      appDownlinkEventsPerSecond: 10
    )
    let coalesced =
      try WirePreHandshakeCodec().encode(appHello)
      + codec.encode(
        WireFlowPolicyAccepted(policy: accepted),
        phase: .negotiatingPolicy
      )
    let connection = FlowIncomingConnection()
    admission.activateGeneration(generation)
    admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
    connection.emit(.stateChanged(.ready))
    connection.emit(.received(coalesced))

    waitUntil { pending.value.count == 1 }
    XCTAssertEqual(connection.channel.pauseResolutionCounts.claims, 1)
    XCTAssertEqual(connection.channel.pauseResolutionCounts.resumes, 0)
    XCTAssertEqual(connection.channel.pauseResolutionCounts.cancellations, 0)
    admission.accept(try XCTUnwrap(pending.value.first?.id))
    waitUntil { snapshots.value.first?.state == .active }
    waitUntil { connection.channel.pauseResolutionCounts.resumes == 1 }
    XCTAssertEqual(connection.channel.pauseResolutionCounts.cancellations, 0)
    _ = admission.stop()
  }

  func testApprovalFreezesPartialPostHelloFrameUntilAttachmentResumesReceive() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let pending = FlowPendingBox()
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      scheduler: clock.scheduler,
      preferences: try isolatedPreferences(),
      onSnapshots: { snapshots.set($0) }
    )
    let admission = ViewerAdmissionManager(
      onPending: { pending.set($0) },
      handoffOwner: manager,
      scheduler: clock.scheduler
    )
    admission.setRequiresApproval(true)
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-approval-partial")
    let appID = try EndpointID(rawValue: "app-approval-partial")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.example.approval-partial"
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("0.1.0"),
      role: .viewer,
      installationID: viewerID
    )
    let codec = try WireSessionCodec(
      negotiation: WireNegotiator.negotiate(local: appHello, remote: viewerHello)
    )
    let acceptance = try codec.encode(
      WireFlowPolicyAccepted(
        policy: WireFlowPolicy(
          appUplinkEventsPerSecond: 20,
          appDownlinkEventsPerSecond: 10
        )
      ),
      phase: .negotiatingPolicy
    )
    let split = acceptance.count / 2
    let first = try WirePreHandshakeCodec().encode(appHello) + acceptance.prefix(split)
    let connection = FlowIncomingConnection()
    admission.activateGeneration(generation)
    admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
    connection.emit(.stateChanged(.ready))
    connection.emit(.received(first))

    waitUntil { pending.value.count == 1 }
    XCTAssertEqual(connection.channel.pauseResolutionCounts.claims, 1)
    XCTAssertEqual(connection.channel.pauseResolutionCounts.resumes, 0)
    admission.accept(try XCTUnwrap(pending.value.first?.id))
    waitUntil { connection.channel.pauseResolutionCounts.resumes == 1 }
    XCTAssertEqual(snapshots.value.first?.state, .negotiating)
    connection.emit(.received(Data(acceptance.suffix(from: split))))
    waitUntil { snapshots.value.first?.state == .active }
    XCTAssertEqual(connection.channel.pauseResolutionCounts.cancellations, 0)
    XCTAssertEqual(connection.channel.cancelCount, 0)
    _ = admission.stop()
  }

  func testSystemBurstUsesBoundedContinuationTurnsAndOneReceivePause() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      scheduler: clock.scheduler,
      preferences: try isolatedPreferences(),
      onSnapshots: { snapshots.set($0) }
    )
    let admission = ViewerAdmissionManager(
      onPending: { _ in },
      handoffOwner: manager,
      scheduler: clock.scheduler
    )
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-system-burst")
    let appID = try EndpointID(rawValue: "app-system-burst")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.example.system-burst"
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("0.1.0"),
      role: .viewer,
      installationID: viewerID
    )
    let codec = try WireSessionCodec(
      negotiation: WireNegotiator.negotiate(local: appHello, remote: viewerHello)
    )
    let accepted = try WireFlowPolicy(
      appUplinkEventsPerSecond: 20,
      appDownlinkEventsPerSecond: 10
    )
    var coalesced = try WirePreHandshakeCodec().encode(appHello)
    coalesced.append(
      try codec.encode(
        WireFlowPolicyAccepted(policy: accepted),
        phase: .negotiatingPolicy
      )
    )
    for nonce in 0..<70 {
      coalesced.append(try codec.encode(WirePing(nonce: UInt64(nonce)), phase: .active))
    }
    let connection = FlowIncomingConnection()
    admission.activateGeneration(generation)
    admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
    connection.emit(.stateChanged(.ready))
    connection.emit(.received(coalesced))

    waitUntil { connection.channel.sentPayloads.count >= 73 }
    waitUntil { connection.channel.pauseResolutionCounts.resumes == 1 }
    XCTAssertEqual(connection.channel.pauseResolutionCounts.claims, 1)
    XCTAssertEqual(connection.channel.pauseResolutionCounts.cancellations, 0)
    XCTAssertEqual(snapshots.value.first?.state, .active)
    _ = admission.stop()
  }

  func testRetainedEventContinuationDefersALaterBatchServiceTurn() throws {
    func run(advanceDeadlineDuringPause: Bool, appID: String) throws
      -> FlowContinuationOutcome
    {
      let clock = FlowManualScheduler(startNanoseconds: 1_800_000_000)
      let delivered = FlowEventBox()
      let fixture = try establishActiveSession(
        clock: clock,
        appIDRaw: appID,
        uplinkSink: { _, event in delivered.append(event) }
      )
      let connectionID = try XCTUnwrap(fixture.snapshots.value.first?.connectionID)
      XCTAssertTrue(
        fixture.manager.send(
          try EventDraft(
            type: EventType.user("test.deferred-service.downlink"),
            content: .object(["value": .integer(1)])
          ),
          to: connectionID
        )
      )
      waitUntil { fixture.snapshots.value.first?.downlinkCount == 1 }
      waitUntil { clock.pendingDeadlines.contains(2_300_000_000) }

      if advanceDeadlineDuringPause {
        fixture.connection.channel.setPauseClaimHook {
          clock.advance(by: 500_000_000)
          Thread.sleep(forTimeInterval: 0.02)
        }
      }

      var coalesced = Data()
      for nonce in 0..<ViewerSessionIngressLimits.maximumFramesPerTurn {
        coalesced.append(
          try fixture.codec.encode(WirePing(nonce: UInt64(nonce)), phase: .active)
        )
      }
      let envelope = try EventEnvelope(
        id: EventID(),
        type: EventType.user("test.deferred-service.uplink"),
        content: .object(["value": .integer(2)]),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        monotonicTimestampNanoseconds: 1_800_000_000,
        source: EventEndpoint(role: .app, id: fixture.appID),
        target: EventEndpoint(role: .viewer, id: fixture.viewerID),
        direction: .appToViewer,
        sessionEpoch: fixture.acknowledgement.sessionEpoch,
        sequence: EventSequence(0),
        priority: .normal,
        ttl: .default,
        causality: EventCausality()
      )
      coalesced.append(
        try fixture.codec.encode(
          WireEventPayload(
            record: WireEventRecord(
              envelope: envelope,
              remainingTTLNanoseconds: 10_000_000_000
            )
          ),
          phase: .active
        )
      )
      fixture.connection.emit(.received(coalesced))
      waitUntil { delivered.value.count == 1 }
      if !advanceDeadlineDuringPause { clock.advance(by: 500_000_000) }
      waitUntil { fixture.snapshots.value.first?.sentEvents == 1 }
      let snapshot = try XCTUnwrap(fixture.snapshots.value.first)
      let outcome = FlowContinuationOutcome(
        state: snapshot.state,
        receivedEvents: snapshot.receivedEvents,
        deliveredEvents: snapshot.deliveredEvents,
        sentEvents: snapshot.sentEvents,
        uplinkCount: snapshot.uplinkCount,
        downlinkCount: snapshot.downlinkCount,
        droppedEvents: snapshot.droppedEvents,
        ingressEventsPerSecond: snapshot.ingressEventsPerSecond,
        egressEventsPerSecond: snapshot.egressEventsPerSecond,
        cancellationCount: fixture.connection.channel.cancelCount,
        pauseClaims: fixture.connection.channel.pauseResolutionCounts.claims,
        pauseResumes: fixture.connection.channel.pauseResolutionCounts.resumes
      )
      _ = fixture.admission.stop()
      return outcome
    }

    let continuationFirst = try run(
      advanceDeadlineDuringPause: false,
      appID: "app-continuation-first"
    )
    let serviceSubmittedFirst = try run(
      advanceDeadlineDuringPause: true,
      appID: "app-service-first"
    )
    XCTAssertEqual(serviceSubmittedFirst, continuationFirst)
    XCTAssertEqual(serviceSubmittedFirst.state, .active)
    XCTAssertEqual(serviceSubmittedFirst.receivedEvents, 1)
    XCTAssertEqual(serviceSubmittedFirst.deliveredEvents, 1)
    XCTAssertEqual(serviceSubmittedFirst.sentEvents, 1)
    XCTAssertEqual(serviceSubmittedFirst.cancellationCount, 0)
  }

  func testDownlinkMailboxBackpressureRetriesWithoutSequenceGapOrDisconnect() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(clock: clock, appIDRaw: "app-mailbox-retry")
    let connectionID = try XCTUnwrap(fixture.snapshots.value.first?.connectionID)
    fixture.connection.channel.setReservedAdmissionAllowed(false)
    let draft = try EventDraft(
      type: EventType.user("test.retry"),
      content: .object(["value": .integer(1)])
    )
    let baseline = fixture.connection.channel.sentPayloads.count
    XCTAssertTrue(fixture.manager.send(draft, to: connectionID))
    clock.advance(by: 500_000_000)
    waitUntil { fixture.snapshots.value.first?.downlinkCount == 1 }
    XCTAssertEqual(fixture.connection.channel.sentPayloads.count, baseline)
    XCTAssertEqual(fixture.snapshots.value.first?.state, .active)

    fixture.connection.channel.setReservedAdmissionAllowed(true)
    fixture.connection.emit(
      .sendCompleted(byteCount: fixture.connection.channel.sentPayloads[0].count)
    )
    waitUntil { fixture.connection.channel.sentPayloads.count == baseline + 1 }
    let frame = try decodeFrame(fixture.connection.channel.sentPayloads.last!)
    let message = try fixture.codec.decode(frame: frame, phase: .active)
    let payload = try fixture.codec.decode(WireEventPayload.self, from: message)
    XCTAssertEqual(payload.record.envelope.sequence, EventSequence(0))
    XCTAssertEqual(fixture.snapshots.value.first?.state, .active)
    _ = fixture.admission.stop()
  }

  func testAuthoritativeMailboxBackpressureAlsoRetriesWithoutCommittingSequence() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(clock: clock, appIDRaw: "app-mailbox-race")
    let connectionID = try XCTUnwrap(fixture.snapshots.value.first?.connectionID)
    let baseline = fixture.connection.channel.sentPayloads.count
    fixture.connection.channel.rejectNextReservedAdmission()
    XCTAssertTrue(
      fixture.manager.send(
        try EventDraft(
          type: EventType.user("test.authoritative-retry"),
          content: .object(["value": .integer(1)])
        ),
        to: connectionID
      )
    )
    clock.advance(by: 500_000_000)
    waitUntil { fixture.snapshots.value.first?.downlinkCount == 1 }
    XCTAssertEqual(fixture.connection.channel.sentPayloads.count, baseline)
    XCTAssertEqual(fixture.snapshots.value.first?.state, .active)

    fixture.connection.emit(
      .sendCompleted(byteCount: fixture.connection.channel.sentPayloads[0].count)
    )
    waitUntil { fixture.connection.channel.sentPayloads.count == baseline + 1 }
    let message = try fixture.codec.decode(
      frame: decodeFrame(fixture.connection.channel.sentPayloads.last!),
      phase: .active
    )
    let payload = try fixture.codec.decode(WireEventPayload.self, from: message)
    XCTAssertEqual(payload.record.envelope.sequence, EventSequence(0))
    XCTAssertEqual(fixture.snapshots.value.first?.state, .active)
    _ = fixture.admission.stop()
  }

  func testBlockedUplinkSinkDoesNotBlockProtocolControlProgress() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let fixture = try establishActiveSession(
      clock: clock,
      appIDRaw: "app-blocked-sink",
      uplinkSink: { _, _ in
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
    )
    let envelope = try EventEnvelope(
      id: EventID(),
      type: EventType.user("test.blocked"),
      content: .object(["secret": .string("not-diagnostic")]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      monotonicTimestampNanoseconds: 1_000_000_000,
      source: EventEndpoint(role: .app, id: fixture.appID),
      target: EventEndpoint(role: .viewer, id: fixture.viewerID),
      direction: .appToViewer,
      sessionEpoch: fixture.acknowledgement.sessionEpoch,
      sequence: EventSequence(0),
      priority: .normal,
      ttl: .default,
      causality: EventCausality()
    )
    let record = try WireEventRecord(
      envelope: envelope,
      remainingTTLNanoseconds: 10_000_000_000
    )
    fixture.connection.emit(
      .received(
        try fixture.codec.encode(WireEventPayload(record: record), phase: .active)
      )
    )
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    let baseline = fixture.connection.channel.sentPayloads.count
    fixture.connection.emit(.received(try fixture.codec.encode(WirePing(nonce: 7), phase: .active)))
    waitUntil { fixture.connection.channel.sentPayloads.count == baseline + 1 }
    XCTAssertEqual(fixture.snapshots.value.first?.state, .active)
    release.signal()
    _ = fixture.admission.stop()
  }

  func testSubMillisecondReceiverTTLExpiresAtTheExactNanosecondBoundary() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let delivered = FlowEventBox()
    let fixture = try establishActiveSession(
      clock: clock,
      appIDRaw: "app-exact-ttl",
      uplinkSink: { _, event in
        delivered.append(event)
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
    )

    func record(sequence: UInt64, ttl: UInt64) throws -> WireEventRecord {
      let envelope = try EventEnvelope(
        id: EventID(),
        type: EventType.user("test.exact-ttl"),
        content: .object(["sequence": .integer(Int64(sequence))]),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        monotonicTimestampNanoseconds: 1_000_000_000,
        source: EventEndpoint(role: .app, id: fixture.appID),
        target: EventEndpoint(role: .viewer, id: fixture.viewerID),
        direction: .appToViewer,
        sessionEpoch: fixture.acknowledgement.sessionEpoch,
        sequence: EventSequence(sequence),
        priority: .normal,
        ttl: .default,
        causality: EventCausality()
      )
      return try WireEventRecord(envelope: envelope, remainingTTLNanoseconds: ttl)
    }

    fixture.connection.emit(
      .received(
        try fixture.codec.encode(
          WireEventPayload(record: record(sequence: 0, ttl: 10_000_000_000)),
          phase: .active
        )
      )
    )
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    fixture.connection.emit(
      .received(
        try fixture.codec.encode(
          WireEventPayload(record: record(sequence: 1, ttl: 500_000)),
          phase: .active
        )
      )
    )
    waitUntil { fixture.snapshots.value.first?.uplinkCount == 1 }
    waitUntil { clock.pendingDeadlines.contains(1_000_500_000) }
    clock.advance(by: 500_000)
    waitUntil { fixture.snapshots.value.first?.uplinkCount == 0 }
    XCTAssertEqual(fixture.snapshots.value.first?.expiredEvents, 1)
    XCTAssertEqual(delivered.value.count, 1)
    XCTAssertEqual(fixture.snapshots.value.first?.state, .active)
    release.signal()
    _ = fixture.admission.stop()
  }

  func testTerminalClearsQueuedUplinkWhileAnotherSessionStillDelivers() throws {
    let firstClock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let first = try establishActiveSession(
      clock: firstClock,
      appIDRaw: "app-terminal-handoff",
      uplinkSink: { _, _ in
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
    )

    func sendRecord(_ sequence: UInt64, through fixture: FlowActiveFixture) throws {
      let envelope = try EventEnvelope(
        id: EventID(),
        type: EventType.user("test.terminal-handoff"),
        content: .object(["sequence": .integer(Int64(sequence))]),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        monotonicTimestampNanoseconds: 1_000_000_000,
        source: EventEndpoint(role: .app, id: fixture.appID),
        target: EventEndpoint(role: .viewer, id: fixture.viewerID),
        direction: .appToViewer,
        sessionEpoch: fixture.acknowledgement.sessionEpoch,
        sequence: EventSequence(sequence),
        priority: .normal,
        ttl: .default,
        causality: EventCausality()
      )
      let record = try WireEventRecord(
        envelope: envelope,
        remainingTTLNanoseconds: 10_000_000_000
      )
      fixture.connection.emit(
        .received(try fixture.codec.encode(WireEventPayload(record: record), phase: .active))
      )
    }

    try sendRecord(0, through: first)
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    try sendRecord(1, through: first)
    waitUntil { first.snapshots.value.first?.uplinkCount == 1 }
    first.manager.disconnect(
      connectionID: try XCTUnwrap(first.snapshots.value.first?.connectionID)
    )
    waitUntil { first.snapshots.value.first?.state == .recent }
    XCTAssertEqual(first.snapshots.value.first?.routeDroppedEvents, 1)

    let secondClock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let delivered = FlowEventBox()
    let second = try establishActiveSession(
      clock: secondClock,
      appIDRaw: "app-after-terminal-handoff",
      uplinkSink: { _, event in delivered.append(event) }
    )
    try sendRecord(0, through: second)
    waitUntil { delivered.value.count == 1 }
    XCTAssertEqual(second.snapshots.value.first?.state, .active)

    release.signal()
    _ = first.admission.stop()
    _ = second.admission.stop()
  }

  func testDropSummariesCoalesceWhileOneSummaryOwnsTheReservedControlSlot() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(clock: clock, appIDRaw: "app-drop-summary")
    let connectionID = try XCTUnwrap(fixture.snapshots.value.first?.connectionID)
    let baseline = fixture.connection.channel.sentPayloads.count
    let reservationBaseline = fixture.connection.channel.reservedSendRecords.count

    for value in 0..<11 {
      let draft = try EventDraft(
        type: EventType.user("test.latest"),
        content: .object(["value": .integer(Int64(value))])
      )
      XCTAssertTrue(
        fixture.manager.send(
          draft,
          to: connectionID,
          policy: .keepLatest("shared-metric")
        )
      )
    }

    waitUntil { fixture.connection.channel.sentPayloads.count == baseline + 1 }
    XCTAssertEqual(fixture.snapshots.value.first?.downlinkCount, 1)
    XCTAssertEqual(fixture.snapshots.value.first?.droppedEvents, 10)
    XCTAssertEqual(
      fixture.connection.channel.reservedSendRecords.count,
      reservationBaseline + 1
    )
    XCTAssertEqual(
      fixture.connection.channel.reservedSendRecords.last,
      FlowReservedSend(count: 1, bytes: 64 * 1_024)
    )

    let firstMessage = try fixture.codec.decode(
      frame: decodeFrame(fixture.connection.channel.sentPayloads[baseline]),
      phase: .active
    )
    let firstSummary = try fixture.codec.decode(WireDropSummaryPayload.self, from: firstMessage)
    XCTAssertEqual(firstSummary.overflowDropped, 0)
    XCTAssertEqual(firstSummary.expired, 0)
    XCTAssertEqual(firstSummary.coalesced, 1)

    for index in 0...3 {
      fixture.connection.emit(
        .sendCompleted(byteCount: fixture.connection.channel.sentPayloads[index].count)
      )
    }
    waitUntil { fixture.connection.channel.sentPayloads.count == baseline + 2 }
    XCTAssertEqual(
      fixture.connection.channel.reservedSendRecords.count,
      reservationBaseline + 2
    )
    let secondMessage = try fixture.codec.decode(
      frame: decodeFrame(fixture.connection.channel.sentPayloads[baseline + 1]),
      phase: .active
    )
    let secondSummary = try fixture.codec.decode(WireDropSummaryPayload.self, from: secondMessage)
    XCTAssertEqual(secondSummary.overflowDropped, 0)
    XCTAssertEqual(secondSummary.expired, 0)
    XCTAssertEqual(secondSummary.coalesced, 9)
    _ = fixture.admission.stop()
  }

  func testZeroRateQueuesBusinessEventsWithoutInstallingABatchPollingWake() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(clock: clock, appIDRaw: "app-zero-rate")
    let connectionID = try XCTUnwrap(fixture.snapshots.value.first?.connectionID)
    fixture.manager.updatePolicy(
      connectionID: connectionID,
      policy: try ViewerRatePolicy(appUplink: 0, appDownlink: 0)
    )
    waitUntil { fixture.connection.channel.sentPayloads.count == 4 }
    fixture.connection.emit(
      .received(
        try fixture.codec.encode(
          WireFlowPolicyAccepted(
            policy: try WireFlowPolicy(
              appUplinkEventsPerSecond: 0,
              appDownlinkEventsPerSecond: 0
            )
          ),
          phase: .active
        )
      )
    )
    waitUntil {
      fixture.snapshots.value.first?.effectivePolicy
        == (try? ViewerRatePolicy(appUplink: 0, appDownlink: 0))
    }

    let baseline = fixture.connection.channel.sentPayloads.count
    XCTAssertTrue(
      fixture.manager.send(
        try EventDraft(
          type: EventType.user("test.paused"),
          content: .object(["value": .integer(1)])
        ),
        to: connectionID
      )
    )
    waitUntil { fixture.snapshots.value.first?.downlinkCount == 1 }
    XCTAssertFalse(clock.pendingDeadlines.contains(1_500_000_000))
    clock.advance(by: 500_000_000)
    XCTAssertEqual(fixture.connection.channel.sentPayloads.count, baseline)
    XCTAssertEqual(fixture.snapshots.value.first?.state, .active)
    XCTAssertTrue(
      fixture.manager.send(
        try EventDraft(
          type: EventType.user("test.paused.second"),
          content: .object(["value": .integer(2)])
        ),
        to: connectionID
      )
    )
    waitUntil {
      fixture.snapshots.value.first?.downlinkOldestWaitNanoseconds == 500_000_000
    }
    _ = fixture.admission.stop()
  }

  func testOversizedPreferenceBlobIsRejectedBeforeDecodeAndRewrittenBoundedly() throws {
    let suite = "ViewerFlowControlTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defaults.set(
      Data(repeating: 0x7B, count: ViewerDevicePreferences.maximumStoredBytes + 1),
      forKey: ViewerDevicePreferences.storageKey
    )
    let preferences = ViewerDevicePreferences(defaults: defaults)
    XCTAssertEqual(preferences.globalPolicy(), .default)
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(defaults.data(forKey: ViewerDevicePreferences.storageKey)).count,
      ViewerDevicePreferences.maximumStoredBytes
    )
  }

  func testLiveNicknameSurvivesLaterPolicyAndTelemetrySnapshots() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(clock: clock, appIDRaw: "app-live-nickname")
    let snapshot = try XCTUnwrap(fixture.snapshots.value.first)
    XCTAssertTrue(fixture.manager.setNickname("Lab Phone", route: snapshot.route))
    waitUntil { fixture.snapshots.value.first?.nickname == "Lab Phone" }
    fixture.manager.updatePolicy(
      connectionID: try XCTUnwrap(snapshot.connectionID),
      policy: try ViewerRatePolicy(appUplink: 5, appDownlink: 4)
    )
    waitUntil { fixture.connection.channel.sentPayloads.count >= 4 }
    XCTAssertEqual(fixture.snapshots.value.first?.nickname, "Lab Phone")
    _ = fixture.admission.stop()
  }

  func testDynamicPolicyCoalescesLatestRequestAndTimesOutAtExactDeadline() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(clock: clock, appIDRaw: "app-policy-dynamic")
    let connectionID = try XCTUnwrap(fixture.snapshots.value.first?.connectionID)
    fixture.manager.updatePolicy(
      connectionID: connectionID,
      policy: try ViewerRatePolicy(appUplink: 5, appDownlink: 4)
    )
    fixture.manager.updatePolicy(
      connectionID: connectionID,
      policy: try ViewerRatePolicy(appUplink: 2, appDownlink: 1)
    )
    waitUntil {
      fixture.snapshots.value.first?.requestedPolicy
        == (try? ViewerRatePolicy(appUplink: 2, appDownlink: 1))
    }
    XCTAssertEqual(fixture.connection.channel.sentPayloads.count, 4)
    let firstAccepted = try WireFlowPolicy(
      appUplinkEventsPerSecond: 5,
      appDownlinkEventsPerSecond: 4
    )
    fixture.connection.emit(
      .received(
        try fixture.codec.encode(
          WireFlowPolicyAccepted(policy: firstAccepted),
          phase: .active
        )
      )
    )
    waitUntil { fixture.connection.channel.sentPayloads.count == 5 }
    XCTAssertEqual(
      fixture.snapshots.value.first?.effectivePolicy,
      try ViewerRatePolicy(appUplink: 5, appDownlink: 4))
    clock.advance(by: ViewerDeviceSession.policyDeadlineNanoseconds)
    waitUntil { fixture.snapshots.value.first?.state == .recent }
    XCTAssertEqual(fixture.snapshots.value.first?.terminalCategory, .policyTimeout)
  }

  func testRecentRowsAreCappedAndExpireAtExactThirtySecondBoundary() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      scheduler: clock.scheduler,
      preferences: try isolatedPreferences(),
      onSnapshots: { snapshots.set($0) }
    )
    let admission = ViewerAdmissionManager(
      onPending: { _ in },
      handoffOwner: manager,
      scheduler: clock.scheduler
    )
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-recent-cap")
    admission.activateGeneration(generation)
    for index in 0...ViewerMultiDeviceSessionManager.maximumRecentRows {
      let appID = String(format: "recent-%03d", index)
      let connection = FlowIncomingConnection()
      admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
      connection.emit(.stateChanged(.ready))
      connection.emit(.received(try appHelloFrame(id: appID)))
      waitUntil { manager.ownedSessionCount == 1 }
      let liveID = try XCTUnwrap(
        snapshots.value.first(where: { $0.state != .recent })?.connectionID
      )
      manager.disconnect(connectionID: liveID)
      waitUntil { manager.ownedSessionCount == 0 }
    }
    XCTAssertEqual(manager.recentRowCount, ViewerMultiDeviceSessionManager.maximumRecentRows)
    XCTAssertFalse(snapshots.value.contains { $0.route.installationID == "recent-000" })
    XCTAssertTrue(snapshots.value.contains { $0.route.installationID == "recent-064" })
    clock.advance(by: ViewerMultiDeviceSessionManager.recentTTLNanoseconds - 1)
    XCTAssertEqual(manager.recentRowCount, ViewerMultiDeviceSessionManager.maximumRecentRows)
    clock.advance(by: 1)
    waitUntil { manager.recentRowCount == 0 }
    _ = admission.stop()
  }

  func testSessionSnapshotDiagnosticsExposeOnlyClosedState() throws {
    let sentinel = "SENSITIVE-INSTALLATION"
    let snapshot = ViewerSessionSnapshot(
      id: UUID(),
      connectionID: UUID(),
      route: ViewerLogicalRoute(
        installationID: try EndpointID(rawValue: sentinel),
        applicationIdentifier: "com.secret.bundle"
      ),
      displayName: "Secret Device",
      applicationVersion: "99",
      installationAlias: "Secret Alias",
      nickname: "Secret Nickname",
      state: .active,
      requestedPolicy: try ViewerRatePolicy(appUplink: 123, appDownlink: 456),
      effectivePolicy: try ViewerRatePolicy(appUplink: 12, appDownlink: 45),
      uplinkCount: 77,
      uplinkBytes: 88,
      uplinkOldestWaitNanoseconds: 89,
      downlinkCount: 99,
      downlinkBytes: 111,
      downlinkOldestWaitNanoseconds: 112,
      receivedEvents: 222,
      deliveredEvents: 333,
      sentEvents: 444,
      droppedEvents: 555,
      overflowDroppedEvents: 100,
      expiredEvents: 200,
      coalescedEvents: 250,
      routeDroppedEvents: 5,
      remoteDroppedEvents: 666,
      ingressEventsPerSecond: 777,
      egressEventsPerSecond: 888,
      terminalCategory: nil
    )
    let surfaces = [
      String(describing: snapshot),
      String(reflecting: snapshot),
      Mirror(reflecting: snapshot).children.map { String(describing: $0.value) }.joined(),
    ]
    for surface in surfaces {
      XCTAssertFalse(surface.contains(sentinel))
      XCTAssertFalse(surface.contains("com.secret.bundle"))
      XCTAssertFalse(surface.contains("Secret Nickname"))
      XCTAssertFalse(surface.contains("123"))
      XCTAssertFalse(surface.contains("777"))
    }
    XCTAssertEqual(
      String(describing: snapshot), "ViewerSessionSnapshot(state: active, terminal: none)")
    let routeSurfaces = [
      String(describing: snapshot.route),
      String(reflecting: snapshot.route),
      Mirror(reflecting: snapshot.route).children.map { String(describing: $0.value) }.joined(),
    ]
    XCTAssertFalse(routeSurfaces.joined().contains(sentinel))
    XCTAssertFalse(routeSurfaces.joined().contains("com.secret.bundle"))
    let policySurfaces = [
      String(describing: snapshot.requestedPolicy),
      String(reflecting: snapshot.requestedPolicy),
      Mirror(reflecting: snapshot.requestedPolicy).children.map {
        String(describing: $0.value)
      }.joined(),
    ]
    XCTAssertFalse(policySurfaces.joined().contains("123"))
    XCTAssertFalse(policySurfaces.joined().contains("456"))
  }

  func testBidirectionalEventExchangeUsesNegotiatedEpochAndRoutes() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let snapshots = FlowSnapshotBox()
    let delivered = FlowEventBox()
    let manager = ViewerMultiDeviceSessionManager(
      scheduler: clock.scheduler,
      preferences: try isolatedPreferences(),
      onSnapshots: { snapshots.set($0) },
      uplinkSink: { _, event in delivered.append(event) }
    )
    let admission = ViewerAdmissionManager(
      onPending: { _ in },
      handoffOwner: manager,
      scheduler: clock.scheduler
    )
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-events")
    let appID = try EndpointID(rawValue: "app-events")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.example.events"
    )
    let connection = FlowIncomingConnection()
    admission.activateGeneration(generation)
    admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
    connection.emit(.stateChanged(.ready))
    connection.emit(.received(try WirePreHandshakeCodec().encode(appHello)))
    waitUntil { connection.channel.sentPayloads.count >= 3 }

    let viewerHello = try WireHello(
      productVersion: WireProductVersion("0.1.0"),
      role: .viewer,
      installationID: viewerID
    )
    let negotiation = try WireNegotiator.negotiate(local: appHello, remote: viewerHello)
    let codec = try WireSessionCodec(negotiation: negotiation)
    let acknowledgementFrame = try decodeFrame(connection.channel.sentPayloads[1])
    let acknowledgementMessage = try codec.decode(
      frame: acknowledgementFrame,
      phase: .awaitingApproval
    )
    let acknowledgement = try codec.decode(
      WireHelloAcknowledgement.self,
      from: acknowledgementMessage
    )
    let acceptedPolicy = try WireFlowPolicy(
      appUplinkEventsPerSecond: 20,
      appDownlinkEventsPerSecond: 10
    )
    connection.emit(
      .received(
        try codec.encode(
          WireFlowPolicyAccepted(policy: acceptedPolicy),
          phase: .negotiatingPolicy
        )
      )
    )
    waitUntil { snapshots.value.first?.state == .active }

    let incomingEnvelope = try EventEnvelope(
      id: EventID(),
      type: EventType.user("test.uplink"),
      content: .object(["value": .integer(1)]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      monotonicTimestampNanoseconds: 1_000,
      source: EventEndpoint(role: .app, id: appID),
      target: EventEndpoint(role: .viewer, id: viewerID),
      direction: .appToViewer,
      sessionEpoch: acknowledgement.sessionEpoch,
      sequence: EventSequence(0),
      priority: .normal,
      ttl: .default,
      causality: EventCausality()
    )
    let incomingRecord = try WireEventRecord(
      envelope: incomingEnvelope,
      remainingTTLNanoseconds: 10_000_000_000
    )
    connection.emit(
      .received(
        try codec.encode(WireEventPayload(record: incomingRecord), phase: .active)
      )
    )
    waitUntil { delivered.value.count == 1 }
    XCTAssertEqual(delivered.value.first?.envelope.type.rawValue, "test.uplink")

    let draft = try EventDraft(
      type: EventType.user("test.downlink"),
      content: .object(["enabled": .bool(true)])
    )
    let connectionID = try XCTUnwrap(snapshots.value.first?.connectionID)
    let outboundBaseline = connection.channel.sentPayloads.count
    XCTAssertTrue(manager.send(draft, to: connectionID))
    waitUntil { clock.pendingDeadlines.contains(1_500_000_000) }
    clock.advance(by: 500_000_000)
    waitUntil {
      connection.channel.sentPayloads.count > outboundBaseline
        || snapshots.value.first?.state != .active
    }
    XCTAssertEqual(snapshots.value.first?.state, .active)
    guard connection.channel.sentPayloads.count > outboundBaseline else {
      return XCTFail(
        "Downlink service stopped before mailbox admission: \(String(describing: snapshots.value.first?.terminalCategory))"
      )
    }
    let downlinkFrame = try decodeFrame(connection.channel.sentPayloads.last!)
    let downlinkMessage = try codec.decode(frame: downlinkFrame, phase: .active)
    let downlink = try codec.decode(WireEventPayload.self, from: downlinkMessage)
    XCTAssertEqual(downlink.record.envelope.sessionEpoch, acknowledgement.sessionEpoch)
    XCTAssertEqual(downlink.record.envelope.target, EventEndpoint(role: .app, id: appID))
    XCTAssertEqual(downlink.record.envelope.sequence, EventSequence(0))
    _ = admission.stop()
  }

  private func establishActiveSession(
    clock: FlowManualScheduler,
    appIDRaw: String,
    uplinkSink: @escaping @Sendable (UUID, WireReceivedEvent) -> Void = { _, _ in }
  ) throws -> FlowActiveFixture {
    let snapshots = FlowSnapshotBox()
    let suite = "ViewerFlowControlTests.fixture.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let manager = ViewerMultiDeviceSessionManager(
      scheduler: clock.scheduler,
      preferences: ViewerDevicePreferences(defaults: defaults),
      onSnapshots: { snapshots.set($0) },
      uplinkSink: uplinkSink
    )
    let admission = ViewerAdmissionManager(
      onPending: { _ in },
      handoffOwner: manager,
      scheduler: clock.scheduler
    )
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-\(appIDRaw)")
    let appID = try EndpointID(rawValue: appIDRaw)
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.example.\(appIDRaw)"
    )
    let connection = FlowIncomingConnection()
    admission.activateGeneration(generation)
    admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
    connection.emit(.stateChanged(.ready))
    connection.emit(.received(try WirePreHandshakeCodec().encode(appHello)))
    waitUntil { connection.channel.sentPayloads.count >= 3 }

    let viewerHello = try WireHello(
      productVersion: WireProductVersion("0.1.0"),
      role: .viewer,
      installationID: viewerID
    )
    let negotiation = try WireNegotiator.negotiate(local: appHello, remote: viewerHello)
    let codec = try WireSessionCodec(negotiation: negotiation)
    let acknowledgementFrame = try decodeFrame(connection.channel.sentPayloads[1])
    let acknowledgementMessage = try codec.decode(
      frame: acknowledgementFrame,
      phase: .awaitingApproval
    )
    let acknowledgement = try codec.decode(
      WireHelloAcknowledgement.self,
      from: acknowledgementMessage
    )
    let acceptedPolicy = try WireFlowPolicy(
      appUplinkEventsPerSecond: 20,
      appDownlinkEventsPerSecond: 10
    )
    connection.emit(
      .received(
        try codec.encode(
          WireFlowPolicyAccepted(policy: acceptedPolicy),
          phase: .negotiatingPolicy
        )
      )
    )
    waitUntil { snapshots.value.first?.state == .active }
    return FlowActiveFixture(
      manager: manager,
      admission: admission,
      connection: connection,
      snapshots: snapshots,
      codec: codec,
      acknowledgement: acknowledgement,
      appID: appID,
      viewerID: viewerID
    )
  }

  private func appHelloFrame(id: String) throws -> Data {
    let hello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: EndpointID(rawValue: id),
      applicationIdentifier: "com.example.\(id)"
    )
    return try WirePreHandshakeCodec().encode(hello)
  }

  private func isolatedPreferences() throws -> ViewerDevicePreferences {
    let suite = "ViewerFlowControlTests.preferences.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return ViewerDevicePreferences(defaults: defaults)
  }

  private func decodeFrame(_ data: Data) throws -> WireFrame {
    var decoder = WireFrameDecoder()
    var frames: [WireFrame] = []
    try decoder.consume(data) { frames.append($0) }
    return try XCTUnwrap(frames.first)
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping () -> Bool
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    XCTAssertTrue(condition())
  }
}

private struct FlowActiveFixture {
  let manager: ViewerMultiDeviceSessionManager
  let admission: ViewerAdmissionManager
  let connection: FlowIncomingConnection
  let snapshots: FlowSnapshotBox
  let codec: WireSessionCodec
  let acknowledgement: WireHelloAcknowledgement
  let appID: EndpointID
  let viewerID: EndpointID
}

private struct FlowContinuationOutcome: Equatable {
  let state: ViewerSessionState
  let receivedEvents: UInt64
  let deliveredEvents: UInt64
  let sentEvents: UInt64
  let uplinkCount: Int
  let downlinkCount: Int
  let droppedEvents: UInt64
  let ingressEventsPerSecond: UInt64
  let egressEventsPerSecond: UInt64
  let cancellationCount: Int
  let pauseClaims: Int
  let pauseResumes: Int
}

private final class FlowManualScheduler: @unchecked Sendable {
  private struct Waiter {
    let deadline: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var current: UInt64
  private var waiters: [UUID: Waiter] = [:]

  init(startNanoseconds: UInt64) {
    current = startNanoseconds
  }

  var scheduler: ViewerAdmissionScheduler {
    ViewerAdmissionScheduler(
      now: { [weak self] in self?.now ?? 0 },
      sleep: { [weak self] duration in
        guard let self else { throw CancellationError() }
        try await self.sleep(duration: duration)
      }
    )
  }

  func advance(by duration: UInt64) {
    let ready: [CheckedContinuation<Void, Error>]
    lock.lock()
    let (advanced, overflow) = current.addingReportingOverflow(duration)
    current = overflow ? UInt64.max : advanced
    let due = waiters.filter { $0.value.deadline <= current }
    for id in due.keys { waiters.removeValue(forKey: id) }
    ready = due.values.map(\.continuation)
    lock.unlock()
    for continuation in ready { continuation.resume() }
  }

  var pendingDeadlines: [UInt64] {
    lock.lock()
    defer { lock.unlock() }
    return waiters.values.map(\.deadline)
  }

  private var now: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  private func sleep(duration: UInt64) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        if Task.isCancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        let (deadline, overflow) = current.addingReportingOverflow(duration)
        if overflow {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        waiters[id] = Waiter(deadline: deadline, continuation: continuation)
        lock.unlock()
      }
    } onCancel: {
      self.cancel(id: id)
    }
  }

  private func cancel(id: UUID) {
    lock.lock()
    let continuation = waiters.removeValue(forKey: id)?.continuation
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
  }
}

private final class FlowAdmissionChannel: ViewerAdmissionChannel, @unchecked Sendable {
  private let lock = NSLock()
  private var payloads: [Data] = []
  private var cancellations = 0
  private var pauseClaims = 0
  private var pauseResumes = 0
  private var pauseCancellations = 0
  private var reservedAdmissionAllowed = true
  private var rejectNextReserved = false
  private var reservations: [FlowReservedSend] = []
  private var pauseClaimHook: (@Sendable () -> Void)?

  func admitSend(_ data: Data) throws {
    lock.lock()
    payloads.append(data)
    lock.unlock()
  }

  func admitSend(
    _ data: Data,
    reservingPendingSendCount: Int,
    reservingPendingSendBytes: Int
  ) throws {
    lock.lock()
    let allowed = reservedAdmissionAllowed
    let rejectsAuthoritatively = rejectNextReserved
    rejectNextReserved = false
    if allowed && !rejectsAuthoritatively {
      payloads.append(data)
      reservations.append(
        FlowReservedSend(
          count: reservingPendingSendCount,
          bytes: reservingPendingSendBytes
        )
      )
    }
    lock.unlock()
    if rejectsAuthoritatively {
      throw SecureTransportError(
        code: .backpressure,
        path: "sendMailbox",
        message: "Injected authoritative backpressure."
      )
    }
    if !allowed { throw FlowChannelError.backpressure }
  }

  func canAdmitSend(
    byteCount: Int,
    reservingPendingSendCount: Int,
    reservingPendingSendBytes: Int
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return reservedAdmissionAllowed
  }

  func claimReceivePause() -> SecureReceivePauseToken? {
    lock.lock()
    pauseClaims += 1
    let hook = pauseClaimHook
    pauseClaimHook = nil
    lock.unlock()
    hook?()
    return SecureReceivePauseToken { [weak self] resumes in
      self?.recordPauseResolution(resumes: resumes)
    }
  }

  func start() async throws {}

  func cancel() async {
    recordCancellation()
  }

  private func recordCancellation() {
    lock.lock()
    cancellations += 1
    lock.unlock()
  }

  private func recordPauseResolution(resumes: Bool) {
    lock.lock()
    if resumes {
      pauseResumes += 1
    } else {
      pauseCancellations += 1
    }
    lock.unlock()
  }

  func setReservedAdmissionAllowed(_ allowed: Bool) {
    lock.lock()
    reservedAdmissionAllowed = allowed
    lock.unlock()
  }

  func rejectNextReservedAdmission() {
    lock.lock()
    rejectNextReserved = true
    lock.unlock()
  }

  func setPauseClaimHook(_ hook: @escaping @Sendable () -> Void) {
    lock.lock()
    pauseClaimHook = hook
    lock.unlock()
  }

  var sentPayloads: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return payloads
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancellations
  }

  var pauseResolutionCounts: (claims: Int, resumes: Int, cancellations: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (pauseClaims, pauseResumes, pauseCancellations)
  }

  var reservedSendRecords: [FlowReservedSend] {
    lock.lock()
    defer { lock.unlock() }
    return reservations
  }
}

private struct FlowReservedSend: Equatable {
  let count: Int
  let bytes: Int
}

private enum FlowChannelError: Error {
  case backpressure
}

private final class FlowIncomingConnection: ViewerIncomingConnection, @unchecked Sendable {
  let channel = FlowAdmissionChannel()
  private let lock = NSLock()
  private var handler: SecureByteChannel.EventHandler?

  func makeAdmissionChannel(
    queue: DispatchQueue,
    eventHandler: @escaping SecureByteChannel.EventHandler
  ) throws -> any ViewerAdmissionChannel {
    lock.lock()
    handler = eventHandler
    lock.unlock()
    return channel
  }

  func reject() {}

  func emit(_ event: SecureByteChannelEvent) {
    lock.lock()
    let handler = handler
    lock.unlock()
    handler?(event)
  }
}

private final class FlowSnapshotBox: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshots: [ViewerSessionSnapshot] = []

  func set(_ value: [ViewerSessionSnapshot]) {
    lock.lock()
    snapshots = value
    lock.unlock()
  }

  var value: [ViewerSessionSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return snapshots
  }
}

private final class FlowPendingBox: @unchecked Sendable {
  private let lock = NSLock()
  private var summaries: [ViewerPendingAppSummary] = []

  func set(_ value: [ViewerPendingAppSummary]) {
    lock.lock()
    summaries = value
    lock.unlock()
  }

  var value: [ViewerPendingAppSummary] {
    lock.lock()
    defer { lock.unlock() }
    return summaries
  }
}

private final class FlowEventBox: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [WireReceivedEvent] = []

  func append(_ value: WireReceivedEvent) {
    lock.lock()
    events.append(value)
    lock.unlock()
  }

  var value: [WireReceivedEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}
