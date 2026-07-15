## Context

The Viewer already maintains a bounded live projection with stable Event identity, exact Event content, Device metadata, diagnostics, and Performance snapshots. The production runtime currently duplicates that data into a unique process-scoped SQLite Store. Explorer refresh then reconciles a transient row with a durable row, while Store status and cleanup remain active even though no historical Source is user-visible.

SwiftUI is not inherently unable to render this workload smoothly. The visible flashing comes from avoidable publication and identity changes:

- Timeline publishes a retained `loading` state before live evaluation and a second `ready` state after the same refresh.
- Performance publishes `loading(retainsPresentation: true)`, swaps a notice branch, publishes progress, and then publishes the completed projection.
- database reconciliation can replace the representation of the same logical Event.
- the AppKit editor's document view is sized during `makeNSView` while its enclosing SwiftUI scroll view still has zero content size.

## Goals and Non-Goals

Goals:

- Ensure the production Viewer opens no local database and writes no Session/Source database files.
- Keep one explicitly bounded in-memory Session usable for Timeline, Inspector, filters, Clear, Performance, and JSON transfer.
- Make ordinary Event arrival update only semantically changed Event or Performance content without replacing layout branches or view identity.
- Keep the composer Event type editor visibly sized, hit-testable, focusable, and editable.

Non-goals:

- Preserve multi-million-Event database retention, database-backed pagination, database cleanup, pinning, annotations, or historical catalogs.
- Change network flow control, Event payload limits, pairing, TLS, or SDK behavior.
- Add a server, cloud persistence, another local persistence engine, or a third-party dependency.
- Redesign the Viewer information architecture beyond the affected surfaces.

## Decisions

### Production runtime uses the existing bounded live projection as Session authority

`ViewerRuntimeDependencies.live` constructs runtime components without `ViewerStoreRuntime`, process workspace paths, or an installed Store gateway. A memory-only journal acknowledges that the live projection is the final local authority and never emits Store-unavailable state. Application startup and termination do not load storage configuration, observe storage status, run cleanup, retry storage, or close/remove a working Store.

The current in-memory limits remain explicit: at most 512 retained Events, 32 MiB of accounted Event data, 16 Device-session metadata lanes, and the existing bounded ingress. Oldest Event eviction is visible as an in-memory-window gap. These are product memory bounds, not database retention settings. Closing the runtime clears all received content.

Legacy Store implementation and focused Store tests may remain in the repository as non-production compatibility code during this narrow change, but no production runtime composition may instantiate or call it.

### Clear and JSON transfer operate on one memory snapshot

Clear establishes one serialized workspace boundary, clears retained Event/detail/diagnostic/Performance content, and preserves active connections and their Device lanes. Success is reported only after the replacement memory snapshot is published.

Complete-Session JSON export freezes one immutable copy of the retained memory snapshot. Export remains explicitly unencrypted and destination-selected; it includes only content currently retained by the bounded Session and never claims database completeness. Import remains allowed only with no active, disconnecting, or approval-pending App. It validates the supported complete-Session schema and memory bounds before atomically replacing the inactive Session. An over-limit or invalid file changes nothing. Import/export files are explicit user-selected transfer artifacts, not local Viewer persistence.

### Timeline publication represents visible state, not internal refresh phases

When Timeline already has rows, its visible signature excludes internal refresh-phase changes that do not affect rendered content. An ordinary refresh retains the existing list until the evaluated successor rows are ready. The row identity remains the Event journal key; no memory-to-database row replacement occurs. Data-only updates disable implicit animation for the Timeline container and rows.

Because every current-Session Event now has the same memory-only lifetime, Timeline rows do not repeat an "In memory" badge. Session-level copy communicates that lifetime once. The normal `consumerAccepted` pipeline disposition is also omitted from rows; badges remain available for outcomes and diagnostics that require operator attention. Full Event detail may retain the disposition as technical metadata.

The primary Timeline line is a bounded 256-byte UTF-8 prefix of the canonical compact Event JSON, followed by an ellipsis when truncated and constrained to one rendered line. Event type moves into the secondary metadata line without headline emphasis. Preview derivation runs outside SwiftUI and reads at most the bounded prefix, so body evaluation never converts a complete large payload.

The Explorer may still use internal loading and cancellation states for correctness. Those states publish visible loading UI only when no prior rows exist or when an error/paused state changes what the operator sees.

### Performance publishes completed successor presentations

When a complete Performance publication already exists, beginning or progressing a refresh updates internal operation state without publishing an intermediate loading presentation. The last complete cards, charts, notice, scroll position, and chart identity remain unchanged. Applying a valid successor publishes once. Initial load, explicit scope replacement, pause/resume, failure, and empty states remain visible and accessible.

Charts continue to rebuild bounded projection values when completed data changes, but stable chart-group and metric identifiers prevent container replacement. No implicit animation is attached to data refresh.

### Native editor owns layout-time document sizing

The bounded input uses a dedicated `NSScrollView` subclass that resizes its `ViewerOperatorTextView` document during every AppKit layout pass. A single-line editor fills the clip view in both dimensions. A multiline editor tracks clip width and grows vertically while preserving scrolling. Sizing no longer depends on the zero frame passed to `makeNSView`.

Tests render the composer at the supported minimum workspace size and a compact fallback width, locate the Event type editor by accessibility label, assert a meaningful frame and hit-test result, make it first responder, apply a real edit, and verify the controller receives the value.

## Risks and Mitigations

- Removing SQLite reduces retained history. The UI and documentation state the exact bounded memory behavior and export only the retained snapshot.
- Clear can race ingress. The existing workspace mutation gate defines the boundary and successor Events remain admitted after the clear snapshot.
- Import can allocate untrusted content. File, Device, Event, and accounted-byte bounds are checked before replacement; failure is atomic.
- Suppressing intermediate publications could hide progress. Initial loading still publishes; only refresh progress that retains an already complete visible presentation is suppressed.
- A custom scroll view could regress multiline sizing. Focused AppKit layout tests cover single-line and multiline behavior at compact and normal sizes.

## Verification

- Runtime tests prove production component creation does not create a process workspace or invoke Store lifecycle callbacks.
- Memory-session tests cover Event retention, Clear, detail/filter/Performance input, bounded JSON export/import, invalid/over-limit rollback, and cleanup.
- Event presentation tests count visible-signature publications across burst refreshes and verify stable row identity with animation disabled.
- Performance tests prove retained refresh start/progress publishes no visible revision and a completed successor publishes exactly once.
- Composer layout tests verify frame, hit testing, first responder, and actual Event type editing at supported sizes.
- Full Viewer tests, strict-concurrency build, Viewer build, strict OpenSpec validation, and a focused visual inspection provide final evidence.
