import NearWire
import SwiftUI

#if NEARWIRE_DEMO_SEPARATE_MODULES
  import NearWirePerformance
#endif

@main
@MainActor
struct NearWireDemoApp: App {
  private let nearWire: NearWire
  @StateObject private var model: DemoApplicationModel

  init() {
    let nearWire = Self.makeNearWire()
    self.nearWire = nearWire
    _model = StateObject(
      wrappedValue: DemoApplicationModel(
        nearWire: nearWire,
        performanceMonitor: NearWirePerformanceMonitor(nearWire: nearWire)
      )
    )
  }

  static func makeNearWire() -> NearWire {
    do {
      let recovery = try NearWireReconnectionPolicy(
        maximumAttempts: 6,
        initialDelay: .milliseconds(500),
        maximumDelay: .seconds(4)
      )
      return NearWire(
        configuration: try NearWireConfiguration(reconnectionPolicy: recovery)
      )
    } catch {
      preconditionFailure("The fixed NearWire Demo recovery configuration is invalid.")
    }
  }

  var body: some Scene {
    WindowGroup {
      DemoRootView(nearWire: nearWire, model: model)
    }
  }
}
