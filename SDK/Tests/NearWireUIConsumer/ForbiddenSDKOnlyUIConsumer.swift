import NearWire

@MainActor
func compileForbiddenSDKOnlyUIAPI(nearWire: NearWire) {
  _ = NearWireConnectionView(nearWire: nearWire)
}
