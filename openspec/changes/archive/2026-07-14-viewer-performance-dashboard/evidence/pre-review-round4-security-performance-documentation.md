# Security, Performance, and Documentation Artifact Pre-Review — Round 4

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Approved for implementation from the security, performance, and documentation dimension.**

This fresh artifact-only review found no actionable privacy, retention, cleanup, resource-bound,
denial-of-service, dependency, documentation, evidence-plan, or signing-boundary issue. The two
Round 3 correctness findings are closed without weakening the security/performance/documentation
contracts or changing the exact deterministic memory peak.

## Independent scope reviewed

- Reread the current `README.md`, proposal, design, tasks, and all five capability delta specs in
  full.
- Reread all three Round 3 reports and `pre-review-remediation-round3.md` in full. No prior verdict
  was inherited without checking it against the current artifacts.
- Rechecked raw authority, decoding and Store limits, gap normalization, cache and concurrency
  bounds, privacy sinks, lifecycle cleanup, dependencies, documentation/evidence requirements, and
  the Goal-level signing deferral in addition to the new Round 3 remediation.
- No production or test source was inspected as implementation evidence, and no implementation test
  was run because this is a pre-implementation artifact review.

## Status of Round 3 findings

### R3-CT-1: late freshness publication — Resolved

Every card result now carries a source generation, latest-Event journal key or durable row identity,
absolute Viewer-monotonic freshness deadline, and monotonically advancing revision. Claim and apply
both validate the complete receipt and injected clock. At or after equality, chart data may publish
but cards are restated as No recent sample and no elapsed deadline is armed
(`specs/viewer-performance-dashboard/spec.md:135-152`; `design.md:147-163`).

The deadline is one replaceable, future-only wake rather than a poll or a task per sample. Its
callback fires at most once, validates the same generation/Event/deadline/revision tuple, and cannot
re-arm an elapsed deadline. Pause retains one bounded dirty bit; Resume performs one fresh
projection. Source/runtime replacement invalidates the receipt before joined cleanup, and the wider
cleanup contract cancels deadline work and clears cards, identities, delivery state, and all decoded
content (`specs/viewer-performance-dashboard/spec.md:221-239,285-311`; `design.md:203-219,229-247`).

The receipt contains fixed identity and scalar metadata, not Event content, decoded metrics, labels,
or variable strings. It remains within the already charged result/controller/identity ownership of
the shared ledger. Tasks 3.5, 4.1, and 4.2 require the implementation boundary, while tasks 6.4 and
6.5 require equality, one-wake, barrier-controlled claim/apply/Pause/Resume/replacement ordering, no
stale-to-fresh reversal, no past-deadline loop, constant bytes, and zero predecessor state.

### R3-CT-2: gap normalization and live overflow evidence — Resolved

The current artifacts define six closed kinds (`eventLoss`, `storageContinuity`,
`controlContinuity`, `lifecycleContinuity`, `presentationLoss`, and `unknown`) and three closed
applicability values (`performance`, `irrelevant`, and `uncertain`). Store normalization uses
case-sensitive ASCII exact/prefix mappings; unrecognized reasons become `unknown`, unrecognized
directions become `uncertain`, and Viewer-to-App-only evidence is explicitly irrelevant. Live
ingress/window, storage, resident-conflict, and diagnostic counters also have closed kind mappings;
every positive live counter is uncertain and interval-less
(`specs/viewer-local-store-search/spec.md:28-46`;
`specs/viewer-performance-dashboard/spec.md:158-181`; `design.md:169-195`).

Only bounded identity, count, optional wall interval, kind, and applicability cross in a fixed
256-byte carrier. Namespace, reason, and direction strings do not cross. A live slice retains at most
128 carriers and its existing fixed 4,096-byte wrapper now carries a saturating applicable-loss total
and `hasMoreApplicableGaps`. Truncation, interval-less applicable evidence, uncertain input, Store or
live `hasMore`, and combined overflow all produce conservative Unplaced-gap suppression. Irrelevant
evidence is counted without breaking the App-to-Viewer series, and forgotten detail cannot reconnect
a line.

