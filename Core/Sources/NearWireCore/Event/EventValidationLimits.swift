import Foundation

@_spi(NearWireInternal) public struct EventValidationLimits: Equatable, Sendable {
  public static let `default` = EventValidationLimits(
    unchecked: (
      maximumTypeBytes: 128,
      maximumContentDepth: 32,
      maximumArrayEntries: 4_096,
      maximumObjectEntries: 4_096,
      maximumStringBytes: 65_536,
      maximumObjectKeyBytes: 65_536,
      maximumEncodedContentBytes: 262_144,
      maximumEncodedModelBytes: 2_097_152,
      maximumTTLMilliseconds: 86_400_000
    ))

  public let maximumTypeBytes: Int
  public let maximumContentDepth: Int
  public let maximumArrayEntries: Int
  public let maximumObjectEntries: Int
  public let maximumStringBytes: Int
  public let maximumObjectKeyBytes: Int
  public let maximumEncodedContentBytes: Int
  public let maximumEncodedModelBytes: Int
  public let maximumTTLMilliseconds: UInt64

  public init(
    maximumTypeBytes: Int = 128,
    maximumContentDepth: Int = 32,
    maximumArrayEntries: Int = 4_096,
    maximumObjectEntries: Int = 4_096,
    maximumStringBytes: Int = 65_536,
    maximumObjectKeyBytes: Int = 65_536,
    maximumEncodedContentBytes: Int = 262_144,
    maximumEncodedModelBytes: Int = 2_097_152,
    maximumTTLMilliseconds: UInt64 = 86_400_000
  ) throws {
    let values = (
      maximumTypeBytes,
      maximumContentDepth,
      maximumArrayEntries,
      maximumObjectEntries,
      maximumStringBytes,
      maximumObjectKeyBytes,
      maximumEncodedContentBytes,
      maximumEncodedModelBytes,
      maximumTTLMilliseconds
    )
    try Self.validate(values)
    self.init(unchecked: values)
  }

  private init(
    unchecked values: (
      maximumTypeBytes: Int,
      maximumContentDepth: Int,
      maximumArrayEntries: Int,
      maximumObjectEntries: Int,
      maximumStringBytes: Int,
      maximumObjectKeyBytes: Int,
      maximumEncodedContentBytes: Int,
      maximumEncodedModelBytes: Int,
      maximumTTLMilliseconds: UInt64
    )
  ) {
    maximumTypeBytes = values.maximumTypeBytes
    maximumContentDepth = values.maximumContentDepth
    maximumArrayEntries = values.maximumArrayEntries
    maximumObjectEntries = values.maximumObjectEntries
    maximumStringBytes = values.maximumStringBytes
    maximumObjectKeyBytes = values.maximumObjectKeyBytes
    maximumEncodedContentBytes = values.maximumEncodedContentBytes
    maximumEncodedModelBytes = values.maximumEncodedModelBytes
    maximumTTLMilliseconds = values.maximumTTLMilliseconds
  }

  private static func validate(
    _ values: (
      maximumTypeBytes: Int,
      maximumContentDepth: Int,
      maximumArrayEntries: Int,
      maximumObjectEntries: Int,
      maximumStringBytes: Int,
      maximumObjectKeyBytes: Int,
      maximumEncodedContentBytes: Int,
      maximumEncodedModelBytes: Int,
      maximumTTLMilliseconds: UInt64
    )
  ) throws {
    let boundedIntegers: [(String, Int, ClosedRange<Int>)] = [
      ("maximumTypeBytes", values.maximumTypeBytes, 1...128),
      ("maximumContentDepth", values.maximumContentDepth, 1...128),
      ("maximumArrayEntries", values.maximumArrayEntries, 1...100_000),
      ("maximumObjectEntries", values.maximumObjectEntries, 1...100_000),
      ("maximumStringBytes", values.maximumStringBytes, 1...1_048_576),
      ("maximumObjectKeyBytes", values.maximumObjectKeyBytes, 1...1_048_576),
      ("maximumEncodedContentBytes", values.maximumEncodedContentBytes, 1...16_777_216),
      ("maximumEncodedModelBytes", values.maximumEncodedModelBytes, 1...134_217_728),
    ]

    for (name, value, range) in boundedIntegers where !range.contains(value) {
      throw EventModelError(
        code: .invalidLimits,
        path: name,
        message: "Expected a value in \(range.lowerBound)...\(range.upperBound)."
      )
    }

    let (expandedContentBytes, multiplyOverflow) = values.maximumEncodedContentBytes
      .multipliedReportingOverflow(by: 4)
    let (minimumModelBytes, addOverflow) = expandedContentBytes.addingReportingOverflow(65_536)
    guard !multiplyOverflow, !addOverflow,
      values.maximumEncodedModelBytes >= minimumModelBytes
    else {
      throw EventModelError(
        code: .invalidLimits,
        path: "maximumEncodedModelBytes",
        message: "Encoded model limit must cover compact tags and fixed envelope fields."
      )
    }

    guard (1...604_800_000).contains(values.maximumTTLMilliseconds) else {
      throw EventModelError(
        code: .invalidLimits,
        path: "maximumTTLMilliseconds",
        message: "Expected a value from 1 millisecond through 7 days."
      )
    }
  }
}
