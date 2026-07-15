import Darwin
import Foundation
@_spi(NearWireInternal) import NearWireCore
import SQLite3

struct ViewerSessionImportSession: Decodable, Sendable {
  let startedAtMilliseconds: Int64
  let endedAtMilliseconds: Int64?
  let name: String?
  let note: String?
  let pinned: Bool
  let state: String
}

struct ViewerSessionImportDevice: Decodable, Sendable {
  let device: String
  let connection: String
  let startedAtMilliseconds: Int64
  let endedAtMilliseconds: Int64?
  let partialHistory: Bool
  let state: String
  let applicationIdentifier: String?
  let applicationVersion: String?
  let displayName: String?

  var referenceKey: String { "\(device)\u{1f}\(connection)" }
}

struct ViewerSessionImportEvent: Sendable {
  struct Causality: Decodable, Sendable {
    let correlationID: String?
    let replyTo: String?
  }

  let device: String
  let connection: String
  let direction: EventDirection
  let wireSequence: UInt64
  let eventID: String
  let eventType: String
  let content: JSONValue
  let createdAtMilliseconds: Int64
  let viewerReceivedAtMilliseconds: Int64
  let viewerMonotonicNanoseconds: UInt64
  let priority: EventPriority
  let disposition: String?
  let originMonotonicNanoseconds: UInt64
  let ttlMilliseconds: UInt64
  let eventSchemaVersion: UInt16
  let causality: Causality?

  var deviceReferenceKey: String { "\(device)\u{1f}\(connection)" }

  fileprivate init(record: ViewerSessionImportEventRecord, content: JSONValue) {
    device = record.device
    connection = record.connection
    direction = record.direction
    wireSequence = record.wireSequence
    eventID = record.eventID
    eventType = record.eventType
    self.content = content
    createdAtMilliseconds = record.createdAtMilliseconds
    viewerReceivedAtMilliseconds = record.viewerReceivedAtMilliseconds
    viewerMonotonicNanoseconds = record.viewerMonotonicNanoseconds
    priority = record.priority
    disposition = record.disposition
    originMonotonicNanoseconds = record.originMonotonicNanoseconds
    ttlMilliseconds = record.ttlMilliseconds
    eventSchemaVersion = record.eventSchemaVersion
    causality = record.causality
  }
}

fileprivate struct ViewerSessionImportEventRecord: Decodable {
  let device: String
  let connection: String
  let direction: EventDirection
  let wireSequence: UInt64
  let eventID: String
  let eventType: String
  let createdAtMilliseconds: Int64
  let viewerReceivedAtMilliseconds: Int64
  let viewerMonotonicNanoseconds: UInt64
  let priority: EventPriority
  let disposition: String?
  let originMonotonicNanoseconds: UInt64
  let ttlMilliseconds: UInt64
  let eventSchemaVersion: UInt16
  let causality: ViewerSessionImportEvent.Causality?
}

struct ViewerSessionImportGap: Decodable, Sendable {
  let createdAtMilliseconds: Int64
  let reason: String
  let count: Int64
  let firstViewerTimeMilliseconds: Int64
  let lastViewerTimeMilliseconds: Int64
  let directions: String
  let device: String?
  let connection: String?
  let firstWireSequence: UInt64?
  let lastWireSequence: UInt64?

  var deviceReferenceKey: String? {
    guard let device, let connection else { return nil }
    return "\(device)\u{1f}\(connection)"
  }
}

struct ViewerSessionImportAnnotation: Decodable, Sendable {
  let revision: Int64
  let createdAtMilliseconds: Int64
  let body: String
}

final class ViewerSessionImportCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func check() throws {
    if isCancelled { throw ViewerStoreError.cancelled }
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

enum ViewerSessionTransferLimits {
  static let maximumFileBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
  static let maximumDeviceCount: Int64 = 4_096
  static let maximumEventCount: Int64 = 2_000_000
  static let maximumGapCount: Int64 = 500_000
  static let maximumAnnotationCount: Int64 = 100_000

  static func validateCounts(
    deviceCount: Int64,
    eventCount: Int64,
    gapCount: Int64,
    annotationCount: Int64
  ) throws {
    guard deviceCount >= 0, deviceCount <= maximumDeviceCount,
      eventCount >= 0, eventCount <= maximumEventCount,
      gapCount >= 0, gapCount <= maximumGapCount,
      annotationCount >= 0, annotationCount <= maximumAnnotationCount
    else { throw ViewerStoreError.workLimitExceeded }
  }

  static func validateFileBytes(_ count: Int64) throws {
    guard count >= 0, count <= maximumFileBytes else {
      throw ViewerStoreError.workLimitExceeded
    }
  }
}

private final class ViewerMappedImportFile {
  let data: Data
  private let descriptor: Int32
  private let pointer: UnsafeMutableRawPointer
  private let count: Int
  private let snapshotURL: URL

  init(descriptor: Int32, pointer: UnsafeMutableRawPointer, count: Int, snapshotURL: URL) {
    self.descriptor = descriptor
    self.pointer = pointer
    self.count = count
    self.snapshotURL = snapshotURL
    data = Data(bytesNoCopy: pointer, count: count, deallocator: .none)
  }

  deinit {
    _ = munmap(pointer, count)
    _ = Darwin.close(descriptor)
    _ = unlink(snapshotURL.path)
  }
}

struct ViewerSessionImportDocument: @unchecked Sendable {
  let session: ViewerSessionImportSession
  private let storage: ViewerMappedImportFile
  private let data: Data
  private let members: [String: Range<Int>]
  private let cancellation: ViewerSessionImportCancellation
  private let structuralScanProgress: (Int) -> Void

  static func open(
    _ url: URL,
    maximumFileBytes: Int64,
    snapshotDirectory: URL,
    cancellation: ViewerSessionImportCancellation = ViewerSessionImportCancellation(),
    reserveSnapshotBytes: (Int64) throws -> Void = { _ in },
    structuralScanProgress: @escaping (Int) -> Void = { _ in }
  ) throws -> ViewerSessionImportDocument {
    guard url.isFileURL, maximumFileBytes > 0 else { throw ViewerStoreError.invalidPath }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ViewerStoreError.invalidPath }
    defer { _ = Darwin.close(descriptor) }

    var status = stat()
    guard fstat(descriptor, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_size > 0,
      status.st_size <= maximumFileBytes,
      status.st_size <= Int64(Int.max)
    else {
      throw ViewerStoreError.invalidValue
    }

    try reserveSnapshotBytes(status.st_size)
    try cancellation.check()
    let storage = try copyOwnedSnapshot(
      descriptor: descriptor,
      sourceStatus: status,
      directory: snapshotDirectory,
      cancellation: cancellation
    )
    return try ViewerSessionImportDocument(
      storage: storage,
      cancellation: cancellation,
      structuralScanProgress: structuralScanProgress
    )
  }

