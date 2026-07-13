# Pre-Implementation Security, Performance, and Documentation Review — Round 2

## Verdict

**Not approved for implementation.** The round-1 remediation materially improves the artifacts,
but five actionable findings remain after independent verification against the normative specs and
current implementation seams.

| Severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 1 |
| **Total actionable** | **5** |

Implementation remains blocked until the artifacts are revised and a fresh independent review
reports zero unresolved actionable findings.

## Scope Reviewed

- Repository `AGENTS.md`, latest proposal, design, task plan, and all three delta specifications.
- All three round-1 review reports and `pre-review-remediation-round1.md`; the remediation claims
  were treated only as an index and were checked against the revised normative text.
- Canonical Event-model, queue, rate, local-store/search, multi-device, export, privacy, and cleanup
  requirements and the current Viewer operator documentation/roadmap.
- Current Core Event content/model limits, Viewer queue limits, SQLite connection configuration,
  schema/migration, store capacity, query/export, session admission, reflection, privacy manifest,
  and application cleanup seams.

No production or test source was modified by this review.

## Round-1 SPD Verification

| Finding | Round-2 status | Independent verification |
| --- | --- | --- |
| SPD1 | Resolved | The revised artifacts specify fixed callback ingress, off-callback O(1) projection storage, large-value release outside locks, resident model caps, one 10-Hz wake, pause suppression, and required latency/heap/count evidence. |
| SPD2 | Resolved for explorer reads/live matching | Catalog, gap, causality, and live matching now have exact result/work/time/cancellation/plan limits and required indexes. Round-2 finding R2-SPD1 concerns the separate schema migration that creates those indexes. |
| SPD3 | Partially resolved | Raw, pretty, tree, accessibility, and numeric limits are explicit, but log and table renderer budgets remain undefined. See R2-SPD2. |
| SPD4 | Partially resolved | Incremental buffers and encode-once multi-target admission are specified, but the JSON field uses the wrong Core limit and TTL has no prevalidation storage contract. See R2-SPD3. |
| SPD5 | Partially resolved | The cleanup receipt names and joins operations, but does not normatively clear all resident detail/renderer/filter buffers. See R2-SPD4. |

## Actionable Findings

### R2-SPD1 — High — Schema-1-to-2 index migration has no memory, disk, progress, or cancellation boundary

The revised change requires one writer transaction to create three indexes over all existing Event
and gap rows (`design.md:321-340`; local-store delta `spec.md:3-21,81-85`; `tasks.md:7`). That work is
history-size-linear, unlike the now-bounded interactive queries. A valid current store may be
configured up to 1 TiB (`openspec/specs/viewer-local-store-search/spec.md:134-142` and
`ViewerStoragePreferences.swift:3-18`). The current writer configures `temp_store=MEMORY` and WAL
(`ViewerSQLite.swift:390-423`), while current schema migration runs without a progress budget
(`ViewerStoreSchema.swift:5-34`). Building the scoped Event UUID index can therefore require a large
SQLite sorter allocation and a large index/WAL write. The existing 64-MiB normal-write disk floor is
not an index-build headroom proof.

The artifacts require rollback safety but do not specify a migration operation token, cancellation
at application termination, maximum memory strategy, physical-space preflight, progress state, or
retry policy. A large but valid internal database can consequently make Viewer startup consume
unbounded memory, exhaust the volume, or remain in an opaque migration for an arbitrarily long time.
Failing closed after OOM/disk exhaustion is not a sufficient resource boundary.

**Required artifact changes:**

1. Add a normative migration resource decision covering the maximum memory/sorter strategy, checked
   physical disk/WAL/index headroom, execution executor, operation token, progress/cancellation
   checkpoints, termination behavior, and safe retry authority. If secure disk-backed temporary
   sorting is selected, amend the current memory-only temporary-storage contract and specify its
   owner-only nonsymlink creation and cleanup; do not change it only in source.
2. Define the presentation status while schema 1 is intact/migrating/space-blocked/cancelled/failed.
   Networking and the bounded live projection may continue, but query/export/persistence availability
   and retry must be honest and must not spin automatically.
3. Preserve the all-or-nothing schema contract: interruption or insufficient resources must leave a
   probe-valid schema 1, remove temporary migration artifacts, and never publish schema 2 until all
   three indexes and final plans pass.
4. Extend tasks/evidence with large populated schema-1 fixtures, near-capacity volume simulation,
   migration cancellation/termination, injected failure during each index, WAL/temp/heap high-water,
   progress responsiveness, file modes/symlink checks, retry, and post-rollback/post-success probes.
   State pass/fail budgets rather than saving measurements without acceptance criteria.

