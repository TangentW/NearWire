import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

enum ViewerPerformanceLimits {
  static let maximumRowContentBytes = 65_536
  static let maximumCopiedContentBytes = 4_194_304
  static let maximumEmittedEvents = 512
  static let eventCarrierBytes = 512
  static let eventPageWrapperBytes = 4_096
  static let maximumLiveGaps = 128
  static let maximumProjectionGaps = 128
  static let gapCarrierBytes = 256
  static let maximumLiveSliceBytes = 4_493_312
  static let decoderBufferBytes = 65_536
}

enum ViewerPerformanceFailure: Error, Equatable, Sendable {
  case invalidScope
  case invalidContinuation
  case invalidCarrier
  case limitExceeded
  case workLimitExceeded
  case cancelled
  case unavailable
}

enum ViewerPerformanceSource: Equatable, Hashable, Sendable {
  case current(runtimeLogicalID: UUID, connectionID: UUID)
}

enum ViewerPerformanceEventLocator: Equatable, Hashable, Sendable {
  case memory(observationID: UUID)
}

enum ViewerPerformanceEventContent: Equatable, Sendable {
  case canonical(Data)
  case oversized(byteCount: Int64)

  var copiedByteCount: Int {
    switch self {
    case .canonical(let data): return data.count
    case .oversized: return 0
    }
  }

  var declaredByteCount: Int64 {
    switch self {
    case .canonical(let data): return Int64(data.count)
    case .oversized(let byteCount): return byteCount
    }
  }
}

struct ViewerPerformanceEventCarrier: Equatable, Sendable {
  let locator: ViewerPerformanceEventLocator
  let key: ViewerEventJournalKey
  let viewerWallMilliseconds: Int64
  let viewerMonotonicNanoseconds: Int64
  let content: ViewerPerformanceEventContent

  init(
    locator: ViewerPerformanceEventLocator,
    key: ViewerEventJournalKey,
    viewerWallMilliseconds: Int64,
    viewerMonotonicNanoseconds: Int64,
    content: ViewerPerformanceEventContent
  ) throws {
    guard viewerMonotonicNanoseconds >= 0 else {
      throw ViewerPerformanceFailure.invalidCarrier
    }
    switch content {
    case .canonical(let data):
      guard data.count <= ViewerPerformanceLimits.maximumRowContentBytes else {
        throw ViewerPerformanceFailure.limitExceeded
      }
    case .oversized(let byteCount):
      guard byteCount > Int64(ViewerPerformanceLimits.maximumRowContentBytes) else {
        throw ViewerPerformanceFailure.invalidCarrier
      }
    }
    self.locator = locator
    self.key = key
    self.viewerWallMilliseconds = viewerWallMilliseconds
    self.viewerMonotonicNanoseconds = viewerMonotonicNanoseconds
    self.content = content
  }

  var accountedBytes: Int {
    ViewerPerformanceLimits.eventCarrierBytes + content.copiedByteCount
  }
}

enum ViewerPerformanceCanonicalOrder {
  static func eventPrecedes(
    _ lhs: ViewerPerformanceEventCarrier,
    _ rhs: ViewerPerformanceEventCarrier
  ) -> Bool {
    if lhs.viewerMonotonicNanoseconds != rhs.viewerMonotonicNanoseconds {
      return lhs.viewerMonotonicNanoseconds < rhs.viewerMonotonicNanoseconds
    }
    return keyPrecedes(lhs.key, rhs.key)
  }

  static func keyPrecedes(_ lhs: ViewerEventJournalKey, _ rhs: ViewerEventJournalKey) -> Bool {
    let runtimeComparison = compareUUID(lhs.runtimeLogicalID, rhs.runtimeLogicalID)
    if runtimeComparison != 0 { return runtimeComparison < 0 }
    let connectionComparison = compareUUID(lhs.connectionID, rhs.connectionID)
    if connectionComparison != 0 { return connectionComparison < 0 }
    let leftDirection = directionOrdinal(lhs.direction)
    let rightDirection = directionOrdinal(rhs.direction)
    if leftDirection != rightDirection { return leftDirection < rightDirection }
    return lhs.wireSequence < rhs.wireSequence
  }

  static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
    compareUUID(lhs, rhs) < 0
  }

  static func compareUUID(_ lhs: UUID, _ rhs: UUID) -> Int {
    var leftValue = lhs.uuid
    var rightValue = rhs.uuid
    return withUnsafeBytes(of: &leftValue) { leftBytes in
      withUnsafeBytes(of: &rightValue) { rightBytes in
        for index in 0..<leftBytes.count where leftBytes[index] != rightBytes[index] {
          return leftBytes[index] < rightBytes[index] ? -1 : 1
        }
        return 0
      }
    }
  }

  private static func directionOrdinal(_ direction: EventDirection) -> UInt8 {
    switch direction {
    case .appToViewer: return 0
    case .viewerToApp: return 1
    }
  }
}

enum ViewerPerformanceGapKind: String, Equatable, Hashable, Sendable {
  case eventLoss
  case controlContinuity
  case lifecycleContinuity
  case presentationLoss
  case unknown
}

