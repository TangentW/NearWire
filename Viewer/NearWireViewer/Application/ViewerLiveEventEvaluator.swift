import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

enum ViewerLiveEvaluationError: Error, Equatable, Sendable {
  case invalidRequest
}

enum ViewerJSONPathComponent: Equatable, Sendable {
  case key(String)
  case index(Int)
}

struct ViewerJSONPath: Equatable, Sendable {
  let rawValue: String
  let components: [ViewerJSONPathComponent]

  init(_ value: String) throws {
    let normalized = value.precomposedStringWithCanonicalMapping
    guard normalized.utf8.count <= 256, normalized.first == "$" else {
      throw ViewerLiveEvaluationError.invalidRequest
    }
    var parsed: [ViewerJSONPathComponent] = []
    var cursor = normalized.index(after: normalized.startIndex)
    while cursor < normalized.endIndex {
      guard parsed.count < 16 else { throw ViewerLiveEvaluationError.invalidRequest }
      if normalized[cursor] == "." {
        cursor = normalized.index(after: cursor)
        let start = cursor
        while cursor < normalized.endIndex {
          let scalar = normalized[cursor].unicodeScalars.first!
          if scalar == "." || scalar == "[" { break }
          guard
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
              || scalar == "_" || scalar == "-"
          else { throw ViewerLiveEvaluationError.invalidRequest }
          cursor = normalized.index(after: cursor)
        }
        guard start != cursor else { throw ViewerLiveEvaluationError.invalidRequest }
        parsed.append(.key(String(normalized[start..<cursor])))
      } else if normalized[cursor] == "[" {
        cursor = normalized.index(after: cursor)
        let start = cursor
        while cursor < normalized.endIndex, normalized[cursor].unicodeScalars.count == 1,
          (48...57).contains(normalized[cursor].unicodeScalars.first!.value)
        {
          cursor = normalized.index(after: cursor)
        }
        guard start != cursor, cursor < normalized.endIndex, normalized[cursor] == "]",
          let index = Int(normalized[start..<cursor])
        else { throw ViewerLiveEvaluationError.invalidRequest }
        parsed.append(.index(index))
        cursor = normalized.index(after: cursor)
      } else {
        throw ViewerLiveEvaluationError.invalidRequest
      }
    }
    rawValue = normalized
    components = parsed
  }
}

struct ViewerLiveDeviceScope: Equatable, Sendable {
  private enum Storage: Equatable, Sendable {
    case all
    case selected(Set<UUID>)
  }

  static let all = ViewerLiveDeviceScope(storage: .all)
  private let storage: Storage

  init(selectedConnectionIDs: [UUID]) throws {
    let values = Set(selectedConnectionIDs)
    guard (1...16).contains(selectedConnectionIDs.count),
      values.count == selectedConnectionIDs.count
    else { throw ViewerLiveEvaluationError.invalidRequest }
    storage = .selected(values)
  }

  private init(storage: Storage) { self.storage = storage }

  func contains(_ connectionID: UUID) -> Bool {
    switch storage {
    case .all: return true
    case .selected(let values): return values.contains(connectionID)
    }
  }
}

private enum ViewerLiveCompiledPredicate: Equatable, Sendable {
  case eventTypeEquals(String)
  case eventTypeEqualsAny(Set<String>)
  case eventTypePrefix(String)
  case contentContains(Data)
  case fullText
  case applicationIdentifiers([Data])
  case applicationVersions([Data])
  case directions(Set<EventDirection>)
  case priorities(Set<EventPriority>)
  case durableDeviceSessionIDs
  case wallTime(from: Int64?, through: Int64?)
  case json(path: ViewerJSONPath, equals: ViewerQueryScalar)
  case jsonAny(path: ViewerJSONPath, equalsAny: [ViewerQueryScalar])
  case jsonExists(path: ViewerJSONPath)
  case jsonStringContains(path: ViewerJSONPath, value: Data)
  case hasGap
  case hasDrop
  case hasTerminalDisposition

