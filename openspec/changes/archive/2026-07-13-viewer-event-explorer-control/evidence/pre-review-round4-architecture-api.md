# Pre-Implementation Architecture and API Review — Round 4

## Verdict

**Approved for implementation.** The current proposal, design, task plan, and three capability
deltas resolve the round-3 migration and duplicate-authority findings, including the later
durable-representation correction. The planned interfaces remain implementable from the current
Viewer/Core seams without a schema expansion, wire-format change, public SDK/Core API, custom
SQLite VFS, or process-global temporary-directory mutation.

| Severity | Unresolved count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| **Total actionable** | **0** |

This is approval of the pre-implementation artifacts only. Source changes, tests, evidence,
independent implementation review, the spec-to-evidence audit, and archival remain required by the
task plan.

## Scope and Method

This review independently reread the current proposal, complete design, task plan, and all three
delta specifications. It also reread the prior architecture/API, correctness/testing, and
security/performance/documentation reports and the round-1 through round-5 remediation records.
Historical reports were used only as finding indexes; the current normative artifacts were the
approval authority.

The review then checked implementability against the current runtime/session ownership, store
runtime and reopen boundary, SQLite pool/connection/schema, Event preparation and durable journal,
query/export, and Core/transport Event-validation seams. No production or test source and no
artifact other than this report was modified.

The generic review skill's referenced repository checklist is not present in this workspace, so the
repository's `AGENTS.md` workflow and the active OpenSpec artifacts supplied the review gates.

## Focused Round-4 Verification

### Migration uses process-private OS temporary storage without global or VFS mutation

The migration contract is now one finite, two-phase connection lifecycle (`design.md:427-473`;
local-store delta `spec.md:5-15`; `tasks.md:8,41`):

1. A dedicated serial off-MainActor executor opens only a migration writer. Interactive and export
   readers remain closed.
2. That writer uses connection-local disk-backed temporary sorting through the system default VFS,
   a 32-MiB cache target, one index statement at a time, and no application row array.
3. NearWire does not read, set, or mutate `sqlite3_temp_directory`, `temp_store_directory`,
   `SQLITE_TMPDIR`, or `TMPDIR`, and does not register a custom VFS.
4. Before `BEGIN IMMEDIATE`, the process-provided sandbox/private temporary directory must be an
   existing current-user-owned mode-`0700` nonsymlink directory.
5. Checked preflight applies `512 MiB + 6 * allocated(main + WAL + SHM)` independently to the
   database and temporary volumes, once when they identify the same volume. The progress handler
   checks both 256-MiB floors and the exact token within every 10,000 VM instructions.
6. After commit or rollback, the migration writer closes and its executor joins until no sorter
   descriptor remains. The migration writer is never published.
7. Success opens a fresh writer through normal hardening with `temp_store=MEMORY` and an explicit
   8-MiB cache, re-probes schema 2, features, indexes/plans, hardening, and settings, and only then
   opens two equally fresh normal readers. Availability publishes only after the entire pool passes;
   any post-commit open/probe failure closes all fresh connections and remains unavailable.

This closes the prior ownership ambiguity: neither FILE temporary storage nor the 32-MiB migration
cache can cross into the normal pool. System-VFS delete-on-close is paired with an application-owned
close/join receipt and a zero-descriptor requirement rather than being treated as secure erasure.
Task 6.1 requires construction order, both-volume and overflow cases, unsafe temporary-root cases,
unchanged global routing/default VFS, live sorter inspection, key-only contents, cancellation and
rollback, zero descriptors, and post-open settings/probes. The contract is therefore both
implementable and falsifiable.

The current source provides the required seams. SQLite already opens with a `nil` VFS name
(`ViewerSQLite.swift:227-249`), confines handles to serial queues, and has a synchronous close path.
Normal connection hardening already sets `temp_store=MEMORY` (`ViewerSQLite.swift:390-424`), while
the pool construction order is centralized (`ViewerSQLite.swift:507-565`). The existing disk guard
already abstracts volume-capacity lookup (`ViewerSQLite.swift:140-159`). Implementation must split
the current writer-migrate-reader construction into the specified migration-only and fresh-normal
phases, extend the guard to two volume identities, and make descriptor completion observable; none
requires a new runtime dependency or public API.

### Live and durable duplicate authorities use one exactly representable projection

The current design and both affected capability deltas now define the same duplicate contract
(`design.md:175-215`; multi-device delta `spec.md:29-35`; local-store delta `spec.md:15`):

- identity is the exact runtime/connection/direction/wire-sequence key, mapped durably to the exact
  recording/device/direction/wire-sequence key;
- compared values are Event ID/type, canonical content JSON bytes, App-created time normalized once
  to nearest integer milliseconds since 1970, App monotonic time, priority, TTL, schema version,
  correlation/reply IDs, and initial disposition;
- source, target, and session epoch are exact-session transport invariants rejected before journal
  commit, rather than values silently omitted after admission;
- frozen session metadata, deterministic byte accounting, and newly sampled Viewer receive times
  are excluded, with the first observation's accounting and receive values remaining authoritative;
  and
- equality is decided by exact fields/bytes and never by a hash alone.

