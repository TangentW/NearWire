import Foundation
@_spi(NearWireInternal) import NearWireCore
import Network
import ObjectiveC
import XCTest

@testable import NearWire
@_spi(NearWireInternal) @testable import NearWireTransport

final class SDKPublicConnectionOrchestrationTests: XCTestCase {
  func testTaskAndTerminalUseFirstMutationBeforeTransfer() {
    let taskFirst = SDKSessionTransitionGate()
    XCTAssertTrue(taskFirst.requestCancellation(.task))
    XCTAssertEqual(taskFirst.markTerminal(.remoteClosed), .attempting)
    assertFailure(taskFirst.claimActiveTransfer(), equals: .cancelled)

    let terminalFirst = SDKSessionTransitionGate()
    XCTAssertEqual(terminalFirst.markTerminal(.remoteClosed), .attempting)
    XCTAssertTrue(terminalFirst.requestCancellation(.task))
    assertFailure(terminalFirst.claimActiveTransfer(), equals: .terminal(.remoteClosed))
  }

  func testTransitionGateDeliversCancellationOncePerTargetGeneration() {
    let gate = SDKSessionTransitionGate()
    let deliveries = SDKLockedCapture<String>()
    let first = SDKSessionTransitionTarget()
    XCTAssertTrue(
      gate.installTarget(token: first) { deliveries.append("first") }
    )
    XCTAssertTrue(gate.requestCancellation(.task))
    XCTAssertTrue(gate.requestCancellation(.task))
    XCTAssertTrue(gate.requestCancellation(.shutdown))
    XCTAssertEqual(deliveries.snapshot, ["first"])

    let late = SDKSessionTransitionTarget()
    XCTAssertFalse(
      gate.installTarget(token: late) { deliveries.append("late") }
    )
    XCTAssertEqual(deliveries.snapshot, ["first", "late"])
    XCTAssertTrue(gate.requestCancellation(.shutdown))
    XCTAssertEqual(deliveries.snapshot, ["first", "late"])
  }

  func testTransitionGateReportsCancellationDeliveryAtomically() {
    let gate = SDKSessionTransitionGate()
    let target = SDKSessionTransitionTarget()
    let cancellations = SDKLockedCapture<Void>()

    XCTAssertTrue(
      gate.installTarget(token: target) {
        cancellations.append(())
      }
    )

    XCTAssertEqual(
      gate.requestCancellationResult(.task),
      SDKSessionTransitionGate.CancellationResult(
        accepted: true,
        deliveredToTarget: true
      )
    )
    XCTAssertEqual(cancellations.snapshot.count, 1)
    XCTAssertEqual(
      gate.requestCancellationResult(.task),
      SDKSessionTransitionGate.CancellationResult(
        accepted: true,
        deliveredToTarget: true
      )
    )
    XCTAssertEqual(cancellations.snapshot.count, 1)
  }

  func testCancellationResultLinearizesBeforeLateTargetInstallation() {
    let gate = SDKSessionTransitionGate()
    let result = gate.requestCancellationResult(.task)
    XCTAssertEqual(
      result,
      SDKSessionTransitionGate.CancellationResult(
        accepted: true,
        deliveredToTarget: false
      )
    )

    let lateCancellations = SDKLockedCapture<Void>()
    XCTAssertFalse(
      gate.installTarget(token: SDKSessionTransitionTarget()) {
        lateCancellations.append(())
      }
    )
    XCTAssertEqual(lateCancellations.snapshot.count, 1)
    XCTAssertEqual(
      gate.requestCancellationResult(.task),
      SDKSessionTransitionGate.CancellationResult(
        accepted: true,
        deliveredToTarget: true
      )
    )
    XCTAssertEqual(lateCancellations.snapshot.count, 1)
  }

  func testPairingTransferClearsOwnershipAfterOneSynchronousTake() throws {
    let transfer = try SDKPairingCodeTransfer(rawValue: "ABC234")
    XCTAssertFalse(transfer.isEmpty)
    XCTAssertEqual(transfer.take()?.canonicalValue, "ABC234")
    XCTAssertTrue(transfer.isEmpty)
    XCTAssertNil(transfer.take())
  }

  func testTransitionGateReplacesOnlyExactTargetGeneration() {
    let gate = SDKSessionTransitionGate()
    let deliveries = SDKLockedCapture<String>()
    let first = SDKSessionTransitionTarget()
    let rejected = SDKSessionTransitionTarget()
    let second = SDKSessionTransitionTarget()
    let stale = SDKSessionTransitionTarget()
    XCTAssertTrue(gate.installTarget(token: first) { deliveries.append("first") })
    XCTAssertFalse(
      gate.replaceTarget(
        expectedToken: stale,
        newToken: rejected,
        cancel: { deliveries.append("rejected") }
      )
    )
    XCTAssertTrue(
      gate.replaceTarget(
        expectedToken: first,
        newToken: second,
        cancel: { deliveries.append("second") }
      )
    )
    XCTAssertTrue(gate.requestCancellation(.shutdown))
    XCTAssertEqual(deliveries.snapshot, ["rejected", "second"])
  }

  func testActiveTransferCriticalSectionCanWinTerminalWithoutCheckCommitGap() async {
    let barrier = SDKSynchronousBarrier()
    let gate = SDKSessionTransitionGate(
      hooks: SDKSessionTransitionGateHooks(
        beforeTerminalMutation: {},
        beforeActiveTransferMutation: { barrier.block() },
        beforeConnectedCommitMutation: {}
      )
    )
    let transfer = Task.detached { gate.claimActiveTransfer() }
    await barrier.waitUntilReached()
    let terminal = Task.detached { gate.markTerminal(.remoteClosed) }
    barrier.release()

    let transferResult = await transfer.value
    let terminalResult = await terminal.value
    assertSuccess(transferResult)
    XCTAssertEqual(terminalResult, .transferred)
    assertFailure(gate.claimConnectedCommit(), equals: .terminal(.remoteClosed))
  }

  func testTerminalCriticalSectionCanWinActiveTransferWithoutCheckCommitGap() async {
    let barrier = SDKSynchronousBarrier()
    let gate = SDKSessionTransitionGate(
      hooks: SDKSessionTransitionGateHooks(
        beforeTerminalMutation: { barrier.block() },
        beforeActiveTransferMutation: {},
        beforeConnectedCommitMutation: {}
      )
    )
    let terminal = Task.detached { gate.markTerminal(.remoteClosed) }
    await barrier.waitUntilReached()
    let transfer = Task.detached { gate.claimActiveTransfer() }
    barrier.release()

    let terminalResult = await terminal.value
    let transferResult = await transfer.value
    XCTAssertEqual(terminalResult, .attempting)
    assertFailure(transferResult, equals: .terminal(.remoteClosed))
  }

  func testConnectedCommitCriticalSectionCanWinTerminal() async {
    let barrier = SDKSynchronousBarrier()
    let gate = SDKSessionTransitionGate(
      hooks: SDKSessionTransitionGateHooks(
        beforeTerminalMutation: {},
        beforeActiveTransferMutation: {},
        beforeConnectedCommitMutation: { barrier.block() }
      )
    )
    assertSuccess(gate.claimActiveTransfer())
    let connected = Task.detached { gate.claimConnectedCommit() }
    await barrier.waitUntilReached()
    let terminal = Task.detached { gate.markTerminal(.remoteClosed) }
    barrier.release()

    let connectedResult = await connected.value
    let terminalResult = await terminal.value
    assertSuccess(connectedResult)
    XCTAssertEqual(terminalResult, .connected)
  }

  func testTerminalCriticalSectionCanWinConnectedCommit() async {
    let barrier = SDKSynchronousBarrier()
    let gate = SDKSessionTransitionGate(
      hooks: SDKSessionTransitionGateHooks(
        beforeTerminalMutation: { barrier.block() },
        beforeActiveTransferMutation: {},
        beforeConnectedCommitMutation: {}
      )
    )
    assertSuccess(gate.claimActiveTransfer())
    let terminal = Task.detached { gate.markTerminal(.remoteClosed) }
    await barrier.waitUntilReached()
    let connected = Task.detached { gate.claimConnectedCommit() }
    barrier.release()

    let terminalResult = await terminal.value
    let connectedResult = await connected.value
    XCTAssertEqual(terminalResult, .transferred)
    assertFailure(connectedResult, equals: .terminal(.remoteClosed))
  }

  func testTerminalWaitFailureVaultsLeaseWithoutReleaseOrDelivery() async {
    let probe = SDKPublicConnectionProbe()
    let delivery = SDKLockedCapture<SDKSessionAdmissionError.Code>()
    let baseline = SDKPublicFailClosedLeaseVault.shared.retainedLeaseCount
    var coordinator: SDKPublicTerminalCoordinator? = SDKPublicTerminalCoordinator(
      lease: SDKPublicConnectionLease { probe.recordRelease() },
      hooks: .none,
      wait: { throw SDKSessionAdmissionError(.terminationWaitCancelled) },
      delivery: { delivery.append($0) }
    )

    await sdkWaitUntil {
      SDKPublicFailClosedLeaseVault.shared.retainedLeaseCount == baseline + 1
    }
    coordinator = nil
    XCTAssertNil(coordinator)
    XCTAssertEqual(probe.snapshot.releases, 0)
    XCTAssertTrue(delivery.snapshot.isEmpty)
  }

