@_spi(NearWireInternal) import NearWireCore
import XCTest

@testable import NearWirePerformance

final class PerformanceMonitorTests: XCTestCase {
  func testRunWaitsOneIntervalSendsOneSnapshotAndStopsExactly() async throws {
    let clock = PerformanceManualClock()
    let collector = PerformanceFakeCollector(
      reading: PerformanceCollectedReading(
        process: PerformanceProcessReading(cpuPercent: 12.5, memoryFootprintBytes: 128),
        display: PerformanceDisplayReading(estimatedFramesPerSecond: 60),
        device: PerformanceDeviceReading(),
        transport: PerformanceTransportReading(uplinkQueueDepth: 0, droppedEventCount: 0)
      )
    )
    let recorder = PerformanceSnapshotRecorder()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(clock: clock, collector: collector, recorder: recorder)
    )

    try await monitor.start()
    let runningState = await monitor.currentState
    XCTAssertEqual(runningState, .running)
    let initialSnapshotCount = await recorder.snapshots.count
    XCTAssertEqual(initialSnapshotCount, 0)
    try await waitUntil("first sleep") { clock.waiterCount == 1 }

    clock.advanceNext()
    try await waitUntil("first snapshot") { await recorder.snapshots.count == 1 }
    let snapshots = await recorder.snapshots
    XCTAssertEqual(snapshots[0].sampleIntervalMilliseconds, 1_000)
    XCTAssertEqual(snapshots[0].process?.cpuPercent, 12.5)

    await monitor.stop()
    let stoppedState = await monitor.currentState
    XCTAssertEqual(stoppedState, .stopped)
    let stopCount = await collector.stopCount
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testSlowCollectionIsIncludedInNextHeaderWithoutCatchup() async throws {
    let trace = PerformanceLockedTrace()
    let clock = PerformanceManualClock()
    let recorder = PerformanceSnapshotRecorder()
    let collector = PerformanceFakeCollector(onSample: {
      trace.append("sample")
      if trace.values.count == 1 { clock.advance(by: .milliseconds(500)) }
    })
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(clock: clock, collector: collector, recorder: recorder)
    )

    try await monitor.start()
    try await waitUntil("first slow-collection sleep") { clock.waiterCount == 1 }
    clock.advanceNext()
    try await waitUntil("first slow-collection snapshot") { await recorder.snapshots.count == 1 }
    try await waitUntil("second slow-collection sleep") { clock.waiterCount == 1 }
    clock.advanceNext()
    try await waitUntil("second slow-collection snapshot") { await recorder.snapshots.count == 2 }

