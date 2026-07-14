import Foundation
@_spi(NearWireInternal) import NearWireCore

struct ViewerPerformanceMetricDescriptor: Equatable, Sendable {
  let key: PerformanceMetricKey
  let group: PerformanceMetricGroup
  let kind: PerformanceMetricKind
}

enum ViewerPerformanceMetricInventory {
  static let descriptors: [ViewerPerformanceMetricDescriptor] =
    PerformanceMetricKey.allCases.map { key in
      ViewerPerformanceMetricDescriptor(key: key, group: key.group, kind: key.kind)
    }
}

enum ViewerPerformanceMetricState: Equatable, Sendable {
  case numeric(Double)
  case unsigned(UInt64)
  case batteryState(BatteryState)
  case thermalState(ThermalState)
  case boolean(Bool)
  case unavailable(UnavailablePerformanceMetricReason)
  case notCollected

  var isMeasurement: Bool {
    switch self {
    case .numeric, .unsigned, .batteryState, .thermalState, .boolean: return true
    case .unavailable, .notCollected: return false
    }
  }
}

struct ViewerDecodedPerformanceSnapshot: Equatable, Sendable {
  let sampledAt: Date
  let sampleIntervalMilliseconds: UInt64
  private let states: [ViewerPerformanceMetricState]

  init(
    sampledAt: Date,
    sampleIntervalMilliseconds: UInt64,
    states: [ViewerPerformanceMetricState]
  ) throws {
    guard states.count == PerformanceMetricKey.allCases.count else {
      throw ViewerPerformanceStoreFailure.invalidCarrier
    }
    self.sampledAt = sampledAt
    self.sampleIntervalMilliseconds = sampleIntervalMilliseconds
    self.states = states
  }

  func state(for key: PerformanceMetricKey) -> ViewerPerformanceMetricState {
    guard let index = PerformanceMetricKey.allCases.firstIndex(of: key) else {
      preconditionFailure("Core performance metric inventory is incomplete")
    }
    return states[index]
  }
}

enum ViewerPerformanceInvalidSnapshotReason: String, Equatable, Sendable {
  case oversizedContent
  case malformedJSON
  case unsupportedSchema
  case invalidCoreContent
  case duplicateKnownUnavailable
  case presentAndUnavailable
}

enum ViewerPerformanceDecodeOutcome: Equatable, Sendable {
  case valid(ViewerDecodedPerformanceSnapshot)
  case invalid(ViewerPerformanceInvalidSnapshotReason)
}

enum ViewerPerformanceSnapshotDecoder {
  private static let limits: EventValidationLimits = {
    do {
      return try EventValidationLimits(
        maximumEncodedContentBytes: ViewerPerformanceLimits.decoderBufferBytes,
        maximumEncodedModelBytes: 327_680
      )
    } catch {
      preconditionFailure("Viewer performance decoder limits are invalid")
    }
  }()

