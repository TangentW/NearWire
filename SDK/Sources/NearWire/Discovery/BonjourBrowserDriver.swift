import Foundation
import Network
import dnssd

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

internal struct BonjourBrowserPlan: Equatable, Sendable {
  let serviceType: String
  let domain: String

  static let production = BonjourBrowserPlan(
    serviceType: NearWireBonjour.serviceType,
    domain: NearWireBonjour.localDomain
  )

  func makeDescriptor() -> NWBrowser.Descriptor {
    .bonjourWithTXTRecord(type: serviceType, domain: domain)
  }

  func makeParameters() -> NWParameters {
    let parameters = NWParameters()
    parameters.includePeerToPeer = true
    return parameters
  }
}

internal enum BonjourResultConversion: @unchecked Sendable {
  case discarded
  case unattributedExact
  case candidate(ViewerDiscoveryCandidate)
}

internal enum BonjourSnapshotConversion: @unchecked Sendable {
  case snapshot(ViewerDiscoverySnapshot)
  case resultLimitExceeded
}

internal struct BonjourServiceObservation: Sendable {
  let instanceName: String
  let type: String
  let domain: String
  let viewerDiscriminator: ViewerDiscoveryDiscriminator?
  let interfaceObservationCount: Int
}

internal enum BonjourServiceObservationConverter {
  static func convert(
    _ observation: BonjourServiceObservation,
    expectedInstanceName: String
  ) -> BonjourResultConversion {
    guard NearWireBonjour.isSafeInstanceName(observation.instanceName),
      NearWireBonjour.canonicalType(observation.type) != nil,
      NearWireBonjour.canonicalDomain(observation.domain) != nil,
      observation.instanceName == expectedInstanceName
    else {
      return .discarded
    }

    // Interface observations are path hints only. This bounded read intentionally ignores
    // additional observations without changing identity or endpoint construction.
    _ = min(observation.interfaceObservationCount, NearWireBonjour.maximumInterfacesPerResult)

    guard let discriminator = observation.viewerDiscriminator,
      let identity = NearWireBonjourServiceIdentity(
        instanceName: observation.instanceName,
        type: observation.type,
        domain: observation.domain,
        viewerDiscriminator: discriminator
      )
    else {
      return .unattributedExact
    }
    let endpoint = NWEndpoint.service(
      name: identity.instanceName,
      type: identity.type,
      domain: identity.domain,
      interface: nil
    )
    return .candidate(ViewerDiscoveryCandidate(identity: identity, endpoint: endpoint))
  }
}

internal struct BonjourReadinessGate: Sendable {
  private(set) var epoch: UInt64 = 0
  private(set) var isReady = false

  mutating func readyEvent() -> ViewerDiscoveryDriverEvent? {
    guard !isReady else { return nil }
    isReady = true
    epoch &+= 1
    return .ready(epoch: epoch)
  }

  mutating func waitingEvent(
    _ reason: ViewerDiscoveryWaitingReason
  ) -> ViewerDiscoveryDriverEvent {
    isReady = false
    epoch &+= 1
    return .waiting(reason)
  }

  func snapshotEvent(_ snapshot: ViewerDiscoverySnapshot) -> ViewerDiscoveryDriverEvent? {
    guard isReady else { return nil }
    return .snapshot(snapshot, epoch: epoch)
  }

  mutating func stop() {
    isReady = false
    epoch &+= 1
  }
}

internal final class BonjourBrowserCallbackEdge: @unchecked Sendable {
  private var readinessGate = BonjourReadinessGate()
  private let emit: @Sendable (ViewerDiscoveryDriverEvent) -> Void
  private let emitTerminal: @Sendable (ViewerDiscoveryDriverEvent) -> Void
  private var isTerminal = false

  init(
    emit: @escaping @Sendable (ViewerDiscoveryDriverEvent) -> Void,
    emitTerminal: @escaping @Sendable (ViewerDiscoveryDriverEvent) -> Void
  ) {
    self.emit = emit
    self.emitTerminal = emitTerminal
  }

