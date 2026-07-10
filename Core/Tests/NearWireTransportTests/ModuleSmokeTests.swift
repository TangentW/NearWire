import XCTest

@testable import NearWireTransport

final class NearWireTransportModuleSmokeTests: XCTestCase {
  func testModuleIsAvailable() {
    XCTAssertTrue(NearWireTransportModule.isAvailable)
  }
}
