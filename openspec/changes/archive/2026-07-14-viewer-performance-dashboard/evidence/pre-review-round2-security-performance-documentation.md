# Security, Performance, and Documentation Artifact Pre-Review — Round 2

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**One medium-severity artifact finding remains before implementation.**

This review re-read the current proposal, design, all four capability deltas, and tasks without
inheriting the Round 1 verdict. The current artifacts now close availability conflicts, oversized raw
content handling, Event-page and live-slice bytes, categorical/diagnostic/chart/accessibility counts,
the single-current-source cache lifetime, injected-clock deadlines, privacy, documentation, and the
Goal-level signing deferral. The remaining issue is limited to one omitted scratch owner in the claimed
exact deterministic peak.

## Medium-severity finding

### 1. The exact peak omits in-flight Store and live gap carriers

**[MEDIUM] (confidence: 9/10)**

`design.md:96-110` and `specs/viewer-performance-dashboard/spec.md:89-95` define the exact
25,755,648-byte performance-owned peak as:

```text
16,777,216 shared ledger
+ 4,456,448 Store Event page
+ 4,456,448 live slice
+    65,536 decoder buffer
= 25,755,648 bytes
```

The same frozen Store scope also exposes up to 128 gap rows plus `hasMore`
(`specs/viewer-local-store-search/spec.md:27-30`), and task 2.4 explicitly returns one bounded live
slice "plus gaps/generation/anchor." Neither artifact assigns a fixed byte charge to the in-flight
Store gap result or live gap carriers, includes them in the 4,456,448-byte page/slice caps, or requires
them to stream one at a time directly into already charged reducer state. They can coexist with the
full Event page, live slice, decoder buffer, and shared ledger. Existing `ViewerGapRow` also contains
variable-length namespace, reason, and direction strings
(`Viewer/NearWireViewer/Store/ViewerStoreDiagnostics.swift:16-29`), so a 128-row count alone cannot
prove the stated byte peak.

This does not reopen an unbounded-memory path because the gap count is finite. It does make the exact
peak and its proposed test oracle incomplete.

**Required artifact change:** Choose one closed ownership model and reflect it consistently in design,
specs, and tasks:

- assign each Store/live gap carrier checked fixed-plus-string accounting, cap the aggregate gap batch,
  add it to the page/slice or shared-ledger budget, and recompute the exact peak; or
- require row-at-a-time gap reduction with one numerically bounded scratch carrier charged in the exact
  peak and prohibit retaining a separate gap-result array.

Extend tasks 2.1, 2.4, 3.2, 6.1, 6.3, and 6.7 to combine 128 maximum-shape gaps plus `hasMore` with a
full Store page, full live slice, decoder buffer, and full shared ledger, then assert the corrected
peak and zero gap scratch after cancellation and cleanup.

## Independently verified closures

- **Availability trust boundary:** Duplicate known unavailable keys and known
  present-plus-unavailable conflicts invalidate the complete typed snapshot. Unknown fields and keys
  remain raw-only, and task 6.2 requires identical/conflicting-duplicate and contradictory-known-value
  coverage.
- **Large and malformed snapshots:** SQLite reads BLOB length before content. More than 65,536 bytes
  returns identity/length/invalid metadata without JSON copy. A turn copies at most 4,194,304 content
  bytes, emits at most 512 carriers, charges 512 bytes per carrier, and caps an Event page at 4,456,448
  bytes with explicit continuation progress.
- **Projection and presentation bounds:** Results have 512 buckets, ten numeric accumulators per
  bucket, first/latest/last state for three categorical metrics, 128 detailed gaps, 128 invalid
  diagnostics, one saturating loss counter, 16 fixed inventory keys, 12,288 total chart marks, one
  tooltip, and 64 accessible summaries per chart. The normative 100,000-sample storm scenario and tasks
  6.3/6.7 require evidence for those caps.
- **Cache and content lifetime:** One shared 16-MiB ledger covers active reduction, four completed
  entries, presentation, claimed delivery, tooltip/crosshair, diagnostics, and identities for only the
  current source/device. Source/device/runtime replacement invalidates, joins, clears all predecessor
  content, and only then admits successor work, including while paused.
- **Raw Event authority:** Durable and transient observations reconcile only by stable journal key.
  Metric-specific representatives pass identity only to the Event Explorer; no JSON, metric, bucket,
  tooltip, or renderer object crosses controllers, and derived buckets are neither persisted nor
  exported.
- **Finite work and timing evidence:** Candidate scanning has exact examined/emitted/content/VM limits.
  The 50-ms boundary uses injected monotonic time with equality/no-progress behavior, and task 6.1
  requires deterministic 49/50/exceeded boundary tests. Host elapsed time and process heap are diagnostic
  only, while structural counts and deterministic accounting remain normative.
- **Privacy and cleanup:** Performance values have no log, analytics, preference, restoration,
  recent/safe-row, clipboard, drag, share, or content-bearing reflection sink. Lifecycle and claimed-
  delivery cleanup joins work and clears models, caches, locators, tooltip, accessibility, and delivery
  state before the existing receipt completes.
- **Dependency, documentation, and signing boundary:** Swift Charts remains the macOS 13 system
  framework rather than a package dependency. No root-package/CocoaPods product, third-party runtime,
  entitlement, schema migration, or derived persistence is added. English documentation covers
  authority, bounds, privacy, cleanup, exclusions, and signing deferral. Configured signing and embedded
  entitlement inspection remain explicitly deferred to Goal-level `release-hardening` and are not
  claimed passed by this change.
- `env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive` passes,
  and OpenSpec parses ten deltas across the four capability specifications.

## Unresolved finding count

**1**
