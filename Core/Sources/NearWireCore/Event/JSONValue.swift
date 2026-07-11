import CoreFoundation
import Foundation

@_spi(NearWireInternal) public indirect enum JSONValue: Equatable, Hashable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    switch try container.decode(JSONValueKind.self) {
    case .null:
      self = .null
    case .bool:
      self = .bool(try container.decode(Bool.self))
    case .integer:
      self = .integer(try container.decode(Int64.self))
    case .number:
      let value = try container.decode(Double.self)
      guard value.isFinite else {
        throw EventModelError(code: .nonFiniteNumber, message: "JSON numbers must be finite.")
      }
      self = .number(value)
    case .string:
      self = .string(try container.decode(String.self))
    case .array:
      self = .array(try container.decode([JSONValue].self))
    case .object:
      self = .object(try container.decode([String: JSONValue].self))
    }
    try validate(limits: decoder.nearWireEventValidationLimits)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    switch self {
    case .null:
      try container.encode(JSONValueKind.null)
    case .bool(let value):
      try container.encode(JSONValueKind.bool)
      try container.encode(value)
    case .integer(let value):
      try container.encode(JSONValueKind.integer)
      try container.encode(value)
    case .number(let value):
      guard value.isFinite else {
        throw EventModelError(code: .nonFiniteNumber, message: "JSON numbers must be finite.")
      }
      try container.encode(JSONValueKind.number)
      try container.encode(value)
    case .string(let value):
      try container.encode(JSONValueKind.string)
      try container.encode(value)
    case .array(let values):
      try container.encode(JSONValueKind.array)
      try container.encode(values)
    case .object(let values):
      try container.encode(JSONValueKind.object)
      try container.encode(values)
    }
  }
}

extension JSONValue {
  public static func decodeJSON(
    from data: Data,
    limits: EventValidationLimits = .default
  ) throws -> JSONValue {
    try preflightJSONInput(
      data,
      maximumByteCount: limits.maximumEncodedContentBytes,
      maximumNestingDepth: limits.maximumContentDepth,
      validateIntegerRange: true
    )

    let foundationValue: Any
    do {
      foundationValue = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw EventModelError(
        code: .invalidContent,
        message: "Content is not valid JSON: \(error.localizedDescription)"
      )
    }

    let value = try fromFoundation(foundationValue, path: "$", depth: 1, limits: limits)
    try value.validate(limits: limits)
    return value
  }

  public func deterministicData() throws -> Data {
    try deterministicData(maximumByteCount: nil)
  }

  private func deterministicData(maximumByteCount: Int?) throws -> Data {
    var data = Data()
    do {
      try appendDeterministicJSON(to: &data, maximumByteCount: maximumByteCount)
      return data
    } catch let error as EventModelError {
      throw error
    } catch {
      throw EventModelError(
        code: .contentEncodingFailed,
        message: "Unable to encode JSON content: \(error.localizedDescription)"
      )
    }
  }

  private func appendDeterministicJSON(
    to data: inout Data,
    maximumByteCount: Int?
  ) throws {
    switch self {
    case .null:
      try Self.append(Data("null".utf8), to: &data, maximumByteCount: maximumByteCount)
    case .bool(let value):
      try Self.append(
        Data((value ? "true" : "false").utf8),
        to: &data,
        maximumByteCount: maximumByteCount
      )
    case .integer(let value):
      try Self.append(Data(String(value).utf8), to: &data, maximumByteCount: maximumByteCount)
    case .number(let value):
      guard value.isFinite else {
        throw EventModelError(code: .nonFiniteNumber, message: "JSON numbers must be finite.")
      }
      try Self.append(Data(String(value).utf8), to: &data, maximumByteCount: maximumByteCount)
    case .string(let value):
      try Self.append(
        Self.encodedJSONString(value),
        to: &data,
        maximumByteCount: maximumByteCount
      )
    case .array(let values):
      try Self.append(Data("[".utf8), to: &data, maximumByteCount: maximumByteCount)
      for (index, value) in values.enumerated() {
        if index > 0 {
          try Self.append(Data(",".utf8), to: &data, maximumByteCount: maximumByteCount)
        }
        try value.appendDeterministicJSON(to: &data, maximumByteCount: maximumByteCount)
      }
      try Self.append(Data("]".utf8), to: &data, maximumByteCount: maximumByteCount)
    case .object(let values):
      try Self.append(Data("{".utf8), to: &data, maximumByteCount: maximumByteCount)
      for (index, key) in values.keys.sorted().enumerated() {
        if index > 0 {
          try Self.append(Data(",".utf8), to: &data, maximumByteCount: maximumByteCount)
        }
        try Self.append(
          Self.encodedJSONString(key),
          to: &data,
          maximumByteCount: maximumByteCount
        )
        try Self.append(Data(":".utf8), to: &data, maximumByteCount: maximumByteCount)
        guard let child = values[key] else {
          throw EventModelError(
            code: .invalidContent,
            message: "Object content changed during deterministic encoding."
          )
        }
        try child.appendDeterministicJSON(to: &data, maximumByteCount: maximumByteCount)
      }
      try Self.append(Data("}".utf8), to: &data, maximumByteCount: maximumByteCount)
    }
  }

