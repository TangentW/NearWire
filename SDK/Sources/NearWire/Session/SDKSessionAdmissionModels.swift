import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireInternal) import NearWireTransport
#endif

enum SDKSessionAdmissionState: String, Equatable, Sendable {
  case idle
  case discovering
  case transferred
  case connecting
  case exchangingHello
  case awaitingApproval
  case admitted
  case bindingActiveOwner
  case negotiatingPolicy
  case active
  case failed
  case cancelled
}

struct SDKSessionAdmissionError: Error, Equatable, Sendable {
  enum Code: String, CaseIterable, Sendable {
    case invalidLocalConfiguration
    case alreadyStarted
    case cancelled
    case discoveryTimedOut
    case discoveryDenied
    case discoveryUnavailable
    case discoveryAmbiguous
    case discoveryFailed
    case secureAdmissionTimedOut
    case pumpAttachmentTimedOut
    case transportFailed
    case ingressOverflow
    case protocolViolation
    case incompatiblePeer
    case viewerIdentityMismatch
    case viewerRejected
    case remoteClosed
    case handshakeWorkLimitExceeded
    case handoffWorkLimitExceeded
    case handoffBufferOverflow
    case alreadyAttached
    case pullAlreadyPending
    case pullCancelled
    case policyConsumerClaimed
    case terminationWaitAlreadyStarted
    case terminationWaitCancelled
    case policyNegotiationTimedOut
    case activeIngressOverflow
    case activeWorkLimitExceeded
    case routeMismatch
    case sequenceViolation
    case outboundEncodingFailed
    case ownerUnavailable
    case clockFailed
  }

  let code: Code

  var message: String {
    switch code {
    case .invalidLocalConfiguration:
      return "Local session admission configuration is invalid."
    case .alreadyStarted:
      return "Session admission has already started."
    case .cancelled:
      return "Session admission was cancelled."
    case .discoveryTimedOut:
      return "Viewer discovery timed out."
    case .discoveryDenied:
      return "Viewer discovery is denied by local policy."
    case .discoveryUnavailable:
      return "Viewer discovery is unavailable."
    case .discoveryAmbiguous:
      return "More than one Viewer matched discovery."
    case .discoveryFailed:
      return "Viewer discovery failed."
    case .secureAdmissionTimedOut:
      return "Secure session admission timed out."
    case .pumpAttachmentTimedOut:
      return "The event pump did not attach in time."
    case .transportFailed:
      return "The secure transport failed."
    case .ingressOverflow:
      return "Session callback ingress exceeded its bound."
    case .protocolViolation:
      return "The peer violated the session protocol."
    case .incompatiblePeer:
      return "The peer is not protocol-compatible."
    case .viewerIdentityMismatch:
      return "Viewer discovery and hello identity do not agree."
    case .viewerRejected:
      return "The Viewer rejected this App connection."
    case .remoteClosed:
      return "The Viewer closed session admission."
    case .handshakeWorkLimitExceeded:
      return "Handshake work exceeded its bound."
    case .handoffWorkLimitExceeded:
      return "Pre-active handoff work exceeded its bound."
    case .handoffBufferOverflow:
      return "Pre-active handoff buffering exceeded its bound."
    case .alreadyAttached:
      return "An event pump is already attached."
    case .pullAlreadyPending:
      return "A policy-message pull is already pending."
    case .pullCancelled:
      return "The policy-message pull was cancelled."
    case .policyConsumerClaimed:
      return "Policy-message ownership has already been claimed."
    case .terminationWaitAlreadyStarted:
      return "Termination observation has already started."
    case .terminationWaitCancelled:
      return "Termination observation was cancelled."
    case .policyNegotiationTimedOut:
      return "Active flow-policy negotiation timed out."
    case .activeIngressOverflow:
      return "Active Event ingress exceeded its bound."
    case .activeWorkLimitExceeded:
      return "Active Event work exceeded its bound."
    case .routeMismatch:
      return "An active Event did not match the admitted route."
    case .sequenceViolation:
      return "An active Event sequence was invalid."
    case .outboundEncodingFailed:
      return "An outbound Event could not be encoded."
    case .ownerUnavailable:
      return "The bound NearWire owner is unavailable."
    case .clockFailed:
      return "The active session clock failed."
    }
  }

