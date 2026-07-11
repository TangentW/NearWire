# sdk-async-facade Specification

## Purpose
TBD - created by archiving change sdk-public-api. Update Purpose after archive.
## Requirements
### Requirement: NearWire is an instance actor with explicit lifecycle

The SDK SHALL expose `NearWire` as an actor-backed instance with a side-effect-free initializer. The instance SHALL start idle, SHALL support idempotent terminal shutdown, and SHALL reject sends and replies after shutdown with a typed safe error.

#### Scenario: Construct an instance

- **WHEN** application code initializes NearWire
- **THEN** no discovery, connection, timer, task, persistence, UI, or global ownership begins

#### Scenario: Shut down twice

- **WHEN** shutdown is invoked more than once
- **THEN** the instance remains terminal without duplicate clearing or duplicate terminal publication

### Requirement: State observation is latest-value bounded fan-out

Every state subscription SHALL first receive the current state and then later state changes. Each subscriber SHALL retain at most the newest pending state, SHALL be removable by cancellation, and SHALL not block or alter other subscribers.

#### Scenario: Late state subscriber

- **WHEN** a subscriber starts after state has changed
- **THEN** its first value is the current state rather than a replay of all historical states

#### Scenario: Subscriber cancels

- **WHEN** a state consumer stops iteration
- **THEN** its continuation is released without changing the NearWire instance lifecycle

### Requirement: Incoming event observation never silently loses an event

Every incoming-event subscription SHALL have a finite configured buffer. If publication would drop a buffered event for a slow subscriber, only that subscriber SHALL terminate with a typed stream-overflow error. The SDK SHALL NOT silently discard the event, block the facade actor, or fail another subscriber.

#### Scenario: One slow and one active subscriber

- **WHEN** one subscriber exceeds its buffer while another consumes promptly
- **THEN** the slow subscription fails and the active subscription continues receiving ordered events

### Requirement: Shutdown terminates observation deterministically

Shutdown SHALL clear pending offline work, publish the final shutdown state once, finish all existing streams, and make later event publication inert. A state stream created after shutdown SHALL yield the final state and finish; an event stream created after shutdown SHALL finish without retaining a continuation.

#### Scenario: Shutdown with active observers

- **WHEN** an instance shuts down while state and event subscribers exist
- **THEN** state observers receive the terminal state and all observers terminate without leaked continuation ownership

