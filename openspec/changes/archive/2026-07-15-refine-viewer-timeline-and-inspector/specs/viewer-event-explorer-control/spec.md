## MODIFIED Requirements

### Requirement: Timeline uses bounded Viewer receive order and explicit diagnostics

The Timeline SHALL evaluate one immutable snapshot of the bounded memory Session. Events SHALL be ordered by Viewer monotonic receive time and stable journal identity; App-created clocks SHALL remain metadata and SHALL NOT reorder Events from different Devices. The evaluator SHALL retain at most the Session's 512 Events, bounded diagnostic markers, one selection, and the closed filter state.

Oldest-Event eviction, ingress overflow, conflicts, drops, and other non-normal outcomes SHALL use explicit bounded markers. A normal accepted disposition and the Session-wide memory lifetime SHALL NOT be repeated as badges on every row. Each Event row SHALL place Event type, exceptional badges, and receive time on one shared top horizontal line. Beneath it, a content summary derived from at most 256 UTF-8 bytes SHALL wrap to at most three lines and tail-truncate any remainder. Badges SHALL NOT add another row. Device/source, direction, priority, and payload byte count SHALL remain available in Inspector metadata and SHALL NOT be repeated in the Timeline row.

The Timeline SHALL derive tail-follow behavior from the visible scroll viewport. A newly admitted matching Event SHALL scroll to the newest row only when the operator was already at the Timeline bottom. Manual upward scrolling SHALL preserve the reading position; returning to the bottom or invoking Jump to Latest SHALL resume tail following.

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

### Requirement: Event detail and renderer selection are bounded and fallback-safe

Selecting a retained Event SHALL resolve exact metadata and canonical content from the current memory snapshot. Raw JSON SHALL remain chunked, Pretty JSON SHALL retain its existing input/output/work bounds, and selection replacement or Clear/import/shutdown SHALL invalidate predecessor detail and renderer generations. Raw and Pretty content SHALL wrap within the available Inspector width and SHALL support explicit user selection, Copy, and Select All while remaining noneditable and non-draggable.

The immutable Viewer-internal Renderer registry SHALL remain available for Generic JSON, log line, key-value table, numeric-series, and timeline presentations. The Inspector SHALL label this presentation as Preview. Pattern selection and all existing input, time, derived-output, cancellation, accessibility, escaping, fallback, and redacted-reflection bounds SHALL remain enforced. A Generic JSON result SHALL show bounded Pretty content when available or bounded Raw content otherwise; it SHALL NOT present an empty instruction in place of the selected Event. Renderer preparation SHALL create no persistence or secondary Session authority.

The Inspector SHALL expose only Metadata, Raw, Pretty, and Preview tabs. It SHALL NOT expose a Tree or Causality tab, Tree expansion state, causality loading/error state, cross-Event candidate graph, or database row lookup. `correlationID` and `replyTo` MAY remain visible as metadata for the selected Event.

#### Scenario: Operator selects a renderer-compatible Event

- **WHEN** a retained `log.*`, `table.*`, `chart.*`, or `timeline.*` Event is selected
- **THEN** Preview prepares the bounded specialized presentation or safe Generic JSON fallback from the selected in-memory bytes
- **AND** no database or cross-Event query is performed

#### Scenario: Operator selects an ordinary JSON Event

- **WHEN** a retained Event has no specialized renderer pattern
- **THEN** Preview displays bounded formatted JSON or a bounded Raw fallback from the selected Event
- **AND** the operator is not redirected to a removed Tree view or shown an empty renderer state

#### Scenario: Operator copies inspected content

- **WHEN** the operator selects text in Raw or Pretty and invokes Copy
- **THEN** only the selected received text is written to the clipboard by that explicit action
- **AND** editing, paste, drag, automatic copy, and background disclosure remain unavailable

#### Scenario: Operator inspects causality metadata

- **WHEN** a selected Event contains correlation or reply identifiers
- **THEN** the identifiers remain available in Event metadata
- **AND** no Tree, Causality, or inferred cross-Event candidate list is shown
