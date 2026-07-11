import Foundation

@_spi(NearWireInternal) public struct EventRateLimit: Codable, Equatable, Hashable, Sendable {
  public static let minimumPositiveEventsPerSecond = 0.000_000_001
  public static let maximumEventsPerSecond = 100_000.0

  public let eventsPerSecond: Double

  public init(eventsPerSecond: Double) throws {
    let isPaused = eventsPerSecond == 0
    let isSupportedPositiveRate =
      (Self.minimumPositiveEventsPerSecond...Self.maximumEventsPerSecond)
      .contains(eventsPerSecond)
    guard eventsPerSecond.isFinite, isPaused || isSupportedPositiveRate
    else {
      throw FlowControlError(
        code: .invalidRate,
        path: "eventsPerSecond",
        message:
          "Event rate must be zero or finite between 0.000000001 and 100,000."
      )
    }
    self.eventsPerSecond = eventsPerSecond
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(eventsPerSecond: container.decode(Double.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(eventsPerSecond)
  }
}

@_spi(NearWireInternal) public struct DirectionalEventRates: Equatable, Sendable {
  public let appUplink: EventRateLimit
  public let appDownlink: EventRateLimit

  public init(appUplink: EventRateLimit, appDownlink: EventRateLimit) {
    self.appUplink = appUplink
    self.appDownlink = appDownlink
  }

  public static func effective(
    viewerRequested: DirectionalEventRates,
    appMaximum: DirectionalEventRates
  ) throws -> DirectionalEventRates {
    try DirectionalEventRates(
      appUplink: EventRateLimit(
        eventsPerSecond: min(
          viewerRequested.appUplink.eventsPerSecond,
          appMaximum.appUplink.eventsPerSecond
        )
      ),
      appDownlink: EventRateLimit(
        eventsPerSecond: min(
          viewerRequested.appDownlink.eventsPerSecond,
          appMaximum.appDownlink.eventsPerSecond
        )
      )
    )
  }
}

@_spi(NearWireInternal) public struct EventTokenBucket: Equatable, Sendable {
  public static let defaultBurstDurationSeconds = 2.0

  public private(set) var rate: EventRateLimit
  public private(set) var burstDurationSeconds: Double
  public private(set) var availableTokens: Double
  public private(set) var capacity: Double
  public private(set) var lastUpdateNanoseconds: UInt64

  public init(
    rate: EventRateLimit,
    burstDurationSeconds: Double = Self.defaultBurstDurationSeconds,
    startNanoseconds: UInt64
  ) throws {
    try Self.validateBurstDuration(burstDurationSeconds)
    let capacity = try Self.capacity(rate: rate, burstDurationSeconds: burstDurationSeconds)
    guard capacity.isFinite else {
      throw FlowControlError(
        code: .invalidRate,
        path: "burstCapacity",
        message: "Token capacity must be finite."
      )
    }
    self.rate = rate
    self.burstDurationSeconds = burstDurationSeconds
    self.capacity = capacity
    availableTokens = capacity
    lastUpdateNanoseconds = startNanoseconds
  }

  public mutating func availableWholeTokens(atNanoseconds now: UInt64) throws -> Int {
    try refill(to: now)
    return Int(availableTokens.rounded(.down))
  }

  public mutating func consume(_ count: Int, atNanoseconds now: UInt64) throws {
    guard count >= 0 else {
      throw FlowControlError(
        code: .invalidTokenCount,
        path: "count",
        message: "Consumed event count cannot be negative."
      )
    }
    var planned = self
    try planned.refill(to: now)
    guard Double(count) <= planned.availableTokens.rounded(.down) else {
      throw FlowControlError(
        code: .invalidTokenCount,
        path: "count",
        message: "Requested events exceed available whole tokens."
      )
    }
    planned.availableTokens -= Double(count)
    self = planned
  }

  @_spi(NearWireInternal) public mutating func consumePrevalidated(_ count: Int) {
    precondition(count >= 0 && Double(count) <= availableTokens.rounded(.down))
    availableTokens -= Double(count)
  }

  public mutating func reconfigure(
    rate newRate: EventRateLimit,
    burstDurationSeconds newBurstDuration: Double? = nil,
    atNanoseconds now: UInt64
  ) throws {
    var planned = self
    try planned.refill(to: now)
    let burst = newBurstDuration ?? planned.burstDurationSeconds
    try Self.validateBurstDuration(burst)
    let newCapacity = try Self.capacity(rate: newRate, burstDurationSeconds: burst)
    planned.rate = newRate
    planned.burstDurationSeconds = burst
    planned.capacity = newCapacity
    planned.availableTokens =
      newRate.eventsPerSecond == 0
      ? 0
      : min(planned.availableTokens, newCapacity)
    self = planned
  }

  public mutating func delayUntilNextTokenNanoseconds(
    atNanoseconds now: UInt64
  ) throws -> UInt64? {
    try refill(to: now)
    guard rate.eventsPerSecond > 0 else { return nil }
    guard availableTokens < 1 else { return 0 }
    let seconds = (1 - availableTokens) / rate.eventsPerSecond
    let nanoseconds = (seconds * 1_000_000_000).rounded(.up)
    guard nanoseconds.isFinite, nanoseconds < Double(UInt64.max) else {
      throw FlowControlError(
        code: .arithmeticOverflow,
        path: "nextTokenDelay",
        message: "Next-token delay cannot be represented."
      )
    }
    var candidate = UInt64(nanoseconds)
    while projectedTokens(afterNanoseconds: candidate) < 1 {
      let (next, overflow) = candidate.addingReportingOverflow(1)
      guard !overflow else {
        throw FlowControlError(
          code: .arithmeticOverflow,
          path: "nextTokenDelay",
          message: "Next-token delay cannot be represented."
        )
      }
      candidate = next
    }
    return candidate
  }

  private mutating func refill(to now: UInt64) throws {
    guard now >= lastUpdateNanoseconds else {
      throw FlowControlError(
        code: .invalidClock,
        path: "nowNanoseconds",
        message: "Token-bucket clock moved backward."
      )
    }
    let elapsed = now - lastUpdateNanoseconds
    let replenished = Double(elapsed) / 1_000_000_000 * rate.eventsPerSecond
    guard replenished.isFinite else {
      throw FlowControlError(
        code: .arithmeticOverflow,
        path: "availableTokens",
        message: "Token refill is not finite."
      )
    }
    availableTokens = min(capacity, availableTokens + replenished)
    lastUpdateNanoseconds = now
  }

  private static func validateBurstDuration(_ value: Double) throws {
    guard value.isFinite, (0.001...60).contains(value) else {
      throw FlowControlError(
        code: .invalidRate,
        path: "burstDurationSeconds",
        message: "Burst duration must be finite and between 0.001 and 60 seconds."
      )
    }
  }

  private func projectedTokens(afterNanoseconds delay: UInt64) -> Double {
    let replenished = Double(delay) / 1_000_000_000 * rate.eventsPerSecond
    return min(capacity, availableTokens + replenished)
  }

  private static func capacity(
    rate: EventRateLimit,
    burstDurationSeconds: Double
  ) throws -> Double {
    guard rate.eventsPerSecond > 0 else { return 0 }
    let calculated = rate.eventsPerSecond * burstDurationSeconds
    guard calculated.isFinite else {
      throw FlowControlError(
        code: .invalidRate,
        path: "burstCapacity",
        message: "Token capacity must be finite."
      )
    }
    return max(1, calculated)
  }
}
