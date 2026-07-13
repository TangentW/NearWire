import Foundation

enum ViewerExplorerScopeError: Error, Equatable, Sendable {
  case invalidScope
  case invalidFilter
  case invalidMaterialization
  case staleMaterialization
}

enum ViewerExplorerSource: Equatable, Hashable, Sendable {
  case current(runtimeLogicalID: UUID)
  case historical(recordingID: Int64, recordingLogicalID: UUID)
}

enum ViewerExplorerDeviceScope: Equatable, Sendable {
  static let maximumSelectedLogicalIDs = 16

  case all
  case selected([UUID])

  init(selectedLogicalIDs: [UUID]) throws {
    guard
      (1...Self.maximumSelectedLogicalIDs).contains(
        selectedLogicalIDs.count
      ), Set(selectedLogicalIDs).count == selectedLogicalIDs.count
    else { throw ViewerExplorerScopeError.invalidScope }
    self = .selected(selectedLogicalIDs)
  }
}

struct ViewerExplorerFilter: Equatable, Sendable {
  let predicates: [ViewerEventPredicate]

  init(predicates: [ViewerEventPredicate] = []) throws {
    guard predicates.count <= 32,
      !predicates.contains(where: {
        if case .deviceSessionIDs = $0 { return true }
        return false
      })
    else { throw ViewerExplorerScopeError.invalidFilter }
    do {
      _ = try ViewerEventQueryCompiler.compile(
        ViewerEventQuery(recordingID: 1, predicates: predicates)
      )
      _ = try ViewerLiveEvaluationRequest(
        runtimeLogicalID: UUID(),
        predicates: predicates
      )
    } catch {
      throw ViewerExplorerScopeError.invalidFilter
    }
    self.predicates = predicates
  }
}

struct ViewerExplorerScope: Equatable, Sendable {
  let source: ViewerExplorerSource
  let devices: ViewerExplorerDeviceScope
  let filter: ViewerExplorerFilter

  init(
    source: ViewerExplorerSource,
    devices: ViewerExplorerDeviceScope = .all,
    filter: ViewerExplorerFilter
  ) throws {
    if case .historical(let recordingID, _) = source {
      guard recordingID > 0 else { throw ViewerExplorerScopeError.invalidScope }
    }
    if case .selected = devices, filter.predicates.count == 32 {
      throw ViewerExplorerScopeError.invalidScope
    }
    self.source = source
    self.devices = devices
    self.filter = filter
  }
}

struct ViewerExplorerMaterializationSnapshot: Equatable, Sendable {
  static let maximumDeviceMappings = 200

  let source: ViewerExplorerSource
  let generation: UInt64
  let recordingID: Int64?
  let deviceSessionIDsByLogicalID: [UUID: Int64]

  init(
    source: ViewerExplorerSource,
    generation: UInt64,
    recordingID: Int64?,
    deviceSessionIDsByLogicalID: [UUID: Int64]
  ) throws {
    guard generation > 0,
      deviceSessionIDsByLogicalID.count <= Self.maximumDeviceMappings,
      deviceSessionIDsByLogicalID.values.allSatisfy({ $0 > 0 }),
      Set(deviceSessionIDsByLogicalID.values).count == deviceSessionIDsByLogicalID.count
    else { throw ViewerExplorerScopeError.invalidMaterialization }
    if let recordingID {
      guard recordingID > 0 else { throw ViewerExplorerScopeError.invalidMaterialization }
    } else if !deviceSessionIDsByLogicalID.isEmpty {
      throw ViewerExplorerScopeError.invalidMaterialization
    }
    switch source {
    case .current:
      break
    case .historical(let sourceRecordingID, _):
      guard recordingID == sourceRecordingID else {
        throw ViewerExplorerScopeError.invalidMaterialization
      }
    }
    self.source = source
    self.generation = generation
    self.recordingID = recordingID
    self.deviceSessionIDsByLogicalID = deviceSessionIDsByLogicalID
  }
}

struct ViewerExplorerCompiledInputs: Sendable {
  let scope: ViewerExplorerScope
  let materializationGeneration: UInt64
  let durableQuery: ViewerEventQuery?
  let liveRequest: ViewerLiveEvaluationRequest?
  let selectedLogicalDeviceCount: Int
  let materializedSelectedDeviceCount: Int
}

enum ViewerExplorerScopeCompiler {
  static func compile(
    scope: ViewerExplorerScope,
    materialization: ViewerExplorerMaterializationSnapshot
  ) throws -> ViewerExplorerCompiledInputs {
    guard scope.source == materialization.source else {
      throw ViewerExplorerScopeError.staleMaterialization
    }

    let selectedLogicalIDs: [UUID]
    switch scope.devices {
    case .all:
      selectedLogicalIDs = []
    case .selected(let values):
      selectedLogicalIDs = values
    }
    let materializedDeviceIDs = selectedLogicalIDs.compactMap {
      materialization.deviceSessionIDsByLogicalID[$0]
    }.sorted()

    let durableQuery: ViewerEventQuery?
    if let recordingID = materialization.recordingID {
      switch scope.devices {
      case .all:
        durableQuery = try ViewerEventQuery(
          recordingID: recordingID,
          predicates: scope.filter.predicates
        )
      case .selected:
        durableQuery =
          materializedDeviceIDs.isEmpty
          ? nil
          : try ViewerEventQuery(
            recordingID: recordingID,
            predicates: scope.filter.predicates + [.deviceSessionIDs(materializedDeviceIDs)]
          )
      }
    } else {
      durableQuery = nil
    }

    let liveRequest: ViewerLiveEvaluationRequest?
    switch scope.source {
    case .current(let runtimeLogicalID):
      let deviceScope: ViewerLiveDeviceScope
      switch scope.devices {
      case .all:
        deviceScope = .all
      case .selected(let logicalIDs):
        deviceScope = try ViewerLiveDeviceScope(selectedConnectionIDs: logicalIDs)
      }
      liveRequest = try ViewerLiveEvaluationRequest(
        runtimeLogicalID: runtimeLogicalID,
        deviceScope: deviceScope,
        predicates: scope.filter.predicates
      )
    case .historical:
      liveRequest = nil
    }

    return ViewerExplorerCompiledInputs(
      scope: scope,
      materializationGeneration: materialization.generation,
      durableQuery: durableQuery,
      liveRequest: liveRequest,
      selectedLogicalDeviceCount: selectedLogicalIDs.count,
      materializedSelectedDeviceCount: materializedDeviceIDs.count
    )
  }
}

extension ViewerExplorerFilter: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerFilter(redacted, predicates: \(predicates.count))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["predicateCount": predicates.count], displayStyle: .struct)
  }
}

extension ViewerExplorerSource: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerSource(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerExplorerDeviceScope: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerDeviceScope(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

extension ViewerExplorerMaterializationSnapshot: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerExplorerMaterializationSnapshot(mappings: \(deviceSessionIDsByLogicalID.count), redacted)"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["mappingCount": deviceSessionIDsByLogicalID.count],
      displayStyle: .struct
    )
  }
}

extension ViewerExplorerScope: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerScope(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerExplorerCompiledInputs: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerExplorerCompiledInputs(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
