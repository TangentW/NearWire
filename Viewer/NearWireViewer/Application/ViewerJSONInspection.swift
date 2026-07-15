import Foundation
@_spi(NearWireInternal) import NearWireCore

enum ViewerJSONInspectionError: Error, Equatable, Sendable {
  case invalidJSON
  case invalidRequest
  case inputTooLarge
  case outputTooLarge
  case workLimitExceeded
  case deadlineExceeded
  case cancelled
}

enum ViewerJSONInspectionLimits {
  static let maximumCanonicalBytes = 16 * 1_024 * 1_024
  static let rawChunkBytes = 64 * 1_024
  static let maximumPrettyInputBytes = 1 * 1_024 * 1_024
  static let maximumPrettyOutputBytes = 2 * 1_024 * 1_024
  static let maximumTreeChildrenPerExpansion = 128
  static let maximumTreeNodes = 4_096
  static let maximumTreeDerivedTextBytes = 2 * 1_024 * 1_024
  static let maximumTreePreviewBytes = 256
  static let maximumFocusedAccessibilityBytes = 512
  static let deadlineNanoseconds: UInt64 = 100_000_000
}

struct ViewerInspectorEventMetadata: Equatable, Sendable {
  let eventUUID: String
  let eventType: String
  let deviceLogicalID: UUID
  let deviceAlias: String
  let connectionAlias: String
  let direction: String
  let wireSequence: UInt64
  let priority: String
  let createdWallMilliseconds: Int64
  let viewerWallMilliseconds: Int64
  let viewerMonotonicNanoseconds: UInt64
  let originMonotonicNanoseconds: UInt64
  let ttlMilliseconds: UInt64
  let schemaVersion: UInt16
  let disposition: String?
  let correlationEventUUID: String?
  let replyToEventUUID: String?
  let hasGap: Bool
  let hasDrop: Bool
  let hasPresentationConflict: Bool
  let sessionEnded: Bool
}

struct ViewerCanonicalEventDetailBuffer: Sendable {
  let metadata: ViewerInspectorEventMetadata
  let content: Data

  init(metadata: ViewerInspectorEventMetadata, content: Data) throws {
    guard content.count <= ViewerJSONInspectionLimits.maximumCanonicalBytes else {
      throw ViewerJSONInspectionError.inputTooLarge
    }
    self.metadata = metadata
    self.content = content
  }

  init(liveEvent: ViewerLiveEventSnapshot) throws {
    let observation = liveEvent.observation
    let content = observation.canonicalProjection.canonicalContent
    guard content.count <= ViewerJSONInspectionLimits.maximumCanonicalBytes else {
      throw ViewerJSONInspectionError.inputTooLarge
    }
    let metadata = ViewerInspectorEventMetadata(
      eventUUID: observation.envelope.id.rawValue,
      eventType: observation.envelope.type.rawValue,
      deviceLogicalID: observation.key.connectionID,
      deviceAlias: observation.session.installationAlias,
      connectionAlias: observation.key.connectionID.uuidString,
      direction: observation.envelope.direction.rawValue,
      wireSequence: observation.key.wireSequence,
      priority: observation.envelope.priority.rawValue,
      createdWallMilliseconds: observation.canonicalProjection.createdWallMilliseconds,
      viewerWallMilliseconds: observation.viewerWallMilliseconds,
      viewerMonotonicNanoseconds: observation.viewerMonotonicNanoseconds,
      originMonotonicNanoseconds: observation.envelope.monotonicTimestampNanoseconds,
      ttlMilliseconds: observation.envelope.ttl.milliseconds,
      schemaVersion: observation.envelope.schemaVersion.rawValue,
      disposition: liveEvent.laterDisposition?.rawValue
        ?? observation.canonicalProjection.initialDisposition?.rawValue,
      correlationEventUUID: observation.envelope.causality.correlationID?.rawValue,
      replyToEventUUID: observation.envelope.causality.replyTo?.rawValue,
      hasGap: liveEvent.hasGap,
      hasDrop: liveEvent.hasDrop,
      hasPresentationConflict: liveEvent.hasPresentationConflict,
      sessionEnded: liveEvent.sessionEnded
    )
    try self.init(metadata: metadata, content: content)
  }

