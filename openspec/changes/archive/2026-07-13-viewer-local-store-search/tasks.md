## 1. Change Gate

- [x] 1.1 Complete and strictly validate the proposal, design, new capability spec, modified multi-device capability spec, and task plan before modifying production or test source.
- [x] 1.2 Obtain lightweight independent architecture/API, correctness/testing, and security/performance/documentation reviews of the artifacts and resolve every actionable finding.

## 2. SQLite Foundation and Schema

- [x] 2.1 Link only system SQLite in the Viewer Xcode project and implement one serial writer, one serial query reader, and one serial export reader with generation-bound interrupt/progress cancellation; owner-only nonsymlink Application Support/main/WAL/SHM/journal/migration/temp paths; defensive/trusted-schema/secure-delete configuration; memory-only SQLite temporaries; bounded busy/VM/time work; checked bindings; safe errors; schema migration/probes; rollback; and exact cleanup.
- [x] 2.2 Implement schema version 1 for immutable recording/device bases, installation/device alias ordinals, immutable Events, append-only recording/device/disposition/policy/drop/gap/annotation versions, store metadata, tombstones, and external-content FTS with nonreused AUTOINCREMENT IDs, deterministic JSON, receive/admission ordering, quota accounting, and no raw wire/security/session-epoch persistence.
- [x] 2.3 Implement bounded versioned storage preferences for 3 GiB and seven-day defaults, validated configurable ranges, injected `UserDefaults`, safe corruption recovery, and explicit `historyRetention` naming.

## 3. Bounded Recording Integration

- [x] 3.1 Implement the 4,096-record/32-MiB default and 8,192-record/64-MiB hard Event ingress, separate 36-value structural lane, normal 256-record/4-MiB writes, one-record 20-MiB oversize mode, one drain plus one dirty successor, precomputed constant-time reservations, coalesced gaps, nonpolling write-failed/capacity-paused states, explicit retry, and latest-only safe notifications.
- [x] 3.2 Integrate stable logical recording/device contexts with conditional causal durable admission. Cover unavailable start, partial mid-runtime retry, devices ended during outage, structural close reservation, one-recording-group/eight-turn orphan reconciliation with at most 16 child closes before atomic parent close and nondurable fallback, corruption handling, idempotent revisions, pairing refresh, and finite shutdown ownership through the existing receipt.
- [x] 3.3 Add immutable uplink Event commits uniquely keyed by recording/device/direction/wire sequence plus sequence-keyed idempotent terminal transitions for consumer acceptance, later expiry/displacement, and session clear; treat peer Event UUID as nonunique content; add committed downlink mailbox observations, changed policy/drop samples, transition-loss gaps, and precomputed copy-on-write admission. Prove maximum Events/batches and store pressure cannot mutate/block protocol ownership.

## 4. Retention, Capacity, and Session Operations

- [x] 4.1 Implement startup/settings/session-close/threshold/one-wake maintenance with at most eight turns per trigger; 32-session transactional tombstone selection; deterministic schema-owned quota accounting; retention-first/85% selection; active/pinned/leased protection; and rollback of each logical-selection transaction.
- [x] 4.2 Implement 1,024-row/4-MiB normal physical reclaim plus one-record Event/FTS reclaim up to 41 MiB, impossible-head isolation, tombstone resume after failure, checkpoint/free-page optimization between turns, filesystem available-capacity safety, distinct quota/allocated-footprint status, exact 85%/100% exhaustion behavior, capacity pause/resume, and no automatic recreation or over-delete on checkpoint failure.
- [x] 4.3 Implement exact name/note/append-only annotation bounds, pin/unpin, and revision-bound manual-delete confirmation, rejecting active/leased/stale targets and tombstoning an exact pinned closed session only after matching confirmation.

## 5. Search, Pagination, and Export

