import SwiftUI

#if SWIFT_PACKAGE
  import NearWire
  import NearWirePerformance
#endif

/// A complete NearWire panel with connection, Performance, and latest Viewer Event controls.
public struct NearWirePanelView: View {
  private struct Identity: Hashable {
    let nearWire: ObjectIdentifier
    let performanceMonitor: ObjectIdentifier
  }

  private let nearWire: NearWire
  private let performanceMonitor: NearWirePerformanceMonitor

  public init(
    nearWire: NearWire,
    performanceMonitor: NearWirePerformanceMonitor
  ) {
    self.nearWire = nearWire
    self.performanceMonitor = performanceMonitor
  }

  var stateIdentity: AnyHashable {
    AnyHashable(
      Identity(
        nearWire: ObjectIdentifier(nearWire),
        performanceMonitor: ObjectIdentifier(performanceMonitor)
      )
    )
  }

  public var body: some View {
    VStack(spacing: 0) {
      NearWireConnectionView(nearWire: nearWire)
      Divider()
      NearWirePerformanceControlView(performanceMonitor: performanceMonitor)
      Divider()
      NearWireLatestViewerEventView(nearWire: nearWire)
    }
    .id(stateIdentity)
  }
}
