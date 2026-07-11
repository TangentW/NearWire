import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireFlowControl
import XCTest

@testable import NearWire
@_spi(NearWireInternal) @testable import NearWireTransport

final class NearWireBufferTests: XCTestCase {
  func testOutboundWakeRegistrationReturnsPrebufferedSnapshotAndUsesExactToken() async throws {
    let clock = SDKTestClock(
      identifiers: [
        UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
      ]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)
    let first = try await nearWire.send(type: "test.first", content: 1)
    let signals = SDKLockedCapture<Int>()
    let token = SDKOutboundWakeToken()
    let registration = try await nearWire.registerOutboundWorkWake(
      token: token,
      callback: { signals.append(1) },
      maximumServiceUnits: 8,
      gate: SDKActiveOperationGate()
    )

    XCTAssertTrue(registration.installed)
    guard case .available(let observation) = registration.schedule else {
      return XCTFail("Expected an available prebuffered schedule.")
    }
    XCTAssertEqual(
      observation.nextFairCandidateID.flatMap { UUID(uuidString: $0.rawValue) },
      first.eventID
    )
    XCTAssertEqual(signals.snapshot.count, 0)

    let staleToken = SDKOutboundWakeToken()
    await nearWire.removeOutboundWorkWake(token: staleToken)
    _ = try await nearWire.send(type: "test.second", content: 2)
    XCTAssertEqual(signals.snapshot.count, 1)

    await nearWire.removeOutboundWorkWake(token: token)
    _ = try await nearWire.send(type: "test.third", content: 3)
    XCTAssertEqual(signals.snapshot.count, 1)
  }

  func testOutboundWakeRejectsSecondRegistrationAndClosedGate() async throws {
    let nearWire = NearWire()
    let token = SDKOutboundWakeToken()
    _ = try await nearWire.registerOutboundWorkWake(
      token: token,
      callback: {},
      maximumServiceUnits: 1,
      gate: SDKActiveOperationGate()
    )
    do {
      _ = try await nearWire.registerOutboundWorkWake(
        token: SDKOutboundWakeToken(),
        callback: {},
        maximumServiceUnits: 1,
        gate: SDKActiveOperationGate()
      )
      XCTFail("Expected the second wake registration to fail.")
    } catch {
      XCTAssertEqual(error as? SDKOutboundWakeRegistrationError, .alreadyRegistered)
    }
    await nearWire.removeOutboundWorkWake(token: token)

    let closedGate = SDKActiveOperationGate()
    closedGate.close()
    let closed = try await nearWire.registerOutboundWorkWake(
      token: SDKOutboundWakeToken(),
      callback: {},
      maximumServiceUnits: 1,
      gate: closedGate
    )
    XCTAssertEqual(
      closed, SDKOutboundWakeRegistrationResult(installed: false, schedule: .terminalFirst))
  }

  func testOutboundWakeMakesShutdownLevelTriggeredBeforeAndAfterRegistration() async throws {
    let shutdownBeforeRegistration = NearWire()
    await shutdownBeforeRegistration.shutdown()
    let unavailable = try await shutdownBeforeRegistration.registerOutboundWorkWake(
      token: SDKOutboundWakeToken(),
      callback: {},
      maximumServiceUnits: 1,
      gate: SDKActiveOperationGate()
    )
    XCTAssertEqual(
      unavailable,
      SDKOutboundWakeRegistrationResult(installed: false, schedule: .ownerUnavailable)
    )

    let live = NearWire()
    let signals = SDKLockedCapture<Int>()
    let gate = SDKActiveOperationGate()
    let token = SDKOutboundWakeToken()
    _ = try await live.registerOutboundWorkWake(
      token: token,
      callback: { signals.append(1) },
      maximumServiceUnits: 1,
      gate: gate
    )
    await live.shutdown()
    XCTAssertEqual(signals.snapshot.count, 1)
    let shutdownSchedule = await live.outboundSchedule(maximumServiceUnits: 1, gate: gate)
    XCTAssertEqual(shutdownSchedule, .ownerUnavailable)
    await live.removeOutboundWorkWake(token: token)
  }

