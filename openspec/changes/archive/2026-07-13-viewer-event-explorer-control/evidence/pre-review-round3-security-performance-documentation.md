# Pre-Implementation Security, Performance, and Documentation Review — Round 3

## Verdict

**Not approved for implementation.** The round-2 remediation closes the previously reported
renderer, composer, cleanup, evidence, and most migration-governance gaps. Two actionable artifact
issues remain: the required migration-only SQLite temporary directory has no safe implementation
mechanism under the system SQLite contract, and the clipboard prohibition conflicts with the
required paste test.

| Severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 1 |
| Medium | 0 |
| Low | 1 |
| **Total actionable** | **2** |

Implementation remains blocked until the normative artifacts are revised and a fresh independent
review reports zero unresolved actionable findings.

## Scope Reviewed

- Repository `AGENTS.md`, the latest proposal, design, task plan, and all three delta
  specifications.
- All round-1 and round-2 architecture/API, correctness/testing, and
  security/performance/documentation reports, plus both remediation records and the appended
  post-remediation self-audit clarification.
- Canonical local-store/search, Event-model, queue, multi-device, export, privacy, cleanup, and
  storage-capacity requirements.
- Current system-SQLite configuration, schema/migration, store-capacity and file-inspection seams;
  Core Event content/model/TTL limits; Viewer queue admission; and application privacy/cleanup
  boundaries.
- The macOS 16 SDK's system `sqlite3.h` contract for temporary-directory and heap-limit APIs, and
  the system SQLite build's relevant compile options.

No production, test, proposal, design, task, or specification source was modified by this review.

## Prior SPD Finding Verification

| Finding | Round-3 status | Independent verification |
| --- | --- | --- |
| SPD1 | Resolved | Callback ingress, projection ownership, large-value release, resident presentation, refresh cadence, Pause behavior, and structural evidence gates are now explicitly bounded. |
| SPD2 | Resolved | Catalog, gap, causality, and live matching have exact indexes, result/work/time/cancellation limits, accepted plans, and fixed refine behavior. |
| SPD3 | Resolved | Raw, pretty, tree, log, table, numeric, preview, accessibility, derived-byte, work, and structured-control/bidirectional-label limits are explicit. |
| SPD4 | Resolved | Editable fields use incremental accounting, composer preparation encodes once, and per-target admission uses the prepared value without repeated traversal or deep copying. |
| SPD5 | Resolved | The cleanup receipt names and joins every content-bearing producer and clears every resident content/filter/composer/accessibility value before completion. |
| R2-SPD1 | Partially resolved | Headroom, progress, cancellation, retry, rollback, status, cache target, fixture heap, and cleanup gates are present. The connection-specific Application Support temporary-directory mechanism is not safely defined. See R3-SPD1. |
| R2-SPD2 | Resolved | Log object matching is additionally capped at 4,096 top-level entries under its 1-MiB/100-ms budget; table and label bounds remain complete. |
| R2-SPD3 | Resolved for sizing | The checked JSON formula, `UInt64` TTL editor, nine-digit syntax/range, incremental accounting, and one prepared draft are coherent with current Core hard limits. Clipboard behavior remains contradictory. See R3-SPD2. |
| R2-SPD4 | Resolved | Canonical detail, all renderer derivatives, selections, filters, composer/validation text, focused accessibility, coalescers, live values, reflection, and fresh-runtime absence are all covered. |
| R2-SPD5 | Resolved | Normative count/byte/logical-deadline/operation gates, exact migration/live fixtures, structural counters, diagnostic-only wall/heap context, release documentation, and spec-to-evidence audit requirements are explicit. |

The latest self-audit clarifications are also reflected consistently in the normative artifacts:
live-ingress rejection returns `untracked` while still submitting to the serial writer; duplicate
equivalence excludes newly sampled Viewer receive times while comparing exact fields/bytes; manager
terminal classification is ordered around capability lookup and committed enqueue; and log-object
search has the 4,096-entry scan ceiling.

## Actionable Findings

### R3-SPD1 — High — The migration-only Application Support SQLite temp directory has no safe system-SQLite mechanism

The design requires the schema-1 migration connection alone to use disk-backed SQLite sorting in a
dedicated owner-only, nonsymlink `migration-temp` directory under Application Support, then remove
that directory after success, cancellation, rollback, or recovery. Normal connections must keep
`temp_store=MEMORY` (`design.md:416-423`; local-store delta `spec.md:5-11`; `tasks.md:8,41`). The
delta simultaneously requires the system SQLite library.

The ordinary system-SQLite interface does not provide a per-connection temporary-directory option.
The macOS 16 SDK documents `sqlite3_temp_directory` as a process-global legacy variable affecting
all built-in VFS temporary files. It strongly discourages use outside WinRT, says reading or
modifying it is unsafe while a database connection is used on another thread, and says it is
intended to be set once before any SQLite interface call and remain unchanged. The documented
`temp_store_directory` pragma mutates that same global (`sqlite3.h:6730-6764`). Therefore setting it
for migration and restoring it afterwards would violate the SQLite lifecycle contract; leaving it
set while deleting the directory would leave process-global SQLite temporary-file routing pointed
at a removed path. Opening the Viewer query/export readers only after migration does not prove that
no other framework or process component has used the system SQLite library.