  static func decode(_ content: ViewerPerformanceEventContent) -> ViewerPerformanceDecodeOutcome {
    let data: Data
    switch content {
    case .oversized:
      return .invalid(.oversizedContent)
    case .canonical(let canonical):
      guard canonical.count <= ViewerPerformanceLimits.decoderBufferBytes else {
        return .invalid(.oversizedContent)
      }
      data = canonical
    }

    let raw: JSONValue
    do {
      raw = try JSONValue.decodeJSON(from: data, limits: limits)
    } catch {
      return .invalid(.malformedJSON)
    }
    if case .object(let root) = raw,
      case .integer(let schemaVersion)? = root["schemaVersion"],
      schemaVersion != Int64(PerformanceSnapshotSchema.version)
    {
      return .invalid(.unsupportedSchema)
    }

    let snapshot: PerformanceSnapshot
    do {
      snapshot = try EventContentCodec(limits: limits).decode(PerformanceSnapshot.self, from: raw)
    } catch {
      return .invalid(.invalidCoreContent)
    }

    var unavailable: [PerformanceMetricKey: UnavailablePerformanceMetricReason] = [:]
    for value in snapshot.unavailable {
      guard let key = PerformanceMetricKey(rawValue: value.metric) else { continue }
      guard unavailable.updateValue(value.reason, forKey: key) == nil else {
        return .invalid(.duplicateKnownUnavailable)
      }
    }

    var states = Array(
      repeating: ViewerPerformanceMetricState.notCollected,
      count: PerformanceMetricKey.allCases.count
    )
    func set(_ state: ViewerPerformanceMetricState?, for key: PerformanceMetricKey) {
      guard let state,
        let index = PerformanceMetricKey.allCases.firstIndex(of: key)
      else { return }
      states[index] = state
    }
    set(
      snapshot.process?.cpuPercent.map(ViewerPerformanceMetricState.numeric),
      for: .processCPUPercent)
    set(
      snapshot.process?.memoryFootprintBytes.map(ViewerPerformanceMetricState.unsigned),
      for: .processMemoryFootprintBytes
    )
    set(
      snapshot.display?.estimatedFramesPerSecond.map(ViewerPerformanceMetricState.numeric),
      for: .displayEstimatedFramesPerSecond
    )
    set(
      snapshot.display?.maximumFramesPerSecond.map(ViewerPerformanceMetricState.numeric),
      for: .displayMaximumFramesPerSecond
    )
    set(
      snapshot.device?.batteryLevel.map(ViewerPerformanceMetricState.numeric),
      for: .deviceBatteryLevel)
    set(
      snapshot.device?.batteryState.map(ViewerPerformanceMetricState.batteryState),
      for: .deviceBatteryState)
    set(
      snapshot.device?.thermalState.map(ViewerPerformanceMetricState.thermalState),
      for: .deviceThermalState)
    set(
      snapshot.device?.lowPowerModeEnabled.map(ViewerPerformanceMetricState.boolean),
      for: .deviceLowPowerModeEnabled
    )
    set(
      snapshot.transport?.uplinkQueueDepth.map(ViewerPerformanceMetricState.unsigned),
      for: .transportUplinkQueueDepth
    )
    set(
      snapshot.transport?.droppedEventCount.map(ViewerPerformanceMetricState.unsigned),
      for: .transportDroppedEventCount
    )
    set(
      snapshot.transport?.uplinkBytesPerSecond.map(ViewerPerformanceMetricState.unsigned),
      for: .transportUplinkBytesPerSecond
    )
    set(
      snapshot.transport?.downlinkBytesPerSecond.map(ViewerPerformanceMetricState.unsigned),
      for: .transportDownlinkBytesPerSecond
    )
    set(
      snapshot.transport?.downlinkQueueDepth.map(ViewerPerformanceMetricState.unsigned),
      for: .transportDownlinkQueueDepth
    )

    for (key, reason) in unavailable {
      guard let index = PerformanceMetricKey.allCases.firstIndex(of: key) else { continue }
      guard !states[index].isMeasurement else {
        return .invalid(.presentAndUnavailable)
      }
      states[index] = .unavailable(reason)
    }
    do {
      return .valid(
        try ViewerDecodedPerformanceSnapshot(
          sampledAt: snapshot.sampledAt,
          sampleIntervalMilliseconds: snapshot.sampleIntervalMilliseconds,
          states: states
        )
      )
    } catch {
      return .invalid(.invalidCoreContent)
    }
  }
}

