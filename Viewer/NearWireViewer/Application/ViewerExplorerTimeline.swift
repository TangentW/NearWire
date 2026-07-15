import Foundation
@_spi(NearWireInternal) import NearWireCore

struct ViewerExplorerMemoryEventRow: Equatable, Sendable {
  private static let maximumContentSummaryBytes = 256

  let key: ViewerEventJournalKey
  let observationID: UUID
  let eventUUID: String
  let eventType: String
  let contentSummary: String
  let contentByteCount: Int
  let viewerWallMilliseconds: Int64
  let viewerMonotonicNanoseconds: UInt64
  let priority: String
  let deviceAlias: String
  let disposition: String?
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
    contentSummary = Self.makeContentSummary(observation.canonicalProjection.canonicalContent)
    contentByteCount = observation.canonicalProjection.canonicalContent.count
    viewerWallMilliseconds = observation.viewerWallMilliseconds
    viewerMonotonicNanoseconds = observation.viewerMonotonicNanoseconds
    priority = observation.envelope.priority.rawValue
    deviceAlias = observation.session.installationAlias
    disposition = snapshot.laterDisposition?.rawValue
      ?? observation.canonicalProjection.initialDisposition?.rawValue
    hasPresentationConflict = snapshot.hasPresentationConflict
    hasGap = snapshot.hasGap
    hasDrop = snapshot.hasDrop
    sessionEnded = snapshot.sessionEnded
  }

  private static func makeContentSummary(_ content: Data) -> String {
    guard content.count > maximumContentSummaryBytes else {
      return String(decoding: content, as: UTF8.self)
    }
    var count = maximumContentSummaryBytes
    while count > 0 {
      if let value = String(data: content.prefix(count), encoding: .utf8) {
        return value + "…"
      }
      count -= 1
    }
    return "…"
  }
}

struct ViewerExplorerMemoryGapLane: Equatable, Sendable {
  let snapshotGeneration: UInt64
  let gaps: ViewerLiveGapSnapshot

  var hasDiagnostic: Bool {
    gaps.ingressOverflowCount > 0 || gaps.windowOverflowCount > 0
      || gaps.residentConflictCount > 0 || gaps.diagnosticLossCount > 0
  }
}

enum ViewerExplorerLiveEvaluationState: Equatable, Sendable {
  case complete(ViewerLiveTransientExclusion?)
  case refineRequired
}
