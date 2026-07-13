# Pre-Implementation Correctness and Testing Review — Round 3

## Verdict

**Approved for implementation.** The current proposal, design, task plan, and three delta
specifications define deterministic outcomes for every previously reported correctness/testing
failure and for the additional round-3 race, migration, rendering, input, and cleanup checks.

| Severity | Unresolved count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| **Total actionable** | **0** |

This approval is limited to the pre-implementation artifacts. Each implementation checkbox still
requires its stated evidence, and implementation completion still requires the independent reviews
and requirement-to-evidence audit in tasks 7.1 through 7.3.

## Scope and Method

This review independently reread the latest proposal, design, tasks, and all delta specifications,
then reread all round-1 and round-2 architecture/API, correctness/testing, and
security/performance/documentation reports plus both remediation reports. The remediation reports
were treated as claims to verify, not as approval evidence.

The review replayed every CT1 through CT7 and R2-CT1 through R2-CT4 failure condition against the
current normative text. It also inspected the present query model/compiler, Event duplicate lookup,
store runtime, session manager/recent-row implementation, and Core Event limits to confirm that the
new requirements have implementable seams and deterministic tests rather than merely descriptive
UI behavior.

## Prior Correctness Finding Disposition

| Prior finding | Round-3 disposition | Independent basis |
| --- | --- | --- |
| CT1 — Query cancellation and lease ownership | Resolved | One runtime-owned explorer gateway binds every operation and lease to its originating coordinator generation. One non-MainActor arbiter solely owns traversal/lease mutation; enqueue-to-completion tokens make queued, completed, superseded, and successor cancellation distinct; filtered export receives an immutable scope and independent export lease. Tasks 2.2, 2.3, 6.1, 6.6, and 6.7 cover the required races and exact release. |
| CT2 — Store/live filter oracle and exact-key behavior | Resolved | One normalized observation supplies the same receive times, Event, initial disposition, identity, and frozen metadata to store/live paths. Presence scopes, unavailable-data behavior, durable-only FTS, bounded live work, and SQLite/live differential tests are closed. Source representation and duplicate horizon are separately verified below. |
| CT3 — Frozen catalog membership/order | Resolved | Recording order is immutable descending row ID; device order is connection ordinal plus row ID. Cursors bind upper bounds, generations, direction, and fingerprint. Relevant mutation requires an explicit first-page restart, narrowing continuity to one unchanged snapshot. Tasks 2.4, 6.1, and 6.2 include equal-boundary, mutation, bidirectional, and stale-cursor coverage. |
| CT4 — Gap membership/placement | Resolved | Gaps use a distinct diagnostic lane bound to the Event traversal lease, device scope, and frozen gap upper row ID. Stable identity, latest-revision selection, deterministic wall-time/row-ID order, 32-row page, 128-row residence, and bounded 17-lane selected-device merge replace the former approximate Event placement. |
| CT5 — Causality determinism | Resolved | Lookup binds recording, exact device, traversal lease, and frozen Event upper bound; candidates use durable row-ID order and a nine-row truncation probe; breadth-first expansion is reply-to before correlation, uses row ID for visited/cycle identity, and stops at 32 nodes. Task 6.2 covers 0/1/2/8/9+ matches and true/false cycles. |
| CT6 — Pause/shutdown generations | Resolved | Pause increments presentation generation before freezing. Source/filter/Pause/Resume/Jump share one state machine, stale traversal release is exact-once, and runtime/attempt generations gate every background completion and control admission. The finite cleanup receipt cancels, joins, clears, and releases all named content-bearing work; task 6.7 exercises every stop/reset/replacement path. |
| CT7 — Target classification/races | Resolved | Manager-issued opaque capabilities, duplicate-token handling, ordered per-target results, manager/session authority, exact terminal lookup ordering, and enqueue-first truthfulness form a closed result API. The separate terminal cache and its tests resolve the remaining round-2 dependency. |

