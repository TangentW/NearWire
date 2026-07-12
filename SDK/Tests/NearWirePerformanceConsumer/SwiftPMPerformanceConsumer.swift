import NearWire
import NearWirePerformance

func compileSupportedNearWirePerformanceSwiftPMAPI(
  nearWire: NearWire
) throws -> NearWirePerformanceMonitor {
  let configuration = try NearWirePerformanceConfiguration(
    sampleInterval: .seconds(1),
    processMetricsEnabled: true,
    displayMetricsEnabled: true,
    deviceMetricsEnabled: true,
    transportMetricsEnabled: true,
    managesBatteryMonitoring: false
  )
  return NearWirePerformanceMonitor(nearWire: nearWire, configuration: configuration)
}

func compileSupportedNearWirePerformanceStateAPI(
  monitor: NearWirePerformanceMonitor,
  error: NearWirePerformanceError
) async {
  _ = monitor.states
  _ = await monitor.currentState
  _ = error.code
  _ = error.field
  _ = error.message
  try? await monitor.start()
  await monitor.stop()
}
