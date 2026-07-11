import Foundation
import Network

@_spi(NearWireInternal) public enum SecureByteChannelEvent: Sendable {
  case stateChanged(SecureTransportState)
  case received(Data)
  case sendCompleted(byteCount: Int)
  case terminated(SecureTransportError)
}

enum SecureDriverState: Sendable {
  case preparing
  case ready
  case failed
  case cancelled
}

protocol SecureConnectionDriving: AnyObject, Sendable {
  func start(stateHandler: @escaping @Sendable (SecureDriverState) -> Void)
  func receive(
    maximumLength: Int,
    completion: @escaping @Sendable (Data?, Bool, Bool) -> Void
  )
  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void)
  func cancel()
}

@_spi(NearWireInternal) public actor SecureByteChannel {
  public typealias EventHandler = @Sendable (SecureByteChannelEvent) -> Void

  public private(set) var state: SecureTransportState = .setup
  public let limits: SecureTransportLimits

  var retainedSendPayloadBytes: Int {
    sendMailbox.retainedPayloadBytes
  }

  private let driver: any SecureConnectionDriving
  private let eventHandler: EventHandler
  private nonisolated let callbackIngress = SecureCallbackIngress()
  private nonisolated let sendMailbox: SecureSendMailbox
  private var activeReceiveToken: UInt64?
  private var nextReceiveToken: UInt64 = 0
  private var generation: UInt64 = 0
  private var didCancelDriver = false

  fileprivate init(
    connection: NWConnection,
    queue: DispatchQueue,
    limits: SecureTransportLimits = .default,
    eventHandler: @escaping EventHandler
  ) {
    driver = NWConnectionDriver(connection: connection, queue: queue)
    self.limits = limits
    self.eventHandler = eventHandler
    sendMailbox = SecureSendMailbox(limits: limits)
  }

  init(
    driver: any SecureConnectionDriving,
    limits: SecureTransportLimits = .default,
    eventHandler: @escaping EventHandler
  ) {
    self.driver = driver
    self.limits = limits
    self.eventHandler = eventHandler
    sendMailbox = SecureSendMailbox(limits: limits)
  }

  public func start() throws {
    guard state == .setup else {
      throw SecureTransportError(
        code: .alreadyStarted,
        path: "state",
        message: "Secure byte channel can start only once."
      )
    }
    generation += 1
    let callbackGeneration = generation
    transition(to: .preparing)
    driver.start { [weak self] driverState in
      guard let self else { return }
      callbackIngress.submit {
        await self.handleDriverState(driverState, generation: callbackGeneration)
      }
    }
  }

  public func send(_ data: Data) throws {
    guard state == .preparing || state == .ready else {
      throw SecureTransportError(
        code: .invalidState,
        path: "state",
        message: "Channel accepts sends only while preparing or ready."
      )
    }
    try sendMailbox.admit(data)
    beginNextSendIfPossible()
  }

  /// Synchronously admits bytes into the channel's bounded mailbox.
  ///
  /// Success means the channel owns the bytes. It does not mean the peer received them.
  public nonisolated func admitSend(_ data: Data) throws {
    try sendMailbox.admit(data)
    callbackIngress.submit { [weak self] in
      await self?.beginNextSendIfPossible()
    }
  }

  public func cancel() {
    guard !isTerminal else { return }
    transition(to: .closing)
    finish(
      state: .cancelled,
      error: SecureTransportError(
        code: .cancelled,
        path: "state",
        message: "Secure byte channel was cancelled.",
        disposition: .connectionTerminal
      )
    )
  }

  private var isTerminal: Bool {
    state == .failed || state == .cancelled
  }

  private func handleDriverState(
    _ driverState: SecureDriverState,
    generation callbackGeneration: UInt64
  ) {
    guard callbackGeneration == generation, !isTerminal else { return }
    switch driverState {
    case .preparing:
      if state == .setup { transition(to: .preparing) }
    case .ready:
      if state == .ready { return }
      guard state == .preparing else {
        fail(
          code: .invalidState, path: "driver.state", message: "Driver became ready out of order.")
        return
      }
      transition(to: .ready)
      beginNextSendIfPossible()
      requestReceiveIfPossible()
    case .failed:
      fail(code: .driverFailure, path: "driver.state", message: "Network driver failed.")
    case .cancelled:
      finish(
        state: .cancelled,
        error: SecureTransportError(
          code: .cancelled,
          path: "driver.state",
          message: "Network driver cancelled the channel.",
          disposition: .connectionTerminal
        )
      )
    }
  }

  private func requestReceiveIfPossible() {
    guard state == .ready, activeReceiveToken == nil else { return }
    guard nextReceiveToken != UInt64.max else {
      fail(
        code: .arithmeticOverflow,
        path: "receiveToken",
        message: "Receive token space is exhausted."
      )
      return
    }
    let receiveToken = nextReceiveToken
    nextReceiveToken += 1
    activeReceiveToken = receiveToken
    let callbackGeneration = generation
    driver.receive(maximumLength: limits.receiveChunkBytes) {
      [weak self] data, isComplete, failed in
      guard let self else { return }
      callbackIngress.submit {
        await self.handleReceive(
          data: data,
          isComplete: isComplete,
          failed: failed,
          token: receiveToken,
          generation: callbackGeneration
        )
      }
    }
  }

  private func handleReceive(
    data: Data?,
    isComplete: Bool,
    failed: Bool,
    token: UInt64,
    generation callbackGeneration: UInt64
  ) {
    guard callbackGeneration == generation, !isTerminal,
      activeReceiveToken == token
    else {
      return
    }
    activeReceiveToken = nil
    if failed {
      fail(code: .driverFailure, path: "receive", message: "Network receive failed.")
      return
    }
    if let data, !data.isEmpty {
      guard data.count <= limits.receiveChunkBytes else {
        fail(code: .invalidDelivery, path: "receive", message: "Driver exceeded receive bound.")
        return
      }
      eventHandler(.received(data))
    } else if !isComplete {
      fail(code: .invalidDelivery, path: "receive", message: "Driver returned no receive progress.")
      return
    }
    if isComplete {
      fail(code: .endOfStream, path: "receive", message: "Secure byte stream ended.")
      return
    }
    requestReceiveIfPossible()
  }

  private func beginNextSendIfPossible() {
    guard state == .ready, let item = sendMailbox.takeNextIfAvailable() else { return }
    let callbackGeneration = generation
    driver.send(item.data) { [weak self] failed in
      guard let self else { return }
      callbackIngress.submit {
        await self.handleSendCompletion(
          token: item.token,
          byteCount: item.data.count,
          failed: failed,
          generation: callbackGeneration
        )
      }
    }
  }

  private func handleSendCompletion(
    token: UInt64,
    byteCount: Int,
    failed: Bool,
    generation callbackGeneration: UInt64
  ) {
    guard callbackGeneration == generation, !isTerminal,
      sendMailbox.inFlightToken == token
    else {
      return
    }
    if failed {
      fail(code: .driverFailure, path: "send", message: "Network send failed.")
      return
    }
    guard sendMailbox.complete(token: token, byteCount: byteCount) else {
      fail(
        code: .invalidState,
        path: "pendingSends",
        message: "Send completion did not match the bounded mailbox."
      )
      return
    }
    eventHandler(.sendCompleted(byteCount: byteCount))
    beginNextSendIfPossible()
  }

  private func transition(to newState: SecureTransportState) {
    state = newState
    sendMailbox.setAccepting(newState == .preparing || newState == .ready)
    eventHandler(.stateChanged(newState))
  }

  private func fail(code: SecureTransportError.Code, path: String, message: String) {
    finish(
      state: .failed,
      error: SecureTransportError(
        code: code,
        path: path,
        message: message,
        disposition: .connectionTerminal
      )
    )
  }

  private func finish(state terminalState: SecureTransportState, error: SecureTransportError) {
    guard !isTerminal else { return }
    generation += 1
    activeReceiveToken = nil
    sendMailbox.setAccepting(false)
    sendMailbox.clear()
    transition(to: terminalState)
    if !didCancelDriver {
      didCancelDriver = true
      driver.cancel()
    }
    eventHandler(.terminated(error))
  }

}

