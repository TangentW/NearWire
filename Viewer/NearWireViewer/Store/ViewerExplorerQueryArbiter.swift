import Foundation

final class ViewerExplorerQueryArbiter: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.nearwire.viewer.explorer-query-arbiter")
  private let queryService: ViewerStoreQueryService
  private let diagnosticService: ViewerStoreDiagnosticService
  private let exportService: ViewerStoreExportService
  private var traversal: ViewerEventTraversal?
  private var closed = false

  init(
    queryService: ViewerStoreQueryService,
    diagnosticService: ViewerStoreDiagnosticService,
    exportService: ViewerStoreExportService
  ) {
    self.queryService = queryService
    self.diagnosticService = diagnosticService
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
    exportService.cancel(operationID: operationID)
  }

  func clearCancellation(operationID: UUID) {
    queryService.clearCancellation(operationID: operationID)
    diagnosticService.clearCancellation(operationID: operationID)
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
    guard let traversal else { return }
    self.traversal = nil
    queryService.end(traversal)
  }
}

extension ViewerExplorerQueryArbiter: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerQueryArbiter(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
