import Foundation
@_spi(NearWireInternal) import NearWireCore
import Network
import XCTest
import dnssd

@testable import NearWire
@_spi(NearWireInternal) @testable import NearWireTransport

final class TestViewerDiscoveryDriver: ViewerDiscoveryDriving, @unchecked Sendable {
  enum StartFailure: Error { case failed }

  private let lock = NSLock()
  private var handler: (@Sendable (ViewerDiscoveryDriverEvent) -> Void)?
  private var _startCount = 0
  private var _quiesceCount = 0
  private var _cancelCount = 0
  private var _expectedInstanceNames: [String] = []
  var startFailure: Error?
  var reentrantEvent: ViewerDiscoveryDriverEvent?
  var reentrantEvents: [ViewerDiscoveryDriverEvent] = []

  func start(
    expectedInstanceName: String,
    handler: @escaping @Sendable (ViewerDiscoveryDriverEvent) -> Void
  ) throws {
    lock.lock()
    _startCount += 1
    _expectedInstanceNames.append(expectedInstanceName)
    self.handler = handler
    let failure = startFailure
    let event = reentrantEvent
    let events = reentrantEvents
    lock.unlock()
    if let event { handler(event) }
    for event in events { handler(event) }
    if let failure { throw failure }
  }

  func cancel() {
    lock.lock()
    _cancelCount += 1
    lock.unlock()
  }

  func quiesceAfterMatch() {
    lock.lock()
    _quiesceCount += 1
    handler = nil
    lock.unlock()
  }

  func emit(_ event: ViewerDiscoveryDriverEvent) {
    lock.lock()
    let callback = handler
    lock.unlock()
    callback?(event)
  }

  var startCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _startCount
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _cancelCount
  }

  var quiesceCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _quiesceCount
  }

  var expectedInstanceNames: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _expectedInstanceNames
  }
}

final class TestCallbackEdgeDriver: ViewerDiscoveryDriving, @unchecked Sendable {
  private let lock = NSLock()
  private var edge: BonjourBrowserCallbackEdge?
  private var _startCount = 0
  private var _quiesceCount = 0
  private var _cancelCount = 0

  func start(
    expectedInstanceName: String,
    handler: @escaping @Sendable (ViewerDiscoveryDriverEvent) -> Void
  ) throws {
    lock.lock()
    _startCount += 1
    edge = BonjourBrowserCallbackEdge(emit: handler, emitTerminal: handler)
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    _cancelCount += 1
    edge = nil
    lock.unlock()
  }

  func quiesceAfterMatch() {
    lock.lock()
    _quiesceCount += 1
    edge = nil
    lock.unlock()
  }

  func ready() {
    readEdge()?.ready()
  }

  func results<Results: Collection>(
    _ rawResults: Results,
    transform: (Results.Element) -> BonjourResultConversion
  ) {
    readEdge()?.results(rawResults, transform: transform)
  }

  var startCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _startCount
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _cancelCount
  }

  var quiesceCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _quiesceCount
  }

  private func readEdge() -> BonjourBrowserCallbackEdge? {
    lock.lock()
    defer { lock.unlock() }
    return edge
  }
}

final class TestNWBrowserController: NWBrowserControlling, @unchecked Sendable {
  var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)?
  var browseResultsChangedHandler:
    (@Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void)?
  private(set) var startCount = 0
  private(set) var cancelCount = 0
  private(set) var startQueueLabels: [String] = []

  func start(queue: DispatchQueue) {
    startCount += 1
    startQueueLabels.append(queue.label)
  }

  func cancel() {
    cancelCount += 1
  }

  func emit(_ state: NWBrowser.State) {
    stateUpdateHandler?(state)
  }
}

private actor DiscoveryTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

final class ViewerDiscoveryTests: XCTestCase {
  private let pairingCode = try! PairingCode("7K3M")

  func testExactMatchReturnsInterfaceNeutralEndpointAndRetainsBrowserUntilRelease() async throws {
    let driver = TestViewerDiscoveryDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }

    driver.emit(.ready(epoch: 1))
    driver.emit(.snapshot(snapshot([candidate(vid: "b3a97f874aad08bf")]), epoch: 1))
    let viewer = try await task.value

    let matchedState = await coordinator.state
    XCTAssertEqual(matchedState, .matched)
    XCTAssertEqual(driver.expectedInstanceNames, ["NearWire-7K3M"])
    XCTAssertEqual(driver.quiesceCount, 1)
    XCTAssertEqual(driver.cancelCount, 0)
    let retainsExpectedInstanceName = await coordinator.retainsExpectedInstanceName
    XCTAssertFalse(retainsExpectedInstanceName)
    let retainedAfterMatch = await coordinator.retainedCandidateCount
    XCTAssertEqual(retainedAfterMatch, 0)
    if case .service(let name, let type, let domain, let interface) = viewer.endpoint {
      XCTAssertEqual(name, "NearWire-7K3M")
      XCTAssertEqual(type, NearWireBonjour.serviceType)
      XCTAssertEqual(domain, NearWireBonjour.localDomain)
      XCTAssertNil(interface)
    } else {
      XCTFail("Expected an interface-neutral service endpoint.")
    }

    driver.emit(.failed(.browserFailure))
    let stateAfterLateEvent = await coordinator.state
    XCTAssertEqual(stateAfterLateEvent, .matched)

    _ = SecureAppTransport.makeChannel(
      endpoint: viewer.endpoint,
      connectionQueue: DispatchQueue(label: "test.discovery.connection"),
      verificationQueue: DispatchQueue(label: "test.discovery.verification"),
      eventHandler: { _ in }
    )
    await coordinator.cancel()
    await coordinator.cancel()
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testUnrelatedConflictSuffixAndEmptySnapshotsDoNotMatch() async throws {
    let driver = TestViewerDiscoveryDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    driver.emit(.ready(epoch: 4))
    driver.emit(.snapshot(.empty, epoch: 4))
    driver.emit(
      .snapshot(snapshot([candidate(name: "NearWire-7K3R")]), epoch: 4)
    )
    await waitUntilAsync { await coordinator.retainedCandidateCount == 0 }
    let searchingState = await coordinator.state
    XCTAssertEqual(searchingState, .searching)

    driver.emit(.snapshot(snapshot([candidate()]), epoch: 4))
    _ = try await task.value
  }

