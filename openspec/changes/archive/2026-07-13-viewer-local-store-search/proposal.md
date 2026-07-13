## Why

The Viewer now receives and sends bounded Events across up to 16 independent device sessions, but all Event data disappears when memory queues drain or the window closes. The product requires automatic Mac-local history, predictable disk retention, consistent live/history search, and JSON export without adding a server or moving persistence into the iOS SDK. This change adds that data foundation before the later event-explorer UI is built.

## What Changes

- Add a Viewer-only SQLite store backed by the system `SQLite3` library. Keep the root Swift Package and SDK dependency graph unchanged.
- Create one stable logical recording context for each live Viewer runtime and conditionally materialize durable recording/device rows only after causal store admission. Explicitly reconcile prior-process open rows and represent unavailable intervals as bounded gaps rather than inventing history.
- Persist immutable validated App-to-Viewer Events plus append-only final-disposition transitions, and persist successfully mailbox-admitted Viewer-to-App Events as transport-admitted only.
- Add a bounded, nonblocking store ingress with reserved structural lifecycle capacity and finite writer transactions so SQLite latency, capacity exhaustion, or failure cannot block a device protocol executor. Coalesce persistence gaps when Event observations cannot be saved.
- Add versioned storage preferences with defaults of 3 GiB capacity and seven days of `historyRetention`, plus bounded editable values and safe corruption recovery.
- Implement bounded whole-session cleanup. A small transaction atomically tombstones complete eligible sessions using deterministic quota accounting; finite child/FTS batches reclaim physical rows later. Expired closed unpinned sessions are selected first, capacity cleanup targets 85%, and active, pinned, or read-leased sessions are protected.
- Pause new disk writes when protected data prevents reclamation or the store enters a write-failed state, while preserving bounded real-time operation and an actionable safe status. Resume only after a successful explicit retry or a configuration/data change makes writing safe.
- Add indexed full-text search, validated parameter-bound JSON path predicates, exact literal text operators, stable keyset pagination, bounded reader work/cancellation, finite read leases, point event loading, and a latest-only change notification seam.
- Add streaming schema-versioned JSON export through a dedicated short-transaction reader, append-only frozen bounds, one finite deletion-protection lease, stored alias ordinals, and no full-result or alias-map materialization.
- Add a native storage settings/status surface for capacity, retention, usage, oldest history, pinned usage, estimated retention, and safe store errors. Event timeline/detail, renderer, pin/delete history browsing, export selection, and Viewer-to-App composition remain in the next change.
- Add deterministic database, cleanup, query, export, lifecycle, UI, packaging, and failure-injection coverage plus English documentation and saved evidence.

## Capabilities

### New Capabilities

- `viewer-local-store-search`: Viewer-local session persistence, retention and capacity enforcement, indexed search/filtering, stable pagination, storage status/settings, and streaming JSON export.

### Modified Capabilities

- `viewer-multidevice-flow-control`: Add a bounded persistence observation seam for validated uplink outcomes, committed downlink mailbox admission, policy/drop samples, and exact device-session lifecycle while keeping persistence failures outside protocol terminal decisions.

## Impact

The change affects only the macOS Viewer implementation, its manually maintained Xcode project, Viewer tests, Viewer documentation, and OpenSpec artifacts. It links the system SQLite library but adds no third-party package, nested manifest, server, cloud component, entitlement, wire-schema change, Core/SDK runtime dependency, or supported SDK API. The database and export files contain user Event content and are intentionally local, nonencrypted V1 artifacts protected by the Viewer sandbox and normal filesystem permissions.