  init(_ code: Code) {
    self.code = code
  }
}

extension SDKSessionAdmissionError: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String { "\(code.rawValue): \(message)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

struct SDKSessionAdmissionLimits: Equatable, Sendable {
  static let hardMaximumTimeoutSeconds = 120
  static let hardMaximumAttachmentTimeoutSeconds = 30
  static let hardMaximumIngressEvents = 256
  static let hardMaximumIngressBytes = 1_048_576
  static let hardMaximumHandshakeWorkItems = 128
  static let hardMaximumHandshakeWorkBytes = 1_048_576
  static let hardMaximumHandoffWorkItems = 256
  static let hardMaximumHandoffWorkBytes = 1_048_576
  static let hardMaximumHandoffMessages = 128
  static let hardMaximumHandoffBytes = 1_048_576

  static let `default` = SDKSessionAdmissionLimits(
    uncheckedDiscoveryTimeoutSeconds: 30,
    secureAdmissionTimeoutSeconds: 15,
    pumpAttachmentTimeoutSeconds: 5,
    maximumIngressEvents: 64,
    maximumIngressBytes: 256 * 1_024,
    maximumHandshakeWorkItems: 32,
    maximumHandshakeWorkBytes: 256 * 1_024,
    maximumHandoffWorkItems: 64,
    maximumHandoffWorkBytes: 512 * 1_024,
    maximumHandoffMessages: 32,
    maximumHandoffBytes: 256 * 1_024
  )

  let discoveryTimeoutSeconds: Int
  let secureAdmissionTimeoutSeconds: Int
  let pumpAttachmentTimeoutSeconds: Int
  let maximumIngressEvents: Int
  let maximumIngressBytes: Int
  let maximumHandshakeWorkItems: Int
  let maximumHandshakeWorkBytes: Int
  let maximumHandoffWorkItems: Int
  let maximumHandoffWorkBytes: Int
  let maximumHandoffMessages: Int
  let maximumHandoffBytes: Int