This projection is durably representable by the existing schema. `Events` stores the key and every
listed Event value, with `createdWallMs` at the specified precision
(`ViewerStoreSchema.swift:202-223`); initial disposition is represented by sequence 0 in
`EventDispositionVersions` (`ViewerStoreSchema.swift:225-234`). Canonical content bytes are already
prepared once (`ViewerEventStore.swift:28-76`). The current ingress validates uplink source/target
and the sequence validator checks the session-bound envelope before journal admission
(`ViewerMultiDeviceSession.swift:691-699`); downlink envelopes are constructed from the owned
session. Thus no schema-2 column, duplicated Event blob, or protocol field is needed.

The current writer comparator still includes Viewer receive times and deterministic accounting, and
its initial-disposition collision check still includes the receive monotonic value
(`ViewerEventStore.swift:1291-1323,1451-1474`). That is expected apply work, not an artifact gap:
task 3.2 requires one shared projection implementation, and task 6.3 explicitly tests metadata,
accounting, receive-time, sub-millisecond normalization, normalized-millisecond conflict,
initial-disposition conflict, invariant rejection, and exact field/byte behavior across pending,
drain, eviction, `untracked`, durable, recovery, and shutdown authority states.

The bounded authority model remains coherent. Live ingress linearizes first while a key is pending
or retained; eviction deliberately ends that authority and emits a horizon-loss marker; an existing
durable row becomes the second authority; and no first-wins promise is made when neither bounded
authority retains the first observation. Typed `journalConflict` preserves store availability and
the immutable first row, while accepted/identical/conflict reconciliation removes only the later
transient candidate.

## Prior Architecture/API Finding Disposition

| Finding | Round-4 disposition | Current basis |
| --- | --- | --- |
| A1 — Runtime-scoped component ownership | Resolved | One per-runtime component factory owns the exact runtime ID, manager, handoff owner, typed control facade, live projection, composite journal, explorer inputs, and cleanup receipt; no application downcast or second protocol owner remains in the plan. |
| A2 — Coordinator-generation store ownership | Resolved | `ViewerStoreRuntime` remains the only application gateway, and originating coordinator generations own operation tokens and leases through seal/cancel/join/release-before-close. |
| A3 — Query arbiter and lease ownership | Resolved | One non-MainActor arbiter owns traversal and interactive-reader tokens; filtered export freezes an immutable scope and uses an independent export-reader lease. |
| A4 — Complete bounded live state | Resolved | Shared observations, exact durable projection, dispositions, bounded metadata/drop/gap state, immutable snapshots, bounded duplicate authority, and joined clearing are all explicit. |
| A5 — Total presentation retention | Resolved | Recording, device, Event, gap, cursor/anchor, selection, detail, renderer, accessibility, input, and derived-content residency retain exact caps and deterministic eviction/cleanup. |
| A6 — Closed downlink admission API | Resolved | Opaque manager-issued capabilities, the distinct bounded terminal cache, manager-serial classifications, encode-once prepared Events, ordered independent results, and no retry/retarget/delivery claim form a closed API. |
| R2-1 — Mutable catalog continuation | Resolved | Catalog continuation uses immutable row-ID/connection-ordinal bounds and explicit restart on relevant change. |
| R2-2 — Filtered export traversal ownership | Resolved | The arbiter freezes an immutable filtered scope; export streams it under a separate exact export lease rather than borrowing the traversal lease. |
| R3-A1 — Migration temporary-directory ownership | Resolved | Default VFS plus verified OS process-private temporary storage, no global/environment mutation, two-volume gates, migration-writer close/join, and a freshly probed normal pool now form one implementable lifecycle. |
| R3-A2 — Live/durable duplicate equality mismatch | Resolved | Both authorities now use the same exactly persisted projection and initial disposition while consistently excluding session metadata/accounting/Viewer receive samples; session invariants are rejected before either comparator. |

## Other Architecture and API Regression Checks

- Runtime shutdown still has one finite ownership chain that stops admission, invalidates
  generations, joins store/live/query/export/renderer/composer producers, clears content, and then
  completes the cleanup receipt.
- Current-runtime and historical scopes remain source-neutral. Partial device materialization does
  not invent durable IDs, omit live selections, or widen a query; exact mappings replace the
  traversal atomically.
- Query cancellation remains successor-safe through enqueue-to-completion tokens. Export retains
  its separate reader and immutable scope, including coordinator replacement and cancellation.
- The downlink control facade remains internal and capability-based. Current lock/session seams can
  be moved to the specified manager-serial classifier without exposing mutable sessions to SwiftUI.
- The change adds no public Core/SDK symbol, wire field, cloud/server role, root-package dependency,
  nested manifest, or third-party Core/SDK dependency. Viewer-only dependency policy is unchanged.
- The inspector clipboard/share restriction and the separately disclosed JSON file export remain
  distinct APIs; operator-owned editable controls keep standard bounded copy/cut/paste behavior.
- All new shared implementation remains assignable to internal Viewer or platform-neutral Core
  seams under explicit Sendable/isolation ownership; no planned API requires lowering iOS 16,
  macOS 13, Swift 5 language mode, or Xcode 16 compatibility.

## Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  completed successfully with `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` completed successfully with no output.
- `git status --short` showed only the active untracked OpenSpec change directory. No production or
  test source was modified by this review.

## Conclusion

There are **zero unresolved architecture or API findings** in the current common artifact snapshot.
This architecture/API dimension of task 1.2 is explicitly **approved for implementation**.
