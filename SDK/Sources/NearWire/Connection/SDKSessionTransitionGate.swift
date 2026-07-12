import Foundation

enum SDKSessionCancellationReason: Equatable, Sendable {
  case task
  case suspension
  case disconnect
  case shutdown
}

enum SDKSessionTransitionFailure: Error, Equatable, Sendable {
  case cancelled
  case shutdown
  case terminal(SDKSessionAdmissionError.Code)
  case invalidState
}

final class SDKSessionTransitionTarget: @unchecked Sendable {
  private let lock = NSLock()
  private var cancellation: (@Sendable () -> Void)?
  private var didRequestCancellation = false

  func installCancellation(_ operation: @escaping @Sendable () -> Void) {
    let cancelImmediately = lock.withLock {
      precondition(cancellation == nil, "A transition target may be installed only once.")
      guard !didRequestCancellation else { return true }
      cancellation = operation
      return false
    }
    if cancelImmediately { operation() }
  }

  func requestCancellation() {
    let operation: (@Sendable () -> Void)? = lock.withLock {
      guard !didRequestCancellation else { return nil }
      didRequestCancellation = true
      defer { cancellation = nil }
      return cancellation
    }
    operation?()
  }
}

struct SDKSessionTransitionGateHooks: Sendable {
  let beforeTerminalMutation: @Sendable () -> Void
  let beforeActiveTransferMutation: @Sendable () -> Void
  let beforeConnectedCommitMutation: @Sendable () -> Void

  static let none = SDKSessionTransitionGateHooks(
    beforeTerminalMutation: {},
    beforeActiveTransferMutation: {},
    beforeConnectedCommitMutation: {}
  )
}

final class SDKSessionTransitionGate: @unchecked Sendable {
  struct CancellationResult: Equatable, Sendable {
    let accepted: Bool
    let deliveredToTarget: Bool
  }

  enum PublicPhase: String, Equatable, Sendable {
    case attempting
    case transferred
    case connected
  }

  struct Snapshot: Equatable, Sendable {
    let phase: PublicPhase
    let cancellationReason: SDKSessionCancellationReason?
    let terminalCode: SDKSessionAdmissionError.Code?
    let hasTarget: Bool
    let targetGeneration: UInt64?
    let coordinatorOwnsLease: Bool
  }

  private struct Target {
    let token: SDKSessionTransitionTarget
    let generation: UInt64
  }

  private let lock = NSLock()
  private let hooks: SDKSessionTransitionGateHooks
  private var phase: PublicPhase = .attempting
  private var cancellationReason: SDKSessionCancellationReason?
  private var cancellationOrder: UInt64?
  private var terminalCode: SDKSessionAdmissionError.Code?
  private var terminalOrder: UInt64?
  private var target: Target?
  private var deliveredCancellationToTarget = false
  private var nextOrder: UInt64 = 1
  private var nextTargetGeneration: UInt64 = 1
  private var coordinatorOwnsLease = false

  init(hooks: SDKSessionTransitionGateHooks = .none) {
    self.hooks = hooks
  }

