import Foundation
@_spi(NearWireInternal) import NearWireCore
@_spi(NearWireInternal) import NearWireFlowControl

struct ViewerRatePolicy: Codable, Equatable, Sendable {
  static let `default` = try! ViewerRatePolicy(appUplink: 20, appDownlink: 10)

  let appUplink: Double
  let appDownlink: Double

  init(appUplink: Double, appDownlink: Double) throws {
    _ = try EventRateLimit(eventsPerSecond: appUplink)
    _ = try EventRateLimit(eventsPerSecond: appDownlink)
    self.appUplink = appUplink == 0 ? 0 : appUplink
    self.appDownlink = appDownlink == 0 ? 0 : appDownlink
  }
}

extension ViewerRatePolicy: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerRatePolicy(configured)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

struct ViewerLogicalRoute: Codable, Hashable, Sendable {
  let installationID: String
  let applicationIdentifier: String?

  init(installationID: EndpointID, applicationIdentifier: String?) {
    self.installationID = installationID.rawValue
    self.applicationIdentifier = applicationIdentifier
  }

  var storageKey: String {
    let bundle = applicationIdentifier ?? "<missing>"
    return "\(installationID.utf8.count):\(installationID)|\(bundle.utf8.count):\(bundle)"
  }
}

extension ViewerLogicalRoute: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  var description: String { "ViewerLogicalRoute(unauthenticated)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

final class ViewerDevicePreferences: @unchecked Sendable {
  private struct TimedValue<Value: Codable & Sendable>: Codable, Sendable {
    var value: Value
    var touchedAt: TimeInterval
  }

  private struct StoredState: Codable, Sendable {
    var schemaVersion: Int
    var globalPolicy: ViewerRatePolicy
    var bundlePolicies: [String: TimedValue<ViewerRatePolicy>]
    var routeNicknames: [String: TimedValue<String>]
  }

  static let maximumBundlePolicies = 256
  static let maximumRouteNicknames = 256
  static let maximumStoredBytes = 2 * 1_024 * 1_024
  static let storageKey = "viewer.devicePreferences.v1"

  private let lock = NSLock()
  private let defaults: UserDefaults
  private let now: @Sendable () -> Date
  private var state: StoredState

  init(
    defaults: UserDefaults = .standard,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.defaults = defaults
    self.now = now
    state = Self.load(from: defaults) ?? Self.emptyState()
    repairAndPersistIfNeeded()
  }

  func globalPolicy() -> ViewerRatePolicy {
    withLock { state.globalPolicy }
  }

  func setGlobalPolicy(_ policy: ViewerRatePolicy) {
    withLock {
      state.globalPolicy = policy
      persistLocked()
    }
  }

  func requestedPolicy(
    for route: ViewerLogicalRoute,
    sessionOverride: ViewerRatePolicy? = nil
  ) -> ViewerRatePolicy {
    if let sessionOverride { return sessionOverride }
    return withLock {
      guard let bundle = route.applicationIdentifier,
        let stored = state.bundlePolicies[bundle]
      else { return state.globalPolicy }
      return stored.value
    }
  }

  func setBundlePolicy(_ policy: ViewerRatePolicy, bundleID: String) {
    guard Self.isValidKey(bundleID) else { return }
    withLock {
      state.bundlePolicies[bundleID] = TimedValue(value: policy, touchedAt: safeNowLocked())
      Self.evictOldest(&state.bundlePolicies, limit: Self.maximumBundlePolicies)
      persistLocked()
    }
  }

  func nickname(for route: ViewerLogicalRoute) -> String? {
    withLock {
      let key = route.storageKey
      guard let stored = state.routeNicknames[key] else { return nil }
      return stored.value
    }
  }

  @discardableResult
  func setNickname(_ nickname: String?, for route: ViewerLogicalRoute) -> Bool {
    withLock {
      let key = route.storageKey
      guard let nickname else {
        state.routeNicknames.removeValue(forKey: key)
        persistLocked()
        return true
      }
      guard let validated = Self.validatedNickname(nickname) else { return false }
      state.routeNicknames[key] = TimedValue(value: validated, touchedAt: safeNowLocked())
      Self.evictOldest(&state.routeNicknames, limit: Self.maximumRouteNicknames)
      persistLocked()
      return true
    }
  }

  private func repairAndPersistIfNeeded() {
    withLock {
      guard state.schemaVersion == 1 else {
        state = Self.emptyState()
        persistLocked()
        return
      }
      state.bundlePolicies = state.bundlePolicies.filter { key, item in
        Self.isValidKey(key) && Self.isValidTimestamp(item.touchedAt)
          && Self.isValidPolicy(item.value)
      }
      state.routeNicknames = state.routeNicknames.filter { key, item in
        Self.isValidKey(key) && Self.isValidTimestamp(item.touchedAt)
          && Self.validatedNickname(item.value) == item.value
      }
      Self.evictOldest(&state.bundlePolicies, limit: Self.maximumBundlePolicies)
      Self.evictOldest(&state.routeNicknames, limit: Self.maximumRouteNicknames)
      persistLocked()
    }
  }

  private func safeNowLocked() -> TimeInterval {
    let value = now().timeIntervalSince1970
    return Self.isValidTimestamp(value) ? value : 0
  }

  private func persistLocked() {
    if let data = try? JSONEncoder().encode(state) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private static func load(from defaults: UserDefaults) -> StoredState? {
    guard let data = defaults.data(forKey: storageKey),
      data.count <= maximumStoredBytes,
      let decoded = try? JSONDecoder().decode(StoredState.self, from: data),
      decoded.schemaVersion == 1,
      (try? ViewerRatePolicy(
        appUplink: decoded.globalPolicy.appUplink,
        appDownlink: decoded.globalPolicy.appDownlink
      )) != nil
    else { return nil }
    return decoded
  }

  private static func emptyState() -> StoredState {
    StoredState(
      schemaVersion: 1,
      globalPolicy: .default,
      bundlePolicies: [:],
      routeNicknames: [:]
    )
  }

  private static func isValidKey(_ value: String) -> Bool {
    (1...512).contains(value.utf8.count)
      && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
  }

  private static func isValidTimestamp(_ value: TimeInterval) -> Bool {
    value.isFinite && (0...253_402_300_799).contains(value)
  }

  private static func isValidPolicy(_ value: ViewerRatePolicy) -> Bool {
    (try? ViewerRatePolicy(
      appUplink: value.appUplink,
      appDownlink: value.appDownlink
    )) != nil
  }

  private static func validatedNickname(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 80,
      trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return trimmed
  }

  private static func evictOldest<Value>(
    _ values: inout [String: TimedValue<Value>],
    limit: Int
  ) where Value: Codable & Sendable {
    while values.count > limit {
      guard
        let key = values.keys.min(by: { lhs, rhs in
          let left = values[lhs]!.touchedAt
          let right = values[rhs]!.touchedAt
          return left == right ? lhs < rhs : left < right
        })
      else { return }
      values.removeValue(forKey: key)
    }
  }
}
