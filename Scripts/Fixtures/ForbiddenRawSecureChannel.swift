import Dispatch
import NearWireTransport
import Network

let plaintextConnection = NWConnection(
  host: "127.0.0.1",
  port: 9,
  using: .tcp
)
let insecureChannel = SecureByteChannel(
  connection: plaintextConnection,
  queue: .main
) { _ in }
_ = insecureChannel
