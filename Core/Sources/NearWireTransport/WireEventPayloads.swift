import Foundation

#if SWIFT_PACKAGE
  @_spi(NearWireInternal) import NearWireCore
#endif

@_spi(NearWireInternal) public struct WireEventRecord: Equatable, Sendable {
  public let envelope: EventEnvelope
  public let remainingTTLNanoseconds: UInt64

  public init(
    envelope: EventEnvelope,
    nowOnOriginClockNanoseconds now: UInt64
  ) throws {
    let deadline = try Self.validatedOriginDeadline(for: envelope)
    guard now >= envelope.monotonicTimestampNanoseconds else {
      throw WireProtocolError(
        code: .invalidClock,
        path: "nowOnOriginClockNanoseconds",
        message: "Origin clock cannot precede the event timestamp."
      )
    }
    guard now < deadline else {
      throw WireProtocolError(
        code: .eventExpired,
        path: "ttl",
        message: "Expired events cannot enter the wire protocol."
      )
    }
    self.envelope = envelope
    remainingTTLNanoseconds = deadline - now
  }

  public init(
    envelope: EventEnvelope,
    remainingTTLNanoseconds: UInt64
  ) throws {
    _ = try Self.validatedOriginDeadline(for: envelope)
    let (maximumRemaining, overflow) = envelope.ttl.milliseconds.multipliedReportingOverflow(
      by: 1_000_000)
    guard !overflow, remainingTTLNanoseconds > 0,
      remainingTTLNanoseconds <= maximumRemaining
    else {
      throw WireProtocolError(
        code: .invalidMessage,
        path: "remainingTTLNanoseconds",
        message: "Remaining TTL must be positive and no greater than original TTL."
      )
    }
    self.envelope = envelope
    self.remainingTTLNanoseconds = remainingTTLNanoseconds
  }

  private static func validatedOriginDeadline(for envelope: EventEnvelope) throws -> UInt64 {
    guard WireDateCodec.format(envelope.createdAt) != nil else {
      throw WireProtocolError(
        code: .invalidMessage,
        path: "createdAt",
        message: "Event date cannot use the canonical wire representation."
      )
    }
    let (duration, multiplyOverflow) = envelope.ttl.milliseconds.multipliedReportingOverflow(
      by: 1_000_000
    )
    let (deadline, addOverflow) = envelope.monotonicTimestampNanoseconds
      .addingReportingOverflow(duration)
    guard !multiplyOverflow, !addOverflow else {
      throw WireProtocolError(
        code: .arithmeticOverflow,
        path: "ttl",
        message: "Event deadline overflows the origin monotonic clock."
      )
    }
    return deadline
  }

  public func receiverEvent(
    receivedAtNanoseconds: UInt64
  ) throws -> WireReceivedEvent {
    let (deadline, overflow) = receivedAtNanoseconds.addingReportingOverflow(
      remainingTTLNanoseconds)
    guard !overflow else {
      throw WireProtocolError(
        code: .arithmeticOverflow,
        path: "receiverDeadline",
        message: "Receiver-local deadline overflows the monotonic clock."
      )
    }
    return WireReceivedEvent(
      envelope: envelope,
      receivedAtNanoseconds: receivedAtNanoseconds,
      deadlineNanoseconds: deadline,
      deterministicEncodedByteCount: try deterministicEncodedByteCount()
    )
  }

  public func deterministicEncodedByteCount() throws -> Int {
    try jsonValue().deterministicData().count
  }

