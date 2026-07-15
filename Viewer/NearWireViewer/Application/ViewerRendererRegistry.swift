import Foundation

enum ViewerRendererKind: String, Equatable, Sendable {
  case genericJSON
  case log
  case table
  case numericSeries
  case timeline
}

struct ViewerRendererRegistry: Sendable {
  private struct Entry: Sendable {
    let pattern: String
    let kind: ViewerRendererKind
    let specificity: Int
  }

  private let entries: [Entry]

  init() {
    entries = [
      Entry(pattern: "timeline.*", kind: .timeline, specificity: 9),
      Entry(pattern: "table.*", kind: .table, specificity: 6),
      Entry(pattern: "chart.*", kind: .numericSeries, specificity: 6),
      Entry(pattern: "log.*", kind: .log, specificity: 4),
      Entry(pattern: "*", kind: .genericJSON, specificity: 0),
    ].sorted {
      $0.specificity == $1.specificity
        ? $0.pattern < $1.pattern : $0.specificity > $1.specificity
    }
  }

  func renderer(for eventType: String) -> ViewerRendererKind {
    entries.first(where: { Self.matches($0.pattern, eventType: eventType) })?.kind
      ?? .genericJSON
  }

  private static func matches(_ pattern: String, eventType: String) -> Bool {
    if pattern == "*" { return true }
    guard pattern.hasSuffix(".*") else { return pattern == eventType }
    return eventType.hasPrefix(String(pattern.dropLast()))
  }
}

enum ViewerRendererFallbackReason: Equatable, Sendable {
  case incompatibleShape
  case inputTooLarge
  case outputTooLarge
  case refineRequired
  case cancelled

  static let guidance =
    "Generic JSON shown because the selected renderer could not safely prepare this Event."
}

enum ViewerGenericPrettyState: Equatable, Sendable {
  case prepared
  case chunkedRawOnly
  case refineRequired
}

struct ViewerGenericJSONPreparation: Equatable, Sendable {
  let rawChunkCount: Int
  let prettyText: String?
  let prettyState: ViewerGenericPrettyState
  let prettyGuidance: String?
  let treeState: ViewerJSONTreeState?
  let treeGuidance: String?
}

struct ViewerLogPreparation: Equatable, Sendable {
  static let maximumInputBytes = 1 * 1_024 * 1_024
  static let maximumOutputBytes = 64 * 1_024
  static let chunkBytes = 4 * 1_024

  let chunks: [String]
  let derivedTextBytes: Int
  let hasMore: Bool
  let focusedAccessibilityText: String
}

struct ViewerTableRowDescriptor: Equatable, Sendable {
  let keyRange: Range<Int>
  let valueRange: Range<Int>
  let keyPreview: String
  let valuePreview: String

  var focusedAccessibilityText: String {
    ViewerStructuredTextEscaper.escape(
      "\(keyPreview): \(valuePreview)",
      maximumBytes: ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
    )
  }
}

struct ViewerTablePreparation: Equatable, Sendable {
  static let maximumInputBytes = 1 * 1_024 * 1_024
  static let pageRows = 64
  static let maximumRetainedRows = 128
  static let maximumDerivedTextBytes = 512 * 1_024
  static let maximumKeyPreviewBytes = 256
  static let maximumValuePreviewBytes = 1_024

  let rows: [ViewerTableRowDescriptor]
  let hasMore: Bool
  let scannedEntryCount: Int
  let derivedTextBytes: Int

  func page(offset: Int) throws -> ArraySlice<ViewerTableRowDescriptor> {
    guard offset >= 0, offset <= rows.count else {
      throw ViewerJSONInspectionError.invalidRequest
    }
    return rows[offset..<min(rows.count, offset + Self.pageRows)]
  }
}

struct ViewerNumericPoint: Equatable, Sendable {
  let row: Int
  let field: Int
  let value: Double
}

struct ViewerNumericPreparation: Equatable, Sendable {
  static let maximumInputBytes = 8 * 1_024 * 1_024
  static let maximumRows = 200
  static let maximumFields = 8
  static let maximumPoints = 200

  let fields: [String]
  let points: [ViewerNumericPoint]
  let scannedRowCount: Int
  let hasMore: Bool
}

