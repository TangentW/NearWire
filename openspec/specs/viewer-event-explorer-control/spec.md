# viewer-event-explorer-control Specification

## Purpose

Define the bounded current-Session Event workspace, including Timeline evaluation, filtering, inspection, rendering, pause behavior, Viewer-to-App composition, and stable SwiftUI publication.
## Requirements
### Requirement: Timeline uses bounded Viewer receive order and explicit diagnostics

The Timeline SHALL evaluate one immutable snapshot of the bounded memory Session. Events SHALL be ordered by Viewer monotonic receive time and stable journal identity; App-created clocks SHALL remain metadata and SHALL NOT reorder Events from different Devices. The evaluator SHALL retain at most the Session's 512 Events, bounded diagnostic markers, one selection, and the closed filter state.

Oldest-Event eviction, ingress overflow, conflicts, drops, and other non-normal outcomes SHALL use explicit bounded markers. A normal accepted disposition and the Session-wide memory lifetime SHALL NOT be repeated as badges on every row. Each Event row SHALL lead with a one-line content summary derived from at most 256 UTF-8 bytes and present Event type as secondary metadata.

#### Scenario: A new Event is admitted

- **WHEN** the current memory snapshot gains one Event matching the active scope and filter
- **THEN** the Timeline places it by Viewer receive order and preserves existing stable row identities
- **AND** no database query, page cursor, or historical source is involved

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

Selecting a retained Event SHALL resolve exact metadata and canonical content from the current memory snapshot. Raw JSON SHALL remain chunked, Pretty JSON and tree derivation SHALL retain their existing input/output/work bounds, and selection replacement or Clear/import/shutdown SHALL invalidate predecessor detail and renderer generations.

The immutable Viewer-internal Renderer registry SHALL remain available for Generic JSON, log line, key-value table, numeric-series, and timeline presentations. Pattern selection and all existing input, time, derived-output, cancellation, accessibility, escaping, fallback, and redacted-reflection bounds SHALL remain enforced. Renderer preparation SHALL create no persistence or secondary Session authority.

The Inspector SHALL NOT expose a Causality tab, causality loading/error state, cross-Event candidate graph, or database row lookup. `correlationID` and `replyTo` MAY remain visible as metadata for the selected Event.

#### Scenario: Operator selects a renderer-compatible Event

- **WHEN** a retained `log.*`, `table.*`, `chart.*`, or `timeline.*` Event is selected
- **THEN** Renderer prepares the bounded specialized presentation or safe Generic JSON fallback from the selected in-memory bytes
- **AND** no database or cross-Event query is performed

#### Scenario: Operator inspects causality metadata

- **WHEN** a selected Event contains correlation or reply identifiers
- **THEN** the identifiers remain available in Event metadata
- **AND** no Causality tab or inferred cross-Event candidate list is shown

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

Timeline, Inspector, composer, Devices, and header regions SHALL have stable semantic identity and independently controlled visibility. Toolbar panel toggles and Inspector tab changes SHALL publish immediately. Ordinary Event refresh SHALL retain the existing Timeline, Inspector, composer, and chart containers while applying only semantically changed values.

Equivalent snapshots SHALL not publish. Data-only refresh SHALL disable implicit animation, coalesce high-frequency change notifications to the bounded cadence, and avoid removing and recreating whole conditional branches. No model mutation SHALL be initiated from within a SwiftUI render update.

#### Scenario: Events arrive at normal cadence

- **WHEN** a visible Timeline or Inspector already exists and new data arrives
- **THEN** affected rows or detail values update without whole-window flashing
- **AND** unrelated controls retain focus, scroll position, selection, and accessibility identity

#### Scenario: The operator changes an Inspector tab

- **WHEN** the tab selection changes without a new Event
- **THEN** the selected tab appears immediately
- **AND** the transition does not wait for another runtime publication

### Requirement: Event workspace is accessible, private, and localized

Controls SHALL provide labels, help, keyboard focus, disabled state, and non-color state descriptions. Received Event type, content, metadata values, App-provided names, identifiers, and JSON keys/values SHALL be displayed verbatim and SHALL NOT be localized. Viewer-owned labels, guidance, errors, confirmations, tooltips, formatted presentation, and accessibility text SHALL be complete in English and Simplified Chinese.

Received content SHALL have no log, analytics, preference, restoration, recent-item, clipboard, drag, share, or reflection sink except explicit Inspector copy actions and disclosed JSON export. Generation-bound cleanup SHALL clear received content after Session replacement or shutdown.

#### Scenario: Viewer language changes

- **WHEN** the operator switches between supported languages while Events are visible
- **THEN** Viewer-owned chrome updates immediately
- **AND** received Event values and the active Session remain byte-for-byte unchanged
