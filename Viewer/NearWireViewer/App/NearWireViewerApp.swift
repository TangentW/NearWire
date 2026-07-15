import AppKit
import SwiftUI

@main
struct NearWireViewerApp: App {
  @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) private var appDelegate
  @StateObject private var model = ViewerApplicationModel()

  var body: some Scene {
    Window("NearWire", id: "main") {
      ViewerRootView(model: model)
        .frame(
          minWidth: ViewerWorkspaceLayout.minimumWindowWidth,
          minHeight: ViewerWorkspaceLayout.minimumWindowHeight
        )
        .onAppear {
          appDelegate.configure(model: model)
          if !ViewerLaunchContext.isRunningUnitTests {
            model.openWindow()
          }
        }
        .onDisappear { model.closeWindow() }
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
