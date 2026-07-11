import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireFlowControl
import XCTest

@testable import NearWire

final class NearWireBufferTests: XCTestCase {
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
