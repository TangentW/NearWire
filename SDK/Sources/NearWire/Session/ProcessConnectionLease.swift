import Foundation
import ObjectiveC

enum ProcessConnectionLeaseNamespace {
  static let monitorName = "com.nearwire.connection-lease.monitor"
  static let ownerName = "com.nearwire.connection-lease.owner"

  static var monitorKey: UnsafeRawPointer {
    unsafeBitCast(NSSelectorFromString(monitorName), to: UnsafeRawPointer.self)
  }

  static var ownerKey: UnsafeRawPointer {
    unsafeBitCast(NSSelectorFromString(ownerName), to: UnsafeRawPointer.self)
  }
}

protocol ProcessConnectionLeaseRuntimeOperations: Sendable {
  func enter(_ object: AnyObject) -> Int32
  func exit(_ object: AnyObject) -> Int32
  func associatedObject(_ object: AnyObject, key: UnsafeRawPointer) -> Any?
  func setAssociatedObject(_ object: AnyObject, key: UnsafeRawPointer, value: AnyObject?)
}

struct AppleProcessConnectionLeaseRuntime: ProcessConnectionLeaseRuntimeOperations {
  func enter(_ object: AnyObject) -> Int32 {
    objc_sync_enter(object)
  }

  func exit(_ object: AnyObject) -> Int32 {
    objc_sync_exit(object)
  }

  func associatedObject(_ object: AnyObject, key: UnsafeRawPointer) -> Any? {
    objc_getAssociatedObject(object, key)
  }

  func setAssociatedObject(_ object: AnyObject, key: UnsafeRawPointer, value: AnyObject?) {
    objc_setAssociatedObject(object, key, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }
}

final class ProcessConnectionLeaseRuntimeReference: @unchecked Sendable {
  let monitor: NSObject?

  init(monitor: NSObject?) {
    self.monitor = monitor
  }
}

struct ProcessConnectionLeaseError: Error, Equatable, Sendable {
  enum Code: String, Sendable {
    case anotherConnectionIsActive
    case runtimeUnavailable
  }

  let code: Code

  var message: String {
    switch code {
    case .anotherConnectionIsActive:
      return "Another NearWire connection is already active."
    case .runtimeUnavailable:
      return "NearWire connection ownership is unavailable."
    }
  }

  static let anotherConnectionIsActive = ProcessConnectionLeaseError(
    code: .anotherConnectionIsActive
  )

  static let runtimeUnavailable = ProcessConnectionLeaseError(
    code: .runtimeUnavailable
  )

  private init(code: Code) {
    self.code = code
  }
}

extension ProcessConnectionLeaseError: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String {
    "\(code.rawValue): \(message)"
  }

  var debugDescription: String {
    description
  }

  var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}

final class ProcessConnectionLeaseHandle: @unchecked Sendable {
  private let monitor: NSObject
  private let token: NSObject
  private let runtime: any ProcessConnectionLeaseRuntimeOperations
  private let releaseLock = NSLock()
  private var didRelease = false

  init(
    monitor: NSObject,
    token: NSObject,
    runtime: any ProcessConnectionLeaseRuntimeOperations
  ) {
    self.monitor = monitor
    self.token = token
    self.runtime = runtime
  }

  func release() {
    let shouldRelease = releaseLock.withLock {
      guard !didRelease else { return false }
      didRelease = true
      return true
    }
    guard shouldRelease else { return }
    ProcessConnectionLeaseOperation.release(
      monitor: monitor,
      token: token,
      runtime: runtime
    )
  }

  deinit {
    release()
  }
}

extension ProcessConnectionLeaseHandle: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String {
    "NearWire connection lease"
  }

  var debugDescription: String {
    description
  }

  var customMirror: Mirror {
    Mirror(self, children: ["description": description], displayStyle: .class)
  }
}

enum ProcessConnectionLeaseOperation {
  static let synchronizationSucceeded: Int32 = 0

