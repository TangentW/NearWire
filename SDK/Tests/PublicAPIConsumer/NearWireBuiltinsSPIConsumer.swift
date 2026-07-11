import Foundation
@_spi(NearWireBuiltins) import NearWire

private struct NearWireBuiltinConsumerPayload: Codable, Sendable {
  let sample: Int
}

func compileNearWireBuiltinsSPI(_ nearWire: NearWire) async throws {
  _ = try await nearWire.sendPlatformEvent(
    type: "nearwire.performance.snapshot",
    content: NearWireBuiltinConsumerPayload(sample: 1),
    policy: .keepLatest(key: "performance-snapshot")
  )
}