  private static func append(
    _ bytes: Data,
    to data: inout Data,
    maximumByteCount: Int?
  ) throws {
    if let maximumByteCount,
      bytes.count > maximumByteCount - min(data.count, maximumByteCount)
    {
      throw EventModelError(
        code: .encodedContentTooLarge,
        message: "Encoded content exceeds the \(maximumByteCount)-byte limit."
      )
    }
    data.append(bytes)
  }

  static func preflightJSONInput(
    _ data: Data,
    maximumByteCount: Int,
    maximumNestingDepth: Int,
    validateIntegerRange: Bool
  ) throws {
    guard data.count <= maximumByteCount else {
      throw EventModelError(
        code: .encodedContentTooLarge,
        message: "Encoded JSON uses \(data.count) bytes; the limit is \(maximumByteCount)."
      )
    }

    let bytes = [UInt8](data)
    var index = 0
    var nestingDepth = 0
    var isInsideString = false
    var isEscaped = false

    while index < bytes.count {
      let byte = bytes[index]
      if isInsideString {
        if isEscaped {
          isEscaped = false
        } else if byte == 92 {
          isEscaped = true
        } else if byte == 34 {
          isInsideString = false
        }
        index += 1
        continue
      }

      if byte == 34 {
        isInsideString = true
        index += 1
        continue
      }
      if byte == 91 || byte == 123 {
        nestingDepth += 1
        guard nestingDepth <= maximumNestingDepth else {
          throw EventModelError(
            code: .structuralLimitExceeded,
            message: "JSON input exceeds maximum nesting depth \(maximumNestingDepth)."
          )
        }
        index += 1
        continue
      }
      if byte == 93 || byte == 125 {
        nestingDepth = max(0, nestingDepth - 1)
        index += 1
        continue
      }

      if validateIntegerRange, byte == 45 || (48...57).contains(byte),
        let token = numberToken(in: bytes, startingAt: index)
      {
        if token.isInteger {
          let value = String(decoding: bytes[index..<token.endIndex], as: UTF8.self)
          guard Int64(value) != nil else {
            throw EventModelError(
              code: .integerOutOfRange,
              message: "JSON integer is outside the signed 64-bit range."
            )
          }
        }
        index = token.endIndex
        continue
      }

      index += 1
    }
  }

  private static func numberToken(
    in bytes: [UInt8],
    startingAt startIndex: Int
  ) -> (endIndex: Int, isInteger: Bool)? {
    var index = startIndex
    if bytes[index] == 45 {
      index += 1
      guard index < bytes.count else { return nil }
    }

    if bytes[index] == 48 {
      index += 1
    } else {
      guard (49...57).contains(bytes[index]) else { return nil }
      while index < bytes.count, (48...57).contains(bytes[index]) {
        index += 1
      }
    }

    var isInteger = true
    if index < bytes.count, bytes[index] == 46 {
      isInteger = false
      index += 1
      let fractionStart = index
      while index < bytes.count, (48...57).contains(bytes[index]) {
        index += 1
      }
      guard index > fractionStart else { return nil }
    }

    if index < bytes.count, bytes[index] == 69 || bytes[index] == 101 {
      isInteger = false
      index += 1
      if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
        index += 1
      }
      let exponentStart = index
      while index < bytes.count, (48...57).contains(bytes[index]) {
        index += 1
      }
      guard index > exponentStart else { return nil }
    }

