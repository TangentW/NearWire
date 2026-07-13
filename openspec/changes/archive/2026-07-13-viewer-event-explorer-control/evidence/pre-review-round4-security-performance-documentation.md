# Pre-Implementation Security, Performance, and Documentation Review — Round 4

## Verdict

**Approved for implementation.** The current proposal, design, task plan, and three delta
specifications resolve both round-3 security/performance/documentation findings and introduce no
regression in the earlier security, performance, privacy, cleanup, or evidence contracts.

| Severity | Unresolved count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| **Total actionable** | **0** |

This approval applies only to the pre-implementation artifacts. Each task checkbox still requires
its stated implementation and saved evidence, and completion remains subject to tasks 7.1 through
7.3.

## Scope and Method

This review independently reread:

- repository `AGENTS.md`, the current proposal, design, tasks, and all three delta specifications;
- every round-1, round-2, and round-3 architecture/API, correctness/testing, and
  security/performance/documentation report;
- all three remediation records, including the current round-3 migration, duplicate-equality, and
  clipboard rationale;
- the canonical local-store/search and multi-device requirements and the current Viewer SQLite,
  entitlement, Event-limit, queue, privacy, and cleanup seams; and
- the macOS 16 SDK's system-SQLite temporary-directory and heap-limit contracts plus the installed
  system SQLite compile options.

Historical remediation documents and prior approvals were treated as finding indexes, not as
approval evidence. The current normative artifacts were the conformance authority.

No production or test source and no artifact other than this review report was modified.

## Round-3 Finding Verification

### R3-SPD1 / R3-A1 — Resolved — Migration uses the existing system-private temp route without global mutation

The unsafe migration-only Application Support directory has been removed. The current contract now
uses disk-backed sorting through the system default VFS and the process's existing sandbox/private
temporary hierarchy. NearWire explicitly does not read, set, or mutate `sqlite3_temp_directory`,
`temp_store_directory`, `SQLITE_TMPDIR`, or `TMPDIR`, and does not register a custom VFS
(`design.md:421-440`; local-store delta `spec.md:5-11`; `tasks.md:8,41`).

That choice matches the local system-SQLite API boundary. The macOS SDK documents
`sqlite3_temp_directory` as discouraged process-global legacy state that must not be changed while
other connections may run and is intended to remain fixed after process initialization. The revised
artifacts no longer require or permit that unsafe lifecycle. The Viewer target is App Sandbox
enabled, and migration fails closed before `BEGIN IMMEDIATE` unless the process-provided temporary
directory is an existing, current-user-owned, mode-`0700`, nonsymlink directory.

Resource and confidentiality ownership are also closed:

- checked headroom applies independently to the database and temporary volumes, once if they are
  the same volume, and the 256-MiB live floor applies while migration executes;
- one tokenized off-MainActor writer, one index statement at a time, disk-backed sorting, a 32-MiB
  page/cache target, no application row array, and the 128-MiB fixture heap gate bound the intended
  strategy without misrepresenting SQLite's advisory soft heap limit as a hard guarantee;
- sorter payload is limited to the three index key sets and excludes Event JSON;
- the system VFS owns delete-on-close, and the joined migration receipt requires zero remaining
  sorter descriptor after success, cancellation, or rollback; and
- crash reclamation, WAL history, temporary storage, snapshots, and backups are documented as
  logical cleanup rather than secure erasure.

Tasks 2.1, 6.1, 6.8, and 6.9 now require unsafe/symlink/wrong-mode root rejection, distinct-volume
space and overflow cases, unchanged process-global routing and VFS, live sorter mode/content
inspection, zero-descriptor cleanup, cancellation/termination/retry, WAL/temp/heap high-water, and
post-rollback/post-success probes. Normal connections remain `temp_store=MEMORY`; the migration
exception does not widen Core, SDK, root-package, or third-party dependency scope.

### R3-A2 — Resolved — Live and durable duplicate comparison use the same field set

The design, local-store delta, and multi-device delta now agree on one comparison domain. Journal
identity is the exact runtime/connection/direction/sequence identity represented durably by the
recording/device/direction/sequence key. Equality compares the complete canonical Event
envelope/content and initial disposition field/byte-exactly, excludes the later observation's newly
sampled Viewer receive wall/monotonic times, and never trusts a hash alone
(`design.md:175-211`; local-store delta `spec.md:15`; multi-device delta `spec.md:29-35`).

Frozen session metadata remains in the normalized observation for presentation and filtering but is
explicitly excluded from duplicate equality because it is validated and owned by the session
boundary. The same comparison therefore applies while a key is pending/retained and after eviction
or `untracked` ingress when an existing durable row is the second authority. The bounded horizon,
typed `journalConflict`, no-store behavior, exact reconciliation, first receive-time preservation,
and no global post-eviction first-wins claim remain coherent.

### R3-SPD2 — Resolved — Clipboard access is an explicit operator-input boundary

The blanket clipboard wording has been replaced with a narrow and testable policy
(`design.md:373-400`; Event Explorer delta `spec.md:114-138`; `tasks.md:37,44`):

- standard user-invoked paste, copy, and cut are allowed only in operator-owned editable composer,
  filter, and metadata controls;