  /// Returns the exact V1 record maximum for content already bounded by `eventLimits`.
  ///
  /// The calculation allocates only a fixed-size maximum non-content wrapper. It never creates
  /// content proportional to the configured content-byte limit.
  public static func maximumDeterministicEncodedByteCount(
    eventLimits: EventValidationLimits = .default
  ) throws -> Int {
    let maximumUUID = "ffffffff-ffff-4fff-bfff-ffffffffffff"
    let maximumEndpointID = String(repeating: "z", count: 128)
    let maximumType = String(repeating: "a", count: eventLimits.maximumTypeBytes)
    let (maximumRemainingTTL, ttlOverflow) =
      eventLimits.maximumTTLMilliseconds.multipliedReportingOverflow(by: 1_000_000)
    guard !ttlOverflow else {
      throw WireProtocolError(
        code: .arithmeticOverflow,
        path: "maximumEventBytes",
        message: "Maximum Event TTL size overflowed."
      )
    }
    let placeholder = JSONValue.null
    let record = JSONValue.object([
      "causality": .object([
        "correlationID": .string(maximumUUID),
        "replyTo": .string(maximumUUID),
      ]),
      "content": placeholder,
      "createdAt": .string("9999-12-31T23:59:59.9999999Z"),
      "direction": .string(EventDirection.appToViewer.rawValue),
      "id": .string(maximumUUID),
      "monotonicTimestampNanoseconds": .string(String(UInt64.max)),
      "priority": .string(EventPriority.critical.rawValue),
      "remainingTTLNanoseconds": .string(String(maximumRemainingTTL)),
      "schemaVersion": .integer(Int64(UInt16.max)),
      "sequence": .string(String(UInt64.max)),
      "sessionEpoch": .string(maximumUUID),
      "source": .object([
        "id": .string(maximumEndpointID),
        "role": .string(EndpointRole.app.rawValue),
      ]),
      "target": .object([
        "id": .string(maximumEndpointID),
        "role": .string(EndpointRole.viewer.rawValue),
      ]),
      "ttlMilliseconds": .string(String(eventLimits.maximumTTLMilliseconds)),
      "type": .string(maximumType),
    ])
    let placeholderBytes = try placeholder.deterministicData().count
    let wrapperBytes = try record.deterministicData().count - placeholderBytes
    let (maximum, overflow) = wrapperBytes.addingReportingOverflow(
      eventLimits.maximumEncodedContentBytes
    )
    guard !overflow else {
      throw WireProtocolError(
        code: .arithmeticOverflow,
        path: "maximumEventBytes",
        message: "Maximum Event record size overflowed."
      )
    }
    return maximum
  }

  func jsonValue() throws -> JSONValue {
    guard let createdAt = WireDateCodec.format(envelope.createdAt) else {
      throw WireProtocolError(
        code: .invalidMessage,
        path: "createdAt",
        message: "Event date cannot use the canonical wire representation."
      )
    }
    return .object([
      "causality": .object([
        "correlationID": envelope.causality.correlationID.map {
          .string($0.rawValue)
        } ?? .null,
        "replyTo": envelope.causality.replyTo.map { .string($0.rawValue) } ?? .null,
      ]),
      "content": envelope.content,
      "createdAt": .string(createdAt),
      "direction": .string(envelope.direction.rawValue),
      "id": .string(envelope.id.rawValue),
      "monotonicTimestampNanoseconds": envelope.monotonicTimestampNanoseconds.wireJSONValue,
      "priority": .string(envelope.priority.rawValue),
      "remainingTTLNanoseconds": remainingTTLNanoseconds.wireJSONValue,
      "schemaVersion": .integer(Int64(envelope.schemaVersion.rawValue)),
      "sequence": envelope.sequence.rawValue.wireJSONValue,
      "sessionEpoch": .string(envelope.sessionEpoch.rawValue),
      "source": Self.endpointJSON(envelope.source),
      "target": Self.endpointJSON(envelope.target),
      "ttlMilliseconds": envelope.ttl.milliseconds.wireJSONValue,
      "type": .string(envelope.type.rawValue),
    ])
  }

