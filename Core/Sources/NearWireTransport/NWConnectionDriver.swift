import Foundation
import Network
import Security

final class NWConnectionDriver: SecureConnectionDriving, @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue

  init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  func start(stateHandler: @escaping @Sendable (SecureDriverState) -> Void) {
    connection.stateUpdateHandler = { state in
      switch state {
      case .setup, .preparing, .waiting:
        stateHandler(.preparing)
      case .ready:
        if Self.hasRequiredTLSMetadata(self.connection) {
          stateHandler(.ready)
        } else {
          stateHandler(.failed)
          self.connection.cancel()
        }
      case .failed:
        stateHandler(.failed)
      case .cancelled:
        stateHandler(.cancelled)
      @unknown default:
        stateHandler(.failed)
      }
    }
    connection.start(queue: queue)
  }

  func receive(
    maximumLength: Int,
    completion: @escaping @Sendable (Data?, Bool, Bool) -> Void
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
      data,
      _,
      isComplete,
      error in
      completion(data, isComplete, error != nil)
    }
  }

  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
    connection.send(
      content: data,
      completion: .contentProcessed { error in
        completion(error != nil)
      })
  }

  func cancel() {
    connection.cancel()
  }

  private static func hasRequiredTLSMetadata(_ connection: NWConnection) -> Bool {
    guard
      let metadata = connection.metadata(definition: NWProtocolTLS.definition)
        as? NWProtocolTLS.Metadata
    else {
      return false
    }
    let securityMetadata = metadata.securityProtocolMetadata
    guard
      sec_protocol_metadata_get_negotiated_tls_protocol_version(securityMetadata) == .TLSv13,
      let negotiatedProtocol = negotiatedApplicationProtocol(securityMetadata)
    else {
      return false
    }
    return negotiatedProtocol == SecureNetworkParameters.applicationProtocol
  }

  private static func negotiatedApplicationProtocol(
    _ metadata: sec_protocol_metadata_t
  ) -> String? {
    guard let bytes = sec_protocol_metadata_get_negotiated_protocol(metadata) else {
      return nil
    }
    return String(cString: bytes)
  }
}
