import Foundation

enum ViewerAnalysisMode: Equatable, Sendable {
  case events
  case performance
}

enum ViewerAnalysisGuidance: Equatable, Sendable {
  case selectOneDevice
  case deviceNotReady
  case sourceUnavailable
  case rawEvent(ViewerPerformanceRawEventGuidance)
  case rawEventResolutionFailed

  var message: String {
    switch self {
    case .selectOneDevice:
      return "Select one device to view performance"
    case .deviceNotReady:
      return "The selected device is not ready for performance analysis."
    case .sourceUnavailable:
      return "Performance data for the selected Device is no longer available."
    case .rawEvent(let guidance):
      return guidance.message
    case .rawEventResolutionFailed:
      return "The raw Event could not be opened. Try again."
    }
  }
}

enum ViewerPerformanceTargetSelection: Equatable, Sendable {
  case target(ViewerPerformanceDashboardTarget)
  case guidance(ViewerAnalysisGuidance)
}

enum ViewerPerformanceTargetCompiler {
  static func compile(
    source: ViewerExplorerSource,
    selectedDeviceIDs: [UUID],
    catalogRecordingID: Int64?,
    recordingRows: [ViewerRecordingCatalogRow],
    deviceRows: [ViewerDeviceCatalogRow],
    sessions: [ViewerSessionSnapshot]
  ) -> ViewerPerformanceTargetSelection {
    guard selectedDeviceIDs.count == 1, let selectedDeviceID = selectedDeviceIDs.first else {
      return .guidance(.selectOneDevice)
    }
    let expectedRecordingID: Int64?
    switch source {
    case .current(let runtimeLogicalID):
      expectedRecordingID = recordingRows.first { $0.logicalID == runtimeLogicalID }?.rowID
    case .historical(let recordingID, _):
      expectedRecordingID = recordingID
    }
    guard catalogRecordingID == expectedRecordingID,
      let device = deviceRows.first(where: { $0.logicalID == selectedDeviceID })
    else { return .guidance(.deviceNotReady) }

    do {
      switch source {
      case .current(let runtimeLogicalID):
        guard
          sessions.contains(where: {
            $0.connectionID == selectedDeviceID && $0.state == .active
          }),
          let recording = recordingRows.first(where: { $0.logicalID == runtimeLogicalID }),
          recording.rowID == device.recordingID
        else { return .guidance(.deviceNotReady) }
        let performanceSource = ViewerPerformanceSource.current(
          runtimeLogicalID: runtimeLogicalID,
          connectionID: selectedDeviceID
        )
        return .target(
          try ViewerPerformanceDashboardTarget.current(
            source: performanceSource,
            recordingID: recording.rowID,
            deviceSessionID: device.rowID,
            deviceStartMonotonicNanoseconds: device.startedMonotonicNanoseconds
          )
        )

      case .historical(let recordingID, let recordingLogicalID):
        guard
          let recording = recordingRows.first(where: {
            $0.rowID == recordingID && $0.logicalID == recordingLogicalID
          }), device.recordingID == recordingID
        else { return .guidance(.sourceUnavailable) }
        let performanceSource = try ViewerPerformanceSource.makeHistorical(
          recordingID: recordingID,
          deviceSessionID: device.rowID,
          recordingLogicalID: recordingLogicalID,
          deviceLogicalID: device.logicalID
        )
        let anchor: ViewerPerformanceAnchor
        switch device.state {
        case "closed":
          guard let end = device.endedMonotonicNanoseconds else {
            return .guidance(.sourceUnavailable)
          }
          anchor =
            end == device.startedMonotonicNanoseconds
            ? try .empty(
              deviceStartMonotonicNanoseconds: device.startedMonotonicNanoseconds
            )
            : try .ended(
              deviceStartMonotonicNanoseconds: device.startedMonotonicNanoseconds,
              deviceEndMonotonicNanoseconds: end
            )
        case "recoveredAfterInterruption":
          if device.endedMonotonicNanoseconds == device.startedMonotonicNanoseconds {
            anchor = try .empty(
              deviceStartMonotonicNanoseconds: device.startedMonotonicNanoseconds
            )
          } else {
            guard let upper = recording.endedMonotonicNanoseconds else {
              return .guidance(.sourceUnavailable)
            }
            anchor = try .interrupted(
              deviceStartMonotonicNanoseconds: device.startedMonotonicNanoseconds,
              frozenRecordingUpperMonotonicNanoseconds: upper
            )
          }
        default:
          return .guidance(.sourceUnavailable)
        }
        return .target(try .historical(source: performanceSource, anchor: anchor))
      }
    } catch {
      return .guidance(.sourceUnavailable)
    }
  }
}

