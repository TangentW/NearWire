## ADDED Requirements

### Requirement: V1 pre-handshake messages use one sealed bootstrap codec

NearWireTransport SHALL provide a repository-only `WirePreHandshakeCodec` fixed to the registered V1 bootstrap envelope. The codec SHALL expose closed encode operations only for hello, safe error, and disconnect and SHALL decode a frame only under the pre-handshake phase with an empty capability set. Successful decode SHALL return only a sealed Sendable `WirePreHandshakeMessage` with typed hello, safe-error, and disconnect cases. It SHALL expose no generic payload extension point, raw message, `WireAdmittedMessage` input or output, arbitrary type token, caller-selected phase, capability set, or wire-envelope version.

Encode SHALL reuse deterministic message and frame encoding after exact phase and lane admission. Decode SHALL preflight the lane before JSON parsing, SHALL apply bounded deterministic JSON, envelope, phase, type, and payload-model decoding, SHALL require envelope V1, and SHALL construct the sealed typed case only after the corresponding payload model succeeds. Every decode failure SHALL be connection-terminal. Event-lane preflight SHALL take precedence over JSON and version inspection. For a Control frame, the raw envelope decoder SHALL parse and validate the nonzero version, then apply an internal V1 expected-version guard before parsing or interpreting the type, required lane, or body. Version zero SHALL retain the version model's `invalidConfiguration` code; a nonzero non-V1 envelope SHALL fail with `incompatibleVersion` even when later fields conflict with V1 rules. The expected version SHALL NOT be caller-selectable through repository SPI.

Before handshake, hello acknowledgement, connection rejection, ping, and pong SHALL fail with `phaseViolation`; flow-policy offer and acceptance SHALL fail with `unsupportedMessageType` because no capability is negotiated; event, event batch, and drop summary SHALL fail with `phaseViolation` at Event-lane preflight before JSON parsing; and a syntactically valid unknown Control type SHALL fail with `unsupportedMessageType`.

The codec SHALL store immutable validated limits only and SHALL retain no frame, payload, hello, identity, pairing code, endpoint, closure, continuation, task, timer, or application content between calls.

#### Scenario: Hello bootstrap round trip

- **WHEN** a valid hello is encoded and decoded before negotiation
- **THEN** the frame uses deterministic V1 control-lane bytes
- **AND** the typed decoded hello equals the input

#### Scenario: Event lane before handshake

- **WHEN** an Event-lane frame is supplied before handshake, including one with malformed JSON
- **THEN** decode fails terminally with phase violation at lane preflight before payload parsing

#### Scenario: Control envelope version has deterministic precedence

- **WHEN** a Control-lane frame contains version zero
- **THEN** decode fails terminally with invalid configuration
- **WHEN** a Control-lane frame contains a nonzero non-V1 version and later fields that conflict with V1 type, lane, or body rules
- **THEN** decode fails terminally with incompatible version before those later fields are interpreted

#### Scenario: Message is not admitted before handshake

- **WHEN** an acknowledgement, rejection, flow-policy offer or acceptance, ping, pong, Event, Event batch, or drop-summary message is supplied to the pre-handshake codec
- **THEN** decode fails terminally with the specified phase-or-capability precedence without returning a typed value

#### Scenario: Allowed type has an invalid body

- **WHEN** a canonical hello, safe-error, or disconnect envelope contains a malformed or over-limit body
- **THEN** frame decode fails terminally before constructing the sealed typed case
