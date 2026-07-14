# Security, Performance, and Documentation Artifact Pre-Review — Round 3

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Approved for implementation from the security, performance, and documentation dimension.**

This review independently re-read the current proposal, design, tasks, all five capability deltas,
the Round 2 security/performance/documentation report, and `pre-review-remediation-round2.md`. No
actionable privacy, content-retention, resource-bound, denial-of-service, cleanup, dependency,
documentation, evidence-plan, or signing-boundary finding remains.

## Prior Round 2 finding

**Resolved.** Round 2 found that the claimed exact peak omitted in-flight Store and live gap carriers.
The current artifacts now close that ownership:

- Every Store/live gap crosses the performance boundary only as a fixed 256-byte normalized carrier
  containing bounded identity, a closed safe kind, wall interval, and applicability. Variable
  namespace, reason, and direction strings do not cross
  (`specs/viewer-performance-dashboard/spec.md:148-155`,
  `specs/viewer-local-store-search/spec.md:28-34`).
- A Store gap page contains at most 32 carriers plus a 512-byte wrapper, for 8,704 bytes. A projection
  consumes at most 128 detailed gaps plus `hasMore`; discarded detail sets conservative Unplaced-gap
  behavior instead of reconnecting a chart line.
- The live slice includes its 4,096-byte wrapper, at most 512 Event carriers, 4,194,304 copied content
  bytes, and 128 normalized gaps, for 4,493,312 bytes
  (`specs/viewer-performance-dashboard/spec.md:106-114`).
- The Store Event page now includes its 4,096-byte wrapper and is capped at 4,460,544 bytes. Together
  with the 16,777,216-byte shared ledger, 8,704-byte Store gap page, and 65,536-byte decoder buffer,
  the exact deterministic peak is correctly stated as:

```text
16,777,216 shared ledger
+ 4,460,544 Store Event page
+ 4,493,312 live slice including gaps
+     8,704 Store gap page
+    65,536 decoder buffer
=25,805,312 bytes
```

The formula is arithmetically correct, explicitly allows all five owners to coexist, is not presented
as a Swift heap guarantee, and is carried into tasks 2.2, 2.4, 2.5, 3.2, 6.1, 6.3, and 6.7. The prior
finding is therefore closed without weakening the raw Event or gap authority.

## Security and privacy verification

- Raw durable Events and bounded transient observations remain the only sources of metric truth. The
  projection persists no raw JSON, derived metric, range, chart state, table, index, database, or
  export. Oversized or invalid content remains available only through ordinary bounded Event Explorer
  inspection.
- SQLite reads exact type and BLOB length before content. Content above 65,536 canonical UTF-8 bytes
  returns identity, length, and Invalid metadata without copying JSON. Core-invalid input, duplicate
  known unavailable keys, and known present-plus-unavailable conflicts invalidate the whole typed
  snapshot and publish no metric.
- The closed ordered 16-key vocabulary moves from SDK duplication into Core `NearWireInternal` SPI.
  SDK and Viewer consume one group/kind inventory without public API, encoded JSON, validation,
  collection, or unknown-key behavior changes. Unknown future fields and unavailable keys remain
  raw-only.
- Performance-to-Explorer handoff contains only source generation and a metric-specific canonical
  journal key. It passes no JSON, decoded metric, bucket, tooltip, availability text, renderer, or
  mutable projection object and never selects a neighboring Event when identity is stale or absent.
- Received metrics have no copy, cut, drag, share, clipboard-export, preference, restoration,
  recent-row, safe-status-row, log, analytics, or content-bearing reflection sink. Safe device and
  queue/error surfaces remain content-free.
- Runtime end, window close, listener failure, TLS/full reset, Store/source/device replacement,
  deinitialization, mode replacement, and claimed delivery all invalidate, cancel, join, and clear
  caches, cards, buckets, categorical values, diagnostics, decoded summaries, slices, locators,
  tooltip, accessibility, deadlines, and delivery state before successor admission or the existing
  cleanup receipt.

## Performance and denial-of-service verification

- Event traversal is forward-only and advances an opaque last-examined key for matching and
  nonmatching rows. A turn examines at most 4,096 candidates, emits 512 carriers, copies 4,194,304
  content bytes, executes 5,000,000 injected VM instructions, and stops at an injected 50-ms monotonic
  boundary. Aggregate-byte exhaustion stops before examining the next row; VM/time exhaustion after a
  row advances through it; pre-first-row exhaustion is terminal rather than a livelock.
- Host elapsed time and process heap are diagnostic only. Injected time/VM boundaries and exact
  candidate, page, bucket, cache, diagnostic, mark, accessibility, byte, and cleanup counts remain the
  normative gates.
- One source generation owns one running frozen scan, one dirty successor, one traversal/lease, one
  live slice, one latest-only delivery pump, and one freshness deadline. Sustained refresh therefore
  creates no task or queued projection per sample.
- One result retains at most 512 buckets, ten numeric accumulators per bucket, three bounded
  categorical summaries, 128 detailed gaps, 128 invalid diagnostics, one saturating loss counter,
  16 availability summaries, 12,288 total chart marks, one tooltip, and 64 accessible summaries per
  chart. Overflow preserves discontinuity and never reconnects an uncertain line.
- One shared 16,777,216-byte ledger covers controller/source, active reduction, four completed cache
  entries, presented and pending results, tooltip/crosshair, diagnostics, and identities. Distinct
  results are independently charged; immutable presentation/delivery references do not double-charge
  shared content. Source/device replacement joins old work and clears the one global cache before
  successor admission.
- Store-unavailable and recovery paths discard every partial result and lease. Historical scope shows
  only Storage unavailable; current live-only projection is explicitly incomplete, starts from a fresh
  bounded slice, and cannot reuse predecessor cache state.

## Documentation, dependency, and evidence verification

- Swift Charts is the macOS 13 system framework, not a package dependency. The change adds no
  third-party runtime, root-package/CocoaPods product, entitlement, SQLite migration, or derived
  persistence.
- Task 6.8 requires English operator documentation for authority, ranges, units, receive-time and
  bucket semantics, gaps, unavailable/stale/invalid states, raw reveal, limits, privacy, cleanup,
  exclusions, and signing deferral.
- Tasks 6.1 through 6.7 require boundary, adversarial, lifecycle, privacy, exact-accounting, and
  100,000-sample evidence, including normalized-gap string exclusion and the complete 25,805,312-byte
  peak. Host timing/heap remain paired diagnostics, and no shell harness is allowed.
- Task 6.9 requires the unsigned Viewer build, complete Viewer and affected root suites, Swift lint,
  package/project/plist/privacy inspection, strict OpenSpec validation, and exact saved results.
- Configured signing and inspection of entitlements embedded in a signed product remain explicitly
  deferred by product-owner decision to Goal-level `release-hardening`. No artifact or this review
  claims that deferred gate passed.

## Commands and results

```text
git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

env DO_NOT_TRACK=1 openspec show viewer-performance-dashboard --json --deltas-only
deltaCount: 11
```

## Findings

No actionable findings.

## Unresolved finding count

**0**
