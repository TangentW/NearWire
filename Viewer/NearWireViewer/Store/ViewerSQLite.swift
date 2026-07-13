import Darwin
import Foundation
import SQLite3

enum ViewerStoreError: Error, Equatable, Sendable {
  case invalidPath
  case unsupportedSchema
  case corruptStore
  case busy
  case sqliteBusy
  case capacityExceeded
  case cancelled
  case workLimitExceeded
  case invalidValue
  case staleObservation
  case writeNotAuthorized
  case unavailable
}

enum ViewerStoreWriteContext: Sendable {
  case eventIngress
  case interactiveMutation
}

enum ViewerStoreWriteFailureDisposition: Sendable {
  case capacityPaused
  case writeFailed
  case operationLocal

  static func classify(
    _ error: ViewerStoreError,
    context: ViewerStoreWriteContext
  ) -> ViewerStoreWriteFailureDisposition {
    if error == .capacityExceeded { return .capacityPaused }
    if error == .staleObservation || error == .writeNotAuthorized {
      return .operationLocal
    }
    if context == .interactiveMutation {
      switch error {
      case .busy, .cancelled, .workLimitExceeded, .invalidValue, .staleObservation,
        .writeNotAuthorized:
        return .operationLocal
      case .invalidPath, .unsupportedSchema, .corruptStore, .sqliteBusy, .unavailable:
        return .writeFailed
      case .capacityExceeded:
        return .capacityPaused
      }
    }
    return .writeFailed
  }
}

struct ViewerStorePaths: Sendable, Equatable {
  let directory: URL
  let database: URL

  var wal: URL { URL(fileURLWithPath: database.path + "-wal") }
  var sharedMemory: URL { URL(fileURLWithPath: database.path + "-shm") }
  var journal: URL { URL(fileURLWithPath: database.path + "-journal") }
  var migration: URL {
    directory.appendingPathComponent("NearWire.sqlite.migration", isDirectory: false)
  }
  var exportTemporary: URL {
    directory.appendingPathComponent("NearWire-export.json.tmp", isDirectory: false)
  }

  static func applicationSupport(fileManager: FileManager = .default) throws -> ViewerStorePaths {
    guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { throw ViewerStoreError.invalidPath }
    return ViewerStorePaths(
      directory: base.appendingPathComponent("NearWire", isDirectory: true),
      database: base.appendingPathComponent("NearWire/NearWire.sqlite", isDirectory: false)
    )
  }
}

enum ViewerStoreFileSecurity {
  static func prepareDirectory(_ url: URL, fileManager: FileManager = .default) throws {
    try rejectSymbolicLink(at: url, allowMissing: true, fileManager: fileManager)
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    try rejectSymbolicLink(at: url, allowMissing: false, fileManager: fileManager)
    guard chmod(url.path, 0o700) == 0 else { throw ViewerStoreError.invalidPath }
  }

  static func secureRegularFileIfPresent(_ url: URL, fileManager: FileManager = .default) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try rejectSymbolicLink(at: url, allowMissing: false, fileManager: fileManager)
    var info = stat()
    guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      throw ViewerStoreError.invalidPath
    }
    guard chmod(url.path, 0o600) == 0 else { throw ViewerStoreError.invalidPath }
  }

  static func secureStoreFiles(_ paths: ViewerStorePaths, fileManager: FileManager = .default)
    throws
  {
    for url in [
      paths.database, paths.wal, paths.sharedMemory, paths.journal, paths.migration,
      paths.exportTemporary,
    ] {
      try secureRegularFileIfPresent(url, fileManager: fileManager)
    }
  }

  static func validatePrivateTemporaryDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      (info.st_mode & 0o777) == 0o700,
      info.st_uid == geteuid()
    else { throw ViewerStoreError.invalidPath }
  }

  private static func rejectSymbolicLink(
    at url: URL,
    allowMissing: Bool,
    fileManager: FileManager
  ) throws {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      if allowMissing && errno == ENOENT { return }
      throw ViewerStoreError.invalidPath
    }
    if (info.st_mode & S_IFMT) == S_IFLNK { throw ViewerStoreError.invalidPath }
    if !allowMissing && !fileManager.fileExists(atPath: url.path) {
      throw ViewerStoreError.invalidPath
    }
  }
}

struct ViewerSQLiteBudget: Sendable, Equatable {
  let maximumVirtualMachineSteps: Int
  let deadline: ContinuousClock.Instant

