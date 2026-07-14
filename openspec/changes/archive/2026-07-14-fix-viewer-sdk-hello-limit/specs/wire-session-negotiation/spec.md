## ADDED Requirements

### Requirement: Peer Hello size offers are decoded before local size selection

A pre-handshake Hello `maximumEventBytes` value SHALL be treated as a peer offer and SHALL be
positive and no greater than the existing 16 MiB wire hard bound. Decoding a Hello SHALL NOT reject
an otherwise valid offer merely because it exceeds the decoder's local active-session Event limit.
The offer SHALL remain scalar metadata and SHALL NOT allocate, reserve, or widen Event, frame,
transport, queue, or storage capacity.

After both Hellos decode, negotiation SHALL continue selecting the smaller offer. A negotiated
session codec SHALL still reject a selected value that exceeds its supplied local Event or frame
limits.

#### Scenario: Larger peer offer negotiates down

- **WHEN** a peer Hello advertises a valid Event-record offer above the decoder's local 256 KiB
  active-session limit but within the 16 MiB hard bound
- **THEN** the pre-handshake codec decodes the Hello
- **AND** negotiation with a local 256 KiB offer selects 256 KiB
- **AND** no Event-sized allocation or capacity widening occurs from decoding the peer offer

#### Scenario: Offer exceeds the hard bound

- **WHEN** a peer Hello advertises an Event limit greater than 16 MiB
- **THEN** pre-handshake decoding fails before negotiation

#### Scenario: Session codec still enforces the local limit

- **WHEN** a negotiation result exceeds the local session codec's Event or frame limit
- **THEN** session codec construction fails without widening the local limit