  static func compile(_ predicate: ViewerEventPredicate) throws -> ViewerLiveCompiledPredicate {
    do {
      _ = try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: [predicate])
      )
      switch predicate {
      case .eventTypeEquals(let value):
        return .eventTypeEquals(try ViewerEventQueryCompiler.canonicalEventType(value))
      case .eventTypeEqualsAny(let values):
        return .eventTypeEqualsAny(
          Set(try values.map(ViewerEventQueryCompiler.canonicalEventType))
        )
      case .eventTypePrefix(let value):
        return .eventTypePrefix(try ViewerEventQueryCompiler.canonicalEventTypePrefix(value))
      case .contentContains(let value):
        let normalized = try ViewerEventQueryCompiler.normalizedSearchText(
          value,
          maximumBytes: 512
        )
        return .contentContains(Data(normalized.utf8))
      case .fullText:
        return .fullText
      case .applicationIdentifiers(let values):
        return .applicationIdentifiers(
          try values.map {
            Data(
              try ViewerEventQueryCompiler.normalizedSearchText($0, maximumBytes: 512).utf8
            )
          }
        )
      case .applicationVersions(let values):
        return .applicationVersions(
          try values.map {
            Data(
              try ViewerEventQueryCompiler.normalizedSearchText($0, maximumBytes: 512).utf8
            )
          }
        )
      case .direction(let value):
        return .directions([try direction(value)])
      case .directions(let values):
        return .directions(Set(try values.map(direction)))
      case .priority(let value):
        return .priorities([try priority(value)])
      case .priorities(let values):
        return .priorities(Set(try values.map(priority)))
      case .deviceSessionIDs:
        return .durableDeviceSessionIDs
      case .wallTime(let from, let through):
        return .wallTime(from: from, through: through)
      case .json(let path, let scalar):
        return .json(path: try ViewerJSONPath(path), equals: try normalized(scalar))
      case .jsonAny(let path, let scalars):
        return .jsonAny(
          path: try ViewerJSONPath(path),
          equalsAny: try scalars.map(normalized)
        )
      case .jsonExists(let path):
        return .jsonExists(path: try ViewerJSONPath(path))
      case .jsonStringContains(let path, let value):
        let normalized = try ViewerEventQueryCompiler.normalizedSearchText(
          value,
          maximumBytes: 16 * 1_024
        )
        return .jsonStringContains(
          path: try ViewerJSONPath(path),
          value: Data(normalized.utf8)
        )
      case .hasGap:
        return .hasGap
      case .hasDrop:
        return .hasDrop
      case .hasTerminalDisposition:
        return .hasTerminalDisposition
      }
    } catch {
      throw ViewerLiveEvaluationError.invalidRequest
    }
  }

  private static func normalized(_ value: ViewerQueryScalar) throws -> ViewerQueryScalar {
    switch value {
    case .string(let string):
      return .string(
        try ViewerEventQueryCompiler.normalizedSearchText(
          string,
          maximumBytes: 16 * 1_024
        )
      )
    case .real(let number):
      guard number.isFinite else { throw ViewerLiveEvaluationError.invalidRequest }
      return value
    case .integer, .boolean, .null:
      return value
    }
  }

  private static func direction(_ value: String) throws -> EventDirection {
    switch value {
    case EventDirection.appToViewer.rawValue: return .appToViewer
    case EventDirection.viewerToApp.rawValue: return .viewerToApp
    default: throw ViewerLiveEvaluationError.invalidRequest
    }
  }

  private static func priority(_ value: String) throws -> EventPriority {
    guard let priority = EventPriority(rawValue: value) else {
      throw ViewerLiveEvaluationError.invalidRequest
    }
    return priority
  }
}

struct ViewerLiveEvaluationRequest: Sendable {
  let runtimeLogicalID: UUID
  let deviceScope: ViewerLiveDeviceScope
  fileprivate let predicates: [ViewerLiveCompiledPredicate]

  init(
    runtimeLogicalID: UUID,
    deviceScope: ViewerLiveDeviceScope = .all,
    predicates: [ViewerEventPredicate]
  ) throws {
    guard predicates.count <= 32 else { throw ViewerLiveEvaluationError.invalidRequest }
    self.runtimeLogicalID = runtimeLogicalID
    self.deviceScope = deviceScope
    self.predicates = try predicates.map(ViewerLiveCompiledPredicate.compile)
  }
}

enum ViewerLiveTransientExclusion: Equatable, Sendable {
  case fullTextRequiresRecordedData

  var guidance: String {
    switch self {
    case .fullTextRequiresRecordedData:
      return "Full-text search requires recorded data — transient rows excluded."
    }
  }
}