  static func query(now: ContinuousClock.Instant = .now) -> ViewerSQLiteBudget {
    ViewerSQLiteBudget(maximumVirtualMachineSteps: 2_000_000, deadline: now + .milliseconds(250))
  }

  static func export(now: ContinuousClock.Instant = .now) -> ViewerSQLiteBudget {
    ViewerSQLiteBudget(maximumVirtualMachineSteps: 8_000_000, deadline: now + .seconds(1))
  }
}

struct ViewerStoreDiskGuard: Sendable {
  static let minimumAvailableBytes: Int64 = 64 * 1_024 * 1_024
  static let live = ViewerStoreDiskGuard { directory in
    try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
      .volumeAvailableCapacity.map(Int64.init)
  }

  private let availableCapacity: @Sendable (URL) throws -> Int64?

  init(availableCapacity: @escaping @Sendable (URL) throws -> Int64?) {
    self.availableCapacity = availableCapacity
  }

  func requireReserve(at directory: URL, plannedBytes: Int64) throws {
    let (required, overflow) = Self.minimumAvailableBytes.addingReportingOverflow(plannedBytes)
    guard plannedBytes >= 0, !overflow,
      let available = try? availableCapacity(directory),
      available >= required
    else { throw ViewerStoreError.capacityExceeded }
  }

  func availableBytes(at directory: URL) throws -> Int64 {
    guard let available = try availableCapacity(directory), available >= 0 else {
      throw ViewerStoreError.capacityExceeded
    }
    return available
  }
}

enum ViewerStoreMigrationPhase: Equatable, Sendable {
  case preparing
  case index(Int)
  case validating
  case needsSpace
  case cancelled
  case failed
}

final class ViewerStoreMigrationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

final class ViewerStoreAutomaticMigrationGate: @unchecked Sendable {
  static let shared = ViewerStoreAutomaticMigrationGate()

  private let lock = NSLock()
  private var claimedDatabasePaths: Set<String> = []

  func claim(_ database: URL) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return claimedDatabasePaths.insert(database.standardizedFileURL.path).inserted
  }
}

final class ViewerStoreMigrationControl: @unchecked Sendable {
  static let baseHeadroomBytes: Int64 = 512 * 1_024 * 1_024
  static let footprintMultiplier: Int64 = 6
  static let liveVolumeFloorBytes: Int64 = 256 * 1_024 * 1_024
  static let progressInstructionInterval: Int32 = 10_000

  private let paths: ViewerStorePaths
  private let stateLock = NSLock()
  private let temporaryDirectory: URL
  private let fileManager: FileManager
  private let diskGuard: ViewerStoreDiskGuard
  private let volumeIdentifier: @Sendable (URL) throws -> UInt64
  private let allocatedFootprintOverride: (@Sendable () throws -> Int64)?
  private let authorizeAttempt: @Sendable () -> Bool
  private let isCancelled: @Sendable () -> Bool
  private let phaseObserver: @Sendable (ViewerStoreMigrationPhase) -> Void
  private let progressObserver: @Sendable () -> Void
  private let phaseGate: @Sendable (ViewerStoreMigrationPhase) throws -> Void
  private var beganMigration = false

  init(
    paths: ViewerStorePaths,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    fileManager: FileManager = .default,
    diskGuard: ViewerStoreDiskGuard = .live,
    volumeIdentifier: @escaping @Sendable (URL) throws -> UInt64 = {
      var info = stat()
      guard stat($0.path, &info) == 0 else { throw ViewerStoreError.invalidPath }
      return UInt64(info.st_dev)
    },
    allocatedFootprintOverride: (@Sendable () throws -> Int64)? = nil,
    authorizeAttempt: @escaping @Sendable () -> Bool = { true },
    isCancelled: @escaping @Sendable () -> Bool = { false },
    phaseObserver: @escaping @Sendable (ViewerStoreMigrationPhase) -> Void = { _ in },
    progressObserver: @escaping @Sendable () -> Void = {},
    phaseGate: @escaping @Sendable (ViewerStoreMigrationPhase) throws -> Void = { _ in }
  ) {
    self.paths = paths
    self.temporaryDirectory = temporaryDirectory
    self.fileManager = fileManager
    self.diskGuard = diskGuard
    self.volumeIdentifier = volumeIdentifier
    self.allocatedFootprintOverride = allocatedFootprintOverride
    self.authorizeAttempt = authorizeAttempt
    self.isCancelled = isCancelled
    self.phaseObserver = phaseObserver
    self.progressObserver = progressObserver
    self.phaseGate = phaseGate
  }

