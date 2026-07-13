# Pre-Implementation Correctness and Testing Review

## Verdict

**Not approved for implementation.** Seven actionable correctness/testing findings remain. The
artifacts pass structural OpenSpec validation, but they do not yet define enough race, snapshot,
and equivalence behavior for deterministic implementation and evidence.

| Severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 3 |
| Medium | 4 |
| Low | 0 |
| **Total actionable** | **7** |

Approval requires artifact corrections followed by a fresh correctness/testing review with zero
unresolved findings.

## Scope Reviewed

- Repository `AGENTS.md`; the active proposal, design, task plan, and all three delta specs.
- Canonical `viewer-local-store-search`, `viewer-multidevice-flow-control`,
  `viewer-application-foundation`, Event-model/transfer/queue/rate requirements, and roadmap items
  19 through 22.
- Current query compiler/traversal, query leases, SQLite cancellation, schema/indexes, store
  coordinator/reopen path, journal preparation, session manager/downlink queue, shutdown, and
  application-model seams.
- The existing architecture/API pre-review was cross-checked after the independent artifact/source
  inspection. Overlapping findings are retained where they independently block correctness.

The latest 512-record/32-MiB live-window bound is consistent and can retain one maximum legal
journal Event. The latest artifacts consistently prohibit clipboard actions. The new requirement
that a newly materialized `DeviceSessions.logicalID` equal the exact admission `connectionID`
correctly closes the principal transient/durable identity gap; preserving pre-existing closed rows
without migration is safe because they cannot have a current transient counterpart.

## Actionable Findings

### CT1 — High — Query cancellation and lease ownership are not operation-exact

The design permits a catalog operation, Event traversal, detail work, causality/gap work, and
filtered-export handoff over the same interactive reader, while requiring replacement to cancel
only the matching prior operation (`design.md:86-103`). The current traversal contains a value-type
lease that `page` and `detail` both touch and replace (`ViewerStoreQuery.swift:567-725`). Concurrent
operations starting from the same traversal can therefore invalidate each other's lease value.

Cancellation is currently even broader: `ViewerStoreQueryService.cancel()` calls
`cancelCurrentOperation()` with no intended operation token (`ViewerStoreQuery.swift:723`), and the
connection interrupts whichever generation is active when cancellation executes
(`ViewerSQLite.swift:332-340`). A late cancellation for completed page A can interrupt queued detail
or catalog B, contrary to the canonical generation-matching requirement
(`openspec/specs/viewer-local-store-search/spec.md:12,26-30`). Store close/reopen can also replace the
coordinator that owns the connection and lease registry while a retained facade still refers to
the old one (`ViewerStoreCoordinator.swift:1484-1500,1531-1559`). MainActor result generations do
not repair an incorrectly interrupted operation or release a lease against the wrong registry.

**Required artifact changes:**

1. Define one non-MainActor query arbiter as the sole mutable owner of a traversal and its refreshed
   lease. Page, detail, causality, gap lookup, and filtered-export handoff must serialize through
   that owner; ending/replacing a traversal must release its exact lease once.
2. Give every interactive-reader operation an enqueue-to-completion token. Cancellation may call
   `sqlite3_interrupt` only if that exact token is currently active; cancellation of a completed,
   queued, or superseded token must be a no-op for its successor.
3. Bind each operation and lease to the coordinator generation that created it. Reopen must fail
   stale work safely, release it through the originating registry before close, and never retarget
   it to the replacement coordinator.
4. Add deterministic races for page/detail, detail/source replacement, queued catalog cancellation,
   filtered-export handoff, lease touch/expiry, cancellation after a successor starts, and
   close/retry/reopen during every explorer read operation.

### CT2 — High — The promised store/live filter equivalence has no complete live data model or oracle

The new capability requires every filter dimension to use the same AND/OR semantics while storage
is unavailable (`specs/viewer-event-explorer-control/spec.md:41-57`). Persisted predicates depend on
App/Bundle metadata, FTS5 `unicode61` tokenization, gap/drop rows, and later terminal disposition
rows (`ViewerStoreQuery.swift:13-34,83-113,242-256`). The proposed live window observes only initial
committed uplink and mailbox-admitted downlink Events plus its own overflow summary
(`design.md:123-144`). It does not define bounded projections for session aliases/App/Bundle,
`uplinkTerminated`, drop changes, store-unavailable gaps, or session end. Consequently
`hasGap`, `hasDrop`, `hasTerminalDisposition`, transient detail disposition, and some device/App
filters cannot satisfy the stated equivalence.

Viewer receive-time equality is also unspecified. The current persisted wall time is sampled later
during store preparation (`ViewerEventStore.swift:39-50`); a separately sampled live time can fall
on the opposite side of a millisecond range boundary. A bespoke Swift text matcher also cannot be
assumed equivalent to the persisted FTS5 tokenizer without a defined compatibility contract.

**Required artifact changes:**

