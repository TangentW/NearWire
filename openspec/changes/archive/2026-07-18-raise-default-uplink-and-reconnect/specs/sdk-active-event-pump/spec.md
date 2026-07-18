## MODIFIED Requirements

### Requirement: Viewer policy activates conservative directional rates

Active pumping SHALL require negotiated `bidirectional-events` and `flow-policy` capabilities. The first buffered or newly received policy message SHALL be one Viewer `flow.policy.offer`. The App SHALL convert the offer and `NearWireConfiguration` maxima to validated directional rates, compute each effective direction as the minimum of Viewer request and App maximum, and synchronously admit one exact `flow.policy.accepted` response before entering active phase. Missing capabilities, an accepted-policy message from Viewer, Event input before the initial offer, or invalid phase/order SHALL fail terminally.

Zero SHALL pause only the corresponding business-Event direction. Control traffic, policy changes, terminal handling, queue retention, and TTL processing SHALL continue. Positive effective rates SHALL use one monotonic token bucket per direction with a 0.25-second bounded burst duration. This session-specific business-Event burst SHALL NOT change the Core token bucket's general default or the Viewer system-message bucket.

Later Viewer offers SHALL become complete ordered transactions containing both validated effective directions, receipt order, and an acceptance intent without retained encoded `Data` or a preselected rate boundary. Receipt SHALL pause selection of new outbound drains and incoming publications. Any old-policy drain or publication already in flight SHALL finish and consume its token at its captured selection time before the acceptance or either bucket changes. At commit the core SHALL deterministically encode the acceptance, sample one fresh policy-commit time from the exact bound session clock, and prepare nonthrowing replacement copies of both buckets before peer-visible mutation. Any encoding, clock, or arithmetic failure SHALL terminate before mailbox admission. The core SHALL then synchronously admit the acceptance and immediately install both prepared bucket copies without suspension or Event selection between those operations. The sampled commit time SHALL be the local policy boundary; mailbox failure SHALL leave both old buckets unchanged. Multiple transactions SHALL apply in offer order, each with a fresh commit time and no Event selection between acceptance boundaries. Events decoded after an offer MAY enter the bounded incoming FIFO but SHALL NOT publish before that transaction commits. Exceeding the complete-transaction bound SHALL fail terminally.

#### Scenario: Viewer requests above App maxima

- **WHEN** Viewer offers 5,000 uplink and 500 downlink Events per second while App maxima are 4,096 and 50
- **THEN** App admits an acceptance containing 4,096 uplink and 50 downlink
- **AND** only those effective values configure the active buckets

#### Scenario: Direction is paused

- **WHEN** either side contributes zero for one direction
- **THEN** no business Event is sent or published in that direction
- **AND** Control processing and later policy offers remain live

#### Scenario: Initial offer and Event are coalesced

- **WHEN** a valid initial offer is followed by a valid Event in the same receive chunk
- **THEN** the acceptance bytes enter the secure mailbox before the Event is admitted to active buffering
- **AND** the Event is governed by the effective downlink policy

#### Scenario: Policy changes during Event work

- **WHEN** one or more Viewer offers arrive while a queue drain or incoming publication is suspended
- **THEN** selected Events consume only old-policy tokens at their captured times
- **AND** complete bidirectional acceptances and reconfigurations apply exactly once in offer order before any new Event selection
