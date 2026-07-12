import XCTest

@testable import NearWire
@testable import NearWireUI

final class NearWireUIPresentationTests: XCTestCase {
  func testEveryConnectionStateHasFixedSemanticPresentation() {
    let expected: [(NearWireState, String, String, Bool, NearWireUIStatusColor)] = [
      (.idle, "Not Connected", "antenna.radiowaves.left.and.right", false, .neutral),
      (.discovering, "Searching for Viewer", "magnifyingglass", true, .neutral),
      (.connecting, "Securing Connection", "lock", true, .neutral),
      (.connected, "Connected", "checkmark.circle.fill", false, .positive),
      (.reconnecting, "Reconnecting", "arrow.clockwise", true, .warning),
      (.disconnected, "Disconnected", "xmark.circle", false, .negative),
      (.shutdown, "Unavailable", "slash.circle", false, .negative),
    ]

    for (state, label, symbol, progress, color) in expected {
      let presentation = NearWireUIStatusPresentation.make(
        status: NearWireConnectionStatus(state: state)
      )
      XCTAssertEqual(presentation.label, label)
      XCTAssertEqual(presentation.symbolName, symbol)
      XCTAssertEqual(presentation.showsProgress, progress)
      XCTAssertEqual(presentation.color, color)
      XCTAssertFalse(presentation.hint.isEmpty)
    }
  }

  func testRetryAndSuspensionRemainVisibleInTextAndAccessibilityHint() {
    let retry = NearWireUIStatusPresentation.make(
      status: NearWireConnectionStatus(state: .reconnecting, reconnectAttempt: 3)
    )
    XCTAssertEqual(retry.secondaryText, "Attempt 3")

    let suspended = NearWireUIStatusPresentation.make(
      status: NearWireConnectionStatus(
        state: .reconnecting,
        reconnectAttempt: 4,
        isSuspended: true
      )
    )
    XCTAssertEqual(suspended.secondaryText, "Attempt 4 - Paused")
    XCTAssertEqual(suspended.accessibilityLabel, "Reconnecting, Attempt 4 - Paused")
    XCTAssertTrue(suspended.hint.contains("paused"))
    XCTAssertEqual(suspended.color, .warning)
  }

  func testEveryActionHasFixedLabelHintAndAvailability() {
    let actions: [NearWireUIActionPresentation] = [
      .connect(showsReset: false), .connect(showsReset: true), .cancel, .cancelling,
      .disconnecting, .disconnect,
    ]
    for action in actions {
      XCTAssertNotNil(action.primaryLabel)
      XCTAssertFalse(action.primaryHint?.isEmpty ?? true)
    }
    XCTAssertTrue(NearWireUIActionPresentation.connect(showsReset: true).showsReset)
    XCTAssertTrue(NearWireUIActionPresentation.cancel.isPrimaryEnabled)
    XCTAssertFalse(NearWireUIActionPresentation.cancelling.isPrimaryEnabled)
    XCTAssertFalse(NearWireUIActionPresentation.disconnecting.isPrimaryEnabled)
    XCTAssertNil(NearWireUIActionPresentation.none.primaryLabel)
  }

  func testUnknownFailureUsesContentSafeGenericMessage() {
    XCTAssertEqual(
      NearWireUIActionError.generic.message,
      "NearWire could not complete the connection action."
    )
    XCTAssertFalse(NearWireUIActionError.generic.offersReset)
  }
}
