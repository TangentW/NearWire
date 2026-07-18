## MODIFIED Requirements

### Requirement: Pairing code has one canonical grammar

Core SHALL represent a pairing code behind repository-only SPI as exactly four bytes from
`ABCDEFGHJKMNPQRSTUVWXYZ23456789`. Raw input SHALL be limited to 64 UTF-8 bytes before
normalization; validation SHALL inspect no more than the first 65 bytes, allocate at most the four
canonical bytes, and return one fixed non-echoing error on overflow. Input normalization SHALL
remove only ASCII hyphen and ASCII whitespace, SHALL uppercase ASCII letters without
locale-sensitive conversion, and SHALL reject every other byte or Unicode scalar. The value SHALL
be Sendable and memory-only and SHALL NOT expose persistence or supported public Codable behavior.
Its description, debug description, interpolation, describing string, and reflecting string SHALL
be redacted.

#### Scenario: Human-formatted input

- **WHEN** input is `7k-3m` with optional ASCII spaces
- **THEN** normalization produces canonical `7K3M`

#### Scenario: Lookalike or invalid input

- **WHEN** input contains `0`, `O`, `1`, `I`, `L`, a Unicode lookalike, non-ASCII whitespace,
  punctuation, or a non-four-character result
- **THEN** validation fails with a stable safe error
- **AND** the error does not echo the input

#### Scenario: Separator-heavy input is bounded

- **WHEN** raw input contains more than 64 UTF-8 bytes of otherwise removable separators
- **THEN** validation examines at most 65 bytes and fails with the fixed safe error
- **AND** normalization does not allocate storage proportional to the raw input

### Requirement: Pairing code derives one exact Bonjour instance

The SDK SHALL derive the instance name `NearWire-<CANONICAL_CODE>` and the fixed service type
`_nearwire._tcp`. Discovery matching SHALL compare against that exact instance name and SHALL NOT
accept a prefix, suffix, case variant, conflict-renamed service, or arbitrary service of the same
type.

#### Scenario: Exact service name

- **WHEN** the canonical code is `7K3M`
- **THEN** the expected instance name is exactly `NearWire-7K3M`

#### Scenario: Bonjour conflict suffix

- **WHEN** a result is named `NearWire-7K3M (2)`
- **THEN** it is not a match for `7K3M`
