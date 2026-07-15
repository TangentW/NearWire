## Why

The Viewer product now owns only one process-lifetime Session, so opening a process-scoped SQLite database for that Session adds storage lifecycle, status, cleanup, and transient-to-durable reconciliation that the product no longer needs. It also causes each newly received Event to move through multiple presentation states, which contributes to visible flashing in the Event and Performance surfaces.

The Viewer-to-App composer also embeds AppKit text editors in SwiftUI. The editor document view is initially created at zero size and is not resized by the scroll container's first layout pass, so the Event type field can exist in the hierarchy without a reliable clickable editing area.

## What Changes

- Make the production Viewer runtime memory-only. It does not create, open, query, clean, recover, or close a SQLite database and does not expose local-database settings or status.
- Retain one bounded in-memory current Session for Timeline, Inspector, filtering, Clear, Performance, and explicit JSON import/export. No Session or Source is recovered on another launch.
- Remove transient database-reconciliation presentation states and storage-unavailable diagnostics from the memory-only path.
- Publish Event and Performance updates only when visible data changes, keep stable view identity, and avoid temporary loading/layout branches while an existing presentation remains visible.
- Make native bounded text editors resize with their SwiftUI scroll container and verify that the composer Event type editor has a nonzero hit target and accepts edits at supported window sizes.

## Capabilities

### New Capabilities

- `viewer-memory-session`: one bounded process-lifetime Session provides in-memory Event retention, Clear, filters, details, Performance input, and explicit JSON transfer without a local database.

### Modified Capabilities

- `viewer-local-store-search`: remove the production Viewer database, retention, cleanup, catalog, and storage-status requirements that no longer apply.
- `viewer-event-explorer-control`: current-Session presentation is memory-backed, high-frequency refresh is visually stable, and the Viewer-to-App Event type field remains editable.
- `viewer-performance-dashboard`: refresh retains one stable presentation and publishes only completed visible data changes.
- `viewer-application-foundation`: the Viewer runtime and shutdown lifecycle no longer own a working Store.

## Impact

This change affects Viewer runtime composition, current-Session transfer and Clear behavior, Event/Performance presentation publication, the native text-input bridge, Viewer documentation, and Viewer tests. It does not change the wire protocol, TLS, Bonjour, SDK public API, Event validation limits, package products, or Viewer connection limits.
