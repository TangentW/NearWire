# viewer-event-explorer-control Specification

## Purpose

Define the bounded current-Session Event workspace, including Timeline evaluation, filtering, inspection, rendering, pause behavior, Viewer-to-App composition, and stable SwiftUI publication.
## Requirements
### Requirement: Timeline uses bounded Viewer receive order and explicit diagnostics

The Timeline SHALL evaluate one immutable snapshot of the bounded memory Session. Events SHALL be ordered by Viewer monotonic receive time and stable journal identity; App-created clocks SHALL remain metadata and SHALL NOT reorder Events from different Devices. The evaluator and Timeline SHALL preserve every Event in the current byte-bounded Session snapshot and SHALL NOT apply an independent fixed row-count suffix. Diagnostic markers, selection, and closed filter state SHALL remain bounded.

Oldest-Event eviction, ingress overflow, conflicts, drops, terminal outcomes, and other non-normal outcomes SHALL use explicit bounded markers. Normal receive-pipeline progress dispositions, including buffered, transport-admitted, and consumer-accepted, and the Session-wide memory lifetime SHALL NOT appear as Timeline badges. Each Event row SHALL place Event type, exceptional badges, and receive time on one shared top horizontal line. Beneath it, a content summary derived from at most 256 UTF-8 bytes SHALL wrap to at most three lines and tail-truncate any remainder. Badges SHALL NOT add another row. Device/source, direction, priority, and payload byte count SHALL remain available in Inspector metadata and SHALL NOT be repeated in the Timeline row.

The Timeline SHALL derive tail-follow behavior from the actual visible scroll viewport. A newly admitted matching Event SHALL scroll to the newest real Event row only when the operator was already following the Timeline bottom before that Event changed content height. The Timeline SHALL NOT insert a synthetic visible or layout-participating row after the final Event for measurement or scrolling. Manual upward scrolling SHALL synchronously latch following off before successor publication and SHALL preserve the reading position. Content-height growth SHALL NOT reinterpret a previously false follow intent as true. Returning to the bottom or invoking Jump to Latest SHALL resume tail following.

When a new last Event is admitted while the exact Timeline scroll view is in momentum deceleration, the Timeline SHALL stop the remaining momentum sequence at the current visible origin before further momentum movement can compete with the content update. It SHALL suppress only that Timeline's remaining momentum movement events and SHALL still allow the terminal phase to reset AppKit gesture state without applying another delta. It SHALL NOT intercept another scroll view, cancel an ordinary successor gesture, schedule a tail scroll for an operator reading older Events, or alter Event admission and ordering.

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

#### Scenario: An Event arrives during Timeline momentum

- **WHEN** the operator releases a Timeline scroll gesture, the Timeline is decelerating, and a new last Event is admitted
- **THEN** the remaining Timeline momentum stops at the current visible origin without repeated flashing
- **AND** unrelated scroll views and a later ordinary Timeline gesture remain unaffected

#### Scenario: The selected Event is evicted

- **WHEN** memory-window eviction removes the exact selected journal identity
- **THEN** selection and Inspector detail are cleared
- **AND** an unrelated Event is never selected as a replacement

### Requirement: Search and filtering use one closed memory evaluator

The Explorer SHALL support selected Devices, App and Bundle hints, exact or prefix Event type, direction, priority, Viewer receive-time range, literal content terms, bounded typed JSON path predicates, gap/drop presence, and terminal-disposition presence. Different dimensions SHALL combine with AND and selected alternatives within one dimension SHALL combine with OR.

Input SHALL be validated into one closed bounded scope before evaluation. Invalid paths, excessive predicates, excessive text, or unavailable projection data SHALL return fixed guidance or no match; they SHALL NOT widen the filter, execute arbitrary code, or trigger persistence lookup.

#### Scenario: A typed JSON filter is applied

- **WHEN** the operator supplies a valid bounded JSON path predicate
- **THEN** the current memory snapshot is evaluated with the same normalized Event observation used by Timeline presentation
- **AND** malformed or excessive input cannot become an unbounded scan or a different query language

### Requirement: Presentation Pause never pauses capture or creates backlog

Pause SHALL freeze Timeline presentation, selection, and scroll anchor after advancing the presentation generation. It SHALL NOT pause network receive, protocol admission, bounded memory retention, queue expiration, flow control, or Viewer-to-App sending. While paused, the Explorer SHALL retain only bounded dirty state and SHALL NOT schedule one UI task per arriving Event.

