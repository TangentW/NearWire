import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireInternal) import NearWireFlowControl
  @_spi(NearWireInternal) import NearWireTransport
#endif

final class SDKOutboundWakeToken: @unchecked Sendable {}

enum SDKOutboundScheduleResult: Equatable, Sendable {
  case available(EventQueueSchedulingObservation)
  case clockFailed
  case ownerUnavailable
  case terminalFirst
}

struct SDKOutboundWakeRegistrationResult: Equatable, Sendable {
  let installed: Bool
  let schedule: SDKOutboundScheduleResult
}

enum SDKOutboundWakeRegistrationError: Error, Equatable, Sendable {
  case alreadyRegistered
}

struct SDKOutboundWakeRegistration: Sendable {
  let token: SDKOutboundWakeToken
  let callback: @Sendable () -> Void
}

enum SDKActiveWireDrainFailure: Equatable, Sendable {
  case clockFailed
  case encodingFailed
  case invalidLimits
  case sequenceFailed
  case transportFailed
}

struct SDKActiveWireTransportBlock: Equatable, Sendable {
  let candidateID: EventID
  let encodedByteCount: Int
  let reservedPendingSendCount: Int
  let reservedPendingSendBytes: Int
  let progressGeneration: UInt64
}

struct SDKActiveWireDrainResult: Equatable, Sendable {
  let ownerAvailable: Bool
  let stoppedByTerminal: Bool
  let failure: SDKActiveWireDrainFailure?
  let acceptedEventIDs: [EventID]
  let rejectedEventIDs: [EventID]
  let notAttemptedEventIDs: [EventID]
  let routingDroppedEventIDs: [EventID]
  let expiredEventIDs: [EventID]
  let plannedSequenceCounter: WireSequenceCounter
  let acceptedEncodedByteCount: Int
  let acceptedAccountedByteCount: Int
  let serviceUnits: Int
  let dueWorkRemains: Bool
  let eligibleWorkRemains: Bool
  let nextExpirationDeadlineNanoseconds: UInt64?
  let nextFairCandidateID: EventID?
  let transportBlock: SDKActiveWireTransportBlock?
}

enum SDKActiveIncomingPublicationResult: Equatable, Sendable {
  case published
  case expired
  case ownerUnavailable
  case terminalFirst
  case clockFailed
}

final class SDKOutboundSignalIngress: @unchecked Sendable {
  struct Snapshot: Equatable, Sendable {
    let isStopped: Bool
    let isScheduled: Bool
    let isDirty: Bool
  }

  private let lock = NSLock()
  private var route: (@Sendable () -> Void)?
  private var isScheduled = false
  private var isDirty = false
  private var isStopped = false

  init(route: @escaping @Sendable () -> Void) {
    self.route = route
  }

  func signal() {
    var callback: (@Sendable () -> Void)?
    lock.lock()
    if !isStopped {
      if isScheduled {
        isDirty = true
      } else {
        isScheduled = true
        callback = route
      }
    }
    lock.unlock()
    callback?()
  }

  func finishRoutingTurn() {
    var callback: (@Sendable () -> Void)?
    lock.lock()
    if !isStopped, isScheduled, isDirty {
      isDirty = false
      callback = route
    } else {
      isScheduled = false
      isDirty = false
    }
    lock.unlock()
    callback?()
  }

  func stop() {
    lock.lock()
    isStopped = true
    isScheduled = false
    isDirty = false
    route = nil
    lock.unlock()
  }

  var snapshot: Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(isStopped: isStopped, isScheduled: isScheduled, isDirty: isDirty)
  }
}