  static func resolveRuntimeReference(
    anchor: NSObject,
    runtime: any ProcessConnectionLeaseRuntimeOperations
  ) -> ProcessConnectionLeaseRuntimeReference {
    let monitorKey = ProcessConnectionLeaseNamespace.monitorKey
    let candidate = NSObject()
    let enterStatus = runtime.enter(anchor)
    guard enterStatus == synchronizationSucceeded else {
      withExtendedLifetime(candidate) {}
      return ProcessConnectionLeaseRuntimeReference(monitor: nil)
    }

    var selectedMonitor: NSObject?
    var resolved = false
    if let current = runtime.associatedObject(anchor, key: monitorKey) {
      if let currentMonitor = current as? NSObject {
        selectedMonitor = currentMonitor
        resolved = true
      }
    } else {
      runtime.setAssociatedObject(
        anchor,
        key: monitorKey,
        value: candidate
      )
      selectedMonitor = candidate
      resolved = true
    }

    let exitStatus = runtime.exit(anchor)
    withExtendedLifetime(candidate) {}
    guard exitStatus == synchronizationSucceeded, resolved, let selectedMonitor else {
      return ProcessConnectionLeaseRuntimeReference(monitor: nil)
    }
    return ProcessConnectionLeaseRuntimeReference(monitor: selectedMonitor)
  }

  static func claim(
    reference: ProcessConnectionLeaseRuntimeReference,
    runtime: any ProcessConnectionLeaseRuntimeOperations
  ) throws -> ProcessConnectionLeaseHandle {
    guard let monitor = reference.monitor else {
      throw ProcessConnectionLeaseError.runtimeUnavailable
    }

    let ownerKey = ProcessConnectionLeaseNamespace.ownerKey
    let token = NSObject()
    let enterStatus = runtime.enter(monitor)
    guard enterStatus == synchronizationSucceeded else {
      withExtendedLifetime(token) {}
      throw ProcessConnectionLeaseError.runtimeUnavailable
    }

    let claimed: Bool
    if runtime.associatedObject(monitor, key: ownerKey) == nil {
      runtime.setAssociatedObject(
        monitor,
        key: ownerKey,
        value: token
      )
      claimed = true
    } else {
      claimed = false
    }

    let exitStatus = runtime.exit(monitor)
    withExtendedLifetime(token) {}
    guard exitStatus == synchronizationSucceeded else {
      throw ProcessConnectionLeaseError.runtimeUnavailable
    }
    guard claimed else {
      throw ProcessConnectionLeaseError.anotherConnectionIsActive
    }
    return ProcessConnectionLeaseHandle(monitor: monitor, token: token, runtime: runtime)
  }

  static func release(
    monitor: NSObject,
    token: NSObject,
    runtime: any ProcessConnectionLeaseRuntimeOperations
  ) {
    let ownerKey = ProcessConnectionLeaseNamespace.ownerKey
    let enterStatus = runtime.enter(monitor)
    guard enterStatus == synchronizationSucceeded else {
      return
    }

    if let current = runtime.associatedObject(
      monitor,
      key: ownerKey
    ) as AnyObject?, current === token {
      runtime.setAssociatedObject(
        monitor,
        key: ownerKey,
        value: nil
      )
    }

    let exitStatus = runtime.exit(monitor)
    withExtendedLifetime(token) {}
    guard exitStatus == synchronizationSucceeded else {
      return
    }
  }
}

enum ProcessConnectionLeaseRegistry {
  private static let runtime = AppleProcessConnectionLeaseRuntime()
  private static let runtimeReference = ProcessConnectionLeaseOperation.resolveRuntimeReference(
    anchor: ProcessInfo.processInfo,
    runtime: runtime
  )

  static func claim() throws -> ProcessConnectionLeaseHandle {
    try ProcessConnectionLeaseOperation.claim(reference: runtimeReference, runtime: runtime)
  }
}
