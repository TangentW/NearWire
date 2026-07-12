## ADDED Requirements

### Requirement: Lifecycle replacement waits for exact prior release

Disconnect, suspension, and route failure SHALL invalidate successor authority before requesting cancellation. A replacement attempt SHALL begin only after the prior exact-route direct cleanup or terminal coordinator has invoked exact release and settled its cleanup receipt. Receipt settlement SHALL be independent of lifecycle-generation freshness; only state, status, intent, and successor authorization SHALL require the current generation. A replacement SHALL claim a fresh handle through the same process registry and SHALL NOT transfer, reuse, overlap, force-reset, or assume successful release of the prior handle.

Concurrent disconnect waiters SHALL await one shared constant-space cleanup receipt and SHALL NOT perform release themselves. A stale direct-cleanup, coordinator, delay, recovery-result, or terminal callback MAY settle only its exact old receipt and SHALL NOT release a newer handle or authorize a newer route. Runtime synchronization failure SHALL remain fail-closed: recovery SHALL stop on ownership-unavailable failure, and no public state or status SHALL claim registry availability.

#### Scenario: Transient terminal starts recovery

- **WHEN** the old route reaches terminal state and exact release synchronization succeeds
- **THEN** its coordinator invokes release before the actor schedules a fresh claim

#### Scenario: Disconnect waits during terminal cleanup

- **WHEN** multiple disconnect callers wait while the old coordinator still owns the lease
- **THEN** one coordinator invokes one release, settles the exact old receipt regardless of generation, and every caller awaiting its shared Task completes

#### Scenario: Old callback arrives after replacement

- **WHEN** stale cleanup work from an older generation runs after a fresh handle exists
- **THEN** exact-token and generation checks preserve the fresh owner
