import Foundation
import XCTest

@_spi(NearWireInternal) @testable import NearWireCore
@_spi(NearWireInternal) @testable import NearWireFlowControl

func makeTestEvent(
  _ number: Int,
  value: String? = nil,
  priority: EventPriority = .normal,
  ttlMilliseconds: UInt64 = 60_000,
  policy: EventQueuePolicy = .normal,
  bytes: Int = 1,
  enqueuedAt: UInt64 = 0
) throws -> PendingEvent<String> {
  let suffix = String(format: "%012d", number)
  return try PendingEvent(
    id: EventID(rawValue: "123e4567-e89b-12d3-a456-\(suffix)"),
    value: value ?? "event-\(number)",
    priority: priority,
    ttl: EventTTL(milliseconds: ttlMilliseconds),
    policy: policy,
    accountedByteCount: bytes,
    enqueuedAtNanoseconds: enqueuedAt
  )
}

func assertFlowError(
  _ code: FlowControlError.Code,
  file: StaticString = #filePath,
  line: UInt = #line,
  _ operation: () throws -> Void
) {
  XCTAssertThrowsError(try operation(), file: file, line: line) { error in
    guard let flowError = error as? FlowControlError else {
      return XCTFail("Expected FlowControlError, received \(error).", file: file, line: line)
    }
    XCTAssertEqual(flowError.code, code, file: file, line: line)
  }
}
