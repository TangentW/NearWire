import Combine
import Darwin
import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport
import SQLite3
import XCTest

@testable import NearWireViewer

final class ViewerStoreTests: XCTestCase {
  @MainActor
  func testExplorerControllerOwnsTraversalAcrossRefreshPaginationAndDetail() async throws {
    let runtimeLogicalID = UUID()
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let store = coordinator.services.eventStore
    let recording = try store.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "explorer-controller-traversal-test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "explorer-controller-traversal-test",
      logicalID: UUID(),
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      partialHistory: false,
      displayName: "Traversal Test"
    )
    let rowID = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "traversal"
      )
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "explorerControllerTraversalTest",
        count: 1,
        firstWallMilliseconds: 1,
        lastWallMilliseconds: 1,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      )
    )

    let executionGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { executionGate.run() })
    gateway.install(coordinator)
    let detailRequests = LockedCounter()
    let live = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: live
      ),
      contentDriver: ViewerExplorerContentDriver(
        gateway: gateway,
        loadDetail: { requestedRowID, completion in
          detailRequests.increment()
          return gateway.loadDetail(rowID: requestedRowID, completion: completion)
        }
      )
    )
    controller.start()
    await waitUntilExplorerController {
      if case .ready = controller.traversalState {
        return controller.timelineRows.contains { $0.id == .durable(rowID: rowID) }
          && controller.hasOlderEvents && controller.hasOlderGaps
      }
      return false
    }

    executionGate.arm()
    _ = controller.coordinator.refresh()
    let releaseBlocked = await executionGate.waitUntilBlockedAsync()
    XCTAssertEqual(releaseBlocked, .success)
    XCTAssertEqual(controller.traversalState, .releasing(.refresh))
    controller.loadOlderEvents()
    controller.loadOlderEvents()
    controller.loadOlderGaps()
    controller.loadOlderGaps()
    controller.revealExactEvent(.durable(rowID: rowID))
    XCTAssertEqual(controller.eventPageRequestCountForTesting, 0)
    XCTAssertEqual(controller.gapPageRequestCountForTesting, 0)
    XCTAssertEqual(detailRequests.value, 0)

    executionGate.release()
    executionGate.arm()
    let replacementBlocked = await executionGate.waitUntilBlockedAsync()
    XCTAssertEqual(replacementBlocked, .success)
    XCTAssertEqual(controller.traversalState, .loading(.refresh))
    controller.loadOlderEvents()
    controller.loadOlderGaps()
    XCTAssertEqual(controller.eventPageRequestCountForTesting, 0)
    XCTAssertEqual(controller.gapPageRequestCountForTesting, 0)
    XCTAssertEqual(detailRequests.value, 0)

    executionGate.release()
    await waitUntilExplorerController {
      if case .ready = controller.traversalState {
        return detailRequests.value == 1 && controller.selectedEventID == .durable(rowID: rowID)
      }
      return false
    }
    XCTAssertEqual(detailRequests.value, 1)

    controller.loadOlderEvents()
    controller.loadOlderEvents()
    controller.loadOlderGaps()
    controller.loadOlderGaps()
    XCTAssertEqual(controller.eventPageRequestCountForTesting, 1)
    XCTAssertEqual(controller.gapPageRequestCountForTesting, 1)

    await waitUntilExplorerController { controller.pendingCleanupWorkCount == 0 }
    executionGate.arm()
    _ = controller.coordinator.refresh()
    let absentRefreshBlocked = await executionGate.waitUntilBlockedAsync()
    XCTAssertEqual(absentRefreshBlocked, .success)
    let absentIdentity = ViewerExplorerEventIdentity.durable(rowID: Int64.max)
    controller.revealExactEvent(absentIdentity)
    XCTAssertEqual(controller.pendingExactRevealIdentityForTesting, absentIdentity)
    executionGate.release()
    await waitUntilExplorerController {
      controller.traversalState.ownsQueryableTraversal
        && controller.pendingExactRevealIdentityForTesting == nil
    }
    XCTAssertEqual(detailRequests.value, 1)
    XCTAssertNil(controller.selectedEventID)

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  func testPerformanceRawEventLocatorRequiresExactSourceKeyAndReleasedTraversal() throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    defer { coordinator.closeStorage() }
    let services = coordinator.services
    let recordingLogicalID = UUID()
    let deviceLogicalID = UUID()
    let recording = try services.eventStore.beginRecording(
      logicalID: recordingLogicalID,
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "performance-raw-event-locator-test"
    )
    let device = try services.eventStore.beginDeviceSession(
      recording: recording,
      installationID: "performance-raw-event-locator-test",
      logicalID: deviceLogicalID,
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      partialHistory: false,
      displayName: "Performance Raw Event Locator Test"
    )
    let rowID = try services.eventStore.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 7,
        value: "performance",
        eventType: try PerformanceSnapshotSchema.eventType()
      )
    )
    _ = try services.eventStore.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 8,
        value: "ordinary"
      )
    )
    let key = ViewerEventJournalKey(
      runtimeLogicalID: recordingLogicalID,
      connectionID: deviceLogicalID,
      direction: .appToViewer,
      wireSequence: 7
    )

    XCTAssertEqual(
      try services.performance.resolveEventLocator(
        recordingID: recording.rowID,
        deviceSessionID: device.rowID,
        key: key
      ),
      .durable(rowID: rowID, deviceSessionID: device.rowID)
    )
    XCTAssertNil(
      try services.performance.resolveEventLocator(
        recordingID: recording.rowID,
        deviceSessionID: device.rowID,
        key: ViewerEventJournalKey(
          runtimeLogicalID: recordingLogicalID,
          connectionID: deviceLogicalID,
          direction: .viewerToApp,
          wireSequence: 7
        )
      )
    )
    XCTAssertNil(
      try services.performance.resolveEventLocator(
        recordingID: recording.rowID,
        deviceSessionID: device.rowID,
        key: ViewerEventJournalKey(
          runtimeLogicalID: UUID(),
          connectionID: deviceLogicalID,
          direction: .appToViewer,
          wireSequence: 7
        )
      )
    )
    XCTAssertNil(
      try services.performance.resolveEventLocator(
        recordingID: recording.rowID,
        deviceSessionID: device.rowID,
        key: ViewerEventJournalKey(
          runtimeLogicalID: recordingLogicalID,
          connectionID: deviceLogicalID,
          direction: .appToViewer,
          wireSequence: 8
        )
      )
    )

    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let _: ViewerPerformanceStoreScope = try explorerValue(
      "Begin traversal before raw Event resolution"
    ) { completion in
      gateway.beginPerformanceTraversal(
        recordingID: recording.rowID,
        deviceSessionID: device.rowID,
        lowerMonotonicNanoseconds: 0,
        upperMonotonicNanoseconds: 100_000,
        completion: completion
      )
    }
    let busy: Result<ViewerPerformanceEventLocator?, ViewerStoreExplorerFailure> =
      try explorerResult("Reject raw Event resolution during traversal") { completion in
        gateway.resolvePerformanceEventLocator(
          recordingID: recording.rowID,
          deviceSessionID: device.rowID,
          key: key,
          completion: completion
        )
      }
    XCTAssertEqual(busy, .failure(.busy))
    let _: Void = try explorerValue("Release traversal before raw Event resolution") {
      gateway.endTraversal(completion: $0)
    }
    let resolvedAfterRelease: ViewerPerformanceEventLocator? = try explorerValue(
      "Resolve raw Event after traversal release"
    ) { completion in
      gateway.resolvePerformanceEventLocator(
        recordingID: recording.rowID,
        deviceSessionID: device.rowID,
        key: key,
        completion: completion
      )
    }
    XCTAssertEqual(
      resolvedAfterRelease,
      .durable(rowID: rowID, deviceSessionID: device.rowID)
    )

    gateway.sealAndWait(originatingFrom: coordinator)
    try services.eventStore.appendStructural(
      .closeDevice(device, wallMilliseconds: 2, monotonicNanoseconds: 2)
    )
    try services.eventStore.appendStructural(
      .closeRecording(recording, wallMilliseconds: 3, monotonicNanoseconds: 3)
    )
    let confirmation = try services.maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    try services.maintenance.requestDelete(confirmation, wallMilliseconds: 4)
    XCTAssertNil(
      try services.performance.resolveEventLocator(
        recordingID: recording.rowID,
        deviceSessionID: device.rowID,
        key: key
      )
    )
  }

  func testPerformanceCandidateScanAdvancesAcrossResidualNonmatches() throws {
    let fixture = try makePerformanceFixture(
      eventCount: 4_098,
      eventTypeSQL:
        "CASE WHEN value=4097 THEN '\(PerformanceSnapshotSchema.eventTypeRawValue)' ELSE 'fixture.ordinary' END",
      contentSQL: "CAST('{}' AS BLOB)"
    )
    defer { fixture.pool.close() }
    let service = ViewerPerformanceStoreService(
      pool: fixture.pool,
      clock: ViewerPerformanceTurnClock(read: { 0 })
    )

    let first = try service.eventPage(scope: fixture.scope)
    XCTAssertTrue(first.events.isEmpty)
    XCTAssertEqual(
      first.examinedCandidateCount,
      ViewerPerformanceLimits.maximumExaminedEvents
    )
    XCTAssertFalse(first.isComplete)
    XCTAssertEqual(first.continuation?.lastExaminedMonotonicNanoseconds, 4_096)

    let second = try service.eventPage(
      scope: fixture.scope,
      continuation: try XCTUnwrap(first.continuation)
    )
    XCTAssertEqual(second.examinedCandidateCount, 2)
    XCTAssertEqual(second.events.count, 1)
    XCTAssertEqual(second.events.first?.viewerMonotonicNanoseconds, 4_098)
    XCTAssertTrue(second.isComplete)
    XCTAssertNil(second.continuation)
  }

  func testPerformanceResidualNonmatchBoundariesReturnDeterministicEmptyContinuations() throws {
    for count in [4_095, 4_096, 4_097] {
      let fixture = try makePerformanceFixture(
        eventCount: count,
        eventTypeSQL: "'fixture.ordinary'",
        contentSQL: "CAST('{}' AS BLOB)"
      )
      defer { fixture.pool.close() }
      let service = ViewerPerformanceStoreService(
        pool: fixture.pool,
        clock: ViewerPerformanceTurnClock(read: { 0 })
      )

      let first = try service.eventPage(scope: fixture.scope)
      XCTAssertTrue(first.events.isEmpty, "count \(count)")
      XCTAssertEqual(
        first.examinedCandidateCount,
        min(count, ViewerPerformanceLimits.maximumExaminedEvents),
        "count \(count)"
      )
      if count < ViewerPerformanceLimits.maximumExaminedEvents {
        XCTAssertTrue(first.isComplete, "count \(count)")
        XCTAssertNil(first.continuation, "count \(count)")
      } else {
        XCTAssertFalse(first.isComplete, "count \(count)")
        let second = try service.eventPage(
          scope: fixture.scope,
          continuation: try XCTUnwrap(first.continuation)
        )
        XCTAssertTrue(second.events.isEmpty, "count \(count)")
        XCTAssertEqual(
          second.examinedCandidateCount,
          count - ViewerPerformanceLimits.maximumExaminedEvents,
          "count \(count)"
        )
        XCTAssertTrue(second.isComplete, "count \(count)")
        XCTAssertNil(second.continuation, "count \(count)")
      }
    }
  }

  func testPerformanceCandidateScanCapsEmittedCarriersWithoutSkipping() throws {
    for count in [511, 512, 513] {
      let fixture = try makePerformanceFixture(
        eventCount: count,
        eventTypeSQL: "'\(PerformanceSnapshotSchema.eventTypeRawValue)'",
        contentSQL: "CAST('{}' AS BLOB)"
      )
      defer { fixture.pool.close() }
      let service = ViewerPerformanceStoreService(
        pool: fixture.pool,
        clock: ViewerPerformanceTurnClock(read: { 0 })
      )

      let first = try service.eventPage(scope: fixture.scope)
      XCTAssertEqual(
        first.events.count,
        min(count, ViewerPerformanceLimits.maximumEmittedEvents),
        "count \(count)"
      )
      XCTAssertEqual(first.examinedCandidateCount, first.events.count, "count \(count)")
      if count < ViewerPerformanceLimits.maximumEmittedEvents {
        XCTAssertTrue(first.isComplete, "count \(count)")
        XCTAssertNil(first.continuation, "count \(count)")
      } else {
        XCTAssertFalse(first.isComplete, "count \(count)")
        let second = try service.eventPage(
          scope: fixture.scope,
          continuation: try XCTUnwrap(first.continuation)
        )
        XCTAssertEqual(
          second.events.count,
          count - ViewerPerformanceLimits.maximumEmittedEvents,
          "count \(count)"
        )
        XCTAssertEqual(second.examinedCandidateCount, second.events.count, "count \(count)")
        if count == 513 {
          XCTAssertEqual(second.events.first?.key.wireSequence, 512)
        } else {
          XCTAssertNil(second.events.first)
        }
        XCTAssertTrue(second.isComplete, "count \(count)")
        XCTAssertNil(second.continuation, "count \(count)")
      }
    }
  }

  func testPerformanceContinuationOrdersEqualMonotonicTiesByRowID() throws {
    let fixture = try makePerformanceFixture(
      eventCount: 513,
      eventTypeSQL: "'\(PerformanceSnapshotSchema.eventTypeRawValue)'",
      contentSQL: "CAST('{}' AS BLOB)"
    )
    defer { fixture.pool.close() }
    try fixture.pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Events SET viewerMonotonicNs=1",
        on: database
      )
    }
    let service = ViewerPerformanceStoreService(
      pool: fixture.pool,
      clock: ViewerPerformanceTurnClock(read: { 0 })
    )

    let first = try service.eventPage(scope: fixture.scope)
    XCTAssertEqual(first.events.map(\.key.wireSequence), Array(0..<512).map { UInt64($0) })
    XCTAssertEqual(first.continuation?.lastExaminedMonotonicNanoseconds, 1)
    let second = try service.eventPage(
      scope: fixture.scope,
      continuation: try XCTUnwrap(first.continuation)
    )
    XCTAssertEqual(second.events.map(\.key.wireSequence), [512])
    XCTAssertTrue(second.isComplete)
  }

  func testPerformanceCandidateScanRetriesAggregateByteBoundaryAndMarksOversized() throws {
    let fixture = try makePerformanceFixture(
      eventCount: 66,
      eventTypeSQL: "'\(PerformanceSnapshotSchema.eventTypeRawValue)'",
      contentSQL:
        "CASE WHEN value=65 THEN zeroblob(65537) ELSE zeroblob(65536) END"
    )
    defer { fixture.pool.close() }
    let service = ViewerPerformanceStoreService(
      pool: fixture.pool,
      clock: ViewerPerformanceTurnClock(read: { 0 })
    )

    let first = try service.eventPage(scope: fixture.scope)
    XCTAssertEqual(first.events.count, 64)
    XCTAssertEqual(first.examinedCandidateCount, 64)
    XCTAssertEqual(
      first.copiedContentBytes,
      ViewerPerformanceLimits.maximumCopiedContentBytes
    )
    XCTAssertFalse(first.isComplete)

    let second = try service.eventPage(
      scope: fixture.scope,
      continuation: try XCTUnwrap(first.continuation)
    )
    XCTAssertEqual(second.events.count, 2)
    XCTAssertEqual(second.examinedCandidateCount, 2)
    XCTAssertEqual(second.events[0].content.copiedByteCount, 65_536)
    XCTAssertEqual(second.events[1].content, .oversized(byteCount: 65_537))
    XCTAssertTrue(second.isComplete)
  }

  func testPerformanceCandidateScanUsesInjectedEqualityAndTerminalNoProgress() throws {
    let fixture = try makePerformanceFixture(
      eventCount: 1,
      eventTypeSQL: "'\(PerformanceSnapshotSchema.eventTypeRawValue)'",
      contentSQL: "CAST('{}' AS BLOB)"
    )
    defer { fixture.pool.close() }

    let equalityClock = ViewerPerformanceTestClock([0, 0, 50_000_000])
    let equalityService = ViewerPerformanceStoreService(
      pool: fixture.pool,
      clock: ViewerPerformanceTurnClock(read: { equalityClock.now() })
    )
    let equalityPage = try equalityService.eventPage(scope: fixture.scope)
    XCTAssertEqual(equalityPage.events.count, 1)
    XCTAssertEqual(equalityPage.examinedCandidateCount, 1)
    XCTAssertFalse(equalityPage.isComplete)

    let belowClock = ViewerPerformanceTestClock([0, 0, 49_999_999, 49_999_999])
    let belowService = ViewerPerformanceStoreService(
      pool: fixture.pool,
      clock: ViewerPerformanceTurnClock(read: { belowClock.now() })
    )
    let belowPage = try belowService.eventPage(scope: fixture.scope)
    XCTAssertEqual(belowPage.events.count, 1)
    XCTAssertTrue(belowPage.isComplete)

    let noProgressClock = ViewerPerformanceTestClock([0, 50_000_000])
    let noProgressService = ViewerPerformanceStoreService(
      pool: fixture.pool,
      clock: ViewerPerformanceTurnClock(read: { noProgressClock.now() })
    )
    XCTAssertThrowsError(try noProgressService.eventPage(scope: fixture.scope)) {
      XCTAssertEqual($0 as? ViewerPerformanceStoreFailure, .workLimitExceeded)
    }

    let exceededClock = ViewerPerformanceTestClock([0, 50_000_001])
    let exceededService = ViewerPerformanceStoreService(
      pool: fixture.pool,
      clock: ViewerPerformanceTurnClock(read: { exceededClock.now() })
    )
    XCTAssertThrowsError(try exceededService.eventPage(scope: fixture.scope)) {
      XCTAssertEqual($0 as? ViewerPerformanceStoreFailure, .workLimitExceeded)
    }

    let sqliteBudget = ViewerSQLiteBudget.performance()
    XCTAssertEqual(sqliteBudget.maximumVirtualMachineSteps, 5_000_000)
    XCTAssertNil(sqliteBudget.deadline)
  }

  func testPerformanceGatewayFreezesEventUpperAndMapsClosedGapMetadata() throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let store = coordinator.services.eventStore
    let recording = try store.beginRecording(
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "performance-gateway-test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "performance-gateway-test",
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      partialHistory: false,
      displayName: "Performance Gateway Test"
    )
    let performanceType = try PerformanceSnapshotSchema.eventType()
    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "first",
        eventType: performanceType
      )
    )
    let gapInputs: [(String, String, Int64)] = [
      ("missingInitialEvent.expired", "appToViewer", 1),
      ("storageUnavailable", "both", 2),
      ("uplinkDispositionOverflow", "viewerToApp", 3),
      ("deviceCloseFailed", "unknown", 4),
      ("coalescedOverflow", "viewerToApp", 5),
      ("unrecognizedReason", "both", 6),
    ]
    for (index, input) in gapInputs.enumerated() {
      try store.appendStructural(
        .gap(
          recording: recording,
          device: device,
          sequence: UInt64(index + 1),
          reason: input.0,
          count: input.2,
          firstWallMilliseconds: Int64(index + 10),
          lastWallMilliseconds: Int64(index + 10),
          directions: input.1,
          firstWireSequence: nil,
          lastWireSequence: nil
        )
      )
    }

    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let scope: ViewerPerformanceStoreScope = try explorerValue(
      "Begin performance traversal"
    ) { completion in
      gateway.beginPerformanceTraversal(
        recordingID: recording.rowID,
        deviceSessionID: device.rowID,
        lowerMonotonicNanoseconds: 0,
        upperMonotonicNanoseconds: 10_000,
        completion: completion
      )
    }
    XCTAssertGreaterThan(scope.storeGeneration, 0)

    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 2,
        value: "after-freeze",
        eventType: performanceType
      )
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 7,
        reason: "storeAfterFreeze",
        count: 7,
        firstWallMilliseconds: 20,
        lastWallMilliseconds: 20,
        directions: "appToViewer",
        firstWireSequence: nil,
        lastWireSequence: nil
      )
    )

    let eventPage: ViewerPerformanceEventPage = try explorerValue(
      "Load frozen performance Events"
    ) { completion in
      gateway.loadPerformanceEventPage(continuation: nil, completion: completion)
    }
    XCTAssertTrue(eventPage.isComplete)
    XCTAssertEqual(eventPage.events.map(\.key.wireSequence), [1])

    let gapPage: ViewerPerformanceGapPage = try explorerValue(
      "Load frozen performance gaps"
    ) { completion in
      gateway.loadPerformanceGapPage(completion: completion)
    }
    XCTAssertEqual(
      gapPage.gaps.map(\.kind),
      [
        .eventLoss, .storageContinuity, .controlContinuity, .lifecycleContinuity,
        .unknown, .unknown,
      ]
    )
    XCTAssertEqual(
      gapPage.gaps.map(\.applicability),
      [.performance, .performance, .irrelevant, .uncertain, .irrelevant, .performance]
    )
    XCTAssertEqual(gapPage.applicableOrUncertainCount, 13)
    XCTAssertFalse(gapPage.hasMoreRows)
    XCTAssertFalse(gapPage.hasMoreApplicableGaps)
    XCTAssertFalse(String(reflecting: gapPage).contains("unrecognizedReason"))
    XCTAssertFalse(String(reflecting: gapPage).contains("appToViewer"))

    let _: Void = try explorerValue("End performance traversal") { completion in
      gateway.endTraversal(completion: completion)
    }
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  func testPerformanceCurrentFreezeUsesLiveAnchorBeforeStoreUppers() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    defer { coordinator.closeStorage() }
    let store = coordinator.services.eventStore
    let recording = try store.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "performance-live-first-test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "performance-live-first-test",
      logicalID: connectionID,
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      partialHistory: false,
      displayName: "Performance Live First Test"
    )
    let performanceType = try PerformanceSnapshotSchema.eventType()
    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "before-freeze",
        viewerMonotonicNanoseconds: 4_000,
        eventType: performanceType
      )
    )
    let liveSlice = try ViewerPerformanceLiveSlice(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      liveGeneration: 7,
      revision: 11,
      anchorMonotonicNanoseconds: 5_000,
      events: [],
      gaps: [],
      applicableOrUncertainCount: 0,
      hasMoreApplicableGaps: false
    )
    let live = ViewerPerformanceFreezeLiveSpy(slice: liveSlice)
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let freezer = ViewerPerformanceFreezeCoordinator(
      live: live,
      storeGateway: gateway
    )
    let result = LockedPerformanceFreezeResult()
    let finished = expectation(description: "Freeze live before Store uppers")
    let token = freezer.freezeCurrent(
      connectionID: connectionID,
      recordingID: recording.rowID,
      deviceSessionID: device.rowID,
      lowerMonotonicNanoseconds: 0
    ) {
      result.set($0)
      finished.fulfill()
    }
    XCTAssertNotNil(token)
    wait(for: [finished], timeout: 2)
    let receipt = try XCTUnwrap(result.value).get()
    XCTAssertEqual(live.frozenConnectionIDs, [connectionID])
    XCTAssertEqual(receipt.liveSlice, liveSlice)
    XCTAssertEqual(receipt.storeScope?.upperMonotonicNanoseconds, 5_000)
    XCTAssertEqual(
      receipt.source,
      .current(runtimeLogicalID: runtimeLogicalID, connectionID: connectionID)
    )

    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 2,
        value: "after-freeze",
        viewerMonotonicNanoseconds: 4_500,
        eventType: performanceType
      )
    )
    let page: ViewerPerformanceEventPage = try explorerValue(
      "Load live-first frozen performance Events"
    ) { completion in
      gateway.loadPerformanceEventPage(continuation: nil, completion: completion)
    }
    XCTAssertEqual(page.events.map(\.key.wireSequence), [1])
    XCTAssertTrue(page.isComplete)
  }

  func testPerformanceFreezeReconcilesBeforeDuringAndAfterStoreUpperCommitsExactlyOnce()
    throws
  {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    defer { coordinator.closeStorage() }
    let store = coordinator.services.eventStore
    let recording = try store.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "performance-freeze-commit-permutations"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "performance-freeze-commit-permutations",
      logicalID: connectionID,
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      partialHistory: false,
      displayName: "Performance Freeze Commit Permutations"
    )
    let performanceType = try PerformanceSnapshotSchema.eventType()
    let content = JSONValue.object([
      "schemaVersion": .integer(1),
      "sampledAt": .string("2026-07-14T01:02:03Z"),
      "sampleIntervalMilliseconds": .integer(1_000),
      "process": .object(["cpuPercent": .integer(42)]),
    ])
    let beforeFreeze = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "before-freeze",
      viewerMonotonicNanoseconds: 4_000,
      viewerWallMilliseconds: 4_000,
      eventType: performanceType,
      content: content
    )
    let duringBarrier = try makeObservation(
      recording: recording,
      device: device,
      sequence: 2,
      value: "during-live-store-barrier",
      viewerMonotonicNanoseconds: 4_500,
      viewerWallMilliseconds: 4_500,
      eventType: performanceType,
      content: content
    )
    let afterAnchor = try makeObservation(
      recording: recording,
      device: device,
      sequence: 3,
      value: "after-anchor",
      viewerMonotonicNanoseconds: 5_500,
      viewerWallMilliseconds: 5_500,
      eventType: performanceType,
      content: content
    )
    let afterStoreUpper = try makeObservation(
      recording: recording,
      device: device,
      sequence: 4,
      value: "after-store-upper",
      viewerMonotonicNanoseconds: 4_800,
      viewerWallMilliseconds: 4_800,
      eventType: performanceType,
      content: content
    )
    _ = try store.appendEvent(beforeFreeze)

    func liveCarrier(
      _ observation: ViewerPreparedEventObservation,
      observationID: UUID
    ) throws -> ViewerPerformanceEventCarrier {
      try ViewerPerformanceEventCarrier(
        locator: .transient(observationID: observationID),
        key: ViewerEventJournalKey(
          runtimeLogicalID: runtimeLogicalID,
          connectionID: connectionID,
          direction: .appToViewer,
          wireSequence: observation.envelope.sequence.rawValue
        ),
        viewerWallMilliseconds: observation.viewerWallMilliseconds,
        viewerMonotonicNanoseconds: Int64(observation.viewerMonotonicNanoseconds),
        content: .canonical(observation.canonicalContent)
      )
    }

    let liveSlice = try ViewerPerformanceLiveSlice(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      liveGeneration: 7,
      revision: 11,
      anchorMonotonicNanoseconds: 5_000,
      events: [
        try liveCarrier(beforeFreeze, observationID: UUID()),
        try liveCarrier(duringBarrier, observationID: UUID()),
      ],
      gaps: [],
      applicableOrUncertainCount: 0,
      hasMoreApplicableGaps: false
    )
    let live = ViewerPerformanceFreezeLiveSpy(slice: liveSlice) {
      _ = try store.appendEvent(duringBarrier)
      _ = try store.appendEvent(afterAnchor)
    }
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let freezer = ViewerPerformanceFreezeCoordinator(live: live, storeGateway: gateway)
    let result = LockedPerformanceFreezeResult()
    let finished = expectation(description: "Freeze across the live/Store commit barrier")
    XCTAssertNotNil(
      freezer.freezeCurrent(
        connectionID: connectionID,
        recordingID: recording.rowID,
        deviceSessionID: device.rowID,
        lowerMonotonicNanoseconds: 0
      ) {
        result.set($0)
        finished.fulfill()
      }
    )
    wait(for: [finished], timeout: 2)
    let receipt = try XCTUnwrap(result.value).get()
    XCTAssertEqual(receipt.storeScope?.upperMonotonicNanoseconds, 5_000)

    _ = try store.appendEvent(afterStoreUpper)
    let page: ViewerPerformanceEventPage = try explorerValue(
      "Load commit-permutation performance Events"
    ) { completion in
      gateway.loadPerformanceEventPage(continuation: nil, completion: completion)
    }
    XCTAssertEqual(page.events.map(\.key.wireSequence), [1, 2])
    XCTAssertTrue(
      page.events.allSatisfy {
        if case .durable = $0.locator { return true }
        return false
      }
    )
    XCTAssertTrue(page.isComplete)
    let gapPage: ViewerPerformanceGapPage = try explorerValue(
      "Load commit-permutation performance gaps"
    ) { completion in
      gateway.loadPerformanceGapPage(completion: completion)
    }

    var session = try ViewerPerformanceProjectionSession(
      receipt: receipt,
      rangeKind: .currentSession,
      bounds: ViewerPerformanceRangeBounds(
        lowerMonotonicNanoseconds: 0,
        upperMonotonicNanoseconds: 5_000
      ),
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: 1
    )
    try session.accept(eventPage: page)
    XCTAssertEqual(session.retainedRawEventCount, 4)
    while case .processed = try session.runDecodeTurn() {}
    try session.accept(gapPage: gapPage)
    let publication = try session.finalize(
      sourceGeneration: 1,
      deadlineRevision: 1,
      currentUptimeNanoseconds: 5_000
    )
    XCTAssertEqual(publication.decodedEventCount, 2)
    XCTAssertEqual(publication.cards.latestEventKey?.wireSequence, 2)
    XCTAssertEqual(
      publication.result.availability.first(where: { $0.key == .processCPUPercent })?.counts
        .measured,
      2
    )

    let _: Void = try explorerValue("End commit-permutation traversal") { completion in
      gateway.endTraversal(completion: completion)
    }
    gateway.sealAndWait(originatingFrom: coordinator)
  }

  func testPerformanceGapClassificationSeparatesGenericAndApplicableOverflow() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "performance-gap-classification-test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "performance-gap-classification-test",
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      partialHistory: false,
      displayName: "Performance Gap Classification Test"
    )
    for sequence in 1...129 {
      try store.appendStructural(
        .gap(
          recording: recording,
          device: device,
          sequence: UInt64(sequence),
          reason: "coalescedOverflow",
          count: 1,
          firstWallMilliseconds: Int64(sequence),
          lastWallMilliseconds: Int64(sequence),
          directions: "viewerToApp",
          firstWireSequence: nil,
          lastWireSequence: nil
        )
      )
    }
    let leases = ViewerStoreLeaseRegistry()
    let service = ViewerPerformanceStoreService(pool: pool, leases: leases)
    let firstTraversal = try service.begin(
      storeGeneration: 1,
      recordingID: recording.rowID,
      deviceSessionID: device.rowID,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 100
    )
    XCTAssertEqual(leases.queryLeaseCountForTesting, 1)
    let (irrelevantTail, refreshedFirstTraversal) = try service.gapPage(
      traversal: firstTraversal
    )
    XCTAssertEqual(irrelevantTail.gaps.count, 32)
    XCTAssertTrue(irrelevantTail.hasMoreRows)
    XCTAssertEqual(irrelevantTail.applicableOrUncertainCount, 0)
    XCTAssertFalse(irrelevantTail.hasMoreApplicableGaps)
    XCTAssertEqual(leases.queryLeaseCountForTesting, 1)
    var completeFirstTraversal = refreshedFirstTraversal
    var classifiedPageCount = 1
    var classifiedRowCount = irrelevantTail.gaps.count
    var hasMoreRows = irrelevantTail.hasMoreRows
    while hasMoreRows {
      let (page, refreshed) = try service.gapPage(traversal: completeFirstTraversal)
      completeFirstTraversal = refreshed
      classifiedPageCount += 1
      classifiedRowCount += page.gaps.count
      hasMoreRows = page.hasMoreRows
      XCTAssertEqual(page.applicableOrUncertainCount, 0)
      XCTAssertFalse(page.hasMoreApplicableGaps)
    }
    XCTAssertEqual(classifiedPageCount, 5)
    XCTAssertEqual(classifiedRowCount, 129)
    XCTAssertEqual(service.classificationInvocationCountForTesting, 1)
    service.end(completeFirstTraversal)
    XCTAssertEqual(leases.queryLeaseCountForTesting, 0)

    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 129,
        reason: "coalescedOverflow",
        count: 2,
        firstWallMilliseconds: 129,
        lastWallMilliseconds: 129,
        directions: "appToViewer",
        firstWireSequence: nil,
        lastWireSequence: nil
      )
    )
    let applicableTraversal = try service.begin(
      storeGeneration: 1,
      recordingID: recording.rowID,
      deviceSessionID: device.rowID,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 100
    )
    let (applicableTail, refreshedApplicableTraversal) = try service.gapPage(
      traversal: applicableTraversal
    )
    XCTAssertTrue(applicableTail.hasMoreRows)
    XCTAssertEqual(applicableTail.applicableOrUncertainCount, 2)
    XCTAssertTrue(applicableTail.hasMoreApplicableGaps)
    XCTAssertEqual(service.classificationInvocationCountForTesting, 2)
    service.end(refreshedApplicableTraversal)

    let exhaustedClock = ViewerPerformanceTestClock([0, 250_000_000])
    let conservativeService = ViewerPerformanceStoreService(
      pool: pool,
      leases: leases,
      clock: ViewerPerformanceTurnClock(read: { exhaustedClock.now() })
    )
    let exhaustedTraversal = try conservativeService.begin(
      storeGeneration: 1,
      recordingID: recording.rowID,
      deviceSessionID: device.rowID,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 100
    )
    let (conservativePage, refreshedExhaustedTraversal) = try conservativeService.gapPage(
      traversal: exhaustedTraversal
    )
    XCTAssertTrue(conservativePage.hasMoreApplicableGaps)
    conservativeService.end(refreshedExhaustedTraversal)
    XCTAssertEqual(leases.queryLeaseCountForTesting, 0)

    let classificationBudget = ViewerSQLiteBudget.performanceClassification()
    XCTAssertEqual(classificationBudget.maximumVirtualMachineSteps, 2_000_000)
    XCTAssertNil(classificationBudget.deadline)
  }

  func testPerformanceGatewayCancellationAfterPageCandidateReleasesTraversal() throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let store = coordinator.services.eventStore
    let recording = try store.beginRecording(
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "performance-cancellation-test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "performance-cancellation-test",
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      partialHistory: false,
      displayName: "Performance Cancellation Test"
    )
    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "cancelled-candidate",
        eventType: try PerformanceSnapshotSchema.eventType()
      )
    )
    let completionGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway(
      operationCompletionGate: { completionGate.run() }
    )
    gateway.install(coordinator)
    let _: ViewerPerformanceStoreScope = try explorerValue(
      "Begin cancellable performance traversal"
    ) { completion in
      gateway.beginPerformanceTraversal(
        recordingID: recording.rowID,
        deviceSessionID: device.rowID,
        lowerMonotonicNanoseconds: 0,
        upperMonotonicNanoseconds: 100,
        completion: completion
      )
    }
    XCTAssertEqual(coordinator.services.performance.activeLeaseCountForTesting, 1)

    completionGate.arm()
    let result = LockedViewerExplorerResult<ViewerPerformanceEventPage>()
    let finished = expectation(description: "Cancelled performance page completed")
    let token = gateway.loadPerformanceEventPage(continuation: nil) {
      result.set($0)
      finished.fulfill()
    }
    XCTAssertEqual(completionGate.waitUntilBlocked(), .success)
    gateway.cancel(token)
    completionGate.release()
    wait(for: [finished], timeout: 2)

    guard case .failure(let failure) = try XCTUnwrap(result.value) else {
      return XCTFail("Cancelled candidate must not be delivered.")
    }
    XCTAssertEqual(failure, .cancelled)
    XCTAssertEqual(coordinator.services.performance.activeLeaseCountForTesting, 0)
    XCTAssertEqual(coordinator.services.query.cancelledOperationCountForTesting, 0)
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  func testPerformanceCarriersAndPagesEnforceExactAccountingAndRedaction() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let scope = try ViewerPerformanceStoreScope(
      storeGeneration: 1,
      recordingID: 1,
      deviceSessionID: 2,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 10_000,
      eventUpperRowID: 1_000,
      gapUpperRowID: 2_000
    )
    let makeCarrier:
      (Int, ViewerPerformanceEventContent) throws ->
        ViewerPerformanceEventCarrier = { index, content in
          try ViewerPerformanceEventCarrier(
            locator: .durable(rowID: Int64(index + 1), deviceSessionID: 2),
            key: ViewerEventJournalKey(
              runtimeLogicalID: runtimeLogicalID,
              connectionID: connectionID,
              direction: .appToViewer,
              wireSequence: UInt64(index)
            ),
            viewerWallMilliseconds: Int64(index),
            viewerMonotonicNanoseconds: Int64(index),
            content: content
          )
        }

    let exact = try makeCarrier(
      0,
      .canonical(Data(repeating: 7, count: ViewerPerformanceLimits.maximumRowContentBytes))
    )
    XCTAssertEqual(
      exact.accountedBytes,
      ViewerPerformanceLimits.eventCarrierBytes
        + ViewerPerformanceLimits.maximumRowContentBytes
    )
    XCTAssertThrowsError(
      try makeCarrier(
        1,
        .canonical(
          Data(repeating: 7, count: ViewerPerformanceLimits.maximumRowContentBytes + 1)
        )
      )
    )
    XCTAssertThrowsError(
      try makeCarrier(
        1,
        .oversized(byteCount: Int64(ViewerPerformanceLimits.maximumRowContentBytes))
      )
    )

    var events: [ViewerPerformanceEventCarrier] = []
    events.reserveCapacity(ViewerPerformanceLimits.maximumEmittedEvents)
    for index in 0..<ViewerPerformanceLimits.maximumEmittedEvents {
      let content: ViewerPerformanceEventContent =
        index < 64
        ? .canonical(
          Data(repeating: UInt8(index), count: ViewerPerformanceLimits.maximumRowContentBytes)
        )
        : .oversized(byteCount: Int64(ViewerPerformanceLimits.maximumRowContentBytes + 1))
      events.append(try makeCarrier(index, content))
    }
    let page = try ViewerPerformanceEventPage(
      scope: scope,
      events: events,
      examinedCandidateCount: ViewerPerformanceLimits.maximumExaminedEvents,
      continuation: nil,
      isComplete: true
    )
    XCTAssertEqual(page.copiedContentBytes, ViewerPerformanceLimits.maximumCopiedContentBytes)
    XCTAssertEqual(page.accountedBytes, ViewerPerformanceLimits.maximumEventPageBytes)

    let oneMoreCopied = try makeCarrier(
      ViewerPerformanceLimits.maximumEmittedEvents,
      .canonical(Data([1]))
    )
    var excessiveCopy = Array(events.dropLast())
    excessiveCopy.append(oneMoreCopied)
    XCTAssertThrowsError(
      try ViewerPerformanceEventPage(
        scope: scope,
        events: excessiveCopy,
        examinedCandidateCount: excessiveCopy.count,
        continuation: nil,
        isComplete: true
      )
    )

    let marker = "performance-content-must-not-reflect"
    let redacted = try makeCarrier(
      1,
      .canonical(Data(marker.utf8))
    )
    XCTAssertFalse(String(reflecting: redacted).contains(marker))
    XCTAssertFalse(String(describing: redacted.customMirror).contains(marker))
  }

  func testPerformanceGapPageAndLiveSliceReachExactCaps() throws {
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let makeGap: (Int) throws -> ViewerPerformanceGapCarrier = { index in
      try ViewerPerformanceGapCarrier(
        rowID: index < 32 ? Int64(index + 1) : nil,
        recordingID: index < 32 ? 1 : nil,
        deviceSessionID: index < 32 ? 2 : nil,
        count: 1,
        firstViewerWallMilliseconds: nil,
        lastViewerWallMilliseconds: nil,
        kind: .unknown,
        applicability: .uncertain
      )
    }
    let pageGaps = try (0..<ViewerPerformanceLimits.maximumGapPageEvents).map(makeGap)
    let gapPage = try ViewerPerformanceGapPage(
      gaps: pageGaps,
      hasMoreRows: true,
      applicableOrUncertainCount: 33,
      hasMoreApplicableGaps: true
    )
    XCTAssertEqual(gapPage.accountedBytes, ViewerPerformanceLimits.maximumGapPageBytes)

    let makeEvent: (Int) throws -> ViewerPerformanceEventCarrier = { index in
      let content: ViewerPerformanceEventContent =
        index < 64
        ? .canonical(
          Data(repeating: UInt8(index), count: ViewerPerformanceLimits.maximumRowContentBytes)
        )
        : .oversized(byteCount: Int64(ViewerPerformanceLimits.maximumRowContentBytes + 1))
      return try ViewerPerformanceEventCarrier(
        locator: .transient(observationID: UUID()),
        key: ViewerEventJournalKey(
          runtimeLogicalID: runtimeLogicalID,
          connectionID: connectionID,
          direction: .appToViewer,
          wireSequence: UInt64(index)
        ),
        viewerWallMilliseconds: Int64(index),
        viewerMonotonicNanoseconds: Int64(index),
        content: content
      )
    }
    let events = try (0..<ViewerPerformanceLimits.maximumEmittedEvents).map(makeEvent)
    let liveGaps = try (0..<ViewerPerformanceLimits.maximumLiveGaps).map(makeGap)
    let slice = try ViewerPerformanceLiveSlice(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      liveGeneration: 1,
      revision: 1,
      anchorMonotonicNanoseconds: 1_000,
      events: events,
      gaps: liveGaps,
      applicableOrUncertainCount: 129,
      hasMoreApplicableGaps: true
    )
    XCTAssertEqual(slice.copiedContentBytes, ViewerPerformanceLimits.maximumCopiedContentBytes)
    XCTAssertEqual(slice.accountedBytes, ViewerPerformanceLimits.maximumLiveSliceBytes)
    XCTAssertEqual(slice.gaps.count, ViewerPerformanceLimits.maximumLiveGaps)
    XCTAssertTrue(slice.hasMoreApplicableGaps)
    XCTAssertFalse(String(reflecting: slice).contains("nearwire.performance.snapshot"))

    let source = ViewerPerformanceSource.current(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID
    )
    var session = try ViewerPerformanceProjectionSession(
      receipt: ViewerPerformanceFrozenReceipt(
        source: source,
        storeScope: nil,
        liveSlice: slice
      ),
      rangeKind: .currentSession,
      bounds: ViewerPerformanceRangeBounds(
        lowerMonotonicNanoseconds: 0,
        upperMonotonicNanoseconds: 1_000
      ),
      deviceStartMonotonicNanoseconds: 0,
      sourceGeneration: 1
    )
    XCTAssertEqual(session.retainedRawEventCount, ViewerPerformanceLimits.maximumEmittedEvents)
    var decodedTurns = 0
    while case .processed(let count) = try session.runDecodeTurn() {
      XCTAssertEqual(count, ViewerPerformancePipelineLimits.maximumDecodedEventsPerTurn)
      decodedTurns += 1
    }
    XCTAssertEqual(decodedTurns, 8)
    let publication = try session.finalize(
      sourceGeneration: 1,
      deadlineRevision: 1,
      currentUptimeNanoseconds: 1_000
    )
    XCTAssertEqual(publication.decodedEventCount, 512)
    XCTAssertEqual(publication.decodeTurnCount, 8)
  }

  func testPerformanceScopeAndContinuationRejectInvalidBounds() throws {
    XCTAssertThrowsError(
      try ViewerPerformanceStoreScope(
        storeGeneration: 0,
        recordingID: 1,
        deviceSessionID: 1,
        lowerMonotonicNanoseconds: 2,
        upperMonotonicNanoseconds: 1,
        eventUpperRowID: 0,
        gapUpperRowID: 0
      )
    )
    XCTAssertThrowsError(
      try ViewerPerformanceSource.makeHistorical(
        recordingID: 0,
        deviceSessionID: 1,
        recordingLogicalID: UUID(),
        deviceLogicalID: UUID()
      )
    )

    let scope = try ViewerPerformanceStoreScope(
      storeGeneration: 1,
      recordingID: 1,
      deviceSessionID: 1,
      lowerMonotonicNanoseconds: 0,
      upperMonotonicNanoseconds: 1,
      eventUpperRowID: 0,
      gapUpperRowID: 0
    )
    let continuation = ViewerPerformanceContinuation.initial(scope: scope)
    XCTAssertNil(continuation.lastExaminedMonotonicNanoseconds)
    XCTAssertNil(continuation.lastExaminedRowID)
  }

  func testStoreCoordinatorAndRuntimeRootsHaveClosedReflection() throws {
    let paths = try makePaths()
    let markers = [
      "store-root-installation-secret",
      "Store Root Display Secret",
      "com.example.store.root.secret",
      "88.store-root-secret",
    ]
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: try EndpointID(rawValue: markers[0]),
      displayName: markers[1],
      applicationIdentifier: markers[2],
      applicationVersion: markers[3]
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .viewer,
      installationID: try EndpointID(rawValue: "store-root-viewer")
    )
    let context = ViewerAdmissionSessionContext(
      connectionID: UUID(),
      appHello: appHello,
      viewerHello: viewerHello,
      negotiation: try WireNegotiator.negotiate(local: appHello, remote: viewerHello),
      receiveChunkBytes: 64 * 1_024
    )
    let runtime = ViewerStoreRuntime(paths: paths)
    let logicalID = UUID()
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000
    )
    runtime.sessionStarted(runtimeLogicalID: logicalID, context)
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())

    let operationalRoots: [Any] = [
      context,
      runtime,
      coordinator,
      coordinator.services,
      coordinator.services.eventStore,
      coordinator.services.maintenance,
      coordinator.services.catalog,
      coordinator.services.query,
      coordinator.services.diagnostics,
      coordinator.services.export,
      coordinator.services.preferences,
      coordinator.services.statusSignal,
      paths,
    ]
    for value in operationalRoots {
      let surfaces = [String(describing: value), String(reflecting: value), "\(value)"]
      for marker in markers {
        XCTAssertFalse(surfaces.contains { $0.contains(marker) })
      }
      XCTAssertTrue(Mirror(reflecting: value).children.isEmpty)
    }

    runtime.closeStorage()
    coordinator.closeStorage()
  }

  func testRelayObserversRejectReorderedTransitions() async throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let relay = ViewerStoreStateRelay()
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      writeStateRelay: relay
    )
    let ingress = ViewerStoreIngress(store: store)

    relay.reportFailure(.writeFailed)
    store.noteAuthoritativeWriteState(.init(sequence: 0, state: .available))
    ingress.noteAuthoritativeStoreState(.init(sequence: 0, state: .available))
    XCTAssertEqual(relay.currentState, .writeFailed)
    XCTAssertEqual(store.status().state, .writeFailed)
    let failedFlush = await ingress.flush()
    XCTAssertEqual(failedFlush, .writeFailed)

    let permit = relay.prepareRecovery(.explicitRetry)
    try relay.completeRecovery(permit)
    store.noteAuthoritativeWriteState(.init(sequence: 1, state: .capacityPaused))
    ingress.noteAuthoritativeStoreState(.init(sequence: 1, state: .capacityPaused))
    XCTAssertEqual(relay.currentState, .available)
    XCTAssertEqual(store.status().state, .available)
    let recoveredFlush = await ingress.flush()
    XCTAssertEqual(recoveredFlush, .drained)
    XCTAssertNoThrow(try relay.issueAutomaticTicket())
    pool.close()
  }

  private var temporaryDirectories: [URL] = []

  override func tearDownWithError() throws {
    for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
    temporaryDirectories.removeAll()
  }

  func testStoreCreatesFreshNormalPoolAndVersionThreeSchemaWithOwnerOnlyPermissions() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }

    XCTAssertEqual(pool.writer.role, .writer)
    XCTAssertEqual(pool.queryReader.role, .queryReader)
    XCTAssertEqual(pool.exportReader.role, .exportReader)
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64("PRAGMA user_version", database: $0)
      },
      3
    )
    for connection in [pool.writer, pool.queryReader, pool.exportReader] {
      XCTAssertEqual(
        try connection.run {
          try ViewerStoreSchema.scalarInt64("PRAGMA temp_store", database: $0)
        },
        2
      )
      XCTAssertEqual(
        try connection.run {
          try ViewerStoreSchema.scalarInt64("PRAGMA cache_size", database: $0)
        },
        -8 * 1_024
      )
    }
    let explorerIndexes = try pool.writer.run { database in
      try ["EventCausalityLookup", "GapTimelineAllDevices", "GapTimelineByDevice"].map {
        name in
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='\(name)'",
          database: database
        )
      }
    }
    XCTAssertEqual(explorerIndexes, [1, 1, 1])
    XCTAssertEqual(try permissions(paths.directory), 0o700)
    XCTAssertEqual(try permissions(paths.database), 0o600)
    XCTAssertEqual(try permissions(paths.wal), 0o600)
    XCTAssertEqual(try permissions(paths.sharedMemory), 0o600)
    XCTAssertTrue(try isRegularFileWithoutFollowingLinks(paths.wal))
    XCTAssertTrue(try isRegularFileWithoutFollowingLinks(paths.sharedMemory))
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64("PRAGMA secure_delete", database: $0)
      },
      1
    )
    let hardening = try pool.writer.hardeningConfiguration()
    XCTAssertTrue(hardening.defensive)
    XCTAssertFalse(hardening.trustedSchema)
  }

  func testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection() throws {
    let paths = try makePaths()
    let firstEvents = LockedViewerPoolConstructionEvents()
    let first = try ViewerSQLitePool(
      migrating: paths,
      constructionObserver: { firstEvents.append($0) }
    )
    XCTAssertEqual(
      firstEvents.value,
      [
        .migrationWriterOpened, .migrationCompleted, .migrationWriterClosed, .writerOpened,
        .schemaAccepted, .queryReaderOpened, .exportReaderOpened,
      ]
    )
    first.close()

    let reopenEvents = LockedViewerPoolConstructionEvents()
    let reopened = try ViewerSQLitePool(
      migrating: paths,
      constructionObserver: { reopenEvents.append($0) }
    )
    XCTAssertEqual(
      reopenEvents.value,
      [
        .migrationWriterOpened, .migrationCompleted, .migrationWriterClosed, .writerOpened,
        .schemaAccepted, .queryReaderOpened, .exportReaderOpened,
      ]
    )
    reopened.close()

    let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    try raw.execute("PRAGMA user_version=99")
    raw.close()
    let rejectedEvents = LockedViewerPoolConstructionEvents()
    XCTAssertThrowsError(
      try ViewerSQLitePool(
        migrating: paths,
        constructionObserver: { rejectedEvents.append($0) }
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .unsupportedSchema)
    }
    XCTAssertEqual(rejectedEvents.value, [.migrationWriterOpened, .migrationWriterClosed])

    let migrationFailurePaths = try makePaths()
    try ViewerStoreFileSecurity.prepareDirectory(
      migrationFailurePaths.directory,
      fileManager: .default
    )
    let invalid = try ViewerSQLiteConnection(
      role: .writer,
      path: migrationFailurePaths.database.path
    )
    try invalid.execute("CREATE TABLE Unexpected(value INTEGER)")
    invalid.close()
    let migrationFailureEvents = LockedViewerPoolConstructionEvents()
    XCTAssertThrowsError(
      try ViewerSQLitePool(
        migrating: migrationFailurePaths,
        constructionObserver: { migrationFailureEvents.append($0) }
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    XCTAssertEqual(
      migrationFailureEvents.value,
      [.migrationWriterOpened, .migrationWriterClosed]
    )
  }

  func testVersionTwoMigrationAddsRetainedCountersForExistingContent() throws {
    let paths = try makeVersionTwoStore(recordingLogicalID: "v2-retained-counter-migration")
    let temporaryDirectory = try makePrivateTemporaryDirectory()
    let phases = LockedViewerMigrationPhases()
    let control = ViewerStoreMigrationControl(
      paths: paths,
      temporaryDirectory: temporaryDirectory,
      phaseObserver: { phases.append($0) }
    )

    let pool = try ViewerSQLitePool(migrating: paths, migrationControl: control)
    defer { pool.close() }

    XCTAssertEqual(phases.value, [.preparing, .validating])
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64("PRAGMA user_version", database: $0)
      },
      3
    )
    for (key, table) in [
      ("retainedEventCount", "Events"),
      ("retainedGapCount", "GapVersions"),
      ("retainedAnnotationCount", "AnnotationVersions"),
    ] {
      XCTAssertEqual(
        try pool.writer.run { database in
          try ViewerStoreSchema.scalarInt64(
            "SELECT integerValue FROM StoreMetadata WHERE key='\(key)'",
            database: database
          )
        },
        try pool.writer.run { database in
          try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM \(table)", database: database)
        }
      )
    }
    XCTAssertEqual(
      try pool.writer.run { database in
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'Retained%Count%'",
          database: database
        )
      },
      6
    )
  }

  func testVersionOneMigrationPreservesContentAndPublishesOnlyFreshNormalConnections() throws {
    let paths = try makeVersionOneStore(
      recordingLogicalID: "migration-preserve",
      legacyDeviceLogicalID: "closed-legacy-device"
    )
    let temporaryDirectory = try makePrivateTemporaryDirectory()
    let phases = LockedViewerMigrationPhases()
    let constructionEvents = LockedViewerPoolConstructionEvents()
    let control = ViewerStoreMigrationControl(
      paths: paths,
      temporaryDirectory: temporaryDirectory,
      phaseObserver: { phases.append($0) }
    )

    let pool = try ViewerSQLitePool(
      migrating: paths,
      migrationControl: control,
      constructionObserver: { constructionEvents.append($0) }
    )
    defer { pool.close() }

    XCTAssertEqual(
      phases.value,
      [.preparing, .index(1), .index(2), .index(3), .validating]
    )
    XCTAssertEqual(
      constructionEvents.value,
      [
        .migrationWriterOpened, .migrationCompleted, .migrationWriterClosed, .writerOpened,
        .schemaAccepted, .queryReaderOpened, .exportReaderOpened,
      ]
    )
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64("PRAGMA user_version", database: $0)
      },
      3
    )
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings WHERE logicalID='migration-preserve'",
          database: $0
        )
      },
      1
    )
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM DeviceSessions d JOIN DeviceSessionVersions v ON v.deviceSessionID=d.rowID WHERE d.logicalID='closed-legacy-device' AND v.state='closed'",
          database: $0
        )
      },
      1
    )
    for connection in [pool.writer, pool.queryReader, pool.exportReader] {
      XCTAssertEqual(
        try connection.run {
          try ViewerStoreSchema.scalarInt64("PRAGMA temp_store", database: $0)
        },
        2
      )
      XCTAssertEqual(
        try connection.run {
          try ViewerStoreSchema.scalarInt64("PRAGMA cache_size", database: $0)
        },
        -8 * 1_024
      )
    }
    pool.close()
  }

  func testVersionOneMigrationRollsBackEveryInjectedIndexAndValidationFailure() throws {
    let failurePhases: [ViewerStoreMigrationPhase] = [
      .index(1), .index(2), .index(3), .validating,
    ]
    for failurePhase in failurePhases {
      let paths = try makeVersionOneStore(
        recordingLogicalID: "rollback-\(String(describing: failurePhase))"
      )
      let temporaryDirectory = try makePrivateTemporaryDirectory()
      let phases = LockedViewerMigrationPhases()
      let constructionEvents = LockedViewerPoolConstructionEvents()
      let control = ViewerStoreMigrationControl(
        paths: paths,
        temporaryDirectory: temporaryDirectory,
        phaseObserver: { phases.append($0) },
        phaseGate: { phase in
          if phase == failurePhase { throw ViewerStoreError.busy }
        }
      )

      XCTAssertThrowsError(
        try ViewerSQLitePool(
          migrating: paths,
          migrationControl: control,
          constructionObserver: { constructionEvents.append($0) }
        )
      ) { error in
        XCTAssertEqual(error as? ViewerStoreError, .busy)
      }
      XCTAssertEqual(constructionEvents.value, [.migrationWriterOpened, .migrationWriterClosed])
      XCTAssertEqual(phases.value.last, .failed)

      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      XCTAssertEqual(
        try raw.run { try ViewerStoreSchema.scalarInt64("PRAGMA user_version", database: $0) },
        1
      )
      XCTAssertEqual(
        try raw.run { database in
          try ViewerStoreSchema.scalarInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('EventCausalityLookup','GapTimelineAllDevices','GapTimelineByDevice')",
            database: database
          )
        },
        0
      )
      XCTAssertEqual(
        try raw.run { database in
          try ViewerStoreSchema.scalarInt64(
            "SELECT COUNT(*) FROM Recordings WHERE logicalID LIKE 'rollback-%'",
            database: database
          )
        },
        1
      )
      raw.close()
    }
  }

  func testVersionOneMigrationRejectsUnsafeTemporaryDirectoriesAndBothVolumeShortfalls()
    throws
  {
    let paths = try makeVersionOneStore(recordingLogicalID: "migration-resource-gates")
    let wrongMode = try makePrivateTemporaryDirectory()
    XCTAssertEqual(chmod(wrongMode.path, 0o755), 0)
    XCTAssertThrowsError(
      try ViewerStoreMigrationControl(
        paths: paths,
        temporaryDirectory: wrongMode
      ).prepareForLegacyMigration()
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidPath)
    }

    let privateTarget = try makePrivateTemporaryDirectory()
    let symbolicLink = privateTarget.deletingLastPathComponent().appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    temporaryDirectories.append(symbolicLink)
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: privateTarget)
    XCTAssertThrowsError(
      try ViewerStoreMigrationControl(
        paths: paths,
        temporaryDirectory: symbolicLink
      ).prepareForLegacyMigration()
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidPath)
    }

    let validTemporaryDirectory = try makePrivateTemporaryDirectory()
    for constrainedDirectory in [paths.directory, validTemporaryDirectory] {
      let capacity = ViewerStoreDiskGuard { directory in
        directory.standardizedFileURL == constrainedDirectory.standardizedFileURL
          ? ViewerStoreMigrationControl.baseHeadroomBytes - 1 : Int64.max
      }
      XCTAssertThrowsError(
        try ViewerStoreMigrationControl(
          paths: paths,
          temporaryDirectory: validTemporaryDirectory,
          diskGuard: capacity,
          volumeIdentifier: { directory in
            directory.standardizedFileURL == paths.directory.standardizedFileURL ? 1 : 2
          }
        ).prepareForLegacyMigration()
      ) { error in
        XCTAssertEqual(error as? ViewerStoreError, .capacityExceeded)
      }
    }

    XCTAssertThrowsError(
      try ViewerStoreMigrationControl(
        paths: paths,
        temporaryDirectory: validTemporaryDirectory,
        diskGuard: ViewerStoreDiskGuard { _ in Int64.max },
        allocatedFootprintOverride: { Int64.max }
      ).prepareForLegacyMigration()
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .capacityExceeded)
    }

    let sameVolumeCapacity = CountingViewerDiskCapacity()
    XCTAssertNoThrow(
      try ViewerStoreMigrationControl(
        paths: paths,
        temporaryDirectory: validTemporaryDirectory,
        diskGuard: ViewerStoreDiskGuard { sameVolumeCapacity.available(at: $0) },
        volumeIdentifier: { _ in 1 }
      ).prepareForLegacyMigration()
    )
    XCTAssertEqual(sameVolumeCapacity.callCount, 1)

    let liveFloorControl = ViewerStoreMigrationControl(
      paths: paths,
      temporaryDirectory: validTemporaryDirectory,
      diskGuard: ViewerStoreDiskGuard { directory in
        directory.standardizedFileURL == paths.directory.standardizedFileURL
          ? Int64.max : ViewerStoreMigrationControl.liveVolumeFloorBytes - 1
      },
      volumeIdentifier: { directory in
        directory.standardizedFileURL == paths.directory.standardizedFileURL ? 1 : 2
      }
    )
    XCTAssertEqual(liveFloorControl.progressFailure(), .capacityExceeded)
  }

  func testRuntimeCloseCancelsAndJoinsVersionOneMigrationRollback() throws {
    let paths = try makeVersionOneStore(recordingLogicalID: "cancel-migration")
    let temporaryDirectory = try makePrivateTemporaryDirectory()
    let phaseGate = BlockingViewerMigrationPhaseGate(blocking: .index(2))
    let resourceEvents = LockedViewerReopenResourceEvents()
    phaseGate.arm()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      startupMode: .asynchronous,
      migrationTemporaryDirectory: temporaryDirectory,
      automaticMigrationAuthorization: { _ in true },
      migrationPhaseGate: { try phaseGate.check($0) },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    XCTAssertEqual(phaseGate.waitUntilEntered(), .success)

    let closeFinished = expectation(description: "Migration close joined")
    DispatchQueue.global(qos: .userInitiated).async {
      runtime.closeStorage()
      closeFinished.fulfill()
    }
    waitUntil { resourceEvents.value.contains(.terminalCloseWaiting) }
    phaseGate.release()
    wait(for: [closeFinished], timeout: 2)

    XCTAssertEqual(runtime.status().migration, .cancelled)
    let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    XCTAssertEqual(
      try raw.run { try ViewerStoreSchema.scalarInt64("PRAGMA user_version", database: $0) },
      1
    )
    XCTAssertEqual(
      try raw.run { database in
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('EventCausalityLookup','GapTimelineAllDevices','GapTimelineByDevice')",
          database: database
        )
      },
      0
    )
    raw.close()
  }

  func testAsynchronousRuntimeMigrationPublishesSafePhaseWithoutBlockingRuntimeStart() throws {
    let paths = try makeVersionOneStore(recordingLogicalID: "async-migration")
    let temporaryDirectory = try makePrivateTemporaryDirectory()
    let phaseGate = BlockingViewerMigrationPhaseGate(blocking: .index(2))
    phaseGate.arm()

    let runtime = ViewerStoreRuntime(
      paths: paths,
      startupMode: .asynchronous,
      migrationTemporaryDirectory: temporaryDirectory,
      automaticMigrationAuthorization: { _ in true },
      migrationPhaseGate: { try phaseGate.check($0) }
    )
    let runtimeLogicalID = UUID()
    runtime.runtimeStarted(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000
    )

    XCTAssertEqual(phaseGate.waitUntilEntered(), .success)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(runtime.status().migration, .updatingIndex(2))
    XCTAssertEqual(runtime.status().migration?.message, "Updating history index 2/3")

    phaseGate.release()
    waitUntil { runtime.status().state == ViewerStoreStatus.State.available }
    XCTAssertNil(runtime.status().migration)
    XCTAssertEqual(try scalar("PRAGMA user_version", at: paths), 3)
    runtime.closeStorage()
  }

  func testAutomaticMigrationIsAuthorizedOnceAndExplicitRetryBypassesAutomaticGate() throws {
    let paths = try makeVersionOneStore(recordingLogicalID: "once-per-process")
    let temporaryDirectory = try makePrivateTemporaryDirectory()
    let authorization = CountingViewerMigrationAuthorization()
    let phaseFault = OneShotViewerMigrationPhaseFault(failing: .index(1))
    let runtime = ViewerStoreRuntime(
      paths: paths,
      startupMode: .asynchronous,
      migrationTemporaryDirectory: temporaryDirectory,
      automaticMigrationAuthorization: { _ in authorization.claim() },
      migrationPhaseGate: { try phaseFault.check($0) }
    )

    waitUntil { runtime.status().migration == ViewerStoreMigrationStatus.failed }
    XCTAssertEqual(authorization.callCount, 1)
    XCTAssertEqual(phaseFault.failureCount, 1)
    XCTAssertEqual(try scalar("PRAGMA user_version", at: paths), 1)

    let runtimeLogicalID = UUID()
    runtime.runtimeStarted(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000
    )
    let automaticAttemptFinished = expectation(description: "Unauthorized automatic attempt")
    runtime.afterCurrentReopenPrefix { automaticAttemptFinished.fulfill() }
    wait(for: [automaticAttemptFinished], timeout: 2)
    XCTAssertEqual(authorization.callCount, 2)
    XCTAssertEqual(phaseFault.failureCount, 1)
    XCTAssertEqual(try scalar("PRAGMA user_version", at: paths), 1)

    runtime.retryStorage()
    waitUntil { runtime.status().state == ViewerStoreStatus.State.available }
    XCTAssertEqual(authorization.callCount, 2)
    XCTAssertEqual(try scalar("PRAGMA user_version", at: paths), 3)
    runtime.closeStorage()
  }

  func testLargeVersionOneMigrationBoundsResourcesAndLeavesOnlyKeySorters() throws {
    let paths = try makeLargeVersionOneStore(
      recordingLogicalID: "migration-large-success",
      eventCount: 100_000,
      gapCount: 10_000
    )
    let temporaryDirectory = try makePrivateTemporaryDirectory()
    let baselineFootprint = try XCTUnwrap(currentProcessPhysicalFootprintBytes())
    let defaultVFS = sqlite3_vfs_find(nil)
    let defaultTemporaryDirectory = sqliteTemporaryDirectoryValue()
    let resources = LockedViewerMigrationResources(
      paths: paths,
      temporaryDirectory: temporaryDirectory,
      baselinePhysicalFootprintBytes: baselineFootprint
    )
    resources.sample(force: true)
    let control = ViewerStoreMigrationControl(
      paths: paths,
      temporaryDirectory: temporaryDirectory,
      progressObserver: { resources.sample() }
    )

    let pool = try ViewerSQLitePool(migrating: paths, migrationControl: control)
    defer { pool.close() }
    resources.sample(force: true)

    XCTAssertEqual(sqlite3_vfs_find(nil), defaultVFS)
    XCTAssertEqual(
      sqliteTemporaryDirectoryValue(),
      defaultTemporaryDirectory
    )
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      100_000
    )
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM GapVersions", database: $0)
      },
      10_000
    )
    XCTAssertEqual(
      try pool.writer.run {
        try ViewerStoreSchema.scalarInt64("PRAGMA user_version", database: $0)
      },
      3
    )
    XCTAssertTrue(
      ViewerStoreSchema.schemaVersion2IndexStatements.allSatisfy { statement in
        let normalized = statement.lowercased()
        return !normalized.contains("contentjson") && !normalized.contains("eventtype")
      }
    )
    for connection in [pool.writer, pool.queryReader, pool.exportReader] {
      XCTAssertEqual(
        try connection.run {
          try ViewerStoreSchema.scalarInt64("PRAGMA temp_store", database: $0)
        },
        2
      )
      XCTAssertEqual(
        try connection.run {
          try ViewerStoreSchema.scalarInt64("PRAGMA cache_size", database: $0)
        },
        -8 * 1_024
      )
    }
    let snapshot = resources.snapshot
    XCTAssertLessThanOrEqual(snapshot.maximumPhysicalFootprintGrowthBytes, 128 * 1_024 * 1_024)
    XCTAssertGreaterThan(snapshot.sampleCount, 0)
    XCTAssertTrue(openDescriptorPaths(under: temporaryDirectory).isEmpty)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path),
      []
    )
    print(
      "NearWire large migration diagnostics: heap-growth=\(snapshot.maximumPhysicalFootprintGrowthBytes), database-high-water=\(snapshot.maximumDatabaseAllocatedBytes), wal-high-water=\(snapshot.maximumWALAllocatedBytes), temp-high-water=\(snapshot.maximumTemporaryAllocatedBytes), samples=\(snapshot.sampleCount)"
    )
    pool.close()
    XCTAssertTrue(openDescriptorPaths(under: temporaryDirectory).isEmpty)
  }

  func testLargeVersionOneMigrationCancelsWithinInjectedProgressDeadline() throws {
    let paths = try makeLargeVersionOneStore(
      recordingLogicalID: "migration-large-cancel",
      eventCount: 100_000,
      gapCount: 10_000
    )
    let temporaryDirectory = try makePrivateTemporaryDirectory()
    let token = ViewerStoreMigrationToken()
    let progressGate = BlockingViewerMigrationProgressGate()
    let baselineFootprint = try XCTUnwrap(currentProcessPhysicalFootprintBytes())
    let resources = LockedViewerMigrationResources(
      paths: paths,
      temporaryDirectory: temporaryDirectory,
      baselinePhysicalFootprintBytes: baselineFootprint
    )
    let defaultVFS = sqlite3_vfs_find(nil)
    let defaultTemporaryDirectory = sqliteTemporaryDirectoryValue()
    let control = ViewerStoreMigrationControl(
      paths: paths,
      temporaryDirectory: temporaryDirectory,
      isCancelled: { token.isCancelled },
      phaseObserver: { progressGate.observe($0) },
      progressObserver: {
        resources.sample()
        progressGate.checkpoint()
      }
    )
    let errors = LockedViewerStoreErrors()
    let completed = expectation(description: "Large migration cancellation completed")
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let pool = try ViewerSQLitePool(migrating: paths, migrationControl: control)
        defer { pool.close() }
        pool.close()
        errors.append(nil)
      } catch {
        errors.append(error as? ViewerStoreError)
      }
      completed.fulfill()
    }

    XCTAssertEqual(progressGate.waitUntilEntered(), .success)
    let cancellationStart = DispatchTime.now().uptimeNanoseconds
    token.cancel()
    progressGate.release()
    wait(for: [completed], timeout: 2)
    let cancellationElapsed = DispatchTime.now().uptimeNanoseconds - cancellationStart

    XCTAssertEqual(errors.values, [.cancelled])
    XCTAssertLessThanOrEqual(cancellationElapsed, 250_000_000)
    XCTAssertEqual(sqlite3_vfs_find(nil), defaultVFS)
    XCTAssertEqual(
      sqliteTemporaryDirectoryValue(),
      defaultTemporaryDirectory
    )
    let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    XCTAssertEqual(
      try raw.run { try ViewerStoreSchema.scalarInt64("PRAGMA user_version", database: $0) },
      1
    )
    XCTAssertEqual(
      try raw.run {
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('EventCausalityLookup','GapTimelineAllDevices','GapTimelineByDevice')",
          database: $0
        )
      },
      0
    )
    XCTAssertEqual(
      try raw.run {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      100_000
    )
    XCTAssertEqual(
      try raw.run {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM GapVersions", database: $0)
      },
      10_000
    )
    raw.close()
    resources.sample(force: true)
    let snapshot = resources.snapshot
    XCTAssertLessThanOrEqual(snapshot.maximumPhysicalFootprintGrowthBytes, 128 * 1_024 * 1_024)
    XCTAssertTrue(openDescriptorPaths(under: temporaryDirectory).isEmpty)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path),
      []
    )
    print(
      "NearWire large migration cancellation diagnostics: acknowledgement-ns=\(cancellationElapsed), heap-growth=\(snapshot.maximumPhysicalFootprintGrowthBytes), database-high-water=\(snapshot.maximumDatabaseAllocatedBytes), wal-high-water=\(snapshot.maximumWALAllocatedBytes), temp-high-water=\(snapshot.maximumTemporaryAllocatedBytes), samples=\(snapshot.sampleCount)"
    )
  }

  func testExplorerGatewaySealsOriginatingGenerationBeforePublishingReplacement() throws {
    let firstCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let replacementCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let operationGate = ArmableViewerExecutionGate()
    operationGate.arm()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(firstCoordinator)
    let results = LockedViewerExplorerResults()
    let firstFinished = expectation(description: "First generation operation finished")
    let firstToken = gateway.loadChangeSnapshot { result in
      results.append(result)
      firstFinished.fulfill()
    }
    XCTAssertEqual(firstToken.coordinatorGeneration, 1)
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)

    let replacementStarted = DispatchSemaphore(value: 0)
    let replacementFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      replacementStarted.signal()
      gateway.install(replacementCoordinator)
      replacementFinished.signal()
    }
    XCTAssertEqual(replacementStarted.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(replacementFinished.wait(timeout: .now() + 0.05), .timedOut)
    operationGate.release()
    wait(for: [firstFinished], timeout: 2)
    XCTAssertEqual(replacementFinished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(results.failures, [.storeReplaced])

    let replacementFinishedExpectation = expectation(description: "Replacement operation")
    let replacementToken = gateway.loadChangeSnapshot { result in
      results.append(result)
      replacementFinishedExpectation.fulfill()
    }
    XCTAssertEqual(replacementToken.coordinatorGeneration, 2)
    gateway.cancel(firstToken)
    wait(for: [replacementFinishedExpectation], timeout: 2)
    XCTAssertEqual(results.successCount, 1)
    XCTAssertTrue(Mirror(reflecting: firstToken).children.isEmpty)
    XCTAssertTrue(Mirror(reflecting: gateway).children.isEmpty)

    gateway.sealAndWait(originatingFrom: replacementCoordinator)
    firstCoordinator.closeStorage()
    replacementCoordinator.closeStorage()
  }

  func testExplorerGatewaySealsBlockedOperationMatrixAndReleasesTraversalLease() throws {
    let paths = try makePaths()
    let coordinator = try ViewerStoreCoordinator(paths: paths)
    let store = coordinator.services.eventStore
    let fixtureWallMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    let recording = try store.beginRecording(
      wallMilliseconds: fixtureWallMilliseconds,
      monotonicNanoseconds: 2_000,
      reason: "blocked-operation-matrix"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "blocked-device",
      wallMilliseconds: fixtureWallMilliseconds,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Blocked Device"
    )
    let eventID = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "blocked")
    )
    try store.appendStructural(
      .closeRecording(
        recording,
        wallMilliseconds: fixtureWallMilliseconds + 1,
        monotonicNanoseconds: 4_000
      )
    )

    let gate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { gate.run() })
    gateway.install(coordinator)
    let catalog: ViewerRecordingCatalogPage = try explorerValue("Matrix catalog") {
      gateway.loadRecordingCatalog(cursor: nil, completion: $0)
    }
    let target = try XCTUnwrap(catalog.recordingTarget(rowID: recording.rowID))
    let query = try ViewerEventQuery(recordingID: recording.rowID, predicates: [])
    let _: ViewerQuerySnapshot = try explorerValue("Matrix query") {
      gateway.replaceQuery(query, completion: $0)
    }

    gate.arm()
    let catalogResult = LockedViewerExplorerResult<ViewerRecordingCatalogPage>()
    let pageResult = LockedViewerExplorerResult<ViewerEventPage>()
    let detailResult = LockedViewerExplorerResult<ViewerStoredEventDetail?>()
    let gapResult = LockedViewerExplorerResult<ViewerGapPage>()
    let causalityResult = LockedViewerExplorerResult<ViewerCausalityGraph>()
    let exportResult = LockedViewerExplorerResult<ViewerStoreExportTicket>()
    let callbacks = (0..<6).map { expectation(description: "Blocked operation \($0)") }
    _ = gateway.loadRecordingCatalog(cursor: nil) {
      catalogResult.set($0)
      callbacks[0].fulfill()
    }
    XCTAssertEqual(gate.waitUntilBlocked(), .success)
    _ = gateway.loadPage(cursor: nil, direction: .forward) {
      pageResult.set($0)
      callbacks[1].fulfill()
    }
    _ = gateway.loadDetail(rowID: eventID) {
      detailResult.set($0)
      callbacks[2].fulfill()
    }
    _ = gateway.loadGapPage(deviceSessionIDs: [], cursor: nil, direction: .forward) {
      gapResult.set($0)
      callbacks[3].fulfill()
    }
    _ = gateway.loadCausality(rootRowID: eventID) {
      causalityResult.set($0)
      callbacks[4].fulfill()
    }
    _ = gateway.prepareFilteredExport {
      exportResult.set($0)
      callbacks[5].fulfill()
    }

    let replacement = try ViewerStoreCoordinator(paths: makePaths())
    let replacementFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      gateway.install(replacement)
      replacementFinished.signal()
    }
    XCTAssertEqual(replacementFinished.wait(timeout: .now() + 0.05), .timedOut)
    gate.release()
    wait(for: callbacks, timeout: 2)
    XCTAssertEqual(replacementFinished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(catalogResult.failure, .storeReplaced)
    XCTAssertEqual(pageResult.failure, .storeReplaced)
    XCTAssertEqual(detailResult.failure, .storeReplaced)
    XCTAssertEqual(gapResult.failure, .storeReplaced)
    XCTAssertEqual(causalityResult.failure, .storeReplaced)
    XCTAssertEqual(exportResult.failure, .storeReplaced)

    let confirmation = try coordinator.services.maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: target.recordingID, revision: target.revision)
    )
    XCTAssertNoThrow(
      try coordinator.services.maintenance.requestDelete(
        confirmation,
        wallMilliseconds: fixtureWallMilliseconds + 2
      )
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Tombstones", at: paths), 1)

    gateway.sealAndWait(originatingFrom: replacement)
    coordinator.closeStorage()
    replacement.closeStorage()
  }

  func testRuntimeSealsExplorerOperationsBeforeClosingOriginatingStore() throws {
    let paths = try makePaths()
    let operationGate = ArmableViewerExecutionGate()
    operationGate.arm()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      explorerOperationExecutionGate: { operationGate.run() }
    )
    let results = LockedViewerExplorerResults()
    let operationFinished = expectation(description: "Runtime explorer operation finished")
    _ = runtime.explorerGateway.loadChangeSnapshot { result in
      results.append(result)
      operationFinished.fulfill()
    }
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)

    let closeStarted = DispatchSemaphore(value: 0)
    let closeFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      closeStarted.signal()
      runtime.closeStorage()
      closeFinished.signal()
    }
    XCTAssertEqual(closeStarted.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(closeFinished.wait(timeout: .now() + 0.05), .timedOut)
    operationGate.release()
    wait(for: [operationFinished], timeout: 2)
    XCTAssertEqual(closeFinished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(results.failures, [.storeReplaced])

    let unavailable = expectation(description: "Closed runtime explorer unavailable")
    _ = runtime.explorerGateway.loadChangeSnapshot { result in
      results.append(result)
      unavailable.fulfill()
    }
    wait(for: [unavailable], timeout: 2)
    XCTAssertEqual(results.failures, [.storeReplaced, .unavailable])
  }

  func testExplorerGatewaySerializesQueryPageDetailAndFilteredScope() throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let store = coordinator.services.eventStore
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    let eventID = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "alpha")
    )
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let query = try ViewerEventQuery(recordingID: recording.rowID, predicates: [])

    let queryResult = LockedViewerExplorerResult<ViewerQuerySnapshot>()
    let queryFinished = expectation(description: "Query replaced")
    let queryToken = gateway.replaceQuery(query) { result in
      queryResult.set(result)
      queryFinished.fulfill()
    }
    wait(for: [queryFinished], timeout: 2)
    XCTAssertEqual(queryToken.coordinatorGeneration, 1)
    guard case .success = try XCTUnwrap(queryResult.value) else {
      return XCTFail("Expected query replacement to succeed")
    }

    let pageResult = LockedViewerExplorerResult<ViewerEventPage>()
    let pageFinished = expectation(description: "Page loaded")
    _ = gateway.loadPage(cursor: nil, direction: .forward, limit: 10) { result in
      pageResult.set(result)
      pageFinished.fulfill()
    }
    wait(for: [pageFinished], timeout: 2)
    guard case .success(let page) = try XCTUnwrap(pageResult.value) else {
      return XCTFail("Expected page to succeed")
    }
    XCTAssertEqual(page.rows.map(\.rowID), [eventID])

    let detailResult = LockedViewerExplorerResult<ViewerStoredEventDetail?>()
    let detailFinished = expectation(description: "Detail loaded")
    _ = gateway.loadDetail(rowID: eventID) { result in
      detailResult.set(result)
      detailFinished.fulfill()
    }
    wait(for: [detailFinished], timeout: 2)
    guard case .success(let detail) = try XCTUnwrap(detailResult.value) else {
      return XCTFail("Expected detail to succeed")
    }
    XCTAssertEqual(detail?.summary.rowID, eventID)

    let gapResult = LockedViewerExplorerResult<ViewerGapPage>()
    let gapFinished = expectation(description: "Gap page loaded")
    _ = gateway.loadGapPage(
      deviceSessionIDs: [],
      cursor: nil,
      direction: .forward,
      limit: 32
    ) { result in
      gapResult.set(result)
      gapFinished.fulfill()
    }
    wait(for: [gapFinished], timeout: 2)
    guard case .success(let gapPage) = try XCTUnwrap(gapResult.value) else {
      return XCTFail("Expected gap page to succeed")
    }
    XCTAssertTrue(gapPage.rows.isEmpty)

    let causalityResult = LockedViewerExplorerResult<ViewerCausalityGraph>()
    let causalityFinished = expectation(description: "Causality loaded")
    _ = gateway.loadCausality(rootRowID: eventID) { result in
      causalityResult.set(result)
      causalityFinished.fulfill()
    }
    wait(for: [causalityFinished], timeout: 2)
    guard case .success(let graph) = try XCTUnwrap(causalityResult.value) else {
      return XCTFail("Expected causality to succeed")
    }
    XCTAssertEqual(graph.nodes.map(\.rowID), [eventID])
    XCTAssertTrue(graph.edges.isEmpty)

    let scopeResult = LockedViewerExplorerResult<ViewerFilteredExportScope>()
    let scopeFinished = expectation(description: "Filtered export scope created")
    _ = gateway.makeFilteredExportScope { result in
      scopeResult.set(result)
      scopeFinished.fulfill()
    }
    wait(for: [scopeFinished], timeout: 2)
    guard case .success(let scope) = try XCTUnwrap(scopeResult.value) else {
      return XCTFail("Expected filtered scope to succeed")
    }
    XCTAssertEqual(scope.query, query)
    XCTAssertTrue(Mirror(reflecting: scope).children.isEmpty)

    let endResult = LockedViewerExplorerResult<Void>()
    let endFinished = expectation(description: "Traversal ended")
    _ = gateway.endTraversal { result in
      endResult.set(result)
      endFinished.fulfill()
    }
    wait(for: [endFinished], timeout: 2)
    guard case .success = try XCTUnwrap(endResult.value) else {
      return XCTFail("Expected traversal end to succeed")
    }

    let missingTraversal = LockedViewerExplorerResult<ViewerEventPage>()
    let missingTraversalFinished = expectation(description: "Missing traversal rejected")
    _ = gateway.loadPage(cursor: nil, direction: .forward) { result in
      missingTraversal.set(result)
      missingTraversalFinished.fulfill()
    }
    wait(for: [missingTraversalFinished], timeout: 2)
    XCTAssertEqual(missingTraversal.failure, .invalidRequest)

    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  func testExplorerGatewayRoutesRevisionBoundHistoryMutationsAndRejectsOldGeneration() throws {
    let operationGate = ArmableViewerExecutionGate()
    let maintenanceGate = ArmableViewerExecutionGate()
    maintenanceGate.arm()
    let paths = try makePaths()
    let coordinator = try ViewerStoreCoordinator(
      paths: paths,
      maintenanceExecutionGate: { maintenanceGate.run() }
    )
    XCTAssertEqual(maintenanceGate.waitUntilBlocked(), .success)
    let store = coordinator.services.eventStore
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "history"
    )
    try store.appendStructural(
      .closeRecording(
        recording,
        wallMilliseconds: 2_000,
        monotonicNanoseconds: 3_000
      )
    )
    let activeRecording = try store.beginRecording(
      wallMilliseconds: 3_000,
      monotonicNanoseconds: 4_000,
      reason: "active-history"
    )
    let gateway = ViewerStoreExplorerGateway(
      operationExecutionGate: { operationGate.run() },
      wallMilliseconds: { 10_000 }
    )
    gateway.install(coordinator)

    let page: ViewerRecordingCatalogPage = try explorerValue("Recording catalog") {
      gateway.loadRecordingCatalog(cursor: nil, completion: $0)
    }
    let initialTarget = try XCTUnwrap(page.recordingTarget(rowID: recording.rowID))
    let activeTarget = try XCTUnwrap(page.recordingTarget(rowID: activeRecording.rowID))
    XCTAssertTrue(Mirror(reflecting: initialTarget).children.isEmpty)

    let activeDelete: Result<ViewerStoreDeleteConfirmation, ViewerStoreExplorerFailure> =
      try explorerResult("Active recording delete") {
        gateway.prepareDelete(activeTarget, completion: $0)
      }
    XCTAssertThrowsError(try activeDelete.get()) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .busy)
    }

    operationGate.arm()
    let updateResult = LockedViewerExplorerResult<ViewerStoreRecordingTarget>()
    let updateFinished = expectation(description: "Non-cancellable update finished truthfully")
    let updateToken = gateway.updateRecording(
      initialTarget,
      name: "Renamed",
      note: "Bounded note",
      pinned: true
    ) { result in
      updateResult.set(result)
      updateFinished.fulfill()
    }
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)
    gateway.cancel(updateToken)
    operationGate.release()
    wait(for: [updateFinished], timeout: 2)
    let completedUpdate = try XCTUnwrap(updateResult.value)
    guard case .success(let updatedTarget) = completedUpdate else {
      return XCTFail("History update failed with \(String(describing: updateResult.failure))")
    }
    XCTAssertEqual(updatedTarget.revision, initialTarget.revision + 1)
    try coordinator.services.maintenance.run(
      trigger: .explicit,
      nowWallMilliseconds: 8 * 86_400_000
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Tombstones", at: paths), 0)

    let staleUpdate: Result<ViewerStoreRecordingTarget, ViewerStoreExplorerFailure> =
      try explorerResult("Stale recording update") {
        gateway.updateRecording(
          initialTarget,
          name: "Must not win",
          note: nil,
          pinned: false,
          completion: $0
        )
      }
    XCTAssertThrowsError(try staleUpdate.get()) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .busy)
    }

    let _: Void = try explorerValue("Annotation") {
      gateway.appendAnnotation(updatedTarget, body: "First annotation", completion: $0)
    }
    let firstConfirmation: ViewerStoreDeleteConfirmation = try explorerValue(
      "Delete confirmation"
    ) {
      gateway.prepareDelete(updatedTarget, completion: $0)
    }
    XCTAssertEqual(firstConfirmation.recordingID, recording.rowID)
    XCTAssertTrue(Mirror(reflecting: firstConfirmation).children.isEmpty)

    let _: Void = try explorerValue("Concurrent annotation") {
      gateway.appendAnnotation(updatedTarget, body: "Invalidates confirmation", completion: $0)
    }
    let staleDelete: Result<Void, ViewerStoreExplorerFailure> = try explorerResult(
      "Stale delete"
    ) {
      gateway.requestDelete(firstConfirmation, completion: $0)
    }
    XCTAssertThrowsError(try staleDelete.get()) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .busy)
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Tombstones", at: paths), 0)

    let protectedQuery = try ViewerEventQuery(
      recordingID: recording.rowID,
      predicates: []
    )
    let _: ViewerQuerySnapshot = try explorerValue("Protected history query") {
      gateway.replaceQuery(protectedQuery, completion: $0)
    }
    let leasedConfirmation: ViewerStoreDeleteConfirmation = try explorerValue(
      "Leased delete confirmation"
    ) {
      gateway.prepareDelete(updatedTarget, completion: $0)
    }
    let leasedDelete: Result<Void, ViewerStoreExplorerFailure> = try explorerResult(
      "Leased delete"
    ) {
      gateway.requestDelete(leasedConfirmation, completion: $0)
    }
    XCTAssertThrowsError(try leasedDelete.get()) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .busy)
    }
    let _: Void = try explorerValue("Release protected history query") {
      gateway.endTraversal(completion: $0)
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Tombstones", at: paths), 0)

    let currentConfirmation: ViewerStoreDeleteConfirmation = try explorerValue(
      "Fresh delete confirmation"
    ) {
      gateway.prepareDelete(updatedTarget, completion: $0)
    }
    let _: Void = try explorerValue("Confirmed delete") {
      gateway.requestDelete(currentConfirmation, completion: $0)
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Tombstones", at: paths), 1)

    let replacement = try ViewerStoreCoordinator(paths: makePaths())
    gateway.install(replacement)
    let oldGeneration: Result<ViewerStoreRecordingTarget, ViewerStoreExplorerFailure> =
      try explorerResult("Old generation mutation") {
        gateway.updateRecording(
          updatedTarget,
          name: "Must not retarget",
          note: nil,
          pinned: false,
          completion: $0
        )
      }
    XCTAssertThrowsError(try oldGeneration.get()) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .storeReplaced)
    }

    gateway.sealAndWait(originatingFrom: replacement)
    maintenanceGate.release()
    coordinator.closeStorage()
    replacement.closeStorage()
  }

  func testExplorerGatewayFreezesPreflightedExportsAndCancellationPreservesDestination() throws {
    let operationGate = ArmableViewerExecutionGate()
    let paths = try makePaths()
    let coordinator = try ViewerStoreCoordinator(paths: paths)
    let store = coordinator.services.eventStore
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "export"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "export-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Export App"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "alpha")
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 2, value: "beta")
    )
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(coordinator)
    let page: ViewerRecordingCatalogPage = try explorerValue("Export recording catalog") {
      gateway.loadRecordingCatalog(cursor: nil, completion: $0)
    }
    let target = try XCTUnwrap(page.recordingTarget(rowID: recording.rowID))

    let completeTicket: ViewerStoreExportTicket = try explorerValue("Complete preflight") {
      gateway.prepareCompleteExport(target, completion: $0)
    }
    XCTAssertEqual(completeTicket.eventCount, 2)
    XCTAssertEqual(completeTicket.disclosure, .current)
    XCTAssertEqual(
      completeTicket.disclosure.warning,
      "Session metadata and notes, annotations and diagnostic gaps, Event metadata and content, and peer-provided App display name, identifier, and version are exported verbatim and can contain identifying or sensitive data."
    )
    XCTAssertTrue(completeTicket.disclosure.unencrypted)
    XCTAssertTrue(completeTicket.disclosure.aliasesArePseudonymsNotRedaction)
    XCTAssertTrue(completeTicket.disclosure.outsideViewerQuotaAndRetention)
    XCTAssertTrue(completeTicket.disclosure.mayBeSyncedOrBackedUpByDestinationProvider)
    XCTAssertTrue(Mirror(reflecting: completeTicket).children.isEmpty)

    let query = try ViewerEventQuery(
      recordingID: recording.rowID,
      predicates: [.json(path: "$.message", equals: .string("alpha"))]
    )
    let _: ViewerQuerySnapshot = try explorerValue("Filtered export query") {
      gateway.replaceQuery(query, completion: $0)
    }
    let filteredTicket: ViewerStoreExportTicket = try explorerValue("Filtered preflight") {
      gateway.prepareFilteredExport(completion: $0)
    }
    XCTAssertEqual(filteredTicket.eventCount, 1)

    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 3, value: "alpha")
    )

    let cancelledDestination = paths.directory.appendingPathComponent("cancelled-export.json")
    let priorDestination = Data("prior destination".utf8)
    try priorDestination.write(to: cancelledDestination)
    operationGate.arm()
    let cancellationResult = LockedViewerExplorerResult<Void>()
    let cancellationFinished = expectation(description: "Export cancelled")
    let cancellationToken = gateway.executeExport(
      filteredTicket,
      to: cancelledDestination
    ) { result in
      cancellationResult.set(result)
      cancellationFinished.fulfill()
    }
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)
    gateway.cancel(cancellationToken)
    operationGate.release()
    wait(for: [cancellationFinished], timeout: 2)
    XCTAssertEqual(cancellationResult.failure, .cancelled)
    XCTAssertEqual(try Data(contentsOf: cancelledDestination), priorDestination)

    let filteredDestination = paths.directory.appendingPathComponent("filtered-ticket.json")
    let _: Void = try explorerValue("Filtered export") {
      gateway.executeExport(filteredTicket, to: filteredDestination, completion: $0)
    }
    let filteredRoot = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: filteredDestination))
        as? [String: Any]
    )
    XCTAssertEqual((filteredRoot["events"] as? [[String: Any]])?.count, 1)

    let completeDestination = paths.directory.appendingPathComponent("complete-ticket.json")
    let _: Void = try explorerValue("Complete export") {
      gateway.executeExport(completeTicket, to: completeDestination, completion: $0)
    }
    let completeRoot = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: completeDestination))
        as? [String: Any]
    )
    XCTAssertEqual((completeRoot["events"] as? [[String: Any]])?.count, 2)

    let replacement = try ViewerStoreCoordinator(paths: makePaths())
    gateway.install(replacement)
    let staleDestination = paths.directory.appendingPathComponent("stale-ticket.json")
    let staleExport: Result<Void, ViewerStoreExplorerFailure> = try explorerResult(
      "Stale export ticket"
    ) {
      gateway.executeExport(completeTicket, to: staleDestination, completion: $0)
    }
    XCTAssertThrowsError(try staleExport.get()) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .storeReplaced)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: staleDestination.path))

    gateway.sealAndWait(originatingFrom: replacement)
    coordinator.closeStorage()
    replacement.closeStorage()
  }

  func testExplorerGatewayCancellationIsQueuedCompletedAndActiveSuccessorSafe() throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let operationGate = ArmableViewerExecutionGate()
    operationGate.arm()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(coordinator)
    let results = LockedViewerExplorerResults()

    let firstFinished = expectation(description: "Active predecessor finished")
    _ = gateway.loadChangeSnapshot { result in
      results.append(result)
      firstFinished.fulfill()
    }
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)

    let queuedFinished = expectation(description: "Queued cancellation finished")
    let queuedToken = gateway.loadChangeSnapshot { result in
      results.append(result)
      queuedFinished.fulfill()
    }
    gateway.cancel(queuedToken)
    wait(for: [queuedFinished], timeout: 1)
    XCTAssertEqual(gateway.operationCountForTesting, 1)
    XCTAssertEqual(gateway.pendingOperationCountForTesting, 0)
    operationGate.release()
    wait(for: [firstFinished], timeout: 2)
    XCTAssertEqual(results.successCount, 1)
    XCTAssertEqual(results.failures, [.cancelled])

    let successorFinished = expectation(description: "Queued successor finished")
    _ = gateway.loadChangeSnapshot { result in
      results.append(result)
      successorFinished.fulfill()
    }
    wait(for: [successorFinished], timeout: 2)
    gateway.cancel(queuedToken)

    let completedCancellationSuccessor = expectation(
      description: "Completed cancellation did not affect successor"
    )
    _ = gateway.loadChangeSnapshot { result in
      results.append(result)
      completedCancellationSuccessor.fulfill()
    }
    wait(for: [completedCancellationSuccessor], timeout: 2)
    XCTAssertEqual(results.successCount, 3)
    XCTAssertEqual(results.failures, [.cancelled])

    operationGate.arm()
    let activeCancelled = expectation(description: "Active cancellation finished")
    let activeToken = gateway.loadChangeSnapshot { result in
      results.append(result)
      activeCancelled.fulfill()
    }
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)
    gateway.cancel(activeToken)
    operationGate.release()
    wait(for: [activeCancelled], timeout: 2)

    let activeSuccessor = expectation(description: "Active cancellation successor finished")
    _ = gateway.loadChangeSnapshot { result in
      results.append(result)
      activeSuccessor.fulfill()
    }
    wait(for: [activeSuccessor], timeout: 2)
    XCTAssertEqual(results.successCount, 4)
    XCTAssertEqual(results.failures, [.cancelled, .cancelled])

    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  func testQueuedGatewayCancellationRemainsBoundedAcrossHundredThousandReplacements() throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let operationGate = ArmableViewerExecutionGate()
    operationGate.arm()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(coordinator)
    let activeFinished = expectation(description: "Active gateway operation finished")
    _ = gateway.loadChangeSnapshot { result in
      if case .failure(let failure) = result { XCTFail("Unexpected failure: \(failure)") }
      activeFinished.fulfill()
    }
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)

    let retainedCancellationCount = LockedCounter()
    var retainedTokens: [ViewerStoreExplorerOperationToken] = []
    for _ in 0..<15 {
      retainedTokens.append(
        gateway.loadChangeSnapshot { result in
          if case .failure(.cancelled) = result {
            retainedCancellationCount.increment()
          } else {
            XCTFail("Retained queued operation must complete as cancelled.")
          }
        }
      )
    }
    let overflow = LockedViewerExplorerResult<ViewerStoreChangeSnapshot>()
    _ = gateway.loadChangeSnapshot { overflow.set($0) }
    XCTAssertEqual(overflow.failure, .busy)
    XCTAssertEqual(gateway.operationCountForTesting, 16)
    XCTAssertEqual(gateway.pendingOperationCountForTesting, 15)
    for token in retainedTokens { gateway.cancel(token) }
    XCTAssertEqual(retainedCancellationCount.value, 15)
    XCTAssertEqual(gateway.operationCountForTesting, 1)
    XCTAssertEqual(gateway.pendingOperationCountForTesting, 0)

    let cancellationCount = LockedCounter()
    for _ in 0..<100_000 {
      let token = gateway.loadChangeSnapshot { result in
        if case .failure(.cancelled) = result {
          cancellationCount.increment()
        } else {
          XCTFail("Queued replacement must complete as cancelled.")
        }
      }
      gateway.cancel(token)
    }
    XCTAssertEqual(cancellationCount.value, 100_000)
    XCTAssertEqual(gateway.operationCountForTesting, 1)
    XCTAssertEqual(gateway.pendingOperationCountForTesting, 0)

    operationGate.release()
    wait(for: [activeFinished], timeout: 2)
    XCTAssertEqual(gateway.operationCountForTesting, 0)
    XCTAssertEqual(gateway.pendingOperationCountForTesting, 0)
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  func testSQLiteOperationCancellationNeverInterruptsAnActiveSuccessor() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let completedOperationID = UUID()
    let successorOperationID = UUID()
    let pendingCancelledOperationID = UUID()

    try pool.queryReader.run(operationID: completedOperationID) { database in
      try ViewerSQLiteConnection.execute("SELECT 1", on: database)
    }

    let successorEntered = DispatchSemaphore(value: 0)
    let successorRelease = DispatchSemaphore(value: 0)
    let successorFinished = expectation(description: "Exact-cancellation successor finished")
    let errors = LockedViewerStoreErrors()
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try pool.queryReader.run(
          operationID: successorOperationID,
          budget: .query()
        ) { database in
          successorEntered.signal()
          successorRelease.wait()
          try ViewerSQLiteConnection.execute("SELECT 1", on: database)
        }
        errors.append(nil)
      } catch {
        errors.append(error as? ViewerStoreError)
      }
      successorFinished.fulfill()
    }
    XCTAssertEqual(successorEntered.wait(timeout: .now() + 1), .success)
    pool.queryReader.cancel(operationID: completedOperationID)
    successorRelease.signal()
    wait(for: [successorFinished], timeout: 2)
    XCTAssertEqual(errors.values, [nil])

    pool.queryReader.cancel(operationID: pendingCancelledOperationID)
    XCTAssertThrowsError(
      try pool.queryReader.run(operationID: pendingCancelledOperationID) { database in
        try ViewerSQLiteConnection.execute("SELECT 1", on: database)
      }
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
    pool.queryReader.clearCancellation(operationID: pendingCancelledOperationID)
    try pool.queryReader.run(operationID: pendingCancelledOperationID) { database in
      try ViewerSQLiteConnection.execute("SELECT 1", on: database)
    }
  }

  func testGatewayRegistersCancellationBeforeCompletionClearsEveryReader() throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let operationGate = ArmableViewerExecutionGate()
    let cancellationGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway(
      operationExecutionGate: { operationGate.run() },
      cancellationRegistrationGate: { cancellationGate.run() }
    )
    gateway.install(coordinator)

    operationGate.arm()
    cancellationGate.arm()
    let cancellationResult = LockedViewerExplorerResult<ViewerStoreChangeSnapshot>()
    let cancellationFinished = DispatchSemaphore(value: 0)
    let cancellationToken = gateway.loadChangeSnapshot { result in
      cancellationResult.set(result)
      cancellationFinished.signal()
    }
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)
    let cancellationReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      gateway.cancel(cancellationToken)
      cancellationReturned.signal()
    }
    XCTAssertEqual(cancellationGate.waitUntilBlocked(), .success)
    operationGate.release()
    XCTAssertEqual(cancellationFinished.wait(timeout: .now() + 0.05), .timedOut)
    cancellationGate.release()
    XCTAssertEqual(cancellationReturned.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(cancellationFinished.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(cancellationResult.failure, .cancelled)
    XCTAssertEqual(coordinator.services.query.cancelledOperationCountForTesting, 0)
    XCTAssertEqual(coordinator.services.export.cancelledOperationCountForTesting, 0)

    operationGate.arm()
    cancellationGate.arm()
    let sealResult = LockedViewerExplorerResult<ViewerStoreChangeSnapshot>()
    let sealedOperationFinished = DispatchSemaphore(value: 0)
    _ = gateway.loadChangeSnapshot { result in
      sealResult.set(result)
      sealedOperationFinished.signal()
    }
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)
    let sealReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      gateway.sealAndWait(originatingFrom: coordinator)
      sealReturned.signal()
    }
    XCTAssertEqual(cancellationGate.waitUntilBlocked(), .success)
    operationGate.release()
    XCTAssertEqual(sealedOperationFinished.wait(timeout: .now() + 0.05), .timedOut)
    cancellationGate.release()
    XCTAssertEqual(sealReturned.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(sealedOperationFinished.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(sealResult.failure, .storeReplaced)
    XCTAssertEqual(coordinator.services.query.cancelledOperationCountForTesting, 0)
    XCTAssertEqual(coordinator.services.export.cancelledOperationCountForTesting, 0)
    coordinator.closeStorage()
  }

  @MainActor
  func testStoreChangeBurstRetainsOneGatewayRequestAndOneDirtySuccessor() async throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let operationGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(coordinator)
    let runtimeLogicalID = UUID()
    let live = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: live
      )
    )

    operationGate.arm()
    controller.noteStoreChanged()
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)
    for _ in 0..<10_000 { controller.noteStoreChanged() }

    XCTAssertEqual(controller.changeSnapshotRequestCountForTesting, 1)
    XCTAssertTrue(controller.hasPendingChangeSnapshotSuccessorForTesting)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 1)
    XCTAssertEqual(gateway.operationCountForTesting, 1)

    operationGate.release()
    for _ in 0..<2_000 {
      if controller.changeSnapshotRequestCountForTesting == 2
        && controller.pendingCleanupWorkCount == 0 && gateway.operationCountForTesting == 0
      {
        break
      }
      await Task.yield()
    }
    XCTAssertEqual(controller.changeSnapshotRequestCountForTesting, 2)
    XCTAssertFalse(controller.hasPendingChangeSnapshotSuccessorForTesting)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(gateway.operationCountForTesting, 0)

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  @MainActor
  func testControllerHundredThousandReplacementsCancelBeforeSchedulingDelivery() async throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let runtimeLogicalID = UUID()
    _ = try coordinator.services.eventStore.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "controller-replacement-stress"
    )
    let operationGate = ArmableViewerExecutionGate()
    let deliveryClaims = LockedCounter()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(coordinator)
    let live = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: live
      ),
      operationDeliveryClaimed: { deliveryClaims.increment() }
    )
    controller.start()
    for _ in 0..<2_000 {
      if controller.canManageSelectedRecording && controller.pendingCleanupWorkCount == 0 { break }
      await Task.yield()
    }
    XCTAssertTrue(controller.canManageSelectedRecording)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    let baselineClaims = deliveryClaims.value

    operationGate.arm()
    controller.updateSelectedRecording(name: "Replacement 0", note: nil, pinned: false)
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)
    for index in 1...100_000 {
      controller.updateSelectedRecording(
        name: "Replacement \(index % 10)",
        note: nil,
        pinned: false
      )
    }
    XCTAssertEqual(controller.pendingCleanupWorkCount, 1)
    XCTAssertLessThanOrEqual(gateway.operationCountForTesting, 2)
    XCTAssertEqual(deliveryClaims.value, baselineClaims)

    await controller.sealAndClear().value
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(deliveryClaims.value, baselineClaims)
    operationGate.release()
    for _ in 0..<2_000 {
      if gateway.operationCountForTesting == 0 { break }
      await Task.yield()
    }
    XCTAssertEqual(gateway.operationCountForTesting, 0)
    XCTAssertEqual(deliveryClaims.value, baselineClaims)

    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  @MainActor
  func testControllerCleanupJoinsResultWhoseDeliveryWasAlreadyClaimed() async throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let runtimeLogicalID = UUID()
    _ = try coordinator.services.eventStore.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "controller-delivery-cleanup-race"
    )
    let deliveryGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let live = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: live
      ),
      operationDeliveryClaimed: { deliveryGate.run() }
    )
    controller.start()
    for _ in 0..<2_000 {
      if controller.canManageSelectedRecording && controller.pendingCleanupWorkCount == 0 { break }
      await Task.yield()
    }
    XCTAssertTrue(controller.canManageSelectedRecording)

    deliveryGate.arm()
    controller.updateSelectedRecording(name: "Claimed delivery", note: nil, pinned: false)
    XCTAssertEqual(deliveryGate.waitUntilBlocked(), .success)
    let cleanup = controller.sealAndClear()
    let cleanupCompletions = LockedCounter()
    Task {
      await cleanup.value
      cleanupCompletions.increment()
    }
    await Task.yield()
    XCTAssertEqual(cleanupCompletions.value, 0)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 1)

    deliveryGate.release()
    await cleanup.value
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    for _ in 0..<2_000 {
      if gateway.operationCountForTesting == 0 { break }
      await Task.yield()
    }
    XCTAssertEqual(gateway.operationCountForTesting, 0)

    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  @MainActor
  func testControllerRejectsClaimedCatalogFromReplacedGatewayGeneration() async throws {
    let runtimeLogicalID = UUID()
    let firstCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    _ = try firstCoordinator.services.eventStore.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "claimed-old-generation"
    )
    let replacementCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    _ = try replacementCoordinator.services.eventStore.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 3_000,
      monotonicNanoseconds: 4_000,
      reason: "replacement-generation"
    )
    let deliveryGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(firstCoordinator)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      ),
      operationDeliveryClaimed: { deliveryGate.run() }
    )

    deliveryGate.arm()
    controller.start()
    XCTAssertEqual(deliveryGate.waitUntilBlocked(), .success)
    gateway.install(replacementCoordinator)
    deliveryGate.release()
    for _ in 0..<2_000 where controller.pendingCleanupWorkCount != 0 { await Task.yield() }

    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertFalse(controller.canManageSelectedRecording)
    XCTAssertNil(controller.selectedRecordingRow)

    controller.noteStoreChanged()
    for _ in 0..<2_000 {
      if controller.canManageSelectedRecording && controller.pendingCleanupWorkCount == 0 { break }
      await Task.yield()
    }
    XCTAssertTrue(controller.canManageSelectedRecording)
    XCTAssertEqual(controller.selectedRecordingRow?.logicalID, runtimeLogicalID)

    controller.updateSelectedRecording(
      name: "Replacement generation",
      note: nil,
      pinned: false
    )
    for _ in 0..<2_000 {
      if case .succeeded = controller.recordingOperationState,
        controller.pendingCleanupWorkCount == 0
      {
        break
      }
      await Task.yield()
    }
    guard case .succeeded = controller.recordingOperationState else {
      return XCTFail("The replacement generation did not accept a fresh recording update.")
    }
    XCTAssertEqual(controller.selectedRecordingRow?.name, "Replacement generation")
    XCTAssertEqual(gateway.operationCountForTesting, 0)

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: replacementCoordinator)
    firstCoordinator.closeStorage()
    replacementCoordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationClearsReusedRowIDsUntilReplacementCatalogsCommit()
    async throws
  {
    let fixtureWallMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    let viewerRuntimeLogicalID = UUID()
    let oldRuntimeLogicalID = UUID()
    let oldDeviceLogicalID = UUID()
    let oldCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let oldRecording = try oldCoordinator.services.eventStore.beginRecording(
      logicalID: oldRuntimeLogicalID,
      wallMilliseconds: fixtureWallMilliseconds,
      monotonicNanoseconds: 2_000,
      reason: "old-rematerialization-store"
    )
    let oldDevice = try oldCoordinator.services.eventStore.beginDeviceSession(
      recording: oldRecording,
      installationID: "old-rematerialization-device",
      logicalID: oldDeviceLogicalID,
      wallMilliseconds: fixtureWallMilliseconds,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Old Rematerialization Device"
    )
    let oldEventRowID = try oldCoordinator.services.eventStore.appendEvent(
      makeObservation(
        recording: oldRecording,
        device: oldDevice,
        sequence: 1,
        value: "old-rematerialization-event"
      )
    )
    try oldCoordinator.services.eventStore.appendStructural(
      .closeDevice(
        oldDevice,
        wallMilliseconds: fixtureWallMilliseconds + 1,
        monotonicNanoseconds: 3_000
      )
    )
    try oldCoordinator.services.eventStore.appendStructural(
      .closeRecording(
        oldRecording,
        wallMilliseconds: fixtureWallMilliseconds + 2,
        monotonicNanoseconds: 4_000
      )
    )

    let newRuntimeLogicalID = UUID()
    let newDeviceLogicalID = UUID()
    let newCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let newRecording = try newCoordinator.services.eventStore.beginRecording(
      logicalID: newRuntimeLogicalID,
      wallMilliseconds: fixtureWallMilliseconds + 10,
      monotonicNanoseconds: 6_000,
      reason: "new-rematerialization-store"
    )
    let newDevice = try newCoordinator.services.eventStore.beginDeviceSession(
      recording: newRecording,
      installationID: "new-rematerialization-device",
      logicalID: newDeviceLogicalID,
      wallMilliseconds: fixtureWallMilliseconds + 10,
      monotonicNanoseconds: 6_000,
      partialHistory: false,
      displayName: "New Rematerialization Device"
    )
    let newEventRowID = try newCoordinator.services.eventStore.appendEvent(
      makeObservation(
        recording: newRecording,
        device: newDevice,
        sequence: 1,
        value: "new-rematerialization-event"
      )
    )
    try newCoordinator.services.eventStore.appendStructural(
      .closeDevice(
        newDevice,
        wallMilliseconds: fixtureWallMilliseconds + 11,
        monotonicNanoseconds: 7_000
      )
    )
    try newCoordinator.services.eventStore.appendStructural(
      .closeRecording(
        newRecording,
        wallMilliseconds: fixtureWallMilliseconds + 12,
        monotonicNanoseconds: 8_000
      )
    )
    XCTAssertEqual(oldRecording.rowID, newRecording.rowID)
    XCTAssertEqual(oldDevice.rowID, newDevice.rowID)
    XCTAssertEqual(oldEventRowID, newEventRowID)

    let operationGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(oldCoordinator)
    let oldCatalog: ViewerRecordingCatalogPage = try explorerValue(
      "Load predecessor rematerialization catalog"
    ) {
      gateway.loadRecordingCatalog(cursor: nil, completion: $0)
    }
    XCTAssertEqual(oldCatalog.rows.first?.logicalID, oldRuntimeLogicalID)
    let oldDeviceCatalog: ViewerDeviceCatalogPage = try explorerValue(
      "Load predecessor rematerialization devices"
    ) {
      gateway.loadDeviceCatalog(recordingID: oldRecording.rowID, cursor: nil, completion: $0)
    }
    XCTAssertEqual(oldDeviceCatalog.rows.first?.logicalID, oldDeviceLogicalID)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: viewerRuntimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: viewerRuntimeLogicalID)
      )
    )
    controller.start()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && !controller.model.recordingRows.isEmpty {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(controller.model.recordingRows.first?.logicalID, oldRuntimeLogicalID)
    controller.selectSource(
      .historical(recordingID: oldRecording.rowID, recordingLogicalID: oldRuntimeLogicalID)
    )
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && !controller.deviceRows.isEmpty { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(controller.deviceRows.first?.id, oldDeviceLogicalID)
    controller.toggleDevice(oldDeviceLogicalID)
    let predecessorSelection = controller.performanceTargetSelection()
    guard case .target(let oldTarget) = predecessorSelection else {
      return XCTFail(
        "Expected the predecessor Store target before replacement; got \(predecessorSelection), "
          + "recordings=\(controller.model.recordingRows), devices=\(controller.model.deviceRows), "
          + "selectedDevices=\(controller.selectedDeviceIDs)"
      )
    }
    XCTAssertEqual(oldTarget.storeIdentity.recordingID, oldRecording.rowID)
    XCTAssertEqual(oldTarget.storeIdentity.deviceSessionID, oldDevice.rowID)

    controller.pauseOrResume()
    let pendingOldIdentity = ViewerExplorerEventIdentity.durable(rowID: oldEventRowID)
    controller.revealExactEvent(pendingOldIdentity)
    XCTAssertEqual(controller.pendingExactRevealIdentityForTesting, pendingOldIdentity)

    gateway.install(newCoordinator)
    operationGate.arm()
    let rematerialization = controller.rematerializeAfterStoreReplacement()
    XCTAssertNil(controller.pendingExactRevealIdentityForTesting)
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("Predecessor row identity remained selectable during rematerialization")
    }
    let completionCount = LockedCounter()
    let completionObserver = Task {
      await rematerialization.value
      completionCount.increment()
    }
    await Task.yield()
    XCTAssertEqual(completionCount.value, 0)

    operationGate.release()
    await completionObserver.value
    XCTAssertEqual(completionCount.value, 1)
    XCTAssertEqual(controller.model.recordingRows.first?.logicalID, newRuntimeLogicalID)
    XCTAssertEqual(controller.model.deviceRows.first?.logicalID, nil)
    XCTAssertEqual(
      controller.selectedSourceID,
      .current(runtimeLogicalID: viewerRuntimeLogicalID)
    )
    XCTAssertTrue(controller.selectedDeviceIDs.isEmpty)
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("Replacement row identity became a selectable performance target")
    }
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: newCoordinator)
    oldCoordinator.closeStorage()
    newCoordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationUsesExactLogicalIdentityWithoutBroadeningMissingDevice()
    async throws
  {
    let wallMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    let viewerRuntimeLogicalID = UUID()
    let recordingLogicalID = UUID()
    let missingDeviceLogicalID = UUID()
    let oldCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let oldRecording = try oldCoordinator.services.eventStore.beginRecording(
      logicalID: recordingLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 1_000,
      reason: "exact-rematerialization-old"
    )
    let oldDevice = try oldCoordinator.services.eventStore.beginDeviceSession(
      recording: oldRecording,
      installationID: "exact-rematerialization-old-device",
      logicalID: missingDeviceLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 1_000,
      partialHistory: false,
      displayName: "Missing after replacement"
    )
    try oldCoordinator.services.eventStore.appendStructural(
      .closeDevice(
        oldDevice,
        wallMilliseconds: wallMilliseconds + 1,
        monotonicNanoseconds: 2_000
      )
    )
    try oldCoordinator.services.eventStore.appendStructural(
      .closeRecording(
        oldRecording,
        wallMilliseconds: wallMilliseconds + 2,
        monotonicNanoseconds: 3_000
      )
    )

    let replacementCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let replacementRecording = try replacementCoordinator.services.eventStore.beginRecording(
      logicalID: recordingLogicalID,
      wallMilliseconds: wallMilliseconds + 10,
      monotonicNanoseconds: 10_000,
      reason: "exact-rematerialization-replacement"
    )
    let reusedRowDeviceLogicalID = UUID()
    let reusedRowDevice = try replacementCoordinator.services.eventStore.beginDeviceSession(
      recording: replacementRecording,
      installationID: "exact-rematerialization-reused-device",
      logicalID: reusedRowDeviceLogicalID,
      wallMilliseconds: wallMilliseconds + 10,
      monotonicNanoseconds: 10_000,
      partialHistory: false,
      displayName: "Replacement row owner"
    )
    try replacementCoordinator.services.eventStore.appendStructural(
      .closeDevice(
        reusedRowDevice,
        wallMilliseconds: wallMilliseconds + 11,
        monotonicNanoseconds: 11_000
      )
    )
    for index in 0..<100 {
      let device = try replacementCoordinator.services.eventStore.beginDeviceSession(
        recording: replacementRecording,
        installationID: "exact-rematerialization-device-\(index)",
        logicalID: UUID(),
        wallMilliseconds: wallMilliseconds + 20 + Int64(index),
        monotonicNanoseconds: 20_000 + UInt64(index),
        partialHistory: false,
        displayName: "Replacement Device \(index)"
      )
      try replacementCoordinator.services.eventStore.appendStructural(
        .closeDevice(
          device,
          wallMilliseconds: wallMilliseconds + 21 + Int64(index),
          monotonicNanoseconds: 21_000 + UInt64(index)
        )
      )
    }
    try replacementCoordinator.services.eventStore.appendStructural(
      .closeRecording(
        replacementRecording,
        wallMilliseconds: wallMilliseconds + 200,
        monotonicNanoseconds: 200_000
      )
    )
    for index in 0..<50 {
      let recording = try replacementCoordinator.services.eventStore.beginRecording(
        logicalID: UUID(),
        wallMilliseconds: wallMilliseconds + 300 + Int64(index),
        monotonicNanoseconds: 300_000 + UInt64(index),
        reason: "newer-rematerialization-recording-\(index)"
      )
      try replacementCoordinator.services.eventStore.appendStructural(
        .closeRecording(
          recording,
          wallMilliseconds: wallMilliseconds + 301 + Int64(index),
          monotonicNanoseconds: 301_000 + UInt64(index)
        )
      )
    }
    XCTAssertEqual(oldRecording.rowID, replacementRecording.rowID)
    XCTAssertEqual(oldDevice.rowID, reusedRowDevice.rowID)

    let operationGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(oldCoordinator)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: viewerRuntimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: viewerRuntimeLogicalID)
      )
    )
    controller.start()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && !controller.model.recordingRows.isEmpty {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    controller.selectSource(
      .historical(
        recordingID: oldRecording.rowID,
        recordingLogicalID: recordingLogicalID
      )
    )
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && !controller.deviceRows.isEmpty { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertFalse(
      controller.deviceRows.isEmpty,
      "Predecessor devices did not materialize before exact rematerialization."
    )
    controller.toggleDevice(missingDeviceLogicalID)
    XCTAssertEqual(controller.selectedDeviceIDs, [missingDeviceLogicalID])
    guard case .target = controller.performanceTargetSelection() else {
      return XCTFail("Expected the predecessor device to be selectable before replacement")
    }

    gateway.install(replacementCoordinator)
    operationGate.arm(blockingCall: 5)
    let rematerialization = controller.rematerializeAfterStoreReplacement()
    let firstDeviceCatalogBlocked = await operationGate.waitUntilBlockedAsync()
    XCTAssertEqual(firstDeviceCatalogBlocked, .success)
    XCTAssertEqual(operationGate.value, 5)
    XCTAssertEqual(controller.selectedDeviceIDs, [missingDeviceLogicalID])
    XCTAssertFalse(controller.usesAllDevices)
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("A reused replacement row became an authorized performance target")
    }
    let replacementCatalog = try replacementCoordinator.services.catalog.recordingPage(
      storeGeneration: gateway.currentStoreGeneration,
      cursor: nil,
      limit: 100
    )
    let replacementRow = try XCTUnwrap(
      replacementCatalog.rows.first { $0.logicalID == recordingLogicalID }
    )
    _ = try replacementCoordinator.services.maintenance.updateRecording(
      ViewerRecordingRevision(
        recordingID: replacementRecording.rowID,
        revision: replacementRow.revision
      ),
      name: "Changed between catalog phases",
      note: nil,
      pinned: false,
      wallMilliseconds: wallMilliseconds + 500
    )
    let completionCount = LockedCounter()
    let completionObserver = Task {
      await rematerialization.value
      completionCount.increment()
    }
    await Task.yield()
    XCTAssertEqual(completionCount.value, 0)

    operationGate.release()
    await completionObserver.value
    XCTAssertEqual(completionCount.value, 1)
    XCTAssertEqual(
      controller.selectedSourceID,
      .historical(
        recordingID: replacementRecording.rowID,
        recordingLogicalID: recordingLogicalID
      )
    )
    XCTAssertEqual(controller.selectedRecordingRow?.logicalID, recordingLogicalID)
    XCTAssertEqual(controller.selectedRecordingRow?.name, "Changed between catalog phases")
    XCTAssertGreaterThan(operationGate.value, 6)
    XCTAssertFalse(
      controller.model.recordingRows.prefix(50).contains { row in
        row.logicalID == recordingLogicalID
      })
    XCTAssertEqual(controller.selectedDeviceIDs, [missingDeviceLogicalID])
    XCTAssertFalse(controller.usesAllDevices)
    XCTAssertFalse(
      controller.model.deviceRows.contains { row in
        row.logicalID == missingDeviceLogicalID
      })
    XCTAssertNil(controller.model.compiledInputs?.durableQuery)
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("A missing logical device broadened the replacement scope")
    }
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: replacementCoordinator)
    oldCoordinator.closeStorage()
    replacementCoordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationFailurePublishesTerminalStateAndPreservesExplicitScope()
    async throws
  {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let viewerRuntimeLogicalID = UUID()
    let historicalLogicalID = UUID()
    let historicalDeviceLogicalID = UUID()
    let wallMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    let historicalRecording = try coordinator.services.eventStore.beginRecording(
      logicalID: historicalLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000,
      reason: "failed-rematerialization"
    )
    let historicalDevice = try coordinator.services.eventStore.beginDeviceSession(
      recording: historicalRecording,
      installationID: "failed-rematerialization-device",
      logicalID: historicalDeviceLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Fail-closed device"
    )
    try coordinator.services.eventStore.appendStructural(
      .closeDevice(
        historicalDevice,
        wallMilliseconds: wallMilliseconds + 1,
        monotonicNanoseconds: 2_001
      )
    )
    try coordinator.services.eventStore.appendStructural(
      .closeRecording(
        historicalRecording,
        wallMilliseconds: wallMilliseconds + 2,
        monotonicNanoseconds: 2_002
      )
    )
    for index in 0..<55 {
      let recording = try coordinator.services.eventStore.beginRecording(
        logicalID: UUID(),
        wallMilliseconds: wallMilliseconds + 10 + Int64(index),
        monotonicNanoseconds: 3_000 + UInt64(index),
        reason: "failed-rematerialization-paging-\(index)"
      )
      try coordinator.services.eventStore.appendStructural(
        .closeRecording(
          recording,
          wallMilliseconds: wallMilliseconds + 11 + Int64(index),
          monotonicNanoseconds: 4_000 + UInt64(index)
        )
      )
    }
    let reusedCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let reusedLogicalID = UUID()
    let reusedRecording = try reusedCoordinator.services.eventStore.beginRecording(
      logicalID: reusedLogicalID,
      wallMilliseconds: wallMilliseconds + 100,
      monotonicNanoseconds: 10_000,
      reason: "failed-rematerialization-reused-row"
    )
    try reusedCoordinator.services.eventStore.appendStructural(
      .closeRecording(
        reusedRecording,
        wallMilliseconds: wallMilliseconds + 101,
        monotonicNanoseconds: 10_001
      )
    )
    XCTAssertEqual(historicalRecording.rowID, reusedRecording.rowID)
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: viewerRuntimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: viewerRuntimeLogicalID)
      )
    )
    controller.start()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && controller.hasOlderRecordings {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(controller.hasOlderRecordings)
    controller.loadOlderRecordings()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0,
        controller.model.recordingRows.contains(where: { $0.logicalID == historicalLogicalID })
      {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(
      controller.model.recordingRows.contains { $0.logicalID == historicalLogicalID }
    )
    controller.selectSource(
      .historical(
        recordingID: historicalRecording.rowID,
        recordingLogicalID: historicalLogicalID
      )
    )
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && !controller.deviceRows.isEmpty { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertFalse(
      controller.deviceRows.isEmpty,
      "Historical devices did not materialize before the failure test."
    )
    controller.toggleDevice(historicalDeviceLogicalID)
    XCTAssertEqual(controller.selectedDeviceIDs, [historicalDeviceLogicalID])
    guard case .target = controller.performanceTargetSelection() else {
      return XCTFail("Expected an explicit historical target before Store failure")
    }

    gateway.sealAndWait(originatingFrom: coordinator)
    let completionCount = LockedCounter()
    let rematerialization = controller.rematerializeAfterStoreReplacement()
    XCTAssertTrue(controller.model.recordingRows.isEmpty)
    XCTAssertNil(controller.selectedRecordingRow)
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("Predecessor identity survived failed Store rematerialization")
    }
    let completionObserver = Task {
      await rematerialization.value
      completionCount.increment()
    }
    await completionObserver.value

    XCTAssertEqual(completionCount.value, 1)
    XCTAssertEqual(controller.recordingsState, .empty)
    XCTAssertEqual(controller.devicesState, .empty)
    XCTAssertTrue(controller.model.recordingRows.isEmpty)
    XCTAssertTrue(controller.model.deviceRows.isEmpty)
    XCTAssertNil(controller.model.compiledInputs?.durableQuery)
    XCTAssertEqual(
      controller.selectedSourceID,
      .historical(
        recordingID: historicalRecording.rowID,
        recordingLogicalID: historicalLogicalID
      )
    )
    XCTAssertEqual(controller.selectedDeviceIDs, [historicalDeviceLogicalID])
    XCTAssertFalse(controller.usesAllDevices)
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("Failed rematerialization retained an executable stale Store target")
    }
    XCTAssertFalse(controller.canManageSelectedRecording)
    controller.clearFilter()
    XCTAssertNil(controller.model.compiledInputs)
    XCTAssertEqual(controller.selectedDeviceIDs, [historicalDeviceLogicalID])
    controller.selectAllDevices()
    XCTAssertNil(controller.model.compiledInputs)
    XCTAssertTrue(controller.usesAllDevices)

    gateway.install(coordinator)
    controller.noteStoreChanged()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && controller.hasOlderRecordings { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(controller.hasOlderRecordings)
    XCTAssertNil(controller.selectedRecordingRow)
    XCTAssertFalse(controller.canManageSelectedRecording)
    XCTAssertNil(controller.model.compiledInputs)
    controller.loadOlderRecordings()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0,
        controller.model.recordingRows.contains(where: { $0.logicalID == historicalLogicalID })
      {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(
      controller.model.recordingRows.contains { $0.logicalID == historicalLogicalID }
    )
    XCTAssertNil(controller.selectedRecordingRow)
    XCTAssertFalse(controller.canManageSelectedRecording)
    XCTAssertNil(controller.model.compiledInputs)
    let workBeforeDevicePaging = controller.pendingCleanupWorkCount
    controller.loadOlderDevices()
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(controller.pendingCleanupWorkCount, workBeforeDevicePaging)
    controller.updateSelectedRecording(name: "Must not reach Store", note: nil, pinned: false)
    XCTAssertEqual(controller.recordingOperationState, .failed(.unavailable))
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("Ordinary paging restored failed historical authority")
    }

    gateway.install(reusedCoordinator)
    controller.noteStoreChanged()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0,
        controller.model.recordingRows.contains(where: { $0.logicalID == reusedLogicalID })
      {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(
      controller.model.recordingRows.contains { row in
        row.rowID == historicalRecording.rowID && row.logicalID == reusedLogicalID
      }
    )
    XCTAssertNil(controller.selectedRecordingRow)
    XCTAssertFalse(controller.canManageSelectedRecording)
    XCTAssertNil(controller.model.compiledInputs)
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("Reused numeric row ID restored failed historical authority")
    }

    controller.selectSource(.current(runtimeLogicalID: viewerRuntimeLogicalID))
    XCTAssertNil(controller.model.compiledInputs?.durableQuery)
    XCTAssertNotNil(controller.model.compiledInputs?.liveRequest)
    XCTAssertNil(controller.model.materializationSnapshot?.recordingID)
    XCTAssertTrue(
      controller.model.materializationSnapshot?.deviceSessionIDsByLogicalID.isEmpty == true)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: reusedCoordinator)
    coordinator.closeStorage()
    reusedCoordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationClearsPartialCatalogAuthorityAfterDevicePhaseFailure()
    async throws
  {
    let wallMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    let viewerRuntimeLogicalID = UUID()
    let historicalLogicalID = UUID()
    let historicalDeviceLogicalID = UUID()
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let historicalRecording = try coordinator.services.eventStore.beginRecording(
      logicalID: historicalLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 1_000,
      reason: "partial-catalog-failure"
    )
    let historicalDevice = try coordinator.services.eventStore.beginDeviceSession(
      recording: historicalRecording,
      installationID: "partial-catalog-failure-device",
      logicalID: historicalDeviceLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 1_000,
      partialHistory: false,
      displayName: "Partial catalog device"
    )
    try coordinator.services.eventStore.appendStructural(
      .closeDevice(
        historicalDevice,
        wallMilliseconds: wallMilliseconds + 1,
        monotonicNanoseconds: 2_000
      )
    )
    try coordinator.services.eventStore.appendStructural(
      .closeRecording(
        historicalRecording,
        wallMilliseconds: wallMilliseconds + 2,
        monotonicNanoseconds: 3_000
      )
    )

    let deviceCatalogFault = OneShotViewerStoreFault()
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let contentDriver = ViewerExplorerContentDriver(
      gateway: gateway,
      loadDeviceCatalog: {
        recordingID, recordingSnapshot, cursor, direction, limit, completion in
        let submittedRecordingID: Int64
        do {
          try deviceCatalogFault.check()
          submittedRecordingID = recordingID
        } catch {
          submittedRecordingID = 0
        }
        return gateway.loadDeviceCatalog(
          recordingID: submittedRecordingID,
          recordingSnapshot: recordingSnapshot,
          cursor: cursor,
          direction: direction,
          limit: limit,
          completion: completion
        )
      }
    )
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: viewerRuntimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: viewerRuntimeLogicalID)
      ),
      contentDriver: contentDriver
    )
    controller.start()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && !controller.model.recordingRows.isEmpty {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    controller.selectSource(
      .historical(
        recordingID: historicalRecording.rowID,
        recordingLogicalID: historicalLogicalID
      )
    )
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && !controller.deviceRows.isEmpty { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    controller.toggleDevice(historicalDeviceLogicalID)
    guard case .target = controller.performanceTargetSelection() else {
      return XCTFail("Expected the predecessor historical target before partial failure")
    }

    deviceCatalogFault.failNext()
    await controller.rematerializeAfterStoreReplacement().value
    XCTAssertEqual(deviceCatalogFault.failureCount, 1)

    XCTAssertTrue(controller.model.recordingRows.isEmpty)
    XCTAssertTrue(controller.model.deviceRows.isEmpty)
    XCTAssertNil(controller.deviceCatalogRecordingID)
    XCTAssertNil(controller.model.compiledInputs)
    XCTAssertFalse(controller.canManageSelectedRecording)
    XCTAssertEqual(
      controller.selectedSourceID,
      .historical(
        recordingID: historicalRecording.rowID,
        recordingLogicalID: historicalLogicalID
      )
    )
    XCTAssertEqual(controller.selectedDeviceIDs, [historicalDeviceLogicalID])
    controller.clearFilter()
    XCTAssertNil(controller.model.compiledInputs)
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("Partial catalog failure retained executable replacement authority")
    }
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(gateway.operationCountForTesting, 0)

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationClearsCommittedDevicePageAfterExactIdentityFailure()
    async throws
  {
    let wallMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    let viewerRuntimeLogicalID = UUID()
    let historicalLogicalID = UUID()
    let selectedDeviceLogicalID = UUID()
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let historicalRecording = try coordinator.services.eventStore.beginRecording(
      logicalID: historicalLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 1_000,
      reason: "exact-device-failure"
    )
    let selectedDevice = try coordinator.services.eventStore.beginDeviceSession(
      recording: historicalRecording,
      installationID: "exact-device-failure-selected",
      logicalID: selectedDeviceLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 1_000,
      partialHistory: false,
      displayName: "Exact identity device"
    )
    try coordinator.services.eventStore.appendStructural(
      .closeDevice(
        selectedDevice,
        wallMilliseconds: wallMilliseconds + 1,
        monotonicNanoseconds: 2_000
      )
    )
    for index in 0..<100 {
      let device = try coordinator.services.eventStore.beginDeviceSession(
        recording: historicalRecording,
        installationID: "exact-device-failure-\(index)",
        logicalID: UUID(),
        wallMilliseconds: wallMilliseconds + 10 + Int64(index),
        monotonicNanoseconds: 3_000 + UInt64(index),
        partialHistory: false,
        displayName: "Exact identity page \(index)"
      )
      try coordinator.services.eventStore.appendStructural(
        .closeDevice(
          device,
          wallMilliseconds: wallMilliseconds + 11 + Int64(index),
          monotonicNanoseconds: 4_000 + UInt64(index)
        )
      )
    }
    try coordinator.services.eventStore.appendStructural(
      .closeRecording(
        historicalRecording,
        wallMilliseconds: wallMilliseconds + 200,
        monotonicNanoseconds: 10_000
      )
    )

    let identityFault = OneShotViewerStoreFault()
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let contentDriver = ViewerExplorerContentDriver(
      gateway: gateway,
      loadDeviceIdentities: {
        recordingID, logicalIDs, snapshot, completion in
        let submittedRecordingID: Int64
        do {
          try identityFault.check()
          submittedRecordingID = recordingID
        } catch {
          submittedRecordingID = 0
        }
        return gateway.loadDeviceIdentities(
          recordingID: submittedRecordingID,
          logicalIDs: logicalIDs,
          snapshot: snapshot,
          completion: completion
        )
      }
    )
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: viewerRuntimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: viewerRuntimeLogicalID)
      ),
      contentDriver: contentDriver
    )
    controller.start()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && !controller.model.recordingRows.isEmpty {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    controller.selectSource(
      .historical(
        recordingID: historicalRecording.rowID,
        recordingLogicalID: historicalLogicalID
      )
    )
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && controller.model.deviceRows.count == 100 {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(controller.model.deviceRows.count, 100)
    XCTAssertFalse(
      controller.model.deviceRows.contains { $0.logicalID == selectedDeviceLogicalID }
    )
    XCTAssertTrue(controller.hasOlderDevices)
    controller.loadOlderDevices()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && controller.model.deviceRows.count == 101 {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(controller.model.deviceRows.count, 101)
    controller.toggleDevice(selectedDeviceLogicalID)
    XCTAssertEqual(controller.selectedDeviceIDs, [selectedDeviceLogicalID])
    guard case .target = controller.performanceTargetSelection() else {
      return XCTFail("Expected the paged predecessor device to be selectable")
    }

    identityFault.failNext()
    await controller.rematerializeAfterStoreReplacement().value
    XCTAssertEqual(identityFault.failureCount, 1)
    XCTAssertTrue(controller.model.recordingRows.isEmpty)
    XCTAssertTrue(controller.model.deviceRows.isEmpty)
    XCTAssertNil(controller.deviceCatalogRecordingID)
    XCTAssertNil(controller.selectedRecordingRow)
    XCTAssertNil(controller.model.compiledInputs)
    XCTAssertFalse(controller.canManageSelectedRecording)
    XCTAssertEqual(controller.selectedDeviceIDs, [selectedDeviceLogicalID])
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("Exact-device failure retained partial device authority")
    }
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(gateway.operationCountForTesting, 0)

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationDevicePhaseSwitchToLiveCompletesReceiptAndSuccessor()
    async throws
  {
    let wallMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    let viewerRuntimeLogicalID = UUID()
    let historicalLogicalID = UUID()
    let routedUserRematerializations = LockedCounter()
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let historicalRecording = try coordinator.services.eventStore.beginRecording(
      logicalID: historicalLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 1_000,
      reason: "device-phase-live-switch"
    )
    let historicalDevice = try coordinator.services.eventStore.beginDeviceSession(
      recording: historicalRecording,
      installationID: "device-phase-live-switch",
      logicalID: UUID(),
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 1_000,
      partialHistory: false,
      displayName: "Pending device"
    )
    try coordinator.services.eventStore.appendStructural(
      .closeDevice(
        historicalDevice,
        wallMilliseconds: wallMilliseconds + 1,
        monotonicNanoseconds: 2_000
      )
    )
    try coordinator.services.eventStore.appendStructural(
      .closeRecording(
        historicalRecording,
        wallMilliseconds: wallMilliseconds + 2,
        monotonicNanoseconds: 3_000
      )
    )

    let deviceCompletionGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let contentDriver = ViewerExplorerContentDriver(
      gateway: gateway,
      loadDeviceCatalog: {
        recordingID, recordingSnapshot, cursor, direction, limit, completion in
        gateway.loadDeviceCatalog(
          recordingID: recordingID,
          recordingSnapshot: recordingSnapshot,
          cursor: cursor,
          direction: direction,
          limit: limit
        ) { result in
          deviceCompletionGate.run()
          completion(result)
        }
      }
    )
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: viewerRuntimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: viewerRuntimeLogicalID)
      ),
      contentDriver: contentDriver
    )
    controller.setAnalysisRematerializationHandler { _ in
      routedUserRematerializations.increment()
    }
    controller.start()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && !controller.model.recordingRows.isEmpty {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    controller.selectSource(
      .historical(
        recordingID: historicalRecording.rowID,
        recordingLogicalID: historicalLogicalID
      )
    )
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && !controller.model.deviceRows.isEmpty { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertFalse(controller.model.deviceRows.isEmpty)

    deviceCompletionGate.arm()
    let rematerialization = controller.rematerializeAfterStoreReplacement()
    let deviceCatalogBlocked = await deviceCompletionGate.waitUntilBlockedAsync()
    XCTAssertEqual(deviceCatalogBlocked, .success)
    XCTAssertEqual(deviceCompletionGate.value, 1)
    controller.noteStoreChanged()
    XCTAssertTrue(controller.hasPendingChangeSnapshotSuccessorForTesting)

    let receiptCompletion = expectation(description: "Live switch completes receipt")
    Task { @MainActor in
      await rematerialization.value
      receiptCompletion.fulfill()
    }
    controller.selectSource(.current(runtimeLogicalID: viewerRuntimeLogicalID))
    await fulfillment(of: [receiptCompletion], timeout: 1)
    XCTAssertEqual(controller.changeSnapshotRequestCountForTesting, 2)
    XCTAssertFalse(controller.hasPendingChangeSnapshotSuccessorForTesting)
    XCTAssertNil(controller.model.compiledInputs?.durableQuery)
    XCTAssertNotNil(controller.model.compiledInputs?.liveRequest)
    XCTAssertNil(controller.model.materializationSnapshot?.recordingID)
    XCTAssertTrue(
      controller.model.materializationSnapshot?.deviceSessionIDsByLogicalID.isEmpty == true)
    XCTAssertNil(controller.selectedRecordingRow)
    guard case .guidance = controller.performanceTargetSelection() else {
      return XCTFail("Live switch retained the pending Store target")
    }

    deviceCompletionGate.release()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && gateway.operationCountForTesting == 0 { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(gateway.operationCountForTesting, 0)
    XCTAssertNil(controller.model.compiledInputs?.durableQuery)
    XCTAssertNotNil(controller.model.compiledInputs?.liveRequest)
    XCTAssertNil(controller.model.materializationSnapshot?.recordingID)
    XCTAssertTrue(
      controller.model.materializationSnapshot?.deviceSessionIDsByLogicalID.isEmpty == true)

    XCTAssertTrue(
      controller.model.recordingRows.contains { $0.logicalID == historicalLogicalID }
    )
    deviceCompletionGate.arm()
    controller.selectSource(
      .historical(
        recordingID: historicalRecording.rowID,
        recordingLogicalID: historicalLogicalID
      )
    )
    XCTAssertEqual(routedUserRematerializations.value, 1)
    let freshHistoricalDeviceBlocked = await deviceCompletionGate.waitUntilBlockedAsync()
    XCTAssertEqual(freshHistoricalDeviceBlocked, .success)
    XCTAssertEqual(
      controller.selectedSourceID,
      .historical(
        recordingID: historicalRecording.rowID,
        recordingLogicalID: historicalLogicalID
      )
    )
    XCTAssertNil(controller.model.compiledInputs)
    XCTAssertNil(controller.model.materializationSnapshot)
    XCTAssertGreaterThan(controller.pendingCleanupWorkCount, 0)

    deviceCompletionGate.release()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && gateway.operationCountForTesting == 0 { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(controller.changeSnapshotRequestCountForTesting, 3)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(gateway.operationCountForTesting, 0)
    XCTAssertEqual(controller.selectedRecordingRow?.logicalID, historicalLogicalID)
    XCTAssertEqual(
      controller.model.compiledInputs?.durableQuery?.recordingID,
      historicalRecording.rowID
    )
    XCTAssertNil(controller.model.compiledInputs?.liveRequest)
    XCTAssertEqual(
      controller.model.materializationSnapshot?.recordingID,
      historicalRecording.rowID
    )

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationActiveHistoricalSwitchRestartsOneReceiptForNewIdentity()
    async throws
  {
    let wallMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    let viewerRuntimeLogicalID = UUID()
    let firstLogicalID = UUID()
    let firstDeviceLogicalID = UUID()
    let secondLogicalID = UUID()
    let secondDeviceLogicalID = UUID()
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let firstRecording = try coordinator.services.eventStore.beginRecording(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 1_000,
      reason: "active-historical-switch-first"
    )
    let firstDevice = try coordinator.services.eventStore.beginDeviceSession(
      recording: firstRecording,
      installationID: "active-historical-switch-first",
      logicalID: firstDeviceLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 1_000,
      partialHistory: false,
      displayName: "First historical device"
    )
    try coordinator.services.eventStore.appendStructural(
      .closeDevice(
        firstDevice,
        wallMilliseconds: wallMilliseconds + 1,
        monotonicNanoseconds: 2_000
      )
    )
    try coordinator.services.eventStore.appendStructural(
      .closeRecording(
        firstRecording,
        wallMilliseconds: wallMilliseconds + 2,
        monotonicNanoseconds: 3_000
      )
    )
    let secondRecording = try coordinator.services.eventStore.beginRecording(
      logicalID: secondLogicalID,
      wallMilliseconds: wallMilliseconds + 10,
      monotonicNanoseconds: 4_000,
      reason: "active-historical-switch-second"
    )
    let secondDevice = try coordinator.services.eventStore.beginDeviceSession(
      recording: secondRecording,
      installationID: "active-historical-switch-second",
      logicalID: secondDeviceLogicalID,
      wallMilliseconds: wallMilliseconds + 10,
      monotonicNanoseconds: 4_000,
      partialHistory: false,
      displayName: "Second historical device"
    )
    try coordinator.services.eventStore.appendStructural(
      .closeDevice(
        secondDevice,
        wallMilliseconds: wallMilliseconds + 11,
        monotonicNanoseconds: 5_000
      )
    )
    try coordinator.services.eventStore.appendStructural(
      .closeRecording(
        secondRecording,
        wallMilliseconds: wallMilliseconds + 12,
        monotonicNanoseconds: 6_000
      )
    )

    let deviceCompletionGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let contentDriver = ViewerExplorerContentDriver(
      gateway: gateway,
      loadDeviceCatalog: {
        recordingID, recordingSnapshot, cursor, direction, limit, completion in
        gateway.loadDeviceCatalog(
          recordingID: recordingID,
          recordingSnapshot: recordingSnapshot,
          cursor: cursor,
          direction: direction,
          limit: limit
        ) { result in
          deviceCompletionGate.run()
          completion(result)
        }
      }
    )
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: viewerRuntimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: viewerRuntimeLogicalID)
      ),
      contentDriver: contentDriver
    )
    controller.start()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && controller.model.recordingRows.count == 2 {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    controller.selectSource(
      .historical(
        recordingID: firstRecording.rowID,
        recordingLogicalID: firstLogicalID
      )
    )
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0,
        controller.model.deviceRows.contains(where: { $0.logicalID == firstDeviceLogicalID })
      {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(controller.model.deviceRows.first?.logicalID, firstDeviceLogicalID)

    deviceCompletionGate.arm()
    let rematerialization = controller.rematerializeAfterStoreReplacement()
    let firstDeviceCatalogBlocked = await deviceCompletionGate.waitUntilBlockedAsync()
    XCTAssertEqual(firstDeviceCatalogBlocked, .success)
    XCTAssertEqual(deviceCompletionGate.value, 1)
    XCTAssertTrue(
      controller.sourceRows.contains {
        $0.id
          == .historical(
            recordingID: secondRecording.rowID,
            recordingLogicalID: secondLogicalID
          )
      }
    )
    controller.noteStoreChanged()
    XCTAssertTrue(controller.hasPendingChangeSnapshotSuccessorForTesting)

    let receiptCompletions = LockedCounter()
    let completionObserver = Task { @MainActor in
      await rematerialization.value
      receiptCompletions.increment()
    }
    controller.selectSource(
      .historical(
        recordingID: secondRecording.rowID,
        recordingLogicalID: secondLogicalID
      )
    )
    await Task.yield()
    XCTAssertEqual(receiptCompletions.value, 0)
    XCTAssertEqual(
      controller.selectedSourceID,
      .historical(
        recordingID: secondRecording.rowID,
        recordingLogicalID: secondLogicalID
      )
    )
    XCTAssertNil(controller.model.compiledInputs)

    deviceCompletionGate.release()
    await completionObserver.value
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0 && gateway.operationCountForTesting == 0 { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(receiptCompletions.value, 1)
    XCTAssertEqual(controller.changeSnapshotRequestCountForTesting, 2)
    XCTAssertFalse(controller.hasPendingChangeSnapshotSuccessorForTesting)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(gateway.operationCountForTesting, 0)
    XCTAssertEqual(controller.selectedRecordingRow?.logicalID, secondLogicalID)
    XCTAssertEqual(controller.model.deviceRows.map(\.logicalID), [secondDeviceLogicalID])
    XCTAssertFalse(
      controller.model.deviceRows.contains { $0.logicalID == firstDeviceLogicalID }
    )
    XCTAssertEqual(
      controller.model.compiledInputs?.durableQuery?.recordingID,
      secondRecording.rowID
    )
    XCTAssertNil(controller.model.compiledInputs?.liveRequest)
    XCTAssertEqual(
      controller.model.materializationSnapshot?.recordingID,
      secondRecording.rowID
    )

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationRevokesPreparedExportAndDestinationAuthority()
    async throws
  {
    let fixture = try await makePreparedControllerExportFixture(
      reason: "prepared-export-rematerialization"
    )
    let delayedSelection = DelayedViewerExportDestinationSelection()
    fixture.controller.beginExportDestinationSelection { completion in
      delayedSelection.start(completion)
    }
    XCTAssertTrue(delayedSelection.hasCompletion)

    let rematerialization = fixture.controller.rematerializeAfterStoreReplacement()
    XCTAssertEqual(delayedSelection.cancellationCount, 1)
    XCTAssertEqual(fixture.controller.exportState, .idle)
    XCTAssertFalse(fixture.controller.canManageSelectedRecording)
    await rematerialization.value

    let staleDestination = fixture.paths.directory.appendingPathComponent("stale-export.json")
    delayedSelection.respond(staleDestination)
    for _ in 0..<100 { await Task.yield() }
    XCTAssertFalse(FileManager.default.fileExists(atPath: staleDestination.path))
    XCTAssertEqual(fixture.controller.exportState, .idle)
    XCTAssertEqual(fixture.controller.pendingCleanupWorkCount, 0)

    await fixture.controller.sealAndClear().value
    fixture.gateway.sealAndWait(originatingFrom: fixture.coordinator)
    fixture.coordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationRevokesPreparedDeleteAuthority() async throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let wallMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    let historicalLogicalID = UUID()
    let historicalRecording = try coordinator.services.eventStore.beginRecording(
      logicalID: historicalLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000,
      reason: "prepared-delete-rematerialization"
    )
    try coordinator.services.eventStore.appendStructural(
      .closeRecording(
        historicalRecording,
        wallMilliseconds: wallMilliseconds + 1,
        monotonicNanoseconds: 3_000
      )
    )
    let runtimeLogicalID = UUID()
    _ = try coordinator.services.eventStore.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: wallMilliseconds + 2,
      monotonicNanoseconds: 4_000,
      reason: "prepared-delete-current"
    )
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      )
    )
    controller.start()
    for _ in 0..<2_000 {
      if controller.pendingCleanupWorkCount == 0,
        controller.model.recordingRows.contains(where: { $0.logicalID == historicalLogicalID })
      {
        break
      }
      await Task.yield()
    }
    controller.selectSource(
      .historical(
        recordingID: historicalRecording.rowID,
        recordingLogicalID: historicalLogicalID
      )
    )
    for _ in 0..<2_000 {
      if controller.canManageSelectedRecording && controller.pendingCleanupWorkCount == 0 { break }
      await Task.yield()
    }
    XCTAssertTrue(controller.canManageSelectedRecording)
    controller.prepareSelectedRecordingDelete()
    for _ in 0..<2_000 {
      if controller.recordingOperationState == .awaitingDeleteConfirmation,
        controller.pendingCleanupWorkCount == 0
      {
        break
      }
      await Task.yield()
    }
    XCTAssertEqual(controller.recordingOperationState, .awaitingDeleteConfirmation)

    await controller.rematerializeAfterStoreReplacement().value
    XCTAssertEqual(controller.recordingOperationState, .idle)
    controller.confirmSelectedRecordingDelete()
    for _ in 0..<2_000 where controller.pendingCleanupWorkCount != 0 { await Task.yield() }
    XCTAssertEqual(controller.recordingOperationState, .failed(.invalidRequest))
    XCTAssertTrue(
      controller.model.recordingRows.contains { row in
        row.logicalID == historicalLogicalID
      })

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationPreservesAuthoritativeCommittedExportCompletion()
    async throws
  {
    let completionGate = ArmableViewerExecutionGate()
    let fixture = try await makePreparedControllerExportFixture(
      operationCompletionGate: { completionGate.run() },
      reason: "committed-export-rematerialization"
    )
    let destination = fixture.paths.directory.appendingPathComponent(
      "committed-rematerialization.json"
    )
    completionGate.arm()
    fixture.controller.executePreparedExport(to: destination)
    XCTAssertEqual(completionGate.waitUntilBlocked(), .success)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

    let replacementCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    _ = try replacementCoordinator.services.eventStore.beginRecording(
      logicalID: UUID(),
      wallMilliseconds: 2_000,
      monotonicNanoseconds: 3_000,
      reason: "committed-export-replacement"
    )
    let replacementFinished = expectation(description: "Replacement waits for committed export")
    DispatchQueue.global(qos: .userInitiated).async {
      fixture.gateway.install(replacementCoordinator)
      replacementFinished.fulfill()
    }
    for _ in 0..<2_000 where fixture.gateway.currentStoreGeneration != 0 {
      await Task.yield()
    }
    XCTAssertEqual(fixture.gateway.currentStoreGeneration, 0)

    let rematerialization = fixture.controller.rematerializeAfterStoreReplacement()
    XCTAssertEqual(fixture.controller.exportState, .cancelling(eventCount: 0))
    completionGate.release()
    await fulfillment(of: [replacementFinished], timeout: 2)
    await rematerialization.value
    for _ in 0..<2_000 {
      if fixture.controller.exportState == .completed(eventCount: 0),
        fixture.controller.pendingCleanupWorkCount == 0
      {
        break
      }
      await Task.yield()
    }
    XCTAssertEqual(fixture.controller.exportState, .completed(eventCount: 0))
    XCTAssertEqual(fixture.controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(fixture.gateway.operationCountForTesting, 0)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    XCTAssertEqual(root["schemaVersion"] as? Int, 1)

    await fixture.controller.sealAndClear().value
    fixture.gateway.sealAndWait(originatingFrom: replacementCoordinator)
    fixture.coordinator.closeStorage()
    replacementCoordinator.closeStorage()
  }

  @MainActor
  func testStoreRematerializationRetainsDirtyChangeUntilOneSuccessorSnapshotCompletes()
    async throws
  {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let runtimeLogicalID = UUID()
    _ = try coordinator.services.eventStore.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "dirty-rematerialization"
    )
    let operationGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(coordinator)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      )
    )

    operationGate.arm(blockingCall: 3)
    let rematerialization = controller.rematerializeAfterStoreReplacement()
    let recordingCatalogBlocked = await operationGate.waitUntilBlockedAsync()
    XCTAssertEqual(recordingCatalogBlocked, .success)
    XCTAssertEqual(operationGate.value, 3)
    controller.noteStoreChanged()
    XCTAssertTrue(controller.hasPendingChangeSnapshotSuccessorForTesting)
    XCTAssertEqual(controller.changeSnapshotRequestCountForTesting, 1)

    operationGate.release()
    await rematerialization.value
    for _ in 0..<2_000 {
      if controller.changeSnapshotRequestCountForTesting == 2,
        controller.pendingCleanupWorkCount == 0
      {
        break
      }
      await Task.yield()
    }
    XCTAssertEqual(controller.changeSnapshotRequestCountForTesting, 2)
    XCTAssertFalse(controller.hasPendingChangeSnapshotSuccessorForTesting)
    XCTAssertEqual(controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(gateway.operationCountForTesting, 0)

    await controller.sealAndClear().value
    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  @MainActor
  func testDelayedExportDestinationCannotMutateOrRetainSealedExplorer() async throws {
    let paths = try makePaths()
    let coordinator = try ViewerStoreCoordinator(paths: paths)
    let runtimeLogicalID = UUID()
    _ = try coordinator.services.eventStore.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "delayed-export-destination"
    )
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(coordinator)
    let live = ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
    var controller: ViewerEventExplorerController? = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: live
      )
    )
    controller?.start()
    for _ in 0..<2_000 {
      if controller?.canManageSelectedRecording == true
        && controller?.pendingCleanupWorkCount == 0
      {
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(controller?.canManageSelectedRecording == true)
    controller?.prepareExport(.completeRecording)
    for _ in 0..<2_000 {
      if case .disclosure = controller?.exportState,
        controller?.pendingCleanupWorkCount == 0
      {
        break
      }
      await Task.yield()
    }
    guard case .disclosure = controller?.exportState else {
      return XCTFail("The export disclosure was not prepared.")
    }

    let delayedSelection = DelayedViewerExportDestinationSelection()
    controller?.beginExportDestinationSelection { completion in
      delayedSelection.start(completion)
    }
    XCTAssertTrue(delayedSelection.hasCompletion)
    XCTAssertEqual(controller?.pendingCleanupWorkCount, 1)

    let cleanup = try XCTUnwrap(controller).sealAndClear()
    await cleanup.value
    XCTAssertEqual(delayedSelection.cancellationCount, 1)
    XCTAssertEqual(controller?.pendingCleanupWorkCount, 0)
    let sealedRevision = try XCTUnwrap(controller).revision
    let destination = paths.directory.appendingPathComponent("late-export.json")
    delayedSelection.respond(destination)
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(controller?.revision, sealedRevision)
    XCTAssertEqual(controller?.exportState, .idle)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    let weakController = WeakViewerEventExplorerReference(controller)
    controller = nil
    for _ in 0..<100 where weakController.value != nil { await Task.yield() }
    XCTAssertNil(weakController.value)
    delayedSelection.respond(destination)
    for _ in 0..<100 { await Task.yield() }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  @MainActor
  func testControllerCancellationAfterExportCommitPublishesAuthoritativeSuccess() async throws {
    let completionGate = ArmableViewerExecutionGate()
    let fixture = try await makePreparedControllerExportFixture(
      operationCompletionGate: { completionGate.run() },
      reason: "controller-commit-cancellation"
    )
    let destination = fixture.paths.directory.appendingPathComponent("cancel-after-commit.json")
    let prior = Data("prior destination".utf8)
    try prior.write(to: destination)

    completionGate.arm()
    fixture.controller.executePreparedExport(to: destination)
    XCTAssertEqual(completionGate.waitUntilBlocked(), .success)
    XCTAssertNotEqual(try Data(contentsOf: destination), prior)
    fixture.controller.cancelExport()
    XCTAssertEqual(fixture.controller.exportState, .cancelling(eventCount: 0))

    completionGate.release()
    for _ in 0..<2_000 {
      if fixture.controller.exportState == .completed(eventCount: 0)
        && fixture.controller.pendingCleanupWorkCount == 0
      {
        break
      }
      await Task.yield()
    }
    XCTAssertEqual(fixture.controller.exportState, .completed(eventCount: 0))
    XCTAssertEqual(fixture.controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(fixture.gateway.operationCountForTesting, 0)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    XCTAssertEqual(root["schemaVersion"] as? Int, 1)

    await fixture.controller.sealAndClear().value
    fixture.gateway.sealAndWait(originatingFrom: fixture.coordinator)
    fixture.coordinator.closeStorage()
  }

  @MainActor
  func testControllerCancellationBeforeExportCommitPreservesPriorDestination() async throws {
    let executionGate = ArmableViewerExecutionGate()
    let fixture = try await makePreparedControllerExportFixture(
      operationExecutionGate: { executionGate.run() },
      reason: "controller-precommit-cancellation"
    )
    let destination = fixture.paths.directory.appendingPathComponent("cancel-before-commit.json")
    let prior = Data("prior destination".utf8)
    try prior.write(to: destination)

    executionGate.arm()
    fixture.controller.executePreparedExport(to: destination)
    XCTAssertEqual(executionGate.waitUntilBlocked(), .success)
    XCTAssertEqual(try Data(contentsOf: destination), prior)
    fixture.controller.cancelExport()
    XCTAssertEqual(fixture.controller.exportState, .cancelling(eventCount: 0))

    executionGate.release()
    for _ in 0..<2_000 {
      if fixture.controller.exportState == .cancelled
        && fixture.controller.pendingCleanupWorkCount == 0
      {
        break
      }
      await Task.yield()
    }
    XCTAssertEqual(fixture.controller.exportState, .cancelled)
    XCTAssertEqual(try Data(contentsOf: destination), prior)
    XCTAssertEqual(fixture.controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(fixture.gateway.operationCountForTesting, 0)

    await fixture.controller.sealAndClear().value
    fixture.gateway.sealAndWait(originatingFrom: fixture.coordinator)
    fixture.coordinator.closeStorage()
  }

  @MainActor
  func testControllerStoreReplacementAfterExportCommitPublishesAuthoritativeSuccess()
    async throws
  {
    let completionGate = ArmableViewerExecutionGate()
    let fixture = try await makePreparedControllerExportFixture(
      operationCompletionGate: { completionGate.run() },
      reason: "controller-commit-replacement"
    )
    let destination = fixture.paths.directory.appendingPathComponent("replace-after-commit.json")
    let prior = Data("prior destination".utf8)
    try prior.write(to: destination)
    let replacement = try ViewerStoreCoordinator(paths: makePaths())

    completionGate.arm()
    fixture.controller.executePreparedExport(to: destination)
    XCTAssertEqual(completionGate.waitUntilBlocked(), .success)
    XCTAssertNotEqual(try Data(contentsOf: destination), prior)
    let replacementStarted = DispatchSemaphore(value: 0)
    let replacementFinished = DispatchSemaphore(value: 0)
    let gateway = fixture.gateway
    DispatchQueue.global(qos: .userInitiated).async {
      replacementStarted.signal()
      gateway.install(replacement)
      replacementFinished.signal()
    }
    XCTAssertEqual(replacementStarted.wait(timeout: .now() + 2), .success)
    for _ in 0..<2_000 where fixture.gateway.operationCountForTesting != 0 {
      await Task.yield()
    }
    XCTAssertEqual(fixture.gateway.operationCountForTesting, 0)
    XCTAssertEqual(replacementFinished.wait(timeout: .now() + 0.05), .timedOut)

    completionGate.release()
    XCTAssertEqual(replacementFinished.wait(timeout: .now() + 2), .success)
    for _ in 0..<2_000 {
      if fixture.controller.exportState == .completed(eventCount: 0)
        && fixture.controller.pendingCleanupWorkCount == 0
      {
        break
      }
      await Task.yield()
    }
    XCTAssertEqual(fixture.controller.exportState, .completed(eventCount: 0))
    XCTAssertEqual(fixture.controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(fixture.gateway.operationCountForTesting, 0)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    XCTAssertEqual(root["schemaVersion"] as? Int, 1)

    fixture.controller.noteStoreChanged()
    for _ in 0..<2_000 where fixture.controller.pendingCleanupWorkCount != 0 {
      await Task.yield()
    }
    XCTAssertEqual(fixture.controller.pendingCleanupWorkCount, 0)
    XCTAssertEqual(fixture.gateway.operationCountForTesting, 0)

    await fixture.controller.sealAndClear().value
    fixture.gateway.sealAndWait(originatingFrom: replacement)
    fixture.coordinator.closeStorage()
    replacement.closeStorage()
  }

  func testExplorerGatewayFollowingOperationsRejectRetiredPredecessorWithoutRetargeting()
    throws
  {
    let firstCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let firstRecording = try firstCoordinator.services.eventStore.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "retired-predecessor"
    )
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(firstCoordinator)
    let predecessorResult = LockedViewerExplorerResult<Void>()
    let predecessorFinished = expectation(description: "Predecessor traversal release")
    let predecessor = gateway.endTraversal { result in
      predecessorResult.set(result)
      predecessorFinished.fulfill()
    }
    wait(for: [predecessorFinished], timeout: 2)
    XCTAssertNotNil(try predecessorResult.value?.get())

    let replacement = try ViewerStoreCoordinator(paths: makePaths())
    gateway.install(replacement)
    let query = try ViewerEventQuery(recordingID: firstRecording.rowID, predicates: [])
    var rejectedQueryToken: ViewerStoreExplorerOperationToken?
    let queryResult: Result<ViewerQuerySnapshot, ViewerStoreExplorerFailure> = try explorerResult(
      "Retired predecessor query"
    ) {
      let token = gateway.replaceQuery(query, following: predecessor, completion: $0)
      rejectedQueryToken = token
      return token
    }
    var rejectedPageToken: ViewerStoreExplorerOperationToken?
    let pageResult: Result<ViewerEventPage, ViewerStoreExplorerFailure> = try explorerResult(
      "Retired predecessor page"
    ) {
      let token = gateway.loadPage(
        cursor: nil,
        direction: .backward,
        following: predecessor,
        completion: $0
      )
      rejectedPageToken = token
      return token
    }
    var rejectedGapToken: ViewerStoreExplorerOperationToken?
    let gapResult: Result<ViewerGapPage, ViewerStoreExplorerFailure> = try explorerResult(
      "Retired predecessor gaps"
    ) {
      let token = gateway.loadGapPage(
        deviceSessionIDs: [],
        cursor: nil,
        direction: .backward,
        following: predecessor,
        completion: $0
      )
      rejectedGapToken = token
      return token
    }
    for result in [
      queryResult.map { _ in () }, pageResult.map { _ in () }, gapResult.map { _ in () },
    ] {
      XCTAssertThrowsError(try result.get()) {
        XCTAssertEqual($0 as? ViewerStoreExplorerFailure, .storeReplaced)
      }
    }
    XCTAssertFalse(try XCTUnwrap(rejectedQueryToken).isDeliveryValid)
    XCTAssertFalse(try XCTUnwrap(rejectedPageToken).isDeliveryValid)
    XCTAssertFalse(try XCTUnwrap(rejectedGapToken).isDeliveryValid)
    XCTAssertEqual(gateway.operationCountForTesting, 0)
    let fresh: ViewerStoreChangeSnapshot = try explorerValue("Fresh replacement request") {
      gateway.loadChangeSnapshot(completion: $0)
    }
    XCTAssertEqual(fresh.status.state, .available)

    gateway.sealAndWait(originatingFrom: replacement)
    firstCoordinator.closeStorage()
    replacement.closeStorage()
  }

  func testExplorerGatewayReplacementRetiresOperationBeforeArbitraryCompletion() throws {
    let firstCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let replacementCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(firstCoordinator)
    let callbackEntered = DispatchSemaphore(value: 0)
    let callbackRelease = DispatchSemaphore(value: 0)
    let callbackFinished = expectation(description: "Originating completion finished")
    _ = gateway.loadChangeSnapshot { _ in
      callbackEntered.signal()
      _ = callbackRelease.wait(timeout: .now() + 5)
      callbackFinished.fulfill()
    }
    XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success)

    let replacementStarted = DispatchSemaphore(value: 0)
    let replacementFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      replacementStarted.signal()
      gateway.install(replacementCoordinator)
      replacementFinished.signal()
    }
    XCTAssertEqual(replacementStarted.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(replacementFinished.wait(timeout: .now() + 2), .success)

    let replacementResult: ViewerStoreChangeSnapshot = try explorerValue(
      "Replacement while prior callback remains client-owned"
    ) {
      gateway.loadChangeSnapshot(completion: $0)
    }
    XCTAssertEqual(replacementResult.status.state, .available)

    callbackRelease.signal()
    wait(for: [callbackFinished], timeout: 2)

    gateway.sealAndWait(originatingFrom: replacementCoordinator)
    firstCoordinator.closeStorage()
    replacementCoordinator.closeStorage()
  }

  func testExplorerGatewayActiveCompletionCanInstallReplacementReentrantly() throws {
    let firstCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let replacementCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(firstCoordinator)
    let result = LockedViewerExplorerResult<ViewerStoreChangeSnapshot>()
    let callbackCount = LockedCounter()
    let callbackReturned = expectation(description: "Reentrant replacement callback returned")
    _ = gateway.loadChangeSnapshot { value in
      result.set(value)
      callbackCount.increment()
      gateway.install(replacementCoordinator)
      callbackReturned.fulfill()
    }
    wait(for: [callbackReturned], timeout: 2)
    XCTAssertNotNil(try result.value?.get())
    XCTAssertEqual(callbackCount.value, 1)

    let replacementResult: ViewerStoreChangeSnapshot = try explorerValue(
      "Reentrant replacement generation"
    ) {
      gateway.loadChangeSnapshot(completion: $0)
    }
    XCTAssertEqual(replacementResult.status.state, .available)

    gateway.sealAndWait(originatingFrom: replacementCoordinator)
    firstCoordinator.closeStorage()
    replacementCoordinator.closeStorage()
  }

  func testExplorerGatewayLinearizesExternalAndCallbackReplacementWithoutOrphanGeneration()
    throws
  {
    let firstCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let externalCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let callbackCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let operationGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(firstCoordinator)
    let firstCallbackEntered = DispatchSemaphore(value: 0)
    let externalPublished = DispatchSemaphore(value: 0)
    let callbackOperationSubmitted = DispatchSemaphore(value: 0)
    let callbackOperationResult = LockedViewerExplorerResult<ViewerStoreChangeSnapshot>()
    let callbackOperationFinished = expectation(description: "Winning callback generation work")
    let firstCallbackFinished = expectation(description: "Originating callback returned")

    _ = gateway.loadChangeSnapshot { _ in
      firstCallbackEntered.signal()
      XCTAssertEqual(externalPublished.wait(timeout: .now() + 2), .success)
      gateway.install(callbackCoordinator)
      operationGate.arm()
      let token = gateway.loadChangeSnapshot { result in
        callbackOperationResult.set(result)
        callbackOperationFinished.fulfill()
      }
      XCTAssertEqual(token.coordinatorGeneration, 3)
      XCTAssertEqual(operationGate.waitUntilBlocked(), .success)
      callbackOperationSubmitted.signal()
      firstCallbackFinished.fulfill()
    }
    XCTAssertEqual(firstCallbackEntered.wait(timeout: .now() + 2), .success)

    let externalReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      gateway.install(externalCoordinator)
      externalPublished.signal()
      externalReturned.signal()
    }
    XCTAssertEqual(externalReturned.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(callbackOperationSubmitted.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(gateway.operationCountForTesting, 1)

    operationGate.release()
    wait(for: [firstCallbackFinished, callbackOperationFinished], timeout: 2)
    XCTAssertNotNil(try callbackOperationResult.value?.get())
    XCTAssertEqual(gateway.operationCountForTesting, 0)
    let finalToken = gateway.loadChangeSnapshot { _ in }
    XCTAssertEqual(finalToken.coordinatorGeneration, 3)
    for _ in 0..<1_000 where gateway.operationCountForTesting > 0 {
      Thread.sleep(forTimeInterval: 0.001)
    }
    XCTAssertEqual(gateway.operationCountForTesting, 0)

    gateway.sealAndWait(originatingFrom: callbackCoordinator)
    firstCoordinator.closeStorage()
    externalCoordinator.closeStorage()
    callbackCoordinator.closeStorage()
  }

  func testExplorerGatewayQueuedRejectionCanSealReentrantlyWhileActiveWorkFinishes() throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let operationGate = ArmableViewerExecutionGate()
    operationGate.arm()
    let gateway = ViewerStoreExplorerGateway(operationExecutionGate: { operationGate.run() })
    gateway.install(coordinator)
    let activeResult = LockedViewerExplorerResult<ViewerStoreChangeSnapshot>()
    let activeFinished = expectation(description: "Active work retired during reentrant seal")
    _ = gateway.loadChangeSnapshot { result in
      activeResult.set(result)
      activeFinished.fulfill()
    }
    XCTAssertEqual(operationGate.waitUntilBlocked(), .success)

    let queuedResult = LockedViewerExplorerResult<ViewerStoreChangeSnapshot>()
    let queuedCallbackEntered = DispatchSemaphore(value: 0)
    let queuedCallbackReturned = DispatchSemaphore(value: 0)
    let queuedToken = gateway.loadChangeSnapshot { result in
      queuedResult.set(result)
      queuedCallbackEntered.signal()
      gateway.sealAndWait(originatingFrom: coordinator)
      queuedCallbackReturned.signal()
    }
    DispatchQueue.global(qos: .userInitiated).async { gateway.cancel(queuedToken) }
    XCTAssertEqual(queuedCallbackEntered.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(queuedCallbackReturned.wait(timeout: .now() + 0.05), .timedOut)

    operationGate.release()
    wait(for: [activeFinished], timeout: 2)
    XCTAssertEqual(queuedCallbackReturned.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(activeResult.failure, .storeReplaced)
    XCTAssertEqual(queuedResult.failure, .cancelled)
    XCTAssertEqual(gateway.operationCountForTesting, 0)
    coordinator.closeStorage()
  }

  func testGatewayCancellationAfterCommittedExportPreservesSuccessAndClearsState() throws {
    let paths = try makePaths()
    let coordinator = try ViewerStoreCoordinator(paths: paths)
    let store = coordinator.services.eventStore
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "committed-export-cancellation"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "committed-export-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Committed Export Device"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "committed")
    )
    let completionGate = ArmableViewerExecutionGate()
    let gateway = ViewerStoreExplorerGateway(
      operationCompletionGate: { completionGate.run() }
    )
    gateway.install(coordinator)
    let page: ViewerRecordingCatalogPage = try explorerValue("Committed export catalog") {
      gateway.loadRecordingCatalog(cursor: nil, completion: $0)
    }
    let target = try XCTUnwrap(page.recordingTarget(rowID: recording.rowID))
    let ticket: ViewerStoreExportTicket = try explorerValue("Committed export preflight") {
      gateway.prepareCompleteExport(target, completion: $0)
    }
    let destination = paths.directory.appendingPathComponent("committed-export.json")
    let prior = Data("prior destination".utf8)
    try prior.write(to: destination)

    completionGate.arm()
    let exportResult = LockedViewerExplorerResult<Void>()
    let callbackCount = LockedCounter()
    let exportFinished = expectation(description: "Committed export reported once")
    let token = gateway.executeExport(ticket, to: destination) { result in
      exportResult.set(result)
      callbackCount.increment()
      exportFinished.fulfill()
    }
    XCTAssertEqual(completionGate.waitUntilBlocked(), .success)
    XCTAssertNotEqual(try Data(contentsOf: destination), prior)
    gateway.cancel(token)
    completionGate.release()
    wait(for: [exportFinished], timeout: 2)

    XCTAssertNotNil(try exportResult.value?.get())
    XCTAssertEqual(callbackCount.value, 1)
    XCTAssertEqual(gateway.operationCountForTesting, 0)
    XCTAssertEqual(coordinator.services.query.cancelledOperationCountForTesting, 0)
    XCTAssertEqual(coordinator.services.export.cancelledOperationCountForTesting, 0)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    XCTAssertEqual((root["events"] as? [[String: Any]])?.count, 1)

    gateway.sealAndWait(originatingFrom: coordinator)
    coordinator.closeStorage()
  }

  func testExplorerQueryArbiterOwnsOneTraversalAndFilteredExportUsesIndependentLease() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    let firstEventID = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "alpha")
    )
    let leases = ViewerStoreLeaseRegistry()
    let exportLeaseSamples = LockedViewerCounter()
    let exportService = ViewerStoreExportService(
      pool: pool,
      leases: leases,
      filePhases: ViewerExportFilePhaseObserver { phase in
        if phase == .beforeWrite, leases.protects(recordingID: recording.rowID) {
          exportLeaseSamples.increment()
        }
      }
    )
    let arbiter = ViewerExplorerQueryArbiter(
      queryService: ViewerStoreQueryService(pool: pool, leases: leases),
      diagnosticService: ViewerStoreDiagnosticService(pool: pool, leases: leases),
      performanceService: ViewerPerformanceStoreService(pool: pool, leases: leases),
      exportService: exportService
    )
    let query = try ViewerEventQuery(
      recordingID: recording.rowID,
      predicates: [.json(path: "$.message", equals: .string("alpha"))]
    )

    for _ in 0..<16 {
      _ = try arbiter.replaceQuery(query)
    }
    XCTAssertTrue(leases.protects(recordingID: recording.rowID))
    let page = try arbiter.page(cursor: nil, direction: .forward, limit: 10)
    XCTAssertEqual(page.rows.map(\.rowID), [firstEventID])
    XCTAssertEqual(try arbiter.detail(rowID: firstEventID)?.summary.rowID, firstEventID)
    let scope = try arbiter.makeFilteredExportScope()

    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 2, value: "alpha")
    )
    arbiter.endTraversal()
    arbiter.endTraversal()
    XCTAssertFalse(leases.protects(recordingID: recording.rowID))
    XCTAssertEqual(try arbiter.preflight(scope: scope).eventCount, 1)

    let destination = paths.directory.appendingPathComponent("arbiter-filtered.json")
    try exportService.export(scope: scope, to: destination)
    XCTAssertEqual(exportLeaseSamples.value, 1)
    XCTAssertFalse(leases.protects(recordingID: recording.rowID))
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    XCTAssertEqual((root["events"] as? [[String: Any]])?.count, 1)

    arbiter.close()
    arbiter.close()
    XCTAssertThrowsError(try arbiter.replaceQuery(query)) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .storeReplaced)
    }
  }

  func testRecordingCatalogUsesFrozenDescendingKeysetsAndRelevantChangeRestart() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let plans = LockedViewerCatalogPlans()
    let catalog = ViewerStoreCatalogService(pool: pool) { plans.append($0) }
    var recordings: [ViewerRecordingHandle] = []
    for index in 1...5 {
      recordings.append(
        try store.beginRecording(
          wallMilliseconds: Int64(index * 1_000),
          monotonicNanoseconds: UInt64(index * 2_000),
          reason: "test"
        )
      )
    }
    let latestDevice = try store.beginDeviceSession(
      recording: recordings[4],
      installationID: "latest-device",
      wallMilliseconds: 6_000,
      monotonicNanoseconds: 12_000,
      partialHistory: false,
      displayName: "Latest App",
      applicationIdentifier: "com.example.latest",
      applicationVersion: "5"
    )
    _ = try store.appendEvent(
      makeObservation(
        recording: recordings[4],
        device: latestDevice,
        sequence: 1,
        value: "catalog-event-content"
      )
    )

    let first = try catalog.recordingPage(storeGeneration: 7, cursor: nil, limit: 2)
    XCTAssertEqual(first.rows.map(\.rowID), [recordings[4].rowID, recordings[3].rowID])
    XCTAssertEqual(first.rows.first?.latestDevice?.installationAlias, "device-1")
    XCTAssertEqual(first.rows.first?.latestDevice?.connectionAlias, "connection-1")
    XCTAssertEqual(first.rows.first?.latestDevice?.displayName, "Latest App")
    XCTAssertFalse(first.description.contains("catalog-event-content"))
    XCTAssertTrue(Mirror(reflecting: try XCTUnwrap(first.rows.first)).children.isEmpty)
    XCTAssertTrue(Mirror(reflecting: try XCTUnwrap(first.olderCursor)).children.isEmpty)
    let recordingPlan = try XCTUnwrap(plans.value.first { $0.kind == .recording })
    XCTAssertTrue(
      recordingPlan.details.contains { $0.contains("SEARCH R USING INTEGER PRIMARY KEY") }
    )
    XCTAssertFalse(recordingPlan.details.contains { $0.contains("USE TEMP B-TREE") })
    XCTAssertFalse(recordingPlan.details.contains { $0.hasPrefix("SCAN ") })
    let budgetNow = ContinuousClock.now
    let budget = ViewerSQLiteBudget.query(now: budgetNow)
    XCTAssertEqual(budget.maximumVirtualMachineSteps, 2_000_000)
    XCTAssertEqual(budget.deadline, budgetNow + .milliseconds(250))

    _ = try store.appendEvent(
      makeObservation(
        recording: recordings[4],
        device: latestDevice,
        sequence: 2,
        value: "later-event"
      )
    )
    let second = try catalog.recordingPage(
      storeGeneration: 7,
      cursor: try XCTUnwrap(first.olderCursor),
      direction: .older,
      limit: 2
    )
    XCTAssertEqual(second.rows.map(\.rowID), [recordings[2].rowID, recordings[1].rowID])
    let newer = try catalog.recordingPage(
      storeGeneration: 7,
      cursor: try XCTUnwrap(second.newerCursor),
      direction: .newer,
      limit: 2
    )
    XCTAssertEqual(newer.rows.map(\.rowID), [recordings[4].rowID, recordings[3].rowID])

    try store.appendStructural(
      .closeRecording(
        recordings[0],
        wallMilliseconds: 10_000,
        monotonicNanoseconds: 20_000
      )
    )
    XCTAssertThrowsError(
      try catalog.recordingPage(
        storeGeneration: 7,
        cursor: try XCTUnwrap(second.olderCursor),
        direction: .older,
        limit: 2
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .catalogChanged)
    }
    XCTAssertThrowsError(try catalog.recordingPage(storeGeneration: 7, cursor: nil, limit: 0)) {
      XCTAssertEqual($0 as? ViewerStoreError, .invalidValue)
    }
    XCTAssertThrowsError(try catalog.recordingPage(storeGeneration: 7, cursor: nil, limit: 101)) {
      XCTAssertEqual($0 as? ViewerStoreError, .invalidValue)
    }
    XCTAssertThrowsError(
      try catalog.recordingPage(
        storeGeneration: 8,
        cursor: try XCTUnwrap(first.olderCursor),
        direction: .older
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .storeReplaced)
    }
  }

  func testRecordingCatalogIgnoresEventCommitsAndRestartsForRenamePinAndTombstone()
    throws
  {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let catalog = ViewerStoreCatalogService(pool: pool)
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    var recordings: [ViewerRecordingHandle] = []
    for _ in 0..<6 {
      recordings.append(
        try store.beginRecording(
          wallMilliseconds: 1_000,
          monotonicNanoseconds: 2_000,
          reason: "equal-time-catalog"
        )
      )
    }
    for recording in recordings.dropLast() {
      try store.appendStructural(
        .closeRecording(
          recording,
          wallMilliseconds: 3_000,
          monotonicNanoseconds: 4_000
        )
      )
    }
    let activeRecording = recordings[5]
    let activeDevice = try store.beginDeviceSession(
      recording: activeRecording,
      installationID: "catalog-commit-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Commit Device"
    )

    let commitSnapshot = try catalog.recordingPage(storeGeneration: 11, cursor: nil, limit: 2)
    XCTAssertEqual(
      commitSnapshot.rows.map(\.rowID),
      [recordings[5].rowID, recordings[4].rowID]
    )
    _ = try store.appendEvent(
      makeObservation(
        recording: activeRecording,
        device: activeDevice,
        sequence: 1,
        value: "commit-does-not-restart-catalog"
      )
    )
    let afterCommit = try catalog.recordingPage(
      storeGeneration: 11,
      cursor: try XCTUnwrap(commitSnapshot.olderCursor),
      direction: .older,
      limit: 2
    )
    XCTAssertEqual(afterCommit.rows.map(\.rowID), [recordings[3].rowID, recordings[2].rowID])

    var metadataTarget = ViewerRecordingRevision(
      recordingID: recordings[4].rowID,
      revision: 2
    )
    let renameSnapshot = try catalog.recordingPage(storeGeneration: 11, cursor: nil, limit: 2)
    metadataTarget = try maintenance.updateRecording(
      metadataTarget,
      name: "Renamed recording",
      note: nil,
      pinned: false,
      wallMilliseconds: 5_000
    )
    XCTAssertThrowsError(
      try catalog.recordingPage(
        storeGeneration: 11,
        cursor: try XCTUnwrap(renameSnapshot.olderCursor),
        direction: .older,
        limit: 2
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .catalogChanged)
    }
    let afterRename = try catalog.recordingPage(storeGeneration: 11, cursor: nil, limit: 100)
    XCTAssertEqual(
      afterRename.rows.first { $0.rowID == recordings[4].rowID }?.name, "Renamed recording")

    let pinSnapshot = try catalog.recordingPage(storeGeneration: 11, cursor: nil, limit: 2)
    metadataTarget = try maintenance.updateRecording(
      metadataTarget,
      name: "Renamed recording",
      note: nil,
      pinned: true,
      wallMilliseconds: 6_000
    )
    XCTAssertThrowsError(
      try catalog.recordingPage(
        storeGeneration: 11,
        cursor: try XCTUnwrap(pinSnapshot.olderCursor),
        direction: .older,
        limit: 2
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .catalogChanged)
    }
    let afterPin = try catalog.recordingPage(storeGeneration: 11, cursor: nil, limit: 100)
    XCTAssertEqual(afterPin.rows.first { $0.rowID == recordings[4].rowID }?.pinned, true)
    XCTAssertEqual(metadataTarget.revision, 4)

    let tombstoneSnapshot = try catalog.recordingPage(
      storeGeneration: 11,
      cursor: nil,
      limit: 2
    )
    for (offset, recording) in recordings.prefix(2).enumerated() {
      let deleteTarget = ViewerRecordingRevision(
        recordingID: recording.rowID,
        revision: 2
      )
      let confirmation = try maintenance.prepareDelete(deleteTarget)
      try maintenance.requestDelete(
        confirmation,
        wallMilliseconds: 7_000 + Int64(offset)
      )
    }
    XCTAssertThrowsError(
      try catalog.recordingPage(
        storeGeneration: 11,
        cursor: try XCTUnwrap(tombstoneSnapshot.olderCursor),
        direction: .older,
        limit: 2
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .catalogChanged)
    }
    let afterTombstone = try catalog.recordingPage(
      storeGeneration: 11,
      cursor: nil,
      limit: 100
    )
    XCTAssertTrue(
      afterTombstone.rows.allSatisfy {
        $0.rowID != recordings[0].rowID && $0.rowID != recordings[1].rowID
      }
    )
  }

  func testDeviceCatalogUsesConnectionKeysetsAndOnlyRelevantMutationRestarts() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let plans = LockedViewerCatalogPlans()
    let catalog = ViewerStoreCatalogService(pool: pool) { plans.append($0) }
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    var devices: [ViewerDeviceSessionHandle] = []
    for index in 1...5 {
      devices.append(
        try store.beginDeviceSession(
          recording: recording,
          installationID: "installation-\(index)",
          wallMilliseconds: Int64(1_000 + index),
          monotonicNanoseconds: UInt64(2_000 + index),
          partialHistory: index == 1,
          displayName: "Device \(index)",
          applicationIdentifier: "com.example.device\(index)",
          applicationVersion: "\(index)"
        )
      )
    }
    try store.appendStructural(
      .drop(
        device: devices[4],
        sequence: 1,
        wallMilliseconds: 3_000,
        monotonicNanoseconds: 4_000,
        reason: "testDrop",
        count: 2
      )
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: devices[4],
        sequence: 1,
        reason: "testGap",
        count: 1,
        firstWallMilliseconds: 3_000,
        lastWallMilliseconds: 3_000,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      )
    )

    let first = try catalog.devicePage(
      recordingID: recording.rowID,
      storeGeneration: 3,
      cursor: nil,
      limit: 2
    )
    XCTAssertEqual(first.rows.map(\.connectionOrdinal), [5, 4])
    XCTAssertEqual(first.rows.first?.installationAlias, "device-5")
    XCTAssertEqual(first.rows.first?.connectionAlias, "connection-5")
    XCTAssertEqual(first.rows.first?.applicationIdentifier, "com.example.device5")
    XCTAssertEqual(first.rows.first?.hasGap, true)
    XCTAssertEqual(first.rows.first?.hasDrop, true)
    XCTAssertTrue(Mirror(reflecting: try XCTUnwrap(first.rows.first)).children.isEmpty)
    let devicePlan = try XCTUnwrap(plans.value.first { $0.kind == .device })
    XCTAssertTrue(
      devicePlan.details.contains {
        $0.contains("USING INDEX SQLITE_AUTOINDEX_DEVICESESSIONS_2")
      }
    )
    XCTAssertFalse(devicePlan.details.contains { $0.contains("USE TEMP B-TREE") })
    XCTAssertFalse(devicePlan.details.contains { $0.hasPrefix("SCAN ") })

    let otherRecording = try store.beginRecording(
      wallMilliseconds: 5_000,
      monotonicNanoseconds: 6_000,
      reason: "other"
    )
    _ = try store.beginDeviceSession(
      recording: otherRecording,
      installationID: "other",
      wallMilliseconds: 5_000,
      monotonicNanoseconds: 6_000,
      partialHistory: false,
      displayName: "Other"
    )
    let second = try catalog.devicePage(
      recordingID: recording.rowID,
      storeGeneration: 3,
      cursor: try XCTUnwrap(first.olderCursor),
      direction: .older,
      limit: 2
    )
    XCTAssertEqual(second.rows.map(\.connectionOrdinal), [3, 2])
    let newer = try catalog.devicePage(
      recordingID: recording.rowID,
      storeGeneration: 3,
      cursor: try XCTUnwrap(second.newerCursor),
      direction: .newer,
      limit: 2
    )
    XCTAssertEqual(newer.rows.map(\.connectionOrdinal), [5, 4])

    let fresh = try catalog.devicePage(
      recordingID: recording.rowID,
      storeGeneration: 3,
      cursor: nil,
      limit: 2
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: devices[3],
        sequence: 2,
        reason: "laterGap",
        count: 1,
        firstWallMilliseconds: 7_000,
        lastWallMilliseconds: 7_000,
        directions: "viewerToApp",
        firstWireSequence: 2,
        lastWireSequence: 2
      )
    )
    XCTAssertThrowsError(
      try catalog.devicePage(
        recordingID: recording.rowID,
        storeGeneration: 3,
        cursor: try XCTUnwrap(fresh.olderCursor),
        direction: .older,
        limit: 2
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreExplorerFailure, .catalogChanged)
    }
    XCTAssertThrowsError(
      try catalog.devicePage(
        recordingID: otherRecording.rowID,
        storeGeneration: 3,
        cursor: try XCTUnwrap(first.olderCursor),
        direction: .older
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidValue)
    }
    XCTAssertThrowsError(
      try catalog.devicePage(
        recordingID: recording.rowID,
        storeGeneration: 3,
        cursor: nil,
        limit: 201
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidValue)
    }
  }

  func testExplorerGatewayCatalogRejectsOldStoreGenerationWithoutRetargeting() throws {
    let firstCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    let firstRecording = try firstCoordinator.services.eventStore.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "first"
    )
    let gateway = ViewerStoreExplorerGateway()
    gateway.install(firstCoordinator)
    let firstResult = LockedViewerExplorerResult<ViewerRecordingCatalogPage>()
    let firstFinished = expectation(description: "First catalog page")
    let firstToken = gateway.loadRecordingCatalog(cursor: nil, limit: 1) { result in
      firstResult.set(result)
      firstFinished.fulfill()
    }
    wait(for: [firstFinished], timeout: 2)
    XCTAssertEqual(firstToken.coordinatorGeneration, 1)
    guard case .success(let firstPage) = try XCTUnwrap(firstResult.value) else {
      return XCTFail("Expected first catalog page")
    }
    XCTAssertEqual(firstPage.rows.map(\.rowID), [firstRecording.rowID])

    let replacementCoordinator = try ViewerStoreCoordinator(paths: makePaths())
    gateway.install(replacementCoordinator)
    let staleResult = LockedViewerExplorerResult<ViewerRecordingCatalogPage>()
    let staleFinished = expectation(description: "Old catalog cursor rejected")
    let replacementToken = gateway.loadRecordingCatalog(
      cursor: try XCTUnwrap(firstPage.olderCursor),
      direction: .older
    ) { result in
      staleResult.set(result)
      staleFinished.fulfill()
    }
    wait(for: [staleFinished], timeout: 2)
    XCTAssertEqual(replacementToken.coordinatorGeneration, 2)
    XCTAssertEqual(staleResult.failure, .storeReplaced)
    gateway.cancel(firstToken)

    gateway.sealAndWait(originatingFrom: replacementCoordinator)
    firstCoordinator.closeStorage()
    replacementCoordinator.closeStorage()
  }

  func testCatalogDefaultAndMaximumPageBounds() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let catalog = ViewerStoreCatalogService(pool: pool)
    var latestRecording: ViewerRecordingHandle?
    for index in 1...101 {
      latestRecording = try store.beginRecording(
        wallMilliseconds: Int64(index),
        monotonicNanoseconds: UInt64(index),
        reason: "bounds"
      )
    }
    XCTAssertEqual(
      try catalog.recordingPage(storeGeneration: 1, cursor: nil).rows.count,
      50
    )
    XCTAssertEqual(
      try catalog.recordingPage(storeGeneration: 1, cursor: nil, limit: 100).rows.count,
      100
    )

    let recording = try XCTUnwrap(latestRecording)
    for index in 1...201 {
      _ = try store.beginDeviceSession(
        recording: recording,
        installationID: "shared-installation",
        wallMilliseconds: Int64(1_000 + index),
        monotonicNanoseconds: UInt64(2_000 + index),
        partialHistory: false,
        displayName: nil
      )
    }
    XCTAssertEqual(
      try catalog.devicePage(
        recordingID: recording.rowID,
        storeGeneration: 1,
        cursor: nil
      ).rows.count,
      100
    )
    XCTAssertEqual(
      try catalog.devicePage(
        recordingID: recording.rowID,
        storeGeneration: 1,
        cursor: nil,
        limit: 200
      ).rows.count,
      200
    )
  }

  func testDurableMaterializationUsesExactAdmissionConnectionID() throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let runtimeLogicalID = UUID()
    let context = try makeAdmissionContext(suffix: "logical-device")
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: runtimeLogicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    XCTAssertTrue(coordinator.sessionStarted(context))
    let materialized = expectation(description: "Device materialized")
    coordinator.afterCurrentPreparationPrefix { materialized.fulfill() }
    wait(for: [materialized], timeout: 2)

    let recordingPage = try coordinator.services.catalog.recordingPage(
      storeGeneration: 1,
      cursor: nil
    )
    let recordingID = try XCTUnwrap(recordingPage.rows.first?.rowID)
    let devicePage = try coordinator.services.catalog.devicePage(
      recordingID: recordingID,
      storeGeneration: 1,
      cursor: nil
    )
    XCTAssertEqual(devicePage.rows.map(\.logicalID), [context.connectionID])
    coordinator.closeStorage()
  }

  func testEventDetailIncludesExactIdentityAliasesAndCompleteMetadata() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "detail"
    )
    let connectionID = UUID()
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "detail-installation",
      logicalID: connectionID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Detail App"
    )
    let correlationID = EventID()
    let replyToID = EventID()
    let eventID = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 7,
        value: "complete-detail",
        causality: EventCausality(correlationID: correlationID, replyTo: replyToID),
        viewerMonotonicNanoseconds: 14_000,
        viewerWallMilliseconds: 15_000
      )
    )
    let leases = ViewerStoreLeaseRegistry()
    let query = ViewerStoreQueryService(pool: pool, leases: leases)
    let traversal = try query.begin(
      query: ViewerEventQuery(recordingID: recording.rowID, predicates: [])
    )
    let (detailValue, refreshed) = try query.detail(traversal: traversal, rowID: eventID)
    let detail = try XCTUnwrap(detailValue)
    XCTAssertEqual(detail.deviceLogicalID, connectionID)
    XCTAssertEqual(detail.installationAlias, "device-1")
    XCTAssertEqual(detail.connectionAlias, "connection-1")
    XCTAssertEqual(detail.originMonotonicNanoseconds, 7_000)
    XCTAssertEqual(detail.ttlMilliseconds, 60_000)
    XCTAssertEqual(detail.schemaVersion, 1)
    XCTAssertEqual(detail.correlationEventUUID, correlationID.rawValue)
    XCTAssertEqual(detail.replyToEventUUID, replyToID.rawValue)
    XCTAssertEqual(detail.summary.viewerWallMilliseconds, 15_000)
    XCTAssertEqual(detail.summary.viewerMonotonicNanoseconds, 14_000)
    XCTAssertEqual(detail.summary.resolvedDisposition, "consumerAccepted")
    XCTAssertEqual(Mirror(reflecting: detail).children.count, 1)
    query.end(refreshed)
  }

  func testGapTraversalFreezesLatestRevisionsAndUsesBoundedBidirectionalLanes() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "gaps"
    )
    let firstDevice = try store.beginDeviceSession(
      recording: recording,
      installationID: "gap-first",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "First"
    )
    let secondDevice = try store.beginDeviceSession(
      recording: recording,
      installationID: "gap-second",
      wallMilliseconds: 1_001,
      monotonicNanoseconds: 2_001,
      partialHistory: false,
      displayName: "Second"
    )
    for sequence in 1...34 {
      let device: ViewerDeviceSessionHandle? =
        sequence % 3 == 0 ? nil : (sequence % 2 == 0 ? firstDevice : secondDevice)
      try store.appendStructural(
        .gap(
          recording: recording,
          device: device,
          sequence: UInt64(sequence),
          reason: "gap-\(sequence)",
          count: 1,
          firstWallMilliseconds: Int64(sequence * 100),
          lastWallMilliseconds: Int64(sequence * 100),
          directions: "appToViewer",
          firstWireSequence: UInt64(sequence),
          lastWireSequence: UInt64(sequence)
        )
      )
    }
    let leases = ViewerStoreLeaseRegistry()
    let query = ViewerStoreQueryService(pool: pool, leases: leases)
    let plans = LockedViewerDiagnosticPlans()
    let diagnostics = ViewerStoreDiagnosticService(pool: pool, leases: leases) {
      plans.append($0)
    }
    let traversal = try query.begin(
      query: ViewerEventQuery(recordingID: recording.rowID, predicates: [])
    )

    try store.appendStructural(
      .gap(
        recording: recording,
        device: secondDevice,
        sequence: 1,
        reason: "gap-1",
        count: 2,
        firstWallMilliseconds: 100,
        lastWallMilliseconds: 4_000,
        directions: "both",
        firstWireSequence: 1,
        lastWireSequence: 40
      )
    )
    let (latestPage, secondTraversal) = try diagnostics.gapPage(
      traversal: traversal,
      deviceSessionIDs: [],
      cursor: nil,
      direction: .backward,
      limit: 32
    )
    XCTAssertEqual(latestPage.rows.count, 32)
    XCTAssertEqual(latestPage.rows.map(\.sequence), Array(3...34).map(Int64.init))
    XCTAssertTrue(latestPage.rows.allSatisfy { $0.count == 1 })
    XCTAssertTrue(Mirror(reflecting: try XCTUnwrap(latestPage.rows.first)).children.isEmpty)

    let (_, eventRefreshedTraversal) = try query.page(
      traversal: secondTraversal,
      cursor: nil,
      direction: .backward,
      limit: 1
    )
    let (oldestPage, thirdTraversal) = try diagnostics.gapPage(
      traversal: eventRefreshedTraversal,
      deviceSessionIDs: [],
      cursor: try XCTUnwrap(latestPage.nextCursor),
      direction: .backward,
      limit: 32
    )
    XCTAssertEqual(oldestPage.rows.map(\.sequence), [1, 2])
    XCTAssertEqual(Set(latestPage.rows.map(\.rowID)).intersection(oldestPage.rows.map(\.rowID)), [])
    XCTAssertEqual(oldestPage.rows.first?.count, 1)

    let (filteredPage, fourthTraversal) = try diagnostics.gapPage(
      traversal: thirdTraversal,
      deviceSessionIDs: [firstDevice.rowID],
      cursor: nil,
      direction: .forward,
      limit: 32
    )
    XCTAssertTrue(
      filteredPage.rows.allSatisfy {
        $0.deviceSessionID == nil || $0.deviceSessionID == firstDevice.rowID
      }
    )
    XCTAssertFalse(filteredPage.rows.contains { $0.deviceSessionID == secondDevice.rowID })
    XCTAssertTrue(
      plans.value.contains {
        $0.kind == .gapAllDevices
          && $0.details.contains(where: { $0.contains("GAPTIMELINEALLDEVICES") })
      }
    )
    XCTAssertTrue(
      plans.value.contains {
        $0.kind == .gapDeviceLane
          && $0.details.contains(where: { $0.contains("GAPTIMELINEBYDEVICE") })
      }
    )
    XCTAssertFalse(
      plans.value.flatMap(\.details).contains {
        $0.hasPrefix("SCAN ") || $0.contains("USE TEMP B-TREE")
      }
    )
    query.end(fourthTraversal)
  }

  func testCausalityUsesExactDeviceNineRowCandidatesReplyFirstAndRowIDCycles() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "causality"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "causality-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Primary"
    )
    let otherDevice = try store.beginDeviceSession(
      recording: recording,
      installationID: "causality-other",
      wallMilliseconds: 1_001,
      monotonicNanoseconds: 2_001,
      partialHistory: false,
      displayName: "Other"
    )
    let duplicateID = EventID()
    var duplicateRows: [Int64] = []
    for sequence in 1...9 {
      duplicateRows.append(
        try store.appendEvent(
          makeObservation(
            recording: recording,
            device: device,
            sequence: UInt64(sequence),
            value: "duplicate-\(sequence)",
            eventID: duplicateID
          )
        )
      )
    }
    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: otherDevice,
        sequence: 1,
        value: "other-device",
        eventID: duplicateID
      )
    )
    let twoCandidateID = EventID()
    var twoCandidateRows: [Int64] = []
    for sequence in 60...61 {
      twoCandidateRows.append(
        try store.appendEvent(
          makeObservation(
            recording: recording,
            device: device,
            sequence: UInt64(sequence),
            value: "two-candidate-\(sequence)",
            eventID: twoCandidateID
          )
        )
      )
    }
    let eightCandidateID = EventID()
    var eightCandidateRows: [Int64] = []
    for sequence in 70...77 {
      eightCandidateRows.append(
        try store.appendEvent(
          makeObservation(
            recording: recording,
            device: device,
            sequence: UInt64(sequence),
            value: "eight-candidate-\(sequence)",
            eventID: eightCandidateID
          )
        )
      )
    }
    let zeroCandidateRoot = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 90,
        value: "zero-candidate-root",
        causality: EventCausality(replyTo: EventID())
      )
    )
    let twoCandidateRoot = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 91,
        value: "two-candidate-root",
        causality: EventCausality(replyTo: twoCandidateID)
      )
    )
    let eightCandidateRoot = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 92,
        value: "eight-candidate-root",
        causality: EventCausality(replyTo: eightCandidateID)
      )
    )
    let correlationID = EventID()
    let correlationRow = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 10,
        value: "correlation",
        eventID: correlationID
      )
    )
    let rootRow = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 11,
        value: "root",
        causality: EventCausality(correlationID: correlationID, replyTo: duplicateID)
      )
    )
    let cycleAID = EventID()
    let cycleBID = EventID()
    let cycleARow = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 12,
        value: "cycle-a",
        causality: EventCausality(replyTo: cycleBID),
        eventID: cycleAID
      )
    )
    let cycleBRow = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 13,
        value: "cycle-b",
        causality: EventCausality(replyTo: cycleAID),
        eventID: cycleBID
      )
    )

    var chainIDs: [EventID] = []
    for _ in 0..<33 { chainIDs.append(EventID()) }
    var chainRows: [Int64] = []
    for index in 0..<33 {
      chainRows.append(
        try store.appendEvent(
          makeObservation(
            recording: recording,
            device: device,
            sequence: UInt64(20 + index),
            value: "chain-\(index)",
            causality: EventCausality(replyTo: index + 1 < 33 ? chainIDs[index + 1] : nil),
            eventID: chainIDs[index]
          )
        )
      )
    }

    let leases = ViewerStoreLeaseRegistry()
    let query = ViewerStoreQueryService(pool: pool, leases: leases)
    let plans = LockedViewerDiagnosticPlans()
    let diagnostics = ViewerStoreDiagnosticService(pool: pool, leases: leases) {
      plans.append($0)
    }
    let traversal = try query.begin(
      query: ViewerEventQuery(recordingID: recording.rowID, predicates: [])
    )
    let (zeroCandidateGraph, secondTraversal) = try diagnostics.causality(
      traversal: traversal,
      rootRowID: zeroCandidateRoot
    )
    XCTAssertEqual(zeroCandidateGraph.edges.first?.candidateRowIDs, [])
    XCTAssertEqual(zeroCandidateGraph.edges.first?.hasMore, false)

    let (twoCandidateGraph, thirdTraversal) = try diagnostics.causality(
      traversal: secondTraversal,
      rootRowID: twoCandidateRoot
    )
    XCTAssertEqual(twoCandidateGraph.edges.first?.candidateRowIDs, twoCandidateRows)
    XCTAssertEqual(twoCandidateGraph.edges.first?.hasMore, false)

    let (eightCandidateGraph, fourthTraversal) = try diagnostics.causality(
      traversal: thirdTraversal,
      rootRowID: eightCandidateRoot
    )
    XCTAssertEqual(eightCandidateGraph.edges.first?.candidateRowIDs, eightCandidateRows)
    XCTAssertEqual(eightCandidateGraph.edges.first?.hasMore, false)
    XCTAssertEqual(eightCandidateGraph.edges.first?.cyclicCandidateRowIDs, [])

    let (graph, fifthTraversal) = try diagnostics.causality(
      traversal: fourthTraversal,
      rootRowID: rootRow
    )
    XCTAssertEqual(graph.edges.first?.kind, .replyTo)
    XCTAssertEqual(graph.edges.first?.candidateRowIDs, Array(duplicateRows.prefix(8)))
    XCTAssertEqual(graph.edges.first?.hasMore, true)
    XCTAssertEqual(graph.edges.first?.cyclicCandidateRowIDs, [])
    XCTAssertEqual(graph.edges.dropFirst().first?.kind, .correlation)
    XCTAssertEqual(graph.edges.dropFirst().first?.candidateRowIDs, [correlationRow])
    XCTAssertFalse(graph.nodes.contains { $0.deviceSessionID == otherDevice.rowID })
    XCTAssertTrue(graph.truncated)

    let (cycleGraph, sixthTraversal) = try diagnostics.causality(
      traversal: fifthTraversal,
      rootRowID: cycleARow
    )
    let cycleEdge = try XCTUnwrap(
      cycleGraph.edges.first {
        $0.sourceRowID == cycleBRow && $0.kind == .replyTo
      }
    )
    XCTAssertEqual(cycleEdge.candidateRowIDs, [cycleARow])
    XCTAssertEqual(cycleEdge.cyclicCandidateRowIDs, [cycleARow])

    let (chainGraph, seventhTraversal) = try diagnostics.causality(
      traversal: sixthTraversal,
      rootRowID: chainRows[0]
    )
    XCTAssertEqual(chainGraph.nodes.count, 32)
    XCTAssertTrue(chainGraph.truncated)
    XCTAssertEqual(chainGraph.nodes.map(\.rowID), Array(chainRows.prefix(32)))
    XCTAssertTrue(
      plans.value.contains {
        $0.kind == .causality
          && $0.details.contains(where: { $0.contains("EVENTCAUSALITYLOOKUP") })
      }
    )
    XCTAssertFalse(
      plans.value.flatMap(\.details).contains {
        $0.hasPrefix("SCAN ") || $0.contains("USE TEMP B-TREE")
      }
    )
    XCTAssertTrue(Mirror(reflecting: graph.nodes[0]).children.isEmpty)
    query.end(seventhTraversal)
  }

  func testOptInLiveApplicationSupportArtifactsWhileViewerStoreIsOpen() throws {
    guard
      FileManager.default.fileExists(
        atPath: "/tmp/nearwire-live-container-audit.enabled"
      )
    else {
      throw XCTSkip(
        "Create the explicit local-container audit marker before this machine-local gate.")
    }
    let paths = try ViewerStorePaths.applicationSupport()
    XCTAssertNotEqual(ViewerRuntimeDependencies.live.loadStoreStatus().state, .unavailable)
    XCTAssertEqual(try permissions(paths.directory), 0o700)
    for url in [paths.database, paths.wal, paths.sharedMemory] {
      XCTAssertEqual(try permissions(url), 0o600)
      XCTAssertTrue(try isRegularFileWithoutFollowingLinks(url))
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
      print(
        "NearWire live container active artifact: \(url.path), mode=0600, size=\(values.fileSize ?? 0), allocated=\(values.fileAllocatedSize ?? 0)"
      )
    }
    print("NearWire live container directory: \(paths.directory.path), mode=0700")
  }

  func testStoreReopensAndRejectsUnknownSchema() throws {
    let paths = try makePaths()
    _ = try ViewerSQLitePool(migrating: paths)
    _ = try ViewerSQLitePool(migrating: paths)

    let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    try raw.execute("PRAGMA user_version=99")
    XCTAssertThrowsError(try ViewerSQLitePool(migrating: paths)) { error in
      XCTAssertEqual(error as? ViewerStoreError, .unsupportedSchema)
    }
  }

  func testStoreRejectsIncompleteVersionOneSchemaWithoutDeletingData() throws {
    let paths = try makePaths()
    do {
      let pool = try ViewerSQLitePool(migrating: paths)
      defer { pool.close() }
      try pool.writer.run { database in
        try ViewerSQLiteConnection.execute(
          "INSERT INTO Recordings(logicalID, startedWallMs, startedMonotonicNs, durableStartReason, quotaBytes, liveQuotaBytes) VALUES('preserve-me', 1, 1, 'test', 0, 0)",
          on: database
        )
      }
    }
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("ALTER TABLE Recordings DROP COLUMN liveQuotaBytes")
    }

    XCTAssertThrowsError(try ViewerSQLitePool(migrating: paths)) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    XCTAssertEqual(
      try raw.run {
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings WHERE logicalID='preserve-me'",
          database: $0
        )
      },
      1
    )
  }

  func testSchemaRoundTripsCheckedBindingsAndRollsBackFailure() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
      do {
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql:
            "INSERT INTO Recordings(logicalID, startedWallMs, startedMonotonicNs, durableStartReason, quotaBytes, liveQuotaBytes) VALUES(?1, ?2, ?3, ?4, ?5, ?5)"
        )
        try insert.bind("recording-one", at: 1)
        try insert.bind(Int64(1_000), at: 2)
        try insert.bind(Int64(2_000), at: 3)
        try insert.bind("liveStart", at: 4)
        try insert.bind(Int64(512), at: 5)
        XCTAssertFalse(try insert.step())
        try ViewerSQLiteConnection.execute("COMMIT", on: database)
      } catch {
        try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
        throw error
      }
    }
    XCTAssertThrowsError(
      try pool.writer.run { database in
        try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
        defer { try? ViewerSQLiteConnection.execute("ROLLBACK", on: database) }
        try ViewerSQLiteConnection.execute(
          "INSERT INTO Recordings(logicalID, startedWallMs, startedMonotonicNs, durableStartReason, quotaBytes, liveQuotaBytes) VALUES('recording-one', 1, 1, 'duplicate', 0, 0)",
          on: database
        )
      }
    )
    let count = try pool.queryReader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Recordings", database: $0)
    }
    XCTAssertEqual(count, 1)
  }

  func testSymlinkDatabaseAndDirectoryAreRejected() throws {
    let base = try makeTemporaryDirectory()
    let real = base.appendingPathComponent("real.sqlite")
    XCTAssertTrue(FileManager.default.createFile(atPath: real.path, contents: Data()))
    let directory = base.appendingPathComponent("Store", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let linked = directory.appendingPathComponent("NearWire.sqlite")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
    XCTAssertThrowsError(
      try ViewerSQLitePool(
        migrating: ViewerStorePaths(directory: directory, database: linked)
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidPath)
    }
  }

  func testPreferencesUseDefaultsAndRecoverFromCorruption() throws {
    let suite = "ViewerStoreTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("Missing defaults") }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ViewerStoragePreferences(defaults: defaults)

    XCTAssertEqual(preferences.load(), .default)
    let custom = try ViewerStorageConfiguration(
      capacityBytes: 512 * 1_024 * 1_024,
      historyRetentionDays: 30
    )
    preferences.save(custom)
    XCTAssertEqual(preferences.load(), custom)
    defaults.set(-1, forKey: "nearwire.storage.capacityBytes")
    XCTAssertEqual(preferences.load(), .default)
    defaults.set(true, forKey: "nearwire.storage.capacityBytes")
    XCTAssertEqual(preferences.load(), .default)
    defaults.set(
      ViewerStorageConfiguration.defaultCapacityBytes,
      forKey: "nearwire.storage.capacityBytes"
    )
    defaults.set(3.5, forKey: "nearwire.storage.historyRetentionDays")
    XCTAssertEqual(preferences.load(), .default)
  }

  func testConfigurationRejectsOutOfRangeValues() {
    XCTAssertThrowsError(
      try ViewerStorageConfiguration(capacityBytes: 1, historyRetentionDays: 7)
    )
    XCTAssertThrowsError(
      try ViewerStorageConfiguration(
        capacityBytes: ViewerStorageConfiguration.defaultCapacityBytes,
        historyRetentionDays: 0
      )
    )
  }

  func testEventStorePersistsIdempotentEventAndSearchesFrozenKeysetPage() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device-private-identifier",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Test App"
    )
    let first = try makeObservation(
      recording: recording, device: device, sequence: 1, value: "alpha % _")
    let second = try makeObservation(
      recording: recording, device: device, sequence: 2, value: "beta")
    let firstID = try store.appendEvent(first)
    XCTAssertEqual(try store.appendEvent(first), firstID)
    _ = try store.appendEvent(second)

    let leases = ViewerStoreLeaseRegistry()
    let service = ViewerStoreQueryService(pool: pool, leases: leases)
    let query = try ViewerEventQuery(
      recordingID: recording.rowID,
      predicates: [.eventTypePrefix("test."), .contentContains("% _")]
    )
    let traversal = try service.begin(query: query)
    let (page, _) = try service.page(
      traversal: traversal,
      cursor: nil,
      direction: .forward,
      limit: 100
    )
    XCTAssertEqual(page.rows.map(\.rowID), [firstID])
    XCTAssertEqual(page.rows.first?.eventType, "test.metric")
  }

  func testDurableDuplicateComparatorPreservesFirstReceiveAndAccountingValues() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let runtimeLogicalID = UUID()
    let connectionID = UUID()
    let appID = try EndpointID(rawValue: "durable-comparator-app")
    let viewerID = try EndpointID(rawValue: "durable-comparator-viewer")
    let firstHello = try WireHello(
      productVersion: WireProductVersion("1.0.0"),
      role: .app,
      installationID: appID,
      displayName: "First display",
      applicationIdentifier: "com.nearwire.comparator",
      applicationVersion: "1.0"
    )
    let laterHello = try WireHello(
      productVersion: WireProductVersion("1.0.0"),
      role: .app,
      installationID: appID,
      displayName: "Later display",
      applicationIdentifier: "com.nearwire.comparator",
      applicationVersion: "2.0"
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("1.0.0"),
      role: .viewer,
      installationID: viewerID
    )
    let firstContext = ViewerAdmissionSessionContext(
      connectionID: connectionID,
      appHello: firstHello,
      viewerHello: viewerHello,
      negotiation: try WireNegotiator.negotiate(local: viewerHello, remote: firstHello),
      receiveChunkBytes: 64 * 1_024
    )
    let laterContext = ViewerAdmissionSessionContext(
      connectionID: connectionID,
      appHello: laterHello,
      viewerHello: viewerHello,
      negotiation: try WireNegotiator.negotiate(local: viewerHello, remote: laterHello),
      receiveChunkBytes: 64 * 1_024
    )
    let recording = try store.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "duplicate-comparator"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: appID.rawValue,
      logicalID: connectionID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: firstHello.displayName,
      applicationIdentifier: firstHello.applicationIdentifier,
      applicationVersion: firstHello.applicationVersion
    )
    let envelope = try EventEnvelope(
      id: EventID(),
      type: EventType.user("test.durable-comparator"),
      content: .object(["value": .integer(1)]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000.000_1),
      monotonicTimestampNanoseconds: 3_000,
      source: EventEndpoint(role: .app, id: appID),
      target: EventEndpoint(role: .viewer, id: viewerID),
      direction: .appToViewer,
      sessionEpoch: SessionEpoch(),
      sequence: EventSequence(0),
      priority: .normal,
      ttl: .default,
      causality: EventCausality()
    )
    let wireBytes = try WireEventRecord(
      envelope: envelope,
      remainingTTLNanoseconds: 10_000_000_000
    ).deterministicEncodedByteCount()
    let first = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: firstContext,
      nickname: "First nickname",
      envelope: envelope,
      viewerWallMilliseconds: 11_111,
      viewerMonotonicNanoseconds: 22_222,
      deterministicEventBytes: wireBytes,
      initialDisposition: .buffered
    )
    let firstResult = try XCTUnwrap(
      store.appendEventResults([
        try ViewerPreparedEventObservation(
          recording: recording,
          device: device,
          committed: first
        )
      ]).first
    )
    XCTAssertEqual(firstResult.outcome, .accepted)
    let quotaAfterFirst = store.status().logicalQuotaBytes

    let identical = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: laterContext,
      nickname: "Later nickname",
      envelope: envelope,
      viewerWallMilliseconds: 99_999,
      viewerMonotonicNanoseconds: 88_888,
      deterministicEventBytes: wireBytes + 17,
      initialDisposition: .buffered
    )
    let identicalResult = try XCTUnwrap(
      store.appendEventResults([
        try ViewerPreparedEventObservation(
          recording: recording,
          device: device,
          committed: identical
        )
      ]).first
    )
    XCTAssertEqual(
      identicalResult,
      ViewerEventStoreCommitResult(
        rowID: firstResult.rowID,
        outcome: .identical
      ))

    let conflictingEnvelope = try EventEnvelope(
      id: envelope.id,
      type: envelope.type,
      content: .object(["value": .integer(2)]),
      createdAt: envelope.createdAt,
      monotonicTimestampNanoseconds: envelope.monotonicTimestampNanoseconds,
      source: envelope.source,
      target: envelope.target,
      direction: envelope.direction,
      sessionEpoch: envelope.sessionEpoch,
      sequence: envelope.sequence,
      priority: envelope.priority,
      ttl: envelope.ttl,
      causality: envelope.causality,
      schemaVersion: envelope.schemaVersion
    )
    let conflict = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: laterContext,
      nickname: nil,
      envelope: conflictingEnvelope,
      viewerWallMilliseconds: 77_777,
      viewerMonotonicNanoseconds: 66_666,
      deterministicEventBytes: wireBytes,
      initialDisposition: .buffered
    )
    let conflictResult = try XCTUnwrap(
      store.appendEventResults([
        try ViewerPreparedEventObservation(
          recording: recording,
          device: device,
          committed: conflict
        )
      ]).first
    )
    XCTAssertEqual(
      conflictResult,
      ViewerEventStoreCommitResult(
        rowID: firstResult.rowID,
        outcome: .journalConflict
      ))
    XCTAssertEqual(store.status().state, .available)
    XCTAssertEqual(store.status().logicalQuotaBytes, quotaAfterFirst)

    let stored = try pool.queryReader.run(budget: .query()) { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT viewerWallMs,viewerMonotonicNs,deterministicBytes,contentJSON,(SELECT COUNT(*) FROM EventDispositionVersions WHERE eventID=Events.rowID AND sequence=0) FROM Events WHERE rowID=?1"
      )
      try statement.bind(firstResult.rowID, at: 1)
      guard try statement.step() else { throw ViewerStoreError.corruptStore }
      return (
        statement.int64(at: 0), statement.int64(at: 1), statement.int64(at: 2),
        statement.data(at: 3), statement.int64(at: 4)
      )
    }
    XCTAssertEqual(stored.0, first.viewerWallMilliseconds)
    XCTAssertEqual(stored.1, Int64(first.viewerMonotonicNanoseconds))
    XCTAssertEqual(stored.2, Int64(first.deterministicEventBytes))
    XCTAssertEqual(stored.3, first.durableProjection.canonicalContent)
    XCTAssertEqual(stored.4, 1)
    pool.close()
  }

  func testAppendOnlyDispositionPolicyAndDropSamplesAreIdempotentAndDetectConflicts() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    let buffered = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "buffered",
      initialDisposition: .buffered
    )
    _ = try store.appendEvent(buffered)
    let conflictingInitial = try ViewerPreparedEventObservation(
      recording: recording,
      device: device,
      envelope: buffered.envelope,
      viewerMonotonicNanoseconds: buffered.viewerMonotonicNanoseconds,
      viewerWallMilliseconds: buffered.viewerWallMilliseconds,
      deterministicEventBytes: buffered.deterministicEventBytes,
      initialDisposition: .transportAdmitted
    )
    XCTAssertEqual(
      try store.appendEventResults([conflictingInitial]).first?.outcome,
      .journalConflict
    )
    try store.retry()
    let terminal = ViewerStructuralObservation.disposition(
      recording: recording,
      device: device,
      direction: .appToViewer,
      wireSequence: 1,
      value: .consumerAccepted,
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100
    )
    try store.appendStructural(terminal)
    try store.appendStructural(terminal)
    XCTAssertThrowsError(
      try store.appendStructural(
        .disposition(
          recording: recording,
          device: device,
          direction: .appToViewer,
          wireSequence: 1,
          value: .expired,
          wallMilliseconds: 1_200,
          monotonicNanoseconds: 2_200
        )
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    try store.retry()

    let policyJSON = try ViewerCanonicalJSON.encode(ViewerRatePolicy.default)
    let policy = ViewerStructuralObservation.policy(
      device: device,
      sequence: 1,
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      policyJSON: policyJSON
    )
    try store.appendStructural(policy)
    try store.appendStructural(policy)
    XCTAssertThrowsError(
      try store.appendStructural(
        .policy(
          device: device,
          sequence: 1,
          wallMilliseconds: 1_200,
          monotonicNanoseconds: 2_200,
          policyJSON: Data("{}".utf8)
        )
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    try store.retry()

    let drop = ViewerStructuralObservation.drop(
      device: device,
      sequence: 1,
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
      count: 2
    )
    try store.appendStructural(drop)
    try store.appendStructural(drop)
    XCTAssertThrowsError(
      try store.appendStructural(
        .drop(
          device: device,
          sequence: 1,
          wallMilliseconds: 1_200,
          monotonicNanoseconds: 2_200,
          reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
          count: 3
        )
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }
    try store.retry()
    try store.appendStructural(
      .drop(
        device: device,
        sequence: 2,
        wallMilliseconds: 1_300,
        monotonicNanoseconds: 2_300,
        reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
        count: 5
      )
    )
    XCTAssertThrowsError(
      try store.appendStructural(
        .drop(
          device: device,
          sequence: 3,
          wallMilliseconds: 1_400,
          monotonicNanoseconds: 2_400,
          reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
          count: 4
        )
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .staleObservation)
    }

    let recordingGap = ViewerStructuralObservation.gap(
      recording: recording,
      device: nil,
      sequence: 9,
      reason: "storageUnavailable",
      count: 2,
      firstWallMilliseconds: 1_100,
      lastWallMilliseconds: 1_100,
      directions: "unknown",
      firstWireSequence: nil,
      lastWireSequence: nil
    )
    try store.appendStructural(recordingGap)
    try store.appendStructural(recordingGap)
    XCTAssertThrowsError(
      try store.appendStructural(
        .gap(
          recording: recording,
          device: nil,
          sequence: 9,
          reason: "differentReason",
          count: 1,
          firstWallMilliseconds: 1_200,
          lastWallMilliseconds: 1_200,
          directions: "unknown",
          firstWireSequence: nil,
          lastWireSequence: nil
        )
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .corruptStore)
    }

    let counts = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM EventDispositionVersions",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM PolicyVersions", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM DropVersions", database: database),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM GapVersions WHERE deviceSessionID IS NULL",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64(
          "SELECT count FROM GapVersions WHERE deviceSessionID IS NULL",
          database: database
        )
      )
    }
    XCTAssertEqual(counts.0, 2)
    XCTAssertEqual(counts.1, 1)
    XCTAssertEqual(counts.2, 2)
    XCTAssertEqual(counts.3, 1)
    XCTAssertEqual(counts.4, 2)
  }

  func testRejectedCumulativeDropSampleCreatesGapBeforeLaterSample() throws {
    let paths = try makePaths()
    let fault = CountingViewerStoreFault()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { try fault.check() })
    let logicalID = UUID()
    let context = try makeAdmissionContext(suffix: "drop-gap")
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    XCTAssertTrue(coordinator.sessionStarted(context))
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths)) == 1
    }

    fault.failEveryAttempt()
    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .localOverflow, count: 2)],
      monotonicNanoseconds: 3_000
    )
    waitUntil { coordinator.services.eventStore.status().state == .writeFailed }

    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .localOverflow, count: 5)],
      monotonicNanoseconds: 3_100
    )
    fault.succeedEveryAttempt()
    XCTAssertTrue(coordinator.retryStorage())
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM DropVersions", at: paths)) == 1
        && (try? self.scalar(
          "SELECT COUNT(*) FROM GapVersions WHERE reason='dropJournalFull'",
          at: paths
        )) == 1
    }

    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .localOverflow, count: 7)],
      monotonicNanoseconds: 3_200
    )
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM DropVersions", at: paths)) == 2
    }
    XCTAssertEqual(
      try scalar("SELECT MIN(count) FROM DropVersions", at: paths),
      2
    )
    XCTAssertEqual(
      try scalar("SELECT MAX(count) FROM DropVersions", at: paths),
      7
    )
    coordinator.closeStorage()
  }

  func testDropPlanningRejectsNonIncreasingCountsBeforeCapacityRecovery() throws {
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 7
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "drop-planning"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "drop-planning-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    try store.appendStructural(
      .drop(
        device: device,
        sequence: 1,
        wallMilliseconds: 1_100,
        monotonicNanoseconds: 2_100,
        reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
        count: 5
      )
    )
    let eligible = try store.beginRecording(
      wallMilliseconds: 500,
      monotonicNanoseconds: 600,
      reason: "eligible"
    )
    try store.appendStructural(
      .closeRecording(eligible, wallMilliseconds: 700, monotonicNanoseconds: 800)
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=\(configuration.capacityBytes) WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    let recoveryCount = LockedCounter()
    store.setCapacityRecovery { _, _ in recoveryCount.increment() }

    try store.appendStructural(
      .drop(
        device: device,
        sequence: 2,
        wallMilliseconds: 1_200,
        monotonicNanoseconds: 2_200,
        reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
        count: 5
      )
    )
    XCTAssertThrowsError(
      try store.appendStructural(
        .drop(
          device: device,
          sequence: 3,
          wallMilliseconds: 1_300,
          monotonicNanoseconds: 2_300,
          reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
          count: 4
        )
      )
    ) {
      XCTAssertEqual($0 as? ViewerStoreError, .staleObservation)
    }
    let result = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM DropVersions", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: database),
        try ViewerStoreSchema.scalarInt64(
          "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
          database: database
        )
      )
    }
    XCTAssertEqual(result.0, 1)
    XCTAssertEqual(result.1, 0)
    XCTAssertEqual(result.2, configuration.capacityBytes)
    XCTAssertEqual(recoveryCount.value, 0)
    XCTAssertEqual(store.status().state, .available)
    pool.close()
  }

  func testCoordinatorSaturatesDropProjectionAndGapsARealDecrease() throws {
    let paths = try makePaths()
    let coordinator = try ViewerStoreCoordinator(paths: paths)
    let logicalID = UUID()
    let context = try makeAdmissionContext(suffix: "drop-saturation")
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    XCTAssertTrue(coordinator.sessionStarted(context))
    waitUntil { (try? self.scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths)) == 1 }

    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .remoteOverflow, count: UInt64(Int64.max))],
      monotonicNanoseconds: 3_000
    )
    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .remoteOverflow, count: UInt64(Int64.max) + 1)],
      monotonicNanoseconds: 3_100
    )
    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .remoteOverflow, count: UInt64.max)],
      monotonicNanoseconds: 3_200
    )
    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .remoteOverflow, count: UInt64(Int64.max - 1))],
      monotonicNanoseconds: 3_300
    )
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM DropVersions", at: paths)) == 1
        && (try? self.scalar(
          "SELECT COUNT(*) FROM GapVersions WHERE reason='dropJournalNonIncreasing'",
          at: paths
        )) == 1
    }
    XCTAssertEqual(
      try scalar("SELECT count FROM DropVersions", at: paths),
      Int64.max
    )
    XCTAssertEqual(coordinator.services.eventStore.status().state, .available)
    coordinator.closeStorage()
  }

  func testDurableMetadataAndSensitiveReflectionAreBoundedAndRedacted() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    XCTAssertThrowsError(
      try store.beginDeviceSession(
        recording: recording,
        installationID: String(repeating: "x", count: 513),
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000,
        partialHistory: false,
        displayName: nil
      )
    )
    XCTAssertThrowsError(
      try store.beginDeviceSession(
        recording: recording,
        installationID: "device",
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000,
        partialHistory: false,
        displayName: "secret\nname"
      )
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    let observation = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "reflection-secret"
    )
    XCTAssertFalse(String(reflecting: observation).contains("reflection-secret"))
    XCTAssertFalse(String(describing: observation).contains("reflection-secret"))

    let received = try WireEventRecord(
      envelope: observation.envelope,
      remainingTTLNanoseconds: 1_000_000
    ).receiverEvent(receivedAtNanoseconds: 9_000)
    let downlink = ViewerDownlinkJournalEvent(
      envelope: observation.envelope,
      deterministicEncodedByteCount: received.deterministicEncodedByteCount,
      canonicalContentData: received.canonicalContentData
    )
    let structural: [ViewerStructuralObservation] = [
      .policy(
        device: device,
        sequence: 1,
        wallMilliseconds: 1,
        monotonicNanoseconds: 1,
        policyJSON: Data("reflection-secret".utf8)
      ),
      .drop(
        device: device,
        sequence: 1,
        wallMilliseconds: 1,
        monotonicNanoseconds: 1,
        reason: "reflection-secret",
        count: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "reflection-secret",
        count: 1,
        firstWallMilliseconds: 1,
        lastWallMilliseconds: 1,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      ),
    ]
    let carriers: [Any] = [received, downlink] + structural.map { $0 as Any }
    for carrier in carriers {
      XCTAssertFalse(String(describing: carrier).contains("reflection-secret"))
      XCTAssertFalse(String(reflecting: carrier).contains("reflection-secret"))
      XCTAssertFalse(
        Mirror(reflecting: carrier).children.contains {
          String(reflecting: $0.value).contains("reflection-secret")
        }
      )
      XCTAssertFalse("diagnostic=\(carrier)".contains("reflection-secret"))
    }
  }

  func testQueryCompilerTreatsOperatorsAndWildcardsAsLiteralBindings() throws {
    let query = try ViewerEventQuery(
      recordingID: 1,
      predicates: [
        .fullText("one OR two %_\\\""),
        .json(path: "$.payload[0].value", equals: .string("x' --")),
      ]
    )
    XCTAssertNoThrow(try ViewerEventQueryCompiler.compile(query))
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(
          recordingID: 1,
          predicates: [.json(path: "$['open']", equals: .null)]
        )
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(
          recordingID: 1,
          predicates: [.fullText(Array(repeating: "term", count: 33).joined(separator: " "))]
        )
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(
          recordingID: 1,
          predicates: [.fullText(String(repeating: "x", count: 513))]
        )
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.contentContains("bad\u{0}value")])
      )
    )
  }

  func testQueryCompilerRejectsImpossibleEventTypesAndNonASCIIJSONIndexes() throws {
    for value in ["1leading", "empty..segment", "trailing.", "unicode.é", ".leading"] {
      XCTAssertThrowsError(
        try ViewerEventQueryCompiler.compile(
          ViewerEventQuery(recordingID: 1, predicates: [.eventTypeEquals(value)])
        )
      )
    }
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(
          recordingID: 1,
          predicates: [.eventTypeEquals("a" + String(repeating: "b", count: 128))]
        )
      )
    )
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix("valid.")])
      )
    )
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix("valid.part")])
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix("invalid..")])
      )
    )
    let segment126 = "a" + String(repeating: "b", count: 125)
    let segment127 = "a" + String(repeating: "b", count: 126)
    let segment128 = "a" + String(repeating: "b", count: 127)
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix(segment126 + ".")])
      )
    )
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix(segment127)])
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix(segment127 + ".")])
      )
    )
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.eventTypePrefix(segment128)])
      )
    )
    XCTAssertNoThrow(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.jsonExists(path: "$.items[12]")])
      )
    )
    XCTAssertThrowsError(
      try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [.jsonExists(path: "$.items[١]")])
      )
    )
  }

  func testSensitiveQueryAndSummaryModelsHaveClosedRedactedReflection() throws {
    let secret = "secret.event.value"
    let query = try ViewerEventQuery(
      recordingID: 1,
      predicates: [.eventTypeEquals(secret), .fullText(secret)]
    )
    let compiled = try ViewerEventQueryCompiler.compile(query)
    let row = ViewerStoredEventRow(
      rowID: 1,
      deviceSessionID: 2,
      direction: "appToViewer",
      wireSequence: 3,
      eventUUID: secret,
      eventType: secret,
      contentByteCount: 4,
      createdWallMilliseconds: 5,
      viewerWallMilliseconds: 6,
      viewerMonotonicNanoseconds: 7,
      priority: "normal",
      recordingRevision: 1,
      deviceRevision: 1,
      resolvedDisposition: "buffered"
    )
    let values: [Any] = [
      ViewerQueryScalar.string(secret),
      ViewerEventPredicate.fullText(secret),
      query,
      ViewerQueryBinding.text(secret),
      compiled,
      row,
      ViewerEventPage(rows: [row], nextCursor: nil, previousCursor: nil),
    ]
    for value in values {
      XCTAssertFalse(String(describing: value).contains(secret))
      XCTAssertFalse(String(reflecting: value).contains(secret))
      XCTAssertFalse(
        Mirror(reflecting: value).children.contains {
          String(reflecting: $0.value).contains(secret)
        }
      )
    }
  }

  func testSQLiteProgressBudgetReportsWorkLimitInsteadOfCancellation() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let connection = pool.queryReader
    XCTAssertThrowsError(
      try connection.run(
        budget: ViewerSQLiteBudget(
          maximumVirtualMachineSteps: 1_000,
          deadline: .now + .seconds(1)
        )
      ) { database in
        try ViewerStoreSchema.scalarInt64(
          "WITH RECURSIVE valueset(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM valueset WHERE value<1000000) SELECT SUM(value) FROM valueset",
          database: database
        )
      }
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .workLimitExceeded)
    }
    pool.close()
  }

  func testUnavailableRuntimeReopensAfterExplicitRetry() async throws {
    let paths = try makePaths()
    do { _ = try ViewerSQLitePool(migrating: paths) }
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=99")
    }
    let fault = OneShotViewerStoreFault()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: { try fault.check() }
    )
    XCTAssertEqual(runtime.status().state, .unavailable)
    let logicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=3")
    }

    fault.failNext()
    runtime.retryStorage()
    waitUntil { fault.failureCount == 1 && !runtime.isRecoveryInFlight }
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: logicalID
        )) == 1)
    }
    XCTAssertEqual(runtime.status().state, .available)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 0)
    XCTAssertEqual(
      try scalar(
        "SELECT COUNT(*) FROM Recordings WHERE durableStartReason='midRuntimeRetry'",
        at: paths
      ),
      1
    )

    let laterRetryFinished = expectation(description: "Later retry finished")
    runtime.retryStorage()
    runtime.afterCurrentJournalPrefix { laterRetryFinished.fulfill() }
    await fulfillment(of: [laterRetryFinished], timeout: 2)
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: logicalID),
      1
    )

    await runtime.runtimeEnded(
      logicalID: logicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 5_000
    )
    let raw = try ViewerSQLiteConnection(
      role: .queryReader, path: paths.database.path, readOnly: true)
    let recovered = try raw.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COALESCE(MAX(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
          database: database
        )
      )
    }
    XCTAssertEqual(recovered.0, 1)
    XCTAssertEqual(recovered.1, 1)
    raw.close()
    runtime.closeStorage()
  }

  func testFailedInitialExplicitRetryDoesNotAuthorizeLaterRuntime() async throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    pool.close()
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=99")
      raw.close()
    }
    let runtime = ViewerStoreRuntime(paths: paths)
    let firstLogicalID = UUID()
    let laterLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )

    runtime.retryStorage()
    let failedRetryFinished = expectation(description: "Failed explicit retry finished")
    runtime.afterCurrentReopenPrefix { failedRetryFinished.fulfill() }
    await fulfillment(of: [failedRetryFinished], timeout: 2)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=3")
      raw.close()
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )
    runtime.runtimeStarted(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    let automaticPrefixFinished = expectation(description: "Unauthorized automatic prefix")
    runtime.afterCurrentReopenPrefix { automaticPrefixFinished.fulfill() }
    await fulfillment(of: [automaticPrefixFinished], timeout: 2)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: laterLogicalID,
          state: "active"
        )) == 1)
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: laterLogicalID
        )) == 1)
    }
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: laterLogicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )
  }

  func testCancelledInitialExplicitRetryDoesNotAuthorizeLaterRuntime() async throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    pool.close()
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=99")
      raw.close()
    }
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let laterLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=3")
      raw.close()
    }

    reopenGate.arm()
    runtime.retryStorage()
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    let ended = LockedViewerCounter()
    let endTask = Task {
      await runtime.runtimeEnded(
        logicalID: firstLogicalID,
        wallMilliseconds: wallMilliseconds + 1_000,
        monotonicNanoseconds: 4_000
      )
      ended.increment()
    }
    waitUntil { resourceEvents.value.contains(.runtimeEndWaiting) }
    XCTAssertEqual(ended.value, 0)
    reopenGate.release()
    await endTask.value
    XCTAssertEqual(ended.value, 1)
    XCTAssertEqual(
      resourceEvents.value,
      [.runtimeEndWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )

    runtime.runtimeStarted(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    let automaticPrefixFinished = expectation(description: "Cancelled explicit automatic prefix")
    runtime.afterCurrentReopenPrefix { automaticPrefixFinished.fulfill() }
    await fulfillment(of: [automaticPrefixFinished], timeout: 2)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: laterLogicalID,
          state: "active"
        )) == 1)
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: laterLogicalID
        )) == 1)
    }
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: laterLogicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )
  }

  func testRepeatedRuntimeStartPreservesOriginalContextAndRecoveryOwnership() async throws {
    let paths = try makePaths()
    do { _ = try ViewerSQLitePool(migrating: paths) }
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=99")
      raw.close()
    }
    let fault = OneShotViewerStoreFault()
    let reopenGate = ArmableViewerExecutionGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: { try fault.check() },
      reopenExecutionGate: { reopenGate.run() }
    )
    let logicalID = UUID()
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000
    )
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 10_000,
      monotonicNanoseconds: 20_000
    )
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=3")
      raw.close()
    }

    reopenGate.arm()
    runtime.retryStorage()
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 30_000,
      monotonicNanoseconds: 40_000
    )
    fault.failNext()
    reopenGate.release()
    waitUntil { fault.failureCount == 1 && !runtime.isRecoveryInFlight }
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 50_000,
      monotonicNanoseconds: 60_000
    )
    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: logicalID
        )) == 1)
    }
    let start = try recordingStart(at: paths, logicalID: logicalID)
    XCTAssertEqual(start.wallMilliseconds, 1_000)
    XCTAssertEqual(start.monotonicNanoseconds, 2_000)
    XCTAssertEqual(start.reason, "midRuntimeRetry")
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 0)

    let laterRetryFinished = expectation(description: "Repeated-start later retry finished")
    runtime.retryStorage()
    runtime.afterCurrentJournalPrefix { laterRetryFinished.fulfill() }
    await fulfillment(of: [laterRetryFinished], timeout: 2)
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: logicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: logicalID,
      wallMilliseconds: 70_000,
      monotonicNanoseconds: 80_000
    )
  }

  func testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes() async throws {
    let paths = try makePaths()
    do { _ = try ViewerSQLitePool(migrating: paths) }
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=99")
      raw.close()
    }
    let fault = OneShotViewerStoreFault()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: { try fault.check() }
    )
    let logicalID = UUID()
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000
    )
    runtime.policyChanged(
      runtimeLogicalID: logicalID,
      connectionID: UUID(),
      policy: .default,
      monotonicNanoseconds: 3_000
    )
    do {
      let raw = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
      try raw.execute("PRAGMA user_version=3")
      raw.close()
    }

    fault.failNext()
    runtime.retryStorage()
    waitUntil { fault.failureCount == 1 && !runtime.isRecoveryInFlight }
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.policyChanged(
      runtimeLogicalID: logicalID,
      connectionID: UUID(),
      policy: .default,
      monotonicNanoseconds: 4_000
    )
    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && !runtime.isRecoveryInFlight
        && ((try? self.scalar(
          "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
          at: paths
        )) == 3)
    }
    XCTAssertEqual(
      try scalar(
        "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
        at: paths
      ),
      3
    )
    await runtime.runtimeEnded(
      logicalID: logicalID,
      wallMilliseconds: 5_000,
      monotonicNanoseconds: 6_000
    )
  }

  func testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork() async throws {
    let paths = try makePaths()
    let initialFailure = BlockingViewerStoreFailureGate()
    let retryFailure = BlockingViewerStoreFailureGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: {
        try initialFailure.check()
        try retryFailure.check()
      }
    )
    let logicalID = UUID()
    initialFailure.arm()
    runtime.runtimeStarted(
      logicalID: logicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000
    )
    XCTAssertEqual(initialFailure.waitUntilEntered(), .success)
    let context = try makeAdmissionContext(suffix: "runtime-recovery")
    for _ in 0..<40 {
      runtime.sessionStarted(runtimeLogicalID: logicalID, context)
    }
    let prefixCompleted = expectation(description: "Accepted lifecycle prefix completed")
    runtime.afterCurrentJournalPrefix { prefixCompleted.fulfill() }
    initialFailure.release()
    await fulfillment(of: [prefixCompleted], timeout: 5)
    XCTAssertEqual(runtime.status().state, .unavailable)

    retryFailure.arm()
    runtime.retryStorage()
    XCTAssertEqual(retryFailure.waitUntilEntered(), .success)
    XCTAssertTrue(runtime.isRecoveryInFlight)
    retryFailure.release()
    waitUntil(timeout: 5) { !runtime.isRecoveryInFlight }
    XCTAssertEqual(retryFailure.armedCheckCount, 1)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && !runtime.isRecoveryInFlight
        && ((try? self.scalar(
          "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
          at: paths
        )) == 6)
        && ((try? self.scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths)) == 1)
    }
    XCTAssertEqual(
      try scalar(
        "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
        at: paths
      ),
      6
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 1)
    await runtime.runtimeEnded(
      logicalID: logicalID,
      wallMilliseconds: 5_000,
      monotonicNanoseconds: 6_000
    )
  }

  func testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime() async throws {
    let paths = try makePaths()
    let fault = OneShotViewerStoreFault()
    let reopenGate = ArmableViewerExecutionGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: { try fault.check() },
      reopenExecutionGate: { reopenGate.run() }
    )
    let oldLogicalID = UUID()
    let newLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: oldLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: oldLogicalID,
        state: "active"
      )) == 1
    }

    runtime.runtimeStarted(
      logicalID: newLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 4_000
    )
    XCTAssertEqual(runtime.status().state, .unavailable)

    reopenGate.arm()
    await runtime.runtimeEnded(
      logicalID: oldLogicalID,
      wallMilliseconds: wallMilliseconds + 5_000,
      monotonicNanoseconds: 7_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    fault.failNext()
    reopenGate.release()
    waitUntil { fault.failureCount == 1 && !runtime.isRecoveryInFlight }
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: newLogicalID, state: "active"),
      0
    )

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: newLogicalID,
          state: "active"
        )) == 1)
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: newLogicalID
        )) == 1)
    }
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: newLogicalID),
      1
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 0)

    let laterRetryFinished = expectation(description: "Later replacement retry finished")
    runtime.retryStorage()
    runtime.afterCurrentJournalPrefix { laterRetryFinished.fulfill() }
    await fulfillment(of: [laterRetryFinished], timeout: 2)
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: newLogicalID),
      1
    )

    await runtime.runtimeEnded(
      logicalID: oldLogicalID,
      wallMilliseconds: wallMilliseconds + 7_000,
      monotonicNanoseconds: 9_000
    )
    XCTAssertEqual(runtime.status().state, .available)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: newLogicalID, state: "active"),
      1
    )

    await runtime.runtimeEnded(
      logicalID: newLogicalID,
      wallMilliseconds: wallMilliseconds + 9_000,
      monotonicNanoseconds: 11_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: newLogicalID,
        state: "closed"
      )) == 1
    }
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: newLogicalID, state: "closed"),
      1
    )
  }

  func testSequentialRuntimeAutomaticallyReopensAfterCompletedShutdown() async throws {
    let paths = try makePaths()
    let runtime = ViewerStoreRuntime(paths: paths)
    let firstLogicalID = UUID()
    let secondLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    let firstStoreGeneration = runtime.status().storeGeneration
    XCTAssertGreaterThan(firstStoreGeneration, 0)

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    XCTAssertEqual(runtime.status().storeGeneration, firstStoreGeneration)
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: firstLogicalID, state: "closed"),
      1
    )
    XCTAssertEqual(runtime.status().storeGeneration, 0)

    runtime.runtimeStarted(
      logicalID: secondLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: secondLogicalID,
          state: "active"
        )) == 1)
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: secondLogicalID
        )) == 1)
    }
    XCTAssertGreaterThan(runtime.status().storeGeneration, firstStoreGeneration)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 1)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: firstLogicalID, state: "closed"),
      0
    )
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: secondLogicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: secondLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )
  }

  func testFailedAutomaticSequentialReopenRetainsMarkerForExplicitRetry() async throws {
    let paths = try makePaths()
    let fault = OneShotViewerStoreFault()
    let reopenGate = ArmableViewerExecutionGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      coordinatorWriteGate: { try fault.check() },
      reopenExecutionGate: { reopenGate.run() }
    )
    let firstLogicalID = UUID()
    let secondLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: secondLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    fault.failNext()
    reopenGate.release()
    waitUntil { fault.failureCount == 1 && !runtime.isRecoveryInFlight }
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: secondLogicalID, state: "active"),
      0
    )

    runtime.retryStorage()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: secondLogicalID,
          state: "active"
        )) == 1)
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: secondLogicalID
        )) == 1)
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 1)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: firstLogicalID, state: "closed"),
      0
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 0)
    await runtime.runtimeEnded(
      logicalID: secondLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )
  }

  func testEndedRuntimeCancelsPausedAutomaticReopenAndPreservesNextAttempt() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let cancelledLogicalID = UUID()
    let laterLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: cancelledLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    let ended = LockedViewerCounter()
    let endTask = Task {
      await runtime.runtimeEnded(
        logicalID: cancelledLogicalID,
        wallMilliseconds: wallMilliseconds + 3_000,
        monotonicNanoseconds: 8_000
      )
      ended.increment()
    }
    waitUntil { resourceEvents.value.contains(.runtimeEndWaiting) }
    XCTAssertEqual(ended.value, 0)
    reopenGate.release()
    await endTask.value
    XCTAssertEqual(ended.value, 1)
    let cancelledPrefixFinished = expectation(description: "Cancelled reopen prefix finished")
    runtime.afterCurrentReopenPrefix { cancelledPrefixFinished.fulfill() }
    await fulfillment(of: [cancelledPrefixFinished], timeout: 2)
    XCTAssertEqual(
      resourceEvents.value,
      [.runtimeEndWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: cancelledLogicalID,
        state: "active"
      ),
      0
    )

    runtime.runtimeStarted(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 4_000,
      monotonicNanoseconds: 10_000
    )
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: laterLogicalID,
          state: "active"
        )) == 1)
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: laterLogicalID
        )) == 1)
    }
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: laterLogicalID),
      1
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 1)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: firstLogicalID, state: "closed"),
      0
    )
    await runtime.runtimeEnded(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 5_000,
      monotonicNanoseconds: 12_000
    )
  }

  func testTerminalCloseCancelsPausedAutomaticReopen() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let cancelledLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: cancelledLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    let closed = LockedViewerCounter()
    let closeTask = Task.detached {
      runtime.closeStorage()
      closed.increment()
    }
    waitUntil { resourceEvents.value.contains(.terminalCloseWaiting) }
    XCTAssertEqual(closed.value, 0)
    reopenGate.release()
    await closeTask.value
    XCTAssertEqual(closed.value, 1)
    let cancelledPrefixFinished = expectation(description: "Terminal reopen prefix finished")
    runtime.afterCurrentReopenPrefix { cancelledPrefixFinished.fulfill() }
    await fulfillment(of: [cancelledPrefixFinished], timeout: 2)
    XCTAssertEqual(
      resourceEvents.value,
      [.terminalCloseWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: cancelledLogicalID,
        state: "active"
      ),
      0
    )
  }

  func testNewerRuntimeSupersedesPausedAutomaticReopen() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let supersededLogicalID = UUID()
    let currentLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: supersededLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    runtime.runtimeStarted(
      logicalID: currentLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )
    let supersededEnded = LockedViewerCounter()
    let supersededEndTask = Task {
      await runtime.runtimeEnded(
        logicalID: supersededLogicalID,
        wallMilliseconds: wallMilliseconds + 4_000,
        monotonicNanoseconds: 10_000
      )
      supersededEnded.increment()
    }
    waitUntil { resourceEvents.value.contains(.runtimeEndWaiting) }
    XCTAssertEqual(supersededEnded.value, 0)
    reopenGate.release()
    await supersededEndTask.value
    XCTAssertEqual(supersededEnded.value, 1)
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: currentLogicalID,
          state: "active"
        )) == 1)
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: currentLogicalID
        )) == 1)
    }
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: supersededLogicalID,
        state: "active"
      ),
      0
    )
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: currentLogicalID),
      1
    )
    XCTAssertEqual(
      Array(resourceEvents.value.prefix(3)),
      [.runtimeEndWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )

    await runtime.runtimeEnded(
      logicalID: supersededLogicalID,
      wallMilliseconds: wallMilliseconds + 4_500,
      monotonicNanoseconds: 11_000
    )
    XCTAssertEqual(runtime.status().state, .available)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: currentLogicalID,
        state: "active"
      ),
      1
    )
    await runtime.runtimeEnded(
      logicalID: currentLogicalID,
      wallMilliseconds: wallMilliseconds + 5_000,
      monotonicNanoseconds: 12_000
    )
  }

  func testFinalCurrentRuntimeWaitsForSupersededReopenConstruction() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let supersededLogicalID = UUID()
    let finalLogicalID = UUID()
    let laterLogicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: supersededLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    runtime.runtimeStarted(
      logicalID: finalLogicalID,
      wallMilliseconds: wallMilliseconds + 3_000,
      monotonicNanoseconds: 8_000
    )

    let finalEnded = LockedViewerCounter()
    let finalEndTask = Task {
      await runtime.runtimeEnded(
        logicalID: finalLogicalID,
        wallMilliseconds: wallMilliseconds + 4_000,
        monotonicNanoseconds: 10_000
      )
      finalEnded.increment()
    }
    waitUntil { resourceEvents.value.contains(.runtimeEndWaiting) }
    XCTAssertEqual(finalEnded.value, 0)
    reopenGate.release()
    await finalEndTask.value
    XCTAssertEqual(finalEnded.value, 1)
    let cancelledPrefixFinished = expectation(description: "Final runtime cancellation finished")
    runtime.afterCurrentReopenPrefix { cancelledPrefixFinished.fulfill() }
    await fulfillment(of: [cancelledPrefixFinished], timeout: 2)

    XCTAssertEqual(
      resourceEvents.value,
      [.runtimeEndWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 1)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: supersededLogicalID,
        state: "active"
      ),
      0
    )
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: finalLogicalID, state: "active"),
      0
    )

    await runtime.runtimeEnded(
      logicalID: supersededLogicalID,
      wallMilliseconds: wallMilliseconds + 4_500,
      monotonicNanoseconds: 11_000
    )
    runtime.runtimeStarted(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 5_000,
      monotonicNanoseconds: 12_000
    )
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: laterLogicalID,
          state: "active"
        )) == 1)
        && ((try? self.recordingStorageUnavailableGapCount(
          at: paths,
          logicalID: laterLogicalID
        )) == 1)
    }
    XCTAssertEqual(reopenGate.value, 2)
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: laterLogicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: laterLogicalID,
      wallMilliseconds: wallMilliseconds + 6_000,
      monotonicNanoseconds: 14_000
    )
  }

  func testRepeatedRuntimeSupersessionCoalescesOneReopenSuccessor() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() }
    )
    let firstLogicalID = UUID()
    let blockedLogicalID = UUID()
    let supersedingLogicalIDs = (0..<64).map { _ in UUID() }
    let latestLogicalID = try XCTUnwrap(supersedingLogicalIDs.last)
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: blockedLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    for (index, logicalID) in supersedingLogicalIDs.enumerated() {
      runtime.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: wallMilliseconds + 3_000 + Int64(index),
        monotonicNanoseconds: 8_000 + UInt64(index)
      )
    }
    reopenGate.release()
    waitUntil {
      runtime.status().state == .available
        && ((try? self.latestRecordingStateCount(
          at: paths,
          logicalID: latestLogicalID,
          state: "active"
        )) == 1)
    }

    XCTAssertEqual(reopenGate.value, 2)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 1)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: blockedLogicalID, state: "active"),
      0
    )
    for logicalID in supersedingLogicalIDs.dropLast() {
      XCTAssertEqual(
        try latestRecordingStateCount(at: paths, logicalID: logicalID, state: "active"),
        0
      )
    }
    XCTAssertEqual(
      try recordingStorageUnavailableGapCount(at: paths, logicalID: latestLogicalID),
      1
    )
    await runtime.runtimeEnded(
      logicalID: latestLogicalID,
      wallMilliseconds: wallMilliseconds + 5_000,
      monotonicNanoseconds: 12_000
    )
  }

  func testTerminalCloseDiscardsCoalescedReopenSuccessor() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let resourceEvents = LockedViewerReopenResourceEvents()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() },
      reopenResourceObserver: { resourceEvents.append($0) }
    )
    let firstLogicalID = UUID()
    let blockedLogicalID = UUID()
    let supersedingLogicalIDs = (0..<64).map { _ in UUID() }
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

    runtime.runtimeStarted(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds,
      monotonicNanoseconds: 2_000
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: firstLogicalID,
        state: "active"
      )) == 1
    }
    await runtime.runtimeEnded(
      logicalID: firstLogicalID,
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )

    reopenGate.arm()
    runtime.runtimeStarted(
      logicalID: blockedLogicalID,
      wallMilliseconds: wallMilliseconds + 2_000,
      monotonicNanoseconds: 6_000
    )
    XCTAssertEqual(reopenGate.waitUntilBlocked(), .success)
    for (index, logicalID) in supersedingLogicalIDs.enumerated() {
      runtime.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: wallMilliseconds + 3_000 + Int64(index),
        monotonicNanoseconds: 8_000 + UInt64(index)
      )
    }

    let closed = LockedViewerCounter()
    let closeTask = Task.detached {
      runtime.closeStorage()
      closed.increment()
    }
    waitUntil { resourceEvents.value.contains(.terminalCloseWaiting) }
    XCTAssertEqual(closed.value, 0)
    reopenGate.release()
    await closeTask.value
    XCTAssertEqual(closed.value, 1)
    let reopenPrefixFinished = expectation(description: "Coalesced terminal prefix finished")
    runtime.afterCurrentReopenPrefix { reopenPrefixFinished.fulfill() }
    await fulfillment(of: [reopenPrefixFinished], timeout: 2)

    XCTAssertEqual(reopenGate.value, 1)
    XCTAssertEqual(
      resourceEvents.value,
      [.terminalCloseWaiting, .coordinatorConstructed, .staleCoordinatorClosed]
    )
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 1)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: blockedLogicalID, state: "active"),
      0
    )
    for logicalID in supersedingLogicalIDs {
      XCTAssertEqual(
        try latestRecordingStateCount(at: paths, logicalID: logicalID, state: "active"),
        0
      )
    }
  }

  func testMidRuntimeNondurableDeviceObservationsBecomeRecordingGapAfterRetry() async throws {
    let paths = try makePaths()
    let fault = OneShotViewerStoreFault()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { try fault.check() })
    let logicalID = UUID()
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    waitUntil {
      coordinator.services.eventStore.status().logicalQuotaBytes > 0
    }

    let appID = try EndpointID(rawValue: "nondurable-app")
    let viewerID = try EndpointID(rawValue: "nondurable-viewer")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.example.nondurable"
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .viewer,
      installationID: viewerID
    )
    let connectionID = UUID()
    let context = ViewerAdmissionSessionContext(
      connectionID: connectionID,
      appHello: appHello,
      viewerHello: viewerHello,
      negotiation: try WireNegotiator.negotiate(local: appHello, remote: viewerHello),
      receiveChunkBytes: 64 * 1_024
    )
    fault.failNext()
    XCTAssertTrue(coordinator.sessionStarted(context))
    waitUntil { coordinator.services.eventStore.status().state == .writeFailed }

    let envelope = try EventEnvelope(
      id: EventID(),
      type: EventType.user("test.nondurable"),
      content: .object(["value": .integer(1)]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      monotonicTimestampNanoseconds: 3_000,
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
      remainingTTLNanoseconds: 10_000_000_000
    ).receiverEvent(receivedAtNanoseconds: 4_000)
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: logicalID,
      context: context,
      nickname: nil,
      envelope: received.envelope,
      viewerWallMilliseconds: 1_700_000_000_000,
      viewerMonotonicNanoseconds: received.receivedAtNanoseconds,
      deterministicEventBytes: received.deterministicEncodedByteCount,
      initialDisposition: .buffered
    )
    coordinator.eventCommitted(observation) { _ in }
    XCTAssertTrue(
      coordinator.sessionEnded(
        connectionID: connectionID,
        wallMilliseconds: 2_000,
        monotonicNanoseconds: 5_000
      )
    )
    XCTAssertTrue(coordinator.retryStorage())
    waitUntil {
      coordinator.services.eventStore.status().state == .available
        && ((try? self.sumStorageUnavailableGaps(at: paths)) ?? 0) == 2
    }
    XCTAssertEqual(try sumStorageUnavailableGaps(at: paths), 2)

    await coordinator.runtimeEnded(wallMilliseconds: 3_000, monotonicNanoseconds: 6_000)
  }

  func testSameCoordinatorRecoveryDoesNotDuplicateDurableLiveDevices() async throws {
    let paths = try makePaths()
    let fault = OneShotViewerStoreFault()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { try fault.check() })
    let logicalID = UUID()
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    let durable = try makeAdmissionContext(suffix: "durable")
    let initiallyNondurable = try makeAdmissionContext(suffix: "retry")
    XCTAssertTrue(coordinator.sessionStarted(durable))
    waitUntil {
      (try? self.scalar(
        "SELECT COUNT(*) FROM DeviceSessions",
        at: paths
      )) == 1
    }

    fault.failNext()
    XCTAssertTrue(coordinator.sessionStarted(initiallyNondurable))
    waitUntil { coordinator.services.eventStore.status().state == .writeFailed }
    XCTAssertTrue(coordinator.retryStorage())
    XCTAssertTrue(
      coordinator.recoverRuntime(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000,
        missedObservationCount: 1
      )
    )
    for _ in 0..<2 {
      XCTAssertTrue(coordinator.recoverSession(durable))
      XCTAssertTrue(coordinator.recoverSession(initiallyNondurable))
    }
    waitUntil {
      coordinator.services.eventStore.status().state == .available
        && ((try? self.scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths)) == 2)
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 2)

    await coordinator.runtimeEnded(wallMilliseconds: 3_000, monotonicNanoseconds: 4_000)
    coordinator.closeStorage()
    let verification = try ViewerSQLitePool(migrating: paths)
    defer { verification.close() }
    let counts = try verification.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM DeviceSessions", database: database),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM DeviceSessionVersions WHERE state='closed'",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM DeviceSessionVersions WHERE state='active'",
          database: database
        )
      )
    }
    XCTAssertEqual(counts.0, 2)
    XCTAssertEqual(counts.1, 2)
    XCTAssertEqual(counts.2, 2)
    XCTAssertEqual(
      try verification.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM DeviceSessionVersions v WHERE v.state='closed' AND v.rowID=(SELECT MAX(v2.rowID) FROM DeviceSessionVersions v2 WHERE v2.deviceSessionID=v.deviceSessionID)",
          database: $0
        )
      },
      2
    )
    verification.close()
  }

  func testMaintenanceOwnerRunsAtThresholdAndPeriodicWakeCanBeCancelled() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let scheduler = ManualViewerStoreScheduler()
    let statusSignal = ViewerStoreStatusSignal()
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      statusSignal: statusSignal
    )
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: scheduler.value
    )

    let thresholdRun = expectation(description: "Threshold maintenance")
    thresholdRun.assertForOverFulfill = false
    statusSignal.setHandler { _ in thresholdRun.fulfill() }
    owner.noteCommittedBytes(8 * 1_024 * 1_024, wallMilliseconds: 1_000)
    wait(for: [thresholdRun], timeout: 2)

    let sleepScheduled = expectation(description: "Periodic sleep scheduled")
    sleepScheduled.assertForOverFulfill = false
    scheduler.onSleep { sleepScheduled.fulfill() }
    owner.runtimeStarted()
    wait(for: [sleepScheduled], timeout: 2)

    let periodicRun = expectation(description: "Periodic maintenance")
    periodicRun.assertForOverFulfill = false
    statusSignal.setHandler { _ in periodicRun.fulfill() }
    scheduler.advance(by: 15 * 60 * 1_000_000_000)
    wait(for: [periodicRun], timeout: 2)

    let cancelledRun = expectation(description: "Cancelled periodic maintenance")
    cancelledRun.isInverted = true
    cancelledRun.assertForOverFulfill = false
    statusSignal.setHandler { _ in cancelledRun.fulfill() }
    owner.runtimeEnded()
    scheduler.advance(by: 15 * 60 * 1_000_000_000)
    wait(for: [cancelledRun], timeout: 0.2)
    statusSignal.setHandler { _ in }
  }

  func testLatestOnlyChangeSignalCarriesSafeRecordingAndUpperRowSnapshot() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let signal = ViewerStoreStatusSignal()
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      statusSignal: signal
    )
    let observed = LockedViewerStoreChange()
    let committed = expectation(description: "Event commit notification")
    committed.assertForOverFulfill = false
    signal.setHandler { snapshot in
      observed.set(snapshot)
      if snapshot.eventUpperRowID >= 1 { committed.fulfill() }
    }
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "change-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "secret")
    )
    wait(for: [committed], timeout: 2)
    let snapshot = try XCTUnwrap(observed.value)
    XCTAssertEqual(snapshot.changedRecordingIDs, [recording.rowID])
    XCTAssertEqual(snapshot.eventUpperRowID, 1)
    XCTAssertEqual(snapshot.status.state, .available)
    let forbiddenDiagnostics = [
      "secret", String(recording.rowID), String(snapshot.eventUpperRowID),
    ]
    let diagnostics = [
      String(describing: snapshot),
      snapshot.debugDescription,
      String(reflecting: snapshot),
      "\(snapshot)",
    ]
    for diagnostic in diagnostics {
      for forbidden in forbiddenDiagnostics {
        XCTAssertFalse(diagnostic.contains(forbidden))
      }
    }
    XCTAssertTrue(Mirror(reflecting: snapshot).children.isEmpty)
  }

  func testChangeSignalCoalescesSnapshotProviderBeforeWorkAndJoinsDeactivation() {
    let status = ViewerStoreStatus(
      state: .available,
      capacityBytes: 1,
      logicalQuotaBytes: 0,
      allocatedFootprintBytes: 0,
      oldestHistoryMilliseconds: nil,
      pinnedQuotaBytes: 0,
      estimatedRetainedDurationMilliseconds: nil,
      lastCleanupCategory: .none
    )
    let signal = ViewerStoreStatusSignal()
    let providerCount = LockedCounter()
    let deliveryCount = LockedCounter()
    let firstProviderEntered = DispatchSemaphore(value: 0)
    let firstProviderRelease = DispatchSemaphore(value: 0)
    let delivered = expectation(description: "One provider plus one dirty successor delivered")
    delivered.expectedFulfillmentCount = 2
    signal.setSnapshotProvider {
      providerCount.increment()
      if providerCount.value == 1 {
        firstProviderEntered.signal()
        firstProviderRelease.wait()
      }
      return ViewerStoreChangeSnapshot(
        changedRecordingIDs: [],
        eventUpperRowID: Int64(providerCount.value),
        status: status
      )
    }
    signal.setHandler { snapshot in
      XCTAssertLessThanOrEqual(snapshot.changedRecordingIDs.count, 32)
      deliveryCount.increment()
      delivered.fulfill()
    }

    signal.publish(changedRecordingIDs: [1])
    XCTAssertEqual(firstProviderEntered.wait(timeout: .now() + 1), .success)
    for value in 0..<100_000 {
      signal.publish(changedRecordingIDs: [Int64(value)])
    }
    XCTAssertEqual(providerCount.value, 1)
    XCTAssertTrue(signal.hasScheduledWorkForTesting)
    XCTAssertEqual(signal.pendingChangedRecordingIDCountForTesting, 32)
    firstProviderRelease.signal()
    wait(for: [delivered], timeout: 2)
    XCTAssertEqual(providerCount.value, 2)
    XCTAssertEqual(deliveryCount.value, 2)
    signal.deactivateAndWait()
    XCTAssertFalse(signal.hasScheduledWorkForTesting)

    let cleanupSignal = ViewerStoreStatusSignal()
    let cleanupProviderEntered = DispatchSemaphore(value: 0)
    let cleanupProviderRelease = DispatchSemaphore(value: 0)
    let cleanupReturned = DispatchSemaphore(value: 0)
    let cleanupDeliveries = LockedCounter()
    cleanupSignal.setSnapshotProvider {
      cleanupProviderEntered.signal()
      cleanupProviderRelease.wait()
      return ViewerStoreChangeSnapshot(
        changedRecordingIDs: [],
        eventUpperRowID: 1,
        status: status
      )
    }
    cleanupSignal.setHandler { _ in cleanupDeliveries.increment() }
    cleanupSignal.publish()
    XCTAssertEqual(cleanupProviderEntered.wait(timeout: .now() + 1), .success)
    DispatchQueue.global(qos: .userInitiated).async {
      cleanupSignal.deactivateAndWait()
      cleanupReturned.signal()
    }
    XCTAssertEqual(cleanupReturned.wait(timeout: .now() + 0.05), .timedOut)
    cleanupProviderRelease.signal()
    XCTAssertEqual(cleanupReturned.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(cleanupDeliveries.value, 0)
    XCTAssertFalse(cleanupSignal.hasScheduledWorkForTesting)
  }

  func testConcurrentRuntimeEndPathsJoinBlockedStatusProviderBeforeStorageClose() throws {
    let coordinator = try ViewerStoreCoordinator(paths: makePaths())
    let signal = coordinator.services.statusSignal
    let providerEntered = DispatchSemaphore(value: 0)
    let providerRelease = DispatchSemaphore(value: 0)
    let runtimeEndStarted = DispatchSemaphore(value: 0)
    let runtimeEndReturned = DispatchSemaphore(value: 0)
    let deliveries = LockedCounter()
    signal.setSnapshotProvider {
      providerEntered.signal()
      providerRelease.wait()
      return coordinator.services.eventStore.currentChangeSnapshot()
    }
    signal.setHandler { _ in deliveries.increment() }
    signal.publish()
    XCTAssertEqual(providerEntered.wait(timeout: .now() + 1), .success)

    for offset in 0..<2 {
      Task {
        runtimeEndStarted.signal()
        await coordinator.runtimeEnded(
          wallMilliseconds: Int64(10 + offset),
          monotonicNanoseconds: UInt64(20 + offset)
        )
        runtimeEndReturned.signal()
      }
    }
    XCTAssertEqual(runtimeEndStarted.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(runtimeEndStarted.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(runtimeEndReturned.wait(timeout: .now() + 0.05), .timedOut)

    providerRelease.signal()
    XCTAssertEqual(runtimeEndReturned.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(runtimeEndReturned.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(deliveries.value, 0)
    XCTAssertFalse(signal.hasScheduledWorkForTesting)
    signal.publish(changedRecordingIDs: [1])
    XCTAssertFalse(signal.hasScheduledWorkForTesting)

    coordinator.closeStorage()
  }

  func testExportUsesAliasesAndDisclosureWithoutRawInstallationIdentifier() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "raw-installation-must-not-export",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: nil
    )
    let correlationID = EventID()
    let replyTo = EventID()
    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "exported",
        causality: EventCausality(correlationID: correlationID, replyTo: replyTo)
      )
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "testGap",
        count: 2,
        firstWallMilliseconds: 1_100,
        lastWallMilliseconds: 1_100,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 2
      )
    )
    let leases = ViewerStoreLeaseRegistry()
    let maintenance = ViewerStoreMaintenance(
      pool: pool, leases: leases, configuration: { .default })
    _ = try maintenance.appendAnnotation(
      recordingID: recording.rowID,
      body: "annotation",
      wallMilliseconds: 1_200
    )
    let exporter = ViewerStoreExportService(pool: pool, leases: leases)
    let destination = paths.directory.appendingPathComponent("out.json")
    try Data("old-destination".utf8).write(to: destination)
    let preflight = try exporter.preflight(recordingID: recording.rowID)
    XCTAssertEqual(preflight.eventCount, 1)
    XCTAssertTrue(preflight.disclosure.unencrypted)
    try exporter.export(recordingID: recording.rowID, to: destination)
    let data = try Data(contentsOf: destination)
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(text.contains("device-1"))
    XCTAssertTrue(text.contains("connection-1"))
    XCTAssertTrue(text.contains("aliasesArePseudonymsNotRedaction"))
    XCTAssertFalse(text.contains("raw-installation-must-not-export"))
    XCTAssertFalse(text.contains("sessionEpoch"))
    XCTAssertFalse(text.contains("pairingCode"))
    XCTAssertFalse(text.contains("certificate"))
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertEqual(
      Set(root.keys),
      Set([
        "schemaVersion", "scope", "disclosure", "session", "devices", "events", "gaps",
        "annotations",
      ])
    )
    XCTAssertEqual(root["scope"] as? String, "completeSession")
    XCTAssertEqual((root["events"] as? [[String: Any]])?.count, 1)
    let exportedCausality =
      (root["events"] as? [[String: Any]])?.first?["causality"]
      as? [String: String]
    XCTAssertEqual(exportedCausality?["correlationID"], correlationID.rawValue)
    XCTAssertEqual(exportedCausality?["replyTo"], replyTo.rawValue)
    XCTAssertEqual((root["gaps"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual((root["annotations"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual(try permissions(destination), 0o600)
  }

  func testExportCommitBoundaryPreservesDestinationAcrossInjectedFailuresAndCancellation() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "export")
    )
    let leases = ViewerStoreLeaseRegistry()
    let destination = paths.directory.appendingPathComponent("atomic-export.json")
    let old = Data("old-destination".utf8)
    let precommitPhases: [ViewerExportFilePhase] = [
      .temporaryCreated,
      .beforeOpen,
      .beforeWrite,
      .afterWrite,
      .beforeFileSync,
      .afterFileSync,
      .beforeClose,
      .afterClose,
      .beforeCommitSeal,
      .beforeDirectoryOpen,
      .beforeRename,
    ]

    for phase in precommitPhases {
      try old.write(to: destination)
      let exporter = ViewerStoreExportService(
        pool: pool,
        leases: leases,
        filePhases: ViewerExportFilePhaseObserver { reached in
          if reached == phase { throw ViewerStoreError.invalidPath }
        }
      )
      XCTAssertThrowsError(
        try exporter.export(recordingID: recording.rowID, to: destination),
        "Expected injected failure at \(phase)."
      ) { error in
        XCTAssertEqual(error as? ViewerStoreError, .invalidPath)
      }
      XCTAssertEqual(try Data(contentsOf: destination), old)
    }

    let cancellationBox = ViewerExportCancellationBox()
    try old.write(to: destination)
    let cancelledExporter = ViewerStoreExportService(
      pool: pool,
      leases: leases,
      filePhases: ViewerExportFilePhaseObserver { phase in
        if phase == .beforeCommitSeal { cancellationBox.cancel() }
      }
    )
    cancellationBox.exporter = cancelledExporter
    XCTAssertThrowsError(
      try cancelledExporter.export(recordingID: recording.rowID, to: destination)
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
    XCTAssertEqual(try Data(contentsOf: destination), old)

    for phase in [ViewerExportFilePhase.afterRename, .directorySync] {
      try old.write(to: destination)
      let committedExporter = ViewerStoreExportService(
        pool: pool,
        leases: leases,
        filePhases: ViewerExportFilePhaseObserver { reached in
          if reached == phase { throw ViewerStoreError.invalidPath }
        }
      )
      try committedExporter.export(recordingID: recording.rowID, to: destination)
      XCTAssertNotEqual(try Data(contentsOf: destination), old)
    }

    try old.write(to: destination)
    let duringCommitBox = ViewerExportCancellationBox()
    let commitExporter = ViewerStoreExportService(
      pool: pool,
      leases: leases,
      filePhases: ViewerExportFilePhaseObserver { phase in
        if phase == .beforeRename { duringCommitBox.cancel() }
      }
    )
    duringCommitBox.exporter = commitExporter
    try commitExporter.export(recordingID: recording.rowID, to: destination)
    XCTAssertNotEqual(try Data(contentsOf: destination), old)
  }

  func testExportRejectsTemporaryLeafHardLinkAndParentSubstitution() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "export")
    )
    let leases = ViewerStoreLeaseRegistry()
    let old = Data("old-destination".utf8)

    for usesHardLink in [false, true] {
      let name = usesHardLink ? "hard-link.json" : "regular-substitution.json"
      let destination = paths.directory.appendingPathComponent(name)
      try old.write(to: destination)
      let unrelated = paths.directory.appendingPathComponent("unrelated-\(name)")
      let unrelatedData = Data("unrelated-marker".utf8)
      try unrelatedData.write(to: unrelated)
      let exporter = ViewerStoreExportService(
        pool: pool,
        leases: leases,
        filePhases: ViewerExportFilePhaseObserver { phase in
          guard phase == .afterWrite else { return }
          let temporary = try FileManager.default.contentsOfDirectory(
            at: paths.directory,
            includingPropertiesForKeys: nil
          ).first {
            $0.lastPathComponent.hasPrefix(".\(name).") && $0.pathExtension == "tmp"
          }
          guard let temporary else { throw ViewerStoreError.invalidPath }
          try FileManager.default.removeItem(at: temporary)
          if usesHardLink {
            guard link(unrelated.path, temporary.path) == 0 else {
              throw ViewerStoreError.invalidPath
            }
          } else {
            guard
              FileManager.default.createFile(
                atPath: temporary.path,
                contents: Data("substitute".utf8)
              )
            else { throw ViewerStoreError.invalidPath }
          }
        }
      )
      XCTAssertThrowsError(
        try exporter.export(recordingID: recording.rowID, to: destination)
      ) { XCTAssertEqual($0 as? ViewerStoreError, .invalidPath) }
      XCTAssertEqual(try Data(contentsOf: destination), old)
      XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedData)
    }

    let parent = paths.directory.appendingPathComponent("export-parent", isDirectory: true)
    let movedParent = paths.directory.appendingPathComponent("moved-parent", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let destination = parent.appendingPathComponent("parent.json")
    try old.write(to: destination)
    let exporter = ViewerStoreExportService(
      pool: pool,
      leases: leases,
      filePhases: ViewerExportFilePhaseObserver { phase in
        guard phase == .beforeRename else { return }
        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try old.write(to: destination)
      }
    )
    XCTAssertThrowsError(
      try exporter.export(recordingID: recording.rowID, to: destination)
    ) { XCTAssertEqual($0 as? ViewerStoreError, .invalidPath) }
    XCTAssertEqual(try Data(contentsOf: destination), old)
  }

  func testFrozenQueryExportExcludesLaterEventsAndRejectsMixedCursor() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "alpha")
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 2, value: "beta")
    )
    let leases = ViewerStoreLeaseRegistry()
    let queryService = ViewerStoreQueryService(pool: pool, leases: leases)
    let alphaQuery = try ViewerEventQuery(
      recordingID: recording.rowID,
      predicates: [.json(path: "$.message", equals: .string("alpha"))]
    )
    let alphaTraversal = try queryService.begin(query: alphaQuery)
    let (alphaPage, refreshedAlphaTraversal) = try queryService.page(
      traversal: alphaTraversal,
      cursor: nil,
      direction: .forward,
      limit: 1
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 3, value: "alpha")
    )
    let betaTraversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [.json(path: "$.message", equals: .string("beta"))]
      )
    )
    XCTAssertThrowsError(
      try queryService.page(
        traversal: betaTraversal,
        cursor: alphaPage.nextCursor,
        direction: .forward,
        limit: 1
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidValue)
    }

    let exporter = ViewerStoreExportService(pool: pool, leases: leases)
    XCTAssertEqual(try exporter.preflight(traversal: refreshedAlphaTraversal).eventCount, 1)
    let destination = paths.directory.appendingPathComponent("query.json")
    try exporter.export(traversal: refreshedAlphaTraversal, to: destination)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    let events = try XCTUnwrap(root["events"] as? [[String: Any]])
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual((events[0]["content"] as? [String: Any])?["message"] as? String, "alpha")
  }

  func testQueryUsesDimensionAndValueOrWithStableBidirectionalKeysets() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1.0"
    )
    let firstID = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "first",
        viewerMonotonicNanoseconds: 10_000
      )
    )
    let secondID = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "second",
        direction: .viewerToApp,
        viewerMonotonicNanoseconds: 10_000
      )
    )
    let thirdID = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 2,
        value: "third",
        viewerMonotonicNanoseconds: 10_000
      )
    )
    let leases = ViewerStoreLeaseRegistry()
    let service = ViewerStoreQueryService(pool: pool, leases: leases)
    let diagnostics = ViewerStoreDiagnosticService(pool: pool, leases: leases)
    let query = try ViewerEventQuery(
      recordingID: recording.rowID,
      predicates: [
        .eventTypeEqualsAny(["test.metric", "test.other"]),
        .applicationIdentifiers(["com.invalid", "com.example.app"]),
        .applicationVersions(["1.0", "2.0"]),
        .directions(["appToViewer", "viewerToApp"]),
        .priorities(["normal", "high"]),
      ]
    )
    let traversal = try service.begin(query: query)
    let (firstPage, secondTraversal) = try service.page(
      traversal: traversal,
      cursor: nil,
      direction: .forward,
      limit: 2
    )
    XCTAssertEqual(firstPage.rows.map(\.rowID), [firstID, secondID])
    let (secondPage, thirdTraversal) = try service.page(
      traversal: secondTraversal,
      cursor: firstPage.nextCursor,
      direction: .forward,
      limit: 2
    )
    XCTAssertEqual(secondPage.rows.map(\.rowID), [thirdID])
    let (previousPage, _) = try service.page(
      traversal: thirdTraversal,
      cursor: secondPage.previousCursor,
      direction: .backward,
      limit: 2
    )
    XCTAssertEqual(previousPage.rows.map(\.rowID), [firstID, secondID])

    let backwardTraversal = try service.begin(query: query)
    let (tailPage, refreshedBackwardTraversal) = try service.page(
      traversal: backwardTraversal,
      cursor: nil,
      direction: .backward,
      limit: 2
    )
    XCTAssertEqual(tailPage.rows.map(\.rowID), [secondID, thirdID])
    XCTAssertEqual(tailPage.nextCursor?.direction, .backward)
    XCTAssertEqual(tailPage.nextCursor?.rowID, secondID)
    XCTAssertEqual(tailPage.previousCursor?.direction, .forward)
    XCTAssertEqual(tailPage.previousCursor?.rowID, thirdID)

    let (_, traversalAfterSiblingGap) = try diagnostics.gapPage(
      traversal: refreshedBackwardTraversal,
      deviceSessionIDs: [],
      cursor: nil,
      direction: .backward,
      limit: 1
    )
    let (_, traversalAfterDetail) = try service.detail(
      traversal: traversalAfterSiblingGap,
      rowID: thirdID
    )
    let (olderPage, finalTraversal) = try service.page(
      traversal: traversalAfterDetail,
      cursor: tailPage.nextCursor,
      direction: .backward,
      limit: 2
    )
    XCTAssertEqual(olderPage.rows.map(\.rowID), [firstID])

    let issuedCursor = try XCTUnwrap(tailPage.nextCursor)
    let futureCursor = ViewerEventCursor(
      recordingID: issuedCursor.recordingID,
      queryFingerprint: issuedCursor.queryFingerprint,
      snapshot: issuedCursor.snapshot,
      leaseID: issuedCursor.leaseID,
      leaseExpiresAt: finalTraversal.lease.expiresAt + .seconds(1),
      direction: issuedCursor.direction,
      viewerMonotonicNanoseconds: issuedCursor.viewerMonotonicNanoseconds,
      rowID: issuedCursor.rowID
    )
    XCTAssertThrowsError(
      try service.page(
        traversal: finalTraversal,
        cursor: futureCursor,
        direction: .backward,
        limit: 2
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidValue)
    }
  }

  func testQueryLeaseExpiresAndCannotBeRefreshed() throws {
    let registry = ViewerStoreLeaseRegistry()
    let start = ContinuousClock.now
    let lease = try registry.acquireQuery(recordingID: 1, now: start)
    XCTAssertThrowsError(try registry.validateQuery(lease, now: start + .seconds(61))) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
    XCTAssertThrowsError(try registry.touchQuery(lease, now: start + .seconds(61))) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
  }

  func testExportLeaseExpiresAtExactAbsoluteBoundary() throws {
    let leases = ViewerStoreLeaseRegistry()
    let now = ContinuousClock.now
    let lease = try leases.acquireExport(recordingID: 1, now: now)
    XCTAssertNoThrow(try leases.validateExport(lease, now: now + .seconds(3_599)))
    XCTAssertThrowsError(try leases.validateExport(lease, now: now + .seconds(3_600))) {
      XCTAssertEqual($0 as? ViewerStoreError, .cancelled)
    }
    XCTAssertNoThrow(try leases.acquireExport(recordingID: 1, now: now + .seconds(3_600)))
  }

  func testSustainedBatchesKeepWALBoundedAndStoreArtifactsSecureThroughClose() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "sustained"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "sustained-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    for batch in 0..<10 {
      let observations = try (0..<100).map { offset in
        try makeObservation(
          recording: recording,
          device: device,
          sequence: UInt64(batch * 100 + offset + 1),
          value: "event-\(batch)-\(offset)"
        )
      }
      XCTAssertEqual(try store.appendEvents(observations).count, 100)
    }
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      1_000
    )
    let walBytes = Int64(
      (try paths.wal.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
    )
    print("NearWire sustained WAL allocated bytes: \(walBytes)")
    XCTAssertGreaterThan(walBytes, 0)
    XCTAssertLessThan(walBytes, 64 * 1_024 * 1_024)
    for url in [paths.database, paths.wal, paths.sharedMemory] {
      XCTAssertEqual(try permissions(url), 0o600)
      XCTAssertTrue(try isRegularFileWithoutFollowingLinks(url))
    }
    pool.close()
    XCTAssertEqual(try permissions(paths.directory), 0o700)
    for url in [
      paths.database, paths.wal, paths.sharedMemory, paths.journal, paths.exportTemporary,
    ]
    where FileManager.default.fileExists(atPath: url.path) {
      XCTAssertEqual(try permissions(url), 0o600)
      XCTAssertTrue(try isRegularFileWithoutFollowingLinks(url))
    }
  }

  func testNearMaximumPayloadUsesBoundedOversizeTransaction() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "maximum-payload"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "maximum-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    let segmentBytes = 64 * 1_024
    let segmentCount = 240
    let payloadBytes = segmentBytes * segmentCount
    let payload = Array(
      repeating: JSONValue.string(String(repeating: "x", count: segmentBytes)),
      count: segmentCount
    )
    let nearMaximumLimits = try EventValidationLimits(
      maximumEncodedContentBytes: 16 * 1_024 * 1_024,
      maximumEncodedModelBytes: 65 * 1_024 * 1_024
    )
    let observation = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "maximum",
      content: .object(["payload": .array(payload)]),
      validationLimits: nearMaximumLimits
    )
    XCTAssertLessThanOrEqual(observation.deterministicEventBytes, 20 * 1_024 * 1_024)
    XCTAssertGreaterThan(observation.deterministicEventBytes, 15 * 1_024 * 1_024)
    XCTAssertGreaterThan(try store.appendEvent(observation), 0)
    let storedContentBytes = try pool.queryReader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64("SELECT length(contentJSON) FROM Events", database: $0)
    }
    XCTAssertGreaterThan(storedContentBytes, Int64(payloadBytes))
    XCTAssertLessThan(storedContentBytes, Int64(payloadBytes + 1_024))
    print("NearWire near-maximum deterministic Event bytes: \(observation.deterministicEventBytes)")
  }

  func testRevisionBoundDeleteHonorsLeaseAndMaintenanceReclaimsSession() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let leases = ViewerStoreLeaseRegistry()
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: leases,
      configuration: { .default }
    )
    let lease = try leases.acquireQuery(recordingID: recording.rowID)
    let blockedConfirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    XCTAssertThrowsError(
      try maintenance.requestDelete(
        blockedConfirmation,
        wallMilliseconds: 3_000
      )
    )
    leases.release(lease)
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    try maintenance.requestDelete(
      confirmation,
      wallMilliseconds: 3_000
    )
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 4_000)
    let count = try pool.queryReader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Recordings", database: $0)
    }
    XCTAssertEqual(count, 0)
  }

  func testCapacityCleanupStartsAboveOneHundredPercentAndTargetsEightyFivePercent() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 3_650
    )
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    for index in 0..<7 {
      let recording = try store.beginRecording(
        wallMilliseconds: Int64(1_000 + index),
        monotonicNanoseconds: UInt64(2_000 + index),
        reason: "test"
      )
      try store.appendStructural(
        .closeRecording(
          recording,
          wallMilliseconds: Int64(3_000 + index),
          monotonicNanoseconds: UInt64(4_000 + index)
        )
      )
    }
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { configuration }
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=57*1024*1024 WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 5_000)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: $0)
      },
      0
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=64*1024*1024 WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 5_000)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: $0)
      },
      0
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=10*1024*1024",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=70*1024*1024 WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 5_000)
    let result = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings WHERE rowID NOT IN (SELECT recordingID FROM Tombstones)",
          database: database
        )
      )
    }
    XCTAssertEqual(result.0, 50 * 1_024 * 1_024)
    XCTAssertEqual(result.1, 5)
  }

  func testCapacityPauseRunsOneRecoveryAndExplicitProbeResumesAfterCapacityIncrease() throws {
    let configuration = LockedStorageConfiguration()
    configuration.set(
      try ViewerStorageConfiguration(capacityBytes: 64 * 1_024 * 1_024, historyRetentionDays: 7)
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { configuration.value! })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=64*1024*1024 WHERE rowID=\(recording.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=64*1024*1024 WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    let recoveryCount = LockedCounter()
    store.setCapacityRecovery { _, _ in recoveryCount.increment() }
    let observation = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "capacity"
    )
    XCTAssertThrowsError(try store.appendEvent(observation)) { error in
      XCTAssertEqual(error as? ViewerStoreError, .capacityExceeded)
    }
    XCTAssertEqual(recoveryCount.value, 1)
    XCTAssertEqual(store.status().state, .capacityPaused)

    configuration.set(
      try ViewerStorageConfiguration(capacityBytes: 128 * 1_024 * 1_024, historyRetentionDays: 7)
    )
    try store.retry()
    XCTAssertNoThrow(try store.appendEvent(observation))
    XCTAssertEqual(store.status().state, .available)
  }

  func testConcurrentMetadataAndEventCapacityAdmissionUsesWriterOrdering() throws {
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 3_650
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { configuration },
      storeStateReporter: { store.writeStateRelay.reportFailure($0) },
      recoveryPermitProvider: { store.writeStateRelay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        store.writeStateRelay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try store.writeStateRelay.validate($0) },
      recoveryValidator: { try store.writeStateRelay.validate($0) },
      recoveryCompleter: { try store.writeStateRelay.completeRecovery($0) }
    )
    store.setCapacityRecovery { pending, permit in
      try maintenance.run(
        trigger: .threshold,
        nowWallMilliseconds: 10_000,
        pendingReservationBytes: pending,
        recoveryPermit: permit
      )
    }
    let target = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "target"
    )
    let device = try store.beginDeviceSession(
      recording: target,
      installationID: "capacity-target",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Target"
    )

    func addEligible(_ suffix: Int) throws -> ViewerRecordingHandle {
      let recording = try store.beginRecording(
        wallMilliseconds: Int64(2_000 + suffix),
        monotonicNanoseconds: UInt64(3_000 + suffix),
        reason: "eligible"
      )
      try store.appendStructural(
        .closeRecording(
          recording,
          wallMilliseconds: Int64(4_000 + suffix),
          monotonicNanoseconds: UInt64(5_000 + suffix)
        )
      )
      try pool.writer.run { database in
        try ViewerSQLiteConnection.execute(
          "UPDATE Recordings SET liveQuotaBytes=4194304 WHERE rowID=\(recording.rowID)",
          on: database
        )
        try ViewerSQLiteConnection.execute(
          "UPDATE StoreMetadata SET integerValue=\(configuration.capacityBytes - 1) WHERE key='logicalQuotaBytes'",
          on: database
        )
      }
      return recording
    }

    func concurrently(
      _ first: @escaping @Sendable () throws -> Void,
      _ second: @escaping @Sendable () throws -> Void
    ) throws {
      let errors = LockedViewerStoreErrors()
      let group = DispatchGroup()
      for operation in [first, second] {
        group.enter()
        DispatchQueue.global().async {
          do { try operation() } catch { errors.append(error as? ViewerStoreError) }
          group.leave()
        }
      }
      XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
      XCTAssertTrue(
        errors.values.allSatisfy {
          $0 == .writeNotAuthorized || $0 == .capacityExceeded
        }
      )
      if store.status().state != .available { try store.retry() }
    }

    _ = try addEligible(1)
    try concurrently(
      {
        _ = try maintenance.appendAnnotation(
          recordingID: target.rowID,
          body: "first",
          wallMilliseconds: 6_001
        )
      },
      {
        _ = try maintenance.appendAnnotation(
          recordingID: target.rowID,
          body: "second",
          wallMilliseconds: 6_002
        )
      }
    )

    _ = try addEligible(2)
    let eventRace = try makeObservation(
      recording: target,
      device: device,
      sequence: 1,
      value: "race"
    )
    try concurrently(
      {
        _ = try maintenance.appendAnnotation(
          recordingID: target.rowID,
          body: "event-race",
          wallMilliseconds: 6_003
        )
      },
      { _ = try store.appendEvent(eventRace) }
    )

    _ = try addEligible(3)
    let metadataRace = try makeObservation(
      recording: target,
      device: device,
      sequence: 2,
      value: "metadata-race"
    )
    try concurrently(
      {
        _ = try maintenance.updateRecording(
          ViewerRecordingRevision(recordingID: target.rowID, revision: 1),
          name: "Updated",
          note: nil,
          pinned: false,
          wallMilliseconds: 6_004
        )
      },
      { _ = try store.appendEvent(metadataRace) }
    )

    XCTAssertEqual(store.status().state, .available)
    let annotationCount = try pool.queryReader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64(
        "SELECT COUNT(*) FROM AnnotationVersions WHERE recordingID=\(target.rowID)",
        database: $0
      )
    }
    XCTAssertGreaterThanOrEqual(annotationCount, 0)
    XCTAssertLessThanOrEqual(annotationCount, 3)

    let protected = try store.beginRecording(
      wallMilliseconds: 7_000,
      monotonicNanoseconds: 8_000,
      reason: "protected"
    )
    try store.appendStructural(
      .closeRecording(protected, wallMilliseconds: 7_100, monotonicNanoseconds: 8_100)
    )
    _ = try maintenance.updateRecording(
      ViewerRecordingRevision(recordingID: protected.rowID, revision: 2),
      name: nil,
      note: nil,
      pinned: true,
      wallMilliseconds: 7_200
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=4194304 WHERE rowID=\(protected.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=\(configuration.capacityBytes) WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    XCTAssertThrowsError(
      try maintenance.appendAnnotation(
        recordingID: target.rowID,
        body: "protected-capacity",
        wallMilliseconds: 7_300
      )
    ) { XCTAssertEqual($0 as? ViewerStoreError, .capacityExceeded) }
    XCTAssertEqual(store.status().state, .capacityPaused)
    pool.close()
  }

  func testProjectedReservationCrossingCapacityReclaimsEligibleHistoryThenAdmits() throws {
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 3_650
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    let old = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "old"
    )
    try store.appendStructural(
      .closeRecording(old, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let active = try store.beginRecording(
      wallMilliseconds: 3_000,
      monotonicNanoseconds: 4_000,
      reason: "active"
    )
    let device = try store.beginDeviceSession(
      recording: active,
      installationID: "active-device",
      wallMilliseconds: 3_000,
      monotonicNanoseconds: 4_000,
      partialHistory: false,
      displayName: "Active"
    )
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=10*1024*1024 WHERE rowID=\(old.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=54*1024*1024-512 WHERE rowID=\(active.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=64*1024*1024-512 WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { configuration },
      activeRecordingIDs: { [active.rowID] }
    )
    store.setCapacityRecovery { pending, permit in
      try maintenance.run(
        trigger: .threshold,
        nowWallMilliseconds: 5_000,
        pendingReservationBytes: pending,
        recoveryPermit: permit
      )
    }
    _ = try store.appendEvent(
      makeObservation(recording: active, device: device, sequence: 1, value: "crossing")
    )
    let state = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings WHERE rowID=\(old.rowID) AND rowID NOT IN (SELECT recordingID FROM Tombstones)",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: database)
      )
    }
    XCTAssertEqual(state.0, 0)
    XCTAssertEqual(state.1, 1)
    XCTAssertEqual(store.status().state, .available)
    store.setCapacityRecovery { _, _ in }
    pool.close()
  }

  func testWholeTransactionPlanIncludesInitialDispositionAndDuplicateIsZeroQuota() throws {
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 3_650
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    let old = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "old"
    )
    try store.appendStructural(
      .closeRecording(old, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let active = try store.beginRecording(
      wallMilliseconds: 3_000,
      monotonicNanoseconds: 4_000,
      reason: "active"
    )
    let device = try store.beginDeviceSession(
      recording: active,
      installationID: "active-device",
      wallMilliseconds: 3_000,
      monotonicNanoseconds: 4_000,
      partialHistory: false,
      displayName: "Active"
    )
    let observation = try makeObservation(
      recording: active,
      device: device,
      sequence: 1,
      value: "whole-transaction"
    )
    let oldQuota = Int64(10 * 1_024 * 1_024)
    let currentQuota = configuration.capacityBytes - observation.quotaBytes
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=\(oldQuota) WHERE rowID=\(old.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=\(currentQuota - oldQuota) WHERE rowID=\(active.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=\(currentQuota) WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { configuration },
      activeRecordingIDs: { [active.rowID] }
    )
    store.setCapacityRecovery { pending, permit in
      try maintenance.run(
        trigger: .threshold,
        nowWallMilliseconds: 5_000,
        pendingReservationBytes: pending,
        recoveryPermit: permit
      )
    }

    let eventID = try store.appendEvent(observation)
    XCTAssertGreaterThan(eventID, 0)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM Recordings WHERE rowID=\(old.rowID)",
          database: $0
        )
      },
      0
    )

    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=\(configuration.capacityBytes) WHERE rowID=\(active.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=\(configuration.capacityBytes) WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    XCTAssertEqual(try store.appendEvent(observation), eventID)
    XCTAssertEqual(store.status().state, .available)
  }

  func testIngressRetainsFailedPrefixUntilExplicitRetry() async throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let fault = OneShotViewerStoreFault()
    let signal = ViewerStoreStatusSignal()
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      writeGate: { try fault.check() },
      statusSignal: signal
    )
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    let ingress = ViewerStoreIngress(store: store)
    let failed = expectation(description: "Write failed")
    failed.assertForOverFulfill = false
    signal.setHandler { _ in
      if store.status().state == .writeFailed { failed.fulfill() }
    }
    fault.failNext()
    XCTAssertEqual(
      ingress.admit(
        try makeObservation(recording: recording, device: device, sequence: 1, value: "one")),
      .admitted
    )
    await fulfillment(of: [failed], timeout: 2)
    let failedFlush = await ingress.flush()
    XCTAssertEqual(failedFlush, .writeFailed)
    XCTAssertEqual(store.status().state, .writeFailed)
    let lifecycleBudget = ViewerJournalPipelineBudget()
    let closeReservation = try XCTUnwrap(
      lifecycleBudget.reserve(bytes: 0, kind: .lifecycle)
    )
    XCTAssertEqual(
      ingress.admit(
        .closeDevice(device, wallMilliseconds: 3_000, monotonicNanoseconds: 4_000),
        reservation: closeReservation
      ),
      .stopped
    )
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      0
    )

    let committed = expectation(description: "Retained prefix committed")
    committed.assertForOverFulfill = false
    signal.setHandler { _ in
      if store.status().state == .available { committed.fulfill() }
    }
    try store.retry()
    await fulfillment(of: [committed], timeout: 2)
    _ = await ingress.flush()
    signal.setHandler { _ in }
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      1
    )
    pool.close()
  }

  func testPhasedReclaimDeletesEveryRecordingOwnedTable() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "App"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "event")
    )
    try store.appendStructural(
      .policy(
        device: device,
        sequence: 1,
        wallMilliseconds: 1_100,
        monotonicNanoseconds: 2_100,
        policyJSON: ViewerCanonicalJSON.encode(ViewerRatePolicy.default)
      )
    )
    try store.appendStructural(
      .drop(
        device: device,
        sequence: 1,
        wallMilliseconds: 1_100,
        monotonicNanoseconds: 2_100,
        reason: "localOverflow",
        count: 1
      )
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "testGap",
        count: 1,
        firstWallMilliseconds: 1_100,
        lastWallMilliseconds: 1_100,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      )
    )
    try store.appendStructural(
      .closeDevice(device, wallMilliseconds: 1_200, monotonicNanoseconds: 2_200)
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 1_300, monotonicNanoseconds: 2_300)
    )
    let leases = ViewerStoreLeaseRegistry()
    let maintenance = ViewerStoreMaintenance(
      pool: pool, leases: leases, configuration: { .default })
    _ = try maintenance.appendAnnotation(
      recordingID: recording.rowID,
      body: "annotation",
      wallMilliseconds: 1_400
    )
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    try maintenance.requestDelete(
      confirmation,
      wallMilliseconds: 1_500
    )
    for _ in 0..<6 {
      try maintenance.run(trigger: .explicit, nowWallMilliseconds: 1_600)
    }
    let remaining = try pool.queryReader.run(budget: .query()) { database in
      try ViewerStoreSchema.scalarInt64(
        "SELECT (SELECT COUNT(*) FROM Recordings)+(SELECT COUNT(*) FROM RecordingVersions)+(SELECT COUNT(*) FROM InstallationAliases)+(SELECT COUNT(*) FROM DeviceSessions)+(SELECT COUNT(*) FROM DeviceSessionVersions)+(SELECT COUNT(*) FROM Events)+(SELECT COUNT(*) FROM EventDispositionVersions)+(SELECT COUNT(*) FROM PolicyVersions)+(SELECT COUNT(*) FROM DropVersions)+(SELECT COUNT(*) FROM GapVersions)+(SELECT COUNT(*) FROM AnnotationVersions)+(SELECT COUNT(*) FROM Tombstones)",
        database: database
      )
    }
    XCTAssertEqual(remaining, 0)
    XCTAssertEqual(store.status().logicalQuotaBytes, 0)
  }

  func testTextBoundsRejectControlsAndAllowMultilineNotes() throws {
    XCTAssertEqual(try ViewerTextRules.recordingName("A name"), "A name")
    XCTAssertThrowsError(try ViewerTextRules.recordingName("line\nbreak"))
    XCTAssertEqual(try ViewerTextRules.noteOrAnnotation("line\n\tnext"), "line\n\tnext")
    XCTAssertThrowsError(try ViewerTextRules.noteOrAnnotation("bad\u{0}value"))
  }

  func testInvalidStructuralObservationsCannotTriggerCapacityCleanup() throws {
    let configuration = try ViewerStorageConfiguration(
      capacityBytes: 64 * 1_024 * 1_024,
      historyRetentionDays: 3_650
    )
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { configuration })
    let eligible = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "eligible"
    )
    try store.appendStructural(
      .closeRecording(eligible, wallMilliseconds: 1_100, monotonicNanoseconds: 2_100)
    )
    let recording = try store.beginRecording(
      wallMilliseconds: 1_200,
      monotonicNanoseconds: 2_200,
      reason: "active"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "invalid-structural",
      wallMilliseconds: 1_200,
      monotonicNanoseconds: 2_200,
      partialHistory: false,
      displayName: "Device"
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { configuration }
    )
    store.setCapacityRecovery { pending, permit in
      try maintenance.run(
        trigger: .threshold,
        nowWallMilliseconds: 2_000,
        pendingReservationBytes: pending,
        recoveryPermit: permit
      )
    }
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "UPDATE Recordings SET liveQuotaBytes=1048576 WHERE rowID=\(eligible.rowID)",
        on: database
      )
      try ViewerSQLiteConnection.execute(
        "UPDATE StoreMetadata SET integerValue=\(configuration.capacityBytes) WHERE key='logicalQuotaBytes'",
        on: database
      )
    }
    let invalid: [ViewerStructuralObservation] = [
      .policy(
        device: device,
        sequence: 1,
        wallMilliseconds: 2_000,
        monotonicNanoseconds: 3_000,
        policyJSON: Data(repeating: 0x61, count: 4_097)
      ),
      .drop(
        device: device,
        sequence: 1,
        wallMilliseconds: 2_000,
        monotonicNanoseconds: 3_000,
        reason: "invalid",
        count: 0
      ),
      .drop(
        device: device,
        sequence: 2,
        wallMilliseconds: 2_000,
        monotonicNanoseconds: 3_000,
        reason: String(repeating: "x", count: 129),
        count: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "invalid",
        count: 0,
        firstWallMilliseconds: 2_000,
        lastWallMilliseconds: 2_000,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 2,
        reason: "invalid",
        count: 1,
        firstWallMilliseconds: 2_000,
        lastWallMilliseconds: 1_999,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 3,
        reason: "invalid",
        count: 1,
        firstWallMilliseconds: 2_000,
        lastWallMilliseconds: 2_000,
        directions: "invalid",
        firstWireSequence: 1,
        lastWireSequence: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 4,
        reason: "invalid",
        count: 1,
        firstWallMilliseconds: 2_000,
        lastWallMilliseconds: 2_000,
        directions: "appToViewer",
        firstWireSequence: 2,
        lastWireSequence: 1
      ),
      .gap(
        recording: recording,
        device: device,
        sequence: 5,
        reason: String(repeating: "x", count: 129),
        count: 1,
        firstWallMilliseconds: 2_000,
        lastWallMilliseconds: 2_000,
        directions: "appToViewer",
        firstWireSequence: nil,
        lastWireSequence: 1
      ),
    ]
    for observation in invalid {
      XCTAssertThrowsError(try store.appendStructural(observation)) {
        XCTAssertEqual($0 as? ViewerStoreError, .invalidValue)
      }
    }
    let result = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: database),
        try ViewerStoreSchema.scalarInt64(
          "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
          database: database
        )
      )
    }
    XCTAssertEqual(result.0, 0)
    XCTAssertEqual(result.1, configuration.capacityBytes)
    pool.close()
  }

  func testPipelineBudgetIsSharedAcrossPreparationAndIngressOwnership() throws {
    let limits = ViewerStoreIngressLimits(maximumCount: 2, maximumBytes: 10)
    let budget = ViewerJournalPipelineBudget(limits: limits)
    var first: ViewerJournalPipelineBudget.Reservation? = budget.reserve(bytes: 6, kind: .event)
    var second: ViewerJournalPipelineBudget.Reservation? = budget.reserve(bytes: 4, kind: .event)
    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertNil(budget.reserve(bytes: 1, kind: .event))
    var snapshot = budget.snapshot()
    XCTAssertEqual(snapshot.eventCount, 2)
    XCTAssertEqual(snapshot.eventBytes, 10)
    first = nil
    XCTAssertNotNil(budget.reserve(bytes: 6, kind: .event))
    second = nil

    var structural: [ViewerJournalPipelineBudget.Reservation] = []
    for _ in 0..<18 {
      structural.append(try XCTUnwrap(budget.reserve(bytes: 0, kind: .structural)))
    }
    XCTAssertNil(budget.reserve(bytes: 0, kind: .structural))
    var lifecycle: [ViewerJournalPipelineBudget.Reservation] = []
    for _ in 0..<18 {
      lifecycle.append(try XCTUnwrap(budget.reserve(bytes: 0, kind: .lifecycle)))
    }
    XCTAssertNil(budget.reserve(bytes: 0, kind: .lifecycle))
    snapshot = budget.snapshot()
    XCTAssertEqual(snapshot.structuralCount, 36)
    structural.removeAll()
    XCTAssertEqual(budget.snapshot().structuralCount, 18)
    lifecycle.removeAll()
    XCTAssertEqual(budget.snapshot().structuralCount, 0)
  }

  func testMissingInitialTransitionBecomesIdempotentGapWithoutPoisoningWriter() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "installation",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1"
    )
    let transition = ViewerStructuralObservation.disposition(
      recording: recording,
      device: device,
      direction: .appToViewer,
      wireSequence: 7,
      value: .expired,
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100
    )
    try store.appendStructural(transition)
    try store.appendStructural(
      .disposition(
        recording: recording,
        device: device,
        direction: .appToViewer,
        wireSequence: 7,
        value: .expired,
        wallMilliseconds: 1_200,
        monotonicNanoseconds: 2_200
      )
    )
    XCTAssertThrowsError(
      try store.appendStructural(
        .disposition(
          recording: recording,
          device: device,
          direction: .appToViewer,
          wireSequence: 7,
          value: .consumerAccepted,
          wallMilliseconds: 1_100,
          monotonicNanoseconds: 2_100
        )
      )
    )
    try store.retry()
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 8, value: "ok"))
    let values = try pool.queryReader.run(budget: .query()) { database in
      (
        try ViewerStoreSchema.scalarInt64(
          "SELECT COUNT(*) FROM GapVersions WHERE namespace='transition' AND reason='missingInitialEvent.expired'",
          database: database
        ),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: database)
      )
    }
    XCTAssertEqual(values.0, 1)
    XCTAssertEqual(values.1, 1)
    XCTAssertEqual(store.status().state, .available)
  }

  func testDeleteConfirmationIsSingleUseAndInvalidatedByAnnotation() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    let target = ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    let stale = try maintenance.prepareDelete(target)
    _ = try maintenance.appendAnnotation(
      recordingID: recording.rowID,
      body: "changed after confirmation",
      wallMilliseconds: 2_100
    )
    XCTAssertThrowsError(try maintenance.requestDelete(stale, wallMilliseconds: 2_200))
    XCTAssertThrowsError(try maintenance.requestDelete(stale, wallMilliseconds: 2_300))
    let current = try maintenance.prepareDelete(target)
    try maintenance.requestDelete(current, wallMilliseconds: 2_400)
    XCTAssertThrowsError(try maintenance.requestDelete(current, wallMilliseconds: 2_500))
  }

  func testQueryUsesViewerTimeTypedJSONScalarOrAndFrozenTerminalPresence() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "installation",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1"
    )
    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: "integer",
        initialDisposition: .buffered,
        viewerWallMilliseconds: 5_000,
        content: .object(["message": .integer(42), "kind": .integer(1)])
      )
    )
    _ = try store.appendEvent(
      makeObservation(
        recording: recording,
        device: device,
        sequence: 2,
        value: "string",
        viewerWallMilliseconds: 6_000,
        content: .object(["message": .string("42"), "kind": .bool(true)])
      )
    )
    let leases = ViewerStoreLeaseRegistry()
    let queryService = ViewerStoreQueryService(pool: pool, leases: leases)

    var traversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [
          .wallTime(from: 4_000, through: 6_000),
          .jsonStringContains(path: "$.message", value: "42"),
        ]
      )
    )
    var page = try queryService.page(traversal: traversal, cursor: nil, direction: .forward).0
    XCTAssertEqual(page.rows.map(\.wireSequence), [2])
    queryService.end(traversal)

    traversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [.jsonAny(path: "$.message", equalsAny: [.integer(42), .string("no")])]
      )
    )
    page = try queryService.page(traversal: traversal, cursor: nil, direction: .forward).0
    XCTAssertEqual(page.rows.map(\.wireSequence), [1])
    queryService.end(traversal)

    traversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [.json(path: "$.kind", equals: .integer(1))]
      )
    )
    page = try queryService.page(traversal: traversal, cursor: nil, direction: .forward).0
    XCTAssertEqual(page.rows.map(\.wireSequence), [1])
    queryService.end(traversal)

    traversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [.json(path: "$.kind", equals: .boolean(true))]
      )
    )
    page = try queryService.page(traversal: traversal, cursor: nil, direction: .forward).0
    XCTAssertEqual(page.rows.map(\.wireSequence), [2])
    queryService.end(traversal)

    traversal = try queryService.begin(
      query: ViewerEventQuery(
        recordingID: recording.rowID,
        predicates: [.hasTerminalDisposition]
      )
    )
    try store.appendStructural(
      .disposition(
        recording: recording,
        device: device,
        direction: .appToViewer,
        wireSequence: 1,
        value: .expired,
        wallMilliseconds: 7_000,
        monotonicNanoseconds: 8_000
      )
    )
    page = try queryService.page(traversal: traversal, cursor: nil, direction: .forward).0
    XCTAssertEqual(page.rows.map(\.wireSequence), [2])
    XCTAssertEqual(page.rows.first?.resolvedDisposition, "consumerAccepted")
    XCTAssertEqual(page.rows.first?.recordingRevision, 1)
    XCTAssertEqual(page.rows.first?.deviceRevision, 1)
    queryService.end(traversal)
  }

  func testLiveEvaluatorMatchesSQLiteForSharedPredicatesAndExplicitlyExcludesFTS() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "differential"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "app-app",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Differential App",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1.0"
    )
    let first = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "alpha",
      initialDisposition: .consumerAccepted,
      viewerWallMilliseconds: 5_000,
      content: .object([
        "items": .array([.object(["value": .integer(42)])]),
        "message": .string("alpha searchable"),
      ])
    )
    let second = try makeObservation(
      recording: recording,
      device: device,
      sequence: 2,
      value: "beta",
      initialDisposition: .buffered,
      viewerWallMilliseconds: 6_000,
      content: .object([
        "items": .array([.object(["value": .integer(7)])]),
        "message": .string("e\u{301}"),
      ])
    )
    _ = try store.appendEvent(first)
    _ = try store.appendEvent(second)
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "differentialGap",
        count: 1,
        firstWallMilliseconds: 5_000,
        lastWallMilliseconds: 6_000,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 2
      )
    )
    try store.appendStructural(
      .drop(
        device: device,
        sequence: 1,
        wallMilliseconds: 6_000,
        monotonicNanoseconds: 7_000,
        reason: ViewerDropJournalSample.Reason.localOverflow.rawValue,
        count: 1
      )
    )

    let context = try makeAdmissionContext(suffix: "app", applicationVersion: "1.0")
    let metadata = try ViewerFrozenSessionMetadata(context: context, nickname: "Differential")
    let runtimeLogicalID = UUID()
    let liveFirst = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: context.connectionID,
      session: metadata,
      envelope: first.envelope,
      viewerWallMilliseconds: first.viewerWallMilliseconds,
      viewerMonotonicNanoseconds: first.viewerMonotonicNanoseconds,
      deterministicEventBytes: first.deterministicEventBytes,
      initialDisposition: first.initialDisposition
    )
    let liveSecond = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: context.connectionID,
      session: metadata,
      envelope: second.envelope,
      viewerWallMilliseconds: second.viewerWallMilliseconds,
      viewerMonotonicNanoseconds: second.viewerMonotonicNanoseconds,
      deterministicEventBytes: second.deterministicEventBytes,
      initialDisposition: second.initialDisposition
    )
    let liveSnapshot = ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 1,
      events: [
        ViewerLiveEventSnapshot(
          observation: liveFirst,
          laterDisposition: nil,
          durableState: .notRecorded,
          hasPresentationConflict: false,
          hasGap: true,
          hasDrop: true,
          sessionEnded: false
        ),
        ViewerLiveEventSnapshot(
          observation: liveSecond,
          laterDisposition: nil,
          durableState: .notRecorded,
          hasPresentationConflict: false,
          hasGap: true,
          hasDrop: true,
          sessionEnded: false
        ),
      ],
      sessions: [
        ViewerLiveSessionSnapshot(
          connectionID: context.connectionID,
          metadata: metadata,
          positiveDropCount: 1,
          endedWallMilliseconds: nil,
          endedMonotonicNanoseconds: nil
        )
      ],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 0,
        residentConflictCount: 0,
        diagnosticLossCount: 0,
        storeUnavailableCount: 0,
        storeRecoveryCount: 0,
        storeUnavailable: false
      ),
      accountedEventBytes: [liveFirst, liveSecond].reduce(0) {
        $0 + $1.deterministicEventBytes + ViewerLiveProjectionLimits.fixedEntryOverheadBytes
      }
    )
    let queryService = ViewerStoreQueryService(pool: pool, leases: ViewerStoreLeaseRegistry())
    let evaluator = ViewerLiveEventEvaluator(nowNanoseconds: { 0 })

    func durableSequences(_ predicates: [ViewerEventPredicate]) throws -> [UInt64] {
      let traversal = try queryService.begin(
        query: ViewerEventQuery(recordingID: recording.rowID, predicates: predicates)
      )
      defer { queryService.end(traversal) }
      return try queryService.page(
        traversal: traversal,
        cursor: nil,
        direction: .forward,
        limit: 100
      ).0.rows.map { UInt64($0.wireSequence) }
    }

    func liveSequences(_ predicates: [ViewerEventPredicate]) throws -> [UInt64] {
      let request = try ViewerLiveEvaluationRequest(
        runtimeLogicalID: runtimeLogicalID,
        predicates: predicates
      )
      guard
        case .complete(let output) = evaluator.evaluate(
          snapshot: liveSnapshot,
          request: request
        )
      else { throw ViewerStoreError.workLimitExceeded }
      XCTAssertNil(output.transientExclusion)
      return output.matchedKeys.map(\.wireSequence)
    }

    let sharedCases: [[ViewerEventPredicate]] = [
      [.eventTypeEquals("test.metric")],
      [.eventTypePrefix("test.")],
      [.contentContains("alpha")],
      [
        .applicationIdentifiers(["com.example.app"]),
        .applicationVersions(["1.0"]),
        .direction("appToViewer"),
        .priority("normal"),
        .wallTime(from: 5_000, through: 5_000),
      ],
      [.json(path: "$.items[0].value", equals: .integer(42))],
      [.jsonAny(path: "$.items[0].value", equalsAny: [.integer(7), .integer(42)])],
      [.jsonExists(path: "$.items[0].value")],
      [.jsonStringContains(path: "$.message", value: "alpha")],
      [.json(path: "$.message", equals: .string("é"))],
      [.jsonStringContains(path: "$.message", value: "é")],
      [.hasGap],
      [.hasDrop],
      [.hasTerminalDisposition],
    ]
    for predicates in sharedCases {
      XCTAssertEqual(try liveSequences(predicates), try durableSequences(predicates))
    }

    XCTAssertEqual(try durableSequences([.fullText("alpha")]), [1])
    let fullTextRequest = try ViewerLiveEvaluationRequest(
      runtimeLogicalID: runtimeLogicalID,
      predicates: [.fullText("alpha")]
    )
    guard
      case .complete(let fullTextOutput) = evaluator.evaluate(
        snapshot: liveSnapshot,
        request: fullTextRequest
      )
    else { return XCTFail("Expected explicit durable-only FTS result") }
    XCTAssertTrue(fullTextOutput.matchedKeys.isEmpty)
    XCTAssertEqual(fullTextOutput.transientExclusion, .fullTextRequiresRecordedData)
  }

  func testGapAggregateVersionsAreAppendOnlyAndFrozenExportUsesCapturedVersion() throws {
    let root = try makeTemporaryDirectory()
    let paths = ViewerStorePaths(
      directory: root.appendingPathComponent("Store", isDirectory: true),
      database: root.appendingPathComponent("Store/NearWire.sqlite")
    )
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "installation",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "one"))
    let first = ViewerStructuralObservation.gap(
      recording: recording,
      device: device,
      sequence: 1,
      reason: "storeIngressFull",
      count: 2,
      firstWallMilliseconds: 1_100,
      lastWallMilliseconds: 1_200,
      directions: "appToViewer",
      firstWireSequence: 1,
      lastWireSequence: 2
    )
    try store.appendStructural(first)
    try store.appendStructural(first)
    let leases = ViewerStoreLeaseRegistry()
    let queryService = ViewerStoreQueryService(pool: pool, leases: leases)
    let traversal = try queryService.begin(
      query: ViewerEventQuery(recordingID: recording.rowID, predicates: [])
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "storeIngressFull",
        count: 3,
        firstWallMilliseconds: 1_100,
        lastWallMilliseconds: 1_300,
        directions: "both",
        firstWireSequence: 1,
        lastWireSequence: 3
      )
    )
    let destination = root.appendingPathComponent("frozen.json")
    try ViewerStoreExportService(pool: pool, leases: leases).export(
      traversal: traversal,
      to: destination
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    let gaps = try XCTUnwrap(object["gaps"] as? [[String: Any]])
    XCTAssertEqual(gaps.count, 1)
    XCTAssertEqual(gaps[0]["count"] as? Int, 2)
    XCTAssertEqual(gaps[0]["lastViewerTimeMilliseconds"] as? Int, 1_200)
    let versions = try pool.queryReader.run(budget: .query()) { database in
      try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM GapVersions", database: database)
    }
    XCTAssertEqual(versions, 2)
    queryService.end(traversal)
  }

  func testDiskGuardFailsClosedBeforeBootstrapAndEveryMutationCategory() throws {
    let blockedPaths = try makePaths()
    let missing = ViewerStoreDiskGuard { _ in nil }
    XCTAssertThrowsError(try ViewerSQLitePool(migrating: blockedPaths, diskGuard: missing)) {
      XCTAssertEqual($0 as? ViewerStoreError, .capacityExceeded)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: blockedPaths.database.path))

    let capacity = LockedCapacity(Int64.max)
    let guardWithSeam = ViewerStoreDiskGuard { _ in capacity.value }
    let pool = try ViewerSQLitePool(migrating: makePaths(), diskGuard: guardWithSeam)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "installation",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device",
      applicationIdentifier: "com.example.app",
      applicationVersion: "1"
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    capacity.value = nil
    XCTAssertThrowsError(
      try store.appendEvent(
        makeObservation(recording: recording, device: device, sequence: 1, value: "blocked"))
    )
    XCTAssertThrowsError(
      try maintenance.updateRecording(
        ViewerRecordingRevision(recordingID: recording.rowID, revision: 2),
        name: "blocked",
        note: nil,
        pinned: false,
        wallMilliseconds: 2_100
      )
    )
    XCTAssertThrowsError(
      try maintenance.appendAnnotation(
        recordingID: recording.rowID,
        body: "blocked",
        wallMilliseconds: 2_100
      )
    )
    XCTAssertThrowsError(try maintenance.requestDelete(confirmation, wallMilliseconds: 2_200))
    let counts = try pool.queryReader.run(budget: .query()) { database in
      try ViewerStoreSchema.scalarInt64(
        "SELECT (SELECT COUNT(*) FROM Events)+(SELECT COUNT(*) FROM AnnotationVersions)+(SELECT COUNT(*) FROM Tombstones)",
        database: database
      )
    }
    XCTAssertEqual(counts, 0)
  }

  func testDiskGuardPreservesFloorAcrossNormalOversizeAndReclaimPlans() throws {
    let capacity = LockedCapacity(nil)
    let guardWithSeam = ViewerStoreDiskGuard { _ in capacity.value }
    let directory = try makeTemporaryDirectory()
    let plans: [Int64] = [
      4 * 1_024 * 1_024,
      try ViewerStoreQuota.eventReservation(canonicalEventBytes: 16 * 1_024 * 1_024),
      41 * 1_024 * 1_024,
    ]
    for plannedBytes in plans {
      capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes + plannedBytes
      XCTAssertNoThrow(
        try guardWithSeam.requireReserve(at: directory, plannedBytes: plannedBytes)
      )
      capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes + plannedBytes - 1
      XCTAssertThrowsError(
        try guardWithSeam.requireReserve(at: directory, plannedBytes: plannedBytes)
      )
    }
    capacity.value = Int64.max
    XCTAssertThrowsError(
      try guardWithSeam.requireReserve(at: directory, plannedBytes: Int64.max)
    )
    XCTAssertThrowsError(
      try guardWithSeam.requireReserve(at: directory, plannedBytes: -1)
    )
  }

  func testIncrementalVacuumUsesFloorOnlyAndMeasuresPhysicalReclaim() throws {
    let paths = try makePaths()
    let capacity = LockedCapacity(Int64.max)
    let pool = try ViewerSQLitePool(
      migrating: paths,
      diskGuard: ViewerStoreDiskGuard { _ in capacity.value }
    )
    defer { pool.close() }
    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "CREATE TABLE VacuumFixture(rowID INTEGER PRIMARY KEY, payload BLOB NOT NULL)",
        on: database
      )
      try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
      do {
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql: "INSERT INTO VacuumFixture(payload) VALUES(zeroblob(16384))"
        )
        for _ in 0..<512 {
          _ = try insert.step()
          try insert.reset()
        }
        try ViewerSQLiteConnection.execute("COMMIT", on: database)
      } catch {
        try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
        throw error
      }
      try ViewerSQLiteConnection.execute("DELETE FROM VacuumFixture", on: database)
      try ViewerSQLiteConnection.execute("PRAGMA wal_checkpoint(TRUNCATE)", on: database)
    }
    let before = try pool.writer.run { database in
      (
        try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database),
        try ViewerStoreSchema.scalarInt64("PRAGMA page_count", database: database)
      )
    }
    let beforeMain = Int64(
      (try paths.database.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
    )
    let beforeMainSize = Int64(
      (try paths.database.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    )
    let beforeWAL = Int64(
      (try paths.wal.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
    )
    XCTAssertGreaterThan(before.0, 0)

    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes + 1
    XCTAssertTrue(try maintenance.reclaimFreePagesOneStep())
    XCTAssertTrue(try maintenance.checkpointOneStep())
    let after = try pool.writer.run { database in
      (
        try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database),
        try ViewerStoreSchema.scalarInt64("PRAGMA page_count", database: database)
      )
    }
    let afterMain = Int64(
      (try paths.database.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
    )
    let afterMainSize = Int64(
      (try paths.database.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    )
    let afterWAL = Int64(
      (try paths.wal.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
    )
    XCTAssertLessThan(after.0, before.0)
    XCTAssertLessThan(after.1, before.1)
    XCTAssertLessThanOrEqual(afterMain, beforeMain)

    capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes - 1
    let stable = after
    XCTAssertThrowsError(try maintenance.reclaimFreePagesOneStep()) {
      XCTAssertEqual($0 as? ViewerStoreError, .capacityExceeded)
    }
    XCTAssertEqual(
      try pool.writer.run { database in
        (
          try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database),
          try ViewerStoreSchema.scalarInt64("PRAGMA page_count", database: database)
        )
      }.0,
      stable.0
    )
    pool.close()
    let closedMainValues = try paths.database.resourceValues(
      forKeys: [.fileSizeKey, .fileAllocatedSizeKey]
    )
    let closedMainSize = Int64(closedMainValues.fileSize ?? 0)
    let closedMainAllocated = Int64(closedMainValues.fileAllocatedSize ?? 0)
    XCTAssertLessThanOrEqual(closedMainAllocated, beforeMain)
    print(
      "NearWire incremental vacuum: freelist \(before.0)->\(after.0), pages \(before.1)->\(after.1), main size \(beforeMainSize)->\(afterMainSize)->\(closedMainSize) after close, main allocated \(beforeMain)->\(afterMain)->\(closedMainAllocated), WAL allocated \(beforeWAL)->\(afterWAL)"
    )
  }

  func testMaintenanceRunBypassesBlockedReclaimForOneFloorOnlyAction() throws {
    let paths = try makePaths()
    let capacity = LockedCapacity(Int64.max)
    let pool = try ViewerSQLitePool(
      migrating: paths,
      diskGuard: ViewerStoreDiskGuard { _ in capacity.value }
    )
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "maintenance-fallback"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "maintenance-device",
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      partialHistory: false,
      displayName: "Device"
    )
    _ = try store.appendEvents([
      makeObservation(
        recording: recording,
        device: device,
        sequence: 1,
        value: String(repeating: "x", count: 4_096)
      )
    ])
    try store.appendStructural(
      .closeDevice(device, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    try maintenance.requestDelete(confirmation, wallMilliseconds: 2_100)

    try pool.writer.run { database in
      try ViewerSQLiteConnection.execute(
        "CREATE TABLE MaintenanceVacuumFixture(rowID INTEGER PRIMARY KEY, payload BLOB NOT NULL)",
        on: database
      )
      try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
      do {
        let insert = try ViewerSQLiteStatement(
          database: database,
          sql: "INSERT INTO MaintenanceVacuumFixture(payload) VALUES(zeroblob(16384))"
        )
        for _ in 0..<256 {
          _ = try insert.step()
          try insert.reset()
        }
        try ViewerSQLiteConnection.execute("COMMIT", on: database)
      } catch {
        try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
        throw error
      }
      try ViewerSQLiteConnection.execute("DELETE FROM MaintenanceVacuumFixture", on: database)
      try ViewerSQLiteConnection.execute("PRAGMA wal_checkpoint(TRUNCATE)", on: database)
    }
    let before = try pool.writer.run { database in
      (
        try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database),
        try ViewerStoreSchema.scalarInt64("PRAGMA page_count", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: database)
      )
    }
    XCTAssertGreaterThan(before.0, 0)
    XCTAssertEqual(before.2, 1)
    XCTAssertEqual(before.3, 1)

    capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes + 1
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 2_200)
    let after = try pool.writer.run { database in
      (
        try ViewerStoreSchema.scalarInt64("PRAGMA freelist_count", database: database),
        try ViewerStoreSchema.scalarInt64("PRAGMA page_count", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: database),
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Tombstones", database: database)
      )
    }
    XCTAssertLessThan(after.0, before.0)
    XCTAssertLessThan(after.1, before.1)
    XCTAssertEqual(after.2, 1)
    XCTAssertEqual(after.3, 1)
    pool.close()
  }

  func testMaintenanceMutationFailuresReportAuthoritativeStateAndRollback() throws {
    for phase in [
      ViewerStoreMaintenance.MutationPhase.beforeBegin,
      .beforeBody,
      .beforeCommit,
    ] {
      let pool = try ViewerSQLitePool(migrating: makePaths())
      defer { pool.close() }
      let signal = ViewerStoreStatusSignal()
      let store = ViewerEventStore(
        pool: pool,
        configuration: { .default },
        statusSignal: signal
      )
      let recording = try store.beginRecording(
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000,
        reason: "maintenance-failure"
      )
      let fault = ViewerMaintenanceMutationFault(phase)
      let maintenance = ViewerStoreMaintenance(
        pool: pool,
        leases: ViewerStoreLeaseRegistry(),
        configuration: { .default },
        statusSignal: signal,
        storeStateReporter: { store.writeStateRelay.reportFailure($0) },
        mutationGate: { try fault.check($0) }
      )
      XCTAssertThrowsError(
        try maintenance.updateRecording(
          ViewerRecordingRevision(recordingID: recording.rowID, revision: 1),
          name: "Name",
          note: nil,
          pinned: false,
          wallMilliseconds: 2_000
        )
      ) {
        XCTAssertEqual($0 as? ViewerStoreError, .unavailable)
      }
      XCTAssertEqual(store.status().state, .writeFailed)
      XCTAssertEqual(
        try pool.queryReader.run(budget: .query()) {
          try ViewerStoreSchema.scalarInt64(
            "SELECT COUNT(*) FROM RecordingVersions WHERE recordingID=\(recording.rowID)",
            database: $0
          )
        },
        1
      )
      pool.close()
    }

    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "stale-revision"
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { store.writeStateRelay.reportFailure($0) }
    )
    XCTAssertThrowsError(
      try maintenance.updateRecording(
        ViewerRecordingRevision(recordingID: recording.rowID, revision: 0),
        name: nil,
        note: nil,
        pinned: false,
        wallMilliseconds: 2_000
      )
    ) {
      XCTAssertEqual($0 as? ViewerStoreError, .busy)
    }
    XCTAssertEqual(store.status().state, .available)
    pool.close()
  }

  func testMaintenanceWriteFailureStopsIngressUntilExplicitRecovery() async throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let signal = ViewerStoreStatusSignal()
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      statusSignal: signal
    )
    let ingress = ViewerStoreIngress(store: store)
    let relay = store.writeStateRelay
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "maintenance-ingress-gate"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "maintenance-ingress-device",
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      partialHistory: false,
      displayName: "Device"
    )
    let fault = ViewerMaintenanceMutationFault(.beforeBegin)
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      statusSignal: signal,
      storeStateReporter: { relay.reportFailure($0) },
      mutationGate: { try fault.check($0) }
    )

    XCTAssertThrowsError(
      try maintenance.updateRecording(
        ViewerRecordingRevision(recordingID: recording.rowID, revision: 1),
        name: "Blocked",
        note: nil,
        pinned: false,
        wallMilliseconds: 2_000
      )
    ) {
      XCTAssertEqual($0 as? ViewerStoreError, .unavailable)
    }
    XCTAssertEqual(store.status().state, .writeFailed)
    XCTAssertEqual(
      try ingress.admit(
        makeObservation(recording: recording, device: device, sequence: 1, value: "blocked")
      ),
      .stopped
    )
    XCTAssertEqual(
      ingress.admit(
        .closeDevice(device, wallMilliseconds: 2_100, monotonicNanoseconds: 3_100)
      ),
      .stopped
    )

    try store.retry()
    XCTAssertEqual(
      try ingress.admit(
        makeObservation(recording: recording, device: device, sequence: 1, value: "admitted")
      ),
      .admitted
    )
    let flushOutcome = await ingress.flush()
    XCTAssertEqual(flushOutcome, .drained)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      1
    )
    pool.close()
  }

  func testWriterGenerationRejectsAPreselectedIngressPrefixAfterMaintenanceFailure()
    async throws
  {
    let maintenanceEntered = DispatchSemaphore(value: 0)
    let releaseMaintenance = DispatchSemaphore(value: 0)
    let queuedAuthorization = ArmedViewerStoreSignal()
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      automaticWriteAuthorizationObserver: { queuedAuthorization.observe() }
    )
    let ingress = ViewerStoreIngress(store: store)
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "generation-gate"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "generation-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { store.writeStateRelay.reportFailure($0) },
      mutationGate: { phase in
        guard phase == .beforeBody else { return }
        maintenanceEntered.signal()
        _ = releaseMaintenance.wait(timeout: .now() + 5)
        throw ViewerStoreError.unavailable
      }
    )
    let mutationErrors = LockedViewerStoreErrors()
    let mutationFinished = expectation(description: "Maintenance failed")
    DispatchQueue.global().async {
      do {
        _ = try maintenance.appendAnnotation(
          recordingID: recording.rowID,
          body: "blocked",
          wallMilliseconds: 2_000
        )
      } catch {
        mutationErrors.append(error as? ViewerStoreError)
      }
      mutationFinished.fulfill()
    }
    XCTAssertEqual(maintenanceEntered.wait(timeout: .now() + 2), .success)

    queuedAuthorization.arm()
    let secret = "nearwire-stale-ingress-secret"
    XCTAssertEqual(
      try ingress.admit(
        makeObservation(recording: recording, device: device, sequence: 1, value: secret)
      ),
      .admitted
    )
    XCTAssertEqual(queuedAuthorization.wait(timeout: .now() + 2), .success)
    XCTAssertFalse(String(describing: ingress).contains(secret))
    XCTAssertFalse(String(reflecting: ingress).contains(secret))
    XCTAssertTrue(Mirror(reflecting: ingress).children.isEmpty)
    releaseMaintenance.signal()
    await fulfillment(of: [mutationFinished], timeout: 2)
    XCTAssertEqual(mutationErrors.values, [.unavailable])
    let failedFlush = await ingress.flush()
    XCTAssertEqual(failedFlush, .writeFailed)
    XCTAssertEqual(store.status().state, .writeFailed)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      0
    )

    try store.retry()
    let recoveredFlush = await ingress.flush()
    XCTAssertEqual(recoveredFlush, .drained)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      1
    )
    pool.close()
  }

  func testDirectWriterFailurePublishesBeforeQueuedAutomaticWriterValidates() throws {
    let gate = BlockingViewerStoreFailureGate()
    let queuedAuthorization = ArmedViewerStoreSignal()
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      writeGate: { try gate.check() },
      automaticWriteAuthorizationObserver: { queuedAuthorization.observe() }
    )
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "direct-writer-failure"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "direct-writer-device",
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      partialHistory: false,
      displayName: "Device"
    )
    let first = try makeObservation(
      recording: recording,
      device: device,
      sequence: 1,
      value: "first"
    )
    let second = try makeObservation(
      recording: recording,
      device: device,
      sequence: 2,
      value: "second"
    )
    gate.arm()
    let errors = LockedViewerStoreErrors()
    let finished = expectation(description: "Both direct writes completed")
    finished.expectedFulfillmentCount = 2
    DispatchQueue.global().async {
      do { _ = try store.appendEvents([first]) } catch {
        errors.append(error as? ViewerStoreError)
      }
      finished.fulfill()
    }
    XCTAssertEqual(gate.waitUntilEntered(), .success)
    queuedAuthorization.arm()
    DispatchQueue.global().async {
      do { _ = try store.appendEvents([second]) } catch {
        errors.append(error as? ViewerStoreError)
      }
      finished.fulfill()
    }
    XCTAssertEqual(queuedAuthorization.wait(timeout: .now() + 2), .success)
    gate.release()
    wait(for: [finished], timeout: 2)

    XCTAssertEqual(errors.values.count, 2)
    XCTAssertTrue(errors.values.contains(.unavailable))
    XCTAssertTrue(errors.values.contains(.writeNotAuthorized))
    XCTAssertEqual(gate.armedCheckCount, 1)
    XCTAssertEqual(store.status().state, .writeFailed)
    XCTAssertEqual(
      try pool.queryReader.run(budget: .query()) {
        try ViewerStoreSchema.scalarInt64("SELECT COUNT(*) FROM Events", database: $0)
      },
      0
    )

    try store.retry()
    XCTAssertEqual(try store.appendEvents([second]).count, 1)
    XCTAssertEqual(store.status().state, .available)
    pool.close()
  }

  func testDirectMaterializationFailureAndFailedRetryCannotReopenIngress() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let fault = OneShotViewerStoreFault()
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      writeGate: { try fault.check() }
    )
    let ingress = ViewerStoreIngress(store: store)
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "existing"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "existing-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Device"
    )
    fault.failNext()
    XCTAssertThrowsError(
      try store.beginRecording(
        wallMilliseconds: 3_000,
        monotonicNanoseconds: 4_000,
        reason: "direct-failure"
      )
    )
    XCTAssertEqual(store.status().state, .writeFailed)
    XCTAssertEqual(
      try ingress.admit(
        makeObservation(recording: recording, device: device, sequence: 1, value: "blocked")
      ),
      .stopped
    )
    pool.close()

    let paths = try makePaths()
    let repeatedFault = CountingViewerStoreFault()
    repeatedFault.failEveryAttempt()
    let coordinator = try ViewerStoreCoordinator(
      paths: paths,
      writeGate: { try repeatedFault.check() }
    )
    let logicalID = UUID()
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 5_000,
        monotonicNanoseconds: 6_000
      )
    )
    waitUntil {
      repeatedFault.failedAttemptCount >= 1
        && coordinator.services.eventStore.status().state == .writeFailed
    }
    XCTAssertEqual(coordinator.services.eventStore.status().state, .writeFailed)
    XCTAssertTrue(coordinator.retryStorage())
    waitUntil {
      repeatedFault.failedAttemptCount >= 2
        && coordinator.services.eventStore.status().state == .writeFailed
    }
    XCTAssertEqual(coordinator.services.eventStore.status().state, .writeFailed)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 0)
    repeatedFault.succeedEveryAttempt()
    XCTAssertTrue(coordinator.retryStorage())
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM Recordings", at: paths)) == 1
        && ((try? self.scalar(
          "SELECT COUNT(*) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
          at: paths
        )) == 1)
    }
    XCTAssertEqual(coordinator.services.eventStore.status().state, .available)
    XCTAssertEqual(
      try scalar(
        "SELECT COUNT(*) FROM Recordings WHERE durableStartReason='midRuntimeRetry'",
        at: paths
      ),
      1
    )
    XCTAssertEqual(
      try scalar(
        "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE deviceSessionID IS NULL AND reason='storageUnavailable'",
        at: paths
      ),
      1
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 0)
    coordinator.closeStorage()
  }

  func testRecoveryMatrixAllowsOnlyApprovedSuccessfulActions() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { relay.reportFailure($0) },
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        relay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try relay.validate($0) },
      recoveryValidator: { try relay.validate($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "recovery-matrix"
    )
    var revision = try maintenance.updateRecording(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 1),
      name: nil,
      note: nil,
      pinned: true,
      wallMilliseconds: 1_100
    )

    for failedState in [
      ViewerStoreStatus.State.writeFailed,
      .capacityPaused,
    ] {
      relay.reportFailure(failedState)
      _ = try maintenance.appendAnnotation(
        recordingID: recording.rowID,
        body: "does not recover",
        wallMilliseconds: 1_200
      )
      XCTAssertEqual(store.status().state, failedState)
      revision = try maintenance.updateRecording(
        revision,
        name: "Rename only",
        note: nil,
        pinned: true,
        wallMilliseconds: 1_300
      )
      XCTAssertEqual(store.status().state, failedState)
      revision = try maintenance.updateRecording(
        revision,
        name: "Rename only",
        note: nil,
        pinned: false,
        wallMilliseconds: 1_400
      )
      XCTAssertEqual(store.status().state, .available)
      revision = try maintenance.updateRecording(
        revision,
        name: nil,
        note: nil,
        pinned: true,
        wallMilliseconds: 1_500
      )
    }

    let deletable = try store.beginRecording(
      wallMilliseconds: 2_000,
      monotonicNanoseconds: 3_000,
      reason: "manual-delete-recovery"
    )
    try store.appendStructural(
      .closeRecording(deletable, wallMilliseconds: 2_100, monotonicNanoseconds: 3_100)
    )
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: deletable.rowID, revision: 2)
    )
    relay.reportFailure(.writeFailed)
    try maintenance.requestDelete(confirmation, wallMilliseconds: 2_200)
    XCTAssertEqual(store.status().state, .available)

    relay.reportFailure(.capacityPaused)
    try maintenance.run(trigger: .explicit, nowWallMilliseconds: 3_000)
    XCTAssertEqual(store.status().state, .capacityPaused)
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 3_100,
      recoveryAction: .settingsChanged
    )
    waitUntil { store.status().state == .available }
    owner.close()
    pool.close()
  }

  func testApprovedRecoveryActionsCannotReopenANewerFailureGeneration() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay

    let unpinGate = ViewerRecoveryCompletionGate(relay: relay, action: .unpin)
    let unpinMaintenance = makeRecoveryAwareMaintenance(
      pool: pool,
      relay: relay,
      completionGate: unpinGate
    )
    let pinned = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "stale-unpin"
    )
    let pinnedRevision = try unpinMaintenance.updateRecording(
      ViewerRecordingRevision(recordingID: pinned.rowID, revision: 1),
      name: nil,
      note: nil,
      pinned: true,
      wallMilliseconds: 1_100
    )
    relay.reportFailure(.capacityPaused)
    let unpinFinished = expectation(description: "Unpin completed")
    DispatchQueue.global().async {
      _ = try? unpinMaintenance.updateRecording(
        pinnedRevision,
        name: nil,
        note: nil,
        pinned: false,
        wallMilliseconds: 1_200
      )
      unpinFinished.fulfill()
    }
    XCTAssertEqual(unpinGate.waitUntilEntered(), .success)
    relay.reportFailure(.writeFailed)
    unpinGate.release()
    wait(for: [unpinFinished], timeout: 2)
    XCTAssertEqual(relay.currentState, .writeFailed)
    try store.retry()

    let manualGate = ViewerRecoveryCompletionGate(relay: relay, action: .manualDelete)
    let manualMaintenance = makeRecoveryAwareMaintenance(
      pool: pool,
      relay: relay,
      completionGate: manualGate
    )
    let deletable = try store.beginRecording(
      wallMilliseconds: 2_000,
      monotonicNanoseconds: 3_000,
      reason: "stale-manual-delete"
    )
    try store.appendStructural(
      .closeRecording(deletable, wallMilliseconds: 2_100, monotonicNanoseconds: 3_100)
    )
    let confirmation = try manualMaintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: deletable.rowID, revision: 2)
    )
    relay.reportFailure(.writeFailed)
    let deleteFinished = expectation(description: "Manual delete completed")
    DispatchQueue.global().async {
      try? manualMaintenance.requestDelete(confirmation, wallMilliseconds: 2_200)
      deleteFinished.fulfill()
    }
    XCTAssertEqual(manualGate.waitUntilEntered(), .success)
    relay.reportFailure(.capacityPaused)
    manualGate.release()
    wait(for: [deleteFinished], timeout: 2)
    XCTAssertEqual(relay.currentState, .capacityPaused)
    try store.retry()

    let settingsCompletion = ViewerRecoveryCompletionGate(relay: relay, action: .unpin)
    let settingsPublication = ViewerRecoveryPublicationGate()
    let settingsMaintenance = makeRecoveryAwareMaintenance(
      pool: pool,
      relay: relay,
      completionGate: settingsCompletion
    )
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: settingsMaintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) },
      recoveryPublicationGate: { settingsPublication.block() }
    )
    relay.reportFailure(.capacityPaused)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 3_000,
      recoveryAction: .settingsChanged
    )
    XCTAssertEqual(settingsPublication.waitUntilEntered(), .success)
    relay.reportFailure(.writeFailed)
    settingsPublication.release()
    waitUntil { relay.currentState == .writeFailed }
    owner.close()
    XCTAssertEqual(relay.currentState, .writeFailed)
    pool.close()
  }

  func testRuntimeEndInvalidatesInFlightMaintenanceRecoveryBeforePublication() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { relay.reportFailure($0) },
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        relay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try relay.validate($0) },
      recoveryValidator: { try relay.validate($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )
    let publication = ViewerRecoveryPublicationGate()
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) },
      recoveryPublicationGate: { publication.block() }
    )
    relay.reportFailure(.capacityPaused)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 1_000,
      recoveryAction: .settingsChanged
    )
    XCTAssertEqual(publication.waitUntilEntered(), .success)
    owner.runtimeEnded()
    publication.release()
    owner.close()

    XCTAssertEqual(relay.currentState, .capacityPaused)
    XCTAssertEqual(store.status().state, .capacityPaused)
    XCTAssertThrowsError(try relay.issueAutomaticTicket()) {
      XCTAssertEqual($0 as? ViewerStoreError, .writeNotAuthorized)
    }
    pool.close()
  }

  func testRuntimeShutdownQuiescesMaintenanceBeforeOneTerminalFlush() async throws {
    let paths = try makePaths()
    let maintenanceGate = ArmableViewerExecutionGate()
    let writerTurns = LockedViewerCounter()
    let coordinator = try ViewerStoreCoordinator(
      paths: paths,
      writeGate: { writerTurns.increment() },
      maintenanceExecutionGate: { maintenanceGate.run() }
    )
    let logicalID = UUID()
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    waitUntil {
      (try? self.scalar("SELECT COUNT(*) FROM Recordings", at: paths)) == 1
    }
    writerTurns.reset()
    maintenanceGate.arm()
    coordinator.requestMaintenance(.explicit)
    XCTAssertEqual(maintenanceGate.waitUntilBlocked(), .success)
    coordinator.requestMaintenance(.threshold)

    let shutdownFinished = expectation(description: "Runtime shutdown finished")
    Task {
      await coordinator.runtimeEnded(
        wallMilliseconds: 3_000,
        monotonicNanoseconds: 4_000
      )
      shutdownFinished.fulfill()
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(writerTurns.value, 0)
    XCTAssertEqual(maintenanceGate.value, 1)

    maintenanceGate.release()
    await fulfillment(of: [shutdownFinished], timeout: 2)
    XCTAssertEqual(maintenanceGate.value, 1)
    XCTAssertEqual(writerTurns.value, 1)
  }

  func testScheduledMaintenanceStorageFailureClosesAutomaticWrites() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "scheduled-maintenance-failure"
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 1_100, monotonicNanoseconds: 2_100)
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { relay.reportFailure($0) }
    )
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live
    )
    let externalWriter = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    try externalWriter.execute("BEGIN IMMEDIATE")
    owner.trigger(.explicit, wallMilliseconds: 10 * 86_400_000)
    waitUntil { relay.currentState == .writeFailed }
    XCTAssertEqual(store.status().state, .writeFailed)
    XCTAssertThrowsError(try relay.issueAutomaticTicket())
    owner.close()
    try externalWriter.execute("ROLLBACK")
    externalWriter.close()
    pool.close()
  }

  func testDirtySettingsRecoverySuccessorRetainsItsOriginalPermit() throws {
    let blocker = BlockingViewerDiskGuard()
    let pool = try ViewerSQLitePool(
      migrating: makePaths(),
      diskGuard: ViewerStoreDiskGuard { _ in blocker.availableCapacity() }
    )
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    _ = try store.beginRecording(
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "dirty-settings-recovery"
    )
    let relay = store.writeStateRelay
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { relay.reportFailure($0) },
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        relay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try relay.validate($0) },
      recoveryValidator: { try relay.validate($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )
    blocker.arm()
    owner.trigger(.threshold, wallMilliseconds: 1_000)
    XCTAssertEqual(blocker.waitUntilBlocked(), .success)
    relay.reportFailure(.capacityPaused)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 2_000,
      recoveryAction: .settingsChanged
    )
    blocker.release()
    waitUntil { relay.currentState == .available }
    XCTAssertEqual(store.status().state, .available)
    XCTAssertNoThrow(try relay.issueAutomaticTicket())
    owner.close()
    pool.close()
  }

  func testQueuedSettingsRecoveryIsRevokedByANewerNonrecoveringRevision() throws {
    let blocker = BlockingViewerDiskGuard()
    let pool = try ViewerSQLitePool(
      migrating: makePaths(),
      diskGuard: ViewerStoreDiskGuard { _ in blocker.availableCapacity() }
    )
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    _ = try store.beginRecording(
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "queued-settings-recovery"
    )
    let relay = store.writeStateRelay
    let maintenance = makeRecoveryAwareMaintenance(pool: pool, relay: relay)
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) }
    )

    blocker.arm()
    owner.trigger(.threshold, wallMilliseconds: 1_000)
    XCTAssertEqual(blocker.waitUntilBlocked(), .success)
    relay.reportFailure(.capacityPaused)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 2_000,
      recoveryAction: .settingsChanged,
      settingsRevision: 1
    )
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 3_000,
      settingsRevision: 2
    )
    blocker.release()
    owner.waitForQuiescence()

    XCTAssertEqual(relay.currentState, .capacityPaused)
    XCTAssertEqual(store.status().state, .capacityPaused)
    XCTAssertThrowsError(try relay.issueAutomaticTicket())

    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 4_000,
      recoveryAction: .settingsChanged,
      settingsRevision: 3
    )
    waitUntil { relay.currentState == .available }
    XCTAssertNoThrow(try relay.issueAutomaticTicket())
    owner.close()
    pool.close()
  }

  func testRunningSettingsRecoveryIsRevokedBeforePublicationByNewerRevision() throws {
    let pool = try ViewerSQLitePool(migrating: makePaths())
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let relay = store.writeStateRelay
    let publication = ViewerRecoveryPublicationGate()
    let maintenance = makeRecoveryAwareMaintenance(pool: pool, relay: relay)
    let owner = ViewerStoreMaintenanceOwner(
      maintenance: maintenance,
      scheduler: .live,
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      recoveryCompleter: { try relay.completeRecovery($0) },
      recoveryPublicationGate: { publication.block() }
    )

    relay.reportFailure(.capacityPaused)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 1_000,
      recoveryAction: .settingsChanged,
      settingsRevision: 1
    )
    XCTAssertEqual(publication.waitUntilEntered(), .success)
    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 2_000,
      settingsRevision: 2
    )
    publication.release()
    owner.waitForQuiescence()

    XCTAssertEqual(relay.currentState, .capacityPaused)
    XCTAssertEqual(store.status().state, .capacityPaused)
    XCTAssertThrowsError(try relay.issueAutomaticTicket())

    owner.trigger(
      .settingsChanged,
      wallMilliseconds: 3_000,
      recoveryAction: .settingsChanged,
      settingsRevision: 3
    )
    XCTAssertEqual(publication.waitUntilEntered(), .success)
    publication.release()
    waitUntil { relay.currentState == .available }
    XCTAssertNoThrow(try relay.issueAutomaticTicket())
    owner.close()
    pool.close()
  }

  func testSQLiteWriterLockReportsWriteFailedWhileStaleRevisionRemainsLocal() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "sqlite-lock"
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { store.writeStateRelay.reportFailure($0) }
    )
    let externalWriter = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    try externalWriter.execute("BEGIN IMMEDIATE")
    defer { try? externalWriter.execute("ROLLBACK") }

    XCTAssertThrowsError(
      try maintenance.updateRecording(
        ViewerRecordingRevision(recordingID: recording.rowID, revision: 1),
        name: "Locked",
        note: nil,
        pinned: false,
        wallMilliseconds: 2_000
      )
    ) {
      XCTAssertEqual($0 as? ViewerStoreError, .sqliteBusy)
    }
    XCTAssertEqual(store.status().state, .writeFailed)
    try externalWriter.execute("ROLLBACK")

    try store.retry()
    XCTAssertThrowsError(
      try maintenance.updateRecording(
        ViewerRecordingRevision(recordingID: recording.rowID, revision: 0),
        name: nil,
        note: nil,
        pinned: false,
        wallMilliseconds: 2_100
      )
    ) {
      XCTAssertEqual($0 as? ViewerStoreError, .busy)
    }
    XCTAssertEqual(store.status().state, .available)
    pool.close()
  }

  func testManualDeleteClassifiesStorageAndCapacityFailuresWithoutMutation() throws {
    for error in [
      ViewerStoreError.unavailable,
      .corruptStore,
      .capacityExceeded,
    ] {
      for phase in [
        ViewerStoreMaintenance.MutationPhase.beforeBegin,
        .beforeBody,
        .beforeCommit,
      ] {
        let pool = try ViewerSQLitePool(migrating: makePaths())
        defer { pool.close() }
        let store = ViewerEventStore(pool: pool, configuration: { .default })
        let recording = try store.beginRecording(
          wallMilliseconds: 1_000,
          monotonicNanoseconds: 2_000,
          reason: "delete-failure"
        )
        try store.appendStructural(
          .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
        )
        let quotaBefore = store.status().logicalQuotaBytes
        let fault = ViewerMaintenanceMutationFault(phase, error: error)
        let maintenance = ViewerStoreMaintenance(
          pool: pool,
          leases: ViewerStoreLeaseRegistry(),
          configuration: { .default },
          storeStateReporter: { store.writeStateRelay.reportFailure($0) },
          mutationGate: { try fault.check($0) }
        )
        let confirmation = try maintenance.prepareDelete(
          ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
        )
        XCTAssertThrowsError(
          try maintenance.requestDelete(confirmation, wallMilliseconds: 3_000)
        ) {
          XCTAssertEqual($0 as? ViewerStoreError, error)
        }
        XCTAssertEqual(
          store.status().state,
          error == .capacityExceeded ? .capacityPaused : .writeFailed
        )
        let after = try pool.queryReader.run(budget: .query()) { database in
          (
            try ViewerStoreSchema.scalarInt64(
              "SELECT COUNT(*) FROM Tombstones", database: database),
            try ViewerStoreSchema.scalarInt64(
              "SELECT integerValue FROM StoreMetadata WHERE key='logicalQuotaBytes'",
              database: database
            )
          )
        }
        XCTAssertEqual(after.0, 0)
        XCTAssertEqual(after.1, quotaBefore)
        pool.close()
      }
    }
  }

  func testManualDeleteReserveSharesWriterOrderingWithMetadataWrite() throws {
    let diskGate = BlockingViewerDiskGuard()
    let pool = try ViewerSQLitePool(
      migrating: makePaths(),
      diskGuard: ViewerStoreDiskGuard { _ in diskGate.availableCapacity() }
    )
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "delete-ordering"
    )
    try store.appendStructural(
      .closeRecording(recording, wallMilliseconds: 2_000, monotonicNanoseconds: 3_000)
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    let confirmation = try maintenance.prepareDelete(
      ViewerRecordingRevision(recordingID: recording.rowID, revision: 2)
    )
    diskGate.arm()
    let deleteFinished = expectation(description: "Manual delete finished")
    let annotationFinished = expectation(description: "Annotation finished")
    DispatchQueue.global().async {
      _ = try? maintenance.requestDelete(confirmation, wallMilliseconds: 3_000)
      deleteFinished.fulfill()
    }
    XCTAssertEqual(diskGate.waitUntilBlocked(), .success)
    DispatchQueue.global().async {
      _ = try? maintenance.appendAnnotation(
        recordingID: recording.rowID,
        body: "annotation",
        wallMilliseconds: 3_100
      )
      annotationFinished.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertEqual(diskGate.maximumConcurrentChecks, 1)
    diskGate.release()
    wait(for: [deleteFinished, annotationFinished], timeout: 2)
    XCTAssertEqual(diskGate.maximumConcurrentChecks, 1)
    pool.close()
  }

  func testCheckpointReserveSharesWriterOrderingWithEventWrite() throws {
    let diskGate = BlockingViewerDiskGuard()
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(
      migrating: paths,
      diskGuard: ViewerStoreDiskGuard { _ in diskGate.availableCapacity() }
    )
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    _ = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "checkpoint-ordering"
    )
    XCTAssertGreaterThan(
      (try? paths.wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
      32
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    diskGate.arm()
    let checkpointFinished = expectation(description: "Checkpoint finished")
    let writeFinished = expectation(description: "Event write finished")
    DispatchQueue.global().async {
      _ = try? maintenance.checkpointOneStep()
      checkpointFinished.fulfill()
    }
    XCTAssertEqual(diskGate.waitUntilBlocked(), .success)
    DispatchQueue.global().async {
      _ = try? store.beginRecording(
        wallMilliseconds: 1_100,
        monotonicNanoseconds: 2_100,
        reason: "ordered-write"
      )
      writeFinished.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertEqual(diskGate.maximumConcurrentChecks, 1)
    diskGate.release()
    wait(for: [checkpointFinished, writeFinished], timeout: 2)
    XCTAssertEqual(diskGate.maximumConcurrentChecks, 1)
    pool.close()
  }

  func testOrphanRecoveryChecksExactPhysicalPlanOnWriter() throws {
    let paths = try makePaths()
    let setupPool = try ViewerSQLitePool(migrating: paths)
    defer { setupPool.close() }
    let store = ViewerEventStore(pool: setupPool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "orphan-plan"
    )
    _ = try store.beginDeviceSession(
      recording: recording,
      installationID: "orphan-one",
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      partialHistory: false,
      displayName: "One"
    )
    _ = try store.beginDeviceSession(
      recording: recording,
      installationID: "orphan-two",
      wallMilliseconds: 1_200,
      monotonicNanoseconds: 2_200,
      partialHistory: false,
      displayName: "Two"
    )
    setupPool.close()

    let capacity = SequencedViewerCapacity([
      Int64.max,
      ViewerStoreDiskGuard.minimumAvailableBytes
        + 3 * ViewerStoreQuota.structuralReservation,
    ])
    let coordinator = try ViewerStoreCoordinator(
      paths: paths,
      diskGuard: ViewerStoreDiskGuard { _ in capacity.next() }
    )
    coordinator.closeStorage()
    XCTAssertGreaterThanOrEqual(capacity.callCount, 2)
  }

  func testShutdownUsesOneFailedFlushAndNextOpenReconcilesOrphan() async throws {
    let paths = try makePaths()
    let fault = CountingViewerStoreFault()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { try fault.check() })
    let logicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: wallMilliseconds,
        monotonicNanoseconds: 2_000
      )
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: logicalID,
        state: "active"
      )) == 1
    }
    fault.failEveryAttempt()
    await coordinator.runtimeEnded(
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 3_000
    )
    XCTAssertEqual(fault.failedAttemptCount, 1)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: logicalID, state: "closed"),
      0
    )

    let reopened = try ViewerStoreCoordinator(paths: paths)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: logicalID,
        state: "recoveredAfterInterruption"
      ),
      1
    )
    reopened.closeStorage()
  }

  func testShutdownDoesNotRetryPreexistingFailedPrefix() async throws {
    let paths = try makePaths()
    let fault = CountingViewerStoreFault()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { try fault.check() })
    let logicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: wallMilliseconds,
        monotonicNanoseconds: 2_000
      )
    )
    waitUntil { coordinator.services.eventStore.status().logicalQuotaBytes > 0 }
    let context = try makeAdmissionContext(suffix: "shutdown-prefix")
    let recordingOnlyQuota = coordinator.services.eventStore.status().logicalQuotaBytes
    XCTAssertTrue(coordinator.sessionStarted(context))
    waitUntil {
      coordinator.services.eventStore.status().logicalQuotaBytes > recordingOnlyQuota
    }
    fault.failEveryAttempt()
    coordinator.policyChanged(
      connectionID: context.connectionID,
      policy: .default,
      monotonicNanoseconds: 3_000
    )
    waitUntil { coordinator.services.eventStore.status().state == .writeFailed }
    XCTAssertEqual(fault.failedAttemptCount, 1)

    await coordinator.runtimeEnded(
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 4_000
    )
    XCTAssertEqual(fault.failedAttemptCount, 1)
    let reopened = try ViewerStoreCoordinator(paths: paths)
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: logicalID,
        state: "recoveredAfterInterruption"
      ),
      1
    )
    reopened.closeStorage()
  }

  func testShutdownCapacityFailureIsFiniteAndReconcilesOnNextOpen() async throws {
    let paths = try makePaths()
    let capacity = LockedCapacity(Int64.max)
    let coordinator = try ViewerStoreCoordinator(
      paths: paths,
      diskGuard: ViewerStoreDiskGuard { _ in capacity.value }
    )
    let logicalID = UUID()
    let wallMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: logicalID,
        wallMilliseconds: wallMilliseconds,
        monotonicNanoseconds: 2_000
      )
    )
    waitUntil {
      (try? self.latestRecordingStateCount(
        at: paths,
        logicalID: logicalID,
        state: "active"
      )) == 1
    }
    capacity.value = ViewerStoreDiskGuard.minimumAvailableBytes - 1
    await coordinator.runtimeEnded(
      wallMilliseconds: wallMilliseconds + 1_000,
      monotonicNanoseconds: 3_000
    )
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, logicalID: logicalID, state: "closed"),
      0
    )
    capacity.value = Int64.max
    let reopened = try ViewerStoreCoordinator(
      paths: paths,
      diskGuard: ViewerStoreDiskGuard { _ in capacity.value }
    )
    XCTAssertEqual(
      try latestRecordingStateCount(
        at: paths,
        logicalID: logicalID,
        state: "recoveredAfterInterruption"
      ),
      1
    )
    reopened.closeStorage()
  }

  @MainActor
  func testApplicationFailuresCloseEveryRecordingWhileReusingOneStoreRuntime() async throws {
    let paths = try makePaths()
    let runtime = ViewerStoreRuntime(paths: paths)
    let identityLoads = LockedViewerCounter()
    let identityResets = LockedViewerCounter()
    let managerGenerations = ViewerManagerGenerationSource()
    let dependencies = ViewerRuntimeDependencies(
      loadIdentity: {
        identityLoads.increment()
        throw ViewerStoreError.unavailable
      },
      resetTLSIdentity: { identityResets.increment() },
      resetAllIdentity: {},
      generatePairingCode: { try PairingCode("ABCDEF") },
      makeRuntimeComponents: { runtimeLogicalID in
        ViewerRuntimeComponents.make(
          runtimeLogicalID: runtimeLogicalID,
          managerGeneration: managerGenerations.next(),
          durableJournal: runtime,
          storeGateway: runtime.explorerGateway
        )
      },
      loadStorageConfiguration: { runtime.loadConfiguration() },
      loadStoreStatus: { runtime.status() }
    )
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: dependencies
    )

    model.openWindow()
    await waitForApplicationStatus(.failed(.identityUnavailable), in: model)
    waitUntil {
      identityLoads.value == 1
        && ((try? self.scalar("SELECT COUNT(*) FROM Recordings", at: paths)) == 1)
        && ((try? self.latestRecordingStateCount(at: paths, state: "closed")) == 1)
        && ((try? self.latestRecordingStateCount(at: paths, state: "active")) == 0)
    }

    model.retry()
    await waitUntilAsync {
      identityLoads.value == 2
        && model.status == .failed(.identityUnavailable)
        && ((try? self.latestRecordingStateCount(at: paths, state: "active")) == 0)
    }
    XCTAssertEqual(model.status, .failed(.identityUnavailable))
    let countAfterRetry = try scalar("SELECT COUNT(*) FROM Recordings", at: paths)
    XCTAssertEqual(countAfterRetry, 1)
    XCTAssertEqual(
      try latestRecordingStateCount(at: paths, state: "closed"), countAfterRetry)

    model.resetTLSIdentity()
    await waitUntilAsync {
      identityResets.value == 1
        && identityLoads.value == 3
        && model.status == .failed(.identityUnavailable)
        && ((try? self.latestRecordingStateCount(at: paths, state: "active")) == 0)
    }
    XCTAssertEqual(model.status, .failed(.identityUnavailable))

    _ = await model.prepareForTermination()
    let finalCount = try scalar("SELECT COUNT(*) FROM Recordings", at: paths)
    XCTAssertEqual(finalCount, 1)
    XCTAssertEqual(try latestRecordingStateCount(at: paths, state: "closed"), finalCount)
    XCTAssertEqual(try latestRecordingStateCount(at: paths, state: "active"), 0)
    runtime.closeStorage()
  }

  @MainActor
  func testApplicationRapidStopCancelsPausedAutomaticReopen() async throws {
    let paths = try makePaths()
    let reopenGate = ArmableViewerExecutionGate()
    let runtime = ViewerStoreRuntime(
      paths: paths,
      reopenExecutionGate: { reopenGate.run() }
    )
    let identityLoads = LockedViewerCounter()
    let managerGenerations = ViewerManagerGenerationSource()
    let dependencies = ViewerRuntimeDependencies(
      loadIdentity: {
        identityLoads.increment()
        throw ViewerStoreError.unavailable
      },
      resetTLSIdentity: {},
      resetAllIdentity: {},
      generatePairingCode: { try PairingCode("ABCDEF") },
      makeRuntimeComponents: { runtimeLogicalID in
        ViewerRuntimeComponents.make(
          runtimeLogicalID: runtimeLogicalID,
          managerGeneration: managerGenerations.next(),
          durableJournal: runtime,
          storeGateway: runtime.explorerGateway
        )
      },
      loadStorageConfiguration: { runtime.loadConfiguration() },
      loadStoreStatus: { runtime.status() }
    )
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: dependencies
    )

    model.openWindow()
    await waitForApplicationStatus(.failed(.identityUnavailable), in: model)
    waitUntil {
      identityLoads.value == 1
        && ((try? self.scalar("SELECT COUNT(*) FROM Recordings", at: paths)) == 1)
        && ((try? self.latestRecordingStateCount(at: paths, state: "closed")) == 1)
        && ((try? self.latestRecordingStateCount(at: paths, state: "active")) == 0)
    }

    reopenGate.arm()
    model.retry()
    let reopenBlocked = await Task.detached {
      reopenGate.waitUntilBlocked()
    }.value
    XCTAssertEqual(reopenBlocked, .success)
    let terminationTask = Task { await model.prepareForTermination() }
    for _ in 0..<100 where model.status == .starting { await Task.yield() }
    switch model.status {
    case .stopping, .failed(.identityUnavailable): break
    default:
      XCTFail(
        "Termination must retain or replace the safe failure state while cleanup waits."
      )
    }
    reopenGate.release()
    _ = await terminationTask.value
    let cancelledPrefixFinished = expectation(description: "Application reopen prefix finished")
    runtime.afterCurrentReopenPrefix { cancelledPrefixFinished.fulfill() }
    await fulfillment(of: [cancelledPrefixFinished], timeout: 2)

    XCTAssertEqual(model.status, .stopped)
    XCTAssertEqual(runtime.status().state, .unavailable)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Recordings", at: paths), 1)
    XCTAssertEqual(try latestRecordingStateCount(at: paths, state: "closed"), 1)
    runtime.closeStorage()
  }

  @MainActor
  func testApplicationStorageSettingsValidatePersistAndRefreshSafeStatus() async throws {
    let saved = LockedStorageConfiguration()
    let expectedStatus = ViewerStoreStatus(
      state: .capacityPaused,
      capacityBytes: ViewerStorageConfiguration.defaultCapacityBytes,
      logicalQuotaBytes: 123,
      allocatedFootprintBytes: 456,
      oldestHistoryMilliseconds: nil,
      pinnedQuotaBytes: 12,
      estimatedRetainedDurationMilliseconds: nil,
      lastCleanupCategory: .none
    )
    let dependencies = ViewerRuntimeDependencies(
      loadIdentity: { throw ViewerStoreError.unavailable },
      resetTLSIdentity: {},
      resetAllIdentity: {},
      generatePairingCode: { throw ViewerStoreError.unavailable },
      saveStorageConfiguration: { saved.set($0) },
      loadStoreStatus: { expectedStatus }
    )
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: dependencies
    )
    XCTAssertTrue(model.updateStorage(capacityGiB: "4", historyRetentionDays: "30"))
    XCTAssertEqual(saved.value?.capacityBytes, 4 * 1_024 * 1_024 * 1_024)
    for _ in 0..<20 where model.storeStatus != expectedStatus { await Task.yield() }
    XCTAssertEqual(model.storeStatus, expectedStatus)
    XCTAssertFalse(model.updateStorage(capacityGiB: String(Int64.max), historyRetentionDays: "30"))
  }

  func testProcessWorkspaceIsUniqueMarkedAndRemovedExactly() throws {
    let first = ViewerStorePaths.processWorkspace(nonce: UUID())
    let second = ViewerStorePaths.processWorkspace(nonce: UUID())
    XCTAssertNotEqual(first.directory, second.directory)

    let pool = try ViewerSQLitePool(migrating: first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.database.path))
    XCTAssertEqual(
      try Data(contentsOf: first.processWorkspaceMarker),
      Data(first.directory.lastPathComponent.utf8)
    )
    pool.close()
    try first.removeProcessWorkspace()
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))

    let ordinary = try makePaths()
    try FileManager.default.createDirectory(at: ordinary.directory, withIntermediateDirectories: true)
    XCTAssertThrowsError(try ordinary.removeProcessWorkspace()) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidPath)
    }
  }

  func testCompleteSessionTransferProducerAndImporterShareExactBounds() throws {
    XCTAssertNoThrow(
      try ViewerSessionTransferLimits.validateCounts(
        deviceCount: ViewerSessionTransferLimits.maximumDeviceCount,
        eventCount: ViewerSessionTransferLimits.maximumEventCount,
        gapCount: ViewerSessionTransferLimits.maximumGapCount,
        annotationCount: ViewerSessionTransferLimits.maximumAnnotationCount
      )
    )
    XCTAssertNoThrow(
      try ViewerSessionTransferLimits.validateFileBytes(
        ViewerSessionTransferLimits.maximumFileBytes
      )
    )

    let overflowCases: [(Int64, Int64, Int64, Int64)] = [
      (ViewerSessionTransferLimits.maximumDeviceCount + 1, 0, 0, 0),
      (0, ViewerSessionTransferLimits.maximumEventCount + 1, 0, 0),
      (0, 0, ViewerSessionTransferLimits.maximumGapCount + 1, 0),
      (0, 0, 0, ViewerSessionTransferLimits.maximumAnnotationCount + 1),
    ]
    for counts in overflowCases {
      XCTAssertThrowsError(
        try ViewerSessionTransferLimits.validateCounts(
          deviceCount: counts.0,
          eventCount: counts.1,
          gapCount: counts.2,
          annotationCount: counts.3
        )
      ) { error in
        XCTAssertEqual(error as? ViewerStoreError, .workLimitExceeded)
      }
    }
    XCTAssertThrowsError(
      try ViewerSessionTransferLimits.validateFileBytes(
        ViewerSessionTransferLimits.maximumFileBytes + 1
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .workLimitExceeded)
    }
  }

  @MainActor
  func testApplicationTerminationRetainsWorkingStoreCleanupAfterBoundedTimeout() async throws {
    let paths = ViewerStorePaths.processWorkspace(nonce: UUID())
    let pool = try ViewerSQLitePool(migrating: paths)
    let closeGate = ArmableViewerExecutionGate()
    closeGate.arm()
    let dependencies = ViewerRuntimeDependencies(
      loadIdentity: { throw ViewerStoreError.unavailable },
      resetTLSIdentity: {},
      resetAllIdentity: {},
      generatePairingCode: { throw ViewerStoreError.unavailable },
      cleanupTimeoutNanoseconds: 10_000_000,
      closeWorkingStore: {
        await Task.detached {
          closeGate.run()
          pool.close()
          try? paths.removeProcessWorkspace()
        }.value
      }
    )
    let model = ViewerApplicationModel(
      preferences: ViewerPreferences(requiresApproval: { false }, setRequiresApproval: { _ in }),
      dependencies: dependencies
    )
    model.openWindow()
    await waitForApplicationStatus(.failed(.identityUnavailable), in: model)

    let replied = expectation(description: "App delegate replied after bounded cleanup wait")
    let delegate = ViewerAppDelegate()
    delegate.beginTermination(using: model) { shouldTerminate in
      XCTAssertTrue(shouldTerminate)
      replied.fulfill()
    }
    let closeBlocked = await closeGate.waitUntilBlockedAsync()
    XCTAssertEqual(closeBlocked, .success)
    await fulfillment(of: [replied], timeout: 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.directory.path))

    closeGate.release()
    await model.waitForTerminalCleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.path))
  }

  func testClearCurrentSessionRemovesEventDerivedRowsAndPreservesDeviceCapture() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "clear-current-session-test"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "clear-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Clear Device"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "before-clear")
    )
    try store.appendStructural(
      .drop(
        device: device,
        sequence: 1,
        wallMilliseconds: 1_100,
        monotonicNanoseconds: 2_100,
        reason: "testDrop",
        count: 1
      )
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "testGap",
        count: 1,
        firstWallMilliseconds: 1_100,
        lastWallMilliseconds: 1_100,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      )
    )
    let maintenance = ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    )
    _ = try maintenance.appendAnnotation(
      recordingID: recording.rowID,
      body: "remove me",
      wallMilliseconds: 1_200
    )

    let result = try store.clearCurrentSessionEvents(recording: recording)
    XCTAssertEqual(result.deletedEventCount, 1)
    XCTAssertGreaterThan(result.reclaimedQuotaBytes, 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Events", at: paths), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM EventDispositionVersions", at: paths), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DropVersions", at: paths), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM GapVersions", at: paths), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM AnnotationVersions", at: paths), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM RecordingVersions", at: paths), 1)

    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 2, value: "after-clear")
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Events", at: paths), 1)
  }

  func testWorkspaceMutationDrainsAdmittedEventAndStructuralIngressPrefixes() throws {
    let sourcePaths = try makePaths()
    let sourcePool = try ViewerSQLitePool(migrating: sourcePaths)
    defer { sourcePool.close() }
    let sourceStore = ViewerEventStore(pool: sourcePool, configuration: { .default })
    let sourceRecording = try sourceStore.beginRecording(
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "mutation-prefix-import-source"
    )
    _ = try sourceStore.beginDeviceSession(
      recording: sourceRecording,
      installationID: "imported-prefix-device",
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      partialHistory: false,
      displayName: "Imported Prefix Device"
    )
    let importURL = sourcePaths.directory.appendingPathComponent("prefix-import.json")
    try ViewerStoreExportService(
      pool: sourcePool,
      leases: ViewerStoreLeaseRegistry()
    ).export(recordingID: sourceRecording.rowID, to: importURL)

    let paths = try makePaths()
    let writeGate = ArmableViewerExecutionGate()
    let coordinator = try ViewerStoreCoordinator(paths: paths, writeGate: { writeGate.run() })
    defer { coordinator.closeStorage() }
    let runtimeLogicalID = UUID()
    let context = try makeAdmissionContext(suffix: "mutation-prefix")
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: runtimeLogicalID,
        wallMilliseconds: 1_000,
        monotonicNanoseconds: 2_000
      )
    )
    XCTAssertTrue(coordinator.sessionStarted(context))
    waitUntil { (try? self.scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths)) == 1 }

    let appID = context.appHello.installationID
    let viewerID = context.viewerHello.installationID
    let envelope = try EventEnvelope(
      id: EventID(),
      type: EventType.user("test.mutation-prefix"),
      content: .object(["value": .integer(1)]),
      createdAt: Date(timeIntervalSince1970: 1),
      monotonicTimestampNanoseconds: 3_000,
      source: EventEndpoint(role: .app, id: appID),
      target: EventEndpoint(role: .viewer, id: viewerID),
      direction: .appToViewer,
      sessionEpoch: SessionEpoch(),
      sequence: EventSequence(1),
      priority: .normal,
      ttl: .default,
      causality: EventCausality()
    )
    let encodedBytes = try WireEventRecord(
      envelope: envelope,
      remainingTTLNanoseconds: 10_000_000_000
    ).deterministicEncodedByteCount()
    let observation = try ViewerCommittedEventObservation(
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nil,
      envelope: envelope,
      viewerWallMilliseconds: 1_000,
      viewerMonotonicNanoseconds: 3_000,
      deterministicEventBytes: encodedBytes,
      initialDisposition: .buffered
    )

    writeGate.arm()
    coordinator.eventCommitted(observation) { _ in }
    coordinator.dropsChanged(
      connectionID: context.connectionID,
      samples: [.init(reason: .localOverflow, count: 1)],
      monotonicNanoseconds: 3_100
    )
    XCTAssertEqual(writeGate.waitUntilBlocked(), .success)
    let clearFinished = expectation(description: "Clear drained ingress prefix")
    XCTAssertTrue(
      coordinator.clearCurrentSession { result in
        if case .failure(let error) = result { XCTFail("Clear failed: \(error)") }
        clearFinished.fulfill()
      }
    )
    writeGate.release()
    wait(for: [clearFinished], timeout: 2)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Events", at: paths), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DropVersions", at: paths), 0)

    writeGate.arm()
    XCTAssertTrue(
      coordinator.sessionEnded(
        connectionID: context.connectionID,
        wallMilliseconds: 2_000,
        monotonicNanoseconds: 4_000
      )
    )
    XCTAssertEqual(writeGate.waitUntilBlocked(), .success)
    let importFinished = expectation(description: "Import drained structural ingress prefix")
    XCTAssertTrue(
      coordinator.importCurrentSession(from: importURL) { result in
        if case .failure(let error) = result { XCTFail("Import failed: \(error)") }
        importFinished.fulfill()
      }
    )
    writeGate.release()
    wait(for: [importFinished], timeout: 2)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 1)
    XCTAssertEqual(
      try scalar("SELECT COUNT(*) FROM DeviceSessionVersions WHERE state='active'", at: paths),
      0
    )
  }

  func testImportedCoordinatorGapSequenceAdvancesBeforeNewRuntimeGap() throws {
    let sourcePaths = try makePaths()
    let sourcePool = try ViewerSQLitePool(migrating: sourcePaths)
    defer { sourcePool.close() }
    let sourceStore = ViewerEventStore(pool: sourcePool, configuration: { .default })
    let sourceRecording = try sourceStore.beginRecording(
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "imported-gap-sequence-source"
    )
    try sourceStore.appendStructural(
      .gap(
        recording: sourceRecording,
        device: nil,
        sequence: 1,
        reason: "imported-runtime-gap",
        count: 1,
        firstWallMilliseconds: 1,
        lastWallMilliseconds: 1,
        directions: "unknown",
        firstWireSequence: nil,
        lastWireSequence: nil
      )
    )
    let importURL = sourcePaths.directory.appendingPathComponent("runtime-gap-import.json")
    try ViewerStoreExportService(
      pool: sourcePool,
      leases: ViewerStoreLeaseRegistry()
    ).export(recordingID: sourceRecording.rowID, to: importURL)

    let targetPaths = try makePaths()
    let coordinator = try ViewerStoreCoordinator(paths: targetPaths)
    defer { coordinator.closeStorage() }
    let runtimeLogicalID = UUID()
    XCTAssertTrue(
      coordinator.runtimeStarted(
        logicalID: runtimeLogicalID,
        wallMilliseconds: 10,
        monotonicNanoseconds: 10
      )
    )
    waitUntil { (try? self.scalar("SELECT COUNT(*) FROM Recordings", at: targetPaths)) == 1 }

    let imported = expectation(description: "Imported Session with runtime gap")
    XCTAssertTrue(
      coordinator.importCurrentSession(from: importURL) { result in
        if case .failure(let error) = result { XCTFail("Import failed: \(error)") }
        imported.fulfill()
      }
    )
    wait(for: [imported], timeout: 2)
    XCTAssertEqual(
      try scalar("SELECT COUNT(*) FROM GapVersions WHERE deviceSessionID IS NULL", at: targetPaths),
      1
    )

    XCTAssertTrue(
      coordinator.recoverRuntime(
        logicalID: runtimeLogicalID,
        wallMilliseconds: 20,
        monotonicNanoseconds: 20,
        missedObservationCount: 1
      )
    )
    waitUntil {
      (try? self.scalar(
        "SELECT COUNT(*) FROM GapVersions WHERE deviceSessionID IS NULL",
        at: targetPaths
      )) == 2
    }
    XCTAssertEqual(
      try scalar(
        "SELECT COUNT(DISTINCT sequence) FROM GapVersions WHERE deviceSessionID IS NULL",
        at: targetPaths
      ),
      2
    )
    XCTAssertEqual(coordinator.services.eventStore.status().state, .available)
  }

  func testReopenedCoordinatorResumesDurableGapSequence() throws {
    let paths = try makePaths()
    let firstCoordinator = try ViewerStoreCoordinator(paths: paths)
    let firstRuntimeID = UUID()
    XCTAssertTrue(
      firstCoordinator.runtimeStarted(
        logicalID: firstRuntimeID,
        wallMilliseconds: 1,
        monotonicNanoseconds: 1
      )
    )
    XCTAssertTrue(
      firstCoordinator.recoverRuntime(
        logicalID: firstRuntimeID,
        wallMilliseconds: 2,
        monotonicNanoseconds: 2,
        missedObservationCount: 1
      )
    )
    waitUntil {
      (try? self.scalar(
        "SELECT COUNT(*) FROM GapVersions WHERE deviceSessionID IS NULL",
        at: paths
      )) == 1
    }
    firstCoordinator.closeStorage()

    let reopenedCoordinator = try ViewerStoreCoordinator(paths: paths)
    defer { reopenedCoordinator.closeStorage() }
    let reopenedRuntimeID = UUID()
    XCTAssertTrue(
      reopenedCoordinator.runtimeStarted(
        logicalID: reopenedRuntimeID,
        wallMilliseconds: 3,
        monotonicNanoseconds: 3
      )
    )
    XCTAssertTrue(
      reopenedCoordinator.recoverRuntime(
        logicalID: reopenedRuntimeID,
        wallMilliseconds: 4,
        monotonicNanoseconds: 4,
        missedObservationCount: 1
      )
    )
    waitUntil {
      (try? self.scalar(
        "SELECT COUNT(*) FROM GapVersions WHERE deviceSessionID IS NULL",
        at: paths
      )) == 2
    }
    XCTAssertEqual(
      try scalar(
        "SELECT COUNT(DISTINCT sequence) FROM GapVersions WHERE deviceSessionID IS NULL",
        at: paths
      ),
      2
    )
    XCTAssertEqual(reopenedCoordinator.services.eventStore.status().state, .available)
  }

  func testSessionImportCancellationInterruptsBulkDeleteAndRollsBackCurrentSession() throws {
    let sourcePaths = try makePaths()
    let sourcePool = try ViewerSQLitePool(migrating: sourcePaths)
    defer { sourcePool.close() }
    let sourceStore = ViewerEventStore(pool: sourcePool, configuration: { .default })
    let sourceRecording = try sourceStore.beginRecording(
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: "bulk-delete-cancellation-source"
    )
    _ = try sourceStore.beginDeviceSession(
      recording: sourceRecording,
      installationID: "bulk-delete-imported-device",
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      partialHistory: false,
      displayName: "Imported Device"
    )
    let importURL = sourcePaths.directory.appendingPathComponent("bulk-delete-import.json")
    try ViewerStoreExportService(
      pool: sourcePool,
      leases: ViewerStoreLeaseRegistry()
    ).export(recordingID: sourceRecording.rowID, to: importURL)

    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 10,
      monotonicNanoseconds: 10,
      reason: "bulk-delete-cancellation-target"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "bulk-delete-existing-device",
      wallMilliseconds: 10,
      monotonicNanoseconds: 10,
      partialHistory: false,
      displayName: "Existing Device"
    )
    let retainedEventCount = 4_096
    for start in stride(from: 0, to: retainedEventCount, by: 256) {
      let end = min(start + 256, retainedEventCount)
      let observations = try (start..<end).map { index in
        try makeObservation(
          recording: recording,
          device: device,
          sequence: UInt64(index + 1),
          value: "existing-\(index)"
        )
      }
      _ = try store.appendEvents(observations)
    }
    let document = try ViewerSessionImportDocument.open(
      importURL,
      maximumFileBytes: ViewerSessionTransferLimits.maximumFileBytes,
      snapshotDirectory: paths.directory
    )
    let cancellation = ViewerSessionImportCancellation()
    let phase = LockedViewerImportPhase()
    let progressGate = ArmableViewerExecutionGate()
    progressGate.arm()
    let errors = LockedViewerStoreErrors()
    let finished = expectation(description: "Cancelled bulk replacement rolled back")

    DispatchQueue.global(qos: .utility).async {
      do {
        _ = try store.replaceCurrentSession(
          recording: recording,
          with: document,
          cancellation: cancellation,
          progress: { phase.set($0) },
          transactionProgress: {
            if phase.value == .recording { progressGate.run() }
          }
        )
        errors.append(nil)
      } catch {
        errors.append(error as? ViewerStoreError)
      }
      finished.fulfill()
    }

    XCTAssertEqual(progressGate.waitUntilBlocked(), .success)
    cancellation.cancel()
    progressGate.release()
    wait(for: [finished], timeout: 5)
    XCTAssertEqual(errors.values, [.cancelled])
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Events", at: paths), Int64(retainedEventCount))
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: paths), 1)
  }

  func testCompleteSessionRoundTripRegeneratesOfflineIdentityAndCancellationRollsBack() throws {
    let sourcePaths = try makePaths()
    let sourcePool = try ViewerSQLitePool(migrating: sourcePaths)
    defer { sourcePool.close() }
    let sourceStore = ViewerEventStore(pool: sourcePool, configuration: { .default })
    let sourceRecording = try sourceStore.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "round-trip-source"
    )
    let firstDevice = try sourceStore.beginDeviceSession(
      recording: sourceRecording,
      installationID: "raw-installation-never-imported",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Imported App",
      applicationIdentifier: "com.example.imported",
      applicationVersion: "1.0"
    )
    let secondDevice = try sourceStore.beginDeviceSession(
      recording: sourceRecording,
      installationID: "raw-installation-never-imported",
      wallMilliseconds: 1_100,
      monotonicNanoseconds: 2_100,
      partialHistory: false,
      displayName: "Imported App"
    )
    let repeatedPeerEventID = EventID()
    _ = try sourceStore.appendEvent(
      makeObservation(
        recording: sourceRecording,
        device: firstDevice,
        sequence: 1,
        value: "one",
        eventID: repeatedPeerEventID,
        content: .object([
          "decimal": .number(1),
          "exponent": .number(100),
        ])
      )
    )
    _ = try sourceStore.appendEvent(
      makeObservation(
        recording: sourceRecording,
        device: secondDevice,
        sequence: 1,
        value: "two",
        eventID: repeatedPeerEventID
      )
    )
    try sourceStore.appendStructural(
      .gap(
        recording: sourceRecording,
        device: firstDevice,
        sequence: 1,
        reason: "roundTripGap",
        count: 1,
        firstWallMilliseconds: 1_200,
        lastWallMilliseconds: 1_200,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      )
    )
    let sourceLeases = ViewerStoreLeaseRegistry()
    let sourceMaintenance = ViewerStoreMaintenance(
      pool: sourcePool,
      leases: sourceLeases,
      configuration: { .default }
    )
    _ = try sourceMaintenance.appendAnnotation(
      recordingID: sourceRecording.rowID,
      body: "round trip annotation",
      wallMilliseconds: 1_300
    )
    let exportURL = sourcePaths.directory.appendingPathComponent("round-trip.json")
    try ViewerStoreExportService(pool: sourcePool, leases: sourceLeases).export(
      recordingID: sourceRecording.rowID,
      to: exportURL
    )
    let document = try ViewerSessionImportDocument.open(
      exportURL,
      maximumFileBytes: 64 * 1_024 * 1_024,
      snapshotDirectory: sourcePaths.directory
    )

    let targetPaths = try makePaths()
    let targetPool = try ViewerSQLitePool(migrating: targetPaths)
    defer { targetPool.close() }
    let targetStore = ViewerEventStore(pool: targetPool, configuration: { .default })
    let targetRecording = try targetStore.beginRecording(
      wallMilliseconds: 9_000,
      monotonicNanoseconds: 9_000,
      reason: "round-trip-target"
    )
    let imported = try targetStore.replaceCurrentSession(
      recording: targetRecording,
      with: document
    )
    XCTAssertEqual(imported.deviceCount, 2)
    XCTAssertEqual(imported.eventCount, 2)
    XCTAssertEqual(imported.gapCount, 1)
    XCTAssertEqual(imported.annotationCount, 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM InstallationAliases", at: targetPaths), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: targetPaths), 2)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Events", at: targetPaths), 2)
    XCTAssertEqual(
      try scalar("SELECT COUNT(DISTINCT eventUUID) FROM Events", at: targetPaths),
      1
    )
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM GapVersions", at: targetPaths), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM AnnotationVersions", at: targetPaths), 1)
    let importedNumericContent: JSONValue = try targetPool.queryReader.run { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: "SELECT contentJSON FROM Events WHERE wireSequence=1 ORDER BY rowID LIMIT 1"
      )
      guard try statement.step() else { throw ViewerStoreError.corruptStore }
      return try JSONValue.decodeJSON(from: statement.data(at: 0))
    }
    XCTAssertEqual(
      importedNumericContent,
      .object(["decimal": .number(1), "exponent": .number(100)])
    )
    XCTAssertEqual(
      try scalar("SELECT COUNT(*) FROM DeviceSessionVersions WHERE state='closed'", at: targetPaths),
      2
    )
    XCTAssertEqual(
      try scalar(
        "SELECT COUNT(*) FROM InstallationAliases WHERE installationID='raw-installation-never-imported'",
        at: targetPaths
      ),
      0
    )

    let midImportCancellation = ViewerSessionImportCancellation()
    XCTAssertThrowsError(
      try targetStore.replaceCurrentSession(
        recording: targetRecording,
        with: document,
        cancellation: midImportCancellation,
        progress: { phase in
          if phase == .event { midImportCancellation.cancel() }
        }
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Events", at: targetPaths), 2)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: targetPaths), 2)
    XCTAssertEqual(targetStore.status().state, .available)

    let cancellation = ViewerSessionImportCancellation()
    cancellation.cancel()
    XCTAssertThrowsError(
      try targetStore.replaceCurrentSession(
        recording: targetRecording,
        with: document,
        cancellation: cancellation
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Events", at: targetPaths), 2)

    let symbolicLink = targetPaths.directory.appendingPathComponent("import-link.json")
    XCTAssertEqual(symlink(exportURL.path, symbolicLink.path), 0)
    XCTAssertThrowsError(
      try ViewerSessionImportDocument.open(
        symbolicLink,
        maximumFileBytes: 64 * 1_024 * 1_024,
        snapshotDirectory: targetPaths.directory
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .invalidPath)
    }
  }

  func testCompleteSessionImportAcceptsLegacyVersionOneDisclosureWarning() throws {
    let sourcePaths = try makePaths()
    let sourcePool = try ViewerSQLitePool(migrating: sourcePaths)
    defer { sourcePool.close() }
    let sourceStore = ViewerEventStore(pool: sourcePool, configuration: { .default })
    let sourceRecording = try sourceStore.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "legacy-disclosure-source"
    )
    let sourceDevice = try sourceStore.beginDeviceSession(
      recording: sourceRecording,
      installationID: "legacy-disclosure-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Legacy App"
    )
    _ = try sourceStore.appendEvent(
      makeObservation(
        recording: sourceRecording,
        device: sourceDevice,
        sequence: 1,
        value: "legacy-disclosure-event"
      )
    )

    let exportURL = sourcePaths.directory.appendingPathComponent("legacy-disclosure.json")
    try ViewerStoreExportService(
      pool: sourcePool,
      leases: ViewerStoreLeaseRegistry()
    ).export(recordingID: sourceRecording.rowID, to: exportURL)
    var root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: exportURL)) as? [String: Any]
    )
    var disclosure = try XCTUnwrap(root["disclosure"] as? [String: Any])
    disclosure["warning"] =
      "Event content can contain secrets, personal information, or identifying data."
    root["disclosure"] = disclosure
    try JSONSerialization.data(withJSONObject: root).write(to: exportURL, options: .atomic)

    let document = try ViewerSessionImportDocument.open(
      exportURL,
      maximumFileBytes: ViewerSessionTransferLimits.maximumFileBytes,
      snapshotDirectory: sourcePaths.directory
    )
    let targetPaths = try makePaths()
    let targetPool = try ViewerSQLitePool(migrating: targetPaths)
    defer { targetPool.close() }
    let targetStore = ViewerEventStore(pool: targetPool, configuration: { .default })
    let targetRecording = try targetStore.beginRecording(
      wallMilliseconds: 9_000,
      monotonicNanoseconds: 9_000,
      reason: "legacy-disclosure-target"
    )

    let result = try targetStore.replaceCurrentSession(
      recording: targetRecording,
      with: document
    )
    XCTAssertEqual(result.deviceCount, 1)
    XCTAssertEqual(result.eventCount, 1)
  }

  func testCompleteSessionRoundTripSupportsReconnectRowsBeyondConcurrentDeviceLimit() throws {
    let sourcePaths = try makePaths()
    let sourcePool = try ViewerSQLitePool(migrating: sourcePaths)
    defer { sourcePool.close() }
    let sourceStore = ViewerEventStore(pool: sourcePool, configuration: { .default })
    let sourceRecording = try sourceStore.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "reconnect-device-import-source"
    )
    for index in 0..<17 {
      _ = try sourceStore.beginDeviceSession(
        recording: sourceRecording,
        installationID: "reconnect-device-\(index)",
        wallMilliseconds: Int64(1_000 + index),
        monotonicNanoseconds: UInt64(2_000 + index),
        partialHistory: false,
        displayName: "Imported App \(index)"
      )
    }
    let exportURL = sourcePaths.directory.appendingPathComponent("seventeen-devices.json")
    try ViewerStoreExportService(pool: sourcePool, leases: ViewerStoreLeaseRegistry()).export(
      recordingID: sourceRecording.rowID,
      to: exportURL
    )

    let targetPaths = try makePaths()
    let targetPool = try ViewerSQLitePool(migrating: targetPaths)
    defer { targetPool.close() }
    let targetStore = ViewerEventStore(pool: targetPool, configuration: { .default })
    let targetRecording = try targetStore.beginRecording(
      wallMilliseconds: 9_000,
      monotonicNanoseconds: 9_000,
      reason: "oversized-device-import-target"
    )
    let targetDevice = try targetStore.beginDeviceSession(
      recording: targetRecording,
      installationID: "preserved-target-device",
      wallMilliseconds: 9_000,
      monotonicNanoseconds: 9_000,
      partialHistory: false,
      displayName: "Preserved App"
    )
    _ = try targetStore.appendEvent(
      makeObservation(
        recording: targetRecording,
        device: targetDevice,
        sequence: 1,
        value: "preserved"
      )
    )
    let document = try ViewerSessionImportDocument.open(
      exportURL,
      maximumFileBytes: 64 * 1_024 * 1_024,
      snapshotDirectory: targetPaths.directory
    )

    let result = try targetStore.replaceCurrentSession(
      recording: targetRecording,
      with: document
    )
    XCTAssertEqual(result.deviceCount, 17)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM DeviceSessions", at: targetPaths), 17)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Events", at: targetPaths), 0)
    XCTAssertEqual(targetStore.status().state, .available)
  }

  func testSessionImportCancellationInterruptsRootStructuralScan() throws {
    let paths = try makePaths()
    try FileManager.default.createDirectory(
      at: paths.directory,
      withIntermediateDirectories: true
    )
    let source = paths.directory.appendingPathComponent("large-root-scan.json")
    var bytes = Data("{".utf8)
    bytes.append(Data(repeating: UInt8(ascii: " "), count: 256 * 1_024))
    bytes.append(Data("}".utf8))
    try bytes.write(to: source, options: .atomic)
    let cancellation = ViewerSessionImportCancellation()

    XCTAssertThrowsError(
      try ViewerSessionImportDocument.open(
        source,
        maximumFileBytes: Int64(bytes.count + 1),
        snapshotDirectory: paths.directory,
        cancellation: cancellation,
        structuralScanProgress: { offset in
          if offset >= 64 * 1_024 { cancellation.cancel() }
        }
      )
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
  }

  func testSessionImportCancellationInterruptsSecondPassArrayWhitespace() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "second-pass-cancellation"
    )
    let exported = paths.directory.appendingPathComponent("second-pass-source.json")
    try ViewerStoreExportService(
      pool: pool,
      leases: ViewerStoreLeaseRegistry()
    ).export(recordingID: recording.rowID, to: exported)
    var bytes = try Data(contentsOf: exported)
    let emptyDevices = Data("\"devices\":[]".utf8)
    let range = try XCTUnwrap(bytes.range(of: emptyDevices))
    var expandedDevices = Data("\"devices\":[".utf8)
    expandedDevices.append(Data(repeating: UInt8(ascii: " "), count: 256 * 1_024))
    expandedDevices.append(UInt8(ascii: "]"))
    bytes.replaceSubrange(range, with: expandedDevices)
    try bytes.write(to: exported, options: .atomic)

    let cancellation = ViewerSessionImportCancellation()
    let document = try ViewerSessionImportDocument.open(
      exported,
      maximumFileBytes: Int64(bytes.count + 1),
      snapshotDirectory: paths.directory,
      cancellation: cancellation
    )
    cancellation.cancel()
    XCTAssertThrowsError(try document.forEachDevice { _ in }) { error in
      XCTAssertEqual(error as? ViewerStoreError, .cancelled)
    }
  }

  func testWorkLimitRejectionsDrainIngressAndLeaveClearReusable() async throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(
      pool: pool,
      configuration: { .default },
      maximumRetainedEventCount: 1,
      maximumRetainedGapCount: 1
    )
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "work-limit-drain"
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "work-limit-device",
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      partialHistory: false,
      displayName: "Work Limit Device"
    )
    let ingress = ViewerStoreIngress(store: store)
    let eventOutcomes = LockedViewerJournalOutcomes()
    let rejectedStructural = LockedViewerStoreErrors()
    ingress.setRejectedStructuralHandler { _, error in
      rejectedStructural.append(error)
    }

    XCTAssertEqual(
      ingress.admit(
        try makeObservation(recording: recording, device: device, sequence: 1, value: "first")
      ),
      .admitted
    )
    let initialFlushOutcome = await ingress.flush()
    XCTAssertEqual(initialFlushOutcome, .drained)
    XCTAssertEqual(
      ingress.admit(
        try makeObservation(recording: recording, device: device, sequence: 2, value: "rejected"),
        outcome: { eventOutcomes.append($0) }
      ),
      .admitted
    )
    let eventLimitFlushOutcome = await ingress.flush()
    XCTAssertEqual(eventLimitFlushOutcome, .drained)
    XCTAssertEqual(eventOutcomes.values, [.unavailable])

    XCTAssertEqual(
      ingress.admit(
        .gap(
          recording: recording,
          device: device,
          sequence: 1,
          reason: "firstGap",
          count: 1,
          firstWallMilliseconds: 1_000,
          lastWallMilliseconds: 1_000,
          directions: "appToViewer",
          firstWireSequence: 1,
          lastWireSequence: 1
        )
      ),
      .admitted
    )
    let gapLimitFlushOutcome = await ingress.flush()
    XCTAssertEqual(gapLimitFlushOutcome, .drained)
    XCTAssertEqual(
      ingress.admit(
        .gap(
          recording: recording,
          device: device,
          sequence: 2,
          reason: "rejectedGap",
          count: 1,
          firstWallMilliseconds: 2_000,
          lastWallMilliseconds: 2_000,
          directions: "appToViewer",
          firstWireSequence: 2,
          lastWireSequence: 2
        )
      ),
      .admitted
    )
    let clearFlushOutcome = await ingress.flush()
    XCTAssertEqual(clearFlushOutcome, .drained)
    XCTAssertEqual(rejectedStructural.values, [.workLimitExceeded])

    let clear = try store.clearCurrentSessionEvents(recording: recording)
    XCTAssertEqual(clear.deletedEventCount, 1)
    XCTAssertEqual(
      ingress.admit(
        try makeObservation(recording: recording, device: device, sequence: 3, value: "after-clear")
      ),
      .admitted
    )
    XCTAssertEqual(
      ingress.admit(
        .gap(
          recording: recording,
          device: device,
          sequence: 3,
          reason: "afterClearGap",
          count: 1,
          firstWallMilliseconds: 3_000,
          lastWallMilliseconds: 3_000,
          directions: "appToViewer",
          firstWireSequence: 3,
          lastWireSequence: 3
        )
      ),
      .admitted
    )
    let recoveryFlushOutcome = await ingress.flush()
    XCTAssertEqual(recoveryFlushOutcome, .drained)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Events", at: paths), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM GapVersions", at: paths), 1)
  }

  func testCompleteExportByteBudgetFailsEarlyAndPreservesDestination() throws {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: "bounded-complete-export"
    )
    let destination = paths.directory.appendingPathComponent("bounded-export.json")
    let original = Data("preserve-existing-destination".utf8)
    try original.write(to: destination)
    let exporter = ViewerStoreExportService(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      maximumCompleteFileBytes: 64
    )

    XCTAssertThrowsError(
      try exporter.export(recordingID: recording.rowID, to: destination)
    ) { error in
      XCTAssertEqual(error as? ViewerStoreError, .workLimitExceeded)
    }
    XCTAssertEqual(try Data(contentsOf: destination), original)
    let temporaryPrefix = ".\(destination.lastPathComponent)."
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: paths.directory.path)
        .contains { $0.hasPrefix(temporaryPrefix) && $0.hasSuffix(".tmp") }
    )
    XCTAssertTrue(
      ViewerStoreExplorerFailure.exportTooLarge.operatorMessage.contains("Clear unneeded Events")
    )
  }

  @MainActor
  private func makePreparedControllerExportFixture(
    operationExecutionGate: @escaping @Sendable () -> Void = {},
    operationCompletionGate: @escaping @Sendable () -> Void = {},
    reason: String
  ) async throws -> ViewerControllerExportFixture {
    let paths = try makePaths()
    let coordinator = try ViewerStoreCoordinator(paths: paths)
    let runtimeLogicalID = UUID()
    _ = try coordinator.services.eventStore.beginRecording(
      logicalID: runtimeLogicalID,
      wallMilliseconds: 1_000,
      monotonicNanoseconds: 2_000,
      reason: reason
    )
    let gateway = ViewerStoreExplorerGateway(
      operationExecutionGate: operationExecutionGate,
      operationCompletionGate: operationCompletionGate
    )
    gateway.install(coordinator)
    let controller = ViewerEventExplorerController(
      inputs: ViewerRuntimeExplorerInputs(
        runtimeLogicalID: runtimeLogicalID,
        storeGateway: gateway,
        liveObservations: ViewerLiveEventWindow(runtimeLogicalID: runtimeLogicalID)
      )
    )
    controller.start()
    for _ in 0..<2_000 {
      if controller.canManageSelectedRecording && controller.pendingCleanupWorkCount == 0 { break }
      await Task.yield()
    }
    guard controller.canManageSelectedRecording else {
      throw ViewerStoreExplorerFailure.unavailable
    }
    controller.prepareExport(.completeRecording)
    for _ in 0..<2_000 {
      if case .disclosure = controller.exportState, controller.pendingCleanupWorkCount == 0 {
        break
      }
      await Task.yield()
    }
    guard case .disclosure = controller.exportState else {
      throw ViewerStoreExplorerFailure.unavailable
    }
    return ViewerControllerExportFixture(
      paths: paths,
      coordinator: coordinator,
      gateway: gateway,
      controller: controller
    )
  }

  private func makePaths() throws -> ViewerStorePaths {
    let root = try makeTemporaryDirectory()
    let directory = root.appendingPathComponent("Store", isDirectory: true)
    return ViewerStorePaths(
      directory: directory,
      database: directory.appendingPathComponent("NearWire.sqlite")
    )
  }

  @MainActor
  private func waitUntilExplorerController(
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<20_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for the Event Explorer controller")
  }

  private func makePerformanceFixture(
    eventCount: Int,
    eventTypeSQL: String,
    contentSQL: String
  ) throws -> (pool: ViewerSQLitePool, scope: ViewerPerformanceStoreScope) {
    precondition((1...100_000).contains(eventCount))
    let pool = try ViewerSQLitePool(migrating: makePaths())
    do {
      let store = ViewerEventStore(pool: pool, configuration: { .default })
      let recording = try store.beginRecording(
        wallMilliseconds: 1,
        monotonicNanoseconds: 1,
        reason: "performance-test"
      )
      let device = try store.beginDeviceSession(
        recording: recording,
        installationID: "performance-test",
        wallMilliseconds: 1,
        monotonicNanoseconds: 1,
        partialHistory: false,
        displayName: "Performance Test"
      )
      let eventUpperRowID = try pool.writer.run { database in
        try ViewerSQLiteConnection.execute(
          """
          WITH digits(value) AS (
            VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)
          ), numbers(value) AS (
            SELECT a.value + 10*b.value + 100*c.value + 1000*d.value + 10000*e.value
            FROM digits a, digits b, digits c, digits d, digits e
            ORDER BY 1
            LIMIT \(eventCount)
          )
          INSERT INTO Events(
            recordingID, deviceSessionID, direction, wireSequence, eventUUID, eventType,
            contentJSON, createdWallMs, viewerWallMs, originMonotonicNs,
            viewerMonotonicNs, priority, ttlMs, schemaVersion, deterministicBytes,
            correlationEventUUID, replyToEventUUID, quotaBytes
          )
          SELECT
            \(recording.rowID),
            \(device.rowID),
            CASE WHEN value % 2 = 0 THEN 'appToViewer' ELSE 'viewerToApp' END,
            value,
            'performance-event-' || value,
            \(eventTypeSQL),
            \(contentSQL),
            value + 1,
            value + 1,
            value + 1,
            value + 1,
            'normal',
            60000,
            1,
            0,
            NULL,
            NULL,
            0
          FROM numbers
          ORDER BY value
          """,
          on: database
        )
        return try ViewerStoreSchema.scalarInt64(
          "SELECT COALESCE(MAX(rowID),0) FROM Events",
          database: database
        )
      }
      return (
        pool,
        try ViewerPerformanceStoreScope(
          storeGeneration: 1,
          recordingID: recording.rowID,
          deviceSessionID: device.rowID,
          lowerMonotonicNanoseconds: 0,
          upperMonotonicNanoseconds: Int64(eventCount + 1),
          eventUpperRowID: eventUpperRowID,
          gapUpperRowID: 0
        )
      )
    } catch {
      pool.close()
      throw error
    }
  }

  private func explorerResult<Value: Sendable>(
    _ description: String,
    submit:
      (@escaping @Sendable (Result<Value, ViewerStoreExplorerFailure>) -> Void) ->
      ViewerStoreExplorerOperationToken
  ) throws -> Result<Value, ViewerStoreExplorerFailure> {
    let result = LockedViewerExplorerResult<Value>()
    let finished = expectation(description: description)
    _ = submit {
      result.set($0)
      finished.fulfill()
    }
    wait(for: [finished], timeout: 2)
    return try XCTUnwrap(result.value)
  }

  private func explorerValue<Value: Sendable>(
    _ description: String,
    submit:
      (@escaping @Sendable (Result<Value, ViewerStoreExplorerFailure>) -> Void) ->
      ViewerStoreExplorerOperationToken
  ) throws -> Value {
    let result = try explorerResult(description, submit: submit)
    if case .failure(let failure) = result {
      XCTFail("\(description) failed with \(failure)")
    }
    return try result.get()
  }

  private func makeVersionOneStore(
    recordingLogicalID: String,
    legacyDeviceLogicalID: String? = nil
  ) throws -> ViewerStorePaths {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    defer { pool.close() }
    try pool.writer.run { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: """
          INSERT INTO Recordings(
            logicalID, startedWallMs, startedMonotonicNs, durableStartReason,
            quotaBytes, liveQuotaBytes
          ) VALUES(?1, 1, 1, 'migration-test', 0, 0)
          """
      )
      try statement.bind(recordingLogicalID, at: 1)
      _ = try statement.step()
      if let legacyDeviceLogicalID {
        let recordingID = sqlite3_last_insert_rowid(database)
        let alias = try ViewerSQLiteStatement(
          database: database,
          sql:
            "INSERT INTO InstallationAliases(recordingID, installationID, ordinal, quotaBytes) VALUES(?1, 'legacy-installation', 1, 0)"
        )
        try alias.bind(recordingID, at: 1)
        _ = try alias.step()
        let aliasID = sqlite3_last_insert_rowid(database)
        let device = try ViewerSQLiteStatement(
          database: database,
          sql:
            "INSERT INTO DeviceSessions(logicalID, recordingID, installationAliasID, connectionOrdinal, startedWallMs, startedMonotonicNs, quotaBytes) VALUES(?1, ?2, ?3, 1, 1, 1, 0)"
        )
        try device.bind(legacyDeviceLogicalID, at: 1)
        try device.bind(recordingID, at: 2)
        try device.bind(aliasID, at: 3)
        _ = try device.step()
        let deviceID = sqlite3_last_insert_rowid(database)
        let version = try ViewerSQLiteStatement(
          database: database,
          sql:
            "INSERT INTO DeviceSessionVersions(deviceSessionID, revision, createdWallMs, state, partialHistory, endedWallMs, endedMonotonicNs, quotaBytes) VALUES(?1, 1, 1, 'closed', 0, 2, 2, 0)"
        )
        try version.bind(deviceID, at: 1)
        _ = try version.step()
      }
      for name in ["EventCausalityLookup", "GapTimelineAllDevices", "GapTimelineByDevice"] {
        try ViewerSQLiteConnection.execute("DROP INDEX \(name)", on: database)
      }
      for name in [
        "RetainedEventCountInsert", "RetainedEventCountDelete", "RetainedGapCountInsert",
        "RetainedGapCountDelete", "RetainedAnnotationCountInsert",
        "RetainedAnnotationCountDelete",
      ] {
        try ViewerSQLiteConnection.execute("DROP TRIGGER \(name)", on: database)
      }
      try ViewerSQLiteConnection.execute(
        "DELETE FROM StoreMetadata WHERE key IN ('retainedEventCount','retainedGapCount','retainedAnnotationCount')",
        on: database
      )
      try ViewerSQLiteConnection.execute("PRAGMA user_version=1", on: database)
    }
    pool.close()
    return paths
  }

  private func makeVersionTwoStore(recordingLogicalID: String) throws -> ViewerStorePaths {
    let paths = try makePaths()
    let pool = try ViewerSQLitePool(migrating: paths)
    let store = ViewerEventStore(pool: pool, configuration: { .default })
    let recording = try store.beginRecording(
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      reason: recordingLogicalID
    )
    let device = try store.beginDeviceSession(
      recording: recording,
      installationID: "v2-installation",
      wallMilliseconds: 1,
      monotonicNanoseconds: 1,
      partialHistory: false,
      displayName: "V2 App"
    )
    _ = try store.appendEvent(
      makeObservation(recording: recording, device: device, sequence: 1, value: "v2")
    )
    try store.appendStructural(
      .gap(
        recording: recording,
        device: device,
        sequence: 1,
        reason: "v2-gap",
        count: 1,
        firstWallMilliseconds: 1,
        lastWallMilliseconds: 1,
        directions: "appToViewer",
        firstWireSequence: 1,
        lastWireSequence: 1
      )
    )
    _ = try ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default }
    ).appendAnnotation(recordingID: recording.rowID, body: "v2-note", wallMilliseconds: 1)
    pool.close()

    let writer = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    try writer.run { database in
      try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
      do {
        for name in [
          "RetainedEventCountInsert", "RetainedEventCountDelete", "RetainedGapCountInsert",
          "RetainedGapCountDelete", "RetainedAnnotationCountInsert",
          "RetainedAnnotationCountDelete",
        ] {
          try ViewerSQLiteConnection.execute("DROP TRIGGER \(name)", on: database)
        }
        try ViewerSQLiteConnection.execute(
          "DELETE FROM StoreMetadata WHERE key IN ('retainedEventCount','retainedGapCount','retainedAnnotationCount')",
          on: database
        )
        try ViewerSQLiteConnection.execute("PRAGMA user_version=2", on: database)
        try ViewerSQLiteConnection.execute("COMMIT", on: database)
      } catch {
        try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
        throw error
      }
    }
    writer.close()
    return paths
  }

  private func makeLargeVersionOneStore(
    recordingLogicalID: String,
    eventCount: Int,
    gapCount: Int
  ) throws -> ViewerStorePaths {
    precondition((0...100_000).contains(eventCount))
    precondition((0...10_000).contains(gapCount))
    let paths = try makeVersionOneStore(
      recordingLogicalID: recordingLogicalID,
      legacyDeviceLogicalID: "\(recordingLogicalID)-device"
    )
    let writer = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    do {
      try writer.run { database in
        try ViewerSQLiteConnection.execute("BEGIN IMMEDIATE", on: database)
        do {
          if eventCount > 0 {
            try ViewerSQLiteConnection.execute(
              """
              WITH digits(value) AS (
                VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)
              ), numbers(value) AS (
                SELECT a.value + 10*b.value + 100*c.value + 1000*d.value + 10000*e.value
                FROM digits a, digits b, digits c, digits d, digits e
                LIMIT \(eventCount)
              )
              INSERT INTO Events(
                recordingID, deviceSessionID, direction, wireSequence, eventUUID, eventType,
                contentJSON, createdWallMs, viewerWallMs, originMonotonicNs,
                viewerMonotonicNs, priority, ttlMs, schemaVersion, deterministicBytes,
                correlationEventUUID, replyToEventUUID, quotaBytes
              )
              SELECT
                (SELECT rowID FROM Recordings LIMIT 1),
                (SELECT rowID FROM DeviceSessions LIMIT 1),
                CASE WHEN value % 2 = 0 THEN 'appToViewer' ELSE 'viewerToApp' END,
                value,
                printf('00000000-0000-4000-8000-%012d', value),
                'fixture.migration',
                CAST('{"value":0}' AS BLOB),
                value + 1,
                value + 1,
                value + 1,
                value + 1,
                'normal',
                60000,
                1,
                11,
                NULL,
                NULL,
                0
              FROM numbers
              """,
              on: database
            )
          }
          if gapCount > 0 {
            try ViewerSQLiteConnection.execute(
              """
              WITH digits(value) AS (
                VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)
              ), numbers(value) AS (
                SELECT a.value + 10*b.value + 100*c.value + 1000*d.value
                FROM digits a, digits b, digits c, digits d
                LIMIT \(gapCount)
              )
              INSERT INTO GapVersions(
                recordingID, deviceSessionID, sequence, namespace, revision, createdWallMs,
                reason, firstViewerWallMs, lastViewerWallMs, directions,
                firstWireSequence, lastWireSequence, count, quotaBytes
              )
              SELECT
                (SELECT rowID FROM Recordings LIMIT 1),
                CASE WHEN value % 2 = 0 THEN (SELECT rowID FROM DeviceSessions LIMIT 1) ELSE NULL END,
                value,
                'coordinator',
                1,
                value + 1,
                'fixtureGap',
                value + 1,
                value + 1,
                'appToViewer',
                value,
                value,
                1,
                0
              FROM numbers
              """,
              on: database
            )
          }
          try ViewerSQLiteConnection.execute("COMMIT", on: database)
        } catch {
          try? ViewerSQLiteConnection.execute("ROLLBACK", on: database)
          throw error
        }
      }
    } catch {
      writer.close()
      throw error
    }
    writer.close()
    return paths
  }

  private func makePrivateTemporaryDirectory() throws -> URL {
    let url = try makeTemporaryDirectory()
    guard chmod(url.path, 0o700) == 0 else { throw ViewerStoreError.invalidPath }
    return url
  }

  private func sumStorageUnavailableGaps(at paths: ViewerStorePaths) throws -> Int64 {
    let reader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { reader.close() }
    return try reader.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64(
        "SELECT COALESCE(SUM(count), 0) FROM GapVersions WHERE reason='storageUnavailable'",
        database: $0
      )
    }
  }

  private func recordingStorageUnavailableGapCount(
    at paths: ViewerStorePaths,
    logicalID: UUID
  ) throws -> Int64 {
    let reader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { reader.close() }
    return try reader.run(budget: .query()) { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: """
          SELECT COALESCE(SUM(gap.count), 0)
          FROM GapVersions gap
          JOIN Recordings recording ON recording.rowID=gap.recordingID
          WHERE recording.logicalID=?1
            AND gap.deviceSessionID IS NULL
            AND gap.reason='storageUnavailable'
          """
      )
      try statement.bind(logicalID.uuidString.lowercased(), at: 1)
      guard try statement.step() else { return 0 }
      return statement.int64(at: 0)
    }
  }

  private func recordingStart(
    at paths: ViewerStorePaths,
    logicalID: UUID
  ) throws -> (wallMilliseconds: Int64, monotonicNanoseconds: Int64, reason: String) {
    let reader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { reader.close() }
    return try reader.run(budget: .query()) { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: """
          SELECT startedWallMs, startedMonotonicNs, durableStartReason
          FROM Recordings
          WHERE logicalID=?1
          """
      )
      try statement.bind(logicalID.uuidString.lowercased(), at: 1)
      guard try statement.step() else { throw ViewerStoreError.unavailable }
      return (
        statement.int64(at: 0),
        statement.int64(at: 1),
        statement.string(at: 2)
      )
    }
  }

  private func latestRecordingStateCount(
    at paths: ViewerStorePaths,
    state: String
  ) throws -> Int64 {
    let reader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { reader.close() }
    return try reader.run(budget: .query()) { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: """
          SELECT COUNT(*)
          FROM RecordingVersions version
          WHERE version.state=?1
            AND NOT EXISTS(
              SELECT 1 FROM RecordingVersions later
              WHERE later.recordingID=version.recordingID AND later.revision>version.revision
            )
          """
      )
      try statement.bind(state, at: 1)
      guard try statement.step() else { return 0 }
      return statement.int64(at: 0)
    }
  }

  private func latestRecordingStateCount(
    at paths: ViewerStorePaths,
    logicalID: UUID,
    state: String
  ) throws -> Int64 {
    let reader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { reader.close() }
    return try reader.run(budget: .query()) { database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: """
          SELECT COUNT(*)
          FROM Recordings recording
          JOIN RecordingVersions version ON version.recordingID=recording.rowID
          WHERE recording.logicalID=?1 AND version.state=?2
            AND NOT EXISTS(
              SELECT 1 FROM RecordingVersions later
              WHERE later.recordingID=version.recordingID AND later.revision>version.revision
            )
          """
      )
      try statement.bind(logicalID.uuidString.lowercased(), at: 1)
      try statement.bind(state, at: 2)
      guard try statement.step() else { return 0 }
      return statement.int64(at: 0)
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

  @MainActor
  private func waitUntilAsync(
    timeoutIterations: Int = 2_000,
    condition: @escaping () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<timeoutIterations {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  @MainActor
  private func waitForApplicationStatus(
    _ expected: ViewerApplicationModel.Status,
    in model: ViewerApplicationModel
  ) async {
    if model.status == expected { return }
    let reached = expectation(description: "Application model reached expected status")
    let observation = model.$status.sink { status in
      if status == expected { reached.fulfill() }
    }
    await fulfillment(of: [reached], timeout: 2)
    withExtendedLifetime(observation) {}
    XCTAssertEqual(model.status, expected)
  }

  private func makeObservation(
    recording: ViewerRecordingHandle,
    device: ViewerDeviceSessionHandle,
    sequence: UInt64,
    value: String,
    initialDisposition: ViewerStoredDisposition? = .consumerAccepted,
    causality: EventCausality = EventCausality(),
    direction: EventDirection = .appToViewer,
    viewerMonotonicNanoseconds: UInt64? = nil,
    viewerWallMilliseconds: Int64? = nil,
    eventID: EventID = EventID(),
    eventType: EventType? = nil,
    content: JSONValue? = nil,
    validationLimits: EventValidationLimits = .default
  ) throws -> ViewerPreparedEventObservation {
    let app = try EndpointID(rawValue: "app")
    let viewer = try EndpointID(rawValue: "viewer")
    let source =
      direction == .appToViewer
      ? EventEndpoint(role: .app, id: app)
      : EventEndpoint(role: .viewer, id: viewer)
    let target =
      direction == .appToViewer
      ? EventEndpoint(role: .viewer, id: viewer)
      : EventEndpoint(role: .app, id: app)
    let envelope = try EventEnvelope(
      id: eventID,
      type: eventType ?? EventType.user("test.metric"),
      content: content
        ?? .object([
          "message": .string(value),
          "payload": .array([.object(["value": .string(value)])]),
        ]),
      createdAt: Date(timeIntervalSince1970: 1),
      monotonicTimestampNanoseconds: sequence * 1_000,
      source: source,
      target: target,
      direction: direction,
      sessionEpoch: SessionEpoch(),
      sequence: EventSequence(sequence),
      priority: .normal,
      ttl: EventTTL(milliseconds: 60_000),
      causality: causality,
      limits: validationLimits
    )
    let record = try WireEventRecord(envelope: envelope, remainingTTLNanoseconds: 30_000_000_000)
    let received = try record.receiverEvent(
      receivedAtNanoseconds: viewerMonotonicNanoseconds ?? sequence * 2_000
    )
    return try ViewerPreparedEventObservation(
      recording: recording,
      device: device,
      envelope: received.envelope,
      viewerMonotonicNanoseconds: received.receivedAtNanoseconds,
      viewerWallMilliseconds: viewerWallMilliseconds,
      deterministicEventBytes: received.deterministicEncodedByteCount,
      initialDisposition: initialDisposition
    )
  }

  private func makeAdmissionContext(
    suffix: String,
    applicationVersion: String? = nil
  ) throws -> ViewerAdmissionSessionContext {
    let appID = try EndpointID(rawValue: "app-\(suffix)")
    let viewerID = try EndpointID(rawValue: "viewer-\(suffix)")
    let appHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .app,
      installationID: appID,
      applicationIdentifier: "com.example.\(suffix)",
      applicationVersion: applicationVersion
    )
    let viewerHello = try WireHello(
      productVersion: WireProductVersion("1.0"),
      role: .viewer,
      installationID: viewerID
    )
    return ViewerAdmissionSessionContext(
      connectionID: UUID(),
      appHello: appHello,
      viewerHello: viewerHello,
      negotiation: try WireNegotiator.negotiate(local: appHello, remote: viewerHello),
      receiveChunkBytes: 64 * 1_024
    )
  }

  private func makeRecoveryAwareMaintenance(
    pool: ViewerSQLitePool,
    relay: ViewerStoreStateRelay,
    completionGate: ViewerRecoveryCompletionGate? = nil
  ) -> ViewerStoreMaintenance {
    ViewerStoreMaintenance(
      pool: pool,
      leases: ViewerStoreLeaseRegistry(),
      configuration: { .default },
      storeStateReporter: { relay.reportFailure($0) },
      recoveryPermitProvider: { relay.prepareRecovery($0) },
      automaticAuthorizationProvider: {
        relay.issueMaintenanceAuthorization()
      },
      authorizationValidator: { try relay.validate($0) },
      recoveryValidator: { try relay.validate($0) },
      recoveryCompleter: {
        if let completionGate {
          try completionGate.complete($0)
        } else {
          try relay.completeRecovery($0)
        }
      }
    )
  }

  private func scalar(_ sql: String, at paths: ViewerStorePaths) throws -> Int64 {
    let connection = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    defer { connection.close() }
    return try connection.run(budget: .query()) {
      try ViewerStoreSchema.scalarInt64(sql, database: $0)
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("NearWireStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    temporaryDirectories.append(url)
    return url
  }

  private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }

  private func isRegularFileWithoutFollowingLinks(_ url: URL) throws -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw ViewerStoreError.invalidPath }
    return (info.st_mode & S_IFMT) == S_IFREG
  }
}

private final class LockedCapacity: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Int64?

  init(_ value: Int64?) { storage = value }

  var value: Int64? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
  }
}

private struct ViewerMigrationResourceSnapshot: Equatable, Sendable {
  let maximumPhysicalFootprintGrowthBytes: UInt64
  let maximumDatabaseAllocatedBytes: UInt64
  let maximumWALAllocatedBytes: UInt64
  let maximumTemporaryAllocatedBytes: UInt64
  let sampleCount: Int
}

private struct ViewerControllerExportFixture {
  let paths: ViewerStorePaths
  let coordinator: ViewerStoreCoordinator
  let gateway: ViewerStoreExplorerGateway
  let controller: ViewerEventExplorerController
}

private final class LockedViewerMigrationResources: @unchecked Sendable {
  private let lock = NSLock()
  private let paths: ViewerStorePaths
  private let temporaryDirectory: URL
  private let baselinePhysicalFootprintBytes: UInt64
  private var callbackCount = 0
  private var maximumPhysicalFootprintGrowthBytes: UInt64 = 0
  private var maximumDatabaseAllocatedBytes: UInt64 = 0
  private var maximumWALAllocatedBytes: UInt64 = 0
  private var maximumTemporaryAllocatedBytes: UInt64 = 0
  private var sampleCount = 0

  init(
    paths: ViewerStorePaths,
    temporaryDirectory: URL,
    baselinePhysicalFootprintBytes: UInt64
  ) {
    self.paths = paths
    self.temporaryDirectory = temporaryDirectory
    self.baselinePhysicalFootprintBytes = baselinePhysicalFootprintBytes
  }

  var snapshot: ViewerMigrationResourceSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return ViewerMigrationResourceSnapshot(
      maximumPhysicalFootprintGrowthBytes: maximumPhysicalFootprintGrowthBytes,
      maximumDatabaseAllocatedBytes: maximumDatabaseAllocatedBytes,
      maximumWALAllocatedBytes: maximumWALAllocatedBytes,
      maximumTemporaryAllocatedBytes: maximumTemporaryAllocatedBytes,
      sampleCount: sampleCount
    )
  }

  func sample(force: Bool = false) {
    lock.lock()
    callbackCount += 1
    let shouldSample = force || callbackCount % 32 == 1
    lock.unlock()
    guard shouldSample else { return }

    let physical = currentProcessPhysicalFootprintBytes() ?? baselinePhysicalFootprintBytes
    let physicalGrowth =
      physical > baselinePhysicalFootprintBytes ? physical - baselinePhysicalFootprintBytes : 0
    let database = allocatedBytes(at: paths.database)
    let wal = allocatedBytes(at: paths.wal)
    let temporary = allocatedDirectoryBytes(at: temporaryDirectory)

    lock.lock()
    maximumPhysicalFootprintGrowthBytes = max(
      maximumPhysicalFootprintGrowthBytes,
      physicalGrowth
    )
    maximumDatabaseAllocatedBytes = max(maximumDatabaseAllocatedBytes, database)
    maximumWALAllocatedBytes = max(maximumWALAllocatedBytes, wal)
    maximumTemporaryAllocatedBytes = max(maximumTemporaryAllocatedBytes, temporary)
    sampleCount += 1
    lock.unlock()
  }
}

private final class BlockingViewerMigrationProgressGate: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let continuation = DispatchSemaphore(value: 0)
  private var observesFirstIndex = false
  private var didBlock = false

  func observe(_ phase: ViewerStoreMigrationPhase) {
    lock.lock()
    observesFirstIndex = phase == .index(1)
    lock.unlock()
  }

  func checkpoint() {
    lock.lock()
    guard observesFirstIndex, !didBlock else {
      lock.unlock()
      return
    }
    didBlock = true
    lock.unlock()
    entered.signal()
    continuation.wait()
  }

  func waitUntilEntered() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() {
    continuation.signal()
  }
}

private func currentProcessPhysicalFootprintBytes() -> UInt64? {
  var information = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
  )
  let result = withUnsafeMutablePointer(to: &information) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
      task_info(
        mach_task_self_,
        task_flavor_t(TASK_VM_INFO),
        rebound,
        &count
      )
    }
  }
  return result == KERN_SUCCESS ? information.phys_footprint : nil
}

private func allocatedBytes(at url: URL) -> UInt64 {
  guard
    let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]),
    let value = values.fileAllocatedSize ?? values.fileSize,
    value >= 0
  else { return 0 }
  return UInt64(value)
}

private func allocatedDirectoryBytes(at directory: URL) -> UInt64 {
  guard
    let children = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    )
  else { return 0 }
  return children.reduce(0) { partial, child in
    let (sum, overflow) = partial.addingReportingOverflow(allocatedBytes(at: child))
    return overflow ? UInt64.max : sum
  }
}

private func openDescriptorPaths(under directory: URL) -> [String] {
  let prefix = directory.standardizedFileURL.path + "/"
  guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
    return []
  }
  return names.compactMap { name in
    guard let descriptor = Int32(name) else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
      nearwire_file_descriptor_path(descriptor, pointer.baseAddress)
    }
    guard result == 0 else { return nil }
    let path = String(cString: buffer)
    return path.hasPrefix(prefix) ? path : nil
  }.sorted()
}

private func sqliteTemporaryDirectoryValue() -> String? {
  nearwire_sqlite3_temp_directory().map { String(cString: $0) }
}

private final class LockedViewerStoreErrors: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ViewerStoreError?] = []

  var values: [ViewerStoreError?] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ value: ViewerStoreError?) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }
}

private final class LockedViewerJournalOutcomes: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ViewerEventJournalOutcome] = []

  var values: [ViewerEventJournalOutcome] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ value: ViewerEventJournalOutcome) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }
}

private final class LockedViewerImportPhase: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: ViewerSessionImportPhase?

  var value: ViewerSessionImportPhase? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func set(_ value: ViewerSessionImportPhase) {
    lock.lock()
    storage = value
    lock.unlock()
  }
}

private final class ArmedViewerStoreSignal: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var armed = false

  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  func observe() {
    lock.lock()
    let shouldSignal = armed
    armed = false
    lock.unlock()
    if shouldSignal { semaphore.signal() }
  }

  func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
  }
}

private final class LockedStorageConfiguration: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ViewerStorageConfiguration?

  var value: ViewerStorageConfiguration? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ value: ViewerStorageConfiguration) {
    lock.lock()
    stored = value
    lock.unlock()
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func increment() {
    lock.lock()
    stored += 1
    lock.unlock()
  }
}

private final class LockedViewerStoreChange: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ViewerStoreChangeSnapshot?

  var value: ViewerStoreChangeSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ value: ViewerStoreChangeSnapshot) {
    lock.lock()
    stored = value
    lock.unlock()
  }
}

private final class ManualViewerStoreScheduler: @unchecked Sendable {
  private struct Sleeper {
    let deadline: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var current: UInt64 = 0
  private var sleepers: [Sleeper] = []
  private var sleepHandler: (@Sendable () -> Void)?

  var value: ViewerAdmissionScheduler {
    ViewerAdmissionScheduler(
      now: { [weak self] in self?.now() ?? 0 },
      sleep: { [weak self] duration in
        guard let self else { throw CancellationError() }
        try await self.sleep(for: duration)
      }
    )
  }

  func onSleep(_ handler: @escaping @Sendable () -> Void) {
    lock.lock()
    sleepHandler = handler
    lock.unlock()
  }

  func advance(by duration: UInt64) {
    lock.lock()
    let (next, overflow) = current.addingReportingOverflow(duration)
    current = overflow ? UInt64.max : next
    let ready = sleepers.filter { $0.deadline <= current }
    sleepers.removeAll { $0.deadline <= current }
    lock.unlock()
    for sleeper in ready {
      sleeper.continuation.resume()
    }
  }

  private func now() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  private func sleep(for duration: UInt64) async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      let (deadline, overflow) = current.addingReportingOverflow(duration)
      sleepers.append(
        Sleeper(deadline: overflow ? UInt64.max : deadline, continuation: continuation))
      let handler = sleepHandler
      sleepHandler = nil
      lock.unlock()
      handler?()
    }
  }
}

private final class OneShotViewerStoreFault: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = false
  private var failures = 0

  var failureCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return failures
  }

  func failNext() {
    lock.lock()
    pending = true
    lock.unlock()
  }

  func check() throws {
    lock.lock()
    let shouldFail = pending
    pending = false
    if shouldFail { failures += 1 }
    lock.unlock()
    if shouldFail { throw ViewerStoreError.busy }
  }
}

private final class BlockingViewerStoreFailureGate: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var armed = false
  private var checks = 0

  var armedCheckCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return checks
  }

  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  func check() throws {
    lock.lock()
    guard armed else {
      lock.unlock()
      return
    }
    checks += 1
    let shouldBlock = checks == 1
    lock.unlock()
    guard shouldBlock else { return }
    entered.signal()
    _ = resume.wait(timeout: .now() + 5)
    throw ViewerStoreError.unavailable
  }

  func waitUntilEntered() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class ViewerRecoveryCompletionGate: @unchecked Sendable {
  private let relay: ViewerStoreStateRelay
  private let action: ViewerStoreRecoveryAction
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)

  init(relay: ViewerStoreStateRelay, action: ViewerStoreRecoveryAction) {
    self.relay = relay
    self.action = action
  }

  func complete(_ permit: ViewerStoreStateRelay.RecoveryPermit) throws {
    if permit.action == action {
      entered.signal()
      _ = resume.wait(timeout: .now() + 5)
    }
    try relay.completeRecovery(permit)
  }

  func waitUntilEntered() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class ViewerRecoveryPublicationGate: @unchecked Sendable {
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)

  func block() {
    entered.signal()
    _ = resume.wait(timeout: .now() + 5)
  }

  func waitUntilEntered() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class LockedViewerPoolConstructionEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [ViewerSQLitePool.ConstructionEvent] = []

  var value: [ViewerSQLitePool.ConstructionEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }

  func append(_ event: ViewerSQLitePool.ConstructionEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }
}

private final class LockedViewerMigrationPhases: @unchecked Sendable {
  private let lock = NSLock()
  private var phases: [ViewerStoreMigrationPhase] = []

  var value: [ViewerStoreMigrationPhase] {
    lock.lock()
    defer { lock.unlock() }
    return phases
  }

  func append(_ phase: ViewerStoreMigrationPhase) {
    lock.lock()
    phases.append(phase)
    lock.unlock()
  }
}

private final class LockedViewerExplorerResults: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<ViewerStoreChangeSnapshot, ViewerStoreExplorerFailure>] = []

  var failures: [ViewerStoreExplorerFailure] {
    lock.lock()
    defer { lock.unlock() }
    return results.compactMap {
      if case .failure(let failure) = $0 { return failure }
      return nil
    }
  }

  var successCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return results.reduce(into: 0) { count, result in
      if case .success = result { count += 1 }
    }
  }

  func append(_ result: Result<ViewerStoreChangeSnapshot, ViewerStoreExplorerFailure>) {
    lock.lock()
    results.append(result)
    lock.unlock()
  }
}

private final class LockedViewerExplorerResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, ViewerStoreExplorerFailure>?

  var value: Result<Value, ViewerStoreExplorerFailure>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }

  var failure: ViewerStoreExplorerFailure? {
    lock.lock()
    defer { lock.unlock() }
    guard case .failure(let failure) = result else { return nil }
    return failure
  }

  func set(_ result: Result<Value, ViewerStoreExplorerFailure>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }
}

private final class LockedPerformanceFreezeResult: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<ViewerPerformanceFrozenReceipt, ViewerPerformanceFreezeFailure>?

  var value: Result<ViewerPerformanceFrozenReceipt, ViewerPerformanceFreezeFailure>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }

  func set(
    _ result: Result<ViewerPerformanceFrozenReceipt, ViewerPerformanceFreezeFailure>
  ) {
    lock.lock()
    self.result = result
    lock.unlock()
  }
}

private final class ViewerPerformanceFreezeLiveSpy: ViewerLiveObservationProviding,
  @unchecked Sendable
{
  let runtimeLogicalID: UUID

  private let lock = NSLock()
  private let slice: ViewerPerformanceLiveSlice
  private let beforeReturn: (() throws -> Void)?
  private var connectionIDs: [UUID] = []

  init(
    slice: ViewerPerformanceLiveSlice,
    beforeReturn: (() throws -> Void)? = nil
  ) {
    runtimeLogicalID = slice.runtimeLogicalID
    self.slice = slice
    self.beforeReturn = beforeReturn
  }

  func freezePerformance(connectionID: UUID) throws -> ViewerPerformanceLiveSlice {
    lock.lock()
    connectionIDs.append(connectionID)
    lock.unlock()
    guard connectionID == slice.connectionID else {
      throw ViewerPerformanceStoreFailure.invalidScope
    }
    try beforeReturn?()
    return slice
  }

  func snapshot() -> ViewerLiveProjectionSnapshot {
    ViewerLiveProjectionSnapshot(
      runtimeLogicalID: runtimeLogicalID,
      generation: 0,
      events: [],
      sessions: [],
      gaps: ViewerLiveGapSnapshot(
        ingressOverflowCount: 0,
        windowOverflowCount: 0,
        residentConflictCount: 0,
        diagnosticLossCount: 0,
        storeUnavailableCount: 0,
        storeRecoveryCount: 0,
        storeUnavailable: false
      ),
      accountedEventBytes: 0
    )
  }

  func setRefreshHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
  func storeStateChanged(_ state: ViewerStoreStatus.State) {}
  func setPresentationPaused(_ paused: Bool) {}
  func durableRowBecameVisible(key: ViewerEventJournalKey, observationID: UUID) {}

  var frozenConnectionIDs: [UUID] {
    lock.lock()
    defer { lock.unlock() }
    return connectionIDs
  }
}

private final class DelayedViewerExportDestinationSelection: @unchecked Sendable {
  private let lock = NSLock()
  private var completion: (@Sendable (URL?) -> Void)?
  private var cancellationStorage = 0

  @MainActor
  func start(
    _ completion: @escaping @Sendable (URL?) -> Void
  ) -> ViewerExportDestinationSelectionCancellation {
    lock.lock()
    self.completion = completion
    lock.unlock()
    return { [weak self] in self?.noteCancellation() }
  }

  var hasCompletion: Bool {
    lock.lock()
    defer { lock.unlock() }
    return completion != nil
  }

  var cancellationCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancellationStorage
  }

  func respond(_ destination: URL?) {
    lock.lock()
    let completion = completion
    lock.unlock()
    completion?(destination)
  }

  private func noteCancellation() {
    lock.lock()
    cancellationStorage += 1
    lock.unlock()
  }
}

@MainActor
private final class WeakViewerEventExplorerReference {
  weak var value: ViewerEventExplorerController?

  init(_ value: ViewerEventExplorerController?) {
    self.value = value
  }
}

private final class LockedViewerCatalogPlans: @unchecked Sendable {
  private let lock = NSLock()
  private var plans: [ViewerCatalogPlanObservation] = []

  var value: [ViewerCatalogPlanObservation] {
    lock.lock()
    defer { lock.unlock() }
    return plans
  }

  func append(_ plan: ViewerCatalogPlanObservation) {
    lock.lock()
    plans.append(plan)
    lock.unlock()
  }
}

private final class LockedViewerDiagnosticPlans: @unchecked Sendable {
  private let lock = NSLock()
  private var plans: [ViewerDiagnosticPlanObservation] = []

  var value: [ViewerDiagnosticPlanObservation] {
    lock.lock()
    defer { lock.unlock() }
    return plans
  }

  func append(_ plan: ViewerDiagnosticPlanObservation) {
    lock.lock()
    plans.append(plan)
    lock.unlock()
  }
}

private final class BlockingViewerMigrationPhaseGate: @unchecked Sendable {
  private let lock = NSLock()
  private let blockingPhase: ViewerStoreMigrationPhase
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var armed = false

  init(blocking phase: ViewerStoreMigrationPhase) {
    blockingPhase = phase
  }

  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  func check(_ phase: ViewerStoreMigrationPhase) throws {
    lock.lock()
    let shouldBlock = armed && phase == blockingPhase
    if shouldBlock { armed = false }
    lock.unlock()
    guard shouldBlock else { return }
    entered.signal()
    _ = resume.wait(timeout: .now() + 5)
  }

  func waitUntilEntered() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class CountingViewerMigrationAuthorization: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  func claim() -> Bool {
    lock.lock()
    calls += 1
    let authorized = calls == 1
    lock.unlock()
    return authorized
  }
}

private final class CountingViewerDiskCapacity: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  func available(at _: URL) -> Int64? {
    lock.lock()
    calls += 1
    lock.unlock()
    return Int64.max
  }
}

private final class OneShotViewerMigrationPhaseFault: @unchecked Sendable {
  private let lock = NSLock()
  private let failingPhase: ViewerStoreMigrationPhase
  private var pending = true
  private var failures = 0

  init(failing phase: ViewerStoreMigrationPhase) {
    failingPhase = phase
  }

  var failureCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return failures
  }

  func check(_ phase: ViewerStoreMigrationPhase) throws {
    lock.lock()
    let shouldFail = pending && phase == failingPhase
    if shouldFail {
      pending = false
      failures += 1
    }
    lock.unlock()
    if shouldFail { throw ViewerStoreError.busy }
  }
}

private final class LockedViewerReopenResourceEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [ViewerStoreReopenResourceEvent] = []

  var value: [ViewerStoreReopenResourceEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }

  func append(_ event: ViewerStoreReopenResourceEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }
}

private final class LockedViewerCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func reset() {
    lock.lock()
    count = 0
    lock.unlock()
  }
}

private final class ViewerPerformanceTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UInt64]
  private var lastValue: UInt64

  init(_ values: [UInt64]) {
    precondition(!values.isEmpty)
    self.values = values
    lastValue = values[values.count - 1]
  }

  func now() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    guard !values.isEmpty else { return lastValue }
    let value = values.removeFirst()
    lastValue = value
    return value
  }
}

private final class ArmableViewerExecutionGate: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var armed = false
  private var blockingCall = 1
  private var calls = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  func arm(blockingCall: Int = 1) {
    precondition(blockingCall > 0)
    lock.lock()
    armed = true
    self.blockingCall = blockingCall
    calls = 0
    lock.unlock()
  }

  func run() {
    lock.lock()
    guard armed else {
      lock.unlock()
      return
    }
    calls += 1
    let shouldBlock = calls == blockingCall
    lock.unlock()
    if shouldBlock {
      entered.signal()
      _ = resume.wait(timeout: .now() + 5)
    }
  }

  func waitUntilBlocked() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func waitUntilBlockedAsync() async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        continuation.resume(returning: waitUntilBlocked())
      }
    }
  }

  func release() { resume.signal() }
}

private final class CountingViewerStoreFault: @unchecked Sendable {
  private let lock = NSLock()
  private var failing = false
  private var failures = 0

  var failedAttemptCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return failures
  }

  func failEveryAttempt() {
    lock.lock()
    failing = true
    failures = 0
    lock.unlock()
  }

  func succeedEveryAttempt() {
    lock.lock()
    failing = false
    lock.unlock()
  }

  func check() throws {
    lock.lock()
    let shouldFail = failing
    if shouldFail { failures += 1 }
    lock.unlock()
    if shouldFail { throw ViewerStoreError.busy }
  }
}

private final class ViewerMaintenanceMutationFault: @unchecked Sendable {
  private let phase: ViewerStoreMaintenance.MutationPhase
  private let error: ViewerStoreError

  init(
    _ phase: ViewerStoreMaintenance.MutationPhase,
    error: ViewerStoreError = .unavailable
  ) {
    self.phase = phase
    self.error = error
  }

  func check(_ candidate: ViewerStoreMaintenance.MutationPhase) throws {
    if candidate == phase { throw error }
  }
}

private final class BlockingViewerDiskGuard: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let resume = DispatchSemaphore(value: 0)
  private var armed = false
  private var blockedFirst = false
  private var concurrent = 0
  private var maximumConcurrent = 0

  var maximumConcurrentChecks: Int {
    lock.lock()
    defer { lock.unlock() }
    return maximumConcurrent
  }

  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  func availableCapacity() -> Int64? {
    lock.lock()
    guard armed else {
      lock.unlock()
      return Int64.max
    }
    concurrent += 1
    maximumConcurrent = max(maximumConcurrent, concurrent)
    let shouldBlock = !blockedFirst
    if shouldBlock { blockedFirst = true }
    lock.unlock()
    if shouldBlock {
      entered.signal()
      _ = resume.wait(timeout: .now() + 2)
    }
    lock.lock()
    concurrent -= 1
    lock.unlock()
    return Int64.max
  }

  func waitUntilBlocked() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 2)
  }

  func release() { resume.signal() }
}

private final class SequencedViewerCapacity: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int64]
  private var calls = 0

  init(_ values: [Int64]) { self.values = values }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  func next() -> Int64? {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    return values.isEmpty ? Int64.max : values.removeFirst()
  }
}

private final class ViewerExportCancellationBox: @unchecked Sendable {
  weak var exporter: ViewerStoreExportService?

  func cancel() { exporter?.cancel() }
}