  var contentByteCount: Int { content.count }
}

struct ViewerInspectionBudget: Sendable {
  private let startedAt: UInt64
  private let nowNanoseconds: @Sendable () -> UInt64
  private let isCancelled: @Sendable () -> Bool
  private let maximumScannedBytes: Int
  private(set) var scannedBytes = 0
  private var nextCheckpoint = 4_096

  init(
    maximumScannedBytes: Int,
    nowNanoseconds: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    },
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) {
    precondition(maximumScannedBytes >= 0)
    self.maximumScannedBytes = maximumScannedBytes
    self.nowNanoseconds = nowNanoseconds
    self.isCancelled = isCancelled
    startedAt = nowNanoseconds()
  }

  mutating func consume(_ count: Int) throws {
    guard count >= 0 else { throw ViewerJSONInspectionError.invalidRequest }
    let (next, overflow) = scannedBytes.addingReportingOverflow(count)
    guard !overflow, next <= maximumScannedBytes else {
      throw ViewerJSONInspectionError.workLimitExceeded
    }
    scannedBytes = next
    if scannedBytes == count || scannedBytes >= nextCheckpoint {
      try checkpoint()
      nextCheckpoint = scannedBytes > Int.max - 4_096 ? Int.max : scannedBytes + 4_096
    }
  }

  mutating func checkpoint() throws {
    if isCancelled() { throw ViewerJSONInspectionError.cancelled }
    let now = nowNanoseconds()
    guard now >= startedAt, now - startedAt < ViewerJSONInspectionLimits.deadlineNanoseconds else {
      throw ViewerJSONInspectionError.deadlineExceeded
    }
  }
}

struct ViewerRawJSONChunk: Equatable, Sendable {
  let index: Int
  let byteRange: Range<Int>
  let text: String
  let hasPrevious: Bool
  let hasNext: Bool

  var focusedAccessibilityText: String {
    ViewerStructuredTextEscaper.escape(
      text,
      maximumBytes: ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
    )
  }
}

enum ViewerRawJSONNavigator {
  static func chunk(
    at requestedIndex: Int,
    in buffer: ViewerCanonicalEventDetailBuffer
  ) throws -> ViewerRawJSONChunk {
    guard requestedIndex >= 0 else { throw ViewerJSONInspectionError.invalidRequest }
    let data = buffer.content
    var start = 0
    var index = 0
    while index < requestedIndex, start < data.count {
      start = nextBoundary(after: start, data: data)
      index += 1
    }
    guard index == requestedIndex, start < data.count || (data.isEmpty && requestedIndex == 0)
    else { throw ViewerJSONInspectionError.invalidRequest }
    let end = nextBoundary(after: start, data: data)
    let bytes = data.subdata(in: start..<end)
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw ViewerJSONInspectionError.invalidJSON
    }
    return ViewerRawJSONChunk(
      index: requestedIndex,
      byteRange: start..<end,
      text: text,
      hasPrevious: requestedIndex > 0,
      hasNext: end < data.count
    )
  }

  static func chunkCount(in buffer: ViewerCanonicalEventDetailBuffer) -> Int {
    let data = buffer.content
    if data.isEmpty { return 1 }
    var count = 0
    var start = 0
    while start < data.count {
      start = nextBoundary(after: start, data: data)
      count += 1
    }
    return count
  }

  private static func nextBoundary(after start: Int, data: Data) -> Int {
    guard start < data.count else { return data.count }
    var end = min(data.count, start + ViewerJSONInspectionLimits.rawChunkBytes)
    if end < data.count {
      while end > start, data[end] & 0xC0 == 0x80 { end -= 1 }
      if end == start {
        end = min(data.count, start + ViewerJSONInspectionLimits.rawChunkBytes)
        while end < data.count, data[end] & 0xC0 == 0x80 { end += 1 }
      }
    }
    return end
  }
}

enum ViewerJSONNodeKind: Equatable, Sendable {
  case object
  case array
  case string
  case number
  case boolean
  case null

  var hasChildren: Bool { self == .object || self == .array }
}

