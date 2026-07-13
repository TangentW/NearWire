import Foundation
@_spi(NearWireInternal) import NearWireCore

enum ViewerTextEditRejection: Equatable, Sendable {
  case invalidRange
  case byteLimit
  case scalarLimit
  case unsupportedCharacter
}

enum ViewerTextEditResult: Equatable, Sendable {
  case applied
  case rejected(ViewerTextEditRejection)
}

enum ViewerTextCharacterPolicy: Equatable, Sendable {
  case unrestricted
  case asciiDigits
}

struct ViewerTextBufferDiagnostics: Equatable, Sendable {
  let appliedEditCount: UInt64
  let rejectedEditCount: UInt64
  let replacementMetricScanCount: UInt64
  let removedRangeMetricScanCount: UInt64
  let storageCopyCount: UInt64
  let fullValueRescanCount: UInt64
}

struct ViewerIncrementalTextBuffer: Sendable {
  let maximumUTF8Bytes: Int
  let maximumUnicodeScalars: Int?
  let characterPolicy: ViewerTextCharacterPolicy

  private(set) var value = ""
  private(set) var utf8ByteCount = 0
  private(set) var unicodeScalarCount = 0
  private(set) var utf16Count = 0
  private var appliedEditCount: UInt64 = 0
  private var rejectedEditCount: UInt64 = 0
  private var replacementMetricScanCount: UInt64 = 0
  private var removedRangeMetricScanCount: UInt64 = 0
  private var storageCopyCount: UInt64 = 0

  init(
    maximumUTF8Bytes: Int,
    maximumUnicodeScalars: Int? = nil,
    characterPolicy: ViewerTextCharacterPolicy = .unrestricted
  ) {
    precondition(maximumUTF8Bytes >= 0)
    precondition(maximumUnicodeScalars.map { $0 >= 0 } ?? true)
    self.maximumUTF8Bytes = maximumUTF8Bytes
    self.maximumUnicodeScalars = maximumUnicodeScalars
    self.characterPolicy = characterPolicy
  }

  var diagnostics: ViewerTextBufferDiagnostics {
    ViewerTextBufferDiagnostics(
      appliedEditCount: appliedEditCount,
      rejectedEditCount: rejectedEditCount,
      replacementMetricScanCount: replacementMetricScanCount,
      removedRangeMetricScanCount: removedRangeMetricScanCount,
      storageCopyCount: storageCopyCount,
      fullValueRescanCount: 0
    )
  }

  @discardableResult
  mutating func replaceCharacters(
    in range: NSRange,
    with replacement: String
  ) -> ViewerTextEditResult {
    guard let stringRange = Range(range, in: value) else { return reject(.invalidRange) }
    guard acceptsCharacters(replacement) else { return reject(.unsupportedCharacter) }

    replacementMetricScanCount = Self.saturatingIncrement(replacementMetricScanCount)
    let replacementBytes = replacement.utf8.count
    let replacementScalars = replacement.unicodeScalars.count
    let replacementUTF16 = replacement.utf16.count
    guard replacementBytes <= maximumUTF8Bytes else { return reject(.byteLimit) }
    if let maximumUnicodeScalars, replacementScalars > maximumUnicodeScalars {
      return reject(.scalarLimit)
    }

    removedRangeMetricScanCount = Self.saturatingIncrement(removedRangeMetricScanCount)
    let removed = value[stringRange]
    let removedBytes = removed.utf8.count
    let removedScalars = removed.unicodeScalars.count
    let removedUTF16 = removed.utf16.count
    guard
      let nextBytes = Self.replacingCount(
        current: utf8ByteCount,
        removed: removedBytes,
        added: replacementBytes
      ), nextBytes <= maximumUTF8Bytes
    else { return reject(.byteLimit) }
    guard
      let nextScalars = Self.replacingCount(
        current: unicodeScalarCount,
        removed: removedScalars,
        added: replacementScalars
      )
    else { return reject(.scalarLimit) }
    if let maximumUnicodeScalars, nextScalars > maximumUnicodeScalars {
      return reject(.scalarLimit)
    }
    guard
      let nextUTF16 = Self.replacingCount(
        current: utf16Count,
        removed: removedUTF16,
        added: replacementUTF16
      )
    else { return reject(.invalidRange) }

    value.replaceSubrange(stringRange, with: replacement)
    utf8ByteCount = nextBytes
    unicodeScalarCount = nextScalars
    utf16Count = nextUTF16
    appliedEditCount = Self.saturatingIncrement(appliedEditCount)
    storageCopyCount = Self.saturatingIncrement(storageCopyCount)
    return .applied
  }

