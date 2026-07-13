# Implementation Review Round 2 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This fresh independent review compares the current `viewer-local-store-search` production code, tests, operator documentation, Round 1 findings, and saved validation evidence with the active proposal, design, capability specification, and tasks. Production, test, and operator-documentation files were inspected but not modified.

The review focused on path and SQLite hardening, sensitive-value and reflection boundaries, bounded queue and maintenance work, quota and physical reclamation, query/export injection and cancellation, atomic export replacement, privacy disclosure, and whether saved evidence supports the current tree.

## Verdict

**Not approved.** Seven actionable findings remain: three high and four medium.

## Findings

### NW-ISPD2-001 — High — The new preparation queue duplicates the specified ingress bounds and can silently lose structural lifecycle ownership

Round 1's unbounded dispatch backlog is now finite, but the remediation adds a second Event-retaining queue with its own 8,192-record/64-MiB allowance before the 4,096-record/32-MiB default ingress (`ViewerStoreCoordinator.swift:257-281,332-358,761-815`; `ViewerEventStore.swift:1017-1095`). The end-to-end default can therefore retain the preparation allowance plus the ingress allowance, rather than the documented default. The preparation queue also reserves 64 structural closures in addition to the 36-value ingress lane (`ViewerStoreCoordinator.swift:768-770`; `ViewerEventStore.swift:1019-1023`). Runtime/session starts, recovery, and retry discard the Boolean result of that structural offer (`ViewerStoreCoordinator.swift:176-255,435-447`), so saturation can lose the only start/materialization operation without a durable or bounded nondurable fallback. Shutdown can likewise fail its second structural offer and resume without clearing the active recording/runtime state or triggering session-close maintenance (`ViewerStoreCoordinator.swift:459-515`).

Required resolution:

- Make the protocol-facing reservation and the documented ingress one bounded ownership budget, or explicitly reserve a smaller preparation stage whose count/bytes are included in the stated end-to-end limits.
- Use the specified structural ownership derived from one recording plus 16 sessions; never ignore a rejected runtime/session/recovery/close operation.
- Give shutdown one nonfailable finite completion path that either completes cleanup state or records a precise nondurable outcome.
- Add saturation tests covering simultaneous maximum Events, all structural operation kinds, retry, and runtime shutdown while both stages are full.

### NW-ISPD2-002 — High — Physical reclamation still has unbounded work and never returns free main-database pages to the filesystem

The new persisted reclaim phases fix Round 1's all-metadata cascade, but the Event phase selects up to 1,024 Events and then deletes every disposition version for those Events in one transaction (`ViewerStoreMaintenance.swift:414-459,464-483`). The schema does not cap disposition-version count per Event, so the actual deleted-row and WAL work can exceed the 1,024-row bound. Phase advancement and finalization use full `COUNT(*)` expressions on potentially very large child tables on the unbudgeted writer (`ViewerStoreMaintenance.swift:537-560,583-603`), which also violates the finite-turn claim.

After physical row deletion, `checkpointOneStep` performs only a passive WAL checkpoint (`ViewerStoreMaintenance.swift:614-635`). The schema does not enable an auto-vacuum mode and there is no incremental-vacuum/free-page operation. Consequently, deleted main-database pages can remain allocated indefinitely even though the operator guide claims opportunistic free-page optimization (`Documentation/Viewer-Local-Store.md:35-37`). This is particularly important because status separately reports allocated footprint and the disk guard can pause future writes while reclaimed logical history still occupies filesystem blocks.

Required resolution:

- Reclaim disposition versions through a counted phase or otherwise prove a schema-enforced per-Event bound included in the same 1,024-row/4-MiB quantum.
- Replace unbounded phase/finalization counts with bounded existence/integrity probes and add a writer work budget where data-dependent scans remain.
- Implement and validate a compatible bounded free-page strategy, or remove the free-page-release claim and explicitly document that physical main-file allocation is retained for reuse.
- Test millions of dispositions/metadata rows, WAL growth, crash/resume at each phase, and allocated main/WAL footprint before and after reclaim.

### NW-ISPD2-003 — High — Export cancellation and destination preservation are not atomic with the commit boundary

Export validates its cancellation generation and lease, closes the file, and then calls `atomicReplace` without atomically sealing the generation against a concurrent `cancel()` (`ViewerStoreExport.swift:146-190`). A cancellation or lease expiry after the final validation at line 178 but before the rename can therefore still replace the destination and return success. The cancellation object has no `committing` state or lock-coupled commit transition.

For an existing destination, replacement swaps the files, synchronizes the directory, unlinks the old destination now held at the temporary path, and synchronizes again (`ViewerStoreExport.swift:604-640`). If the final directory sync fails, the method throws after the old destination has already been removed and cannot roll back. If either best-effort swap-back fails on an earlier error, it also throws while the new destination may remain installed. This contradicts the required and documented guarantee that cancellation or failure preserves the prior destination until a successful commit (`Documentation/Viewer-Local-Store.md:49-51`).

Required resolution:

- Add a lock-coupled export state transition that rejects cancellation/expiry before commit or deterministically reports that commit has begun; no unchecked cancellation window may precede rename.
- Define the exact filesystem commit point and ensure errors before it preserve the old destination. After an irreversible successful commit, do not report the operation as an uncommitted failure.
- Add deterministic fault injection for cancel/expiry before and during commit, rename/swap, file sync, both directory syncs, unlink, and rollback failure, checking destination bytes and reported result each time.

### NW-ISPD2-004 — Medium — Several store mutations bypass the fail-closed physical disk guard

