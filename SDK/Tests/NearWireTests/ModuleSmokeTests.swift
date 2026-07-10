import XCTest

@testable import NearWire

final class NearWireModuleSmokeTests: XCTestCase {
  func testModuleIsAvailable() {
    XCTAssertTrue(NearWireModule.isAvailable)
  }
}