struct ViewerLiveEvaluationOutput: Equatable, Sendable {
  let snapshotGeneration: UInt64
  let matchedKeys: [ViewerEventJournalKey]
  let transientExclusion: ViewerLiveTransientExclusion?
  let predicateCheckCount: Int
  let jsonNodeVisitCount: Int
}

enum ViewerLiveEvaluationResult: Equatable, Sendable {
  case complete(ViewerLiveEvaluationOutput)
  case refineRequired
  case cancelled

  static let refineGuidance = "Refine the live filter to evaluate within bounded work."
}

struct ViewerLiveEventEvaluator: Sendable {
  static let maximumPredicateChecks = 16_384
  static let maximumJSONNodeVisits = 1_000_000
  static let deadlineNanoseconds: UInt64 = 100_000_000

  private let nowNanoseconds: @Sendable () -> UInt64

  init(
    nowNanoseconds: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    }
  ) {
    self.nowNanoseconds = nowNanoseconds
  }

  func evaluate(
    snapshot: ViewerLiveProjectionSnapshot,
    request: ViewerLiveEvaluationRequest,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) -> ViewerLiveEvaluationResult {
    guard snapshot.events.count <= ViewerLiveProjectionLimits.retainedCount,
      snapshot.accountedEventBytes <= ViewerLiveProjectionLimits.retainedBytes,
      snapshot.sessions.count <= ViewerLiveProjectionLimits.maximumSessions
    else { return .refineRequired }
    if request.predicates.contains(.fullText) {
      return .complete(
        ViewerLiveEvaluationOutput(
          snapshotGeneration: snapshot.generation,
          matchedKeys: [],
          transientExclusion: .fullTextRequiresRecordedData,
          predicateCheckCount: 0,
          jsonNodeVisitCount: 0
        )
      )
    }
    guard snapshot.runtimeLogicalID == request.runtimeLogicalID else {
      return .complete(
        ViewerLiveEvaluationOutput(
          snapshotGeneration: snapshot.generation,
          matchedKeys: [],
          transientExclusion: nil,
          predicateCheckCount: 0,
          jsonNodeVisitCount: 0
        )
      )
    }

    var work = Work(
      startedAt: nowNanoseconds(),
      nowNanoseconds: nowNanoseconds,
      isCancelled: isCancelled
    )
    var matchedKeys: [ViewerEventJournalKey] = []
    matchedKeys.reserveCapacity(snapshot.events.count)
    do {
      try work.checkpoint()
      for event in snapshot.events {
        try work.checkpoint()
        guard request.deviceScope.contains(event.observation.key.connectionID) else { continue }
        var matchesAll = true
        for predicate in request.predicates {
          try work.beginPredicate()
          if try !matches(predicate, event: event, work: &work) {
            matchesAll = false
            break
          }
        }
        if matchesAll { matchedKeys.append(event.observation.key) }
      }
    } catch Work.Stop.cancelled {
      return .cancelled
    } catch {
      return .refineRequired
    }
    return .complete(
      ViewerLiveEvaluationOutput(
        snapshotGeneration: snapshot.generation,
        matchedKeys: matchedKeys,
        transientExclusion: nil,
        predicateCheckCount: work.predicateCheckCount,
        jsonNodeVisitCount: work.jsonNodeVisitCount
      )
    )
  }

  private func matches(
    _ predicate: ViewerLiveCompiledPredicate,
    event: ViewerLiveEventSnapshot,
    work: inout Work
  ) throws -> Bool {
    let observation = event.observation
    switch predicate {
    case .eventTypeEquals(let value):
      return observation.envelope.type.rawValue == value
    case .eventTypeEqualsAny(let values):
      return values.contains(observation.envelope.type.rawValue)
    case .eventTypePrefix(let value):
      return observation.envelope.type.rawValue.hasPrefix(value)
    case .contentContains(let value):
      let result = observation.durableProjection.canonicalContent.range(of: value) != nil
      try work.checkpoint()
      return result
    case .fullText:
      return false
    case .applicationIdentifiers(let values):
      guard let value = observation.session.applicationIdentifier else { return false }
      return values.contains(Data(value.utf8))
    case .applicationVersions(let values):
      guard let value = observation.session.applicationVersion else { return false }
      return values.contains(Data(value.utf8))
    case .directions(let values):
      return values.contains(observation.key.direction)
    case .priorities(let values):
      return values.contains(observation.envelope.priority)
    case .durableDeviceSessionIDs:
      return false
    case .wallTime(let from, let through):
      if let from, observation.viewerWallMilliseconds < from { return false }
      if let through, observation.viewerWallMilliseconds > through { return false }
      return true
    case .json(let path, let scalar):
      guard
        let value = try jsonValue(
          at: path,
          in: observation.envelope.content,
          work: &work
        )
      else { return false }
      return scalarMatches(scalar, value: value)
    case .jsonAny(let path, let scalars):
      guard
        let value = try jsonValue(
          at: path,
          in: observation.envelope.content,
          work: &work
        )
      else { return false }
      return scalars.contains { scalarMatches($0, value: value) }
    case .jsonExists(let path):
      return try jsonValue(at: path, in: observation.envelope.content, work: &work) != nil
    case .jsonStringContains(let path, let needle):
      guard
        let value = try jsonValue(
          at: path,
          in: observation.envelope.content,
          work: &work
        ), case .string(let string) = value
      else { return false }
      let result = Data(string.utf8).range(of: needle) != nil
      try work.checkpoint()
      return result
    case .hasGap:
      return event.hasGap
    case .hasDrop:
      return event.hasDrop
    case .hasTerminalDisposition:
      let disposition =
        event.laterDisposition
        ?? event.observation.durableProjection.initialDisposition
      switch disposition {
      case .consumerAccepted, .expired, .overflowDisplaced, .sessionEnded:
        return true
      case .buffered, .transportAdmitted, nil:
        return false
      }
    }
  }

  private func jsonValue(
    at path: ViewerJSONPath,
    in root: JSONValue,
    work: inout Work
  ) throws -> JSONValue? {
    var current = root
    for component in path.components {
      try work.visitJSONNode()
      switch (component, current) {
      case (.key(let key), .object(let object)):
        guard let child = object[key] else { return nil }
        current = child
      case (.index(let index), .array(let values)):
        guard values.indices.contains(index) else { return nil }
        current = values[index]
      default:
        return nil
      }
    }
    return current
  }

  private func scalarMatches(_ scalar: ViewerQueryScalar, value: JSONValue) -> Bool {
    switch (scalar, value) {
    case (.null, .null): return true
    case (.string(let expected), .string(let actual)):
      return Data(expected.utf8) == Data(actual.utf8)
    case (.integer(let expected), .integer(let actual)): return expected == actual
    case (.real(let expected), .number(let actual)): return expected == actual
    case (.boolean(let expected), .bool(let actual)): return expected == actual
    default: return false
    }
  }

  private struct Work {
    enum Stop: Error {
      case cancelled
      case boundedWork
    }

    let startedAt: UInt64
    let nowNanoseconds: @Sendable () -> UInt64
    let isCancelled: @Sendable () -> Bool
    var predicateCheckCount = 0
    var jsonNodeVisitCount = 0

    mutating func beginPredicate() throws {
      guard predicateCheckCount < ViewerLiveEventEvaluator.maximumPredicateChecks else {
        throw Stop.boundedWork
      }
      predicateCheckCount += 1
      try checkpoint()
    }

    mutating func visitJSONNode() throws {
      guard jsonNodeVisitCount < ViewerLiveEventEvaluator.maximumJSONNodeVisits else {
        throw Stop.boundedWork
      }
      jsonNodeVisitCount += 1
      try checkpoint()
    }

    func checkpoint() throws {
      if isCancelled() { throw Stop.cancelled }
      let now = nowNanoseconds()
      guard now >= startedAt,
        now - startedAt < ViewerLiveEventEvaluator.deadlineNanoseconds
      else { throw Stop.boundedWork }
    }
  }
}

extension ViewerLiveEvaluationRequest: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerLiveEvaluationRequest(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerJSONPath: CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { "ViewerJSONPath(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerLiveDeviceScope: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerLiveDeviceScope(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerLiveEventEvaluator: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerLiveEventEvaluator(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerLiveEvaluationOutput: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerLiveEvaluationOutput(matches: \(matchedKeys.count), redacted)"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["matchCount": matchedKeys.count], displayStyle: .struct)
  }
}
