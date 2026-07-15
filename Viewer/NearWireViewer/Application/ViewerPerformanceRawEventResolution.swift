import Foundation

struct ViewerPerformanceRawEventRequest: Equatable, Sendable {
  let sourceGeneration: UInt64
  let key: ViewerEventJournalKey

  init(sourceGeneration: UInt64, key: ViewerEventJournalKey) throws {
    guard sourceGeneration > 0 else { throw ViewerPerformanceFailure.invalidScope }
    self.sourceGeneration = sourceGeneration
    self.key = key
  }
}

struct ViewerPerformanceResolvedRawEvent: Equatable, Sendable {
  let sourceGeneration: UInt64
  let key: ViewerEventJournalKey
  let locator: ViewerPerformanceEventLocator

  init(
    sourceGeneration: UInt64,
    key: ViewerEventJournalKey,
    locator: ViewerPerformanceEventLocator
  ) throws {
    guard sourceGeneration > 0 else { throw ViewerPerformanceFailure.invalidScope }
    self.sourceGeneration = sourceGeneration
    self.key = key
    self.locator = locator
  }
}

enum ViewerPerformanceRawEventGuidance: UInt8, Equatable, Sendable {
  case sourceChanged
  case eventNoLongerAvailable

  var message: String {
    switch self {
    case .sourceChanged:
      return "The performance data changed. Select a current data point and try again."
    case .eventNoLongerAvailable:
      return "The raw Event was evicted and is no longer available in the current Session."
    }
  }
}

enum ViewerPerformanceRawEventResolutionOutcome: Equatable, Sendable {
  case resolved(ViewerPerformanceResolvedRawEvent)
  case guidance(ViewerPerformanceRawEventGuidance)
  case failed(ViewerExplorerFailure)
  case cancelled
}

enum ViewerPerformanceRawEventRevalidation: Equatable, Sendable {
  case explorerIdentity(ViewerExplorerEventIdentity)
  case requiresResolution
  case guidance(ViewerPerformanceRawEventGuidance)
}

@MainActor
final class ViewerPerformanceRawEventResolver: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  typealias Completion =
    @MainActor @Sendable (ViewerPerformanceRawEventResolutionOutcome) -> Void

  private let live: any ViewerLiveObservationProviding
  private var sealed = false

  init(live: any ViewerLiveObservationProviding) {
    self.live = live
  }

  @discardableResult
  func resolve(
    _ request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget,
    completion: @escaping Completion
  ) -> Bool {
    guard !sealed else {
      completion(.cancelled)
      return false
    }
    guard scope.sourceGeneration == request.sourceGeneration, scope.source == target.source,
      request.key.runtimeLogicalID == live.runtimeLogicalID
    else {
      completion(.guidance(.sourceChanged))
      return true
    }
    guard let locator = live.performanceEventLocator(for: request.key) else {
      completion(.guidance(.eventNoLongerAvailable))
      return true
    }
    do {
      completion(
        .resolved(
          try ViewerPerformanceResolvedRawEvent(
            sourceGeneration: request.sourceGeneration,
            key: request.key,
            locator: locator
          )
        )
      )
    } catch {
      completion(.failed(.invalidRequest))
    }
    return true
  }

  func revalidate(
    _ resolved: ViewerPerformanceResolvedRawEvent,
    request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget
  ) -> ViewerPerformanceRawEventRevalidation {
    guard !sealed, resolved.sourceGeneration == request.sourceGeneration,
      resolved.key == request.key, scope.sourceGeneration == request.sourceGeneration,
      scope.source == target.source
    else { return .guidance(.sourceChanged) }
    guard live.performanceEventLocator(for: request.key) == resolved.locator else {
      return .requiresResolution
    }
    return .explorerIdentity(.memory(request.key))
  }

  func cancelActiveAndWait() -> Task<Void, Never> { Task {} }

  func sealAndClear() -> Task<Void, Never> {
    sealed = true
    return Task {}
  }

  var pendingWorkCount: Int { 0 }

  nonisolated var description: String { "ViewerPerformanceRawEventResolver(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }
}
