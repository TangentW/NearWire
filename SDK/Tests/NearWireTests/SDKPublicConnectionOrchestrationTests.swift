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

  var cancelCount: Int {
    lock.withLock { storedCancelCount }
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
