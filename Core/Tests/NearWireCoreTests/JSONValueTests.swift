import Foundation
import XCTest

@_spi(NearWireInternal) @testable import NearWireCore

final class JSONValueTests: XCTestCase {
  func testDefaultContentLimitIsExactlyOneMiB() throws {
    let exact = contentSized(at: 1_024 * 1_024)
    let oversized = contentSized(at: 1_024 * 1_024 + 1)

    XCTAssertEqual(try exact.deterministicData().count, 1_024 * 1_024)
    XCTAssertNoThrow(try exact.validate())
    assertEventError(.encodedContentTooLarge) {
      try oversized.validate()
    }
  }

  func testEveryJSONCaseRoundTripsDeterministically() throws {
    let data = Data(
      """
      {"z":null,"a":[true,false,-9223372036854775808,9223372036854775807,1.25,"text"]}
      """.utf8
    )

    let value = try JSONValue.decodeJSON(from: data)
    XCTAssertEqual(
      String(decoding: try value.deterministicData(), as: UTF8.self),
      "{\"a\":[true,false,-9223372036854775808,9223372036854775807,1.25,\"text\"],\"z\":null}"
    )
    XCTAssertEqual(try JSONValue.decodeJSON(from: value.deterministicData()), value)
  }

  func testIntegerAndFloatingPointIntentRemainDistinct() throws {
    XCTAssertEqual(try JSONValue.decodeJSON(from: Data("1".utf8)), .integer(1))
    XCTAssertEqual(try JSONValue.decodeJSON(from: Data("1.0".utf8)), .number(1))
    XCTAssertEqual(try JSONValue.decodeJSON(from: Data("1e2".utf8)), .number(100))
    XCTAssertEqual(
      try JSONValue.decodeJSON(from: JSONValue.number(1).deterministicData()),
      .number(1)
    )
  }

  func testTaggedCodableRoundTripPreservesNumericCases() throws {
    let value = JSONValue.object([
      "integer": .integer(Int64.max),
      "number": .number(1),
    ])
    let data = try JSONEncoder().encode(value)

    XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
  }

  func testContentCodecPropagatesCustomLimitsToNestedModels() throws {
    struct Payload: Codable, Equatable, Sendable {
      let ttl: EventTTL
    }

    let permissive = try EventValidationLimits(maximumTTLMilliseconds: 172_800_000)
    let payload = Payload(ttl: try EventTTL(milliseconds: 172_800_000, limits: permissive))
    let content = try EventContentCodec(limits: permissive).encode(payload)

    XCTAssertEqual(
      try EventContentCodec(limits: permissive).decode(Payload.self, from: content),
      payload
    )
    assertEventError(.contentDecodingFailed) {
      _ = try EventContentCodec().decode(Payload.self, from: content)
    }
  }

  func testInvalidNumbersFailWithoutProducingAValue() {
    for token in [
      "9223372036854775808",
      "-9223372036854775809",
      "18446744073709551616",
      "9999999999999999999999999999999999999999",
    ] {
      assertEventError(.integerOutOfRange) {
        _ = try JSONValue.decodeJSON(from: Data(token.utf8))
      }
    }
    XCTAssertEqual(
      try? JSONValue.decodeJSON(from: Data("18446744073709551616.0".utf8)),
      .number(18_446_744_073_709_551_616)
    )
    XCTAssertEqual(
      try? JSONValue.decodeJSON(from: Data("1e40".utf8)),
      .number(1e40)
    )
    assertEventError(.nonFiniteNumber) {
      try JSONValue.number(.infinity).validate()
    }
  }