struct ViewerTimelinePreparation: Equatable, Sendable {
  let eventType: String
  let deviceAlias: String
  let direction: String
  let priority: String
  let viewerWallMilliseconds: Int64
  let disposition: String
}

enum ViewerSpecializedRendererPreparation: Equatable, Sendable {
  case log(ViewerLogPreparation)
  case table(ViewerTablePreparation)
  case numeric(ViewerNumericPreparation)
  case timeline(ViewerTimelinePreparation)
}

struct ViewerRendererPreparation: Equatable, Sendable {
  let requestedKind: ViewerRendererKind
  let presentedKind: ViewerRendererKind
  let generic: ViewerGenericJSONPreparation
  let specialized: ViewerSpecializedRendererPreparation?
  let fallbackReason: ViewerRendererFallbackReason?

  var fallbackGuidance: String? {
    fallbackReason == nil ? nil : ViewerRendererFallbackReason.guidance
  }
}

struct ViewerInspectorGenerationToken: Equatable, Hashable, Sendable {
  let runtimeLogicalID: UUID
  let generation: UInt64
  let eventIdentity: ViewerExplorerEventIdentity?
}

struct ViewerRendererPreparationRequest: Sendable {
  let token: ViewerInspectorGenerationToken
  let buffer: ViewerCanonicalEventDetailBuffer
  let rendererKind: ViewerRendererKind
}

struct ViewerRendererPreparationResult: Sendable {
  let token: ViewerInspectorGenerationToken
  let preparation: ViewerRendererPreparation
}

struct ViewerRendererPreparer: Sendable {
  private let nowNanoseconds: @Sendable () -> UInt64