### R2-SPD2 — Medium — Log and table renderers still lack exact byte, row, time, and accessibility bounds

The revised artifacts close the raw/pretty/tree/numeric portion of SPD3 with explicit limits
(`design.md:220-244`; explorer delta `spec.md:75-81`; `tasks.md:28,45`). In contrast, `log.*` is only
described as a string or object with `message`, and `table.*` only as a “bounded” top-level scalar
object. No numeric input, output, row, work, elapsed-time, preview, or accessibility limit is stated
for either renderer.

This omission is material because Core allows a 1-MiB string/key and 100,000 object entries
(`EventValidationLimits.swift:90-99`). A valid paired App can therefore make a naïve table renderer
materialize 100,000 rows or copy large keys/values despite the 600-row timeline and 4,096-node tree
caps. The generic renderer fallback mentions byte/time/work exhaustion, but an implementation cannot
enforce or test an unstated limit. Decoded keys/messages can also contain control or bidirectional
characters and should not be allowed to visually or accessibly impersonate Viewer-owned metadata.

**Required artifact changes:**

1. Give `log.*` and `table.*` exact input-byte, derived-output-byte, elapsed-time, work/row, preview,
   and accessibility caps. Table rows must be paged/chunked or truncated with explicit `hasMore`/
   refine guidance; neither renderer may retain copied full values beyond the one canonical detail
   buffer.
2. Define safe display of untrusted decoded keys/messages: preserve content through the raw surface,
   but escape or visibly isolate control/bidirectional text in structured renderer labels so it cannot
   masquerade as Viewer status, metadata, or controls.
3. Add maximum 100,000-entry, 1-MiB key/message, mixed scalar, control/bidirectional, VoiceOver,
   cancellation, and rapid-selection tests. Save peak derived bytes, retained row/value counts,
   elapsed work, and stale-publication results for log and table independently.

### R2-SPD3 — Medium — Composer prevalidation uses the 128-MiB model limit for JSON content and omits TTL input storage

The composer caps ordinary JSON text at the “Core encoded-model limit” (`design.md:268-280`; explorer
delta `spec.md:112-118`). That is not the authoritative input limit for ordinary JSON content.
`JSONValue.decodeJSON` preflights against `maximumEncodedContentBytes`, whose hard maximum is 16 MiB,
while `EventDraft`'s tagged model limit may be as high as 128 MiB
(`EventValidationLimits.swift:77-119`; `JSONValue.swift:70-95`). Viewer queues also hard-cap one Event
at 16 MiB (`EventQueueConfiguration.swift:67-105`). The current wording therefore permits a
MainActor-bound text buffer up to 128 MiB that can never pass the content validator or Viewer queue.
That defeats the purpose of pre-parse resource limiting and creates avoidable copies during
SwiftUI/AppKit editing and UTF-8 conversion.

TTL is another editable composer field, but it is absent from the incrementally bounded field list,
task 4.5, and the rapid-edit coverage. If represented by an ordinary text field, it can retain an
arbitrarily long string before numeric/EventTTL validation even though the eventual value is bounded.

**Required artifact changes:**

1. Cap the JSON editor by the authoritative encoded-content input limit and by the Viewer hard
   single-Event/admission limit, using checked overhead so a permitted buffer can produce a permitted
   prepared draft. If per-target negotiated limits differ, keep per-target `queueRejected` semantics
   but do not allow the editor above the Viewer-wide hard maximum.
2. Define TTL as either a bounded native numeric control or an incrementally capped ASCII-decimal
   buffer with exact character/byte/range/overflow behavior. Add it to task 4.5 and rapid-edit,
   shutdown, reflection, logging, preference, and clipboard coverage.
3. Test the exact content/model/queue boundaries, a model limit larger than the content limit,
   multibyte edit replacements, over-cap paste/input attempts, TTL overflow/leading signs/whitespace,
   and prove bounded MainActor storage/copies before off-main preparation begins.

### R2-SPD4 — Medium — Cleanup joins operations but does not require clearing resident detail, renderer, and filter content

The revised cleanup receipt correctly closes admission, invalidates generations, cancels and joins
named operations, clears coalescers/accessibility/composer/live content, and releases leases
(`design.md:304-312`; explorer delta `spec.md:132-142`). It does not explicitly clear the selected
canonical Event detail buffer, raw chunk/tree/log/table/numeric derived state, or the search/JSON-path/
comparison input buffers. The resident-state decision even allows one selected detail buffer after
its row is evicted (`design.md:350-357`). Cancelling a completed renderer task does not release values
already retained by the MainActor model.

