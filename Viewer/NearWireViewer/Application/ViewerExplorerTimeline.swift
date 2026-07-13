import Foundation
@_spi(NearWireInternal) import NearWireCore

enum ViewerExplorerTimelineError: Error, Equatable, Sendable {
  case invalidLiveSnapshot
  case staleLiveSnapshot
}

struct ViewerExplorerTransientEventRow: Equatable, Sendable {
  let key: ViewerEventJournalKey
  let observationID: UUID
  let eventUUID: String
  let eventType: String
  let contentByteCount: Int
  let createdWallMilliseconds: Int64
  let viewerWallMilliseconds: Int64
  let viewerMonotonicNanoseconds: UInt64
  let priority: String
  let deviceAlias: String
  let resolvedDisposition: String?
  let durableState: ViewerLiveDurableState
  let hasPresentationConflict: Bool
  let hasGap: Bool
  let hasDrop: Bool
  let sessionEnded: Bool

  init(_ snapshot: ViewerLiveEventSnapshot) {
    let observation = snapshot.observation
    key = observation.key
    observationID = observation.observationID
    eventUUID = observation.envelope.id.rawValue
    eventType = observation.envelope.type.rawValue
    contentByteCount = observation.durableProjection.canonicalContent.count
    createdWallMilliseconds = observation.durableProjection.createdWallMilliseconds
    viewerWallMilliseconds = observation.viewerWallMilliseconds
    viewerMonotonicNanoseconds = observation.viewerMonotonicNanoseconds
    priority = observation.envelope.priority.rawValue
    deviceAlias = observation.session.installationAlias
    resolvedDisposition =
      snapshot.laterDisposition?.rawValue
      ?? observation.durableProjection.initialDisposition?.rawValue
    durableState = snapshot.durableState
    hasPresentationConflict = snapshot.hasPresentationConflict
    hasGap = snapshot.hasGap
    hasDrop = snapshot.hasDrop
    sessionEnded = snapshot.sessionEnded
  }
}

enum ViewerExplorerTimelineRow: Equatable, Sendable {
  case durable(summary: ViewerStoredEventRow, journalKey: ViewerEventJournalKey?)
  case transient(ViewerExplorerTransientEventRow)

  var identity: ViewerExplorerEventIdentity {
    switch self {
    case .durable(let summary, _): return .durable(rowID: summary.rowID)
    case .transient(let summary): return .transient(summary.key)
    }
  }

  var viewerMonotonicNanoseconds: UInt64? {
    switch self {
    case .durable(let summary, _):
      return UInt64(exactly: summary.viewerMonotonicNanoseconds)
    case .transient(let summary):
      return summary.viewerMonotonicNanoseconds
    }
  }

  var journalKey: ViewerEventJournalKey? {
    switch self {
    case .durable(_, let journalKey): return journalKey
    case .transient(let summary): return summary.key
    }
  }
}

struct ViewerExplorerDurableVisibility: Equatable, Sendable {
  let key: ViewerEventJournalKey
  let observationID: UUID
  let durableRowID: Int64
}

struct ViewerExplorerTimelineMutation: Equatable, Sendable {
  let evictedIdentities: [ViewerExplorerEventIdentity]
  let evictedEdge: ViewerExplorerWindowEdge?
  let durableVisibilities: [ViewerExplorerDurableVisibility]
}

struct ViewerExplorerLiveGapLane: Equatable, Sendable {
  let snapshotGeneration: UInt64
  let gaps: ViewerLiveGapSnapshot

  var hasDiagnostic: Bool {
    gaps.ingressOverflowCount > 0 || gaps.windowOverflowCount > 0
      || gaps.residentConflictCount > 0 || gaps.diagnosticLossCount > 0
      || gaps.storeUnavailableCount > 0 || gaps.storeRecoveryCount > 0
      || gaps.storeUnavailable
  }
}

enum ViewerExplorerLiveEvaluationState: Equatable, Sendable {
  case complete(ViewerLiveTransientExclusion?)
  case refineRequired
}