  func testTerminalWaitFailureKeepsRealProcessLeaseContendedInSubprocess() async throws {
    #if os(macOS)
      let marker = "NEARWIRE_REAL_LEASE_WAIT_FAILURE_CHILD"
      if ProcessInfo.processInfo.environment[marker] == "1" {
        let baseline = SDKPublicFailClosedLeaseVault.shared.retainedLeaseCount
        var coordinator: SDKPublicTerminalCoordinator? = SDKPublicTerminalCoordinator(
          lease: SDKPublicConnectionLease(
            handle: try ProcessConnectionLeaseRegistry.claim()
          ),
          hooks: .none,
          wait: { throw SDKSessionAdmissionError(.terminationWaitCancelled) },
          delivery: { _ in
            XCTFail("A failed terminal wait must not deliver a terminal callback.")
          }
        )
        await sdkWaitUntil {
          SDKPublicFailClosedLeaseVault.shared.retainedLeaseCount == baseline + 1
        }
        coordinator = nil
        XCTAssertNil(coordinator)
        do {
          _ = try ProcessConnectionLeaseRegistry.claim()
          XCTFail("The fail-closed real process lease unexpectedly became claimable.")
        } catch let error as ProcessConnectionLeaseError {
          XCTAssertEqual(error.code, .anotherConnectionIsActive)
        }
        return
      }

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      process.arguments = [
        "xctest",
        "-XCTest",
        "NearWireTests.SDKPublicConnectionOrchestrationTests/"
          + "testTerminalWaitFailureKeepsRealProcessLeaseContendedInSubprocess",
        Bundle(for: Self.self).bundleURL.path,
      ]
      var environment = ProcessInfo.processInfo.environment
      environment[marker] = "1"
      process.environment = environment
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      try process.run()
      process.waitUntilExit()
      let transcript = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      )
      XCTAssertEqual(process.terminationStatus, 0, transcript)
      XCTAssertTrue(transcript.contains("Executed 1 test, with 0 failures"), transcript)
    #else
      throw XCTSkip("The isolated real process-lease vault proof runs on macOS.")
    #endif
  }

  func testPreflightRejectsInvalidCodeBeforeLeaseOrIdentity() async {
    let probe = SDKPublicConnectionProbe()
    let owner = makeOwner(probe: probe) { throw SDKInstallationIdentityError.unavailable }

    await assertConnectError(.invalidPairingCode) {
      try await owner.connect(code: "bad")
    }
    XCTAssertEqual(probe.snapshot, SDKPublicConnectionProbe.Snapshot())
    let state = await owner.currentState
    XCTAssertEqual(state, .idle)
  }

  func testTaskCancellationKeepsAttemptAttachedUntilIdentityCompletesAndReleases() async {
    let probe = SDKPublicConnectionProbe()
    let identity = SDKPublicIdentityBarrier()
    let owner = makeOwner(probe: probe) { try await identity.run() }
    let first = Task { try await owner.connect(code: "ABC234") }
    await identity.waitUntilReached()
    first.cancel()

    await assertConnectError(.connectionInProgress) {
      try await owner.connect(code: "bad")
    }
    XCTAssertEqual(probe.snapshot.releases, 0)
    identity.resume(returning: "00000000-0000-4000-8000-000000000001")
    await assertTaskError(.connectionCancelled, task: first)
    XCTAssertEqual(probe.snapshot.releases, 1)
    let state = await owner.currentState
    XCTAssertEqual(state, .idle)
  }

  func testCancellationAfterLeaseClaimSkipsIdentityAndReleasesExactlyOnce() async {
    let probe = SDKPublicConnectionProbe()
    let barrier = SDKSynchronousBarrier()
    let owner = makeOwner(
      probe: probe,
      identity: { "00000000-0000-4000-8000-000000000001" },
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { point in
          if point == .afterLeaseClaim { barrier.block() }
        },
        reach: { _ in }
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    await barrier.waitUntilReached()
    connect.cancel()
    barrier.release()

    await assertTaskError(.connectionCancelled, task: connect)
    XCTAssertEqual(probe.snapshot.claims, 1)
    XCTAssertEqual(probe.snapshot.identities, 0)
    XCTAssertEqual(probe.snapshot.releases, 1)
  }

  func testCancellationWinningBlockedLeaseFailureReturnsCancellation() async {
    let probe = SDKPublicConnectionProbe()
    let barrier = SDKSynchronousBarrier()
    let owner = makeOwner(
      probe: probe,
      identity: { "00000000-0000-4000-8000-000000000001" },
      claimLease: {
        probe.recordClaim()
        barrier.block()
        throw ProcessConnectionLeaseError.anotherConnectionIsActive
      }
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    await barrier.waitUntilReached()
    connect.cancel()
    barrier.release()

    await assertTaskError(.connectionCancelled, task: connect)
    XCTAssertEqual(probe.snapshot.claims, 1)
    XCTAssertEqual(probe.snapshot.identities, 0)
    XCTAssertEqual(probe.snapshot.releases, 0)
  }

  func testShutdownDetachesImmediatelyButPendingConnectReturnsAfterRelease() async {
    let probe = SDKPublicConnectionProbe()
    let identity = SDKPublicIdentityBarrier()
    let owner = makeOwner(probe: probe) { try await identity.run() }
    let connect = Task { try await owner.connect(code: "ABC234") }
    await identity.waitUntilReached()

    await owner.shutdown()
    let immediateState = await owner.currentState
    XCTAssertEqual(immediateState, .shutdown)
    XCTAssertEqual(probe.snapshot.releases, 0)
    identity.resume(returning: "00000000-0000-4000-8000-000000000001")

    await assertTaskError(.shutdown, task: connect)
    XCTAssertEqual(probe.snapshot.releases, 1)
    let finalState = await owner.currentState
    XCTAssertEqual(finalState, .shutdown)
  }

  func testTaskCancellationDuringDiscoveryReleasesBeforeClearingAttempt() async {
    let probe = SDKPublicConnectionProbe()
    let discovery = SDKPublicControlledDiscovery()
    let driver = SDKPublicSecureDriver()
    let owner = makeAdmissionOwner(
      probe: probe,
      discovery: { discovery },
      driver: driver
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    await discovery.waitUntilRunning()
    connect.cancel()

    await assertConnectError(.connectionInProgress) {
      try await owner.connect(code: "bad")
    }
    await assertTaskError(.connectionCancelled, task: connect)
    XCTAssertEqual(probe.snapshot.releases, 1)
    XCTAssertEqual(probe.snapshot.channels, 0)
    let state = await owner.currentState
    XCTAssertEqual(state, .disconnected)
  }

  func testShutdownDuringPhaseAuthorizationPreventsChannelConstruction() async {
    let probe = SDKPublicConnectionProbe()
    let phase = SDKPublicVoidBarrier()
    let driver = SDKPublicSecureDriver()
    let owner = makeAdmissionOwner(
      probe: probe,
      discovery: { SDKPublicImmediateDiscovery(result: Self.discoveredViewer()) },
      driver: driver,
      phaseObserver: { observer in
        await phase.run()
        return await observer()
      }
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    await phase.waitUntilReached()
    await owner.shutdown()
    phase.resume()

    await assertTaskError(.shutdown, task: connect)
    XCTAssertEqual(probe.snapshot.releases, 1)
    XCTAssertEqual(probe.snapshot.channels, 0)
  }

  func testTaskCancellationDuringSecureAdmissionReleasesWithoutCoordinator() async {
    let probe = SDKPublicConnectionProbe()
    let driver = SDKPublicSecureDriver()
    let owner = makeAdmissionOwner(
      probe: probe,
      discovery: { SDKPublicImmediateDiscovery(result: Self.discoveredViewer()) },
      driver: driver
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    await driver.waitUntilStarted()
    connect.cancel()

    await assertTaskError(.connectionCancelled, task: connect)
    XCTAssertEqual(probe.snapshot.releases, 1)
    XCTAssertEqual(probe.snapshot.channels, 1)
    XCTAssertEqual(driver.cancelCount, 1)
    let state = await owner.currentState
    XCTAssertEqual(state, .disconnected)
  }

  func testSupportedConnectReachesActivePumpThenTerminalReleasesAndDisconnects() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let owner = NearWire(
      dependencies: SDKTestClock().dependencies,
      connectionDependencies: SDKPublicConnectionDependencies(
        makeTransitionGate: { SDKSessionTransitionGate() },
        claimLease: {
          probe.recordClaim()
          return SDKPublicConnectionLease { probe.recordRelease() }
        },
        loadInstallationIdentity: {
          probe.recordIdentity()
          return "00000000-0000-4000-8000-000000000001"
        },
        bundleMetadata: {
          SDKBundleMetadataInput(
            applicationIdentifier: "com.example.Host",
            shortVersion: "1.0",
            buildVersion: "1",
            displayName: "Host",
            bundleName: "Fallback"
          )
        },
        makeAdmission: { pairingCode, hello, plan, gate, phaseObserver in
          session.makeAdmission(
            pairingCode: pairingCode,
            hello: hello,
            plan: plan,
            gate: gate,
            phaseObserver: phaseObserver
          )
        },
        makePump: { attachment, owner, limits in
          SDKActiveEventPump(attachment: attachment, owner: owner, limits: limits)
        },
        hooks: .none
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }

    await session.driver.waitUntilStarted()
    session.driver.emitState(.ready)
    await session.driver.waitForReceive()
    session.driver.completeReceive(
      try WirePreHandshakeCodec(limits: session.wireLimits).encode(session.viewerHello)
    )
    await session.driver.waitForReceive()
    session.driver.completeReceive(
      try session.codec.encode(session.acknowledgement, phase: .awaitingApproval)
    )
    await session.driver.waitForReceive()
    session.driver.completeReceive(
      try session.codec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 10,
            appDownlinkEventsPerSecond: 10
          )
        ),
        phase: .negotiatingPolicy
      )
    )
    try await connect.value

    let connected = await owner.currentState
    XCTAssertEqual(connected, .connected)
    XCTAssertEqual(probe.snapshot.claims, 1)
    XCTAssertEqual(probe.snapshot.identities, 1)
    XCTAssertEqual(probe.snapshot.releases, 0)
    await assertConnectError(.alreadyConnected) {
      try await owner.connect(code: "bad")
    }

    var states = owner.states.makeAsyncIterator()
    let initialStreamState = await states.next()
    XCTAssertEqual(initialStreamState, .connected)
    session.driver.emitState(.failed)
    let terminalStreamState = await states.next()
    XCTAssertEqual(terminalStreamState, .disconnected)
    XCTAssertEqual(probe.snapshot.releases, 1)
  }

  func testDroppingFinalConnectedFacadeReferenceCancelsCoreAndReleasesLease() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    var owner: NearWire? = makeSessionOwner(probe: probe, session: session)
    let weakOwner = SDKWeakNearWire(owner)
    var connect: Task<Void, Error>? = Task { [owner] in
      try await owner!.connect(code: "ABC234")
    }
    try await driveConnection(session: session, connect: connect!)
    connect = nil
    owner = nil

    await sdkWaitUntil {
      weakOwner.value == nil && probe.snapshot.releases == 1
    }
    XCTAssertNil(weakOwner.value)
    XCTAssertEqual(probe.snapshot.releases, 1)
    XCTAssertEqual(session.driver.cancelCount, 1)
  }

  func testCancellationAtAdmissionResultCancelsReturnedOwnerAndReleases() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let barrier = SDKPublicVoidBarrier()
    let owner = makeSessionOwner(
      probe: probe,
      session: session,
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .afterAdmissionResult { await barrier.run() }
        }
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveAdmission(session: session)
    await barrier.waitUntilReached()
    connect.cancel()
    barrier.resume()

    await assertTaskError(.connectionCancelled, task: connect)
    await sdkWaitUntil {
      probe.snapshot.releases == 1 && session.driver.cancelCount == 1
    }
    XCTAssertEqual(session.driver.cancelCount, 1)
    let admissionResultState = await owner.currentState
    XCTAssertEqual(admissionResultState, .disconnected)
  }

  func testCancellationAtActivationResultCancelsHandleAndReleases() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let barrier = SDKPublicVoidBarrier()
    let owner = makeSessionOwner(
      probe: probe,
      session: session,
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .afterActivationResult { await barrier.run() }
        }
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveAdmission(session: session)
    try await sendInitialPolicy(session: session)
    await barrier.waitUntilReached()
    connect.cancel()
    barrier.resume()

    await assertTaskError(.connectionCancelled, task: connect)
    await sdkWaitUntil {
      probe.snapshot.releases == 1 && session.driver.cancelCount == 1
    }
    XCTAssertEqual(session.driver.cancelCount, 1)
    let activationResultState = await owner.currentState
    XCTAssertEqual(activationResultState, .disconnected)
  }

  func testTerminalReleaseCompletesBeforeWeakStateDelivery() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let releaseBarrier = SDKPublicVoidBarrier()
    let owner = makeSessionOwner(
      probe: probe,
      session: session,
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .beforeRelease { await releaseBarrier.run() }
        }
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)
    var states = owner.states.makeAsyncIterator()
    let initialState = await states.next()
    XCTAssertEqual(initialState, .connected)
    session.driver.emitState(.failed)
    await releaseBarrier.waitUntilReached()

    XCTAssertEqual(probe.snapshot.releases, 0)
    let stateBeforeRelease = await owner.currentState
    XCTAssertEqual(stateBeforeRelease, .connected)
    await assertConnectError(.connectionInProgress) {
      try await owner.connect(code: "bad")
    }
    XCTAssertEqual(probe.snapshot.claims, 1)
    XCTAssertEqual(probe.snapshot.identities, 1)
    releaseBarrier.resume()
    await sdkWaitUntil { probe.snapshot.releases == 1 }
    let deliveredState = await states.next()
    XCTAssertEqual(deliveredState, .disconnected)
  }

  func testPublicFacadeReleaseEnterFailureRemainsContendedOnRetry() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let monitor = NSObject()
    let runtime = SDKPublicScriptedLeaseRuntime(failedEnterOrdinals: [2])
    let reference = ProcessConnectionLeaseRuntimeReference(monitor: monitor)
    let owner = makeSessionOwner(
      probe: probe,
      session: session,
      claimLease: {
        SDKPublicConnectionLease(
          handle: try ProcessConnectionLeaseOperation.claim(
            reference: reference,
            runtime: runtime
          )
        )
      }
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)
    var states = owner.states.makeAsyncIterator()
    let connected = await states.next()
    XCTAssertEqual(connected, .connected)
    session.driver.emitState(.failed)
    let disconnected = await states.next()
    XCTAssertEqual(disconnected, .disconnected)

    await assertConnectError(.connectionIntentExists) {
      try await owner.connect(code: "ABC234")
    }
    await owner.disconnect()
    await assertConnectError(.anotherConnectionIsActive) {
      try await owner.connect(code: "ABC234")
    }
    XCTAssertEqual(probe.snapshot.identities, 1)
    XCTAssertEqual(runtime.snapshot.enters, 3)
  }

  func testPublicFacadeClaimExitFailureMapsUnavailableAndStartsNoIdentity() async {
    let probe = SDKPublicConnectionProbe()
    let monitor = NSObject()
    let runtime = SDKPublicScriptedLeaseRuntime(failedExitOrdinals: [1])
    let reference = ProcessConnectionLeaseRuntimeReference(monitor: monitor)
    let owner = makeOwner(
      probe: probe,
      identity: { "00000000-0000-4000-8000-000000000001" },
      claimLease: {
        SDKPublicConnectionLease(
          handle: try ProcessConnectionLeaseOperation.claim(
            reference: reference,
            runtime: runtime
          )
        )
      }
    )

    await assertConnectError(.connectionOwnershipUnavailable) {
      try await owner.connect(code: "ABC234")
    }
    XCTAssertEqual(probe.snapshot.identities, 0)
    XCTAssertEqual(runtime.snapshot.exits, 1)
  }

  func testPublicFacadeReleaseExitFailureDoesNotRetryRuntimeRelease() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let monitor = NSObject()
    let runtime = SDKPublicScriptedLeaseRuntime(failedExitOrdinals: [2])
    let reference = ProcessConnectionLeaseRuntimeReference(monitor: monitor)
    let owner = makeSessionOwner(
      probe: probe,
      session: session,
      claimLease: {
        SDKPublicConnectionLease(
          handle: try ProcessConnectionLeaseOperation.claim(
            reference: reference,
            runtime: runtime
          )
        )
      }
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)
    var states = owner.states.makeAsyncIterator()
    let connected = await states.next()
    XCTAssertEqual(connected, .connected)
    session.driver.emitState(.failed)
    let disconnected = await states.next()
    XCTAssertEqual(disconnected, .disconnected)

    XCTAssertEqual(runtime.snapshot.enters, 2)
    XCTAssertEqual(runtime.snapshot.exits, 2)
    XCTAssertNil(objc_getAssociatedObject(monitor, ProcessConnectionLeaseNamespace.ownerKey))
  }

  func testDisconnectWaitsForReleaseAndClearsLifecycleIntent() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let release = SDKPublicVoidBarrier()
    let owner = makeSessionOwner(
      probe: probe,
      session: session,
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .beforeRelease { await release.run() }
        }
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)

    let disconnect = Task { await owner.disconnect() }
    await release.waitUntilReached()
    let stateBeforeRelease = await owner.currentState
    XCTAssertEqual(stateBeforeRelease, .connected)
    XCTAssertEqual(probe.snapshot.releases, 0)
    release.resume()
    await disconnect.value

    let finalState = await owner.currentState
    let finalLifecycle = await owner.lifecycleSnapshot
    XCTAssertEqual(finalState, .disconnected)
    XCTAssertFalse(finalLifecycle.hasIntent)
    XCTAssertEqual(probe.snapshot.releases, 1)
    XCTAssertEqual(session.driver.cancelCount, 1)
  }

  func testSuspendAndExplicitResumeUseFreshRouteWithDisabledPolicy() async throws {
    let probe = SDKPublicConnectionProbe()
    let first = SDKPublicSessionController()
    let second = SDKPublicSessionController()
    let owner = makeSequenceOwner(
      probe: probe,
      sessions: [first, second]
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: first, connect: connect)

    await owner.suspendConnection()
    let suspended = await owner.connectionStatus
    XCTAssertEqual(suspended.state, .disconnected)
    XCTAssertTrue(suspended.isSuspended)
    let suspendedLifecycle = await owner.lifecycleSnapshot
    XCTAssertTrue(suspendedLifecycle.hasIntent)

    await owner.resumeConnection()
    await second.driver.waitUntilStarted()
    try await driveAdmission(session: second)
    try await sendInitialPolicy(session: second)
    await waitUntilState(.connected, owner: owner)

    XCTAssertEqual(probe.snapshot.claims, 2)
    XCTAssertEqual(probe.snapshot.releases, 1)
    let resumedStatus = await owner.connectionStatus
    XCTAssertFalse(resumedStatus.isSuspended)
  }

  func testEnabledRecoveryUsesConfiguredDelayAndFreshRoute() async throws {
    let probe = SDKPublicConnectionProbe()
    let first = SDKPublicSessionController()
    let second = SDKPublicSessionController()
    let sleeps = SDKLockedCapture<Duration>()
    let policy = try NearWireReconnectionPolicy(
      maximumAttempts: 2,
      initialDelay: .milliseconds(100),
      maximumDelay: .milliseconds(200)
    )
    let owner = makeSequenceOwner(
      probe: probe,
      sessions: [first, second],
      configuration: try NearWireConfiguration(reconnectionPolicy: policy),
      sleep: { sleeps.append($0) }
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: first, connect: connect)
    let initialSendCount = first.driver.sentData.count
    _ = try await owner.send(type: "lifecycle.accepted", content: ["value": 1])
    await sdkWaitUntil { first.driver.sentData.count > initialSendCount }

    first.driver.emitState(.failed)
    await second.driver.waitUntilStarted()
    try await driveAdmission(session: second)
    try await sendInitialPolicy(session: second)
    await waitUntilState(.connected, owner: owner)

    XCTAssertEqual(sleeps.snapshot, [.milliseconds(100)])
    XCTAssertEqual(probe.snapshot.claims, 2)
    XCTAssertEqual(probe.snapshot.releases, 1)
    let recoveredLifecycle = await owner.lifecycleSnapshot
    XCTAssertEqual(recoveredLifecycle.attemptsUsed, 1)
    XCTAssertEqual(second.driver.sentData.count, 2)
  }

  func testIntentWideBudgetDoesNotResetAfterBriefRecoverySuccess() async throws {
    let probe = SDKPublicConnectionProbe()
    let sessions = (0..<3).map { _ in SDKPublicSessionController() }
    let sleeps = SDKLockedCapture<Duration>()
    let policy = try NearWireReconnectionPolicy(
      maximumAttempts: 2,
      initialDelay: .milliseconds(100),
      maximumDelay: .milliseconds(200)
    )
    let owner = makeSequenceOwner(
      probe: probe,
      sessions: sessions,
      configuration: try NearWireConfiguration(reconnectionPolicy: policy),
      sleep: { sleeps.append($0) }
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: sessions[0], connect: connect)

    sessions[0].driver.emitState(.failed)
    await sessions[1].driver.waitUntilStarted()
    try await driveAdmission(session: sessions[1])
    try await sendInitialPolicy(session: sessions[1])
    await waitUntilState(.connected, owner: owner)

    sessions[1].driver.emitState(.failed)
    await sessions[2].driver.waitUntilStarted()
    try await driveAdmission(session: sessions[2])
    try await sendInitialPolicy(session: sessions[2])
    await waitUntilState(.connected, owner: owner)

    sessions[2].driver.emitState(.failed)
    await waitUntilState(.disconnected, owner: owner)
    let snapshot = await owner.lifecycleSnapshot
    XCTAssertFalse(snapshot.hasIntent)
    XCTAssertFalse(snapshot.hasRecoveryTask)
    XCTAssertEqual(probe.snapshot.claims, 3)
    XCTAssertEqual(sleeps.snapshot, [.milliseconds(100), .milliseconds(200)])
  }

  func testResumeWhileConnectedIsInert() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let owner = makeSessionOwner(probe: probe, session: session)
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)

    await owner.resumeConnection()
    let snapshot = await owner.lifecycleSnapshot
    let connectedState = await owner.currentState
    XCTAssertEqual(connectedState, .connected)
    XCTAssertEqual(snapshot.attemptsUsed, 0)
    XCTAssertFalse(snapshot.hasRecoveryTask)
    XCTAssertEqual(probe.snapshot.claims, 1)
  }

  func testRecoveryDispositionIsExhaustiveAndPhaseAware() {
    for code in SDKSessionAdmissionError.Code.allCases {
      _ = SDKLifecycleRecoveryMapping.disposition(for: code, phase: .activeTerminal)
      _ = SDKLifecycleRecoveryMapping.disposition(for: code, phase: .recoveryAttempt)
      let productionFailure = SDKLifecycleRecoveryFailure(
        code: code,
        phase: .recoveryAttempt
      )
      XCTAssertEqual(
        productionFailure.disposition,
        SDKLifecycleRecoveryMapping.disposition(for: code, phase: .recoveryAttempt)
      )
      XCTAssertEqual(
        productionFailure.publicError.code,
        SDKPublicConnectionErrorMapping.map(code).code
      )
    }
    XCTAssertEqual(
      SDKLifecycleRecoveryMapping.disposition(for: .transportFailed, phase: .activeTerminal),
      .transient
    )
    XCTAssertEqual(
      SDKLifecycleRecoveryMapping.disposition(for: .transportFailed, phase: .recoveryAttempt),
      .permanent
    )
    XCTAssertEqual(
      SDKLifecycleRecoveryMapping.disposition(for: .remoteClosed, phase: .recoveryAttempt),
      .transient
    )
    XCTAssertEqual(
      SDKLifecycleRecoveryMapping.disposition(for: .clockFailed, phase: .activeTerminal),
      .permanent
    )
  }

  func testSuspendDuringInitialIdentityClearsPendingIntent() async {
    let probe = SDKPublicConnectionProbe()
    let identity = SDKPublicIdentityBarrier()
    let owner = makeOwner(probe: probe) { try await identity.run() }
    let connect = Task { try await owner.connect(code: "ABC234") }
    await identity.waitUntilReached()

    let suspend = Task { await owner.suspendConnection() }
    await waitUntilSuspended(owner: owner)
    identity.resume(returning: "00000000-0000-4000-8000-000000000001")
    await assertTaskError(.connectionCancelled, task: connect)
    await suspend.value

    let snapshot = await owner.lifecycleSnapshot
    XCTAssertFalse(snapshot.hasIntent)
    XCTAssertTrue(snapshot.isSuspended)
    await assertConnectError(.connectionSuspended) {
      try await owner.connect(code: "bad")
    }
    await owner.resumeConnection()
    XCTAssertEqual(probe.snapshot.claims, 1)
  }

  func testCancelledDisconnectCallerStillWaitsForSharedReceipt() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let release = SDKPublicVoidBarrier()
    let completion = SDKLockedCapture<Void>()
    let owner = makeSessionOwner(
      probe: probe,
      session: session,
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .beforeRelease { await release.run() }
        }
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)

    let first = Task {
      await owner.disconnect()
      completion.append(())
    }
    let second = Task { await owner.disconnect() }
    await release.waitUntilReached()
    first.cancel()
    await Task.yield()
    XCTAssertTrue(completion.snapshot.isEmpty)
    let heldSnapshot = await owner.lifecycleSnapshot
    XCTAssertTrue(heldSnapshot.hasCleanupReceipt)

    release.resume()
    await first.value
    await second.value
    XCTAssertEqual(completion.snapshot.count, 1)
    XCTAssertEqual(probe.snapshot.releases, 1)
  }

  func testDisconnectCancelsHeldRecoveryDelayBeforeAnotherClaim() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let sleep = SDKPublicSleepBarrier()
    let policy = try NearWireReconnectionPolicy(
      maximumAttempts: 2,
      initialDelay: .milliseconds(100),
      maximumDelay: .milliseconds(200)
    )
    let owner = makeSequenceOwner(
      probe: probe,
      sessions: [session],
      configuration: try NearWireConfiguration(reconnectionPolicy: policy),
      sleep: { duration in try await sleep.run(duration) }
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)

    session.driver.emitState(.failed)
    await sleep.waitUntilReached()
    let disconnect = Task { await owner.disconnect() }
    await Task.yield()
    XCTAssertEqual(probe.snapshot.claims, 1)
    let delayedSnapshot = await owner.lifecycleSnapshot
    XCTAssertTrue(delayedSnapshot.hasRecoveryTask)

    sleep.resume()
    await disconnect.value
    let snapshot = await owner.lifecycleSnapshot
    XCTAssertFalse(snapshot.hasIntent)
    XCTAssertFalse(snapshot.hasRecoveryTask)
    XCTAssertEqual(probe.snapshot.claims, 1)
  }

  func testExplicitConnectReportsInProgressDuringRecoveryDelay() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let sleep = SDKPublicSleepBarrier()
    let policy = try NearWireReconnectionPolicy(
      maximumAttempts: 1,
      initialDelay: .milliseconds(100),
      maximumDelay: .milliseconds(100)
    )
    let owner = makeSequenceOwner(
      probe: probe,
      sessions: [session],
      configuration: try NearWireConfiguration(reconnectionPolicy: policy),
      sleep: { duration in try await sleep.run(duration) }
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)

    session.driver.emitState(.failed)
    await sleep.waitUntilReached()
    await assertConnectError(.connectionInProgress) {
      try await owner.connect(code: "bad")
    }
    XCTAssertEqual(probe.snapshot.claims, 1)
    XCTAssertEqual(probe.snapshot.identities, 1)

    let disconnect = Task { await owner.disconnect() }
    sleep.resume()
    await disconnect.value
  }

  func testExplicitConnectReportsInProgressDuringDisconnectCleanup() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let release = SDKPublicVoidBarrier()
    let owner = makeSessionOwner(
      probe: probe,
      session: session,
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .beforeRelease { await release.run() }
        }
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)

    let disconnect = Task { await owner.disconnect() }
    await release.waitUntilReached()
    await assertConnectError(.connectionInProgress) {
      try await owner.connect(code: "bad")
    }
    XCTAssertEqual(probe.snapshot.claims, 1)
    XCTAssertEqual(probe.snapshot.identities, 1)

    release.resume()
    await disconnect.value
  }

  func testResumeDuringActiveRouteCleanupHasOneAuthorizedSuccessor() async throws {
    let probe = SDKPublicConnectionProbe()
    let first = SDKPublicSessionController()
    let second = SDKPublicSessionController()
    let release = SDKPublicVoidBarrier()
    let sleep = SDKPublicSleepBarrier()
    let policy = try NearWireReconnectionPolicy(
      maximumAttempts: 1,
      initialDelay: .milliseconds(100),
      maximumDelay: .milliseconds(100)
    )
    let owner = makeSequenceOwner(
      probe: probe,
      sessions: [first, second],
      configuration: try NearWireConfiguration(reconnectionPolicy: policy),
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .beforeRelease { await release.run() }
        }
      ),
      sleep: { duration in try await sleep.run(duration) }
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: first, connect: connect)

    let suspend = Task { await owner.suspendConnection() }
    await release.waitUntilReached()
    await owner.resumeConnection()
    XCTAssertEqual(probe.snapshot.claims, 1)
    release.resume()
    await suspend.value
    await sleep.waitUntilReached()

    let heldStatus = await owner.connectionStatus
    XCTAssertEqual(heldStatus.state, .reconnecting)
    XCTAssertEqual(heldStatus.reconnectAttempt, 1)
    XCTAssertFalse(heldStatus.isSuspended)
    XCTAssertEqual(probe.snapshot.claims, 1)

    sleep.resume()
    await second.driver.waitUntilStarted()
    try await driveAdmission(session: second)
    try await sendInitialPolicy(session: second)
    await waitUntilState(.connected, owner: owner)
    XCTAssertEqual(probe.snapshot.claims, 2)
  }

  func testResumeDuringHeldRecoveryDelayInvalidatesOldCampaign() async throws {
    let probe = SDKPublicConnectionProbe()
    let first = SDKPublicSessionController()
    let second = SDKPublicSessionController()
    let staleSleep = SDKPublicSleepBarrier()
    let resumedSleep = SDKPublicSleepBarrier()
    let sleeps = SDKPublicSleepSequence([staleSleep, resumedSleep])
    let policy = try NearWireReconnectionPolicy(
      maximumAttempts: 2,
      initialDelay: .milliseconds(100),
      maximumDelay: .milliseconds(200)
    )
    let owner = makeSequenceOwner(
      probe: probe,
      sessions: [first, second],
      configuration: try NearWireConfiguration(reconnectionPolicy: policy),
      sleep: { duration in try await sleeps.run(duration) }
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: first, connect: connect)

    first.driver.emitState(.failed)
    await staleSleep.waitUntilReached()
    let suspend = Task { await owner.suspendConnection() }
    await waitUntilSuspended(owner: owner)
    await owner.resumeConnection()
    await assertConnectError(.connectionInProgress) {
      try await owner.connect(code: "bad")
    }
    XCTAssertEqual(probe.snapshot.claims, 1)

    staleSleep.resume()
    await suspend.value
    await resumedSleep.waitUntilReached()
    XCTAssertEqual(probe.snapshot.claims, 1)
    let restartedStatus = await owner.connectionStatus
    XCTAssertEqual(restartedStatus.state, .reconnecting)
    XCTAssertEqual(restartedStatus.reconnectAttempt, 1)

    resumedSleep.resume()
    await second.driver.waitUntilStarted()
    try await driveAdmission(session: second)
    try await sendInitialPolicy(session: second)
    await waitUntilState(.connected, owner: owner)
    XCTAssertEqual(probe.snapshot.claims, 2)
  }

  func testResumeDuringRecoveryAttemptPreservesIntentForOneSuccessor() async throws {
    let probe = SDKPublicConnectionProbe()
    let sessions = (0..<3).map { _ in SDKPublicSessionController() }
    let secondRelease = SDKNthPublicVoidBarrier(ordinal: 2)
    let policy = try NearWireReconnectionPolicy(
      maximumAttempts: 2,
      initialDelay: .milliseconds(100),
      maximumDelay: .milliseconds(200)
    )
    let owner = makeSequenceOwner(
      probe: probe,
      sessions: sessions,
      configuration: try NearWireConfiguration(reconnectionPolicy: policy),
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .beforeRelease { await secondRelease.reach() }
        }
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: sessions[0], connect: connect)

    sessions[0].driver.emitState(.failed)
    await sessions[1].driver.waitUntilStarted()
    XCTAssertEqual(probe.snapshot.claims, 2)
    let suspend = Task { await owner.suspendConnection() }
    await secondRelease.waitUntilReached()
    await owner.resumeConnection()
    XCTAssertEqual(probe.snapshot.claims, 2)

    secondRelease.resume()
    await suspend.value
    await sessions[2].driver.waitUntilStarted()
    try await driveAdmission(session: sessions[2])
    try await sendInitialPolicy(session: sessions[2])
    await waitUntilState(.connected, owner: owner)

    let snapshot = await owner.lifecycleSnapshot
    let recoveredStatus = await owner.connectionStatus
    XCTAssertTrue(snapshot.hasIntent)
    XCTAssertEqual(snapshot.attemptsUsed, 1)
    XCTAssertEqual(probe.snapshot.claims, 3)
    XCTAssertNil(recoveredStatus.lastError)
  }

  func testNewExplicitAttemptClearsPreviousTerminalErrorFromInitialPhases() async throws {
    let probe = SDKPublicConnectionProbe()
    let sessions = (0..<3).map { _ in SDKPublicSessionController() }
    let thirdAdmission = SDKNthPublicVoidBarrier(ordinal: 3)
    let policy = try NearWireReconnectionPolicy(
      maximumAttempts: 1,
      initialDelay: .milliseconds(100),
      maximumDelay: .milliseconds(100)
    )
    let owner = makeSequenceOwner(
      probe: probe,
      sessions: sessions,
      configuration: try NearWireConfiguration(reconnectionPolicy: policy),
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .beforeAdmissionTarget { await thirdAdmission.reach() }
        }
      )
    )
    let firstConnect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: sessions[0], connect: firstConnect)
    sessions[0].driver.emitState(.failed)
    await sessions[1].driver.waitUntilStarted()
    sessions[1].driver.emitState(.failed)
    await waitUntilState(.disconnected, owner: owner)
    let terminalStatus = await owner.connectionStatus
    XCTAssertNotNil(terminalStatus.lastError)

    let nextConnect = Task { try await owner.connect(code: "ABC234") }
    await thirdAdmission.waitUntilReached()
    let discovering = await owner.connectionStatus
    XCTAssertEqual(discovering.state, .discovering)
    XCTAssertNil(discovering.lastError)
    XCTAssertNil(discovering.reconnectAttempt)
    var lateStatuses = owner.connectionStatuses.makeAsyncIterator()
    let lateDiscovering = await lateStatuses.next()
    XCTAssertEqual(lateDiscovering, discovering)

    thirdAdmission.resume()
    await sessions[2].driver.waitUntilStarted()
    sessions[2].driver.emitState(.ready)
    await waitUntilState(.connecting, owner: owner)
    let connecting = await owner.connectionStatus
    XCTAssertNil(connecting.lastError)
    XCTAssertNil(connecting.reconnectAttempt)
    await sessions[2].driver.waitForReceive()
    sessions[2].driver.completeReceive(
      try WirePreHandshakeCodec(limits: sessions[2].wireLimits).encode(sessions[2].viewerHello)
    )
    await sessions[2].driver.waitForReceive()
    sessions[2].driver.completeReceive(
      try sessions[2].codec.encode(
        sessions[2].acknowledgement,
        phase: .awaitingApproval
      )
    )
    try await sendInitialPolicy(session: sessions[2])
    try await nextConnect.value
  }

  func testPreActiveTransportFailureStopsProductionRecoveryCampaign() async throws {
    let probe = SDKPublicConnectionProbe()
    let sessions = (0..<3).map { _ in SDKPublicSessionController() }
    let policy = try NearWireReconnectionPolicy(
      maximumAttempts: 2,
      initialDelay: .milliseconds(100),
      maximumDelay: .milliseconds(200)
    )
    let owner = makeSequenceOwner(
      probe: probe,
      sessions: sessions,
      configuration: try NearWireConfiguration(reconnectionPolicy: policy)
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: sessions[0], connect: connect)

    sessions[0].driver.emitState(.failed)
    await sessions[1].driver.waitUntilStarted()
    sessions[1].driver.emitState(.failed)
    await waitUntilState(.disconnected, owner: owner)

    let snapshot = await owner.lifecycleSnapshot
    let terminalStatus = await owner.connectionStatus
    XCTAssertFalse(snapshot.hasIntent)
    XCTAssertFalse(snapshot.hasRecoveryTask)
    XCTAssertEqual(probe.snapshot.claims, 2)
    XCTAssertEqual(probe.snapshot.releases, 2)
    XCTAssertEqual(terminalStatus.lastError?.code, .secureConnectionFailed)
  }

  func testDisconnectThenSuspendNeverRegressesLatestSuspensionStatus() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let release = SDKPublicVoidBarrier()
    let owner = makeSessionOwner(
      probe: probe,
      session: session,
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .beforeRelease { await release.run() }
        }
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)
    let observed = Task {
      var iterator = owner.connectionStatuses.makeAsyncIterator()
      var values: [NearWireConnectionStatus] = []
      while values.count < 3, let value = await iterator.next() {
        values.append(value)
      }
      return values
    }
    await sdkWaitUntil { owner.streamSubscriberCounts.statuses == 1 }

    let disconnect = Task { await owner.disconnect() }
    await release.waitUntilReached()
    let suspend = Task { await owner.suspendConnection() }
    await waitUntilSuspended(owner: owner)
    release.resume()

    let values = await observed.value
    await disconnect.value
    await suspend.value
    let finalStatus = await owner.connectionStatus
    XCTAssertEqual(values.map(\.state), [.connected, .connected, .disconnected])
    XCTAssertEqual(values.map(\.isSuspended), [false, true, true])
    XCTAssertTrue(finalStatus.isSuspended)
  }

  func testSuspendThenDisconnectNeverRegressesLatestSuspensionStatus() async throws {
    let probe = SDKPublicConnectionProbe()
    let session = SDKPublicSessionController()
    let release = SDKPublicVoidBarrier()
    let owner = makeSessionOwner(
      probe: probe,
      session: session,
      hooks: SDKPublicConnectionHooks(
        reachSynchronous: { _ in },
        reach: { point in
          if point == .beforeRelease { await release.run() }
        }
      )
    )
    let connect = Task { try await owner.connect(code: "ABC234") }
    try await driveConnection(session: session, connect: connect)
    let observed = Task {
      var iterator = owner.connectionStatuses.makeAsyncIterator()
      var values: [NearWireConnectionStatus] = []
      while values.count < 4, let value = await iterator.next() {
        values.append(value)
      }
      return values
    }
    await sdkWaitUntil { owner.streamSubscriberCounts.statuses == 1 }

    let suspend = Task { await owner.suspendConnection() }
    await release.waitUntilReached()
    let disconnect = Task { await owner.disconnect() }
    await waitUntilNotSuspended(owner: owner)
    release.resume()

    let values = await observed.value
    await suspend.value
    await disconnect.value
    let finalStatus = await owner.connectionStatus
    XCTAssertEqual(
      values.map(\.state),
      [.connected, .connected, .connected, .disconnected]
    )
    XCTAssertEqual(values.map(\.isSuspended), [false, true, false, false])
    XCTAssertFalse(finalStatus.isSuspended)
  }

  private func makeSessionOwner(
    probe: SDKPublicConnectionProbe,
    session: SDKPublicSessionController,
    hooks: SDKPublicConnectionHooks = .none,
    claimLease: (@Sendable () throws -> SDKPublicConnectionLease)? = nil
  ) -> NearWire {
    NearWire(
      dependencies: SDKTestClock().dependencies,
      connectionDependencies: SDKPublicConnectionDependencies(
        makeTransitionGate: { SDKSessionTransitionGate() },
        claimLease: {
          if let claimLease { return try claimLease() }
          probe.recordClaim()
          return SDKPublicConnectionLease { probe.recordRelease() }
        },
        loadInstallationIdentity: {
          probe.recordIdentity()
          return "00000000-0000-4000-8000-000000000001"
        },
        bundleMetadata: {
          SDKBundleMetadataInput(
            applicationIdentifier: "com.example.Host",
            shortVersion: "1.0",
            buildVersion: "1",
            displayName: "Host",
            bundleName: "Fallback"
          )
        },
        makeAdmission: { pairingCode, hello, plan, gate, phaseObserver in
          session.makeAdmission(
            pairingCode: pairingCode,
            hello: hello,
            plan: plan,
            gate: gate,
            phaseObserver: phaseObserver
          )
        },
        makePump: { attachment, owner, limits in
          SDKActiveEventPump(attachment: attachment, owner: owner, limits: limits)
        },
        hooks: hooks
      )
    )
  }

  private func makeSequenceOwner(
    probe: SDKPublicConnectionProbe,
    sessions: [SDKPublicSessionController],
    configuration: NearWireConfiguration = .default,
    hooks: SDKPublicConnectionHooks = .none,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
  ) -> NearWire {
    let sequence = SDKPublicSessionSequence(sessions)
    return NearWire(
      configuration: configuration,
      dependencies: SDKTestClock().dependencies,
      connectionDependencies: SDKPublicConnectionDependencies(
        makeTransitionGate: { SDKSessionTransitionGate() },
        claimLease: {
          probe.recordClaim()
          return SDKPublicConnectionLease { probe.recordRelease() }
        },
        loadInstallationIdentity: {
          probe.recordIdentity()
          return "00000000-0000-4000-8000-000000000001"
        },
        bundleMetadata: {
          SDKBundleMetadataInput(
            applicationIdentifier: "com.example.Host",
            shortVersion: "1.0",
            buildVersion: "1",
            displayName: "Host",
            bundleName: "Fallback"
          )
        },
        makeAdmission: { pairingCode, hello, plan, gate, phaseObserver in
          sequence.next().makeAdmission(
            pairingCode: pairingCode,
            hello: hello,
            plan: plan,
            gate: gate,
            phaseObserver: phaseObserver
          )
        },
        makePump: { attachment, owner, limits in
          SDKActiveEventPump(attachment: attachment, owner: owner, limits: limits)
        },
        hooks: hooks,
        sleep: sleep
      )
    )
  }

  private func waitUntilState(
    _ expected: NearWireState,
    owner: NearWire,
    timeoutNanoseconds: UInt64 = 1_000_000_000
  ) async {
    let start = DispatchTime.now().uptimeNanoseconds
    while await owner.currentState != expected,
      DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds
    {
      await Task.yield()
    }
    let finalState = await owner.currentState
    XCTAssertEqual(finalState, expected)
  }

  private func waitUntilSuspended(
    owner: NearWire,
    timeoutNanoseconds: UInt64 = 1_000_000_000
  ) async {
    let start = DispatchTime.now().uptimeNanoseconds
    while !(await owner.lifecycleSnapshot.isSuspended),
      DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds
    {
      await Task.yield()
    }
    let snapshot = await owner.lifecycleSnapshot
    XCTAssertTrue(snapshot.isSuspended)
  }

  private func waitUntilNotSuspended(
    owner: NearWire,
    timeoutNanoseconds: UInt64 = 1_000_000_000
  ) async {
    let start = DispatchTime.now().uptimeNanoseconds
    while await owner.lifecycleSnapshot.isSuspended,
      DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds
    {
      await Task.yield()
    }
    let snapshot = await owner.lifecycleSnapshot
    XCTAssertFalse(snapshot.isSuspended)
  }

  private func makeAdmissionOwner(
    probe: SDKPublicConnectionProbe,
    discovery: @escaping @Sendable () -> any SDKSessionDiscoveryOperation,
    driver: SDKPublicSecureDriver,
    phaseObserver:
      @escaping @Sendable (
        @escaping @Sendable () async -> SDKSessionPhaseAuthorization
      ) async -> SDKSessionPhaseAuthorization = { observer in await observer() }
  ) -> NearWire {
    NearWire(
      dependencies: SDKTestClock().dependencies,
      connectionDependencies: SDKPublicConnectionDependencies(
        makeTransitionGate: { SDKSessionTransitionGate() },
        claimLease: {
          probe.recordClaim()
          return SDKPublicConnectionLease { probe.recordRelease() }
        },
        loadInstallationIdentity: {
          probe.recordIdentity()
          return "00000000-0000-4000-8000-000000000001"
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
        makeAdmission: { pairingCode, hello, plan, gate, observer in
          SDKSessionAdmission(
            pairingCode: pairingCode,
            localHello: hello,
            wireLimits: plan.wireLimits,
            transportLimits: plan.transportLimits,
            admissionLimits: plan.admissionLimits,
            transitionGate: gate,
            phaseObserver: { await phaseObserver(observer) },
            dependencies: SDKSessionAdmissionDependencies(
              makeDiscovery: { _ in discovery() },
              makeChannel: { _, eventHandler in
                probe.recordChannel()
                return SecureByteChannel(
                  driver: driver,
                  limits: plan.transportLimits,
                  eventHandler: eventHandler
                )
              },
              sleep: { seconds in
                try await ContinuousClock().sleep(for: .seconds(seconds))
              }
            )
          )
        },
        makePump: { _, _, _ in
          fatalError("The active pump must not start in this test.")
        },
        hooks: .none
      )
    )
  }

  private static func discoveredViewer() -> DiscoveredViewer {
    let identity = NearWireBonjourServiceIdentity(
      instanceName: "NearWire-ABC234",
      type: NearWireBonjour.serviceType,
      domain: NearWireBonjour.localDomain,
      viewerDiscriminator: ViewerDiscoveryDiscriminator(
        viewerInstallationID: try! EndpointID(rawValue: "viewer-installation")
      )
    )!
    return DiscoveredViewer(
      identity: identity,
      endpoint: .hostPort(host: "127.0.0.1", port: 49_999)
    )
  }

  private func driveConnection(
    session: SDKPublicSessionController,
    connect: Task<Void, Error>
  ) async throws {
    try await driveAdmission(session: session)
    try await sendInitialPolicy(session: session)
    try await connect.value
  }

  private func driveAdmission(session: SDKPublicSessionController) async throws {
    await session.driver.waitUntilStarted()
    session.driver.emitState(.ready)
    await session.driver.waitForReceive()
    session.driver.completeReceive(
      try WirePreHandshakeCodec(limits: session.wireLimits).encode(session.viewerHello)
    )
    await session.driver.waitForReceive()
    session.driver.completeReceive(
      try session.codec.encode(session.acknowledgement, phase: .awaitingApproval)
    )
  }

  private func sendInitialPolicy(session: SDKPublicSessionController) async throws {
    await session.driver.waitForReceive()
    session.driver.completeReceive(
      try session.codec.encode(
        WireFlowPolicyOffer(
          policy: try WireFlowPolicy(
            appUplinkEventsPerSecond: 10,
            appDownlinkEventsPerSecond: 10
          )
        ),
        phase: .negotiatingPolicy
      )
    )
  }

  private func makeOwner(
    probe: SDKPublicConnectionProbe,
    identity: @escaping @Sendable () async throws -> String,
    hooks: SDKPublicConnectionHooks = .none,
    claimLease: (@Sendable () throws -> SDKPublicConnectionLease)? = nil
  ) -> NearWire {
    NearWire(
      dependencies: SDKTestClock().dependencies,
      connectionDependencies: SDKPublicConnectionDependencies(
        makeTransitionGate: { SDKSessionTransitionGate() },
        claimLease: {
          if let claimLease { return try claimLease() }
          probe.recordClaim()
          return SDKPublicConnectionLease { probe.recordRelease() }
        },
        loadInstallationIdentity: {
          probe.recordIdentity()
          return try await identity()
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
          fatalError("Admission must not start in this test.")
        },
        makePump: { _, _, _ in
          fatalError("The active pump must not start in this test.")
        },
        hooks: hooks
      )
    )
  }

  private func assertConnectError(
    _ code: NearWireError.Code,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected connect to fail.", file: file, line: line)
    } catch let error as NearWireError {
      XCTAssertEqual(error.code, code, file: file, line: line)
    } catch {
      XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
    }
  }

  private func assertTaskError(
    _ code: NearWireError.Code,
    task: Task<Void, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    await assertConnectError(code, operation: { try await task.value }, file: file, line: line)
  }

  private func assertSuccess(
    _ result: Result<Void, SDKSessionTransitionFailure>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .success = result else {
      XCTFail("Expected a successful transition claim.", file: file, line: line)
      return
    }
  }

  private func assertFailure(
    _ result: Result<Void, SDKSessionTransitionFailure>,
    equals expected: SDKSessionTransitionFailure,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .failure(let failure) = result else {
      XCTFail("Expected a failed transition claim.", file: file, line: line)
      return
    }
    XCTAssertEqual(failure, expected, file: file, line: line)
  }
}