  func testWakeRegistrationSnapshotIsAtomicAndExpirationsClaimSeparately() async throws {
    let clock = SDKTestClock(
      identifiers: [
        UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
      ]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)
    let first = try await nearWire.send(
      type: "test.registration-expiry.first",
      content: 1,
      options: NearWireEventOptions(ttl: .milliseconds(1))
    )
    let second = try await nearWire.send(
      type: "test.registration-expiry.second",
      content: 2,
      options: NearWireEventOptions(ttl: .milliseconds(1))
    )
    clock.advanceMonotonic(by: 1_000_000)
    let wakeToken = SDKOutboundWakeToken()
    let gate = SDKActiveOperationGate()
    let registration = try await nearWire.registerOutboundWorkWake(
      token: wakeToken,
      callback: {},
      maximumServiceUnits: 2,
      gate: gate
    )
    XCTAssertTrue(registration.installed)
    guard case .available(let initial) = registration.schedule else {
      return XCTFail("Expected one complete install-first scheduling snapshot.")
    }
    XCTAssertTrue(initial.dueWorkRemains)
    XCTAssertEqual(initial.expiredEventIDs, [])

    let secondExpiration = SDKTargetSynchronousBarrier(targetEntry: 2)
    let schedule = Task {
      await nearWire.outboundSchedule(
        maximumServiceUnits: 2,
        gate: gate,
        operationHooks: SDKActiveLiveOperationHooks(
          beforeExpirationClaim: { secondExpiration.blockAtTarget() }
        )
      )
    }
    await secondExpiration.waitUntilReached()
    gate.close()
    secondExpiration.release()
    let result = await schedule.value

    XCTAssertEqual(result, .terminalFirst)
    let retry = await nearWire.outboundSchedule(
      maximumServiceUnits: 2,
      gate: SDKActiveOperationGate()
    )
    guard case .available(let observation) = retry else {
      return XCTFail("Expected the uncommitted expiration to remain for a later open claim.")
    }
    XCTAssertEqual(
      observation.expiredEventIDs.map(\.rawValue),
      [second.eventID.uuidString.lowercased()]
    )
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 0)
    XCTAssertEqual(diagnostics.statistics.expired, 2)
    XCTAssertNotEqual(first.eventID, second.eventID)
    await nearWire.removeOutboundWorkWake(token: wakeToken)
  }

  func testOutboundScheduleExpiresOnlyThroughOpenGate() async throws {
    let clock = SDKTestClock()
    let nearWire = NearWire(dependencies: clock.dependencies)
    let sent = try await nearWire.send(
      type: "test.expiring",
      content: 1,
      options: NearWireEventOptions(ttl: .milliseconds(1))
    )
    let signals = SDKLockedCapture<Int>()
    let gate = SDKActiveOperationGate()
    _ = try await nearWire.registerOutboundWorkWake(
      token: SDKOutboundWakeToken(),
      callback: { signals.append(1) },
      maximumServiceUnits: 1,
      gate: gate
    )
    clock.advanceMonotonic(by: 1_000_000)

    let result = await nearWire.outboundSchedule(maximumServiceUnits: 1, gate: gate)
    guard case .available(let observation) = result else {
      return XCTFail("Expected a live expiration result.")
    }
    XCTAssertEqual(
      observation.expiredEventIDs.compactMap { UUID(uuidString: $0.rawValue) },
      [sent.eventID]
    )
    XCTAssertEqual(signals.snapshot.count, 1)

    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 0)
    XCTAssertEqual(diagnostics.statistics.expired, 1)
  }

  func testOutboundSignalIngressCoalescesBeforeSchedulingAndStops() async {
    let scheduled = SDKLockedCapture<Int>()
    let ingress = SDKOutboundSignalIngress(route: { scheduled.append(1) })

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<128 {
        group.addTask { ingress.signal() }
      }
      await group.waitForAll()
    }
    XCTAssertEqual(scheduled.snapshot.count, 1)
    XCTAssertEqual(
      ingress.snapshot,
      SDKOutboundSignalIngress.Snapshot(isStopped: false, isScheduled: true, isDirty: true)
    )

    ingress.finishRoutingTurn()
    XCTAssertEqual(scheduled.snapshot.count, 2)
    XCTAssertEqual(
      ingress.snapshot,
      SDKOutboundSignalIngress.Snapshot(isStopped: false, isScheduled: true, isDirty: false)
    )
    ingress.finishRoutingTurn()
    XCTAssertFalse(ingress.snapshot.isScheduled)

    ingress.stop()
    ingress.signal()
    XCTAssertEqual(scheduled.snapshot.count, 2)
    XCTAssertTrue(ingress.snapshot.isStopped)
  }

  func testActiveWireDrainAdmitsExactEnvelopeAndAdvancesAcceptedSequence() async throws {
    let clock = SDKTestClock(
      identifiers: [UUID(uuidString: "00000000-0000-0000-0000-000000000201")!]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)
    let sent = try await nearWire.send(type: "test.active", content: ["value": 1])
    let codec = try makeSDKTestSessionCodec()
    let driver = SDKSecureConnectionDriver()
    let channel = SecureByteChannel(driver: driver) { _ in }
    try await channel.start()

    let result = await nearWire.drainActiveWire(
      for: sdkTestSessionRoute,
      codec: codec,
      sequenceCounter: try makeSDKTestSequenceCounter(),
      maximumServiceUnits: 4,
      maximumAcceptedEventCount: 1,
      maximumAccountedBytes: 256 * 1_024,
      channel: channel,
      reservingPendingSendCount: 2,
      reservingPendingSendBytes: 1_024,
      gate: SDKActiveOperationGate()
    )
    XCTAssertNil(result.failure)
    XCTAssertEqual(
      result.acceptedEventIDs.compactMap { UUID(uuidString: $0.rawValue) }, [sent.eventID])
    XCTAssertEqual(result.plannedSequenceCounter.nextRawValue, 1)
    XCTAssertGreaterThan(result.acceptedEncodedByteCount, 0)
    let drainedDiagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(drainedDiagnostics.eventCount, 0)

    driver.emitState(.ready)
    await sdkWaitUntil { driver.sentData.count == 1 }
    var frame: WireFrame?
    var decoder = WireFrameDecoder(limits: codec.limits.frame)
    try decoder.consume(try XCTUnwrap(driver.sentData.first)) { frame = $0 }
    let admitted = try codec.decode(frame: try XCTUnwrap(frame), phase: .active)
    let payload = try codec.decode(WireEventPayload.self, from: admitted)
    XCTAssertEqual(payload.record.envelope.id.rawValue, sent.eventID.uuidString.lowercased())
    XCTAssertEqual(payload.record.envelope.sequence.rawValue, 0)
    XCTAssertEqual(payload.record.envelope.source.id.rawValue, sdkTestSessionRoute.appID)
    XCTAssertEqual(payload.record.envelope.target.id.rawValue, sdkTestSessionRoute.viewerID)
    XCTAssertEqual(payload.record.remainingTTLNanoseconds, 60_000_000_000)
    await channel.cancel()
  }

  func testActiveWireDrainBackpressureRetainsCandidateAndCounter() async throws {
    let clock = SDKTestClock(
      identifiers: [UUID(uuidString: "00000000-0000-0000-0000-000000000211")!]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)
    let sent = try await nearWire.send(type: "test.blocked", content: 1)
    let limits = try SecureTransportLimits(
      maximumPendingSendCount: 3,
      maximumPendingSendBytes: 512 * 1_024,
      maximumSingleSendBytes: 256 * 1_024
    )
    let channel = SecureByteChannel(driver: SDKSecureConnectionDriver(), limits: limits) { _ in }
    try await channel.start()
    try channel.admitSend(Data([9]))
    let operationEntries = SDKLockedCapture<String>()

    let result = await nearWire.drainActiveWire(
      for: sdkTestSessionRoute,
      codec: try makeSDKTestSessionCodec(),
      sequenceCounter: try makeSDKTestSequenceCounter(),
      maximumServiceUnits: 4,
      maximumAcceptedEventCount: 1,
      maximumAccountedBytes: 256 * 1_024,
      channel: channel,
      reservingPendingSendCount: 2,
      reservingPendingSendBytes: 0,
      gate: SDKActiveOperationGate(),
      operationHooks: SDKActiveLiveOperationHooks(
        beforeCandidateClaim: { operationEntries.append("candidate") },
        beforeEventMailboxAdmission: { operationEntries.append("mailbox-admission") },
        beforeEventMailboxProgressSnapshot: { operationEntries.append("mailbox-progress") }
      )
    )

    XCTAssertEqual(
      result.rejectedEventIDs.compactMap { UUID(uuidString: $0.rawValue) }, [sent.eventID])
    XCTAssertEqual(result.plannedSequenceCounter.nextRawValue, 0)
    XCTAssertEqual(
      result.transportBlock?.candidateID.rawValue, sent.eventID.uuidString.lowercased())
    XCTAssertGreaterThan(result.transportBlock?.encodedByteCount ?? 0, 0)
    XCTAssertEqual(
      operationEntries.snapshot,
      ["candidate", "mailbox-admission", "mailbox-progress"]
    )
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 1)
    XCTAssertEqual(diagnostics.statistics.transportAdmissionRejected, 1)
    await channel.cancel()
  }

  func testActiveWireDrainClosedGateAndZeroAllowanceLeaveCandidateUnchanged() async throws {
    let clock = SDKTestClock(
      identifiers: [UUID(uuidString: "00000000-0000-0000-0000-000000000221")!]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)
    let sent = try await nearWire.send(type: "test.waiting", content: 1)
    let codec = try makeSDKTestSessionCodec()
    let channel = SecureByteChannel(driver: SDKSecureConnectionDriver()) { _ in }
    try await channel.start()

    let zeroAllowance = await nearWire.drainActiveWire(
      for: sdkTestSessionRoute,
      codec: codec,
      sequenceCounter: try makeSDKTestSequenceCounter(),
      maximumServiceUnits: 2,
      maximumAcceptedEventCount: 0,
      maximumAccountedBytes: 256 * 1_024,
      channel: channel,
      reservingPendingSendCount: 0,
      reservingPendingSendBytes: 0,
      gate: SDKActiveOperationGate()
    )
    XCTAssertTrue(zeroAllowance.eligibleWorkRemains)
    XCTAssertEqual(
      zeroAllowance.nextFairCandidateID?.rawValue, sent.eventID.uuidString.lowercased())
    XCTAssertEqual(zeroAllowance.acceptedEventIDs, [])

    let closedGate = SDKActiveOperationGate()
    closedGate.close()
    let terminalFirst = await nearWire.drainActiveWire(
      for: sdkTestSessionRoute,
      codec: codec,
      sequenceCounter: try makeSDKTestSequenceCounter(),
      maximumServiceUnits: 2,
      maximumAcceptedEventCount: 1,
      maximumAccountedBytes: 256 * 1_024,
      channel: channel,
      reservingPendingSendCount: 0,
      reservingPendingSendBytes: 0,
      gate: closedGate
    )
    XCTAssertTrue(terminalFirst.stoppedByTerminal)
    XCTAssertEqual(terminalFirst.plannedSequenceCounter.nextRawValue, 0)
    let retainedDiagnostics = try await nearWire.bufferDiagnostics()
    let channelLimits = channel.limits
    XCTAssertEqual(retainedDiagnostics.eventCount, 1)
    XCTAssertEqual(
      channel.sendCapacitySnapshot.availablePendingSendCount,
      channelLimits.maximumPendingSendCount
    )
    await channel.cancel()
  }

  func testActiveWireDrainCrossesTokenServiceByteDepthAndMailboxBounds() async throws {
    struct Case {
      let name: String
      let allowance: Int
      let serviceUnits: Int
      let accountedBytes: Int
      let depth: Int
      let blocksMailbox: Bool
      let expectedAccepted: Int
    }
    let cases = [
      Case(
        name: "zero-token", allowance: 0, serviceUnits: 4,
        accountedBytes: 256 * 1_024, depth: 3, blocksMailbox: false, expectedAccepted: 0),
      Case(
        name: "token-smaller", allowance: 1, serviceUnits: 4,
        accountedBytes: 256 * 1_024, depth: 3, blocksMailbox: false, expectedAccepted: 1),
      Case(
        name: "service-smaller", allowance: 4, serviceUnits: 1,
        accountedBytes: 256 * 1_024, depth: 3, blocksMailbox: false, expectedAccepted: 1),
      Case(
        name: "byte-smaller", allowance: 4, serviceUnits: 4,
        accountedBytes: 1, depth: 3, blocksMailbox: false, expectedAccepted: 0),
      Case(
        name: "equal-depth", allowance: 3, serviceUnits: 3,
        accountedBytes: 256 * 1_024, depth: 3, blocksMailbox: false, expectedAccepted: 3),
      Case(
        name: "mailbox-smaller", allowance: 4, serviceUnits: 4,
        accountedBytes: 256 * 1_024, depth: 3, blocksMailbox: true, expectedAccepted: 0),
    ]

    for value in cases {
      let clock = SDKTestClock(identifiers: (0..<value.depth).map { _ in UUID() })
      let nearWire = NearWire(dependencies: clock.dependencies)
      for index in 0..<value.depth {
        _ = try await nearWire.send(type: "test.matrix.\(value.name)", content: index)
      }
      let transportLimits = try SecureTransportLimits(
        maximumPendingSendCount: value.blocksMailbox ? 3 : 256,
        maximumPendingSendBytes: 4 * 1_024 * 1_024,
        maximumSingleSendBytes: WireFrameLimits.default.maximumEncodedFrameBytes(for: .event)
      )
      let channel = SecureByteChannel(
        driver: SDKSecureConnectionDriver(),
        limits: transportLimits
      ) { _ in }
      try await channel.start()
      if value.blocksMailbox { try channel.admitSend(Data([1])) }

      let result = await nearWire.drainActiveWire(
        for: sdkTestSessionRoute,
        codec: try makeSDKTestSessionCodec(),
        sequenceCounter: try makeSDKTestSequenceCounter(),
        maximumServiceUnits: value.serviceUnits,
        maximumAcceptedEventCount: value.allowance,
        maximumAccountedBytes: value.accountedBytes,
        channel: channel,
        reservingPendingSendCount: value.blocksMailbox ? 2 : 0,
        reservingPendingSendBytes: 0,
        gate: SDKActiveOperationGate()
      )
      let diagnostics = try await nearWire.bufferDiagnostics()
      XCTAssertNil(result.failure, value.name)
      XCTAssertEqual(result.acceptedEventIDs.count, value.expectedAccepted, value.name)
      XCTAssertEqual(result.plannedSequenceCounter.nextRawValue, UInt64(value.expectedAccepted))
      XCTAssertEqual(diagnostics.eventCount, value.depth - value.expectedAccepted, value.name)
      await channel.cancel()
    }
  }

  func testActiveWireDrainBurstAllowanceCartesianLimiterMatrix() async throws {
    enum Relation: String, CaseIterable {
      case smaller
      case equal
      case larger

      var units: Int {
        switch self {
        case .smaller: return 2
        case .equal: return 4
        case .larger: return 6
        }
      }
    }

    for serviceRelation in Relation.allCases {
      for byteRelation in Relation.allCases {
        for depthRelation in Relation.allCases {
          for mailboxRelation in Relation.allCases {
            let name = [
              serviceRelation.rawValue,
              byteRelation.rawValue,
              depthRelation.rawValue,
              mailboxRelation.rawValue,
            ].joined(separator: "-")
            let depth = depthRelation.units
            let clock = SDKTestClock(identifiers: (0..<depth).map { _ in UUID() })
            let nearWire = NearWire(dependencies: clock.dependencies)
            for index in 0..<depth {
              _ = try await nearWire.send(type: "test.cartesian", content: index)
            }
            let candidate = SDKLockedCapture<PendingEvent<SDKQueuedEvent>>()
            _ = try await nearWire.drainOutbound(
              for: sdkTestSessionRoute,
              maximumCount: 1,
              maximumBytes: 1_024 * 1_024
            ) { event in
              candidate.append(event)
              return .notAttempted
            }
            let accountedUnit = try XCTUnwrap(candidate.snapshot.first).accountedByteCount
            let transportLimits = try SecureTransportLimits(
              maximumPendingSendCount: mailboxRelation.units,
              maximumPendingSendBytes: 4 * 1_024 * 1_024,
              maximumSingleSendBytes: WireFrameLimits.default.maximumEncodedFrameBytes(
                for: .event
              )
            )
            let channel = SecureByteChannel(
              driver: SDKSecureConnectionDriver(),
              limits: transportLimits
            ) { _ in }
            try await channel.start()

            let result = await nearWire.drainActiveWire(
              for: sdkTestSessionRoute,
              codec: try makeSDKTestSessionCodec(),
              sequenceCounter: try makeSDKTestSequenceCounter(),
              maximumServiceUnits: serviceRelation.units,
              maximumAcceptedEventCount: 4,
              maximumAccountedBytes: byteRelation.units * accountedUnit,
              channel: channel,
              reservingPendingSendCount: 0,
              reservingPendingSendBytes: 0,
              gate: SDKActiveOperationGate()
            )
            let expected = min(
              4,
              serviceRelation.units,
              byteRelation.units,
              depthRelation.units,
              mailboxRelation.units
            )
            XCTAssertNil(result.failure, name)
            XCTAssertEqual(result.acceptedEventIDs.count, expected, name)
            let rejectedMailboxCandidate =
              mailboxRelation.units == expected
              && expected < 4
              && expected < serviceRelation.units
              && expected < byteRelation.units
              && expected < depthRelation.units
            XCTAssertEqual(
              result.serviceUnits,
              expected + (rejectedMailboxCandidate ? 1 : 0),
              name
            )
            XCTAssertEqual(result.acceptedAccountedByteCount, expected * accountedUnit, name)
            XCTAssertEqual(result.plannedSequenceCounter.nextRawValue, UInt64(expected), name)
            let diagnostics = try await nearWire.bufferDiagnostics()
            XCTAssertEqual(diagnostics.eventCount, depth - expected, name)
            await channel.cancel()
          }
        }
      }
    }
  }

  func testActiveWireDrainDropsStaleReplyBeforeAcceptingNormalEvent() async throws {
    let clock = SDKTestClock(
      identifiers: [
        UUID(uuidString: "00000000-0000-0000-0000-000000000231")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000232")!,
      ]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)
    var incomingEvents = nearWire.events.makeAsyncIterator()
    let incoming = try makeIncomingEnvelope()
    let didPublish = await nearWire.publishIncoming(incoming)
    XCTAssertTrue(didPublish)
    let nextIncoming = try await incomingEvents.next()
    let published = try XCTUnwrap(nextIncoming)
    let reply = try await nearWire.reply(to: published, type: "test.reply", content: 1)
    let normal = try await nearWire.send(type: "test.normal", content: 2)
    let route = SDKSessionRoute(
      sessionEpoch: sdkTestSessionRoute.sessionEpoch,
      viewerID: "viewer-two",
      appID: sdkTestSessionRoute.appID
    )
    let channel = SecureByteChannel(driver: SDKSecureConnectionDriver()) { _ in }
    try await channel.start()
    let operationEntries = SDKLockedCapture<String>()

    let result = await nearWire.drainActiveWire(
      for: route,
      codec: try makeSDKTestSessionCodec(),
      sequenceCounter: try makeSDKTestSequenceCounter(route: route),
      maximumServiceUnits: 2,
      maximumAcceptedEventCount: 1,
      maximumAccountedBytes: 256 * 1_024,
      channel: channel,
      reservingPendingSendCount: 0,
      reservingPendingSendBytes: 0,
      gate: SDKActiveOperationGate(),
      operationHooks: SDKActiveLiveOperationHooks(
        beforeRouteDropClaim: { operationEntries.append("route") },
        beforeCandidateClaim: { operationEntries.append("candidate") }
      )
    )
    XCTAssertEqual(
      result.routingDroppedEventIDs.map(\.rawValue), [reply.eventID.uuidString.lowercased()])
    XCTAssertEqual(
      result.acceptedEventIDs.map(\.rawValue), [normal.eventID.uuidString.lowercased()])
    XCTAssertEqual(result.plannedSequenceCounter.nextRawValue, 1)
    XCTAssertEqual(operationEntries.snapshot, ["route", "candidate"])
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 0)
    XCTAssertEqual(diagnostics.statistics.routingDropped, 1)
    XCTAssertEqual(diagnostics.statistics.transportAccepted, 1)
    await channel.cancel()
  }

  func testActiveWireDrainExpiresAfterActorEntryWithoutEncodingOrSequence() async throws {
    let clock = SDKTestClock(
      identifiers: [UUID(uuidString: "00000000-0000-0000-0000-000000000241")!]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)
    let sent = try await nearWire.send(
      type: "test.expired",
      content: 1,
      options: NearWireEventOptions(ttl: .milliseconds(1))
    )
    clock.advanceMonotonic(by: 1_000_000)
    let channel = SecureByteChannel(driver: SDKSecureConnectionDriver()) { _ in }
    try await channel.start()

    let result = await nearWire.drainActiveWire(
      for: sdkTestSessionRoute,
      codec: try makeSDKTestSessionCodec(),
      sequenceCounter: try makeSDKTestSequenceCounter(),
      maximumServiceUnits: 1,
      maximumAcceptedEventCount: 1,
      maximumAccountedBytes: 256 * 1_024,
      channel: channel,
      reservingPendingSendCount: 0,
      reservingPendingSendBytes: 0,
      gate: SDKActiveOperationGate()
    )

    XCTAssertEqual(result.expiredEventIDs.map(\.rawValue), [sent.eventID.uuidString.lowercased()])
    XCTAssertEqual(result.acceptedEncodedByteCount, 0)
    XCTAssertEqual(result.plannedSequenceCounter.nextRawValue, 0)
    let channelLimits = channel.limits
    XCTAssertEqual(
      channel.sendCapacitySnapshot.availablePendingSendCount,
      channelLimits.maximumPendingSendCount
    )
    await channel.cancel()
  }

  func testActiveWireDrainEncodingFailureRetainsCandidateWithoutTransportTelemetry() async throws {
    let clock = SDKTestClock(
      identifiers: [UUID(uuidString: "00000000-0000-0000-0000-000000000251")!]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)
    let sent = try await nearWire.send(type: "test.too-large-for-wire", content: ["value": 1])
    let channel = SecureByteChannel(driver: SDKSecureConnectionDriver()) { _ in }
    try await channel.start()

    let result = await nearWire.drainActiveWire(
      for: sdkTestSessionRoute,
      codec: try makeSDKTestSessionCodec(maximumEventBytes: 1),
      sequenceCounter: try makeSDKTestSequenceCounter(),
      maximumServiceUnits: 1,
      maximumAcceptedEventCount: 1,
      maximumAccountedBytes: 256 * 1_024,
      channel: channel,
      reservingPendingSendCount: 0,
      reservingPendingSendBytes: 0,
      gate: SDKActiveOperationGate()
    )

    XCTAssertEqual(result.failure, .encodingFailed)
    XCTAssertEqual(
      result.notAttemptedEventIDs.map(\.rawValue), [sent.eventID.uuidString.lowercased()])
    XCTAssertEqual(result.plannedSequenceCounter.nextRawValue, 0)
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 1)
    XCTAssertEqual(diagnostics.statistics.transportAccepted, 0)
    XCTAssertEqual(diagnostics.statistics.transportAdmissionRejected, 0)
    await channel.cancel()
  }

  func testActiveWireDrainRejectsMismatchedSequenceDomainBeforeQueueMutation() async throws {
    let clock = SDKTestClock(
      identifiers: [UUID(uuidString: "00000000-0000-0000-0000-000000000252")!]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)
    _ = try await nearWire.send(type: "test.sequence-domain", content: 1)
    let channel = SecureByteChannel(driver: SDKSecureConnectionDriver()) { _ in }
    try await channel.start()
    let wrongCounter = WireSequenceCounter(
      sessionEpoch: try SessionEpoch(
        rawValue: "30000000-0000-0000-0000-000000000001"
      ),
      direction: .appToViewer
    )

    let result = await nearWire.drainActiveWire(
      for: sdkTestSessionRoute,
      codec: try makeSDKTestSessionCodec(),
      sequenceCounter: wrongCounter,
      maximumServiceUnits: 1,
      maximumAcceptedEventCount: 1,
      maximumAccountedBytes: 256 * 1_024,
      channel: channel,
      reservingPendingSendCount: 0,
      reservingPendingSendBytes: 0,
      gate: SDKActiveOperationGate()
    )

    XCTAssertEqual(result.failure, .sequenceFailed)
    XCTAssertEqual(result.plannedSequenceCounter, wrongCounter)
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 1)
    XCTAssertEqual(diagnostics.statistics.transportAccepted, 0)
    await channel.cancel()
  }

  func testActiveWireDrainGateHasExactTerminalFirstAndCandidateFirstOutcomes() async throws {
    let terminalClock = SDKTestClock(
      identifiers: [UUID(uuidString: "00000000-0000-0000-0000-000000000261")!]
    )
    let terminalNearWire = NearWire(dependencies: terminalClock.dependencies)
    _ = try await terminalNearWire.send(type: "test.terminal-first", content: 1)
    let terminalChannel = SecureByteChannel(driver: SDKSecureConnectionDriver()) { _ in }
    try await terminalChannel.start()
    let beforeClaim = SDKSynchronousBarrier()
    let terminalGate = SDKActiveOperationGate()
    let terminalTask = Task {
      await terminalNearWire.drainActiveWire(
        for: sdkTestSessionRoute,
        codec: try makeSDKTestSessionCodec(),
        sequenceCounter: try makeSDKTestSequenceCounter(),
        maximumServiceUnits: 1,
        maximumAcceptedEventCount: 1,
        maximumAccountedBytes: 256 * 1_024,
        channel: terminalChannel,
        reservingPendingSendCount: 0,
        reservingPendingSendBytes: 0,
        gate: terminalGate,
        operationHooks: SDKActiveLiveOperationHooks(
          beforeCandidateClaim: { beforeClaim.block() }
        )
      )
    }
    await beforeClaim.waitUntilReached()
    terminalGate.close()
    beforeClaim.release()
    let terminalResult = try await terminalTask.value
    XCTAssertTrue(terminalResult.stoppedByTerminal)
    XCTAssertEqual(terminalResult.acceptedEventIDs, [])
    let terminalDiagnostics = try await terminalNearWire.bufferDiagnostics()
    XCTAssertEqual(terminalDiagnostics.eventCount, 1)

    let acceptedClock = SDKTestClock(
      identifiers: [UUID(uuidString: "00000000-0000-0000-0000-000000000262")!]
    )
    let acceptedNearWire = NearWire(dependencies: acceptedClock.dependencies)
    _ = try await acceptedNearWire.send(type: "test.candidate-first", content: 1)
    let acceptedChannel = SecureByteChannel(driver: SDKSecureConnectionDriver()) { _ in }
    try await acceptedChannel.start()
    let afterOperation = SDKSynchronousBarrier()
    let acceptedGate = SDKActiveOperationGate()
    let acceptedTask = Task {
      await acceptedNearWire.drainActiveWire(
        for: sdkTestSessionRoute,
        codec: try makeSDKTestSessionCodec(),
        sequenceCounter: try makeSDKTestSequenceCounter(),
        maximumServiceUnits: 1,
        maximumAcceptedEventCount: 1,
        maximumAccountedBytes: 256 * 1_024,
        channel: acceptedChannel,
        reservingPendingSendCount: 0,
        reservingPendingSendBytes: 0,
        gate: acceptedGate,
        operationHooks: SDKActiveLiveOperationHooks(
          afterCandidateClaim: { afterOperation.block() }
        )
      )
    }
    await afterOperation.waitUntilReached()
    let closeTask = Task.detached { acceptedGate.close() }
    afterOperation.release()
    await closeTask.value
    let acceptedResult = try await acceptedTask.value
    XCTAssertEqual(acceptedResult.acceptedEventIDs.count, 1)
    XCTAssertEqual(acceptedResult.plannedSequenceCounter.nextRawValue, 1)
    let acceptedDiagnostics = try await acceptedNearWire.bufferDiagnostics()
    XCTAssertEqual(acceptedDiagnostics.eventCount, 0)
    await terminalChannel.cancel()
    await acceptedChannel.cancel()
  }

  func testNormalEventsRemainDistinctAndResultsAreLocal() async throws {
    let clock = SDKTestClock(
      identifiers: [
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      ]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)

    let first = try await nearWire.send(type: "ui.route.changed", content: ["route": "/a"])
    let second = try await nearWire.send(type: "ui.route.changed", content: ["route": "/b"])
    let diagnostics = try await nearWire.bufferDiagnostics()

    XCTAssertTrue(first.isBuffered)
    XCTAssertTrue(second.isBuffered)
    XCTAssertNil(first.coalescedEventID)
    XCTAssertNil(second.coalescedEventID)
    XCTAssertEqual(diagnostics.eventCount, 2)
    XCTAssertEqual(diagnostics.statistics.submitted, 2)
  }

  func testKeepLatestUsesExplicitKeyAndReportsReplacement() async throws {
    let clock = SDKTestClock(
      identifiers: [
        UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
      ]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)

    let first = try await nearWire.send(
      type: "ui.route.changed",
      content: ["route": "/a"],
      policy: .keepLatest(key: "current-route")
    )
    let second = try await nearWire.send(
      type: "ui.route.changed",
      content: ["route": "/b"],
      policy: .keepLatest(key: "current-route")
    )

    XCTAssertEqual(second.coalescedEventID, first.eventID)
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 1)
    XCTAssertEqual(diagnostics.statistics.coalesced, 1)
  }

  func testInvalidKeepLatestKeyAndTTLFailWithoutMutation() async throws {
    let nearWire = NearWire()
    do {
      _ = try await nearWire.send(
        type: "test.value",
        content: 1,
        policy: .keepLatest(key: "")
      )
      XCTFail("Expected invalid key failure.")
    } catch {
      assertNearWireError(error, code: .invalidEventOptions)
    }
    do {
      _ = try await nearWire.send(
        type: "test.value",
        content: 1,
        options: NearWireEventOptions(ttl: .milliseconds(0))
      )
      XCTFail("Expected invalid TTL failure.")
    } catch {
      assertNearWireError(error, code: .invalidEventOptions)
    }
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 0)
  }

  func testTTLUsesMonotonicClockInsteadOfWallClock() async throws {
    let clock = SDKTestClock()
    let nearWire = NearWire(dependencies: clock.dependencies)
    let result = try await nearWire.send(
      type: "test.expiring",
      content: 1,
      options: NearWireEventOptions(ttl: .seconds(1))
    )

    clock.setWall(Date(timeIntervalSince1970: 9_000_000_000))
    let beforeExpiry = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(beforeExpiry.eventCount, 1)
    clock.advanceMonotonic(by: 1_000_000_000)
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 0)
    XCTAssertEqual(diagnostics.expiredEventIDs, [result.eventID])
    XCTAssertEqual(diagnostics.statistics.expired, 1)
  }

  func testPriorityOverflowCanDropIncomingLowPriorityEvent() async throws {
    let buffer = try NearWireBufferConfiguration(
      maximumEventCount: 1,
      maximumBytes: 64 * 1_024,
      maximumEventBytes: 32 * 1_024
    )
    let configuration = try NearWireConfiguration(buffer: buffer)
    let clock = SDKTestClock(
      identifiers: [
        UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
      ]
    )
    let nearWire = NearWire(configuration: configuration, dependencies: clock.dependencies)

    let critical = try await nearWire.send(
      type: "test.critical",
      content: 1,
      options: NearWireEventOptions(priority: .critical)
    )
    let low = try await nearWire.send(
      type: "test.low",
      content: 2,
      options: NearWireEventOptions(priority: .low)
    )

    XCTAssertTrue(critical.isBuffered)
    XCTAssertFalse(low.isBuffered)
    XCTAssertEqual(low.overflowDroppedEventIDs, [low.eventID])
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 1)
  }

  func testOversizedEventFailsAtomically() async throws {
    let buffer = try NearWireBufferConfiguration(
      maximumEventCount: 10,
      maximumBytes: 1_024,
      maximumEventBytes: 256
    )
    let nearWire = NearWire(configuration: try NearWireConfiguration(buffer: buffer))

    do {
      _ = try await nearWire.send(
        type: "test.large",
        content: String(repeating: "x", count: 512)
      )
      XCTFail("Expected event-too-large failure.")
    } catch {
      assertNearWireError(error, code: .eventTooLarge)
    }
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 0)
  }

  func testInstancesAndClearingAreIsolated() async throws {
    let first = NearWire()
    let second = NearWire()
    _ = try await first.send(type: "test.first", content: 1)
    _ = try await second.send(type: "test.second", content: 2)

    let cleared = await first.clearBufferedEvents()
    let firstDiagnostics = try await first.bufferDiagnostics()
    let secondDiagnostics = try await second.bufferDiagnostics()
    XCTAssertEqual(cleared.removedEventIDs.count, 1)
    XCTAssertEqual(firstDiagnostics.eventCount, 0)
    XCTAssertEqual(secondDiagnostics.eventCount, 1)
  }

  func testRejectedAdmissionRemainsInPlaceForKeepLatest() async throws {
    let clock = SDKTestClock(
      identifiers: [
        UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000032")!,
      ]
    )
    let nearWire = NearWire(dependencies: clock.dependencies)
    _ = try await nearWire.send(
      type: "test.progress",
      content: 1,
      policy: .keepLatest(key: "progress")
    )
    let rejected = try await nearWire.drainOutbound(
      for: sdkTestSessionRoute,
      maximumCount: 1,
      maximumBytes: 1_024 * 1_024
    ) { _ in .transportRejected }
    let second = try await nearWire.send(
      type: "test.progress",
      content: 2,
      policy: .keepLatest(key: "progress")
    )

    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(rejected.rejectedEventIDs.count, 1)
    XCTAssertEqual(
      second.coalescedEventID,
      rejected.rejectedEventIDs.first.flatMap { UUID(uuidString: $0.rawValue) }
    )
    XCTAssertEqual(diagnostics.eventCount, 1)
  }

  func testAdmissionStopsAfterRejectionAndClearRemovesBufferedEvents() async throws {
    let nearWire = NearWire()
    _ = try await nearWire.send(type: "test.first", content: 1)
    _ = try await nearWire.send(type: "test.second", content: 2)
    let attempts = SDKLockedCapture<EventID>()

    let drain = try await nearWire.drainOutbound(
      for: sdkTestSessionRoute,
      maximumCount: 2,
      maximumBytes: 1_024 * 1_024
    ) { event in
      attempts.append(event.id)
      return .transportRejected
    }
    let diagnostics = try await nearWire.bufferDiagnostics()
    let cleared = await nearWire.clearBufferedEvents()
    let afterClear = try await nearWire.bufferDiagnostics()

    XCTAssertEqual(attempts.snapshot.count, 1)
    XCTAssertEqual(drain.rejectedEventIDs.count, 1)
    XCTAssertEqual(diagnostics.eventCount, 2)
    XCTAssertEqual(diagnostics.statistics.transportAdmissionRejected, 1)
    XCTAssertEqual(diagnostics.statistics.transportAccepted, 0)
    XCTAssertEqual(cleared.removedEventIDs.count, 2)
    XCTAssertEqual(afterClear.eventCount, 0)
  }

  func testDuplicateIdentifierSupplierFailsWithAccurateError() async throws {
    let duplicate = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
    let clock = SDKTestClock(identifiers: Array(repeating: duplicate, count: 9))
    let nearWire = NearWire(dependencies: clock.dependencies)
    _ = try await nearWire.send(type: "test.first", content: 1)

    do {
      _ = try await nearWire.send(type: "test.second", content: 2)
      XCTFail("Expected identifier generation failure.")
    } catch {
      assertNearWireError(error, code: .identifierGenerationFailed)
    }
    let diagnostics = try await nearWire.bufferDiagnostics()
    XCTAssertEqual(diagnostics.eventCount, 1)
  }
}
