# Change: Remove Viewer database implementation

## Why

The Viewer now owns one bounded process-lifetime memory Session. Keeping the former SQLite Store, SQL schema, Store gateway, database maintenance, and database-focused tests adds roughly thirty thousand lines of unreachable implementation, obscures the actual product architecture, and leaves obsolete UI behavior such as a causality view that can only query durable rows.

## What Changes

- Delete the Viewer SQLite implementation, SQL schema and queries, Store lifecycle/gateway/maintenance/export code, bridging header, SQLite linkage, and database-only tests.
- Move the small platform-neutral contracts still required by the memory Session into memory-focused Application or Session files and rename database-derived types where they remain user-visible in code.
- Simplify Event and Performance controllers to consume only bounded memory snapshots; remove durable catalog, pagination, rematerialization, database recovery, and Store traversal paths.
- Remove the Inspector Causality tab and its operation state because cross-Event database traversal no longer exists.
- Retain the bounded Renderer tab because it transforms the selected in-memory Event into useful log, table, numeric-series, timeline, or Generic JSON presentations without persistence.
- Remove or rewrite database documentation and stale database references in active specifications.

## Impact

- Viewer runtime and test targets no longer link SQLite or compile a bridging header.
- Viewer keeps current-Session Timeline, filters, Inspector metadata/raw/tree/pretty/renderer views, Performance, Clear, JSON import/export, and Viewer-to-App composition.
- There is no historical catalog, durable pagination, database causality graph, database recovery, or database test suite.
