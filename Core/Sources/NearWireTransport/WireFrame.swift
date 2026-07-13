import Foundation

@_spi(NearWireInternal) public struct WireFrame: Equatable, Sendable {
  public let lane: WireLane
  public let payload: Data

  public init(lane: WireLane, payload: Data) {
    self.lane = lane
    self.payload = payload
  }
}

extension WireFrame: CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "WireFrame(redacted, bytes: \(payload.count))" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: ["byteCount": payload.count], displayStyle: .struct)
  }
}

@_spi(NearWireInternal) public enum WireFrameDeliveryDecision: Equatable, Sendable {
  case consume
  case pause
}

@_spi(NearWireInternal) public enum WireFrameDecoderProgress: Equatable, Sendable {
  case drained
  case needsMoreBytes
  case pausedOnCompleteFrame
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
  private enum ConsumptionMode: Equatable, Sendable {
    case legacy
    case resumable
  }

  public let limits: WireFrameLimits

  private var prefix: [UInt8] = []
  private var declaredLength: Int?
  private var lane: WireLane?
  private var payload = Data()
  private var resumableInput = Data()
  private var resumableFrame: WireFrame?
  private var terminalError: WireProtocolError?
  private var consumptionMode: ConsumptionMode?

  public init(limits: WireFrameLimits = .default) {
    self.limits = limits
    prefix.reserveCapacity(4)
  }

  public var isAtFrameBoundary: Bool {
    prefix.isEmpty && declaredLength == nil && lane == nil && payload.isEmpty
      && resumableInput.isEmpty && resumableFrame == nil
  }

  public var isFailed: Bool { terminalError != nil }

  public var retainedByteCount: Int {
    var count = prefix.count + payload.count + resumableInput.count
    if lane != nil { count += 1 }
    if let resumableFrame {
      let (frameBytes, overflow) = resumableFrame.payload.count.addingReportingOverflow(5)
      let (total, totalOverflow) = count.addingReportingOverflow(frameBytes)
      count = overflow || totalOverflow ? Int.max : total
    }
    return count
  }

  /// Incrementally decodes bounded input and can pause before delivering a complete frame.
  ///
  /// A paused frame and every later byte remain owned by this value in wire order. Supplying
  /// empty input continues previously retained work. The caller must bound the transient input
  /// `Data` separately when computing its complete cross-layer retention budget.
  public mutating func consumeResumable(
    _ bytes: Data,
    maximumCompletedFrames: Int,
    maximumRetainedBytes: Int,
    preflightLane: (WireLane) throws -> Void = { _ in },
    onFrame: (WireFrame) throws -> WireFrameDeliveryDecision
  ) throws -> WireFrameDecoderProgress {
    if let terminalError {
      throw WireProtocolError(
        code: .decoderFailed,
        path: terminalError.path,
        message: "Frame decoder is terminal after a prior error.",
        disposition: .connectionTerminal
      )
    }
    guard maximumCompletedFrames > 0, maximumRetainedBytes > 0 else {
      throw WireProtocolError(
        code: .invalidConfiguration,
        path: "resumableDecoderLimits",
        message: "Resumable decoder bounds must be positive."
      )
    }
    try activate(.resumable)
    let (prospectiveBytes, overflow) = retainedByteCount.addingReportingOverflow(bytes.count)
    guard !overflow, prospectiveBytes <= maximumRetainedBytes else {
      let error = WireProtocolError(
        code: .frameTooLarge,
        path: "retainedInput",
        message: "Retained frame input exceeds the active bound.",
        disposition: .connectionTerminal
      )
      terminalError = error
      throw error
    }

    do {
      resumableInput.append(bytes)
      var completedFrames = 0
      var index = resumableInput.startIndex

      func retainedResult(
        _ result: WireFrameDecoderProgress,
        input: inout Data,
        through index: Data.Index
      ) -> WireFrameDecoderProgress {
        if index > input.startIndex {
          input.removeSubrange(input.startIndex..<index)
        }
        return result
      }

      while true {
        if let frame = resumableFrame {
          guard completedFrames < maximumCompletedFrames else {
            return retainedResult(
              .pausedOnCompleteFrame,
              input: &resumableInput,
              through: index
            )
          }
          let decision: WireFrameDeliveryDecision
          do {
            decision = try onFrame(frame)
          } catch {
            throw WireProtocolError(
              code: .callbackFailed,
              path: "$",
              message: "Frame consumer rejected a decoded frame."
            )
          }
          guard decision == .consume else {
            return retainedResult(
              .pausedOnCompleteFrame,
              input: &resumableInput,
              through: index
            )
          }
          resumableFrame = nil
          completedFrames += 1
          continue
        }

        guard index < resumableInput.endIndex else {
          let result: WireFrameDecoderProgress =
            prefix.isEmpty && declaredLength == nil && lane == nil && payload.isEmpty
            ? .drained : .needsMoreBytes
          return retainedResult(result, input: &resumableInput, through: index)
        }

        if prefix.count < 4 {
          let needed = 4 - prefix.count
          let available = resumableInput.distance(from: index, to: resumableInput.endIndex)
          let count = min(needed, available)
          let end = resumableInput.index(index, offsetBy: count)
          prefix.append(contentsOf: resumableInput[index..<end])
          index = end
          if prefix.count < 4 { continue }
          try parsePrefix()
        }

        if lane == nil {
          guard index < resumableInput.endIndex else { continue }
          let rawLane = resumableInput[index]
          index = resumableInput.index(after: index)
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
        let available = resumableInput.distance(from: index, to: resumableInput.endIndex)
        let count = min(needed, available)
        if count > 0 {
          let end = resumableInput.index(index, offsetBy: count)
          payload.append(contentsOf: resumableInput[index..<end])
          index = end
        }

        if payload.count == payloadLength {
          resumableFrame = WireFrame(lane: lane, payload: payload)
          resetFrameState()
        }
      }
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
    try activate(.legacy)

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

  private mutating func activate(_ requestedMode: ConsumptionMode) throws {
    guard let currentMode = consumptionMode, currentMode != requestedMode else {
      consumptionMode = requestedMode
      return
    }
    guard isAtFrameBoundary else {
      let error = WireProtocolError(
        code: .invalidConfiguration,
        path: "decoderMode",
        message: "A frame decoder cannot switch consumption APIs while bytes are retained.",
        disposition: .connectionTerminal
      )
      terminalError = error
      throw error
    }
    consumptionMode = requestedMode
  }

  private mutating func resetFrameState() {
    prefix.removeAll(keepingCapacity: true)
    declaredLength = nil
    lane = nil
    payload.removeAll(keepingCapacity: true)
  }
}

extension WireFrameDecoder: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var description: String { "WireFrameDecoder(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .struct)
  }
}