1. Define one immutable normalized journal observation, shared by live and store paths, with one
   Viewer wall/monotonic receive time, exact session identity, stable aliases/App/Bundle metadata,
   canonical Event data/byte count, direction/sequence, and initial disposition.
2. Define fixed-bounded live updates for later disposition, drop presence, session end, live
   overflow, and storage-unavailable/recovery gaps. Define whether each presence predicate is
   Event-, device-, or runtime-scoped and how unavailable data evaluates; absence of a projection
   must not silently count as a match.
3. Specify exact literal/Unicode/token behavior for the in-memory evaluator relative to the SQLite
   compiler. Use one shared normalized predicate model and a differential SQLite oracle rather than
   two independently interpreted UI filters.
4. Extend tests to compare store and live results for every predicate and scalar type, mixed
   AND/OR, NFC/combining marks, punctuation/quotes/FTS operators, millisecond boundaries,
   disposition/drop/gap transitions, aliases/App/Bundle, and store available/unavailable/recovered
   states.
5. Define duplicate live-key behavior: identical observations are idempotent; conflicting content
   under the same runtime/connection/direction/sequence key must fail closed in presentation and
   must not replace the earlier Event or affect protocol/store ownership. Test both cases as well as
   delayed durability, outage recovery, reconnect sequence reuse, and exact-row-only removal.

### CT3 — Medium — Catalog keysets do not define a frozen membership/order contract

Recording pages order by "effective last activity" plus row ID, but effective activity is not
defined and is mutable while Events, versions, gaps, or closure state arrive
(`design.md:86-97`; `specs/viewer-local-store-search/spec.md:39-51`). A row below page one's cursor
can move above it before page two and be omitted; a new row can enter the traversal; cleanup can
tombstone an unseen recording. Device connection ordinals are stable, but new device rows and
metadata revisions create the same membership/revision question. The test task mentions frozen
bounds without specifying which catalog bounds or cursor fingerprint must be frozen (`tasks.md:35`).

**Required artifact changes:**

1. Define the exact effective-activity expression and tie behavior, including active recordings,
   no-Event recordings, gap-only activity, and equal timestamps.
2. Define a catalog traversal snapshot: relevant upper row IDs/revisions, cleanup protection or
   explicit stale-restart behavior, cursor fingerprint/direction, and exact lease lifetime. If the
   UI intentionally restarts on catalog change, narrow the no-omission guarantee to one frozen
   traversal and state that restart explicitly.
3. Add page-boundary tests with equal activity, Event/version/gap/close commits between pages, new
   devices, rename/pin mutations, tombstone/cleanup, forward/backward traversal, stale cursors, and
   replacement while a page is queued.

### CT4 — Medium — Gap marker membership and placement are not deterministic

Events have a stable monotonic/row-ID order, but persisted gaps contain only Viewer wall-time ranges
and optional wire-sequence hints (`ViewerStoreSchema.swift:261-277`). The design says gap markers
are "adjacent" to a loaded Event window and approximately placed when no monotonic point exists
(`design.md:105-116`), without defining marker identity, frozen revision, anchor/tie order, page-edge
ownership, or how overlapping/device-scoped gaps are deduplicated. A latest gap revision committed
after page one could move or duplicate a marker unless the gap lookup is explicitly bound to the
Event traversal's frozen `gapUpperRowID`.

**Required artifact changes:**

1. Bind gap membership and latest-revision selection to the exact Event traversal snapshot and
   lease, including device filters and the frozen gap upper row ID.
2. Define a stable marker identity and deterministic placement/ownership rule that never fabricates
   a monotonic Event order. State which page owns a marker that spans two page ranges and how
   overlapping runtime/device gaps coalesce or remain separate.
3. Add tests for gap revision after page one, equal/out-of-order wall times, no neighboring Event,
   overlapping gaps, reconnect/device filters, gaps spanning page boundaries, forward/backward
   loading, and pause/resume while a gap closes.

### CT5 — Medium — Causality bounds lack deterministic candidate and cycle semantics

Causality is scoped correctly to recording and exact device, treats duplicate peer UUIDs as
ambiguous, and bounds candidates/nodes (`design.md:180-183`). It does not define candidate order,
how the UI signals more than eight matches, which durable identity is used for cycle detection, or
which frozen Event upper bound applies. Cycle detection by peer Event UUID would falsely collapse
distinct rows when UUIDs are reused. The current schema has timeline/type indexes but no scoped
Event-UUID index (`ViewerStoreSchema.swift:318-327`), so an exact lookup over a large recording may
scan until the query budget fails.

**Required artifact changes:**

1. Define deterministic candidate ordering, a `hasMore`/truncated result for 9+ matches, and the
   precise correlation/reply edge expansion order within the 32-node budget.
2. Use durable Event row/journal identity for visited nodes and cycles; peer UUID remains only the
   lookup value. Bind every lookup to the selected traversal's recording, exact device, and frozen
   Event upper row ID.
3. Require either a schema/index migration for bounded scoped UUID lookup or recorded query-plan
   evidence that the existing schema meets the large-history work budget.