  private mutating func reject(_ reason: ViewerTextEditRejection) -> ViewerTextEditResult {
    rejectedEditCount = Self.saturatingIncrement(rejectedEditCount)
    return .rejected(reason)
  }

  private func acceptsCharacters(_ replacement: String) -> Bool {
    switch characterPolicy {
    case .unrestricted:
      return true
    case .asciiDigits:
      return replacement.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
  }

  private static func replacingCount(current: Int, removed: Int, added: Int) -> Int? {
    guard current >= removed else { return nil }
    let (result, overflow) = (current - removed).addingReportingOverflow(added)
    return overflow ? nil : result
  }

  private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? UInt64.max : value + 1
  }
}

enum ViewerComposerTextLimitError: Error, Equatable, Sendable {
  case invalidLimits
}

struct ViewerComposerTextLimits: Equatable, Sendable {
  static let hardModelBytes = 16 * 1_024 * 1_024
  static let modelReserveBytes = 65_536

  let eventTypeBytes: Int
  let contentBytes: Int
  let ttlBytes: Int

  init(activeLimits: EventValidationLimits) throws {
    let cappedModel = min(activeLimits.maximumEncodedModelBytes, Self.hardModelBytes)
    let (availableModelBytes, underflow) = cappedModel.subtractingReportingOverflow(
      Self.modelReserveBytes
    )
    guard !underflow, availableModelBytes >= 0 else {
      throw ViewerComposerTextLimitError.invalidLimits
    }
    eventTypeBytes = min(128, activeLimits.maximumTypeBytes)
    contentBytes = min(activeLimits.maximumEncodedContentBytes, availableModelBytes / 4)
    ttlBytes = 9
  }
}

enum ViewerTTLValidationError: Error, Equatable, Sendable {
  case invalidSyntax
  case outOfRange
}

enum ViewerTTLTextParser {
  static func parse(_ text: String, maximumMilliseconds: UInt64) throws -> UInt64 {
    guard (1...9).contains(text.utf8.count),
      text.utf8.allSatisfy({ (0x30...0x39).contains($0) })
    else { throw ViewerTTLValidationError.invalidSyntax }
    guard let value = UInt64(text), value > 0, value <= maximumMilliseconds else {
      throw ViewerTTLValidationError.outOfRange
    }
    return value
  }
}

enum ViewerExplorerOperatorTextField: Equatable, Sendable {
  case search
  case jsonPath
  case jsonComparison
  case name
  case note
  case annotation
}

struct ViewerExplorerOperatorTextBuffers: Sendable {
  private(set) var search = ViewerIncrementalTextBuffer(maximumUTF8Bytes: 512)
  private(set) var jsonPath = ViewerIncrementalTextBuffer(maximumUTF8Bytes: 256)
  private(set) var jsonComparison = ViewerIncrementalTextBuffer(maximumUTF8Bytes: 16 * 1_024)
  private(set) var name = ViewerIncrementalTextBuffer(
    maximumUTF8Bytes: 120,
    maximumUnicodeScalars: 80
  )
  private(set) var note = ViewerIncrementalTextBuffer(
    maximumUTF8Bytes: 16 * 1_024,
    maximumUnicodeScalars: 4_096
  )
  private(set) var annotation = ViewerIncrementalTextBuffer(
    maximumUTF8Bytes: 16 * 1_024,
    maximumUnicodeScalars: 4_096
  )

  @discardableResult
  mutating func replaceCharacters(
    field: ViewerExplorerOperatorTextField,
    range: NSRange,
    replacement: String
  ) -> ViewerTextEditResult {
    switch field {
    case .search: return search.replaceCharacters(in: range, with: replacement)
    case .jsonPath: return jsonPath.replaceCharacters(in: range, with: replacement)
    case .jsonComparison:
      return jsonComparison.replaceCharacters(in: range, with: replacement)
    case .name: return name.replaceCharacters(in: range, with: replacement)
    case .note: return note.replaceCharacters(in: range, with: replacement)
    case .annotation: return annotation.replaceCharacters(in: range, with: replacement)
    }
  }
}

enum ViewerComposerField: Equatable, Sendable {
  case eventType
  case content
  case ttl
}

struct ViewerComposerGenerationToken: Equatable, Hashable, Sendable {
  let runtimeLogicalID: UUID
  let generation: UInt64
}

struct ViewerComposerInputSnapshot: Sendable {
  let eventType: String
  let contentJSON: String
  let ttlText: String
  let priority: EventPriority
  let policy: ViewerControlDraftPolicy
  let activeLimits: EventValidationLimits
}

struct ViewerComposerPreparationRequest: Sendable {
  let token: ViewerComposerGenerationToken
  let input: ViewerComposerInputSnapshot
}

