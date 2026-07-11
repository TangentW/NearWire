import Foundation
import XCTest

@_spi(NearWireInternal) @testable import NearWireCore

func assertEventError(
  _ expectedCode: EventModelError.Code,
  expectedPath: String? = nil,
  file: StaticString = #filePath,
  line: UInt = #line,
  _ operation: () throws -> Void
) {
  XCTAssertThrowsError(try operation(), file: file, line: line) { error in
    guard let eventError = error as? EventModelError else {
      return XCTFail("Expected EventModelError, received \(error).", file: file, line: line)
    }
    XCTAssertEqual(eventError.code, expectedCode, file: file, line: line)
    if let expectedPath {
      XCTAssertEqual(eventError.path, expectedPath, file: file, line: line)
    }
  }
}

func makeEndpoint(_ role: EndpointRole, id: String) throws -> EventEndpoint {
  EventEndpoint(role: role, id: try EndpointID(rawValue: id))
}