    let snapshots = await recorder.snapshots
    XCTAssertEqual(snapshots[0].sampleIntervalMilliseconds, 1_000)
    XCTAssertEqual(snapshots[1].sampleIntervalMilliseconds, 1_500)
    XCTAssertEqual(trace.values, ["sample", "sample"])
    await monitor.stop()
  }

  func testWallAndMonotonicSampleBoundariesAreCapturedBeforeCollectorReads() async throws {
    let trace = PerformanceLockedTrace()
    let clock = PerformanceManualClock()
    let collector = PerformanceFakeCollector(onSample: { trace.append("collector") })
    let recorder = PerformanceSnapshotRecorder()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: clock,
        collector: collector,
        recorder: recorder,
        wallClock: {
          trace.append("wallClock")
          return Date(timeIntervalSince1970: 1_700_000_000)
        }
      )
    )

    try await monitor.start()
    try await waitUntil("ordered sample sleep") { clock.waiterCount == 1 }
    clock.advanceNext()
    try await waitUntil("ordered sample") { await recorder.snapshots.count == 1 }

    XCTAssertEqual(trace.values, ["wallClock", "collector"])
    await monitor.stop()
  }

  func testStartWhileRunningIsIdempotent() async throws {
    let setupCount = PerformanceAsyncCounter()
    let collector = PerformanceFakeCollector()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: collector,
        recorder: PerformanceSnapshotRecorder(),
        makeCollector: { _, _ in
          await setupCount.increment()
          return collector
        }
      )
    )

    try await monitor.start()
    try await monitor.start()
    let finalSetupCount = await setupCount.value
    let runningState = await monitor.currentState
    XCTAssertEqual(finalSetupCount, 1)
    XCTAssertEqual(runningState, .running)

    await monitor.stop()
    let stopCount = await collector.stopCount
    XCTAssertEqual(stopCount, 1)
  }

  func testUnknownSetupFailureIsContentSafeAndReleasesLease() async {
    struct PrivateSetupError: Error {}

    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: PerformanceFakeCollector(),
        recorder: PerformanceSnapshotRecorder(),
        makeCollector: { _, _ in throw PrivateSetupError() }
      )
    )

    do {
      try await monitor.start()
      XCTFail("Expected setup failure.")
    } catch let error as NearWirePerformanceError {
      XCTAssertEqual(error.code, .collectorSetupFailed)
      XCTAssertEqual(error.field, nil)
      XCTAssertEqual(error.message, "The performance collector could not be prepared.")
      XCTAssertFalse(error.message.contains("PrivateSetupError"))
    } catch {
      XCTFail("Expected a typed performance error.")
    }

    let state = await monitor.currentState
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testPrecancelledStartClaimsNoLeaseOrCollector() async {
    let entryGate = PerformanceAsyncGate()
    let setupCount = PerformanceAsyncCounter()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: PerformanceFakeCollector(),
        recorder: PerformanceSnapshotRecorder(),
        makeCollector: { _, _ in
          await setupCount.increment()
          return PerformanceFakeCollector()
        }
      )
    )
    let start = Task { () -> Bool in
      await entryGate.wait()
      do {
        try await monitor.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }

    start.cancel()
    await entryGate.open()
    let wasCancelled = await start.value
    let finalSetupCount = await setupCount.value
    let state = await monitor.currentState
    XCTAssertTrue(wasCancelled)
    XCTAssertEqual(finalSetupCount, 0)
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testSubmissionFailureCleansBeforePublishingFailed() async throws {
    let clock = PerformanceManualClock()
    let collector = PerformanceFakeCollector()
    let recorder = PerformanceSnapshotRecorder()
    await recorder.fail(with: .eventSubmissionFailed)
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(clock: clock, collector: collector, recorder: recorder)
    )

    try await monitor.start()
    try await waitUntil("failure sleep") { clock.waiterCount == 1 }
    clock.advanceNext()
    try await waitUntil("failed state") {
      await monitor.currentState == .failed(.eventSubmissionFailed)
    }

    let stopCount = await collector.stopCount
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testSecondMonitorForExactAnchorFailsWithoutCollectorSetup() async throws {
    let anchor = PerformanceLeaseAnchor()
    let firstClock = PerformanceManualClock()
    let secondClock = PerformanceManualClock()
    let firstCollector = PerformanceFakeCollector()
    let secondCollector = PerformanceFakeCollector()
    let first = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: firstClock,
        collector: firstCollector,
        recorder: PerformanceSnapshotRecorder(),
        anchor: anchor
      )
    )
    let second = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: secondClock,
        collector: secondCollector,
        recorder: PerformanceSnapshotRecorder(),
        anchor: anchor
      )
    )

    try await first.start()
    do {
      try await second.start()
      XCTFail("Expected exact-instance monitor lease contention.")
    } catch let error as NearWirePerformanceError {
      XCTAssertEqual(error.code, .monitorAlreadyRunning)
    }
    let secondSampleCount = await secondCollector.sampleCount
    XCTAssertEqual(secondSampleCount, 0)
    await first.stop()
    try await second.start()
    await second.stop()
  }

  func testStateStreamsYieldCurrentAndCancelIndependently() async throws {
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: PerformanceFakeCollector(),
        recorder: PerformanceSnapshotRecorder()
      )
    )
    let first = monitor.states
    let second = monitor.states
    XCTAssertEqual(monitor.stateSubscriberCount, 2)
    let probe = PerformanceAsyncCounter()

    let firstTask = Task {
      var didReceive = false
      for await value in first {
        if !didReceive {
          XCTAssertEqual(value, .stopped)
          didReceive = true
          await probe.increment()
        }
        if Task.isCancelled { break }
      }
    }
    let secondTask = Task {
      var didReceive = false
      for await value in second {
        if !didReceive {
          XCTAssertEqual(value, .stopped)
          didReceive = true
          await probe.increment()
        }
        if Task.isCancelled { break }
      }
    }
    try await waitUntil("initial stream values") { await probe.value == 2 }
    firstTask.cancel()
    secondTask.cancel()
    _ = await firstTask.result
    _ = await secondTask.result
    try await waitUntil("stream termination") { monitor.stateSubscriberCount == 0 }
  }

  func testConcurrentStartsJoinOneSetupAttempt() async throws {
    let setupGate = PerformanceAsyncGate()
    let setupCount = PerformanceAsyncCounter()
    let collector = PerformanceFakeCollector()
    let runtime = makePerformanceRuntime(
      clock: PerformanceManualClock(),
      collector: collector,
      recorder: PerformanceSnapshotRecorder(),
      makeCollector: { _, _ in
        await setupCount.increment()
        await setupGate.wait()
        return collector
      }
    )
    let monitor = NearWirePerformanceMonitor(runtime: runtime)

    let first = Task { try await monitor.start() }
    try await waitUntil("first setup") { await setupCount.value == 1 }
    let second = Task { try await monitor.start() }
    try await waitUntil("both setup waiters") { await monitor.startingWaiterCount == 2 }
    let countBeforeRelease = await setupCount.value
    XCTAssertEqual(countBeforeRelease, 1)
    await setupGate.open()
    try await first.value
    try await second.value
    let runningState = await monitor.currentState
    XCTAssertEqual(runningState, .running)
    await monitor.stop()
  }

  func testCancellingOneStartingWaiterCancelsSharedAttemptForAllWaiters() async throws {
    let setupGate = PerformanceAsyncGate()
    let setupCount = PerformanceAsyncCounter()
    let collector = PerformanceFakeCollector()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: collector,
        recorder: PerformanceSnapshotRecorder(),
        makeCollector: { _, _ in
          await setupCount.increment()
          await setupGate.wait()
          return collector
        }
      )
    )

    let owner = Task { () -> Bool in
      do {
        try await monitor.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    try await waitUntil("shared setup owner") { await setupCount.value == 1 }
    let waiter = Task { () -> Bool in
      do {
        try await monitor.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    try await waitUntil("shared setup waiter") { await monitor.startingWaiterCount == 2 }
    waiter.cancel()
    await setupGate.open()

    let ownerWasCancelled = await owner.value
    let waiterWasCancelled = await waiter.value
    let stopCount = await collector.stopCount
    let state = await monitor.currentState
    XCTAssertTrue(ownerWasCancelled)
    XCTAssertTrue(waiterWasCancelled)
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testOwnedSetupTaskReceivesCooperativeCancellation() async throws {
    let setupCount = PerformanceAsyncCounter()
    let collector = PerformanceFakeCollector()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: collector,
        recorder: PerformanceSnapshotRecorder(),
        makeCollector: { _, _ in
          await setupCount.increment()
          try await Task.sleep(for: .seconds(60))
          return collector
        }
      )
    )
    let start = Task { () -> Bool in
      do {
        try await monitor.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }

    try await waitUntil("cooperative setup suspension") { await setupCount.value == 1 }
    start.cancel()

    let wasCancelled = await start.value
    let state = await monitor.currentState
    let activationCount = await collector.activationCount
    let stopCount = await collector.stopCount
    XCTAssertTrue(wasCancelled)
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(activationCount, 0)
    XCTAssertEqual(stopCount, 0)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testWaiterCancellationDominatesLateUnknownSetupError() async throws {
    struct PrivateLateError: Error {}

    let setupGate = PerformanceAsyncGate()
    let setupCount = PerformanceAsyncCounter()
    let collector = PerformanceFakeCollector()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: collector,
        recorder: PerformanceSnapshotRecorder(),
        makeCollector: { _, _ in
          await setupCount.increment()
          await setupGate.wait()
          throw PrivateLateError()
        }
      )
    )
    let owner = Task { () -> Bool in
      do {
        try await monitor.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    try await waitUntil("late-error setup") { await setupCount.value == 1 }
    let waiter = Task { () -> Bool in
      do {
        try await monitor.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    try await waitUntil("late-error waiter") { await monitor.startingWaiterCount == 2 }
    waiter.cancel()
    await setupGate.open()

    let ownerWasCancelled = await owner.value
    let waiterWasCancelled = await waiter.value
    let state = await monitor.currentState
    XCTAssertTrue(ownerWasCancelled)
    XCTAssertTrue(waiterWasCancelled)
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testFinalPrecommitCancellationCleansPreparedCollector() async throws {
    let commitGate = PerformanceAsyncGate()
    let commitCount = PerformanceAsyncCounter()
    let collector = PerformanceFakeCollector()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: collector,
        recorder: PerformanceSnapshotRecorder(),
        beforeSetupCommit: {
          await commitCount.increment()
          await commitGate.wait()
        }
      )
    )
    let start = Task { () -> Bool in
      do {
        try await monitor.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }

    try await waitUntil("precommit boundary") { await commitCount.value == 1 }
    start.cancel()
    await commitGate.open()

    let wasCancelled = await start.value
    let activationCount = await collector.activationCount
    let stopCount = await collector.stopCount
    let state = await monitor.currentState
    XCTAssertTrue(wasCancelled)
    XCTAssertEqual(activationCount, 0)
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testSlowSetupIsExcludedFromFirstHeaderAndCPUBaseline() async throws {
    let setupGate = PerformanceAsyncGate()
    let setupCount = PerformanceAsyncCounter()
    let cpuValues = PerformanceLockedSequence<Double?>([1, 3])
    let clock = PerformanceManualClock()
    let recorder = PerformanceSnapshotRecorder()
    let configuration = try NearWirePerformanceConfiguration(
      displayMetricsEnabled: false,
      deviceMetricsEnabled: false,
      transportMetricsEnabled: false
    )
    let monitor = NearWirePerformanceMonitor(
      configuration: configuration,
      runtime: makePerformanceRuntime(
        clock: clock,
        collector: PerformanceFakeCollector(),
        recorder: recorder,
        makeCollector: { configuration, _ in
          await setupCount.increment()
          await setupGate.wait()
          return LivePerformanceCollectorSession(
            configuration: configuration,
            platform: DisabledPerformancePlatformSession(),
            readCPUSeconds: { cpuValues.next() },
            readMemoryFootprint: { 128 },
            readTransport: { nil }
          )
        }
      )
    )
    let start = Task { try await monitor.start() }

    try await waitUntil("slow setup") { await setupCount.value == 1 }
    clock.advance(by: .seconds(5))
    await setupGate.open()
    try await start.value
    try await waitUntil("post-setup sleep") { clock.waiterCount == 1 }
    clock.advanceNext()
    try await waitUntil("post-setup snapshot") { await recorder.snapshots.count == 1 }

    let snapshot = await recorder.snapshots[0]
    XCTAssertEqual(snapshot.sampleIntervalMilliseconds, 1_000)
    XCTAssertEqual(snapshot.process?.cpuPercent, 200)
    await monitor.stop()
  }

  func testStopDuringSetupCancelsAndCleansBeforeReturning() async throws {
    let setupGate = PerformanceAsyncGate()
    let setupCount = PerformanceAsyncCounter()
    let collector = PerformanceFakeCollector()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: collector,
        recorder: PerformanceSnapshotRecorder(),
        makeCollector: { _, _ in
          await setupCount.increment()
          await setupGate.wait()
          return collector
        }
      )
    )

    let start = Task { () -> Bool in
      do {
        try await monitor.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    try await waitUntil("setup suspension") { await setupCount.value == 1 }
    let stop = Task { await monitor.stop() }
    try await waitUntil("setup stop barrier") { await monitor.isStoppingTowardStopped }
    await setupGate.open()

    let startWasCancelled = await start.value
    XCTAssertTrue(startWasCancelled)
    await stop.value
    let setupStopCount = await collector.stopCount
    let setupStoppedState = await monitor.currentState
    XCTAssertEqual(setupStopCount, 1)
    XCTAssertEqual(setupStoppedState, .stopped)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testStopDominatesLateTypedSetupFailure() async throws {
    let setupGate = PerformanceAsyncGate()
    let setupCount = PerformanceAsyncCounter()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: PerformanceFakeCollector(),
        recorder: PerformanceSnapshotRecorder(),
        makeCollector: { _, _ in
          await setupCount.increment()
          await setupGate.wait()
          throw NearWirePerformanceError.collectorSetupFailed
        }
      )
    )
    let start = Task { () -> Bool in
      do {
        try await monitor.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }

    try await waitUntil("late typed setup failure") { await setupCount.value == 1 }
    let stop = Task { await monitor.stop() }
    try await waitUntil("typed-error stop barrier") { await monitor.isStoppingTowardStopped }
    await setupGate.open()

    let startWasCancelled = await start.value
    await stop.value
    let state = await monitor.currentState
    XCTAssertTrue(startWasCancelled)
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testFailureCleanupReceiptPrecedesFailedAndStopCanOverride() async throws {
    let cleanupGate = PerformanceAsyncGate()
    let collector = PerformanceFakeCollector(stopGate: cleanupGate)
    let clock = PerformanceManualClock()
    let recorder = PerformanceSnapshotRecorder()
    await recorder.fail(with: .eventSubmissionFailed)
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(clock: clock, collector: collector, recorder: recorder)
    )

    try await monitor.start()
    try await waitUntil("failure sleep") { clock.waiterCount == 1 }
    clock.advanceNext()
    try await waitUntil("cleanup start") { await collector.stopStartedCount == 1 }
    let stateDuringFailureCleanup = await monitor.currentState
    XCTAssertEqual(stateDuringFailureCleanup, .running)

    let stop = Task { await monitor.stop() }
    try await waitUntil("failure cleanup override") { await monitor.isStoppingTowardStopped }
    let stateAfterStopJoined = await monitor.currentState
    XCTAssertEqual(stateAfterStopJoined, .running)
    await cleanupGate.open()
    await stop.value

    let finalState = await monitor.currentState
    let finalStopCount = await collector.stopCount
    XCTAssertEqual(finalState, .stopped)
    XCTAssertEqual(finalStopCount, 1)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testConcurrentStopsJoinOneCleanupAndIgnoreCallerCancellation() async throws {
    let cleanupGate = PerformanceAsyncGate()
    let collector = PerformanceFakeCollector(stopGate: cleanupGate)
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: collector,
        recorder: PerformanceSnapshotRecorder()
      )
    )

    try await monitor.start()
    let first = Task { await monitor.stop() }
    try await waitUntil("shared cleanup start") { await collector.stopStartedCount == 1 }
    let second = Task { await monitor.stop() }
    first.cancel()
    second.cancel()
    let startedCount = await collector.stopStartedCount
    XCTAssertEqual(startedCount, 1)

    await cleanupGate.open()
    await first.value
    await second.value
    let stopCount = await collector.stopCount
    let state = await monitor.currentState
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testStateStreamBuffersOnlyLatestTransitionAcrossRestart() async throws {
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: PerformanceFakeCollector(),
        recorder: PerformanceSnapshotRecorder()
      )
    )
    let stream = monitor.states

    try await monitor.start()
    await monitor.stop()
    try await monitor.start()

    var iterator = stream.makeAsyncIterator()
    let latest = await iterator.next()
    XCTAssertEqual(latest, .running)
    await monitor.stop()
  }

  func testStartDuringFailureCleanupWaitsThenOwnsFreshGeneration() async throws {
    let cleanupGate = PerformanceAsyncGate()
    let collector = PerformanceFakeCollector(stopGate: cleanupGate)
    let clock = PerformanceManualClock()
    let recorder = PerformanceSnapshotRecorder()
    await recorder.fail(with: .eventSubmissionFailed)
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(clock: clock, collector: collector, recorder: recorder)
    )

    try await monitor.start()
    try await waitUntil("failure sleep") { clock.waiterCount == 1 }
    clock.advanceNext()
    try await waitUntil("failure cleanup") { await collector.stopStartedCount == 1 }

    let restart = Task {
      try await monitor.start()
    }

    await cleanupGate.open()
    try await restart.value
    let state = await monitor.currentState
    XCTAssertEqual(state, .running)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 1)
    await monitor.stop()
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testCancelledStartDuringExplicitCleanupCreatesNoSuccessorResources() async throws {
    let cleanupGate = PerformanceAsyncGate()
    let collector = PerformanceFakeCollector(stopGate: cleanupGate)
    let clock = PerformanceManualClock()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: clock,
        collector: collector,
        recorder: PerformanceSnapshotRecorder()
      )
    )

    try await monitor.start()
    let stop = Task { await monitor.stop() }
    try await waitUntil("explicit cleanup start") { await collector.stopStartedCount == 1 }
    let restart = Task { () -> Bool in
      do {
        try await monitor.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    restart.cancel()

    await cleanupGate.open()
    await stop.value
    let restartWasCancelled = await restart.value
    XCTAssertTrue(restartWasCancelled)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)

    try await monitor.start()
    await monitor.stop()
  }

  func testStartDuringExplicitCleanupWaitsThenOwnsFreshGeneration() async throws {
    let cleanupGate = PerformanceAsyncGate()
    let collector = PerformanceFakeCollector(stopGate: cleanupGate)
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: collector,
        recorder: PerformanceSnapshotRecorder()
      )
    )

    try await monitor.start()
    let stop = Task { await monitor.stop() }
    try await waitUntil("explicit cleanup barrier") { await collector.stopStartedCount == 1 }
    let restart = Task { try await monitor.start() }

    await cleanupGate.open()
    await stop.value
    try await restart.value
    let state = await monitor.currentState
    let activationCount = await collector.activationCount
    XCTAssertEqual(state, .running)
    XCTAssertEqual(activationCount, 2)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 1)

    await monitor.stop()
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testExplicitStopRejectsLateNoncooperativeSubmissionFailure() async throws {
    let submissionGate = PerformanceAsyncGate()
    let submissionCount = PerformanceAsyncCounter()
    let clock = PerformanceManualClock()
    let collector = PerformanceFakeCollector()
    let monitor = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: clock,
        collector: collector,
        recorder: PerformanceSnapshotRecorder(),
        sendSnapshot: { _ in
          await submissionCount.increment()
          await submissionGate.wait()
          throw NearWirePerformanceError.eventSubmissionFailed
        }
      )
    )

    try await monitor.start()
    try await waitUntil("late-failure sleep") { clock.waiterCount == 1 }
    clock.advanceNext()
    try await waitUntil("noncooperative submission") { await submissionCount.value == 1 }
    let stop = Task { await monitor.stop() }
    try await waitUntil("submission stop barrier") { await monitor.isStoppingTowardStopped }
    await submissionGate.open()
    await stop.value

    let state = await monitor.currentState
    let stopCount = await collector.stopCount
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }

  func testDeinitializationCancelsRunFinishesStreamAndReleasesLease() async throws {
    let clock = PerformanceManualClock()
    let collector = PerformanceFakeCollector()
    var monitor: NearWirePerformanceMonitor? = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: clock,
        collector: collector,
        recorder: PerformanceSnapshotRecorder()
      )
    )
    let weakMonitor = PerformanceWeakBox(monitor)
    var states = monitor!.states.makeAsyncIterator()
    let initialState = await states.next()
    XCTAssertEqual(initialState, .stopped)
    try await monitor!.start()
    let runningState = await states.next()
    XCTAssertEqual(runningState, .running)
    try await waitUntil("deinit sleep") { clock.waiterCount == 1 }

    monitor = nil
    try await waitUntil("monitor deinit") { weakMonitor.value == nil }
    let terminalState = await states.next()
    XCTAssertNil(terminalState)
    try await waitUntil("deinit cleanup") {
      let stopCount = await collector.stopCount
      return PerformanceMonitorLeaseRegistry.activeCount == 0 && stopCount == 1
    }
  }

  func testCancelledStartingCallerDoesNotLeaveMonitorRetained() async throws {
    let setupCount = PerformanceAsyncCounter()
    let collector = PerformanceFakeCollector()
    var monitor: NearWirePerformanceMonitor? = NearWirePerformanceMonitor(
      runtime: makePerformanceRuntime(
        clock: PerformanceManualClock(),
        collector: collector,
        recorder: PerformanceSnapshotRecorder(),
        makeCollector: { _, _ in
          await setupCount.increment()
          try await Task.sleep(for: .seconds(60))
          return collector
        }
      )
    )
    let weakMonitor = PerformanceWeakBox(monitor)
    let start = Task { [monitor] () -> Bool in
      do {
        try await monitor!.start()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }

    try await waitUntil("retention setup suspension") { await setupCount.value == 1 }
    start.cancel()
    monitor = nil
    let wasCancelled = await start.value
    XCTAssertTrue(wasCancelled)
    try await waitUntil("starting monitor release") { weakMonitor.value == nil }
    XCTAssertEqual(PerformanceMonitorLeaseRegistry.activeCount, 0)
  }
}

extension PerformanceMonitorTests: @unchecked Sendable {}
