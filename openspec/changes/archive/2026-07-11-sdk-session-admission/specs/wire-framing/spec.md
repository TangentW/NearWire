## MODIFIED Requirements

### Requirement: Bounded incremental stream decoding

The frame decoder SHALL accept arbitrary prefix and payload fragmentation plus multiple coalesced frames. It SHALL deliver frames through a caller callback without accumulating an unbounded output array and SHALL retain at most one bounded partial frame. Any malformed frame SHALL put that decoder in a terminal failed state.

Decode SHALL additionally accept an allow-all-by-default synchronous lane-preflight operation. For each frame, preflight SHALL execute exactly once after the prefix, lane byte, and lane-specific declared-payload bound have validated but before payload storage reservation or payload-byte copy. The decoder SHALL NOT retain the operation. A preflight `WireProtocolError` SHALL become the terminal connection error; any other thrown value SHALL become a fixed safe terminal decoder error. Failure SHALL retain no bytes from the rejected payload and SHALL NOT attempt stream resynchronization.

#### Scenario: Byte-at-a-time fragmentation

- **WHEN** a valid frame is supplied one byte at a time
- **THEN** lane preflight runs once after the lane byte
- **AND** no frame is delivered early
- **AND** exactly one frame is delivered after the final byte

#### Scenario: Coalesced frames

- **WHEN** several complete frames arrive in one input chunk
- **THEN** each lane is preflighted and each frame is delivered once in stream order

#### Scenario: Input after terminal failure

- **WHEN** a decoder has rejected a malformed frame or lane preflight
- **THEN** later input fails without attempting resynchronization

#### Scenario: Lane preflight rejects before payload

- **WHEN** preflight rejects a known lane whose declared payload is within its lane limit
- **THEN** no payload storage is reserved or copied
- **AND** the preflight operation receives no payload bytes