  func ready() {
    guard !isTerminal else { return }
    if let event = readinessGate.readyEvent() { emit(event) }
  }

  func waiting(_ reason: ViewerDiscoveryWaitingReason) {
    guard !isTerminal else { return }
    let event = readinessGate.waitingEvent(reason)
    switch reason {
    case .permissionOrPolicyDenied:
      transitionTerminal(event)
    case .unavailableNetwork:
      emit(event)
    }
  }

  func failed(_ failure: ViewerDiscoveryDriverFailure) {
    transitionTerminal(.failed(failure))
  }

  func cancelled() {
    transitionTerminal(.cancelled)
  }

  func results<Results: Collection>(
    _ rawResults: Results,
    transform: (Results.Element) -> BonjourResultConversion
  ) {
    guard !isTerminal, readinessGate.isReady else { return }
    switch BonjourSnapshotConverter.convert(rawResults, transform: transform) {
    case .resultLimitExceeded:
      failed(.resultLimitExceeded)
    case .snapshot(let snapshot):
      if let event = readinessGate.snapshotEvent(snapshot) { emit(event) }
    }
  }

  private func transitionTerminal(_ event: ViewerDiscoveryDriverEvent) {
    guard !isTerminal else { return }
    isTerminal = true
    readinessGate.stop()
    emitTerminal(event)
  }
}

internal enum BonjourSnapshotConverter {
  static func convert<Results: Collection>(
    _ rawResults: Results,
    transform: (Results.Element) -> BonjourResultConversion
  ) -> BonjourSnapshotConversion {
    guard rawResults.count <= NearWireBonjour.maximumRawResults else {
      return .resultLimitExceeded
    }

    var candidates: [ViewerDiscoveryCandidate] = []
    candidates.reserveCapacity(rawResults.count)
    var hasUnattributed = false
    var discarded: UInt64 = 0

    for rawResult in rawResults {
      switch transform(rawResult) {
      case .discarded:
        if discarded < UInt64.max { discarded += 1 }
      case .unattributedExact:
        hasUnattributed = true
      case .candidate(let candidate):
        candidates.append(candidate)
      }
    }

    return .snapshot(
      ViewerDiscoverySnapshot(
        candidates: candidates,
        hasUnattributedExactResult: hasUnattributed,
        discardedResultCount: discarded
      )
    )
  }
}

internal protocol NWBrowserControlling: AnyObject {
  var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)? { get set }
  var browseResultsChangedHandler:
    (@Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void)?
  { get set }
  func start(queue: DispatchQueue)
  func cancel()
}

extension NWBrowser: NWBrowserControlling {}

internal final class NWBrowserDiscoveryDriver: ViewerDiscoveryDriving, @unchecked Sendable {
  typealias BrowserFactory = (NWBrowser.Descriptor, NWParameters) -> NWBrowserControlling

  static let productionPlan = BonjourBrowserPlan.production

  private let lock = NSLock()
  private let callbackQueue = DispatchQueue(label: "com.nearwire.discovery.browser")
  private let browser: NWBrowserControlling
  private var handler: (@Sendable (ViewerDiscoveryDriverEvent) -> Void)?
  private var callbackEdge: BonjourBrowserCallbackEdge?
  private var hasStarted = false
  private var hasCancelled = false
  private var hasReportedTerminal = false

  init(
    browserFactory: BrowserFactory = { descriptor, parameters in
      NWBrowser(for: descriptor, using: parameters)
    }
  ) {
    let plan = Self.productionPlan
    browser = browserFactory(plan.makeDescriptor(), plan.makeParameters())
  }

