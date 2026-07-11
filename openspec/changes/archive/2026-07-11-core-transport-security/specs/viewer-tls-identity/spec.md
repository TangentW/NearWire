## ADDED Requirements

### Requirement: Viewer identity is caller owned

Core SHALL adapt a caller-supplied Security identity for Viewer TLS and SHALL NOT generate, export, persist, rotate, log, or otherwise manage its private key or certificate lifecycle.

#### Scenario: Valid identity adaptation

- **WHEN** a valid `SecIdentity` is supplied
- **THEN** Viewer TLS parameters receive the corresponding protocol identity

#### Scenario: Adaptation failure

- **WHEN** Security cannot adapt the supplied identity
- **THEN** construction fails without starting a listener or exposing private material

### Requirement: App trust is connection-local leaf anchoring

The App trust evaluator SHALL require a presented certificate, SHALL evaluate it under Basic X.509 policy with the presented leaf as the only connection-local anchor, and SHALL accept only a successful Security evaluation. It SHALL NOT use an unconditional trust callback or persist trust state.

#### Scenario: Valid self-signed Viewer leaf

- **WHEN** Security successfully evaluates the presented Viewer leaf as its connection-local anchor
- **THEN** TLS verification completes successfully for that connection

#### Scenario: Missing or invalid leaf

- **WHEN** no certificate is present or Security evaluation fails
- **THEN** TLS verification fails closed

### Requirement: Security guarantee is documented accurately

Documentation SHALL state that mandatory TLS plus connection-local anchoring protects confidentiality from passive observers but does not provide strong pre-established Viewer authentication against an active local attacker. Pairing codes SHALL NOT be described as certificate secrets.

#### Scenario: Security documentation review

- **WHEN** an integrator reads the transport security contract
- **THEN** encryption, authentication limitations, switching behavior, and later strengthening options are distinguishable
