import NearWire
import SwiftUI

#if NEARWIRE_DEMO_SEPARATE_MODULES
  import NearWireUI
#endif

struct DemoRootView: View {
  @Environment(\.scenePhase) private var scenePhase

  let nearWire: NearWire
  @ObservedObject var model: DemoApplicationModel

  @State private var showsResetConfirmation = false

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          introduction
          connectionSection
          eventSection
          controlSection
          performanceSection
          resetSection
        }
        .padding()
      }
      .accessibilityIdentifier("demo.root")
      .navigationTitle("NearWire Demo")
    }
    .task { model.activate() }
    .task(id: scenePhase) { await model.applyScenePhase(scenePhase) }
    .alert("Reset Demo?", isPresented: $showsResetConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Reset", role: .destructive) {
        Task { await model.reset() }
      }
    } message: {
      Text(
        "This disconnects NearWire, stops performance sampling, and clears Demo presentation state."
      )
    }
  }

  private var introduction: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("NearWire Integration Demo")
        .font(.title2.bold())
      Text(
        "Connect to the Mac Viewer, send sample Events, and optionally publish performance snapshots."
      )
      .foregroundStyle(.secondary)
    }
  }

  private var connectionSection: some View {
    GroupBox("Connection") {
      NearWireConnectionView(nearWire: nearWire)
    }
    .accessibilityIdentifier("demo.connection.section")
  }

  private var eventSection: some View {
    GroupBox("Event Lab") {
      VStack(alignment: .leading, spacing: 12) {
        TextField(
          "Message",
          text: Binding(
            get: { model.messageText },
            set: { model.updateMessage($0) }
          ),
          axis: .vertical
        )
        .textFieldStyle(.roundedBorder)
        .lineLimit(2...4)
        .accessibilityIdentifier("demo.message.input")
        .accessibilityHint("Enter up to 512 UTF-8 bytes for a demo.message Event.")

        Button("Send Message") {
          Task { await model.sendMessage() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!DemoTextLimit.accepts(model.messageText))
        .accessibilityIdentifier("demo.message.send")

        Divider()

        HStack {
          Text("Latest counter: \(model.counter)")
            .monospacedDigit()
            .accessibilityIdentifier("demo.counter.value")
          Spacer()
          Button("Increment and Send") {
            Task { await model.incrementCounter() }
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("demo.counter.send")
        }

        Text(model.lastSendPresentation)
          .font(.footnote)
          .foregroundStyle(.secondary)

        HStack {
          Text(model.queuePresentation)
            .font(.footnote)
          Spacer()
          Button("Refresh") {
            Task { await model.refreshDiagnostics() }
          }
          .accessibilityIdentifier("demo.queue.refresh")
        }
      }
      .padding(.top, 6)
    }
  }

  private var controlSection: some View {
    GroupBox("Viewer Controls") {
      VStack(alignment: .leading, spacing: 10) {
        Text(model.banner)
          .font(.headline)
          .accessibilityIdentifier("demo.banner")
        Text(model.eventObservationPresentation)
          .font(.footnote)
          .foregroundStyle(.secondary)

        if model.summaries.isEmpty {
          Text("No Viewer Events summarized.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.summaries.suffix(5)) { summary in
            VStack(alignment: .leading, spacing: 2) {
              Text(summary.type)
                .font(.caption.monospaced())
              Text(summary.outcome)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          if model.summaries.count > 5 {
            Text("Showing the newest 5 of \(model.summaries.count) retained summaries.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 6)
    }
  }

  private var performanceSection: some View {
    GroupBox("Performance") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("State")
          Spacer()
          Text(model.performance.title)
            .fontWeight(.semibold)
            .accessibilityIdentifier("demo.performance.state")
        }

        if case .failed(let message) = model.performance {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
        }

        HStack {
          Button("Start Performance") {
            Task { await model.startPerformance() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.performance == .running)
          .accessibilityIdentifier("demo.performance.start")

          Button("Stop Performance") {
            Task { await model.stopPerformance() }
          }
          .buttonStyle(.bordered)
          .disabled(model.performance == .stopped)
          .accessibilityIdentifier("demo.performance.stop")
        }

        Text(
          "Snapshots use NearWire's ordinary keep-latest Event path and appear in the Viewer's Performance page."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      .padding(.top, 6)
    }
  }

  private var resetSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let error = model.displayedError {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityIdentifier("demo.error")
      }

      Button("Reset Demo", role: .destructive) {
        showsResetConfirmation = true
      }
      .disabled(model.isResetting)
      .accessibilityIdentifier("demo.reset")
      .accessibilityHint("Disconnect, stop sampling, and clear the Demo presentation.")
    }
  }
}
