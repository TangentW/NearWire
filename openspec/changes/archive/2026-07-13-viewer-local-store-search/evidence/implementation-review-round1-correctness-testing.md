# Implementation Review Round 1 — Correctness and Testing

Date: 2026-07-13

## Scope

This is an independent review of the current uncommitted `viewer-local-store-search` implementation, tests, documentation, OpenSpec requirements, and task plan. No production or test source was modified. This report is the only file added by the review.

The review traced data integrity and ownership through SQLite schema and transactions, protocol-to-journal observations, ingress/drain failure, recording lifecycle and recovery, quota/retention/reclaim, query compilation and pagination, export snapshots and cancellation, application composition, and test evidence.

Severity meanings:

- **High:** can lose or misattribute accepted journal data, delete protected/eligible history incorrectly, violate a fundamental snapshot/lifecycle contract, or make a major required capability materially false.
- **Medium:** a bounded but material race, missing operational contract, or evidence gap that must be resolved before this change can be completed.

## Findings

### NW-LSS-IMPL-CT-001 — High — Uplink journaling is attached after consumer dequeue and the terminal state machine is not integrated

The session commits input sequence and queue state in `admitIncoming`, but emits no journal Event observation there (`ViewerMultiDeviceSession.swift:550-594`). The only App-to-Viewer callback reaches `uplinkSink` after an Event has been dequeued and successfully offered to the single consumer (`ViewerMultiDeviceSession.swift:597-636`). Consequently, buffered Events that later expire, are overflow-displaced, or are cleared at session end never receive the required immutable sequence-commit row. Successfully handed-off Events are immediately prepared as `consumerAccepted` (`ViewerEventStore.swift:37-50`), so the durable model skips the required commit-time `buffered` state rather than appending the later transition.

There is no protocol callback for consumer acceptance, later expiry/displacement, or session clear in `ViewerSessionJournaling` (`ViewerStoreCoordinator.swift:5-14`), and no production caller of `.disposition`. The structural API addresses a transition by SQLite `eventRowID` rather than the store-independent `(recordingID, deviceSessionID, direction, wireSequence)` journal key (`ViewerEventStore.swift:70-79`). Its `ON CONFLICT ... DO NOTHING` path also accepts a same-key different disposition without comparing it (`ViewerEventStore.swift:240-254`); initial disposition does the same (`ViewerEventStore.swift:501-520`). Event duplicate verification compares UUID/type/content but not the complete immutable envelope and receive metadata (`ViewerEventStore.swift:436-453`). These paths cannot enforce the specified idempotent-identical versus conflicting-terminal behavior.

**Required resolution:** publish the immutable Event observation at sequence commit with the exact initial admission result; retain its sequence-keyed journal identity with the live queue entry; publish every later terminal transition; compare the full immutable record and transition on duplicate; treat a conflicting duplicate as store-integrity failure only. Add repeated-peer-UUID/different-sequence, delayed acceptance, expiry, earlier overflow victim, terminal clear, identical replay, conflict, lost initial row, and transition-loss gap tests.

### NW-LSS-IMPL-CT-002 — High — The ingress removes accepted observations before commit and loses them on write failure or shutdown

`drain()` removes one structural value or an entire Event prefix from the protected arrays before any SQLite call (`ViewerEventStore.swift:659-693`). The Event prefix is correctly passed to one `appendEvents` transaction, but if that transaction or a structural write fails, the already-removed value/prefix is discarded, no failed prefix is retained, no gap is produced, and `drainScheduled` is merely reset (`ViewerEventStore.swift:695-703`). A later admission schedules another drain automatically even though the store entered `writeFailed`, contradicting the explicit-retry/nonpolling rule.

The structural lane is an ordinary 36-element array, not coalesced lifecycle state; full-lane closes are silently ignored by callers (`ViewerEventStore.swift:631-638`; `ViewerStoreCoordinator.swift:141-156`). Gap offers can themselves be rejected and are ignored (`ViewerStoreCoordinator.swift:244-256`). `shutdown()` enqueues closes and immediately calls `ingress.stop()`, which clears both arrays without a flush or ownership receipt (`ViewerStoreCoordinator.swift:190-204`; `ViewerEventStore.swift:641-648`).