private final class SecureSendMailbox: @unchecked Sendable {
  struct Item: Sendable {
    let token: UInt64
    let data: Data
  }

  private let lock = NSLock()
  private let limits: SecureTransportLimits
  private var accepting = false
  private var pending: [Item?] = []
  private var head = 0
  private var inFlight: Item?
  private var retainedBytes = 0
  private var nextToken: UInt64 = 0

  init(limits: SecureTransportLimits) {
    self.limits = limits
  }

  var retainedPayloadBytes: Int {
    lock.lock()
    defer { lock.unlock() }
    return retainedBytes
  }

  var inFlightToken: UInt64? {
    lock.lock()
    defer { lock.unlock() }
    return inFlight?.token
  }

  func setAccepting(_ value: Bool) {
    lock.lock()
    accepting = value
    lock.unlock()
  }

  func admit(_ data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    guard accepting else {
      throw SecureTransportError(
        code: .invalidState,
        path: "state",
        message: "Channel accepts sends only while preparing or ready."
      )
    }
    guard !data.isEmpty, data.count <= limits.maximumSingleSendBytes else {
      throw SecureTransportError(
        code: .backpressure,
        path: "data",
        message: "Send bytes are empty or exceed the single-send limit."
      )
    }
    let pendingCount = pending.count - head + (inFlight == nil ? 0 : 1)
    guard pendingCount < limits.maximumPendingSendCount else {
      throw SecureTransportError(
        code: .backpressure,
        path: "pendingSends",
        message: "Pending send bounds reject this operation."
      )
    }
    let newByteCount = try SecureSendAdmission.addedByteCount(
      current: retainedBytes,
      adding: data.count,
      maximum: limits.maximumPendingSendBytes
    )
    guard nextToken != UInt64.max else {
      throw SecureTransportError(
        code: .arithmeticOverflow,
        path: "sendToken",
        message: "Send token space is exhausted."
      )
    }
    pending.append(Item(token: nextToken, data: data))
    nextToken += 1
    retainedBytes = newByteCount
  }

