import NearWire

func compileSupportedNearWirePerformanceCocoaPodsAPI(
  nearWire: NearWire
) throws -> NearWirePerformanceMonitor {
  let configuration = try NearWirePerformanceConfiguration(
    sampleInterval: .seconds(1),
    managesBatteryMonitoring: true
  )
  return NearWirePerformanceMonitor(nearWire: nearWire, configuration: configuration)
}
