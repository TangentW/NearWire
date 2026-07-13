import CryptoKit
import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

protocol ViewerAdmissionChannel: Sendable {
  func admitSend(_ data: Data) throws
  func admitSend(
    _ data: Data,
    reservingPendingSendCount: Int,
    reservingPendingSendBytes: Int
  ) throws
  func canAdmitSend(
    byteCount: Int,
    reservingPendingSendCount: Int,
    reservingPendingSendBytes: Int
  ) -> Bool
  func claimReceivePause() -> SecureReceivePauseToken?
  var receiveChunkBytes: Int { get }
  func start() async throws
  func cancel() async
}

extension ViewerAdmissionChannel {
  func admitSend(
    _ data: Data,
    reservingPendingSendCount: Int,
    reservingPendingSendBytes: Int
  ) throws {
    try admitSend(data)
  }

  func canAdmitSend(
    byteCount: Int,
    reservingPendingSendCount: Int,
    reservingPendingSendBytes: Int
  ) -> Bool { true }

  func claimReceivePause() -> SecureReceivePauseToken? { nil }
  var receiveChunkBytes: Int { SecureTransportLimits.default.receiveChunkBytes }
}

extension SecureByteChannel: ViewerAdmissionChannel {
  nonisolated var receiveChunkBytes: Int { limits.receiveChunkBytes }
}

struct ViewerAdmissionSessionContext: Sendable {
  let connectionID: UUID
  let appHello: WireHello
  let viewerHello: WireHello
  let negotiation: WireNegotiationResult
  let receiveChunkBytes: Int
}

