import AppKit
import SwiftUI

@main
struct NearWireViewerApp: App {
  @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) private var appDelegate
  @StateObject private var model = ViewerApplicationModel()

  var body: some Scene {
    Window("NearWire", id: "main") {
      ViewerMainWindowContent(model: model)
        .frame(
          minWidth: ViewerWorkspaceLayout.minimumWindowWidth,
          minHeight: ViewerWorkspaceLayout.minimumWindowHeight
        )
        .onAppear {
          appDelegate.configure(model: model)
          ViewerWindowRuntimeLifecycle.ensureRuntime(
            for: model,
            isRunningUnitTests: ViewerLaunchContext.isRunningUnitTests
          )
        }
        .alert("Reset All Viewer Identity?", isPresented: $model.showsFullIdentityResetConfirmation)
      {
        Button("Cancel", role: .cancel) { model.cancelFullIdentityReset() }
        Button("Reset All", role: .destructive) { model.confirmFullIdentityReset() }
      } message: {
        Text("This replaces both the installation identifier and TLS identity.")
      }
    }
    .commands {
      CommandGroup(replacing: .newItem) {}
    }

    Window("Performance", id: "performance") {
      ViewerPerformanceWindowRootView(model: model)
        .frame(
          minWidth: ViewerPerformanceWindowLayout.minimumWidth,
          minHeight: ViewerPerformanceWindowLayout.minimumHeight
        )
        .onAppear {
          appDelegate.configure(model: model)
          ViewerWindowRuntimeLifecycle.ensureRuntime(
            for: model,
            isRunningUnitTests: ViewerLaunchContext.isRunningUnitTests
          )
        }
    }
    .defaultSize(
      width: ViewerPerformanceWindowLayout.defaultWidth,
      height: ViewerPerformanceWindowLayout.defaultHeight
    )
  }
}

@MainActor
enum ViewerWindowRuntimeLifecycle {
  static func ensureRuntime(
    for model: ViewerApplicationModel,
    isRunningUnitTests: Bool
  ) {
    guard !isRunningUnitTests else { return }
    model.openWindow()
  }
}

private struct ViewerMainWindowContent: View {
  @Environment(\.openWindow) private var openWindow
  let model: ViewerApplicationModel

  var body: some View {
    ViewerRootView(
      model: model,
      openPerformanceWindow: { openWindow(id: "performance") }
    )
  }
}

private enum ViewerLaunchContext {
  static var isRunningUnitTests: Bool {
    NSClassFromString("XCTestCase") != nil
  }
}

@MainActor
final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
  private weak var model: ViewerApplicationModel?
  private var terminationPending = false

  func configure(model: ViewerApplicationModel) {
    self.model = model
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    beginTermination(using: model) { sender.reply(toApplicationShouldTerminate: $0) }
    return .terminateLater
  }

  func beginTermination(
    using model: ViewerApplicationModel,
    reply: @escaping @MainActor (Bool) -> Void
  ) {
    Task {
      _ = await model.prepareForTermination()
      reply(true)
    }
  }
}
