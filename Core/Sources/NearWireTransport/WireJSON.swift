import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

enum WireJSON {
  static func object(_ value: JSONValue, path: String = "body") throws -> [String: JSONValue] {
    guard case .object(let object) = value else {
      throw invalid(path, "Expected a JSON object.")
    }
    return object
  }

  static func required(_ key: String, in object: [String: JSONValue], path: String) throws
    -> JSONValue
  {
    guard let value = object[key] else {
      throw invalid("\(path).\(key)", "Missing required field.")
    }
    return value
  }

  static func string(_ value: JSONValue, path: String) throws -> String {
    guard case .string(let string) = value else { throw invalid(path, "Expected a string.") }
    return string
  }

  static func bool(_ value: JSONValue, path: String) throws -> Bool {
    guard case .bool(let bool) = value else { throw invalid(path, "Expected a Boolean.") }
    return bool
  }

  static func int64(_ value: JSONValue, path: String) throws -> Int64 {
    guard case .integer(let integer) = value else { throw invalid(path, "Expected an integer.") }
    return integer
  }

  static func positiveInt(_ value: JSONValue, path: String) throws -> Int {
    let integer = try int64(value, path: path)
    guard integer > 0, integer <= Int64(Int.max) else {
      throw invalid(path, "Expected a positive platform integer.")
    }
    return Int(integer)
  }

  static func uint16(_ value: JSONValue, path: String) throws -> UInt16 {
    let integer = try int64(value, path: path)
    guard integer > 0, integer <= Int64(UInt16.max) else {
      throw invalid(path, "Expected a nonzero UInt16 value.")
    }
    return UInt16(integer)
  }

  static func uint64(_ value: JSONValue, path: String) throws -> UInt64 {
    let raw = try string(value, path: path)
    guard let value = UInt64(raw), raw == String(value) else {
      throw invalid(path, "Expected a canonical unsigned decimal string.")
    }
    return value
  }

  static func double(_ value: JSONValue, path: String) throws -> Double {
    let result: Double
    switch value {
    case .integer(let integer): result = Double(integer)
    case .number(let number): result = number
    default: throw invalid(path, "Expected a finite number.")
    }
    guard result.isFinite else { throw invalid(path, "Expected a finite number.") }
    return result
  }

  static func array(_ value: JSONValue, path: String) throws -> [JSONValue] {
    guard case .array(let array) = value else { throw invalid(path, "Expected an array.") }
    return array
  }

  static func stringArray(
    _ value: JSONValue,
    path: String,
    maximumCount: Int
  ) throws -> [String] {
    let values = try array(value, path: path)
    guard values.count <= maximumCount else {
      throw invalid(path, "Array exceeds the configured entry limit.")
    }
    return try values.enumerated().map { index, value in
      try string(value, path: "\(path)[\(index)]")
    }
  }

  static func optionalString(
    _ key: String,
    in object: [String: JSONValue],
    path: String
  ) throws -> String? {
    guard let value = object[key], value != .null else { return nil }
    return try string(value, path: "\(path).\(key)")
  }

  static func invalid(_ path: String, _ message: String) -> WireProtocolError {
    WireProtocolError(code: .invalidMessage, path: path, message: message)
  }
}

extension UInt64 {
  var wireJSONValue: JSONValue { .string(String(self)) }
}