**Required resolution:** reserve and commit one prefix transactionally, restore the complete uncommitted prefix on rollback, transition once to nonpolling failure, coalesce later loss into a bounded gap, and preserve structural close ownership. Implement a finite asynchronous flush/receipt before stop. Test failure at every Event in a batch, structural saturation, admission while failure races drain completion, explicit retry, gap ordering, and shutdown with pending normal/oversize/structural work.

### NW-LSS-IMPL-CT-003 — High — Recording ownership and orphan recovery do not match one Viewer runtime or append-only child-before-parent repair

The coordinator clears `currentRecording` whenever the last current device disconnects and enqueues a recording close (`ViewerStoreCoordinator.swift:131-156`). A later device in the same Viewer runtime therefore creates a new recording (`ViewerStoreCoordinator.swift:206-215`), contradicting the required single stable recording context across disconnect/reconnect waves. The live coordinator is process-static and its `shutdown()` is never composed into application cleanup (`ViewerRuntimeDependencies.swift:21-55`; repository search finds no production call), so it also lacks the required runtime end boundary.

Unavailable recovery is attempted opportunistically on every received Event, not by an explicit successful retry, and creates a fresh start time rather than retaining a logical context's original identity/start (`ViewerStoreCoordinator.swift:106-128,217-235`). Startup reconciliation directly updates mutable base rows, closes only the first 16 children, and commits even when more remain (`ViewerStoreCoordinator.swift:259-311`). It neither rejects a corrupt seventeenth open child nor appends `recoveredAfterInterruption` child versions followed by one parent version in the same all-or-none group transaction.

**Required resolution:** give the application runtime one logical context independent of connection count and store availability; materialize it causally on explicit retry; end it only at full runtime shutdown. Reconcile one complete group atomically through append-only device versions then the parent version, fail closed above 16 open children, bound group turns, and fall back to nondurable networking rather than failing coordinator construction. Add empty-wave reconnect, unavailable-start/retry, ended-during-outage, original-time preservation, 0/1/16/17-child recovery, rollback, eight-group exhaustion, cleanup exclusion, and shutdown/reopen tests.

### NW-LSS-IMPL-CT-004 — High — Schema V1 mutates snapshot fields and does not provide recording-local aliases or required device metadata

The schema calls recording/device bases immutable but stores mutable end times and `partialHistory` directly in `Recordings` and `DeviceSessions` (`ViewerStoreSchema.swift:71-80,101-114`), while the version tables do not contain the full end/partial/terminal state required to reconstruct a frozen version (`ViewerStoreSchema.swift:82-92,116-125`). Normal close and reconciliation update those bases in place (`ViewerEventStore.swift:219-239`; `ViewerStoreCoordinator.swift:272-294`). Captured recording/device version upper IDs therefore cannot freeze exported or queried lifecycle metadata.

`InstallationAliases` has no `recordingID`; both installation ID and ordinal are globally unique (`ViewerStoreSchema.swift:94-99`). Lookup and ordinal allocation are also global (`ViewerEventStore.swift:331-358`), violating recording-local deterministic aliases and leaving alias rows outside whole-recording ownership. The durable device base omits the bounded Bundle/application correlation fields described by the spec, and the current coordinator collapses application ID/display name into one version display string (`ViewerStoreCoordinator.swift:90-98`).

**Required resolution:** make base identity/start fields genuinely immutable; append end, partial, terminal, nickname, and recording metadata revisions with monotonic conflict rules; scope installation aliases and ordinals to recording ownership; store the required bounded App/Bundle correlation fields; make every recording child reclaimable. Add frozen-before/after-version, cross-recording same-installation, reconnect alias, app metadata, duplicate revision, and whole-recording foreign-key/accounting tests.

### NW-LSS-IMPL-CT-005 — High — Capacity selection can delete history below capacity and does not atomically subtract recording quota

