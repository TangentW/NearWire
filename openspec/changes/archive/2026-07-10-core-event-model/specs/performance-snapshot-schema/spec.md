## ADDED Requirements

### Requirement: Reserved versioned performance snapshot

Core SHALL define `nearwire.performance.snapshot` as the exact reserved event type for a V1 aggregate performance snapshot. Snapshot content SHALL include schema version 1, sample wall time, positive sample interval milliseconds, and optional process, display, device, transport, and unavailability groups.

#### Scenario: Valid snapshot content

- **WHEN** a V1 snapshot with one or more supported metric groups is encoded as event content
- **THEN** it round trips through the default JSON content codec
- **AND** its event type is constructible only through the platform namespace path

#### Scenario: Invalid snapshot header

- **WHEN** schema version is not 1 or sample interval is zero
- **THEN** snapshot validation fails

### Requirement: Explicit metric units and ranges

Performance metric field names and documentation SHALL encode their units. CPU percent SHALL be finite and non-negative; byte and count fields SHALL be unsigned; battery level SHALL be a finite fraction from 0 through 1; estimated and maximum frames per second SHALL be finite and positive when present.

#### Scenario: Metric boundaries accepted

- **WHEN** battery level is 0 or 1, CPU percent is 0 or greater, and positive frame-rate and unsigned counter values are supplied
- **THEN** the values are accepted and preserved exactly within their numeric representation

#### Scenario: Invalid metric rejected

- **WHEN** a metric is negative where prohibited, non-finite, battery level is outside 0 through 1, or a present frame rate is zero
- **THEN** snapshot validation fails with the metric path identified

### Requirement: Missing and unavailable are distinct from zero

Optional metric fields SHALL use absence to mean not collected or unavailable and SHALL preserve zero only as a real measured value. The schema SHALL support explicit unavailable-metric records with a stable metric key and a reason of unsupported, disabled, permission denied, or temporarily unavailable.

#### Scenario: Missing metric

- **WHEN** a snapshot omits process CPU percent
- **THEN** decoding represents it as absent
- **AND** it is not converted to zero

#### Scenario: Explicit unavailable metric

- **WHEN** GPU utilization cannot be obtained through an approved public interface
- **THEN** the snapshot may record the GPU metric key as unsupported
- **AND** it contains no fabricated numeric GPU value

#### Scenario: Real zero metric

- **WHEN** a collected counter or CPU value is measured as zero
- **THEN** zero is encoded and decoded as a present measurement

### Requirement: Conservative public-metric boundary

The V1 snapshot SHALL NOT define numeric whole-device GPU utilization, power watts, or Celsius temperature fields. Thermal state SHALL be categorical, display FPS SHALL be described as an estimate, and all process or device values SHALL remain compatible with later collection through approved public interfaces.

#### Scenario: Thermal state representation

- **WHEN** device thermal state is encoded
- **THEN** it uses nominal, fair, serious, critical, or unknown
- **AND** no temperature in Celsius is implied

#### Scenario: Frame-rate representation

- **WHEN** display metrics contain estimated frames per second
- **THEN** the field remains explicitly estimated
- **AND** it is not labeled as GPU utilization

### Requirement: Forward-compatible performance content

V1 performance decoders SHALL ignore unknown fields, SHALL map unknown battery or thermal state strings to `unknown`, and SHALL continue requiring all V1 header fields. The raw enclosing event content SHALL remain available to later SDK and Viewer layers even when typed decoding ignores an unknown field.

#### Scenario: Future optional metric

- **WHEN** snapshot JSON includes an unknown optional metric field
- **THEN** V1 typed decoding succeeds for known fields
- **AND** event-level raw JSON can still retain the unknown field

#### Scenario: Future enum value

- **WHEN** battery or thermal state contains an unknown string
- **THEN** typed decoding produces `unknown` rather than failing the whole snapshot

### Requirement: Schema has no collection side effects

The performance snapshot capability SHALL contain only platform-neutral values and validation. Creating, encoding, or decoding a snapshot SHALL NOT start timers, display links, battery monitoring, notifications, network transmission, or any other collector side effect.

#### Scenario: Schema-only use

- **WHEN** a test constructs and round trips a performance snapshot in NearWireCore
- **THEN** no UIKit, AppKit, SwiftUI, CADisplayLink, UIDevice, or network dependency is required