  init(
    nowNanoseconds: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    }
  ) {
    self.nowNanoseconds = nowNanoseconds
  }

  func prepare(
    _ request: ViewerRendererPreparationRequest,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) -> ViewerRendererPreparationResult {
    let generic = prepareGeneric(buffer: request.buffer, isCancelled: isCancelled)
    guard request.rendererKind != .genericJSON else {
      return ViewerRendererPreparationResult(
        token: request.token,
        preparation: ViewerRendererPreparation(
          requestedKind: .genericJSON,
          presentedKind: .genericJSON,
          generic: generic,
          specialized: nil,
          fallbackReason: nil
        )
      )
    }
    do {
      let specialized: ViewerSpecializedRendererPreparation
      switch request.rendererKind {
      case .genericJSON:
        preconditionFailure("Handled above")
      case .log:
        specialized = .log(try prepareLog(buffer: request.buffer, isCancelled: isCancelled))
      case .table:
        specialized = .table(try prepareTable(buffer: request.buffer, isCancelled: isCancelled))
      case .numericSeries:
        specialized = .numeric(
          try prepareNumeric(buffer: request.buffer, isCancelled: isCancelled)
        )
      case .timeline:
        specialized = .timeline(prepareTimeline(buffer: request.buffer))
      }
      return ViewerRendererPreparationResult(
        token: request.token,
        preparation: ViewerRendererPreparation(
          requestedKind: request.rendererKind,
          presentedKind: request.rendererKind,
          generic: generic,
          specialized: specialized,
          fallbackReason: nil
        )
      )
    } catch {
      return ViewerRendererPreparationResult(
        token: request.token,
        preparation: ViewerRendererPreparation(
          requestedKind: request.rendererKind,
          presentedKind: .genericJSON,
          generic: generic,
          specialized: nil,
          fallbackReason: Self.fallbackReason(error)
        )
      )
    }
  }

  private func prepareGeneric(
    buffer: ViewerCanonicalEventDetailBuffer,
    isCancelled: @escaping @Sendable () -> Bool
  ) -> ViewerGenericJSONPreparation {
    let data = buffer.content
    var treeState: ViewerJSONTreeState?
    var treeGuidance: String?
    do {
      var scanner = ViewerJSONRangeScanner(
        data: data,
        budget: ViewerInspectionBudget(
          maximumScannedBytes: data.count,
          nowNanoseconds: nowNanoseconds,
          isCancelled: isCancelled
        )
      )
      treeState = try ViewerJSONTreeState(root: scanner.root(), data: data)
    } catch {
      treeGuidance = "Refine the selection to build the bounded JSON tree."
    }

    let prettyText: String?
    let prettyState: ViewerGenericPrettyState
    let prettyGuidance: String?
    if data.count > ViewerJSONInspectionLimits.maximumPrettyInputBytes {
      prettyText = nil
      prettyState = .chunkedRawOnly
      prettyGuidance = "Pretty JSON is available up to 1 MiB. Use chunked raw JSON."
    } else {
      do {
        prettyText = try ViewerJSONPrettyPrinter.prepare(
          data: data,
          nowNanoseconds: nowNanoseconds,
          isCancelled: isCancelled
        )
        prettyState = .prepared
        prettyGuidance = nil
      } catch {
        prettyText = nil
        prettyState = .refineRequired
        prettyGuidance = "Use chunked raw JSON or refine the selected Event."
      }
    }
    return ViewerGenericJSONPreparation(
      rawChunkCount: ViewerRawJSONNavigator.chunkCount(in: buffer),
      prettyText: prettyText,
      prettyState: prettyState,
      prettyGuidance: prettyGuidance,
      treeState: treeState,
      treeGuidance: treeGuidance
    )
  }

  private func prepareLog(
    buffer: ViewerCanonicalEventDetailBuffer,
    isCancelled: @escaping @Sendable () -> Bool
  ) throws -> ViewerLogPreparation {
    let data = buffer.content
    guard data.count <= ViewerLogPreparation.maximumInputBytes else {
      throw ViewerJSONInspectionError.inputTooLarge
    }
    var scanner = ViewerJSONRangeScanner(
      data: data,
      budget: ViewerInspectionBudget(
        maximumScannedBytes: data.count,
        nowNanoseconds: nowNanoseconds,
        isCancelled: isCancelled
      )
    )
    let root = try scanner.assumedValidatedRoot()
    let messageRange: Range<Int>
    switch root.kind {
    case .string:
      messageRange = root.valueRange
    case .object:
      let page = try scanner.children(
        of: root,
        offset: 0,
        limit: 4_096,
        maximumEntries: 4_096
      )
      guard
        let message = try page.values.first(where: { value in
          guard value.kind == .string, let keyRange = value.keyRange else { return false }
          return try ViewerJSONPreview.decodedString(range: keyRange, data: data) == "message"
        })
      else { throw ViewerJSONInspectionError.invalidRequest }
      messageRange = message.valueRange
    default:
      throw ViewerJSONInspectionError.invalidRequest
    }
    let message = try ViewerJSONPreview.decodedString(range: messageRange, data: data)
    let escaped = ViewerStructuredTextEscaper.escape(
      message,
      maximumBytes: ViewerLogPreparation.maximumOutputBytes
    )
    let chunks = ViewerStructuredTextEscaper.chunks(
      escaped,
      maximumChunkBytes: ViewerLogPreparation.chunkBytes
    )
    return ViewerLogPreparation(
      chunks: chunks,
      derivedTextBytes: escaped.utf8.count,
      hasMore: escaped.hasSuffix("…⟧"),
      focusedAccessibilityText: ViewerStructuredTextEscaper.escape(
        message,
        maximumBytes: ViewerJSONInspectionLimits.maximumFocusedAccessibilityBytes
      )
    )
  }

  private func prepareTable(
    buffer: ViewerCanonicalEventDetailBuffer,
    isCancelled: @escaping @Sendable () -> Bool
  ) throws -> ViewerTablePreparation {
    let data = buffer.content
    guard data.count <= ViewerTablePreparation.maximumInputBytes else {
      throw ViewerJSONInspectionError.inputTooLarge
    }
    var scanner = ViewerJSONRangeScanner(
      data: data,
      budget: ViewerInspectionBudget(
        maximumScannedBytes: data.count,
        nowNanoseconds: nowNanoseconds,
        isCancelled: isCancelled
      )
    )
    let root = try scanner.assumedValidatedRoot()
    guard root.kind == .object else { throw ViewerJSONInspectionError.invalidRequest }
    let page = try scanner.children(
      of: root,
      offset: 0,
      limit: 4_096,
      maximumEntries: 4_096
    )
    var rows: [ViewerTableRowDescriptor] = []
    var scalarCount = 0
    var derivedTextBytes = 0
    for value in page.values where !value.kind.hasChildren {
      scalarCount += 1
      guard rows.count < ViewerTablePreparation.maximumRetainedRows,
        let keyRange = value.keyRange
      else { continue }
      let key = ViewerStructuredTextEscaper.escape(
        try ViewerJSONPreview.decodedString(range: keyRange, data: data),
        maximumBytes: ViewerTablePreparation.maximumKeyPreviewBytes
      )
      let preview = try ViewerJSONPreview.make(
        value: value,
        data: data,
        maximumBytes: ViewerTablePreparation.maximumValuePreviewBytes
      )
      let rowBytes = key.utf8.count + preview.utf8.count
      guard rowBytes <= ViewerTablePreparation.maximumDerivedTextBytes - derivedTextBytes else {
        throw ViewerJSONInspectionError.outputTooLarge
      }
      derivedTextBytes += rowBytes
      rows.append(
        ViewerTableRowDescriptor(
          keyRange: keyRange,
          valueRange: value.valueRange,
          keyPreview: key,
          valuePreview: preview
        )
      )
    }
    guard !rows.isEmpty else { throw ViewerJSONInspectionError.invalidRequest }
    return ViewerTablePreparation(
      rows: rows,
      hasMore: scalarCount > rows.count || page.nextOffset != nil,
      scannedEntryCount: page.scannedEntryCount,
      derivedTextBytes: derivedTextBytes
    )
  }

  private func prepareNumeric(
    buffer: ViewerCanonicalEventDetailBuffer,
    isCancelled: @escaping @Sendable () -> Bool
  ) throws -> ViewerNumericPreparation {
    let data = buffer.content
    guard data.count <= ViewerNumericPreparation.maximumInputBytes else {
      throw ViewerJSONInspectionError.inputTooLarge
    }
    let maximumScan = data.count > Int.max / 2 ? Int.max : data.count * 2
    var scanner = ViewerJSONRangeScanner(
      data: data,
      budget: ViewerInspectionBudget(
        maximumScannedBytes: maximumScan,
        nowNanoseconds: nowNanoseconds,
        isCancelled: isCancelled
      )
    )
    let root = try scanner.assumedValidatedRoot()
    guard root.kind == .array else { throw ViewerJSONInspectionError.invalidRequest }
    let rows = try scanner.children(
      of: root,
      offset: 0,
      limit: ViewerNumericPreparation.maximumRows,
      maximumEntries: ViewerNumericPreparation.maximumRows
    )
    var fields: [String] = []
    var fieldIndices: [String: Int] = [:]
    var points: [ViewerNumericPoint] = []
    var hasMore = rows.nextOffset != nil
    for (rowIndex, row) in rows.values.enumerated() {
      if row.kind == .number {
        if fields.isEmpty {
          fields = ["Value"]
          fieldIndices["Value"] = 0
        }
        if points.count < ViewerNumericPreparation.maximumPoints,
          let number = try finiteNumber(range: row.valueRange, data: data)
        {
          points.append(ViewerNumericPoint(row: rowIndex, field: 0, value: number))
        } else if points.count >= ViewerNumericPreparation.maximumPoints {
          hasMore = true
        }
      } else if row.kind == .object {
        let values = try scanner.children(
          of: row,
          offset: 0,
          limit: ViewerNumericPreparation.maximumFields,
          maximumEntries: ViewerNumericPreparation.maximumFields
        )
        for value in values.values where value.kind == .number {
          guard let keyRange = value.keyRange,
            let number = try finiteNumber(range: value.valueRange, data: data)
          else { continue }
          let key = ViewerStructuredTextEscaper.escape(
            try ViewerJSONPreview.decodedString(range: keyRange, data: data),
            maximumBytes: ViewerTablePreparation.maximumKeyPreviewBytes
          )
          let field: Int
          if let existing = fieldIndices[key] {
            field = existing
          } else if fields.count < ViewerNumericPreparation.maximumFields {
            field = fields.count
            fields.append(key)
            fieldIndices[key] = field
          } else {
            hasMore = true
            continue
          }
          guard points.count < ViewerNumericPreparation.maximumPoints else {
            hasMore = true
            continue
          }
          points.append(ViewerNumericPoint(row: rowIndex, field: field, value: number))
        }
        if values.nextOffset != nil { hasMore = true }
      }
    }
    guard !fields.isEmpty, !points.isEmpty else {
      throw ViewerJSONInspectionError.invalidRequest
    }
    return ViewerNumericPreparation(
      fields: fields,
      points: points,
      scannedRowCount: rows.scannedEntryCount,
      hasMore: hasMore
    )
  }

  private func prepareTimeline(
    buffer: ViewerCanonicalEventDetailBuffer
  ) -> ViewerTimelinePreparation {
    let metadata = buffer.metadata
    return ViewerTimelinePreparation(
      eventType: metadata.eventType,
      deviceAlias: metadata.deviceAlias,
      direction: metadata.direction,
      priority: metadata.priority,
      viewerWallMilliseconds: metadata.viewerWallMilliseconds,
      disposition: metadata.disposition ?? "Pending"
    )
  }

  private func finiteNumber(range: Range<Int>, data: Data) throws -> Double? {
    guard range.count <= 128,
      let raw = String(data: data.subdata(in: range), encoding: .utf8),
      let value = Double(raw)
    else { return nil }
    return value.isFinite ? value : nil
  }

  private static func fallbackReason(_ error: Error) -> ViewerRendererFallbackReason {
    switch error as? ViewerJSONInspectionError {
    case .inputTooLarge: return .inputTooLarge
    case .outputTooLarge: return .outputTooLarge
    case .cancelled: return .cancelled
    case .workLimitExceeded, .deadlineExceeded: return .refineRequired
    default: return .incompatibleShape
    }
  }
}