## Round-2 Correctness Finding Disposition

### R2-CT1 — Source-neutral scope and partial materialization

Resolved. `ViewerExplorerScope` represents either an exact current runtime logical ID or a historical
recording and either All Devices or 1 through 16 exact device logical IDs. It is authoritative with
`ViewerExplorerFilter`; the existing SQL-only `ViewerEventQuery` is only a compiled durable form.

The materialization contract is unambiguous for every state:

- live evaluation retains the complete logical selection;
- SQL receives only selected devices that have exact positive durable mappings;
- no durable Event query is issued when none of the selected devices is mapped;
- All Devices uses the mapped recording without inventing a device predicate; and
- a mapping change increments presentation generation, atomically replaces traversal, preserves the
  logical selection, and cannot admit another runtime.

This directly fits the present seam, where `ViewerEventQuery` requires a positive recording row ID
and represents devices only as durable `[Int64]` values. Tasks 4.2 and 6.3 explicitly cover no
durable parent, partial materialization, one/2-through-16/all selection, filter replacement,
reconnect, and the current-to-durable transition.

### R2-CT2 — Duplicate comparison, linearization, and bounded horizon

Resolved. The current requirements define one classification sequence across ingress, projection,
and store:

1. The composite journal offers the immutable normalized observation to the live exact-key index
   before either fan-out effect.
2. Pending or retained identical values are idempotent; a conflicting value preserves the first,
   creates one bounded exact-key marker, and bypasses store fan-out.
3. Ingress capacity rejection records a saturating gap and returns `untracked`, but still submits the
   observation to the serial writer. If storage is unavailable too, no content or duplicate claim is
   retained.
4. Eviction deliberately ends live authority, is disclosed by the existing overflow marker, retains
   no tombstone, and permits a later transient candidate to become the bounded first value.
5. An existing durable row is the second authority: identical is a no-op; a field/byte conflict
   preserves the row and returns content-free `journalConflict` without changing store availability.
6. If neither bounded authority retains the original value, no global post-eviction first-wins claim
   is made.

The complete duplicate equivalence is exact Event envelope/content, initial disposition, and frozen
session metadata; the later observation's newly sampled Viewer wall/monotonic receive times are
excluded and the first times remain authoritative. The local-store delta's “different compared
field” and the multi-device delta's complete equality definition therefore produce the same durable
decision without trusting a hash.

This contract intentionally requires replacing the current `existingEventID` behavior, which
compares Viewer receive times and converts a mismatch into `corruptStore`. Tasks 3.2, 3.3, 6.3, and
6.9 require the bounded ownership, identity/equality, drain, eviction, outage/recovery, reconnect,
row/status, and callback-operation evidence needed to catch that regression.

### R2-CT3 — Exact target capability cache

Resolved. A capability is manager-issued, opaque, memory-only, and bound to random token UUID,
runtime logical ID, manager generation, and connection ID. Active ownership is bounded by 16. On
terminal, the exact capability moves to a separate connection-keyed cache with a 64-entry maximum,
`elapsed < 30 seconds` retention, equality expiry, and oldest-terminal-time then token-UUID lexical
eviction. Same-route reconnect issues a new token and neither removes nor satisfies the old entry;
shutdown and full identity reset clear the cache.

Classification order is now testable on the manager's serial executor: terminal before capability
lookup finds the terminal cache and returns `noLongerConnected`; lookup first followed by terminal
before the synchronous active check returns `notActive`; committed enqueue returns `queued` even if
terminal follows. The cache is explicitly distinct from the current route-keyed recent-row
presentation, so the existing reconnect removal behavior cannot accidentally implement it. Tasks
3.5 and 6.4 cover 64/65 entries, equal times, the exact 30-second boundary, reconnect, eviction,
reset/shutdown, malformed/never-issued tokens, and all terminal/queue races.

### R2-CT4 — Stale normative scenarios

