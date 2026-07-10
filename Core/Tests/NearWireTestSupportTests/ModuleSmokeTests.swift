import XCTest

@testable import NearWireTestSupport

final class NearWireTestSupportModuleSmokeTests: XCTestCase {
  func testModuleIsAvailable() {
    XCTAssertTrue(NearWireTestSupportModule.isAvailable)
  }
}
