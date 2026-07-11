import Foundation

@_spi(NearWireInternal) public struct WireFrame: Equatable, Sendable {
  public let lane: WireLane
  public let payload: Data

  public init(lane: WireLane, payload: Data) {
    self.lane = lane
    self.payload = payload
  }
}

@_spi(NearWireInternal) public enum WireFrameEncoder {
  public static func encode(
    lane: WireLane,
    payload: Data,
    limits: WireFrameLimits = .default
  ) throws -> Data {
    guard !payload.isEmpty else {
      throw WireProtocolError(
        code: .invalidFrameLength,
        path: "payload",
        message: "Frame JSON payload cannot be empty."
      )
    }
    guard payload.count <= limits.maximumPayloadBytes(for: lane) else {
      throw WireProtocolError(
        code: .frameTooLarge,
        path: "payload",
        message: "Frame payload exceeds its lane limit."
      )
    }
    let (declaredLength, overflow) = payload.count.addingReportingOverflow(1)
    guard !overflow, declaredLength <= Int(UInt32.max) else {
      throw WireProtocolError(
        code: .arithmeticOverflow,
        path: "length",
        message: "Frame length cannot be represented by UInt32."
      )
    }

    let length = UInt32(declaredLength)
    var data = Data(capacity: declaredLength + 4)
    data.append(UInt8((length >> 24) & 0xFF))
    data.append(UInt8((length >> 16) & 0xFF))
    data.append(UInt8((length >> 8) & 0xFF))
    data.append(UInt8(length & 0xFF))
    data.append(lane.rawValue)
    data.append(payload)
    return data
  }
}

@_spi(NearWireInternal) public struct WireFrameDecoder: Sendable {
  public let limits: WireFrameLimits

  private var prefix: [UInt8] = []
  private var declaredLength: Int?
  private var lane: WireLane?
  private var payload = Data()
  private var terminalError: WireProtocolError?

  public init(limits: WireFrameLimits = .default) {
    self.limits = limits
    prefix.reserveCapacity(4)
  }

  public var isAtFrameBoundary: Bool {
    prefix.isEmpty && declaredLength == nil && lane == nil && payload.isEmpty
  }

  public var isFailed: Bool { terminalError != nil }

  public mutating func consume(
    _ bytes: Data,
    preflightLane: (WireLane) throws -> Void = { _ in },
    onFrame: (WireFrame) throws -> Void
  ) throws {
    let exceededLimit = try consumeBounded(
      bytes,
      maximumCompletedFrames: Int.max,
      preflightLane: preflightLane,
      onFrame: onFrame
    )
    precondition(!exceededLimit)
  }

  public mutating func consumeBounded(
    _ bytes: Data,
    maximumCompletedFrames: Int,
    preflightLane: (WireLane) throws -> Void = { _ in },
    onFrame: (WireFrame) throws -> Void
  ) throws -> Bool {
    if let terminalError {
      throw WireProtocolError(
        code: .decoderFailed,
        path: terminalError.path,
        message: "Frame decoder is terminal after a prior error.",
        disposition: .connectionTerminal
      )
    }
    guard maximumCompletedFrames > 0 else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "maximumCompletedFrames",
        message: "Completed-frame bound must be positive."
      )
    }

    do {
      var index = bytes.startIndex
      var completedFrames = 0
      while index < bytes.endIndex {
        if prefix.count < 4 {
          let needed = 4 - prefix.count
          let available = bytes.distance(from: index, to: bytes.endIndex)
          let count = min(needed, available)
          let end = bytes.index(index, offsetBy: count)
          prefix.append(contentsOf: bytes[index..<end])
          index = end
          if prefix.count < 4 { continue }
          try parsePrefix()
        }

        if lane == nil {
          guard index < bytes.endIndex else { continue }
          let rawLane = bytes[index]
          index = bytes.index(after: index)
          guard let decodedLane = WireLane(rawValue: rawLane) else {
            throw WireProtocolError(
              code: .invalidLane,
              path: "lane",
              message: "Frame uses an unknown lane byte."
            )
          }
          guard let declaredLength else {
            throw WireProtocolError(
              code: .decoderFailed,
              path: "length",
              message: "Frame decoder lost its declared length."
            )
          }
          let payloadLength = declaredLength - 1
          guard payloadLength <= limits.maximumPayloadBytes(for: decodedLane) else {
            throw WireProtocolError(
              code: .frameTooLarge,
              path: "length",
              message: "Frame exceeds its lane-specific payload limit."
            )
          }
          try preflightLane(decodedLane)
          lane = decodedLane
          payload.reserveCapacity(payloadLength)
        }

        guard let declaredLength, let lane else {
          throw WireProtocolError(
            code: .decoderFailed,
            path: "$",
            message: "Frame decoder entered an invalid state."
          )
        }
        let payloadLength = declaredLength - 1
        let needed = payloadLength - payload.count
        let available = bytes.distance(from: index, to: bytes.endIndex)
        let count = min(needed, available)
        if count > 0 {
          let end = bytes.index(index, offsetBy: count)
          payload.append(contentsOf: bytes[index..<end])
          index = end
        }

        if payload.count == payloadLength {
          let frame = WireFrame(lane: lane, payload: payload)
          resetFrameState()
          do {
            if completedFrames == maximumCompletedFrames { return true }
            try onFrame(frame)
            completedFrames += 1
          } catch {
            throw WireProtocolError(
              code: .callbackFailed,
              path: "$",
              message: "Frame consumer rejected a decoded frame."
            )
          }
        }
      }
      return false
    } catch let error as WireProtocolError {
      let terminal = error.asConnectionTerminal()
      terminalError = terminal
      throw terminal
    } catch {
      let wrapped = WireProtocolError(
        code: .decoderFailed,
        message: "Frame decoding failed.",
        disposition: .connectionTerminal
      )
      terminalError = wrapped
      throw wrapped
    }
  }

  public mutating func finish() throws {
    if terminalError != nil {
      throw WireProtocolError(
        code: .decoderFailed,
        path: "$",
        message: "Frame decoder is terminal after a prior error.",
        disposition: .connectionTerminal
      )
    }
    guard isAtFrameBoundary else {
      let error = WireProtocolError(
        code: .invalidFrameLength,
        path: "length",
        message: "Byte stream ended with an incomplete frame.",
        disposition: .connectionTerminal
      )
      terminalError = error
      throw error
    }
  }

  private mutating func parsePrefix() throws {
    let value = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard value >= 2 else {
      throw WireProtocolError(
        code: .invalidFrameLength,
        path: "length",
        message: "Declared frame length must include a lane and nonempty JSON payload."
      )
    }
    let hardMaximum = WireFrameLimits.hardMaximumPayloadBytes + 1
    guard value <= UInt32(hardMaximum) else {
      throw WireProtocolError(
        code: .frameTooLarge,
        path: "length",
        message: "Declared frame length exceeds the hard limit."
      )
    }
    declaredLength = Int(value)
  }

  private mutating func resetFrameState() {
    prefix.removeAll(keepingCapacity: true)
    declaredLength = nil
    lane = nil
    payload.removeAll(keepingCapacity: true)
  }
}
