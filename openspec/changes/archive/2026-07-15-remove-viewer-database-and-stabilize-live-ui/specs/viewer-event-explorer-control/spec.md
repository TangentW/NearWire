## MODIFIED Requirements

### Requirement: Ordinary refresh preserves a stable bounded presentation

An ordinary current-Session refresh SHALL keep the previous complete Timeline visible until a successor in-memory evaluation is complete. When rows already exist, internal retained-refresh loading/progress/ready phases SHALL NOT independently publish a visible Timeline signature. One completed successor SHALL publish only if rendered rows, selection, diagnostics, guidance, or other visible Timeline state changed. Event rows SHALL retain stable journal-key identity, and no memory-to-database representation replacement SHALL occur.

Data-only Event refresh SHALL disable implicit animation for the affected Timeline container and rows while preserving user-driven scrolling, selection, panel visibility, and sheet interactions. Incoming Events SHALL NOT recreate the root split view, Inspector, composer, or Devices strip when their visible signatures are unchanged.

#### Scenario: A burst arrives while Timeline has rows

- **WHEN** several Events arrive within the bounded refresh cadence
- **THEN** the existing Timeline remains continuously visible until each completed coalesced successor is ready
- **AND** internal loading/progress phases do not replace the list or publish unrelated regions

#### Scenario: A new row is appended

- **WHEN** evaluation adds one retained Event to the visible result
- **THEN** only the completed row result publishes with stable identities and no implicit flash animation
- **AND** Inspector and composer state remain unchanged unless their own visible data changed

### Requirement: Viewer-to-App control composition reports only local admission

Viewer SHALL expose one memory-only control composer below the Event workspace. It SHALL target one or more currently active App sessions and accept a bounded user Event type, bounded JSON content, priority, optional bounded TTL, and either normal or keep-latest queue policy. The Event type editor SHALL have a nonzero visible and hit-testable area at the supported minimum window size and compact fallback layout, SHALL accept keyboard focus and ordinary bounded edits, and SHALL remain independent of Event/Performance refresh publication.

One send action SHALL validate and encode the immutable Event candidate once, then attempt local queue admission independently for every selected target using each target's exact current capability. The result SHALL present per-target local admission or rejection and SHALL NOT claim peer receipt, delivery, acknowledgement, execution, or processing.

#### Scenario: Operator edits Event type

- **WHEN** the composer is visible at a supported window size and the operator clicks the Event type field
- **THEN** the native editor becomes first responder and accepted characters update the composer draft
- **AND** concurrent Event or Performance refresh does not clear focus or replace the editor

#### Scenario: Selected Apps have different limits

- **WHEN** one prepared Event is sent to selected Apps with different active Event-size or policy limits
- **THEN** Viewer reports the exact local admission outcome for each App
- **AND** one target's rejection does not change another target's queue transaction

### Requirement: Memory-only Event surfaces use truthful state

Timeline and Inspector SHALL describe the current Session as in-memory content and SHALL NOT show database-recorded, not-recorded, storage-outage, database-recovery, or durable-history claims. Timeline rows SHALL NOT repeat a per-Event in-memory badge and SHALL NOT present the normal `consumerAccepted` disposition as an operator-facing status badge. A retained Event selected from Timeline SHALL resolve its detail from the same in-memory snapshot or show fixed eviction guidance if the exact Event has left the bounded window.

Each current-Session Timeline row SHALL present a bounded, single-line compact JSON content summary as its primary text. Event type SHALL appear as un-emphasized secondary metadata. Building or refreshing the row SHALL NOT require converting the complete content of a large Event into a display string.

#### Scenario: Retained Event is selected

- **WHEN** the operator selects an Event that remains in the memory Session
- **THEN** Inspector shows that exact Event metadata and content
- **AND** no database availability state affects the result

#### Scenario: A normally accepted Event is listed

- **WHEN** a retained Event has the `consumerAccepted` disposition
- **THEN** Timeline shows the Event without an in-memory or accepted-state badge
- **AND** outcomes or diagnostics that require attention remain eligible for row badges

#### Scenario: A large Event is listed

- **WHEN** a retained Event contains JSON larger than the Timeline summary bound
- **THEN** the row shows a one-line truncated content summary as its primary text
- **AND** shows Event type in the secondary metadata line without headline emphasis
