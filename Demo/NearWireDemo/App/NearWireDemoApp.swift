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
    let nearWire = NearWire()
    self.nearWire = nearWire
    _model = StateObject(
      wrappedValue: DemoApplicationModel(
        nearWire: nearWire,
        performanceMonitor: NearWirePerformanceMonitor(nearWire: nearWire)
      )
    )
  }

  var body: some Scene {
    WindowGroup {
      DemoRootView(nearWire: nearWire, model: model)
    }
  }
}
