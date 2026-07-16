## MODIFIED Requirements

### Requirement: Timeline uses bounded Viewer receive order and explicit diagnostics

The Timeline SHALL evaluate one immutable snapshot of the bounded memory Session. Events SHALL be ordered by Viewer monotonic receive time and stable journal identity; App-created clocks SHALL remain metadata and SHALL NOT reorder Events from different Devices. The evaluator and Timeline SHALL preserve every Event in the current byte-bounded Session snapshot and SHALL NOT apply an independent fixed row-count suffix. Diagnostic markers, selection, and closed filter state SHALL remain bounded.

Oldest-Event eviction, ingress overflow, conflicts, drops, terminal outcomes, and other non-normal outcomes SHALL use explicit bounded markers. Normal receive-pipeline progress dispositions, including buffered, transport-admitted, and consumer-accepted, and the Session-wide memory lifetime SHALL NOT appear as Timeline badges. Each Event row SHALL place Event type, exceptional badges, and receive time on one shared top horizontal line. Beneath it, a content summary derived from at most 256 UTF-8 bytes SHALL wrap to at most three lines and tail-truncate any remainder. Badges SHALL NOT add another row. Device/source, direction, priority, and payload byte count SHALL remain available in Inspector metadata and SHALL NOT be repeated in the Timeline row.

The Timeline SHALL derive tail-follow behavior from the actual visible scroll viewport. A newly admitted matching Event SHALL scroll to the newest real Event row only when the operator was already following the Timeline bottom before that Event changed content height. The Timeline SHALL NOT insert a synthetic visible or layout-participating row after the final Event for measurement or scrolling. Manual upward scrolling SHALL synchronously latch following off before successor publication and SHALL preserve the reading position. Content-height growth SHALL NOT reinterpret a previously false follow intent as true. Returning to the bottom or invoking Jump to Latest SHALL resume tail following.

#### Scenario: More than 512 matching Events are retained

- **WHEN** a byte-valid current Session snapshot contains more than 512 Events matching the active scope and filter
- **THEN** Timeline publishes every matching retained row in Viewer receive order
- **AND** it does not discard an older row merely to satisfy a fixed display count

#### Scenario: An Event advances through normal admission

- **WHEN** a retained Event reports buffered, transport-admitted, or consumer-accepted disposition
- **THEN** the Timeline row shows no disposition badge for that normal progress state
- **AND** an exceptional disposition or separate diagnostic remains visible

#### Scenario: A new Event is admitted while following the tail

- **WHEN** the current memory snapshot gains one Event matching the active scope and filter while the operator was following the Timeline bottom
- **THEN** the Timeline places it by Viewer receive order, preserves existing stable row identities, and reveals the new last real Event directly in its final bottom position without animated container replacement, a transient blank item, or a second row-height shift
- **AND** content-height growth does not disable the already-latched follow intent before the reveal

#### Scenario: A new Event is admitted while reading older Events

- **WHEN** the operator has manually scrolled above the Timeline bottom and a matching Event is admitted
- **THEN** the existing reading position remains stable and no automatic tail scroll is scheduled
- **AND** Jump to Latest or returning to the bottom restores tail following

#### Scenario: The selected Event is evicted

- **WHEN** memory-window eviction removes the exact selected journal identity
- **THEN** selection and Inspector detail are cleared
- **AND** an unrelated Event is never selected as a replacement

### Requirement: Workspace panels and refresh preserve stable presentation

Timeline, Inspector, composer, Devices, and header regions SHALL have stable semantic identity and independently controlled visibility. When Timeline and Inspector are both initially visible, the native horizontal split SHALL allocate approximately 70% of the available panel width to Timeline and 30% to Inspector, subject to maintained minimum widths and the native divider. The operator SHALL remain able to resize the divider, and a sole visible panel SHALL expand into the available width.

Toolbar panel toggles and Inspector tab changes SHALL publish immediately. Ordinary Event refresh SHALL retain the existing Timeline, Inspector, composer, and chart containers while applying only semantically changed values.

Equivalent snapshots SHALL not publish. Data-only refresh SHALL disable implicit animation, coalesce high-frequency change notifications to the bounded cadence, and avoid removing and recreating whole conditional branches. No model mutation SHALL be initiated from within a SwiftUI render update.

#### Scenario: Events arrive at normal cadence

- **WHEN** a visible Timeline or Inspector already exists and new data arrives
- **THEN** affected rows or detail values update without whole-window flashing
- **AND** unrelated controls retain focus, scroll position, selection, and accessibility identity

#### Scenario: The operator changes an Inspector tab

- **WHEN** the tab selection changes without a new Event
- **THEN** the selected tab appears immediately
- **AND** the transition does not wait for another runtime publication

#### Scenario: Event panels first appear together

- **WHEN** the Event workspace first materializes with Timeline and Inspector visible
- **THEN** Timeline receives approximately 70% and Inspector approximately 30% of the available horizontal panel width
- **AND** both panels satisfy their minimum widths and remain user-resizable

#### Scenario: One Event panel is hidden

- **WHEN** the operator hides Timeline or Inspector
- **THEN** the remaining Event panel expands into the available horizontal space
- **AND** restoring both panels reintroduces the native adjustable divider without recreating unrelated workspace regions
