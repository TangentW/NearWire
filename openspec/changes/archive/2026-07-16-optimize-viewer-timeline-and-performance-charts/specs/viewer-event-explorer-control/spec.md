## MODIFIED Requirements

### Requirement: Timeline uses bounded Viewer receive order and explicit diagnostics

The Timeline SHALL evaluate one immutable snapshot of the bounded memory Session. Events SHALL be ordered by Viewer monotonic receive time and stable journal identity; App-created clocks SHALL remain metadata and SHALL NOT reorder Events from different Devices. The evaluator SHALL retain at most the Session's 512 Events, bounded diagnostic markers, one selection, and the closed filter state.

Oldest-Event eviction, ingress overflow, conflicts, drops, terminal outcomes, and other non-normal outcomes SHALL use explicit bounded markers. Normal receive-pipeline progress dispositions, including buffered, transport-admitted, and consumer-accepted, and the Session-wide memory lifetime SHALL NOT appear as Timeline badges. Each Event row SHALL place Event type, exceptional badges, and receive time on one shared top horizontal line. Beneath it, a content summary derived from at most 256 UTF-8 bytes SHALL wrap to at most three lines and tail-truncate any remainder. Badges SHALL NOT add another row. Device/source, direction, priority, and payload byte count SHALL remain available in Inspector metadata and SHALL NOT be repeated in the Timeline row.

The Timeline SHALL derive tail-follow behavior from the visible scroll viewport. A newly admitted matching Event SHALL scroll to the newest row only when the operator was already at the Timeline bottom. Manual upward scrolling SHALL preserve the reading position; returning to the bottom or invoking Jump to Latest SHALL resume tail following.

#### Scenario: An Event advances through normal admission

- **WHEN** a retained Event reports buffered, transport-admitted, or consumer-accepted disposition
- **THEN** the Timeline row shows no disposition badge for that normal progress state
- **AND** an exceptional disposition or separate diagnostic remains visible

#### Scenario: A new Event is admitted while following the tail

- **WHEN** the current memory snapshot gains one Event matching the active scope and filter while the Timeline viewport is at its bottom
- **THEN** the Timeline places it by Viewer receive order, preserves existing stable row identities, and reveals the new last row without animated container replacement
- **AND** no database query, page cursor, or historical source is involved

#### Scenario: A new Event is admitted while reading older Events

- **WHEN** the operator has manually scrolled above the Timeline bottom and a matching Event is admitted
- **THEN** the existing reading position remains stable
- **AND** Jump to Latest or returning to the bottom restores tail following

#### Scenario: The selected Event is evicted

- **WHEN** memory-window eviction removes the exact selected journal identity
- **THEN** selection and Inspector detail are cleared
- **AND** an unrelated Event is never selected as a replacement
