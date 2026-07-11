# wire-framing Specification

## Purpose
TBD - created by archiving change core-wire-protocol. Update Purpose after archive.
## Requirements
### Requirement: Deterministic length-prefixed frames

V1 SHALL encode each message as a four-byte unsigned big-endian length, one lane byte, and a nonempty deterministic UTF-8 JSON payload. The length SHALL count lane plus payload and SHALL exclude the prefix. Control SHALL use lane `0x01`, Event SHALL use lane `0x02`, and no other lane SHALL be accepted.

#### Scenario: Frame round trip

- **WHEN** a valid Control or Event payload is framed and decoded
- **THEN** the original lane and exact payload bytes are emitted once

#### Scenario: Invalid declared length

- **WHEN** a prefix declares fewer than two bytes or a value above the hard frame limit
- **THEN** decoding fails before an unbounded payload allocation

#### Scenario: Unknown lane

- **WHEN** the first framed byte is neither the Control nor Event tag
- **THEN** decoding fails with a typed lane error

### Requirement: Independent bounded lane sizes

Frame limits SHALL default to 64 KiB for Control and 1 MiB for Event, SHALL be positive and coherent, and SHALL have a 16 MiB hard ceiling. After reading the lane byte, decoding SHALL reject a declared payload above that lane's configured limit before buffering the remaining payload.

#### Scenario: Oversized Control frame

- **WHEN** a frame uses the Control lane and declares more than the Control payload limit
- **THEN** it is rejected even if it is below the Event limit

#### Scenario: Boundary payload

- **WHEN** a payload exactly equals its lane limit
- **THEN** framing and decoding succeed

### Requirement: Bounded incremental stream decoding

The frame decoder SHALL accept arbitrary prefix and payload fragmentation plus multiple coalesced frames. It SHALL deliver frames through a caller callback without accumulating an unbounded output array and SHALL retain at most one bounded partial frame. Any malformed frame SHALL put that decoder in a terminal failed state.

#### Scenario: Byte-at-a-time fragmentation

- **WHEN** a valid frame is supplied one byte at a time
- **THEN** no frame is delivered early
- **AND** exactly one frame is delivered after the final byte

#### Scenario: Coalesced frames

- **WHEN** several complete frames arrive in one input chunk
- **THEN** each frame is delivered in stream order

#### Scenario: Input after terminal failure

- **WHEN** a decoder has rejected a malformed frame
- **THEN** later input fails without attempting resynchronization

### Requirement: Framing has no transport side effects

The frame codec SHALL start no task, timer, thread, socket, network operation, TLS operation, disk write, or UI work. It SHALL NOT expose a plaintext fallback or claim encryption.

#### Scenario: In-memory framing

- **WHEN** frames are encoded and decoded in Core tests
- **THEN** behavior depends only on supplied bytes and limits