  init(
    jsonValue: JSONValue,
    eventLimits: EventValidationLimits = .default
  ) throws {
    let object = try WireJSON.object(jsonValue, path: "event")
    let source = try Self.endpoint(
      from: WireJSON.required("source", in: object, path: "event"),
      path: "event.source"
    )
    let target = try Self.endpoint(
      from: WireJSON.required("target", in: object, path: "event"),
      path: "event.target"
    )
    let directionRaw = try WireJSON.string(
      WireJSON.required("direction", in: object, path: "event"),
      path: "event.direction"
    )
    guard let direction = EventDirection(rawValue: directionRaw) else {
      throw WireJSON.invalid("event.direction", "Unknown event direction.")
    }
    let priorityRaw = try WireJSON.string(
      WireJSON.required("priority", in: object, path: "event"),
      path: "event.priority"
    )
    guard let priority = EventPriority(rawValue: priorityRaw) else {
      throw WireJSON.invalid("event.priority", "Unknown event priority.")
    }
    let causalityObject = try WireJSON.object(
      WireJSON.required("causality", in: object, path: "event"),
      path: "event.causality"
    )
    let correlationRaw = try WireJSON.optionalString(
      "correlationID",
      in: causalityObject,
      path: "event.causality"
    )
    let replyRaw = try WireJSON.optionalString(
      "replyTo",
      in: causalityObject,
      path: "event.causality"
    )
    let typeRaw = try WireJSON.string(
      WireJSON.required("type", in: object, path: "event"),
      path: "event.type"
    )
    let typeData = try JSONValue.string(typeRaw).deterministicData()
    let decodedType: EventType
    do {
      decodedType = try JSONDecoder().decode(EventType.self, from: typeData)
    } catch {
      throw WireJSON.invalid("event.type", "Event type is invalid.")
    }
    let createdAtRaw = try WireJSON.string(
      WireJSON.required("createdAt", in: object, path: "event"),
      path: "event.createdAt"
    )
    guard let createdAt = WireDateCodec.parse(createdAtRaw) else {
      throw WireJSON.invalid("event.createdAt", "Expected an ISO-8601 UTC date.")
    }
    let schemaValue = try WireJSON.int64(
      WireJSON.required("schemaVersion", in: object, path: "event"),
      path: "event.schemaVersion"
    )
    guard schemaValue > 0, schemaValue <= Int64(UInt16.max) else {
      throw WireJSON.invalid("event.schemaVersion", "Schema version is out of range.")
    }
    let envelope = try EventEnvelope(
      id: EventID(
        rawValue: WireJSON.string(
          WireJSON.required("id", in: object, path: "event"),
          path: "event.id"
        )
      ),
      type: decodedType,
      content: try WireJSON.required("content", in: object, path: "event"),
      createdAt: createdAt,
      monotonicTimestampNanoseconds: WireJSON.uint64(
        WireJSON.required("monotonicTimestampNanoseconds", in: object, path: "event"),
        path: "event.monotonicTimestampNanoseconds"
      ),
      source: source,
      target: target,
      direction: direction,
      sessionEpoch: SessionEpoch(
        rawValue: WireJSON.string(
          WireJSON.required("sessionEpoch", in: object, path: "event"),
          path: "event.sessionEpoch"
        )
      ),
      sequence: EventSequence(
        WireJSON.uint64(
          WireJSON.required("sequence", in: object, path: "event"),
          path: "event.sequence"
        )
      ),
      priority: priority,
      ttl: EventTTL(
        milliseconds: WireJSON.uint64(
          WireJSON.required("ttlMilliseconds", in: object, path: "event"),
          path: "event.ttlMilliseconds"
        ),
        limits: eventLimits
      ),
      causality: EventCausality(
        correlationID: try correlationRaw.map(EventID.init(rawValue:)),
        replyTo: try replyRaw.map(EventID.init(rawValue:))
      ),
      schemaVersion: try EventSchemaVersion(UInt16(schemaValue)),
      limits: eventLimits
    )
    try self.init(
      envelope: envelope,
      remainingTTLNanoseconds: WireJSON.uint64(
        WireJSON.required("remainingTTLNanoseconds", in: object, path: "event"),
        path: "event.remainingTTLNanoseconds"
      )
    )
  }

  private static func endpointJSON(_ endpoint: EventEndpoint) -> JSONValue {
    .object([
      "id": .string(endpoint.id.rawValue),
      "role": .string(endpoint.role.rawValue),
    ])
  }

  private static func endpoint(from value: JSONValue, path: String) throws -> EventEndpoint {
    let object = try WireJSON.object(value, path: path)
    let roleRaw = try WireJSON.string(
      WireJSON.required("role", in: object, path: path),
      path: "\(path).role"
    )
    guard let role = EndpointRole(rawValue: roleRaw) else {
      throw WireJSON.invalid("\(path).role", "Unknown endpoint role.")
    }
    return EventEndpoint(
      role: role,
      id: try EndpointID(
        rawValue: WireJSON.string(
          WireJSON.required("id", in: object, path: path),
          path: "\(path).id"
        )
      )
    )
  }
}

extension WireEventRecord: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var description: String { "WireEventRecord(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .struct)
  }
}

@_spi(NearWireInternal) public struct WireReceivedEvent: Equatable, Sendable {
  public let envelope: EventEnvelope
  public let receivedAtNanoseconds: UInt64
  public let deadlineNanoseconds: UInt64
  public let deterministicEncodedByteCount: Int

