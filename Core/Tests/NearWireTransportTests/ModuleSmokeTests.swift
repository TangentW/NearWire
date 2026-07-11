import XCTest

@_spi(NearWireInternal) @testable import NearWireTransport

final class NearWireTransportModuleSmokeTests: XCTestCase {
  func testModuleIsAvailable() {
    XCTAssertTrue(NearWireTransportModule.isAvailable)
  }
}
