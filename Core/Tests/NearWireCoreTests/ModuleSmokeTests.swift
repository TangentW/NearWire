import XCTest

@_spi(NearWireInternal) @testable import NearWireCore

final class NearWireCoreModuleSmokeTests: XCTestCase {
  func testModuleIsAvailable() {
    XCTAssertTrue(NearWireCoreModule.isAvailable)
  }
}
