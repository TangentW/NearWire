import Dispatch
@_spi(NearWireInternal) import NearWireTransport

let plaintextParameters = SecureNetworkParameters.appClient(
  verificationQueue: .main
)
_ = plaintextParameters
