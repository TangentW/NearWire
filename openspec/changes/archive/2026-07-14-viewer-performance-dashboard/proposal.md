## Why

NearWire already records validated `nearwire.performance.snapshot` Events, but the Viewer exposes
them only as ordinary JSON. Operators need a bounded, single-device analysis surface that aligns
current values and charts without creating a second source of truth or treating unavailable data as
zero.

## What Changes

- Add a native Viewer Performance page for one exact current or historical device session.
- Decode the existing Core V1 performance schema from raw durable or bounded transient Events while
  preserving the original Event as the only authoritative record.
- Move the closed 16-key performance inventory from SDK-internal duplication into the existing Core
  internal SPI so SDK collection and Viewer projection consume one schema-owned vocabulary.
- Present current metric cards, synchronized charts, explicit unavailable states, durable/live gaps,
  and 1-minute, 5-minute, 15-minute, and current-session ranges.
- Stream raw snapshot rows through a generation-bound Store facade and compute bounded
  min/max/average time buckets off the MainActor. Keep only rebuildable in-memory projection data;
  add no SQLite schema, derived-content table, or second persistent store.
- Let an operator open the exact raw Event nearest a chart selection in the existing Event Explorer.
- Integrate Performance into the current single-window workspace while preserving the single
  session manager, Store owner, and Event Explorer controller.
- Keep multi-device chart overlays, custom metric formulas, alerts, MetricKit reports, persisted
  dashboard state, and export of derived buckets outside V1.

## Capabilities

### New Capabilities

- `viewer-performance-dashboard`: Defines the single-device performance scope, typed projection,
  current cards, synchronized bucketed charts, gap/unavailable semantics, raw-Event traceability,
  bounded refresh and cleanup, accessibility, privacy, and UI behavior.

### Modified Capabilities

- `viewer-local-store-search`: Adds one bounded generation-bound raw performance-Event traversal for
  exact recording/device/range/upper-bound scopes without changing schema version 2 or persisting a
  derived projection.
- `viewer-event-explorer-control`: Adds source/selection handoff between Performance and the Event
  Explorer, exact raw-Event reveal, and shared generation/cleanup ownership without implementing the
  dashboard through the renderer registry.
- `viewer-multidevice-flow-control`: Replaces the Performance-page deferral with single-device
  Performance navigation while keeping safe device rows content-free and multi-device overlays
  deferred.
- `performance-snapshot-schema`: Adds the closed ordered 16-key metric inventory to Core's existing
  `NearWireInternal` SPI without exposing it as public App API or changing encoded JSON.

## Impact

- Viewer production changes under `Viewer`, one shared inventory move from SDK internals to Core SPI,
  SDK/Core regression tests, Viewer tests, and English operator documentation.
- Reuse of the internal Core `PerformanceSnapshot` SPI; no public SDK API or wire-format change.
- No root-package dependency, third-party runtime dependency, new entitlement, SQLite migration,
  additional persistence, or CocoaPods/SPM product change.
- macOS 13 and Swift 5 language-mode compatibility remain required. Swift Charts may be used as the
  system UI framework; it is not a package dependency.
- Configured signing and embedded-entitlement validation remain deferred by product-owner decision
  to Goal-level `release-hardening`.