struct ViewerJSONValueRange: Equatable, Sendable {
  let kind: ViewerJSONNodeKind
  let keyRange: Range<Int>?
  let valueRange: Range<Int>
}

struct ViewerJSONChildPage: Equatable, Sendable {
  let values: [ViewerJSONValueRange]
  let nextOffset: Int?
  let scannedEntryCount: Int
}

struct ViewerJSONRangeScanner: Sendable {
  static let maximumRetainedChildren = 4_097

  private let data: Data
  private var budget: ViewerInspectionBudget

  init(data: Data, budget: ViewerInspectionBudget) {
    self.data = data
    self.budget = budget
  }

  mutating func root() throws -> ViewerJSONValueRange {
    var cursor = 0
    try skipWhitespace(&cursor)
    let value = try parseValue(&cursor, keyRange: nil, depth: 0)
    try skipWhitespace(&cursor)
    guard cursor == data.count else { throw ViewerJSONInspectionError.invalidJSON }
    return value
  }

  mutating func assumedValidatedRoot() throws -> ViewerJSONValueRange {
    var lower = 0
    try skipWhitespace(&lower)
    guard lower < data.count else { throw ViewerJSONInspectionError.invalidJSON }
    var upper = data.count
    while upper > lower, [0x20, 0x09, 0x0A, 0x0D].contains(data[upper - 1]) {
      upper -= 1
      try budget.consume(1)
    }
    let kind: ViewerJSONNodeKind
    switch byte(at: lower) {
    case 0x7B: kind = .object
    case 0x5B: kind = .array
    case 0x22: kind = .string
    case 0x74, 0x66: kind = .boolean
    case 0x6E: kind = .null
    default: kind = .number
    }
    return ViewerJSONValueRange(kind: kind, keyRange: nil, valueRange: lower..<upper)
  }

  mutating func children(
    of parent: ViewerJSONValueRange,
    offset: Int,
    limit: Int = ViewerJSONInspectionLimits.maximumTreeChildrenPerExpansion,
    maximumEntries: Int = Int.max
  ) throws -> ViewerJSONChildPage {
    guard offset >= 0, (1...Self.maximumRetainedChildren).contains(limit),
      maximumEntries > 0, parent.kind.hasChildren
    else { throw ViewerJSONInspectionError.invalidRequest }
    var cursor = parent.valueRange.lowerBound + 1
    var entryIndex = 0
    var retained: [ViewerJSONValueRange] = []
    retained.reserveCapacity(limit)
    while cursor < parent.valueRange.upperBound - 1 {
      try skipWhitespace(&cursor)
      if parent.kind == .object, byte(at: cursor) == 0x7D { break }
      if parent.kind == .array, byte(at: cursor) == 0x5D { break }
      guard entryIndex < maximumEntries else {
        throw ViewerJSONInspectionError.workLimitExceeded
      }
      let keyRange: Range<Int>?
      if parent.kind == .object {
        let keyStart = cursor
        try parseString(&cursor)
        keyRange = keyStart..<cursor
        try skipWhitespace(&cursor)
        guard try take(&cursor) == 0x3A else { throw ViewerJSONInspectionError.invalidJSON }
        try skipWhitespace(&cursor)
      } else {
        keyRange = nil
      }
      let value = try parseValue(&cursor, keyRange: keyRange, depth: 0)
      if entryIndex >= offset {
        retained.append(value)
      }
      entryIndex += 1
      try skipWhitespace(&cursor)
      let terminal = parent.kind == .object ? UInt8(0x7D) : UInt8(0x5D)
      if byte(at: cursor) == terminal { break }
      guard try take(&cursor) == 0x2C else { throw ViewerJSONInspectionError.invalidJSON }
      if retained.count == limit {
        return ViewerJSONChildPage(
          values: retained,
          nextOffset: entryIndex,
          scannedEntryCount: entryIndex
        )
      }
    }
    return ViewerJSONChildPage(
      values: retained,
      nextOffset: nil,
      scannedEntryCount: entryIndex
    )
  }

