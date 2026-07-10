import XCTest

@testable import NearWireUI

final class NearWireUIModuleSmokeTests: XCTestCase {
  func testModuleIsAvailable() {
    XCTAssertTrue(NearWireUIModule.isAvailable)
  }
}