Resolved. The recording-catalog scenario now requires immutable descending row-ID continuation in
one unchanged frozen traversal and restart after relevant mutation. The filtered-export scenario now
requires the arbiter to freeze an immutable scope and the dedicated export reader to stream it under
an independent finite lease. Neither scenario retains the removed activity key nor the removed
shared mutable traversal behavior.

## Additional Round-3 Verification

### Migration rollback, cancellation, and retry

The schema-1-to-2 path is a single off-MainActor writer-only operation with an exact token, private
owner-only nonsymlink disk-backed migration temp area, one index statement at a time, 32-MiB cache
target, checked free-space formula, 256-MiB live floor, and progress checks within each 10,000 SQLite
VM instructions. Readers remain closed until final acceptance.

All three indexes, plans/probes, and `user_version=2` remain in one transaction. Cancellation,
termination, resource failure, injected index failure, or validation failure must roll back to
probe-valid schema 1, publish no schema 2, remove artifacts, and join cleanup. Automatic attempt is
once per process; only explicit Retry Storage or a later launch can try again. Tasks 2.1, 6.1, and
6.9 provide exact near-capacity/overflow, every failure point, cancellation acknowledgement,
termination/recovery, filesystem, retry, plan, heap, and post-state evidence.

### Renderer and input determinism

Raw, tree, log, table, and numeric rendering now have independent input, scan, derived-byte,
row/node, preview, accessibility, logical-time, cancellation, and retained-value limits. In
particular, log object lookup scans at most 4,096 top-level entries under the 1-MiB/100-ms limits,
and table rendering has explicit paging, descriptor, copied-text, preview, accessibility, and
`hasMore` behavior. Structured labels isolate untrusted text and escape C0/C1 and bidirectional
formatting scalars while bounded raw navigation retains exact content.

The composer cap uses checked nonnegative arithmetic against both active Core limits and the Viewer
16-MiB model ceiling. Core currently validates model capacity as at least four times content plus
65,536 bytes, so the formula has a valid implementable basis. TTL's `UInt64`, nine-ASCII-digit,
no-sign/no-whitespace, active-range contract covers the Core maximum of 604,800,000. Tasks 4.4, 4.5,
6.4, 6.5, and 6.9 include maximum shapes, 100,000-entry objects, controls/bidirectional text,
VoiceOver, multibyte edits, over-cap paste, TTL syntax/overflow/range, cancellation, stale
publication, retained-buffer counts, and exactly-once encode/traversal/copy evidence.

### Cleanup and privacy observability

The cleanup receipt first closes new content/control admission and invalidates generations, then
cancels and joins every named producer. Before exact lease release it clears selections, canonical
detail, all raw/tree/log/table/numeric derived values and renderer selections, filters and composer
inputs, user-text validation failures, focused accessibility content, coalescer state, and live
values. Redacted description, debug description, and mirror requirements also apply to cancelled
content-bearing values. Task 6.7 verifies every buffer and subscription after every stop/reset/
replacement path and again after a fresh runtime, including absence of late enqueue, presentation,
or accessibility publication.

## Evidence and Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  exited 0 with `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` exited 0 with no output.
- A stale-term scan found no active artifact requiring the superseded activity/row-ID keyset,
  traversal-owned filtered export, or an undefined shared terminal cache.
- `git status --short` showed only the untracked active OpenSpec change directory. No production or
  test source was modified by this review.

All normative counts, bytes, logical deadlines, generations, tokens, VM steps, pages, cursors,
wakes, and leases are release-blocking under design decision 13 and task 6.9. Wall-clock callback
latency, total migration duration, and whole-process heap remain diagnostic context unless paired
with the specified deterministic gates.

## Conclusion

There are **zero unresolved correctness/testing findings** in the current pre-implementation
artifacts. The change may pass this review dimension of task 1.2 once the other independent round-3
review dimensions also report zero unresolved findings.
