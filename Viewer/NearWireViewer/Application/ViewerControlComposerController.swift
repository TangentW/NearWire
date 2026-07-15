import Foundation
@_spi(NearWireInternal) import NearWireCore

struct ViewerControlTargetPresentationRow: Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let subtitle: String
}

struct ViewerControlResultPresentationRow: Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let statusText: String
  let outcome: ViewerControlTargetOutcome
}

enum ViewerComposerPresentationFailure: Equatable, Sendable {
  case noTargets
  case invalidEventType
  case invalidContent
  case invalidTTL
  case encodedSizeRejected
  case targetsChanged

  var message: String {
    switch self {
    case .noTargets: return "Select at least one active App."
    case .invalidEventType:
      return "Enter a valid user Event type. Reserved nearwire.* types are unavailable here."
    case .invalidContent: return "Enter ordinary JSON within the active content limits."
    case .invalidTTL: return "TTL must contain 1–9 ASCII digits within the active limit."
    case .encodedSizeRejected: return "The prepared Event exceeds the supported encoded size."
    case .targetsChanged: return "The selected Apps changed before local queue admission."
    }
  }
}

enum ViewerComposerPresentationState: Equatable, Sendable {
  case idle
  case preparing
  case completed
  case failed(ViewerComposerPresentationFailure)
}

@MainActor
final class ViewerControlComposerController: ObservableObject, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private struct Attempt {
    typealias Target = (
      row: ViewerControlTargetPresentationRow,
      capability: ViewerControlTargetCapability
    )