enum ViewerExplorerTimelineReconciler {
  static func durableJournalKey(
    for row: ViewerStoredEventRow,
    scope: ViewerExplorerScope?,
    materialization: ViewerExplorerMaterializationSnapshot?
  ) -> ViewerEventJournalKey? {
    guard case .current(let runtimeLogicalID) = scope?.source,
      materialization?.source == scope?.source,
      let connectionID = materialization?.deviceSessionIDsByLogicalID.first(where: {
        $0.value == row.deviceSessionID
      })?.key,
      let direction = EventDirection(rawValue: row.direction),
      let wireSequence = UInt64(exactly: row.wireSequence)
    else { return nil }
    return ViewerEventJournalKey(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      direction: direction,
      wireSequence: wireSequence
    )
  }

  static func transientRows(
    snapshot: ViewerLiveProjectionSnapshot,
    matchedKeys: [ViewerEventJournalKey],
    runtimeLogicalID: UUID
  ) throws -> [ViewerExplorerTransientEventRow] {
    guard snapshot.runtimeLogicalID == runtimeLogicalID,
      snapshot.events.count <= ViewerLiveProjectionLimits.retainedCount,
      snapshot.accountedEventBytes <= ViewerLiveProjectionLimits.retainedBytes,
      Set(matchedKeys).count == matchedKeys.count
    else { throw ViewerExplorerTimelineError.invalidLiveSnapshot }
    let matches = Set(matchedKeys)
    var rows: [ViewerExplorerTransientEventRow] = []
    rows.reserveCapacity(min(matches.count, snapshot.events.count))
    for event in snapshot.events where matches.contains(event.observation.key) {
      guard event.observation.key.runtimeLogicalID == runtimeLogicalID else {
        throw ViewerExplorerTimelineError.invalidLiveSnapshot
      }
      rows.append(ViewerExplorerTransientEventRow(event))
    }
    guard rows.count == matches.count else {
      throw ViewerExplorerTimelineError.staleLiveSnapshot
    }
    return rows
  }
}

struct ViewerExplorerTimelineWindow: Sendable {
  private(set) var rows: [ViewerExplorerTimelineRow] = []
  private(set) var navigation =
    ViewerExplorerListNavigation<ViewerEventCursor, ViewerExplorerEventIdentity>()

  let capacity: Int

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  mutating func applyDurablePage(
    _ page: ViewerEventPage,
    placement: ViewerExplorerPagePlacement,
    scope: ViewerExplorerScope?,
    materialization: ViewerExplorerMaterializationSnapshot?
  ) -> ViewerExplorerTimelineMutation? {
    guard Self.isStrictlyOrdered(page.rows), Set(page.rows.map(\.rowID)).count == page.rows.count
    else { return nil }
    let currentDurableRows = rows.compactMap { row -> ViewerStoredEventRow? in
      if case .durable(let summary, _) = row { return summary }
      return nil
    }
    let transientRows = rows.compactMap { row -> ViewerExplorerTransientEventRow? in
      if case .transient(let summary) = row { return summary }
      return nil
    }
    let incomingIDs = Set(page.rows.map(\.rowID))
    let durableRows: [ViewerStoredEventRow]
    switch placement {
    case .replace:
      durableRows = page.rows
    case .leading:
      durableRows = page.rows + currentDurableRows.filter { !incomingIDs.contains($0.rowID) }
    case .trailing:
      durableRows = currentDurableRows.filter { !incomingIDs.contains($0.rowID) } + page.rows
    }
    guard Self.isStrictlyOrdered(durableRows) else { return nil }

    switch placement {
    case .replace:
      navigation = ViewerExplorerListNavigation(
        leadingCursor: page.previousCursor,
        trailingCursor: page.nextCursor,
        reloadAnchor: nil,
        hasUnloadedLeadingRows: false,
        hasUnloadedTrailingRows: false
      )
    case .leading:
      navigation.leadingCursor = page.previousCursor
      if currentDurableRows.isEmpty { navigation.trailingCursor = page.nextCursor }
    case .trailing:
      navigation.trailingCursor = page.nextCursor
      if currentDurableRows.isEmpty { navigation.leadingCursor = page.previousCursor }
    }
    return rebuild(
      durableRows: durableRows,
      transientRows: transientRows,
      scope: scope,
      materialization: materialization,
      retaining: placement == .leading ? .leading : .trailing
    )
  }

