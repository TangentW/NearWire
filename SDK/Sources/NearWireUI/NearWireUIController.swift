import SwiftUI

#if SWIFT_PACKAGE
  import NearWire
#endif

protocol NearWireUIConnectionControlling: AnyObject, Sendable {
  var connectionStatuses: AsyncStream<NearWireConnectionStatus> { get }

  func connect(code: String) async throws
  func disconnect() async
}

extension NearWire: NearWireUIConnectionControlling {}
