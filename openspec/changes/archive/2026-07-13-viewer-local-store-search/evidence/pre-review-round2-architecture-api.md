# Pre-Implementation Architecture/API Review — Round 2

Date: 2026-07-13

## Verdict

**Not approved. Exact unresolved actionable finding count: 4 — 2 high, 1 medium, and 1 low.**

Round 1 remediation resolves the broad architecture of the prior findings: durable lifecycle is now conditional on causal store admission; SQLite has independent writer/query/export owners; cancellation and read work are generation/budget bounded; pagination and export use finite leases plus append-only upper bounds; recording/device metadata is versioned; quota selection is deterministic and separate from physical footprint; cleanup uses tombstones and bounded campaigns; and uplink disposition is an append-only state machine. The remaining findings are narrower contract gaps that can still produce incorrect history or prevent physical recovery.

Repository and scope boundaries remain correct. SQLite and every persistence/search/export API stay Viewer-internal, no Core/SDK dependency or nested manifest is proposed, and `viewer-event-explorer-control` UI/control work remains deferred.

## Findings

### 1. High — A caller Event UUID is not a unique durable transition key

The remediated state machine keys an uplink terminal transition by recording ID, device ID, Event ID, and transition kind (`design.md`, Decision 3; `specs/viewer-local-store-search/spec.md`, requirement “Validated bidirectional Event outcomes are journaled without becoming protocol authority”). Neither this change nor the canonical Event model guarantees that an Event UUID is unique for the lifetime of one device connection. It is a syntactically valid caller/wire value; queue uniqueness is only an ownership condition while an entry is pending. The same UUID can therefore appear again at a later contiguous wire sequence after the earlier entry becomes terminal.

Two different durable Event rows with the same Event UUID can then make an identical later transition look like an idempotent duplicate or make different outcomes look like a conflicting second terminal transition. The store cannot identify which immutable Event row owns the transition, so the append-only model still permits incorrect history.

Before implementation:

- key transitions to a store-independent unique committed-record identity, such as recording ID + device ID + uplink sequence, or a locally assigned journal record key retained with the queue entry;
- keep the peer Event UUID as query/export metadata rather than the persistence identity;
- define the database uniqueness/FK rule and how an initial Event observation and later transition correlate before the Event row ID is known; and
- add tests where the same Event UUID is accepted at two later wire sequences with identical and different terminal outcomes, plus duplicate delivery of the same transition observation.

### 2. High — The physical reclaimer has no legal quantum for one oversized Event row

Normal journal writes are capped at 4 MiB but explicitly allow one Event observation up to the 20-MiB hard reservation. Quota accounting can reserve even more for that Event because it uses `2 * deterministicCanonicalEventBytes + 1 KiB`. Physical reclaim, however, is unconditionally described as at most 1,024 child rows or 4 MiB of reserved data per transaction (`design.md`, Decision 5; `specs/viewer-local-store-search/spec.md`, cleanup requirement; Tasks 4.2 and 7.2).

A tombstoned recording whose next child is one legal Event above 4 MiB has no conforming reclaim transaction: deleting it violates the byte quantum, while refusing it leaves the tombstone and its Event/FTS content permanently allocated. That can eventually hold the volume-capacity guard in a paused state even though logical quota was subtracted correctly.

Before implementation, add an explicit one-child oversize reclaim mode bounded by the maximum checked Event quota reservation, or define another finite row-level deletion rule that can remove every legal Event and matching FTS entry atomically. Specify head-of-line behavior and add below/equal/above-4-MiB reclaim tests, a maximum legal Event reclaim, FTS rollback, restart/resume, and volume-pressure recovery.

### 3. Medium — Bounded orphan reconciliation does not specify child-before-parent grouping

Reconciliation is now finite at 32 prior-process open rows per transaction and eight immediate turns, and a new durable recording waits until no prior open row remains. The artifacts do not state how those rows are grouped or ordered. A turn could append a recovered close version for a recording before every open device child of that recording has received its terminal version. Between turns, that creates a closed parent with open children and can make the parent eligible for retention/capacity selection before lifecycle repair is complete.

Before implementation, require reconciliation to process one causal recording group at a time: close all of that recording's open device rows before appending its recording close, and keep a partially reconciled group explicitly protected from normal maintenance. If a group or the eight-turn campaign cannot complete, define its nondurable/recovery status without publishing a false closed lifecycle. Add multiple-crash histories that cross the 32-row and eight-turn bounds, including cleanup triggers between turns.

### 4. Low — The schema-v1 export alias spelling is contradictory

The export design first defines installation aliases as `device-<installationOrdinal>` and device-session aliases as `connection-<deviceOrdinal>`, then states that `device-1`, `device-2`, and so on replace both installation identifiers and device-session IDs (`design.md`, Decision 7). The capability spec requires deterministic aliases but does not settle the exact schema-v1 field values.

Choose one naming contract, state it once in design/spec, and add an exact export fixture. The two namespaces should remain distinguishable if both identifiers can appear in the same document.

## Prior-Finding Verification

- **Conditional lifecycle and retry:** resolved except for Finding 3's multi-turn reconciliation ordering. Unavailable-start, same-runtime retry, ended-during-outage gaps, causal durable admission, reserved structural capacity, and nondurable fallback are now coherent.
- **SQLite ownership and cancellation:** resolved. Writer, interactive query, and export each have a dedicated serial connection/executor; short transactions, progress budgets, generation matching, and late-cancel isolation keep read cancellation away from later operations and the writer.
- **Pagination/export snapshots and WAL:** resolved. Finite leases protect deletion, append-only Event/recording/device/disposition/gap/drop/annotation versions freeze membership, device/installation ordinals are bounded in the snapshot, reader transactions end per page, and the export lifetime fails closed.
- **Quota and cleanup selection:** deterministic logical quota, 85%/100% outcomes, physical-footprint reporting, volume guard, atomic tombstones, bounded turns, and checkpoint behavior resolve the prior metric contradiction. Finding 2 remains in the physical reclaim quantum.
- **Uplink disposition:** immutable Event commit plus one append-only terminal transition resolves the timing contradiction. Finding 1 remains in transition identity, not in the state progression itself.
- **Scope separation:** resolved; no event-explorer timeline/detail/control UI has entered this change.

## Validation

Current-tree commands run during this review:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
git diff --check
```

Results: strict validation passed (`Change 'viewer-local-store-search' is valid`), and `git diff --check` passed with no output.

## Approval Gate

Update the artifacts and task evidence for all four findings, rerun strict validation, and obtain a fresh architecture/API review reporting **0 unresolved findings** before implementation begins.
