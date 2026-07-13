# Pre-Implementation Round 2 Security, Performance, and Documentation Review

Date: 2026-07-13

## Scope

This is a fresh review of the current `viewer-local-store-search` proposal, design, capability deltas, tasks, validation evidence, Round 1 remediation record, and prior security/performance/documentation report. No production or test source was reviewed or modified.

The review re-tested every Round 1 finding and looked for new contradictions in sensitive-data handling, SQLite input and filesystem boundaries, connection/task ownership, memory and disk bounds, cleanup protection, export disclosure, and privacy-manifest evidence.

## Verdict

**Not approved for implementation.** All seven Round 1 findings are substantively remediated, but the new oversize Event path is incompatible with the physical-reclaim quantum, and the export-confirmation requirement conflicts with the explicitly deferred UI scope. Two actionable findings remain.

Strict validation was rerun against the current tree:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid
```

## Round 1 Finding Verification

| Prior finding | Round 2 status | Evidence in the current artifacts |
| --- | --- | --- |
| `NW-SPD-001` unbounded cleanup | Resolved | Cleanup atomically tombstones at most 32 recordings per turn, owns at most eight turns per trigger and one task plus one dirty successor, and physically reclaims at most 1,024 child rows or 4 MiB per transaction. Active, pinned, and leased recordings remain protected. Finding `NW-SPD2-001` below addresses one new oversize-row mismatch rather than reopening the original unbounded-cascade design. |
| `NW-SPD-002` long reads/WAL ownership | Resolved | The design now uses exactly one writer, one interactive reader, and one export reader on separate serial executors. Query/export use short transactions, fixed VM/time budgets, generation-bound cancellation, frozen Event/recording-version/device-version/transition/gap/drop bounds, and finite leases; cleanup/manual deletion skip leased recordings. Long WAL snapshots are forbidden and sustained-write/WAL ownership tests are planned. |
| `NW-SPD-003` unbounded alias metadata | Resolved | Recording-local installation and device ordinals are stored during durable admission. Export freezes upper installation/device ordinals, pages metadata, and emits aliases from stored ordinals without a Swift alias dictionary. Tests now include many-device as well as many-Event exports and peak-memory evidence. |
| `NW-SPD-004` sidecars and deletion remnants | Resolved | The `0700` Application Support directory and `0600` regular nonsymlink main/WAL/SHM/journal/migration/export-temporary artifacts are explicit. Active-sidecar and post-close inspection, memory-only SQLite temporaries, `secure_delete=ON`, symlink rejection, and the logical-deletion-not-secure-erasure disclaimer are required. |
| `NW-SPD-005` protocol-executor content work | Resolved | Admission uses the decoder's precomputed deterministic byte count, checked fixed metadata, and Swift copy-on-write ownership. JSON encoding, traversal, binding, and deep copy are prohibited on the protocol executor and maximum Event/batch evidence is required. |
| `NW-SPD-006` textual SQL semantics | Resolved | FTS5 terms have exact quote doubling and quoted-AND construction; type prefix uses binary `substr` equality; JSON string containment uses `instr`; NUL/disallowed controls, normalization, wildcards, operators, comments, and Unicode cases have explicit validation and tests. User values remain parameters and never SQL fragments. |
| `NW-SPD-007` disclosure and text bounds | Resolved | The artifacts now state that aliases are pseudonyms, Event/App content can identify secrets or people, exports are unencrypted/outside Viewer quota and retention, and destination providers may sync or back them up. Recording names are capped at 80 scalars/120 UTF-8 bytes; notes and annotation versions at 4,096 scalars/16 KiB, with exact control-character rules. Finding `NW-SPD2-002` is a new change-scope inconsistency in where confirmation is delivered. |

## New Findings

### NW-SPD2-001 — Medium — A legal oversize Event cannot enter the bounded physical reclaimer

Normal writes are capped at 256 observations or 4 MiB, but a single legal Event observation may use the new one-record oversize mode up to a 20-MiB reservation. Quota accounting then reserves `2 * deterministicCanonicalEventBytes + 1 KiB` for its Event plus FTS content. Physical reclaim, however, is required to remove at most 1,024 child rows **or 4 MiB of reserved data** per transaction and defines no one-row oversize exception. A stored Event whose reserved data exceeds 4 MiB cannot satisfy that reclaim predicate, so a tombstoned recording containing such an Event can become permanently unreclaimable while its quota has already been subtracted. This can strand sensitive content and physical disk use and eventually leave the volume guard permanently paused.

Required resolution:

- Add a checked one-row physical-reclaim exception for one legal oversize Event plus its exact FTS/index cleanup, with a hard bound derived from the maximum admitted Event and quota formula.
- State that the reclaimer always makes progress: either a normal batch removes at least one eligible row, or the one-row oversize path handles the next row; an impossible/corrupt larger row must fail closed with a recoverable safe category rather than spin.
- Add a test that admits the maximum legal Event, tombstones its recording, reclaims the Event/FTS rows, updates physical status, and proves no unbounded executor turn or repeated zero-progress maintenance task.

### NW-SPD2-002 — Low — The required export confirmation has no owner in this change

The revised spec requires both documentation **and export confirmation** to present the pseudonym/not-redaction and unencrypted/outside-retention disclosure. The design and tasks simultaneously defer export selection and history workflows to `viewer-event-explorer-control`; this change only supplies an internal exporter and the storage settings surface. Task 5.3 refers generally to disclosure rules, while task 7.4 covers documentation and fixtures, but no current task owns a user-visible export confirmation. A spec-to-evidence audit therefore cannot prove the current `SHALL` without broadening this change into the explicitly deferred UI.

Required resolution:

- Keep the full operator documentation requirement in this change.
- Either defer the user-visible confirmation requirement explicitly to `viewer-event-explorer-control`, or add only a bounded internal disclosure presentation model/contract here and state that the later export UI must render it before invoking the exporter.
- Make the corresponding task and test evidence explicit so the current change does not claim a confirmation surface it intentionally does not build.

## Confirmed Security and Resource Boundaries

- Persistence remains Viewer-only. Event content and internal correlation stay out of Core, SDK, the root package graph, `UserDefaults`, logs, analytics, clipboard, safe status, recent rows, errors, interpolation, reflection, and accessibility values.
- Unknown schema, corruption, failed migration, and missing SQLite features fail closed without deleting the database or changing network-session outcomes.
- Query values and JSON paths are bounded parameters; identifiers, functions, collations, order clauses, and raw expressions are closed implementation choices.
- Lifecycle structural capacity is separate from lossy Event ingress, and unavailable intervals are represented by bounded gaps rather than fabricated durable history.
- Recording and device mutable state is append-only and included in frozen query/export version bounds, so short reads do not silently substitute later names, notes, terminal state, or device metadata into an earlier traversal.
- Prior-process orphan reconciliation is a bounded campaign of at most 32 rows per turn and eight immediate turns; unresolved work keeps the new runtime nondurable until an explicit later retry instead of creating an unbounded startup chain.
- Quota-accounted visible bytes are distinguished from physical SQLite/WAL/SHM footprint. The 64-MiB available-volume floor, bounded campaigns, leases, and capacity-pause behavior avoid a false physical-overshoot promise.
- Export uses a single finite lease, bounded pages/output buffer, owner-only nonsymlink temporary state, flush/close, atomic replacement, and cancellation cleanup. The design correctly limits preservation of an old destination to phases before replacement commits.
- Privacy-manifest reassessment remains a release gate. The implementation must identify the exact filesystem-capacity API used, compare it with Apple's current Required Reason API policy, validate the existing UserDefaults declaration, and inspect the packaged manifest rather than assuming the pre-change manifest remains sufficient.

## Unresolved Count

**2 actionable findings remain unresolved: 0 high, 1 medium, and 1 low. Approval is withheld.**
