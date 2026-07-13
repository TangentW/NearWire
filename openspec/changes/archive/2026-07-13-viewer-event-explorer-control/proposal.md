## Why

The Viewer can now exchange Events with up to 16 Apps and persist bounded local history, but an
operator still cannot inspect that history, correlate requests and replies, search live and older
Events, manage recordings, export a selected result, or compose a Viewer-to-App control Event from
the native application. This change turns the existing protocol and store foundations into the V1
event-analysis workspace without adding a server, changing the wire protocol, or moving Viewer UI
concerns into Core or the iOS SDK.

## What Changes

- Replace the current two-pane device workspace with the planned single-window three-column Event
  Explorer plus a bottom Viewer-to-App control composer. Preserve pairing, approval, device,
  storage, and identity controls in the same application.
- Add bounded recording and device catalogs so the operator can choose the current live context or
  one historical recording, then view one device, up to 16 selected devices, or all devices in that
  recording. V1 does not merge different recordings.
- Route all explorer work through the process-lifetime store runtime with coordinator-generation
  operation leases and one tokenized query arbiter. Migrate schema 1 to schema 2 only by adding the
  scoped Event-UUID and gap diagnostic indexes required for bounded catalog/causality plans.
- Drive live and historical timelines from the same validated query model and Viewer receive-time
  semantics, with FTS5 full text explicitly limited to durable rows. Use keyset pages and
  virtualized rows, display bounded gap diagnostics, and never request replay from an App.
- Add the complete V1 durable search/filter surface for device/App scope, exact or prefix Event
  type, direction, priority, receive time, literal content terms, safe JSON paths, and gap/drop
  presence. Transient rows use the documented non-FTS subset rather than guessed tokenization.
- Add a bounded live presentation window at the existing committed journal boundaries. It keeps
  the current workspace useful while storage is unavailable, reconciles with durable rows by the
  journal key rather than peer Event UUID, and cannot affect protocol or persistence ownership.
- Create one injectable runtime-components bundle per application runtime so admission handoff,
  typed control, manager generation, composite journal, live projection, explorer inputs, and
  cleanup all share the same explicit runtime identity with no concrete downcast.
- Add pause/resume for presentation refresh only. Networking, flow control, local persistence, and
  the bounded live window continue while paused; resuming creates a fresh query traversal instead
  of accumulating UI work.
- Add Event detail inspection with complete raw JSON, a bounded JSON tree, metadata and time
  semantics, ambiguity-safe causality lookup, and an internal renderer registry with Generic JSON,
  log, key-value, numeric-series, and timeline renderers. Generic JSON is always the fallback.
- Expose recording rename/note/pin/delete operations and complete/filtered JSON export through
  native UI. Preserve revision-bound delete confirmation and mandatory export disclosure.
- Add a simple multi-target control composer for Event type, JSON content, priority, TTL, and
  normal or keep-latest policy. Report only per-target local queue admission; do not claim App
  receipt or processing and do not add templates, favorites, or independent send history.
- Add deterministic presentation, query-lifecycle, renderer, live-window, composer, accessibility,
  integration, resource/heap/cadence/query-plan, and documentation coverage with saved validation
  evidence.

## Capabilities

### New Capabilities

- `viewer-event-explorer-control`: Native event exploration, detail rendering, history operations,
  export selection, pause semantics, and Viewer-to-App control composition.

### Modified Capabilities

- `viewer-local-store-search`: Add bounded recording/device catalogs and explorer-oriented detail,
  gap, causality, mutation, and export UI facades over the existing store.
- `viewer-multidevice-flow-control`: Compose the existing device workspace with the explorer and add
  bounded live-presentation observations plus typed per-target downlink admission results without
  transferring protocol ownership.

## Impact

The change affects only the macOS Viewer, its tests, Viewer documentation, and OpenSpec artifacts.
It may extend Viewer-internal store/query and session-manager facades, but it adds no public SDK
API, Core persistence or UI, wire message, database server, cloud service, third-party runtime
dependency, nested package manifest, entitlement, menu-bar process, import format, or performance
projection store. The dedicated performance dashboard remains the next change.
