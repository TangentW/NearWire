import Foundation

struct SDKActiveOperationGateHooks: Sendable {
  static let none = SDKActiveOperationGateHooks(beforeClaim: {}, afterOperation: {})

  let beforeClaim: @Sendable () -> Void
  let afterOperation: @Sendable () -> Void
}

final class SDKActiveOperationGate: @unchecked Sendable {
  private let lock = NSLock()
  private let hooks: SDKActiveOperationGateHooks
  private var isOpen = true

  init(hooks: SDKActiveOperationGateHooks = .none) {
    self.hooks = hooks
  }

  @discardableResult
  func withOpenClaim(_ operation: () -> Void) -> Bool {
    hooks.beforeClaim()
    lock.lock()
    defer { lock.unlock() }
    guard isOpen else { return false }
    operation()
    hooks.afterOperation()
    return true
  }

  func close() {
    lock.lock()
    isOpen = false
    lock.unlock()
  }
}
