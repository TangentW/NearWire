# Pre-Implementation Review Remediation — Round 1

## Status

The proposal, design, three delta specifications, and task plan were revised after the first
independent review round. This document maps every actionable finding to the revised artifact
contract. It is remediation evidence only; implementation remains blocked until a fresh independent
round reports zero unresolved findings.

No production or test source was modified during remediation.

## Architecture and API Findings

### A1 — Runtime-scoped components

Resolved in design decision 1 and the explorer/multi-device requirements:

- one `ViewerRuntimeDependencies.makeRuntimeComponents(runtimeLogicalID:)` call creates one typed
  bundle for each `startRuntime`;
- admission handoff, typed session control, manager generation, live projection, composite journal,
  explorer inputs, explicit runtime logical ID, and cleanup receipt come from that same bundle;
- the process-lifetime store runtime remains outside the bundle; and
- application code cannot downcast the handoff owner or assemble mixed-runtime components.

Tasks 3.1, 6.3, 6.4, and 6.7 require implementation and identity/lifecycle evidence.

### A2 — Coordinator-generation ownership

Resolved in design decision 3 and the modified store requirement:

- `ViewerStoreRuntime` owns the application-facing explorer gateway;
- each operation carries immutable coordinator-generation and operation identities and an
  originating-coordinator lease;
- replacement seals the generation, cancels and joins exact work, releases leases against the
  originating registry, closes SQLite, and only then publishes replacement availability; and
- stale work returns `storeReplaced` and cannot retarget itself.

Tasks 2.2, 2.6, 6.1, and 6.7 cover the implementation and reopen races.

### A3 — Query arbitration and exact cancellation

Resolved in design decision 3 and the search/store requirements:

- one non-MainActor query arbiter is the sole traversal and refreshed-lease owner;
- page, detail, gap, causality, and filtered-export scope creation serialize through it;
- every interactive request has an enqueue-to-completion token; cancellation can remove only the
  matching queued request or interrupt only the matching active request; and
- filtered export receives an immutable frozen scope and acquires an independent export lease.

Tasks 2.3, 6.1, and 6.7 require successor-safe cancellation and exact-release evidence.

### A4 — Complete live projection state

Resolved in design decisions 5 and 12 and the modified multi-device requirement:

- one normalized committed observation supplies shared receive timestamps, identity, bounded
  aliases, Event value, byte accounting, direction, sequence, and initial disposition;
- the projection retains bounded session aliases, later terminal disposition, drop samples, session
  end, overflow/conflict gaps, and store unavailable/recovered state;
- store outcome transitions are content-free and enter only on the projection executor; and
- one immutable snapshot defines exact runtime/device/Event presence semantics and transient filter
  evaluation, with durable-only FTS5 behavior explicitly disclosed.

Tasks 3.2 through 3.4 and 6.3 require the differential and transition matrix.

### A5 — Total resident bounds

Resolved in design decisions 7 and 11 and the timeline/detail requirements:

- resident caps are 200 recordings, 200 devices, 600 Events, 128 gaps, two boundary cursors plus one
  reload anchor per list, 16 selected device identities, and one selected Event/detail buffer;
- forward/backward eviction, opposite reload cursors, selection reload/clear, and anchor movement are
  deterministic; and
- raw, tree, accessibility, and numeric renderer input/derived-state limits are explicit.

Tasks 4.1, 4.4, 6.2, 6.5, and 6.9 require count and heap evidence.

### A6 — Closed control-target API

Resolved in design decision 9 and the control-composition requirements:

- exact tokens contain runtime logical ID, manager generation, and connection ID;
- all duplicate occurrences are invalid and unique results preserve input order;
- the manager owns mutually exclusive invalid, terminal-cache, nonactive, queue-rejected, and queued
  classification; and
- terminal ordering, no retarget/retry/rollback, and `Queued locally` truthfulness are explicit.

Tasks 3.5, 6.4, and 6.7 require the full target/race matrix.

## Correctness and Testing Findings

### CT1 — Operation-exact query cancellation and lease ownership

Resolved by the same arbiter, immutable generation token, originating lease, retirement, independent
filtered-export scope, and exact cancellation contracts described for A2/A3. Tasks 2.2, 2.3, 6.1,
and 6.7 name close/retry/reopen, successor-start, expiry, refresh, and exact-release races.

### CT2 — Store/live filter oracle

Resolved in design decisions 5 and 12:

- live and durable paths share one normalized observation and one Viewer receive time;
- metadata, JSON, gap, drop, and terminal scopes are normative and differentially tested;
- identical keys are idempotent, conflicts are first-wins with a presentation gap, and durable merge
  uses runtime/connection/direction/sequence rather than peer UUID; and
- FTS5 is explicitly durable-only while transient rows receive fixed guidance.

Tasks 3.2, 3.4, and 6.3 require boundary-time, duplicate, transition, reconnect, and differential
coverage.

### CT3 — Frozen catalog membership and ordering

Resolved in design decisions 2, 3, and 11:

- recording order is immutable descending recording row ID;
- device order is connection ordinal plus row ID;
- cursors bind fingerprint, store/change generation, upper base/version/tombstone bounds, direction,
  and key; and
- a relevant mutation restarts from page one, while exact continuity is claimed only for an
  unchanged frozen traversal.

Tasks 2.4, 6.1, and 6.2 cover equal keys and between-page creation/revision/tombstone cases.

### CT4 — Deterministic gap placement

Resolved in design decisions 4 and 11:

