## MODIFIED Requirements

### Requirement: NearWire is an instance actor with explicit lifecycle

The SDK SHALL expose `NearWire` as an actor-backed instance with a side-effect-free initializer. The instance SHALL start idle, support one explicit tokenized connect attempt, idempotent async disconnect and suspension, idempotent nonblocking resume, optional bounded recovery, and idempotent terminal shutdown. It SHALL reject sends, replies, and connect after shutdown with the typed shutdown error; lifecycle cleanup calls after shutdown SHALL be inert.

Shutdown SHALL synchronously invalidate connection intent and recovery generation, explicitly cancel delay work, detach the exact public attempt or active slot, latch the shutdown reason, request cancellation, clear pending Event work, publish shutdown, and finish observers once. Non-cancellable identity or pre-admission work MAY continue in the attempt; after admission, the already-running sole terminal coordinator SHALL retain the exact lease until core terminal state without retaining NearWire. Shutdown SHALL start no second terminal wait and SHALL NOT promise immediate lease reacquisition. Deinitialization after connect returns SHALL explicitly cancel the recovery Task and release the hidden active handle so cancellation and the same coordinator complete cleanup without state publication; dropping a Task handle alone SHALL NOT be treated as cancellation. A live connect Task retains the actor; attempt-time cleanup SHALL use Task cancellation, disconnect, suspension, or shutdown.

#### Scenario: Construct an instance

- **WHEN** application code initializes NearWire
- **THEN** no discovery, connection, Keychain, timer, task, persistence, UI, lifecycle observer, or global ownership begins

#### Scenario: Shut down during connect or recovery

- **WHEN** shutdown races a token-current worker, admission, activation, or recovery delay
- **THEN** shutdown invalidates intent, detaches public ownership, and remains final while non-public exact cleanup retains the lease until the internal operation ends

#### Scenario: Shut down while connected

- **WHEN** shutdown runs with one active connected owner
- **THEN** it requests active cancellation while the already-running sole terminal coordinator retains the lease and wait

#### Scenario: Drop an external reference during connect

- **WHEN** a live Task is awaiting the instance connect method and the caller drops another NearWire reference
- **THEN** the Task still retains the actor and no implicit attempt cancellation is promised

#### Scenario: Shut down twice

- **WHEN** shutdown is invoked more than once
- **THEN** the instance remains terminal without duplicate intent invalidation, detachment, cancellation request, clearing, or state publication

### Requirement: State observation is latest-value bounded fan-out

Every state subscription SHALL first receive current state and then generation-current changes. Each subscriber SHALL retain at most the newest pending state, be removable by cancellation, and not block or alter connection lifecycle. Initial public connect SHALL publish discovering, connecting, connected, and disconnected according to public-connect requirements. Eligible recovery SHALL publish reconnecting and then connected or disconnected; its internal discovery and admission phases SHALL remain reconnecting. During disconnect/suspension cleanup the prior state SHALL remain current until exact receipt settlement. Duplicate state values SHALL be suppressed.

#### Scenario: Late state subscriber

- **WHEN** a subscriber starts after connection state changed
- **THEN** its first value is current state rather than historical replay

#### Scenario: Subscriber cancels

- **WHEN** a state consumer stops iteration
- **THEN** its continuation is released without changing connection or instance lifecycle

#### Scenario: Recovery traverses internal phases

- **WHEN** a replacement attempt performs delay, discovery, admission, and activation
- **THEN** the simple state surface remains reconnecting until connected or disconnected

### Requirement: Shutdown terminates observation deterministically

Shutdown SHALL clear pending offline work and lifecycle intent, publish the final shutdown state and connection status once, finish all existing state, status, and Event streams, and make later publication inert. A state stream created after shutdown SHALL yield the final state and finish; a status stream SHALL yield the final status and finish; an Event stream SHALL finish without retaining a continuation.

#### Scenario: Shutdown with active observers

- **WHEN** an instance shuts down while state, connection-status, and Event subscribers exist
- **THEN** state and status observers receive their terminal values and all observers terminate without leaked continuation ownership