  mutating func applyLiveRows(
    _ transientRows: [ViewerExplorerTransientEventRow],
    autoFollow: Bool
  ) -> ViewerExplorerTimelineMutation? {
    guard Set(transientRows.map(\.key)).count == transientRows.count else { return nil }
    let durableRows = rows.compactMap { row -> ViewerStoredEventRow? in
      if case .durable(let summary, _) = row { return summary }
      return nil
    }
    return rebuild(
      durableRows: durableRows,
      transientRows: transientRows,
      scope: nil,
      materialization: nil,
      preservesExistingDurableKeys: true,
      retaining: autoFollow ? .trailing : .leading
    )
  }

  mutating func clear() {
    rows.removeAll(keepingCapacity: false)
    navigation = ViewerExplorerListNavigation()
  }

  func contains(_ identity: ViewerExplorerEventIdentity) -> Bool {
    rows.contains { $0.identity == identity }
  }

  func firstIdentity() -> ViewerExplorerEventIdentity? { rows.first?.identity }
  func lastIdentity() -> ViewerExplorerEventIdentity? { rows.last?.identity }

  private mutating func rebuild(
    durableRows: [ViewerStoredEventRow],
    transientRows: [ViewerExplorerTransientEventRow],
    scope: ViewerExplorerScope?,
    materialization: ViewerExplorerMaterializationSnapshot?,
    preservesExistingDurableKeys: Bool = false,
    retaining edge: ViewerExplorerWindowEdge
  ) -> ViewerExplorerTimelineMutation? {
    return rebuildResolved(
      durableRows: durableRows,
      transientRows: transientRows,
      scope: scope,
      materialization: materialization,
      preservesExistingDurableKeys: preservesExistingDurableKeys,
      retaining: edge
    )
  }

