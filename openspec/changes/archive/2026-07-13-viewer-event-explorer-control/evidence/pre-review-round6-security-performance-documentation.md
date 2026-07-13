# Pre-Implementation Security, Performance, and Documentation Review — Round 6

## Verdict

**Approved for implementation.** The revised duplicate semantics use one representable durable
projection without adding Viewer identity, session epoch, a second content representation, or any
schema column. Live and durable authorities compare the same semantic fields, preserve the first
observation's accounting and receive times, and retain the previously approved privacy and resource
bounds. The migration normal-pool transition and the inspector-clipboard/file-export boundary have
not regressed.

| Severity | Unresolved count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| **Total actionable** | **0** |

This approval covers the current pre-implementation artifacts only. Apply evidence, independent
implementation review, the spec-to-evidence audit, and archival gates remain outstanding.

## Scope and Method

This review reread the current proposal, full design, task plan, all three capability deltas, and
`pre-review-remediation-round5.md`. The review then checked the revised projection against the
current Events/disposition representation and the source/target/session-epoch admission seam. It
also repeated focused regression checks for migration connection replacement, live ownership and
callback work, content retention and disclosure, clipboard behavior, and JSON file export.

Prior reports were used only as finding indexes. The current proposal, design, specifications, and
tasks were the normative authority.

No production or test source and no artifact other than this report was modified.

## Revised Duplicate-Semantics Verification

### The stored projection is representable without new identity or content storage

The durable key remains the existing recording/device-session/direction/wire-sequence identity. The
compared values are exactly Event ID/type, canonical content JSON bytes, App-created wall time
normalized once to nearest integer milliseconds since 1970, App monotonic time, priority, TTL,
schema version, correlation/reply IDs, and initial disposition (`design.md:175-190`; local-store
delta `spec.md:15`; multi-device delta `spec.md:29-35`; `tasks.md:18`).

That field set maps to the existing immutable Events row and sequence-zero disposition row. It does
not require or authorize:

- a Viewer installation identity;
- source or target endpoints;
- a session epoch;
- frozen session aliases or metadata;
- deterministic byte accounting as semantic content;
- Viewer receive wall or monotonic time as semantic content;
- a hash-only equality decision;
- another Event-content blob; or
- a schema-2 column or Event-row rewrite.

Canonical content bytes are the existing `Events.contentJSON` representation, not an additional
stored projection. Initial disposition is the existing sequence-zero disposition value. The
schema-2 migration remains limited to the three reviewed explorer indexes and explicitly rewrites
no Event/content row (`design.md:415-425`; local-store delta `spec.md:5-11,23-27`). The correction
therefore closes the earlier representability gap without widening persistent privacy exposure or
retention.

### Excluded endpoint and epoch values remain enforced before either journal path

The artifacts exclude source, target, and session epoch only because they are exact-session
transport invariants checked before journal commit. The current session admission seam validates
the App source and Viewer target and then invokes directional sequence validation; that validator
rejects a different session epoch before a received observation is constructed or journaled.

The exclusion is therefore not an equality relaxation. A candidate with a mismatched endpoint or
epoch cannot use duplicate equality to cross sessions. Task 6.3 requires direct evidence of this
ordering, so the implementation cannot satisfy the review by merely omitting those fields from the
comparator.

### Live and durable duplicate authorities have one semantic rule

The composite journal applies the same projection at the bounded live ingress and at the serial
writer. Pending or retained identical candidates are idempotent; conflicts preserve the first
observation, publish one bounded content-free marker, and bypass store fan-out. After live eviction,
only an existing durable row remains authoritative. Its identical outcome removes only the later
exact transient candidate, while `journalConflict` preserves the first row, removes the later
candidate, and adds the bounded marker without changing store availability. If ingress is
`untracked`, the writer is the only duplicate authority; if storage is also unavailable, the
artifacts make no content or post-eviction duplicate guarantee (`design.md:191-215`; multi-device
delta `spec.md:33-35`).

The first observation's deterministic accounting and Viewer receive times remain authoritative but
do not decide semantic equality. This prevents harmless scheduling or accounting differences from
becoming false content conflicts while also preventing a later duplicate from rewriting receive
order or quota evidence.

### The test matrix is sufficient and discriminating

Task 6.3 now exercises duplicate behavior across pending ingress, drain, eviction, `untracked`,
durable writer authority, storage recovery, and shutdown. It requires all of the following:

- metadata-, accounting-, and receive-time-only differences remain equal and preserve the first
  values;
- App-created times that differ below millisecond precision but normalize to the same millisecond
  remain equal;
- any persisted-projection field, initial disposition, or normalized-millisecond difference
  conflicts;
- source, target, or session-epoch mismatch is rejected before journal commit;
- no hash alone decides equality; and
- store rows/status plus live reconciliation, conflict, and gap markers match across unavailable,
  recovery, reconnect sequence reuse, eviction, and shutdown states.

