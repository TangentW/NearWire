# Pre-Implementation Security, Performance, and Documentation Review

## Verdict

**Not approved for implementation.** The latest artifacts establish strong privacy, export,
accessibility, and protocol-ownership boundaries, but five actionable resource-governance and
lifecycle findings remain.

| Severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 4 |
| Low | 1 |
| **Total actionable** | **5** |

Approval requires artifact revisions followed by a fresh independent review that reports zero
unresolved findings.

## Scope Reviewed

- Repository `AGENTS.md` and the active proposal, design, tasks, and all three delta specs.
- The current architecture/API pre-review, including its runtime ownership, coordinator generation,
  query arbitration, live projection, retained-page, and control-target findings.
- Canonical Event-model, wire-transfer, local-store/search, multi-device flow-control, queue, rate,
  export, privacy, and cleanup requirements, plus the implementation roadmap and current Viewer
  operator documentation.
- Current Viewer application, session-manager/session, query/store/export, schema, privacy-manifest,
  reflection, and cleanup seams, and the Core Event validation/rate limits.

The review includes the latest corrections: the live window is 512 Events / 32 MiB so that one
maximum legal journal Event fits; new durable `DeviceSessions.logicalID` values use the exact
admission `connectionID`; pre-existing closed rows require no migration; and all Event-content
clipboard integration/actions are prohibited.

## Actionable Findings

### SPD1 — Medium — Logical live-window bounds do not yet bound callback work, resident UI state, or refresh cadence

The 512-Event / 32-MiB accounting limit is internally consistent, and the protocol callback forbids
encoding and traversal (`design.md:123-144`; multi-device delta `spec.md:25-29`). However, the
artifacts do not define the physical data structure and exact admission operations. An implementation
using array-front removal can shift 511 values, and dropping the last reference to a 16-MiB nested
Event while holding the callback lock can perform content-proportional deallocation. “Constant-
bounded” by 512 is not enough to demonstrate a short protocol callback. Deterministic Event bytes are
also an accounting quantity, not an upper bound on Swift heap allocation.

The presentation side has the same gap. Pages are bounded individually and rows are virtualized
(`design.md:86-103`; explorer delta `spec.md:23-27`), but no cap exists for retained recording,
device, timeline, gap, cursor, or per-row state after repeated scrolling. SwiftUI virtualization does
not bound the model arrays. Latest-only tokens bound backlog, but no minimum refresh interval or
maximum refresh cadence is specified. With a legal rate of 100,000 Events/s
(`Core/Sources/NearWireFlowControl/EventRateControl.swift:3-20`), an implementation can still create
one successfully completed MainActor wake/query per Event whenever the consumer temporarily keeps
up, despite never having more than one pending token.

**Required artifact changes:**

1. Specify an O(1) ring/deque plus exact-key index (or an equally bounded structure), the maximum
   lock-held operations per admission, and release of displaced large values outside the protocol
   callback/lock. Require a worst-shape callback-latency and actual-heap benchmark; documentation
   must distinguish deterministic accounted bytes from allocated heap.
2. Set explicit resident page/row/derived-state caps for recording and device catalogs, Event and gap
   windows, cursors, selection, and renderer input. Define bidirectional eviction, reload, exact
   selection clearing/restoration, and scroll-anchor behavior.
3. Set an explicit latest-only UI refresh cadence (for example, at most once per main run-loop turn
   and no more than a fixed Hz), with one owned wake/timer/task and one query per cadence. Pause must
   retain only the already specified token/counters and schedule no refresh work.
4. Extend tasks and tests with full-window replacement, exact-key replacement, a maximum-size
   structurally complex Event, 100,000-token bursts, long bidirectional scrolling, and pause/resume.
   Evidence must report callback latency, actual heap high-water mark, retained row/page/cursor counts,
   MainActor task/wake counts, and query counts.

### SPD2 — Medium — New catalog, gap, causality, and live-filter operations have result limits but no complete work/plan contract

The existing Event traversal has a VM-step / 250-ms page budget and an `EXPLAIN QUERY PLAN` gate
(`openspec/specs/viewer-local-store-search/spec.md:222-246`; current query service
`ViewerStoreQuery.swift:596-677`). The new explorer operations only bound returned rows and causality
nodes. They do not define equivalent time/VM-step budgets, frozen upper bounds, keysets, cancellation
checkpoints, or accepted query plans for every catalog, gap, and causality operation.

