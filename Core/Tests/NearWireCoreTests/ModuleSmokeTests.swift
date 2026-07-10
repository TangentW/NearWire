import XCTest

@testable import NearWireCore

final class NearWireCoreModuleSmokeTests: XCTestCase {
  func testModuleIsAvailable() {
    XCTAssertTrue(NearWireCoreModule.isAvailable)
  }
}
