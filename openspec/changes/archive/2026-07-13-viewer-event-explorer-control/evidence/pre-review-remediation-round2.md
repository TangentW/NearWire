# Pre-Implementation Review Remediation — Round 2

## Status

The active artifacts were revised after all three round-2 reports. This document maps each
round-2 actionable finding to the new normative contract. It is not approval evidence;
implementation remains blocked until a fresh independent round reports zero unresolved findings.

No production or test source was modified.

## Correctness and Testing

### R2-CT1 — Source-neutral current-live query

Resolved by defining immutable Viewer-internal `ViewerExplorerScope` and `ViewerExplorerFilter`
values. Source is exact current runtime logical ID or positive historical recording ID; device scope
is All or 1 through 16 exact logical IDs. Current logical IDs are connection IDs and durable catalogs
expose the same `DeviceSessions.logicalID`.

One immutable materialization snapshot maps current runtime/device logical IDs to durable row IDs.
Live matching always retains the complete logical selection. SQL compilation creates the existing
`ViewerEventQuery` only for mapped durable IDs, creates no durable query when no selected device is
mapped, and never substitutes synthetic IDs or widens a selected-device filter. Current-to-durable
transition is one presentation-generation replacement that preserves logical selection and accepts
only the exact runtime. Tasks 4.2 and 6.3 now require no-parent, partial materialization, all selection
cardinalities, filter races, reconnect, transition, and differential coverage.

### R2-CT2 — Duplicate/conflict horizon and linearization

Resolved by making the composite journal's live ingress index the first linearization owner before
fan-out. Exact equality uses the durable Event projection and initial disposition; it excludes
session invariants/metadata, deterministic accounting, and newly sampled Viewer receive times and
cannot rely on a hash alone.
Pending/retained identical values are idempotent and conflicts preserve the first without store
fan-out.

Live eviction explicitly ends the bounded duplicate horizon and already emits an overflow marker.
No key tombstone is retained. If a durable row exists, the writer is the second authority: identical
removes the later transient candidate; conflict preserves the immutable durable row, removes the
candidate, adds a bounded marker, and does not make storage unavailable. If neither live nor durable
state retains the first value, the artifacts make no post-eviction global first-wins claim. Marker
identity/coalescing/saturation and pending/drained/durable/outage/recovery/shutdown cases are now
normative and covered by tasks 3.2 and 6.3.

### R2-CT3 — Exact terminal capability cache

Resolved by replacing reconstructible tokens with manager-issued opaque memory-only capabilities
containing random token UUID, runtime ID, manager generation, and connection ID. Active capability
ownership is bounded by 16 sessions. Terminal entries use a separate exact-connection cache capped
at 64 and retained only while elapsed monotonic time is below 30 seconds; equality expires and
capacity eviction uses terminal time then token UUID.

Same-route reconnect issues a new capability and cannot remove or satisfy the old entry. The cache
is independent of route-keyed recent presentation and clears on shutdown/full reset. Never-issued,
expired, evicted, wrong-generation, and reset-cleared capabilities are deterministically invalid;
only an exact retained terminal capability is `noLongerConnected`. Tasks 3.5 and 6.4 now cover the
complete boundary/race matrix.

### R2-CT4 — Stale normative scenarios

Resolved in both scenarios:

- recording catalog continuation now uses immutable descending recording row ID inside one
  unchanged frozen traversal and requires restart after relevant change; and
- filtered export now freezes an immutable scope in the arbiter, then streams it on the dedicated
  export reader under an independent finite lease.

The same corrections resolve architecture findings R2-1 and R2-2 and security/documentation finding
R2-SPD5's stale catalog wording.

## Security, Performance, and Documentation

### R2-SPD1 — Schema migration resource governance

Resolved by a dedicated serial off-MainActor, writer-only migration executor and exact token. The
schema-1 upgrade uses one index statement at a time, a 32-MiB cache target, no application row array,
and system-default-VFS disk sorting only after the process-provided sandbox/private temporary root is
verified current-user-owned, mode 0700, and nonsymlink. NearWire never mutates process-global SQLite
or environment temporary-directory routing and adds no custom VFS. Sorter files contain index keys,
not Event JSON, and the joined receipt requires no remaining sorter file descriptor. Normal SQLite
connections remain memory-only for temporary storage.

Checked preflight requires `512 MiB + 6 * allocated(main + WAL + SHM)` free space on both the
database and OS temporary volumes, once if identical. Progress checks occur within each 10,000 VM
instructions and cancel on token invalidation or either volume's 256-MiB remaining-space floor.
Release gates include no more than 128-MiB heap growth on the defined populated fixture and
250-ms acknowledgement of injected in-SQLite cancellation; total duration is diagnostic because it
scales with history. Safe phases are fixed and content-free. Persistence/query/export remain
unavailable while networking/live projection may continue. One automatic attempt is allowed per
process; later work requires explicit Retry Storage or a new launch, with no spin.