  func testDistinctPublishersAreAmbiguousEvenWithUnattributedResult() async {
    let driver = TestViewerDiscoveryDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    driver.emit(.ready(epoch: 1))
    driver.emit(
      .snapshot(
        snapshot(
          [candidate(vid: "b3a97f874aad08bf"), candidate(vid: "7ac1b8d7010bb6cd")],
          unattributed: true
        ),
        epoch: 1
      )
    )
    await assertError(task, code: .ambiguous)
    let ambiguousState = await coordinator.state
    XCTAssertEqual(ambiguousState, .ambiguous)
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testUnattributedExactResultBlocksOneValidPublisherUntilReplacement() async throws {
    let driver = TestViewerDiscoveryDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    driver.emit(.ready(epoch: 2))
    driver.emit(.snapshot(snapshot([candidate()], unattributed: true), epoch: 2))
    await waitUntilAsync { await coordinator.retainedCandidateCount == 0 }
    let blockedState = await coordinator.state
    XCTAssertEqual(blockedState, .searching)
    XCTAssertEqual(driver.cancelCount, 0)

    driver.emit(.snapshot(snapshot([candidate()]), epoch: 2))
    _ = try await task.value
  }

  func testSameDiscriminatorAndInterfaceDuplicatesMergeWithoutIdentityProof() async throws {
    let driver = TestViewerDiscoveryDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    driver.emit(.ready(epoch: 3))
    driver.emit(.snapshot(snapshot([candidate(), candidate()]), epoch: 3))
    let viewer = try await task.value
    XCTAssertEqual(viewer.identity.viewerDiscriminator.rawValue, "b3a97f874aad08bf")
    let duplicateState = await coordinator.state
    XCTAssertEqual(duplicateState, .matched)
  }

  func testWaitingRequiresNewReadyEpochAndLaterSnapshot() async throws {
    let driver = TestViewerDiscoveryDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    driver.emit(.ready(epoch: 1))
    driver.emit(.waiting(.unavailableNetwork))
    await waitUntilAsync { await coordinator.state == .waiting }
    driver.emit(.snapshot(snapshot([candidate()]), epoch: 1))
    driver.emit(.ready(epoch: 2))
    await waitUntilAsync { await coordinator.state == .searching }
    XCTAssertEqual(driver.cancelCount, 0)

    driver.emit(.snapshot(snapshot([candidate()]), epoch: 2))
    _ = try await task.value
  }

  func testPolicyDenialResultLimitFailureAndUnsolicitedCancellationAreTerminal() async {
    await assertTerminalEvent(.waiting(.permissionOrPolicyDenied), code: .permissionOrPolicyDenied)
    await assertTerminalEvent(.failed(.resultLimitExceeded), code: .resultLimitExceeded)
    await assertTerminalEvent(.failed(.browserFailure), code: .browserFailure)
    await assertTerminalEvent(.cancelled, code: .cancelled, expectedCancelCount: 0)
  }

  func testCancelBeforeRunAndRepeatedRunAreDeterministic() async {
    let beforeDriver = TestViewerDiscoveryDriver()
    let beforeCoordinator = ViewerDiscoveryCoordinator(
      pairingCode: pairingCode, driver: beforeDriver)
    await beforeCoordinator.cancel()
    do {
      _ = try await beforeCoordinator.run()
      XCTFail("Expected already-started after cancel-before-run.")
    } catch {
      XCTAssertEqual((error as? ViewerDiscoveryError)?.code, .alreadyStarted)
    }
    XCTAssertEqual(beforeDriver.startCount, 0)
    XCTAssertEqual(beforeDriver.cancelCount, 0)

    let driver = TestViewerDiscoveryDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let first = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    do {
      _ = try await coordinator.run()
      XCTFail("Expected repeated run to fail.")
    } catch {
      XCTAssertEqual((error as? ViewerDiscoveryError)?.code, .alreadyStarted)
    }
    await coordinator.cancel()
    await assertError(first, code: .cancelled)
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testAlreadyCancelledTaskDoesNotStartOrCancelDriver() async {
    let driver = TestViewerDiscoveryDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { () throws -> DiscoveredViewer in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await coordinator.run()
    }
    await assertError(task, code: .cancelled)
    XCTAssertEqual(driver.startCount, 0)
    XCTAssertEqual(driver.cancelCount, 0)
    let state = await coordinator.state
    XCTAssertEqual(state, .cancelled)
  }

  func testFirstReentrantTerminalWinsAndLaterEventsRetainNothing() async {
    for events: [ViewerDiscoveryDriverEvent] in [
      [.failed(.browserFailure), .cancelled, .snapshot(.empty, epoch: 1)],
      [.waiting(.permissionOrPolicyDenied), .cancelled, .ready(epoch: 1)],
    ] {
      let driver = TestViewerDiscoveryDriver()
      driver.reentrantEvents = events
      let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
      let task = Task { try await coordinator.run() }
      let expected: ViewerDiscoveryError.Code
      if case .failed = events[0] {
        expected = .browserFailure
      } else {
        expected = .permissionOrPolicyDenied
      }
      await assertError(task, code: expected)
      XCTAssertEqual(driver.cancelCount, 1)
      let retained = await coordinator.retainedCandidateCount
      XCTAssertEqual(retained, 0)
      let ingressCounts = await coordinator.ingressRetainedCounts
      XCTAssertNil(ingressCounts)
    }
  }

  func testDuplicateReadyCannotInvalidatePendingSnapshot() async throws {
    let driver = TestCallbackEdgeDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    driver.ready()
    driver.results([0]) { _ in .candidate(self.candidate()) }
    driver.ready()
    _ = try await task.value
    let state = await coordinator.state
    XCTAssertEqual(state, .matched)
    XCTAssertEqual(driver.cancelCount, 0)
    await coordinator.cancel()
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testOversizedCallbackEdgeFailsAndReleasesBlockedSnapshot() async {
    let driver = TestCallbackEdgeDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    driver.ready()
    driver.results([0, 1]) { value in
      value == 0 ? .unattributedExact : .discarded
    }
    await waitUntilAsync { await coordinator.discardedResultCount == 1 }

    var conversionCount = 0
    driver.results(Array(0...256)) { _ in
      conversionCount += 1
      return .candidate(self.candidate())
    }
    await assertError(task, code: .resultLimitExceeded)
    XCTAssertEqual(conversionCount, 0)
    XCTAssertEqual(driver.cancelCount, 1)
    let retained = await coordinator.retainedCandidateCount
    XCTAssertEqual(retained, 0)
    let ingress = await coordinator.ingressRetainedCounts
    XCTAssertNil(ingress)
  }

  func testDiscardTelemetryAccumulatesAndSaturates() async throws {
    let driver = TestViewerDiscoveryDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    driver.emit(.ready(epoch: 1))
    driver.emit(
      .snapshot(
        ViewerDiscoverySnapshot(
          candidates: [],
          hasUnattributedExactResult: false,
          discardedResultCount: UInt64.max - 1
        ),
        epoch: 1
      )
    )
    await waitUntilAsync { await coordinator.discardedResultCount == UInt64.max - 1 }
    driver.emit(
      .snapshot(
        ViewerDiscoverySnapshot(
          candidates: [],
          hasUnattributedExactResult: false,
          discardedResultCount: 10
        ),
        epoch: 1
      )
    )
    await waitUntilAsync { await coordinator.discardedResultCount == UInt64.max }
    driver.emit(.snapshot(snapshot([candidate()]), epoch: 1))
    _ = try await task.value
    let finalDiscardedCount = await coordinator.discardedResultCount
    XCTAssertEqual(finalDiscardedCount, UInt64.max)
  }

  func testStartFailureReentrantReadyAndLateCallbacksCompleteOnce() async {
    let failingDriver = TestViewerDiscoveryDriver()
    failingDriver.startFailure = TestViewerDiscoveryDriver.StartFailure.failed
    failingDriver.reentrantEvent = .ready(epoch: 9)
    let failingCoordinator = ViewerDiscoveryCoordinator(
      pairingCode: pairingCode,
      driver: failingDriver
    )
    let failingTask = Task { try await failingCoordinator.run() }
    await assertError(failingTask, code: .browserFailure)
    XCTAssertEqual(failingDriver.cancelCount, 1)
    failingDriver.emit(.snapshot(snapshot([candidate()]), epoch: 9))
    let failedState = await failingCoordinator.state
    XCTAssertEqual(failedState, .failed)

    let driver = TestViewerDiscoveryDriver()
    driver.reentrantEvent = .ready(epoch: 1)
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    driver.emit(.snapshot(snapshot([candidate()]), epoch: 1))
    _ = try? await task.value
    driver.emit(.failed(.browserFailure))
    driver.emit(.cancelled)
    let finalState = await coordinator.state
    XCTAssertEqual(finalState, .matched)
    XCTAssertEqual(driver.cancelCount, 0)
    await coordinator.cancel()
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testTaskCancellationAndResultRaceHasOneWinner() async {
    for index in 0..<20 {
      let driver = TestViewerDiscoveryDriver()
      let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
      let task = Task { try await coordinator.run() }
      await waitUntil { driver.startCount == 1 }
      driver.emit(.ready(epoch: UInt64(index + 1)))
      task.cancel()
      driver.emit(
        .snapshot(snapshot([candidate()]), epoch: UInt64(index + 1))
      )
      _ = try? await task.value
      let state = await coordinator.state
      XCTAssertTrue(state == .matched || state == .cancelled)
      await coordinator.cancel()
      XCTAssertEqual(driver.cancelCount, 1)
      let retainedCount = await coordinator.retainedCandidateCount
      XCTAssertEqual(retainedCount, 0)
    }
  }

  func testIngressCoalescesSnapshotsAndGivesTerminalPriority() async {
    let gate = DiscoveryTestGate()
    let capture = SDKLockedCapture<ViewerDiscoveryDriverEvent>()
    let ingress = ViewerDiscoveryEventIngress { event in
      await gate.wait()
      capture.append(event)
    }
    ingress.submit(.ready(epoch: 1))
    await waitUntil { ingress.retainedCounts.processing == 1 }
    for epoch in 1...100 {
      ingress.submit(.snapshot(.empty, epoch: UInt64(epoch)))
    }
    XCTAssertEqual(ingress.retainedCounts.snapshot, 1)
    ingress.submit(.failed(.browserFailure))
    XCTAssertEqual(ingress.retainedCounts.snapshot, 0)
    XCTAssertEqual(ingress.retainedCounts.stateOrTerminal, 1)
    await gate.open()
    await waitUntil { ingress.retainedCounts.processing == 0 }
    XCTAssertEqual(capture.snapshot.count, 2)
    if case .failed(.browserFailure) = capture.snapshot.last {
    } else {
      XCTFail("Expected terminal failure to replace the pending snapshot.")
    }
  }

  func testIngressFootprintBoundsProcessingAndPendingSnapshots() async {
    let gate = DiscoveryTestGate()
    let ingress = ViewerDiscoveryEventIngress { _ in await gate.wait() }
    let candidates = Array(repeating: candidate(), count: NearWireBonjour.maximumRawResults)
    let bounded = snapshot(candidates)
    ingress.submit(.snapshot(bounded, epoch: 1))
    await waitUntil {
      let counts = ingress.retainedCounts
      return counts.processing == 1 && counts.snapshot == 0
        && counts.candidateCount == NearWireBonjour.maximumRawResults
    }
    ingress.submit(.snapshot(bounded, epoch: 1))
    XCTAssertEqual(
      ingress.retainedCounts.candidateCount,
      NearWireBonjour.maximumRawResults * 2
    )
    XCTAssertEqual(
      ingress.retainedCounts.identityByteCount,
      bounded.retainedIdentityByteCount * 2
    )
    ingress.submit(.failed(.browserFailure))
    XCTAssertEqual(ingress.retainedCounts.snapshot, 0)
    XCTAssertEqual(
      ingress.retainedCounts.candidateCount,
      NearWireBonjour.maximumRawResults
    )
    await gate.open()
    await waitUntil { ingress.retainedCounts.processing == 0 }
    XCTAssertEqual(ingress.retainedCounts.candidateCount, 0)
    XCTAssertEqual(ingress.retainedCounts.identityByteCount, 0)
  }

  private func assertTerminalEvent(
    _ event: ViewerDiscoveryDriverEvent,
    code: ViewerDiscoveryError.Code,
    expectedCancelCount: Int = 1
  ) async {
    let driver = TestViewerDiscoveryDriver()
    let coordinator = ViewerDiscoveryCoordinator(pairingCode: pairingCode, driver: driver)
    let task = Task { try await coordinator.run() }
    await waitUntil { driver.startCount == 1 }
    driver.emit(event)
    await assertError(task, code: code)
    XCTAssertEqual(driver.cancelCount, expectedCancelCount)
    let retainedCount = await coordinator.retainedCandidateCount
    XCTAssertEqual(retainedCount, 0)
  }

  private func assertError(
    _ task: Task<DiscoveredViewer, Error>,
    code: ViewerDiscoveryError.Code
  ) async {
    do {
      _ = try await task.value
      XCTFail("Expected discovery error \(code.rawValue).")
    } catch {
      XCTAssertEqual((error as? ViewerDiscoveryError)?.code, code)
    }
  }

  private func candidate(
    name: String = "NearWire-7K3M",
    vid: String = "b3a97f874aad08bf"
  ) -> ViewerDiscoveryCandidate {
    let identity = NearWireBonjourServiceIdentity(
      instanceName: name,
      type: NearWireBonjour.serviceType,
      domain: NearWireBonjour.localDomain,
      viewerDiscriminator: ViewerDiscoveryDiscriminator(rawValue: vid)!
    )!
    return ViewerDiscoveryCandidate(
      identity: identity,
      endpoint: .service(
        name: identity.instanceName,
        type: identity.type,
        domain: identity.domain,
        interface: nil
      )
    )
  }

  private func snapshot(
    _ candidates: [ViewerDiscoveryCandidate],
    unattributed: Bool = false
  ) -> ViewerDiscoverySnapshot {
    ViewerDiscoverySnapshot(
      candidates: candidates,
      hasUnattributedExactResult: unattributed,
      discardedResultCount: 0
    )
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async {
    await sdkWaitUntil(condition: condition)
    XCTAssertTrue(condition())
  }

  private func waitUntilAsync(_ condition: @escaping () async -> Bool) async {
    for _ in 0..<10_000 {
      if await condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for asynchronous condition.")
  }
}

final class BonjourBrowserAdapterTests: XCTestCase {
  func testProductionPlanUsesTXTLocalDomainAndPeerToPeer() throws {
    XCTAssertEqual(
      NWBrowserDiscoveryDriver.productionPlan,
      BonjourBrowserPlan(
        serviceType: "_nearwire._tcp",
        domain: "local."
      )
    )

    var capturedDescriptor: NWBrowser.Descriptor?
    var capturedPeerToPeer: Bool?
    let controller = TestNWBrowserController()
    let driver = NWBrowserDiscoveryDriver { descriptor, parameters in
      capturedDescriptor = descriptor
      capturedPeerToPeer = parameters.includePeerToPeer
      return controller
    }
    _ = driver
    guard case .bonjourWithTXTRecord(let type, let domain)? = capturedDescriptor else {
      return XCTFail("Production driver must construct the TXT-enabled descriptor.")
    }
    XCTAssertEqual(type, "_nearwire._tcp")
    XCTAssertEqual(domain, "local.")
    XCTAssertEqual(capturedPeerToPeer, true)
    try driver.start(expectedInstanceName: "NearWire-7K3M") { _ in }
    XCTAssertEqual(controller.startQueueLabels, ["com.nearwire.discovery.browser"])
    driver.cancel()
  }

  func testUnstartedProductionDriverDeinitializesWithoutHiddenLifetimeWork() throws {
    weak var retainedDriver: NWBrowserDiscoveryDriver?
    autoreleasepool {
      let driver = NWBrowserDiscoveryDriver()
      retainedDriver = driver
    }
    XCTAssertNil(retainedDriver)
  }

  func testRawResultLimitRejectsBeforeConversion() {
    var conversionCount = 0
    let conversion = BonjourSnapshotConverter.convert(Array(0...256)) { _ in
      conversionCount += 1
      return .discarded
    }
    if case .resultLimitExceeded = conversion {
    } else {
      XCTFail("Expected the 257-result callback to fail.")
    }
    XCTAssertEqual(conversionCount, 0)
  }

  func testOversizedCallbackDoesNotReusePriorSnapshot() {
    let valid = BonjourSnapshotConverter.convert([0]) { _ in .candidate(self.candidate()) }
    if case .snapshot(let snapshot) = valid {
      XCTAssertEqual(snapshot.candidates.count, 1)
    } else {
      XCTFail("Expected valid snapshot.")
    }

    let oversized = BonjourSnapshotConverter.convert(Array(0...256)) { _ in
      XCTFail("Oversized callbacks must fail before conversion.")
      return .discarded
    }
    if case .resultLimitExceeded = oversized {
    } else {
      XCTFail("Expected independent terminal result-limit event.")
    }
  }

  func testMissingMalformedAndBoundedTXTValues() {
    XCTAssertNil(NWBrowserDiscoveryDriver.viewerDiscriminator(from: .none))
    XCTAssertNil(
      NWBrowserDiscoveryDriver.viewerDiscriminator(
        from: .bonjour(NWTXTRecord(["vid": "B3A97F874AAD08BF"]))
      )
    )
    XCTAssertNil(
      NWBrowserDiscoveryDriver.viewerDiscriminator(
        from: .bonjour(NWTXTRecord(["vid": String(repeating: "a", count: 17)]))
      )
    )
    XCTAssertEqual(
      NWBrowserDiscoveryDriver.viewerDiscriminator(
        from: .bonjour(NWTXTRecord(["vid": "b3a97f874aad08bf", "private": "discarded"]))
      )?.rawValue,
      "b3a97f874aad08bf"
    )
  }

  func testInterfaceOverflowPreservesMatchingAndAmbiguityIdentity() {
    let expected = "NearWire-7K3M"
    let first = observation(expected, vid: "b3a97f874aad08bf", interfaces: 33)
    let second = observation(expected, vid: "7ac1b8d7010bb6cd", interfaces: 1)
    let conversions = [first, second].map {
      BonjourServiceObservationConverter.convert($0, expectedInstanceName: expected)
    }
    let candidates = conversions.compactMap { conversion -> ViewerDiscoveryCandidate? in
      if case .candidate(let candidate) = conversion { return candidate }
      return nil
    }
    XCTAssertEqual(candidates.count, 2)
    XCTAssertEqual(Set(candidates.map(\.identity.viewerDiscriminator)).count, 2)
  }

  func testObservationConversionHasThreeExplicitOutcomes() {
    let expected = "NearWire-7K3M"
    if case .discarded = BonjourServiceObservationConverter.convert(
      observation("NearWire-WXYZ", vid: "b3a97f874aad08bf", interfaces: 0),
      expectedInstanceName: expected
    ) {
    } else {
      XCTFail("Wrong-name result must be discarded.")
    }
    if case .unattributedExact = BonjourServiceObservationConverter.convert(
      observation(expected, vid: nil, interfaces: 0),
      expectedInstanceName: expected
    ) {
    } else {
      XCTFail("Exact result without vid must remain unattributed.")
    }
    if case .candidate = BonjourServiceObservationConverter.convert(
      observation(expected, vid: "b3a97f874aad08bf", interfaces: 0),
      expectedInstanceName: expected
    ) {
    } else {
      XCTFail("Exact attributed result must become a candidate.")
    }
    if case .discarded = BonjourServiceObservationConverter.convert(
      observation("NearWire-7K3M (2)", vid: "b3a97f874aad08bf", interfaces: 0),
      expectedInstanceName: expected
    ) {
    } else {
      XCTFail("Bonjour conflict-renamed instance must not match.")
    }
  }

  func testReadinessGateDiscardsWaitingSnapshotAndRequiresLaterSnapshot() {
    var gate = BonjourReadinessGate()
    if case .ready(let epoch)? = gate.readyEvent() { XCTAssertEqual(epoch, 1) }
    XCTAssertNil(gate.readyEvent())
    _ = gate.waitingEvent(.unavailableNetwork)
    XCTAssertNil(gate.snapshotEvent(.empty))
    if case .ready(let epoch)? = gate.readyEvent() { XCTAssertEqual(epoch, 3) }
    guard case .snapshot(_, let epoch)? = gate.snapshotEvent(.empty) else {
      return XCTFail("Expected a later ready-epoch snapshot.")
    }
    XCTAssertEqual(epoch, 3)
  }

  func testCallbackEdgeLatchesTerminalAndRejectsLateConversion() {
    let capture = SDKLockedCapture<ViewerDiscoveryDriverEvent>()
    let edge = BonjourBrowserCallbackEdge(
      emit: { event in capture.append(event) },
      emitTerminal: { event in capture.append(event) }
    )
    edge.ready()
    edge.failed(.browserFailure)
    edge.cancelled()
    var conversionCount = 0
    edge.results([0]) { _ in
      conversionCount += 1
      return .discarded
    }
    XCTAssertEqual(conversionCount, 0)
    XCTAssertEqual(capture.snapshot.count, 2)
    if case .failed(.browserFailure) = capture.snapshot.last {
    } else {
      XCTFail("The first callback-edge terminal must remain authoritative.")
    }
  }

  func testUnsolicitedBrowserCancellationReleasesCallbacksWithoutRecancel() throws {
    final class Token: @unchecked Sendable {}

    let controller = TestNWBrowserController()
    var driver: NWBrowserDiscoveryDriver? = NWBrowserDiscoveryDriver { _, _ in controller }
    var token: Token? = Token()
    weak let retainedToken = token
    try driver?.start(expectedInstanceName: "NearWire-7K3M") { [token] _ in
      _ = token
    }
    token = nil
    XCTAssertNotNil(retainedToken)
    controller.emit(.cancelled)
    XCTAssertNil(controller.stateUpdateHandler)
    XCTAssertNil(controller.browseResultsChangedHandler)
    XCTAssertNil(retainedToken)
    driver = nil
    XCTAssertEqual(controller.cancelCount, 0)
  }

  func testMatchedBrowserQuiescesCallbacksWithoutCancellingLifetime() throws {
    final class Token: @unchecked Sendable {}

    let controller = TestNWBrowserController()
    let driver = NWBrowserDiscoveryDriver { _, _ in controller }
    var token: Token? = Token()
    weak let retainedToken = token
    try driver.start(expectedInstanceName: "NearWire-7K3M") { [token] _ in
      _ = token
    }
    token = nil
    XCTAssertNotNil(retainedToken)

    driver.quiesceAfterMatch()
    driver.quiesceAfterMatch()
    XCTAssertNil(controller.stateUpdateHandler)
    XCTAssertNil(controller.browseResultsChangedHandler)
    XCTAssertNil(retainedToken)
    XCTAssertEqual(controller.cancelCount, 0)

    driver.cancel()
    XCTAssertEqual(controller.cancelCount, 1)
  }

  func testPolicyDenialClassificationDoesNotExposeUnderlyingError() {
    let denied = NWError.dns(Int32(kDNSServiceErr_PolicyDenied))
    if case .permissionOrPolicyDenied = NWBrowserDiscoveryDriver.waitingReason(for: denied) {
    } else {
      XCTFail("Expected policy-denied classification.")
    }
    if case .unavailableNetwork = NWBrowserDiscoveryDriver.waitingReason(
      for: .dns(Int32(kDNSServiceErr_NoSuchName))
    ) {
    } else {
      XCTFail("Expected generic waiting classification.")
    }
  }

  func testSafeDescriptionsNeverExposeAdvertisedText() throws {
    let error = ViewerDiscoveryError(.browserFailure)
    XCTAssertEqual(String(describing: error), "browserFailure")
    XCTAssertFalse(String(reflecting: error).contains("private-host"))

    let candidate = candidate()
    let viewer = DiscoveredViewer(identity: candidate.identity, endpoint: candidate.endpoint)
    for rendered in [
      viewer.description, viewer.debugDescription, String(describing: viewer),
      String(reflecting: viewer),
    ] {
      XCTAssertFalse(rendered.contains("NearWire-7K3M"))
      XCTAssertFalse(rendered.contains("b3a97f874aad08bf"))
    }
  }

  private func observation(
    _ name: String,
    vid: String?,
    interfaces: Int
  ) -> BonjourServiceObservation {
    BonjourServiceObservation(
      instanceName: name,
      type: NearWireBonjour.serviceType,
      domain: NearWireBonjour.localDomain,
      viewerDiscriminator: vid.flatMap(ViewerDiscoveryDiscriminator.init(rawValue:)),
      interfaceObservationCount: interfaces
    )
  }

  private func candidate() -> ViewerDiscoveryCandidate {
    let identity = NearWireBonjourServiceIdentity(
      instanceName: "NearWire-7K3M",
      type: NearWireBonjour.serviceType,
      domain: NearWireBonjour.localDomain,
      viewerDiscriminator: ViewerDiscoveryDiscriminator(rawValue: "b3a97f874aad08bf")!
    )!
    return ViewerDiscoveryCandidate(
      identity: identity,
      endpoint: .service(
        name: identity.instanceName,
        type: identity.type,
        domain: identity.domain,
        interface: nil
      )
    )
  }
}
