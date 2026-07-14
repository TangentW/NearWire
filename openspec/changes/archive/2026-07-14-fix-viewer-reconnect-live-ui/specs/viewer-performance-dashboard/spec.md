## MODIFIED Requirements

### Requirement: Events and Performance hand off metric-specific raw identity under one arbiter

Every measured accumulator SHALL carry a contributing journal key and source generation. Live-to-durable reconciliation SHALL update only its locator. Open Source Event SHALL resolve the selected metric's key at action time, preferring exact durable then still-live. Deleted, evicted, stale, or unresolvable keys SHALL show fixed guidance and SHALL not choose a neighbor. No JSON, metric, bucket, tooltip, or renderer object SHALL cross controllers; derived buckets SHALL not export.

One analysis-mode coordinator SHALL serialize the shared query arbiter. Events-to-Performance SHALL invalidate/join Explorer query/detail work and release its traversal before Performance starts. Performance-to-Events SHALL invalidate/join the scan and release its traversal before Event work or reveal. Reveal SHALL validate source, perform this order, switch mode, then submit the key. At most one mode SHALL own an active traversal; cached presentation owns no lease. The native workspace SHALL directly observe that coordinator's published mode/revision so a completed mode transition redraws without waiting for an Event, Store, device, or application-model update.

#### Scenario: Aggregated CPU bucket opens source

- **WHEN** CPU contributors differ from FPS contributors and the operator opens the CPU series
- **THEN** Viewer resolves CPU's deterministic contributing key and selects exactly that raw Event
- **AND** it never opens the bucket-wide or nearest unrelated Event

#### Scenario: Mode changes during traversal

- **WHEN** Events owns a traversal and Performance is selected
- **THEN** Events cancellation/join and exact lease release finish before Performance submits work
- **AND** no predecessor completion can retarget the shared arbiter
- **AND** the workspace redraws from the coordinator's completed publication without waiting for unrelated model activity