  func prepareForVersionOne() throws {
    guard authorizeAttempt() else { throw ViewerStoreError.unavailable }
    stateLock.lock()
    beganMigration = true
    stateLock.unlock()
    try enter(.preparing)
    try ViewerStoreFileSecurity.validatePrivateTemporaryDirectory(temporaryDirectory)
    let allocated = try allocatedStoreFootprint()
    let (multiplied, multiplyOverflow) = allocated.multipliedReportingOverflow(
      by: Self.footprintMultiplier
    )
    let (required, addOverflow) = Self.baseHeadroomBytes.addingReportingOverflow(multiplied)
    guard !multiplyOverflow, !addOverflow else {
      throw ViewerStoreError.capacityExceeded
    }
    guard try volumesHaveAvailableBytes(required) else {
      throw ViewerStoreError.capacityExceeded
    }
  }

  func beforeIndex(_ index: Int) throws { try enter(.index(index)) }

  func beforeValidation() throws { try enter(.validating) }

  func progressFailure() -> ViewerStoreError? {
    progressObserver()
    if isCancelled() { return .cancelled }
    guard (try? volumesHaveAvailableBytes(Self.liveVolumeFloorBytes)) == true else {
      return .capacityExceeded
    }
    return nil
  }

  func reportFailure(_ error: Error) {
    stateLock.lock()
    let shouldReport = beganMigration
    stateLock.unlock()
    guard shouldReport else { return }
    switch error as? ViewerStoreError {
    case .capacityExceeded: phaseObserver(.needsSpace)
    case .cancelled: phaseObserver(.cancelled)
    default: phaseObserver(.failed)
    }
  }

  private func enter(_ phase: ViewerStoreMigrationPhase) throws {
    if isCancelled() {
      throw ViewerStoreError.cancelled
    }
    phaseObserver(phase)
    try phaseGate(phase)
    if isCancelled() { throw ViewerStoreError.cancelled }
  }

  private func allocatedStoreFootprint() throws -> Int64 {
    if let allocatedFootprintOverride {
      let value = try allocatedFootprintOverride()
      guard value >= 0 else { throw ViewerStoreError.capacityExceeded }
      return value
    }
    var result: Int64 = 0
    for url in [paths.database, paths.wal, paths.sharedMemory] {
      guard fileManager.fileExists(atPath: url.path) else { continue }
      let values = try url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey])
      let bytes = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
      let (next, overflow) = result.addingReportingOverflow(bytes)
      guard bytes >= 0, !overflow else { throw ViewerStoreError.capacityExceeded }
      result = next
    }
    return result
  }

  private func volumesHaveAvailableBytes(_ required: Int64) throws -> Bool {
    guard try diskGuard.availableBytes(at: paths.directory) >= required else { return false }
    if try volumeIdentifier(paths.directory) == volumeIdentifier(temporaryDirectory) {
      return true
    }
    return try diskGuard.availableBytes(at: temporaryDirectory) >= required
  }
}

final class ViewerSQLiteCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelledGeneration: UInt64?

  func cancel(generation: UInt64) {
    lock.lock()
    cancelledGeneration = generation
    lock.unlock()
  }

  func isCancelled(generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelledGeneration == generation
  }
}

private final class ViewerSQLiteProgressContext {
  let cancellation: ViewerSQLiteCancellation
  let generation: UInt64
  let deadline: ContinuousClock.Instant?
  let instructionInterval: Int
  let externalCheck: (() -> ViewerStoreError?)?
  var remainingSteps: Int?
  var terminationError: ViewerStoreError?

  init(
    cancellation: ViewerSQLiteCancellation,
    generation: UInt64,
    budget: ViewerSQLiteBudget?,
    instructionInterval: Int32,
    externalCheck: (() -> ViewerStoreError?)?
  ) {
    self.cancellation = cancellation
    self.generation = generation
    deadline = budget?.deadline
    self.instructionInterval = Int(instructionInterval)
    self.externalCheck = externalCheck
    remainingSteps = budget?.maximumVirtualMachineSteps
  }
}

