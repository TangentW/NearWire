## MODIFIED Requirements

### Requirement: Events and Performance share one Session with coordinated traversal access

The Viewer SHALL expose Events and Performance over one authoritative Session without a second session manager, Store owner, query execution queue, Explorer controller, live projection, or raw Event cache. Event scope MAY contain up to 16 logical Devices; Performance SHALL own an independent exact logical Device selection. Runtime or Store replacement SHALL invalidate and join both presentation owners, clear predecessor content/cache/delivery state, and only then admit successor work even while either presentation is paused.

Store replacement SHALL synchronously clear predecessor Store-derived catalog rows and operation targets, revoke prepared delete/export and destination-selection authority, and deactivate both Store traversals. A Store-committed export SHALL retain its execution slot until authoritative completion. Explorer SHALL hold one rematerialization receipt until replacement change snapshot, first catalog pages, and bounded exact logical-ID lookup commit or a terminal Store failure commits an empty/failed catalog state. Catalog mismatch SHALL restart the bounded phase. Numeric row-ID reuse SHALL never preserve Event or Performance authority. Terminal failure SHALL retain logical selection only, compile no executable query/target, and SHALL NOT become Live, all Devices, or a nearby Device.

One coordinator and gateway generation SHALL retain at most one Event traversal and one Performance traversal. The generation's existing bounded operation queue and SQLite reader SHALL serialize all actual work. Event replace/end SHALL affect only Event traversal; Performance replace/end SHALL affect only Performance traversal. Discarded completion, refresh, range change, pause, reveal, or window close from one surface SHALL NOT end or retarget the other surface's traversal. Store replacement and shutdown SHALL cancel and join both.

Performance raw reveal SHALL pass only source generation and a metric-contributing journal key. The coordinator SHALL validate source, release only the Performance traversal while retaining the completed Performance presentation and its memory reservations, refresh the retained Event traversal snapshot, resolve exact durable or still-live identity through the serialized gateway, and ask the active Explorer to preflight and atomically perform its ordinary bounded reveal. Durable acceptance SHALL asynchronously load and validate the exact detail before mutating selection or Inspector; transient acceptance SHALL validate one live snapshot before mutation. A paused Event presentation SHALL retain its frozen Timeline rows and Pause state while a bounded snapshot-only replacement admits the exact detail request. Snapshot preparation and exact reveal acceptance SHALL return explicit success authority, and Main SHALL focus only after both authorities succeed and the coordinator revalidates its transition revision and target. Deleted, evicted, stale, unavailable, missing-detail, superseded, or finally rejected identity SHALL preserve the prior Event selection and Inspector, show fixed guidance in Performance without focusing Main, and SHALL not choose a nearby row. Superseding window, Device, range, Store, raw-request, or shutdown transitions SHALL cancel and join the pending exact-detail preflight. No JSON, metric, bucket, tooltip, availability text, or renderer object SHALL cross. Performance MAY resume exactly one fresh projection for the unchanged scope after reveal while the main Event presentation remains intact; if Performance is paused, it SHALL retain its completed presentation and defer that successor until Resume.

Presentation Pause SHALL freeze refresh only for an unchanged Performance Device/range. A paused range change clears crosshair/tooltip, records desired range, starts no traversal, and Resume starts one fresh projection. Reveal while paused is allowed only for the unchanged frozen scope. The dashboard SHALL remain separate from Renderer Registry; numeric and `chart.*` renderers SHALL not claim its multi-Event aggregation/current-card ownership.

#### Scenario: Performance opens while Events is active

- **WHEN** Event traversal and Inspector state are active and the operator opens Performance
- **THEN** Performance acquires only its bounded traversal through the shared serialized queue
- **AND** Event filtering, selection, paging, detail, and visible presentation remain active and intact

#### Scenario: Metric-specific raw Event is revealed

- **WHEN** a selected CPU accumulator resolves to a still-valid journal key
- **THEN** Performance releases only its traversal and Explorer opens exactly that Event in the main window
- **AND** Performance remains open and may resume without selecting a synthesized bucket or different contributor

#### Scenario: Performance Device changes while presentation is paused

- **WHEN** another exact Performance Device is selected while old charts are frozen
- **THEN** old Performance content and raw identities clear before successor admission
- **AND** the Event Device filter, Timeline, selection, and Inspector do not change

#### Scenario: Replacement Store reuses numeric row IDs

- **WHEN** a replacement Store assigns predecessor recording and device row IDs to different logical identities
- **THEN** Explorer clears predecessor catalogs before replacement I/O begins
- **AND** neither Event nor Performance admits successor work until exact replacement catalogs commit
- **AND** reused rows cannot become prior targets

#### Scenario: Selected Performance Device is absent from the replacement Store

- **WHEN** the selected Performance logical Device does not exist after rematerialization
- **THEN** bounded exact lookup completes before replacement admission
- **AND** Performance clears the invalid choice, applies the documented sole-Event or sole-available fallback when exact, and otherwise requests an explicit Device without changing Event scope