  private mutating func parseValue(
    _ cursor: inout Int,
    keyRange: Range<Int>?,
    depth: Int
  ) throws -> ViewerJSONValueRange {
    guard depth <= 128, cursor < data.count else {
      throw ViewerJSONInspectionError.invalidJSON
    }
    let start = cursor
    let kind: ViewerJSONNodeKind
    switch byte(at: cursor) {
    case 0x7B:
      kind = .object
      try parseContainer(&cursor, opening: 0x7B, closing: 0x7D, depth: depth)
    case 0x5B:
      kind = .array
      try parseContainer(&cursor, opening: 0x5B, closing: 0x5D, depth: depth)
    case 0x22:
      kind = .string
      try parseString(&cursor)
    case 0x74:
      kind = .boolean
      try parseLiteral(&cursor, bytes: [0x74, 0x72, 0x75, 0x65])
    case 0x66:
      kind = .boolean
      try parseLiteral(&cursor, bytes: [0x66, 0x61, 0x6C, 0x73, 0x65])
    case 0x6E:
      kind = .null
      try parseLiteral(&cursor, bytes: [0x6E, 0x75, 0x6C, 0x6C])
    default:
      kind = .number
      try parseNumber(&cursor)
    }
    return ViewerJSONValueRange(kind: kind, keyRange: keyRange, valueRange: start..<cursor)
  }

  private mutating func parseContainer(
    _ cursor: inout Int,
    opening: UInt8,
    closing: UInt8,
    depth: Int
  ) throws {
    guard try take(&cursor) == opening else { throw ViewerJSONInspectionError.invalidJSON }
    try skipWhitespace(&cursor)
    if byte(at: cursor) == closing {
      cursor += 1
      try budget.consume(1)
      return
    }
    while cursor < data.count {
      if opening == 0x7B {
        try parseString(&cursor)
        try skipWhitespace(&cursor)
        guard try take(&cursor) == 0x3A else { throw ViewerJSONInspectionError.invalidJSON }
        try skipWhitespace(&cursor)
      }
      _ = try parseValue(&cursor, keyRange: nil, depth: depth + 1)
      try skipWhitespace(&cursor)
      if byte(at: cursor) == closing {
        cursor += 1
        try budget.consume(1)
        return
      }
      guard try take(&cursor) == 0x2C else { throw ViewerJSONInspectionError.invalidJSON }
      try skipWhitespace(&cursor)
    }
    throw ViewerJSONInspectionError.invalidJSON
  }

  private mutating func parseString(_ cursor: inout Int) throws {
    guard try take(&cursor) == 0x22 else { throw ViewerJSONInspectionError.invalidJSON }
    while cursor < data.count {
      let value = try take(&cursor)
      if value == 0x22 { return }
      guard value >= 0x20 else { throw ViewerJSONInspectionError.invalidJSON }
      if value == 0x5C {
        let escaped = try take(&cursor)
        if escaped == 0x75 {
          for _ in 0..<4 where !Self.isHex(try take(&cursor)) {
            throw ViewerJSONInspectionError.invalidJSON
          }
        } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) {
          throw ViewerJSONInspectionError.invalidJSON
        }
      }
    }
    throw ViewerJSONInspectionError.invalidJSON
  }

  private mutating func parseLiteral(_ cursor: inout Int, bytes: [UInt8]) throws {
    for expected in bytes where try take(&cursor) != expected {
      throw ViewerJSONInspectionError.invalidJSON
    }
  }

  private mutating func parseNumber(_ cursor: inout Int) throws {
    let start = cursor
    if byte(at: cursor) == 0x2D { cursor += 1 }
    guard cursor < data.count else { throw ViewerJSONInspectionError.invalidJSON }
    if byte(at: cursor) == 0x30 {
      cursor += 1
    } else {
      guard Self.isDigit1To9(byte(at: cursor)) else {
        throw ViewerJSONInspectionError.invalidJSON
      }
      repeat { cursor += 1 } while cursor < data.count && Self.isDigit(byte(at: cursor))
    }
    if cursor < data.count, byte(at: cursor) == 0x2E {
      cursor += 1
      guard cursor < data.count, Self.isDigit(byte(at: cursor)) else {
        throw ViewerJSONInspectionError.invalidJSON
      }
      repeat { cursor += 1 } while cursor < data.count && Self.isDigit(byte(at: cursor))
    }
    if cursor < data.count, byte(at: cursor) == 0x65 || byte(at: cursor) == 0x45 {
      cursor += 1
      if cursor < data.count, byte(at: cursor) == 0x2B || byte(at: cursor) == 0x2D {
        cursor += 1
      }
      guard cursor < data.count, Self.isDigit(byte(at: cursor)) else {
        throw ViewerJSONInspectionError.invalidJSON
      }
      repeat { cursor += 1 } while cursor < data.count && Self.isDigit(byte(at: cursor))
    }
    try budget.consume(cursor - start)
  }

  private mutating func skipWhitespace(_ cursor: inout Int) throws {
    let start = cursor
    while cursor < data.count, [0x20, 0x09, 0x0A, 0x0D].contains(byte(at: cursor)) {
      cursor += 1
    }
    try budget.consume(cursor - start)
  }

  private mutating func take(_ cursor: inout Int) throws -> UInt8 {
    guard cursor < data.count else { throw ViewerJSONInspectionError.invalidJSON }
    let value = data[cursor]
    cursor += 1
    try budget.consume(1)
    return value
  }

  private func byte(at index: Int) -> UInt8 {
    guard index >= 0, index < data.count else { return 0 }
    return data[index]
  }

  private static func isHex(_ value: UInt8) -> Bool {
    isDigit(value) || (0x41...0x46).contains(value) || (0x61...0x66).contains(value)
  }

  private static func isDigit(_ value: UInt8) -> Bool { (0x30...0x39).contains(value) }
  private static func isDigit1To9(_ value: UInt8) -> Bool { (0x31...0x39).contains(value) }
}

