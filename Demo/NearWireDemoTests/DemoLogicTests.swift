import XCTest

@testable import NearWireDemo

final class DemoLogicTests: XCTestCase {
  func testTextLimitUsesUTF8Bytes() {
    XCTAssertTrue(DemoTextLimit.accepts(String(repeating: "a", count: 512)))
    XCTAssertFalse(DemoTextLimit.accepts(String(repeating: "a", count: 513)))
    XCTAssertEqual(DemoTextLimit.truncated(String(repeating: "é", count: 300)).utf8.count, 512)
  }

  func testControlEvaluatorAcceptsOnlyValidViewerBanner() {
    XCTAssertEqual(
      DemoControlEvaluator.evaluate(
        type: DemoEventType.setBanner,
        direction: .viewerToApp,
        control: DemoBannerControl(banner: "Ready")
      ),
      .apply("Ready")
    )
    XCTAssertNotEqual(
      DemoControlEvaluator.evaluate(
        type: "demo.unknown",
        direction: .viewerToApp,
        control: DemoBannerControl(banner: "Ignored")
      ),
      .apply("Ignored")
    )
  }

  func testSummaryBufferKeepsNewestFiftyValues() {
    var buffer = DemoSummaryBuffer()
    for index in 0..<49 {
      buffer.append(
        DemoEventSummary(
          id: UUID(),
          createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
          type: "demo.\(index)",
          outcome: "Handled"
        )
      )
    }

    XCTAssertEqual(buffer.values.count, 49)

    buffer.append(
      DemoEventSummary(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: 49),
        type: "demo.49",
        outcome: "Handled"
      )
    )
    XCTAssertEqual(buffer.values.count, 50)

    buffer.append(
      DemoEventSummary(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: 50),
        type: "demo.50",
        outcome: "Handled"
      )
    )
    XCTAssertEqual(buffer.values.count, 50)
    XCTAssertEqual(buffer.values.first?.type, "demo.1")
    XCTAssertEqual(buffer.values.last?.type, "demo.50")
  }
}
