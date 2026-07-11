import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
  @_spi(NearWireInternal) import NearWireFlowControl
#endif

enum SDKValidation {
  static func validateRate(_ value: Double, field: String) throws {
    do {
      _ = try EventRateLimit(eventsPerSecond: value)
    } catch {
      throw NearWireError(
        code: .invalidConfiguration,
        field: field,
        message: "Event rate must be zero or a supported finite positive value."
      )
    }
  }

  static func validateBuffer(
    maximumEventCount: Int,
    maximumBytes: Int,
    maximumEventBytes: Int,
    defaultTTL: NearWireEventTTL
  ) throws {
    do {
      _ = try EventQueueLimits(
        maximumEventCount: maximumEventCount,
        maximumTotalBytes: maximumBytes,
        maximumSingleEventBytes: maximumEventBytes
      )
    } catch {
      throw NearWireError(
        code: .invalidConfiguration,
        field: "buffer",
        message: "Buffer count and byte limits are outside the supported range."
      )
    }
    _ = try coreTTL(defaultTTL, field: "buffer.defaultTTL")
  }

  static func coreTTL(_ ttl: NearWireEventTTL, field: String = "options.ttl") throws -> EventTTL {
    let milliseconds: UInt64
    switch ttl {
    case .milliseconds(let value):
      milliseconds = value
    case .seconds(let value):
      let (result, overflow) = value.multipliedReportingOverflow(by: 1_000)
      guard !overflow else { throw invalidTTL(field: field) }
      milliseconds = result
    case .minutes(let value):
      let (seconds, secondsOverflow) = value.multipliedReportingOverflow(by: 60)
      let (result, millisecondsOverflow) = seconds.multipliedReportingOverflow(by: 1_000)
      guard !secondsOverflow, !millisecondsOverflow else { throw invalidTTL(field: field) }
      milliseconds = result
    }

    do {
      return try EventTTL(milliseconds: milliseconds)
    } catch {
      throw invalidTTL(field: field)
    }
  }

  static func queueLimits(_ value: NearWireBufferConfiguration) -> EventQueueLimits {
    // Public construction has already validated these exact values.
    // The fallback is unreachable for a valid NearWireBufferConfiguration and avoids traps.
    (try? EventQueueLimits(
      maximumEventCount: value.maximumEventCount,
      maximumTotalBytes: value.maximumBytes,
      maximumSingleEventBytes: value.maximumEventBytes
    )) ?? .default
  }

  private static func invalidTTL(field: String) -> NearWireError {
    NearWireError(
      code: .invalidEventOptions,
      field: field,
      message: "TTL must be between one millisecond and seven days."
    )
  }
}

enum SDKContentConversion {
  static func encode<Value: Encodable & Sendable>(_ value: Value) throws -> JSONValue {
    do {
      return try EventContentCodec().encode(value)
    } catch let error as EventModelError {
      switch error.code {
      case .encodedContentTooLarge, .structuralLimitExceeded:
        throw NearWireError(
          code: .invalidContent,
          field: "content",
          message: "Event content exceeds the supported structural limits."
        )
      case .nonFiniteNumber, .integerOutOfRange, .invalidContent:
        throw NearWireError(
          code: .invalidContent,
          field: "content",
          message: "Event content is not a supported JSON value."
        )
      default:
        throw NearWireError(
          code: .contentEncodingFailed,
          field: "content",
          message: "Event content could not be encoded."
        )
      }
    } catch {
      throw NearWireError(
        code: .contentEncodingFailed,
        field: "content",
        message: "Event content could not be encoded."
      )
    }
  }

  static func decode<Value: Decodable>(
    _ type: Value.Type,
    from content: NearWireEventContent
  ) throws -> Value {
    do {
      return try EventContentCodec().decode(type, from: content.coreValue)
    } catch {
      throw NearWireError(
        code: .contentDecodingFailed,
        field: "content",
        message: "Event content could not be decoded as the requested type."
      )
    }
  }
}

extension NearWireEventContent {
  init(coreValue: JSONValue) {
    switch coreValue {
    case .null: self = .null
    case .bool(let value): self = .bool(value)
    case .integer(let value): self = .integer(value)
    case .number(let value): self = .number(value)
    case .string(let value): self = .string(value)
    case .array(let values): self = .array(values.map(NearWireEventContent.init(coreValue:)))
    case .object(let values):
      self = .object(values.mapValues(NearWireEventContent.init(coreValue:)))
    }
  }

  var coreValue: JSONValue {
    switch self {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .integer(let value): return .integer(value)
    case .number(let value): return .number(value)
    case .string(let value): return .string(value)
    case .array(let values): return .array(values.map(\.coreValue))
    case .object(let values): return .object(values.mapValues(\.coreValue))
    }
  }
}

extension NearWireEventPriority {
  var coreValue: EventPriority {
    switch self {
    case .low: return .low
    case .normal: return .normal
    case .high: return .high
    case .critical: return .critical
    }
  }

  init(coreValue: EventPriority) {
    switch coreValue {
    case .low: self = .low
    case .normal: self = .normal
    case .high: self = .high
    case .critical: self = .critical
    }
  }
}

extension NearWireEventDirection {
  init(coreValue: EventDirection) {
    switch coreValue {
    case .appToViewer: self = .appToViewer
    case .viewerToApp: self = .viewerToApp
    }
  }
}

extension UUID {
  var nearWireCanonicalString: String { uuidString.lowercased() }
}

extension EventID {
  var sdkUUID: UUID {
    // EventID construction guarantees canonical UUID content.
    UUID(uuidString: rawValue)!
  }
}
