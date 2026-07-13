# Implementation Review Round 5 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This fresh independent review examined AGENTS.md; the complete active `viewer-local-store-search` proposal, design, capability specifications, and task plan; the current production, test, and operator-documentation tree; all Round 4 implementation-review reports; `implementation-remediation-round4.md`; `implementation-validation-round5.md`; and `resource-filesystem-audit-round5.md`. It rechecked the three Round 4 security/performance/documentation findings and inspected physical-reserve serialization, no-work behavior, sensitive reflection/interpolation, export identity and atomic replacement, SQLite quota versus allocated-footprint claims, live Application Support handling, APFS reclamation evidence, shutdown resource ownership, privacy/disclosure, and evidence accuracy.

Production, test, specification, task, and operator-documentation files were not modified. Configured signing, entitlement assertions, and stable-signer validation remain explicitly deferred by user direction to `release-hardening`; that deferral is not a finding.

## Verdict

**Not approved. Four actionable medium-severity findings remain.**

## Findings

### NW-ISPD5-001 — Medium — Two write paths still perform physical-reserve admission outside the serialized writer

Round 4's maintenance dead zone is fixed: tombstone selection, normal/oversize reclaim, phase advancement, checkpoint, and free-page work now determine their action before applying an action-specific plan, and no-work inspection no longer inherits 41 MiB. Event, structural, annotation, and metadata transactions also check their plan on the writer executor immediately before `BEGIN IMMEDIATE`.

Manual deletion and orphan reconciliation do not preserve that ordering. `requestDelete` checks the structural reserve before acquiring the deletion lock and before entering `pool.writer.run` (`ViewerStoreMaintenance.swift:361-377`). `reconcileOrphans` checks the maximum 17-version reserve before entering `pool.writer.run`, then computes the actual child/version count and begins the transaction without rechecking physical capacity (`ViewerStoreCoordinator.swift:944-982`). Another queued writer can consume its independently admitted plan between either outside check and the later transaction. Both operations can then begin against only the floor, defeating the design and operator claim that every mutation preserves `64 MiB + its checked planned work` (`design.md:108,125`; `Documentation/Viewer-Local-Store.md:19-21`).

The current fail-closed test changes the capacity seam to unavailable and invokes mutation categories sequentially (`ViewerStoreTests.swift:2724-2789`). It does not interleave two admitted plans or assert that the guard and `BEGIN` share writer ordering.

Required resolution:

- Move manual-delete admission into the same `pool.writer.run` closure immediately before `BEGIN IMMEDIATE`.
- For orphan reconciliation, inspect the bounded group, compute its exact version plan, then check that plan and begin on the same writer turn.
- Add a deterministic interleaving test in which two writes cannot both spend the same apparent post-floor capacity; prove the second transaction fails before mutation.

### NW-ISPD5-002 — Medium — Redaction still stops at journal wrappers while active Viewer wire carriers synthesize sensitive reflection

`WireReceivedEvent`, `ViewerDownlinkJournalEvent`, and every case of `ViewerStructuralObservation` now have closed descriptions, debug descriptions, and mirrors. The table-driven regression correctly covers received/downlink Event wrappers plus policy, drop, and gap values (`ViewerStoreTests.swift:442-498`). This resolves the exact three carriers named in Round 4.

The Viewer nevertheless creates and retains other direct Event carriers that still use synthesized reflection. `WireEventRecord` contains `EventEnvelope`, `WireEventPayload` contains one record, and `WireEventBatchPayload` contains an array of records (`WireEventPayloads.swift:7-10,376-420`). `EventEnvelope` itself contains Event type, arbitrary JSON content, endpoints, session epoch, sequence, and causality (`EventEnvelope.swift:3-17`). None of these types supplies closed reflection, and the live Viewer decodes, queues, constructs, and encodes them (`ViewerMultiDeviceSession.swift:518,630,909-942`). `String(reflecting:)`, failed assertion interpolation, or a debugger mirror on any of these active values therefore traverses Event content and metadata despite the capability requirement covering every description, reflection helper, interpolation, and diagnostic surface (`viewer-multidevice-flow-control/spec.md:7-11`).

Required resolution:

- Close reflection at the remaining direct Event model/wire carriers, or place them behind a nonreflecting owner throughout Viewer runtime ownership.
- Extend the secret-marker matrix to `EventEnvelope`, `WireEventRecord`, single-Event payload, batch payload, and any other Viewer-owned container that directly stores Event JSON.
- Preserve deterministic byte counts and closed bounded categories only; do not expose type, content, endpoints, epochs, IDs, or causality through generic diagnostics.

### NW-ISPD5-003 — Medium — The new automatic shutdown retry contradicts the approved finite-flush contract

Round 4 remediation added a second ingress flush whenever the first shutdown flush returns `writeFailed`: it resets the Event store and ingress, then calls `flush()` again (`ViewerStoreCoordinator.swift:663-669`). The remediation record accurately discloses this behavior as an automatic finite retry (`implementation-remediation-round4.md:54-57`).

