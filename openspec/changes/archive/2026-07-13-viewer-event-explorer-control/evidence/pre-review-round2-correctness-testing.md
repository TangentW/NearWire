# Pre-Implementation Correctness and Testing Review — Round 2

## Verdict

**Not approved for implementation.** The round-1 revisions resolve the main cancellation, gap,
causality, pause, cleanup, and result-ordering mechanisms, but four actionable correctness/testing
findings remain.

| Severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 0 |
| **Total actionable** | **4** |

The change must remain at the artifact gate. Approval requires normative corrections and a fresh
review reporting zero unresolved actionable findings.

## Scope and Method

This review reread the latest proposal, design, tasks, all three delta specifications, all three
round-1 review reports, and the round-1 remediation report. It then checked the revised contracts
against the canonical local-store and multi-device specifications and the current query, store,
session-manager, recent-row, cancellation, and shutdown seams. The remediation report was treated as
a claim to verify, not as evidence of resolution by itself.

The review specifically replayed every prior CT1 through CT7 failure condition, including late
SQLite cancellation, mutable lease refresh, coordinator replacement, no-store filtering, duplicate
journal keys, catalog mutations, gap revisions, duplicate Event UUIDs, Pause/Resume generations,
shutdown admission, reconnects, and terminal/queue races.

## Round-1 Correctness Finding Status

| Prior finding | Round-2 status | Basis |
| --- | --- | --- |
| CT1 — Query cancellation and lease ownership | Resolved | Runtime-owned gateway, originating coordinator generation, sole traversal arbiter, enqueue-to-completion operation tokens, independent filtered-export lease, exact retirement, and task 6.1/6.7 races are normative. |
| CT2 — Store/live filter oracle and exact-key behavior | **Partially resolved** | Shared observations, timestamps, presence scopes, durable-only FTS, and differential tests are specified, but current-live source/device scope cannot be represented by the claimed authoritative query type, and duplicate guarantees exceed the defined bounded state. See R2-CT1 and R2-CT2. |
| CT3 — Frozen catalog membership/order | **Partially resolved** | Immutable row-ID/connection-ordinal traversal, upper bounds, mutation restart, and resident caps are specified, but one normative scenario still requires the removed activity ordering. See R2-CT4. |
| CT4 — Gap membership/placement | Resolved | The separate frozen diagnostic lane, stable identity, latest-revision bound, keyset, page/resident limits, device lanes, and tests remove the prior placement ambiguity. |
| CT5 — Causality determinism | Resolved | Exact scope, row-ID order/visited identity, nine-row truncation probe, reply-before-correlation BFS, 32-node limit, schema index, plan budget, and 0/1/2/8/9+ tests are normative. |
| CT6 — Pause/shutdown generations | Resolved | Pause-before-freeze invalidation, one presentation state machine, exact traversal release, runtime/attempt generations, admission seal, named cleanup barrier, and blocked-operation tests are normative. |
| CT7 — Target classification/races | **Partially resolved** | Tokens, duplicate handling, input order, manager authority, terminal ordering, and truthful queue results are specified, but `noLongerConnected` depends on an undefined exact terminal cache. See R2-CT3. |

## Actionable Findings

### R2-CT1 — High — `Live — not recording` cannot be represented by the claimed authoritative query model

The revised artifacts still say the existing normalized `ViewerEventQuery` is authoritative
(`design.md:132-134`) and that input is validated into the existing closed query model before live
or SQLite evaluation (`specs/viewer-event-explorer-control/spec.md:43-49`). They simultaneously
require a current runtime with no durable row to use no synthetic recording ID and to support one,
multiple, or all selected devices (`specs/viewer-event-explorer-control/spec.md:7,13-23`).

The existing type cannot express that state. `ViewerEventQuery` requires a positive durable
`recordingID`, and its only device selector is `[Int64]` durable `deviceSessionIDs`
(`ViewerStoreQuery.swift:25,36-44`). During a storage outage there is no recording row or device row;
the live projection has runtime and connection UUIDs instead. This is not an implementation detail:
there is currently no valid value that can carry the required current source and selected-device
scope without inventing durable IDs or silently dropping the device predicate. The unavailable-to-
durable transition is therefore not testable against one unambiguous filter value.

**Required artifact changes:**

1. Define a Viewer-internal source-neutral explorer query/filter value. Its source scope must be an
   explicit current runtime logical ID or durable recording identity, and its device scope must
   carry exact connection/device logical identities for one, 2 through 16, or all devices.
2. State that the source-neutral value is authoritative for presentation/live evaluation and is
   compiled into the existing SQL-only `ViewerEventQuery` only when durable row IDs exist. Do not
   use synthetic recording/device row IDs or omit a selected-device predicate during an outage.
3. Define how logical device selections map to durable row IDs as individual devices materialize,
   and how a filter/query generation transitions atomically from `Live — not recording` to the
   matching durable recording without changing logical selection or admitting another runtime.
4. Add tasks/tests for no durable parent, partial device materialization, one/2–16/all selected
   devices, filter replacement during materialization, reconnect with reused sequence numbers, and
   exact live/durable differential results before and after source transition.

### R2-CT2 — Medium — Duplicate/conflict semantics are global, but the only defined key memory is evictable

The revised requirements state without qualification that identical duplicate journal keys are
idempotent and conflicting content under one key is first-wins with one presentation-conflict gap
and no durable/protocol outcome change
(`specs/viewer-multidevice-flow-control/spec.md:35,61-65`). The only exact-key structures described
are a 64-entry ingress and a 512-entry window that evict or reject values
(`design.md:166-175`; multi-device delta `spec.md:31-35,49-53`). No retained-key tombstone horizon or
other bounded authority is defined after a key leaves both structures.

