import Foundation

struct ViewerStorageConfiguration: Codable, Equatable, Sendable {
  static let defaultCapacityBytes: Int64 = 3 * 1_024 * 1_024 * 1_024
  static let minimumCapacityBytes: Int64 = 64 * 1_024 * 1_024
  static let maximumCapacityBytes: Int64 = 1_024 * 1_024 * 1_024 * 1_024
  static let defaultHistoryRetentionDays = 7
  static let minimumHistoryRetentionDays = 1
  static let maximumHistoryRetentionDays = 3_650

  let capacityBytes: Int64
  let historyRetentionDays: Int

  init(capacityBytes: Int64, historyRetentionDays: Int) throws {
    guard Self.minimumCapacityBytes...Self.maximumCapacityBytes ~= capacityBytes,
      Self.minimumHistoryRetentionDays...Self.maximumHistoryRetentionDays
        ~= historyRetentionDays
    else { throw ViewerStoreError.invalidValue }
    self.capacityBytes = capacityBytes
    self.historyRetentionDays = historyRetentionDays
  }

  static let `default` = try! ViewerStorageConfiguration(
    capacityBytes: defaultCapacityBytes,
    historyRetentionDays: defaultHistoryRetentionDays
  )
}

final class ViewerStoragePreferences: @unchecked Sendable {
  private enum Key {
    static let version = "nearwire.storage.version"
    static let capacityBytes = "nearwire.storage.capacityBytes"
    static let historyRetentionDays = "nearwire.storage.historyRetentionDays"
  }

  private let defaults: UserDefaults
  private let lock = NSLock()

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func load() -> ViewerStorageConfiguration {
    lock.lock()
    defer { lock.unlock() }
    guard let version = defaults.object(forKey: Key.version) as? NSNumber,
      Self.exactInteger(version) == 1,
      let capacity = defaults.object(forKey: Key.capacityBytes) as? NSNumber,
      let retention = defaults.object(forKey: Key.historyRetentionDays) as? NSNumber,
      let capacityValue = Self.exactInteger(capacity),
      let retentionValue = Self.exactInteger(retention),
      retentionValue >= Int64(Int.min), retentionValue <= Int64(Int.max),
      let value = try? ViewerStorageConfiguration(
        capacityBytes: capacityValue,
        historyRetentionDays: Int(retentionValue)
      )
    else {
      persistLocked(.default)
      return .default
    }
    return value
  }

  func save(_ configuration: ViewerStorageConfiguration) {
    lock.lock()
    persistLocked(configuration)
    lock.unlock()
  }

  private func persistLocked(_ configuration: ViewerStorageConfiguration) {
    defaults.set(1, forKey: Key.version)
    defaults.set(NSNumber(value: configuration.capacityBytes), forKey: Key.capacityBytes)
    defaults.set(
      NSNumber(value: configuration.historyRetentionDays),
      forKey: Key.historyRetentionDays
    )
  }

  private static func exactInteger(_ number: NSNumber) -> Int64? {
    guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let type = String(cString: number.objCType)
    guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else {
      return nil
    }
    return number.int64Value
  }
}

extension ViewerStoragePreferences: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerStoragePreferences(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