- [x] 5.1 Implement normalized query models and a parameter-only compiler for all required dimensions, literal quoted FTS terms, binary `substr` Event-type prefix, `instr` JSON containment, closed JSON paths/scalars, exact AND/OR semantics, NUL/control/Unicode/wildcard/operator handling, canonical fingerprints, and hard bounds.
- [x] 5.2 Implement 1-through-200-row short-transaction keyset pages with at most eight finite recording leases, frozen upper Event/recording-version/device-version/transition/gap/drop IDs, nonreused row IDs, explicit forward/backward tuple inequalities, covering-index/EXPLAIN-plan gates against unbounded temporary sorts, per-page VM/250-ms budgets, generation-bound cancellation, no `OFFSET`, point detail, and safe latest-only change signals.
- [x] 5.3 Implement one finite export lease and dedicated short-transaction reader with frozen base-device/base-alias and append-only table AUTOINCREMENT row-ID bounds, 60-minute lifetime, per-page VM/one-second budgets, stored installation/device ordinals used only as aliases rather than snapshot bounds, 200-row/64-KiB memory bounds, bounded preflight disclosure metadata/forbidden-field rules, owner-only nonsymlink temporary files, cancellation at every phase, atomic replacement, and parent-directory synchronization.

## 6. Application and Settings Surface

- [x] 6.1 Compose the live store/coordinator with runtime construction, multi-device ownership, application shutdown, safe retry, and dependency injection without introducing a second session/protocol owner or a Core/SDK persistence dependency.
- [x] 6.2 Add a native storage settings/status surface for capacity, `historyRetention`, usage, oldest history, pinned usage estimate, estimated retention, store state, cleanup, and retry with bounded accessible English presentation and no Event/query/path/SQL values.
- [x] 6.3 Keep history lists, Event timeline/detail, search/filter UI, renderer registry, pause-rendering, pin/delete workflows, export selection, control composition, and performance charts absent while exposing internal seams for `viewer-event-explorer-control`.

## 7. Tests, Documentation, and Evidence

- [x] 7.1 Add deterministic SQLite tests for connection ownership, first creation/reopen/migration/unknown schema, probes, bindings, Event/append-only round trips, rollback, busy/full/I/O/corruption, generation-cancel races, progress budgets, statement finalization, main/active-sidecar/temp permissions and symlink rejection, secure-delete configuration/disclaimer, and safe reflection.
- [x] 7.2 Add recording/cleanup integrations for unavailable start/retry/end/crash reconciliation; lifecycle-control saturation; initial/transition dispositions and loss; downlink commit; maximum observation/oversize boundaries; 1/4/8/16-device contention; ingress/gaps/failure; exact retention and 85%/100% quota cases; bounded huge-session tombstone/reclaim; WAL/checkpoint/volume failure; leases; protected data; revision-safe delete; pairing refresh; and shutdown.
- [x] 7.3 Add proportional compiler truth-table/pairwise query tests, exact literal `%`/`_`/backslash/quote/operator/comment/NUL/control/Unicode semantics, JSON bounds, both-direction frozen keyset traversal with equal times/new inserts/new transitions/deletion leases/expiry, operation-cancel races, many-device/many-Event export, sustained writes, lease expiry, forbidden-field/disclosure fixtures, bounded memory/VM/WAL ownership, and cancellation/atomic-file phases.
- [x] 7.4 Add application/presentation tests and English storage/operator documentation covering schema, quota versus allocated footprint, logical retention versus Event TTL and secure erasure, main/sidecar ownership, gaps/reconciliation, failure recovery, exact text limits, unencrypted local data/exports, pseudonym-not-redaction and outside-quota/sync/backup disclosure, privacy rationale, exclusions, and the next Viewer change.
- [x] 7.5 Build and test the Viewer scheme and all affected package suites; inspect SQLite linkage, app-container files/permissions, built privacy manifest, root SwiftPM/CocoaPods manifests, format/language/structure boundaries, strict OpenSpec validation, and save exact current-tree commands/results under the change `evidence` directory. Do not add a new shell harness.

## 8. Independent Completion Review

- [x] 8.1 Obtain independent architecture/API, correctness/testing, and security/performance/documentation implementation reviews and save each report.
- [x] 8.2 Fix every actionable finding, rerun affected validation, and repeat all three review dimensions until a fresh round reports zero unresolved findings.
- [x] 8.3 Complete the requirement-to-evidence audit, archive `viewer-local-store-search`, verify canonical specs and archived evidence, and commit the completed change before starting `viewer-event-explorer-control`.