Resume SHALL evaluate one fresh bounded snapshot with the current scope and filter. Manual scrolling SHALL disable auto-follow without changing Pause; Jump to Latest SHALL restore tail presentation.

#### Scenario: Events arrive while presentation is paused

- **WHEN** multiple Events commit during Pause
- **THEN** frozen rows and selection remain unchanged while capture continues within memory bounds
- **AND** Resume publishes one current successor rather than replaying an unbounded UI backlog

### Requirement: Event detail and renderer selection are bounded and fallback-safe

Selecting a retained Event SHALL resolve exact metadata and canonical content from the current memory snapshot. Raw JSON SHALL remain chunked, Pretty JSON SHALL retain its existing input/output/work bounds, and selection replacement or Clear/import/shutdown SHALL invalidate predecessor detail and renderer generations. Raw and Pretty content SHALL wrap within the available Inspector width and SHALL support explicit user selection, Copy, and Select All while remaining noneditable and non-draggable.

The immutable Viewer-internal Renderer registry SHALL remain available for Generic JSON, log line, key-value table, numeric-series, and timeline presentations. The Inspector SHALL label this presentation as Preview. Pattern selection and all existing input, time, derived-output, cancellation, accessibility, escaping, fallback, and redacted-reflection bounds SHALL remain enforced. A Generic JSON result SHALL show bounded Pretty content when available or bounded Raw content otherwise; it SHALL NOT present an empty instruction in place of the selected Event. Renderer preparation SHALL create no persistence or secondary Session authority.

The Inspector SHALL expose only Pretty, Raw, Preview, and Metadata tabs, ordered from leading to trailing in that sequence. It SHALL NOT expose a Tree or Causality tab, Tree expansion state, causality loading/error state, cross-Event candidate graph, or database row lookup. `correlationID` and `replyTo` MAY remain visible as metadata for the selected Event.

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

#### Scenario: Operator reads inspector choices

- **WHEN** Event detail is ready
- **THEN** Pretty is the leftmost inspector choice
- **AND** Metadata is the rightmost inspector choice
- **AND** Raw and Preview remain available between them

### Requirement: Current Session actions preserve one authoritative workspace

The workspace SHALL expose Clear and complete-Session JSON import/export against the same bounded memory Session. Clear SHALL atomically remove retained Event-derived data while preserving the listener, pairing code, connected Device lanes, negotiated policies, and composer capability. Export SHALL freeze only currently retained content after the unencrypted disclosure. Import SHALL be allowed only when no App is active or pending and SHALL atomically replace the inactive Session after bounded validation.

The Explorer SHALL NOT expose recording/device Store catalogs, Store row identities, traversal leases, durable pagination, recording mutation, retention, capacity, historical catalogs, filtered durable export, Store replacement, or database recovery state. Detailed transfer, Clear, and memory bounds are defined by `viewer-memory-session`.

#### Scenario: The operator clears an active Session

- **WHEN** Clear is confirmed while an App remains connected
- **THEN** Timeline, Inspector, diagnostics, and derived Performance content become empty
- **AND** successor Events may enter the same live Device connection without a Store lifecycle

### Requirement: Viewer-to-App control composition reports only local admission

The composer SHALL accept an explicit Event type and Codable JSON content, validate the configured payload limit and selected route, and report local mailbox admission separately from later peer processing. It SHALL NOT claim peer acknowledgement from local acceptance. Admission failure SHALL preserve editable input and display a closed safe error.

#### Scenario: A control Event is admitted

- **WHEN** the operator enters valid type and content for one connected Device
- **THEN** Viewer reports local queue admission and clears input only according to the composer contract
- **AND** no Timeline or Inspector state is used as an acknowledgement authority

### Requirement: Workspace panels and refresh preserve stable presentation

Timeline, Inspector, composer, Devices, and header regions SHALL have stable semantic identity and independently controlled visibility. When Timeline and Inspector are both initially visible, the native horizontal split SHALL allocate approximately 70% of the available panel width to Timeline and 30% to Inspector, subject to maintained minimum widths and the native divider. The settled split SHALL retain that allocation until the operator resizes the divider or changes panel visibility. The operator SHALL remain able to resize the divider, and a sole visible panel SHALL expand into the available width.

Composer SHALL default hidden when a Viewer window is created. When the operator shows Composer, it SHALL occupy one fixed height sufficient to present the complete maintained horizontal send form. The operator SHALL NOT be able to resize Composer height. Hiding Composer SHALL return its space to analysis without clearing the current draft or changing controller identity.

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