final class ViewerRendererPreparationService: @unchecked Sendable {
  typealias Completion = @Sendable (ViewerRendererPreparationResult) -> Void

  private struct Pending: Sendable {
    let request: ViewerRendererPreparationRequest
    let completion: Completion
  }

  private let lock = NSLock()
  private let queue: DispatchQueue
  private let preparer: ViewerRendererPreparer
  private let workTracker = ViewerAsyncWorkTracker()
  private var activeToken: ViewerInspectorGenerationToken?
  private var pending: Pending?
  private var workerRunning = false
  private var executing = false

  init(
    queue: DispatchQueue = DispatchQueue(
      label: "com.nearwire.viewer.renderer-preparation",
      qos: .userInitiated
    ),
    preparer: ViewerRendererPreparer = ViewerRendererPreparer()
  ) {
    self.queue = queue
    self.preparer = preparer
  }

  func submit(
    _ request: ViewerRendererPreparationRequest,
    completion: @escaping Completion
  ) {
    let replaced: Pending?
    let workID: UUID?
    lock.lock()
    activeToken = request.token
    replaced = pending
    pending = Pending(request: request, completion: completion)
    if workerRunning {
      workID = nil
    } else {
      workerRunning = true
      workID = workTracker.begin()
    }
    lock.unlock()
    if let replaced {
      replaced.completion(Self.cancelledResult(for: replaced.request))
    }
    if let workID {
      queue.async { [weak self, workTracker] in
        guard let self else {
          workTracker.complete(workID)
          return
        }
        self.runWorker(workID: workID)
      }
    }
  }

