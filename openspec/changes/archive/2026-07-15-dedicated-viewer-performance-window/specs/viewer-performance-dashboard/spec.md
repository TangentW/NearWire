## MODIFIED Requirements

### Requirement: Events and Performance reveal metric-specific raw identity through coordinated traversals

Every measured accumulator SHALL carry a contributing journal key and source generation. Live-to-durable reconciliation SHALL update only its locator. Open Raw Event SHALL resolve the selected metric's key at action time, preferring exact durable then still-live. Deleted, evicted, stale, or unresolvable keys SHALL show fixed guidance and SHALL not choose a neighbor. No JSON, metric, bucket, tooltip, or renderer object SHALL cross controllers; derived buckets SHALL not export.

One coordinator SHALL serialize lifecycle transitions while the shared Store gateway retains one bounded Event traversal and one bounded Performance traversal under one serialized operation queue. Opening Performance SHALL NOT invalidate Event query/detail work, clear Inspector, or replace the main window. Performance close, range replacement, refresh, or discarded completion SHALL release only Performance traversal. Store replacement and shutdown SHALL cancel and join both traversal owners. Raw reveal SHALL validate source, release Performance traversal while retaining the last complete dashboard presentation and its memory reservations, refresh the retained Event traversal snapshot, resolve and preflight the exact identity and durable detail through the still-active Explorer, focus the main window only after exact reveal succeeds, restore Inspector visibility, and resume exactly one Performance projection for the unchanged scope when allowed. If Event presentation is paused, refresh SHALL replace only the bounded Store snapshot, preserve the frozen Timeline and Pause state, and report failure instead of publishing a false reveal. Failed preparation, resolution, missing durable detail, or final Explorer acceptance SHALL preserve the prior Event selection and Inspector and retain Performance focus for its fixed guidance. Superseding window, Device, range, Store, raw-request, or shutdown transitions SHALL cancel and join a pending exact-reveal preflight and SHALL revalidate revision and target after any awaited acceptance. A paused Performance presentation SHALL retain its immutable presentation without a projection successor until Resume. At most one traversal per surface SHALL be retained.

#### Scenario: Aggregated CPU bucket opens source

- **WHEN** CPU contributors differ from FPS contributors and the operator opens the CPU series
- **THEN** Viewer resolves CPU's deterministic contributing key and selects exactly that raw Event in the main window
- **AND** it never opens the bucket-wide or nearest unrelated Event
- **AND** the Performance window remains open with its Device, range, and pause state unchanged

#### Scenario: Events refresh during Performance traversal

- **WHEN** Events and Performance both request bounded Store work
- **THEN** one operation queue serializes actual SQLite access while retaining no more than one traversal per surface
- **AND** completion or cancellation from either surface cannot release or retarget the other traversal

### Requirement: Performance UI is accessible, privacy-aware, and fully cleared

The native singleton macOS Performance window SHALL use an accessible exact-Device picker, scalable current cards, a fixed 16-key availability section, six bounded system Charts views, fixed ranges, one synchronized pointer/keyboard crosshair, aggregate tooltip, representative raw action, Show Viewer action, and deterministic English runtime/device/empty/loading/live-only/unavailable/error guidance. State SHALL not rely on color. Accessibility SHALL combine metric, unit, Viewer time, statistics, discontinuity, and availability within the 64-summary-per-chart cap.

The Performance Device selection SHALL be independent of the main Event multi-selection. On first open or after invalidation it SHALL prefer an exact sole Event selection when still available, otherwise the sole available Device, otherwise explicit no selection. A valid existing choice and range SHALL remain in process memory across Performance-window close/reopen and SHALL not persist across process launch. Changing the Performance Device SHALL clear predecessor content and work without changing Event scope or Inspector state.

Received values SHALL have no copy, cut, drag, share, clipboard-export, preference, restoration, recent-row, safe-status-row, log, analytics, or content-bearing reflection sink. Closing Performance SHALL cancel/join active projection/reveal/deadline work, release Performance traversal, and clear received metric values, buckets, tooltip, accessibility values, cache, locators, and delivery state without altering Event presentation. Runtime end, listener failure, TLS/full reset, Store replacement, deinitialization, and claimed-delivery cleanup SHALL additionally clear all coordinator selection/content state before the existing receipt completes. Unsealed controller deinitialization SHALL synchronously seal any externally retained model and transfer cancellation/join receipts and required owners to a detached cleanup owner until all work and charged memory reach zero.

#### Scenario: Performance opens with several Devices and no exact suggestion

- **WHEN** several Devices exist and Event scope is All Devices or multi-selected
- **THEN** the Performance window presents Choose a Device and starts no projection traversal
- **AND** choosing one Device does not change Event scope

#### Scenario: Performance window closes and reopens

- **WHEN** the operator closes Performance and later reopens it during the same runtime
- **THEN** prior received metric content and active work are absent while the valid Device and range controls are restored
- **AND** one fresh bounded projection starts without disturbing Event state

#### Scenario: Claimed chart delivery races cleanup

- **WHEN** cleanup begins after a chart result claimed MainActor delivery
- **THEN** cleanup waits until that exact result is discarded and every received Performance value is cleared
- **AND** Event traversal, selection, and Inspector remain authoritative unless the whole runtime is ending

## RENAMED Requirements

- FROM: `### Requirement: Events and Performance hand off metric-specific raw identity under one arbiter`
- TO: `### Requirement: Events and Performance reveal metric-specific raw identity through coordinated traversals`
