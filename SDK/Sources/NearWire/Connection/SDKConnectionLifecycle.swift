import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

final class SDKLifecycleIntentToken: @unchecked Sendable {}
final class SDKRecoveryTaskToken: @unchecked Sendable {}
final class SDKLifecycleCommandToken: @unchecked Sendable {}

struct SDKLifecycleIntent: Sendable {
  enum Phase: Equatable, Sendable {
    case pending
    case active
  }

  let token: SDKLifecycleIntentToken
  let pairingCode: PairingCode
  var generation: UInt64
  var phase: Phase
  var attemptsUsed: Int
}

private final class SDKCleanupSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var isSettled = false

  func wait() async {
    await withCheckedContinuation { continuation in
      let resumeImmediately = lock.withLock {
        guard !isSettled else { return true }
        precondition(self.continuation == nil, "Cleanup signal has one shared waiter.")
        self.continuation = continuation
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }

  func settle() {
    let continuation = lock.withLock {
      guard !isSettled else { return nil as CheckedContinuation<Void, Never>? }
      isSettled = true
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume()
  }
}

final class SDKCleanupReceipt: @unchecked Sendable {
  private let signal: SDKCleanupSignal
  let completion: Task<Void, Never>

  init() {
    let signal = SDKCleanupSignal()
    self.signal = signal
    completion = Task { await signal.wait() }
  }

  func settle() {
    signal.settle()
  }
}

enum SDKLifecycleFailurePhase: Sendable {
  case activeTerminal
  case recoveryAttempt
}

enum SDKLifecycleRecoveryDisposition: Equatable, Sendable {
  case transient
  case permanent
  case lifecycleCancellation
}

enum SDKLifecycleRecoveryMapping {
  static func disposition(
    for code: SDKSessionAdmissionError.Code,
    phase: SDKLifecycleFailurePhase
  ) -> SDKLifecycleRecoveryDisposition {
    switch code {
    case .cancelled, .pullCancelled:
      return .lifecycleCancellation
    case .discoveryTimedOut, .discoveryUnavailable, .discoveryFailed,
      .secureAdmissionTimedOut, .pumpAttachmentTimedOut, .policyNegotiationTimedOut,
      .remoteClosed:
      return .transient
    case .transportFailed:
      switch phase {
      case .activeTerminal: return .transient
      case .recoveryAttempt: return .permanent
      }
    case .invalidLocalConfiguration, .alreadyStarted, .discoveryDenied,
      .discoveryAmbiguous, .ingressOverflow, .protocolViolation, .incompatiblePeer,
      .viewerIdentityMismatch, .viewerRejected, .handshakeWorkLimitExceeded,
      .handoffWorkLimitExceeded, .handoffBufferOverflow, .alreadyAttached,
      .pullAlreadyPending, .policyConsumerClaimed, .terminationWaitAlreadyStarted,
      .terminationWaitCancelled, .activeIngressOverflow, .activeWorkLimitExceeded,
      .routeMismatch, .sequenceViolation, .outboundEncodingFailed, .ownerUnavailable,
      .clockFailed:
      return .permanent
    }
  }
}

struct SDKLifecycleRecoveryFailure: Error, Sendable {
  let publicError: NearWireError
  let disposition: SDKLifecycleRecoveryDisposition

  init(code: SDKSessionAdmissionError.Code, phase: SDKLifecycleFailurePhase) {
    publicError = SDKPublicConnectionErrorMapping.map(code)
    disposition = SDKLifecycleRecoveryMapping.disposition(for: code, phase: phase)
  }
}

struct SDKLifecycleSnapshot: Equatable, Sendable {
  let hasIntent: Bool
  let intentIsPending: Bool
  let attemptsUsed: Int
  let hasRecoveryTask: Bool
  let hasCleanupReceipt: Bool
  let isSuspended: Bool
  let resumeAfterCleanup: Bool
}