Capacity candidates are selected when global usage is greater than **85%**, not when usage exceeds capacity: the SQL condition is `?2 > ?3`, where `?3` is `capacity * 85 / 100` (`ViewerStoreMaintenance.swift:264-281`). At 86% usage, maintenance may therefore tombstone up to 32 otherwise unexpired sessions even though the required outcome is writable/no capacity deletion. The candidate loop never subtracts projected session usage or stops after reaching 85%; it simply accepts every row returned by the limit (`ViewerStoreMaintenance.swift:282-301`).

The selected size is only `Recordings.quotaBytes`, which remains the fixed base reservation rather than the exact recording total. Tombstoning then **adds** one structural reservation per tombstone to global quota instead of subtracting the selected recordings' exact counters (`ViewerStoreMaintenance.swift:293-307`). `reserveQuota` pauses a write immediately at capacity without first running a bounded cleanup campaign (`ViewerEventStore.swift:408-425`). These errors can over-delete eligible history and still fail to recover writable quota.

**Required resolution:** maintain exact per-recording and global live counters in every insert/delete transaction; select retention first, then capacity only above 100%; decrement projected visible usage session by session toward 85%; atomically tombstone and subtract exact totals; preserve the specified 85–100 and above-100 results; run one bounded campaign before pausing a write. Add exact 85/100/equality, one-large-session, 32-session turn, retention-plus-capacity, protected/leased exhaustion, arithmetic overflow, rollback, and quota-reconciliation tests.

### NW-LSS-IMPL-CT-006 — High — Physical reclaim performs unbounded non-Event cascades and leaks recording-owned alias state

The Event phase correctly filters a tombstone whose impossible head was isolated with `reclaimCursor = -1`, so later tombstones can progress (`ViewerStoreMaintenance.swift:316-343,421-428`). However, after Event rows are gone, `deleteEmptyRecording` deletes all policy, drop, device-version, gap, annotation, recording-version, tombstone, and device rows for the recording in one transaction (`ViewerStoreMaintenance.swift:380-419`). A recording can contain unbounded reconnect/device and version history, so this bypasses both the 1,024-row and 4-MiB turn bounds. Installation aliases are never deleted or quota-subtracted, producing permanent rows and quota leakage. Logical deletion also remains quota-visible until this physical cascade, contrary to tombstone-first accounting.

**Required resolution:** retain the current impossible-head isolation, add a persisted bounded phase/cursor for every remaining child table, delete recording-owned alias rows, and remove the parent only after all child phases complete. Keep logical quota subtraction at tombstone commit and physical footprint separate. Add maximum legal 41-MiB Event+FTS rollback/resume, impossible-head plus later tombstone progress, millions-of-children model bounds, crash at every phase, alias cleanup, quota conservation, and checkpoint-failure tests.

### NW-LSS-IMPL-CT-007 — High — Query semantics and cursors do not implement the specified frozen filter model

`ViewerEventQuery` exposes a global `.all`/`.any` over every predicate (`ViewerStoreQuery.swift:25-36`), allowing OR between independent dimensions even though the requirement is AND across dimensions and OR only within selected values of one dimension. Required App/Bundle scope, terminal/gap/drop presence, JSON existence, JSON string containment, and one-predicate scalar OR-list are absent (`ViewerStoreQuery.swift:13-23,51-129`). The caller also supplies already-split full-text terms rather than the specified bounded search-text input/splitting semantics (`ViewerStoreQuery.swift:70-78`).

The cursor contains only the ordering tuple (`ViewerStoreQuery.swift:209-212`). `page` accepts an independently supplied query, compiled SQL, snapshot, lease, and cursor without binding or checking the normalized fingerprint and frozen bounds (`ViewerStoreQuery.swift:264-308`); a caller can pair one query's recording lease with different compiled predicates. Captured recording/device/disposition/gap/drop bounds are not referenced by page SQL (`ViewerStoreQuery.swift:244-255,282-304`). Detail loading has no recording scope, lease, or fingerprint and can return a row from another recording below the global upper ID (`ViewerStoreQuery.swift:311-328`).

