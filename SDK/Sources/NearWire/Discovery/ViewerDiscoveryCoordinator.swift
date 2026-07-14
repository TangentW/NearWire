import Foundation
import Network

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

internal actor ViewerDiscoveryCoordinator {
  private var expectedInstanceName: String?
  private let driver: ViewerDiscoveryDriving
  private var operationState: ViewerDiscoveryState = .idle
  private var continuation: CheckedContinuation<DiscoveredViewer, Error>?
  private var ingress: ViewerDiscoveryEventIngress?
  private var driverStarted = false
  private var driverCancelled = false
  private var latestReadyEpoch: UInt64?
  private var retainedCandidates: [ViewerDiscoveryCandidate] = []
  private var totalDiscardedResultCount: UInt64 = 0

  init(pairingCode: PairingCode, driver: ViewerDiscoveryDriving) {
    expectedInstanceName = NearWireBonjour.instanceName(for: pairingCode)
    self.driver = driver
  }

  var state: ViewerDiscoveryState { operationState }
  var retainsExpectedInstanceName: Bool { expectedInstanceName != nil }
  var retainedCandidateCount: Int { retainedCandidates.count }
  var discardedResultCount: UInt64 { totalDiscardedResultCount }
  var ingressRetainedCounts: ViewerDiscoveryEventIngress.RetainedCounts? {
    ingress?.retainedCounts
  }

  func run() async throws -> DiscoveredViewer {
    guard operationState == .idle else {
      throw ViewerDiscoveryError(.alreadyStarted)
    }
    guard !Task.isCancelled else {
      operationState = .cancelled
      expectedInstanceName = nil
      throw ViewerDiscoveryError(.cancelled)
    }
    guard let expectedInstanceName else {
      operationState = .failed
      throw ViewerDiscoveryError(.browserFailure)
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiter in
        continuation = waiter
        operationState = .searching
        let eventIngress = ViewerDiscoveryEventIngress { [weak self] event in
          await self?.receive(event)
        }
        ingress = eventIngress
        driverStarted = true
        do {
          try driver.start(expectedInstanceName: expectedInstanceName) { event in
            eventIngress.submit(event)
          }
        } catch {
          finishFailure(.browserFailure, state: .failed, cancelDriver: true)
        }
      }
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  func cancel() {
    switch operationState {
    case .idle:
      operationState = .cancelled
      expectedInstanceName = nil
    case .searching, .waiting:
      finishFailure(.cancelled, state: .cancelled, cancelDriver: true)
    case .matched:
      cancelDriverOnce()
    case .ambiguous, .failed, .cancelled:
      break
    }
  }

  private func receive(_ event: ViewerDiscoveryDriverEvent) {
    guard operationState == .searching || operationState == .waiting else { return }

    switch event {
    case .ready(let epoch):
      if let latestReadyEpoch, epoch <= latestReadyEpoch { return }
      latestReadyEpoch = epoch
      operationState = .searching
      retainedCandidates.removeAll(keepingCapacity: false)

    case .snapshot(let snapshot, let epoch):
      guard operationState == .searching, latestReadyEpoch == epoch else { return }
      totalDiscardedResultCount = Self.saturatingAdd(
        totalDiscardedResultCount,
        snapshot.discardedResultCount
      )
      retainedCandidates = snapshot.candidates
      evaluate(snapshot)

    case .waiting(.unavailableNetwork):
      latestReadyEpoch = nil
      operationState = .waiting
      retainedCandidates.removeAll(keepingCapacity: false)

    case .waiting(.permissionOrPolicyDenied):
      finishFailure(.permissionOrPolicyDenied, state: .failed, cancelDriver: true)

    case .failed(.resultLimitExceeded):
      finishFailure(.resultLimitExceeded, state: .failed, cancelDriver: true)

    case .failed(.browserFailure):
      finishFailure(.browserFailure, state: .failed, cancelDriver: true)

    case .cancelled:
      finishFailure(.cancelled, state: .cancelled, cancelDriver: false)
    }
  }

  private func evaluate(_ snapshot: ViewerDiscoverySnapshot) {
    guard let expectedInstanceName else { return }
    var matches: [ViewerDiscoveryDiscriminator: ViewerDiscoveryCandidate] = [:]
    for candidate in snapshot.candidates
    where candidate.identity.instanceName == expectedInstanceName {
      matches[candidate.identity.viewerDiscriminator] = candidate
    }

    if matches.count >= 2 {
      finishFailure(.ambiguous, state: .ambiguous, cancelDriver: true)
      return
    }
    if snapshot.hasUnattributedExactResult {
      retainedCandidates.removeAll(keepingCapacity: false)
      return
    }
    guard let match = matches.values.first else {
      retainedCandidates.removeAll(keepingCapacity: false)
      return
    }
    finishSuccess(match)
  }

  private func finishSuccess(_ candidate: ViewerDiscoveryCandidate) {
    guard let waiter = continuation else { return }
    continuation = nil
    operationState = .matched
    expectedInstanceName = nil
    ingress?.stop()
    ingress = nil
    driver.quiesceAfterMatch()
    retainedCandidates.removeAll(keepingCapacity: false)
    waiter.resume(
      returning: DiscoveredViewer(identity: candidate.identity, endpoint: candidate.endpoint)
    )
  }

  private func finishFailure(
    _ code: ViewerDiscoveryError.Code,
    state: ViewerDiscoveryState,
    cancelDriver: Bool
  ) {
    let waiter = continuation
    continuation = nil
    operationState = state
    expectedInstanceName = nil
    ingress?.stop()
    ingress = nil
    if cancelDriver { cancelDriverOnce() }
    retainedCandidates.removeAll(keepingCapacity: false)
    waiter?.resume(throwing: ViewerDiscoveryError(code))
  }

  private func cancelDriverOnce() {
    guard driverStarted, !driverCancelled else { return }
    driverCancelled = true
    driver.cancel()
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : sum
  }
}
