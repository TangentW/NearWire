import Foundation

#if SWIFT_PACKAGE
  import NearWire
#endif

enum NearWireUIOperationPhase: Equatable, Sendable {
  case idle
  case connecting
  case cancelling
  case disconnecting
}

struct NearWireUIActionError: Equatable, Sendable {
  static let generic = NearWireUIActionError(
    message: "NearWire could not complete the connection action.",
    offersReset: false
  )

  let message: String
  let offersReset: Bool
}

enum NearWireUIConnectOutcome: Equatable, Sendable {
  case success
  case cancelled
  case failure(NearWireUIActionError)
}

final class NearWireUIOperationToken: Hashable, @unchecked Sendable {
  static func == (lhs: NearWireUIOperationToken, rhs: NearWireUIOperationToken) -> Bool {
    lhs === rhs
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

final class NearWireUIPhaseRegistrationToken: Hashable, @unchecked Sendable {
  static func == (
    lhs: NearWireUIPhaseRegistrationToken,
    rhs: NearWireUIPhaseRegistrationToken
  ) -> Bool {
    lhs === rhs
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

struct NearWireUIPhaseRegistration {
  let initialPhase: NearWireUIOperationPhase
  let stream: AsyncStream<NearWireUIOperationPhase>
  let token: NearWireUIPhaseRegistrationToken
}

@MainActor
final class NearWireUIOperationCoordinator {
  static let shared = NearWireUIOperationCoordinator()

  typealias DeliveryHook = @Sendable (NearWireUIOperationPhase) -> Void

  typealias OriginCompletion =
    @MainActor @Sendable (
      NearWireUIOperationToken,
      NearWireUIConnectOutcome
    ) -> Void

  private final class ConnectOperation: @unchecked Sendable {
    let token: NearWireUIOperationToken
    let task: Task<Void, Never>
    var originCompletion: OriginCompletion?

    init(
      token: NearWireUIOperationToken,
      task: Task<Void, Never>,
      originCompletion: OriginCompletion?
    ) {
      self.token = token
      self.task = task
      self.originCompletion = originCompletion
    }
  }

  private final class DisconnectOperation: @unchecked Sendable {
    let token: NearWireUIOperationToken
    let task: Task<Void, Never>

    init(token: NearWireUIOperationToken, task: Task<Void, Never>) {
      self.token = token
      self.task = task
    }
  }

  private final class Entry: @unchecked Sendable {
    var phase: NearWireUIOperationPhase = .idle
    var phaseRevision: UInt64 = 0
    var subscribers:
      [NearWireUIPhaseRegistrationToken: AsyncStream<NearWireUIOperationPhase>.Continuation] = [:]
    var connect: ConnectOperation?
    var disconnect: DisconnectOperation?
  }

  private final class Storage: @unchecked Sendable {
    struct PhaseDelivery {
      let key: ObjectIdentifier
      let entry: Entry
    }

    struct ReleaseEffect {
      let continuation: AsyncStream<NearWireUIOperationPhase>.Continuation?
      let taskToCancel: Task<Void, Never>?
      let delivery: PhaseDelivery?
    }

    struct CancellationEffect {
      let taskToCancel: Task<Void, Never>?
      let delivery: PhaseDelivery?
    }

    struct DisconnectPreparation {
      let shouldStart: Bool
      let taskToCancel: Task<Void, Never>?
      let delivery: PhaseDelivery?
    }

    struct ConnectFinishEffect {
      let completion: OriginCompletion?
      let delivery: PhaseDelivery?
    }

    private let lock = NSLock()
    private let deliveryHook: DeliveryHook?
    private var entries: [ObjectIdentifier: Entry] = [:]

    init(deliveryHook: DeliveryHook?) {
      self.deliveryHook = deliveryHook
    }

    func subscribe(
      key: ObjectIdentifier,
      token: NearWireUIPhaseRegistrationToken,
      continuation: AsyncStream<NearWireUIOperationPhase>.Continuation
    ) -> NearWireUIOperationPhase {
      withLock {
        let entry = entryLocked(for: key)
        entry.subscribers[token] = continuation
        return entry.phase
      }
    }

    func terminateSubscriber(
      key: ObjectIdentifier,
      token: NearWireUIPhaseRegistrationToken
    ) {
      withLock {
        guard let entry = entries[key] else { return }
        entry.subscribers.removeValue(forKey: token)
        pruneIfIdleLocked(key: key, entry: entry)
      }
    }

    func unsubscribe(
      key: ObjectIdentifier,
      token: NearWireUIPhaseRegistrationToken
    ) -> AsyncStream<NearWireUIOperationPhase>.Continuation? {
      withLock {
        guard let entry = entries[key] else { return nil }
        let continuation = entry.subscribers.removeValue(forKey: token)
        pruneIfIdleLocked(key: key, entry: entry)
        return continuation
      }
    }

    func releaseModel(
      key: ObjectIdentifier,
      registrationToken: NearWireUIPhaseRegistrationToken?,
      operationToken: NearWireUIOperationToken?
    ) -> ReleaseEffect {
      withLock {
        guard let entry = entries[key] else {
          return ReleaseEffect(continuation: nil, taskToCancel: nil, delivery: nil)
        }
        let continuation = registrationToken.flatMap {
          entry.subscribers.removeValue(forKey: $0)
        }
        var taskToCancel: Task<Void, Never>?
        var delivery: PhaseDelivery?
        if let operationToken, let connect = entry.connect, connect.token === operationToken {
          connect.originCompletion = nil
          taskToCancel = connect.task
          if entry.disconnect == nil {
            delivery = preparePhaseLocked(.cancelling, key: key, entry: entry)
          }
        }
        pruneIfIdleLocked(key: key, entry: entry)
        return ReleaseEffect(
          continuation: continuation,
          taskToCancel: taskToCancel,
          delivery: delivery
        )
      }
    }

    func canStartConnect(key: ObjectIdentifier) -> Bool {
      withLock {
        let entry = entryLocked(for: key)
        return entry.phase == .idle && entry.connect == nil && entry.disconnect == nil
      }
    }

    func startConnect(key: ObjectIdentifier, operation: ConnectOperation) -> PhaseDelivery? {
      withLock {
        let entry = entryLocked(for: key)
        precondition(entry.phase == .idle && entry.connect == nil && entry.disconnect == nil)
        entry.connect = operation
        return preparePhaseLocked(.connecting, key: key, entry: entry)
      }
    }

    func cancelConnect(
      key: ObjectIdentifier,
      token: NearWireUIOperationToken
    ) -> CancellationEffect {
      withLock {
        guard let entry = entries[key], let connect = entry.connect, connect.token === token else {
          return CancellationEffect(taskToCancel: nil, delivery: nil)
        }
        connect.originCompletion = nil
        let delivery: PhaseDelivery?
        if entry.disconnect == nil {
          delivery = preparePhaseLocked(.cancelling, key: key, entry: entry)
        } else {
          delivery = nil
        }
        return CancellationEffect(taskToCancel: connect.task, delivery: delivery)
      }
    }

    func prepareDisconnect(key: ObjectIdentifier) -> DisconnectPreparation {
      withLock {
        let entry = entryLocked(for: key)
        let taskToCancel: Task<Void, Never>?
        if let connect = entry.connect {
          connect.originCompletion = nil
          taskToCancel = connect.task
        } else {
          taskToCancel = nil
        }
        if entry.disconnect != nil {
          return DisconnectPreparation(
            shouldStart: false,
            taskToCancel: taskToCancel,
            delivery: preparePhaseLocked(.disconnecting, key: key, entry: entry)
          )
        }
        return DisconnectPreparation(
          shouldStart: true,
          taskToCancel: taskToCancel,
          delivery: nil
        )
      }
    }

    func startDisconnect(key: ObjectIdentifier, operation: DisconnectOperation) -> PhaseDelivery? {
      withLock {
        let entry = entryLocked(for: key)
        precondition(entry.disconnect == nil)
        entry.disconnect = operation
        return preparePhaseLocked(.disconnecting, key: key, entry: entry)
      }
    }

    func finishConnect(
      key: ObjectIdentifier,
      token: NearWireUIOperationToken
    ) -> ConnectFinishEffect {
      withLock {
        guard let entry = entries[key], let connect = entry.connect, connect.token === token else {
          return ConnectFinishEffect(completion: nil, delivery: nil)
        }
        let completion = connect.originCompletion
        entry.connect = nil
        if entry.disconnect == nil {
          let delivery = preparePhaseLocked(.idle, key: key, entry: entry)
          pruneIfIdleLocked(key: key, entry: entry)
          return ConnectFinishEffect(completion: completion, delivery: delivery)
        }
        return ConnectFinishEffect(
          completion: nil,
          delivery: preparePhaseLocked(.disconnecting, key: key, entry: entry)
        )
      }
    }

    func finishDisconnect(
      key: ObjectIdentifier,
      token: NearWireUIOperationToken
    ) -> PhaseDelivery? {
      withLock {
        guard let entry = entries[key], let disconnect = entry.disconnect,
          disconnect.token === token
        else { return nil }
        entry.disconnect = nil
        if entry.connect == nil {
          let delivery = preparePhaseLocked(.idle, key: key, entry: entry)
          pruneIfIdleLocked(key: key, entry: entry)
          return delivery
        } else {
          return preparePhaseLocked(.disconnecting, key: key, entry: entry)
        }
      }
    }

    func deliver(_ delivery: PhaseDelivery?) {
      guard let delivery else { return }
      while true {
        let snapshot = withLock {
          () -> (
            NearWireUIOperationPhase,
            UInt64,
            [NearWireUIPhaseRegistrationToken: AsyncStream<NearWireUIOperationPhase>.Continuation]
          )? in
          guard let entry = entries[delivery.key], entry === delivery.entry else { return nil }
          return (entry.phase, entry.phaseRevision, entry.subscribers)
        }
        guard let (phase, revision, subscribers) = snapshot else { return }
        deliveryHook?(phase)

        var terminated: [NearWireUIPhaseRegistrationToken] = []
        for (token, continuation) in subscribers {
          if case .terminated = continuation.yield(phase) {
            terminated.append(token)
          }
        }

        let changedDuringDelivery = withLock { () -> Bool in
          guard let entry = entries[delivery.key], entry === delivery.entry else { return false }
          for token in terminated { entry.subscribers.removeValue(forKey: token) }
          let changed = entry.phaseRevision != revision
          pruneIfIdleLocked(key: delivery.key, entry: entry)
          return changed && entries[delivery.key] === entry
        }
        if !changedDuringDelivery { return }
      }
    }

    var entryCount: Int {
      withLock { entries.count }
    }

    func phase(key: ObjectIdentifier) -> NearWireUIOperationPhase {
      withLock { entries[key]?.phase ?? .idle }
    }

    func subscriberCount(key: ObjectIdentifier) -> Int {
      withLock { entries[key]?.subscribers.count ?? 0 }
    }

    func liveTaskCounts(key: ObjectIdentifier) -> (connect: Int, disconnect: Int) {
      withLock {
        guard let entry = entries[key] else { return (0, 0) }
        return (entry.connect == nil ? 0 : 1, entry.disconnect == nil ? 0 : 1)
      }
    }

    func retainsOrigin(key: ObjectIdentifier, token: NearWireUIOperationToken) -> Bool {
      withLock {
        guard let connect = entries[key]?.connect, connect.token === token else { return false }
        return connect.originCompletion != nil
      }
    }

    private func entryLocked(for key: ObjectIdentifier) -> Entry {
      if let existing = entries[key] { return existing }
      let created = Entry()
      entries[key] = created
      return created
    }

    private func preparePhaseLocked(
      _ phase: NearWireUIOperationPhase,
      key: ObjectIdentifier,
      entry: Entry
    ) -> PhaseDelivery? {
      guard entries[key] === entry, entry.phase != phase else { return nil }
      entry.phase = phase
      entry.phaseRevision &+= 1
      return PhaseDelivery(
        key: key,
        entry: entry
      )
    }

    private func pruneIfIdleLocked(key: ObjectIdentifier, entry: Entry) {
      guard entries[key] === entry, entry.phase == .idle, entry.connect == nil,
        entry.disconnect == nil, entry.subscribers.isEmpty
      else { return }
      entries.removeValue(forKey: key)
    }

    private func withLock<T>(_ body: () -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return body()
    }
  }

  private nonisolated let storage: Storage

  init(deliveryHook: DeliveryHook? = nil) {
    storage = Storage(deliveryHook: deliveryHook)
  }

  func subscribe(
    controller: any NearWireUIConnectionControlling
  ) -> NearWireUIPhaseRegistration {
    let key = ObjectIdentifier(controller)
    let token = NearWireUIPhaseRegistrationToken()
    var capturedContinuation: AsyncStream<NearWireUIOperationPhase>.Continuation?
    let stream = AsyncStream<NearWireUIOperationPhase>(bufferingPolicy: .bufferingNewest(1)) {
      continuation in
      capturedContinuation = continuation
    }
    guard let continuation = capturedContinuation else {
      preconditionFailure("AsyncStream must synchronously provide its continuation.")
    }
    let initialPhase = storage.subscribe(key: key, token: token, continuation: continuation)
    continuation.onTermination = { [weak storage, token] _ in
      storage?.terminateSubscriber(key: key, token: token)
    }
    return NearWireUIPhaseRegistration(
      initialPhase: initialPhase,
      stream: stream,
      token: token
    )
  }

  func unsubscribe(
    controller: any NearWireUIConnectionControlling,
    token: NearWireUIPhaseRegistrationToken
  ) {
    storage.unsubscribe(key: ObjectIdentifier(controller), token: token)?.finish()
  }

  nonisolated func releaseModel(
    controller: any NearWireUIConnectionControlling,
    registrationToken: NearWireUIPhaseRegistrationToken?,
    operationToken: NearWireUIOperationToken?
  ) {
    let effect = storage.releaseModel(
      key: ObjectIdentifier(controller),
      registrationToken: registrationToken,
      operationToken: operationToken
    )
    storage.deliver(effect.delivery)
    effect.taskToCancel?.cancel()
    effect.continuation?.finish()
  }

  @discardableResult
  func connect(
    controller: any NearWireUIConnectionControlling,
    code: String,
    originCompletion: @escaping OriginCompletion
  ) -> NearWireUIOperationToken? {
    let key = ObjectIdentifier(controller)
    guard storage.canStartConnect(key: key) else { return nil }

    let token = NearWireUIOperationToken()
    let task = Task { [weak self, controller, token, code] in
      let outcome: NearWireUIConnectOutcome
      do {
        try await controller.connect(code: code)
        outcome = .success
      } catch let error as NearWireError {
        outcome = Self.connectOutcome(for: error)
      } catch is CancellationError {
        outcome = .cancelled
      } catch {
        outcome = .failure(.generic)
      }
      self?.finishConnect(key: key, token: token, outcome: outcome)
    }
    let delivery = storage.startConnect(
      key: key,
      operation: ConnectOperation(
        token: token,
        task: task,
        originCompletion: originCompletion
      )
    )
    storage.deliver(delivery)
    return token
  }

  func cancelConnectForDisappearance(
    controller: any NearWireUIConnectionControlling,
    token: NearWireUIOperationToken
  ) {
    let effect = storage.cancelConnect(key: ObjectIdentifier(controller), token: token)
    storage.deliver(effect.delivery)
    effect.taskToCancel?.cancel()
  }

  func disconnect(controller: any NearWireUIConnectionControlling) {
    let key = ObjectIdentifier(controller)
    let preparation = storage.prepareDisconnect(key: key)
    storage.deliver(preparation.delivery)
    preparation.taskToCancel?.cancel()
    guard preparation.shouldStart else { return }

    let token = NearWireUIOperationToken()
    let task = Task { [weak self, controller, token] in
      await controller.disconnect()
      self?.finishDisconnect(key: key, token: token)
    }
    let delivery = storage.startDisconnect(
      key: key,
      operation: DisconnectOperation(token: token, task: task)
    )
    storage.deliver(delivery)
  }

  var entryCount: Int { storage.entryCount }

  func phase(for controller: any NearWireUIConnectionControlling) -> NearWireUIOperationPhase {
    storage.phase(key: ObjectIdentifier(controller))
  }

  func subscriberCount(for controller: any NearWireUIConnectionControlling) -> Int {
    storage.subscriberCount(key: ObjectIdentifier(controller))
  }

  func liveTaskCounts(
    for controller: any NearWireUIConnectionControlling
  ) -> (connect: Int, disconnect: Int) {
    storage.liveTaskCounts(key: ObjectIdentifier(controller))
  }

  func retainsOrigin(
    controller: any NearWireUIConnectionControlling,
    token: NearWireUIOperationToken
  ) -> Bool {
    storage.retainsOrigin(key: ObjectIdentifier(controller), token: token)
  }

  static func connectOutcome(for error: NearWireError) -> NearWireUIConnectOutcome {
    if error.code == .connectionCancelled || error.code == .shutdown { return .cancelled }
    return .failure(
      NearWireUIActionError(
        message: error.message,
        offersReset: offersReset(for: error.code)
      )
    )
  }

  private func finishConnect(
    key: ObjectIdentifier,
    token: NearWireUIOperationToken,
    outcome: NearWireUIConnectOutcome
  ) {
    let effect = storage.finishConnect(key: key, token: token)
    storage.deliver(effect.delivery)
    effect.completion?(token, outcome)
  }

  private func finishDisconnect(
    key: ObjectIdentifier,
    token: NearWireUIOperationToken
  ) {
    storage.deliver(storage.finishDisconnect(key: key, token: token))
  }

  private static func offersReset(for code: NearWireError.Code) -> Bool {
    switch code {
    case .connectionInProgress, .alreadyConnected, .connectionSuspended,
      .connectionIntentExists, .anotherConnectionIsActive:
      return true
    default:
      return false
    }
  }
}