This matters because the current schema has receive-order indexes but no
`(recordingID, deviceSessionID, eventUUID, rowID)` causality index and no declared index/maintained
field for recording “effective last activity” ordering (`ViewerStoreSchema.swift:202-223,318-327`). A
bounded result such as eight candidates can still scan a large recording. Latest-revision gap paging
also has no exact page size or traversal key in the artifacts. The off-main live matcher is limited to
512 Events / 32 MiB but can apply up to 32 content/JSON predicates; without scanned-byte, time, and
cancellation budgets, one valid filter replacement can monopolize its executor.

**Required artifact changes:**

1. Define each recording catalog, device catalog, gap, causality-edge, and live-match operation with
   exact page/result limits, frozen bounds where applicable, keysets, transaction limits, VM-step/time
   budgets, generation cancellation, and one closed refine/busy result. No operation may fall back to
   a full scan, `OFFSET`, unbounded sort, or wider predicate.
2. Add the schema migration/index or maintained bounded activity key needed for effective-last-
   activity catalog ordering, the exact causality UUID lookup, and bounded latest-revision gap paging.
   Require plan-gate tests against large, skewed databases.
3. Give live evaluation a total scanned deterministic-byte/predicate-step/time budget and cancellation
   checkpoints between entries/predicates. Budget exhaustion must yield fixed refine guidance and may
   not publish a partial match as complete.
4. Extend tasks/tests for millions of Events/gaps/recordings, highly duplicated Event UUIDs, worst-case
   JSON predicates, cancellation/replacement, and writer concurrency. Save query plans, work-counter
   results, latency, and transaction-duration evidence.

### SPD3 — Medium — Renderer count limits do not bound input bytes, derived allocations, or accessibility duplication

The inspector permits complete raw JSON, off-main pretty printing, 4,096 materialized tree nodes, and
numeric extraction from 200 loaded rows (`design.md:162-186`; explorer delta `spec.md:71-77`). These
are count limits, not byte/allocation limits. Core permits a negotiated Event content size up to
16,777,216 bytes, 100,000 array/object entries, 1-MiB strings/keys, and depth 128
(`EventValidationLimits.swift:77-99`). A 4,096-node tree can therefore retain or copy very large
labels/path components; raw plus pretty plus tree representations can multiply one maximum Event;
and exposing one complete large scalar as an accessibility label can duplicate it again.

The numeric renderer is especially underspecified. Current timeline rows carry only a content byte
count, while detail loads one content blob (`ViewerStoreQuery.swift:434-454`). Extracting fields from
200 points can therefore load or decode up to 200 maximum Events even though only eight scalar series
are retained. The 200-point limit does not prevent multi-gigabyte transient work.

**Required artifact changes:**

1. Define total input-byte, derived-output-byte, elapsed-time, and cancellation budgets for raw,
   pretty, tree, table, log, and numeric preparation. Every completion must carry the exact detail/
   renderer generation and release oversized intermediate buffers after cancellation.
2. Require path/shared backing or another design that does not copy complete JSON values into every
   tree node. Bound node preview and accessibility text separately; load children in bounded chunks.
   The explicit inspector may expose complete content only through deliberate bounded navigation, not
   by automatically constructing a single full-content accessibility value.
3. Require numeric extraction to stream/load at most one Event detail at a time, enforce a total
   scanned-content-byte/time budget, and retain only bounded scalar series metadata and points. It may
   not retain 200 full content blobs or decoded trees.
4. Define fixed fallback/refine states for every budget/cancellation/shape failure. Extend tasks/tests
   with depth-128, 100,000-entry, 1-MiB key/string, 16-MiB Event, 200-row, rapid-selection, and VoiceOver
   cases, recording peak resident bytes, retained content-buffer count, work time, and stale-update
   absence.

### SPD4 — Medium — Composer and editable presentation inputs lack prevalidation storage bounds, and multi-target admission can repeat full encoding

The composer validates `EventDraft` off the MainActor and targets at most 16 sessions
(`design.md:203-224`; explorer delta `spec.md:108-126`), but the UI-bound type/JSON strings are not
bounded before parse/validation. The same omission applies to filter/path fields and recording
metadata editors. A user can therefore retain an arbitrarily large Swift `String` in MainActor state
before the eventual validator rejects it; repeatedly computing UTF-8/scalar counts on each keystroke
would add quadratic work.

The current single-target implementation also encodes the full draft inside each session's
synchronous operation (`ViewerMultiDeviceSession.swift:473-499`), and the manager calls that method
per target (`ViewerMultiDeviceSessionManager.swift:269-278`). A direct 16-target extension can encode
and traverse one maximum draft 16 times, potentially processing about 256 MiB of content before queue
admission. The proposed “validates once” wording does not require encoding/accounting once or prevent
this repeated session-executor work.