    guard index == bytes.count || isJSONTokenDelimiter(bytes[index]) else {
      return nil
    }
    return (index, isInteger)
  }

  private static func isJSONTokenDelimiter(_ byte: UInt8) -> Bool {
    byte == 9 || byte == 10 || byte == 13 || byte == 32 || byte == 44 || byte == 93
      || byte == 125
  }

  private static func encodedJSONString(_ value: String) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  public func validate(limits: EventValidationLimits = .default) throws {
    try validate(path: "$", depth: 1, limits: limits)
    _ = try deterministicData(maximumByteCount: limits.maximumEncodedContentBytes)
  }

  private static func fromFoundation(
    _ value: Any,
    path: String,
    depth: Int,
    limits: EventValidationLimits
  ) throws -> JSONValue {
    guard depth <= limits.maximumContentDepth else {
      throw EventModelError(
        code: .structuralLimitExceeded,
        path: path,
        message: "Content exceeds maximum depth \(limits.maximumContentDepth)."
      )
    }

    if value is NSNull {
      return .null
    }

    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }

      let numericType = String(cString: number.objCType)
      if numericType == "f" || numericType == "d" {
        let double = number.doubleValue
        guard double.isFinite else {
          throw EventModelError(
            code: .nonFiniteNumber, path: path, message: "JSON numbers must be finite.")
        }
        return .number(double)
      }

      guard let integer = Int64(number.stringValue) else {
        throw EventModelError(
          code: .integerOutOfRange,
          path: path,
          message: "JSON integer is outside the signed 64-bit range."
        )
      }
      return .integer(integer)
    }

    if let string = value as? String {
      return .string(string)
    }

    if let array = value as? [Any] {
      guard array.count <= limits.maximumArrayEntries else {
        throw EventModelError(
          code: .structuralLimitExceeded,
          path: path,
          message:
            "Array contains \(array.count) entries; the limit is \(limits.maximumArrayEntries)."
        )
      }
      return .array(
        try array.enumerated().map { index, value in
          try fromFoundation(value, path: "\(path)[\(index)]", depth: depth + 1, limits: limits)
        })
    }

    if let object = value as? [String: Any] {
      guard object.count <= limits.maximumObjectEntries else {
        throw EventModelError(
          code: .structuralLimitExceeded,
          path: path,
          message:
            "Object contains \(object.count) entries; the limit is \(limits.maximumObjectEntries)."
        )
      }
      var result: [String: JSONValue] = [:]
      result.reserveCapacity(object.count)
      for (key, child) in object {
        result[key] = try fromFoundation(
          child,
          path: pathForKey(key, parent: path),
          depth: depth + 1,
          limits: limits
        )
      }
      return .object(result)
    }

    throw EventModelError(
      code: .invalidContent,
      path: path,
      message: "Value is not JSON-compatible."
    )
  }

  private func validate(
    path: String,
    depth: Int,
    limits: EventValidationLimits
  ) throws {
    guard depth <= limits.maximumContentDepth else {
      throw EventModelError(
        code: .structuralLimitExceeded,
        path: path,
        message: "Content exceeds maximum depth \(limits.maximumContentDepth)."
      )
    }

    switch self {
    case .null, .bool, .integer:
      break
    case .number(let value):
      guard value.isFinite else {
        throw EventModelError(
          code: .nonFiniteNumber, path: path, message: "JSON numbers must be finite.")
      }
    case .string(let value):
      try validateBytes(
        value,
        maximum: limits.maximumStringBytes,
        code: .structuralLimitExceeded,
        path: path,
        label: "String"
      )
    case .array(let values):
      guard values.count <= limits.maximumArrayEntries else {
        throw EventModelError(
          code: .structuralLimitExceeded,
          path: path,
          message:
            "Array contains \(values.count) entries; the limit is \(limits.maximumArrayEntries)."
        )
      }
      for (index, value) in values.enumerated() {
        try value.validate(path: "\(path)[\(index)]", depth: depth + 1, limits: limits)
      }
    case .object(let values):
      guard values.count <= limits.maximumObjectEntries else {
        throw EventModelError(
          code: .structuralLimitExceeded,
          path: path,
          message:
            "Object contains \(values.count) entries; the limit is \(limits.maximumObjectEntries)."
        )
      }
      for (key, value) in values {
        let childPath = Self.pathForKey(key, parent: path)
        try validateBytes(
          key,
          maximum: limits.maximumObjectKeyBytes,
          code: .structuralLimitExceeded,
          path: childPath,
          label: "Object key"
        )
        try value.validate(path: childPath, depth: depth + 1, limits: limits)
      }
    }
  }

  private func validateBytes(
    _ value: String,
    maximum: Int,
    code: EventModelError.Code,
    path: String,
    label: String
  ) throws {
    let byteCount = value.utf8.count
    guard byteCount <= maximum else {
      throw EventModelError(
        code: code,
        path: path,
        message: "\(label) uses \(byteCount) UTF-8 bytes; the limit is \(maximum)."
      )
    }
  }

  private static func pathForKey(_ key: String, parent: String) -> String {
    let escaped = key.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\(parent)[\"\(escaped)\"]"
  }
}

private enum JSONValueKind: UInt8, Codable {
  case null = 0
  case bool = 1
  case integer = 2
  case number = 3
  case string = 4
  case array = 5
  case object = 6
}