  public func isExpired(nowOnReceiverClockNanoseconds now: UInt64) throws -> Bool {
    guard now >= receivedAtNanoseconds else {
      throw WireProtocolError(
        code: .invalidClock,
        path: "nowOnReceiverClockNanoseconds",
        message: "Receiver clock moved before event receipt."
      )
    }
    return now >= deadlineNanoseconds
  }
}

extension WireReceivedEvent: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var description: String {
    "WireReceivedEvent(redacted, bytes: \(deterministicEncodedByteCount))"
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(
      self,
      children: ["deterministicEncodedByteCount": deterministicEncodedByteCount],
      displayStyle: .struct
    )
  }
}

@_spi(NearWireInternal) public struct WireEventPayload: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.event
  public static let lane = WireLane.event
  public let record: WireEventRecord

  public init(record: WireEventRecord) { self.record = record }
  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    do {
      record = try WireEventRecord(
        jsonValue: body,
        eventLimits: limits.eventValidationLimits
      )
    } catch let error as WireProtocolError {
      throw error
    } catch {
      throw WireJSON.invalid("event", "Event violates the active model limits.")
    }
    try Self.validateSize(record, limits: limits)
  }
  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue {
    try Self.validateSize(record, limits: limits)
    return try record.jsonValue()
  }

  private static func validateSize(
    _ record: WireEventRecord,
    limits: WireProtocolLimits
  ) throws {
    let byteCount = try record.deterministicEncodedByteCount()
    guard byteCount <= limits.maximumEventBytes else {
      throw WireProtocolError(
        code: .frameTooLarge,
        path: "event",
        message: "Wire event exceeds the negotiated event limit."
      )
    }
  }
}

extension WireEventPayload: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var description: String { "WireEventPayload(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: [:], displayStyle: .struct)
  }
}

@_spi(NearWireInternal) public struct WireEventBatchPayload: Equatable, Sendable, WireMessagePayload
{
  public static let messageType = WireMessageType.eventBatch
  public static let lane = WireLane.event
  public let records: [WireEventRecord]

  public init(records: [WireEventRecord], limits: WireProtocolLimits = .default) throws {
    guard (1...limits.maximumBatchEventCount).contains(records.count) else {
      throw WireProtocolError(
        code: .invalidBatch,
        path: "events",
        message: "Event batch count is outside the active limit."
      )
    }
    var encodedRecords: [JSONValue] = []
    encodedRecords.reserveCapacity(records.count)
    var cumulativeBytes = 0
    for record in records {
      let value = try WireEventPayload(record: record).bodyJSON(limits: limits)
      let byteCount = try value.deterministicData().count
      let (nextBytes, overflow) = cumulativeBytes.addingReportingOverflow(byteCount)
      guard !overflow, nextBytes <= limits.frame.maximumEventPayloadBytes else {
        throw WireProtocolError(
          code: .frameTooLarge,
          path: "events",
          message: "Event batch cannot fit the active Event frame limit."
        )
      }
      cumulativeBytes = nextBytes
      encodedRecords.append(value)
    }
    try Self.validateSession(records)
    let messageBytes = try WireMessage(
      version: .v1,
      type: Self.messageType,
      body: .object(["events": .array(encodedRecords)])
    ).deterministicPayloadData()
    guard messageBytes.count <= limits.frame.maximumEventPayloadBytes else {
      throw WireProtocolError(
        code: .frameTooLarge,
        path: "events",
        message: "Event batch cannot fit the active Event frame limit."
      )
    }
    self.records = records
  }

  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    let object = try WireJSON.object(body)
    let values = try WireJSON.array(
      WireJSON.required("events", in: object, path: "body"),
      path: "body.events"
    )
    guard (1...limits.maximumBatchEventCount).contains(values.count) else {
      throw WireProtocolError(
        code: .invalidBatch,
        path: "body.events",
        message: "Event batch count is outside the active limit."
      )
    }
    let decodedRecords: [WireEventRecord]
    do {
      decodedRecords = try values.map {
        try WireEventRecord(
          jsonValue: $0,
          eventLimits: limits.eventValidationLimits
        )
      }
    } catch let error as WireProtocolError {
      throw error
    } catch {
      throw WireJSON.invalid("body.events", "Batch event violates the active model limits.")
    }
    try self.init(
      records: decodedRecords,
      limits: limits
    )
  }

  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue {
    _ = try WireEventBatchPayload(records: records, limits: limits)
    return .object(["events": .array(try records.map { try $0.jsonValue() })])
  }

  private static func validateSession(_ records: [WireEventRecord]) throws {
    guard let first = records.first else { return }
    for (index, record) in records.enumerated() {
      let (expected, overflow) = first.envelope.sequence.rawValue.addingReportingOverflow(
        UInt64(index)
      )
      guard !overflow else {
        throw WireProtocolError(
          code: .arithmeticOverflow,
          path: "events.sequence",
          message: "Batch sequence overflows UInt64."
        )
      }
      guard record.envelope.sessionEpoch == first.envelope.sessionEpoch,
        record.envelope.direction == first.envelope.direction,
        record.envelope.sequence.rawValue == expected
      else {
        throw WireProtocolError(
          code: .invalidBatch,
          path: "events",
          message: "Batch events must be contiguous within one epoch and direction."
        )
      }
    }
  }
}

