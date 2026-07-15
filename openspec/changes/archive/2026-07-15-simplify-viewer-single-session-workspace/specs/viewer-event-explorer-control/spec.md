## MODIFIED Requirements

### Requirement: Viewer presents one current-Session Event workspace

The Viewer SHALL present one native current-Session workspace with a top Devices strip, a central Analysis region, and an optional bottom Viewer-to-App composer. It SHALL NOT expose a Sources or historical recording sidebar. Events SHALL default to All Devices and MAY select up to 16 Device logical IDs; Performance SHALL retain its existing exactly-one-Device requirement. Device selection SHALL remain logical when durable storage is temporarily unavailable and SHALL rematerialize only exact current-Session identities.

The Devices strip SHALL expose bounded horizontally scrollable Device rows, All Devices, selected state, connection state, Device settings, and pending approvals without Event content. A Device row action SHALL update Event scope and the Device-details target without treating that row as a Source.

#### Scenario: Current runtime has no durable recording

- **WHEN** the working Store is unavailable but live committed Events exist
- **THEN** the current Session remains selected and bounded live rows remain filterable
- **AND** no historical Source or invented durable identity appears

#### Scenario: Operator selects several Devices

- **WHEN** the operator selects two current-Session Device logical IDs
- **THEN** Events show the merged bounded lanes for exactly those Devices
- **AND** Performance continues to request one exact Device before scanning

## RENAMED Requirements

- FROM: `### Requirement: Viewer presents one three-column Event Explorer with an explicit recording scope`
- TO: `### Requirement: Viewer presents one current-Session Event workspace`

## ADDED Requirements

### Requirement: Current Session actions preserve one authoritative workspace

The Event Timeline toolbar SHALL expose Clear Events with a destructive confirmation. The top Session controls SHALL expose complete JSON Import and Export. Clear SHALL invoke the Store generation-safe operation and clear selected Event, inspector, gaps, and Performance presentation only after success. Import SHALL be disabled while any Device is active or pending and, after an atomic Store replacement, SHALL rematerialize Events, Devices, and Performance under one successor generation. Export SHALL freeze the complete current Session and retain the unencrypted disclosure.

No action SHALL create a second Source, recording-history row, or hidden Session. Stale pre-action page, detail, renderer, chart, or selection completion SHALL not update the successor presentation. Clear and import errors SHALL use fixed safe guidance without imported or Event content.

#### Scenario: Operator confirms Clear

- **WHEN** the current Session contains Events and the operator confirms Clear
- **THEN** Timeline, Inspector, diagnostics, and Performance reset after the Store commits
- **AND** connected Devices and later Events remain active in the same working Session

#### Scenario: Operator cancels Clear

- **WHEN** the destructive confirmation is dismissed
- **THEN** the Store, selection, Timeline, Inspector, and Performance remain unchanged

#### Scenario: Import replaces an inactive Session

- **WHEN** no Device is active or pending and a complete supported export commits
- **THEN** exactly one successor current Session presentation is materialized
- **AND** no predecessor row or transport capability survives as imported state

### Requirement: Workspace panels are independently visible and stable

The top Viewer header SHALL provide independent Timeline, Inspector, and Composer visibility buttons. Each SHALL expose icon, selected state, tooltip, accessibility label/value, keyboard focus, and enabled state without relying only on color. Timeline and Inspector buttons SHALL be disabled while Performance mode is active without losing their in-process choices; Composer SHALL remain available in both modes.

In Events mode the Viewer SHALL render Timeline-only, Inspector-only, both through one stable native horizontal split, or a bounded empty explanation when neither is visible. Composer visibility SHALL add or remove the bottom region through one stable native vertical split. Hiding a panel SHALL NOT clear capture, filters, selection, inspector state, composer draft, traversal, or Performance state. Panel preferences SHALL NOT persist beyond the process.

#### Scenario: Operator hides Inspector during Event arrival

- **WHEN** Inspector is hidden while new Events continue
- **THEN** Timeline updates within its normal cadence and Inspector state remains bounded but unrendered
- **AND** showing Inspector restores the exact still-resident selection without restarting capture

#### Scenario: Both Event panels are hidden

- **WHEN** Timeline and Inspector are both hidden in Events mode
- **THEN** Analysis presents compact guidance and the top visibility controls remain reachable
- **AND** no Event capture or query ownership is transferred to the placeholder

### Requirement: SwiftUI publication is region scoped and animation safe

Header, Devices, Timeline, Inspector, Performance, and composer/layout presentation SHALL use stable region identity and region-specific Equatable publication signatures. A source publication SHALL invalidate only regions whose visible signature changed. Timeline Event arrival SHALL NOT publish Inspector or composer/layout changes when their visible values are unchanged. Equivalent session snapshots SHALL be coalesced.

Data-only Timeline refresh SHALL preserve stable Event row identities, scroll ownership, split positions, and selection and SHALL disable implicit insertion/removal/layout animation. UI refresh SHALL remain capped by the existing ten-per-second cadence, keep bounded Timeline rows, and perform no Event-proportional work in the root header or Devices strip. Semantic state transitions such as explicit panel visibility or mode changes MAY animate only through short reduced-motion-aware transitions.

#### Scenario: High-frequency Events arrive with one selected Event

- **WHEN** Events arrive faster than the UI cadence and selection/detail do not change
- **THEN** Timeline publishes at most the bounded cadence while Inspector and workspace-layout publication counts do not increase
- **AND** rows, divider positions, and selected detail do not flash through empty or animated intermediate states

#### Scenario: Equivalent Device snapshot arrives

- **WHEN** only non-visible counters change for a Device chip
- **THEN** the Devices strip does not republish or reconstruct its scroll position
- **AND** Device details may still observe their separately scoped telemetry state
