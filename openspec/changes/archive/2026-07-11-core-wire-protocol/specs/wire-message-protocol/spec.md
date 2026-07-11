## ADDED Requirements

### Requirement: Versioned deterministic message envelope

Every frame payload SHALL be a deterministic UTF-8 JSON object with required `version`, `type`, and `body` fields. The wire version SHALL be nonzero and independent of product and event-schema versions. Message type SHALL use 1 through 64 UTF-8 bytes of lowercase dot-separated ASCII segments. Unknown object fields SHALL be ignored while required known fields remain mandatory.

Decode SHALL require deterministic re-encoding to equal the original bytes, rejecting duplicate or escaped-equivalent keys, whitespace, alternate key order, and alternate numeric spellings.

#### Scenario: Deterministic message bytes

- **WHEN** the same valid message is encoded repeatedly
- **THEN** its JSON bytes and complete framed bytes are identical

#### Scenario: Missing required field

- **WHEN** version, type, or body is absent
- **THEN** decode fails with a typed path

#### Scenario: Unknown field

- **WHEN** a valid V1 message contains an additional object field
- **THEN** the known message remains decodable

#### Scenario: Duplicate required key

- **WHEN** a payload repeats a required key directly or through an escaped-equivalent spelling
- **THEN** decode fails before message dispatch

### Requirement: Lane and type agree

Known V1 Control types SHALL be `hello`, `hello.acknowledged`, `connection.rejected`, `flow.policy.offer`, `flow.policy.accepted`, `ping`, `pong`, `disconnect`, and `error`. Known V1 Event types SHALL be `event`, `event.batch`, and `event.drop-summary`. A known type SHALL appear only on its required lane.

#### Scenario: Event type on Control lane

- **WHEN** an `event` message is framed as Control
- **THEN** decode fails before event dispatch

#### Scenario: Unknown type

- **WHEN** a syntactically valid future type is received
- **THEN** its raw type and body remain available
- **AND** phase admission does not implicitly authorize it

### Requirement: Handshake-phase admission

Core SHALL define pure admission rules for pre-handshake, awaiting approval, policy negotiation, active, and closing phases. Event-lane messages SHALL NOT be admissible before active state. Pre-active Control messages SHALL be limited to the documented handshake, rejection, error, ping/pong where allowed, and disconnect set.

After negotiation, a session codec SHALL require a registered implementation for the selected version and every envelope version to equal it. It SHALL NOT widen the supplied local event limit. Event-lane phase and baseline-capability admission SHALL occur before JSON parsing. Event, batch, drop-summary, and flow-policy messages SHALL require their corresponding negotiated capabilities. Typed session decode SHALL accept only a message value produced by successful frame, phase, lane, version, and capability admission. The payload conformance and raw codec SHALL remain internal, and public session encode/decode SHALL be closed to the documented V1 payload types.

#### Scenario: Event before active session

- **WHEN** a valid Event-lane message is evaluated before active state
- **THEN** admission fails with a typed phase error

#### Scenario: Active event

- **WHEN** a known Event message is evaluated in active state
- **THEN** phase admission succeeds

### Requirement: Typed bounded V1 control payloads

V1 SHALL provide validated typed payloads for hello, hello acknowledgement, connection rejection, flow-policy offer and acceptance, ping, pong, disconnect, and protocol error. Strings, arrays, metadata, rate values, and error text SHALL have explicit bounds. Error payloads SHALL carry a stable code, bounded message, fatal flag, and optional related message type without automatically serializing underlying errors.

#### Scenario: Protocol error payload

- **WHEN** a component constructs an error message from a stable code and safe text
- **THEN** it round-trips without private error details or executable content

#### Scenario: Oversized control text

- **WHEN** a rejection, disconnect, or error message exceeds its bound
- **THEN** construction fails before framing

### Requirement: Golden V1 compatibility fixtures

The repository SHALL contain canonical V1 hello, error, event, and event-batch JSON/framed fixtures. Tests SHALL compare current encoding with fixed golden bytes and SHALL decode the same fixtures. Intentional byte changes SHALL require an explicit fixture and compatibility review.

#### Scenario: Golden fixture verification

- **WHEN** the protocol test suite runs
- **THEN** every canonical fixture encodes and decodes exactly
- **AND** accidental field, ordering, lane, prefix, date, or numeric-format drift fails a test