struct ViewerComposerPreparationDiagnostics: Equatable, Sendable {
  var inputCopyCount: UInt64 = 0
  var contentTraversalCount: UInt64 = 0
  var draftValidationCount: UInt64 = 0
  var encodeCount: UInt64 = 0
}

enum ViewerComposerPreparationError: Error, Equatable, Sendable {
  case cancelled
  case invalidEventType
  case invalidContent
  case invalidTTL
  case encodedSizeRejected
}

enum ViewerComposerPreparationOutcome: Sendable {
  case success(ViewerPreparedControlEvent, ViewerComposerPreparationDiagnostics)
  case failure(ViewerComposerPreparationError, ViewerComposerPreparationDiagnostics)
}

struct ViewerComposerPreparationResult: Sendable {
  let token: ViewerComposerGenerationToken
  let outcome: ViewerComposerPreparationOutcome
}

struct ViewerComposerPreparer: Sendable {
  func prepare(
    _ request: ViewerComposerPreparationRequest,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) -> ViewerComposerPreparationResult {
    var diagnostics = ViewerComposerPreparationDiagnostics()
    func failure(_ error: ViewerComposerPreparationError) -> ViewerComposerPreparationResult {
      ViewerComposerPreparationResult(
        token: request.token,
        outcome: .failure(error, diagnostics)
      )
    }
    guard !isCancelled() else { return failure(.cancelled) }

    let contentData = Data(request.input.contentJSON.utf8)
    diagnostics.inputCopyCount = 1
    guard !isCancelled() else { return failure(.cancelled) }

    let content: JSONValue
    diagnostics.contentTraversalCount = 1
    do {
      content = try JSONValue.decodeJSON(
        from: contentData,
        limits: request.input.activeLimits
      )
    } catch {
      return failure(.invalidContent)
    }
    guard !isCancelled() else { return failure(.cancelled) }

    let eventType: EventType
    do {
      eventType = try EventType.user(
        request.input.eventType,
        limits: request.input.activeLimits
      )
    } catch {
      return failure(.invalidEventType)
    }
    let ttl: EventTTL
    do {
      let milliseconds = try ViewerTTLTextParser.parse(
        request.input.ttlText,
        maximumMilliseconds: request.input.activeLimits.maximumTTLMilliseconds
      )
      ttl = try EventTTL(
        milliseconds: milliseconds,
        limits: request.input.activeLimits
      )
    } catch {
      return failure(.invalidTTL)
    }
    guard !isCancelled() else { return failure(.cancelled) }

    let draft: EventDraft
    diagnostics.draftValidationCount = 1
    do {
      draft = try EventDraft(
        type: eventType,
        content: content,
        priority: request.input.priority,
        ttl: ttl,
        limits: request.input.activeLimits
      )
    } catch {
      return failure(.invalidContent)
    }
    guard !isCancelled() else { return failure(.cancelled) }

    let encoded: Data
    diagnostics.encodeCount = 1
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      encoded = try encoder.encode(draft)
    } catch {
      return failure(.encodedSizeRejected)
    }
    guard !isCancelled() else { return failure(.cancelled) }

    do {
      let prepared = try ViewerPreparedControlEvent(
        draft: draft,
        policy: request.input.policy,
        encode: { _ in encoded }
      )
      return ViewerComposerPreparationResult(
        token: request.token,
        outcome: .success(prepared, diagnostics)
      )
    } catch {
      return failure(.encodedSizeRejected)
    }
  }
}

final class ViewerComposerPreparationService: @unchecked Sendable {
  typealias Completion = @Sendable (ViewerComposerPreparationResult) -> Void

  private struct Pending: Sendable {
    let request: ViewerComposerPreparationRequest
    let completion: Completion
  }

  private let lock = NSLock()
  private let queue: DispatchQueue
  private let preparer: ViewerComposerPreparer
  private let workTracker = ViewerAsyncWorkTracker()
  private var activeToken: ViewerComposerGenerationToken?
  private var pending: Pending?
  private var workerRunning = false
  private var executing = false

  init(
    queue: DispatchQueue = DispatchQueue(
      label: "com.nearwire.viewer.composer-preparation",
      qos: .userInitiated
    ),
    preparer: ViewerComposerPreparer = ViewerComposerPreparer()
  ) {
    self.queue = queue
    self.preparer = preparer
  }

  func submit(
    _ request: ViewerComposerPreparationRequest,
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

  private func isActive(_ token: ViewerComposerGenerationToken) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeToken == token
  }

  private static func cancelledResult(
    for request: ViewerComposerPreparationRequest
  ) -> ViewerComposerPreparationResult {
    ViewerComposerPreparationResult(
      token: request.token,
      outcome: .failure(.cancelled, ViewerComposerPreparationDiagnostics())
    )
  }
}