  var snapshot: Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      phase: phase,
      cancellationReason: cancellationReason,
      terminalCode: terminalCode,
      hasTarget: target != nil,
      targetGeneration: target?.generation,
      coordinatorOwnsLease: coordinatorOwnsLease
    )
  }

  func isAuthorized() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancellationReason == nil && terminalCode == nil
  }

  @discardableResult
  func requestCancellation(_ reason: SDKSessionCancellationReason) -> Bool {
    requestCancellationResult(reason).accepted
  }

  func requestCancellationResult(
    _ reason: SDKSessionCancellationReason
  ) -> CancellationResult {
    let cancellationTarget: SDKSessionTransitionTarget?
    let deliveredAtLinearization: Bool
    lock.lock()
    if phase == .connected || (phase == .transferred && reason == .task) {
      lock.unlock()
      return CancellationResult(accepted: false, deliveredToTarget: false)
    }
    if cancellationReason.map({ cancellationPriority(reason) > cancellationPriority($0) }) ?? true {
      cancellationReason = reason
      cancellationOrder = takeOrder()
    }
    cancellationTarget = target?.token
    if cancellationTarget != nil { deliveredCancellationToTarget = true }
    deliveredAtLinearization = deliveredCancellationToTarget
    target = nil
    lock.unlock()
    cancellationTarget?.requestCancellation()
    return CancellationResult(
      accepted: true,
      deliveredToTarget: deliveredAtLinearization
    )
  }

  func installTarget(
    token: SDKSessionTransitionTarget,
    cancel: @escaping @Sendable () -> Void
  ) -> Bool {
    token.installCancellation(cancel)
    var cancelImmediately = false
    lock.lock()
    if cancellationReason != nil || terminalCode != nil {
      cancelImmediately = true
      deliveredCancellationToTarget = true
    } else {
      let generation = nextTargetGeneration
      nextTargetGeneration &+= 1
      target = Target(token: token, generation: generation)
    }
    lock.unlock()
    if cancelImmediately { token.requestCancellation() }
    return !cancelImmediately
  }

  func removeTarget(token: SDKSessionTransitionTarget) {
    lock.lock()
    if target?.token === token { target = nil }
    lock.unlock()
  }

  @discardableResult
  func cancelTarget(token: SDKSessionTransitionTarget) -> Bool {
    let cancellationTarget: SDKSessionTransitionTarget?
    lock.lock()
    if target?.token === token {
      cancellationTarget = target?.token
      target = nil
    } else {
      cancellationTarget = nil
    }
    lock.unlock()
    cancellationTarget?.requestCancellation()
    return cancellationTarget != nil
  }

  func replaceTarget(
    expectedToken: SDKSessionTransitionTarget,
    newToken: SDKSessionTransitionTarget,
    cancel: @escaping @Sendable () -> Void
  ) -> Bool {
    newToken.installCancellation(cancel)
    var cancelImmediately = false
    lock.lock()
    if cancellationReason != nil || terminalCode != nil {
      if target?.token === expectedToken { target = nil }
      cancelImmediately = true
      deliveredCancellationToTarget = true
    } else if target?.token === expectedToken {
      let generation = nextTargetGeneration
      nextTargetGeneration &+= 1
      target = Target(token: newToken, generation: generation)
    } else {
      cancelImmediately = true
    }
    lock.unlock()
    if cancelImmediately { newToken.requestCancellation() }
    return !cancelImmediately
  }

  func markTerminal(_ code: SDKSessionAdmissionError.Code) -> PublicPhase? {
    lock.lock()
    defer { lock.unlock() }
    guard terminalCode == nil else { return nil }
    hooks.beforeTerminalMutation()
    terminalCode = code
    terminalOrder = takeOrder()
    target = nil
    return phase
  }

  func claimActiveTransfer() -> Result<Void, SDKSessionTransitionFailure> {
    lock.lock()
    defer { lock.unlock() }
    hooks.beforeActiveTransferMutation()
    if cancellationReason == .shutdown { return .failure(.shutdown) }
    if cancellationReason != nil,
      let cancellationOrder,
      terminalOrder.map({ cancellationOrder < $0 }) ?? true
    {
      return .failure(.cancelled)
    }
    if let terminalCode { return .failure(.terminal(terminalCode)) }
    guard phase == .attempting else { return .failure(.invalidState) }
    phase = .transferred
    target = nil
    return .success(())
  }

  func currentFailure() -> SDKSessionTransitionFailure? {
    lock.lock()
    defer { lock.unlock() }
    if cancellationReason == .shutdown { return .shutdown }
    if cancellationReason != nil,
      let cancellationOrder,
      terminalOrder.map({ cancellationOrder < $0 }) ?? true
    {
      return .cancelled
    }
    if let terminalCode { return .terminal(terminalCode) }
    return nil
  }

  func claimConnectedCommit() -> Result<Void, SDKSessionTransitionFailure> {
    lock.lock()
    defer { lock.unlock() }
    hooks.beforeConnectedCommitMutation()
    if cancellationReason == .shutdown { return .failure(.shutdown) }
    if cancellationReason != nil { return .failure(.cancelled) }
    if let terminalCode { return .failure(.terminal(terminalCode)) }
    guard phase == .transferred else { return .failure(.invalidState) }
    phase = .connected
    target = nil
    return .success(())
  }

  func claimCoordinatorLeaseOwnership() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !coordinatorOwnsLease else { return false }
    coordinatorOwnsLease = true
    return true
  }

  private func takeOrder() -> UInt64 {
    let order = nextOrder
    nextOrder &+= 1
    return order
  }

  private func cancellationPriority(_ reason: SDKSessionCancellationReason) -> Int {
    switch reason {
    case .task: return 0
    case .suspension: return 1
    case .disconnect: return 2
    case .shutdown: return 3
    }
  }
}
