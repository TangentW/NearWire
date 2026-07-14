## ADDED Requirements

### Requirement: Viewer admission accepts the production SDK Event-size offer

Viewer admission SHALL decode an otherwise valid App Hello that advertises the exact maximum
deterministic Event-record size calculated by the production SDK, even when that offer is slightly
larger than Viewer's local 256 KiB Event limit. Viewer SHALL negotiate the effective value down to
its own advertised limit, retain existing bounded admission ownership, and continue to the normal
automatic or approval handoff. It SHALL NOT allocate an offered-size Event buffer during Hello
decoding.

#### Scenario: Production SDK Hello reaches handoff

- **WHEN** Bonjour, TCP, and TLS succeed and App sends a valid production Hello whose Event-record
  offer includes the envelope above 256 KiB
- **THEN** Viewer decodes and negotiates the Hello instead of cancelling the secure connection
- **AND** the effective Event limit equals the smaller Viewer offer
- **AND** the attempt reaches its configured automatic or approval handoff
