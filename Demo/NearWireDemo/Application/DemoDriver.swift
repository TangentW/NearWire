import Foundation
import NearWire

#if NEARWIRE_DEMO_SEPARATE_MODULES
  import NearWirePerformance
#endif

struct DemoDriver: Sendable {
  let nearWire: NearWire
  let performanceMonitor: NearWirePerformanceMonitor

  var events: AsyncThrowingStream<NearWireEvent, Error> {
    nearWire.events
  }

  var performanceStates: AsyncStream<NearWirePerformanceMonitorState> {
    performanceMonitor.states
  }

  func sendMessage(_ text: String) async throws -> DemoSendReceipt {
    let result = try await nearWire.send(
      type: DemoEventType.message,
      content: DemoMessage(text: text),
      policy: .normal
    )
    return DemoSendReceipt(
      eventID: result.eventID,
      isBuffered: result.isBuffered,
      replacedPendingValue: result.coalescedEventID != nil
    )
  }

  func sendCounter(_ value: Int) async throws -> DemoSendReceipt {
    let result = try await nearWire.send(
      type: DemoEventType.counter,
      content: DemoCounter(value: value),
      policy: .keepLatest(key: DemoEventType.counterLatestKey)
    )
    return DemoSendReceipt(
      eventID: result.eventID,
      isBuffered: result.isBuffered,
      replacedPendingValue: result.coalescedEventID != nil
    )
  }

  func reply(to event: NearWireEvent, banner: String) async throws -> DemoSendReceipt {
    let result = try await nearWire.reply(
      to: event,
      type: DemoEventType.controlResult,
      content: DemoControlResult(status: "applied", bannerByteCount: banner.utf8.count)
    )
    return DemoSendReceipt(
      eventID: result.eventID,
      isBuffered: result.isBuffered,
      replacedPendingValue: result.coalescedEventID != nil
    )
  }

  func diagnostics() async throws -> DemoQueueSnapshot {
    let result = try await nearWire.bufferDiagnostics()
    return DemoQueueSnapshot(eventCount: result.eventCount, byteCount: result.accountedByteCount)
  }

  func startPerformance() async throws {
    try await performanceMonitor.start()
  }

  func stopPerformance() async {
    await performanceMonitor.stop()
  }

  func disconnect() async {
    await nearWire.disconnect()
  }

  func suspendConnection() async {
    await nearWire.suspendConnection()
  }

  func resumeConnection() async {
    await nearWire.resumeConnection()
  }

  func shutdown() async {
    await nearWire.shutdown()
  }
}