  private static func copyOwnedSnapshot(
    descriptor source: Int32,
    sourceStatus: stat,
    directory: URL,
    cancellation: ViewerSessionImportCancellation
  ) throws -> ViewerMappedImportFile {
    let snapshotURL = directory.appendingPathComponent(
      "NearWire-import.json.snapshot",
      isDirectory: false
    )
    let snapshot = Darwin.open(
      snapshotURL.path,
      O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard snapshot >= 0 else {
      throw errno == EEXIST ? ViewerStoreError.busy : ViewerStoreError.unavailable
    }

    var keepsSnapshot = false
    defer {
      if !keepsSnapshot {
        _ = Darwin.close(snapshot)
        _ = unlink(snapshotURL.path)
      }
    }

    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var copied: Int64 = 0
    while copied < sourceStatus.st_size {
      try cancellation.check()
      let requested = min(buffer.count, Int(sourceStatus.st_size - copied))
      let readCount = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(source, bytes.baseAddress, requested)
      }
      if readCount < 0, errno == EINTR { continue }
      guard readCount > 0 else { throw ViewerStoreError.invalidValue }

      var written = 0
      while written < readCount {
        let result = buffer.withUnsafeBytes { bytes in
          Darwin.write(snapshot, bytes.baseAddress?.advanced(by: written), readCount - written)
        }
        if result < 0, errno == EINTR { continue }
        guard result > 0 else { throw ViewerStoreError.unavailable }
        written += result
      }
      copied += Int64(readCount)
    }

    var finalSourceStatus = stat()
    guard fstat(source, &finalSourceStatus) == 0,
      finalSourceStatus.st_dev == sourceStatus.st_dev,
      finalSourceStatus.st_ino == sourceStatus.st_ino,
      finalSourceStatus.st_size == sourceStatus.st_size,
      finalSourceStatus.st_mtimespec.tv_sec == sourceStatus.st_mtimespec.tv_sec,
      finalSourceStatus.st_mtimespec.tv_nsec == sourceStatus.st_mtimespec.tv_nsec,
      fsync(snapshot) == 0,
      lseek(snapshot, 0, SEEK_SET) == 0
    else { throw ViewerStoreError.invalidValue }

    let count = Int(sourceStatus.st_size)
    guard let pointer = mmap(nil, count, PROT_READ, MAP_PRIVATE, snapshot, 0),
      pointer != MAP_FAILED
    else { throw ViewerStoreError.unavailable }
    keepsSnapshot = true
    return ViewerMappedImportFile(
      descriptor: snapshot,
      pointer: pointer,
      count: count,
      snapshotURL: snapshotURL
    )
  }

  private init(
    storage: ViewerMappedImportFile,
    cancellation: ViewerSessionImportCancellation,
    structuralScanProgress: @escaping (Int) -> Void
  ) throws {
    let data = storage.data
    let scanner = ViewerJSONStructureScanner(
      data: data,
      cancellation: cancellation,
      scanProgress: structuralScanProgress
    )
    let members = try scanner.rootObjectMembers()
    let required = Set([
      "schemaVersion", "scope", "disclosure", "session", "devices", "events", "gaps",
      "annotations",
    ])
    guard Set(members.keys) == required,
      try Self.decode(Int.self, from: data, range: members["schemaVersion"]) == 1,
      try Self.decode(String.self, from: data, range: members["scope"]) == "completeSession",
      let disclosureRange = members["disclosure"],
      try Self.decode(ViewerExportDisclosure.self, from: data, range: disclosureRange)
        .isSupportedForImport,
      let sessionRange = members["session"], sessionRange.count <= 64 * 1_024
    else { throw ViewerStoreError.unsupportedSchema }
    let session = try Self.decode(
      ViewerSessionImportSession.self,
      from: data,
      range: sessionRange
    )
    _ = try session.name.map(ViewerTextRules.recordingName)
    _ = try session.note.map(ViewerTextRules.noteOrAnnotation)
    guard ["active", "closed", "recoveredAfterInterruption"].contains(session.state),
      session.endedAtMilliseconds.map({ $0 >= session.startedAtMilliseconds }) ?? true
    else { throw ViewerStoreError.invalidValue }

    self.storage = storage
    self.data = data
    self.members = members
    self.session = session
    self.cancellation = cancellation
    self.structuralScanProgress = structuralScanProgress
  }

  func forEachDevice(
    _ body: (ViewerSessionImportDevice) throws -> Void
  ) throws {
    try forEach(
      "devices",
      maximumCount: Int(ViewerSessionTransferLimits.maximumDeviceCount),
      maximumRecordBytes: 16 * 1_024
    ) { range in
      let value = try Self.decode(ViewerSessionImportDevice.self, from: data, range: range)
      guard Self.validReference(value.device), Self.validReference(value.connection),
        ["active", "closed", "recoveredAfterInterruption"].contains(value.state),
        Self.validOptionalText(value.displayName, maximumBytes: 512),
        Self.validOptionalText(value.applicationIdentifier, maximumBytes: 512),
        Self.validOptionalText(value.applicationVersion, maximumBytes: 256)
      else { throw ViewerStoreError.invalidValue }
      try body(value)
    }
  }

  func forEachEvent(
    _ body: (ViewerSessionImportEvent) throws -> Void
  ) throws {
    try forEach(
      "events",
      maximumCount: Int(ViewerSessionTransferLimits.maximumEventCount),
      maximumRecordBytes: EventValidationLimits.default.maximumEncodedModelBytes
    ) { range in
      let record = Data(data[range])
      let eventMembers = try ViewerJSONStructureScanner(
        data: record,
        cancellation: cancellation
      ).rootObjectMembers()
      guard let contentRange = eventMembers["content"],
        contentRange.count <= EventValidationLimits.default.maximumEncodedContentBytes
      else {
        throw ViewerStoreError.invalidValue
      }
      let metadata = try Self.decode(
        ViewerSessionImportEventRecord.self,
        from: data,
        range: range
      )
      let content: JSONValue
      do {
        content = try JSONValue.decodeJSON(from: Data(record[contentRange]))
      } catch {
        throw ViewerStoreError.invalidValue
      }
      let value = ViewerSessionImportEvent(record: metadata, content: content)
      guard Self.validReference(value.device), Self.validReference(value.connection),
        !value.eventType.isEmpty,
        value.eventType.utf8.count <= EventValidationLimits.default.maximumTypeBytes
      else { throw ViewerStoreError.invalidValue }
      try body(value)
    }
  }

  func forEachGap(_ body: (ViewerSessionImportGap) throws -> Void) throws {
    try forEach(
      "gaps",
      maximumCount: Int(ViewerSessionTransferLimits.maximumGapCount),
      maximumRecordBytes: 16 * 1_024
    ) { range in
      let value = try Self.decode(ViewerSessionImportGap.self, from: data, range: range)
      let hasCompleteDeviceReference = (value.device == nil) == (value.connection == nil)
      guard hasCompleteDeviceReference,
        value.device.map(Self.validReference) ?? true,
        value.connection.map(Self.validReference) ?? true,
        !value.reason.isEmpty, value.reason.utf8.count <= 128,
        value.count > 0,
        value.firstViewerTimeMilliseconds <= value.lastViewerTimeMilliseconds,
        ["unknown", "appToViewer", "viewerToApp", "both"].contains(value.directions),
        (value.firstWireSequence == nil) == (value.lastWireSequence == nil),
        !(value.firstWireSequence.map { first in
          value.lastWireSequence.map { first > $0 } ?? false
        } ?? false)
      else { throw ViewerStoreError.invalidValue }
      try body(value)
    }
  }

  func forEachAnnotation(
    _ body: (ViewerSessionImportAnnotation) throws -> Void
  ) throws {
    try forEach(
      "annotations",
      maximumCount: Int(ViewerSessionTransferLimits.maximumAnnotationCount),
      maximumRecordBytes: 128 * 1_024
    ) { range in
      let value = try Self.decode(ViewerSessionImportAnnotation.self, from: data, range: range)
      guard value.revision > 0, !value.body.isEmpty, value.body.utf8.count <= 65_536 else {
        throw ViewerStoreError.invalidValue
      }
      try body(value)
    }
  }

  private func forEach(
    _ member: String,
    maximumCount: Int,
    maximumRecordBytes: Int,
    _ body: (Range<Int>) throws -> Void
  ) throws {
    guard let range = members[member] else { throw ViewerStoreError.invalidValue }
    try ViewerJSONStructureScanner(
      data: data,
      cancellation: cancellation,
      scanProgress: structuralScanProgress
    ).forEachArrayElement(
      in: range,
      maximumCount: maximumCount
    ) { valueRange in
      guard valueRange.count <= maximumRecordBytes else { throw ViewerStoreError.invalidValue }
      try body(valueRange)
    }
  }

  private static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    range: Range<Int>?
  ) throws -> T {
    guard let range else { throw ViewerStoreError.invalidValue }
    do {
      return try JSONDecoder().decode(type, from: Data(data[range]))
    } catch {
      throw ViewerStoreError.invalidValue
    }
  }

  private static func validReference(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
  }

  private static func validOptionalText(_ value: String?, maximumBytes: Int) -> Bool {
    guard let value else { return true }
    return !value.isEmpty && value.utf8.count <= maximumBytes
      && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
  }
}

