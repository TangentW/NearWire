import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireTransport

enum ViewerEventDisposition: String, Sendable {
  case buffered
  case transportAdmitted
  case consumerAccepted
  case expired
  case overflowDisplaced
  case sessionEnded
}

enum ViewerCommittedObservationError: Error, Equatable, Sendable {
  case invalidTimestamp
  case invalidAccounting
  case invalidSessionMetadata
  case invalidSessionIdentity
}

struct ViewerEventJournalKey: Equatable, Hashable, Sendable {
  let runtimeLogicalID: UUID
  let connectionID: UUID
  let direction: EventDirection
  let wireSequence: UInt64
}

struct ViewerFrozenSessionMetadata: Equatable, Sendable {
  let installationID: String
  let installationAlias: String
  let displayName: String
  let applicationIdentifier: String?
  let applicationVersion: String?
  let nickname: String?

  init(context: ViewerAdmissionSessionContext, nickname: String?) throws {
    let installationID = context.appHello.installationID.rawValue
    let displayName =
      context.appHello.displayName ?? context.appHello.applicationIdentifier ?? "Unnamed App"
    let installationAlias = "App \(installationID.suffix(8))"
    guard Self.isBounded(installationID, maximumBytes: 512),
      Self.isBounded(installationAlias, maximumBytes: 128),
      Self.isBounded(displayName, maximumBytes: 512),
      Self.isBounded(context.appHello.applicationIdentifier, maximumBytes: 512),
      Self.isBounded(context.appHello.applicationVersion, maximumBytes: 256),
      Self.isBounded(nickname, maximumBytes: 512)
    else { throw ViewerCommittedObservationError.invalidSessionMetadata }
    self.installationID = installationID
    self.installationAlias = installationAlias
    self.displayName = displayName
    applicationIdentifier = context.appHello.applicationIdentifier
    applicationVersion = context.appHello.applicationVersion
    self.nickname = nickname
  }

  init(
    installationID: String,
    installationAlias: String,
    displayName: String,
    applicationIdentifier: String?,
    applicationVersion: String?,
    nickname: String? = nil
  ) throws {
    guard Self.isBounded(installationID, maximumBytes: 512),
      Self.isBounded(installationAlias, maximumBytes: 128),
      Self.isBounded(displayName, maximumBytes: 512),
      Self.isBounded(applicationIdentifier, maximumBytes: 512),
      Self.isBounded(applicationVersion, maximumBytes: 256),
      Self.isBounded(nickname, maximumBytes: 512)
    else { throw ViewerCommittedObservationError.invalidSessionMetadata }
    self.installationID = installationID
    self.installationAlias = installationAlias
    self.displayName = displayName
    self.applicationIdentifier = applicationIdentifier
    self.applicationVersion = applicationVersion
    self.nickname = nickname
  }

  private static func isBounded(_ value: String?, maximumBytes: Int) -> Bool {
    guard let value else { return true }
    return value.utf8.count <= maximumBytes
      && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
  }
}

struct ViewerCanonicalEventProjection: Equatable, Sendable {
  let eventID: EventID
  let eventType: EventType
  let canonicalContent: Data
  let createdWallMilliseconds: Int64
  let originMonotonicNanoseconds: UInt64
  let priority: EventPriority
  let ttlMilliseconds: UInt64
  let schemaVersion: EventSchemaVersion
  let correlationID: EventID?
  let replyToID: EventID?
  let initialDisposition: ViewerEventDisposition?

  init(
    envelope: EventEnvelope,
    canonicalContent: Data,
    initialDisposition: ViewerEventDisposition?
  ) throws {
    let milliseconds = (envelope.createdAt.timeIntervalSince1970 * 1_000).rounded()
    guard milliseconds.isFinite, let normalized = Int64(exactly: milliseconds) else {
      throw ViewerCommittedObservationError.invalidTimestamp
    }
    eventID = envelope.id
    eventType = envelope.type
    self.canonicalContent = canonicalContent
    createdWallMilliseconds = normalized
    originMonotonicNanoseconds = envelope.monotonicTimestampNanoseconds
    priority = envelope.priority
    ttlMilliseconds = envelope.ttl.milliseconds
    schemaVersion = envelope.schemaVersion
    correlationID = envelope.causality.correlationID
    replyToID = envelope.causality.replyTo
    self.initialDisposition = initialDisposition
  }
}

struct ViewerCommittedEventObservation: Sendable {
  let observationID: UUID
  let key: ViewerEventJournalKey
  let session: ViewerFrozenSessionMetadata
  let envelope: EventEnvelope
  let viewerWallMilliseconds: Int64
  let viewerMonotonicNanoseconds: UInt64
  let deterministicEventBytes: Int
  let canonicalProjection: ViewerCanonicalEventProjection

