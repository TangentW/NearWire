## MODIFIED Requirements

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