**Required resolution:** model normalized dimensions explicitly; compile all required operators with exact grouping; bind a closed cursor token to recording, fingerprint, all upper bounds, lease, tuple, and direction; use frozen related-table bounds for membership and displayed state; require recording scope/bounds for detail. Add compiler truth tables, pairwise integrations, every grammar/normalization boundary, cursor mix-and-match rejection, both directions/equal times, later transitions/samples/versions, detail cross-scope, expiry, and work-plan tests.

### NW-LSS-IMPL-CT-008 — High — Export is neither the required schema/snapshot nor bounded to one Event of content memory

The API accepts an arbitrary list of up to 32 recording IDs and has no validated-query export (`ViewerStoreExport.swift:50-63,212-217`). Output contains only `disclosure`, `devices`, and `events` (`ViewerStoreExport.swift:84-97`), omitting required `session`, `gaps`, and `annotations`; it also omits several required Event analysis fields and local disposition. Events are ordered by row ID, not `(viewerMonotonicNs, rowID)` (`ViewerStoreExport.swift:147-156`).

Although snapshot captures recording/device/disposition/gap/drop/annotation version bounds, export SQL never uses those bounds (`ViewerStoreExport.swift:99-205`). Device pages read mutable base end/partial fields, so concurrent close/recovery can change an in-progress export (`ViewerStoreExport.swift:107-125`). The export lease is not tied to a recording and globally protects every recording (`ViewerStoreMaintenance.swift:86-114`), while it still cannot make unused metadata bounds meaningful.

`writeEvents` materializes an array of up to 200 complete JSON Events before file output (`ViewerStoreExport.swift:139-188`). With a legal near-20-MiB Event, this can approach 4 GiB instead of one Event plus bounded page metadata. `cancel()` only interrupts an active SQLite page; encode, file-write, flush, rename, and directory-sync phases have no cancellation token (`ViewerStoreExport.swift:59-82,243-258`).

**Required resolution:** support exactly one complete recording or one validated frozen query; emit the complete schema-v1 root and fields in receive order; apply every base/version bound; bind the finite lease to the source; stream one Event content value at a time with bounded metadata; check generation-bound cancellation at every file phase and preserve atomic destination semantics. Add active metadata mutation, delayed base admission, gaps/annotations/dispositions, many reconnects, maximum-size pages, sustained writes/WAL, lease expiry, source deletion, forbidden-field scan, and cancellation at each phase.

### NW-LSS-IMPL-CT-009 — Medium — Cancellation and lease acquisition contain late-winner races

`cancelCurrentOperation` snapshots `activeGeneration` and the database pointer under a lock, releases the lock, then sets cancellation and calls `sqlite3_interrupt` (`ViewerSQLite.swift:217-225`). The old operation can complete and a new operation can become active between unlock and interrupt, allowing a late cancel to interrupt the following generation—the exact race the design forbids.

Maintenance and manual delete test lease protection before opening their writer transaction and do not revalidate inside the mutation (`ViewerStoreMaintenance.swift:233-260,264-313`). A query/export lease can be acquired after candidate selection but before tombstone commit, or cleanup can commit between lease acquisition and snapshot capture (`ViewerStoreQuery.swift:244-261`; `ViewerStoreExport.swift:59-64`). The source can therefore disappear underneath a nominally frozen traversal/export.

**Required resolution:** make interrupt conditional on the same generation still being active at the interruption point, and serialize lease acquisition/snapshot with tombstone eligibility or revalidate the exact lease winner within the writer transaction. Add deterministic old-completion/new-start cancellation races and both cleanup-before/after-lease acquisition orders.

### NW-LSS-IMPL-CT-010 — Medium — Required maintenance triggers, retry behavior, and status calculations are not composed

Saving storage settings writes only `UserDefaults`; it does not trigger maintenance (`ViewerRuntimeDependencies.swift:56-61`; `ViewerApplicationModel.swift:126-142`). Retry merely changes the in-memory state to `.available` without reopening/probing the database, flushing a retained prefix, or running reconciliation/maintenance (`ViewerEventStore.swift:325-329`; `ViewerRuntimeDependencies.swift:78`). No threshold trigger or replaceable 15-minute wake is implemented. Session-close maintenance races before the enqueued close commits (`ViewerStoreCoordinator.swift:141-156`).

