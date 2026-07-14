# Pre-Implementation Review Remediation — Round 1

Date: 2026-07-14

## Result

All first-round architecture/API, correctness/testing, and
security/performance/documentation findings were addressed in proposal-derived design, delta
specifications, and tasks before any production or test source changed. The revised change remains
strictly valid. A fresh independent review round is required before implementation.

Configured signing and inspection of entitlements embedded in a signed product remain deferred by
product-owner decision to Goal-level `release-hardening`; no artifact claims that gate passed.

## Traversal and raw-byte ownership

- The Store traversal is forward-only and carries an opaque last-examined key independent of emitted
  matches. Matching and nonmatching candidates both advance it; aggregate-byte exhaustion stops
  before the next row; VM/time exhaustion after a row advances through it; exhaustion before any
  candidate is terminal rather than a retrying empty continuation.
- One turn has exact 512 emitted, 4,096 examined, 5,000,000 injected-VM, and injected-50-ms limits.
  Host time is diagnostic only.
- SQLite length/type metadata precede content copy. A row above exactly 65,536 UTF-8 bytes returns
  identity/length/invalid metadata only. Copied content is at most 4,194,304 bytes and 512 fixed
  carrier bytes produce a 4,456,448-byte page/live-slice cap.

## Freeze, ranges, buckets, and cache

- Current scope uses a live-first drained-ingress anchor and later Store Event/gap uppers. Durable
  rows are filtered at/before that anchor and exact journal keys reconcile representation without
  double application or bucket movement.
- Historical ended/interrupted/empty anchors, inclusive range arithmetic, underflow behavior,
  exact bucket width/index/final-edge rules, equal-time order, and Current Session lower bound are
  explicit.
- Cache identity includes every source, range, upper-bound, and generation value. Exact hits/touches,
  fifth-entry eviction, moving-current-anchor behavior, and mandatory source/device clearing are
  specified.

## Availability, gaps, and traceability

- Duplicate known unavailable keys and present-plus-unavailable conflicts invalidate the entire
  typed snapshot. Current cards use the latest raw snapshot without metric fallback; mixed buckets
  retain measured statistics and separate state counts under a closed display precedence.
- The fixed 16-key availability section includes unavailable-only GPU, power, and Celsius fields,
  resolving the prior GPU-UI mismatch without fabricating values.
- Schema-2 wall-time gaps map only through monotonic bucket wall envelopes. Ambiguous, regressing,
  nonoverlapping, or excessive gaps suppress every line connection conservatively. Per-metric break
  flags and saturating detail loss ensure discarded detail never reconnects a line.
- Each metric accumulator owns its own contributing journal key with exact tie order. Raw reveal
  resolves durable-then-live locator at action time and cannot select a neighbor.

## Resource, refresh, availability, and lifecycle bounds

- Per-result, global derived-state, page/slice, decoder, diagnostics, categorical, chart-mark,
  tooltip, accessibility, and exact 25,755,648-byte peak accounting are all numeric. Source/device
  replacement joins and clears the one global cache before successor admission.
- Refresh owns one running scan plus one dirty successor and one replaceable freshness-deadline wake,
  preventing sustained-input starvation and stale cards without polling.
- Historical unavailable, current Live window only, mid-scan failure, recovery, Pause, paused range,
  and source/device/runtime replacement each have closed behavior; predecessor partial buckets are
  never reused.
- One analysis-mode coordinator releases and joins the current Event or Performance traversal before
  successor submission or raw reveal. At most one mode owns the shared arbiter traversal.

## Validation

```text
env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid

env DO_NOT_TRACK=1 openspec show viewer-performance-dashboard --json --deltas-only
deltaCount: 10

git diff --check
exit 0
```

Only OpenSpec artifacts and their review/remediation reports exist in the active diff.