- **WHEN** the Event workspace first materializes with Timeline and Inspector visible and delayed layout has settled
- **THEN** Timeline retains approximately 70% and Inspector approximately 30% of the available horizontal panel width
- **AND** both panels satisfy their minimum widths and remain user-resizable

#### Scenario: Ordinary content updates after the split settles

- **WHEN** Timeline or Inspector content changes without an operator divider action
- **THEN** the existing divider position remains stable
- **AND** the panels do not redistribute to an equal split

#### Scenario: One Event panel is hidden

- **WHEN** the operator hides Timeline or Inspector
- **THEN** the remaining Event panel expands into the available horizontal space
- **AND** restoring both panels reintroduces the native adjustable divider without recreating unrelated workspace regions

#### Scenario: Viewer window opens

- **WHEN** a new Viewer window materializes
- **THEN** Composer is collapsed and analysis receives the available vertical workspace
- **AND** the toolbar control remains available to show Composer

#### Scenario: Operator shows Composer

- **WHEN** the operator enables Composer from the toolbar
- **THEN** the complete send form appears at the maintained fixed height
- **AND** no draggable vertical split can resize or clip the Composer

### Requirement: Event workspace is accessible, private, and localized

Controls SHALL provide labels, help, keyboard focus, disabled state, and non-color state descriptions. Received Event type, content, metadata values, App-provided names, identifiers, and JSON keys/values SHALL be displayed verbatim and SHALL NOT be localized. Viewer-owned labels, guidance, errors, confirmations, tooltips, formatted presentation, and accessibility text SHALL be complete in English and Simplified Chinese.

Received content SHALL have no log, analytics, preference, restoration, recent-item, clipboard, drag, share, or reflection sink except explicit Inspector copy actions and disclosed JSON export. Generation-bound cleanup SHALL clear received content after Session replacement or shutdown.

#### Scenario: Viewer language changes

- **WHEN** the operator switches between supported languages while Events are visible
- **THEN** Viewer-owned chrome updates immediately
- **AND** received Event values and the active Session remain byte-for-byte unchanged

### Requirement: Active Device selection follows exact-route reconnect replacement

The Event Explorer SHALL preserve an operator's active logical Device focus across newest-session replacement. When a selected predecessor was non-recent in the prior session snapshot and a different non-recent connection for the exact same `ViewerLogicalRoute` appears in the successor snapshot, the Explorer SHALL replace the predecessor connection UUID with the successor UUID before its next bounded Timeline evaluation. It SHALL preserve other selected Devices and SHALL NOT migrate a deliberately selected historical recent connection, a different installation, or a different application route.

The Devices strip SHALL present at most one non-imported Device row for each exact `ViewerLogicalRoute`, even while the memory Session retains Events and lifecycle metadata from predecessor connection UUIDs. That row SHALL retain a stable process-local presentation identity across reconnect replacement and SHALL target the newest current connection when one exists, otherwise the most recently ended retained connection. Different logical routes and imported Devices SHALL remain distinct. Coalescing presentation SHALL NOT merge connection-scoped Event ordering, transport state, Performance samples, control capability, or wire session identity.

The selection migration SHALL use the existing in-memory selection refresh path and SHALL NOT clear existing rows while the successor evaluation is pending, create persistence, or treat the predecessor's Events as belonging to the successor session.

#### Scenario: Selected App reconnects with a fresh session

- **WHEN** an actively selected App connection is replaced by a fresh connection for the exact same logical route
- **THEN** the selected Device scope moves from the ended predecessor connection UUID to the fresh connection UUID before filtering the next memory snapshot
- **AND** a fresh-epoch Event admitted through the replacement session becomes visible in the Timeline without requiring All Devices or a manual Device reselection

#### Scenario: The same App reconnects repeatedly

- **WHEN** the memory Session retains predecessor connections and a newest connection exists for the exact same logical route
- **THEN** the Devices strip shows one stable Device row for that route
- **AND** the row targets the newest current connection instead of adding one card per reconnect

#### Scenario: Historical or different route remains independent

- **WHEN** a selected connection was already recent, or a new connection belongs to a different installation or application identifier
- **THEN** the Explorer does not retarget that selection
- **AND** distinct session and route identities remain independently filterable
- **AND** different logical routes and imported Device rows remain separate in the Devices strip