**Required artifact changes:**

1. Set UI storage caps for every editable type, JSON, search/path/value, recording name, note, and
   annotation buffer. Caps must align with the authoritative validators and be enforced incrementally
   without rescanning the full buffer on every edit. Inputs beyond the cap receive fixed safe guidance.
2. Define one replaceable off-main parse/validation/preparation generation. It must produce one
   immutable validated draft plus one checked deterministic/accounted byte count and then hand that
   value to the authoritative manager.
3. Require each per-target admission to do only O(1) target/ownership/policy checks plus bounded queue
   mutation using the precomputed byte count. It must not re-encode, deep-traverse, or deep-copy Event
   content. Per-target negotiated-size and queue decisions remain authoritative; no retarget/retry or
   delivery claim is added.
4. Add tests for rapid edits/cancellation, over-cap input, the maximum draft sent to 16 mixed targets,
   target terminal races, and queue rejection. Evidence must count draft encodes/traversals/copies and
   measure MainActor/session-operation duration and peak memory. Also assert content-free result
   reflection/logging/preferences and zero clipboard actions.

### SPD5 — Low — Shutdown does not explicitly own every new content-bearing operation

The normative lifecycle requirement cancels query/detail/export work, clears transient Event content
and composer state, and then joins existing cleanup (`explorer delta spec.md:128-138`). Catalog,
live-match, renderer/tree/raw preparation, causality, composer parsing/validation, and multi-target
send preparation are not all named. Generation rejection prevents stale publication, but cancellation
alone does not prove that tasks holding large Event buffers have stopped before cleanup reports
completion.

**Required artifact changes:**

1. Define one finite explorer cleanup receipt/barrier that first closes new admission and subscriptions,
   invalidates generations, cancels and joins catalog/timeline/gap/causality/detail/live-match/renderer/
   export/composer preparation, clears latest-only coalescers and accessibility content, releases exact
   leases, and only then joins the existing runtime session/store cleanup receipt.
2. Preserve the existing queue authority: already admitted downlink items remain owned and cleared by
   the session shutdown path rather than by a second explorer queue.
3. Extend tasks/tests with blocked query, renderer, live matcher, export, and composer operations at
   window close, runtime replacement, listener failure, TLS/identity reset, and application termination.
   Prove bounded completion, no late presentation/accessibility update, zero surviving Event-content
   tasks/buffers/subscriptions, and exact lease release.

## Reviewed Boundaries With No Additional Finding

- The exact admission `connectionID` -> new durable `DeviceSessions.logicalID` contract provides the
  correct transient/durable reconciliation identity. Peer Event UUID remains content, sequence reuse
  is runtime/connection scoped, and pre-existing closed rows do not need migration.
- The filter model is closed, validates/binds inputs, and prohibits raw SQL, raw FTS, dynamic JSON
  functions, unvalidated ordering, replay, and widening. Causality ambiguity is presented rather than
  silently resolved.
- The renderer registry is Viewer-internal, immutable, and excludes plug-ins, JavaScript, and dynamic
  bundles. Renderer failures remain presentation-local.
- Export reuses the existing lease, bounded-page streaming, owner-only temporary file, atomic
  replacement, and cancellation contract. Disclosure precedes the save panel and states that output
  is unencrypted, pseudonymous rather than redacted, content-bearing, outside Viewer retention/quota,
  and potentially provider-synced. Destinations are not persisted.
- Composer results are closed and content-free, and `Queued locally` correctly avoids peer-delivery,
  acknowledgement, execution, or processing claims. No template, retry, favorite, or independent
  sent-history store is introduced.
- Event content is excluded from safe device/status/recent rows, generic reflection, logs, analytics,
  preferences, and every clipboard action. Content is allowed only in the explicitly selected
  inspector/accessibility surface. Controls, state, and non-color accessibility requirements are
  present.
- The current privacy manifest remains sufficient for this local Viewer-only feature: the change adds
  no collection, tracking, server/cloud transfer, new Required Reason API, public SDK API, wire field,
  root-package dependency, or dynamic third-party code path. This decision must be re-audited against
  the final source and archive privacy report.
- The roadmap and task plan preserve the Viewer-only scope, defer the performance dashboard, require
  English operator documentation, forbid source modification before the artifact gate, and require
  complete validation/evidence plus fresh independent implementation reviews.

## Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive` was
  run against the latest artifact set and reported the change valid.
- No production or test source was modified by this review.
