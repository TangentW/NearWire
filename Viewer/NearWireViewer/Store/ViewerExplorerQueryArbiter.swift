import Foundation

final class ViewerExplorerQueryArbiter: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.nearwire.viewer.explorer-query-arbiter")
  private let queryService: ViewerStoreQueryService
  private let diagnosticService: ViewerStoreDiagnosticService
  private let performanceService: ViewerPerformanceStoreService
  private let exportService: ViewerStoreExportService
  private var traversal: ViewerEventTraversal?
  private var performanceTraversal: ViewerPerformanceTraversal?
  private var closed = false

  init(
    queryService: ViewerStoreQueryService,
    diagnosticService: ViewerStoreDiagnosticService,
    performanceService: ViewerPerformanceStoreService,
    exportService: ViewerStoreExportService
  ) {
    self.queryService = queryService
    self.diagnosticService = diagnosticService
    self.performanceService = performanceService
    self.exportService = exportService
  }

  func replaceQuery(
    _ query: ViewerEventQuery,
    operationID: UUID? = nil
  ) throws -> ViewerQuerySnapshot {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      endTraversalLocked()
      let next = try queryService.begin(query: query, operationID: operationID)
      traversal = next
      return next.snapshot
    }
  }

  func page(
    cursor: ViewerEventCursor?,
    direction: ViewerStoreQueryService.Direction,
    limit: Int,
    operationID: UUID? = nil
  ) throws -> ViewerEventPage {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      guard let current = traversal else { throw ViewerStoreError.invalidValue }
      do {
        let (page, refreshed) = try queryService.page(
          traversal: current,
          cursor: cursor,
          direction: direction,
          limit: limit,
          operationID: operationID
        )
        traversal = refreshed
        return page
      } catch {
        queryService.end(current)
        traversal = nil
        throw error
      }
    }
  }

  func replacePerformanceTraversal(
    storeGeneration: UInt64,
    recordingID: Int64,
    deviceSessionID: Int64,
    lowerMonotonicNanoseconds: Int64,
    upperMonotonicNanoseconds: Int64,
    operationID: UUID? = nil
  ) throws -> ViewerPerformanceStoreScope {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      endTraversalLocked()
      let next = try performanceService.begin(
        storeGeneration: storeGeneration,
        recordingID: recordingID,
        deviceSessionID: deviceSessionID,
        lowerMonotonicNanoseconds: lowerMonotonicNanoseconds,
        upperMonotonicNanoseconds: upperMonotonicNanoseconds,
        operationID: operationID
      )
      performanceTraversal = next
      return next.scope
    }
  }

  func performanceEventPage(
    continuation: ViewerPerformanceContinuation?,
    operationID: UUID? = nil
  ) throws -> ViewerPerformanceEventPage {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      guard let current = performanceTraversal else {
        throw ViewerPerformanceStoreFailure.invalidScope
      }
      do {
        let (page, refreshed) = try performanceService.eventPage(
          traversal: current,
          continuation: continuation,
          operationID: operationID
        )
        performanceTraversal = refreshed
        return page
      } catch {
        performanceService.end(current)
        performanceTraversal = nil
        throw error
      }
    }
  }

  func performanceGapPage(
    operationID: UUID? = nil
  ) throws -> ViewerPerformanceGapPage {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      guard let current = performanceTraversal else {
        throw ViewerPerformanceStoreFailure.invalidScope
      }
      do {
        let (page, refreshed) = try performanceService.gapPage(
          traversal: current,
          operationID: operationID
        )
        performanceTraversal = refreshed
        return page
      } catch {
        performanceService.end(current)
        performanceTraversal = nil
        throw error
      }
    }
  }

  func resolvePerformanceEventLocator(
    recordingID: Int64,
    deviceSessionID: Int64,
    key: ViewerEventJournalKey,
    operationID: UUID? = nil
  ) throws -> ViewerPerformanceEventLocator? {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      guard traversal == nil, performanceTraversal == nil else {
        throw ViewerStoreExplorerFailure.busy
      }
      return try performanceService.resolveEventLocator(
        recordingID: recordingID,
        deviceSessionID: deviceSessionID,
        key: key,
        operationID: operationID
      )
    }
  }

  func detail(
    rowID: Int64,
    operationID: UUID? = nil
  ) throws -> ViewerStoredEventDetail? {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      guard let current = traversal else { throw ViewerStoreError.invalidValue }
      do {
        let (detail, refreshed) = try queryService.detail(
          traversal: current,
          rowID: rowID,
          operationID: operationID
        )
        traversal = refreshed
        return detail
      } catch {
        queryService.end(current)
        traversal = nil
        throw error
      }
    }
  }

  func makeFilteredExportScope(operationID: UUID? = nil) throws -> ViewerFilteredExportScope {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      guard let current = traversal else { throw ViewerStoreError.invalidValue }
      do {
        let refreshed = try queryService.refresh(current)
        traversal = refreshed
        return ViewerFilteredExportScope(
          query: refreshed.query,
          snapshot: refreshed.snapshot
        )
      } catch {
        queryService.end(current)
        traversal = nil
        throw error
      }
    }
  }

  func gapPage(
    deviceSessionIDs: [Int64],
    cursor: ViewerGapCursor?,
    direction: ViewerStoreQueryService.Direction,
    limit: Int,
    operationID: UUID? = nil
  ) throws -> ViewerGapPage {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      guard let current = traversal else { throw ViewerStoreError.invalidValue }
      do {
        let (page, refreshed) = try diagnosticService.gapPage(
          traversal: current,
          deviceSessionIDs: deviceSessionIDs,
          cursor: cursor,
          direction: direction,
          limit: limit,
          operationID: operationID
        )
        traversal = refreshed
        return page
      } catch {
        queryService.end(current)
        traversal = nil
        throw error
      }
    }
  }

  func causality(
    rootRowID: Int64,
    operationID: UUID? = nil
  ) throws -> ViewerCausalityGraph {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      guard let current = traversal else { throw ViewerStoreError.invalidValue }
      do {
        let (graph, refreshed) = try diagnosticService.causality(
          traversal: current,
          rootRowID: rootRowID,
          operationID: operationID
        )
        traversal = refreshed
        return graph
      } catch {
        queryService.end(current)
        traversal = nil
        throw error
      }
    }
  }

  func preflight(scope: ViewerFilteredExportScope, operationID: UUID? = nil) throws -> (
    eventCount: Int64, disclosure: ViewerExportDisclosure
  ) {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      return try exportService.preflight(scope: scope, operationID: operationID)
    }
  }

  func preflight(recordingID: Int64, operationID: UUID? = nil) throws -> (
    eventCount: Int64, disclosure: ViewerExportDisclosure
  ) {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      return try exportService.preflight(recordingID: recordingID, operationID: operationID)
    }
  }

  func makeCompleteExportScope(
    recordingID: Int64,
    operationID: UUID? = nil
  ) throws -> ViewerCompleteExportScope {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      return try exportService.makeCompleteScope(
        recordingID: recordingID,
        operationID: operationID
      )
    }
  }

  func preflight(scope: ViewerCompleteExportScope, operationID: UUID? = nil) throws -> (
    eventCount: Int64, disclosure: ViewerExportDisclosure
  ) {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      return try exportService.preflight(scope: scope, operationID: operationID)
    }
  }

  func export(
    recordingID: Int64,
    to destination: URL,
    operationID: UUID? = nil
  ) throws {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      try exportService.export(
        recordingID: recordingID,
        to: destination,
        operationID: operationID
      )
    }
  }

  func export(
    scope: ViewerCompleteExportScope,
    to destination: URL,
    operationID: UUID? = nil
  ) throws {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      try exportService.export(scope: scope, to: destination, operationID: operationID)
    }
  }

  func export(
    scope: ViewerFilteredExportScope,
    to destination: URL,
    operationID: UUID? = nil
  ) throws {
    try queue.sync {
      guard !closed else { throw ViewerStoreExplorerFailure.storeReplaced }
      try exportService.export(scope: scope, to: destination, operationID: operationID)
    }
  }

  func endTraversal() {
    queue.sync { endTraversalLocked() }
  }

  func cancel(operationID: UUID) {
    queryService.cancel(operationID: operationID)
    diagnosticService.cancel(operationID: operationID)
    performanceService.cancel(operationID: operationID)
    exportService.cancel(operationID: operationID)
  }

  func clearCancellation(operationID: UUID) {
    queryService.clearCancellation(operationID: operationID)
    diagnosticService.clearCancellation(operationID: operationID)
    performanceService.clearCancellation(operationID: operationID)
    exportService.clearCancellation(operationID: operationID)
  }

  func close() {
    queue.sync {
      guard !closed else { return }
      closed = true
      endTraversalLocked()
    }
  }

  private func endTraversalLocked() {
    if let traversal {
      self.traversal = nil
      queryService.end(traversal)
    }
    if let performanceTraversal {
      self.performanceTraversal = nil
      performanceService.end(performanceTraversal)
    }
  }
}

extension ViewerExplorerQueryArbiter: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerQueryArbiter(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
