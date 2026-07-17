import SwiftUI
import XCTest

@testable import NearWire
@testable import NearWirePerformance
@testable import NearWireUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@MainActor
final class NearWireUIViewSmokeTests: XCTestCase {
  func testMountedPublicViewReplacementTransfersStatusSubscription() async {
    let first = NearWire()
    let second = NearWire()

    #if os(macOS)
      let host = NSHostingController(rootView: NearWireConnectionView(nearWire: first))
      let window = NSWindow(contentViewController: host)
      window.setContentSize(NSSize(width: 320, height: 320))
      window.orderFront(nil)
      host.view.layoutSubtreeIfNeeded()
      await NearWireUITestWait.until { first.streamSubscriberCounts.statuses == 1 }

      host.rootView = NearWireConnectionView(nearWire: second)
      host.view.layoutSubtreeIfNeeded()
      await NearWireUITestWait.until {
        first.streamSubscriberCounts.statuses == 0 && second.streamSubscriberCounts.statuses == 1
      }

      window.orderOut(nil)
      window.close()
    #else
      let host = UIHostingController(rootView: NearWireConnectionView(nearWire: first))
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
      window.rootViewController = host
      window.makeKeyAndVisible()
      host.beginAppearanceTransition(true, animated: false)
      host.endAppearanceTransition()
      host.view.layoutIfNeeded()
      await NearWireUITestWait.until { first.streamSubscriberCounts.statuses == 1 }

      host.rootView = NearWireConnectionView(nearWire: second)
      host.view.layoutIfNeeded()
      await NearWireUITestWait.until {
        first.streamSubscriberCounts.statuses == 0 && second.streamSubscriberCounts.statuses == 1
      }

      host.beginAppearanceTransition(false, animated: false)
      host.endAppearanceTransition()
      window.isHidden = true
    #endif
  }

  func testPublicViewsConstructAndRenderAtAccessibilitySize() async {
    let nearWire = NearWire()
    let performanceMonitor = NearWirePerformanceMonitor(nearWire: nearWire)
    _ = NearWireConnectionView(nearWire: nearWire).body
    _ = NearWirePerformanceControlView(performanceMonitor: performanceMonitor).body
    _ = NearWireLatestViewerEventView(nearWire: nearWire).body
    _ =
      NearWirePanelView(
        nearWire: nearWire,
        performanceMonitor: performanceMonitor
      ).body
    let replacement = NearWire()
    let replacementMonitor = NearWirePerformanceMonitor(nearWire: replacement)
    XCTAssertNotEqual(
      NearWireConnectionView(nearWire: nearWire).stateIdentity,
      NearWireConnectionView(nearWire: replacement).stateIdentity
    )
    XCTAssertNotEqual(
      NearWirePerformanceControlView(performanceMonitor: performanceMonitor).stateIdentity,
      NearWirePerformanceControlView(performanceMonitor: replacementMonitor).stateIdentity
    )
    XCTAssertNotEqual(
      NearWireLatestViewerEventView(nearWire: nearWire).stateIdentity,
      NearWireLatestViewerEventView(nearWire: replacement).stateIdentity
    )
    XCTAssertNotEqual(
      NearWirePanelView(
        nearWire: nearWire,
        performanceMonitor: performanceMonitor
      ).stateIdentity,
      NearWirePanelView(
        nearWire: replacement,
        performanceMonitor: replacementMonitor
      ).stateIdentity
    )

    let status = NearWireConnectionStatus(state: .connected)
    let statusView = NearWireConnectionStatusView(status: status)
      .environment(\.dynamicTypeSize, .accessibility5)
      .frame(width: 320)
    let renderer = ImageRenderer(content: statusView)
    assertRenderedImage(renderer)

    let connectionView = NearWireConnectionView(nearWire: nearWire)
      .environment(\.dynamicTypeSize, .accessibility5)
      .frame(width: 320)
    assertRenderedImage(ImageRenderer(content: connectionView))

    let panel = NearWirePanelView(
      nearWire: nearWire,
      performanceMonitor: performanceMonitor
    )
    .environment(\.dynamicTypeSize, .accessibility5)
    .frame(width: 320)
    assertRenderedImage(ImageRenderer(content: panel))

    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    controller.sendStatus(
      NearWireConnectionStatus(
        state: .disconnected,
        lastError: NearWireError(
          code: .connectionIntentExists,
          message: "A connection reset is available."
        )
      )
    )
    model.start()
    await NearWireUITestWait.until { model.status?.state == .disconnected }
    model.updatePairingCode("PAIR")
    let resetPanel = NearWireConnectionContent(model: model)
      .environment(\.dynamicTypeSize, .accessibility5)
      .frame(width: 320)
    assertRenderedImage(ImageRenderer(content: resetPanel))

    model.performPrimaryAction()
    await NearWireUITestWait.until {
      model.operationPhase == .connecting && controller.pendingConnectCount == 1
    }
    let progressPanel = NearWireConnectionContent(model: model)
      .environment(\.dynamicTypeSize, .accessibility5)
      .frame(width: 320)
    assertRenderedImage(ImageRenderer(content: progressPanel))
    model.stop()
    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.entryCount == 0 }
  }

  private func assertRenderedImage<Content: View>(_ renderer: ImageRenderer<Content>) {
    #if os(macOS)
      XCTAssertNotNil(renderer.nsImage)
    #else
      XCTAssertNotNil(renderer.uiImage)
    #endif
  }
}