private struct ViewerJSONStructureScanner {
  let data: Data
  let cancellation: ViewerSessionImportCancellation?
  let scanProgress: (Int) -> Void
  private let maximumDepth = 80
  private let cancellationCheckMask = (64 * 1_024) - 1

  init(
    data: Data,
    cancellation: ViewerSessionImportCancellation? = nil,
    scanProgress: @escaping (Int) -> Void = { _ in }
  ) {
    self.data = data
    self.cancellation = cancellation
    self.scanProgress = scanProgress
  }

  func rootObjectMembers() throws -> [String: Range<Int>] {
    var index = data.startIndex
    try skipWhitespace(&index)
    try expect(UInt8(ascii: "{"), at: &index)
    var members: [String: Range<Int>] = [:]
    try skipWhitespace(&index)
    if consume(UInt8(ascii: "}"), at: &index) {
      throw ViewerStoreError.invalidValue
    }
    while true {
      try skipWhitespace(&index)
      let keyRange = try scanString(at: &index)
      guard keyRange.count <= 128 else { throw ViewerStoreError.invalidValue }
      let key: String
      do {
        key = try JSONDecoder().decode(String.self, from: Data(data[keyRange]))
      } catch {
        throw ViewerStoreError.invalidValue
      }
      guard members[key] == nil else { throw ViewerStoreError.invalidValue }
      try skipWhitespace(&index)
      try expect(UInt8(ascii: ":"), at: &index)
      try skipWhitespace(&index)
      let valueStart = index
      try scanValue(at: &index)
      let valueRange = valueStart..<index
      switch key {
      case "schemaVersion":
        guard valueRange.count <= 32 else { throw ViewerStoreError.invalidValue }
      case "scope":
        guard valueRange.count <= 64 else { throw ViewerStoreError.invalidValue }
      case "disclosure":
        guard valueRange.count <= 8 * 1_024 else { throw ViewerStoreError.invalidValue }
      case "session":
        guard valueRange.count <= 64 * 1_024 else { throw ViewerStoreError.invalidValue }
      default:
        break
      }
      members[key] = valueRange
      try skipWhitespace(&index)
      if consume(UInt8(ascii: "}"), at: &index) { break }
      try expect(UInt8(ascii: ","), at: &index)
    }
    try skipWhitespace(&index)
    guard index == data.endIndex else { throw ViewerStoreError.invalidValue }
    return members
  }

  func forEachArrayElement(
    in range: Range<Int>,
    maximumCount: Int,
    _ body: (Range<Int>) throws -> Void
  ) throws {
    var index = range.lowerBound
    try skipWhitespace(&index, limit: range.upperBound)
    try expect(UInt8(ascii: "["), at: &index, limit: range.upperBound)
    try skipWhitespace(&index, limit: range.upperBound)
    if consume(UInt8(ascii: "]"), at: &index, limit: range.upperBound) {
      try skipWhitespace(&index, limit: range.upperBound)
      guard index == range.upperBound else { throw ViewerStoreError.invalidValue }
      return
    }
    var count = 0
    while true {
      guard count < maximumCount else { throw ViewerStoreError.invalidValue }
      let start = index
      try scanValue(at: &index, limit: range.upperBound)
      try body(start..<index)
      count += 1
      try skipWhitespace(&index, limit: range.upperBound)
      if consume(UInt8(ascii: "]"), at: &index, limit: range.upperBound) { break }
      try expect(UInt8(ascii: ","), at: &index, limit: range.upperBound)
      try skipWhitespace(&index, limit: range.upperBound)
    }
    try skipWhitespace(&index, limit: range.upperBound)
    guard index == range.upperBound else { throw ViewerStoreError.invalidValue }
  }

  private func scanValue(at index: inout Int, limit: Int? = nil) throws {
    let limit = limit ?? data.endIndex
    guard index < limit else { throw ViewerStoreError.invalidValue }
    switch data[index] {
    case UInt8(ascii: "\""):
      _ = try scanString(at: &index, limit: limit)
    case UInt8(ascii: "{"), UInt8(ascii: "["):
      try scanCompound(at: &index, limit: limit)
    default:
      let start = index
      while index < limit {
        try checkCancellation(at: index)
        let byte = data[index]
        if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "]")
          || byte == UInt8(ascii: "}") || Self.isWhitespace(byte)
        {
          break
        }
        index += 1
      }
      guard index > start else { throw ViewerStoreError.invalidValue }
    }
  }

  private func scanCompound(at index: inout Int, limit: Int) throws {
    var stack: [UInt8] = []
    while index < limit {
      try checkCancellation(at: index)
      let byte = data[index]
      if byte == UInt8(ascii: "\"") {
        _ = try scanString(at: &index, limit: limit)
        continue
      }
      index += 1
      if byte == UInt8(ascii: "{") {
        stack.append(UInt8(ascii: "}"))
      } else if byte == UInt8(ascii: "[") {
        stack.append(UInt8(ascii: "]"))
      } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
        guard stack.last == byte else { throw ViewerStoreError.invalidValue }
        stack.removeLast()
        if stack.isEmpty { return }
      }
      guard stack.count <= maximumDepth else { throw ViewerStoreError.invalidValue }
    }
    throw ViewerStoreError.invalidValue
  }

  private func scanString(at index: inout Int, limit: Int? = nil) throws -> Range<Int> {
    let limit = limit ?? data.endIndex
    let start = index
    try expect(UInt8(ascii: "\""), at: &index, limit: limit)
    var escaped = false
    while index < limit {
      try checkCancellation(at: index)
      let byte = data[index]
      index += 1
      if escaped {
        escaped = false
      } else if byte == UInt8(ascii: "\\") {
        escaped = true
      } else if byte == UInt8(ascii: "\"") {
        return start..<index
      } else if byte < 0x20 {
        throw ViewerStoreError.invalidValue
      }
    }
    throw ViewerStoreError.invalidValue
  }

  private func skipWhitespace(_ index: inout Int, limit: Int? = nil) throws {
    let limit = limit ?? data.endIndex
    while index < limit, Self.isWhitespace(data[index]) {
      try checkCancellation(at: index)
      index += 1
    }
  }

  private func checkCancellation(at index: Int) throws {
    if index & cancellationCheckMask == 0 {
      scanProgress(index)
      try cancellation?.check()
    }
  }

  private func expect(_ byte: UInt8, at index: inout Int, limit: Int? = nil) throws {
    guard consume(byte, at: &index, limit: limit) else { throw ViewerStoreError.invalidValue }
  }

  private func consume(_ byte: UInt8, at index: inout Int, limit: Int? = nil) -> Bool {
    let limit = limit ?? data.endIndex
    guard index < limit, data[index] == byte else { return false }
    index += 1
    return true
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
  }
}

struct ViewerExportSnapshot: Equatable, Sendable {
  let eventUpperRowID: Int64
  let recordingUpperRowID: Int64
  let deviceSessionUpperRowID: Int64
  let installationAliasUpperRowID: Int64
  let recordingVersionUpperRowID: Int64
  let deviceVersionUpperRowID: Int64
  let dispositionUpperRowID: Int64
  let gapUpperRowID: Int64
  let dropUpperRowID: Int64
  let annotationUpperRowID: Int64
}

struct ViewerCompleteExportScope: Equatable, Sendable {
  let recordingID: Int64
  let snapshot: ViewerExportSnapshot
}

struct ViewerExportDisclosure: Codable, Equatable, Sendable {
  let format: String
  let version: Int
  let warning: String
  let aliasesArePseudonymsNotRedaction: Bool
  let unencrypted: Bool
  let outsideViewerQuotaAndRetention: Bool
  let mayBeSyncedOrBackedUpByDestinationProvider: Bool

  static let current = ViewerExportDisclosure(
    format: "NearWire JSON Export",
    version: 1,
    warning:
      "Session metadata and notes, annotations and diagnostic gaps, Event metadata and content, and peer-provided App display name, identifier, and version are exported verbatim and can contain identifying or sensitive data.",
    aliasesArePseudonymsNotRedaction: true,
    unencrypted: true,
    outsideViewerQuotaAndRetention: true,
    mayBeSyncedOrBackedUpByDestinationProvider: true
  )

