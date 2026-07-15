import Darwin
import Foundation
@_spi(NearWireInternal) import NearWireCore


enum ViewerSessionTransferError: Error, Equatable, Sendable {
  case cancelled
  case workLimitExceeded
  case capacityExceeded
  case invalidPath
  case invalidValue
  case busy
  case unavailable
  case unsupportedSchema
}

enum ViewerSessionTextRules {
  static func sessionName(_ value: String) throws -> String {
    try validate(value, maximumScalars: 80, maximumBytes: 120, allowsLineFeedAndTab: false)
  }

  static func noteOrAnnotation(_ value: String) throws -> String {
    try validate(
      value,
      maximumScalars: 4_096,
      maximumBytes: 16 * 1_024,
      allowsLineFeedAndTab: true
    )
  }

  private static func validate(
    _ value: String,
    maximumScalars: Int,
    maximumBytes: Int,
    allowsLineFeedAndTab: Bool
  ) throws -> String {
    guard value.unicodeScalars.count <= maximumScalars, value.utf8.count <= maximumBytes else {
      throw ViewerSessionTransferError.invalidValue
    }
    for scalar in value.unicodeScalars {
      if scalar.value == 0 { throw ViewerSessionTransferError.invalidValue }
      if CharacterSet.controlCharacters.contains(scalar) {
        let allowed = allowsLineFeedAndTab && (scalar.value == 9 || scalar.value == 10)
        if !allowed { throw ViewerSessionTransferError.invalidValue }
      }
    }
    return value
  }
}

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
    if isCancelled { throw ViewerSessionTransferError.cancelled }
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
    else { throw ViewerSessionTransferError.workLimitExceeded }
  }

  static func validateFileBytes(_ count: Int64) throws {
    guard count >= 0, count <= maximumFileBytes else {
      throw ViewerSessionTransferError.workLimitExceeded
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
    guard url.isFileURL, maximumFileBytes > 0 else { throw ViewerSessionTransferError.invalidPath }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ViewerSessionTransferError.invalidPath }
    defer { _ = Darwin.close(descriptor) }

    var status = stat()
    guard fstat(descriptor, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_size > 0,
      status.st_size <= maximumFileBytes,
      status.st_size <= Int64(Int.max)
    else {
      throw ViewerSessionTransferError.invalidValue
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
      throw errno == EEXIST ? ViewerSessionTransferError.busy : ViewerSessionTransferError.unavailable
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
      guard readCount > 0 else { throw ViewerSessionTransferError.invalidValue }

      var written = 0
      while written < readCount {
        let result = buffer.withUnsafeBytes { bytes in
          Darwin.write(snapshot, bytes.baseAddress?.advanced(by: written), readCount - written)
        }
        if result < 0, errno == EINTR { continue }
        guard result > 0 else { throw ViewerSessionTransferError.unavailable }
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
    else { throw ViewerSessionTransferError.invalidValue }

    let count = Int(sourceStatus.st_size)
    guard let pointer = mmap(nil, count, PROT_READ, MAP_PRIVATE, snapshot, 0),
      pointer != MAP_FAILED
    else { throw ViewerSessionTransferError.unavailable }
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
    else { throw ViewerSessionTransferError.unsupportedSchema }
    let session = try Self.decode(
      ViewerSessionImportSession.self,
      from: data,
      range: sessionRange
    )
    _ = try session.name.map(ViewerSessionTextRules.sessionName)
    _ = try session.note.map(ViewerSessionTextRules.noteOrAnnotation)
    guard ["active", "closed", "recoveredAfterInterruption"].contains(session.state),
      session.endedAtMilliseconds.map({ $0 >= session.startedAtMilliseconds }) ?? true
    else { throw ViewerSessionTransferError.invalidValue }

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
      else { throw ViewerSessionTransferError.invalidValue }
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
        throw ViewerSessionTransferError.invalidValue
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
        throw ViewerSessionTransferError.invalidValue
      }
      let value = ViewerSessionImportEvent(record: metadata, content: content)
      guard Self.validReference(value.device), Self.validReference(value.connection),
        !value.eventType.isEmpty,
        value.eventType.utf8.count <= EventValidationLimits.default.maximumTypeBytes
      else { throw ViewerSessionTransferError.invalidValue }
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
      else { throw ViewerSessionTransferError.invalidValue }
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
        throw ViewerSessionTransferError.invalidValue
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
    guard let range = members[member] else { throw ViewerSessionTransferError.invalidValue }
    try ViewerJSONStructureScanner(
      data: data,
      cancellation: cancellation,
      scanProgress: structuralScanProgress
    ).forEachArrayElement(
      in: range,
      maximumCount: maximumCount
    ) { valueRange in
      guard valueRange.count <= maximumRecordBytes else { throw ViewerSessionTransferError.invalidValue }
      try body(valueRange)
    }
  }

  private static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    range: Range<Int>?
  ) throws -> T {
    guard let range else { throw ViewerSessionTransferError.invalidValue }
    do {
      return try JSONDecoder().decode(type, from: Data(data[range]))
    } catch {
      throw ViewerSessionTransferError.invalidValue
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
      throw ViewerSessionTransferError.invalidValue
    }
    while true {
      try skipWhitespace(&index)
      let keyRange = try scanString(at: &index)
      guard keyRange.count <= 128 else { throw ViewerSessionTransferError.invalidValue }
      let key: String
      do {
        key = try JSONDecoder().decode(String.self, from: Data(data[keyRange]))
      } catch {
        throw ViewerSessionTransferError.invalidValue
      }
      guard members[key] == nil else { throw ViewerSessionTransferError.invalidValue }
      try skipWhitespace(&index)
      try expect(UInt8(ascii: ":"), at: &index)
      try skipWhitespace(&index)
      let valueStart = index
      try scanValue(at: &index)
      let valueRange = valueStart..<index
      switch key {
      case "schemaVersion":
        guard valueRange.count <= 32 else { throw ViewerSessionTransferError.invalidValue }
      case "scope":
        guard valueRange.count <= 64 else { throw ViewerSessionTransferError.invalidValue }
      case "disclosure":
        guard valueRange.count <= 8 * 1_024 else { throw ViewerSessionTransferError.invalidValue }
      case "session":
        guard valueRange.count <= 64 * 1_024 else { throw ViewerSessionTransferError.invalidValue }
      default:
        break
      }
      members[key] = valueRange
      try skipWhitespace(&index)
      if consume(UInt8(ascii: "}"), at: &index) { break }
      try expect(UInt8(ascii: ","), at: &index)
    }
    try skipWhitespace(&index)
    guard index == data.endIndex else { throw ViewerSessionTransferError.invalidValue }
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
      guard index == range.upperBound else { throw ViewerSessionTransferError.invalidValue }
      return
    }
    var count = 0
    while true {
      guard count < maximumCount else { throw ViewerSessionTransferError.invalidValue }
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
    guard index == range.upperBound else { throw ViewerSessionTransferError.invalidValue }
  }

  private func scanValue(at index: inout Int, limit: Int? = nil) throws {
    let limit = limit ?? data.endIndex
    guard index < limit else { throw ViewerSessionTransferError.invalidValue }
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
      guard index > start else { throw ViewerSessionTransferError.invalidValue }
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
        guard stack.last == byte else { throw ViewerSessionTransferError.invalidValue }
        stack.removeLast()
        if stack.isEmpty { return }
      }
      guard stack.count <= maximumDepth else { throw ViewerSessionTransferError.invalidValue }
    }
    throw ViewerSessionTransferError.invalidValue
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
        throw ViewerSessionTransferError.invalidValue
      }
    }
    throw ViewerSessionTransferError.invalidValue
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
    guard consume(byte, at: &index, limit: limit) else { throw ViewerSessionTransferError.invalidValue }
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
      "The export includes Session timing and state, diagnostic gaps, Event metadata and content, and peer-provided App display name, identifier, and version; these can contain identifying or sensitive data.",
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