struct ViewerJSONTreeNode: Equatable, Sendable {
  let id: Int
  let parentID: Int?
  let kind: ViewerJSONNodeKind
  let keyRange: Range<Int>?
  let valueRange: Range<Int>
  let preview: String
  let childOffset: Int
  let nextChildOffset: Int?
}

struct ViewerJSONTreeState: Equatable, Sendable {
  private(set) var nodes: [ViewerJSONTreeNode]
  private(set) var derivedTextBytes: Int
  private var loadedExpansions: Set<ExpansionKey>
  private var nextNodeID: Int

  private struct ExpansionKey: Equatable, Hashable, Sendable {
    let nodeID: Int
    let offset: Int
  }

  init(root: ViewerJSONValueRange, data: Data) throws {
    let preview = try ViewerJSONPreview.make(
      value: root,
      data: data,
      maximumBytes: ViewerJSONInspectionLimits.maximumTreePreviewBytes
    )
    nodes = [
      ViewerJSONTreeNode(
        id: 0,
        parentID: nil,
        kind: root.kind,
        keyRange: nil,
        valueRange: root.valueRange,
        preview: preview,
        childOffset: 0,
        nextChildOffset: root.kind.hasChildren ? 0 : nil
      )
    ]
    derivedTextBytes = preview.utf8.count
    loadedExpansions = []
    nextNodeID = 1
  }