The approved specification says the exact finite prefix receives **one flush attempt** during shutdown and that failure releases resources for next-open reconciliation (`viewer-local-store-search/spec.md:276-282`). The design is equally explicit that a failed terminal flush performs no retry, releases resources, and completes cleanup (`design.md:176-180`). A bounded second call is not an unbounded retry loop, but it is still a second automatic attempt after the terminal failure and can repeat the entire maximum finite prefix, extend shutdown ownership, and produce behavior not authorized by the active change. Neither the artifacts nor operator documentation were updated to adopt and bound a two-attempt policy.

Required resolution:

- Restore the single terminal flush and rely on the specified next-open orphan reconciliation after failure; or revise and independently approve the artifacts before retaining a two-attempt shutdown policy.
- Add evidence for the chosen contract's maximum work/time and exact failure disposition rather than relying only on five successful repetitions of one regression.

### NW-ISPD5-004 — Medium — The live audit is materially improved but leaves a store copy and does not yet provide an exact, semantically consistent restoration record

The live audit now proves substantially more than Round 4: the actual `~/Library/Application Support/NearWire` directory and live main/WAL/SHM artifacts were owner-only, `lsof` observed the built Viewer holding those files, clean-close state was inspected, and the pre-existing unsupported store was returned to its original path. A read-only Round 5 review check confirmed the restored main/WAL/SHM logical sizes are currently 184320/0/32768 bytes and that `/tmp/NearWire-preaudit-20260713` and the opt-in marker no longer exist.

However, `/tmp/NearWire-audit-created-20260713` still exists with a complete second store directory (`0700`) and main/WAL/SHM files (`0600`). Because the built Viewer was launched while that audit store was active, retaining the database outside Viewer quota, retention, and cleanup is an unnecessary residual-data boundary even if this particular run admitted no known Event. Evidence should retain non-content metadata, not a duplicate unencrypted database.

The audit also records only a prose move/restore sequence and size equality, without the exact commands, exit results, or pre/post directory identity/digest metadata needed to substantiate “restored exactly” under the repository's evidence rule. Finally, the incremental-vacuum test reads `fileAllocatedSizeKey` for WAL (`ViewerStoreTests.swift:2862-2864,2887-2889`), while `resource-filesystem-audit-round5.md:46` labels the result “WAL logical size.” The APFS conclusion itself is honest and supported: SQLite `freelist_count` and `page_count` fell by 64 while main logical/allocated size did not immediately shrink. The WAL metric label is nevertheless wrong in a document whose purpose is to distinguish logical and allocated footprint.

The operator guide also says only that JSON export is unencrypted (`Documentation/Viewer-Local-Store.md:55-63`). It does not plainly disclose that the local SQLite Event store has no application-level at-rest encryption, despite task 7.4 requiring the local-data and export encryption posture and the design explicitly placing at-rest encryption out of scope (`tasks.md:41`; `design.md:28,198`).

Required resolution:

- Remove the audit-created store after capturing non-content metadata and record the cleanup result; do not preserve a duplicate database as evidence.
- Add the exact move/test/launch/`lsof`/quit/stat/restore/cleanup commands and exit results, plus a non-content pre/post identity or digest sufficient to support the restoration claim.
- Relabel the WAL value as allocated bytes (or measure and report both logical and allocated values), and keep the APFS non-shrink limitation unchanged.
- State directly that the local SQLite database is not application-level encrypted and that filesystem/FileVault protection, if present, is outside NearWire's guarantee.

## Round 4 Finding Disposition

- `NW-ISPD4-001`: resolved for maintenance action selection and no-work/floor-only checkpoint/free-page behavior. `NW-ISPD5-001` is a separate reserve-serialization gap in manual delete and orphan reconciliation.
- `NW-ISPD4-002`: resolved for the three named journal/structural carriers, but broader active Event wire/model carriers remain exposed as `NW-ISPD5-002`.
- `NW-ISPD4-003`: the live Application Support inspection and incremental-vacuum/APFS measurements now exist and the APFS non-shrink observation is appropriately qualified. Residual audit data and evidence/disclosure inaccuracies remain as `NW-ISPD5-004`.

## Security and Resource Boundaries Rechecked Without New Findings

- Export retains the original temporary-file and parent-directory descriptors, validates file and parent identity, commits with descriptor-relative `renameat`, preserves the prior destination on reported pre-commit failure, and treats post-rename synchronization as best effort. The substitution and phase-failure regressions remain current.
- SQL/FTS/JSON query values remain bounded and parameterized; no direct injection issue was found.
- Logical quota and database/WAL/SHM allocated footprint remain separate in production status and operator documentation. The resource evidence does not falsely claim immediate APFS byte-for-byte shrinkage.
- Store files remain owner-only and nonsymlink-validated. Secure delete is documented as defense in depth rather than SSD, snapshot, sync, or backup erasure.
- The macOS-only Required Reason API conclusion from Round 4 is unchanged. Configured signing remains deferred by explicit user direction and is not counted here.

## Validation Basis

This review used the exact current-tree test and packaging results saved in `implementation-validation-round5.md`: 126 unsigned Viewer tests with one explicit live-audit skip and zero failures, plus 531 root Swift package tests with seven documented skips and zero failures. It also used the saved live/resource measurements and a nonmutating current-state check of the restored and audit-created directories. Tests were not duplicated where the saved result already covered the unchanged branch; source inspection identified the uncovered serialization, reflection, and shutdown-contract issues.

## Unresolved Count

**Four actionable findings remain unresolved: zero high and four medium. Approval is withheld.**
