import Foundation

enum ViewerExplorerFailure: Error, Equatable, Sendable {
  case cancelled
  case unavailable
  case invalidRequest
  case busy
  case refineQuery
  case exportTooLarge
}

struct ViewerOperationToken: Hashable, Sendable {
  let operationID: UUID

  init(operationID: UUID = UUID()) {
    self.operationID = operationID
  }
}

enum ViewerQueryScalar: Equatable, Sendable {
  case string(String)
  case integer(Int64)
  case real(Double)
  case boolean(Bool)
  case null
}

enum ViewerEventPredicate: Equatable, Sendable {
  case eventTypeEquals(String)
  case eventTypeEqualsAny([String])
  case eventTypePrefix(String)
  case contentContains(String)
  case applicationIdentifiers([String])
  case applicationVersions([String])
  case direction(String)
  case directions([String])
  case priority(String)
  case priorities([String])
  case wallTime(from: Int64?, through: Int64?)
  case json(path: String, equals: ViewerQueryScalar)
  case jsonAny(path: String, equalsAny: [ViewerQueryScalar])
  case jsonExists(path: String)
  case jsonStringContains(path: String, value: String)
  case hasGap
  case hasDrop
  case hasTerminalDisposition
}

enum ViewerEventFilterRules {
  static func canonicalEventType(_ value: String) throws -> String {
    try validateEventTypeComponents(value, permitsTrailingDot: false)
  }

  static func canonicalEventTypePrefix(_ value: String) throws -> String {
    try validateEventTypeComponents(value, permitsTrailingDot: true)
  }

  static func normalizedSearchText(_ value: String, maximumBytes: Int) throws -> String {
    let normalized = value.precomposedStringWithCanonicalMapping
    guard !normalized.isEmpty, normalized.utf8.count <= maximumBytes else {
      throw ViewerExplorerScopeError.invalidFilter
    }
    guard normalized.unicodeScalars.allSatisfy({
      !CharacterSet.controlCharacters.contains($0)
    }) else {
      throw ViewerExplorerScopeError.invalidFilter
    }
    return normalized
  }

  private static func validateEventTypeComponents(
    _ value: String,
    permitsTrailingDot: Bool
  ) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 128,
      value.unicodeScalars.allSatisfy(\.isASCII)
    else { throw ViewerExplorerScopeError.invalidFilter }
    let segments = value.split(separator: ".", omittingEmptySubsequences: false)
    for (index, segment) in segments.enumerated() {
      if segment.isEmpty {
        guard permitsTrailingDot, index == segments.count - 1, value.utf8.count < 128 else {
          throw ViewerExplorerScopeError.invalidFilter
        }
        continue
      }
      guard let first = segment.utf8.first,
        (65...90).contains(first) || (97...122).contains(first),
        segment.utf8.dropFirst().allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            || $0 == 95 || $0 == 45
        })
      else { throw ViewerExplorerScopeError.invalidFilter }
    }
    return value
  }
}