private let viewerSQLiteProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
  pointer in
  guard let pointer else { return 1 }
  let context = Unmanaged<ViewerSQLiteProgressContext>.fromOpaque(pointer).takeUnretainedValue()
  if context.cancellation.isCancelled(generation: context.generation) {
    context.terminationError = .cancelled
    return 1
  }
  if let error = context.externalCheck?() {
    context.terminationError = error
    return 1
  }
  if let remainingSteps = context.remainingSteps {
    let next = remainingSteps - context.instructionInterval
    context.remainingSteps = next
    if next <= 0 || (context.deadline.map { ContinuousClock.now >= $0 } ?? false) {
      context.terminationError = .workLimitExceeded
      return 1
    }
  }
  return 0
}

final class ViewerSQLiteConnection: @unchecked Sendable {
  enum Role: String, Sendable {
    case migrationWriter
    case writer
    case queryReader
    case exportReader
  }

  enum TemporaryStorage: Sendable {
    case memory(cacheKiB: Int)
    case file(cacheKiB: Int)

    static let normal = TemporaryStorage.memory(cacheKiB: 8 * 1_024)
    static let migration = TemporaryStorage.file(cacheKiB: 32 * 1_024)

    fileprivate var pragmaValue: String {
      switch self {
      case .memory: return "MEMORY"
      case .file: return "FILE"
      }
    }

    fileprivate var cacheKiB: Int {
      switch self {
      case .memory(let cacheKiB), .file(let cacheKiB): return cacheKiB
      }
    }
  }

  let role: Role
  private let queue: DispatchQueue
  private let stateLock = NSLock()
  private let cancellation = ViewerSQLiteCancellation()
  private var database: OpaquePointer?
  private var activeGeneration: UInt64?
  private var activeOperationID: UUID?
  private var cancelledOperationIDs: Set<UUID> = []
  private var nextGeneration: UInt64 = 1

  init(
    role: Role,
    path: String,
    readOnly: Bool = false,
    temporaryStorage: TemporaryStorage = .normal
  ) throws {
    self.role = role
    queue = DispatchQueue(label: "com.nearwire.viewer.sqlite.\(role.rawValue)")
    let requestedURL = URL(fileURLWithPath: path)
    guard
      let resolvedParentPointer = realpath(
        requestedURL.deletingLastPathComponent().path,
        nil
      )
    else { throw ViewerStoreError.invalidPath }
    defer { free(resolvedParentPointer) }
    let canonicalPath = URL(
      fileURLWithPath: String(cString: resolvedParentPointer),
      isDirectory: true
    ).appendingPathComponent(requestedURL.lastPathComponent, isDirectory: false).path
    var pointer: OpaquePointer?
    let access = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    let result = sqlite3_open_v2(
      canonicalPath,
      &pointer,
      access | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
      nil
    )
    guard result == SQLITE_OK, let pointer else {
      if let pointer { sqlite3_close_v2(pointer) }
      throw Self.map(result)
    }
    database = pointer
    do {
      try configure(
        pointer: pointer,
        readOnly: readOnly,
        temporaryStorage: temporaryStorage
      )
    } catch {
      sqlite3_close_v2(pointer)
      database = nil
      throw error
    }
  }

  deinit {
    close()
  }

  func close() {
    queue.sync {
      stateLock.lock()
      let pointer = database
      database = nil
      activeGeneration = nil
      activeOperationID = nil
      cancelledOperationIDs.removeAll(keepingCapacity: false)
      stateLock.unlock()
      if let pointer { sqlite3_close_v2(pointer) }
    }
  }

