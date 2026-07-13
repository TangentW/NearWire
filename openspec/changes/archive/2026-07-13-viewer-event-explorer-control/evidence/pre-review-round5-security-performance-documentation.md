# Pre-Implementation Security, Performance, and Documentation Review — Round 5

## Verdict

**Approved for implementation.** The current normative artifacts close the migration-connection
publication gap identified after round 4, strengthen duplicate-comparator conformance, and remove
the remaining ambiguity between inspector clipboard/share restrictions and the disclosed JSON file
export. No earlier security, performance, privacy, cleanup, or documentation finding regressed.

| Severity | Unresolved count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| **Total actionable** | **0** |

This approval is limited to the pre-implementation artifacts. Implementation, evidence, independent
implementation review, requirement-to-evidence audit, and archival gates remain outstanding.

## Scope and Method

This review reread the current proposal, complete design, task plan, and all three delta
specifications, then checked the changed migration, duplicate, clipboard, and export language against
all prior review/remediation evidence, including `pre-review-remediation-round4.md`. It also
rechecked the canonical store/session boundaries and current Viewer SQLite hardening, App Sandbox,
Core Event limits, queue, privacy, and cleanup seams.

Historical reviews and remediation notes were used only as finding indexes. The current proposal,
design, capability deltas, and tasks were the conformance authority.

No production or test source and no artifact other than this report was modified.

## Changed-Artifact Verification

### Migration connection is migration-only and can never enter the published pool

The revised startup contract now has two explicit connection phases
(`design.md:421-458`; local-store delta `spec.md:5-27`; `tasks.md:8,41`):

1. A serial off-MainActor executor opens only a migration writer. Schema-1 index creation and all
   in-transaction version/feature/index/plan probes occur there under the existing exact token,
   disk-space, progress, cancellation, and rollback gates.
2. After either commit or rollback, that connection closes. Its executor joins until zero SQLite
   sorter descriptor remains. The migration writer is never inserted into or exposed as the normal
   pool writer.
3. Success opens a new writer through the normal hardening path with `temp_store=MEMORY` and an
   explicit 8-MiB cache target. That fresh connection re-probes schema version 2, hardening,
   features, index presence/plans, cache/temp settings, and writer settings.
4. Only after the writer passes do two equally fresh normal interactive/export readers open with
   memory temporary storage and 8-MiB cache targets. Availability publishes only after the complete
   normal pool satisfies those settings and probes.
5. Any post-commit writer or reader open/configuration/probe failure closes every fresh connection
   and leaves persistence, query, and export unavailable. A committed schema 2 is not falsely
   described as rolled back, and no partial pool is published.

This connection replacement is the correct boundary for the system-SQLite strategy. The
migration-only `temp_store=FILE` and 32-MiB cache target are connection-local and disappear with the
closed migration handle; no attempt is made to switch the published writer back in place. The
normal 8-MiB cache target is explicit rather than inherited from SQLite defaults. Tasks 2.1 and 6.1
require construction-order, close/join, zero-descriptor, exact setting, post-open failure, and
publication evidence, so a FILE-temp or 32-MiB migration connection cannot pass by implementation
accident.

All previously approved migration controls remain intact:

- system default VFS and the verified current-user-owned mode-`0700` nonsymlink process-private
  temporary root;
- no read or mutation of global SQLite/environment temp routing and no custom VFS;
- independent checked reservation and 256-MiB floor for database and temporary volumes;
- one index statement at a time, key-only sorter payload, no Event JSON or application row array;
- 32-MiB migration cache target, 128-MiB fixture heap-growth gate, progress checks within 10,000 VM
  instructions, and 250-ms injected cancellation acknowledgement;
- rollback-safe schema publication, once-per-process automatic attempt, explicit retry, content-free
  status, and no automatic spin; and
- system delete-on-close plus zero surviving sorter descriptors, while OS/WAL/snapshot/backup
  reclamation remains documented as logical cleanup rather than secure erasure.

### Duplicate comparator and evidence now test the same field set in every authority

Task 3.2 now names the normative comparator directly: canonical Event envelope/content plus initial
disposition, compared field/byte-exactly, while session metadata and newly sampled Viewer receive
times are excluded. That matches both the local-store and multi-device requirements and preserves
the first observation's receive times without trusting a hash.

Task 6.3 now exercises that comparator across pending ingress, drain, eviction, `untracked`, durable
writer authority, recovery, and shutdown. It explicitly requires:

- metadata-only differences to remain equal;
- receive-time-only differences to remain equal and preserve the first receive time;
- any compared Event or initial-disposition difference to produce the typed conflict behavior;
- no hash-only decision; and
- exact durable rows/status plus live conflict/gap marker outcomes.

The bounded duplicate horizon, serial-writer second authority, no guarantee after both bounded
authorities forget a value, and no protocol mutation remain unchanged and coherent.

### Inspector clipboard/share restrictions no longer conflict with disclosed JSON file export

The normative privacy boundary remains narrow and explicit. Standard user-invoked copy, cut, and
paste are available only in operator-owned editable composer/filter/metadata controls, with pasted
replacements checked against incremental caps before storage. NearWire performs no background
pasteboard read/monitoring, restoration, or custom clipboard history. Received/stored Event
inspector controls expose no copy, cut, drag, share, or clipboard-export command.

Tasks 5.5 and 6.4 now say expressly that this inspector restriction does not remove Complete
Recording or Current Filtered Result JSON file export. That separate workflow still requires its
unencrypted/pseudonym/content/provider-sync disclosure, native save panel, bounded streaming,
owner-only temporary sibling, cancellation, and atomic destination commit. Task 6.4 exercises actual
macOS text controls, keyboard commands, and contextual commands rather than testing only model
methods.

## Prior SPD Regression Check

| Area | Round-5 result |
| --- | --- |
| Live callback and projection | Resolved without regression: exact ingress/window count and byte ownership, constant callback operations, off-lock release, one drain/dirty successor, bounded resident rows, one 10-Hz wake, and diagnostic-versus-structural evidence remain explicit. |
| Query work and plans | Resolved without regression: catalogs, gaps, causality, live evaluation, cancellation, VM/time/result bounds, exact indexes, accepted plans, and fixed refine behavior remain closed. |
| Renderer and accessibility resources | Resolved without regression: raw/pretty/tree/log/table/numeric input, output, work, page/node, preview, accessibility, retained-value, cancellation, and control/bidirectional escaping limits remain independent and testable. |
| Composer and control admission | Resolved without regression: incremental field caps, checked JSON formula, bounded TTL, one encode/traversal/copy, opaque targets, bounded terminal cache, O(1) per-target admission, and truthful local-only results remain intact. |
| Cleanup and content retention | Resolved without regression: every producer is joined; canonical, derived, input, validation, accessibility, coalescer, and live content is cleared; reflection is redacted; and fresh-runtime absence is tested. |
| Migration resources and lifecycle | Resolved and strengthened: the earlier system-temp, two-volume, cache, heap, cancellation, rollback, descriptor, retry, and documentation controls now end at an unpublishable migration connection followed by a freshly probed normal pool. |
| Evidence and documentation | Resolved without regression: every normative count/byte/logical deadline/generation/token/VM/page/cursor/wake/lease/cache/connection-lifecycle bound gates release; wall-clock and whole-process heap values remain diagnostic only. |

## Verified Boundaries With No Additional Finding

- Runtime components, coordinator generations, query arbiter leases/tokens, filtered-export scope,
  and shutdown ordering remain internally owned and stale-result safe.
- Source-neutral current/history scope, partial materialization, selected-device preservation,
  durable-only FTS, and atomic current-to-durable replacement remain bounded.
- Live ingress `untracked`, exact durable reconciliation, duplicate/conflict horizon disclosure, and
  store-unavailable behavior retain no hidden unbounded key history.
- Target capabilities and terminal cache remain bounded, memory-only, non-retargetable, and
  content-free. `Queued locally` still makes no peer-delivery or execution claim.
- Export remains a deliberate disclosed file operation with no destination persistence; inspector
  clipboard/share exclusion does not weaken or silently bypass that disclosure.
- Safe status/device/recent rows, logs, analytics, preferences, and generic reflection remain
  content-free. Explicit inspector, editable input, accessibility, and file-export surfaces retain
  their separate documented privacy contracts.
- The change still adds no public SDK/Core API, wire field, cloud/server path, third-party runtime
  dependency, nested manifest, tracking, entitlement, Required Reason API, or root-package
  dependency. Final source/archive audits remain required.

## Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  completed successfully with `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` completed successfully with no output.
- No production or test source and no artifact other than this report was modified.

## Conclusion

There are **zero unresolved security, performance, or documentation findings** in the current
pre-implementation artifacts. This review dimension of task 1.2 is approved for implementation.
