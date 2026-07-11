# secure-network-parameters Specification

## Purpose
TBD - created by archiving change core-transport-security. Update Purpose after archive.
## Requirements
### Requirement: Supported transport is always encrypted

The supported transport factory SHALL create ordered Network.framework TCP parameters with mandatory TLS, SHALL expose no plaintext or TLS-disable option, and SHALL fail construction rather than downgrade when secure configuration is unavailable.

#### Scenario: App parameters

- **WHEN** App client parameters are created
- **THEN** TCP and TLS are both present
- **AND** no plaintext alternative is returned

#### Scenario: Missing Viewer identity

- **WHEN** Viewer server parameters are requested without a valid identity
- **THEN** construction fails before a listener or connection starts

### Requirement: V1 TLS policy is fixed and inspectable

V1 SHALL require TLS 1.3 as both minimum and maximum, SHALL advertise only the `nearwire/1` ALPN token, and SHALL enable Network.framework peer-to-peer routing for App and Viewer parameters.

#### Scenario: Policy plan

- **WHEN** either role constructs its TLS plan
- **THEN** TLS bounds, ALPN, ordered transport, and peer-to-peer routing equal the V1 constants

#### Scenario: Unsupported override

- **WHEN** a caller attempts to request plaintext, another ALPN, or a weaker TLS version
- **THEN** no supported configuration API can express that override

### Requirement: Transport configuration is bounded and coherent

Receive chunk bytes, pending send count, pending send bytes, and relevant timeout values SHALL have documented defaults and hard ceilings. Invalid or internally incoherent values SHALL fail before any network object starts.

#### Scenario: Invalid queue bound

- **WHEN** pending bytes cannot hold one maximum send or a bound is zero or above its hard ceiling
- **THEN** configuration fails with a typed local error

### Requirement: Both roles have mandatory-secure integration entry points

The App entry point SHALL create a channel only from fixed App TLS parameters. The Viewer entry point SHALL require a valid identity before creating a listener, SHALL hide the raw listener, and SHALL expose each accepted connection through a one-shot bounded channel wrapper. Listener cancellation SHALL close admission for racing incoming wrappers.

#### Scenario: Viewer listener construction

- **WHEN** a valid Viewer identity is supplied
- **THEN** a peer-to-peer-enabled mandatory-TLS listener can be created without exposing an identity-free overload

#### Scenario: Incoming connection claim

- **WHEN** Viewer code claims an accepted secure connection
- **THEN** exactly one bounded secure byte channel can be created from it
