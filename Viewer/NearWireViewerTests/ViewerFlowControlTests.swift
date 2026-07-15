import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireFlowControl
@_spi(NearWireInternal) import NearWireTransport
import XCTest

@testable import NearWireViewer

final class ViewerFlowControlTests: XCTestCase {
  func testActiveViewerEventOwnersHaveContentFreeReflection() throws {
    let secret = "nearwire-viewer-active-owner-secret"
    let draft = try EventDraft(
      type: EventType.user("test.viewer.reflection"),
      content: .object(["secret": .string(secret)])
    )
    let appID = try EndpointID(rawValue: "reflection-app")
    let viewerID = try EndpointID(rawValue: "reflection-viewer")
    let envelope = try EventEnvelope(
      id: EventID(),
      type: EventType.user("test.viewer.reflection"),
      content: .object(["secret": .string(secret)]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      monotonicTimestampNanoseconds: 1_000,
      source: EventEndpoint(role: .app, id: appID),
      target: EventEndpoint(role: .viewer, id: viewerID),
      direction: .appToViewer,
      sessionEpoch: SessionEpoch(),
      sequence: EventSequence(0),
      priority: .normal,
      ttl: .default,
      causality: EventCausality()
    )
    let received = try WireEventRecord(
      envelope: envelope,
      remainingTTLNanoseconds: 1_000_000_000
    ).receiverEvent(receivedAtNanoseconds: 2_000)
    let queueID = EventID()
    let draftPending = try PendingEvent(
      id: EventID(),
      value: draft,
      accountedByteCount: 128,
      enqueuedAtNanoseconds: 0
    )
    let receivedPending = try PendingEvent(
      id: queueID,
      value: received,
      accountedByteCount: received.deterministicEncodedByteCount,
      enqueuedAtNanoseconds: 0
    )
    var draftQueue = BoundedEventQueue<EventDraft>()
    var receivedQueue = BoundedEventQueue<WireReceivedEvent>()
    _ = try draftQueue.enqueue(draftPending, nowOnQueueClockNanoseconds: 0)
    _ = try receivedQueue.enqueue(receivedPending, nowOnQueueClockNanoseconds: 0)
    let item = ViewerUplinkHandoff.Item(queueID: queueID, event: received)
    let payload = ViewerUplinkPayload(item)
    let handoff = ViewerUplinkHandoff()

    let forbidden = [secret, queueID.rawValue]
    let values: [Any] = [draftQueue, receivedQueue, item, payload, handoff]
    for value in values {
      let diagnostics = [String(describing: value), String(reflecting: value), "\(value)"]
      for marker in forbidden {
        XCTAssertFalse(diagnostics.contains { $0.contains(marker) })
        XCTAssertFalse(
          Mirror(reflecting: value).children.contains {
            String(reflecting: $0.value).contains(marker)
          }
        )
      }
    }
  }

  func testAdmissionAndActiveSessionRootsHaveClosedReflection() throws {
    let markers = [
      "viewer-root-installation-secret",
      "Viewer Root Display Secret",
      "com.example.viewer.root.secret",
      "77.viewer-root-secret",
    ]
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: try EndpointID(rawValue: markers[0]),
      displayName: markers[1],
      applicationIdentifier: markers[2],
      applicationVersion: markers[3]
    )
    let owner = FlowReflectionHandoffOwner()
    let pending = FlowPendingBox()
    let admission = ViewerAdmissionManager(
      onPending: { pending.set($0) },
      handoffOwner: owner
    )
    admission.setRequiresApproval(true)
    let generation = UUID()
    admission.activateGeneration(generation)
    let connection = FlowIncomingConnection()
    admission.admit(
      connection,
      generation: generation,
      viewerInstallationID: try EndpointID(rawValue: "viewer-root-local")
    )
    connection.emit(.stateChanged(.ready))
    connection.emit(.received(try WirePreHandshakeCodec().encode(appHello)))
    waitUntil { pending.value.count == 1 }
    assertClosedDiagnostics([admission], excluding: markers)

    admission.accept(try XCTUnwrap(pending.value.first?.id))
    waitUntil { owner.snapshot != nil }
    let captured = try XCTUnwrap(owner.snapshot)
    assertClosedDiagnostics(
      [captured.context, captured.handle, captured.handle.connectionCore, captured.session],
      excluding: markers
    )

    let activeManager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
      preferences: try isolatedPreferences()
    )
    let activeAdmission = ViewerAdmissionManager(
      onPending: { _ in },
      handoffOwner: activeManager
    )
    let activeGeneration = UUID()
    activeAdmission.activateGeneration(activeGeneration)
    let activeConnection = FlowIncomingConnection()
    activeAdmission.admit(
      activeConnection,
      generation: activeGeneration,
      viewerInstallationID: try EndpointID(rawValue: "viewer-root-manager")
    )
    activeConnection.emit(.stateChanged(.ready))
    activeConnection.emit(.received(try WirePreHandshakeCodec().encode(appHello)))
    waitUntil { activeManager.ownedSessionCount == 1 }
    assertClosedDiagnostics([activeManager], excluding: markers)