  func run<T>(
    operationID: UUID? = nil,
    budget: ViewerSQLiteBudget? = nil,
    progressInstructionInterval: Int32 = 1_000,
    progressCheck: (() -> ViewerStoreError?)? = nil,
    failureHandler: ((Error) -> Void)? = nil,
    _ body: (OpaquePointer) throws -> T
  ) throws -> T {
    try queue.sync {
      guard progressInstructionInterval > 0 else {
        let error = ViewerStoreError.invalidValue
        failureHandler?(error)
        throw error
      }
      guard let database else {
        let error = ViewerStoreError.unavailable
        failureHandler?(error)
        throw error
      }
      let generation = nextGeneration
      nextGeneration &+= 1
      stateLock.lock()
      if let operationID, cancelledOperationIDs.contains(operationID) {
        stateLock.unlock()
        let error = ViewerStoreError.cancelled
        failureHandler?(error)
        throw error
      }
      activeGeneration = generation
      activeOperationID = operationID
      stateLock.unlock()
      var retainedContext: Unmanaged<ViewerSQLiteProgressContext>?
      var progressContext: ViewerSQLiteProgressContext?
      if budget != nil || progressCheck != nil {
        let context = ViewerSQLiteProgressContext(
          cancellation: cancellation,
          generation: generation,
          budget: budget,
          instructionInterval: progressInstructionInterval,
          externalCheck: progressCheck
        )
        progressContext = context
        let retained = Unmanaged.passRetained(context)
        retainedContext = retained
        sqlite3_progress_handler(
          database,
          progressInstructionInterval,
          viewerSQLiteProgressCallback,
          retained.toOpaque()
        )
      }
      defer {
        sqlite3_progress_handler(database, 0, nil, nil)
        retainedContext?.release()
        stateLock.lock()
        activeGeneration = nil
        activeOperationID = nil
        stateLock.unlock()
      }
      do {
        return try body(database)
      } catch {
        let reportedError: Error
        if cancellation.isCancelled(generation: generation) {
          reportedError = ViewerStoreError.cancelled
        } else if let terminationError = progressContext?.terminationError {
          reportedError = terminationError
        } else {
          reportedError = error
        }
        failureHandler?(reportedError)
        throw reportedError
      }
    }
  }

  func cancelCurrentOperation() {
    stateLock.lock()
    guard let generation = activeGeneration, let database else {
      stateLock.unlock()
      return
    }
    cancellation.cancel(generation: generation)
    sqlite3_interrupt(database)
    stateLock.unlock()
  }

  func cancel(operationID: UUID) {
    stateLock.lock()
    cancelledOperationIDs.insert(operationID)
    if activeOperationID == operationID, let generation = activeGeneration, let database {
      cancellation.cancel(generation: generation)
      sqlite3_interrupt(database)
    }
    stateLock.unlock()
  }

  func clearCancellation(operationID: UUID) {
    stateLock.lock()
    cancelledOperationIDs.remove(operationID)
    stateLock.unlock()
  }

  var cancelledOperationCountForTesting: Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return cancelledOperationIDs.count
  }

  func execute(_ sql: String) throws {
    try run { database in try Self.execute(sql, on: database) }
  }

  func hardeningConfiguration() throws -> (defensive: Bool, trustedSchema: Bool) {
    try run { database in
      var defensive: Int32 = 0
      guard
        nearwire_sqlite3_db_config(
          database,
          SQLITE_DBCONFIG_DEFENSIVE,
          -1,
          &defensive
        ) == SQLITE_OK
      else { throw ViewerStoreError.unavailable }
      var trusted: Int32 = 1
      guard
        nearwire_sqlite3_db_config(
          database,
          SQLITE_DBCONFIG_TRUSTED_SCHEMA,
          -1,
          &trusted
        ) == SQLITE_OK
      else { throw ViewerStoreError.unavailable }
      return (defensive != 0, trusted != 0)
    }
  }

  static func execute(_ sql: String, on database: OpaquePointer) throws {
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    if let message { sqlite3_free(message) }
    guard result == SQLITE_OK else { throw map(result) }
  }

  static func map(_ result: Int32) -> ViewerStoreError {
    switch result {
    case SQLITE_BUSY, SQLITE_LOCKED: return .sqliteBusy
    case SQLITE_FULL: return .capacityExceeded
    case SQLITE_INTERRUPT: return .cancelled
    case SQLITE_CORRUPT, SQLITE_NOTADB: return .corruptStore
    case SQLITE_RANGE, SQLITE_MISMATCH, SQLITE_TOOBIG: return .invalidValue
    default: return .unavailable
    }
  }

  private func configure(
    pointer: OpaquePointer,
    readOnly: Bool,
    temporaryStorage: TemporaryStorage
  ) throws {
    sqlite3_extended_result_codes(pointer, 1)
    sqlite3_busy_timeout(
      pointer,
      role == .writer || role == .migrationWriter ? 1_000 : 250
    )
    var defensiveResult: Int32 = 0
    let defensiveConfiguration = nearwire_sqlite3_db_config(
      pointer,
      SQLITE_DBCONFIG_DEFENSIVE,
      1,
      &defensiveResult
    )
    guard defensiveConfiguration == SQLITE_OK, defensiveResult == 1 else {
      throw ViewerStoreError.unavailable
    }
    var trustedSchemaResult: Int32 = 1
    let trustedSchemaConfiguration = nearwire_sqlite3_db_config(
      pointer,
      SQLITE_DBCONFIG_TRUSTED_SCHEMA,
      0,
      &trustedSchemaResult
    )
    guard trustedSchemaConfiguration == SQLITE_OK, trustedSchemaResult == 0 else {
      throw ViewerStoreError.unavailable
    }
    try Self.execute("PRAGMA defensive=ON", on: pointer)
    try Self.execute("PRAGMA trusted_schema=OFF", on: pointer)
    try Self.execute("PRAGMA temp_store=\(temporaryStorage.pragmaValue)", on: pointer)
    try Self.execute("PRAGMA cache_size=-\(temporaryStorage.cacheKiB)", on: pointer)
    try Self.execute("PRAGMA foreign_keys=ON", on: pointer)
    try Self.execute("PRAGMA secure_delete=ON", on: pointer)
    if readOnly {
      try Self.execute("PRAGMA query_only=ON", on: pointer)
    } else {
      try Self.execute("PRAGMA journal_mode=WAL", on: pointer)
      try Self.execute("PRAGMA synchronous=FULL", on: pointer)
      try Self.execute("PRAGMA wal_autocheckpoint=0", on: pointer)
    }
  }
}