The current Viewer uses the built-in VFS and only sets per-connection `PRAGMA temp_store=MEMORY`
(`ViewerSQLite.swift:390-423`); it has no custom VFS, helper-process, or other connection-scoped
temporary-path seam. A custom VFS wrapper or isolated helper process could make the requirement
implementable, but either is a material security/lifecycle design choice that cannot safely be
invented during source apply. Alternatively, the artifacts can rely on the app-sandbox-private
system temporary directory and remove the Application Support location requirement.

The 32-MiB page/cache value is also only described as a target. System SQLite's documented soft heap
limit is process-wide and advisory, not a hard connection limit (`sqlite3.h:7257-7303`). The existing
128-MiB populated-fixture gate remains useful, but it does not substitute for defining which
connection/VFS owns sorter files and which observable configuration provides the intended bounded
strategy.

**Required artifact changes:**

1. Choose and normatively describe one safe mechanism: a migration-connection custom VFS that routes
   only SQLite temporary opens, an isolated migration helper process with its own pre-initialization
   environment, or use of the sandbox-private OS temporary directory. Do not base the design on
   mutating `sqlite3_temp_directory`/`PRAGMA temp_store_directory` around an active process.
2. If a custom VFS or helper is selected, define registration/startup order, exact ownership,
   cancellation/crash/retry teardown, temporary-file identification, `0700`/`0600` and nonsymlink
   enforcement, escape/failure handling, and how main database/WAL/SHM opens remain unchanged.
3. Define the post-migration transition before writer publication: close the migration-only
   connection or restore and probe the normal `temp_store=MEMORY`/cache configuration on a safe new
   writer connection before readers and persistence become available.
4. Extend tasks/evidence with a test proving the migration connection uses only the selected private
   temporary location without changing process-global SQLite routing, inspection while a sorter file
   is live, cleanup after every terminal path and next-launch recovery, and coexistence with an
   unrelated normal system-SQLite connection. Record the exact cache/temp/worker configuration and
   SQLite memory/temp high-water for the maximum indexed-key fixture in addition to the existing
   100,000-Event/10,000-gap gate.

### R3-SPD2 — Low — Clipboard prohibition and the required over-cap paste case are inconsistent

The design and delta spec say Event content must remain absent from clipboard actions and that V1
adds no clipboard actions (`design.md:390-393`; explorer delta `spec.md:120,136-138`; `tasks.md:37`).
Task 6.4 nevertheless requires an “over-cap paste” case and general clipboard-behavior evidence
(`tasks.md:44`); the round-2 remediation repeats that requirement. On macOS, paste is a clipboard
action, and ordinary SwiftUI/AppKit text editors may expose copy, cut, paste, Services, and contextual
commands automatically even when the product does not add custom buttons.

The artifacts therefore do not tell implementation or tests whether all Event-content clipboard
interaction is forbidden, whether inbound paste is an intentional exception, or whether only
outbound Event-content copying is forbidden. This is a narrow wording issue, but it is a privacy
boundary and cannot be left to default text-control behavior.

**Required artifact changes:**

1. Select one policy explicitly. To preserve the previously stated zero-clipboard boundary, replace
   “over-cap paste” with an over-cap edit-range/programmatic bulk-insertion case and require copy,
   cut, paste, Services, contextual commands, and other Event-content pasteboard paths to be absent
   or disabled. If inbound paste is intentionally permitted instead, amend every blanket clipboard
   prohibition to say that capped inbound paste is the sole exception and explicitly prohibit
   outbound copy/cut/Services/drag/share behavior.
2. Make task 6.4 test the selected policy using the actual macOS text controls, including default
   keyboard and contextual commands, while retaining the existing incremental byte/range and
   shutdown/reflection assertions.

## Verified Areas With No Additional Finding

- Migration now has checked disk headroom, a live free-space floor, exact progress/cancellation
  checks, one automatic attempt, explicit retry, fixed content-free status, rollback-safe schema
  publication, in-transaction probes/plans, cleanup, and release-blocking fixture gates. Those
  controls remain valid once R3-SPD1 defines the temporary-file mechanism.
- Renderer input, scan, output, preview, page, retained-descriptor, accessibility, cancellation, and
  structured-label escaping caps are complete. No renderer retains a copied full value beyond the
  canonical detail buffer.
- The composer JSON formula is checked and conservative relative to Core content/model expansion and
  the 16-MiB Viewer queue ceiling. TTL syntax/range is bounded, preparation traverses/encodes/copies
  once, and target-specific negotiated rejection remains manager/session-owned.
- Runtime cleanup closes admission, invalidates generations, joins all producers, clears all
  content-bearing resident state and focused accessibility, redacts reflection, and prevents old
  content from entering a fresh runtime.
- Control capabilities and terminal-cache results are bounded, memory-only, content-free, ordered,
  and truthful. `Queued locally` makes no delivery, acknowledgement, execution, or processing claim.
- Export retains owner-only temporary output, bounded streaming, mandatory unencrypted/pseudonym/
  content/provider-sync disclosure, cancellation, atomic replacement, and no destination
  persistence.
- The feature remains Viewer-only and adds no SDK/Core public API, wire field, server/cloud path,
  third-party runtime dependency, nested package manifest, tracking, new entitlement, or new Required
  Reason API. The final source/archive privacy audit remains required.
- English operator documentation, Viewer/package validation, independent implementation reviews,
  remediation loops, and a requirement-to-evidence audit remain explicit release gates.

## Validation Observed

- Strict OpenSpec validation was run against the round-3 artifact tree and reported the change
  valid.
- No production or test source was modified by this review.
