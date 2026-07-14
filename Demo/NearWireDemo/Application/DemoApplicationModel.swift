import Foundation
import NearWire
import SwiftUI

#if NEARWIRE_DEMO_SEPARATE_MODULES
  import NearWirePerformance
#endif

@MainActor
final class DemoApplicationModel: ObservableObject {
  @Published private(set) var messageText = ""
  @Published private(set) var counter = 0
  @Published private(set) var banner = "No banner received from Viewer."
  @Published private(set) var summaries: [DemoEventSummary] = []
  @Published private(set) var lastSendPresentation = "No Demo Event has entered the local queue."
  @Published private(set) var queuePresentation = "Local queue diagnostics have not been read."
  @Published private(set) var performance: DemoPerformancePresentation = .stopped
  @Published private(set) var eventObservationPresentation = "Observation has not started."
  @Published private(set) var displayedError: String?
  @Published private(set) var isResetting = false

  private let driver: DemoDriver
  private var summaryBuffer = DemoSummaryBuffer()
  private var observationGeneration: UInt64 = 0
  private var eventTask: Task<Void, Never>?
  private var performanceTask: Task<Void, Never>?

  init(nearWire: NearWire, performanceMonitor: NearWirePerformanceMonitor) {
    driver = DemoDriver(nearWire: nearWire, performanceMonitor: performanceMonitor)
  }

  deinit {
    eventTask?.cancel()
    performanceTask?.cancel()
  }

  func activate() {
    startEventObservationIfNeeded()
    startPerformanceObservationIfNeeded()
  }

  func updateMessage(_ value: String) {
    messageText = DemoTextLimit.truncated(value)
  }

  func sendMessage() async {
    let value = messageText
    guard DemoTextLimit.accepts(value) else {
      displayedError = "Enter a message between 1 and 512 UTF-8 bytes."
      return
    }
    await submit {
      try await driver.sendMessage(value)
    }
  }

  func incrementCounter() async {
    counter = counter == Int.max ? 0 : counter + 1
    let value = counter
    await submit {
      try await driver.sendCounter(value)
    }
  }

  func refreshDiagnostics() async {
    do {
      queuePresentation = try await driver.diagnostics().presentation
      displayedError = nil
    } catch {
      displayedError = "Local queue diagnostics are unavailable."
    }
  }

  func startPerformance() async {
    do {
      try await driver.startPerformance()
      displayedError = nil
    } catch let error as NearWirePerformanceError {
      displayedError = error.message
    } catch {
      displayedError = "Performance collection could not start."
    }
  }

  func stopPerformance() async {
    await driver.stopPerformance()
  }

  func reset() async {
    guard !isResetting else { return }
    isResetting = true
    observationGeneration &+= 1

    let oldEventTask = eventTask
    let oldPerformanceTask = performanceTask
    eventTask = nil
    performanceTask = nil
    oldEventTask?.cancel()
    oldPerformanceTask?.cancel()
    await oldEventTask?.value
    await oldPerformanceTask?.value

    await driver.stopPerformance()
    await driver.disconnect()
    clearPresentation()
    isResetting = false
    activate()
  }

  func tearDown() async {
    observationGeneration &+= 1
    let oldEventTask = eventTask
    let oldPerformanceTask = performanceTask
    eventTask = nil
    performanceTask = nil
    oldEventTask?.cancel()
    oldPerformanceTask?.cancel()
    await oldEventTask?.value
    await oldPerformanceTask?.value
    await driver.stopPerformance()
    await driver.disconnect()
    await driver.shutdown()
    clearPresentation()
  }

  private func submit(_ operation: () async throws -> DemoSendReceipt) async {
    do {
      let result = try await operation()
      lastSendPresentation = result.presentation
      queuePresentation = try await driver.diagnostics().presentation
      displayedError = nil
    } catch {
      displayedError = "The Demo Event could not enter the local NearWire queue."
    }
  }

  private func startEventObservationIfNeeded() {
    guard eventTask == nil else { return }
    let generation = observationGeneration
    let events = driver.events
    eventObservationPresentation = "Observing Viewer Events."
    eventTask = Task { [weak self] in
      do {
        for try await event in events {
          guard !Task.isCancelled, let self else { return }
          await self.handle(event, generation: generation)
        }
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.eventObservationFailed(generation: generation)
      }
    }
  }

  private func startPerformanceObservationIfNeeded() {
    guard performanceTask == nil else { return }
    let generation = observationGeneration
    let states = driver.performanceStates
    performanceTask = Task { [weak self] in
      for await state in states {
        guard !Task.isCancelled, let self else { return }
        self.apply(state, generation: generation)
      }
    }
  }

  private func handle(_ event: NearWireEvent, generation: UInt64) async {
    guard generation == observationGeneration, !Task.isCancelled else { return }

    let direction: DemoIncomingDirection =
      event.direction == .viewerToApp ? .viewerToApp : .appToViewer
    let decodedControl = try? event.decode(DemoBannerControl.self)
    let decision = DemoControlEvaluator.evaluate(
      type: event.type,
      direction: direction,
      control: decodedControl
    )

    switch decision {
    case .apply(let value):
      banner = value
      appendSummary(type: event.type, outcome: "Applied banner control.")
      guard generation == observationGeneration, !Task.isCancelled else { return }
      do {
        _ = try await driver.reply(to: event, banner: value)
      } catch {
        guard generation == observationGeneration else { return }
        displayedError = "The control was applied, but its local reply could not be queued."
      }
    case .ignore(let reason):
      appendSummary(type: event.type, outcome: reason)
    }
  }

  private func appendSummary(type: String, outcome: String) {
    summaryBuffer.append(
      DemoEventSummary(
        id: UUID(),
        createdAt: Date(),
        type: String(type.prefix(80)),
        outcome: outcome
      )
    )
    summaries = summaryBuffer.values
  }

  private func eventObservationFailed(generation: UInt64) {
    guard generation == observationGeneration else { return }
    eventTask = nil
    eventObservationPresentation = "Observation stopped. Reset Demo to start a fresh stream."
    displayedError = "Viewer Event observation stopped."
  }

  private func apply(_ state: NearWirePerformanceMonitorState, generation: UInt64) {
    guard generation == observationGeneration else { return }
    switch state {
    case .stopped:
      performance = .stopped
    case .running:
      performance = .running
    case .failed(let error):
      performance = .failed(error.message)
      displayedError = error.message
    }
  }

  private func clearPresentation() {
    messageText = ""
    counter = 0
    banner = "No banner received from Viewer."
    summaryBuffer.removeAll()
    summaries = []
    lastSendPresentation = "No Demo Event has entered the local queue."
    queuePresentation = "Local queue diagnostics have not been read."
    performance = .stopped
    eventObservationPresentation = "Observation has not started."
    displayedError = nil
  }
}
