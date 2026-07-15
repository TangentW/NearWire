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

  var isExactTarget: Bool {
    if case .target = self { return true }
    return false
  }
}

struct ViewerAnalysisModeDiagnostics: Equatable, Sendable {
  let transitionRevision: UInt64
  let pendingTransitionCount: Int
  let rawResolutionWorkCount: Int
  let isSealed: Bool
}

struct ViewerPerformanceDeviceOption: Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let subtitle: String
  let state: String
  let isEligible: Bool
}

@MainActor
struct ViewerAnalysisEventDriver {
  typealias Handler = @MainActor @Sendable () -> Void
  typealias HandlerInstaller = @MainActor @Sendable (@escaping Handler) -> Void

  let targetSelection: @MainActor @Sendable (UUID?) -> ViewerPerformanceTargetSelection
  let performanceDevices: @MainActor @Sendable () -> [ViewerPerformanceDeviceOption]
  let selectedEventDeviceIDs: @MainActor @Sendable () -> Set<UUID>
  let usesIndependentPerformanceDeviceSelection: Bool
  let deactivate: @MainActor @Sendable () -> Task<Void, Never>
  let activate: @MainActor @Sendable () -> Task<Void, Never>
  let prepareExactReveal: @MainActor @Sendable () -> Task<Bool, Never>
  let acceptExactReveal:
    @MainActor @Sendable (ViewerExplorerEventIdentity) async -> Bool
  let cancelExactReveal: @MainActor @Sendable () -> Task<Void, Never>
  let setSelectionHandler: HandlerInstaller
  let setRefreshHandler: HandlerInstaller

  init(controller: ViewerEventExplorerController) {
    targetSelection = { [weak controller] deviceID in
      controller?.performanceTargetSelection(deviceID: deviceID)
        ?? .guidance(.sourceUnavailable)
    }
    performanceDevices = { [weak controller] in
      controller?.deviceRows.map {
        let selection = controller?.performanceTargetSelection(deviceID: $0.id)
        return ViewerPerformanceDeviceOption(
          id: $0.id,
          title: $0.title,
          subtitle: $0.subtitle,
          state: $0.state,
          isEligible: selection?.isExactTarget == true
        )
      } ?? []
    }
    selectedEventDeviceIDs = { [weak controller] in
      controller?.selectedDeviceIDs ?? []
    }
    usesIndependentPerformanceDeviceSelection = true
    deactivate = { [weak controller] in
      controller?.deactivateForAnalysisSwitch() ?? Task {}
    }
    activate = { [weak controller] in
      controller?.activateAfterAnalysisSwitch() ?? Task {}
    }
    prepareExactReveal = { [weak controller] in
      controller?.refreshTraversalForExactReveal() ?? Task { false }
    }
    acceptExactReveal = { [weak controller] identity in
      guard let controller else { return false }
      return await controller.acceptExactReveal(identity)
    }
    cancelExactReveal = { [weak controller] in
      controller?.cancelExactRevealAndWait() ?? Task {}
    }
    setSelectionHandler = { [weak controller] handler in
      controller?.setAnalysisSelectionHandler(handler)
    }
    setRefreshHandler = { [weak controller] handler in
      controller?.setAnalysisRefreshHandler(handler)
    }
  }

  init(
    targetSelection:
      @escaping @MainActor @Sendable () -> ViewerPerformanceTargetSelection,
    targetSelectionForDevice:
      (@MainActor @Sendable (UUID?) -> ViewerPerformanceTargetSelection)? = nil,
    performanceDevices:
      @escaping @MainActor @Sendable () -> [ViewerPerformanceDeviceOption] = { [] },
    selectedEventDeviceIDs:
      @escaping @MainActor @Sendable () -> Set<UUID> = { [] },
    usesIndependentPerformanceDeviceSelection: Bool = false,
    deactivate: @escaping @MainActor @Sendable () -> Task<Void, Never>,
    activate: @escaping @MainActor @Sendable () -> Task<Void, Never>,
    prepareExactReveal: @escaping @MainActor @Sendable () -> Task<Bool, Never> = { Task { true } },
    reveal: @escaping @MainActor @Sendable (ViewerExplorerEventIdentity) -> Bool,
    acceptExactReveal:
      (@MainActor @Sendable (ViewerExplorerEventIdentity) async -> Bool)? = nil,
    cancelExactReveal: @escaping @MainActor @Sendable () -> Task<Void, Never> = { Task {} },
    setSelectionHandler: @escaping HandlerInstaller = { _ in },
    setRefreshHandler: @escaping HandlerInstaller = { _ in }
  ) {
    self.targetSelection = targetSelectionForDevice ?? { _ in targetSelection() }
    self.performanceDevices = performanceDevices
    self.selectedEventDeviceIDs = selectedEventDeviceIDs
    self.usesIndependentPerformanceDeviceSelection = usesIndependentPerformanceDeviceSelection
    self.deactivate = deactivate
    self.activate = activate
    self.prepareExactReveal = prepareExactReveal
    self.acceptExactReveal =
      acceptExactReveal ?? { identity in reveal(identity) }
    self.cancelExactReveal = cancelExactReveal
    self.setSelectionHandler = setSelectionHandler
    self.setRefreshHandler = setRefreshHandler
  }
}

