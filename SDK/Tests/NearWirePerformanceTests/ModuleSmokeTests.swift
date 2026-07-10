import XCTest

@testable import NearWirePerformance

final class NearWirePerformanceModuleSmokeTests: XCTestCase {
  func testModuleIsAvailable() {
    XCTAssertTrue(NearWirePerformanceModule.isAvailable)
  }
}