extension WireEventBatchPayload: CustomReflectable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var description: String { "WireEventBatchPayload(redacted, count: \(records.count))" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: ["count": records.count], displayStyle: .struct)
  }
}

@_spi(NearWireInternal)
public struct WireDropSummaryPayload: Equatable, Sendable, WireMessagePayload {
  public static let messageType = WireMessageType.eventDropSummary
  public static let lane = WireLane.event

  public let overflowDropped: UInt64
  public let expired: UInt64
  public let coalesced: UInt64

  public init(overflowDropped: UInt64, expired: UInt64, coalesced: UInt64) {
    self.overflowDropped = overflowDropped
    self.expired = expired
    self.coalesced = coalesced
  }

  public init(body: JSONValue, limits: WireProtocolLimits) throws {
    let object = try WireJSON.object(body)
    overflowDropped = try WireJSON.uint64(
      WireJSON.required("overflowDropped", in: object, path: "body"),
      path: "body.overflowDropped"
    )
    expired = try WireJSON.uint64(
      WireJSON.required("expired", in: object, path: "body"),
      path: "body.expired"
    )
    coalesced = try WireJSON.uint64(
      WireJSON.required("coalesced", in: object, path: "body"),
      path: "body.coalesced"
    )
  }

  public func bodyJSON(limits: WireProtocolLimits) throws -> JSONValue {
    .object([
      "coalesced": coalesced.wireJSONValue,
      "expired": expired.wireJSONValue,
      "overflowDropped": overflowDropped.wireJSONValue,
    ])
  }
}

enum WireDateCodec {
  static func format(_ date: Date) -> String? {
    let interval = date.timeIntervalSince1970
    guard interval.isFinite else { return nil }
    let formatter = baseFormatter()

    for digits in 3...9 {
      let scale = Self.scale(for: digits)
      var wholeSeconds = floor(interval)
      var fraction = Int(((interval - wholeSeconds) * Double(scale)).rounded())
      if fraction == scale {
        wholeSeconds += 1
        fraction = 0
      }
      let candidate =
        formatter.string(from: Date(timeIntervalSince1970: wholeSeconds))
        + String(format: ".%0*dZ", digits, fraction)
      if parseRaw(candidate, formatter: formatter) == date {
        return candidate
      }
    }
    return nil
  }

  static func parse(_ value: String) -> Date? {
    guard let date = parseRaw(value, formatter: baseFormatter()),
      format(date) == value
    else {
      return nil
    }
    return date
  }

  private static func parseRaw(_ value: String, formatter: DateFormatter) -> Date? {
    let bytes = Array(value.utf8)
    guard (24...30).contains(bytes.count), bytes[19] == 46, bytes.last == 90 else {
      return nil
    }
    let fractionBytes = bytes[20..<(bytes.count - 1)]
    guard (3...9).contains(fractionBytes.count),
      fractionBytes.allSatisfy({ (48...57).contains($0) })
    else {
      return nil
    }
    let prefix = String(decoding: bytes[0..<19], as: UTF8.self)
    guard let base = formatter.date(from: prefix), formatter.string(from: base) == prefix else {
      return nil
    }
    let fraction = fractionBytes.reduce(0) { $0 * 10 + Int($1 - 48) }
    return Date(
      timeIntervalSince1970: base.timeIntervalSince1970
        + Double(fraction) / Double(scale(for: fractionBytes.count))
    )
  }

  private static func baseFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter
  }

  private static func scale(for digits: Int) -> Int {
    (0..<digits).reduce(1) { result, _ in result * 10 }
  }
}
