## MODIFIED Requirements

### Requirement: Public connect is one explicit instance operation

The SDK SHALL expose `public func connect(code: String) async throws` on the `NearWire` actor. Construction and every existing Event, buffer, stream, state, disconnect, suspend, and resume operation without active intent SHALL NOT start connection work. One successful explicit call SHALL validate, install one actor-owned pending intent capsule, reserve one exact instance attempt and cleanup receipt, claim the process lease, construct one App hello, explicitly run one admission and active pump, install one connected owner, promote the same intent, publish connected, and return in the same actor turn. Success SHALL mean only TLS transport and initial flow-policy activation.

Preflight precedence SHALL be shutdown, pre-latched Task cancellation, suspension, same-instance initial/recovery attempt or unresolved cleanup, active route, retained active intent, pairing validation, limit and SDK-version validation, exact intent/slot/receipt reservation, then lease claim. Results SHALL be shutdown, connectionCancelled, connectionSuspended, connectionInProgress, alreadyConnected, connectionIntentExists, invalidPairingCode, invalidConfiguration, or mapped lease error respectively. Failures before discovering SHALL preserve idle or prior disconnected state and clear pending intent after cleanup. Ownership state SHALL win before validation of a new code; valid input SHALL win over cross-instance contention. This operation SHALL expose no pairing getter, effective rate, Viewer identity, endpoint, certificate, lease, or pump API.

For a pending call, token-current shutdown before actor connected commit SHALL override Task cancellation and lower-layer results and return the existing shutdown error. Token-current explicit disconnect or suspension before actor connected commit SHALL return connectionCancelled. Connected commit, intent installation, and success return SHALL be indivisible with respect to later actor work.

#### Scenario: Explicit connection succeeds

- **WHEN** the exact Viewer admits and activates one valid request
- **THEN** connect returns after connected owner, pending-to-active intent promotion, and state commit
- **AND** eligible Events may transfer through the existing pump

#### Scenario: Overlapping preflight conditions exist

- **WHEN** multiple rejection conditions are true
- **THEN** the fixed order selects one result and starts no lower-precedence work

#### Scenario: Shutdown wins a pending attempt

- **WHEN** shutdown latches before actor connected commit
- **THEN** the pending call returns shutdown, final state is shutdown, and connected is never published

#### Scenario: Disconnect wins a pending attempt

- **WHEN** explicit disconnect or suspension latches before actor connected commit
- **THEN** the pending call returns connectionCancelled and lifecycle recovery does not start

### Requirement: Pairing-code retention is minimal

After pairing validation the actor SHALL retain one pending lifecycle capsule through initial admission. The public route attempt SHALL release its separate one-shot discovery transfer immediately after giving it to admission, and admission SHALL release that transfer when discovery takes ownership. Connected commit SHALL promote the same pending capsule without another lifecycle copy. The raw method argument SHALL NOT be retained or reparsed, and no current route owner, delay Task, terminal coordinator, Keychain item, Event, public value, error, log, reflection, or diagnostic SHALL retain the code. Every failed initial path, Task cancellation, pre-commit disconnect/suspension, permanent recovery failure, enabled exhaustion, and shutdown SHALL clear its applicable capsule. The SDK SHALL promise reference release, not secure String zeroization.

#### Scenario: Session reaches admission

- **WHEN** admission owns discovery input before connected commit
- **THEN** admission owns only its one-shot transfer while the actor pending capsule remains the sole lifecycle owner

#### Scenario: Connected lifecycle intent ends

- **WHEN** a terminal intent-clearing boundary wins
- **THEN** the actor clears the only retained lifecycle code and stale callbacks cannot recreate it

### Requirement: Public connect has no lifecycle policy

Each invocation of `connect(code:)` SHALL perform one initial attempt only and SHALL NOT retry that pending call. A successful call SHALL promote the actor intent governed by `sdk-connection-lifecycle`; later automatic recovery SHALL occur only after success, only under explicit bounded configuration, and only within the intent-wide budget. The connect operation SHALL NOT supersede existing intent, observe foreground/background state, request background execution, poll connectivity, reuse a route, or turn a thrown initial failure into hidden recovery.

#### Scenario: Initial attempt fails transiently

- **WHEN** a transport-like failure occurs before the explicit connect call succeeds
- **THEN** cleanup proceeds, the call throws its safe error, and no recovery or retained intent begins