private final class SDKPublicConnectionProbe: @unchecked Sendable {
  struct Snapshot: Equatable {
    var claims = 0
    var identities = 0
    var channels = 0
    var releases = 0
  }

  private let lock = NSLock()
  private var value = Snapshot()

  var snapshot: Snapshot {
    lock.withLock { value }
  }

  func recordClaim() {
    lock.withLock { value.claims += 1 }
  }

  func recordIdentity() {
    lock.withLock { value.identities += 1 }
  }

  func recordRelease() {
    lock.withLock { value.releases += 1 }
  }

  func recordChannel() {
    lock.withLock { value.channels += 1 }
  }
}

private final class SDKPublicSessionSequence: @unchecked Sendable {
  private let lock = NSLock()
  private let sessions: [SDKPublicSessionController]
  private var index = 0

  init(_ sessions: [SDKPublicSessionController]) {
    precondition(!sessions.isEmpty)
    self.sessions = sessions
  }

  func next() -> SDKPublicSessionController {
    lock.withLock {
      precondition(index < sessions.count, "Unexpected additional lifecycle route.")
      defer { index += 1 }
      return sessions[index]
    }
  }
}

private final class SDKPublicSleepBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private var reached = false
  private var reachWaiters: [CheckedContinuation<Void, Never>] = []
  private var continuation: CheckedContinuation<Void, Error>?

  func run(_ duration: Duration) async throws {
    precondition(duration > .zero)
    try await withCheckedThrowingContinuation { continuation in
      let waiters = lock.withLock {
        self.continuation = continuation
        reached = true
        let retained = reachWaiters
        reachWaiters.removeAll(keepingCapacity: false)
        return retained
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  func waitUntilReached() async {
    await withCheckedContinuation { continuation in
      let resumeImmediately = lock.withLock {
        if reached { return true }
        reachWaiters.append(continuation)
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }

  func resume() {
    let retained = lock.withLock {
      let retained = continuation
      continuation = nil
      return retained
    }
    retained?.resume()
  }
}

private final class SDKPublicSleepSequence: @unchecked Sendable {
  private let lock = NSLock()
  private let barriers: [SDKPublicSleepBarrier]
  private var index = 0

  init(_ barriers: [SDKPublicSleepBarrier]) {
    precondition(!barriers.isEmpty)
    self.barriers = barriers
  }

  func run(_ duration: Duration) async throws {
    let barrier = lock.withLock {
      precondition(index < barriers.count, "Unexpected additional recovery delay.")
      defer { index += 1 }
      return barriers[index]
    }
    try await barrier.run(duration)
  }
}

private final class SDKNthPublicVoidBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private let ordinal: Int
  private let barrier = SDKPublicVoidBarrier()
  private var count = 0

  init(ordinal: Int) {
    precondition(ordinal > 0)
    self.ordinal = ordinal
  }

  func reach() async {
    let shouldBlock = lock.withLock {
      count += 1
      return count == ordinal
    }
    if shouldBlock { await barrier.run() }
  }

  func waitUntilReached() async {
    await barrier.waitUntilReached()
  }

  func resume() {
    barrier.resume()
  }
}

private final class SDKWeakNearWire: @unchecked Sendable {
  weak var value: NearWire?

  init(_ value: NearWire?) {
    self.value = value
  }
}

private final class SDKPublicScriptedLeaseRuntime: ProcessConnectionLeaseRuntimeOperations,
  @unchecked Sendable
{
  struct Snapshot: Sendable {
    let enters: Int
    let exits: Int
  }

  private let lock = NSLock()
  private let failedEnterOrdinals: Set<Int>
  private let failedExitOrdinals: Set<Int>
  private var enters = 0
  private var exits = 0

  init(
    failedEnterOrdinals: Set<Int> = [],
    failedExitOrdinals: Set<Int> = []
  ) {
    self.failedEnterOrdinals = failedEnterOrdinals
    self.failedExitOrdinals = failedExitOrdinals
  }

  func enter(_ object: AnyObject) -> Int32 {
    let ordinal = lock.withLock {
      enters += 1
      return enters
    }
    guard !failedEnterOrdinals.contains(ordinal) else { return -1 }
    return objc_sync_enter(object)
  }

  func exit(_ object: AnyObject) -> Int32 {
    let status = objc_sync_exit(object)
    let ordinal = lock.withLock {
      exits += 1
      return exits
    }
    return failedExitOrdinals.contains(ordinal) ? -1 : status
  }

  func associatedObject(_ object: AnyObject, key: UnsafeRawPointer) -> Any? {
    objc_getAssociatedObject(object, key)
  }

  func setAssociatedObject(_ object: AnyObject, key: UnsafeRawPointer, value: AnyObject?) {
    objc_setAssociatedObject(object, key, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }

  var snapshot: Snapshot {
    lock.withLock { Snapshot(enters: enters, exits: exits) }
  }
}

private final class SDKPublicIdentityBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private var reached = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var continuation: CheckedContinuation<String, Error>?

  func run() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
        self.continuation = continuation
        reached = true
        let retained = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        return retained
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  func waitUntilReached() async {
    await withCheckedContinuation { continuation in
      let resumeImmediately: Bool = lock.withLock {
        if reached { return true }
        waiters.append(continuation)
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }

  func resume(returning value: String) {
    let retained: CheckedContinuation<String, Error>? = lock.withLock {
      let retained = continuation
      continuation = nil
      return retained
    }
    retained?.resume(returning: value)
  }
}

private final class SDKPublicVoidBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private var reached = false
  private var reachWaiters: [CheckedContinuation<Void, Never>] = []
  private var continuation: CheckedContinuation<Void, Never>?

  func run() async {
    await withCheckedContinuation { continuation in
      let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
        self.continuation = continuation
        reached = true
        let retained = reachWaiters
        reachWaiters.removeAll(keepingCapacity: false)
        return retained
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  func waitUntilReached() async {
    await withCheckedContinuation { continuation in
      let resumeImmediately: Bool = lock.withLock {
        if reached { return true }
        reachWaiters.append(continuation)
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }

  func resume() {
    let retained: CheckedContinuation<Void, Never>? = lock.withLock {
      let retained = continuation
      continuation = nil
      return retained
    }
    retained?.resume()
  }
}

private final class SDKPublicControlledDiscovery: SDKSessionDiscoveryOperation,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var running = false
  private var continuation: CheckedContinuation<DiscoveredViewer, Error>?
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func run() async throws -> DiscoveredViewer {
    try await withCheckedThrowingContinuation { continuation in
      let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
        self.continuation = continuation
        running = true
        let retained = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        return retained
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  func cancel() async {
    let retained: CheckedContinuation<DiscoveredViewer, Error>? = lock.withLock {
      let retained = continuation
      continuation = nil
      return retained
    }
    retained?.resume(throwing: ViewerDiscoveryError(.cancelled))
  }

  func waitUntilRunning() async {
    await withCheckedContinuation { continuation in
      let resumeImmediately: Bool = lock.withLock {
        if running { return true }
        waiters.append(continuation)
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }
}

private final class SDKPublicSessionController: @unchecked Sendable {
  let driver = SDKPublicSecureDriver()

  private let lock = NSLock()
  private var storedViewerHello: WireHello?
  private var storedCodec: WireSessionCodec?
  private var storedAcknowledgement: WireHelloAcknowledgement?
  private var storedWireLimits: WireProtocolLimits?

  var viewerHello: WireHello {
    lock.withLock { storedViewerHello! }
  }

  var codec: WireSessionCodec {
    lock.withLock { storedCodec! }
  }

  var acknowledgement: WireHelloAcknowledgement {
    lock.withLock { storedAcknowledgement! }
  }

  var wireLimits: WireProtocolLimits {
    lock.withLock { storedWireLimits! }
  }

  func makeAdmission(
    pairingCode: PairingCode,
    hello: WireHello,
    plan: SDKPublicConnectionLimitPlan,
    gate: SDKSessionTransitionGate,
    phaseObserver: @escaping @Sendable () async -> SDKSessionPhaseAuthorization
  ) -> SDKSessionAdmission {
    let viewer = try! WireHello(
      productVersion: WireProductVersion("0.1.0"),
      role: .viewer,
      installationID: EndpointID(rawValue: "viewer-installation"),
      maximumEventBytes: plan.maximumEventRecordBytes,
      limits: plan.wireLimits
    )
    let negotiation = try! WireNegotiator.negotiate(local: hello, remote: viewer)
    let codec = try! WireSessionCodec(negotiation: negotiation, baseLimits: plan.wireLimits)
    let acknowledgement = try! WireNegotiator.makeAcknowledgement(
      result: negotiation,
      sessionEpoch: SessionEpoch(rawValue: "123e4567-e89b-12d3-a456-426614174000"),
      limits: plan.wireLimits
    )
    let identity = NearWireBonjourServiceIdentity(
      instanceName: "NearWire-ABC234",
      type: NearWireBonjour.serviceType,
      domain: NearWireBonjour.localDomain,
      viewerDiscriminator: ViewerDiscoveryDiscriminator(
        viewerInstallationID: viewer.installationID
      )
    )!
    let discovered = DiscoveredViewer(
      identity: identity,
      endpoint: .hostPort(host: "127.0.0.1", port: 49_999)
    )
    lock.withLock {
      storedViewerHello = viewer
      storedCodec = codec
      storedAcknowledgement = acknowledgement
      storedWireLimits = plan.wireLimits
    }
    return SDKSessionAdmission(
      pairingCode: pairingCode,
      localHello: hello,
      wireLimits: plan.wireLimits,
      transportLimits: plan.transportLimits,
      admissionLimits: plan.admissionLimits,
      transitionGate: gate,
      phaseObserver: phaseObserver,
      dependencies: SDKSessionAdmissionDependencies(
        makeDiscovery: { _ in SDKPublicImmediateDiscovery(result: discovered) },
        makeChannel: { [driver] _, eventHandler in
          SecureByteChannel(
            driver: driver,
            limits: plan.transportLimits,
            eventHandler: eventHandler
          )
        },
        sleep: { seconds in
          try await ContinuousClock().sleep(for: .seconds(seconds))
        }
      )
    )
  }
}

private final class SDKPublicImmediateDiscovery: SDKSessionDiscoveryOperation,
  @unchecked Sendable
{
  let result: DiscoveredViewer

  init(result: DiscoveredViewer) {
    self.result = result
  }

  func run() async throws -> DiscoveredViewer { result }
  func cancel() async {}
}

private final class SDKPublicSecureDriver: SecureConnectionDriving, @unchecked Sendable {
  private let lock = NSLock()
  private var stateHandler: (@Sendable (SecureDriverState) -> Void)?
  private var receiveCompletion: (@Sendable (Data?, Bool, Bool) -> Void)?
  private var storedCancelCount = 0
  private var storedSentData: [Data] = []

  var cancelCount: Int {
    lock.withLock { storedCancelCount }
  }

  var sentData: [Data] {
    lock.withLock { storedSentData }
  }

  func start(stateHandler: @escaping @Sendable (SecureDriverState) -> Void) {
    lock.withLock { self.stateHandler = stateHandler }
  }

  func receive(
    maximumLength _: Int,
    completion: @escaping @Sendable (Data?, Bool, Bool) -> Void
  ) {
    lock.withLock { receiveCompletion = completion }
  }

  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
    lock.withLock { storedSentData.append(data) }
    completion(false)
  }

  func cancel() {
    lock.withLock {
      storedCancelCount += 1
      receiveCompletion = nil
    }
  }

  func emitState(_ state: SecureDriverState) {
    let handler = lock.withLock { stateHandler }
    handler?(state)
  }

  func completeReceive(_ data: Data) {
    let completion: (@Sendable (Data?, Bool, Bool) -> Void)? = lock.withLock {
      let retained = receiveCompletion
      receiveCompletion = nil
      return retained
    }
    completion?(data, false, false)
  }

  func waitUntilStarted() async {
    await sdkWaitUntil { self.lock.withLock { self.stateHandler != nil } }
  }

  func waitForReceive() async {
    await sdkWaitUntil { self.lock.withLock { self.receiveCompletion != nil } }
  }
}