  var isSupportedForImport: Bool {
    format == Self.current.format
      && version == Self.current.version
      && aliasesArePseudonymsNotRedaction
      && unencrypted
      && outsideViewerQuotaAndRetention
      && mayBeSyncedOrBackedUpByDestinationProvider
  }
}

enum ViewerExportFilePhase: CaseIterable, Equatable, Sendable {
  case temporaryCreated
  case beforeOpen
  case beforeWrite
  case afterWrite
  case beforeFileSync
  case afterFileSync
  case beforeClose
  case afterClose
  case beforeCommitSeal
  case beforeDirectoryOpen
  case beforeRename
  case afterRename
  case directorySync
}

struct ViewerExportFilePhaseObserver: Sendable {
  static let live = ViewerExportFilePhaseObserver { _ in }

  let reach: @Sendable (ViewerExportFilePhase) throws -> Void

  init(_ reach: @escaping @Sendable (ViewerExportFilePhase) throws -> Void) {
    self.reach = reach
  }
}

private final class ViewerExportCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var nextGeneration: UInt64 = 1
  private var activeGeneration: UInt64?
  private var activeOperationID: UUID?
  private var cancelledGeneration: UInt64?
  private var committingGeneration: UInt64?

  func begin(operationID: UUID?) throws -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    guard activeGeneration == nil else { throw ViewerStoreError.busy }
    let generation = nextGeneration
    nextGeneration = nextGeneration == UInt64.max ? 1 : nextGeneration + 1
    activeGeneration = generation
    activeOperationID = operationID
    cancelledGeneration = nil
    return generation
  }

  func cancelActive() {
    lock.lock()
    if committingGeneration != activeGeneration {
      cancelledGeneration = activeGeneration
    }
    lock.unlock()
  }

  func cancel(operationID: UUID) {
    lock.lock()
    if activeOperationID == operationID, committingGeneration != activeGeneration {
      cancelledGeneration = activeGeneration
    }
    lock.unlock()
  }

  func beginCommit(
    _ generation: UInt64,
    validatingLease: () throws -> Void
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard activeGeneration == generation, cancelledGeneration != generation,
      committingGeneration == nil
    else { throw ViewerStoreError.cancelled }
    try validatingLease()
    committingGeneration = generation
  }

  func check(_ generation: UInt64) throws {
    lock.lock()
    let cancelled = cancelledGeneration == generation || activeGeneration != generation
    lock.unlock()
    if cancelled { throw ViewerStoreError.cancelled }
  }

  func finish(_ generation: UInt64) {
    lock.lock()
    if activeGeneration == generation { activeGeneration = nil }
    if activeGeneration == nil { activeOperationID = nil }
    if cancelledGeneration == generation { cancelledGeneration = nil }
    if committingGeneration == generation { committingGeneration = nil }
    lock.unlock()
  }
}

final class ViewerStoreExportService: @unchecked Sendable {
  private static let pageSize = 200
  private static let maximumBufferBytes = 64 * 1_024

  private let pool: ViewerSQLitePool
  private let leases: ViewerStoreLeaseRegistry
  private let filePhases: ViewerExportFilePhaseObserver
  private let maximumCompleteFileBytes: Int64
  private let cancellation = ViewerExportCancellation()

  private final class ByteBudget {
    private let maximumBytes: Int64
    private var writtenBytes: Int64 = 0

    init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }

