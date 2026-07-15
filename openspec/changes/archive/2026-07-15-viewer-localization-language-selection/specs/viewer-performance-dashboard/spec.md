## MODIFIED Requirements

### Requirement: Performance UI is accessible, privacy-aware, and fully cleared

The native singleton macOS Performance window SHALL use an accessible exact-Device picker, scalable current cards, a fixed 16-key availability section, six bounded system Charts views, fixed ranges, one synchronized pointer/keyboard crosshair, aggregate tooltip, representative raw action, Show Viewer action, and localized runtime/device/empty/loading/live-only/unavailable/error guidance in English and Simplified Chinese. State SHALL not rely on color. Accessibility SHALL combine localized metric, unit, Viewer time, statistics, discontinuity, and availability within the 64-summary-per-chart cap.

User-visible numbers, percentages, byte counts, durations, dates, and list phrases SHALL use the effective Viewer locale without changing metric calculation, bucket ordering, range bounds, Store queries, cache keys, wire values, or exported data. Metric protocol keys and received values SHALL remain stable; Viewer display names and state descriptions SHALL be localized.

The Performance Device selection SHALL be independent of the main Event multi-selection. On first open or after invalidation it SHALL prefer an exact sole Event selection when still available, otherwise the sole available Device, otherwise explicit no selection. A valid existing choice and range SHALL remain in process memory across Performance-window close/reopen and SHALL not persist across process launch. Changing the Performance Device SHALL clear predecessor content and work without changing Event scope or Inspector state. Changing language SHALL preserve Device, range, pause, cards, chart identity, crosshair identity, raw locator, and active projection while updating presentation text and locale-aware formatting.

Received values SHALL have no copy, cut, drag, share, clipboard-export, preference, restoration, recent-row, safe-status-row, log, analytics, or content-bearing reflection sink. Closing Performance SHALL cancel/join active projection/reveal/deadline work, release Performance traversal, and clear received metric values, buckets, tooltip, accessibility values, cache, locators, and delivery state without altering Event presentation. Runtime end, listener failure, TLS/full reset, Store replacement, deinitialization, and claimed-delivery cleanup SHALL additionally clear all coordinator selection/content state before the existing receipt completes. Unsealed controller deinitialization SHALL synchronously seal any externally retained model and transfer cancellation/join receipts and required owners to a detached cleanup owner until all work and charged memory reach zero.

#### Scenario: Performance language changes with a chart visible

- **WHEN** one exact Device, range, cards, charts, and tooltip are visible and the operator changes language
- **THEN** Viewer-owned titles, states, guidance, tooltip phrases, formatting, and accessibility summaries update to the new locale
- **AND** the projection generation, Device, range, pause state, contributing Event identities, and metric values remain unchanged

#### Scenario: Performance opens with several Devices and no exact suggestion

- **WHEN** several Devices exist and Event scope is All Devices or multi-selected
- **THEN** the Performance window presents localized Choose a Device guidance and starts no projection traversal
- **AND** choosing one Device does not change Event scope

#### Scenario: Performance window closes and reopens

- **WHEN** the operator closes Performance and later reopens it during the same runtime
- **THEN** prior received metric content and active work are absent while the valid Device and range controls are restored in the effective language
- **AND** one fresh bounded projection starts without disturbing Event state

#### Scenario: Claimed chart delivery races cleanup

- **WHEN** cleanup begins after a chart result claimed MainActor delivery
- **THEN** cleanup waits until that exact result is discarded and every received Performance value is cleared
- **AND** Event traversal, selection, and Inspector remain authoritative unless the whole runtime is ending