  mutating func expand(
    nodeID: Int,
    offset: Int,
    data: Data,
    nowNanoseconds: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    },
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> [ViewerJSONTreeNode] {
    guard let parent = nodes.first(where: { $0.id == nodeID }), parent.kind.hasChildren,
      offset >= 0
    else { throw ViewerJSONInspectionError.invalidRequest }
    let expansion = ExpansionKey(nodeID: nodeID, offset: offset)
    guard !loadedExpansions.contains(expansion) else { return [] }
    var scanner = ViewerJSONRangeScanner(
      data: data,
      budget: ViewerInspectionBudget(
        maximumScannedBytes: data.count,
        nowNanoseconds: nowNanoseconds,
        isCancelled: isCancelled
      )
    )
    let page = try scanner.children(of: parentRange(parent), offset: offset)
    var additions: [ViewerJSONTreeNode] = []
    additions.reserveCapacity(page.values.count)
    var additionalTextBytes = 0
    for value in page.values {
      let preview = try ViewerJSONPreview.make(
        value: value,
        data: data,
        maximumBytes: ViewerJSONInspectionLimits.maximumTreePreviewBytes
      )
      additionalTextBytes += preview.utf8.count
      additions.append(
        ViewerJSONTreeNode(
          id: nextNodeID + additions.count,
          parentID: parent.id,
          kind: value.kind,
          keyRange: value.keyRange,
          valueRange: value.valueRange,
          preview: preview,
          childOffset: offset + additions.count,
          nextChildOffset: value.kind.hasChildren ? 0 : nil
        )
      )
    }
    guard nodes.count + additions.count <= ViewerJSONInspectionLimits.maximumTreeNodes,
      derivedTextBytes + additionalTextBytes
        <= ViewerJSONInspectionLimits.maximumTreeDerivedTextBytes
    else { throw ViewerJSONInspectionError.outputTooLarge }
    nodes.append(contentsOf: additions)
    if let parentIndex = nodes.firstIndex(where: { $0.id == parent.id }) {
      nodes[parentIndex] = ViewerJSONTreeNode(
        id: parent.id,
        parentID: parent.parentID,
        kind: parent.kind,
        keyRange: parent.keyRange,
        valueRange: parent.valueRange,
        preview: parent.preview,
        childOffset: parent.childOffset,
        nextChildOffset: page.nextOffset
      )
    }
    derivedTextBytes += additionalTextBytes
    nextNodeID += additions.count
    loadedExpansions.insert(expansion)
    return additions
  }

  func focusedAccessibilityText(nodeID: Int, data: Data) throws -> String {
    guard let node = nodes.first(where: { $0.id == nodeID }) else {
      throw ViewerJSONInspectionError.invalidRequest
    }
    let key: String
    if let keyRange = node.keyRange {
      key = try ViewerJSONPreview.decodedString(range: keyRange, data: data)
    } else {
      key = "Value"
    }
    return ViewerStructuredTextEscaper.escape(
      "\(key): \(node.preview)",
      maximumBytes: ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
    )
  }

  private func parentRange(_ node: ViewerJSONTreeNode) -> ViewerJSONValueRange {
    ViewerJSONValueRange(kind: node.kind, keyRange: node.keyRange, valueRange: node.valueRange)
  }
}

enum ViewerJSONPreview {
  static func make(
    value: ViewerJSONValueRange,
    data: Data,
    maximumBytes: Int
  ) throws -> String {
    switch value.kind {
    case .object:
      return "Object"
    case .array:
      return "Array"
    case .string:
      if value.valueRange.count <= 64 * 1_024 {
        return ViewerStructuredTextEscaper.escape(
          try decodedString(range: value.valueRange, data: data),
          maximumBytes: maximumBytes
        )
      }
      return "String (\(value.valueRange.count) bytes)"
    case .number, .boolean, .null:
      let upper = min(value.valueRange.upperBound, value.valueRange.lowerBound + maximumBytes)
      guard
        let raw = String(
          data: data.subdata(in: value.valueRange.lowerBound..<upper), encoding: .utf8)
      else { throw ViewerJSONInspectionError.invalidJSON }
      return ViewerStructuredTextEscaper.escape(raw, maximumBytes: maximumBytes)
    }
  }

  static func decodedString(range: Range<Int>, data: Data) throws -> String {
    guard range.lowerBound >= 0, range.upperBound <= data.count else {
      throw ViewerJSONInspectionError.invalidRequest
    }
    do {
      return try JSONDecoder().decode(String.self, from: data.subdata(in: range))
    } catch {
      throw ViewerJSONInspectionError.invalidJSON
    }
  }
}

