@_spi(NearWireInternal) import NearWireCore
import SwiftUI

struct ViewerControlComposerView: View {
  @Environment(\.locale) private var locale
  @ObservedObject var controller: ViewerControlComposerController

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 0) {
        targetColumn
          .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
        Divider()
        inputColumn
          .frame(minWidth: 300, maxWidth: .infinity)
        Divider()
        actionColumn
          .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          targetColumn.frame(minHeight: 180)
          Divider()
          inputColumn
          Divider()
          actionColumn
        }
      }
    }
  }

  private var targetColumn: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Targets", systemImage: "iphone.gen3.radiowaves.left.and.right")
          .font(.headline)
        Spacer()
        Text("\(controller.selectedTargetCount)/\(controller.targetRows.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 6) {
        Button("All") { controller.selectAllTargets() }
          .disabled(controller.targetRows.isEmpty)
        Button("None") { controller.clearTargetSelection() }
          .disabled(controller.selectedTargetIDs.isEmpty)
      }
      .controlSize(.small)
      if controller.targetRows.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "iphone.slash").foregroundStyle(.secondary)
          Text("No active Apps")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(controller.targetRows) { row in
          Button {
            controller.toggleTarget(row.id)
          } label: {
            HStack(alignment: .top, spacing: 8) {
              Image(
                systemName: controller.selectedTargetIDs.contains(row.id)
                  ? "checkmark.circle.fill" : "circle"
              )
              .foregroundStyle(
                controller.selectedTargetIDs.contains(row.id)
                  ? Color.accentColor : Color.secondary
              )
              .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                Text(row.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            ViewerLocalization.format(
              "%@, %@",
              locale: locale,
              arguments: [
                row.title,
                ViewerLocalization.string(
                  controller.selectedTargetIDs.contains(row.id) ? "selected" : "not selected",
                  locale: locale
                ),
              ]
            )
          )
          .accessibilityHint("Adds or removes this active App from the next local queue attempt.")
        }
        .listStyle(.inset)
      }
    }
    .padding(12)
    .focusSection()
    .accessibilitySortPriority(3)
  }

  private var inputColumn: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Viewer → App Control Event", systemImage: "paperplane")
          .font(.headline)
        Spacer()
        Text("Memory only")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text("User Event type, for example app.debug.command")
        .font(.caption)
        .foregroundStyle(.secondary)
      ViewerBoundedTextInput(
        text: controller.eventType,
        style: .singleLine,
        accessibilityLabel: ViewerLocalization.string("Control Event type", locale: locale),
        accessibilityHelp: ViewerLocalization.string(
          "Reserved nearwire.* platform Event types are rejected.",
          locale: locale
        ),
        onEdit: { range, replacement in
          controller.replaceCharacters(.eventType, range: range, replacement: replacement)
        }
      )
      .frame(height: 28)
      HStack(alignment: .firstTextBaseline) {
        Text("JSON content").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text(
          "Up to \(ByteCountFormatStyle(style: .binary, locale: locale).format(Int64(controller.maximumContentBytes)))"
        )
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      ViewerBoundedTextInput(
        text: controller.contentJSON,
        style: .multiline,
        accessibilityLabel: ViewerLocalization.string(
          "Control Event JSON content",
          locale: locale
        ),
        accessibilityHelp: ViewerLocalization.string(
          "Standard editing is allowed and every edit is bounded before storage.",
          locale: locale
        ),
        monospaced: true,
        onEdit: { range, replacement in
          controller.replaceCharacters(.content, range: range, replacement: replacement)
        }
      )
      .frame(minHeight: 110)
      if let message = controller.inputValidationMessage {
        Label(LocalizedStringKey(message), systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(12)
    .focusSection()
    .accessibilitySortPriority(2)
  }

  private var actionColumn: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("Send settings").font(.headline)
        Spacer()
        Button("Clear Draft") { controller.clearDraft() }
          .controlSize(.small)
      }
      Picker("Priority", selection: priorityBinding) {
        Text("Low").tag(EventPriority.low)
        Text("Normal").tag(EventPriority.normal)
        Text("High").tag(EventPriority.high)
      }
      .pickerStyle(.segmented)
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("TTL milliseconds").font(.caption).foregroundStyle(.secondary)
          ViewerBoundedTextInput(
            text: controller.ttlText,
            style: .singleLine,
            accessibilityLabel: ViewerLocalization.string("TTL milliseconds", locale: locale),
            accessibilityHelp: ViewerLocalization.format(
              "One through nine ASCII digits, no sign or spaces, maximum %llu.",
              locale: locale,
              arguments: [controller.maximumTTLMilliseconds]
            ),
            onEdit: { range, replacement in
              controller.replaceCharacters(.ttl, range: range, replacement: replacement)
            }
          )
          .frame(height: 28)
        }
        Picker("Queue policy", selection: policyBinding) {
          Text("Normal").tag(ViewerControlDraftPolicy.normal)
          Text("Keep Latest").tag(ViewerControlDraftPolicy.keepLatest)
        }
        .labelsHidden()
        .frame(width: 110)
      }
      Button {
        controller.send()
      } label: {
        Label("Queue on Selected Apps", systemImage: "paperplane.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!controller.canSend)
      .keyboardShortcut(.return, modifiers: [.command])
      .accessibilityHint(
        "Validates once, then requests local queue admission on each selected App.")
      composerState
      if !controller.resultRows.isEmpty {
        Divider()
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(controller.resultRows) { row in resultRow(row) }
          }
        }
        .frame(maxHeight: 88)
      }
      Text("Queued locally is not delivery, receipt, acknowledgement, execution, or processing.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .focusSection()
    .accessibilitySortPriority(1)
  }

  @ViewBuilder
  private var composerState: some View {
    switch controller.state {
    case .idle:
      EmptyView()
    case .preparing:
      ProgressView("Validating and encoding once")
        .controlSize(.small)
    case .completed:
      Label("Local queue attempt complete", systemImage: "checkmark.circle")
        .font(.caption)
        .foregroundStyle(.green)
    case .failed(let failure):
      Label(LocalizedStringKey(failure.message), systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private func resultRow(_ row: ViewerControlResultPresentationRow) -> some View {
    HStack {
      Label(row.title, systemImage: outcomeIcon(row.outcome)).lineLimit(1)
      Spacer()
      Text(LocalizedStringKey(row.statusText))
        .font(.caption)
        .foregroundStyle(outcomeColor(row.outcome))
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      ViewerLocalization.format(
        "%@, %@",
        locale: locale,
        arguments: [
          row.title,
          ViewerLocalization.string(row.statusText, locale: locale),
        ]
      )
    )
  }

  private var priorityBinding: Binding<EventPriority> {
    Binding(get: { controller.priority }, set: { controller.setPriority($0) })
  }

  private var policyBinding: Binding<ViewerControlDraftPolicy> {
    Binding(get: { controller.policy }, set: { controller.setPolicy($0) })
  }

  private func outcomeIcon(_ outcome: ViewerControlTargetOutcome) -> String {
    switch outcome {
    case .queued: return "tray.and.arrow.down.fill"
    case .invalidTarget: return "questionmark.circle"
    case .noLongerConnected: return "iphone.slash"
    case .notActive: return "pause.circle"
    case .queueRejected: return "xmark.octagon"
    }
  }

  private func outcomeColor(_ outcome: ViewerControlTargetOutcome) -> Color {
    switch outcome {
    case .queued: return .green
    case .invalidTarget, .noLongerConnected, .notActive: return .orange
    case .queueRejected: return .red
    }
  }
}
