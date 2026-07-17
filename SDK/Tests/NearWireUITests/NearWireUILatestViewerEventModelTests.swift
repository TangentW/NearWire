import XCTest

@testable import NearWire
@testable import NearWireUI

@MainActor
final class NearWireUILatestViewerEventModelTests: XCTestCase {
  func testConstructionIsIdleAndObservationRetainsOnlyLatestViewerEvent() async {
    let source = NearWireUIFakeEventSource()
    let model = NearWireUILatestViewerEventModel(source: source)
    XCTAssertEqual(source.subscriberCount, 0)
    XCTAssertNil(model.latest)

    model.startObserving()
    await NearWireUITestWait.until { source.subscriberCount == 1 }

    source.send(
      makeNearWireUIEvent(
        type: "app.ignored",
        content: .string("ignored"),
        direction: .appToViewer
      )
    )
    await Task.yield()
    XCTAssertNil(model.latest)

    source.send(
      makeNearWireUIEvent(
        type: "viewer.first",
        content: .object(["z": .integer(2), "a": .integer(1)])
      )
    )
    await NearWireUITestWait.until { model.latest?.type == "viewer.first" }
    XCTAssertEqual(model.latest?.contentSummary, #"{"a": 1, "z": 2}"#)

    source.send(
      makeNearWireUIEvent(type: "viewer.second", content: .array([.bool(true), .null]))
    )
    await NearWireUITestWait.until { model.latest?.type == "viewer.second" }
    XCTAssertEqual(model.latest?.contentSummary, "[true, null]")

    model.stopObserving()
    await NearWireUITestWait.until { source.subscriberCount == 0 }
    XCTAssertNil(model.latest)
    XCTAssertNil(model.displayedErrorMessage)
  }

  func testUIAndBusinessSubscriptionsReceiveSameEventIndependently() async throws {
    let source = NearWireUIFakeEventSource()
    let model = NearWireUILatestViewerEventModel(source: source)
    model.startObserving()
    var businessIterator = source.events.makeAsyncIterator()
    await NearWireUITestWait.until { source.subscriberCount == 2 }

    let event = makeNearWireUIEvent(type: "viewer.shared", content: .integer(42))
    source.send(event)

    let businessEvent = try await businessIterator.next()
    XCTAssertEqual(businessEvent, event)
    await NearWireUITestWait.until { model.latest?.type == "viewer.shared" }
    XCTAssertEqual(model.latest?.contentSummary, "42")

    model.stopObserving()
  }

  func testSummaryIsDeterministicEscapedAndUTF8Bounded() {
    let values = (0..<80).map { NearWireEventContent.string("value-\($0)-\n") }
    let content = NearWireEventContent.object([
      "large": .array(values),
      "quote\"": .string(String(repeating: "🐝", count: 2_000)),
    ])

    let first = NearWireUIEventSummaryFormatter.summary(content)
    let second = NearWireUIEventSummaryFormatter.summary(content)

    XCTAssertEqual(first, second)
    XCTAssertLessThanOrEqual(
      first.utf8.count,
      NearWireUIEventSummaryFormatter.maximumSummaryBytes
    )
    XCTAssertTrue(first.contains(#""large""#))
    XCTAssertTrue(first.contains(#""quote\"""#))
    XCTAssertTrue(first.hasSuffix("…"))
  }

  func testStreamFailureUsesFixedMessageAndDoesNotRetainContent() async {
    struct SecretError: Error, CustomStringConvertible {
      var description: String { "secret-viewer-content" }
    }

    let source = NearWireUIFakeEventSource()
    let model = NearWireUILatestViewerEventModel(source: source)
    model.startObserving()
    await NearWireUITestWait.until { source.subscriberCount == 1 }
    source.send(makeNearWireUIEvent(type: "viewer.before-failure"))
    await NearWireUITestWait.until { model.latest != nil }

    source.finish(throwing: SecretError())
    await NearWireUITestWait.until { model.displayedErrorMessage != nil }
    XCTAssertEqual(model.displayedErrorMessage, "Viewer Event observation stopped.")
    XCTAssertFalse(model.displayedErrorMessage?.contains("secret") == true)

    model.stopObserving()
    XCTAssertNil(model.latest)
  }
}