Tasks 2.2, 2.4, 2.5, and 3.4 preserve fixed carrier/wrapper ownership, conservative unknown handling,
and saturation. Tasks 6.1, 6.3, 6.4, and 6.7 require mapping-table mutations, normalized-string
exclusion, numeric overflow, 127/128/129 Store/live/combined receipts, unknown and interval-less
inputs, overflow suppression, long-stream bounds, and cleanup evidence.

## Exact ownership and denial-of-service verification

- The new gap enum/applicability fields remain inside each existing 256-byte normalized carrier. The
  saturating total and `hasMoreApplicableGaps` remain inside the existing 4,096-byte live-slice
  wrapper. The deadline receipt is fixed metadata inside already charged result/controller/identity
  ownership. None creates an uncharged variable collection, string, task, cache entry, or side list.
- The exact simultaneous owners remain the 16,777,216-byte shared ledger, 4,460,544-byte Store Event
  page, 4,493,312-byte live slice including 128 gaps, 8,704-byte Store gap page, and 65,536-byte
  decoder buffer. Their independently recalculated sum remains exactly 25,805,312 deterministic
  bytes. The artifacts continue to state that this is not a Swift heap guarantee
  (`specs/viewer-performance-dashboard/spec.md:97-114`; `design.md:108-138`).
- Store traversal remains forward-only and bounded to 4,096 examined candidates, 512 Event carriers,
  4,194,304 copied content bytes, 5,000,000 injected VM instructions, and an injected 50-ms turn.
  Before-first-candidate exhaustion is terminal, byte exhaustion does not examine the deferred row,
  and matching and nonmatching rows both advance the continuation.
- One source generation still owns one running scan, one dirty successor, one traversal/lease, one
  live slice, one latest-only delivery pump, and one replaceable deadline. Cache, result, bucket,
  diagnostic, mark, tooltip, accessibility, and gap-detail limits remain exact and independent of
  session length or refresh count.
- Store failure and recovery discard partial reducers and leases. Historical scope publishes only
  Storage unavailable; current live-only recovery begins from a fresh bounded generation and cannot
  merge predecessor partial/cache state.

## Privacy, cleanup, documentation, and signing verification

- Raw durable Events and bounded transient observations remain the only metric authority. The
  dashboard persists no JSON, decoded metrics, buckets, chart state, range, index, table, database, or
  derived export. Oversized and invalid content remains reachable only through ordinary bounded raw
  Event inspection.
- Performance-to-Explorer reveal passes only source generation and a metric-specific journal key.
  The deadline receipt and normalized gap metadata create no new controller handoff or sink.
- Received metrics remain excluded from copy, cut, drag, share, clipboard export, preferences,
  restoration, recent/safe rows, logs, analytics, and content-bearing reflection. Store/live carrier,
  error, diagnostic, and reflection tasks explicitly require content-free or redacted values.
- Runtime end, window close, listener failure, TLS/full reset, Store/source/device/runtime
  replacement, mode replacement, deinitialization, and claimed delivery invalidate/cancel/join work
  and clear deadlines, receipts, live slices, caches, cards, buckets, categorical values, diagnostics,
  summaries, locators, tooltip, accessibility, and delivery state before successor admission or the
  existing cleanup receipt completes.
- Swift Charts remains a macOS 13 system framework. The change adds no third-party runtime, root
  package/CocoaPods product, entitlement, schema migration, or derived persistence.
- Task 6.8 requires English operator documentation for authority, ranges, card/stale semantics,
  receive time, buckets, gaps, unavailable/invalid states, raw reveal, limits, privacy, cleanup,
  exclusions, and signing deferral. Tasks 6.1 through 6.7 require boundary, mutation, adversarial,
  lifecycle, exact-accounting, and 100,000-sample evidence. Task 6.9 requires the unsigned Viewer
  build, complete affected suites, lint, package/project/plist/privacy inspection, strict OpenSpec
  validation, and exact saved command results.
- Configured signing and inspection of entitlements embedded in a signed product remain explicitly
  deferred by product-owner decision to Goal-level `release-hardening`
  (`proposal.md:48-58`; `tasks.md:45-46`). Neither the current artifacts nor this review claim that
  deferred gate passed.

## Commands and results

```text
git diff --check -- openspec/changes/viewer-performance-dashboard
exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

awk 'BEGIN { print 16777216 + 4460544 + 4493312 + 8704 + 65536 }'
25805312
```

## Findings

No actionable findings.

## Unresolved finding count

**0**
