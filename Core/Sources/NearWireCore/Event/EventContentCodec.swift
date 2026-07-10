import Foundation

public struct EventContentCodec: Sendable {
  public let limits: EventValidationLimits

  public init(limits: EventValidationLimits = .default) {
    self.limits = limits
  }

  public func encode<Value: Encodable & Sendable>(_ value: Value) throws -> JSONValue {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(value)
    } catch let error as EventModelError {
      throw error
    } catch {
      throw EventModelError(
        code: .contentEncodingFailed,
        message: "Unable to encode event content: \(error.localizedDescription)"
      )
    }
    return try JSONValue.decodeJSON(from: data, limits: limits)
  }

  public func decode<Value: Decodable>(
    _ type: Value.Type,
    from content: JSONValue
  ) throws -> Value {
    do {
      try content.validate(limits: limits)
      return try Self.makeDecoder(limits: limits).decode(type, from: content.deterministicData())
    } catch let error as EventModelError {
      throw EventModelError(
        code: .contentDecodingFailed,
        path: error.path,
        message: error.message
      )
    } catch {
      throw EventModelError(
        code: .contentDecodingFailed,
        message: "Unable to decode event content: \(error.localizedDescription)"
      )
    }
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dataEncodingStrategy = .base64
    encoder.nonConformingFloatEncodingStrategy = .throw
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(Self.format(date))
    }
    return encoder
  }

  private static func makeDecoder(limits: EventValidationLimits) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.userInfo[.nearWireEventValidationLimits] = limits
    decoder.dataDecodingStrategy = .base64
    decoder.nonConformingFloatDecodingStrategy = .throw
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      if let date = Self.dateFormatter(fractionalSeconds: true).date(from: value)
        ?? Self.dateFormatter(fractionalSeconds: false).date(from: value)
      {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ISO-8601 UTC date."
      )
    }
    return decoder
  }

  private static func format(_ date: Date) -> String {
    dateFormatter(fractionalSeconds: true).string(from: date)
  }

  private static func dateFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions =
      fractionalSeconds
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter
  }
}

extension CodingUserInfoKey {
  static let nearWireEventValidationLimits = CodingUserInfoKey(
    rawValue: "com.nearwire.event-validation-limits"
  )!
}

extension Decoder {
  var nearWireEventValidationLimits: EventValidationLimits {
    userInfo[.nearWireEventValidationLimits] as? EventValidationLimits ?? .default
  }
}
