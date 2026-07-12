import XCTest

@testable import NearWireUI

final class NearWireUIInputLimiterTests: XCTestCase {
  func testASCIIBoundaryRetainsAtMost64Bytes() {
    for count in [63, 64, 65] {
      let value = String(repeating: "a", count: count)
      let result = NearWireUIInputLimiter.limit(value)
      XCTAssertEqual(result.utf8.count, min(count, 64))
      XCTAssertEqual(result, String(value.prefix(64)))
    }
  }

  func testTwoThreeAndFourByteScalarsAreNeverSplit() {
    assertScalarBoundary(scalar: "é", width: 2)
    assertScalarBoundary(scalar: "\u{4E2D}", width: 3)
    assertScalarBoundary(scalar: "😀", width: 4)
  }

  func testDecomposedCombiningSequenceUsesScalarPrefixWithoutNormalization() {
    let sequence = "e\u{301}"
    let value = String(repeating: "a", count: 62) + sequence + "z"
    let result = NearWireUIInputLimiter.limit(value)
    XCTAssertEqual(
      Array(result.unicodeScalars), Array((String(repeating: "a", count: 62) + "e").unicodeScalars))
    XCTAssertEqual(result.utf8.count, 63)
    XCTAssertFalse(result.hasSuffix("z"))
  }

  func testJoinedEmojiStopsAtFirstScalarThatWouldExceedLimit() {
    let joined = "👩‍💻"
    let value = String(repeating: "a", count: 59) + joined + "suffix"
    let result = NearWireUIInputLimiter.limit(value)
    XCTAssertEqual(result, String(repeating: "a", count: 59) + "👩")
    XCTAssertEqual(result.utf8.count, 63)
    XCTAssertFalse(result.contains("💻"))
    XCTAssertFalse(result.contains("suffix"))
  }

  private func assertScalarBoundary(scalar: String, width: Int) {
    let exactPrefix = String(repeating: "a", count: 64 - width)
    let exact = NearWireUIInputLimiter.limit(exactPrefix + scalar + "z")
    XCTAssertEqual(exact, exactPrefix + scalar)
    XCTAssertEqual(exact.utf8.count, 64)

    let shortPrefix = String(repeating: "a", count: 65 - width)
    let short = NearWireUIInputLimiter.limit(shortPrefix + scalar + "z")
    XCTAssertEqual(short, shortPrefix)
    XCTAssertEqual(short.utf8.count, 65 - width)
    XCTAssertFalse(short.hasSuffix(scalar))
  }
}
