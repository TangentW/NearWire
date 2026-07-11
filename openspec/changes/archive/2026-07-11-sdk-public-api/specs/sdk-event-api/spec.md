## ADDED Requirements

### Requirement: Public event signatures are NearWire-owned

The SDK SHALL expose event content, events, priorities, directions, delivery policies, options, results, diagnostics, state, configuration, and errors using Foundation or NearWire-module types only. No supported public signature SHALL name a Core, flow-control, transport, Network.framework, Security.framework, or Viewer-only type.

#### Scenario: SwiftPM consumer imports the SDK

- **WHEN** an iOS consumer imports only `NearWire`
- **THEN** it can construct configuration, send content, inspect events, decode content, reply, observe state/events, inspect diagnostics, and shut down without importing an implementation module

#### Scenario: CocoaPods consumer imports the SDK

- **WHEN** the same consumer source is compiled through the NearWire pod
- **THEN** the supported source-level API and behavior compile without conditional consumer code

### Requirement: Codable content conversion is deterministic and safe

The SDK SHALL accept generic Encodable and Sendable content, SHALL expose received content as an inspectable JSON-shaped value, and SHALL decode it into a requested Decodable type. Dates SHALL use ISO-8601 UTC text, Data SHALL use Base64, non-finite numbers SHALL fail, and validation SHALL enforce the configured content bounds.

Encoding and decoding failures SHALL map to stable NearWire error codes without including arbitrary underlying error descriptions.

#### Scenario: Typed round trip

- **WHEN** a Codable value containing a date, data, arrays, and nested objects is encoded and decoded
- **THEN** its supported JSON representation and reconstructed value are deterministic

#### Scenario: Application encoder exposes a sensitive error

- **WHEN** application content throws an error whose description contains private data
- **THEN** the public NearWire error contains a fixed safe message and no private description

### Requirement: Send options express local queue intent

The SDK SHALL support normal admission and keep-latest admission with an explicit validated key plus priority and TTL options. A send result SHALL report the stable event UUID, local enqueue date, whether the event remains locally buffered, and exact coalesced, expired, and overflow-dropped IDs. It SHALL NOT claim transmission, receipt, acknowledgement, persistence, or delivery.

#### Scenario: Normal sends share a type

- **WHEN** two normal events use the same event type
- **THEN** both remain distinct pending events when capacity permits

#### Scenario: Keep-latest sends share a key

- **WHEN** a second keep-latest event uses the first event's key
- **THEN** the first pending event is replaced and its ID is reported as coalesced

### Requirement: Replies preserve causal identity

The SDK SHALL allow a caller to reply to an incoming event with Codable content. The reply SHALL receive a new stable event ID, SHALL carry the source event ID as both its correlation and reply-to identity, and SHALL retain hidden origin-instance, Viewer, and session-epoch affinity. An event from another NearWire instance SHALL be rejected. A pending reply SHALL be dropped rather than admitted to a different Viewer or session route.

#### Scenario: Application replies to Viewer control

- **WHEN** application code replies to a received Viewer-to-App event
- **THEN** the queued reply identifies the source event without copying session or transport implementation values into the public API

#### Scenario: Viewer route changes before reply transmission

- **WHEN** a pending reply reaches drain under a different Viewer identity or session epoch
- **THEN** it is reported as routing-dropped and is never offered to transport

#### Scenario: Stale reply exceeds the active transport batch budget

- **WHEN** a route-mismatched reply is larger than the current transport batch byte budget
- **THEN** route preflight still drops it without consuming transport bytes
- **AND** later eligible work is not blocked by that stale reply