final class ViewerSQLiteStatement {
  private let database: OpaquePointer
  private var statement: OpaquePointer?

  init(database: OpaquePointer, sql: String) throws {
    self.database = database
    guard
      sqlite3_prepare_v3(database, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        == SQLITE_OK
    else { throw ViewerSQLiteConnection.map(sqlite3_errcode(database)) }
  }

  deinit { sqlite3_finalize(statement) }

  func bind(_ value: Int64, at index: Int32) throws {
    guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw bindingError() }
  }

  func bind(_ value: Double, at index: Int32) throws {
    guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw bindingError() }
  }

  func bind(_ value: String, at index: Int32) throws {
    guard value.utf8.count <= Int(Int32.max) else { throw ViewerStoreError.invalidValue }
    let result = value.withCString { pointer in
      sqlite3_bind_text(
        statement, index, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard result == SQLITE_OK else { throw bindingError() }
  }

  func bind(_ value: Data, at index: Int32) throws {
    guard value.count <= Int(Int32.max) else { throw ViewerStoreError.invalidValue }
    let result = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(
        statement,
        index,
        bytes.baseAddress,
        Int32(bytes.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      )
    }
    guard result == SQLITE_OK else { throw bindingError() }
  }

  func bindNull(at index: Int32) throws {
    guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw bindingError() }
  }

  func step() throws -> Bool {
    let result = sqlite3_step(statement)
    switch result {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default: throw ViewerSQLiteConnection.map(result)
    }
  }

  func reset() throws {
    guard sqlite3_reset(statement) == SQLITE_OK, sqlite3_clear_bindings(statement) == SQLITE_OK
    else { throw bindingError() }
  }

  func int64(at index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
  func double(at index: Int32) -> Double { sqlite3_column_double(statement, index) }
  func string(at index: Int32) -> String {
    guard let pointer = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: pointer)
  }
  func data(at index: Int32) -> Data {
    guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
  }
  func isNull(at index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }

  private func bindingError() -> ViewerStoreError {
    ViewerSQLiteConnection.map(sqlite3_errcode(database))
  }
}

final class ViewerSQLitePool: @unchecked Sendable {
  enum ConstructionEvent: Equatable, Sendable {
    case migrationWriterOpened
    case migrationCompleted
    case migrationWriterClosed
    case writerOpened
    case schemaAccepted
    case queryReaderOpened
    case exportReaderOpened
  }

  let writer: ViewerSQLiteConnection
  let queryReader: ViewerSQLiteConnection
  let exportReader: ViewerSQLiteConnection
  let paths: ViewerStorePaths
  let diskGuard: ViewerStoreDiskGuard

