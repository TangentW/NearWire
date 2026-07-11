import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

@_spi(NearWireInternal) public struct WireSequenceCounter: Equatable, Sendable {
  public let sessionEpoch: SessionEpoch
  public let direction: EventDirection
  public private(set) var nextRawValue: UInt64?

  public init(
    sessionEpoch: SessionEpoch,
    direction: EventDirection
  ) {
    self.sessionEpoch = sessionEpoch
    self.direction = direction
    nextRawValue = 0
  }

  init(
    sessionEpoch: SessionEpoch,
    direction: EventDirection,
    uncheckedStartingAt: UInt64
  ) {
    self.sessionEpoch = sessionEpoch
    self.direction = direction
    nextRawValue = uncheckedStartingAt
  }

  public mutating func allocate() throws -> EventSequence {
    guard let value = nextRawValue else {
      throw WireProtocolError(
        code: .arithmeticOverflow,
        path: "sequence",
        message: "Directional sequence is exhausted."
      )
    }
    nextRawValue = value == UInt64.max ? nil : value + 1
    return EventSequence(value)
  }
}

@_spi(NearWireInternal) public struct WireSequenceValidator: Equatable, Sendable {
  public let sessionEpoch: SessionEpoch
  public let direction: EventDirection
  public private(set) var nextExpectedRawValue: UInt64?

  public init(
    sessionEpoch: SessionEpoch,
    direction: EventDirection
  ) {
    self.sessionEpoch = sessionEpoch
    self.direction = direction
    nextExpectedRawValue = 0
  }

  init(
    sessionEpoch: SessionEpoch,
    direction: EventDirection,
    uncheckedStartingAt: UInt64
  ) {
    self.sessionEpoch = sessionEpoch
    self.direction = direction
    nextExpectedRawValue = uncheckedStartingAt
  }

  public mutating func validate(_ envelope: EventEnvelope) throws {
    guard envelope.sessionEpoch == sessionEpoch else {
      throw WireProtocolError(
        code: .invalidSequence,
        path: "sessionEpoch",
        message: "Event belongs to a different session epoch."
      )
    }
    guard envelope.direction == direction else {
      throw WireProtocolError(
        code: .invalidSequence,
        path: "direction",
        message: "Event belongs to a different directional sequence."
      )
    }
    guard let expected = nextExpectedRawValue else {
      throw WireProtocolError(
        code: .arithmeticOverflow,
        path: "sequence",
        message: "Directional sequence is exhausted."
      )
    }
    guard envelope.sequence.rawValue == expected else {
      let relationship = envelope.sequence.rawValue < expected ? "duplicate" : "gap"
      throw WireProtocolError(
        code: .invalidSequence,
        path: "sequence",
        message: "Event sequence contains a \(relationship)."
      )
    }
    nextExpectedRawValue = expected == UInt64.max ? nil : expected + 1
  }
}
