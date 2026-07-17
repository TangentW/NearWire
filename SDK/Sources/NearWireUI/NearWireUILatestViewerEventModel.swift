import Foundation

#if SWIFT_PACKAGE
  import NearWire
#endif

protocol NearWireUIEventProviding: AnyObject, Sendable {
  var events: AsyncThrowingStream<NearWireEvent, Error> { get }
}

extension NearWire: NearWireUIEventProviding {}

struct NearWireUILatestEventPresentation: Equatable, Sendable {
  let type: String
  let contentSummary: String

  init(event: NearWireEvent) {
    type = NearWireUIEventSummaryFormatter.boundedType(event.type)
    contentSummary = NearWireUIEventSummaryFormatter.summary(event.content)
  }
}

@MainActor
final class NearWireUILatestViewerEventModel: ObservableObject {
  @Published private(set) var latest: NearWireUILatestEventPresentation?
  @Published private(set) var displayedErrorMessage: String?

  private let source: any NearWireUIEventProviding
  private var generation: UInt64 = 0
  private var observationTask: Task<Void, Never>?

  init(source: any NearWireUIEventProviding) {
    self.source = source
  }

  deinit {
    observationTask?.cancel()
  }

  func startObserving() {
    guard observationTask == nil else { return }
    generation &+= 1
    let currentGeneration = generation
    let events = source.events
    observationTask = Task { [weak self] in
      do {
        for try await event in events {
          guard !Task.isCancelled else { return }
          guard event.direction == .viewerToApp else { continue }
          let presentation = NearWireUILatestEventPresentation(event: event)
          guard let self else { return }
          self.apply(presentation, generation: currentGeneration)
        }
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.fail(generation: currentGeneration)
      }
    }
  }

  func stopObserving() {
    generation &+= 1
    observationTask?.cancel()
    observationTask = nil
    latest = nil
    displayedErrorMessage = nil
  }

  private func apply(
    _ presentation: NearWireUILatestEventPresentation,
    generation expectedGeneration: UInt64
  ) {
    guard generation == expectedGeneration else { return }
    latest = presentation
    displayedErrorMessage = nil
  }

  private func fail(generation expectedGeneration: UInt64) {
    guard generation == expectedGeneration else { return }
    observationTask = nil
    displayedErrorMessage = "Viewer Event observation stopped."
  }
}

enum NearWireUIEventSummaryFormatter {
  static let maximumTypeBytes = 256
  static let maximumSummaryBytes = 4_096
  static let maximumDepth = 8
  static let maximumCollectionItems = 32
  static let maximumNodes = 256

  static func boundedType(_ value: String) -> String {
    NearWireUIUTF8Limit.truncate(value, maximumBytes: maximumTypeBytes)
  }

  static func summary(_ content: NearWireEventContent) -> String {
    var writer = NearWireUIBoundedWriter(maximumBytes: maximumSummaryBytes)
    var remainingNodes = maximumNodes
    write(content, depth: 0, remainingNodes: &remainingNodes, writer: &writer)
    return writer.finishedValue
  }

  private static func write(
    _ content: NearWireEventContent,
    depth: Int,
    remainingNodes: inout Int,
    writer: inout NearWireUIBoundedWriter
  ) {
    guard !writer.isFull else { return }
    guard remainingNodes > 0 else {
      writer.markTruncated()
      return
    }
    remainingNodes -= 1

    guard depth <= maximumDepth else {
      writer.markTruncated()
      return
    }

    switch content {
    case .null:
      writer.append("null")
    case .bool(let value):
      writer.append(value ? "true" : "false")
    case .integer(let value):
      writer.append(String(value))
    case .number(let value):
      writer.append(value.isFinite ? String(value) : "null")
    case .string(let value):
      writeString(value, writer: &writer)
    case .array(let values):
      writer.append("[")
      for (index, value) in values.prefix(maximumCollectionItems).enumerated() {
        if index > 0 { writer.append(", ") }
        write(value, depth: depth + 1, remainingNodes: &remainingNodes, writer: &writer)
        if writer.isFull { break }
      }
      if values.count > maximumCollectionItems {
        if !values.isEmpty { writer.append(", ") }
        writer.markTruncated()
      }
      writer.append("]")
    case .object(let values):
      writer.append("{")
      let keys = values.keys.sorted().prefix(maximumCollectionItems)
      for (index, key) in keys.enumerated() {
        if index > 0 { writer.append(", ") }
        writeString(key, writer: &writer)
        writer.append(": ")
        if let value = values[key] {
          write(value, depth: depth + 1, remainingNodes: &remainingNodes, writer: &writer)
        }
        if writer.isFull { break }
      }
      if values.count > maximumCollectionItems {
        if !values.isEmpty { writer.append(", ") }
        writer.markTruncated()
      }
      writer.append("}")
    }
  }

  private static func writeString(
    _ value: String,
    writer: inout NearWireUIBoundedWriter
  ) {
    writer.append("\"")
    for scalar in value.unicodeScalars {
      guard !writer.isFull else { break }
      switch scalar.value {
      case 0x22:
        writer.append("\\\"")
      case 0x5C:
        writer.append("\\\\")
      case 0x08:
        writer.append("\\b")
      case 0x0C:
        writer.append("\\f")
      case 0x0A:
        writer.append("\\n")
      case 0x0D:
        writer.append("\\r")
      case 0x09:
        writer.append("\\t")
      case 0x00...0x1F:
        writer.append(String(format: "\\u%04X", scalar.value))
      default:
        writer.append(String(scalar))
      }
    }
    writer.append("\"")
  }
}

private enum NearWireUIUTF8Limit {
  static func truncate(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    var result = ""
    var byteCount = 0
    for character in value {
      let bytes = String(character).utf8.count
      guard byteCount + bytes <= maximumBytes else { break }
      result.append(character)
      byteCount += bytes
    }
    return result
  }
}

private struct NearWireUIBoundedWriter {
  private static let truncationMarker = "…"

  private let maximumBytes: Int
  private var value = ""
  private var byteCount = 0
  private(set) var wasTruncated = false

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
  }

  var isFull: Bool {
    byteCount >= maximumBytes
  }

  mutating func append(_ text: String) {
    guard !isFull else {
      wasTruncated = true
      return
    }
    for character in text {
      let character = String(character)
      let bytes = character.utf8.count
      guard byteCount + bytes <= maximumBytes else {
        wasTruncated = true
        return
      }
      value.append(character)
      byteCount += bytes
    }
  }

  mutating func markTruncated() {
    wasTruncated = true
  }

  var finishedValue: String {
    guard wasTruncated else { return value }
    let markerBytes = Self.truncationMarker.utf8.count
    let prefix = NearWireUIUTF8Limit.truncate(
      value,
      maximumBytes: max(0, maximumBytes - markerBytes)
    )
    return prefix + Self.truncationMarker
  }
}