    let id: UUID
    let targets: [Target]
  }

  private struct PreparationDelivery {
    let id: UUID
    let deliveryGate: ViewerOperationDeliveryGate
  }

  private struct PreparationDeliveryValue: Sendable {
    let id: UUID
    let attemptID: UUID
    let result: ViewerComposerPreparationResult
  }

  @Published private(set) var revision: UInt64 = 0
  private(set) var targetRows: [ViewerControlTargetPresentationRow] = []
  private(set) var selectedTargetIDs: Set<UUID> = []
  private(set) var resultRows: [ViewerControlResultPresentationRow] = []
  private(set) var state: ViewerComposerPresentationState = .idle
  private(set) var inputValidationMessage: String?

  let model: ViewerControlComposerModel

  private let sessionControl: any ViewerSessionControlling
  private let preparationService: ViewerComposerPreparationService
  private let preparationDeliveryClaimed: @Sendable () -> Void
  private var targetsByConnectionID: [UUID: ViewerControlTarget] = [:]
  private var activeAttempt: Attempt?
  private var preparationDelivery: PreparationDelivery?
  private var sealed = false
  private var cleanupTask: Task<Void, Never>?
  private lazy var preparationDeliveryPump = ViewerLatestMainActorDeliveryPump<
    PreparationDeliveryValue
  > { [weak self] delivery in
    guard let self, self.finishPreparationDelivery(id: delivery.id) else { return }
    self.handlePreparation(delivery.result, attemptID: delivery.attemptID)
  }

  init(
    runtimeLogicalID: UUID,
    sessionControl: any ViewerSessionControlling,
    activeLimits: EventValidationLimits = .default,
    preparationService: ViewerComposerPreparationService = ViewerComposerPreparationService(),
    preparationDeliveryClaimed: @escaping @Sendable () -> Void = {}
  ) throws {
    guard sessionControl.runtimeLogicalID == runtimeLogicalID else {
      throw ViewerControlSendError.invalidTargetCount
    }
    model = try ViewerControlComposerModel(
      runtimeLogicalID: runtimeLogicalID,
      activeLimits: activeLimits
    )
    self.sessionControl = sessionControl
    self.preparationService = preparationService
    self.preparationDeliveryClaimed = preparationDeliveryClaimed
  }

  var eventType: String { model.eventType.value }
  var contentJSON: String { model.content.value }
  var ttlText: String { model.ttl.value }
  var priority: EventPriority { model.priority }
  var policy: ViewerControlDraftPolicy { model.policy }
  var selectedTargetCount: Int { selectedTargetIDs.count }
  var maximumContentBytes: Int { model.textLimits.contentBytes }
  var maximumTTLMilliseconds: UInt64 { model.activeLimits.maximumTTLMilliseconds }
  var canSend: Bool { !sealed && !selectedTargetIDs.isEmpty && state != .preparing }

  func updateSessionSnapshots(_ snapshots: [ViewerSessionSnapshot]) {
    guard !sealed else { return }
    let previousRows = targetRows
    let previousSelection = selectedTargetIDs
    let oldSelectedCapabilities = selectedCapabilities()
    let activeSnapshots = Dictionary(
      uniqueKeysWithValues: snapshots.compactMap { snapshot -> (UUID, ViewerSessionSnapshot)? in
        guard snapshot.state == .active, let connectionID = snapshot.connectionID else {
          return nil
        }
        return (connectionID, snapshot)
      }
    )
    let targets = sessionControl.controlTargets().filter { activeSnapshots[$0.connectionID] != nil }
    targetsByConnectionID = Dictionary(uniqueKeysWithValues: targets.map { ($0.connectionID, $0) })
    targetRows = targets.compactMap { target in
      guard let snapshot = activeSnapshots[target.connectionID] else { return nil }
      return ViewerControlTargetPresentationRow(
        id: target.connectionID,
        title: snapshot.title,
        subtitle: snapshot.installationAlias
      )
    }.sorted {
      $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title < $1.title
    }
    selectedTargetIDs.formIntersection(Set(targetRows.map(\.id)))
    let capabilitiesChanged = oldSelectedCapabilities != selectedCapabilities()
    if capabilitiesChanged { invalidateAttempt() }
    guard previousRows != targetRows || previousSelection != selectedTargetIDs
      || capabilitiesChanged
    else { return }
    publish()
  }

  func toggleTarget(_ connectionID: UUID) {
    guard !sealed, targetsByConnectionID[connectionID] != nil else { return }
    if selectedTargetIDs.contains(connectionID) {
      selectedTargetIDs.remove(connectionID)
    } else {
      guard selectedTargetIDs.count < ViewerMultiDeviceSessionManager.maximumSessions else {
        return
      }
      selectedTargetIDs.insert(connectionID)
    }
    invalidateAttempt()
    publish()
  }

  func selectAllTargets() {
    guard !sealed else { return }
    selectedTargetIDs = Set(
      targetRows.prefix(ViewerMultiDeviceSessionManager.maximumSessions).map(\.id))
    invalidateAttempt()
    publish()
  }

  func clearTargetSelection() {
    guard !sealed, !selectedTargetIDs.isEmpty else { return }
    selectedTargetIDs.removeAll(keepingCapacity: false)
    invalidateAttempt()
    publish()
  }

  @discardableResult
  func replaceWhole(_ field: ViewerComposerField, with value: String) -> Bool {
    guard !sealed else { return false }
    let length: Int
    switch field {
    case .eventType: length = model.eventType.utf16Count
    case .content: length = model.content.utf16Count
    case .ttl: length = model.ttl.utf16Count
    }
    return replaceCharacters(
      field,
      range: NSRange(location: 0, length: length),
      replacement: value
    )
  }

  @discardableResult
  func replaceCharacters(
    _ field: ViewerComposerField,
    range: NSRange,
    replacement: String
  ) -> Bool {
    guard !sealed else { return false }
    let result = model.replaceCharacters(field: field, range: range, replacement: replacement)
    switch result {
    case .applied:
      inputValidationMessage = nil
      invalidateAttempt()
      publish()
      return true
    case .rejected:
      inputValidationMessage = "The replacement exceeds this field's active limit."
      publish()
      return false
    }
  }

  func setPriority(_ priority: EventPriority) {
    guard !sealed, model.priority != priority else { return }
    model.setPriority(priority)
    invalidateAttempt()
    publish()
  }

  func setPolicy(_ policy: ViewerControlDraftPolicy) {
    guard !sealed, model.policy != policy else { return }
    model.setPolicy(policy)
    invalidateAttempt()
    publish()
  }

  func send() {
    guard !sealed else { return }
    let selected = targetRows.compactMap { row -> Attempt.Target? in
      guard selectedTargetIDs.contains(row.id), let target = targetsByConnectionID[row.id] else {
        return nil
      }
      return (row, target.capability)
    }
    guard (1...ViewerMultiDeviceSessionManager.maximumSessions).contains(selected.count) else {
      state = .failed(.noTargets)
      publish()
      return
    }
    invalidateAttempt()
    resultRows.removeAll(keepingCapacity: false)
    inputValidationMessage = nil
    state = .preparing
    let attempt = Attempt(id: UUID(), targets: selected)
    activeAttempt = attempt
    let request = model.makePreparationRequest()
    let deliveryID = UUID()
    let deliveryGate = ViewerOperationDeliveryGate()
    preparationDelivery = PreparationDelivery(id: deliveryID, deliveryGate: deliveryGate)
    let deliveryPump = preparationDeliveryPump
    let deliveryClaimed = preparationDeliveryClaimed
    preparationService.submit(request) { result in
      guard deliveryGate.claimDelivery() else { return }
      guard
        deliveryPump.submit(
          PreparationDeliveryValue(id: deliveryID, attemptID: attempt.id, result: result)
        )
      else { return }
      deliveryClaimed()
    }
    publish()
  }

  func clearDraft() {
    guard !sealed else { return }
    invalidateAttempt()
    model.clear()
    resultRows.removeAll(keepingCapacity: false)
    inputValidationMessage = nil
    state = .idle
    publish()
  }

  @discardableResult
  func sealAndClear() -> Task<Void, Never> {
    if let cleanupTask { return cleanupTask }
    sealed = true
    cancelPreparationDelivery()
    let preparationCleanup = preparationService.cancelAndWait()
    let deliveryCleanup = preparationDeliveryPump.sealAndWait()
    activeAttempt = nil
    model.clear()
    targetRows.removeAll(keepingCapacity: false)
    targetsByConnectionID.removeAll(keepingCapacity: false)
    selectedTargetIDs.removeAll(keepingCapacity: false)
    resultRows.removeAll(keepingCapacity: false)
    inputValidationMessage = nil
    state = .idle
    publish()
    let cleanup = Task { [self] in
      async let preparation: Void = preparationCleanup.value
      async let delivery: Void = deliveryCleanup.value
      _ = await (preparation, delivery)
      _ = revision
    }
    cleanupTask = cleanup
    return cleanup
  }

  var pendingCleanupWorkCount: Int {
    preparationService.pendingWorkCount + preparationDeliveryPump.pendingWorkCount
  }

  var preparationDeliveryRetainedResultCountForTesting: Int {
    preparationDeliveryPump.retainedValueCountForTesting
  }

  var preparationDeliveryMaximumRetainedResultCountForTesting: Int {
    preparationDeliveryPump.maximumRetainedValueCount
  }

  nonisolated var description: String { "ViewerControlComposerController(redacted)" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .class)
  }

  private func handlePreparation(
    _ result: ViewerComposerPreparationResult,
    attemptID: UUID
  ) {
    guard !sealed, let attempt = activeAttempt, attempt.id == attemptID,
      model.apply(result)
    else { return }
    switch result.outcome {
    case .success(let prepared, _):
      do {
        let outcomes = try sessionControl.send(
          prepared,
          to: attempt.targets.map(\.capability)
        )
        guard outcomes.count == attempt.targets.count,
          outcomes.enumerated().allSatisfy({ $0.offset == $0.element.inputIndex })
        else {
          state = .failed(.targetsChanged)
          activeAttempt = nil
          publish()
          return
        }
        resultRows = zip(attempt.targets, outcomes).map { target, outcome in
          ViewerControlResultPresentationRow(
            id: target.row.id,
            title: target.row.title,
            statusText: outcome.statusText,
            outcome: outcome.outcome
          )
        }
        state = .completed
      } catch {
        state = .failed(.targetsChanged)
      }
    case .failure(let failure, _):
      switch failure {
      case .cancelled:
        return
      case .invalidEventType:
        state = .failed(.invalidEventType)
      case .invalidContent:
        state = .failed(.invalidContent)
      case .invalidTTL:
        state = .failed(.invalidTTL)
      case .encodedSizeRejected:
        state = .failed(.encodedSizeRejected)
      }
    }
    activeAttempt = nil
    publish()
  }

  private func selectedCapabilities() -> [ViewerControlTargetCapability] {
    selectedTargetIDs.sorted { $0.uuidString < $1.uuidString }.compactMap {
      targetsByConnectionID[$0]?.capability
    }
  }

  private func invalidateAttempt() {
    cancelPreparationDelivery()
    preparationService.cancel()
    activeAttempt = nil
    if state == .preparing { state = .idle }
  }

  @discardableResult
  private func finishPreparationDelivery(id: UUID) -> Bool {
    let isCurrent = preparationDelivery?.id == id
    if isCurrent { preparationDelivery = nil }
    return isCurrent
  }

  private func cancelPreparationDelivery() {
    if let delivery = preparationDelivery {
      preparationDelivery = nil
      _ = delivery.deliveryGate.cancel()
    }
    preparationDeliveryPump.cancelPending()
  }

  private func publish() {
    revision = revision == UInt64.max ? 1 : revision + 1
  }
}

extension ViewerControlTargetPresentationRow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerControlTargetPresentationRow(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerControlResultPresentationRow: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerControlResultPresentationRow(outcome: \(outcome.rawValue))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["outcome": outcome.rawValue], displayStyle: .struct)
  }
}

extension ViewerComposerPresentationState: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerComposerPresentationState(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}
