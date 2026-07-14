# Security, Performance, and Documentation Artifact Pre-Review — Round 5

Date: 2026-07-14
Change: `viewer-performance-dashboard`

## Verdict

**Approved for implementation from the security, performance, and documentation dimension.**

This fresh artifact-only review found no actionable privacy, content-retention, cleanup,
resource-bound, denial-of-service, dependency, documentation, evidence-plan, or signing-boundary
issue. The historical/current freshness split and Store applicable-overflow remediation close the two
Round 4 correctness findings without adding a variable content path or changing deterministic memory
ownership.

## Independent scope reviewed

- Reread the current `README.md`, proposal, design, tasks, and all five capability delta specs in
  full.
- Reread all three Round 4 reports and `pre-review-remediation-round4.md` in full. Their conclusions
  were checked against the current artifacts rather than inherited.
- Rechecked raw authority, decoding, traversal and classification limits, gap normalization, exact
  memory accounting, cache and refresh bounds, privacy sinks, lifecycle cleanup, dependency scope,
  documentation/evidence requirements, and Goal-level signing deferral.
- No production or test source was modified or treated as implementation evidence. No implementation
  test was run because this remains a pre-implementation artifact review.

## Status of Round 4 findings

### R4-CT-1: historical freshness clock domain — Resolved

Current and historical card freshness now use separate closed contracts:

- A current-source card result carries source generation, latest-Event journal key, absolute Viewer-
  monotonic deadline, and deadline revision. Claim and apply validate the full receipt against an
  injected current-uptime clock. Equality is stale, only a strictly future deadline may arm, one
  callback may fire, and an elapsed deadline cannot re-arm.
- A historical card compares its latest Event once with the frozen upper anchor in the same recording
  monotonic domain. It never compares persisted monotonic time with current process uptime, owns no
  freshness callback, does not age while paused, and cannot create a historical wake.
- Current/historical switching invalidates and joins the predecessor receipt before the successor uses
  its own clock domain (`specs/viewer-performance-dashboard/spec.md:135-159,242-285`;
  `design.md:147-170,218-235`).

Across both receipt variants, fields are limited to fixed source/Event/recording identity, monotonic
scalars, revision, and state values. They introduce no raw JSON, decoded content, label, variable
string, collection, cache entry, or per-sample task. Only one exact source is active; current owns at
most one deadline and historical owns zero deadlines. Receipt/model/controller values remain inside
the existing 16,777,216-byte shared ledger.

Cleanup invalidates receipt and deadline ownership before successor admission, cancels and joins
projection/reveal/deadline work, and clears cards, summaries, identities, cache, delivery, tooltip, and
accessibility state before the existing receipt completes
(`specs/viewer-performance-dashboard/spec.md:251-261,313-339`; `design.md:245-274`). Tasks 3.5, 4.1,
and 4.2 preserve the split in implementation. Tasks 6.4 through 6.6 require below/equal/above-current-
uptime historical anchors, simulated uptime reset, current/historical switching, Pause, replacement,
cleanup, exactly one current wake, zero historical wakes, constant bytes, and zero predecessor state.

### R4-CT-2: generic versus applicable Store gap overflow — Resolved

The Store gap page keeps a fixed 512-byte wrapper containing only generic `hasMoreRows`, one
saturating performance-or-uncertain count, and `hasMoreApplicableGaps`. Its at-most-32 fixed 256-byte
normalized carriers contain bounded row/scope identity, safe kind, wall interval, count, and
applicability. Namespace, reason, and direction strings do not cross the Store boundary
(`specs/viewer-local-store-search/spec.md:28-48`).

Store classifies the complete frozen matching metadata scope before deciding applicable overflow.
Hidden irrelevant-only rows set only generic pagination; any hidden performance or uncertain row sets
applicable overflow. Budget exhaustion is failure-closed: it sets `hasMoreApplicableGaps`, does not
claim complete classification, and cannot reconnect a chart line. The projector responds only to
applicable overflow for continuity, while retaining generic pagination separately
(`specs/viewer-performance-dashboard/spec.md:165-231`; `design.md:176-216`).

Classification is cancellation-aware, uses the accepted Store plan, and is bounded by 2,000,000
injected VM steps and an injected 250-ms limit. It retains no metadata-sized list: normalization and
classification reduce to fixed carriers, saturating scalar totals, and bits. The finite query-arbiter
lease, Store-generation rejection, cancellation, replacement, retry/reopen, and joined cleanup rules
remain unchanged. A corrupt, future, hidden, or budget-exhausted tail can therefore force conservative
line suppression but cannot force unbounded retained projection memory or a false connected line.

