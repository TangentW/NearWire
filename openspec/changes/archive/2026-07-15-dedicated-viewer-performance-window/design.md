## Context

The main Viewer currently renders a segmented Events/Performance mode inside `ViewerAnalysisWorkspacePane`. `ViewerAnalysisModeCoordinator` enforces that only the selected mode can own the Store traversal. Entering Performance deactivates Explorer work and clears Inspector state; returning to Events tears down Performance and reconstructs Explorer traversal. The Store gateway already serializes every operation and the Store lease registry supports multiple bounded query leases, but the gateway arbiter retains only one traversal of either kind.

A dedicated window should improve macOS multitasking, not leave the visible main window frozen or silently non-interactive. Performance also cannot keep borrowing the Event filter's zero-to-sixteen Device selection because the dashboard requires exactly one Device.

## Goals and Non-Goals

Goals:

- Keep the main Event workspace stable and interactive while Performance is open.
- Open or focus exactly one Performance window.
- Give Performance an independent, process-memory-only exact Device selection.
- Preserve one Store owner and one serialized execution queue while bounding retained traversal state to one per surface.
- Focus and reveal an exact raw Event in the main window without closing Performance.
- Keep runtime ownership valid when either window remains open.
- Preserve existing projection, privacy, clear/import generation, and cleanup guarantees.

Non-goals:

- Add multi-Device Performance overlays.
- Persist window frames, Performance Device choice, range, or pause state across process launches.
- Add a second Store, session manager, listener, runtime, query execution queue, or unbounded reader pool.
- Change Performance sampling, aggregation, charts, Event schema, transfer, or Session JSON.
- Add custom window chrome, a menu-bar process, or a project dependency.

## Decisions

### Performance is a singleton auxiliary Window

SwiftUI declares `Window("Performance", id: "performance")`, not `WindowGroup`, so repeated requests focus the same instance. The main header exposes a labeled `Performance` button with `chart.xyaxis.line`, help, accessibility label, keyboard focus, and a disabled runtime-not-ready state. The Performance window uses a default size of 1,100 by 760 points and a minimum of 800 by 600 points.

The main window contains no Analysis mode picker and always renders the stable Event split. Timeline, Inspector, and Composer visibility controls remain enabled because they always address visible or restorable main-window regions.

### Runtime follows application lifetime

The first supported window to appear, whether Main or Performance, idempotently starts the single runtime. Closing only the main window does not stop it while Performance remains open. Closing the last application window triggers the existing bounded application-termination cleanup. Reopening either window while the other remains open reuses the exact runtime generation. No window starts a second listener or working Session.

### Event and Performance traversals are independent but execution remains serialized

The existing gateway generation retains two optional logical traversal records: one Event traversal and one Performance traversal. Event replacement/end operations touch only the Event traversal; Performance replacement/end operations touch only the Performance traversal. The generation's existing bounded operation queue remains the sole execution authority, and the shared SQLite query reader continues serial execution. The Store lease registry already caps total query leases at eight; this design consumes at most two for the two visible analysis surfaces.

Store replacement, Clear, import, application shutdown, and generation invalidation cancel and join both traversal owners. Discarded Performance completion releases only its Performance traversal and cannot invalidate Event detail/query authority. No operation is allowed to smuggle content or mutable controller objects between surfaces.

### Performance owns an independent exact Device selection

The Performance coordinator stores one optional logical Device ID in process memory. On first open or after the prior Device disappears it chooses, in order: the main Event scope when that scope contains exactly one still-available Device, the only available Device in the Session, or no Device. Once Performance has a valid choice, later Event filter changes do not retarget it. The Performance window exposes a labeled menu picker and fixed empty guidance.

Changing the Performance Device cancels and joins only predecessor Performance work, clears chart/crosshair/raw identity state, and rebuilds against the exact new logical ID. It does not change Timeline scope, selected Event, Inspector, composer, or Device-details targeting. Range and Device choice remain in memory when the Performance window closes and reopens during the same process; received metric content and active work do not.

### Raw Event reveal keeps both workspaces intact

Open Raw Event first cancels and joins the active Performance projection traversal while retaining its source generation, memory reservations, and last complete immutable dashboard presentation. It resolves only the selected metric's contributing journal key through the serialized gateway, while the Event traversal remains authoritative. A successful exact reveal first refreshes the retained Event traversal snapshot, preflights a transient carrier or asynchronously loads and validates the exact durable detail without mutating Explorer, advances the shared latest Event-selection intent, makes Inspector visible, and only then focuses or reopens the main window. When Event presentation is paused, the refresh replaces only its bounded Store snapshot and leaves the frozen Timeline rows and Pause state unchanged. Preparation and reveal acceptance return explicit success authority; a failed refresh, resolution, missing detail, or final Explorer acceptance leaves the prior Event selection and Inspector unchanged and keeps focus in Performance so its guidance remains visible. Window close, Device/range change, Store replacement, a newer raw request, and shutdown cancel and join the exact-reveal preflight; the coordinator revalidates its transition revision and target after the awaited acceptance before publishing focus. Performance then resumes exactly one fresh bounded projection for its unchanged Device/range unless it is paused or the window closed. A paused Performance presentation retains its reservations and does not run a successor until the operator resumes it.

The Performance window stays open. Missing, evicted, stale, or replaced identities show fixed guidance and never select a neighbor. Raw JSON, metric values, buckets, tooltip content, and renderer objects never cross controllers.

### Publication remains surface scoped

The main root no longer observes Performance mode to replace its central tree. The Performance window root observes only runtime/coordinator identity; the dashboard observes the existing bounded model and coordinator publications. Device-option and raw-reveal revisions are small Equatable publications. Event arrival cannot reconstruct the Performance Scene or the main split container, and Performance refresh cannot republish the main workspace layout.

## Risks and Mitigations

- Two retained query leases could increase Store pressure. The hard bound is two surface leases under the existing global cap of eight, and all actual SQLite operations remain serialized.
- A discarded Performance completion could accidentally end Event traversal. Separate typed end operations and arbiter tests prove isolation.
- Independent Device selection could become stale after disconnect, Clear, or import. Reconciliation uses logical IDs, clears unavailable choices, and rebuilds only after the existing rematerialization barrier.
- Raw reveal could race Store replacement or window close. Source generation, resolver cancellation, coordinator revision, and exact-key revalidation reject stale completions before selection.
- Closing the main window could stop the runtime underneath Performance. Runtime shutdown moves to last-window/application termination rather than main-window disappearance.
- A broad application observation could reintroduce chart flicker. The Performance window root publishes only a compact status/coordinator identity signature.

## Verification

- Arbiter tests prove Event and Performance traversal isolation, serialized operation delivery, separate release, Store replacement cleanup, and no retained work.
- Coordinator tests prove independent Device selection, simultaneous active surfaces, selection fallback, pause/range behavior, Store replacement, raw reveal, and window close/reopen behavior.
- SwiftUI tests prove the missing segmented control, labeled singleton entry, always-enabled panel controls, Performance picker states, Inspector restoration, and layouts at 800x600, 1100x760, and wide sizes in light/dark appearances.
- Publication tests prove Event updates do not reconstruct the Performance root or main layout and Performance updates do not republish unrelated main regions.
- Full Viewer tests, strict-concurrency build, application build, Demo build, strict OpenSpec validation, launched-window inspection, and independent multi-agent review provide final evidence.
