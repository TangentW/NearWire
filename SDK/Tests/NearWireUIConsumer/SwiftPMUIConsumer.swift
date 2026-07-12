import NearWire
import NearWireUI
import SwiftUI

@MainActor
func compileSupportedNearWireUISwiftPMAPI(
  nearWire: NearWire,
  status: NearWireConnectionStatus
) -> some View {
  VStack {
    NearWireConnectionView(nearWire: nearWire)
    NearWireConnectionStatusView(status: status)
  }
}
