import XCTest

@testable import NearWirePerformance
@testable import NearWireUI

@MainActor
final class NearWireUIPerformanceModelTests: XCTestCase {
  func testConstructionAndObservationDoNotStartCollection() async {
    let controller = NearWireUIFakePerformanceController()
    let model = NearWireUIPerformanceModel(controller: controller)

    XCTAssertEqual(controller.subscriberCount, 0)
    XCTAssertEqual(controller.startCallCount, 0)
    XCTAssertEqual(controller.stopCallCount, 0)

    model.startObserving()
    await NearWireUITestWait.until { controller.subscriberCount == 1 }

    XCTAssertEqual(controller.startCallCount, 0)
    XCTAssertEqual(controller.stopCallCount, 0)
    XCTAssertEqual(model.stateLabel, "Stopped")

    model.stopObserving()
    await NearWireUITestWait.until { controller.subscriberCount == 0 }
    XCTAssertEqual(controller.stopCallCount, 0)
  }

  func testExplicitToggleSerializesStartAndStopWithoutOwningTeardown() async {
    let controller = NearWireUIFakePerformanceController()
    let model = NearWireUIPerformanceModel(controller: controller)
    model.startObserving()
    await NearWireUITestWait.until { controller.subscriberCount == 1 }

    model.setEnabled(true)
    model.setEnabled(true)
    await NearWireUITestWait.until {
      controller.startCallCount == 1 && controller.pendingStartCount == 1
    }
    XCTAssertTrue(model.isEnabled)
    XCTAssertTrue(model.isOperationPending)
    XCTAssertEqual(model.stateLabel, "Starting")

    controller.finishNextStart()
    await NearWireUITestWait.until {
      model.state == .running && !model.isOperationPending
    }

    model.stopObserving()
    await NearWireUITestWait.until { controller.subscriberCount == 0 }
    XCTAssertEqual(controller.stopCallCount, 0)

    model.startObserving()
    await NearWireUITestWait.until { model.state == .running }
    model.setEnabled(false)
    model.setEnabled(false)
    await NearWireUITestWait.until {
      controller.stopCallCount == 1 && model.state == .stopped && !model.isOperationPending
    }
    model.stopObserving()
  }

  func testKnownAndUnknownStartErrorsRemainContentSafe() async {
    struct SecretError: Error, CustomStringConvertible {
      var description: String { "secret-performance-detail" }
    }

    let controller = NearWireUIFakePerformanceController()
    let model = NearWireUIPerformanceModel(controller: controller)
    model.startObserving()
    await NearWireUITestWait.until { controller.subscriberCount == 1 }

    controller.setStartError(NearWirePerformanceError.collectorSetupFailed)
    model.setEnabled(true)
    await NearWireUITestWait.until { model.displayedErrorMessage != nil }
    XCTAssertEqual(
      model.displayedErrorMessage,
      NearWirePerformanceError.collectorSetupFailed.message
    )

    controller.setStartError(SecretError())
    model.setEnabled(true)
    await NearWireUITestWait.until {
      model.displayedErrorMessage == "Performance collection could not start."
    }
    XCTAssertFalse(model.displayedErrorMessage?.contains("secret") == true)
    controller.sendState(.running)
    await NearWireUITestWait.until { model.displayedErrorMessage == nil }
    model.stopObserving()
  }
}