- gaps occupy a separate diagnostic lane, never Event monotonic order;
- identity, frozen upper row ID, latest-revision rule, wall-time keyset, device scope, direction, and
  page/resident limits are explicit; and
- all-device and selected-device queries use exact schema-2 index lanes and a bounded 17-lane merge.

Tasks 2.1, 2.5, 6.1, and 6.2 require plan, overlap, revision, and traversal evidence.

### CT5 — Deterministic causality

Resolved in design decision 7:

- lookup binds recording, exact device, traversal lease, and frozen Event upper row ID;
- candidates use durable-row ordering and limit nine for eight plus `hasMore`;
- breadth-first order is reply-to before correlation; and
- row ID, not peer UUID, is the 32-node visited/cycle identity.

Tasks 2.5, 6.1, and 6.2 require 0/1/2/8/9+ candidates and true/false cycle cases.

### CT6 — Pause, shutdown, and admission generations

Resolved in design decisions 1, 6, and 10:

- Pause increments the presentation generation before freezing rows;
- source/filter/Pause/Resume/Jump share one state machine and stale traversal release is exact-once;
- composer preparation and result publication bind runtime and attempt generations; and
- shutdown first seals admission/subscriptions, invalidates generations, then cancels and joins every
  named content-bearing operation before the combined receipt completes.

Tasks 4.3, 6.4, 6.5, and 6.7 require rapid transitions, late results, blocked work, and every stop
path.

### CT7 — Target categories and races

Resolved by the exact token and authoritative manager classification described for A6. The contract
also fixes expired-recent versus bounded-terminal-cache behavior and terminal-before versus
terminal-after-enqueue outcomes. Tasks 3.5 and 6.4 enumerate duplicates, wrong runtime, unknown,
expired recent, negotiating, disconnecting, queue rejection, reconnect, terminal races, 16 mixed
targets, ordering, and superseding attempts.

## Security, Performance, and Documentation Findings

### SPD1 — Callback, resident-state, and refresh bounds

Resolved in design decisions 5, 6, and 11:

- callback ingress is a 64-record/20-MiB ring with constant index/ring operations, no callback-lock
  eviction or large-value release, and one drain plus one dirty successor;
- the ingress accounts deterministic Event bytes plus fixed maximum entry overhead and is sized for
  one maximum legal journal Event; actual heap is separately measured;
- the off-callback projection is an O(1) deque/index capped at 512 records/32 MiB; and
- resident explorer caps and one latest-only wake at no more than 10 Hz and once per run-loop turn
  are normative, with no refresh while paused.

Tasks 3.3, 4.1, 6.3, 6.5, and 6.9 require latency, heap, count, wake, and query evidence.

### SPD2 — Query work and plan contracts

Resolved in design decision 11 and the modified store requirement:

- catalog, gap, and causality operations have 2,000,000-step/250-ms budgets, short transactions,
  exact cancellation, fixed refine results, and plan gates;
- schema 2 adds exactly one scoped Event UUID and two gap-order indexes;
- catalog plans must use named existing primary/unique indexes or trigger a reviewed artifact
  amendment before implementation; and
- live evaluation has entry, byte, predicate, JSON-node, time, and cancellation bounds with no
  partial-complete result.

Tasks 2.1, 2.4, 2.5, 3.4, 6.1 through 6.3, and 6.9 require large/skewed data plans and counters.

### SPD3 — Renderer bytes, allocations, and accessibility

Resolved in design decision 7:

- one canonical detail buffer is retained and raw access uses 64-KiB chunks;
- pretty, tree, previews, accessibility text, visible nodes, children per expansion, derived text,
  time, and cancellation are bounded;
- tree nodes share backing paths/ranges rather than copy values; and
- numeric extraction streams one Event at a time under 200-row/8-MiB/100-ms limits and retains only
  bounded scalar points.

Tasks 4.4, 6.5, 6.7, and 6.9 require maximum-shape, VoiceOver, peak-memory, work, and stale-result
evidence.

### SPD4 — Editable input and encode-once bounds

Resolved in design decision 9:

- every editable Event/filter/metadata field has a pre-parse byte/scalar cap maintained by
  incremental edit deltas;
- one replaceable off-MainActor generation parses and validates once; and
- one immutable prepared draft carries the encoded value, accounted bytes, and policy so each target
  performs only ownership/policy/queue checks without re-encoding, traversing, or deep-copying
  content.

Tasks 3.5, 4.5, 6.4, and 6.9 require rapid edit, cap, encode/traversal/copy, duration, and memory
evidence.

### SPD5 — Complete cleanup barrier

Resolved in design decisions 1 and 10 and the lifecycle requirement:

- one finite explorer receipt closes new control/content work, invalidates generations and
  subscriptions, cancels and joins catalog/timeline/gap/causality/detail/live-match/raw/tree/renderer/
  export/composer preparation, clears content and coalescers, and releases originating leases;
- the receipt joins the existing session/store cleanup rather than creating another queue owner; and
- already admitted downlink items remain owned by session shutdown.

Tasks 6.7 and 6.9 require blocked-operation completion, zero late publication/content retention, and
exact lease-release evidence for all stop paths.

## Validation

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  — exit 0, `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` — exit 0 with no output.
- Active-tree source check — only `openspec/changes/viewer-event-explorer-control/` is untracked;
  no production or test source was modified.

The change remains blocked at task 1.2 until a fresh architecture/API, correctness/testing, and
security/performance/documentation review round reports zero unresolved findings.