enum ViewerPerformanceEventReconciler {
  static func reconcile(
    _ lhs: ViewerPerformanceEventCarrier,
    _ rhs: ViewerPerformanceEventCarrier
  ) throws -> ViewerPerformanceEventCarrier {
    guard lhs.key == rhs.key,
      lhs.viewerWallMilliseconds == rhs.viewerWallMilliseconds,
      lhs.viewerMonotonicNanoseconds == rhs.viewerMonotonicNanoseconds,
      lhs.content == rhs.content
    else { throw ViewerPerformanceStoreFailure.invalidCarrier }

    let locator: ViewerPerformanceEventLocator
    switch (lhs.locator, rhs.locator) {
    case (.durable(let leftRow, let leftDevice), .durable(let rightRow, let rightDevice)):
      guard leftRow == rightRow, leftDevice == rightDevice else {
        throw ViewerPerformanceStoreFailure.invalidCarrier
      }
      locator = lhs.locator
    case (.durable, .transient):
      locator = lhs.locator
    case (.transient, .durable):
      locator = rhs.locator
    case (.transient(let leftID), .transient(let rightID)):
      locator =
        ViewerPerformanceCanonicalOrder.uuidPrecedes(leftID, rightID)
        ? lhs.locator : rhs.locator
    }
    return try ViewerPerformanceEventCarrier(
      locator: locator,
      key: lhs.key,
      viewerWallMilliseconds: lhs.viewerWallMilliseconds,
      viewerMonotonicNanoseconds: lhs.viewerMonotonicNanoseconds,
      content: lhs.content
    )
  }
}

enum ViewerPerformanceFreezeFailure: Error, Equatable, Sendable {
  case live(ViewerPerformanceStoreFailure)
  case store(ViewerStoreExplorerFailure)
}

final class ViewerPerformanceFreezeCoordinator: @unchecked Sendable {
  private let live: any ViewerLiveObservationProviding
  private let storeGateway: ViewerStoreExplorerGateway

  init(
    live: any ViewerLiveObservationProviding,
    storeGateway: ViewerStoreExplorerGateway
  ) {
    self.live = live
    self.storeGateway = storeGateway
  }

  @discardableResult
  func freezeCurrent(
    connectionID: UUID,
    recordingID: Int64,
    deviceSessionID: Int64,
    lowerMonotonicNanoseconds: Int64,
    completion:
      @escaping @Sendable (
        Result<ViewerPerformanceFrozenReceipt, ViewerPerformanceFreezeFailure>
      ) -> Void
  ) -> ViewerStoreExplorerOperationToken? {
    let slice: ViewerPerformanceLiveSlice
    do {
      slice = try live.freezePerformance(connectionID: connectionID)
    } catch let failure as ViewerPerformanceStoreFailure {
      completion(.failure(.live(failure)))
      return nil
    } catch {
      completion(.failure(.live(.unavailable)))
      return nil
    }
    guard let upper = Int64(exactly: slice.anchorMonotonicNanoseconds),
      lowerMonotonicNanoseconds >= 0, lowerMonotonicNanoseconds <= upper
    else {
      completion(.failure(.live(.invalidScope)))
      return nil
    }
    let source = ViewerPerformanceSource.current(
      runtimeLogicalID: live.runtimeLogicalID,
      connectionID: connectionID
    )
    return storeGateway.beginPerformanceTraversal(
      recordingID: recordingID,
      deviceSessionID: deviceSessionID,
      lowerMonotonicNanoseconds: lowerMonotonicNanoseconds,
      upperMonotonicNanoseconds: upper
    ) { result in
      switch result {
      case .success(let scope):
        completion(
          .success(
            ViewerPerformanceFrozenReceipt(
              source: source,
              storeScope: scope,
              liveSlice: slice
            )
          )
        )
      case .failure(.unavailable):
        completion(
          .success(
            ViewerPerformanceFrozenReceipt(
              source: source,
              storeScope: nil,
              liveSlice: slice
            )
          )
        )
      case .failure(let failure):
        completion(.failure(.store(failure)))
      }
    }
  }
}

extension ViewerPerformanceMetricState: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceMetricState(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerDecodedPerformanceSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerDecodedPerformanceSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerPerformanceDecodeOutcome: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceDecodeOutcome(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerPerformanceFreezeCoordinator: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerPerformanceFreezeCoordinator(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
