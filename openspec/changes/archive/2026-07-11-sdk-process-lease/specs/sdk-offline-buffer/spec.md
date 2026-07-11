## MODIFIED Requirements

### Requirement: Instances remain isolated

Creating, sending through, observing, or shutting down one NearWire instance SHALL NOT mutate another instance's queue, state, streams, IDs, configuration, statistics, or lifecycle. One SDK-internal process connection lease MAY govern only ownership of future discovery and network-session work. The lease SHALL NOT merge instance-local data, expose a singleton NearWire facade, or mutate any instance merely because another instance claims or releases connection ownership.

#### Scenario: Two idle instances buffer work

- **WHEN** two instances enqueue different events
- **THEN** each instance reports only its own pending work

#### Scenario: One future connection owner exists

- **WHEN** one internal caller holds the process connection lease while two NearWire instances retain different queues
- **THEN** both queues remain independent and unchanged
- **AND** a competing lease claim fails without mutating either queue