struct ViewerAnalysisModeDiagnostics: Equatable, Sendable {
  let transitionRevision: UInt64
  let pendingTransitionCount: Int
  let rawResolutionWorkCount: Int
  let isSealed: Bool
}

@MainActor
struct ViewerAnalysisEventDriver {
  typealias Handler = @MainActor @Sendable () -> Void
  typealias HandlerInstaller = @MainActor @Sendable (@escaping Handler) -> Void
  typealias RematerializationHandler = @MainActor @Sendable (Task<Void, Never>) -> Void
  typealias RematerializationHandlerInstaller =
    @MainActor @Sendable (@escaping RematerializationHandler) -> Void

  let targetSelection: @MainActor @Sendable () -> ViewerPerformanceTargetSelection
  let deactivate: @MainActor @Sendable () -> Task<Void, Never>
  let activate: @MainActor @Sendable () -> Task<Void, Never>
  let reveal: @MainActor @Sendable (ViewerExplorerEventIdentity) -> Void
  let rematerializeStore: @MainActor @Sendable () -> Task<Void, Never>
  let setSelectionHandler: HandlerInstaller
  let setRefreshHandler: HandlerInstaller
  let setRematerializationHandler: RematerializationHandlerInstaller

  init(controller: ViewerEventExplorerController) {
    targetSelection = { [weak controller] in
      controller?.performanceTargetSelection() ?? .guidance(.sourceUnavailable)
    }
    deactivate = { [weak controller] in
      controller?.deactivateForAnalysisSwitch() ?? Task {}
    }
    activate = { [weak controller] in
      controller?.activateAfterAnalysisSwitch() ?? Task {}
    }
    reveal = { [weak controller] identity in
      controller?.revealExactEvent(identity)
    }
    rematerializeStore = { [weak controller] in
      controller?.rematerializeAfterStoreReplacement() ?? Task {}
    }
    setSelectionHandler = { [weak controller] handler in
      controller?.setAnalysisSelectionHandler(handler)
    }
    setRefreshHandler = { [weak controller] handler in
      controller?.setAnalysisRefreshHandler(handler)
    }
    setRematerializationHandler = { [weak controller] handler in
      controller?.setAnalysisRematerializationHandler(handler)
    }
  }

  init(
    targetSelection:
      @escaping @MainActor @Sendable () -> ViewerPerformanceTargetSelection,
    deactivate: @escaping @MainActor @Sendable () -> Task<Void, Never>,
    activate: @escaping @MainActor @Sendable () -> Task<Void, Never>,
    reveal: @escaping @MainActor @Sendable (ViewerExplorerEventIdentity) -> Void,
    rematerializeStore: @escaping @MainActor @Sendable () -> Task<Void, Never> = { Task {} },
    setSelectionHandler: @escaping HandlerInstaller = { _ in },
    setRefreshHandler: @escaping HandlerInstaller = { _ in },
    setRematerializationHandler: @escaping RematerializationHandlerInstaller = { _ in }
  ) {
    self.targetSelection = targetSelection
    self.deactivate = deactivate
    self.activate = activate
    self.reveal = reveal
    self.rematerializeStore = rematerializeStore
    self.setSelectionHandler = setSelectionHandler
    self.setRefreshHandler = setRefreshHandler
    self.setRematerializationHandler = setRematerializationHandler
  }
}