  init(
    observationID: UUID = UUID(),
    runtimeLogicalID: UUID,
    connectionID: UUID,
    session: ViewerFrozenSessionMetadata,
    envelope: EventEnvelope,
    viewerWallMilliseconds: Int64,
    viewerMonotonicNanoseconds: UInt64,
    deterministicEventBytes: Int,
    canonicalContent: Data,
    initialDisposition: ViewerEventDisposition?
  ) throws {
    guard deterministicEventBytes >= 0 else {
      throw ViewerCommittedObservationError.invalidAccounting
    }
    self.observationID = observationID
    key = ViewerEventJournalKey(
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      direction: envelope.direction,
      wireSequence: envelope.sequence.rawValue
    )
    self.session = session
    self.envelope = envelope
    self.viewerWallMilliseconds = viewerWallMilliseconds
    self.viewerMonotonicNanoseconds = viewerMonotonicNanoseconds
    self.deterministicEventBytes = deterministicEventBytes
    canonicalProjection = try ViewerCanonicalEventProjection(
      envelope: envelope,
      canonicalContent: canonicalContent,
      initialDisposition: initialDisposition
    )
  }

  init(
    observationID: UUID = UUID(),
    runtimeLogicalID: UUID,
    connectionID: UUID,
    session: ViewerFrozenSessionMetadata,
    envelope: EventEnvelope,
    viewerWallMilliseconds: Int64,
    viewerMonotonicNanoseconds: UInt64,
    deterministicEventBytes: Int,
    initialDisposition: ViewerEventDisposition?
  ) throws {
    try self.init(
      observationID: observationID,
      runtimeLogicalID: runtimeLogicalID,
      connectionID: connectionID,
      session: session,
      envelope: envelope,
      viewerWallMilliseconds: viewerWallMilliseconds,
      viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
      deterministicEventBytes: deterministicEventBytes,
      canonicalContent: try envelope.content.deterministicData(),
      initialDisposition: initialDisposition
    )
  }

  init(
    observationID: UUID = UUID(),
    runtimeLogicalID: UUID,
    context: ViewerAdmissionSessionContext,
    nickname: String?,
    envelope: EventEnvelope,
    viewerWallMilliseconds: Int64,
    viewerMonotonicNanoseconds: UInt64,
    deterministicEventBytes: Int,
    canonicalContent: Data,
    initialDisposition: ViewerEventDisposition?
  ) throws {
    let expectedSource: EventEndpoint
    let expectedTarget: EventEndpoint
    switch envelope.direction {
    case .appToViewer:
      expectedSource = EventEndpoint(role: .app, id: context.appHello.installationID)
      expectedTarget = EventEndpoint(
        role: .viewer,
        id: context.negotiation.viewerInstallationID
      )
    case .viewerToApp:
      expectedSource = EventEndpoint(
        role: .viewer,
        id: context.negotiation.viewerInstallationID
      )
      expectedTarget = EventEndpoint(role: .app, id: context.appHello.installationID)
    }
    guard envelope.source == expectedSource, envelope.target == expectedTarget else {
      throw ViewerCommittedObservationError.invalidSessionIdentity
    }
    try self.init(
      observationID: observationID,
      runtimeLogicalID: runtimeLogicalID,
      connectionID: context.connectionID,
      session: ViewerFrozenSessionMetadata(context: context, nickname: nickname),
      envelope: envelope,
      viewerWallMilliseconds: viewerWallMilliseconds,
      viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
      deterministicEventBytes: deterministicEventBytes,
      canonicalContent: canonicalContent,
      initialDisposition: initialDisposition
    )
  }

  init(
    observationID: UUID = UUID(),
    runtimeLogicalID: UUID,
    context: ViewerAdmissionSessionContext,
    nickname: String?,
    envelope: EventEnvelope,
    viewerWallMilliseconds: Int64,
    viewerMonotonicNanoseconds: UInt64,
    deterministicEventBytes: Int,
    initialDisposition: ViewerEventDisposition?
  ) throws {
    try self.init(
      observationID: observationID,
      runtimeLogicalID: runtimeLogicalID,
      context: context,
      nickname: nickname,
      envelope: envelope,
      viewerWallMilliseconds: viewerWallMilliseconds,
      viewerMonotonicNanoseconds: viewerMonotonicNanoseconds,
      deterministicEventBytes: deterministicEventBytes,
      canonicalContent: try envelope.content.deterministicData(),
      initialDisposition: initialDisposition
    )
  }
}

enum ViewerLiveEventOfferOutcome: Equatable, Sendable {
  case accepted
  case deferred
  case identical
  case presentationConflict
  case untracked
  case sealed
}

enum ViewerEventJournalOutcome: Equatable, Sendable {
  case identical
  case presentationConflict
  case untracked
  case sealed
}

extension ViewerEventJournalKey: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerEventJournalKey(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerFrozenSessionMetadata: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerFrozenSessionMetadata(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerCanonicalEventProjection: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerCanonicalEventProjection(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

extension ViewerCommittedEventObservation: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String {
    "ViewerCommittedEventObservation(redacted, bytes: \(deterministicEventBytes))"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["deterministicEventBytes": deterministicEventBytes],
      displayStyle: .struct
    )
  }
}