  func cancel() {
    let removed: Pending?
    lock.lock()
    activeToken = nil
    removed = pending
    pending = nil
    lock.unlock()
    if let removed {
      removed.completion(Self.cancelledResult(for: removed.request))
    }
  }

  func cancelAndWait() -> Task<Void, Never> {
    cancel()
    return workTracker.waitTask()
  }

  var pendingWorkCount: Int { workTracker.activeCount }

  var retainedRequestLimit: Int { 2 }

  var retainedRequestCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return (executing ? 1 : 0) + (pending == nil ? 0 : 1)
  }

  private func runWorker(workID: UUID) {
    while true {
      let next: Pending?
      lock.lock()
      next = pending
      pending = nil
      executing = next != nil
      if next == nil { workerRunning = false }
      lock.unlock()
      guard let next else {
        workTracker.complete(workID)
        return
      }
      let result = preparer.prepare(next.request) { [weak self] in
        self?.isActive(next.request.token) != true
      }
      next.completion(result)
      lock.lock()
      executing = false
      lock.unlock()
    }
  }

  private func isActive(_ token: ViewerInspectorGenerationToken) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeToken == token
  }

  private static func cancelledResult(
    for request: ViewerRendererPreparationRequest
  ) -> ViewerRendererPreparationResult {
    ViewerRendererPreparationResult(
      token: request.token,
      preparation: ViewerRendererPreparation(
        requestedKind: request.rendererKind,
        presentedKind: .genericJSON,
        generic: ViewerGenericJSONPreparation(
          rawChunkCount: 0,
          prettyText: nil,
          prettyState: .refineRequired,
          prettyGuidance: nil,
          treeState: nil,
          treeGuidance: nil
        ),
        specialized: nil,
        fallbackReason: .cancelled
      )
    )
  }
}