    _ = activeAdmission.stop()
    _ = admission.stop()
  }

  func testViewerDownlinkPolicyReflectionRedactsKeepLatestKey() {
    let secret = "nearwire-viewer-queue-secret"
    let policy = ViewerDownlinkPolicy.keepLatest(secret)

    XCTAssertFalse(String(describing: policy).contains(secret))
    XCTAssertFalse(String(reflecting: policy).contains(secret))
    XCTAssertFalse("\(policy)".contains(secret))
    XCTAssertFalse(
      Mirror(reflecting: policy).children.contains {
        String(reflecting: $0.value).contains(secret)
      }
    )
  }

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

  func testManagerEnforcesSixteenCurrentSessionsAndReplacesExactRoute() throws {
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
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
    waitUntil {
      incoming[0].channel.cancelCount == 1 && duplicate.channel.sentPayloads.count >= 3
    }
    XCTAssertEqual(manager.ownedSessionCount, 16)
    XCTAssertEqual(duplicate.channel.cancelCount, 0)

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
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
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

  func testSameInstallationRouteVariantsRemainSeparateAndExactDuplicateReplacesOldSession() throws {
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
      preferences: try isolatedPreferences()
    )
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
    waitUntil { first.channel.cancelCount == 1 && duplicate.channel.sentPayloads.count >= 3 }
    let second = try connect(bundle: "com.example.second")
    let missing = try connect(bundle: nil)
    waitUntil { manager.ownedSessionCount == 3 }

    XCTAssertEqual(manager.ownedSessionCount, 3)
    XCTAssertEqual(duplicate.channel.cancelCount, 0)
    XCTAssertEqual(second.channel.cancelCount, 0)
    XCTAssertEqual(missing.channel.cancelCount, 0)
    _ = admission.stop()
  }

  func testExactRouteReplacementRevokesOldCapabilityWithoutTransferringOwnership() throws {
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
      preferences: try isolatedPreferences(),
      onSnapshots: { snapshots.set($0) }
    )
    let admission = ViewerAdmissionManager(onPending: { _ in }, handoffOwner: manager)
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-route-replacement")
    admission.activateGeneration(generation)

    func connect() throws -> FlowIncomingConnection {
      let connection = FlowIncomingConnection()
      admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
      connection.emit(.stateChanged(.ready))
      connection.emit(.received(try appHelloFrame(id: "replacement-app")))
      return connection
    }

    let firstConnection = try connect()
    waitUntil { manager.ownedSessionCount == 1 }
    let firstCapability = try XCTUnwrap(manager.controlTargets().first?.capability)
    let firstConnectionID = try XCTUnwrap(
      snapshots.value.first(where: { $0.state != .recent })?.connectionID
    )

    let replacementConnection = try connect()
    waitUntil {
      firstConnection.channel.cancelCount == 1
        && replacementConnection.channel.sentPayloads.count >= 3
        && manager.ownedSessionCount == 1
    }
    let replacementCapability = try XCTUnwrap(manager.controlTargets().first?.capability)
    let replacementConnectionID = try XCTUnwrap(
      snapshots.value.first(where: { $0.state != .recent })?.connectionID
    )
    XCTAssertNotEqual(firstCapability, replacementCapability)
    XCTAssertNotEqual(firstConnectionID, replacementConnectionID)
    XCTAssertFalse(
      manager.send(
        try EventDraft(type: EventType.user("replacement.old"), content: .null),
        to: firstConnectionID
      )
    )
    XCTAssertEqual(
      try manager.send(
        ViewerPreparedControlEvent(
          draft: EventDraft(type: EventType.user("replacement.capability"), content: .null),
          policy: .normal
        ),
        to: [firstCapability, replacementCapability]
      ).map(\.outcome),
      [.noLongerConnected, .notActive]
    )

    let shutdown = manager.beginShutdown()
    let stopped = expectation(description: "Replacement cleanup")
    Task {
      await shutdown.value
      stopped.fulfill()
    }
    wait(for: [stopped], timeout: 3)
    XCTAssertEqual(manager.ownedSessionCount, 0)
    XCTAssertEqual(manager.displacedSessionCount, 0)
    _ = admission.stop()
  }

  func testExactRouteAttachmentFailurePreservesCurrentOwnerAndCapability() throws {
    let attachments = FlowCounterBox()
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
      preferences: try isolatedPreferences(),
      onSnapshots: { snapshots.set($0) },
      sessionAttacher: { core, receiver in
        attachments.increment()
        guard attachments.value != 2 else { throw FlowChannelError.backpressure }
        try core.attachSession(receiver)
      }
    )
    let admission = ViewerAdmissionManager(onPending: { _ in }, handoffOwner: manager)
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-route-attachment-rollback")
    admission.activateGeneration(generation)

    func connect() throws -> FlowIncomingConnection {
      let connection = FlowIncomingConnection()
      admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
      connection.emit(.stateChanged(.ready))
      connection.emit(.received(try appHelloFrame(id: "attachment-rollback-app")))
      return connection
    }

    let first = try connect()
    waitUntil { manager.ownedSessionCount == 1 }
    let firstCapability = try XCTUnwrap(manager.controlTargets().first?.capability)
    let firstConnectionID = try XCTUnwrap(
      snapshots.value.first(where: { $0.state != .recent })?.connectionID
    )

    let failedReplacement = try connect()
    waitUntil { failedReplacement.channel.cancelCount == 1 }

    XCTAssertEqual(attachments.value, 2)
    XCTAssertEqual(manager.ownedSessionCount, 1)
    XCTAssertEqual(manager.displacedSessionCount, 0)
    XCTAssertEqual(first.channel.cancelCount, 0)
    XCTAssertEqual(manager.controlTargets().first?.connectionID, firstConnectionID)
    XCTAssertEqual(manager.controlTargets().first?.capability, firstCapability)
    _ = admission.stop()
  }

  func testExactRouteRejectsAnotherReplacementWhileDisplacedCleanupIsPending() throws {
    let cancellationGate = FlowCancellationGate()
    cancellationGate.hold()
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
      preferences: try isolatedPreferences()
    )
    let admission = ViewerAdmissionManager(onPending: { _ in }, handoffOwner: manager)
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-replacement-bound")
    admission.activateGeneration(generation)

    func connect(_ connection: FlowIncomingConnection) throws {
      admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
      connection.emit(.stateChanged(.ready))
      connection.emit(.received(try appHelloFrame(id: "bounded-replacement")))
    }

    let first = FlowIncomingConnection(cancellationGate: cancellationGate)
    try connect(first)
    waitUntil { manager.ownedSessionCount == 1 }

    let replacement = FlowIncomingConnection()
    try connect(replacement)
    waitUntil {
      first.channel.cancelCount == 1 && manager.displacedSessionCount == 1
        && replacement.channel.sentPayloads.count >= 3
    }

    let additional = FlowIncomingConnection()
    try connect(additional)
    waitUntil { additional.channel.cancelCount == 1 }
    XCTAssertEqual(manager.ownedSessionCount, 1)
    XCTAssertEqual(manager.displacedSessionCount, 1)
    XCTAssertEqual(replacement.channel.cancelCount, 0)

    cancellationGate.release()
    waitUntil { manager.displacedSessionCount == 0 }
    _ = admission.stop()
  }

  func testApprovalPreservesCoalescedSessionSuffixUntilSameCoreAttachment() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let pending = FlowPendingBox()
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
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
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
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
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
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
    waitUntil { clock.pendingDeadlines.contains(1_500_000_000) }
    clock.advance(by: 500_000_000)
    waitUntil { fixture.connection.channel.reservedAdmissionDenialCount == 1 }
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
    waitUntil { clock.pendingDeadlines.contains(1_500_000_000) }
    clock.advance(by: 500_000_000)
    waitUntil { fixture.connection.channel.authoritativeReservedRejectionCount == 1 }
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
    let journal = FlowJournalBox()
    let sharedID = EventID()
    let fixture = try establishActiveSession(
      clock: clock,
      appIDRaw: "app-exact-ttl",
      uplinkSink: { _, event in
        delivered.append(event)
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      },
      journal: journal
    )

    func record(sequence: UInt64, ttl: UInt64) throws -> WireEventRecord {
      let envelope = try EventEnvelope(
        id: sharedID,
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
    waitUntil {
      journal.uplinkTerminals.contains {
        $0.wireSequence == 1 && $0.disposition == .expired
      }
    }
    XCTAssertEqual(
      journal.uplinkTerminals.filter { $0.wireSequence == 0 }.map(\.disposition),
      [.consumerAccepted]
    )
    XCTAssertEqual(
      journal.uplinkTerminals.filter { $0.wireSequence == 1 }.map(\.disposition),
      [.expired]
    )
    XCTAssertEqual(fixture.snapshots.value.first?.state, .active)
    release.signal()
    _ = fixture.admission.stop()
  }

  func testDropJournalPublishesMonotonicCumulativeLocalAndRemoteSamples() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let journal = FlowJournalBox()
    let fixture = try establishActiveSession(
      clock: clock,
      appIDRaw: "app-cumulative-drops",
      journal: journal
    )
    let connectionID = try XCTUnwrap(fixture.snapshots.value.first?.connectionID)
    let draft = try EventDraft(
      type: EventType.user("test.cumulative-drops"),
      content: .object(["value": .integer(1)])
    )

    XCTAssertTrue(
      fixture.manager.send(draft, to: connectionID, policy: .keepLatest("same-key"))
    )
    XCTAssertTrue(
      fixture.manager.send(draft, to: connectionID, policy: .keepLatest("same-key"))
    )
    XCTAssertTrue(
      fixture.manager.send(draft, to: connectionID, policy: .keepLatest("same-key"))
    )
    waitUntil {
      journal.dropSamples.filter { $0.reason == .localCoalesced }.map(\.count) == [1, 2]
    }

    func sendRemote(overflow: UInt64, expired: UInt64 = 0, coalesced: UInt64 = 0) throws {
      fixture.connection.emit(
        .received(
          try fixture.codec.encode(
            WireDropSummaryPayload(
              overflowDropped: overflow,
              expired: expired,
              coalesced: coalesced
            ),
            phase: .active
          )
        )
      )
    }

    try sendRemote(overflow: 2)
    try sendRemote(overflow: 3)
    try sendRemote(overflow: 0)
    try sendRemote(overflow: UInt64.max)
    try sendRemote(overflow: 1)
    waitUntil {
      journal.dropSamples.filter { $0.reason == .remoteOverflow }.map(\.count)
        == [2, 5, UInt64.max]
    }
    XCTAssertEqual(fixture.snapshots.value.first?.remoteDroppedEvents, UInt64.max)
    XCTAssertEqual(
      journal.dropSamples.filter { $0.reason == .localCoalesced }.map(\.count),
      [1, 2]
    )
    XCTAssertEqual(
      journal.dropSamples.filter { $0.reason == .remoteOverflow }.map(\.count),
      [2, 5, UInt64.max]
    )
    _ = fixture.admission.stop()
  }

  func testTerminalClearsQueuedUplinkAndSameRouteReconnectReusesSequenceZero() throws {
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
      appIDRaw: "app-terminal-handoff",
      uplinkSink: { _, event in delivered.append(event) }
    )
    XCTAssertNotEqual(first.acknowledgement.sessionEpoch, second.acknowledgement.sessionEpoch)
    XCTAssertNotEqual(
      first.snapshots.value.first?.connectionID,
      second.snapshots.value.first?.connectionID
    )
    try sendRecord(0, through: second)
    waitUntil { delivered.value.count == 1 }
    XCTAssertEqual(second.snapshots.value.first?.state, .active)

    release.signal()
    _ = first.admission.stop()
    _ = second.admission.stop()
  }

  func testDuplicatePeerEventIdentifiersRetainIndependentJournalOwnership() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let journal = FlowJournalBox()
    let fixture = try establishActiveSession(
      clock: clock,
      appIDRaw: "app-duplicate-peer-event-id",
      uplinkSink: { _, _ in
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      },
      journal: journal,
      eventWallMilliseconds: { 4_242 }
    )
    let sharedID = EventID()

    func record(sequence: UInt64) throws -> WireEventRecord {
      let envelope = try EventEnvelope(
        id: sharedID,
        type: EventType.user("test.duplicate-peer-event-id"),
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
      return try WireEventRecord(
        envelope: envelope,
        remainingTTLNanoseconds: 10_000_000_000
      )
    }

    fixture.connection.emit(
      .received(
        try fixture.codec.encode(
          WireEventBatchPayload(
            records: [try record(sequence: 0), try record(sequence: 1)],
            limits: fixture.codec.limits
          ),
          phase: .active
        )
      )
    )

    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    waitUntil {
      journal.uplinkCommits.count == 2
        && journal.uplinkTerminals.contains {
          $0.wireSequence == 0 && $0.disposition == .consumerAccepted
        }
    }
    XCTAssertEqual(journal.uplinkCommits.map(\.eventID), [sharedID, sharedID])
    XCTAssertEqual(journal.uplinkCommits.map(\.viewerWallMilliseconds), [4_242, 4_242])
    XCTAssertEqual(
      journal.uplinkCommits.map(\.viewerMonotonicNanoseconds),
      [1_000_000_000, 1_000_000_000]
    )

    fixture.manager.disconnect(
      connectionID: try XCTUnwrap(fixture.snapshots.value.first?.connectionID)
    )
    waitUntil {
      journal.uplinkTerminals.contains {
        $0.wireSequence == 1 && $0.disposition == .sessionEnded
      }
    }
    XCTAssertEqual(
      journal.uplinkTerminals.filter { $0.wireSequence == 0 }.map(\.disposition),
      [.consumerAccepted]
    )
    XCTAssertEqual(
      journal.uplinkTerminals.filter { $0.wireSequence == 1 }.map(\.disposition),
      [.sessionEnded]
    )

    release.signal()
    _ = fixture.admission.stop()
  }

  func testSessionIdentityViolationsNeverCreateCommittedObservations() throws {
    enum Violation: CaseIterable, Equatable { case source, target, epoch }

    for (index, violation) in Violation.allCases.enumerated() {
      let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
      let journal = FlowJournalBox()
      let fixture = try establishActiveSession(
        clock: clock,
        appIDRaw: "app-observation-invariant-\(index)",
        journal: journal
      )
      let source =
        violation == .source
        ? EventEndpoint(
          role: .app,
          id: try EndpointID(rawValue: "other-observation-app-\(index)")
        ) : EventEndpoint(role: .app, id: fixture.appID)
      let target =
        violation == .target
        ? EventEndpoint(
          role: .viewer,
          id: try EndpointID(rawValue: "other-observation-viewer-\(index)")
        ) : EventEndpoint(role: .viewer, id: fixture.viewerID)
      let epoch =
        violation == .epoch ? SessionEpoch() : fixture.acknowledgement.sessionEpoch
      let envelope = try EventEnvelope(
        id: EventID(),
        type: EventType.user("test.observation-invariant"),
        content: .object(["value": .integer(Int64(index))]),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        monotonicTimestampNanoseconds: 1_000_000_000,
        source: source,
        target: target,
        direction: .appToViewer,
        sessionEpoch: epoch,
        sequence: EventSequence(0),
        priority: .normal,
        ttl: .default,
        causality: EventCausality()
      )
      fixture.connection.emit(
        .received(
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
      )
      waitUntil { fixture.connection.channel.cancelCount == 1 }
      XCTAssertTrue(journal.uplinkCommits.isEmpty)
      XCTAssertEqual(fixture.snapshots.value.first?.terminalCategory, .protocolViolation)
      _ = fixture.admission.stop()
    }
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

  func testPreparedControlEventEncodesOnceAndClassifiesTargetsAuthoritatively() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(clock: clock, appIDRaw: "app-control-target")
    let target = try XCTUnwrap(fixture.manager.controlTargets().first)
    let counter = FlowCounterBox()
    let draft = try EventDraft(
      type: EventType.user("control.test"),
      content: .object(["secret": .string("prepared-control-secret")])
    )
    let prepared = try ViewerPreparedControlEvent(draft: draft, policy: .normal) { draft in
      counter.increment()
      return try JSONEncoder().encode(draft)
    }
    XCTAssertEqual(counter.value, 1)

    let queued = try fixture.manager.send(prepared, to: [target.capability])
    XCTAssertEqual(queued.map(\.inputIndex), [0])
    XCTAssertEqual(queued.map(\.outcome), [.queued])
    XCTAssertEqual(queued.map(\.statusText), ["Queued locally"])
    XCTAssertEqual(counter.value, 1)

    let duplicates = try fixture.manager.send(
      prepared,
      to: [target.capability, target.capability]
    )
    XCTAssertEqual(duplicates.map(\.inputIndex), [0, 1])
    XCTAssertEqual(duplicates.map(\.outcome), [.invalidTarget, .invalidTarget])
    XCTAssertEqual(counter.value, 1)

    let wrongRuntime = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: fixture.manager.managerGeneration,
      scheduler: clock.scheduler,
      preferences: try isolatedPreferences()
    )
    XCTAssertEqual(
      try wrongRuntime.send(prepared, to: [target.capability]).map(\.outcome),
      [.invalidTarget]
    )
    let wrongGeneration = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: fixture.manager.runtimeLogicalID,
      managerGeneration: fixture.manager.managerGeneration + 1,
      scheduler: clock.scheduler,
      preferences: try isolatedPreferences()
    )
    XCTAssertEqual(
      try wrongGeneration.send(prepared, to: [target.capability]).map(\.outcome),
      [.invalidTarget]
    )
    let neverIssued = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: fixture.manager.runtimeLogicalID,
      managerGeneration: fixture.manager.managerGeneration,
      scheduler: clock.scheduler,
      preferences: try isolatedPreferences()
    )
    XCTAssertEqual(
      try neverIssued.send(prepared, to: [target.capability]).map(\.outcome),
      [.invalidTarget]
    )

    let oversized = try ViewerPreparedControlEvent(draft: draft, policy: .normal) { _ in
      Data(count: ViewerPreparedControlEvent.maximumEncodedBytes)
    }
    XCTAssertEqual(
      try fixture.manager.send(oversized, to: [target.capability]).map(\.outcome),
      [.queueRejected]
    )
    XCTAssertThrowsError(try fixture.manager.send(prepared, to: [])) { error in
      XCTAssertEqual(error as? ViewerControlSendError, .invalidTargetCount)
    }
    XCTAssertThrowsError(
      try fixture.manager.send(
        prepared,
        to: Array(
          repeating: target.capability, count: ViewerMultiDeviceSessionManager.maximumSessions + 1)
      )
    ) { error in
      XCTAssertEqual(error as? ViewerControlSendError, .invalidTargetCount)
    }

    let diagnosticSurfaces = [
      String(describing: target.capability),
      String(reflecting: target),
      String(describing: prepared),
      String(reflecting: queued[0]),
    ]
    XCTAssertFalse(diagnosticSurfaces.joined().contains("prepared-control-secret"))
    XCTAssertTrue(Mirror(reflecting: target.capability).children.isEmpty)

    _ = wrongRuntime.beginShutdown()
    _ = wrongGeneration.beginShutdown()
    _ = neverIssued.beginShutdown()
    _ = fixture.manager.beginShutdown()
    XCTAssertEqual(
      try fixture.manager.send(prepared, to: [target.capability]).map(\.outcome),
      [.invalidTarget]
    )
    XCTAssertTrue(fixture.manager.controlTargets().isEmpty)
    _ = fixture.admission.stop()
  }

  func testResolvedSessionRejectsControlWhileNegotiatingAndDisconnecting() throws {
    let owner = FlowReflectionHandoffOwner()
    let admission = ViewerAdmissionManager(onPending: { _ in }, handoffOwner: owner)
    let generation = UUID()
    let appID = try EndpointID(rawValue: "control-state-app")
    let viewerID = try EndpointID(rawValue: "control-state-viewer")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.nearwire.control-state"
    )
    let connection = FlowIncomingConnection()
    admission.activateGeneration(generation)
    admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
    connection.emit(.stateChanged(.ready))
    connection.emit(.received(try WirePreHandshakeCodec().encode(appHello)))
    waitUntil { owner.snapshot != nil }

    let captured = try XCTUnwrap(owner.snapshot)
    let prepared = try ViewerPreparedControlEvent(
      draft: EventDraft(type: EventType.user("control.state"), content: .null),
      policy: .normal
    )
    XCTAssertEqual(captured.session.enqueuePreparedControl(prepared), .notActive)
    XCTAssertEqual(owner.sessionState, .negotiating)

    let codec = try WireSessionCodec(negotiation: captured.context.negotiation)
    connection.emit(
      .received(
        try codec.encode(
          WireFlowPolicyAccepted(
            policy: try WireFlowPolicy(
              appUplinkEventsPerSecond: 20,
              appDownlinkEventsPerSecond: 10
            )
          ),
          phase: .negotiatingPolicy
        )
      )
    )
    waitUntil { owner.sessionState == .active }

    captured.session.disconnect(category: .userDisconnected)
    XCTAssertEqual(captured.session.enqueuePreparedControl(prepared), .notActive)
    waitUntil { owner.sessionState == .disconnecting }
    _ = admission.stop()
  }

  func testSixteenControlTargetsPreserveMixedAuthoritativeOrder() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
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
    let viewerID = try EndpointID(rawValue: "control-mixed-viewer")
    admission.activateGeneration(generation)

    func connect(
      index: Int,
      maximumEventBytes: Int,
      activate: Bool
    ) throws -> (ViewerControlTargetCapability, UUID) {
      let appID = try EndpointID(rawValue: String(format: "control-mixed-%02d", index))
      let appHello = try WireHello(
        productVersion: WireProductVersion("1.0"),
        role: .app,
        installationID: appID,
        maximumEventBytes: maximumEventBytes,
        applicationIdentifier: "com.nearwire.control-mixed.\(index)"
      )
      let connection = FlowIncomingConnection()
      admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
      connection.emit(.stateChanged(.ready))
      connection.emit(.received(try WirePreHandshakeCodec().encode(appHello)))
      waitUntil {
        snapshots.value.contains {
          $0.route.installationID == appID.rawValue && $0.connectionID != nil
        }
      }
      let connectionID = try XCTUnwrap(
        snapshots.value.first { $0.route.installationID == appID.rawValue }?.connectionID
      )
      let capability = try XCTUnwrap(
        manager.controlTargets().first { $0.connectionID == connectionID }?.capability
      )
      if activate {
        waitUntil { connection.channel.sentPayloads.count >= 3 }
        let viewerHello = try WireHello(
          productVersion: WireProductVersion("0.1.0"),
          role: .viewer,
          installationID: viewerID
        )
        let codec = try WireSessionCodec(
          negotiation: WireNegotiator.negotiate(local: appHello, remote: viewerHello)
        )
        connection.emit(
          .received(
            try codec.encode(
              WireFlowPolicyAccepted(
                policy: try WireFlowPolicy(
                  appUplinkEventsPerSecond: 20,
                  appDownlinkEventsPerSecond: 10
                )
              ),
              phase: .negotiatingPolicy
            )
          )
        )
        waitUntil {
          snapshots.value.first { $0.connectionID == connectionID }?.state == .active
        }
      }
      return (capability, connectionID)
    }

    var queued: [ViewerControlTargetCapability] = []
    var queueRejected: [ViewerControlTargetCapability] = []
    var negotiating: [ViewerControlTargetCapability] = []
    var terminal: [ViewerControlTargetCapability] = []
    for index in 0..<4 {
      queued.append(try connect(index: index, maximumEventBytes: 2_048, activate: true).0)
      queueRejected.append(
        try connect(index: index + 4, maximumEventBytes: 512, activate: true).0
      )
      negotiating.append(
        try connect(index: index + 8, maximumEventBytes: 2_048, activate: false).0
      )
      let terminalTarget = try connect(
        index: index + 12,
        maximumEventBytes: 2_048,
        activate: true
      )
      terminal.append(terminalTarget.0)
      manager.disconnect(connectionID: terminalTarget.1)
      waitUntil {
        snapshots.value.first {
          $0.route.installationID == String(format: "control-mixed-%02d", index + 12)
        }?.state == .recent
      }
    }

    let ordered = (0..<4).flatMap { index in
      [queued[index], queueRejected[index], negotiating[index], terminal[index]]
    }
    let prepared = try ViewerPreparedControlEvent(
      draft: EventDraft(type: EventType.user("control.mixed"), content: .null),
      policy: .normal,
      encode: { _ in Data(count: 1_024) }
    )
    let results = try manager.send(prepared, to: ordered)
    XCTAssertEqual(results.map(\.inputIndex), Array(0..<16))
    XCTAssertEqual(
      results.map(\.outcome),
      Array(repeating: [.queued, .queueRejected, .notActive, .noLongerConnected], count: 4)
        .flatMap { $0 }
    )
    XCTAssertEqual(results.filter { $0.outcome == .queued }.count, 4)
    XCTAssertEqual(results.map(\.statusText).filter { $0 == "Queued locally" }.count, 4)
    XCTAssertEqual(manager.terminalControlTargetCount, 4)
    _ = admission.stop()
  }

  @MainActor
  func testControlComposerUsesOpaqueTargetsCancelsReplacedAttemptAndReportsLocalAdmission()
    async throws
  {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(clock: clock, appIDRaw: "app-control-composer")
    let queue = DispatchQueue(label: "ViewerFlowControlTests.control-composer")
    let blockerStarted = DispatchSemaphore(value: 0)
    let blockerRelease = DispatchSemaphore(value: 0)
    queue.async {
      blockerStarted.signal()
      blockerRelease.wait()
    }
    XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)
    let controller = try ViewerControlComposerController(
      runtimeLogicalID: fixture.manager.runtimeLogicalID,
      sessionControl: fixture.manager,
      preparationService: ViewerComposerPreparationService(queue: queue)
    )
    controller.updateSessionSnapshots(fixture.snapshots.value)
    let target = try XCTUnwrap(controller.targetRows.first)
    controller.toggleTarget(target.id)
    XCTAssertTrue(controller.replaceWhole(.eventType, with: "control.composer"))
    XCTAssertTrue(
      controller.replaceWhole(
        .content,
        with: "{\"secret\":\"composer-ui-secret\",\"enabled\":true}"
      )
    )
    XCTAssertTrue(controller.replaceWhole(.ttl, with: "60000"))
    controller.setPriority(.high)
    controller.setPolicy(.keepLatest)
    XCTAssertFalse(
      controller.replaceWhole(.eventType, with: String(repeating: "x", count: 129))
    )
    XCTAssertEqual(controller.eventType, "control.composer")

    controller.send()
    XCTAssertEqual(controller.state, .preparing)
    controller.clearTargetSelection()
    XCTAssertEqual(controller.state, .idle)
    blockerRelease.signal()
    for _ in 0..<100 { await Task.yield() }
    XCTAssertTrue(controller.resultRows.isEmpty)

    controller.toggleTarget(target.id)
    controller.send()
    for _ in 0..<1_000 where controller.state == .preparing { await Task.yield() }
    XCTAssertEqual(controller.state, .completed)
    XCTAssertEqual(controller.resultRows.map(\.statusText), ["Queued locally"])
    XCTAssertEqual(controller.resultRows.map(\.outcome), [.queued])
    XCTAssertEqual(controller.model.preparedEvent?.policy, .keepLatest)
    XCTAssertEqual(controller.model.preparedEvent?.draft.priority, .high)
    XCTAssertEqual(controller.resultRows.count, 1)
    XCTAssertFalse(String(reflecting: controller).contains("composer-ui-secret"))
    XCTAssertTrue(Mirror(reflecting: controller).children.isEmpty)

    controller.clearDraft()
    XCTAssertEqual(controller.eventType, "")
    XCTAssertEqual(controller.contentJSON, "")
    XCTAssertEqual(controller.ttlText, "")
    XCTAssertTrue(controller.resultRows.isEmpty)
    controller.sealAndClear()
    XCTAssertTrue(controller.targetRows.isEmpty)
    XCTAssertTrue(controller.selectedTargetIDs.isEmpty)
    _ = fixture.manager.beginShutdown()
    _ = fixture.admission.stop()
  }

  @MainActor
  func testControlComposerHundredThousandReplacementsCancelBeforeDeliveryClaim() async throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(
      clock: clock,
      appIDRaw: "app-control-composer-replacement-stress"
    )
    let queue = DispatchQueue(label: "ViewerFlowControlTests.composer-replacements")
    let workerEntered = DispatchSemaphore(value: 0)
    let workerRelease = DispatchSemaphore(value: 0)
    queue.async {
      workerEntered.signal()
      workerRelease.wait()
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 1), .success)
    let preparationService = ViewerComposerPreparationService(queue: queue)
    let deliveryClaims = FlowCounterBox()
    let controller = try ViewerControlComposerController(
      runtimeLogicalID: fixture.manager.runtimeLogicalID,
      sessionControl: fixture.manager,
      preparationService: preparationService,
      preparationDeliveryClaimed: { deliveryClaims.increment() }
    )
    controller.updateSessionSnapshots(fixture.snapshots.value)
    let target = try XCTUnwrap(controller.targetRows.first)
    controller.toggleTarget(target.id)
    XCTAssertTrue(controller.replaceWhole(.eventType, with: "control.replacement"))
    XCTAssertTrue(
      controller.replaceWhole(.content, with: #"{"secret":"composer-replacement-secret"}"#)
    )
    XCTAssertTrue(controller.replaceWhole(.ttl, with: "60000"))

    for _ in 0..<100_000 { controller.send() }

    XCTAssertEqual(deliveryClaims.value, 0)
    XCTAssertEqual(preparationService.retainedRequestCountForTesting, 1)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 1)
    let cleanup = controller.sealAndClear()
    let cleanupCompletions = FlowCounterBox()
    Task {
      await cleanup.value
      cleanupCompletions.increment()
    }
    await Task.yield()
    XCTAssertEqual(cleanupCompletions.value, 0)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 1)

    workerRelease.signal()
    await cleanup.value
    for _ in 0..<100 where cleanupCompletions.value == 0 { await Task.yield() }
    XCTAssertEqual(cleanupCompletions.value, 1)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(deliveryClaims.value, 0)
    XCTAssertEqual(preparationService.retainedRequestCountForTesting, 0)
    XCTAssertEqual(controller.contentJSON, "")
    _ = fixture.manager.beginShutdown()
    _ = fixture.admission.stop()
  }

  @MainActor
  func testControlComposerBlockedMainActorRetainsBoundedClaimedResults() async throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(
      clock: clock,
      appIDRaw: "app-control-composer-blocked-main-actor"
    )
    let deliveryClaims = FlowCounterBox()
    let deliveryClaimed = DispatchSemaphore(value: 0)
    let controller = try ViewerControlComposerController(
      runtimeLogicalID: fixture.manager.runtimeLogicalID,
      sessionControl: fixture.manager,
      preparationService: ViewerComposerPreparationService(
        queue: DispatchQueue(label: "ViewerFlowControlTests.composer-blocked-main-actor")
      ),
      preparationDeliveryClaimed: {
        deliveryClaims.increment()
        deliveryClaimed.signal()
      }
    )
    controller.updateSessionSnapshots(fixture.snapshots.value)
    let target = try XCTUnwrap(controller.targetRows.first)
    controller.toggleTarget(target.id)
    XCTAssertTrue(controller.replaceWhole(.eventType, with: "control.blocked-main-actor"))
    XCTAssertTrue(controller.replaceWhole(.content, with: #"{"value":"bounded"}"#))
    XCTAssertTrue(controller.replaceWhole(.ttl, with: "60000"))

    for _ in 0..<255 {
      controller.send()
      XCTAssertEqual(deliveryClaimed.wait(timeout: .now() + 2), .success)
      XCTAssertLessThanOrEqual(
        controller.preparationDeliveryRetainedResultCountForTesting,
        controller.preparationDeliveryMaximumRetainedResultCountForTesting
      )
      XCTAssertLessThanOrEqual(controller.pendingCleanupWorkCount, 2)
    }

    let maximumStringBytes = controller.model.activeLimits.maximumStringBytes
    let stringCount =
      (controller.maximumContentBytes - 1 + maximumStringBytes + 2)
      / (maximumStringBytes + 3)
    var remainingStringBytes = controller.maximumContentBytes - (3 * stringCount + 1)
    let maximumContentStrings = (0..<stringCount).map { _ -> String in
      let count = min(maximumStringBytes, remainingStringBytes)
      remainingStringBytes -= count
      return String(repeating: "x", count: count)
    }
    XCTAssertEqual(remainingStringBytes, 0)
    let maximumContent =
      "["
      + maximumContentStrings.map { "\"" + $0 + "\"" }
      .joined(separator: ",")
      + "]"
    XCTAssertEqual(maximumContent.utf8.count, controller.maximumContentBytes)
    XCTAssertTrue(controller.replaceWhole(.content, with: maximumContent))
    controller.send()
    XCTAssertEqual(deliveryClaimed.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(deliveryClaims.value, 256)
    XCTAssertEqual(controller.preparationDeliveryMaximumRetainedResultCountForTesting, 2)
    XCTAssertLessThanOrEqual(controller.preparationDeliveryRetainedResultCountForTesting, 2)
    XCTAssertLessThanOrEqual(controller.pendingCleanupWorkCount, 2)

    for _ in 0..<1_000 where controller.pendingCleanupWorkCount != 0 { await Task.yield() }
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(controller.state, .completed)
    XCTAssertNotNil(controller.model.preparedEvent)

    await controller.sealAndClear().value
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(controller.preparationDeliveryRetainedResultCountForTesting, 0)
    XCTAssertEqual(controller.contentJSON, "")
    XCTAssertNil(controller.model.preparedEvent)
    _ = fixture.manager.beginShutdown()
    _ = fixture.admission.stop()
  }

  @MainActor
  func testControlComposerCleanupJoinsClaimedContentBearingDelivery() async throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let fixture = try establishActiveSession(
      clock: clock,
      appIDRaw: "app-control-composer-claimed-delivery"
    )
    let deliveryGate = FlowArmableExecutionGate()
    let preparationService = ViewerComposerPreparationService(
      queue: DispatchQueue(label: "ViewerFlowControlTests.composer-claimed-delivery")
    )
    let controller = try ViewerControlComposerController(
      runtimeLogicalID: fixture.manager.runtimeLogicalID,
      sessionControl: fixture.manager,
      preparationService: preparationService,
      preparationDeliveryClaimed: { deliveryGate.run() }
    )
    controller.updateSessionSnapshots(fixture.snapshots.value)
    let target = try XCTUnwrap(controller.targetRows.first)
    controller.toggleTarget(target.id)
    XCTAssertTrue(controller.replaceWhole(.eventType, with: "control.claimed"))
    XCTAssertTrue(
      controller.replaceWhole(.content, with: #"{"secret":"claimed-composer-secret"}"#)
    )
    XCTAssertTrue(controller.replaceWhole(.ttl, with: "60000"))

    deliveryGate.arm()
    controller.send()
    XCTAssertEqual(deliveryGate.waitUntilBlocked(), .success)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 2)
    let cleanup = controller.sealAndClear()
    let cleanupCompletions = FlowCounterBox()
    Task {
      await cleanup.value
      cleanupCompletions.increment()
    }
    await Task.yield()
    XCTAssertEqual(cleanupCompletions.value, 0)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 1)
    XCTAssertEqual(controller.contentJSON, "")
    XCTAssertNil(controller.model.preparedEvent)

    deliveryGate.release()
    await cleanup.value
    for _ in 0..<100 where cleanupCompletions.value == 0 { await Task.yield() }
    XCTAssertEqual(cleanupCompletions.value, 1)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(preparationService.retainedRequestCountForTesting, 0)
    XCTAssertEqual(controller.contentJSON, "")
    XCTAssertNil(controller.model.preparedEvent)
    _ = fixture.manager.beginShutdown()
    _ = fixture.admission.stop()
  }

  func testPreparedControlEventRejectsInvalidEncodedSizes() throws {
    let draft = try EventDraft(
      type: EventType.user("control.size"),
      content: .null
    )
    XCTAssertThrowsError(
      try ViewerPreparedControlEvent(draft: draft, policy: .normal) { _ in Data() }
    ) { error in
      XCTAssertEqual(error as? ViewerPreparedControlEventError, .invalidEncodedSize)
    }
    XCTAssertThrowsError(
      try ViewerPreparedControlEvent(draft: draft, policy: .normal) { _ in
        Data(count: ViewerPreparedControlEvent.maximumEncodedBytes + 1)
      }
    ) { error in
      XCTAssertEqual(error as? ViewerPreparedControlEventError, .invalidEncodedSize)
    }
  }

  func testSameRouteReconnectKeepsOldTerminalCapabilityIndependent() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let snapshots = FlowSnapshotBox()
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
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
    let viewerID = try EndpointID(rawValue: "viewer-control-reconnect")
    admission.activateGeneration(generation)

    func connect() throws -> ViewerControlTargetCapability {
      let connection = FlowIncomingConnection()
      admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
      connection.emit(.stateChanged(.ready))
      connection.emit(.received(try appHelloFrame(id: "control-reconnect")))
      waitUntil { manager.ownedSessionCount == 1 }
      return try XCTUnwrap(manager.controlTargets().first?.capability)
    }

    let first = try connect()
    manager.disconnect(
      connectionID: try XCTUnwrap(
        snapshots.value.first(where: { $0.state != .recent })?.connectionID
      )
    )
    waitUntil { manager.ownedSessionCount == 0 }
    let second = try connect()
    XCTAssertNotEqual(first, second)

    let prepared = try ViewerPreparedControlEvent(
      draft: EventDraft(type: EventType.user("control.reconnect"), content: .null),
      policy: .normal
    )
    XCTAssertEqual(
      try manager.send(prepared, to: [first, second]).map(\.outcome),
      [.noLongerConnected, .notActive]
    )

    manager.disconnect(
      connectionID: try XCTUnwrap(
        snapshots.value.first(where: { $0.state != .recent })?.connectionID
      )
    )
    waitUntil { manager.ownedSessionCount == 0 }
    XCTAssertEqual(manager.terminalControlTargetCount, 2)
    _ = admission.stop()
  }

  func testRecentRowsAreCappedAndExpireAtExactThirtySecondBoundary() throws {
    let clock = FlowManualScheduler(startNanoseconds: 1_000_000_000)
    let snapshots = FlowSnapshotBox()
    let tokenUUIDs = FlowSequentialUUIDSource()
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
      scheduler: clock.scheduler,
      preferences: try isolatedPreferences(),
      onSnapshots: { snapshots.set($0) },
      controlTokenUUID: { tokenUUIDs.next() }
    )
    let admission = ViewerAdmissionManager(
      onPending: { _ in },
      handoffOwner: manager,
      scheduler: clock.scheduler
    )
    let generation = UUID()
    let viewerID = try EndpointID(rawValue: "viewer-recent-cap")
    let prepared = try ViewerPreparedControlEvent(
      draft: EventDraft(type: EventType.user("control.cache"), content: .null),
      policy: .normal
    )
    var firstControlCapability: ViewerControlTargetCapability?
    var lastControlCapability: ViewerControlTargetCapability?
    admission.activateGeneration(generation)
    for index in 0...ViewerMultiDeviceSessionManager.maximumRecentRows {
      let appID = String(format: "recent-%03d", index)
      let connection = FlowIncomingConnection()
      admission.admit(connection, generation: generation, viewerInstallationID: viewerID)
      connection.emit(.stateChanged(.ready))
      connection.emit(.received(try appHelloFrame(id: appID)))
      waitUntil { manager.ownedSessionCount == 1 }
      let capability = try XCTUnwrap(manager.controlTargets().first?.capability)
      if index == 0 {
        firstControlCapability = capability
        XCTAssertEqual(
          try manager.send(prepared, to: [capability]).map(\.outcome),
          [.notActive]
        )
      }
      lastControlCapability = capability
      let liveID = try XCTUnwrap(
        snapshots.value.first(where: { $0.state != .recent })?.connectionID
      )
      manager.disconnect(connectionID: liveID)
      waitUntil { manager.ownedSessionCount == 0 }
    }
    XCTAssertEqual(manager.recentRowCount, ViewerMultiDeviceSessionManager.maximumRecentRows)
    XCTAssertEqual(
      manager.terminalControlTargetCount,
      ViewerMultiDeviceSessionManager.maximumTerminalControlTargets
    )
    XCTAssertFalse(snapshots.value.contains { $0.route.installationID == "recent-000" })
    XCTAssertTrue(snapshots.value.contains { $0.route.installationID == "recent-064" })
    XCTAssertEqual(
      try manager.send(prepared, to: [XCTUnwrap(firstControlCapability)]).map(\.outcome),
      [.invalidTarget]
    )
    XCTAssertEqual(
      try manager.send(prepared, to: [XCTUnwrap(lastControlCapability)]).map(\.outcome),
      [.noLongerConnected]
    )
    clock.advance(by: ViewerMultiDeviceSessionManager.recentTTLNanoseconds - 1)
    XCTAssertEqual(manager.recentRowCount, ViewerMultiDeviceSessionManager.maximumRecentRows)
    XCTAssertEqual(
      try manager.send(prepared, to: [XCTUnwrap(lastControlCapability)]).map(\.outcome),
      [.noLongerConnected]
    )
    clock.advance(by: 1)
    waitUntil { manager.recentRowCount == 0 }
    XCTAssertEqual(manager.terminalControlTargetCount, 0)
    XCTAssertEqual(
      try manager.send(prepared, to: [XCTUnwrap(lastControlCapability)]).map(\.outcome),
      [.invalidTarget]
    )
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
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
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
    uplinkSink: @escaping @Sendable (UUID, WireReceivedEvent) -> Void = { _, _ in },
    journal: any ViewerSessionJournaling = ViewerNoopSessionJournal(),
    eventWallMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
  ) throws -> FlowActiveFixture {
    let snapshots = FlowSnapshotBox()
    let suite = "ViewerFlowControlTests.fixture.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let manager = ViewerMultiDeviceSessionManager(
      runtimeLogicalID: UUID(),
      managerGeneration: 1,
      scheduler: clock.scheduler,
      preferences: ViewerDevicePreferences(defaults: defaults),
      onSnapshots: { snapshots.set($0) },
      uplinkSink: uplinkSink,
      eventWallMilliseconds: eventWallMilliseconds,
      journal: journal
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

  private func assertClosedDiagnostics(
    _ values: [Any],
    excluding markers: [String],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for value in values {
      let surfaces = [String(describing: value), String(reflecting: value), "\(value)"]
      for marker in markers {
        XCTAssertFalse(
          surfaces.contains { $0.contains(marker) },
          "Diagnostic surface exposed a forbidden marker.",
          file: file,
          line: line
        )
      }
      XCTAssertTrue(
        Mirror(reflecting: value).children.isEmpty,
        "Root reflection must not expose owned implementation state.",
        file: file,
        line: line
      )
    }
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

private final class FlowReflectionHandoffOwner: ViewerAdmissionHandoffOwning, @unchecked Sendable {
  struct Snapshot {
    let handle: ViewerAdmissionHandle
    let context: ViewerAdmissionSessionContext
    let session: ViewerDeviceSession
  }

  private let lock = NSLock()
  private var captured: Snapshot?
  private var latestSessionState: ViewerSessionState?

  var snapshot: Snapshot? {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  var sessionState: ViewerSessionState? {
    lock.lock()
    defer { lock.unlock() }
    return latestSessionState
  }

  func transfer(_ handle: ViewerAdmissionHandle) -> Bool {
    do {
      let context = try handle.connectionCore.pendingSessionContext()
      let session = try ViewerDeviceSession(
        handle: handle,
        context: context,
        requestedPolicy: .default,
        nickname: nil,
        scheduler: .live,
        uplinkSink: { _ in },
        onSnapshot: { [weak self] snapshot in self?.record(state: snapshot.state) },
        onTerminal: { _, _ in }
      )
      try handle.connectionCore.attachSession(session)
      lock.lock()
      captured = Snapshot(handle: handle, context: context, session: session)
      lock.unlock()
      session.start()
      return true
    } catch {
      return false
    }
  }

  func beginShutdown() -> Task<Void, Never> {
    let session = snapshot?.session
    session?.disconnect(category: .viewerShutdown)
    return Task {
      await session?.cancelAndWaitForCleanup()
    }
  }

  private func record(state: ViewerSessionState) {
    lock.lock()
    latestSessionState = state
    lock.unlock()
  }
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

private final class FlowJournalBox: ViewerSessionJournaling, @unchecked Sendable {
  struct UplinkCommit: Equatable {
    let eventID: EventID
    let wireSequence: UInt64
    let disposition: ViewerEventDisposition
    let viewerWallMilliseconds: Int64
    let viewerMonotonicNanoseconds: UInt64
  }

  struct UplinkTerminal: Equatable {
    let wireSequence: UInt64
    let disposition: ViewerEventDisposition
  }

  private let lock = NSLock()
  private var commits: [UplinkCommit] = []
  private var terminals: [UplinkTerminal] = []
  private var drops: [ViewerDropJournalSample] = []

  var uplinkCommits: [UplinkCommit] {
    lock.lock()
    defer { lock.unlock() }
    return commits
  }

  var uplinkTerminals: [UplinkTerminal] {
    lock.lock()
    defer { lock.unlock() }
    return terminals
  }

  var dropSamples: [ViewerDropJournalSample] {
    lock.lock()
    defer { lock.unlock() }
    return drops
  }

  func runtimeStarted(logicalID: UUID, wallMilliseconds: Int64, monotonicNanoseconds: UInt64) {}
  func sessionStarted(runtimeLogicalID: UUID, _ context: ViewerAdmissionSessionContext) {}

  func eventCommitted(
    _ observation: ViewerCommittedEventObservation,
    outcome: @escaping @Sendable (ViewerEventJournalOutcome) -> Void
  ) {
    guard observation.key.direction == .appToViewer else {
      outcome(.untracked)
      return
    }
    lock.lock()
    commits.append(
      UplinkCommit(
        eventID: observation.envelope.id,
        wireSequence: observation.key.wireSequence,
        disposition: observation.canonicalProjection.initialDisposition ?? .buffered,
        viewerWallMilliseconds: observation.viewerWallMilliseconds,
        viewerMonotonicNanoseconds: observation.viewerMonotonicNanoseconds
      )
    )
    lock.unlock()
    outcome(.untracked)
  }

  func uplinkTerminated(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    direction: EventDirection,
    wireSequence: UInt64,
    disposition: ViewerEventDisposition,
    monotonicNanoseconds: UInt64
  ) {
    lock.lock()
    terminals.append(
      UplinkTerminal(wireSequence: wireSequence, disposition: disposition)
    )
    lock.unlock()
  }

  func policyChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    policy: ViewerRatePolicy,
    monotonicNanoseconds: UInt64
  ) {}
  func dropsChanged(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    samples: [ViewerDropJournalSample],
    monotonicNanoseconds: UInt64
  ) {
    lock.lock()
    drops.append(contentsOf: samples)
    lock.unlock()
  }
  func sessionEnded(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) {}
  func retryStorage() {}
  func runtimeEnded(
    logicalID: UUID,
    wallMilliseconds: Int64,
    monotonicNanoseconds: UInt64
  ) async {}
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
  private var reservedAdmissionDenials = 0
  private var authoritativeReservedRejections = 0
  private var reservations: [FlowReservedSend] = []
  private var pauseClaimHook: (@Sendable () -> Void)?
  private let cancellationGate: FlowCancellationGate?

  init(cancellationGate: FlowCancellationGate? = nil) {
    self.cancellationGate = cancellationGate
  }

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
    if rejectsAuthoritatively { authoritativeReservedRejections += 1 }
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
    if !reservedAdmissionAllowed { reservedAdmissionDenials += 1 }
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
    await cancellationGate?.waitIfHeld()
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

  var authoritativeReservedRejectionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return authoritativeReservedRejections
  }

  var reservedAdmissionDenialCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reservedAdmissionDenials
  }
}

private struct FlowReservedSend: Equatable {
  let count: Int
  let bytes: Int
}

private enum FlowChannelError: Error {
  case backpressure
}

private final class FlowCounterBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  func increment() {
    lock.lock()
    storage += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class FlowArmableExecutionGate: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var armed = false

  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  func run() {
    lock.lock()
    let shouldBlock = armed
    armed = false
    lock.unlock()
    guard shouldBlock else { return }
    entered.signal()
    _ = resume.wait(timeout: .now() + 5)
  }

  func waitUntilBlocked() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class FlowSequentialUUIDSource: @unchecked Sendable {
  private let lock = NSLock()
  private var nextValue: UInt64 = 1

  func next() -> UUID {
    lock.lock()
    let value = nextValue
    nextValue += 1
    lock.unlock()
    return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", value))!
  }
}

private final class FlowIncomingConnection: ViewerIncomingConnection, @unchecked Sendable {
  let channel: FlowAdmissionChannel
  private let lock = NSLock()
  private var handler: SecureByteChannel.EventHandler?

  init(cancellationGate: FlowCancellationGate? = nil) {
    channel = FlowAdmissionChannel(cancellationGate: cancellationGate)
  }

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

private final class FlowCancellationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func hold() {
    lock.lock()
    isHeld = true
    lock.unlock()
  }

  func waitIfHeld() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      guard isHeld else {
        lock.unlock()
        continuation.resume()
        return
      }
      waiters.append(continuation)
      lock.unlock()
    }
  }

  func release() {
    lock.lock()
    isHeld = false
    let waiters = self.waiters
    self.waiters.removeAll()
    lock.unlock()
    for waiter in waiters { waiter.resume() }
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