  private mutating func rebuildResolved(
    durableRows: [ViewerStoredEventRow],
    transientRows: [ViewerExplorerTransientEventRow],
    scope: ViewerExplorerScope?,
    materialization: ViewerExplorerMaterializationSnapshot?,
    preservesExistingDurableKeys: Bool,
    retaining edge: ViewerExplorerWindowEdge
  ) -> ViewerExplorerTimelineMutation? {
    let priorRows = rows
    var durableTimelineRows: [ViewerExplorerTimelineRow] = []
    durableTimelineRows.reserveCapacity(durableRows.count)
    for row in durableRows {
      guard row.rowID > 0, row.viewerMonotonicNanoseconds >= 0 else { return nil }
      let journalKey: ViewerEventJournalKey?
      if preservesExistingDurableKeys {
        journalKey =
          priorRows.first(where: {
            if case .durable(let summary, _) = $0 { return summary.rowID == row.rowID }
            return false
          })?.journalKey
      } else {
        journalKey = ViewerExplorerTimelineReconciler.durableJournalKey(
          for: row,
          scope: scope,
          materialization: materialization
        )
      }
      durableTimelineRows.append(.durable(summary: row, journalKey: journalKey))
    }
    let durableKeyPairs = durableTimelineRows.compactMap {
      row -> (ViewerEventJournalKey, Int64)? in
      guard case .durable(let summary, let key?) = row else { return nil }
      return (key, summary.rowID)
    }
    guard Set(durableKeyPairs.map(\.0)).count == durableKeyPairs.count else { return nil }
    let durableKeys = Dictionary(uniqueKeysWithValues: durableKeyPairs)
    let visibilities = transientRows.compactMap { row -> ViewerExplorerDurableVisibility? in
      guard let rowID = durableKeys[row.key] else { return nil }
      return ViewerExplorerDurableVisibility(
        key: row.key,
        observationID: row.observationID,
        durableRowID: rowID
      )
    }
    if let anchor = navigation.reloadAnchor,
      case .transient(let key) = anchor.identity,
      let durableRowID = durableKeys[key]
    {
      navigation.reloadAnchor = ViewerExplorerReloadAnchor(
        edge: anchor.edge,
        identity: .durable(rowID: durableRowID)
      )
    }
    var combined = durableTimelineRows
    combined.append(
      contentsOf: transientRows.compactMap {
        durableKeys[$0.key] == nil ? .transient($0) : nil
      }
    )
    combined.sort(by: Self.isOrderedBefore)
    guard Set(combined.map(\.identity)).count == combined.count,
      Self.isStrictlyOrdered(combined)
    else { return nil }

    var retained = combined
    var evicted: [ViewerExplorerTimelineRow] = []
    var evictedEdge: ViewerExplorerWindowEdge?
    if retained.count > capacity {
      let excess = retained.count - capacity
      switch edge {
      case .leading:
        evicted = Array(retained.suffix(excess))
        retained.removeLast(excess)
        evictedEdge = .trailing
      case .trailing:
        evicted = Array(retained.prefix(excess))
        retained.removeFirst(excess)
        evictedEdge = .leading
      }
    }
    if let evictedEdge, !evicted.isEmpty {
      let closest = evictedEdge == .leading ? evicted.last! : evicted.first!
      navigation.reloadAnchor = ViewerExplorerReloadAnchor(
        edge: evictedEdge,
        identity: closest.identity
      )
      navigation.hasUnloadedLeadingRows = evictedEdge == .leading
      navigation.hasUnloadedTrailingRows = evictedEdge == .trailing
    }
    rows = retained
    return ViewerExplorerTimelineMutation(
      evictedIdentities: evicted.map(\.identity),
      evictedEdge: evictedEdge,
      durableVisibilities: visibilities
    )
  }

  private static func isStrictlyOrdered(_ rows: [ViewerStoredEventRow]) -> Bool {
    guard rows.count > 1 else { return true }
    for index in 1..<rows.count {
      let previous = rows[index - 1]
      let current = rows[index]
      guard
        previous.viewerMonotonicNanoseconds < current.viewerMonotonicNanoseconds
          || (previous.viewerMonotonicNanoseconds == current.viewerMonotonicNanoseconds
            && previous.rowID < current.rowID)
      else { return false }
    }
    return true
  }

  private static func isStrictlyOrdered(_ rows: [ViewerExplorerTimelineRow]) -> Bool {
    guard rows.count > 1 else { return true }
    for index in 1..<rows.count where !isOrderedBefore(rows[index - 1], rows[index]) {
      return false
    }
    return true
  }

  private static func isOrderedBefore(
    _ lhs: ViewerExplorerTimelineRow,
    _ rhs: ViewerExplorerTimelineRow
  ) -> Bool {
    guard let leftTime = lhs.viewerMonotonicNanoseconds,
      let rightTime = rhs.viewerMonotonicNanoseconds
    else { return false }
    if leftTime != rightTime { return leftTime < rightTime }
    switch (lhs, rhs) {
    case (.durable(let left, _), .durable(let right, _)):
      return left.rowID < right.rowID
    case (.durable, .transient):
      return true
    case (.transient, .durable):
      return false
    case (.transient(let left), .transient(let right)):
      if left.key.connectionID != right.key.connectionID {
        return left.key.connectionID.uuidString < right.key.connectionID.uuidString
      }
      if left.key.direction != right.key.direction {
        return left.key.direction.rawValue < right.key.direction.rawValue
      }
      return left.key.wireSequence < right.key.wireSequence
    }
  }
}

extension ViewerExplorerTransientEventRow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerExplorerTransientEventRow(redacted, contentBytes: \(contentByteCount))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["contentBytes": contentByteCount], displayStyle: .struct)
  }
}

extension ViewerExplorerTimelineRow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerTimelineRow(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerExplorerLiveGapLane: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerLiveGapLane(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