@MainActor
final class ViewerControlComposerModel: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  let runtimeLogicalID: UUID
  let activeLimits: EventValidationLimits
  let textLimits: ViewerComposerTextLimits

  private(set) var eventType: ViewerIncrementalTextBuffer
  private(set) var content: ViewerIncrementalTextBuffer
  private(set) var ttl: ViewerIncrementalTextBuffer
  private(set) var priority: EventPriority = .normal
  private(set) var policy: ViewerControlDraftPolicy = .normal
  private(set) var generation: UInt64 = 0
  private(set) var preparedEvent: ViewerPreparedControlEvent?
  private(set) var preparationFailure: ViewerComposerPreparationError?

  init(runtimeLogicalID: UUID, activeLimits: EventValidationLimits) throws {
    self.runtimeLogicalID = runtimeLogicalID
    self.activeLimits = activeLimits
    textLimits = try ViewerComposerTextLimits(activeLimits: activeLimits)
    eventType = ViewerIncrementalTextBuffer(maximumUTF8Bytes: textLimits.eventTypeBytes)
    content = ViewerIncrementalTextBuffer(maximumUTF8Bytes: textLimits.contentBytes)
    ttl = ViewerIncrementalTextBuffer(
      maximumUTF8Bytes: textLimits.ttlBytes,
      characterPolicy: .asciiDigits
    )
  }

  var currentToken: ViewerComposerGenerationToken {
    ViewerComposerGenerationToken(
      runtimeLogicalID: runtimeLogicalID,
      generation: generation
    )
  }

  @discardableResult
  func replaceCharacters(
    field: ViewerComposerField,
    range: NSRange,
    replacement: String
  ) -> ViewerTextEditResult {
    let result: ViewerTextEditResult
    switch field {
    case .eventType:
      result = eventType.replaceCharacters(in: range, with: replacement)
    case .content:
      result = content.replaceCharacters(in: range, with: replacement)
    case .ttl:
      result = ttl.replaceCharacters(in: range, with: replacement)
    }
    if result == .applied { invalidatePreparation() }
    return result
  }

  func setPriority(_ priority: EventPriority) {
    guard self.priority != priority else { return }
    self.priority = priority
    invalidatePreparation()
  }

  func setPolicy(_ policy: ViewerControlDraftPolicy) {
    guard self.policy != policy else { return }
    self.policy = policy
    invalidatePreparation()
  }

  func makePreparationRequest() -> ViewerComposerPreparationRequest {
    invalidatePreparation()
    return ViewerComposerPreparationRequest(
      token: currentToken,
      input: ViewerComposerInputSnapshot(
        eventType: eventType.value,
        contentJSON: content.value,
        ttlText: ttl.value,
        priority: priority,
        policy: policy,
        activeLimits: activeLimits
      )
    )
  }

  @discardableResult
  func apply(_ result: ViewerComposerPreparationResult) -> Bool {
    guard result.token == currentToken else { return false }
    switch result.outcome {
    case .success(let prepared, _):
      preparedEvent = prepared
      preparationFailure = nil
    case .failure(let error, _):
      preparedEvent = nil
      preparationFailure = error
    }
    return true
  }

  func clear() {
    generation = Self.saturatingIncrement(generation)
    eventType = ViewerIncrementalTextBuffer(maximumUTF8Bytes: textLimits.eventTypeBytes)
    content = ViewerIncrementalTextBuffer(maximumUTF8Bytes: textLimits.contentBytes)
    ttl = ViewerIncrementalTextBuffer(
      maximumUTF8Bytes: textLimits.ttlBytes,
      characterPolicy: .asciiDigits
    )
    priority = .normal
    policy = .normal
    preparedEvent = nil
    preparationFailure = nil
  }

  nonisolated var description: String { "ViewerControlComposerModel(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private func invalidatePreparation() {
    generation = Self.saturatingIncrement(generation)
    preparedEvent = nil
    preparationFailure = nil
  }

  private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? UInt64.max : value + 1
  }
}

extension ViewerIncrementalTextBuffer: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerIncrementalTextBuffer(redacted, bytes: \(utf8ByteCount))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["byteCount": utf8ByteCount], displayStyle: .struct)
  }
}

extension ViewerComposerInputSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerComposerInputSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerComposerPreparationRequest: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerComposerPreparationRequest(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExplorerOperatorTextBuffers: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerOperatorTextBuffers(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerComposerPreparationOutcome: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerComposerPreparationOutcome(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerComposerPreparationResult: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerComposerPreparationResult(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