enum ViewerJSONPrettyPrinter {
  static func prepare(
    data: Data,
    nowNanoseconds: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    },
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> String {
    guard data.count <= ViewerJSONInspectionLimits.maximumPrettyInputBytes else {
      throw ViewerJSONInspectionError.inputTooLarge
    }
    var budget = ViewerInspectionBudget(
      maximumScannedBytes: data.count,
      nowNanoseconds: nowNanoseconds,
      isCancelled: isCancelled
    )
    var output = Data()
    output.reserveCapacity(min(ViewerJSONInspectionLimits.maximumPrettyOutputBytes, data.count * 2))
    var stack: [UInt8] = []
    var inString = false
    var escaped = false
    var index = 0
    while index < data.count {
      let byte = data[index]
      index += 1
      try budget.consume(1)
      if inString {
        try append(byte, to: &output)
        if escaped {
          escaped = false
        } else if byte == 0x5C {
          escaped = true
        } else if byte == 0x22 {
          inString = false
        }
        continue
      }
      switch byte {
      case 0x22:
        inString = true
        try append(byte, to: &output)
      case 0x7B, 0x5B:
        stack.append(byte == 0x7B ? 0x7D : 0x5D)
        try append(byte, to: &output)
        if index < data.count, data[index] != stack.last! {
          try append(0x0A, to: &output)
          try appendIndent(stack.count, to: &output)
        }
      case 0x7D, 0x5D:
        guard stack.popLast() == byte else { throw ViewerJSONInspectionError.invalidJSON }
        let matchingOpening: UInt8 = byte == 0x7D ? 0x7B : 0x5B
        if output.last != 0x0A, output.last != matchingOpening {
          try append(0x0A, to: &output)
          try appendIndent(stack.count, to: &output)
        }
        try append(byte, to: &output)
      case 0x2C:
        try append(byte, to: &output)
        try append(0x0A, to: &output)
        try appendIndent(stack.count, to: &output)
      case 0x3A:
        try append(byte, to: &output)
        try append(0x20, to: &output)
      case 0x20, 0x09, 0x0A, 0x0D:
        continue
      default:
        try append(byte, to: &output)
      }
    }
    guard !inString, stack.isEmpty, let text = String(data: output, encoding: .utf8) else {
      throw ViewerJSONInspectionError.invalidJSON
    }
    return text
  }

  private static func append(_ byte: UInt8, to output: inout Data) throws {
    guard output.count < ViewerJSONInspectionLimits.maximumPrettyOutputBytes else {
      throw ViewerJSONInspectionError.outputTooLarge
    }
    output.append(byte)
  }

  private static func appendIndent(_ depth: Int, to output: inout Data) throws {
    let count = depth * 2
    guard count <= ViewerJSONInspectionLimits.maximumPrettyOutputBytes - output.count else {
      throw ViewerJSONInspectionError.outputTooLarge
    }
    output.append(contentsOf: repeatElement(UInt8(0x20), count: count))
  }
}

enum ViewerStructuredTextEscaper {
  static func escape(_ value: String, maximumBytes: Int) -> String {
    precondition(maximumBytes >= 16)
    let opening = "⟦"
    let closing = "⟧"
    let ellipsis = "…"
    var output = opening
    var truncated = false
    for scalar in value.unicodeScalars {
      let component: String
      if shouldEscape(scalar.value) {
        component = String(format: "<U+%04X>", scalar.value)
      } else {
        component = String(scalar)
      }
      let reserve = closing.utf8.count + ellipsis.utf8.count
      if output.utf8.count + component.utf8.count + reserve > maximumBytes {
        truncated = true
        break
      }
      output.append(component)
    }
    if truncated { output.append(ellipsis) }
    output.append(closing)
    return output
  }

  static func chunks(_ value: String, maximumChunkBytes: Int) -> [String] {
    precondition(maximumChunkBytes > 0)
    var chunks: [String] = []
    var current = ""
    for scalar in value.unicodeScalars {
      let text = String(scalar)
      if !current.isEmpty, current.utf8.count + text.utf8.count > maximumChunkBytes {
        chunks.append(current)
        current = ""
      }
      current.append(text)
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  private static func shouldEscape(_ value: UInt32) -> Bool {
    value <= 0x1F || (0x7F...0x9F).contains(value) || value == 0x061C
      || value == 0x200E || value == 0x200F || (0x202A...0x202E).contains(value)
      || (0x2066...0x2069).contains(value)
  }
}

extension ViewerCanonicalEventDetailBuffer: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerCanonicalEventDetailBuffer(redacted, contentBytes: \(contentByteCount))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["contentBytes": contentByteCount], displayStyle: .struct)
  }
}

extension ViewerInspectorEventMetadata: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerInspectorEventMetadata(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerJSONTreeState: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerJSONTreeState(redacted, nodes: \(nodes.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["nodeCount": nodes.count], displayStyle: .struct)
  }
}
