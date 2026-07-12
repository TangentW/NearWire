import Foundation

struct PerformanceBatteryOwnership: Sendable {
  private(set) var claimCount = 0
  private var initialValue = false
  private var observedConflict = false

  mutating func claim(currentValue: Bool) -> Bool? {
    if claimCount == 0 {
      initialValue = currentValue
      observedConflict = false
      claimCount = 1
      return true
    }
    claimCount += 1
    return nil
  }

  mutating func observe(currentValue: Bool) -> Bool {
    if !currentValue { observedConflict = true }
    return currentValue
  }

  mutating func release(currentValue: Bool) -> Bool? {
    guard claimCount > 0 else { return nil }
    claimCount -= 1
    guard claimCount == 0 else { return nil }
    defer {
      initialValue = false
      observedConflict = false
    }
    guard !observedConflict, currentValue else { return nil }
    return initialValue
  }
}
