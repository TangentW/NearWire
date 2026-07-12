import Foundation

struct PerformanceDisplayAccumulator: Sendable {
  private var callbackCount: UInt64 = 0
  private var firstTimestamp: TimeInterval?
  private var lastTimestamp: TimeInterval?
  private var intervalIsInvalid = false

  mutating func record(timestamp: TimeInterval) {
    guard timestamp.isFinite else {
      intervalIsInvalid = true
      return
    }
    if let lastTimestamp, timestamp <= lastTimestamp {
      intervalIsInvalid = true
      return
    }
    if firstTimestamp == nil { firstTimestamp = timestamp }
    lastTimestamp = timestamp
    if callbackCount < UInt64.max { callbackCount += 1 }
  }

  mutating func consumeEstimatedFramesPerSecond() -> Double? {
    defer { reset() }
    guard !intervalIsInvalid, callbackCount >= 2,
      let firstTimestamp, let lastTimestamp
    else { return nil }
    let elapsed = lastTimestamp - firstTimestamp
    let value = Double(callbackCount - 1) / elapsed
    guard elapsed.isFinite, elapsed > 0, value.isFinite, value > 0 else { return nil }
    return value
  }

  mutating func reset() {
    callbackCount = 0
    firstTimestamp = nil
    lastTimestamp = nil
    intervalIsInvalid = false
  }
}
