import Foundation
import XCTest

@_spi(NearWireInternal) @testable import NearWireTransport

final class WireFrameTests: XCTestCase {
  func testExactBigEndianFrameAndRoundTrip() throws {
    let payload = Data("{}".utf8)
    let encoded = try WireFrameEncoder.encode(lane: .control, payload: payload)
    XCTAssertEqual(Array(encoded), [0, 0, 0, 3, 1, 123, 125])

    var frames: [WireFrame] = []
    var decoder = WireFrameDecoder()
    try decoder.consume(encoded) { frames.append($0) }
    XCTAssertEqual(frames, [WireFrame(lane: .control, payload: payload)])
    XCTAssertTrue(decoder.isAtFrameBoundary)
  }

  func testByteAtATimeFragmentationAndCoalescedFrames() throws {
    let first = try WireFrameEncoder.encode(lane: .control, payload: Data("{\"a\":1}".utf8))
    let second = try WireFrameEncoder.encode(lane: .event, payload: Data("{\"b\":2}".utf8))
    var decoder = WireFrameDecoder()
    var frames: [WireFrame] = []

    for byte in first {
      try decoder.consume(Data([byte])) { frames.append($0) }
    }
    XCTAssertEqual(frames.count, 1)
    try decoder.consume(second + first) { frames.append($0) }

    XCTAssertEqual(frames.map(\.lane), [.control, .event, .control])
    XCTAssertEqual(
      frames.map(\.payload),
      [
        Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8), Data("{\"a\":1}".utf8),
      ])
  }

  func testEmptyConsumeIsANoOpAndManyFramesStayBounded() throws {
    let encoded = try WireFrameEncoder.encode(lane: .control, payload: Data("{}".utf8))
    var decoder = WireFrameDecoder()
    var frameCount = 0

    try decoder.consume(Data()) { _ in frameCount += 1 }
    for _ in 0..<1_000 {
      try decoder.consume(encoded) { _ in frameCount += 1 }
    }

    XCTAssertEqual(frameCount, 1_000)
    XCTAssertTrue(decoder.isAtFrameBoundary)
  }

  func testInvalidLengthUnknownLaneAndTerminalReuse() throws {
    var short = WireFrameDecoder()
    XCTAssertThrowsError(try short.consume(Data([0, 0, 0, 1])) { _ in }) { error in
      let wireError = error as? WireProtocolError
      XCTAssertEqual(wireError?.code, .invalidFrameLength)
      XCTAssertEqual(wireError?.disposition, .connectionTerminal)
    }
    XCTAssertTrue(short.isFailed)
    assertWireError(.decoderFailed) {
      try short.consume(Data([0, 0, 0, 2, 1, 123])) { _ in }
    }

    var unknownLane = WireFrameDecoder()
    assertWireError(.invalidLane) {
      try unknownLane.consume(Data([0, 0, 0, 2, 9, 123])) { _ in }
    }
  }

  func testLaneSpecificLimitsAreAppliedAfterLaneByte() throws {
    let limits = try WireFrameLimits(
      maximumControlPayloadBytes: 2,
      maximumEventPayloadBytes: 4
    )
    XCTAssertNoThrow(
      try WireFrameEncoder.encode(lane: .control, payload: Data([1, 2]), limits: limits)
    )
    var boundary = WireFrameDecoder(limits: limits)
    var boundaryFrames: [WireFrame] = []
    try boundary.consume(
      WireFrameEncoder.encode(lane: .control, payload: Data([1, 2]), limits: limits)
    ) { boundaryFrames.append($0) }
    XCTAssertEqual(boundaryFrames.first?.payload, Data([1, 2]))
    assertWireError(.frameTooLarge) {
      _ = try WireFrameEncoder.encode(
        lane: .control,
        payload: Data([1, 2, 3]),
        limits: limits
      )
    }

    var decoder = WireFrameDecoder(limits: limits)
    assertWireError(.frameTooLarge) {
      try decoder.consume(Data([0, 0, 0, 4, WireLane.control.rawValue])) { _ in }
    }

    var hardLimit = WireFrameDecoder(limits: limits)
    assertWireError(.frameTooLarge) {
      try hardLimit.consume(Data([1, 0, 0, 2])) { _ in }
    }
    var uint32Maximum = WireFrameDecoder(limits: limits)
    assertWireError(.frameTooLarge) {
      try uint32Maximum.consume(Data([255, 255, 255, 255])) { _ in }
    }
  }

  func testCallbackFailureIsTerminalAndDoesNotExposePrivateError() throws {
    struct PrivateFailure: Error {}
    let frame = try WireFrameEncoder.encode(lane: .control, payload: Data("{}".utf8))
    var decoder = WireFrameDecoder()
    assertWireError(.callbackFailed) {
      try decoder.consume(frame) { _ in throw PrivateFailure() }
    }
    XCTAssertTrue(decoder.isFailed)
  }

  func testLanePreflightRunsOncePerFrameBeforePayloadCopy() throws {
    let control = try WireFrameEncoder.encode(lane: .control, payload: Data("{}".utf8))
    let event = try WireFrameEncoder.encode(lane: .event, payload: Data("[]".utf8))
    var decoder = WireFrameDecoder()
    var lanes: [WireLane] = []
    var frames: [WireFrame] = []

    try decoder.consume(
      control.prefix(5),
      preflightLane: { lanes.append($0) },
      onFrame: { frames.append($0) }
    )
    XCTAssertEqual(lanes, [.control])
    XCTAssertTrue(frames.isEmpty)

    try decoder.consume(
      control.dropFirst(5) + event,
      preflightLane: { lanes.append($0) },
      onFrame: { frames.append($0) }
    )
    XCTAssertEqual(lanes, [.control, .event])
    XCTAssertEqual(frames.map(\.lane), [.control, .event])
  }

  func testLanePreflightFailureIsTerminalAndRetainsNoPayload() throws {
    let encoded = try WireFrameEncoder.encode(
      lane: .event,
      payload: Data(repeating: 0x7B, count: 1_024)
    )
    var decoder = WireFrameDecoder()

    XCTAssertThrowsError(
      try decoder.consume(
        encoded,
        preflightLane: { lane in
          XCTAssertEqual(lane, .event)
          throw WireProtocolError(
            code: .phaseViolation,
            path: "phase",
            message: "Event lane is not active."
          )
        },
        onFrame: { _ in XCTFail("Rejected frame must not be delivered.") }
      )
    ) { error in
      let wireError = error as? WireProtocolError
      XCTAssertEqual(wireError?.code, .phaseViolation)
      XCTAssertEqual(wireError?.disposition, .connectionTerminal)
    }
    XCTAssertEqual(retainedPayloadByteCount(decoder), 0)
    assertWireError(.decoderFailed) {
      try decoder.consume(encoded) { _ in }
    }
  }

  func testLaneBoundPrecedesPreflightAndPrivateFailureIsNormalized() throws {
    let limits = try WireFrameLimits(
      maximumControlPayloadBytes: 2,
      maximumEventPayloadBytes: 2
    )
    var oversized = WireFrameDecoder(limits: limits)
    var preflightCount = 0
    assertWireError(.frameTooLarge) {
      try oversized.consume(
        Data([0, 0, 0, 4, WireLane.control.rawValue]),
        preflightLane: { _ in preflightCount += 1 },
        onFrame: { _ in }
      )
    }
    XCTAssertEqual(preflightCount, 0)

    struct PrivateFailure: Error {}
    let encoded = try WireFrameEncoder.encode(lane: .control, payload: Data("{}".utf8))
    var privateFailure = WireFrameDecoder()
    assertWireError(.decoderFailed) {
      try privateFailure.consume(
        encoded,
        preflightLane: { _ in throw PrivateFailure() },
        onFrame: { _ in }
      )
    }
  }

  func testFinishRejectsTruncatedPrefixAndPayload() throws {
    var prefix = WireFrameDecoder()
    try prefix.consume(Data([0, 0, 0])) { _ in }
    assertWireError(.invalidFrameLength) { try prefix.finish() }

    var payload = WireFrameDecoder()
    try payload.consume(Data([0, 0, 0, 3, 1, 123])) { _ in }
    assertWireError(.invalidFrameLength) { try payload.finish() }

    var complete = WireFrameDecoder()
    try complete.consume(
      WireFrameEncoder.encode(lane: .control, payload: Data("{}".utf8))
    ) { _ in }
    XCTAssertNoThrow(try complete.finish())
  }

  private func retainedPayloadByteCount(_ decoder: WireFrameDecoder) -> Int {
    for child in Mirror(reflecting: decoder).children where child.label == "payload" {
      return (child.value as? Data)?.count ?? -1
    }
    return -1
  }
}