enum ViewerPerformanceGapApplicability: String, Equatable, Hashable, Sendable {
  case performance
  case irrelevant
  case uncertain
}

struct ViewerPerformanceGapCarrier: Equatable, Sendable {
  let count: UInt64
  let firstViewerWallMilliseconds: Int64?
  let lastViewerWallMilliseconds: Int64?
  let kind: ViewerPerformanceGapKind
  let applicability: ViewerPerformanceGapApplicability

  init(
    count: UInt64,
    firstViewerWallMilliseconds: Int64?,
    lastViewerWallMilliseconds: Int64?,
    kind: ViewerPerformanceGapKind,
    applicability: ViewerPerformanceGapApplicability
  ) throws {
    guard count > 0,
      (firstViewerWallMilliseconds == nil) == (lastViewerWallMilliseconds == nil)
    else { throw ViewerPerformanceFailure.invalidCarrier }
    self.count = count
    self.firstViewerWallMilliseconds = firstViewerWallMilliseconds
    self.lastViewerWallMilliseconds = lastViewerWallMilliseconds
    self.kind = kind
    self.applicability = applicability
  }
}

struct ViewerPerformanceLiveSlice: Equatable, Sendable {
  let runtimeLogicalID: UUID
  let connectionID: UUID
  let liveGeneration: UInt64
  let revision: UInt64
  let anchorMonotonicNanoseconds: UInt64
  let events: [ViewerPerformanceEventCarrier]
  let gaps: [ViewerPerformanceGapCarrier]
  let applicableOrUncertainCount: UInt64
  let hasMoreApplicableGaps: Bool
  let copiedContentBytes: Int
  let accountedBytes: Int

  init(
    runtimeLogicalID: UUID,
    connectionID: UUID,
    liveGeneration: UInt64,
    revision: UInt64,
    anchorMonotonicNanoseconds: UInt64,
    events: [ViewerPerformanceEventCarrier],
    gaps: [ViewerPerformanceGapCarrier],
    applicableOrUncertainCount: UInt64,
    hasMoreApplicableGaps: Bool
  ) throws {
    guard liveGeneration > 0, revision > 0,
      events.count <= ViewerPerformanceLimits.maximumEmittedEvents,
      gaps.count <= ViewerPerformanceLimits.maximumLiveGaps,
      Self.isStrictlyCanonical(events),
      events.allSatisfy({
        $0.key.runtimeLogicalID == runtimeLogicalID && $0.key.connectionID == connectionID
          && UInt64($0.viewerMonotonicNanoseconds) <= anchorMonotonicNanoseconds
      })
    else { throw ViewerPerformanceFailure.limitExceeded }
    let copiedContentBytes = try Self.checkedSum(events.map { $0.content.copiedByteCount })
    guard copiedContentBytes <= ViewerPerformanceLimits.maximumCopiedContentBytes else {
      throw ViewerPerformanceFailure.limitExceeded
    }
    let eventBytes = try Self.checkedMultiply(
      events.count,
      ViewerPerformanceLimits.eventCarrierBytes
    )
    let gapBytes = try Self.checkedMultiply(gaps.count, ViewerPerformanceLimits.gapCarrierBytes)
    let accountedBytes = try Self.checkedSum([
      ViewerPerformanceLimits.eventPageWrapperBytes,
      eventBytes,
      copiedContentBytes,
      gapBytes,
    ])
    guard accountedBytes <= ViewerPerformanceLimits.maximumLiveSliceBytes else {
      throw ViewerPerformanceFailure.limitExceeded
    }
    self.runtimeLogicalID = runtimeLogicalID
    self.connectionID = connectionID
    self.liveGeneration = liveGeneration
    self.revision = revision
    self.anchorMonotonicNanoseconds = anchorMonotonicNanoseconds
    self.events = events
    self.gaps = gaps
    self.applicableOrUncertainCount = applicableOrUncertainCount
    self.hasMoreApplicableGaps = hasMoreApplicableGaps
    self.copiedContentBytes = copiedContentBytes
    self.accountedBytes = accountedBytes
  }

  private static func checkedSum(_ values: [Int]) throws -> Int {
    var result = 0
    for value in values {
      let (next, overflow) = result.addingReportingOverflow(value)
      guard !overflow else { throw ViewerPerformanceFailure.limitExceeded }
      result = next
    }
    return result
  }

  private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw ViewerPerformanceFailure.limitExceeded }
    return result
  }

  private static func isStrictlyCanonical(_ events: [ViewerPerformanceEventCarrier]) -> Bool {
    guard events.count > 1 else { return true }
    for index in 1..<events.count {
      guard ViewerPerformanceCanonicalOrder.eventPrecedes(events[index - 1], events[index]) else {
        return false
      }
    }
    return true
  }
}

struct ViewerPerformanceFrozenReceipt: Equatable, Sendable {
  let source: ViewerPerformanceSource
  let liveSlice: ViewerPerformanceLiveSlice
}