  func takeNextIfAvailable() -> Item? {
    lock.lock()
    defer { lock.unlock() }
    guard inFlight == nil, head < pending.count, let item = pending[head] else { return nil }
    pending[head] = nil
    head += 1
    inFlight = item
    compactIfNeeded()
    return item
  }

  func complete(token: UInt64, byteCount: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let item = inFlight, item.token == token, item.data.count == byteCount else {
      return false
    }
    inFlight = nil
    retainedBytes -= byteCount
    clearConsumedStorageIfIdle()
    return true
  }

  func clear() {
    lock.lock()
    pending.removeAll(keepingCapacity: false)
    head = 0
    inFlight = nil
    retainedBytes = 0
    lock.unlock()
  }

  private func compactIfNeeded() {
    guard head >= 256, head * 2 >= pending.count else { return }
    pending.removeFirst(head)
    head = 0
  }

  private func clearConsumedStorageIfIdle() {
    guard head == pending.count else { return }
    pending.removeAll(keepingCapacity: false)
    head = 0
  }
}

@_spi(NearWireInternal) public enum SecureAppTransport {
  public static func makeChannel(
    endpoint: NWEndpoint,
    connectionQueue: DispatchQueue,
    verificationQueue: DispatchQueue,
    limits: SecureTransportLimits = .default,
    eventHandler: @escaping SecureByteChannel.EventHandler
  ) -> SecureByteChannel {
    let parameters = SecureNetworkParameters.appClient(
      limits: limits,
      verificationQueue: verificationQueue
    )
    let connection = NWConnection(to: endpoint, using: parameters)
    return SecureByteChannel(
      connection: connection,
      queue: connectionQueue,
      limits: limits,
      eventHandler: eventHandler
    )
  }
}

