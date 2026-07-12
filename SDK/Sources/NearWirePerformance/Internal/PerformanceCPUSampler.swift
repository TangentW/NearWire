import Foundation

struct PerformanceCPUBaseline: Sendable {
  let cumulativeSeconds: Double
  let instant: ContinuousClock.Instant
}

struct PerformanceCPUSampler: Sendable {
  private(set) var baseline: PerformanceCPUBaseline?
  private let readCumulativeSeconds: @Sendable () -> Double?

  init(readCumulativeSeconds: @escaping @Sendable () -> Double?) {
    self.readCumulativeSeconds = readCumulativeSeconds
  }

  mutating func prime(at instant: ContinuousClock.Instant) {
    guard let value = validReading() else {
      baseline = nil
      return
    }
    baseline = PerformanceCPUBaseline(cumulativeSeconds: value, instant: instant)
  }

  mutating func sample(at instant: ContinuousClock.Instant) -> Double? {
    guard let value = validReading() else { return nil }
    guard let baseline else {
      self.baseline = PerformanceCPUBaseline(cumulativeSeconds: value, instant: instant)
      return nil
    }

    let elapsed = baseline.instant.duration(to: instant)
    guard let elapsedSeconds = PerformanceDurationConversion.finitePositiveSeconds(elapsed),
      value >= baseline.cumulativeSeconds
    else {
      self.baseline = PerformanceCPUBaseline(cumulativeSeconds: value, instant: instant)
      return nil
    }

    let percentage = ((value - baseline.cumulativeSeconds) / elapsedSeconds) * 100
    guard percentage.isFinite, percentage >= 0 else {
      self.baseline = PerformanceCPUBaseline(cumulativeSeconds: value, instant: instant)
      return nil
    }

    self.baseline = PerformanceCPUBaseline(cumulativeSeconds: value, instant: instant)
    return percentage
  }

  private func validReading() -> Double? {
    guard let value = readCumulativeSeconds(), value.isFinite, value >= 0 else { return nil }
    return value
  }
}