  func testStructuralLimitsReportStablePaths() throws {
    let limits = try EventValidationLimits(
      maximumContentDepth: 2,
      maximumArrayEntries: 1,
      maximumObjectEntries: 1,
      maximumStringBytes: 2,
      maximumObjectKeyBytes: 2,
      maximumEncodedContentBytes: 16
    )

    assertEventError(.structuralLimitExceeded, expectedPath: "$[0][0]") {
      try JSONValue.array([.array([.integer(1)])]).validate(limits: limits)
    }
    assertEventError(.structuralLimitExceeded) {
      try JSONValue.array([.integer(1), .integer(2)]).validate(limits: limits)
    }
    assertEventError(.structuralLimitExceeded, expectedPath: "$") {
      try JSONValue.string("abc").validate(limits: limits)
    }
    assertEventError(.structuralLimitExceeded, expectedPath: "$[\"abc\"]") {
      try JSONValue.object(["abc": .null]).validate(limits: limits)
    }
    assertEventError(.encodedContentTooLarge) {
      try JSONValue.string("0123456789abcdef").validate(
        limits: EventValidationLimits(maximumEncodedContentBytes: 8)
      )
    }
    assertEventError(.encodedContentTooLarge) {
      _ = try JSONValue.decodeJSON(
        from: Data("        null".utf8),
        limits: EventValidationLimits(maximumEncodedContentBytes: 8)
      )
    }
    let deeplyNested =
      String(repeating: "[", count: 40) + "0"
      + String(repeating: "]", count: 40)
    assertEventError(.structuralLimitExceeded) {
      _ = try JSONValue.decodeJSON(from: Data(deeplyNested.utf8))
    }
  }

  func testInvalidValidationConfigurationsFail() {
    assertEventError(.invalidLimits, expectedPath: "maximumContentDepth") {
      _ = try EventValidationLimits(maximumContentDepth: 0)
    }
    assertEventError(.invalidLimits, expectedPath: "maximumTTLMilliseconds") {
      _ = try EventValidationLimits(maximumTTLMilliseconds: 0)
    }
    assertEventError(.invalidLimits, expectedPath: "maximumEncodedModelBytes") {
      _ = try EventValidationLimits(
        maximumEncodedContentBytes: 2_048,
        maximumEncodedModelBytes: 1_024
      )
    }
  }

  func testCodableBridgeUsesStableDateAndBase64() throws {
    struct Payload: Codable, Equatable, Sendable {
      let name: String
      let sampledAt: Date
      let bytes: Data
      let values: [Int]
    }

    let payload = Payload(
      name: "sample",
      sampledAt: Date(timeIntervalSince1970: 1_700_000_000.125),
      bytes: Data([0, 1, 2]),
      values: [3, 1, 2]
    )
    let codec = EventContentCodec()
    let content = try codec.encode(payload)
    let bytes = String(decoding: try content.deterministicData(), as: UTF8.self)

    XCTAssertTrue(bytes.contains("2023-11-14T22:13:20.125Z"))
    XCTAssertTrue(bytes.contains("AAEC"))
    XCTAssertEqual(try codec.decode(Payload.self, from: content), payload)
  }

  func testDecodeFailureDoesNotMutateOriginalContent() throws {
    struct Requested: Decodable { let count: Int }
    let content = JSONValue.object(["count": .string("not-an-integer")])
    let before = content

    assertEventError(.contentDecodingFailed) {
      _ = try EventContentCodec().decode(Requested.self, from: content)
    }
    XCTAssertEqual(content, before)
  }

  func testNonJSONCodableValueIsRejected() {
    struct Payload: Encodable, Sendable { let value: Double }
    assertEventError(.contentEncodingFailed) {
      _ = try EventContentCodec().encode(Payload(value: .nan))
    }
  }
}

private func contentSized(at targetBytes: Int) -> JSONValue {
  let maximumStringBytes = 65_536
  let stringCount = (targetBytes - 1 + maximumStringBytes + 2) / (maximumStringBytes + 3)
  var remainingStringBytes = targetBytes - (3 * stringCount + 1)
  let strings = (0..<stringCount).map { _ -> JSONValue in
    let count = min(maximumStringBytes, remainingStringBytes)
    remainingStringBytes -= count
    return .string(String(repeating: "x", count: count))
  }
  precondition(remainingStringBytes == 0)
  return .array(strings)
}