@_spi(NearWireInternal) public enum SecureViewerListenerEvent: Sendable {
  case ready(port: UInt16)
  case incoming(SecureViewerIncomingConnection)
  case failed(SecureTransportError)
  case cancelled
}

@_spi(NearWireInternal) public enum SecureViewerTransport {
  public static func makeListener(
    identity: ViewerTransportIdentity,
    port: NWEndpoint.Port? = nil,
    limits: SecureTransportLimits = .default
  ) throws -> SecureViewerListener {
    let parameters = SecureNetworkParameters.viewerServer(identity: identity, limits: limits)
    do {
      let listener: NWListener
      if let port {
        listener = try NWListener(using: parameters, on: port)
      } else {
        listener = try NWListener(using: parameters)
      }
      return SecureViewerListener(listener: listener, limits: limits)
    } catch {
      throw SecureTransportError(
        code: .listenerCreationFailed,
        path: "listener",
        message: "Secure Viewer listener construction failed."
      )
    }
  }
}

@_spi(NearWireInternal) public final class SecureViewerListener: @unchecked Sendable {
  public typealias EventHandler = @Sendable (SecureViewerListenerEvent) -> Void

  private let listener: NWListener
  private let limits: SecureTransportLimits
  private let admissionGate = SecureViewerAdmissionGate()
  private let lock = NSLock()
  private var started = false
  private var terminal = false
  private var eventHandler: EventHandler?
  private var callbackQueue: DispatchQueue?

  fileprivate init(listener: NWListener, limits: SecureTransportLimits) {
    self.listener = listener
    self.limits = limits
  }

  public var port: UInt16? {
    listener.port?.rawValue
  }

  public func start(
    queue: DispatchQueue,
    eventHandler: @escaping EventHandler
  ) throws {
    lock.lock()
    guard !started, !terminal else {
      lock.unlock()
      throw SecureTransportError(
        code: .alreadyStarted,
        path: "listener.state",
        message: "Secure Viewer listener can start only once."
      )
    }
    started = true
    self.eventHandler = eventHandler
    let serializedQueue = DispatchQueue(
      label: "com.nearwire.secure-viewer-listener",
      target: queue
    )
    callbackQueue = serializedQueue
    listener.newConnectionHandler = { [weak self] connection in
      self?.handleIncoming(connection)
    }
    listener.stateUpdateHandler = { [weak self] state in
      self?.handleState(state)
    }
    listener.start(queue: serializedQueue)
    lock.unlock()
  }

  public func cancel() {
    lock.lock()
    guard !terminal else {
      lock.unlock()
      return
    }
    terminal = true
    admissionGate.close()
    let handler = eventHandler
    let queue = callbackQueue
    lock.unlock()
    listener.cancel()
    queue?.async {
      handler?(.cancelled)
    }
  }

  private func handleState(_ state: NWListener.State) {
    switch state {
    case .setup, .waiting:
      break
    case .ready:
      guard let port = listener.port?.rawValue else {
        terminate(
          with: SecureTransportError(
            code: .driverFailure,
            path: "listener.port",
            message: "Secure Viewer listener became ready without a port.",
            disposition: .connectionTerminal
          )
        )
        return
      }
      emit(.ready(port: port))
    case .failed:
      terminate(
        with: SecureTransportError(
          code: .driverFailure,
          path: "listener.state",
          message: "Secure Viewer listener failed.",
          disposition: .connectionTerminal
        )
      )
    case .cancelled:
      cancel()
    @unknown default:
      terminate(
        with: SecureTransportError(
          code: .driverFailure,
          path: "listener.state",
          message: "Secure Viewer listener entered an unsupported state.",
          disposition: .connectionTerminal
        )
      )
    }
  }

