import Foundation
import Network

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

internal struct ViewerDiscoveryError: Error, Equatable, Sendable {
  enum Code: String, Sendable {
    case alreadyStarted
    case resultLimitExceeded
    case unavailableNetwork
    case permissionOrPolicyDenied
    case browserFailure
    case ambiguous
    case cancelled
  }

  let code: Code

  init(_ code: Code) {
    self.code = code
  }
}

extension ViewerDiscoveryError: CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { code.rawValue }
  var debugDescription: String { description }
}

internal enum ViewerDiscoveryState: String, Equatable, Sendable {
  case idle
  case searching
  case waiting
  case matched
  case ambiguous
  case failed
  case cancelled
}

internal struct DiscoveredViewer: @unchecked Sendable {
  let identity: NearWireBonjourServiceIdentity
  let endpoint: NWEndpoint
}

extension DiscoveredViewer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  var description: String { "<redacted-discovered-viewer>" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }
}

internal struct ViewerDiscoveryCandidate: @unchecked Sendable {
  let identity: NearWireBonjourServiceIdentity
  let endpoint: NWEndpoint
}

internal struct ViewerDiscoverySnapshot: @unchecked Sendable {
  var candidates: [ViewerDiscoveryCandidate]
  var hasUnattributedExactResult: Bool
  var discardedResultCount: UInt64

  static let empty = ViewerDiscoverySnapshot(
    candidates: [],
    hasUnattributedExactResult: false,
    discardedResultCount: 0
  )

  var retainedIdentityByteCount: Int {
    candidates.reduce(into: 0) { total, candidate in
      let identity = candidate.identity
      let byteCount =
        identity.instanceName.utf8.count + identity.type.utf8.count
        + identity.domain.utf8.count + identity.viewerDiscriminator.rawValue.utf8.count
      let (sum, overflow) = total.addingReportingOverflow(byteCount)
      total = overflow ? Int.max : sum
    }
  }
}

internal enum ViewerDiscoveryWaitingReason: Sendable {
  case unavailableNetwork
  case permissionOrPolicyDenied
}

internal enum ViewerDiscoveryDriverFailure: Sendable {
  case resultLimitExceeded
  case browserFailure
}

internal enum ViewerDiscoveryDriverEvent: @unchecked Sendable {
  case ready(epoch: UInt64)
  case snapshot(ViewerDiscoverySnapshot, epoch: UInt64)
  case waiting(ViewerDiscoveryWaitingReason)
  case failed(ViewerDiscoveryDriverFailure)
  case cancelled

  var isTerminal: Bool {
    switch self {
    case .failed, .cancelled, .waiting(.permissionOrPolicyDenied):
      return true
    case .ready, .snapshot, .waiting(.unavailableNetwork):
      return false
    }
  }

  var isSnapshot: Bool {
    if case .snapshot = self { return true }
    return false
  }

  var retainedCandidateFootprint: (count: Int, bytes: Int) {
    if case .snapshot(let snapshot, _) = self {
      return (snapshot.candidates.count, snapshot.retainedIdentityByteCount)
    }
    return (0, 0)
  }
}

internal protocol ViewerDiscoveryDriving: AnyObject, Sendable {
  func start(
    expectedInstanceName: String,
    handler: @escaping @Sendable (ViewerDiscoveryDriverEvent) -> Void
  ) throws
  func quiesceAfterMatch()
  func cancel()
}