4. Test 0, 1, 2, 8, and 9+ candidates; duplicate UUIDs that are not cycles; true self/two-node
   cycles; both correlation and reply edges; snapshot-new writes; cleanup/lease races; and large
   histories under the query budget.

### CT6 — High — Pause and shutdown do not invalidate every in-flight generation or control admission

Pause must freeze rendered rows immediately, yet the artifacts do not state that pressing Pause
invalidates an already running page/detail/live-evaluation completion before the frozen snapshot is
captured (`design.md:143-157`). A late old page can otherwise mutate the supposedly frozen rows.
Resume is specified as one fresh traversal, but rapid Pause/Resume/Jump/filter sequences have no
explicit generation state machine.

The lifecycle decision lists source/filter/detail/export generations and shutdown cancellation for
query/detail/export (`design.md:223-228`); composer validation/admission/result generations and
catalog/renderer cancellation are not included in the shutdown sequence. The current manager sets
`shuttingDown` before disconnecting sessions but its send entry point does not check that flag
(`ViewerMultiDeviceSessionManager.swift:195-224,270-278`). Off-main draft validation that completes
after shutdown can therefore attempt admission while entries are still draining, and a late result
can repopulate composer state after it was cleared.

**Required artifact changes:**

1. Define one presentation generation transition for source/filter/Pause/Resume/Jump to Latest.
   Pause must invalidate prior page/live/detail/renderer completions before freezing; Resume must
   release the stale traversal exactly once and create only one fresh traversal.
2. Add composer attempt and runtime generations. Validation completion may call the manager only if
   both still match; later attempts replace earlier result publication without allowing the old
   attempt to mutate the newer panel.
3. Define shutdown as an admission gate: invalidate all catalog/query/detail/renderer/export/live/
   composer generations and subscriptions, reject new control admission, clear content, release
   exact leases, then join session/store cleanup. No late completion may enqueue or repopulate UI.
4. Add deterministic races for Pause during page/detail evaluation, rapid Pause/Resume/Jump/filter,
   runtime replacement, validation during shutdown, send during session draining, late renderer/
   catalog results, and repeated shutdown/retry/identity-reset cleanup.

### CT7 — Medium — Multi-target result categories and target races are not a closed testable API

The composer lists five result cases but does not give mutually exclusive decision points
(`design.md:200-217`; `specs/viewer-event-explorer-control/spec.md:108-126`). Unknown, duplicate,
wrong-runtime, recently disconnected, negotiating, disconnecting, active-then-terminal, and
queue-full targets can map to multiple plausible categories. A UI snapshot pre-check is racy, and a
logical-route lookup could accidentally retarget a reconnect. Result ordering for mixed targets is
also unspecified.

**Required artifact changes:**

1. Define an immutable target token containing exact connection identity plus runtime/manager
   generation. Reject duplicate or wrong-runtime tokens before admission, never retarget by route,
   and preserve deterministic input ordering in the at-most-16 results.
2. Define one authoritative classification order inside the manager/session boundary:
   `invalidTarget` for malformed/duplicate/wrong-runtime/never-owned identity;
   `noLongerConnected` for an exact selected identity whose ownership ended; `notActive` for an
   exact currently owned non-active session; `queueRejected` only while exact active ownership
   remains but the bounded queue rejects; and `queued` only after exact-session buffering.
3. Define the terminal-before/during/after synchronous enqueue races without retry, rollback,
   retarget, or mailbox/peer claim. A successful local queue result remains truthful even if the
   session terminates immediately afterward.
4. Test duplicates, wrong runtime, unknown and expired-recent targets, negotiating/disconnecting,
   queue rejection, reconnect with sequence/route reuse, terminal races, one blocked target, mixed
   16-target outcomes, result ordering, and superseding send attempts.

## Areas With No Additional Finding

- **Exact identity transition:** the latest connection-ID materialization rule, runtime logical-ID
  source transition, exact durable-row visibility rule, and no-backfill behavior are coherent.
- **History revisions and export:** revision-bound mutation/delete behavior, active/leased
  rejection, disclosure-before-save-panel order, frozen filtered export, cancellation, and atomic
  destination behavior are proportionately specified. Task 6.4 covers the required integration
  evidence. Tests should also assert that transient `Not recorded` rows are excluded from filtered
  export and that this exclusion is visible in preflight/UI wording.
- **Transport truthfulness:** history remains correctly delayed until secure-mailbox admission and
  `Queued locally` does not claim delivery.
- **Privacy/exclusions:** the selected inspector is the only allowed Event-content accessibility
  surface, and clipboard integration/actions are consistently excluded.

## Validation Observed

- `openspec validate viewer-event-explorer-control --strict` — exit 0 and reported
  `Change 'viewer-event-explorer-control' is valid`; a subsequent non-gating PostHog telemetry flush
  reported DNS failure for `edge.openspec.dev` in the restricted environment.
- No production or test source was modified by this review.