  init(
    discoveryTimeoutSeconds: Int = 30,
    secureAdmissionTimeoutSeconds: Int = 15,
    pumpAttachmentTimeoutSeconds: Int = 5,
    maximumIngressEvents: Int = 64,
    maximumIngressBytes: Int = 256 * 1_024,
    maximumHandshakeWorkItems: Int = 32,
    maximumHandshakeWorkBytes: Int = 256 * 1_024,
    maximumHandoffWorkItems: Int = 64,
    maximumHandoffWorkBytes: Int = 512 * 1_024,
    maximumHandoffMessages: Int = 32,
    maximumHandoffBytes: Int = 256 * 1_024
  ) throws {
    guard (1...Self.hardMaximumTimeoutSeconds).contains(discoveryTimeoutSeconds),
      (1...Self.hardMaximumTimeoutSeconds).contains(secureAdmissionTimeoutSeconds),
      (1...Self.hardMaximumAttachmentTimeoutSeconds).contains(pumpAttachmentTimeoutSeconds),
      (1...Self.hardMaximumIngressEvents).contains(maximumIngressEvents),
      (1...Self.hardMaximumIngressBytes).contains(maximumIngressBytes),
      (1...Self.hardMaximumHandshakeWorkItems).contains(maximumHandshakeWorkItems),
      (1...Self.hardMaximumHandshakeWorkBytes).contains(maximumHandshakeWorkBytes),
      (1...Self.hardMaximumHandoffWorkItems).contains(maximumHandoffWorkItems),
      (1...Self.hardMaximumHandoffWorkBytes).contains(maximumHandoffWorkBytes),
      (1...Self.hardMaximumHandoffMessages).contains(maximumHandoffMessages),
      (1...Self.hardMaximumHandoffBytes).contains(maximumHandoffBytes),
      maximumHandoffMessages <= maximumHandoffWorkItems,
      maximumHandoffBytes <= maximumHandoffWorkBytes
    else {
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
    self.init(
      uncheckedDiscoveryTimeoutSeconds: discoveryTimeoutSeconds,
      secureAdmissionTimeoutSeconds: secureAdmissionTimeoutSeconds,
      pumpAttachmentTimeoutSeconds: pumpAttachmentTimeoutSeconds,
      maximumIngressEvents: maximumIngressEvents,
      maximumIngressBytes: maximumIngressBytes,
      maximumHandshakeWorkItems: maximumHandshakeWorkItems,
      maximumHandshakeWorkBytes: maximumHandshakeWorkBytes,
      maximumHandoffWorkItems: maximumHandoffWorkItems,
      maximumHandoffWorkBytes: maximumHandoffWorkBytes,
      maximumHandoffMessages: maximumHandoffMessages,
      maximumHandoffBytes: maximumHandoffBytes
    )
  }

  private init(
    uncheckedDiscoveryTimeoutSeconds discoveryTimeoutSeconds: Int,
    secureAdmissionTimeoutSeconds: Int,
    pumpAttachmentTimeoutSeconds: Int,
    maximumIngressEvents: Int,
    maximumIngressBytes: Int,
    maximumHandshakeWorkItems: Int,
    maximumHandshakeWorkBytes: Int,
    maximumHandoffWorkItems: Int,
    maximumHandoffWorkBytes: Int,
    maximumHandoffMessages: Int,
    maximumHandoffBytes: Int
  ) {
    self.discoveryTimeoutSeconds = discoveryTimeoutSeconds
    self.secureAdmissionTimeoutSeconds = secureAdmissionTimeoutSeconds
    self.pumpAttachmentTimeoutSeconds = pumpAttachmentTimeoutSeconds
    self.maximumIngressEvents = maximumIngressEvents
    self.maximumIngressBytes = maximumIngressBytes
    self.maximumHandshakeWorkItems = maximumHandshakeWorkItems
    self.maximumHandshakeWorkBytes = maximumHandshakeWorkBytes
    self.maximumHandoffWorkItems = maximumHandoffWorkItems
    self.maximumHandoffWorkBytes = maximumHandoffWorkBytes
    self.maximumHandoffMessages = maximumHandoffMessages
    self.maximumHandoffBytes = maximumHandoffBytes
  }

  func validate(
    wireLimits: WireProtocolLimits,
    transportLimits: SecureTransportLimits,
    encodedHelloByteCount: Int,
    encodedMaximumPongByteCount: Int
  ) throws {
    let maximumControlFrameBytes = wireLimits.frame.maximumEncodedFrameBytes(for: .control)
    let (outboundByteCount, outboundOverflow) = encodedHelloByteCount.addingReportingOverflow(
      encodedMaximumPongByteCount
    )
    guard secureAdmissionTimeoutSeconds >= transportLimits.connectionTimeoutSeconds,
      maximumIngressBytes >= transportLimits.receiveChunkBytes,
      maximumHandshakeWorkBytes >= maximumControlFrameBytes,
      maximumHandoffWorkBytes >= maximumControlFrameBytes,
      maximumHandoffBytes <= maximumHandoffWorkBytes,
      encodedHelloByteCount > 0,
      encodedMaximumPongByteCount > 0,
      transportLimits.maximumSingleSendBytes >= encodedHelloByteCount,
      transportLimits.maximumSingleSendBytes >= encodedMaximumPongByteCount,
      transportLimits.maximumPendingSendCount >= 2,
      !outboundOverflow,
      transportLimits.maximumPendingSendBytes >= outboundByteCount
    else {
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
  }
}

final class SDKSessionAttemptToken: @unchecked Sendable {}
final class SDKSessionDeadlineToken: @unchecked Sendable {}
final class SDKSessionPullToken: @unchecked Sendable {}

struct SDKActiveEventPumpLimits: Equatable, Sendable {
  static let hardMaximumPolicyTimeoutSeconds = 120
  static let hardMaximumIncomingEvents = 10_000
  static let hardMaximumIncomingBytes = 64 * 1_024 * 1_024
  static let hardMaximumFramesPerReceive = 1_024
  static let hardMaximumOutboundServiceUnits = 256
  static let hardMaximumOutboundBytes = 64 * 1_024 * 1_024
  static let hardMaximumIncomingPublications = 256
  static let hardMaximumDeferredPolicyTransactions = 128

  static let `default` = SDKActiveEventPumpLimits(
    uncheckedInitialPolicyTimeoutSeconds: 10,
    maximumIncomingEvents: 1_024,
    maximumIncomingEncodedBytes: 8 * 1_024 * 1_024,
    maximumCompletedFramesPerReceive: 256,
    maximumOutboundServiceUnitsPerTurn: 64,
    maximumOutboundAccountedBytesPerTurn: 2 * 1_024 * 1_024,
    maximumIncomingPublicationsPerTurn: 32,
    maximumDeferredPolicyTransactions: 32
  )

  let initialPolicyTimeoutSeconds: Int
  let maximumIncomingEvents: Int
  let maximumIncomingEncodedBytes: Int
  let maximumCompletedFramesPerReceive: Int
  let maximumOutboundServiceUnitsPerTurn: Int
  let maximumOutboundAccountedBytesPerTurn: Int
  let maximumIncomingPublicationsPerTurn: Int
  let maximumDeferredPolicyTransactions: Int

  init(
    initialPolicyTimeoutSeconds: Int = 10,
    maximumIncomingEvents: Int = 1_024,
    maximumIncomingEncodedBytes: Int = 8 * 1_024 * 1_024,
    maximumCompletedFramesPerReceive: Int = 256,
    maximumOutboundServiceUnitsPerTurn: Int = 64,
    maximumOutboundAccountedBytesPerTurn: Int = 2 * 1_024 * 1_024,
    maximumIncomingPublicationsPerTurn: Int = 32,
    maximumDeferredPolicyTransactions: Int = 32
  ) throws {
    guard (1...Self.hardMaximumPolicyTimeoutSeconds).contains(initialPolicyTimeoutSeconds),
      (1...Self.hardMaximumIncomingEvents).contains(maximumIncomingEvents),
      (1...Self.hardMaximumIncomingBytes).contains(maximumIncomingEncodedBytes),
      (1...Self.hardMaximumFramesPerReceive).contains(maximumCompletedFramesPerReceive),
      (1...Self.hardMaximumOutboundServiceUnits).contains(maximumOutboundServiceUnitsPerTurn),
      (1...Self.hardMaximumOutboundBytes).contains(maximumOutboundAccountedBytesPerTurn),
      (1...Self.hardMaximumIncomingPublications).contains(maximumIncomingPublicationsPerTurn),
      (1...Self.hardMaximumDeferredPolicyTransactions).contains(maximumDeferredPolicyTransactions)
    else {
      throw SDKSessionAdmissionError(.invalidLocalConfiguration)
    }
    self.init(
      uncheckedInitialPolicyTimeoutSeconds: initialPolicyTimeoutSeconds,
      maximumIncomingEvents: maximumIncomingEvents,
      maximumIncomingEncodedBytes: maximumIncomingEncodedBytes,
      maximumCompletedFramesPerReceive: maximumCompletedFramesPerReceive,
      maximumOutboundServiceUnitsPerTurn: maximumOutboundServiceUnitsPerTurn,
      maximumOutboundAccountedBytesPerTurn: maximumOutboundAccountedBytesPerTurn,
      maximumIncomingPublicationsPerTurn: maximumIncomingPublicationsPerTurn,
      maximumDeferredPolicyTransactions: maximumDeferredPolicyTransactions
    )
  }

  private init(
    uncheckedInitialPolicyTimeoutSeconds initialPolicyTimeoutSeconds: Int,
    maximumIncomingEvents: Int,
    maximumIncomingEncodedBytes: Int,
    maximumCompletedFramesPerReceive: Int,
    maximumOutboundServiceUnitsPerTurn: Int,
    maximumOutboundAccountedBytesPerTurn: Int,
    maximumIncomingPublicationsPerTurn: Int,
    maximumDeferredPolicyTransactions: Int
  ) {
    self.initialPolicyTimeoutSeconds = initialPolicyTimeoutSeconds
    self.maximumIncomingEvents = maximumIncomingEvents
    self.maximumIncomingEncodedBytes = maximumIncomingEncodedBytes
    self.maximumCompletedFramesPerReceive = maximumCompletedFramesPerReceive
    self.maximumOutboundServiceUnitsPerTurn = maximumOutboundServiceUnitsPerTurn
    self.maximumOutboundAccountedBytesPerTurn = maximumOutboundAccountedBytesPerTurn
    self.maximumIncomingPublicationsPerTurn = maximumIncomingPublicationsPerTurn
    self.maximumDeferredPolicyTransactions = maximumDeferredPolicyTransactions
  }
}

protocol SDKSessionDiscoveryOperation: Sendable {
  func run() async throws -> DiscoveredViewer
  func cancel() async
}

struct SDKSessionAdmissionDependencies: Sendable {
  typealias ChannelFactory =
    @Sendable (
      DiscoveredViewer,
      @escaping SecureByteChannel.EventHandler
    ) -> SecureByteChannel

  let makeDiscovery: @Sendable (PairingCode) -> any SDKSessionDiscoveryOperation
  let makeChannel: ChannelFactory
  let sleep: @Sendable (Int) async throws -> Void
  let beforeBind: @Sendable () async -> Void

  init(
    makeDiscovery: @escaping @Sendable (PairingCode) -> any SDKSessionDiscoveryOperation,
    makeChannel: @escaping ChannelFactory,
    sleep: @escaping @Sendable (Int) async throws -> Void,
    beforeBind: @escaping @Sendable () async -> Void = {}
  ) {
    self.makeDiscovery = makeDiscovery
    self.makeChannel = makeChannel
    self.sleep = sleep
    self.beforeBind = beforeBind
  }

  static func live(
    connectionQueue: DispatchQueue,
    verificationQueue: DispatchQueue,
    transportLimits: SecureTransportLimits
  ) -> Self {
    SDKSessionAdmissionDependencies(
      makeDiscovery: { pairingCode in
        SDKProductionDiscoveryOperation(pairingCode: pairingCode)
      },
      makeChannel: { discovered, eventHandler in
        SecureAppTransport.makeChannel(
          endpoint: discovered.endpoint,
          connectionQueue: connectionQueue,
          verificationQueue: verificationQueue,
          limits: transportLimits,
          eventHandler: eventHandler
        )
      },
      sleep: { seconds in
        try await ContinuousClock().sleep(for: .seconds(seconds))
      },
      beforeBind: {}
    )
  }
}

private final class SDKProductionDiscoveryOperation: SDKSessionDiscoveryOperation,
  @unchecked Sendable
{
  private let coordinator: ViewerDiscoveryCoordinator

  init(pairingCode: PairingCode) {
    coordinator = ViewerDiscoveryCoordinator(
      pairingCode: pairingCode,
      driver: NWBrowserDiscoveryDriver()
    )
  }

  func run() async throws -> DiscoveredViewer {
    try await coordinator.run()
  }

  func cancel() async {
    await coordinator.cancel()
  }
}

enum SDKSessionPolicyMessage: Equatable, Sendable {
  case offer(WireFlowPolicyOffer)
  case accepted(WireFlowPolicyAccepted)
}

struct SDKBufferedPolicyMessage: Equatable, Sendable {
  let message: SDKSessionPolicyMessage
  let encodedByteCount: Int
}

final class SDKSessionPullCancellationGate: @unchecked Sendable {
  private enum State {
    case open
    case cancelled
    case registered(@Sendable () -> Void)
    case closed
  }

  private let lock = NSLock()
  private let notificationScheduler: @Sendable (@escaping @Sendable () -> Void) -> Void
  private let claimDidRegister: @Sendable () -> Void
  private var state: State = .open

  init(
    notificationScheduler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
      $0()
    },
    claimDidRegister: @escaping @Sendable () -> Void = {}
  ) {
    self.notificationScheduler = notificationScheduler
    self.claimDidRegister = claimDidRegister
  }

  func cancel() {
    let notification: (@Sendable () -> Void)?
    lock.lock()
    switch state {
    case .open:
      state = .cancelled
      notification = nil
    case .registered(let callback):
      state = .cancelled
      notification = callback
    case .cancelled, .closed:
      notification = nil
    }
    lock.unlock()
    if let notification {
      notificationScheduler(notification)
    }
  }

  func claim(notification: @escaping @Sendable () -> Void) -> Bool {
    lock.lock()
    switch state {
    case .open:
      state = .registered(notification)
      lock.unlock()
      claimDidRegister()
      return true
    case .cancelled, .registered, .closed:
      lock.unlock()
      return false
    }
  }

  func close() {
    lock.lock()
    state = .closed
    lock.unlock()
  }

  func closeRegisteredClaim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard case .registered = state else { return false }
    state = .closed
    return true
  }
}