  func start(
    expectedInstanceName: String,
    handler: @escaping @Sendable (ViewerDiscoveryDriverEvent) -> Void
  ) throws {
    lock.lock()
    guard !hasStarted, !hasCancelled else {
      lock.unlock()
      throw ViewerDiscoveryError(.alreadyStarted)
    }
    hasStarted = true
    self.handler = handler
    let edge = BonjourBrowserCallbackEdge(
      emit: handler,
      emitTerminal: { [weak self] event in
        self?.reportTerminal(event)
      }
    )
    callbackEdge = edge
    lock.unlock()

    browser.stateUpdateHandler = { [weak edge] state in
      guard let edge else { return }
      switch state {
      case .setup:
        break
      case .ready:
        edge.ready()
      case .waiting(let error):
        edge.waiting(Self.waitingReason(for: error))
      case .failed:
        edge.failed(.browserFailure)
      case .cancelled:
        edge.cancelled()
      @unknown default:
        edge.failed(.browserFailure)
      }
    }
    browser.browseResultsChangedHandler = { [weak edge] results, _ in
      guard let edge else { return }
      edge.results(results) { result in
        Self.convert(result, expectedInstanceName: expectedInstanceName)
      }
    }
    browser.start(queue: callbackQueue)
  }

  func cancel() {
    lock.lock()
    guard !hasCancelled else {
      lock.unlock()
      return
    }
    hasCancelled = true
    handler = nil
    callbackEdge = nil
    lock.unlock()
    browser.stateUpdateHandler = nil
    browser.browseResultsChangedHandler = nil
    browser.cancel()
  }

  deinit {
    cancel()
  }

  private func reportTerminal(_ event: ViewerDiscoveryDriverEvent) {
    lock.lock()
    guard !hasReportedTerminal, !hasCancelled else {
      lock.unlock()
      return
    }
    hasReportedTerminal = true
    if case .cancelled = event { hasCancelled = true }
    let callback = handler
    handler = nil
    callbackEdge = nil
    lock.unlock()

    browser.stateUpdateHandler = nil
    browser.browseResultsChangedHandler = nil
    callback?(event)
  }

  private static func convert(
    _ result: NWBrowser.Result,
    expectedInstanceName: String
  ) -> BonjourResultConversion {
    guard case .service(let name, let type, let domain, _) = result.endpoint,
      NearWireBonjour.isSafeInstanceName(name),
      NearWireBonjour.canonicalType(type) != nil,
      NearWireBonjour.canonicalDomain(domain) != nil,
      name == expectedInstanceName
    else {
      return .discarded
    }
    return BonjourServiceObservationConverter.convert(
      BonjourServiceObservation(
        instanceName: name,
        type: type,
        domain: domain,
        viewerDiscriminator: Self.viewerDiscriminator(from: result.metadata),
        interfaceObservationCount: result.interfaces.count
      ),
      expectedInstanceName: expectedInstanceName
    )
  }

  static func viewerDiscriminator(
    from metadata: NWBrowser.Result.Metadata
  ) -> ViewerDiscoveryDiscriminator? {
    guard case .bonjour(let record) = metadata,
      let entry = record.getEntry(for: NearWireBonjour.txtViewerIDKey)
    else {
      return nil
    }
    switch entry {
    case .string(let value):
      return boundedDiscriminator(value)
    case .data(let data):
      guard data.count == ViewerDiscoveryDiscriminator.encodedLength else { return nil }
      return boundedDiscriminator(String(decoding: data, as: UTF8.self))
    case .none, .empty:
      return nil
    @unknown default:
      return nil
    }
  }

  private static func boundedDiscriminator(_ value: String) -> ViewerDiscoveryDiscriminator? {
    var iterator = value.utf8.makeIterator()
    for index in 0...ViewerDiscoveryDiscriminator.encodedLength {
      guard iterator.next() != nil else { break }
      if index == ViewerDiscoveryDiscriminator.encodedLength { return nil }
    }
    return ViewerDiscoveryDiscriminator(rawValue: value)
  }

  static func waitingReason(for error: NWError) -> ViewerDiscoveryWaitingReason {
    if case .dns(let code) = error {
      return code == kDNSServiceErr_PolicyDenied
        ? .permissionOrPolicyDenied : .unavailableNetwork
    }
    return .unavailableNetwork
  }
}