Status calls the minimum recording start the oldest history rather than the oldest Event, and pinned usage sums only fixed recording-base quota (`ViewerEventStore.swift:283-313`). The UI presents configured retention as an estimate rather than computing estimated retained duration. Preference loading accepts arbitrary `NSNumber` values and truncates nonintegral doubles or booleans instead of rejecting them (`ViewerStoragePreferences.swift:41-50`).

**Required resolution:** compose startup/settings/session-close/threshold/periodic triggers with one maintenance owner; implement a real explicit reopen/retry flow; order session-close maintenance after durable close; calculate the specified safe status from authoritative rows/counters; reject nonintegral preference encodings. Add deterministic scheduler, reopen, settings, threshold, status, and corrupt-preference tests.

### NW-LSS-IMPL-CT-011 — Medium — The test plan and documentation do not provide evidence for the implemented risk surface

Only 12 store tests exist (`ViewerStoreTests.swift:17-308`). They cover basic schema creation/hardening, one rollback, one symlink, preferences, one idempotent Event, two compiler literals, one small export, one simple delete, text bounds, and one application-settings happy path. There are no store integration tests for journal transition identity/conflicts, ingress/drain concurrency, write-failure prefix retention, lifecycle outage/reconciliation, 20/41-MiB paths, quota thresholds, reclaim phases, lease/cancel races, pagination directions/snapshots, complete export schema, bounded peak memory/WAL, file-phase cancellation, sidecar lifecycle, corruption, or application shutdown. Tasks 2.1 through 8.3 remain unchecked (`tasks.md:8-48`) and there is no implementation evidence inventory.

The operator documentation claims immutable base rows, child-before-parent versioned recovery, coalesced gaps, correct 85% cleanup, frozen version queries, and matching-generation export cancellation (`Documentation/Viewer-Local-Store.md:13-15,23-37,41-53`), but the implementation above does not provide those behaviors.

**Required resolution:** implement and mark tasks only after exact evidence exists; add proportionate unit/state-machine tests plus transactional/concurrency/failure integrations for every scenario; save current-tree commands/results; update documentation to the verified implementation. A passing set of happy-path store tests is not completion evidence.

## Validation Results

### Required artifact checks

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# no output; exit 0
```

### Viewer build and test observations

The default macOS test command reached the project but failed before build because the local checkout has no configured development team:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' test
Signing for "NearWireViewer" requires a development team.
```

A no-sign universal build then failed resolving the package modules for x86_64. An arm64 active-architecture no-sign run compiled and executed the tests:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

Result on the stable snapshot: 90 tests executed, 1 skipped, 2 failures. All 12 `ViewerStoreTests` passed; the two failures were the running-application entitlement assertions expected to be absent from an unsigned app. This run proves the current narrow happy paths compile, but it does not provide the missing behavioral evidence identified above.

## Verified Strengths

- The implementation uses system SQLite through distinct serialized writer, query, and export connections and does not add a Core/SDK runtime dependency.
- Schema migration is transactional, unknown newer schema fails closed, prepared bindings are used for external values, and Event/FTS insertion/deletion is transactionally coupled through triggers.
- Default preference ranges, basic text bounds, owner-only main file/directory permissions, symlink rejection, deterministic JSON, and basic alias omission are present.
- Network session ownership remains independent of SQLite return values; the findings concern journal completeness and correctness, not a storage-to-protocol acknowledgement path.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 11 — 8 High, 3 Medium, 0 Low.**

The current code is an early functional slice rather than an implementation of the validated change. The highest-risk blockers are accepted-observation loss, absent disposition journaling, incorrect runtime lifecycle, over-deleting quota cleanup, unbounded and alias-leaking reclaim, and query/export snapshot contracts that are present in types but not enforced by SQL or cursors.
