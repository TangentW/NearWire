# Implementation Review Round 3 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This fresh independent review examined the stable Round 3 `viewer-local-store-search` snapshot: AGENTS.md, the active proposal/design/specifications/tasks, all Round 2 implementation reports, current production and test source, the operator guide, the current diff, and saved implementation evidence. Production, test, specification, and operator-documentation files were not modified.

The review focused on end-to-end queue ownership, physical disk safety, SQLite/path/file hardening, bounded reclaim and free-page work, query/export plans and cancellation, atomic export replacement, sensitive reflection, privacy disclosure/manifest inspection, packaging, and whether the saved evidence proves the current requirements.

## Verdict

**Not approved. Four actionable findings remain: two high and two medium.**

Configured signing, entitlement assertions, and stable-signer validation remain explicitly deferred by user direction to the goal-level `release-hardening` change. They are not findings in this review.

## Findings

### NW-ISPD3-001 — High — The volume guard checks only the floor, not the planned transaction reserve

The implementation now calls a fail-closed disk guard before bootstrap and each mutation category, but `ViewerStoreDiskGuard.requireReserve` accepts no planned-byte argument and succeeds whenever current available capacity is at least 64 MiB (`ViewerSQLite.swift:100-117`). Event batching already computes a checked `plannedReservation` (`ViewerEventStore.swift:400-409`), yet `writeTransaction` discards that value for physical-capacity admission and invokes the same floor-only guard (`ViewerEventStore.swift:1019-1028`). Structural and metadata writes likewise check only the floor.

A legal Event can reserve approximately 40 MiB under the Event-plus-FTS formula. Starting such a transaction with exactly 64 MiB available passes the guard even though the transaction can consume the safety margin or exhaust the volume. This does not meet the design's requirement for a reserve based on the planned transaction **with** a 64-MiB floor (`design.md:108`) or the capability's requirement that the guard prevent physical disk exhaustion. The current disk-guard test covers missing/below-floor capacity across mutation categories, not `floor + planned work` boundaries.

Required resolution:

- Make the disk guard accept a checked planned physical reservation and require `available >= 64 MiB + plannedReservation`, with overflow failing closed.
- Pass bounded planned work for Event batches, one-record oversize writes, lifecycle/metadata versions, migration/VACUUM, tombstone/reclaim/checkpoint/free-page turns, and export writes where an applicable destination-volume policy is defined.
- Add exact equality, one-byte-below, overflow, normal 4-MiB, maximum Event, and 41-MiB reclaim boundary tests, proving no SQLite mutation begins when the post-transaction floor cannot be preserved.

### NW-ISPD3-002 — High — Export closes and reopens its temporary path, leaving file-identity and parent-directory races

`secureTemporarySibling` securely creates a random `0600` file with `O_EXCL | O_NOFOLLOW`, but immediately closes its descriptor and returns only the URL (`ViewerStoreExport.swift:658-678`). Export later reopens that pathname with only `O_WRONLY | O_NOFOLLOW` and without `O_EXCL`, `O_TRUNC`, or an inode/link-count check (`ViewerStoreExport.swift:211-218`). A writable destination-directory peer can replace the pathname with another regular file or hard link between creation and reopen. That can corrupt the replacement target while writing, preserve attacker-controlled trailing bytes, or make the final output differ from the created temporary inode despite never using a symlink.

After file close and the commit seal, replacement again trusts pathnames. Although a parent directory descriptor is opened, `rename(temporary.path, destination.path)` uses absolute paths rather than that descriptor (`ViewerStoreExport.swift:681-696`). Renaming/replacing the parent or temporary leaf can therefore make the exporter rename a different file or synchronize a directory other than the one used by the pathname operation. The fault-phase tests cover thrown errors and cancellation, but do not substitute the temporary inode/leaf or parent path.

Required resolution:

- Open the parent once with `O_DIRECTORY | O_NOFOLLOW`, create the temporary file relative to that descriptor, and retain the original file descriptor through write and synchronization instead of reopening by pathname.
- Validate the exact regular-file inode, owner, mode, and link count at the commit boundary; use descriptor-relative leaf operations (`openat`/`fstatat`/`renameat` or the macOS equivalent) against the same parent descriptor.
- Add adversarial tests for regular-file, hard-link, temporary-leaf, and parent-directory substitution at every file phase, verifying that no unrelated file is modified and no substituted payload reaches the destination.

### NW-ISPD3-003 — Medium — Query and stored-summary values still expose sensitive input through default reflection