Tasks 2.2 and 2.4 require fixed wrappers, exact budgets, conservative unknown/budget behavior,
content-free reflection, no variable strings, one finite lease, and joined cleanup. Tasks 6.1, 6.4,
and 6.7 require exact page accounting, the full kind/applicability mapping, identical retained 128-row
receipts with irrelevant versus hidden-applicable 129th rows, classification budget failure,
normalized-string exclusion, cancellation/replacement/lease release, mixed Store/live boundaries,
overflow suppression, and deterministic VM/clock/byte/cleanup evidence.

## Exact memory and denial-of-service verification

- The Store wrapper remains 512 bytes. `512 + 32 × 256 = 8,704` bytes, so the new pagination and
  classification scalars do not enlarge the Store gap page.
- The live slice remains `4,096 + 512 × 512 + 4,194,304 + 128 × 256 = 4,493,312` bytes. The Store
  classifier creates no second live slice and no additional gap carrier owner.
- The simultaneous deterministic owners remain the 16,777,216-byte shared ledger, 4,460,544-byte
  Store Event page, 4,493,312-byte live slice, 8,704-byte Store gap page, and 65,536-byte decoder
  buffer. Their independently recalculated sum remains exactly 25,805,312 bytes. The artifacts still
  state that this is an accounting bound, not a Swift heap guarantee
  (`specs/viewer-performance-dashboard/spec.md:97-114`; `design.md:108-138`).
- Event traversal remains bounded to 4,096 examined candidates, 512 emitted carriers, 4,194,304 copied
  content bytes, 5,000,000 VM steps, and an injected 50-ms turn. Gap classification has its separate
  2,000,000-step/250-ms failure-closed budget. Host elapsed time remains diagnostic rather than the
  normative gate.
- One source generation still owns one running scan, one dirty successor, one finite traversal/lease,
  one bounded live slice, one latest-only delivery pump, and at most one current deadline. A historical
  source owns no deadline. Sustained refresh therefore creates neither one task nor one receipt per
  sample.
- Result, cache, bucket, diagnostic, gap-detail, mark, tooltip, accessibility, and source/device limits
  remain fixed. Store failure/recovery still discards every partial reducer and lease and cannot merge
  predecessor cache state.

## Privacy, cleanup, documentation, and signing verification

- Raw durable Events and bounded transient observations remain the only metric authority. No raw JSON,
  decoded metric, bucket, chart state, range, projection table/index/database, backfill, restoration,
  or derived export is persisted.
- Historical/current receipts and Store gap wrapper fields are content-free control metadata. The
  normalized boundary excludes namespace/reason/direction strings, and Performance-to-Explorer reveal
  still passes only source generation and one metric-specific journal key.
- Received values remain excluded from copy, cut, drag, share, clipboard export, preferences,
  restoration, recent/safe rows, logs, analytics, and content-bearing reflection. Errors,
  diagnostics, carriers, wrappers, and reflection are required to be fixed or redacted.
- Runtime end, window close, listener failure, TLS/full reset, Store/source/device/runtime
  replacement, mode replacement, deinitialization, and claimed delivery cancel/join work and clear
  current or historical receipts, deadlines, slices, caches, cards, buckets, categorical values,
  diagnostics, summaries, locators, tooltip, accessibility, and delivery state before successor
  admission or cleanup completion.
- Swift Charts remains a macOS 13 system framework. The change adds no third-party runtime, root
  package/CocoaPods product, entitlement, schema migration, or derived persistence.
- Task 6.8 requires English operator documentation covering ranges, cards and stale states, receive-
  time semantics, gaps, unavailable/invalid states, bounds, privacy, cleanup, exclusions, and signing
  deferral. That scope includes the user-visible frozen historical-card semantics and conservative
  applicable-gap overflow. Tasks 6.1 through 6.7 require deterministic boundary, adversarial,
  lifecycle, accounting, and 100,000-sample evidence; task 6.9 requires exact saved commands/results
  for the unsigned build, complete affected suites, lint, project/package/plist/privacy inspection,
  and strict OpenSpec validation.
- Configured signing and inspection of entitlements embedded in a signed product remain explicitly
  deferred by product-owner decision to Goal-level `release-hardening`
  (`proposal.md:48-58`; `tasks.md:45-46`). Neither the artifacts nor this review claim that deferred
  gate passed.

## Commands and results

```text
git diff --check -- openspec/changes/viewer-performance-dashboard
exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

awk 'BEGIN { gap=512 + 32 * 256; live=4096 + 512 * 512 + 4194304 + 128 * 256; peak=16777216 + 4460544 + live + gap + 65536; print gap, live, peak }'
8704 4493312 25805312
```

## Findings

No actionable findings.

## Unresolved finding count

**0**
