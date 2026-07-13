# Pre-Implementation Architecture/API Review

## Verdict

**Not approved for implementation.** The artifacts are directionally sound, but six actionable
architecture/API findings remain.

| Severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 3 |
| Medium | 3 |
| Low | 0 |
| **Total actionable** | **6** |

Approval requires a fresh architecture/API review reporting zero unresolved findings after the
artifacts are revised.

## Scope Reviewed

- Repository `AGENTS.md` and the active change proposal, design, tasks, and all three delta specs.
- Canonical `viewer-local-store-search` and `viewer-multidevice-flow-control` requirements relevant
  to store ownership, query leases, cancellation, export, journal boundaries, session ownership,
  downlink queues, telemetry, and shutdown.
- `Documentation/Implementation-Roadmap.md`, especially section 19 and the per-change gate.
- Current Viewer seams in `ViewerRuntimeDependencies`, `ViewerApplicationModel`, `ViewerRootView`,
  `ViewerStoreRuntime`/`ViewerStoreCoordinator.Services`, `ViewerStoreQueryService`,
  `ViewerStoreExportService`, `ViewerMultiDeviceSessionManager`, and `ViewerDeviceSession`.
- Core `EventDraft`, `EventType`, and `JSONValue` validation seams used by the proposed composer.

The revised 512-record/32-MiB live-window bound is internally consistent across the latest design,
task plan, and multi-device delta spec. The latest artifacts also consistently prohibit Event
content clipboard integration. Keeping the feature Viewer-only, keeping the renderer registry
internal and immutable, and deferring the performance dashboard are appropriate boundaries.

## Actionable Findings

### A1 — High — Runtime-scoped components do not yet have one injectable ownership bundle

The design says the MainActor model composes a session manager, process store runtime, live window,
and explorer, and that one composite journal feeds both store and live presentation. It does not
define how those exact instances are constructed and handed to the model as one runtime-scoped
unit. The current dependency seam creates only a type-erased handoff owner, after which the model
casts it back to `ViewerMultiDeviceSessionManager`. That seam cannot guarantee that the control
facade, live window, handoff owner, and composite journal belong to the same runtime logical ID.

This is also a shutdown ownership problem: the artifacts require explorer work and transient
content to be invalidated before joining session/store cleanup, while the current cleanup receipt
is reached through the handoff owner. Independent factories could clear a different live window,
leave a stale explorer subscribed, or make tests silently lose typed control access when a fake
handoff owner is injected.

**Required artifact changes:**

1. Add a design decision for one Viewer-internal runtime-components factory/bundle created exactly
   once per `startRuntime`. It must return the same handoff owner, typed session-control facade,
   live-window observation facade, explorer inputs, and composite journal wiring for one runtime
   logical ID. The process-lifetime `ViewerStoreRuntime` remains outside that per-runtime bundle.
2. Define exact invalidation order for window close, application termination, listener failure,
   TLS reset, and full identity reset: stop explorer generations/subscriptions, stop new control
   admission, drain/terminate owned sessions, clear the live window at runtime end, and then join
   the existing store/session cleanup receipt without creating another protocol owner.
3. Add tasks/tests proving one bundle per runtime, no concrete downcast dependency, no stale
   callback across runtime-token replacement, and zero live/composer content after cleanup.

### A2 — High — Explorer store facades need coordinator-generation ownership across store reopen

The proposed application boundary is described as exposing query/catalog/detail/mutation/export
facades from `ViewerStoreRuntime`, but the current concrete services are owned by
`ViewerStoreCoordinator` and close over that coordinator's SQLite pool and lease registry.
`ViewerStoreRuntime` can detach and replace the coordinator during close/retry/reopen. Capturing a
`ViewerStoreCoordinator.Services` value in the application dependency graph would therefore retain
stale query/export services, closed connections, and leases from a superseded coordinator.

Generation checks only in the MainActor model are insufficient: an operation must release its lease
against the exact registry that created it even if the runtime replaces the current coordinator
before completion.

**Required artifact changes:**

1. State that application-facing store facades are owned and dynamically routed by
   `ViewerStoreRuntime`; the application must never retain coordinator services directly.
2. Bind every catalog/query/detail/mutation/export operation and lease to an immutable store-
   coordinator generation. A replacement must invalidate pending results, fail queued work with one
   closed presentation error, and release/cancel against the originating coordinator before it is
   closed. A late operation must never attach to the replacement coordinator implicitly.
3. Add a task and integration coverage for close/retry/reopen while each explorer operation is
   queued or active, including stale result suppression, exact lease release, and successful fresh
   work on the replacement coordinator.

### A3 — High — The single query connection and single traversal lease lack an exact operation arbiter

The design permits one catalog operation, one Event query, and one detail operation at the same
time, all over the existing serial query reader. It also permits export to consume the current
filtered traversal. The current cancellation API interrupts whichever operation happens to be
active, not a caller-supplied operation identity. A cancellation that arrives after the intended
page finishes but after a queued detail/catalog begins can therefore interrupt the wrong operation,
which the canonical store requirement explicitly forbids.

There is a second race: `page` and `detail` both touch and return a refreshed value-equality query
lease. If they start from the same traversal concurrently, one refresh makes the other's lease
stale. Filtered export preflight/execution can similarly observe a traversal version that no longer
owns the current lease. MainActor result generations prevent stale presentation, but they do not
make lease mutation or SQLite interruption correct.

**Required artifact changes:**