#### Scenario: Prepared operation crosses Store replacement

- **WHEN** delete confirmation, export disclosure, destination selection, or either traversal belongs to the predecessor Store
- **THEN** replacement revokes that authority before replacement rows are exposed
- **AND** an already Store-committed export retains its execution slot and publishes authoritative completion exactly once

### Requirement: Viewer presents one current-Session Event workspace

The main Viewer window SHALL present one native current-Session Event workspace with a top Devices strip, a stable Event Timeline/Inspector region, and an optional bottom Viewer-to-App composer. It SHALL NOT expose a Sources sidebar, historical recording browser, Analysis mode picker, or embedded Performance dashboard. Events SHALL default to All Devices and MAY select up to 16 Device logical IDs. Device selection SHALL remain logical when durable storage is temporarily unavailable and SHALL rematerialize only exact current-Session identities.

The Devices strip SHALL expose bounded horizontally scrollable Device rows, All Devices, selected state, connection state, Device settings, and pending approvals without Event content. A Device row action SHALL update Event scope and the Device-details target without treating that row as a Source or mutating the independent Performance Device selection.

#### Scenario: Current runtime has no durable recording

- **WHEN** the working Store is unavailable but live committed Events exist
- **THEN** the current Session remains selected and bounded live rows remain filterable
- **AND** no historical Source or invented durable identity appears

#### Scenario: Operator selects several Event Devices

- **WHEN** the operator selects two current-Session Device logical IDs in the main window
- **THEN** Events show the merged bounded lanes for exactly those Devices
- **AND** an existing valid Performance Device selection remains unchanged

### Requirement: Workspace panels are independently visible and stable

The top Viewer header SHALL provide a labeled Performance-window button followed by independent Timeline, Inspector, and Composer visibility buttons. Each SHALL expose icon, selected state where applicable, tooltip, accessibility label/value, keyboard focus, and enabled state without relying only on color. Performance SHALL open or focus exactly one auxiliary window. Timeline, Inspector, and Composer buttons SHALL remain enabled whenever the main workspace is ready because Performance no longer replaces those regions.

The main Viewer SHALL render Timeline-only, Inspector-only, both through one stable native horizontal split, or a bounded empty explanation when neither is visible. Composer visibility SHALL add or remove the bottom region through one stable native vertical split. Hiding a panel or opening Performance SHALL NOT clear capture, filters, selection, Inspector state, composer draft, Event traversal, or Performance state. Panel preferences SHALL NOT persist beyond the process.

#### Scenario: Operator opens Performance and hides Inspector

- **WHEN** Performance is open and the operator toggles Inspector in the main window
- **THEN** both windows remain responsive and only the main Inspector region changes visibility
- **AND** Performance Device, range, pause, cards, and charts remain unchanged

#### Scenario: Raw reveal targets a hidden Inspector

- **WHEN** Performance resolves an exact raw Event while Inspector is hidden
- **THEN** the main window is focused or reopened and Inspector becomes visible for that exact Event
- **AND** the Performance window stays open

#### Scenario: Both Event panels are hidden

- **WHEN** Timeline and Inspector are both hidden
- **THEN** the main Event region presents compact guidance and top visibility controls remain reachable
- **AND** Event capture and both bounded traversal owners remain unaffected

### Requirement: SwiftUI publication is region scoped and animation safe

Main header, Devices, Timeline, Inspector, composer/layout, Performance window shell, and Performance dashboard SHALL use stable region identity and region-specific Equatable publication signatures. A source publication SHALL invalidate only regions whose visible signature changed. Timeline Event arrival SHALL NOT publish Inspector, composer/layout, or Performance-window shell changes when their visible values are unchanged. Performance refresh SHALL NOT reconstruct the main split container. Equivalent session snapshots SHALL be coalesced.

Data-only Timeline and Performance refresh SHALL preserve stable row/card/chart identities, scroll ownership, split positions, selection, and completed presentation and SHALL disable implicit insertion/removal/layout animation. UI refresh SHALL remain capped by existing bounded cadences and perform no Event-proportional work in either window root.

#### Scenario: High-frequency Events arrive with both windows open

- **WHEN** Events arrive faster than the UI cadence and selection/detail and Performance target do not change
- **THEN** Timeline publishes at most the bounded cadence while Inspector, main layout, and Performance-window shell publication counts do not increase
- **AND** rows, dividers, selected detail, cards, and charts do not flash through empty or animated intermediate states

#### Scenario: Performance refresh completes

- **WHEN** a new bounded Performance projection replaces the prior complete result
- **THEN** only dashboard presentation regions with changed semantic values update
- **AND** the main header, Devices strip, Timeline split, Inspector, and composer layout are not reconstructed

## RENAMED Requirements

- FROM: `### Requirement: Events and Performance share source identity and one traversal owner`
- TO: `### Requirement: Events and Performance share one Session with coordinated traversal access`
