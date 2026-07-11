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
    eventStreamBufferCapacity: 64
  )
  let nearWire = NearWire(configuration: configuration)
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
  await nearWire.shutdown()
}