Event transactions and maintenance campaigns now call `ViewerStoreDiskGuard.requireReserve`, which fixes most of Round 1's fail-open behavior. However, recording metadata updates, annotations, and manual tombstones call `pool.writer.run` directly without the guard (`ViewerStoreMaintenance.swift:219-263,266-299,302-336`). The migrating pool also opens/creates and configures the database before the convenience initializer performs its first reserve check (`ViewerSQLite.swift:420-448`; `ViewerStoreSchema.swift:348-357`). These paths can still allocate database/WAL pages below the promised 64-MiB safety floor.

Required resolution:

- Route every mutating transaction, including migration/bootstrap, metadata, annotations, pinning, and manual deletion, through one shared guarded writer primitive.
- Preserve fail-closed behavior when the capacity resource value is unavailable.
- Add injected missing/low-volume-capacity tests for every mutation category and prove that no mutation or misleading success occurs.

### NW-ISPD2-005 — Medium — Manual deletion lacks the required explicit confirmation token

`requestDelete` accepts only a `ViewerRecordingRevision` and timestamp (`ViewerStoreMaintenance.swift:302-336`). The revision check prevents stale deletion, and active/leased recordings are correctly rejected, but there is no separately issued confirmation token bound to the exact closed recording ID and revision. A pinned closed recording can therefore be tombstoned by any internal caller that has its current revision, without the explicit confirmation boundary required by the capability specification.

Required resolution:

- Introduce a short-lived, single-purpose confirmation value bound to recording ID and current revision, and require it for manual deletion, including pinned recordings.
- Consume or invalidate the token on use and reject stale, cross-recording, replayed, active, and leased cases.
- Add adversarial token-substitution and pin/delete tests before exposing the deferred history UI.

### NW-ISPD2-006 — Medium — The approved query-plan gate is not applied to export and is not evidenced across compiler shapes

Interactive pages run `EXPLAIN QUERY PLAN`, reject one temporary-order phrase, and require one of three timeline indexes (`ViewerStoreQuery.swift:400-404,519-540`). Filtered export reuses the compiler SQL but executes it without an equivalent plan gate (`ViewerStoreExport.swift:275-345`). A valid filter whose SQLite plan changes can therefore perform repeated bounded-but-expensive scans—currently one database read per exported Event—without the capability's required closed rejection of unsupported query/export plans. Current tests cover literal binding and small filtered traversal, not every compiler shape or planner regression.

Required resolution:

- Centralize the approved-plan validator and apply it to both search and filtered export with operation-appropriate bounds.
- Reject unexpected temporary B-trees and missing approved driving indexes using stable plan assertions rather than one narrow phrase alone.
- Add plan fixtures for every predicate family and representative combinations, including FTS, JSON, App metadata, gap/drop, forward/backward traversal, and export.

### NW-ISPD2-007 — Medium — Documentation and saved evidence do not describe or validate the current implementation

The saved Round 1 validation reports 12 focused store tests and 11 store tests in the full regression (`implementation-validation-round1.md:29-69`), while the current test source contains 23 store test methods and substantial post-validation remediation. It is therefore not current-tree evidence. No saved implementation evidence inspects the built privacy manifest, live app-container sidecars, post-close permissions, physical main/WAL reclamation, peak queue/export memory, exhaustive query plans, file-phase cancellation, or atomic-replacement failure behavior. The operator guide also overstates the 36-value end-to-end structural bound, free-page optimization, and cancellation/failure destination-preservation guarantees (`Documentation/Viewer-Local-Store.md:29,37,49-53`).

The disclosure itself is otherwise appropriately explicit: local history and JSON exports are unencrypted, aliases are pseudonyms rather than redaction, Event/App data may remain identifying, exports are outside Viewer quota/retention, and destination providers may synchronize or back them up (`Documentation/Viewer-Local-Store.md:55`; `ViewerStoreExport.swift:8-31`). Sensitive observation and detail models also now provide redacted descriptions/reflection (`ViewerEventStore.swift:68-84`; `ViewerStoreQuery.swift:314-330`). Those improvements do not replace the missing evidence.

Required resolution:

- Correct operator claims to match the remediated behavior, then regenerate exact validation against that final unchanged tree.
- Save built-manifest inspection and the rationale for the unchanged UserDefaults/Device-ID declarations and volume-capacity API use.
- Add the task-required adversarial, stress, filesystem, privacy, reflection, packaging, and documentation evidence before marking tasks complete.

## Round 1 Disposition and Positive Controls

The current tree materially resolves several Round 1 issues: preparation work is no longer unbounded; ingress retains failed prefixes; gap aggregates and queue indices are bounded; lifecycle bases are immutable with append-only versions; aliases are recording-owned and reclaimed; exact live quota counters and retention-first/85-percent selection are present; query summaries exclude Event content; cursors bind scope/fingerprint/snapshot/lease/direction; export emits the complete root and aliases raw installation identifiers; SQLite uses `SQLITE_OPEN_NOFOLLOW`, defensive/untrusted settings, JSON1/FTS probes, bounded readers, and explicit close; sensitive store models have redacted reflection; and disclosure text covers the unencrypted/pseudonymous export boundary.

SQL values are generally bound parameters. The remaining interpolated identifiers and row-ID lists are selected from closed internal enums or validated SQLite `Int64` values, so no direct SQL/FTS/JSON injection finding was identified in this round.

## Validation Basis

This review is source- and evidence-based. No new test run was performed, as requested for this review handoff. The saved Round 1 commands cannot establish the post-remediation current tree for the reasons in NW-ISPD2-007.

Configured-signing, entitlement, and stable-signer validation remains explicitly deferred to the goal-level `release-hardening` change and is **not** counted as a finding in this review.

## Unresolved Count

**Seven actionable findings remain unresolved: three high and four medium. Approval is withheld.**