@MainActor
final class ViewerAnalysisModeCoordinator: ObservableObject, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  @Published private(set) var mode: ViewerAnalysisMode = .events
  @Published private(set) var guidance: ViewerAnalysisGuidance?
  @Published private(set) var revision: UInt64 = 0

  let performanceController: ViewerPerformanceDashboardController

  private let event: ViewerAnalysisEventDriver
  private let rawResolver: ViewerPerformanceRawEventResolver
  private let transitionTracker = ViewerAsyncWorkTracker()
  private var rangeKind = ViewerPerformanceRangeKind.defaultKind
  private var transitionRevision: UInt64 = 0
  private var transitionTask: Task<Void, Never>?
  private var sealed = false

  init(
    eventController: ViewerEventExplorerController,
    performanceController: ViewerPerformanceDashboardController,
    rawResolver: ViewerPerformanceRawEventResolver
  ) {
    event = ViewerAnalysisEventDriver(controller: eventController)
    self.performanceController = performanceController
    self.rawResolver = rawResolver
    installEventHandlers()
  }

  init(
    event: ViewerAnalysisEventDriver,
    performanceController: ViewerPerformanceDashboardController,
    rawResolver: ViewerPerformanceRawEventResolver
  ) {
    self.event = event
    self.performanceController = performanceController
    self.rawResolver = rawResolver
    installEventHandlers()
  }

  private func installEventHandlers() {
    event.setSelectionHandler { [weak self] in
      self?.sharedSelectionDidChange()
    }
    event.setRefreshHandler { [weak self] in
      self?.liveRefreshDidArrive()
    }
    event.setRematerializationHandler { [weak self] rematerialization in
      self?.sharedSelectionRematerializationDidStart(rematerialization)
    }
  }

  func showEvents() {
    guard !sealed, mode != .events else { return }
    transitionRevision = Self.increment(transitionRevision)
    let requestedRevision = transitionRevision
    let prior = transitionTask
    let performanceWait = performanceController.deactivateAndWait()
    let resolverWait = rawResolver.cancelActiveAndWait()
    mode = .events
    guidance = nil
    publish()
    transitionTask = trackTransition { [weak self] in
      await prior?.value
      await performanceWait.value
      await resolverWait.value
      guard let self, self.accepts(requestedRevision, mode: .events) else { return }
      await self.event.activate().value
    }
  }

  func showPerformance(rangeKind nextRangeKind: ViewerPerformanceRangeKind? = nil) {
    guard !sealed else { return }
    if let nextRangeKind { rangeKind = nextRangeKind }
    beginPerformanceTransition(clearsCurrentSelection: false)
  }

  func setPerformanceRange(_ nextRangeKind: ViewerPerformanceRangeKind) {
    guard !sealed, nextRangeKind != rangeKind else { return }
    rangeKind = nextRangeKind
    guard mode == .performance else { return }
    beginPerformanceTransition(clearsCurrentSelection: true)
  }

  func setPerformancePaused(_ isPaused: Bool) {
    guard !sealed, mode == .performance,
      performanceController.diagnostics.isPaused != isPaused
    else { return }
    if isPaused {
      performanceController.pause()
    } else {
      performanceController.resume()
    }
    publish()
  }

  func noteStoreChanged() {
    guard !sealed, mode == .performance else { return }
    performanceController.requestRefresh()
  }

  func noteStoreReplaced() {
    guard !sealed else { return }
    transitionRevision = Self.increment(transitionRevision)
    let requestedRevision = transitionRevision
    let expectedMode = mode
    let prior = transitionTask
    let eventRematerializationWait = event.rematerializeStore()
    let performanceWait = performanceController.invalidateStoreGenerationAndWait()
    let resolverWait = rawResolver.cancelActiveAndWait()
    guidance = nil
    publish()
    transitionTask = trackTransition { [weak self] in
      await prior?.value
      await performanceWait.value
      await resolverWait.value
      await eventRematerializationWait.value
      guard let self, self.accepts(requestedRevision, mode: expectedMode) else { return }
      switch expectedMode {
      case .events:
        await self.event.activate().value
      case .performance:
        switch self.event.targetSelection() {
        case .guidance(let guidance):
          self.performanceController.rebuildAfterStoreGenerationReplacement(
            target: nil,
            rangeKind: self.rangeKind
          )
          guard self.accepts(requestedRevision, mode: .performance) else { return }
          self.guidance = guidance
          self.publish()
        case .target(let target):
          self.performanceController.rebuildAfterStoreGenerationReplacement(
            target: target,
            rangeKind: self.rangeKind
          )
          guard self.accepts(requestedRevision, mode: .performance),
            self.event.targetSelection() == .target(target)
          else { return }
          self.performanceController.activate()
          self.guidance = nil
          self.publish()
        }
      }
    }
  }

  func openRawEvent(
    bucketIndex: Int,
    metric: ViewerPerformanceNumericMetric
  ) {
    guard !sealed, mode == .performance,
      let request = performanceController.rawEventRequest(
        bucketIndex: bucketIndex,
        metric: metric
      ),
      let scope = performanceController.model.scope,
      let target = performanceController.currentTarget
    else {
      guidance = .rawEvent(.sourceChanged)
      publish()
      return
    }

    transitionRevision = Self.increment(transitionRevision)
    let requestedRevision = transitionRevision
    let prior = transitionTask
    let performanceWait = performanceController.deactivateAndWait()
    let resolverWait = rawResolver.cancelActiveAndWait()
    guidance = nil
    publish()
    transitionTask = trackTransition { [weak self] in
      await prior?.value
      await performanceWait.value
      await resolverWait.value
      guard let self, self.accepts(requestedRevision, mode: .performance) else { return }
      self.mode = .events
      self.publish()
      await self.resolveAndReveal(
        request: request,
        scope: scope,
        target: target,
        revision: requestedRevision
      )
    }
  }

  func sealAndWait() -> Task<Void, Never> {
    guard !sealed else { return transitionTracker.waitTask() }
    sealed = true
    transitionRevision = Self.increment(transitionRevision)
    event.setSelectionHandler {}
    event.setRefreshHandler {}
    event.setRematerializationHandler { _ in }
    let transitionWait = transitionTask ?? Task {}
    let eventWait = event.deactivate()
    let performanceWait = performanceController.sealAndWait()
    let resolverWait = rawResolver.sealAndWait()
    return Task {
      async let transition: Void = transitionWait.value
      async let event: Void = eventWait.value
      async let performance: Void = performanceWait.value
      async let resolver: Void = resolverWait.value
      _ = await (transition, event, performance, resolver)
    }
  }

  var diagnostics: ViewerAnalysisModeDiagnostics {
    ViewerAnalysisModeDiagnostics(
      transitionRevision: transitionRevision,
      pendingTransitionCount: transitionTracker.activeCount,
      rawResolutionWorkCount: rawResolver.pendingWorkCount,
      isSealed: sealed
    )
  }

  var performanceRangeKind: ViewerPerformanceRangeKind { rangeKind }
  var isPerformancePaused: Bool { performanceController.diagnostics.isPaused }

  nonisolated var description: String { "ViewerAnalysisModeCoordinator(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private func sharedSelectionDidChange() {
    guard !sealed, mode == .performance else { return }
    beginPerformanceTransition(clearsCurrentSelection: true)
  }

  private func sharedSelectionRematerializationDidStart(
    _ rematerialization: Task<Void, Never>
  ) {
    guard !sealed else { return }
    transitionRevision = Self.increment(transitionRevision)
    let requestedRevision = transitionRevision
    let expectedMode = mode
    let prior = transitionTask
    let performanceWait: Task<Void, Never>
    let clearWait: Task<Void, Never>
    switch expectedMode {
    case .events:
      performanceWait = Task {}
      clearWait = Task {}
    case .performance:
      performanceWait = performanceController.deactivateAndWait()
      clearWait = performanceController.replace(target: nil, rangeKind: rangeKind)
    }
    let resolverWait = rawResolver.cancelActiveAndWait()
    guidance = nil
    publish()
    transitionTask = trackTransition { [weak self] in
      await prior?.value
      await performanceWait.value
      await clearWait.value
      await resolverWait.value
      await rematerialization.value
      guard let self, self.accepts(requestedRevision, mode: expectedMode) else { return }
      switch expectedMode {
      case .events:
        await self.event.activate().value
      case .performance:
        switch self.event.targetSelection() {
        case .guidance(let guidance):
          await self.performanceController.replace(
            target: nil,
            rangeKind: self.rangeKind
          ).value
          guard self.accepts(requestedRevision, mode: .performance) else { return }
          self.guidance = guidance
          self.publish()
        case .target(let target):
          await self.performanceController.replace(
            target: target,
            rangeKind: self.rangeKind
          ).value
          guard self.accepts(requestedRevision, mode: .performance),
            self.event.targetSelection() == .target(target)
          else { return }
          self.performanceController.activate()
          self.guidance = nil
          self.publish()
        }
      }
    }
  }

  private func liveRefreshDidArrive() {
    guard !sealed, mode == .performance else { return }
    performanceController.requestRefresh()
  }

  private func beginPerformanceTransition(clearsCurrentSelection: Bool) {
    transitionRevision = Self.increment(transitionRevision)
    let requestedRevision = transitionRevision
    let prior = transitionTask
    let resolverWait = rawResolver.cancelActiveAndWait()
    let ownerWait: Task<Void, Never>
    let clearWait: Task<Void, Never>
    if mode == .events {
      ownerWait = event.deactivate()
      clearWait = Task {}
    } else {
      ownerWait = performanceController.deactivateAndWait()
      clearWait =
        clearsCurrentSelection
        ? performanceController.replace(target: nil, rangeKind: rangeKind) : Task {}
    }
    mode = .performance
    guidance = nil
    publish()

    transitionTask = trackTransition { [weak self] in
      await prior?.value
      await ownerWait.value
      await clearWait.value
      await resolverWait.value
      guard let self, self.accepts(requestedRevision, mode: .performance) else { return }
      switch self.event.targetSelection() {
      case .guidance(let guidance):
        await self.performanceController.replace(
          target: nil,
          rangeKind: self.rangeKind
        ).value
        guard self.accepts(requestedRevision, mode: .performance) else { return }
        self.guidance = guidance
        self.publish()
      case .target(let target):
        await self.performanceController.replace(
          target: target,
          rangeKind: self.rangeKind
        ).value
        guard self.accepts(requestedRevision, mode: .performance),
          self.event.targetSelection() == .target(target)
        else { return }
        self.performanceController.activate()
        self.guidance = nil
        self.publish()
      }
    }
  }

  private func resolveAndReveal(
    request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget,
    revision requestedRevision: UInt64
  ) async {
    guard event.targetSelection() == .target(target) else {
      await activateEvents(with: .rawEvent(.sourceChanged), revision: requestedRevision)
      return
    }
    let outcome = await resolve(request: request, scope: scope, target: target)
    guard accepts(requestedRevision, mode: .events) else { return }
    switch outcome {
    case .resolved(let resolved):
      switch rawResolver.revalidate(
        resolved,
        request: request,
        scope: scope,
        target: target
      ) {
      case .explorerIdentity(let identity):
        await reveal(
          identity,
          resolved: resolved,
          request: request,
          scope: scope,
          target: target,
          revision: requestedRevision
        )
      case .requiresResolution:
        await activateEvents(
          with: .rawEvent(.eventNoLongerAvailable),
          revision: requestedRevision
        )
      case .guidance(let guidance):
        await activateEvents(with: .rawEvent(guidance), revision: requestedRevision)
      }
    case .guidance(let guidance):
      await activateEvents(with: .rawEvent(guidance), revision: requestedRevision)
    case .failed:
      await activateEvents(with: .rawEventResolutionFailed, revision: requestedRevision)
    case .cancelled:
      break
    }
  }

  private func reveal(
    _ identity: ViewerExplorerEventIdentity,
    resolved: ViewerPerformanceResolvedRawEvent,
    request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget,
    revision requestedRevision: UInt64
  ) async {
    await event.activate().value
    guard accepts(requestedRevision, mode: .events),
      event.targetSelection() == .target(target)
    else { return }
    switch rawResolver.revalidate(
      resolved,
      request: request,
      scope: scope,
      target: target
    ) {
    case .explorerIdentity(let currentIdentity):
      guard currentIdentity == identity else { return }
      event.reveal(currentIdentity)
      guidance = nil
      publish()
    case .requiresResolution:
      await retryRevealAfterTransientRace(
        request: request,
        scope: scope,
        target: target,
        revision: requestedRevision
      )
    case .guidance(let guidance):
      self.guidance = .rawEvent(guidance)
      publish()
    }
  }

  private func retryRevealAfterTransientRace(
    request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget,
    revision requestedRevision: UInt64
  ) async {
    await event.deactivate().value
    guard accepts(requestedRevision, mode: .events) else { return }
    let outcome = await resolve(request: request, scope: scope, target: target)
    guard accepts(requestedRevision, mode: .events) else { return }
    let identity: ViewerExplorerEventIdentity?
    switch outcome {
    case .resolved(let resolved):
      if case .explorerIdentity(let value) = rawResolver.revalidate(
        resolved,
        request: request,
        scope: scope,
        target: target
      ) {
        identity = value
      } else {
        identity = nil
      }
    default:
      identity = nil
    }
    await event.activate().value
    guard accepts(requestedRevision, mode: .events) else { return }
    if let identity {
      event.reveal(identity)
      guidance = nil
    } else {
      guidance = .rawEvent(.eventNoLongerAvailable)
    }
    publish()
  }

  private func activateEvents(
    with nextGuidance: ViewerAnalysisGuidance,
    revision requestedRevision: UInt64
  ) async {
    await event.activate().value
    guard accepts(requestedRevision, mode: .events) else { return }
    guidance = nextGuidance
    publish()
  }

  private func resolve(
    request: ViewerPerformanceRawEventRequest,
    scope: ViewerPerformanceDashboardScope,
    target: ViewerPerformanceDashboardTarget
  ) async -> ViewerPerformanceRawEventResolutionOutcome {
    await withCheckedContinuation { continuation in
      _ = rawResolver.resolve(request, scope: scope, target: target) { outcome in
        continuation.resume(returning: outcome)
      }
    }
  }

  private func trackTransition(
    _ operation: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never> {
    let workID = transitionTracker.begin()
    return Task { [transitionTracker] in
      await operation()
      transitionTracker.complete(workID)
    }
  }

  private func accepts(_ requestedRevision: UInt64, mode expectedMode: ViewerAnalysisMode) -> Bool {
    !sealed && transitionRevision == requestedRevision && mode == expectedMode
  }

  private func publish() {
    revision = Self.increment(revision)
  }

  private static func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? 1 : value + 1
  }
}

extension ViewerAnalysisModeDiagnostics: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerAnalysisModeDiagnostics(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
