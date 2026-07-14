import Foundation

enum DemoEventType {
  static let message = "demo.message"
  static let counter = "demo.counter"
  static let setBanner = "demo.control.set-banner"
  static let controlResult = "demo.control.result"
  static let counterLatestKey = "demo-counter"
}

struct DemoMessage: Codable, Equatable, Sendable {
  let text: String
}

struct DemoCounter: Codable, Equatable, Sendable {
  let value: Int
}

struct DemoBannerControl: Codable, Equatable, Sendable {
  let banner: String
}

struct DemoControlResult: Codable, Equatable, Sendable {
  let status: String
  let bannerByteCount: Int
}

enum DemoIncomingDirection: Equatable, Sendable {
  case appToViewer
  case viewerToApp
}

enum DemoControlDecision: Equatable, Sendable {
  case apply(String)
  case ignore(String)
}

enum DemoTextLimit {
  static let maximumBytes = 512

  static func accepts(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
  }

  static func truncated(_ value: String) -> String {
    var result = ""
    var byteCount = 0
    for character in value {
      let nextBytes = String(character).utf8.count
      guard byteCount + nextBytes <= maximumBytes else { break }
      result.append(character)
      byteCount += nextBytes
    }
    return result
  }
}

enum DemoControlEvaluator {
  static func evaluate(
    type: String,
    direction: DemoIncomingDirection,
    control: DemoBannerControl?
  ) -> DemoControlDecision {
    guard direction == .viewerToApp else {
      return .ignore("Ignored an Event with the wrong direction.")
    }
    guard type == DemoEventType.setBanner else {
      return .ignore("Ignored an unknown Viewer Event.")
    }
    guard let control, DemoTextLimit.accepts(control.banner) else {
      return .ignore("Rejected an invalid banner control.")
    }
    return .apply(control.banner)
  }
}

struct DemoEventSummary: Identifiable, Equatable, Sendable {
  let id: UUID
  let createdAt: Date
  let type: String
  let outcome: String
}

struct DemoSummaryBuffer: Equatable, Sendable {
  static let maximumCount = 50

  private(set) var values: [DemoEventSummary] = []

  mutating func append(_ value: DemoEventSummary) {
    values.append(value)
    if values.count > Self.maximumCount {
      values.removeFirst(values.count - Self.maximumCount)
    }
  }

  mutating func removeAll() {
    values.removeAll(keepingCapacity: false)
  }
}

struct DemoSendReceipt: Equatable, Sendable {
  let eventID: UUID
  let isBuffered: Bool
  let replacedPendingValue: Bool

  var presentation: String {
    if replacedPendingValue {
      return "Updated the latest value in the local queue. Remote delivery is not confirmed."
    }
    if isBuffered {
      return
        "Accepted by the local queue while transport is unavailable. Remote delivery is not confirmed."
    }
    return "Accepted by NearWire locally. Remote delivery is not confirmed."
  }
}

struct DemoQueueSnapshot: Equatable, Sendable {
  let eventCount: Int
  let byteCount: Int

  var presentation: String {
    "Local queue: \(eventCount) Events, \(byteCount) bytes."
  }
}

enum DemoPerformancePresentation: Equatable, Sendable {
  case stopped
  case running
  case failed(String)

  var title: String {
    switch self {
    case .stopped:
      return "Stopped"
    case .running:
      return "Running"
    case .failed:
      return "Failed"
    }
  }
}
