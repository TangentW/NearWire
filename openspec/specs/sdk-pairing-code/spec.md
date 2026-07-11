# sdk-pairing-code Specification

## Purpose
TBD - created by archiving change sdk-pairing-discovery. Update Purpose after archive.
## Requirements
### Requirement: Pairing code has one canonical grammar

Core SHALL represent a pairing code behind repository-only SPI as exactly six bytes from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`. Raw input SHALL be limited to 64 UTF-8 bytes before normalization; validation SHALL inspect no more than the first 65 bytes, allocate at most the six canonical bytes, and return one fixed non-echoing error on overflow. Input normalization SHALL remove only ASCII hyphen and ASCII whitespace, SHALL uppercase ASCII letters without locale-sensitive conversion, and SHALL reject every other byte or Unicode scalar. The value SHALL be Sendable and memory-only and SHALL NOT expose persistence or supported public Codable behavior. Its description, debug description, interpolation, describing string, and reflecting string SHALL be redacted.

#### Scenario: Human-formatted input

- **WHEN** input is `7k3m-9q` with optional ASCII spaces
- **THEN** normalization produces canonical `7K3M9Q`

#### Scenario: Lookalike or invalid input

- **WHEN** input contains `0`, `O`, `1`, `I`, `L`, a Unicode lookalike, non-ASCII whitespace, punctuation, or a non-six-character result
- **THEN** validation fails with a stable safe error
- **AND** the error does not echo the input

#### Scenario: Separator-heavy input is bounded

- **WHEN** raw input contains more than 64 UTF-8 bytes of otherwise removable separators
- **THEN** validation examines at most 65 bytes and fails with the fixed safe error
- **AND** normalization does not allocate storage proportional to the raw input

### Requirement: Pairing code derives one exact Bonjour instance

The SDK SHALL derive the instance name `NearWire-<CANONICAL_CODE>` and the fixed service type `_nearwire._tcp`. Discovery matching SHALL compare against that exact instance name and SHALL NOT accept a prefix, suffix, case variant, conflict-renamed service, or arbitrary service of the same type.

#### Scenario: Exact service name

- **WHEN** the canonical code is `7K3M9Q`
- **THEN** the expected instance name is exactly `NearWire-7K3M9Q`

#### Scenario: Bonjour conflict suffix

- **WHEN** a result is named `NearWire-7K3M9Q (2)`
- **THEN** it is not a match for `7K3M9Q`

### Requirement: Pairing code is not a secret or identity credential

The SDK SHALL use the pairing code only to select a nearby Bonjour service. It SHALL NOT derive encryption keys, authenticate the Viewer, persist the code, place it in errors or logs, or treat a match as certificate identity proof.

#### Scenario: Discovery diagnostic

- **WHEN** discovery fails for a supplied code
- **THEN** the diagnostic identifies the failure category without containing the canonical code

### Requirement: Viewer discovery discriminator has one shared derivation

Core SHALL derive `ViewerDiscoveryDiscriminator` with `CryptoKit.SHA256` over the exact validated `EndpointID.rawValue` UTF-8 bytes, without case folding or normalization, then encode the first eight digest bytes as exactly 16 lowercase hexadecimal ASCII characters. It SHALL NOT use a custom cryptographic implementation. Equal installation-ID input SHALL produce the same value. A reset installation identity SHALL recompute the value, but a distinct input is not guaranteed to avoid collision in the truncated 64-bit output. The discriminator SHALL be treated as public locally linkable metadata rather than authentication, secrecy, or certificate binding.

#### Scenario: Golden discriminator vectors

- **WHEN** installation ID `viewer-installation` is derived
- **THEN** the discriminator is `b3a97f874aad08bf`
- **AND** installation ID `00000000-0000-0000-0000-000000000001` derives `7ac1b8d7010bb6cd`

#### Scenario: Input bytes differ

- **WHEN** two valid installation IDs differ by case or any ASCII byte
- **THEN** derivation hashes their exact respective bytes without normalization

#### Scenario: Pairing code refreshes

- **WHEN** one Viewer installation keeps its installation ID and refreshes only its pairing code
- **THEN** `vid` remains stable and can be locally correlated across the two advertisements