The prepared Event and full detail models now have redacted descriptions and mirrors, which resolves the original direct-content reflection issue. However, query-layer values still use synthesized reflection: `ViewerEventPredicate` contains Event types, full-text terms, JSON paths/values, and App metadata; `ViewerEventQuery` retains those predicates; and `ViewerCompiledQuery` contains raw predicate SQL and bindings (`ViewerStoreQuery.swift:5-59`). `ViewerStoredEventRow` similarly reflects Event UUID, Event type, direction, sequence, timing, priority, and resolved disposition (`ViewerStoreQuery.swift:356-370`).

Consequently, `String(reflecting:)`, debugger mirrors, assertion interpolation, or generic diagnostics can disclose the exact values that the modified flow-control specification excludes from every description/reflection helper, including Event metadata, query text, and SQL. The current safe-reflection test checks only `ViewerPreparedEventObservation`; the Round 3 evidence does not cover query, compiled-plan, cursor/page, or stored-summary reflection.

Required resolution:

- Give all sensitive query/compiler/result models closed redacted `CustomStringConvertible`, `CustomDebugStringConvertible`, and `CustomReflectable` behavior, or place raw values in a nonreflecting owner that cannot reach generic diagnostic surfaces.
- Ensure safe summaries expose only counts, closed categories, and bounded non-sensitive state; never raw Event type/ID, search/JSON input, bindings, SQL, content, or peer identity.
- Add `String(describing:)`, `String(reflecting:)`, `Mirror`, error/interpolation, log, and accessibility scans for every store/query/export model carrying sensitive values.

### NW-ISPD3-004 — Medium — Current validation is improved but does not complete the task-plan resource and filesystem evidence

`implementation-validation-round3.md` is current and records 35 focused store tests, a 112-test unsigned Viewer regression, 531 root-package tests, system SQLite linkage, built privacy-manifest contents, and root SwiftPM inspection. This resolves Round 2's stale-validation and built-manifest concerns. The disclosure and privacy rationale are also accurate: exports are unencrypted, aliases are pseudonyms rather than redaction, Event/App values may identify people or secrets, exports are outside Viewer quota/retention, and destination providers may sync or back them up.

The completion matrix is still incomplete. Tasks 7.1 through 7.5 remain unchecked (`tasks.md:38-42`), and the saved evidence does not inspect live app-container main/WAL/SHM/journal/temp files before and after close, the root CocoaPods manifest, or the export pathname substitutions in NW-ISPD3-002. It also lacks the task-required measured maximum-payload/peak-memory, sustained-write/WAL, incremental-vacuum allocated-footprint, exhaustive compiler-plan matrix, export-lease-expiry, 20/41-MiB boundary, and huge-session reclaim evidence. Passing focused functional tests cannot establish those resource and adversarial claims.

Required resolution:

- Add focused evidence for the remaining filesystem, resource, plan, lease-expiry, reclaim, and export-path cases, including measured bounds where the requirement is about memory/WAL/allocated footprint rather than only returned values.
- Inspect the live app-container artifacts and both root distribution manifests, save exact commands/results, and reconcile every requirement/scenario to named evidence.
- Mark task checkboxes only after that evidence exists, rerun the final unchanged-tree gates, and complete the required spec-to-evidence audit before archive.

## Round 2 Remediation Verified

The stable Round 3 tree materially resolves the prior review's main issues:

- preparation and ingress share one count/byte/36-value pipeline budget with an observational/lifecycle partition;
- failed flushes return an explicit outcome and runtime shutdown closes store ownership;
- duplicate peer Event UUIDs no longer own terminal journal identity;
- missing initial transitions become bounded gaps rather than poisoning the writer;
- nondurable mid-runtime device observations and runtime generations are bounded and isolated;
- capacity recovery includes projected logical admission;
- gap aggregates are append-only and frozen by export bounds;
- Event reclaim counts the schema-enforced maximum of two dispositions and FTS work, uses bounded existence probes, and adds incremental auto-vacuum/free-page turns;
- manual deletion uses a finite, annotation-aware, single-use confirmation;
- Viewer receive-time, typed JSON equality/OR/containment, frozen disposition/lifecycle membership, query/export plan gates, and SQLite work-limit categorization are implemented;
- export cancellation has a lock-coupled commit seal and a single rename commit point;
- current unsigned regressions, system-SQLite linkage, built privacy manifest, and root SwiftPM language/platform boundaries have saved evidence.

SQL/FTS/JSON inputs are bounded and parameterized, and no direct injection finding remains in this review. SQLite errors remain closed categories without raw paths, SQL, or underlying messages. Local/export encryption limitations and secure-delete limitations are documented without claiming secure erasure.

## Validation Basis

This review used the exact current-tree results saved in `implementation-validation-round3.md`; no duplicate test run was necessary. The saved configured-signing exclusions are accepted solely because the user explicitly assigned those gates to `release-hardening`.

## Unresolved Count

**Four actionable findings remain unresolved: two high and two medium. Approval is withheld.**
