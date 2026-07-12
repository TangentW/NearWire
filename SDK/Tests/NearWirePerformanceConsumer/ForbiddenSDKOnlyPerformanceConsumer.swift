import NearWire

func compileForbiddenSDKOnlyPerformanceAPI(nearWire: NearWire) {
  _ = NearWirePerformanceMonitor(nearWire: nearWire)
}
