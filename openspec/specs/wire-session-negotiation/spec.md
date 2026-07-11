# wire-session-negotiation Specification

## Purpose
TBD - created by archiving change core-wire-protocol. Update Purpose after archive.
## Requirements
### Requirement: Independent protocol interval negotiation

A hello SHALL advertise nonzero minimum and maximum supported wire versions with minimum no greater than maximum. Before a negotiation result exists, each peer SHALL carry its initial hello in the fixed registered V1 bootstrap envelope through `WirePreHandshakeCodec`; the advertised interval MAY include future versions but SHALL NOT change that bootstrap envelope. Negotiation SHALL choose the highest version in the overlap. Product version strings SHALL be diagnostic only and SHALL NOT determine compatibility.

Starting a session SHALL additionally require a registered negotiated-session codec for the selected version. V1 implementations SHALL NOT emit V1 schemas under an unimplemented future negotiated envelope label. Adding a future bootstrap envelope SHALL require an explicit bootstrap codec registry and compatibility design.

#### Scenario: Overlapping intervals

- **WHEN** one peer supports 1 through 2 and the other supports 1 through 3
- **THEN** each initial hello is carried by the V1 bootstrap envelope
- **AND** interval negotiation selects wire version 2
- **AND** session activation still fails unless a version-2 session codec is registered

#### Scenario: No overlap

- **WHEN** supported intervals do not overlap
- **THEN** negotiation fails before an active event session

### Requirement: Codec, role, policy, size, and capability negotiation

V1 SHALL require a common `json` codec, opposite App and Viewer roles, normal send-policy support, and positive bounded maximum event bytes. Effective event bytes SHALL be the smaller advertised limit. Effective capabilities and send policies SHALL be exact intersections. Unknown capability tokens SHALL be retained but SHALL NOT activate known behavior implicitly.

#### Scenario: Conservative event limit

- **WHEN** App advertises 256 KiB and Viewer advertises 1 MiB
- **THEN** effective event bytes are 256 KiB

#### Scenario: Same roles

- **WHEN** both hello payloads claim App or both claim Viewer
- **THEN** negotiation fails with a typed role error

#### Scenario: No JSON codec

- **WHEN** peers have no common JSON codec
- **THEN** negotiation fails before acknowledgement

### Requirement: Session acknowledgement binds the negotiated result

Hello acknowledgement SHALL contain the selected wire version, codec, effective event limit, effective capabilities, effective policies, the installation ID retained from the Viewer hello, and a newly supplied session epoch. Acknowledgement values SHALL exactly match the negotiated result.

#### Scenario: Valid acknowledgement

- **WHEN** Viewer acknowledges exactly the negotiated result and a valid new epoch
- **THEN** Core validation accepts it for policy negotiation

#### Scenario: Capability escalation

- **WHEN** acknowledgement claims a capability absent from either hello
- **THEN** validation fails before active state

#### Scenario: Viewer identity substitution

- **WHEN** acknowledgement contains a Viewer installation ID different from the Viewer hello
- **THEN** validation fails before active state

### Requirement: Directional session sequence

A sequence counter SHALL belong to one session epoch and one event direction, SHALL allocate monotonically from zero after flow-control selection, and SHALL fail on `UInt64` exhaustion. A validator SHALL require the expected epoch, direction, and exact next value. It SHALL reject duplicate, gap, wrong-direction, and wrong-epoch events without adding ACK or retry semantics.

#### Scenario: Contiguous sequence

- **WHEN** events 0, 1, and 2 arrive for the expected epoch and direction
- **THEN** each is accepted in order

#### Scenario: Duplicate or gap

- **WHEN** the next expected value is 4 and the received value is 3 or 5
- **THEN** validation fails with a typed sequence error

#### Scenario: Reconnect epoch

- **WHEN** a new connection uses a new session epoch
- **THEN** a new validator can begin again at sequence zero
- **AND** an event from the old epoch is rejected