  init(
    migrating paths: ViewerStorePaths,
    fileManager: FileManager = .default,
    diskGuard: ViewerStoreDiskGuard = .live,
    migrationControl: ViewerStoreMigrationControl? = nil,
    constructionObserver: @escaping @Sendable (ConstructionEvent) -> Void = { _ in }
  ) throws {
    self.paths = paths
    self.diskGuard = diskGuard
    try ViewerStoreFileSecurity.prepareDirectory(paths.directory, fileManager: fileManager)
    // Fail before creating or opening SQLite files when the volume cannot preserve the reserve.
    try diskGuard.requireReserve(at: paths.directory, plannedBytes: 4 * 1_024 * 1_024)
    try ViewerStoreFileSecurity.secureStoreFiles(paths, fileManager: fileManager)
    let migrationWriter = try ViewerSQLiteConnection(
      role: .migrationWriter,
      path: paths.database.path,
      temporaryStorage: .migration
    )
    constructionObserver(.migrationWriterOpened)
    try ViewerStoreFileSecurity.secureStoreFiles(paths, fileManager: fileManager)
    do {
      try ViewerStoreSchema.migrate(
        migrationWriter,
        control: migrationControl
          ?? ViewerStoreMigrationControl(
            paths: paths,
            fileManager: fileManager,
            diskGuard: diskGuard
          )
      )
      constructionObserver(.migrationCompleted)
    } catch {
      migrationWriter.close()
      constructionObserver(.migrationWriterClosed)
      throw error
    }
    migrationWriter.close()
    constructionObserver(.migrationWriterClosed)
    let writer = try ViewerSQLiteConnection(role: .writer, path: paths.database.path)
    constructionObserver(.writerOpened)
    try Self.probeWriter(writer)
    constructionObserver(.schemaAccepted)
    let queryReader = try ViewerSQLiteConnection(
      role: .queryReader,
      path: paths.database.path,
      readOnly: true
    )
    constructionObserver(.queryReaderOpened)
    let exportReader = try ViewerSQLiteConnection(
      role: .exportReader,
      path: paths.database.path,
      readOnly: true
    )
    constructionObserver(.exportReaderOpened)
    try Self.probeReaders([queryReader, exportReader])
    try ViewerStoreFileSecurity.secureStoreFiles(paths, fileManager: fileManager)
    self.writer = writer
    self.queryReader = queryReader
    self.exportReader = exportReader
  }

  deinit {
    close()
  }

  func close() {
    exportReader.close()
    queryReader.close()
    writer.close()
  }

  private static func probeWriter(_ writer: ViewerSQLiteConnection) throws {
    try writer.run { database in
      try ViewerStoreSchema.probe(database)
      try ViewerStoreSchema.probeExplorerPlans(database)
      let statement = try ViewerSQLiteStatement(database: database, sql: "PRAGMA quick_check(1)")
      guard try statement.step(), statement.string(at: 0) == "ok" else {
        throw ViewerStoreError.corruptStore
      }
      guard
        try ViewerStoreSchema.scalarString("PRAGMA journal_mode", database: database)
          .lowercased() == "wal",
        try ViewerStoreSchema.scalarInt64("PRAGMA synchronous", database: database) == 2,
        try ViewerStoreSchema.scalarInt64("PRAGMA temp_store", database: database) == 2,
        try ViewerStoreSchema.scalarInt64("PRAGMA cache_size", database: database) == -8 * 1_024,
        try ViewerStoreSchema.scalarInt64(
          "SELECT json_extract('{\"nearwire\":1}', '$.nearwire')",
          database: database
        ) == 1
      else { throw ViewerStoreError.unavailable }
    }
  }

  private static func probeReaders(_ readers: [ViewerSQLiteConnection]) throws {
    for reader in readers {
      try reader.run { database in
        guard try ViewerStoreSchema.scalarInt64("PRAGMA query_only", database: database) == 1,
          try ViewerStoreSchema.scalarInt64("PRAGMA foreign_keys", database: database) == 1,
          try ViewerStoreSchema.scalarInt64("PRAGMA temp_store", database: database) == 2,
          try ViewerStoreSchema.scalarInt64("PRAGMA cache_size", database: database)
            == -8 * 1_024
        else { throw ViewerStoreError.unavailable }
      }
    }
  }
}

extension ViewerStorePaths: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStorePaths(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerStoreDiskGuard: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoreDiskGuard(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerSQLiteCancellation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerSQLiteCancellation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerSQLiteProgressContext: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerSQLiteProgressContext(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerSQLiteConnection: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerSQLiteConnection(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerSQLiteStatement: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerSQLiteStatement(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerSQLitePool: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerSQLitePool(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
