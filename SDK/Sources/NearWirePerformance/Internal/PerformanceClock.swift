import Foundation

struct PerformanceClock: Sendable {
  let now: @Sendable () -> ContinuousClock.Instant
  let sleep: @Sendable (Duration) async throws -> Void

  static let live: PerformanceClock = {
    let clock = ContinuousClock()
    return PerformanceClock(
      now: { clock.now },
      sleep: { duration in try await clock.sleep(for: duration) }
    )
  }()
}

enum PerformanceDurationConversion {
  static let maximumJSONSafeUnsigned = UInt64(Int64.max)

  static func positiveRoundedMilliseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    guard components.seconds >= 0, components.attoseconds >= 0 else { return 1 }

    let (secondsMilliseconds, secondsOverflow) = UInt64(components.seconds)
      .multipliedReportingOverflow(by: 1_000)
    guard !secondsOverflow else { return maximumJSONSafeUnsigned }

    let fractionalAttoseconds = UInt64(components.attoseconds)
    let fractionalMilliseconds = fractionalAttoseconds / 1_000_000_000_000_000
    let remainder = fractionalAttoseconds % 1_000_000_000_000_000
    let roundedFraction = fractionalMilliseconds + (remainder >= 500_000_000_000_000 ? 1 : 0)
    let (result, additionOverflow) = secondsMilliseconds.addingReportingOverflow(roundedFraction)
    guard !additionOverflow else { return maximumJSONSafeUnsigned }
    return min(max(result, 1), maximumJSONSafeUnsigned)
  }

  static func finitePositiveSeconds(_ duration: Duration) -> Double? {
    let components = duration.components
    let seconds =
      Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
    guard seconds.isFinite, seconds > 0 else { return nil }
    return seconds
  }
}
