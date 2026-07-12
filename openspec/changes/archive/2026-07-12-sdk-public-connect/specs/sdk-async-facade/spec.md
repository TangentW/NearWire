## MODIFIED Requirements

### Requirement: NearWire is an instance actor with explicit lifecycle

The SDK SHALL expose `NearWire` as an actor-backed instance with a side-effect-free initializer. The instance SHALL start idle, support one explicit tokenized connect attempt, support idempotent terminal shutdown, and reject sends, replies, and connect after shutdown with the typed shutdown error.

Shutdown SHALL synchronously detach the exact public attempt or active slot, latch the shutdown reason, request cancellation, clear pending Event work, publish shutdown, and finish observers once. Non-cancellable identity or pre-admission work MAY continue in the attempt; after admission, the already-running sole terminal coordinator SHALL retain the exact lease until core terminal state without retaining NearWire. Shutdown SHALL start no second terminal wait and SHALL NOT promise immediate lease reacquisition. Deinitialization after connect returns SHALL release the hidden active handle so its cancellation request and the same coordinator complete cleanup without state publication. A live connect Task retains the actor; attempt-time cleanup SHALL use Task cancellation or shutdown.

#### Scenario: Construct an instance

- **WHEN** application code initializes NearWire
- **THEN** no discovery, connection, Keychain, timer, task, persistence, UI, or global ownership begins

#### Scenario: Shut down during connect

- **WHEN** shutdown races a token-current worker, admission, or activation
- **THEN** shutdown detaches public ownership and remains final while non-public exact cleanup retains the lease until the internal operation ends

#### Scenario: Shut down while connected

- **WHEN** shutdown runs with one active connected owner
- **THEN** it requests active cancellation while the already-running sole terminal coordinator retains the lease and wait

#### Scenario: Drop an external reference during connect

- **WHEN** a live Task is awaiting the instance connect method and the caller drops another NearWire reference
- **THEN** the Task still retains the actor and no implicit attempt cancellation is promised

#### Scenario: Shut down twice

- **WHEN** shutdown is invoked more than once
- **THEN** the instance remains terminal without duplicate detachment, cancellation request, clearing, or state publication

### Requirement: State observation is latest-value bounded fan-out

Every state subscription SHALL first receive current state and then token-current changes. Each subscriber SHALL retain at most the newest pending state, be removable by cancellation, and not block or alter connection lifecycle. Public connect SHALL publish discovering, connecting, connected, and disconnected according to the public-connect requirements; reconnecting remains unproduced.

#### Scenario: Late state subscriber

- **WHEN** a subscriber starts after connection state changed
- **THEN** its first value is current state rather than historical replay

#### Scenario: Subscriber cancels

- **WHEN** a state consumer stops iteration
- **THEN** its continuation is released without changing connection or instance lifecycle
