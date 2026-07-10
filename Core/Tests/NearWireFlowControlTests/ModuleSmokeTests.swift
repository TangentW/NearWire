import XCTest

@testable import NearWireFlowControl

final class NearWireFlowControlModuleSmokeTests: XCTestCase {
  func testModuleIsAvailable() {
    XCTAssertTrue(NearWireFlowControlModule.isAvailable)
  }
}