All indexes, plans/probes, and version publication remain inside one transaction. Cancellation,
termination, space/resource failure, injected index failure, or final validation failure rolls back
to probe-valid schema 1, cleans migration artifacts, and publishes no schema 2. Tasks 2.1, 6.1, 6.8,
and 6.9 now require the resource, rollback, status, filesystem, retry, and recovery evidence.

### R2-SPD2 — Log/table renderer bounds and untrusted labels

Resolved with exact independent contracts:

- log: 1-MiB input, one message, 64-KiB output in 4-KiB chunks, 100 ms, and 512 accessibility bytes;
- table: 1-MiB/4,096-entry/100-ms scan, 64-row pages, 128 retained descriptors, 512-KiB derived
  text, 256/1,024-byte key/value previews, 512 focused accessibility bytes, and explicit `hasMore`;
- neither retains copied complete values beyond the canonical detail buffer; and
- structured labels visibly isolate content and escape C0/C1 and bidirectional-formatting scalars,
  while exact content remains available through bounded raw navigation.

Tasks 4.4 and 6.5 now require maximum entry/key/message, mixed scalar, control/bidirectional,
VoiceOver, cancellation, memory/count, and stale-publication evidence.

### R2-SPD3 — Composer JSON and TTL bounds

Resolved by the checked JSON editor formula
`min(active content limit, (min(active model limit, 16,777,216) - 65,536) / 4)`, reserving Core's
model expansion and the Viewer hard single-Event limit. Smaller target negotiation remains an
authoritative queue decision. TTL is a `UInt64`-backed numeric editor whose adapter accepts at most
nine ASCII digits, no signs/whitespace, and only the active Core range.

Tasks 4.5 and 6.4 now require content/model/queue boundaries, a larger model than content limit,
multibyte replacement, over-cap paste, TTL syntax/range/overflow, MainActor storage/copy counts,
privacy/reflection, and shutdown coverage.

### R2-SPD4 — Complete resident-content cleanup

Resolved by requiring the finite cleanup receipt, after joining producers, to clear resident
selections, canonical Event detail, every raw/tree/log/table/numeric derived value and renderer
selection, search/path/comparison/composer input, user-text validation failure, focused accessibility
value, coalescer, and live value before release. Persisted recording metadata remains store-owned.

Every new content-bearing scope/filter/input/prepared/detail/renderer value has redacted description,
debug description, and mirror and is excluded from logs, analytics, preferences, recent rows,
restoration, and clipboard. Task 6.7 now checks all buffers after every stop/reset/replacement path
and again after a fresh runtime starts.

### R2-SPD5 — Evidence criteria

Resolved by design decision 13 and task 6.9. Every normative count, byte, logical deadline,
generation, token, VM-step, page/cursor/wake, and lease bound is release-blocking. Migration uses the
defined 100,000-Event/10,000-gap fixture and exact memory/cancellation gates. Live uses 100,000 offers
and exact ownership/operation/wake gates. Plans, logical clocks, renderer limits, and composer encode/
traversal/copy counts are asserted. Callback wall time and whole-process heap are diagnostic machine
context only and must be paired with structural gates; documentation cannot present them as product
guarantees.

## Validation

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  — exit 0, `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` — exit 0 with no output.
- stale-term scan for the superseded activity cursor, traversal-owned export, Core-model JSON cap,
  undefined terminal cache, and shared-model wording — no active artifact match.
- `git status --short` — only the active OpenSpec change directory is untracked; no production or
  test source was modified.

The change remains blocked at task 1.2 pending a fresh independent round.

## Post-Remediation Self-Audit Clarifications

Before round 3 began, the normative artifacts were tightened further:

- live-ingress rejection now returns an explicit `untracked` result, still submits to the serial
  writer, and makes no content/duplicate claim if storage is also unavailable;
- duplicate equivalence uses the exact stored projection and initial disposition, excludes newly
  sampled Viewer receive times, deterministic accounting, and session invariants/metadata, and does
  not trust a hash;
- target terminal ordering is explicit: terminal before manager capability lookup yields
  `noLongerConnected`, lookup first followed by terminal before session active check yields
  `notActive`, and enqueue first remains `queued`; and
- log object matching now scans at most 4,096 top-level entries under its existing 1-MiB/100-ms
  limits.

After the initial round-3 feasibility check, the migration contract was corrected again: the prior
migration-only Application Support temp directory was removed because system SQLite exposes no safe
per-connection temp-directory switch. The current contract uses verified OS-selected process temp,
does not touch the discouraged process-global `sqlite3_temp_directory`, and gates both involved
volumes and descriptor cleanup.

The round-3 clipboard wording was also reconciled. Standard user-invoked paste/copy/cut is permitted
only within operator-owned editable inputs and paste remains subject to pre-storage caps. NearWire
does not monitor/read the pasteboard in the background or retain clipboard history, and received or
stored Event inspector content has no clipboard/drag/share export action.
