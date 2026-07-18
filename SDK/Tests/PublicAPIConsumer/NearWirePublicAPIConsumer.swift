import Foundation
import NearWire

private struct NearWireConsumerPayload: Codable, Sendable {
  let name: String
  let value: Int
}

func compileSupportedNearWireAPI() async throws {
  let buffer = try NearWireBufferConfiguration(
    maximumEventCount: 100,
    maximumBytes: 1_048_576,
    maximumEventBytes: 262_144,
    defaultTTL: .seconds(60)
  )
  let configuration = try NearWireConfiguration(
    maximumUplinkEventsPerSecond: 100,
    maximumDownlinkEventsPerSecond: 50,
    buffer: buffer,
    eventStreamBufferCapacity: 64,
    reconnectionPolicy: try NearWireReconnectionPolicy(
      maximumAttempts: 3,
      initialDelay: .seconds(1),
      maximumDelay: .seconds(4)
    )
  )
  let nearWire = NearWire(configuration: configuration)
  do {
    try await nearWire.connect(code: "ABC2")
  } catch let error as NearWireError {
    switch error.code {
    case .invalidPairingCode, .connectionInProgress, .alreadyConnected,
      .connectionSuspended, .connectionIntentExists,
      .anotherConnectionIsActive, .connectionOwnershipUnavailable, .connectionCancelled,
      .discoveryTimedOut, .localNetworkDenied, .discoveryUnavailable, .discoveryAmbiguous,
      .connectionTimedOut, .secureConnectionFailed, .incompatibleViewer,
      .viewerIdentityMismatch, .viewerRejected, .connectionClosed, .connectionInternalFailure,
      .invalidConfiguration, .shutdown:
      break
    default:
      break
    }
  }
  _ = await nearWire.currentState
  _ = await nearWire.connectionStatus
  let result = try await nearWire.send(
    type: "fixture.value",
    content: NearWireConsumerPayload(name: "fixture", value: 1),
    policy: .keepLatest(key: "fixture-value"),
    options: NearWireEventOptions(priority: .normal, ttl: .seconds(30))
  )
  let diagnostics = try await nearWire.bufferDiagnostics()
  _ = (result.eventID, result.isBuffered, diagnostics.eventCount)

  for await state in nearWire.states {
    _ = state
    break
  }

  for await status in nearWire.connectionStatuses {
    _ = (status.state, status.lastError, status.reconnectAttempt, status.isSuspended)
    break
  }

  for try await event in nearWire.events {
    let decoded = try event.decode(NearWireConsumerPayload.self)
    _ = try await nearWire.reply(
      to: event,
      type: "fixture.reply",
      content: decoded
    )
    break
  }

  _ = await nearWire.clearBufferedEvents()
  await nearWire.suspendConnection()
  await nearWire.resumeConnection()
  await nearWire.disconnect()
  await nearWire.shutdown()
}