This leaves SPD5's zero-content-after-cleanup property dependent on implementation choice. It is
especially relevant to TLS/full identity reset and sequential runtime replacement, where the process
and application model can survive and old content could remain visible, reflectable, or accessible
to the next runtime. Task 6.7 asks for zero content buffers, but that task is stronger than the
normative lifecycle text it is meant to evidence.

**Required artifact changes:**

1. Require the explorer cleanup barrier to clear the canonical selected detail buffer, every raw/
   tree/renderer derived buffer and selection, all transient search/path/comparison/composer input,
   focused accessibility content, and any cached validation failure that can contain user text before
   the receipt completes. Persisted recording metadata remains governed by the store and is not
   erased by runtime cleanup.
2. Require redacted `description`, `debugDescription`, and `customMirror` for every new content-bearing
   input/prepared/detail/renderer model, including late cancelled values; prohibit their content in
   logs, analytics, preferences, recent rows, restoration state, and clipboard actions.
3. Extend task 6.7 with post-cleanup inspection after every stop/reset/replacement path, then start a
   fresh runtime and prove no prior detail/filter/accessibility/reflection value appears. Count all
   retained content buffers and subscriptions, not only active tasks.

### R2-SPD5 — Low — One normative catalog scenario still requires the removed activity keyset, and benchmark evidence lacks release criteria

The revised catalog requirement correctly orders recordings by immutable descending row ID and
forbids mutable activity ordering (`design.md:108-125`; local-store delta `spec.md:75-77`). Its
existing scenario still says the next page continues by an “activity/row-ID keyset”
(`specs/viewer-local-store-search/spec.md:89-93`). This contradicts the normative paragraph and the
round-1 CT3 remediation claim, and could produce a stale test or accidental activity-derived query.

Separately, task 6.9 asks to save callback latency, heap high-water, transaction times, and work
counts but does not state acceptance thresholds, formulas, fixture sizes, or whether any measurement
is diagnostic only. A saved number alone cannot demonstrate that a resource requirement passed and
does not satisfy the repository rule to match evidence to every requirement.

**Required artifact changes:**

1. Replace the stale scenario wording with the immutable row-ID keyset and exact frozen cursor
   semantics used by the normative requirement.
2. Define pass/fail criteria and exact fixtures for every required latency/heap/disk/work measurement,
   or explicitly label a diagnostic-only measurement and pair it with a deterministic structural
   invariant that gates release. Operator documentation must not convert an accounting or diagnostic
   measurement into an actual-heap/latency guarantee.

## Verified Areas With No Additional Finding

- The revised live pipeline now separates the protocol callback from eviction/deallocation, bounds
  ingress and projection ownership, limits drains/wakes, distinguishes accounted bytes from heap,
  and requires maximum-shape/cadence evidence.
- Explorer catalogs, gaps, causality, live matching, resident paging, and MainActor refresh now have
  explicit work/result/cancellation limits. FTS5 is correctly durable-only for transient rows, with
  fixed guidance instead of guessed tokenizer behavior.
- Transient/durable reconciliation uses exact runtime/connection/direction/sequence identity. Peer
  Event UUID remains content, duplicate/conflict behavior is explicit, and new durable device logical
  identity uses the exact admission connection ID without rewriting closed history.
- Query operations are coordinator- and operation-exact; filtered export receives an immutable
  scope and independent export lease. Raw SQLite pointers, SQL/errors, database paths, and filesystem
  phases remain outside MainActor models.
- Export retains mandatory pre-save disclosure, owner-only temporary output, bounded streaming,
  cancellation, atomic replacement, pseudonym/unencrypted/provider-sync wording, and no destination
  persistence.
- Control-target identities/results are closed and content-free, admission is encode-once and
  per-target O(1), and `Queued locally` makes no peer-delivery or execution claim.
- Event content remains excluded from safe status/device/recent rows, logs, preferences, generic
  reflection, analytics, and clipboard actions. The selected inspector is the intentional content
  accessibility surface; keyboard and non-color requirements are present.
- The feature remains Viewer-only and adds no public SDK/Core API, wire field, cloud/server behavior,
  third-party runtime dependency, nested manifest, entitlement, tracking, new Required Reason API,
  or root-package dependency. The existing privacy-manifest scope remains appropriate, subject to
  the required final source/archive audit.
- The task plan requires English operator documentation, Viewer/package builds, strict OpenSpec
  validation, independent implementation reviews, remediation loops, and a spec-to-evidence audit
  before archival.

## Validation Observed

- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive` was
  run against the round-2 artifact tree and reported the change valid.
- No production or test source was modified by this review.