    func reserve(_ count: Int) throws {
      guard count >= 0 else { throw ViewerStoreError.invalidValue }
      let (next, overflow) = writtenBytes.addingReportingOverflow(Int64(count))
      guard !overflow, next <= maximumBytes else {
        throw ViewerStoreError.workLimitExceeded
      }
      writtenBytes = next
    }
  }

  private struct SecureTemporary {
    let parentDescriptor: Int32
    let parentPath: String
    let fileDescriptor: Int32
    let temporaryLeaf: String
    let destinationLeaf: String
  }

  init(
    pool: ViewerSQLitePool,
    leases: ViewerStoreLeaseRegistry,
    filePhases: ViewerExportFilePhaseObserver = .live,
    maximumCompleteFileBytes: Int64 = ViewerSessionTransferLimits.maximumFileBytes
  ) {
    precondition((1...ViewerSessionTransferLimits.maximumFileBytes).contains(maximumCompleteFileBytes))
    self.pool = pool
    self.leases = leases
    self.filePhases = filePhases
    self.maximumCompleteFileBytes = maximumCompleteFileBytes
  }

  func preflight(recordingID: Int64, operationID: UUID? = nil) throws -> (
    eventCount: Int64, disclosure: ViewerExportDisclosure
  ) {
    let recordingID = try validated(recordingID)
    let count = try pool.exportReader.run(operationID: operationID, budget: .export()) {
      database in
      try requireVisibleRecording(recordingID, database: database)
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT COUNT(*) FROM Events WHERE recordingID=?1 AND recordingID NOT IN (SELECT recordingID FROM Tombstones)"
      )
      try statement.bind(recordingID, at: 1)
      guard try statement.step() else { throw ViewerStoreError.corruptStore }
      return statement.int64(at: 0)
    }
    return (count, .current)
  }

  func makeCompleteScope(
    recordingID: Int64,
    operationID: UUID? = nil
  ) throws -> ViewerCompleteExportScope {
    let recordingID = try validated(recordingID)
    let snapshot = try captureSnapshot(querySnapshot: nil, operationID: operationID)
    return ViewerCompleteExportScope(recordingID: recordingID, snapshot: snapshot)
  }

  func preflight(
    scope: ViewerCompleteExportScope,
    operationID: UUID? = nil
  ) throws -> (eventCount: Int64, disclosure: ViewerExportDisclosure) {
    let recordingID = try validated(scope.recordingID)
    let count = try pool.exportReader.run(operationID: operationID, budget: .export()) {
      database in
      try requireVisibleRecording(recordingID, database: database)
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql: "SELECT COUNT(*) FROM Events WHERE recordingID=?1 AND rowID<=?2"
      )
      try statement.bind(recordingID, at: 1)
      try statement.bind(scope.snapshot.eventUpperRowID, at: 2)
      guard try statement.step() else { throw ViewerStoreError.corruptStore }
      return statement.int64(at: 0)
    }
    return (count, .current)
  }

  func preflight(
    traversal: ViewerEventTraversal,
    operationID: UUID? = nil
  ) throws -> (eventCount: Int64, disclosure: ViewerExportDisclosure) {
    try leases.validateQuery(traversal.lease)
    let compiled = try ViewerEventQueryCompiler.compile(traversal.query)
    let count = try pool.exportReader.run(operationID: operationID, budget: .export()) {
      database in
      try requireVisibleRecording(traversal.query.recordingID, database: database)
      let sql =
        "SELECT COUNT(*) FROM Events e WHERE e.recordingID=? AND e.rowID<=? AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones) AND \(compiled.predicateSQL)"
      let bindStatement: (ViewerSQLiteStatement) throws -> Void = { statement in
        try self.bindQuery(
          recordingID: traversal.query.recordingID,
          eventUpperRowID: traversal.snapshot.eventUpperRowID,
          compiled: compiled,
          querySnapshot: traversal.snapshot,
          to: statement,
          startingAt: 1
        )
      }
      try ViewerQueryPlanGate.validate(sql: sql, database: database, bind: bindStatement)
      let statement = try ViewerSQLiteStatement(database: database, sql: sql)
      try bindStatement(statement)
      guard try statement.step() else { throw ViewerStoreError.corruptStore }
      return statement.int64(at: 0)
    }
    return (count, .current)
  }

  func preflight(
    scope: ViewerFilteredExportScope,
    operationID: UUID? = nil
  ) throws -> (eventCount: Int64, disclosure: ViewerExportDisclosure) {
    let compiled = try ViewerEventQueryCompiler.compile(scope.query)
    let count = try pool.exportReader.run(operationID: operationID, budget: .export()) {
      database in
      try requireVisibleRecording(scope.query.recordingID, database: database)
      let sql =
        "SELECT COUNT(*) FROM Events e WHERE e.recordingID=? AND e.rowID<=? AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones) AND \(compiled.predicateSQL)"
      let bindStatement: (ViewerSQLiteStatement) throws -> Void = { statement in
        try self.bindQuery(
          recordingID: scope.query.recordingID,
          eventUpperRowID: scope.snapshot.eventUpperRowID,
          compiled: compiled,
          querySnapshot: scope.snapshot,
          to: statement,
          startingAt: 1
        )
      }
      try ViewerQueryPlanGate.validate(sql: sql, database: database, bind: bindStatement)
      let statement = try ViewerSQLiteStatement(database: database, sql: sql)
      try bindStatement(statement)
      guard try statement.step() else { throw ViewerStoreError.corruptStore }
      return statement.int64(at: 0)
    }
    return (count, .current)
  }

  func export(
    recordingID: Int64,
    to destination: URL,
    operationID: UUID? = nil
  ) throws {
    try export(
      recordingID: validated(recordingID),
      compiledQuery: nil,
      querySnapshot: nil,
      fixedSnapshot: nil,
      to: destination,
      operationID: operationID
    )
  }

  func export(
    scope: ViewerCompleteExportScope,
    to destination: URL,
    operationID: UUID? = nil
  ) throws {
    try export(
      recordingID: validated(scope.recordingID),
      compiledQuery: nil,
      querySnapshot: nil,
      fixedSnapshot: scope.snapshot,
      to: destination,
      operationID: operationID
    )
  }

  func export(
    traversal: ViewerEventTraversal,
    to destination: URL,
    operationID: UUID? = nil
  ) throws {
    try leases.validateQuery(traversal.lease)
    try export(
      recordingID: traversal.query.recordingID,
      compiledQuery: ViewerEventQueryCompiler.compile(traversal.query),
      querySnapshot: traversal.snapshot,
      fixedSnapshot: nil,
      to: destination,
      operationID: operationID
    )
  }

  func export(
    scope: ViewerFilteredExportScope,
    to destination: URL,
    operationID: UUID? = nil
  ) throws {
    try export(
      recordingID: scope.query.recordingID,
      compiledQuery: ViewerEventQueryCompiler.compile(scope.query),
      querySnapshot: scope.snapshot,
      fixedSnapshot: nil,
      to: destination,
      operationID: operationID
    )
  }

  private func export(
    recordingID: Int64,
    compiledQuery: ViewerCompiledQuery?,
    querySnapshot: ViewerQuerySnapshot?,
    fixedSnapshot: ViewerExportSnapshot?,
    to destination: URL,
    operationID: UUID?
  ) throws {
    let generation = try cancellation.begin(operationID: operationID)
    defer { cancellation.finish(generation) }
    let lease = try leases.acquireExport(recordingID: recordingID)
    defer { leases.release(lease) }
    let snapshot =
      try fixedSnapshot
      ?? captureSnapshot(querySnapshot: querySnapshot, operationID: operationID)
    try validate(lease: lease, generation: generation)
    if compiledQuery == nil {
      try validateCompleteSessionBounds(
        recordingID: recordingID,
        snapshot: snapshot,
        operationID: operationID
      )
    }
    let temporary = try secureTemporarySibling(for: destination)
    var committed = false
    defer {
      if !committed {
        _ = temporary.temporaryLeaf.withCString {
          unlinkat(temporary.parentDescriptor, $0, 0)
        }
      }

      _ = close(temporary.fileDescriptor)
      _ = close(temporary.parentDescriptor)
    }
    try filePhases.reach(.temporaryCreated)
    try filePhases.reach(.beforeOpen)
    let writeDescriptor = dup(temporary.fileDescriptor)
    guard writeDescriptor >= 0 else { throw ViewerStoreError.invalidPath }
    let handle = FileHandle(fileDescriptor: writeDescriptor, closeOnDealloc: true)
    do {
      try filePhases.reach(.beforeWrite)
      try writeExport(
        recordingID: recordingID,
        snapshot: snapshot,
        compiledQuery: compiledQuery,
        querySnapshot: querySnapshot,
        lease: lease,
        generation: generation,
        handle: handle,
        operationID: operationID
      )
      if compiledQuery == nil {
        var status = stat()
        guard fstat(temporary.fileDescriptor, &status) == 0 else {
          throw ViewerStoreError.invalidPath
        }
        guard status.st_size <= maximumCompleteFileBytes else {
          throw ViewerStoreError.workLimitExceeded
        }
      }
      try filePhases.reach(.afterWrite)
      try validate(lease: lease, generation: generation)
      try filePhases.reach(.beforeFileSync)
      try handle.synchronize()
      try filePhases.reach(.afterFileSync)
      try validate(lease: lease, generation: generation)
      try filePhases.reach(.beforeClose)
      try handle.close()
      try filePhases.reach(.afterClose)
      try validateTemporary(temporary)
      try validate(lease: lease, generation: generation)
      try filePhases.reach(.beforeCommitSeal)
      try cancellation.beginCommit(generation) {
        try leases.validateExport(lease)
      }
      try atomicReplace(temporary)
      committed = true
    } catch {
      try? handle.close()
      throw error
    }
  }

  func cancel() {
    cancellation.cancelActive()
    pool.exportReader.cancelCurrentOperation()
  }

  func cancel(operationID: UUID) {
    cancellation.cancel(operationID: operationID)
    pool.exportReader.cancel(operationID: operationID)
  }

  func clearCancellation(operationID: UUID) {
    pool.exportReader.clearCancellation(operationID: operationID)
  }

  var cancelledOperationCountForTesting: Int {
    pool.exportReader.cancelledOperationCountForTesting
  }

  private func writeExport(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    compiledQuery: ViewerCompiledQuery?,
    querySnapshot: ViewerQuerySnapshot?,
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64,
    handle: FileHandle,
    operationID: UUID?
  ) throws {
    let disclosure = try ViewerCanonicalJSON.encode(ViewerExportDisclosure.current)
    let scope = compiledQuery == nil ? "completeSession" : "filteredResult"
    let byteBudget = compiledQuery == nil ? ByteBudget(maximumBytes: maximumCompleteFileBytes) : nil
    try write(
      Data("{\"schemaVersion\":1,\"scope\":\"\(scope)\",\"disclosure\":".utf8),
      to: handle,
      generation: generation,
      byteBudget: byteBudget
    )
    try write(disclosure, to: handle, generation: generation, byteBudget: byteBudget)
    try write(
      Data(",\"session\":".utf8), to: handle, generation: generation, byteBudget: byteBudget)
    try writeSession(
      recordingID: recordingID, snapshot: snapshot, handle: handle, generation: generation,
      operationID: operationID, byteBudget: byteBudget)
    try write(
      Data(",\"devices\":[".utf8), to: handle, generation: generation, byteBudget: byteBudget)
    try writeDevices(
      recordingID: recordingID, snapshot: snapshot, handle: handle, lease: lease,
      generation: generation, operationID: operationID, byteBudget: byteBudget)
    try write(
      Data("],\"events\":[".utf8), to: handle, generation: generation, byteBudget: byteBudget)
    try writeEvents(
      recordingID: recordingID,
      snapshot: snapshot,
      compiledQuery: compiledQuery,
      querySnapshot: querySnapshot,
      handle: handle,
      lease: lease,
      generation: generation,
      operationID: operationID,
      byteBudget: byteBudget
    )
    try write(
      Data("],\"gaps\":[".utf8), to: handle, generation: generation, byteBudget: byteBudget)
    try writeGaps(
      recordingID: recordingID, snapshot: snapshot, handle: handle, lease: lease,
      generation: generation, operationID: operationID, byteBudget: byteBudget)
    try write(
      Data("],\"annotations\":[".utf8), to: handle, generation: generation,
      byteBudget: byteBudget)
    try writeAnnotations(
      recordingID: recordingID, snapshot: snapshot, handle: handle, lease: lease,
      generation: generation, operationID: operationID, byteBudget: byteBudget)
    try write(Data("]}".utf8), to: handle, generation: generation, byteBudget: byteBudget)
  }

  private func writeDevices(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    handle: FileHandle,
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64,
    operationID: UUID?,
    byteBudget: ByteBudget?
  ) throws {
    var cursor: Int64 = 0
    var first = true
    while true {
      try validate(lease: lease, generation: generation)
      let rows: [Data] = try pool.exportReader.run(
        operationID: operationID,
        budget: .export()
      ) { database in
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT d.rowID,a.ordinal,d.connectionOrdinal,d.startedWallMs,v.endedWallMs,v.partialHistory,d.applicationIdentifier,d.applicationVersion,v.displayName,v.state FROM DeviceSessions d JOIN InstallationAliases a ON a.rowID=d.installationAliasID JOIN DeviceSessionVersions v ON v.deviceSessionID=d.rowID WHERE d.recordingID=?1 AND d.recordingID<=?2 AND d.rowID>?3 AND d.rowID<=?4 AND a.rowID<=?5 AND v.rowID=(SELECT MAX(v2.rowID) FROM DeviceSessionVersions v2 WHERE v2.deviceSessionID=d.rowID AND v2.rowID<=?6) AND d.recordingID NOT IN (SELECT recordingID FROM Tombstones) ORDER BY d.rowID LIMIT ?7"
        )
        try statement.bind(recordingID, at: 1)
        try statement.bind(snapshot.recordingUpperRowID, at: 2)
        try statement.bind(cursor, at: 3)
        try statement.bind(snapshot.deviceSessionUpperRowID, at: 4)
        try statement.bind(snapshot.installationAliasUpperRowID, at: 5)
        try statement.bind(snapshot.deviceVersionUpperRowID, at: 6)
        try statement.bind(Int64(Self.pageSize), at: 7)
        var page: [Data] = []
        while try statement.step() {
          var object: [String: Any] = [
            "device": "device-\(statement.int64(at: 1))",
            "connection": "connection-\(statement.int64(at: 2))",
            "startedAtMilliseconds": statement.int64(at: 3),
            "partialHistory": statement.int64(at: 5) != 0,
            "state": statement.string(at: 9),
          ]
          if !statement.isNull(at: 4) { object["endedAtMilliseconds"] = statement.int64(at: 4) }
          if !statement.isNull(at: 6) { object["applicationIdentifier"] = statement.string(at: 6) }
          if !statement.isNull(at: 7) { object["applicationVersion"] = statement.string(at: 7) }
          if !statement.isNull(at: 8) { object["displayName"] = statement.string(at: 8) }
          page.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
          cursor = statement.int64(at: 0)
        }
        return page
      }
      guard !rows.isEmpty else { break }
      for row in rows {
        if !first {
          try write(Data(",".utf8), to: handle, generation: generation, byteBudget: byteBudget)
        }
        try write(row, to: handle, generation: generation, byteBudget: byteBudget)
        first = false
      }
    }
  }

  private func writeEvents(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    compiledQuery: ViewerCompiledQuery?,
    querySnapshot: ViewerQuerySnapshot?,
    handle: FileHandle,
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64,
    operationID: UUID?,
    byteBudget: ByteBudget?
  ) throws {
    var cursorMonotonic: Int64 = -1
    var cursorRowID: Int64 = 0
    var first = true
    while true {
      try validate(lease: lease, generation: generation)
      let rows: [(Int64, Int64, Data)] = try pool.exportReader.run(
        operationID: operationID,
        budget: .export()
      ) { database in
        let predicateSQL = compiledQuery.map { " AND \($0.predicateSQL)" } ?? ""
        let sql =
          "SELECT e.rowID,a.ordinal,d.connectionOrdinal,e.direction,e.wireSequence,e.eventUUID,e.eventType,e.contentJSON,e.createdWallMs,e.viewerWallMs,e.viewerMonotonicNs,e.priority,(SELECT disposition FROM EventDispositionVersions x WHERE x.eventID=e.rowID AND x.rowID<=? ORDER BY x.rowID DESC LIMIT 1),e.originMonotonicNs,e.ttlMs,e.schemaVersion,e.correlationEventUUID,e.replyToEventUUID FROM Events e JOIN DeviceSessions d ON d.rowID=e.deviceSessionID JOIN InstallationAliases a ON a.rowID=d.installationAliasID WHERE e.recordingID=? AND e.recordingID<=? AND e.rowID<=? AND d.rowID<=? AND a.rowID<=?\(predicateSQL) AND (e.viewerMonotonicNs>? OR (e.viewerMonotonicNs=? AND e.rowID>?)) AND e.recordingID NOT IN (SELECT recordingID FROM Tombstones) ORDER BY e.viewerMonotonicNs,e.rowID LIMIT 1"
        let bindStatement: (ViewerSQLiteStatement) throws -> Void = { statement in
          var index: Int32 = 1
          try statement.bind(snapshot.dispositionUpperRowID, at: index)
          index += 1
          try statement.bind(recordingID, at: index)
          index += 1
          try statement.bind(snapshot.recordingUpperRowID, at: index)
          index += 1
          try statement.bind(snapshot.eventUpperRowID, at: index)
          index += 1
          try statement.bind(snapshot.deviceSessionUpperRowID, at: index)
          index += 1
          try statement.bind(snapshot.installationAliasUpperRowID, at: index)
          index += 1
          if let compiledQuery, let querySnapshot {
            index = try self.bindCompiledQuery(
              compiledQuery,
              querySnapshot: querySnapshot,
              to: statement,
              startingAt: index
            )
          }
          try statement.bind(cursorMonotonic, at: index)
          index += 1
          try statement.bind(cursorMonotonic, at: index)
          index += 1
          try statement.bind(cursorRowID, at: index)
        }
        try ViewerQueryPlanGate.validate(sql: sql, database: database, bind: bindStatement)
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql: sql
        )
        try bindStatement(statement)
        var page: [(Int64, Int64, Data)] = []
        while try statement.step() {
          let prefixObject: [String: Any] = [
            "device": "device-\(statement.int64(at: 1))",
            "connection": "connection-\(statement.int64(at: 2))",
            "direction": statement.string(at: 3),
            "wireSequence": statement.int64(at: 4),
            "eventID": statement.string(at: 5),
            "eventType": statement.string(at: 6),
            "createdAtMilliseconds": statement.int64(at: 8),
            "viewerReceivedAtMilliseconds": statement.int64(at: 9),
            "viewerMonotonicNanoseconds": statement.int64(at: 10),
            "priority": statement.string(at: 11),
            "originMonotonicNanoseconds": statement.int64(at: 13),
            "ttlMilliseconds": statement.int64(at: 14),
            "eventSchemaVersion": statement.int64(at: 15),
          ]
          var object = prefixObject
          if !statement.isNull(at: 12) { object["disposition"] = statement.string(at: 12) }
          var causality: [String: String] = [:]
          if !statement.isNull(at: 16) { causality["correlationID"] = statement.string(at: 16) }
          if !statement.isNull(at: 17) { causality["replyTo"] = statement.string(at: 17) }
          if !causality.isEmpty { object["causality"] = causality }
          var prefix = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
          guard prefix.last == UInt8(ascii: "}") else { throw ViewerStoreError.corruptStore }
          prefix.removeLast()
          prefix.append(contentsOf: Data(",\"content\":".utf8))
          prefix.append(statement.data(at: 7))
          prefix.append(UInt8(ascii: "}"))
          guard prefix.count <= 20 * 1_024 * 1_024 else { throw ViewerStoreError.invalidValue }
          page.append((statement.int64(at: 0), statement.int64(at: 10), prefix))
        }
        return page
      }
      guard !rows.isEmpty else { break }
      for (rowID, monotonic, row) in rows {
        if !first {
          try write(Data(",".utf8), to: handle, generation: generation, byteBudget: byteBudget)
        }
        try write(row, to: handle, generation: generation, byteBudget: byteBudget)
        first = false
        cursorRowID = rowID
        cursorMonotonic = monotonic
      }
    }
  }

  private func writeSession(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    handle: FileHandle,
    generation: UInt64,
    operationID: UUID?,
    byteBudget: ByteBudget?
  ) throws {
    let row: Data = try pool.exportReader.run(operationID: operationID, budget: .export()) {
      database in
      let statement = try ViewerSQLiteStatement(
        database: database,
        sql:
          "SELECT r.startedWallMs,v.endedWallMs,v.name,v.note,v.pinned,v.state FROM Recordings r JOIN RecordingVersions v ON v.recordingID=r.rowID WHERE r.rowID=?1 AND r.rowID<=?2 AND v.rowID=(SELECT MAX(v2.rowID) FROM RecordingVersions v2 WHERE v2.recordingID=r.rowID AND v2.rowID<=?3) AND r.rowID NOT IN (SELECT recordingID FROM Tombstones)"
      )
      try statement.bind(recordingID, at: 1)
      try statement.bind(snapshot.recordingUpperRowID, at: 2)
      try statement.bind(snapshot.recordingVersionUpperRowID, at: 3)
      guard try statement.step() else { throw ViewerStoreError.invalidValue }
      var object: [String: Any] = [
        "startedAtMilliseconds": statement.int64(at: 0),
        "pinned": statement.int64(at: 4) != 0,
        "state": statement.string(at: 5),
      ]
      if !statement.isNull(at: 1) { object["endedAtMilliseconds"] = statement.int64(at: 1) }
      if !statement.isNull(at: 2) { object["name"] = statement.string(at: 2) }
      if !statement.isNull(at: 3) { object["note"] = statement.string(at: 3) }
      return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    try write(row, to: handle, generation: generation, byteBudget: byteBudget)
  }

  private func writeGaps(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    handle: FileHandle,
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64,
    operationID: UUID?,
    byteBudget: ByteBudget?
  ) throws {
    var cursor: Int64 = 0
    var first = true
    while true {
      try validate(lease: lease, generation: generation)
      let rows: [(Int64, Data)] = try pool.exportReader.run(
        operationID: operationID,
        budget: .export()
      ) { database in
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT g.rowID,g.createdWallMs,g.reason,g.count,d.connectionOrdinal,a.ordinal,g.firstViewerWallMs,g.lastViewerWallMs,g.directions,g.firstWireSequence,g.lastWireSequence FROM GapVersions g LEFT JOIN DeviceSessions d ON d.rowID=g.deviceSessionID AND d.rowID<=?1 LEFT JOIN InstallationAliases a ON a.rowID=d.installationAliasID AND a.rowID<=?2 WHERE g.recordingID=?3 AND g.rowID>?4 AND g.rowID<=?5 AND g.rowID=(SELECT MAX(g2.rowID) FROM GapVersions g2 WHERE g2.recordingID=g.recordingID AND g2.deviceSessionID IS g.deviceSessionID AND g2.sequence=g.sequence AND g2.namespace=g.namespace AND g2.rowID<=?5) ORDER BY g.rowID LIMIT ?6"
        )
        try statement.bind(snapshot.deviceSessionUpperRowID, at: 1)
        try statement.bind(snapshot.installationAliasUpperRowID, at: 2)
        try statement.bind(recordingID, at: 3)
        try statement.bind(cursor, at: 4)
        try statement.bind(snapshot.gapUpperRowID, at: 5)
        try statement.bind(Int64(Self.pageSize), at: 6)
        var page: [(Int64, Data)] = []
        while try statement.step() {
          var object: [String: Any] = [
            "createdAtMilliseconds": statement.int64(at: 1),
            "reason": statement.string(at: 2),
            "count": statement.int64(at: 3),
            "firstViewerTimeMilliseconds": statement.int64(at: 6),
            "lastViewerTimeMilliseconds": statement.int64(at: 7),
            "directions": statement.string(at: 8),
          ]
          if !statement.isNull(at: 4) {
            object["connection"] = "connection-\(statement.int64(at: 4))"
          }
          if !statement.isNull(at: 5) { object["device"] = "device-\(statement.int64(at: 5))" }
          if !statement.isNull(at: 9) { object["firstWireSequence"] = statement.int64(at: 9) }
          if !statement.isNull(at: 10) { object["lastWireSequence"] = statement.int64(at: 10) }
          page.append(
            (
              statement.int64(at: 0),
              try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            ))
        }
        return page
      }
      guard !rows.isEmpty else { break }
      for (rowID, row) in rows {
        if !first {
          try write(Data(",".utf8), to: handle, generation: generation, byteBudget: byteBudget)
        }
        try write(row, to: handle, generation: generation, byteBudget: byteBudget)
        first = false
        cursor = rowID
      }
    }
  }

  private func writeAnnotations(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    handle: FileHandle,
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64,
    operationID: UUID?,
    byteBudget: ByteBudget?
  ) throws {
    var cursor: Int64 = 0
    var first = true
    while true {
      try validate(lease: lease, generation: generation)
      let rows: [(Int64, Data)] = try pool.exportReader.run(
        operationID: operationID,
        budget: .export()
      ) { database in
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql:
            "SELECT rowID,revision,createdWallMs,body FROM AnnotationVersions WHERE recordingID=?1 AND rowID>?2 AND rowID<=?3 ORDER BY rowID LIMIT ?4"
        )
        try statement.bind(recordingID, at: 1)
        try statement.bind(cursor, at: 2)
        try statement.bind(snapshot.annotationUpperRowID, at: 3)
        try statement.bind(Int64(Self.pageSize), at: 4)
        var page: [(Int64, Data)] = []
        while try statement.step() {
          let object: [String: Any] = [
            "revision": statement.int64(at: 1),
            "createdAtMilliseconds": statement.int64(at: 2),
            "body": statement.string(at: 3),
          ]
          page.append(
            (
              statement.int64(at: 0),
              try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            ))
        }
        return page
      }
      guard !rows.isEmpty else { break }
      for (rowID, row) in rows {
        if !first {
          try write(Data(",".utf8), to: handle, generation: generation, byteBudget: byteBudget)
        }
        try write(row, to: handle, generation: generation, byteBudget: byteBudget)
        first = false
        cursor = rowID
      }
    }
  }

  private func captureSnapshot(
    querySnapshot: ViewerQuerySnapshot?,
    operationID: UUID?
  ) throws -> ViewerExportSnapshot {
    try pool.exportReader.run(operationID: operationID, budget: .export()) { database in
      try ViewerSQLiteConnection.execute("BEGIN", on: database)
      defer { try? ViewerSQLiteConnection.execute("COMMIT", on: database) }
      return ViewerExportSnapshot(
        eventUpperRowID: min(
          try maximum("Events", database: database),
          querySnapshot?.eventUpperRowID ?? Int64.max
        ),
        recordingUpperRowID: try maximum("Recordings", database: database),
        deviceSessionUpperRowID: try maximum("DeviceSessions", database: database),
        installationAliasUpperRowID: try maximum("InstallationAliases", database: database),
        recordingVersionUpperRowID: min(
          try maximum("RecordingVersions", database: database),
          querySnapshot?.recordingVersionUpperRowID ?? Int64.max
        ),
        deviceVersionUpperRowID: min(
          try maximum("DeviceSessionVersions", database: database),
          querySnapshot?.deviceVersionUpperRowID ?? Int64.max
        ),
        dispositionUpperRowID: min(
          try maximum("EventDispositionVersions", database: database),
          querySnapshot?.dispositionUpperRowID ?? Int64.max
        ),
        gapUpperRowID: min(
          try maximum("GapVersions", database: database),
          querySnapshot?.gapUpperRowID ?? Int64.max
        ),
        dropUpperRowID: min(
          try maximum("DropVersions", database: database),
          querySnapshot?.dropUpperRowID ?? Int64.max
        ),
        annotationUpperRowID: try maximum("AnnotationVersions", database: database)
      )
    }
  }

  private func validateCompleteSessionBounds(
    recordingID: Int64,
    snapshot: ViewerExportSnapshot,
    operationID: UUID?
  ) throws {
    let counts = try pool.exportReader.run(operationID: operationID, budget: .export()) {
      database -> (Int64, Int64, Int64, Int64) in
      func count(_ table: String, upperRowID: Int64) throws -> Int64 {
        let statement = try ViewerSQLiteStatement(
          database: database,
          sql: "SELECT COUNT(*) FROM \(table) WHERE recordingID=?1 AND rowID<=?2"
        )
        try statement.bind(recordingID, at: 1)
        try statement.bind(upperRowID, at: 2)
        guard try statement.step() else { throw ViewerStoreError.corruptStore }
        return statement.int64(at: 0)
      }
      return (
        try count("DeviceSessions", upperRowID: snapshot.deviceSessionUpperRowID),
        try count("Events", upperRowID: snapshot.eventUpperRowID),
        try count("GapVersions", upperRowID: snapshot.gapUpperRowID),
        try count("AnnotationVersions", upperRowID: snapshot.annotationUpperRowID)
      )
    }
    try ViewerSessionTransferLimits.validateCounts(
      deviceCount: counts.0,
      eventCount: counts.1,
      gapCount: counts.2,
      annotationCount: counts.3
    )
  }

  private func maximum(_ table: String, database: OpaquePointer) throws -> Int64 {
    try ViewerStoreSchema.scalarInt64(
      "SELECT COALESCE(MAX(rowID),0) FROM \(table)", database: database)
  }

  private func validated(_ recordingID: Int64) throws -> Int64 {
    guard recordingID > 0 else { throw ViewerStoreError.invalidValue }
    return recordingID
  }

  private func requireVisibleRecording(
    _ recordingID: Int64,
    database: OpaquePointer
  ) throws {
    let statement = try ViewerSQLiteStatement(
      database: database,
      sql:
        "SELECT 1 FROM Recordings WHERE rowID=?1 AND rowID NOT IN (SELECT recordingID FROM Tombstones)"
    )
    try statement.bind(recordingID, at: 1)
    guard try statement.step() else { throw ViewerStoreError.invalidValue }
  }

  private func bindQuery(
    recordingID: Int64,
    eventUpperRowID: Int64,
    compiled: ViewerCompiledQuery,
    querySnapshot: ViewerQuerySnapshot,
    to statement: ViewerSQLiteStatement,
    startingAt index: Int32
  ) throws {
    var index = index
    try statement.bind(recordingID, at: index)
    index += 1
    try statement.bind(eventUpperRowID, at: index)
    index += 1
    _ = try bindCompiledQuery(
      compiled,
      querySnapshot: querySnapshot,
      to: statement,
      startingAt: index
    )
  }

  private func bindCompiledQuery(
    _ compiled: ViewerCompiledQuery,
    querySnapshot: ViewerQuerySnapshot,
    to statement: ViewerSQLiteStatement,
    startingAt start: Int32
  ) throws -> Int32 {
    var index = start
    for binding in compiled.bindings {
      switch binding {
      case .integer(let value): try statement.bind(value, at: index)
      case .real(let value): try statement.bind(value, at: index)
      case .text(let value): try statement.bind(value, at: index)
      case .gapSnapshotUpperBound:
        try statement.bind(querySnapshot.gapUpperRowID, at: index)
      case .dropSnapshotUpperBound:
        try statement.bind(querySnapshot.dropUpperRowID, at: index)
      case .dispositionSnapshotUpperBound:
        try statement.bind(querySnapshot.dispositionUpperRowID, at: index)
      }
      index += 1
    }
    return index
  }

  private func validate(
    lease: ViewerStoreLeaseRegistry.Lease,
    generation: UInt64
  ) throws {
    try cancellation.check(generation)
    try leases.validateExport(lease)
  }

  private func secureTemporarySibling(for destination: URL) throws -> SecureTemporary {
    let parent = destination.deletingLastPathComponent()
    let destinationLeaf = destination.lastPathComponent
    guard destinationLeaf != ".", destinationLeaf != "..", !destinationLeaf.contains("/") else {
      throw ViewerStoreError.invalidPath
    }
    let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard parentDescriptor >= 0 else { throw ViewerStoreError.invalidPath }
    var parentInfo = stat()
    guard fstat(parentDescriptor, &parentInfo) == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
      _ = close(parentDescriptor)
      throw ViewerStoreError.invalidPath
    }
    var destinationInfo = stat()
    let destinationStatus = destinationLeaf.withCString {
      fstatat(parentDescriptor, $0, &destinationInfo, AT_SYMLINK_NOFOLLOW)
    }
    if destinationStatus == 0, (destinationInfo.st_mode & S_IFMT) == S_IFLNK {
      _ = close(parentDescriptor)
      throw ViewerStoreError.invalidPath
    }
    let temporaryLeaf = ".\(destinationLeaf).\(UUID().uuidString).tmp"
    let fileDescriptor = temporaryLeaf.withCString {
      openat(parentDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    }
    guard fileDescriptor >= 0, fchmod(fileDescriptor, 0o600) == 0 else {
      if fileDescriptor >= 0 { _ = close(fileDescriptor) }
      _ = close(parentDescriptor)
      throw ViewerStoreError.invalidPath
    }
    return SecureTemporary(
      parentDescriptor: parentDescriptor,
      parentPath: parent.path,
      fileDescriptor: fileDescriptor,
      temporaryLeaf: temporaryLeaf,
      destinationLeaf: destinationLeaf
    )
  }

  private func validateTemporary(_ temporary: SecureTemporary) throws {
    var descriptorInfo = stat()
    var leafInfo = stat()
    let leafStatus = temporary.temporaryLeaf.withCString {
      fstatat(temporary.parentDescriptor, $0, &leafInfo, AT_SYMLINK_NOFOLLOW)
    }
    guard fstat(temporary.fileDescriptor, &descriptorInfo) == 0, leafStatus == 0,
      (descriptorInfo.st_mode & S_IFMT) == S_IFREG,
      (leafInfo.st_mode & S_IFMT) == S_IFREG,
      descriptorInfo.st_dev == leafInfo.st_dev,
      descriptorInfo.st_ino == leafInfo.st_ino,
      descriptorInfo.st_uid == getuid(), descriptorInfo.st_nlink == 1,
      leafInfo.st_nlink == 1, (descriptorInfo.st_mode & 0o777) == 0o600
    else { throw ViewerStoreError.invalidPath }
  }

  private func validateParent(_ temporary: SecureTemporary) throws {
    var descriptorInfo = stat()
    var pathInfo = stat()
    guard fstat(temporary.parentDescriptor, &descriptorInfo) == 0,
      lstat(temporary.parentPath, &pathInfo) == 0,
      (pathInfo.st_mode & S_IFMT) == S_IFDIR,
      descriptorInfo.st_dev == pathInfo.st_dev,
      descriptorInfo.st_ino == pathInfo.st_ino
    else { throw ViewerStoreError.invalidPath }
  }

  private func atomicReplace(_ temporary: SecureTemporary) throws {
    try filePhases.reach(.beforeDirectoryOpen)
    try validateParent(temporary)
    try validateTemporary(temporary)
    // rename(2) is the only irreversible commit point. Before it succeeds, an existing
    // destination is untouched. After it succeeds, directory synchronization is best effort
    // and cannot turn an already committed replacement into a reported pre-commit failure.
    try filePhases.reach(.beforeRename)
    try validateParent(temporary)
    try validateTemporary(temporary)
    let result = temporary.temporaryLeaf.withCString { source in
      temporary.destinationLeaf.withCString { destination in
        renameat(
          temporary.parentDescriptor,
          source,
          temporary.parentDescriptor,
          destination
        )
      }
    }
    guard result == 0 else {
      throw ViewerStoreError.invalidPath
    }
    try? filePhases.reach(.afterRename)
    try? filePhases.reach(.directorySync)
    _ = fsync(temporary.parentDescriptor)
  }

  private func write(
    _ data: Data,
    to handle: FileHandle,
    generation: UInt64,
    byteBudget: ByteBudget?
  ) throws {
    try byteBudget?.reserve(data.count)
    var offset = 0
    while offset < data.count {
      try cancellation.check(generation)
      let end = min(data.count, offset + Self.maximumBufferBytes)
      try handle.write(contentsOf: data[offset..<end])
      offset = end
    }
  }

}

extension ViewerExportSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExportSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExportFilePhaseObserver: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExportFilePhaseObserver(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExportCancellation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExportCancellation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerStoreExportService: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreExportService(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
