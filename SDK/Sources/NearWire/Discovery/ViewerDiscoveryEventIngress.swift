import Foundation

internal final class ViewerDiscoveryEventIngress: @unchecked Sendable {
  typealias Consumer = @Sendable (ViewerDiscoveryDriverEvent) async -> Void

  struct RetainedCounts: Equatable, Sendable {
    let processing: Int
    let snapshot: Int
    let stateOrTerminal: Int
    let candidateCount: Int
    let identityByteCount: Int
  }

  private let lock = NSLock()
  private let consumer: Consumer
  private var isProcessing = false
  private var isStopped = false
  private var hasAcceptedTerminal = false
  private var pendingSnapshot: ViewerDiscoveryDriverEvent?
  private var pendingStateOrTerminal: ViewerDiscoveryDriverEvent?
  private var processingCandidateCount = 0
  private var processingIdentityByteCount = 0

  init(consumer: @escaping Consumer) {
    self.consumer = consumer
  }

  func submit(_ event: ViewerDiscoveryDriverEvent) {
    var shouldStart = false
    lock.lock()
    if !isStopped, !hasAcceptedTerminal {
      if event.isTerminal {
        hasAcceptedTerminal = true
        pendingStateOrTerminal = event
        pendingSnapshot = nil
      } else if pendingStateOrTerminal?.isTerminal != true {
        if event.isSnapshot {
          pendingSnapshot = event
        } else {
          pendingStateOrTerminal = event
        }
      }
      if !isProcessing {
        isProcessing = true
        shouldStart = true
      }
    }
    lock.unlock()

    if shouldStart {
      Task { await drain() }
    }
  }

  func stop() {
    lock.lock()
    isStopped = true
    pendingSnapshot = nil
    pendingStateOrTerminal = nil
    lock.unlock()
  }

  var retainedCounts: RetainedCounts {
    lock.lock()
    defer { lock.unlock() }
    return RetainedCounts(
      processing: isProcessing ? 1 : 0,
      snapshot: pendingSnapshot == nil ? 0 : 1,
      stateOrTerminal: pendingStateOrTerminal == nil ? 0 : 1,
      candidateCount: processingCandidateCount
        + (pendingSnapshot?.retainedCandidateFootprint.count ?? 0),
      identityByteCount: processingIdentityByteCount
        + (pendingSnapshot?.retainedCandidateFootprint.bytes ?? 0)
    )
  }

  private func popNext() -> ViewerDiscoveryDriverEvent? {
    lock.lock()
    defer { lock.unlock() }
    if let state = pendingStateOrTerminal {
      pendingStateOrTerminal = nil
      setProcessingFootprint(state)
      return state
    }
    if let snapshot = pendingSnapshot {
      pendingSnapshot = nil
      setProcessingFootprint(snapshot)
      return snapshot
    }
    isProcessing = false
    return nil
  }

  private func drain() async {
    while let event = popNext() {
      await consumer(event)
      clearProcessingFootprint()
    }
  }

  private func setProcessingFootprint(_ event: ViewerDiscoveryDriverEvent) {
    let footprint = event.retainedCandidateFootprint
    processingCandidateCount = footprint.count
    processingIdentityByteCount = footprint.bytes
  }

  private func clearProcessingFootprint() {
    lock.lock()
    processingCandidateCount = 0
    processingIdentityByteCount = 0
    lock.unlock()
  }
}