@MainActor
final class ViewerEventInspectorModel: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  private(set) var runtimeLogicalID: UUID
  private(set) var generation: UInt64 = 0
  private(set) var selectedIdentity: ViewerExplorerEventIdentity?
  private(set) var canonicalBuffer: ViewerCanonicalEventDetailBuffer?
  private(set) var preparation: ViewerRendererPreparation?
  private let registry: ViewerRendererRegistry

  init(runtimeLogicalID: UUID, registry: ViewerRendererRegistry = ViewerRendererRegistry()) {
    self.runtimeLogicalID = runtimeLogicalID
    self.registry = registry
  }

  @discardableResult
  func select(
    liveEvent: ViewerLiveEventSnapshot,
    identity: ViewerExplorerEventIdentity
  ) throws -> ViewerRendererPreparationRequest {
    let buffer = try prepare(liveEvent: liveEvent, identity: identity)
    return select(preparedLiveBuffer: buffer, identity: identity)
  }

  func prepare(
    liveEvent: ViewerLiveEventSnapshot,
    identity: ViewerExplorerEventIdentity
  ) throws -> ViewerCanonicalEventDetailBuffer {
    guard case .memory(let key) = identity, key == liveEvent.observation.key else {
      throw ViewerJSONInspectionError.invalidRequest
    }
    return try ViewerCanonicalEventDetailBuffer(liveEvent: liveEvent)
  }

  @discardableResult
  func select(
    preparedLiveBuffer buffer: ViewerCanonicalEventDetailBuffer,
    identity: ViewerExplorerEventIdentity
  ) -> ViewerRendererPreparationRequest {
    generation = Self.saturatingIncrement(generation)
    selectedIdentity = identity
    return select(buffer: buffer, identity: identity)
  }

  private func select(
    buffer: ViewerCanonicalEventDetailBuffer,
    identity: ViewerExplorerEventIdentity
  ) -> ViewerRendererPreparationRequest {
    canonicalBuffer = buffer
    preparation = nil
    return ViewerRendererPreparationRequest(
      token: currentToken,
      buffer: buffer,
      rendererKind: registry.renderer(for: buffer.metadata.eventType)
    )
  }

  @discardableResult
  func apply(_ result: ViewerRendererPreparationResult) -> Bool {
    guard result.token == currentToken, canonicalBuffer != nil else { return false }
    preparation = result.preparation
    return true
  }

  func rawChunk(at index: Int) throws -> ViewerRawJSONChunk {
    guard let canonicalBuffer else { throw ViewerJSONInspectionError.invalidRequest }
    return try ViewerRawJSONNavigator.chunk(at: index, in: canonicalBuffer)
  }

  func clear() {
    generation = Self.saturatingIncrement(generation)
    selectedIdentity = nil
    canonicalBuffer = nil
    preparation = nil
  }

  var currentToken: ViewerInspectorGenerationToken {
    ViewerInspectorGenerationToken(
      runtimeLogicalID: runtimeLogicalID,
      generation: generation,
      eventIdentity: selectedIdentity
    )
  }

  nonisolated var description: String { "ViewerEventInspectorModel(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? UInt64.max : value + 1
  }
}

extension ViewerRendererPreparationRequest: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerRendererPreparationRequest(redacted, contentBytes: \(buffer.contentByteCount))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["contentBytes": buffer.contentByteCount], displayStyle: .struct)
  }
}

extension ViewerRendererPreparation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRendererPreparation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerLogPreparation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerLogPreparation(redacted, chunks: \(chunks.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["chunkCount": chunks.count], displayStyle: .struct)
  }
}

extension ViewerTablePreparation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerTablePreparation(redacted, rows: \(rows.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["rowCount": rows.count], displayStyle: .struct)
  }
}

extension ViewerNumericPreparation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerNumericPreparation(redacted, points: \(points.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["pointCount": points.count], displayStyle: .struct)
  }
}
