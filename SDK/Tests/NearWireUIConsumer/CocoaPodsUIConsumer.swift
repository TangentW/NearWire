import NearWire
import SwiftUI

@MainActor
func compileSupportedNearWireUICocoaPodsAPI(
  nearWire: NearWire,
  status: NearWireConnectionStatus
) -> some View {
  VStack {
    NearWireConnectionView(nearWire: nearWire)
    NearWireConnectionStatusView(status: status)
  }
}