The required maximum-shape, 64-record/20-MiB ingress, 512-record/32-MiB window, and exact
callback/drain-count cases make the semantic tests resource-aware rather than narrow comparator
unit tests (`tasks.md:43`).

## Security, Privacy, and Resource Regression Check

### Duplicate handling adds no new content leak or unbounded retention

Duplicate comparison remains exact field/byte comparison, and all duplicate outcomes and conflict
markers are content-free. There is no new Viewer identity, endpoint, epoch, content hash, content
copy, safe-status content, log field, reflection field, preference, recent-row value, restoration
value, or export identity. Exact-key markers coalesce only while resident and otherwise increment a
saturating diagnostic-loss counter; no unbounded tombstone or global first-wins set is retained.

The protocol callback still performs only a constant number of ring/index operations using
precomputed deterministic Event bytes plus fixed overhead. It performs no JSON encoding, content
traversal, SQLite work, large-value eviction/release under its lock, MainActor wait, per-Event task,
or network mutation. Canonical comparison and projection work remains off the callback, within the
64-record/20-MiB ingress, one drain plus one dirty successor, and 512-record/32-MiB resident window.
One maximum legal journal Event remains explicitly admitted, and deterministic accounting remains
documented separately from measured Swift heap (`design.md:217-226`; multi-device delta
`spec.md:31`).

### Migration-only settings still cannot enter the normal pool

The migration connection remains an unpublished off-MainActor writer using the system default VFS,
the verified process-private temporary hierarchy, a 32-MiB cache target, one index statement at a
time, key-only sorter data, checked capacity, bounded progress, and exact cancellation. Commit or
rollback is followed by connection close and a join to zero sorter descriptors.

Success then opens and probes a fresh normal writer with `temp_store=MEMORY` and an explicit 8-MiB
cache target before opening two equally fresh normal readers and publishing availability. A
post-open failure closes the fresh pool and leaves storage unavailable. No global SQLite or
environment temporary routing is read or mutated, no custom VFS is introduced, and no FILE-temp or
32-MiB migration setting can cross the connection boundary (`design.md:427-454`; local-store delta
`spec.md:5-11`; `tasks.md:8,41`). The duplicate-semantics revision does not touch or weaken this
contract.

### Clipboard restrictions and disclosed JSON file export remain separate

Standard user-invoked copy, cut, and paste remain available only in operator-owned editable
composer/filter/metadata controls, with paste checked against the same incremental caps before
model storage. NearWire performs no background pasteboard read, monitoring, restoration, or custom
clipboard history. Received/stored Event inspector controls still expose no copy, cut, drag, share,
or clipboard-export command (`design.md:379-385`; explorer-control delta `spec.md:120,138`).

That restriction does not remove or silently bypass Complete Recording and Current Filtered Result
JSON file export. The separate workflow remains subject to its explicit unencrypted-content and
pseudonym disclosure, native save-panel acknowledgement, bounded streaming, owner-only temporary
sibling, cancellation cleanup, and atomic destination commit. Tasks 5.5 and 6.4 preserve the file
workflow expressly and require actual macOS control/menu behavior, including proof that no
background pasteboard read occurs (`tasks.md:37,44`; local-store delta `spec.md:41-51`). No
duplicate-projection field broadens exported identity or content.

## Prior SPD Regression Summary

| Area | Round-6 result |
| --- | --- |
| Duplicate privacy and retention | Approved: one existing durable content representation, no Viewer identity/epoch, content-free bounded markers, no unbounded tombstones. |
| Live performance | Approved: constant callback work, no callback encoding/traversal, fixed ingress/window ownership, one drain/dirty successor, bounded release. |
| Store and migration lifecycle | Approved: schema remains index-only; the migration handle closes before a fresh memory-temp/8-MiB normal pool can publish. |
| Query, renderer, and accessibility work | No regression: prior count, byte, VM, time, cancellation, retained-value, and derived-value bounds are unchanged. |
| Composer and control admission | No regression: bounded inputs, one encode/traversal/copy, opaque targets, truthful local admission, and shutdown clearing remain intact. |
| Clipboard and export | Approved: operator-input editing only; no received/stored inspector clipboard/share surface; separately disclosed JSON file export remains available. |
| Documentation and evidence | Approved: Task 6.3 discriminates every revised semantic field/exclusion and all duplicate-authority states; Tasks 6.8-6.9 retain privacy/resource gates. |

## Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  completed successfully with `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` completed successfully with no output.
- No production or test source and no artifact other than this report was modified.

## Conclusion

There are **zero unresolved security, performance, or documentation findings** in the current
pre-implementation artifacts. This review dimension of task 1.2 is approved for implementation.
