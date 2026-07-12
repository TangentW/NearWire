import Foundation

final class PerformanceMonitorLease: @unchecked Sendable {
  private let key: ObjectIdentifier
  private let tokenObject: AnyObject
  private let releaseLock = NSLock()
  private var didRelease = false

  init(key: ObjectIdentifier, tokenObject: AnyObject) {
    self.key = key
    self.tokenObject = tokenObject
  }

  func release() {
    let shouldRelease = releaseLock.withLock {
      guard !didRelease else { return false }
      didRelease = true
      return true
    }
    guard shouldRelease else { return }
    PerformanceMonitorLeaseRegistry.release(key: key, token: ObjectIdentifier(tokenObject))
  }

  deinit {
    release()
  }
}

enum PerformanceMonitorLeaseRegistry {
  private final class Token {}
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var owners: [ObjectIdentifier: ObjectIdentifier] = [:]
  }

  private static let state = State()

  static func claim(_ nearWire: AnyObject) throws -> PerformanceMonitorLease {
    let key = ObjectIdentifier(nearWire)
    let tokenObject = Token()
    let token = ObjectIdentifier(tokenObject)
    let claimed = state.lock.withLock {
      guard state.owners[key] == nil else { return false }
      state.owners[key] = token
      return true
    }
    guard claimed else { throw NearWirePerformanceError.monitorAlreadyRunning }
    return PerformanceMonitorLease(key: key, tokenObject: tokenObject)
  }

  static func release(key: ObjectIdentifier, token: ObjectIdentifier) {
    state.lock.withLock {
      guard state.owners[key] == token else { return }
      state.owners.removeValue(forKey: key)
    }
  }

  static var activeCount: Int {
    state.lock.withLock { state.owners.count }
  }
}
