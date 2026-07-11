import Foundation

@_cdecl("nearwire_lease_b_namespaces_valid")
public func nearWireLeaseBNamespacesValid() -> Int32 {
  ProcessConnectionLeaseNamespace.monitorName == "com.nearwire.connection-lease.monitor"
    && ProcessConnectionLeaseNamespace.ownerName == "com.nearwire.connection-lease.owner"
    ? 1 : 0
}

@_cdecl("nearwire_lease_b_monitor_identity")
public func nearWireLeaseBMonitorIdentity() -> UInt {
  let reference = ProcessConnectionLeaseOperation.resolveRuntimeReference(
    anchor: ProcessInfo.processInfo,
    runtime: AppleProcessConnectionLeaseRuntime()
  )
  guard let monitor = reference.monitor else {
    return 0
  }
  return UInt(bitPattern: ObjectIdentifier(monitor))
}

@_cdecl("nearwire_lease_b_claim")
public func nearWireLeaseBClaim(
  _ status: UnsafeMutablePointer<Int32>?
) -> UnsafeMutableRawPointer? {
  do {
    let handle = try ProcessConnectionLeaseRegistry.claim()
    status?.pointee = 0
    return Unmanaged.passRetained(handle).toOpaque()
  } catch let error as ProcessConnectionLeaseError {
    status?.pointee = error.code == .anotherConnectionIsActive ? 1 : 2
    return nil
  } catch {
    status?.pointee = 3
    return nil
  }
}

@_cdecl("nearwire_lease_b_release")
public func nearWireLeaseBRelease(_ pointer: UnsafeMutableRawPointer?) {
  guard let pointer else { return }
  Unmanaged<ProcessConnectionLeaseHandle>.fromOpaque(pointer).takeUnretainedValue().release()
}

@_cdecl("nearwire_lease_b_destroy")
public func nearWireLeaseBDestroy(_ pointer: UnsafeMutableRawPointer?) {
  guard let pointer else { return }
  _ = Unmanaged<ProcessConnectionLeaseHandle>.fromOpaque(pointer).takeRetainedValue()
}