@MainActor
final class ViewerAnalysisModeCoordinator: ObservableObject, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  @Published private(set) var mode: ViewerAnalysisMode = .events
  @Published private(set) var guidance: ViewerAnalysisGuidance?
  @Published private(set) var revision: UInt64 = 0
  @Published private(set) var performanceDeviceID: UUID?
  @Published private(set) var eventRevealRevision: UInt64 = 0
  private(set) var performanceDeviceOptions: [ViewerPerformanceDeviceOption] = []

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
    performanceDeviceOptions = event.performanceDevices()
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
    performanceDeviceOptions = event.performanceDevices()
    installEventHandlers()
  }

  private func installEventHandlers() {
    event.setSelectionHandler { [weak self] in
      self?.sharedSelectionDidChange()
    }
    event.setRefreshHandler { [weak self] in
      self?.liveRefreshDidArrive()
    }
  }

  func showEvents() {
    guard !sealed, mode != .events else { return }
    transitionRevision = Self.increment(transitionRevision)
    let prior = transitionTask
    let performanceWait = performanceController.deactivateAndWait()
    performanceController.resetPauseForWindowClose()
    let clearWait = performanceController.replace(target: nil, rangeKind: rangeKind)
    let resolverWait = rawResolver.cancelActiveAndWait()
    let exactRevealWait = event.cancelExactReveal()
    mode = .events
    guidance = nil
    publish()
    transitionTask = trackTransition {
      await prior?.value
      await performanceWait.value
      await clearWait.value
      await resolverWait.value
      await exactRevealWait.value
    }
  }

  func showPerformance(rangeKind nextRangeKind: ViewerPerformanceRangeKind? = nil) {
    guard !sealed else { return }
    let rangeChanged = nextRangeKind.map { $0 != rangeKind } ?? false
    if let nextRangeKind { rangeKind = nextRangeKind }
    refreshPerformanceDeviceOptions()
    let nextDeviceID = reconciledPerformanceDeviceID()
    let deviceChanged = performanceDeviceID != nextDeviceID
    if deviceChanged { performanceDeviceID = nextDeviceID }
    guard mode != .performance || rangeChanged || deviceChanged else { return }
    beginPerformanceTransition(clearsCurrentSelection: false)
  }

  func setPerformanceDevice(_ deviceID: UUID?) {
    guard !sealed else { return }
    refreshPerformanceDeviceOptions()
    let availableIDs = Set(performanceDeviceOptions.filter(\.isEligible).map(\.id))
    let acceptedID = deviceID.flatMap { availableIDs.contains($0) ? $0 : nil }
    guard acceptedID != performanceDeviceID else { return }
    performanceDeviceID = acceptedID
    guard mode == .performance else {
      publish()
      return
    }
    beginPerformanceTransition(clearsCurrentSelection: true)
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
    let performanceWait = performanceController.suspendForRawRevealAndWait()
    let resolverWait = rawResolver.cancelActiveAndWait()
    let exactRevealWait = event.cancelExactReveal()
    guidance = nil
    publish()
    transitionTask = trackTransition { [weak self] in
      await prior?.value
      await performanceWait.value
      await resolverWait.value
      await exactRevealWait.value
      guard let self, self.accepts(requestedRevision, mode: .performance) else { return }
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
    let transitionWait = transitionTask ?? Task {}
    let eventWait = event.deactivate()
    let exactRevealWait = event.cancelExactReveal()
    let performanceWait = performanceController.sealAndWait()
    let resolverWait = rawResolver.sealAndClear()
    return Task {
      async let transition: Void = transitionWait.value
      async let event: Void = eventWait.value
      async let exactReveal: Void = exactRevealWait.value
      async let performance: Void = performanceWait.value
      async let resolver: Void = resolverWait.value
      _ = await (transition, event, exactReveal, performance, resolver)
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
    let optionsChanged = refreshPerformanceDeviceOptions()
    let nextDeviceID = reconciledPerformanceDeviceID()
    let deviceChanged = performanceDeviceID != nextDeviceID
    if deviceChanged { performanceDeviceID = nextDeviceID }
    if case .target(let target) = currentPerformanceTargetSelection(),
      performanceController.currentTarget == target
    {
      if optionsChanged || deviceChanged { publish() }
      return
    }
    beginPerformanceTransition(clearsCurrentSelection: true)
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
    let exactRevealWait = event.cancelExactReveal()
    let ownerWait: Task<Void, Never>
    let clearWait: Task<Void, Never>
    if mode == .events {
      ownerWait = Task {}
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
      await exactRevealWait.value
      guard let self, self.accepts(requestedRevision, mode: .performance) else { return }
      switch self.currentPerformanceTargetSelection() {
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
          self.currentPerformanceTargetSelection() == .target(target)
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
    guard currentPerformanceTargetSelection() == .target(target) else {
      finishRawReveal(
        guidance: .rawEvent(.sourceChanged),
        target: target,
        revision: requestedRevision
      )
      return
    }
    var outcome = await resolve(request: request, scope: scope, target: target)
    guard accepts(requestedRevision, mode: .performance) else { return }
    if case .resolved(let resolved) = outcome,
      rawResolver.revalidate(
        resolved,
        request: request,
        scope: scope,
        target: target
      ) == .requiresResolution
    {
      outcome = await resolve(request: request, scope: scope, target: target)
      guard accepts(requestedRevision, mode: .performance) else { return }
    }

    if case .resolved = outcome {
      guard await event.prepareExactReveal().value else {
        finishRawReveal(
          guidance: .rawEventResolutionFailed,
          target: target,
          revision: requestedRevision
        )
        return
      }
      guard accepts(requestedRevision, mode: .performance),
        currentPerformanceTargetSelection() == .target(target)
      else { return }
      if case .resolved(let refreshed) = outcome,
        rawResolver.revalidate(
          refreshed,
          request: request,
          scope: scope,
          target: target
        ) == .requiresResolution
      {
        outcome = await resolve(request: request, scope: scope, target: target)
        guard accepts(requestedRevision, mode: .performance) else { return }
      }
    }

    let resolvedIdentity: ViewerExplorerEventIdentity?
    let resolvedGuidance: ViewerAnalysisGuidance?
    switch outcome {
    case .resolved(let resolved):
      switch rawResolver.revalidate(
        resolved,
        request: request,
        scope: scope,
        target: target
      ) {
      case .explorerIdentity(let identity):
        resolvedIdentity = identity
        resolvedGuidance = nil
      case .requiresResolution:
        resolvedIdentity = nil
        resolvedGuidance = .rawEvent(.eventNoLongerAvailable)
      case .guidance(let guidance):
        resolvedIdentity = nil
        resolvedGuidance = .rawEvent(guidance)
      }
    case .guidance(let guidance):
      resolvedIdentity = nil
      resolvedGuidance = .rawEvent(guidance)
    case .failed:
      resolvedIdentity = nil
      resolvedGuidance = .rawEventResolutionFailed
    case .cancelled:
      return
    }

    guard currentPerformanceTargetSelection() == .target(target) else {
      finishRawReveal(
        guidance: .rawEvent(.sourceChanged),
        target: target,
        revision: requestedRevision
      )
      return
    }
    if let identity = resolvedIdentity {
      let accepted = await event.acceptExactReveal(identity)
      guard accepts(requestedRevision, mode: .performance),
        currentPerformanceTargetSelection() == .target(target)
      else { return }
      if accepted {
        eventRevealRevision = Self.increment(eventRevealRevision)
        finishRawReveal(guidance: nil, target: target, revision: requestedRevision)
      } else {
        finishRawReveal(
          guidance: .rawEvent(.eventNoLongerAvailable),
          target: target,
          revision: requestedRevision
        )
      }
    } else {
      finishRawReveal(
        guidance: resolvedGuidance ?? .rawEventResolutionFailed,
        target: target,
        revision: requestedRevision
      )
    }
  }

  private func finishRawReveal(
    guidance nextGuidance: ViewerAnalysisGuidance?,
    target: ViewerPerformanceDashboardTarget,
    revision requestedRevision: UInt64
  ) {
    guard accepts(requestedRevision, mode: .performance) else { return }
    guidance = nextGuidance
    performanceController.resumeAfterRawReveal()
    if currentPerformanceTargetSelection() == .target(target) {
      performanceController.activate()
    }
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

  private func currentPerformanceTargetSelection() -> ViewerPerformanceTargetSelection {
    if event.usesIndependentPerformanceDeviceSelection {
      guard let performanceDeviceID else { return .guidance(.selectOneDevice) }
      return event.targetSelection(performanceDeviceID)
    }
    return event.targetSelection(nil)
  }

  private func reconciledPerformanceDeviceID() -> UUID? {
    guard event.usesIndependentPerformanceDeviceSelection else { return performanceDeviceID }
    let options = performanceDeviceOptions.filter(\.isEligible)
    let availableIDs = Set(options.map(\.id))
    if let performanceDeviceID, availableIDs.contains(performanceDeviceID) {
      return performanceDeviceID
    }
    let eventSelection = event.selectedEventDeviceIDs()
    if eventSelection.count == 1, let selected = eventSelection.first,
      availableIDs.contains(selected)
    {
      return selected
    }
    return options.count == 1 ? options[0].id : nil
  }

  @discardableResult
  private func refreshPerformanceDeviceOptions() -> Bool {
    let next = event.performanceDevices()
    guard next != performanceDeviceOptions else { return false }
    performanceDeviceOptions = next
    return true
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