extension ViewerAdmissionSessionContext: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerAdmissionSessionContext(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

struct ViewerSessionIngressLimits: Sendable {
  static let maximumFramesPerTurn = 64
  static let maximumRetainedInputBytes = 19 * 1_024 * 1_024
  static let `default` = ViewerSessionIngressLimits(
    maximumFramesPerTurn: maximumFramesPerTurn,
    maximumRetainedInputBytes: 2 * 1_024 * 1_024
  )

  let maximumFramesPerTurn: Int
  let maximumRetainedInputBytes: Int

  init(maximumFramesPerTurn: Int, maximumRetainedInputBytes: Int) {
    precondition((1...Self.maximumFramesPerTurn).contains(maximumFramesPerTurn))
    precondition((1...Self.maximumRetainedInputBytes).contains(maximumRetainedInputBytes))
    self.maximumFramesPerTurn = maximumFramesPerTurn
    self.maximumRetainedInputBytes = maximumRetainedInputBytes
  }
}

protocol ViewerAdmissionSessionReceiving: AnyObject, Sendable {
  var ingressLimits: ViewerSessionIngressLimits { get }
  func beginIngressTurn(receiptNanoseconds: UInt64)
  func receiveSessionFrame(
    _ frame: WireFrame,
    receiptNanoseconds: UInt64
  ) throws -> WireFrameDeliveryDecision
  func decoderDidProgress(
    _ progress: WireFrameDecoderProgress,
    receiptNanoseconds: UInt64
  ) -> ViewerDecoderProgressDisposition
  func sessionMailboxMadeProgress(completed: ViewerSessionSendCompletionKind)
  func sessionTransportTerminated()
}

enum ViewerSessionSendCompletionKind: Equatable, Sendable {
  case ordinary
  case localDropSummary
}

enum ViewerDecoderProgressDisposition: Equatable, Sendable {
  case continueReceiving
  case terminalWithoutResume
}

protocol ViewerIncomingConnection: Sendable {
  func makeAdmissionChannel(
    queue: DispatchQueue,
    eventHandler: @escaping SecureByteChannel.EventHandler
  ) throws -> any ViewerAdmissionChannel
  func reject()
}

extension SecureViewerIncomingConnection: ViewerIncomingConnection {
  func makeAdmissionChannel(
    queue: DispatchQueue,
    eventHandler: @escaping SecureByteChannel.EventHandler
  ) throws -> any ViewerAdmissionChannel {
    try makeChannel(queue: queue, eventHandler: eventHandler)
  }
}

struct ViewerAdmissionScheduler: Sendable {
  static let live = ViewerAdmissionScheduler(
    now: { DispatchTime.now().uptimeNanoseconds },
    sleep: { nanoseconds in try await Task.sleep(nanoseconds: nanoseconds) }
  )

  let now: @Sendable () -> UInt64
  let sleep: @Sendable (UInt64) async throws -> Void

  func sleep(untilNanoseconds deadline: UInt64) async throws {
    while true {
      let current = now()
      guard current < deadline else { return }
      try await sleep(deadline - current)
    }
  }
}

enum ViewerCleanupOutcome: Equatable, Sendable {
  case completed
  case timedOut
}

final class ViewerCleanupReceipt: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private final class Race: @unchecked Sendable, CustomReflectable,
    CustomStringConvertible, CustomDebugStringConvertible
  {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ViewerCleanupOutcome, Never>?
    private var result: ViewerCleanupOutcome?

    func install(_ continuation: CheckedContinuation<ViewerCleanupOutcome, Never>) {
      lock.lock()
      if let result {
        lock.unlock()
        continuation.resume(returning: result)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }

    func resolve(_ result: ViewerCleanupOutcome) {
      lock.lock()
      guard self.result == nil else {
        lock.unlock()
        return
      }
      self.result = result
      let continuation = continuation
      self.continuation = nil
      lock.unlock()
      continuation?.resume(returning: result)
    }

    var description: String { "ViewerCleanupRace(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
  }

  private let cleanup: Task<Void, Never>

  init(cleanup: Task<Void, Never>) {
    self.cleanup = cleanup
  }

  func joining(_ other: Task<Void, Never>) -> ViewerCleanupReceipt {
    let cleanup = self.cleanup
    return ViewerCleanupReceipt(
      cleanup: Task {
        async let first: Void = cleanup.value
        async let second: Void = other.value
        _ = await (first, second)
      }
    )
  }

  func wait(
    timeoutNanoseconds: UInt64,
    scheduler: ViewerAdmissionScheduler = .live
  ) async -> ViewerCleanupOutcome {
    precondition(timeoutNanoseconds > 0)
    let race = Race()
    Task {
      await cleanup.value
      race.resolve(.completed)
    }
    Task {
      do {
        try await scheduler.sleep(timeoutNanoseconds)
        race.resolve(.timedOut)
      } catch {
        // Cancellation of the timeout waiter does not change cleanup ownership.
      }
    }
    return await withCheckedContinuation { continuation in
      race.install(continuation)
    }
  }

  var description: String { "ViewerCleanupReceipt(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

final class ViewerAdmissionBudget: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  struct Reservation: Hashable, Sendable {
    fileprivate let id: UUID
  }

  let capacity: Int
  private let lock = NSLock()
  private var reservations: Set<Reservation> = []

  init(capacity: Int = 32) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  func reserve() -> Reservation? {
    lock.lock()
    defer { lock.unlock() }
    guard reservations.count < capacity else { return nil }
    let reservation = Reservation(id: UUID())
    reservations.insert(reservation)
    return reservation
  }

  @discardableResult
  func release(_ reservation: Reservation) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return reservations.remove(reservation) != nil
  }

  var occupiedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reservations.count
  }

  var description: String { "ViewerAdmissionBudget(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

final class ViewerAdmissionHandle: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  let connectionCore: ViewerAdmissionConnectionCore
  private let cleanup: ViewerAdmissionAttemptCleanup
  private let lock = NSLock()
  private var consumed = false

  fileprivate init(
    connectionCore: ViewerAdmissionConnectionCore,
    cleanup: ViewerAdmissionAttemptCleanup
  ) {
    self.connectionCore = connectionCore
    self.cleanup = cleanup
  }

  func cancel() {
    guard let core = consume() else { return }
    core.requestCancellation()
  }

  func cancelAndWait() async {
    if let core = consume() {
      await core.cancelAndWait()
    } else {
      await connectionCore.waitForCleanup()
    }
    await cleanup.waitForCompletion()
  }

  private func consume() -> ViewerAdmissionConnectionCore? {
    lock.lock()
    guard !consumed else {
      lock.unlock()
      return nil
    }
    consumed = true
    lock.unlock()
    return connectionCore
  }

  deinit { cancel() }

  var description: String { "ViewerAdmissionHandle(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

final class ViewerAdmissionConnectionCore: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  enum CoreError: Error {
    case invalidState
    case invalidPeer
  }

  private enum State {
    case awaitingReady
    case awaitingHello
    case awaitingConsumer
    case sessionAttached
    case terminal
  }

  private enum CleanupState {
    case open
    case cancelling
    case complete
  }

  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UUID>()
  private let queueValue = UUID()
  private let connectionID: UUID
  private let viewerHelloFrame: Data
  private let viewerHello: WireHello
  private let nowNanoseconds: @Sendable () -> UInt64
  private let onHello: @Sendable (ViewerPendingAppSummary) -> Void
  private let onTerminal: @Sendable () -> Void
  private var channel: (any ViewerAdmissionChannel)?
  private var decoder = WireFrameDecoder()
  private let codec = WirePreHandshakeCodec()
  private var negotiatedResult: WireNegotiationResult?
  private var appHello: WireHello?
  private weak var sessionReceiver: (any ViewerAdmissionSessionReceiving)?
  private var receivePauseToken: SecureReceivePauseToken?
  private var retainedReceiptNanoseconds: UInt64?
  private var continuationScheduled = false
  private var state: State = .awaitingReady
  private var cleanupState: CleanupState = .open
  private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
  private var startRequested = false
  private var terminalNotified = false
  private var sendCompletionKinds: [ViewerSessionSendCompletionKind] = []

  init(
    id: UUID,
    viewerInstallationID: EndpointID,
    nowNanoseconds: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    },
    onHello: @escaping @Sendable (ViewerPendingAppSummary) -> Void,
    onTerminal: @escaping @Sendable () -> Void
  ) throws {
    connectionID = id
    queue = DispatchQueue(label: "com.nearwire.viewer.admission.\(id.uuidString)")
    viewerHello = try WireHello(
      productVersion: WireProductVersion("0.1.0"),
      role: .viewer,
      installationID: viewerInstallationID
    )
    viewerHelloFrame = try WirePreHandshakeCodec().encode(viewerHello)
    self.nowNanoseconds = nowNanoseconds
    self.onHello = onHello
    self.onTerminal = onTerminal
    queue.setSpecific(key: queueKey, value: queueValue)
  }

  func attach(_ channel: any ViewerAdmissionChannel) throws {
    let attached = queue.sync {
      guard self.channel == nil, state == .awaitingReady, cleanupState == .open else {
        return false
      }
      self.channel = channel
      return true
    }
    guard attached else { throw CoreError.invalidState }
  }

  func receive(_ event: SecureByteChannelEvent) {
    if DispatchQueue.getSpecific(key: queueKey) == queueValue {
      handle(event)
    } else {
      queue.sync { handle(event) }
    }
  }

  func pendingSessionContext() throws -> ViewerAdmissionSessionContext {
    try performSync {
      guard state == .awaitingConsumer, cleanupState == .open,
        let appHello, let negotiatedResult, let channel
      else { throw CoreError.invalidState }
      return ViewerAdmissionSessionContext(
        connectionID: connectionID,
        appHello: appHello,
        viewerHello: viewerHello,
        negotiation: negotiatedResult,
        receiveChunkBytes: channel.receiveChunkBytes
      )
    }
  }

  func attachSession(_ receiver: any ViewerAdmissionSessionReceiving) throws {
    try performSync {
      guard state == .awaitingConsumer, cleanupState == .open,
        sessionReceiver == nil, appHello != nil, negotiatedResult != nil
      else { throw CoreError.invalidState }
      sessionReceiver = receiver
      state = .sessionAttached
    }
  }

  func continueAttachedInput() {
    queue.async { [weak self] in
      guard let self, self.state == .sessionAttached, self.cleanupState == .open,
        self.receivePauseToken != nil
      else { return }
      if self.retainedReceiptNanoseconds != nil {
        self.scheduleInputContinuation()
      } else {
        self.resolveReceivePause(resume: true)
      }
    }
  }

  func performSessionOperation(_ operation: @escaping @Sendable () -> Void) {
    queue.async { [weak self] in
      guard let self, self.state == .sessionAttached, self.cleanupState == .open else { return }
      operation()
    }
  }

  func performSynchronousSessionOperation<T>(_ operation: () throws -> T) throws -> T {
    try performSync {
      guard state == .sessionAttached, cleanupState == .open else {
        throw CoreError.invalidState
      }
      return try operation()
    }
  }

  func closeSession() {
    queue.async { [weak self] in self?.beginCancellation() }
  }

  func admitSessionSend(
    _ data: Data,
    reservingPendingSendCount: Int = 0,
    reservingPendingSendBytes: Int = 0,
    completionKind: ViewerSessionSendCompletionKind = .ordinary
  ) throws {
    try performSync {
      guard state == .sessionAttached, cleanupState == .open, let channel else {
        throw CoreError.invalidState
      }
      try channel.admitSend(
        data,
        reservingPendingSendCount: reservingPendingSendCount,
        reservingPendingSendBytes: reservingPendingSendBytes
      )
      sendCompletionKinds.append(completionKind)
    }
  }

  func canAdmitSessionSend(
    byteCount: Int,
    reservingPendingSendCount: Int,
    reservingPendingSendBytes: Int
  ) -> Bool {
    performSync {
      guard state == .sessionAttached, cleanupState == .open, let channel else { return false }
      return channel.canAdmitSend(
        byteCount: byteCount,
        reservingPendingSendCount: reservingPendingSendCount,
        reservingPendingSendBytes: reservingPendingSendBytes
      )
    }
  }

  func start() {
    queue.async { [weak self] in
      guard let self else { return }
      guard !self.startRequested else { return }
      guard let channel = self.channel, self.state == .awaitingReady,
        self.cleanupState == .open
      else {
        self.beginCancellation()
        return
      }
      self.startRequested = true
      Task {
        do {
          try await channel.start()
        } catch {
          await self.cancelAndWait()
        }
      }
    }
  }

  func requestCancellation() {
    queue.async { [self] in beginCancellation() }
  }

  func cancelAndWait() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        if cleanupState == .complete {
          continuation.resume()
          return
        }
        cleanupWaiters.append(continuation)
        beginCancellation()
      }
    }
  }

  func waitForCleanup() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        if cleanupState == .complete {
          continuation.resume()
        } else {
          cleanupWaiters.append(continuation)
        }
      }
    }
  }

  private func handle(_ event: SecureByteChannelEvent) {
    guard state != .terminal, cleanupState == .open else { return }
    switch event {
    case .stateChanged(let transportState):
      if transportState == .ready {
        guard state == .awaitingReady, let channel else { return }
        do {
          try channel.admitSend(viewerHelloFrame)
          sendCompletionKinds.append(.ordinary)
          state = .awaitingHello
        } catch {
          beginCancellation()
        }
      } else if transportState == .failed || transportState == .cancelled {
        finishWithoutCancellation()
      }
    case .received(let bytes):
      handleReceivedBytes(bytes)
    case .terminated:
      finishWithoutCancellation()
    case .sendCompleted:
      let completed = sendCompletionKinds.isEmpty ? .ordinary : sendCompletionKinds.removeFirst()
      sessionReceiver?.sessionMailboxMadeProgress(completed: completed)
    }
  }

  private func handleReceivedBytes(_ bytes: Data) {
    guard state == .awaitingHello || state == .sessionAttached else {
      beginCancellation()
      return
    }
    let receipt = nowNanoseconds()
    serviceInput(bytes, receiptNanoseconds: receipt, isContinuation: false)
  }

  private func serviceInput(
    _ bytes: Data,
    receiptNanoseconds: UInt64,
    isContinuation: Bool
  ) {
    guard cleanupState == .open, state == .awaitingHello || state == .sessionAttached else {
      resolveReceivePause(resume: false)
      return
    }
    let limits = sessionReceiver?.ingressLimits ?? .default
    let maximumCompletedFrames = state == .awaitingHello ? 1 : limits.maximumFramesPerTurn
    guard bytes.count <= limits.maximumRetainedInputBytes else {
      beginCancellation()
      return
    }
    let decoderLimit = limits.maximumRetainedInputBytes - bytes.count
    guard decoderLimit > 0 else {
      beginCancellation()
      return
    }
    sessionReceiver?.beginIngressTurn(receiptNanoseconds: receiptNanoseconds)
    do {
      let progress = try decoder.consumeResumable(
        bytes,
        maximumCompletedFrames: maximumCompletedFrames,
        maximumRetainedBytes: decoderLimit,
        preflightLane: { [self] lane in
          if state != .sessionAttached, lane != .control { throw CoreError.invalidPeer }
        },
        onFrame: { [self] frame in
          switch state {
          case .awaitingHello:
            guard case .hello(let hello) = try codec.decode(frame: frame), hello.role == .app else {
              throw CoreError.invalidPeer
            }
            appHello = hello
            negotiatedResult = try WireNegotiator.negotiate(local: viewerHello, remote: hello)
            state = .awaitingConsumer
            onHello(Self.summary(from: hello))
            return .consume
          case .sessionAttached:
            guard let sessionReceiver else { throw CoreError.invalidState }
            return try sessionReceiver.receiveSessionFrame(
              frame,
              receiptNanoseconds: receiptNanoseconds
            )
          default:
            throw CoreError.invalidState
          }
        }
      )
      let disposition =
        sessionReceiver?.decoderDidProgress(
          progress,
          receiptNanoseconds: receiptNanoseconds
        ) ?? .continueReceiving
      if disposition == .terminalWithoutResume {
        beginCancellation()
        return
      }
      applyDecoderProgress(
        progress,
        receiptNanoseconds: receiptNanoseconds,
        isContinuation: isContinuation
      )
    } catch {
      beginCancellation()
    }
  }

  private func applyDecoderProgress(
    _ progress: WireFrameDecoderProgress,
    receiptNanoseconds: UInt64,
    isContinuation: Bool
  ) {
    if state == .awaitingConsumer {
      retainedReceiptNanoseconds =
        progress == .pausedOnCompleteFrame ? receiptNanoseconds : nil
      if receivePauseToken == nil {
        guard let token = channel?.claimReceivePause() else {
          beginCancellation()
          return
        }
        receivePauseToken = token
      }
      return
    }
    switch progress {
    case .pausedOnCompleteFrame:
      retainedReceiptNanoseconds = receiptNanoseconds
      if !isContinuation {
        guard let token = channel?.claimReceivePause() else {
          beginCancellation()
          return
        }
        receivePauseToken = token
      } else if receivePauseToken == nil {
        beginCancellation()
        return
      }
      scheduleInputContinuation()
    case .needsMoreBytes, .drained:
      retainedReceiptNanoseconds = nil
      resolveReceivePause(resume: true)
    }
  }

  private func scheduleInputContinuation() {
    guard !continuationScheduled else { return }
    continuationScheduled = true
    queue.async { [weak self] in
      guard let self else { return }
      self.continuationScheduled = false
      guard self.cleanupState == .open, self.receivePauseToken != nil else {
        self.resolveReceivePause(resume: false)
        return
      }
      guard self.state != .awaitingConsumer else { return }
      guard let receipt = self.retainedReceiptNanoseconds,
        self.state == .sessionAttached
      else {
        self.resolveReceivePause(resume: false)
        return
      }
      self.serviceInput(Data(), receiptNanoseconds: receipt, isContinuation: true)
    }
  }

  private func resolveReceivePause(resume: Bool) {
    continuationScheduled = false
    retainedReceiptNanoseconds = nil
    let token = receivePauseToken
    receivePauseToken = nil
    if resume {
      token?.resume()
    } else {
      token?.cancel()
    }
  }

  private func beginCancellation() {
    guard cleanupState == .open else { return }
    cleanupState = .cancelling
    let channel = channel
    finishTerminalState()
    Task { [self] in
      await channel?.cancel()
      queue.async { [self] in completeCleanup() }
    }
  }

  private func finishWithoutCancellation() {
    guard cleanupState == .open else { return }
    finishTerminalState()
    completeCleanup()
  }

  private func finishTerminalState() {
    let sessionReceiver = sessionReceiver
    self.sessionReceiver = nil
    resolveReceivePause(resume: false)
    decoder = WireFrameDecoder()
    sendCompletionKinds.removeAll(keepingCapacity: false)
    state = .terminal
    channel = nil
    sessionReceiver?.sessionTransportTerminated()
    guard !terminalNotified else { return }
    terminalNotified = true
    onTerminal()
  }

  private func completeCleanup() {
    guard cleanupState != .complete else { return }
    cleanupState = .complete
    let waiters = cleanupWaiters
    cleanupWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private static func summary(from hello: WireHello) -> ViewerPendingAppSummary {
    let digest = SHA256.hash(data: Data(hello.installationID.rawValue.utf8))
    let alias = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    return ViewerPendingAppSummary(
      id: UUID(),
      displayName: hello.displayName ?? hello.applicationIdentifier ?? "Unnamed App",
      applicationIdentifier: hello.applicationIdentifier,
      applicationVersion: hello.applicationVersion,
      installationAlias: "App \(alias)",
      compatibilityStatus: "Compatible"
    )
  }

  private func performSync<T>(_ operation: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) == queueValue {
      return try operation()
    }
    return try queue.sync(execute: operation)
  }

  var description: String { "ViewerAdmissionConnectionCore(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

private final class ViewerAdmissionWeakIngress: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let lock = NSLock()
  private weak var core: ViewerAdmissionConnectionCore?

  func install(_ core: ViewerAdmissionConnectionCore) {
    lock.lock()
    self.core = core
    lock.unlock()
  }

  func receive(_ event: SecureByteChannelEvent) {
    lock.lock()
    let core = core
    lock.unlock()
    core?.receive(event)
  }

  var description: String { "ViewerAdmissionWeakIngress(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

private final class ViewerAdmissionCleanupRegistry: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let lock = NSLock()
  private var owners: [UUID: ViewerAdmissionAttemptCleanup] = [:]
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func register(_ owner: ViewerAdmissionAttemptCleanup, id: UUID) {
    lock.lock()
    precondition(owners[id] == nil)
    owners[id] = owner
    lock.unlock()
  }

  func complete(id: UUID) {
    lock.lock()
    guard owners.removeValue(forKey: id) != nil else {
      lock.unlock()
      return
    }
    let waiters = owners.isEmpty ? self.waiters : []
    if owners.isEmpty { self.waiters.removeAll() }
    lock.unlock()
    for waiter in waiters { waiter.resume() }
  }

  func waitForEmpty() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if owners.isEmpty {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  var description: String { "ViewerAdmissionCleanupRegistry(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

private final class ViewerAdmissionAttemptCleanup: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let lock = NSLock()
  private let onComplete: @Sendable () -> Void
  private var claimFinished = false
  private var coreFinished = false
  private var coreCleanupStarted = false
  private var directChannelCleanups = 0
  private var completionPublished = false
  private var completionFinished = false
  private var completionWaiters: [CheckedContinuation<Void, Never>] = []

  init(onComplete: @escaping @Sendable () -> Void) {
    self.onComplete = onComplete
  }

  func finishClaim() {
    lock.lock()
    claimFinished = true
    let completes = takeCompletionLocked()
    lock.unlock()
    if completes { publishCompletion() }
  }

  func beginCoreCleanup(
    _ core: ViewerAdmissionConnectionCore,
    cancel: Bool
  ) {
    lock.lock()
    guard !coreCleanupStarted else {
      lock.unlock()
      return
    }
    coreCleanupStarted = true
    lock.unlock()
    Task { [self] in
      if cancel {
        await core.cancelAndWait()
      } else {
        await core.waitForCleanup()
      }
      finishCoreCleanup()
    }
  }

  func beginDirectChannelCleanup(_ channel: any ViewerAdmissionChannel) {
    lock.lock()
    directChannelCleanups += 1
    lock.unlock()
    Task { [self] in
      await channel.cancel()
      finishDirectChannelCleanup()
    }
  }

  private func finishCoreCleanup() {
    lock.lock()
    coreFinished = true
    let completes = takeCompletionLocked()
    lock.unlock()
    if completes { publishCompletion() }
  }

  private func finishDirectChannelCleanup() {
    lock.lock()
    precondition(directChannelCleanups > 0)
    directChannelCleanups -= 1
    let completes = takeCompletionLocked()
    lock.unlock()
    if completes { publishCompletion() }
  }

  func waitForCompletion() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if completionFinished {
        lock.unlock()
        continuation.resume()
      } else {
        completionWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

  private func publishCompletion() {
    onComplete()
    lock.lock()
    completionFinished = true
    let waiters = completionWaiters
    completionWaiters.removeAll()
    lock.unlock()
    for waiter in waiters { waiter.resume() }
  }

  private func takeCompletionLocked() -> Bool {
    guard !completionPublished, claimFinished, coreFinished, directChannelCleanups == 0 else {
      return false
    }
    completionPublished = true
    return true
  }

  var description: String { "ViewerAdmissionAttemptCleanup(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

protocol ViewerAdmissionHandoffOwning: AnyObject, Sendable {
  func transfer(_ handle: ViewerAdmissionHandle) -> Bool
  func beginShutdown() -> Task<Void, Never>
}

final class ViewerPlaceholderHandoffOwner: ViewerAdmissionHandoffOwning, @unchecked Sendable,
  CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible
{
  private let lock = NSLock()
  private var shuttingDown = false
  private var active: Set<UUID> = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var shutdownTask: Task<Void, Never>?

  func transfer(_ handle: ViewerAdmissionHandle) -> Bool {
    let id = UUID()
    lock.lock()
    guard !shuttingDown else {
      lock.unlock()
      return false
    }
    active.insert(id)
    lock.unlock()
    Task { [self] in
      await handle.cancelAndWait()
      complete(id: id)
    }
    return true
  }

  func beginShutdown() -> Task<Void, Never> {
    lock.lock()
    if let shutdownTask {
      lock.unlock()
      return shutdownTask
    }
    shuttingDown = true
    let task = Task { [self] in await waitForEmpty() }
    shutdownTask = task
    lock.unlock()
    return task
  }

  private func complete(id: UUID) {
    lock.lock()
    guard active.remove(id) != nil else {
      lock.unlock()
      return
    }
    let waiters = active.isEmpty ? self.waiters : []
    if active.isEmpty { self.waiters.removeAll() }
    lock.unlock()
    for waiter in waiters { waiter.resume() }
  }

  private func waitForEmpty() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if active.isEmpty {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  var description: String { "ViewerPlaceholderHandoffOwner(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

final class ViewerAdmissionManager: @unchecked Sendable, CustomReflectable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  typealias PendingHandler = @Sendable ([ViewerPendingAppSummary]) -> Void

  private final class Attempt: @unchecked Sendable, CustomReflectable,
    CustomStringConvertible, CustomDebugStringConvertible
  {
    let id: UUID
    let generation: UUID
    let reservation: ViewerAdmissionBudget.Reservation
    let core: ViewerAdmissionConnectionCore
    let cleanup: ViewerAdmissionAttemptCleanup
    var summary: ViewerPendingAppSummary?
    var deadline: Task<Void, Never>?

    init(
      id: UUID,
      generation: UUID,
      reservation: ViewerAdmissionBudget.Reservation,
      core: ViewerAdmissionConnectionCore,
      cleanup: ViewerAdmissionAttemptCleanup
    ) {
      self.id = id
      self.generation = generation
      self.reservation = reservation
      self.core = core
      self.cleanup = cleanup
    }

    var description: String { "ViewerAdmissionAttempt(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
  }

  static let maximumAttempts = 32
  static let deadlineNanoseconds: UInt64 = 10_000_000_000
  static let cleanupTimeoutNanoseconds: UInt64 = 1_000_000_000

  private let lock = NSLock()
  private let budget: ViewerAdmissionBudget
  private let channelQueue = DispatchQueue(label: "com.nearwire.viewer.admission.channels")
  private let onPending: PendingHandler
  private let handoffOwner: any ViewerAdmissionHandoffOwning
  private let cleanupRegistry = ViewerAdmissionCleanupRegistry()
  private let deadlineNanoseconds: UInt64
  private let scheduler: ViewerAdmissionScheduler
  private var attempts: [UUID: Attempt] = [:]
  private var activeGenerations: Set<UUID> = []
  private var requiresApproval = false
  private var paused = false
  private var shutdown = false
  private var stopReceipt: ViewerCleanupReceipt?

  init(
    budget: ViewerAdmissionBudget = ViewerAdmissionBudget(capacity: maximumAttempts),
    onPending: @escaping PendingHandler,
    handoffOwner: any ViewerAdmissionHandoffOwning = ViewerPlaceholderHandoffOwner(),
    deadlineNanoseconds: UInt64 = ViewerAdmissionManager.deadlineNanoseconds,
    scheduler: ViewerAdmissionScheduler = .live
  ) {
    precondition(deadlineNanoseconds > 0)
    self.budget = budget
    self.onPending = onPending
    self.handoffOwner = handoffOwner
    self.deadlineNanoseconds = deadlineNanoseconds
    self.scheduler = scheduler
  }

  deinit {
    _ = stop()
  }

  func setRequiresApproval(_ required: Bool) {
    lock.lock()
    requiresApproval = required
    lock.unlock()
  }

  func activateGeneration(_ generation: UUID) {
    lock.lock()
    guard !shutdown else {
      lock.unlock()
      return
    }
    activeGenerations.insert(generation)
    lock.unlock()
  }

  func admit(
    _ incoming: any ViewerIncomingConnection,
    generation: UUID,
    viewerInstallationID: EndpointID
  ) {
    let attemptID = UUID()
    let attempt: Attempt
    lock.lock()
    guard !shutdown, !paused, activeGenerations.contains(generation),
      let reservation = budget.reserve()
    else {
      lock.unlock()
      incoming.reject()
      return
    }
    do {
      let core = try ViewerAdmissionConnectionCore(
        id: attemptID,
        viewerInstallationID: viewerInstallationID,
        nowNanoseconds: scheduler.now,
        onHello: { [weak self] summary in self?.receivedHello(summary, attemptID: attemptID) },
        onTerminal: { [weak self] in self?.terminal(attemptID: attemptID) }
      )
      let cleanupRegistry = self.cleanupRegistry
      let budget = self.budget
      let cleanup = ViewerAdmissionAttemptCleanup { [weak cleanupRegistry] in
        _ = budget.release(reservation)
        cleanupRegistry?.complete(id: attemptID)
      }
      attempt = Attempt(
        id: attemptID,
        generation: generation,
        reservation: reservation,
        core: core,
        cleanup: cleanup
      )
      cleanupRegistry.register(cleanup, id: attemptID)
      attempts[attemptID] = attempt
    } catch {
      _ = budget.release(reservation)
      lock.unlock()
      incoming.reject()
      return
    }
    lock.unlock()
    defer { attempt.cleanup.finishClaim() }

    let ingress = ViewerAdmissionWeakIngress()
    ingress.install(attempt.core)
    var claimedChannel: (any ViewerAdmissionChannel)?
    do {
      let claimedAt = scheduler.now()
      let channel = try incoming.makeAdmissionChannel(
        queue: channelQueue,
        eventHandler: { event in ingress.receive(event) }
      )
      claimedChannel = channel
      try attempt.core.attach(channel)

      lock.lock()
      guard attempts[attemptID] === attempt, !shutdown, !paused,
        activeGenerations.contains(generation)
      else {
        lock.unlock()
        attempt.cleanup.beginCoreCleanup(attempt.core, cancel: true)
        return
      }
      let (candidateDeadline, overflow) = claimedAt.addingReportingOverflow(deadlineNanoseconds)
      let absoluteDeadline = overflow ? UInt64.max : candidateDeadline
      let deadline = Task { [weak self, scheduler] in
        do {
          try await scheduler.sleep(untilNanoseconds: absoluteDeadline)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        self?.timeout(attemptID: attemptID)
      }
      attempt.deadline = deadline
      lock.unlock()
      attempt.core.start()
    } catch {
      let removed = removeAttempt(id: attemptID)
      if let removed { finish([removed]) }
      if claimedChannel != nil {
        if let claimedChannel { attempt.cleanup.beginDirectChannelCleanup(claimedChannel) }
      } else {
        incoming.reject()
      }
    }
  }

  func accept(_ summaryID: UUID) {
    complete(summaryID: summaryID, handoff: true)
  }

  func reject(_ summaryID: UUID) {
    complete(summaryID: summaryID, handoff: false)
  }

  func setPaused(_ value: Bool) {
    lock.lock()
    guard paused != value else {
      lock.unlock()
      return
    }
    paused = value
    let cancelled = value ? removeAttempts(where: { _ in true }) : []
    let pending = pendingSummariesLocked()
    lock.unlock()
    finish(cancelled)
    onPending(pending)
  }

  func cancelGeneration(_ generation: UUID) {
    lock.lock()
    activeGenerations.remove(generation)
    let cancelled = removeAttempts(where: { $0.generation == generation })
    let pending = pendingSummariesLocked()
    lock.unlock()
    finish(cancelled)
    onPending(pending)
  }

  @discardableResult
  func stop() -> ViewerCleanupReceipt {
    lock.lock()
    if let stopReceipt {
      lock.unlock()
      return stopReceipt
    }
    shutdown = true
    activeGenerations.removeAll()
    let cancelled = removeAttempts(where: { _ in true })
    let handoffShutdown = handoffOwner.beginShutdown()
    let cleanupRegistry = self.cleanupRegistry
    let cleanup = Task {
      async let attempts: Void = cleanupRegistry.waitForEmpty()
      async let handoffs: Void = handoffShutdown.value
      _ = await (attempts, handoffs)
    }
    let receipt = ViewerCleanupReceipt(cleanup: cleanup)
    stopReceipt = receipt
    lock.unlock()

    finish(cancelled)
    onPending([])
    return receipt
  }

  var occupiedCount: Int { budget.occupiedCount }

  private func receivedHello(_ summary: ViewerPendingAppSummary, attemptID: UUID) {
    lock.lock()
    guard let attempt = attempts[attemptID] else {
      lock.unlock()
      return
    }
    if requiresApproval {
      attempt.summary = summary
      let pending = pendingSummariesLocked()
      lock.unlock()
      onPending(pending)
      return
    }
    attempts.removeValue(forKey: attemptID)
    lock.unlock()
    transfer(attempt)
  }

  private func terminal(attemptID: UUID) {
    lock.lock()
    guard let attempt = attempts.removeValue(forKey: attemptID) else {
      lock.unlock()
      return
    }
    let pending = pendingSummariesLocked()
    lock.unlock()
    finish([attempt], cancelCore: false)
    onPending(pending)
  }

  private func timeout(attemptID: UUID) {
    lock.lock()
    guard let attempt = attempts.removeValue(forKey: attemptID) else {
      lock.unlock()
      return
    }
    let pending = pendingSummariesLocked()
    lock.unlock()
    finish([attempt])
    onPending(pending)
  }

  private func complete(summaryID: UUID, handoff: Bool) {
    lock.lock()
    guard let entry = attempts.first(where: { $0.value.summary?.id == summaryID }) else {
      lock.unlock()
      return
    }
    attempts.removeValue(forKey: entry.key)
    let pending = pendingSummariesLocked()
    lock.unlock()
    if handoff {
      transfer(entry.value)
    } else {
      finish([entry.value])
    }
    onPending(pending)
  }

  private func removeAttempt(id: UUID) -> Attempt? {
    lock.lock()
    let attempt = attempts.removeValue(forKey: id)
    lock.unlock()
    return attempt
  }

  private func removeAttempts(where predicate: (Attempt) -> Bool) -> [Attempt] {
    let removed = attempts.filter { predicate($0.value) }
    for key in removed.keys { attempts.removeValue(forKey: key) }
    return Array(removed.values)
  }

  private func pendingSummariesLocked() -> [ViewerPendingAppSummary] {
    attempts.values.compactMap(\.summary).sorted { $0.displayName < $1.displayName }
  }

  private func finish(
    _ attempts: [Attempt],
    cancelCore: Bool = true
  ) {
    for attempt in attempts {
      attempt.deadline?.cancel()
      attempt.cleanup.beginCoreCleanup(attempt.core, cancel: cancelCore)
    }
  }

  private func transfer(_ attempt: Attempt) {
    attempt.deadline?.cancel()
    let handle = ViewerAdmissionHandle(
      connectionCore: attempt.core,
      cleanup: attempt.cleanup
    )
    if handoffOwner.transfer(handle) {
      attempt.cleanup.beginCoreCleanup(attempt.core, cancel: false)
    } else {
      attempt.cleanup.beginCoreCleanup(attempt.core, cancel: true)
    }
  }

  var description: String { "ViewerAdmissionManager(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

extension ViewerAdmissionBudget.Reservation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerAdmissionReservation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}
