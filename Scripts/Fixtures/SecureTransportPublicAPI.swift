import Dispatch
import NearWireTransport
import Network

let securePlan = SecureTLSPlan.v1
let secureLimits = SecureTransportLimits.default

func makeSecureChannel(endpoint: NWEndpoint) -> SecureByteChannel {
  SecureAppTransport.makeChannel(
    endpoint: endpoint,
    connectionQueue: DispatchQueue(label: "nearwire.fixture.connection"),
    verificationQueue: DispatchQueue(label: "nearwire.fixture.verification")
  ) { _ in }
}

func makeSecureViewerListener(
  identity: ViewerTransportIdentity
) throws -> SecureViewerListener {
  try SecureViewerTransport.makeListener(identity: identity)
}

_ = (securePlan, secureLimits, makeSecureChannel, makeSecureViewerListener)