1. Define one non-MainActor query-owner/arbiter that is the sole mutable owner of the current
   `ViewerEventTraversal`. Page, detail, causality, gap, and filtered-export handoff must serialize
   through it; no two operations may touch the same lease value concurrently.
2. Give every query-reader operation an explicit operation token/generation from enqueue through
   completion. Cancellation may call `sqlite3_interrupt` only when that exact token is currently
   active; cancellation of a completed or merely queued old token must be a no-op and must not
   affect its successor.
3. Specify how catalog cancellation shares the serial reader without cancelling a timeline/detail
   operation, and how source replacement ends the exact traversal once.
4. Add deterministic races for page-versus-detail, detail-versus-source replacement, queued
   catalog cancellation, filtered-export handoff, lease refresh/expiry, and cancellation after the
   successor has started.

### A4 — Medium — The live window does not yet define the state needed by the shared filter/detail model

The explorer spec requires live and historical matching for gap, drop, and terminal-disposition
presence and requires transient detail to show resolved local disposition and device aliases. The
live-window decision and task currently describe only committed uplink and mailbox-admitted
downlink Event admission plus an overflow gap. They do not define bounded handling of later
`uplinkTerminated`, `dropsChanged`, session lifecycle/alias, or runtime/store-gap observations.

Without those projections, the live matcher cannot implement the same closed filter semantics as
SQLite, and a buffered transient Event cannot change to `consumerAccepted`, `expired`,
`overflowDisplaced`, or `sessionEnded`. Reading current session snapshots at render time would also
mix generations and make paused/frozen presentation nondeterministic.

**Required artifact changes:**

1. Define the bounded live projection for session start/end identity and aliases, initial and later
   disposition, drop presence, live overflow gaps, and storage-unavailable/recovery gap state.
   Updates must use the exact journal key and remain within fixed count/byte/metadata bounds.
2. Define the live meaning of `hasGap`, `hasDrop`, and `hasTerminalDisposition`, including whether a
   predicate applies per Event, exact device, or current runtime aggregate. The SQL and in-memory
   evaluators must have testable equivalent semantics where the data exists, and unavailable data
   must not be treated as a match.
3. Require the off-main live evaluator and transient detail builder to consume one immutable
   window snapshot/generation rather than consulting mutable session state during evaluation.
4. Extend tasks/tests for disposition transitions after initial commit, drop changes, session end,
   alias stability, pause/resume, and storage recovery under every presence predicate.

### A5 — Medium — Lazy SwiftUI rows do not provide a total retained-data bound

The artifacts bound each catalog/timeline result page, but they do not bound how many pages the
presentation model may retain after repeated scrolling. `LazyVStack`/`List` virtualizes view
creation; it does not bound the model array. Appending every 50-row recording page, every 100-row
device page, or every 200-row Event page can still materialize an arbitrarily large history and
conflicts with the explicit prohibition on complete catalog/result retention.

Selection and scroll-anchor requirements also need a defined behavior when the page containing the
selected row is evicted.

**Required artifact changes:**

1. Add explicit maximum retained page/row counts for recording catalogs, device catalogs, Event
   timelines, and renderer-derived visible-window data. The bound must cover rows, cursors, and
   per-row presentation state, not only SQLite result size.
2. Define deterministic forward/backward eviction, cursor preservation/reload, selected-row/detail
   identity, and scroll-anchor behavior. Eviction must not select an unrelated Event or device.
3. Add long-scroll tests that traverse histories far beyond the cache bound in both directions and
   prove bounded retained state, correct keyset continuity, stable exact selection when possible,
   and safe selection clearing/reload otherwise.

### A6 — Medium — Downlink result categories overlap and are not yet an implementable closed API

The current manager exposes a Boolean single-target send. The new artifacts list five result cases
but do not define their mutually exclusive decision points. In particular, an unknown target,
stale target from the previous runtime, recent disconnected target, owned negotiating target,
disconnecting target, and active target that becomes terminal inside synchronous queue admission
can currently collapse into several plausible cases. `queueRejected` also needs to be distinguished
from loss of active ownership inside the session executor.

Without a closed classification order, independently correct implementations and tests can disagree,
and a UI pre-check against snapshots can race the authoritative session state.

**Required artifact changes:**

1. Define a Viewer-internal immutable control-target token containing the exact connection identity
   and runtime/manager generation. Reject duplicate tokens before admission and preserve deterministic
   result ordering for the 1-through-16 input targets.
2. Define a single authoritative classification inside the existing manager/session ownership
   boundary: `invalidTarget` for malformed/duplicate/wrong-runtime or never-owned identity;
   `noLongerConnected` for an exact previously selected identity whose ownership ended;
   `notActive` for an exact currently owned but non-active session; `queueRejected` only when the
   exact active session retains ownership but the bounded queue cannot buffer the draft; and
   `queued` only after that exact session reports the draft buffered.
3. State how the terminal race is classified when ownership changes during the synchronous session
   operation. The implementation must not retry, retarget by logical route, or infer mailbox/peer
   admission.
4. Add API/task coverage for duplicates, wrong runtime, unknown target, recent-row expiry,
   negotiating/disconnecting states, queue rejection, terminal-before/after-enqueue races, and mixed
   16-target results.

## Validation Observed

- `openspec validate viewer-event-explorer-control --strict --no-interactive` — exit 0; reported
  `Change 'viewer-event-explorer-control' is valid`. PostHog telemetry flush then reported a
  non-gating DNS failure for `edge.openspec.dev`.
- `git diff --check` — exit 0 with no output before this report was added.

No production or test source was modified by this review.