This also crosses the store fan-out boundary. The current durable store treats a conflicting
existing key as corruption after comparing the complete observation
(`ViewerEventStore.swift:1291-1323`). The artifacts do not identify a linearization point that
classifies a duplicate before both live and store consumers, nor do they say how a conflict found
only by the durable path becomes the required presentation gap without changing store status. A
duplicate after live eviction or while storage is unavailable therefore has several plausible and
incompatible outcomes.

**Required artifact changes:**

1. State the exact duplicate-detection horizon. If the guarantee applies only while a key is in the
   ingress/window, narrow the requirement and scenario and define post-eviction behavior. If it
   applies for the runtime, define the bounded authority that remembers or resolves evicted keys.
2. Define one classification/linearization owner before store/live effects, or an explicit
   store-to-projection conflict result, so identical/conflicting duplicates produce one consistent
   first-wins outcome and never turn an expected presentation conflict into store corruption.
3. Define conflict-gap identity, saturation/coalescing, and behavior when the first observation is
   pending in ingress, retained in the window, already durable, evicted, or accepted while storage
   is unavailable/recovering.
4. Extend tasks/tests across all of those states, including a duplicate straddling drain, eviction,
   recovery, and shutdown, and assert exact store status/rows, live rows/gaps, and protocol state.

### R2-CT3 — Medium — `noLongerConnected` depends on an undefined terminal cache

The revised target taxonomy classifies an exact token in a “bounded terminal cache” as
`noLongerConnected`, while expired-recent or never-owned tokens are `invalidTarget`
(`design.md:284-294`; both control delta requirements). The cache has no normative key, count, TTL,
eviction order, token-issuance rule, or relationship to the existing recent-device presentation.

That relationship matters during reconnect. The canonical/current recent store is capped at 64 for
30 seconds, is keyed by logical route, and a successful same-route handoff removes the prior recent
row (`openspec/specs/viewer-multidevice-flow-control/spec.md:44-48`;
`ViewerMultiDeviceSessionManager.swift:18-28,37-40,184-185`). If the new terminal cache is merely
that route-keyed row, reconnect can erase the old exact connection before its token is classified,
yielding `invalidTarget` even though the control scenario requires a target that lost ownership to
report `noLongerConnected` or `notActive`. If it is a separate exact-connection cache, its resource
and cleanup contract is missing.

**Required artifact changes:**

1. Define whether control tokens are opaque manager-issued capabilities or reconstructible field
   values, and how the manager distinguishes never-owned from previously issued without unbounded
   history.
2. Define the exact-connection terminal cache key, maximum count, TTL boundary, deterministic
   eviction, reconnect behavior, and shutdown clearing, or remove the cache dependency and specify
   another bounded authoritative classification.
3. Ensure a new connection on the same logical route never retargets the old token and cannot erase
   the evidence needed for the promised old-token result before the defined cache boundary.
4. Add tasks/tests for same-route reconnect before send, 64/65 terminal entries, equal disconnect
   times, exact TTL boundary, early capacity eviction, wrong/never-issued token, retry/identity reset,
   and shutdown, with one deterministic result for each old token.

### R2-CT4 — Medium — Two normative scenarios still contradict the revised mechanisms

The revised catalog contract deliberately removes mutable activity ordering and uses immutable
descending recording row ID (`design.md:124-130`; local-store delta `spec.md:77`; task 2.4). However,
the catalog scenario still requires continuation by an “activity/row-ID keyset”
(`specs/viewer-local-store-search/spec.md:89-93`). Both cannot be the conformance oracle.

The revised query arbiter also forbids transferring or concurrently refreshing the interactive
query lease: it creates an immutable filtered-export scope and export acquires its own lease
(`design.md:111-122`; local-store delta `spec.md:75`). The explorer export scenario still says the
“existing frozen query traversal streams” the result
(`specs/viewer-event-explorer-control/spec.md:106-110`), which can be read as the exact shared-
traversal behavior CT1 removed.

**Required artifact changes:**

1. Change the catalog scenario to the immutable descending row-ID keyset and unchanged frozen
   traversal/restart contract; remove “activity” from the expected result.
2. Change the export scenario to say the arbiter creates an immutable scope from the current frozen
   query/bounds and the export reader streams it under its independent export lease. Do not call the
   interactive traversal itself the streaming owner.
3. Add explicit conformance assertions for both scenario wordings so tests cannot implement the
   superseded activity order or shared mutable query lease.

## Verified Resolutions and Evidence Sufficiency

No additional actionable correctness finding remains in these revised areas:

- coordinator-generation retirement, operation-token cancellation, traversal serialization, exact
  lease release, and independent filtered export;
- frozen gap-lane membership, revision/keyset identity, bounded device merge, and no fabricated
  monotonic placement;
- deterministic causality ordering, truncation, row-ID cycle identity, schema index, and work/plan
  gates;
- Pause-before-freeze, refresh cadence, resident eviction/reload, late-result rejection, and the
  named finite cleanup receipt;
- shared receive timestamps, live metadata/presence projection, explicit durable-only FTS guidance,
  bounded evaluator work, and differential predicate coverage apart from the missing source/device
  query representation in R2-CT1;
- revision-bound history mutations, disclosure-before-save, atomic export destination, transient
  export exclusion, and truthful mailbox-history timing; and
- selected-inspector-only content accessibility, content-free reflection/logs/preferences/recent
  rows, and zero clipboard actions.

Tasks 6.1 through 6.9 are otherwise proportionate and name deterministic races, large-history
plans, maximum shapes, counter/heap/cadence evidence, blocked cleanup, packaging, documentation, and
strict validation. The required additions above must be incorporated before task 1.2 can pass.

## Source Modification Boundary

No production or test source was modified by this review. Only this round-2 evidence report was
added.