  private func handleIncoming(_ connection: NWConnection) {
    guard admissionGate.isOpen else {
      connection.cancel()
      return
    }
    emit(
      .incoming(
        SecureViewerIncomingConnection(
          connection: connection,
          limits: limits,
          admissionGate: admissionGate
        )
      )
    )
  }

  private func emit(_ event: SecureViewerListenerEvent) {
    lock.lock()
    let handler = terminal ? nil : eventHandler
    lock.unlock()
    handler?(event)
  }

  private func terminate(with error: SecureTransportError) {
    lock.lock()
    guard !terminal else {
      lock.unlock()
      return
    }
    terminal = true
    admissionGate.close()
    let handler = eventHandler
    lock.unlock()
    listener.cancel()
    handler?(.failed(error))
  }
}

@_spi(NearWireInternal) public final class SecureViewerIncomingConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let limits: SecureTransportLimits
  private let admissionGate: SecureViewerAdmissionGate
  private let lock = NSLock()
  private var claimed = false

  fileprivate init(
    connection: NWConnection,
    limits: SecureTransportLimits,
    admissionGate: SecureViewerAdmissionGate
  ) {
    self.connection = connection
    self.limits = limits
    self.admissionGate = admissionGate
  }

  deinit {
    lock.lock()
    let shouldCancel = !claimed
    lock.unlock()
    if shouldCancel { connection.cancel() }
  }

  public func makeChannel(
    queue: DispatchQueue,
    eventHandler: @escaping SecureByteChannel.EventHandler
  ) throws -> SecureByteChannel {
    lock.lock()
    guard !claimed else {
      lock.unlock()
      throw SecureTransportError(
        code: .invalidState,
        path: "incomingConnection",
        message: "Incoming secure connection is unavailable or already claimed."
      )
    }
    guard
      let channel = admissionGate.withOpenClaim({
        claimed = true
        return SecureByteChannel(
          connection: connection,
          queue: queue,
          limits: limits,
          eventHandler: eventHandler
        )
      })
    else {
      lock.unlock()
      throw SecureTransportError(
        code: .invalidState,
        path: "incomingConnection",
        message: "Incoming secure connection is unavailable or already claimed."
      )
    }
    lock.unlock()
    return channel
  }
}

final class SecureViewerAdmissionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var open = true

  var isOpen: Bool {
    lock.lock()
    defer { lock.unlock() }
    return open
  }

  func close(beforeLock: (() -> Void)? = nil) {
    beforeLock?()
    lock.lock()
    open = false
    lock.unlock()
  }

  func withOpenClaim<Value>(_ claim: () -> Value) -> Value? {
    lock.lock()
    defer { lock.unlock() }
    guard open else { return nil }
    return claim()
  }
}

private final class SecureCallbackIngress: @unchecked Sendable {
  private let lock = NSLock()
  private var tail: Task<Void, Never>?

  func submit(_ operation: @escaping @Sendable () async -> Void) {
    lock.lock()
    let predecessor = tail
    let task = Task {
      await predecessor?.value
      await operation()
    }
    tail = task
    lock.unlock()
  }
}

enum SecureSendAdmission {
  static func addedByteCount(
    current: Int,
    adding: Int,
    maximum: Int
  ) throws -> Int {
    let (result, overflow) = current.addingReportingOverflow(adding)
    guard !overflow else {
      throw SecureTransportError(
        code: .arithmeticOverflow,
        path: "pendingSends",
        message: "Pending send byte accounting overflowed."
      )
    }
    guard result <= maximum else {
      throw SecureTransportError(
        code: .backpressure,
        path: "pendingSends",
        message: "Pending send bounds reject this operation."
      )
    }
    return result
  }
}