- pasted replacements must satisfy the same incremental byte/scalar caps before model storage;
- NearWire performs no background pasteboard read or monitoring, restoration, or custom clipboard
  history; and
- received/stored Event inspector content has no copy, cut, drag, share, or clipboard-export
  command.

The deliberate JSON recording export remains the separately disclosed, bounded, owner-only,
atomic export workflow; it is not a clipboard command. Task 6.4 now tests the actual standard input
paste path, multibyte replacement and over-cap rejection before storage, default clipboard behavior,
no background read, and no received-Event clipboard export.

## Prior SPD Finding Disposition

| Finding | Round-4 disposition | Current basis |
| --- | --- | --- |
| SPD1 — Callback, resident state, and refresh | Resolved | Fixed 64/20-MiB ingress, constant lock/index/ring operations, no callback eviction or large release, one drain plus dirty successor, O(1) 512/32-MiB window, exact resident caps, 10-Hz latest-only wake, Pause suppression, and structural/diagnostic evidence separation remain normative. |
| SPD2 — Query work and plans | Resolved | Catalog, gap, causality, and live evaluation retain exact result, byte, VM-step, logical-time, cancellation, transaction, index, accepted-plan, and fixed refine bounds. |
| SPD3 — Renderer resource and accessibility bounds | Resolved | Raw, pretty, tree, log, table, numeric, preview, accessibility, structured-control escaping, derived-byte, retained-value, work, and cancellation limits remain complete and independently tested. |
| SPD4 — Editable input and encode-once admission | Resolved | Incremental pre-storage field caps, checked JSON content/model/16-MiB formula, bounded `UInt64` TTL, one replaceable preparation, exactly one encode/traversal/copy, and O(1) per-target admission remain explicit. |
| SPD5 — Complete cleanup | Resolved | Cleanup closes admission, invalidates generations, joins every named content producer, clears all canonical/derived/filter/composer/validation/accessibility/live values, releases exact leases, redacts reflection, and proves no old content in a fresh runtime. |
| R2-SPD1 — Migration governance | Resolved | Token, executor, system-default-VFS disk sorter, verified private temp root, two-volume headroom/floor, cache strategy, progress, cancellation, rollback, retry, safe status, descriptor cleanup, heap gate, and documentation are all specified. |
| R2-SPD2 — Log/table bounds | Resolved | Log and table retain exact independent input, scan, output, page, descriptor, preview, accessibility, time, `hasMore`, and untrusted-label escaping limits. |
| R2-SPD3 — Composer JSON/TTL | Resolved | The checked formula is conservative relative to current Core content/model invariants and Viewer queue ceiling; TTL syntax/range and paste/edit accounting are bounded before storage. |
| R2-SPD4 — Resident-content cleanup | Resolved | Canonical detail, all renderer derivatives, selections, inputs, validation text, focused accessibility, coalescers, live values, reflection, restoration, and fresh-runtime absence remain covered. |
| R2-SPD5 — Evidence criteria | Resolved | Every normative count/byte/logical-deadline/generation/token/VM/page/cursor/wake/lease bound gates release; wall-clock and whole-process heap diagnostics remain paired with deterministic structural gates and are not product guarantees. |

## Verified Boundaries With No Additional Finding

- Runtime component identity, coordinator-generation routing, exact query arbitration, immutable
  filtered-export scope, and shutdown ownership remain internal, bounded, and Sendable-aware.
- Source-neutral current/historical scope, partial durable materialization, exact selected-device
  preservation, durable-only FTS, and current-to-durable generation replacement remain closed.
- Live ingress rejection still returns `untracked` and submits to the serial writer; if storage is
  unavailable too, no forgotten-content or duplicate guarantee is claimed.
- Opaque target capabilities, exact terminal cache bounds/expiry/eviction, manager-serial terminal
  ordering, encode-once prepared values, and `Queued locally` wording remain content-free and make no
  delivery, acknowledgement, execution, or processing claim.
- Export remains bounded, cancellation-safe, owner-only, atomic, unencrypted, pseudonymous rather
  than redacted, content-bearing, outside Viewer quota/retention, and disclosed before the save
  panel; destinations are not persisted.
- Safe device/status/recent rows, logs, analytics, preferences, and generic reflection remain
  content-free. Event content appears only in explicit operator surfaces subject to their stated
  accessibility, editor, inspector, export, and cleanup boundaries.
- The change adds no public SDK/Core API, wire field, server/cloud path, third-party runtime
  dependency, nested package manifest, tracking, entitlement, Required Reason API, or root-package
  dependency. Final implementation and archive privacy/package inspection remain mandatory.
- English operator documentation, Viewer/package builds and tests, strict OpenSpec validation,
  independent implementation reviews, remediation loops, and requirement-to-evidence audit remain
  explicit gates.

## Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  completed successfully with `Change 'viewer-event-explorer-control' is valid`.
- `git diff --check` completed successfully with no output.
- No production or test source and no artifact other than this report was modified by this review.

## Conclusion

There are **zero unresolved security, performance, or documentation findings** in the current
pre-implementation artifacts. This review dimension of task 1.2 is approved for implementation.
