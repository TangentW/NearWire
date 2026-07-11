import Dispatch
import Network

let sameModulePlaintextConnection = NWConnection(
  host: "127.0.0.1",
  port: 9,
  using: .tcp
)
let sameModuleInsecureChannel = SecureByteChannel(
  connection: sameModulePlaintextConnection,
  queue: .main
) { _ in }
